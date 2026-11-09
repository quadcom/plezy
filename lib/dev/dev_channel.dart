import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../mpv/mpv.dart';
import '../services/settings_mutation_service.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/dev_log_file.dart';
import '../utils/snackbar_helper.dart';
import 'playback_timing.dart';

/// A developer's window into a running copy of Plezy (local/plans/player-inspector.md).
///
/// In every build, but it only runs while developer mode is on: the "Save Log
/// to File" setting, the `plezy-debug-on` switch file (see [DevLogFile]), or a
/// test build made with `--dart-define=PLEZY_DEV_LOG=true`. Off, nothing runs:
/// no port, no timer. On, it gives:
/// - a control line on 127.0.0.1 (this device only), one JSON command per line,
///   to read or change player and app settings live, and to undo every change;
/// - a timing recorder that writes `logs/plezy-timing.log` while a video plays,
///   one line per dropped or late frame, stall, sync jump or buffer dip;
/// - mpv's own control pipe, `\\.\pipe\plezy-mpv` on Windows;
/// - the `H` key in the player, which marks a hitch with the last 5 seconds.
///
/// Every change made through the line shows on screen and is logged, and
/// switching developer mode off undoes them all.
class DevChannel {
  DevChannel._();

  static bool get enabled => DevLogFile.enabled;
  static const preferredPort = 47811;
  static const mpvPipe = r'\\.\pipe\plezy-mpv';

  /// Settings the line may not change: they reach outside this device, or
  /// (developer mode itself) would close the line under the request.
  static const _blockedSettings = {
    'custom_relay_url',
    'crash_reporting',
    'enable_companion_remote_server',
    'auto_check_updates_on_startup',
    'dev_log_to_file',
  };

  static const _timingProperties = [
    'time-pos',
    'pause',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'vo-delayed-frame-count',
    'mistimed-frame-count',
    'avsync',
    'total-avsync-change',
    'demuxer-cache-duration',
    'paused-for-cache',
    'speed',
    'display-fps',
  ];

  static ServerSocket? _server;
  static BuildContext? Function()? _context;
  static Player? _player;
  static void Function(String text)? _toast;
  static RandomAccessFile? _timingFile;
  static Timer? _sampleTimer;
  static Timer? _heartbeat;
  static bool _watching = false;
  static bool _hooked = false;
  static bool _configured = false;
  static int _port = 0;
  static Future<void> _syncTail = Future<void>.value();
  static Duration _interval = const Duration(milliseconds: 200);
  static PlaybackTimingAnalyzer _analyzer = PlaybackTimingAnalyzer(expectedInterval: _interval);
  static PlaybackSample? _lastSample;
  static final ListQueue<PlaybackSample> _recent = ListQueue();
  static final ListQueue<String> _recentEvents = ListQueue();

  /// Changes made through the line, oldest first, for `revert`.
  static final List<({String kind, String name, Object? before, Player? player})> _changes = [];

  /// Called once at start. [context] gives a live context for settings that
  /// need their runtime effect applied. The line then follows developer mode.
  static void configure({required BuildContext? Function() context}) {
    _context = context;
    if (_configured) return;
    _configured = true;
    DevLogFile.onEnabledChanged = _sync;
    _sync();
  }

  /// Opens or closes everything to match [enabled]. Calls queue, so a quick
  /// on-off-on can't leave two listeners.
  static void _sync() {
    _syncTail = _syncTail.then((_) async {
      try {
        if (enabled && _server == null) {
          await _open();
        } else if (!enabled && _server != null) {
          await _shutdown();
        }
      } catch (e) {
        appLogger.w('Dev channel: could not follow developer mode', error: e);
      }
    });
  }

  static Future<void> _open() async {
    await _openTimingFile();
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferredPort);
    } catch (_) {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    _port = _server!.port;
    _server!.listen(_serve, onError: (Object e) => appLogger.w('Dev channel: listener error', error: e));
    try {
      final dir = await _logsDir();
      await File(p.join(dir.path, 'dev-channel.port')).writeAsString('$_port');
    } catch (_) {}
    _hookKeys();
    appLogger.i('Dev channel: listening on 127.0.0.1:$_port');
    if (DevLogFile.switchedOnByFile) showMainSnackBar('Developer mode on');
    final player = _player;
    if (player != null) _watch(player);
  }

  static Future<void> _shutdown() async {
    if (_changes.isNotEmpty) await _revert();
    final player = _player;
    _unwatch();
    if (player != null && Platform.isWindows) {
      try {
        await player.setProperty('input-ipc-server', '');
      } catch (_) {}
    }
    await _server?.close();
    _server = null;
    try {
      await File(p.join((await _logsDir()).path, 'dev-channel.port')).delete();
    } catch (_) {}
    _timingLine('developer mode off');
    final file = _timingFile;
    _timingFile = null;
    try {
      await file?.close();
    } catch (_) {}
    appLogger.i('Dev channel: closed');
  }

  /// The player screen hands over its player while it plays. Cheap when
  /// developer mode is off: the player is only remembered.
  static void attachPlayer(Player player, {required void Function(String text) toast}) {
    _player = player;
    _toast = toast;
    if (enabled && _server != null) _watch(player);
  }

  static void detachPlayer(Player player) {
    if (!identical(_player, player)) return;
    final wasWatching = _watching;
    _unwatch();
    _player = null;
    _toast = null;
    if (wasWatching) _timing('player detached');
  }

  static void _watch(Player player) {
    _analyzer = PlaybackTimingAnalyzer(expectedInterval: _interval);
    _lastSample = null;
    _recent.clear();
    if (Platform.isWindows) {
      unawaited(() async {
        try {
          await player.setProperty('input-ipc-server', mpvPipe);
          appLogger.i('Dev channel: mpv pipe open at $mpvPipe');
        } catch (e) {
          appLogger.w('Dev channel: mpv pipe not opened', error: e);
        }
      }());
    }
    _timing('player attached');
    _watching = true;
    _scheduleSample();
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      final s = _lastSample;
      if (s != null) _timingLine('state ${s.describe()}');
    });
  }

  static void _unwatch() {
    _watching = false;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  // ---------------------------------------------------------------- recorder

  static void _scheduleSample() {
    if (!_watching) return;
    _sampleTimer?.cancel();
    _sampleTimer = Timer(_interval, _sample);
  }

  static Future<void> _sample() async {
    final player = _player;
    if (player == null || !_watching) return;
    final values = await Future.wait(
      _timingProperties.map((name) async {
        try {
          return await player.getProperty(name);
        } catch (_) {
          return null;
        }
      }),
    );
    if (!identical(player, _player) || !_watching) return;
    double? d(int i) => double.tryParse(values[i] ?? '');
    int? n(int i) => int.tryParse(values[i] ?? '');
    final sample = PlaybackSample(
      wall: DateTime.now(),
      position: d(0),
      paused: values[1] == 'yes',
      droppedFrames: n(2),
      decoderDroppedFrames: n(3),
      delayedFrames: n(4),
      mistimedFrames: n(5),
      avsync: d(6),
      totalAvsyncChange: d(7),
      cacheSeconds: d(8),
      pausedForCache: values[9] == 'yes',
      speed: d(10),
      displayFps: d(11),
    );
    _lastSample = sample;
    _recent.addLast(sample);
    while (_recent.isNotEmpty && sample.wall.difference(_recent.first.wall) > const Duration(seconds: 5)) {
      _recent.removeFirst();
    }
    for (final event in _analyzer.feed(sample)) {
      _timing(event, sample: sample);
    }
    _scheduleSample();
  }

  /// Marks a hitch: a line in both logs plus the last 5 seconds of samples.
  static void mark(String why) {
    _timing('HITCH MARKED ($why)', sample: _lastSample, toDevLog: true);
    for (final s in _recent) {
      _timingLine('  ${_clock(s.wall)} ${s.describe()}');
    }
    _toast?.call('Hitch marked');
  }

  static void _timing(String event, {PlaybackSample? sample, bool toDevLog = true}) {
    final pos = sample?.position;
    final text = pos == null ? event : '$event @ ${pos.toStringAsFixed(3)}';
    _timingLine(text);
    _recentEvents.addLast('${_clock(DateTime.now())} $text');
    while (_recentEvents.length > 200) {
      _recentEvents.removeFirst();
    }
    if (toDevLog) appLogger.d('[TIMING] $text');
  }

  static void _timingLine(String text) {
    final file = _timingFile;
    if (file == null) return;
    try {
      file
        ..writeStringSync('${DateTime.now().toIso8601String()} $text\n')
        ..flushSync();
    } catch (_) {}
  }

  static String _clock(DateTime t) => t.toIso8601String().substring(11, 23);

  static Future<Directory> _logsDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _openTimingFile() async {
    try {
      final dir = await _logsDir();
      final file = File(p.join(dir.path, 'plezy-timing.log'));
      if (await file.exists()) await file.rename(p.join(dir.path, 'plezy-timing.prev.log'));
      _timingFile = await file.open(mode: FileMode.writeOnlyAppend);
    } catch (e) {
      appLogger.w('Dev channel: timing log not opened', error: e);
    }
  }

  static void _hookKeys() {
    if (_hooked) return;
    _hooked = true;
    HardwareKeyboard.instance.addHandler((event) {
      if (_watching && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyH && !_typing()) {
        mark('H key');
      }
      return false;
    });
  }

  static bool _typing() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  // ------------------------------------------------------------ control line

  static void _serve(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            Object? reply;
            try {
              final request = jsonDecode(line);
              if (request is! Map<String, dynamic>) throw const FormatException('Send a JSON object per line.');
              reply = {'ok': true, 'result': await _handle(request)};
            } catch (e) {
              reply = {'ok': false, 'error': '$e'};
            }
            try {
              socket.write('${jsonEncode(reply)}\n');
            } catch (_) {}
          },
          onError: (Object _) => socket.destroy(),
          onDone: socket.destroy,
          cancelOnError: true,
        );
  }

  static Future<Object?> _handle(Map<String, dynamic> r) async {
    final cmd = r['cmd'] as String? ?? '';
    switch (cmd) {
      case 'ping':
        return 'pong';
      case 'status':
        return {
          'port': _port,
          'playing': _player != null,
          'switchFile': DevLogFile.switchedOnByFile,
          'intervalMs': _interval.inMilliseconds,
          'mpvPipe': Platform.isWindows ? mpvPipe : null,
          'changes': [for (final c in _changes) '${c.kind} ${c.name} (was ${c.before})'],
          'last': _lastSample?.describe(),
        };
      case 'events':
        final count = (r['count'] as num?)?.toInt() ?? 50;
        return _recentEvents.toList().reversed.take(count).toList().reversed.toList();
      case 'mark':
        mark(r['why'] as String? ?? 'dev channel');
        return 'marked';
      case 'timing.interval':
        final ms = (r['ms'] as num).toInt().clamp(50, 5000);
        _interval = Duration(milliseconds: ms);
        _analyzer = PlaybackTimingAnalyzer(expectedInterval: _interval);
        _lastSample = null;
        _timing('sampling every $ms ms');
        return ms;
      case 'mpv.get':
        final player = _requirePlayer();
        final names = r['names'] is List ? (r['names'] as List).cast<String>() : [r['name'] as String];
        final values = await Future.wait(names.map(player.getProperty));
        return {for (var i = 0; i < names.length; i++) names[i]: values[i]};
      case 'mpv.set':
        final player = _requirePlayer();
        final name = r['name'] as String;
        final value = '${r['value']}';
        final before = await player.getProperty(name);
        await player.setProperty(name, value);
        _changes.add((kind: 'mpv', name: name, before: before, player: player));
        _announce('player $name = $value (was $before)');
        return {'name': name, 'before': before, 'now': await player.getProperty(name)};
      case 'settings.list':
        final settings = SettingsService.instance;
        return {
          for (final pref in SettingsService.editableAppPrefs)
            if (!_blockedSettings.contains(pref.key)) pref.key: pref.toJson(settings.read(pref)),
        };
      case 'settings.get':
        final pref = _pref(r['key'] as String);
        return pref.toJson(SettingsService.instance.read(pref));
      case 'settings.set':
        final pref = _pref(r['key'] as String);
        final settings = SettingsService.instance;
        final before = pref.toJson(settings.read(pref));
        await _writeSetting(pref, pref.fromJson(r['value']));
        _changes.add((kind: 'setting', name: pref.key, before: before, player: null));
        final now = pref.toJson(settings.read(pref));
        _announce('setting ${pref.key} = $now (was $before)');
        return {'key': pref.key, 'before': before, 'now': now};
      case 'revert':
        return _revert();
    }
    throw FormatException(
      'Unknown cmd "$cmd". Try: ping, status, events, mark, timing.interval, '
      'mpv.get, mpv.set, settings.list, settings.get, settings.set, revert.',
    );
  }

  static Player _requirePlayer() {
    final player = _player;
    if (player == null) throw StateError('No video is playing.');
    return player;
  }

  static Pref<Object?> _pref(String key) {
    if (_blockedSettings.contains(key)) throw StateError('$key is not changeable through the dev channel.');
    for (final pref in SettingsService.editableAppPrefs) {
      if (pref.key == key) return pref;
    }
    throw StateError('Unknown setting "$key".');
  }

  static Future<void> _writeSetting(Pref<Object?> pref, Object? value) async {
    SettingsService.validateEditableValue(pref, value);
    await SettingsService.instance.write(pref, value);
    final context = _context?.call();
    if (context != null && context.mounted) {
      final failure = await const SettingsMutationService().applyEffects(context, pref, rebuildRoot: false);
      if (failure != null) appLogger.w('Dev channel: ${pref.key} saved, effect declined: ${failure.display}');
    }
  }

  static Future<List<String>> _revert() async {
    final done = <String>[];
    for (final c in _changes.reversed.toList()) {
      try {
        if (c.kind == 'mpv') {
          if (!identical(c.player, _player) || c.before == null) {
            done.add('player ${c.name}: skipped (that video has ended)');
            continue;
          }
          await c.player!.setProperty(c.name, c.before! as String);
          done.add('player ${c.name} = ${c.before}');
        } else {
          final pref = _pref(c.name);
          await _writeSetting(pref, pref.fromJson(c.before));
          done.add('setting ${c.name} = ${c.before}');
        }
      } catch (e) {
        done.add('${c.kind} ${c.name}: failed ($e)');
      }
    }
    _changes.clear();
    _announce('reverted ${done.length} change(s)', toastText: 'Claude undid its changes');
    for (final line in done) {
      _timing('  revert: $line');
    }
    return done;
  }

  /// Every change shows on screen: as a player toast during a video, as a
  /// snackbar otherwise.
  static void _announce(String what, {String? toastText}) {
    appLogger.i('[DEV CHANNEL] $what');
    _timing('[DEV CHANNEL] $what', sample: _lastSample, toDevLog: false);
    final text = toastText ?? 'Claude changed: $what';
    final toast = _toast;
    if (toast != null) {
      toast(text);
    } else {
      showMainSnackBar(text);
    }
  }
}
