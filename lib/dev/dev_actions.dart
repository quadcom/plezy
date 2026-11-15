import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

import '../media/ids.dart';
import '../mpv/mpv.dart';
import '../navigation/profile_navigation_scope.dart';
import '../navigation/settings_shortcut.dart';
import '../providers/multi_server_provider.dart';
import '../screens/settings/dev_tools_screen.dart';
import '../services/agent_control_service.dart';
import '../services/image_cache_service.dart';
import '../services/settings_mutation_service.dart';
import '../services/update_service.dart';
import '../utils/app_logger.dart' show MemoryLogOutput;
import '../utils/dev_log_file.dart';
import '../utils/key_event_simulator.dart' as key_sim;
import '../utils/media_navigation_helper.dart';
import 'server_write_guard.dart';
import 'startup_timeline.dart';

/// One input of a [DevAction].
class DevActionInput {
  const DevActionInput(this.name, this.type, this.description, {this.required = false, this.choices});

  final String name;

  /// `string`, `int`, `number`, `bool` or `choice`.
  final String type;
  final String description;
  final bool required;
  final List<String>? choices;

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'description': description,
    'required': required,
    'choices': ?choices,
  };
}

/// Something a developer, or an agent through the dev channel, can do to the
/// running app (local/plans/dev-tools.md). The Developer tools page and the
/// channel's `actions.list` / `actions.run` both come from [DevActions.all].
class DevAction {
  const DevAction({
    required this.name,
    required this.group,
    required this.description,
    this.inputs = const [],
    this.changes = false,
    required this.run,
  });

  final String name;

  /// `look`, `navigate`, `player` or `app`.
  final String group;
  final String description;
  final List<DevActionInput> inputs;

  /// Whether it changes anything (shown on screen when run).
  final bool changes;
  final Future<Object?> Function(Map<String, dynamic> args) run;

  Map<String, dynamic> toJson() => {
    'name': name,
    'group': group,
    'description': description,
    'changes': changes,
    'inputs': [for (final i in inputs) i.toJson()],
  };
}

class DevActions {
  DevActions._();

  static const groups = ['look', 'navigate', 'player', 'app'];

  static BuildContext? Function() _rootContext = () => null;
  static void Function(String text) _announce = (_) {};
  static int _requestSeq = 0;

  /// Wired by the dev channel. [rootContext] is a context under the root
  /// navigator; [announce] shows a change on screen and logs it.
  static void configure({required BuildContext? Function() rootContext, required void Function(String text) announce}) {
    _rootContext = rootContext;
    _announce = announce;
  }

  static DevAction? byName(String name) {
    for (final action in all) {
      if (action.name == name) return action;
    }
    return null;
  }

  /// Checks [args] against the action's inputs, then runs it.
  /// [fromPage] is a person pressing the button on the Developer tools page,
  /// who needs no on-screen note; the dev channel's runs are always shown.
  static Future<Object?> run(String name, Map<String, dynamic> args, {bool fromPage = false}) async {
    if (!DevLogFile.enabled) throw StateError('Developer mode is off.');
    final action = byName(name);
    if (action == null) throw StateError('Unknown action "$name". Ask actions.list for the names.');
    final clean = validate(action, args);
    if (action.changes && !fromPage) _announce('ran ${action.name}${clean.isEmpty ? '' : ' ${jsonEncode(clean)}'}');
    return action.run(clean);
  }

  /// Returns the arguments with numbers and booleans in their declared types.
  @visibleForTesting
  static Map<String, dynamic> validate(DevAction action, Map<String, dynamic> args) {
    final known = {for (final i in action.inputs) i.name: i};
    for (final key in args.keys) {
      if (!known.containsKey(key)) throw ArgumentError('${action.name} has no input "$key".');
    }
    final out = <String, dynamic>{};
    for (final input in action.inputs) {
      final raw = args[input.name];
      if (raw == null) {
        if (input.required) throw ArgumentError('${action.name} needs "${input.name}".');
        continue;
      }
      out[input.name] = switch (input.type) {
        'int' =>
          raw is num
              ? raw.toInt()
              : int.tryParse('$raw') ?? (throw ArgumentError('${input.name} must be a whole number.')),
        'number' =>
          raw is num
              ? raw.toDouble()
              : double.tryParse('$raw') ?? (throw ArgumentError('${input.name} must be a number.')),
        'bool' =>
          raw is bool
              ? raw
              : switch ('$raw'.toLowerCase()) {
                  'true' || 'yes' || '1' || 'on' => true,
                  'false' || 'no' || '0' || 'off' => false,
                  _ => throw ArgumentError('${input.name} must be true or false.'),
                },
        'choice' =>
          (input.choices ?? const []).contains('$raw')
              ? '$raw'
              : throw ArgumentError('${input.name} must be one of ${input.choices?.join(', ')}.'),
        _ => '$raw',
      };
    }
    return out;
  }

  // ------------------------------------------------------------------ list

  static final List<DevAction> all = [
    // look
    DevAction(
      name: 'app.status',
      group: 'look',
      description: 'App version, platform, developer mode, servers, whether a video plays, blocked server writes.',
      run: (_) => appStatus(),
    ),
    DevAction(
      name: 'ui.screen',
      group: 'look',
      description: 'Which pages are open (oldest first) and which item has focus.',
      run: (_) async => screenInfo(),
    ),
    DevAction(
      name: 'ui.read',
      group: 'look',
      description: 'The text on screen with positions (logical pixels), read from the accessibility tree.',
      inputs: const [DevActionInput('max', 'int', 'Most nodes to return (default 400).')],
      run: (args) => readScreen(max: (args['max'] as int?) ?? 400),
    ),
    DevAction(
      name: 'ui.screenshot',
      group: 'look',
      description: 'Saves a PNG of the app window in the logs folder and returns its path. Video may show black.',
      inputs: const [DevActionInput('scale', 'number', 'Size against the screen (default 1, max 2).')],
      run: (args) => screenshot(scale: (args['scale'] as double?) ?? 1),
    ),
    DevAction(
      name: 'startup.timeline',
      group: 'look',
      description: 'How long each start-up step took in this run.',
      run: (_) async => StartupTimeline.toJson(),
    ),
    DevAction(
      name: 'log.tail',
      group: 'look',
      description: 'The newest app log lines.',
      inputs: const [
        DevActionInput('count', 'int', 'How many lines (default 100, max 1000).'),
        DevActionInput('contains', 'string', 'Only lines containing this text.'),
      ],
      run: (args) async => logTail(count: (args['count'] as int?) ?? 100, contains: args['contains'] as String?),
    ),
    DevAction(
      name: 'server.blocked_writes',
      group: 'look',
      description: 'Server writes held back by the switch file (newest last).',
      run: (_) async => ServerWriteGuard.recentBlocked(),
    ),
    DevAction(
      name: 'media.servers',
      group: 'look',
      description: 'The servers this profile uses, with their ids.',
      run: (_) => agent('media.servers', const {}),
    ),
    DevAction(
      name: 'media.search',
      group: 'look',
      description: 'Search a server for items; returns ids for nav.open and player.play.',
      inputs: const [
        DevActionInput('query', 'string', 'What to search for.', required: true),
        DevActionInput('serverId', 'string', 'Server id (default: the first server).'),
        DevActionInput('type', 'string', 'Only this kind, such as movie, show, episode.'),
        DevActionInput('limit', 'int', 'Most results (default 20).'),
      ],
      run: (args) async => agent('media.search', {
        ...args,
        'serverId': await _serverId(args['serverId'] as String?),
        'limit': args['limit'] ?? 20,
      }),
    ),
    DevAction(
      name: 'media.get',
      group: 'look',
      description: 'One item\'s details by id.',
      inputs: const [
        DevActionInput('itemId', 'string', 'Item id.', required: true),
        DevActionInput('serverId', 'string', 'Server id (default: the first server).'),
      ],
      run: (args) async => agent('media.get', {...args, 'serverId': await _serverId(args['serverId'] as String?)}),
    ),
    DevAction(
      name: 'media.children',
      group: 'look',
      description: 'The seasons, episodes or tracks inside an item.',
      inputs: const [
        DevActionInput('itemId', 'string', 'Parent item id.', required: true),
        DevActionInput('serverId', 'string', 'Server id (default: the first server).'),
        DevActionInput('limit', 'int', 'Most results (default 50).'),
      ],
      run: (args) async => agent('media.children', {
        ...args,
        'serverId': await _serverId(args['serverId'] as String?),
        'limit': args['limit'] ?? 50,
      }),
    ),
    DevAction(
      name: 'devices.gamepads',
      group: 'look',
      description: 'Game controllers the gamepad library sees.',
      run: (_) async => (await Gamepad.instance.listGamepads()).map((g) => {'id': g.id, 'name': g.name}).toList(),
    ),

    // navigate
    DevAction(
      name: 'ui.key',
      group: 'navigate',
      description: 'Presses a remote or keyboard key on whatever has focus, like a TV remote.',
      changes: true,
      inputs: [
        DevActionInput(
          'key',
          'string',
          'One of ${_namedKeys.keys.join(', ')}, or a single letter or digit.',
          required: true,
        ),
        const DevActionInput('times', 'int', 'How many presses (default 1, max 50).'),
      ],
      run: (args) => pressKey(args['key'] as String, times: (args['times'] as int?) ?? 1),
    ),
    DevAction(
      name: 'nav.back',
      group: 'navigate',
      description: 'Goes back one page (closes the top dialog or page).',
      changes: true,
      run: (_) => back(),
    ),
    DevAction(
      name: 'nav.home',
      group: 'navigate',
      description: 'Closes every page back to the home screen.',
      changes: true,
      run: (_) => home(),
    ),
    DevAction(
      name: 'nav.settings',
      group: 'navigate',
      description: 'Opens Settings, or the Developer tools page.',
      changes: true,
      inputs: const [
        DevActionInput('page', 'choice', 'Which page (default settings).', choices: ['settings', 'dev_tools']),
      ],
      run: (args) => openSettings(devTools: args['page'] == 'dev_tools'),
    ),
    DevAction(
      name: 'nav.open',
      group: 'navigate',
      description: 'Opens an item\'s page (movie, show, season, episode, collection) by id.',
      changes: true,
      inputs: const [
        DevActionInput('itemId', 'string', 'Item id.', required: true),
        DevActionInput('serverId', 'string', 'Server id (default: the first server).'),
      ],
      run: (args) => openItem(args['itemId'] as String, serverId: args['serverId'] as String?),
    ),

    // player
    DevAction(
      name: 'player.play',
      group: 'player',
      description: 'Plays an item by id. Nothing is reported to the server while the switch file is on.',
      changes: true,
      inputs: const [
        DevActionInput('itemId', 'string', 'Item id.', required: true),
        DevActionInput('serverId', 'string', 'Server id (default: the first server).'),
        DevActionInput(
          'start',
          'choice',
          'From the start or the saved spot (default resume).',
          choices: ['resume', 'beginning'],
        ),
        DevActionInput('positionSeconds', 'number', 'Start at this many seconds instead.'),
      ],
      run: (args) async => agent('playback.start', {
        'serverId': await _serverId(args['serverId'] as String?),
        'itemId': args['itemId'],
        'start': ?args['start'],
        if (args['positionSeconds'] != null) 'positionMs': ((args['positionSeconds'] as double) * 1000).round(),
      }),
    ),
    DevAction(
      name: 'player.status',
      group: 'player',
      description: 'What is playing, its stage, and the player\'s position, length and pause state.',
      run: (_) => playerStatus(),
    ),
    DevAction(
      name: 'player.pause',
      group: 'player',
      description: 'Pauses the video.',
      changes: true,
      run: (_) async {
        await _requirePlayer().pause();
        return 'paused';
      },
    ),
    DevAction(
      name: 'player.resume',
      group: 'player',
      description: 'Resumes the video.',
      changes: true,
      run: (_) async {
        await _requirePlayer().play();
        return 'playing';
      },
    ),
    DevAction(
      name: 'player.seek',
      group: 'player',
      description: 'Jumps to a time, or by an amount.',
      changes: true,
      inputs: const [
        DevActionInput('seconds', 'number', 'Where to go, in seconds from the start.'),
        DevActionInput('by', 'number', 'Or how far to move, in seconds (negative goes back).'),
      ],
      run: (args) => seek(to: args['seconds'] as double?, by: args['by'] as double?),
    ),
    DevAction(
      name: 'player.stop',
      group: 'player',
      description: 'Stops the video or music and leaves the player.',
      changes: true,
      run: (_) => agent('playback.stop', const {}),
    ),
    DevAction(
      name: 'player.tracks',
      group: 'player',
      description: 'The audio, subtitle and video tracks of the playing video. Switch with mpv.set aid/sid.',
      run: (_) => tracks(),
    ),

    // app
    DevAction(
      name: 'cache.clear_images',
      group: 'app',
      description: 'Empties the artwork cache (memory and disk); images load again from the server.',
      changes: true,
      run: (_) async {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await PlexImageCacheManager.instance.emptyCache();
        return 'image cache emptied';
      },
    ),
    DevAction(
      name: 'server.check',
      group: 'app',
      description: 'Checks every server connection again now.',
      changes: true,
      run: (_) async {
        final servers = _rootRead<MultiServerProvider>();
        await servers.checkServerHealth();
        return {'online': servers.serverIds.where((id) => servers.isServerOnline(ServerId(id))).toList()};
      },
    ),
    DevAction(
      name: 'update.check',
      group: 'app',
      description: 'Asks GitHub whether a newer Plezy is out. Never installs anything.',
      run: (_) async => await UpdateService.checkForUpdates() ?? {'update': false},
    ),
    DevAction(
      name: 'gamepad.pause',
      group: 'app',
      description: 'Stops the gamepad library reading devices until gamepad.resume or the window regains focus.',
      changes: true,
      run: (_) async {
        await Gamepad.instance.pause();
        return 'gamepad paused';
      },
    ),
    DevAction(
      name: 'gamepad.resume',
      group: 'app',
      description: 'Starts the gamepad library reading devices again.',
      changes: true,
      run: (_) async {
        await Gamepad.instance.resume();
        return 'gamepad resumed';
      },
    ),
  ];

  // --------------------------------------------------------------- helpers

  static T _rootRead<T>() {
    final context = _profileContext() ?? _rootContext();
    if (context == null || !context.mounted) throw StateError('The app has not finished starting.');
    return context.read<T>();
  }

  static BuildContext? _profileContext() {
    final navigator = profileNavigationRegistry.navigator;
    return navigator?.overlay?.context ?? navigator?.context;
  }

  static Future<String> _serverId(String? given) async {
    if (given != null && given.isNotEmpty) return given;
    final ids = _rootRead<MultiServerProvider>().serverIds;
    if (ids.isEmpty) throw StateError('No server is connected.');
    return ids.first;
  }

  static Player _requirePlayer() {
    final player = playerLookup?.call();
    if (player == null) throw StateError('No video is playing.');
    return player;
  }

  /// The player the video screen handed to the dev channel, if any.
  static Player? Function()? playerLookup;

  /// Wraps the app (in main.dart) so [screenshot] can draw it in any build.
  static final screenshotKey = GlobalKey(debugLabel: 'dev-screenshot');

  // ------------------------------------------------- agent control bridge

  static const _agentMutations = {
    'settings.set',
    'settings.reset',
    'settings.apply',
    'playback.start',
    'playback.stop',
  };

  /// Runs one command of the built-in agent control service
  /// (lib/services/agent_control_service.dart) and returns its result.
  /// Setting changes are limited to this device's own settings (scope app):
  /// developer mode never changes anything stored on the server.
  static Future<Object?> agent(String command, Map<String, dynamic> arguments) async {
    if (command.startsWith('settings.') && command != 'settings.list' && command != 'settings.get') {
      final changes = command == 'settings.apply' ? (arguments['changes'] as List? ?? const []) : [arguments];
      for (final change in changes) {
        final scope = change is Map ? change['scope'] : null;
        if (scope != null && (scope is! Map || scope['type'] != 'app')) {
          throw StateError('Developer mode only changes this device\'s own settings (scope app).');
        }
      }
    }
    final service = AgentControlService.instance;
    String? token;
    if (_agentMutations.contains(command)) {
      final status = await service.executePayload(_payload('app.status', const {}));
      token = (status['result'] as Map?)?['sessionToken'] as String?;
    }
    BuildContext? rebuild;
    final response = await service.executePayload(
      _payload(command, arguments, sessionToken: token),
      onRootRebuild: (context) => rebuild = context.context,
    );
    final context = rebuild;
    if (context != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) SettingsMutationService.rebuild(context);
      });
    }
    if (response['ok'] != true) throw StateError('agent $command failed: ${jsonEncode(response['error'])}');
    return response['result'];
  }

  static String _payload(String command, Map<String, dynamic> arguments, {String? sessionToken}) => jsonEncode({
    'version': AgentControlService.protocolVersion,
    'requestId': 'dev-${++_requestSeq}',
    'command': command,
    'arguments': arguments,
    'sessionToken': ?sessionToken,
  });

  // ----------------------------------------------------------------- look

  static Future<Map<String, dynamic>> appStatus() async {
    final info = await PackageInfo.fromPlatform();
    Map<String, dynamic>? servers;
    try {
      final provider = _rootRead<MultiServerProvider>();
      servers = {
        for (final id in provider.serverIds)
          id: {
            'name': provider.serverManager.serverDisplayName(ServerId(id)),
            'online': provider.isServerOnline(ServerId(id)),
          },
      };
    } catch (_) {}
    return {
      'version': info.version,
      'build': info.buildNumber,
      'platform': Platform.operatingSystem,
      'developerMode': DevLogFile.enabled,
      'developerModeBySwitchFile': DevLogFile.switchedOnByFile,
      'serverWritesBlocked': ServerWriteGuard.active,
      'blockedWriteCount': ServerWriteGuard.blockedCount,
      'videoPlaying': playerLookup?.call() != null,
      'servers': ?servers,
    };
  }

  static Map<String, dynamic> screenInfo() {
    final screens = <String>[];
    void visit(Element element) {
      final name = element.widget.runtimeType.toString();
      if (_isScreenName(name) && (screens.isEmpty || screens.last != name)) screens.add(name);
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    final chain = <String>[];
    focusContext?.visitAncestorElements((element) {
      final name = element.widget.runtimeType.toString();
      if (_isScreenName(name)) chain.add(name);
      return chain.length < 6;
    });
    String? focusText;
    if (focusContext != null) {
      final texts = <String>[];
      void collect(Element element) {
        final widget = element.widget;
        if (widget is Text && (widget.data ?? widget.textSpan?.toPlainText() ?? '').isNotEmpty) {
          texts.add(widget.data ?? widget.textSpan!.toPlainText());
        }
        if (texts.length < 4) element.visitChildElements(collect);
      }

      (focusContext as Element).visitChildElements(collect);
      if (texts.isNotEmpty) focusText = texts.join(' | ');
    }
    return {
      'screens': screens,
      'focus': focus == null
          ? null
          : {
              'label': focus.debugLabel,
              'text': ?focusText,
              'insideScreens': chain,
              if (focus.rect.isFinite) 'rect': _rect(focus.rect),
            },
    };
  }

  static bool _isScreenName(String name) =>
      !name.startsWith('_') &&
      (name.endsWith('Screen') || name.endsWith('Page') || name.endsWith('Dialog') || name.endsWith('Sheet'));

  static Map<String, int> _rect(Rect r) => {
    'x': r.left.round(),
    'y': r.top.round(),
    'w': r.width.round(),
    'h': r.height.round(),
  };

  static Future<Map<String, dynamic>> readScreen({int max = 400}) async {
    final limit = max.clamp(1, 5000);
    final handle = SemanticsBinding.instance.ensureSemantics();
    try {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      final nodes = <Map<String, dynamic>>[];
      var truncated = false;
      for (final view in RendererBinding.instance.renderViews) {
        final root = view.owner?.semanticsOwner?.rootSemanticsNode;
        if (root == null) continue;
        final ratio = view.flutterView.devicePixelRatio;
        void walk(SemanticsNode node, Matrix4 parent) {
          if (nodes.length >= limit) {
            truncated = true;
            return;
          }
          final transform = node.transform == null ? parent : (parent.clone()..multiply(node.transform!));
          final data = node.getSemanticsData();
          final flags = data.flagsCollection;
          final text = [data.label, data.value].where((s) => s.isNotEmpty).join(' | ');
          final focused = flags.isFocused == ui.Tristate.isTrue;
          if (!node.isInvisible && !flags.isHidden && (text.isNotEmpty || focused)) {
            final rect = MatrixUtils.transformRect(transform, node.rect);
            nodes.add({
              'text': text,
              if (data.hint.isNotEmpty) 'hint': data.hint,
              'rect': _rect(
                Rect.fromLTRB(rect.left / ratio, rect.top / ratio, rect.right / ratio, rect.bottom / ratio),
              ),
              if (flags.isButton) 'button': true,
              if (flags.isLink) 'link': true,
              if (flags.isHeader) 'header': true,
              if (flags.isTextField) 'textField': true,
              if (focused) 'focused': true,
              if (flags.isSelected == ui.Tristate.isTrue) 'selected': true,
            });
          }
          node.visitChildren((child) {
            walk(child, transform);
            return nodes.length < limit;
          });
        }

        walk(root, Matrix4.identity());
      }
      return {'nodes': nodes, 'truncated': truncated};
    } finally {
      handle.dispose();
    }
  }

  static Future<Map<String, dynamic>> screenshot({double scale = 1}) async {
    final boundary = screenshotKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) throw StateError('Nothing has been drawn yet.');
    final ratio = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: ratio * scale.clamp(0.25, 2.0));
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('The picture could not be encoded.');
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs', 'screenshots'));
      await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File(p.join(dir.path, 'plezy-$stamp.png'));
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return {'path': file.path, 'width': image.width, 'height': image.height};
    } finally {
      image.dispose();
    }
  }

  static List<String> logTail({int count = 100, String? contains}) {
    final wanted = count.clamp(1, 1000);
    final lines = <String>[];
    for (final entry in MemoryLogOutput.getLogs()) {
      final line = '${entry.timestamp.toIso8601String().substring(11, 23)} ${entry.level.name} ${entry.message}';
      if (contains != null && !line.contains(contains)) continue;
      lines.add(line);
      if (lines.length >= wanted) break;
    }
    return lines.reversed.toList();
  }

  // ------------------------------------------------------------- navigate

  static const Map<String, LogicalKeyboardKey> _namedKeys = {
    'up': LogicalKeyboardKey.arrowUp,
    'down': LogicalKeyboardKey.arrowDown,
    'left': LogicalKeyboardKey.arrowLeft,
    'right': LogicalKeyboardKey.arrowRight,
    'select': LogicalKeyboardKey.select,
    'enter': LogicalKeyboardKey.enter,
    'back': LogicalKeyboardKey.goBack,
    'escape': LogicalKeyboardKey.escape,
    'menu': LogicalKeyboardKey.contextMenu,
    'space': LogicalKeyboardKey.space,
    'tab': LogicalKeyboardKey.tab,
    'pageup': LogicalKeyboardKey.pageUp,
    'pagedown': LogicalKeyboardKey.pageDown,
    'home': LogicalKeyboardKey.home,
    'end': LogicalKeyboardKey.end,
    'playpause': LogicalKeyboardKey.mediaPlayPause,
    'fastforward': LogicalKeyboardKey.mediaFastForward,
    'rewind': LogicalKeyboardKey.mediaRewind,
  };

  @visibleForTesting
  static LogicalKeyboardKey keyFor(String name) {
    final lower = name.toLowerCase().trim();
    final named = _namedKeys[lower];
    if (named != null) return named;
    if (lower.length == 1) {
      final code = lower.codeUnitAt(0);
      final isLetter = code >= 0x61 && code <= 0x7a;
      final isDigit = code >= 0x30 && code <= 0x39;
      if (isLetter || isDigit) return LogicalKeyboardKey(code);
    }
    throw ArgumentError('Unknown key "$name".');
  }

  static Future<Map<String, dynamic>> pressKey(String name, {int times = 1}) async {
    final key = keyFor(name);
    final count = times.clamp(1, 50);
    for (var i = 0; i < count; i++) {
      key_sim.simulateKeyPress(key);
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    return {'pressed': name, 'times': count, ...screenInfo()};
  }

  static Future<bool> back() async {
    final focusNavigator = FocusManager.instance.primaryFocus?.context == null
        ? null
        : Navigator.maybeOf(FocusManager.instance.primaryFocus!.context!);
    final root = _rootContext();
    final rootNavigator = root != null && root.mounted ? Navigator.maybeOf(root, rootNavigator: true) : null;
    // A dialog or the player sits on the root navigator; pages on the profile one.
    if (rootNavigator != null && rootNavigator.canPop()) return rootNavigator.maybePop();
    if (focusNavigator != null && focusNavigator.canPop()) return focusNavigator.maybePop();
    return profileNavigationRegistry.maybePopProfileRoute();
  }

  static Future<Map<String, dynamic>> home() async {
    final root = _rootContext();
    final rootNavigator = root != null && root.mounted ? Navigator.maybeOf(root, rootNavigator: true) : null;
    rootNavigator?.popUntil((route) => route.isFirst);
    profileNavigationRegistry.navigator?.popUntil((route) => route.isFirst);
    // Let the closing pages finish their exit animation before reporting.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return screenInfo();
  }

  static Future<Map<String, dynamic>> openSettings({required bool devTools}) async {
    final navigator = profileNavigationRegistry.navigator;
    if (navigator == null) throw StateError('No profile is open.');
    unawaited(
      devTools
          ? navigator.push(MaterialPageRoute<void>(builder: (_) => const DevToolsScreen()))
          : navigator.push(buildSettingsRoute()),
    );
    await WidgetsBinding.instance.endOfFrame;
    return screenInfo();
  }

  static Future<Map<String, dynamic>> openItem(String itemId, {String? serverId}) async {
    final server = await _serverId(serverId);
    final client = _rootRead<MultiServerProvider>().getClientForServer(ServerId(server));
    if (client == null) throw StateError('Server $server is not connected.');
    final item = await client.fetchItem(itemId);
    if (item == null) throw StateError('No item $itemId on that server.');
    final context = _profileContext();
    if (context == null || !context.mounted) throw StateError('No profile is open.');
    unawaited(navigateToMediaItem(context, item.copyWith(serverId: server)));
    await WidgetsBinding.instance.endOfFrame;
    return {'opened': item.title, 'kind': item.kind.name};
  }

  // --------------------------------------------------------------- player

  static Future<Map<String, dynamic>> playerStatus() async {
    Object? session;
    try {
      session = await agent('playback.status', const {});
    } catch (e) {
      session = '$e';
    }
    final player = playerLookup?.call();
    Map<String, String?>? props;
    if (player != null) {
      props = {};
      // Not media-title or path: they hold the stream address with its access key.
      for (final name in const ['time-pos', 'duration', 'pause', 'hwdec-current', 'speed']) {
        try {
          props[name] = await player.getProperty(name);
        } catch (_) {
          props[name] = null;
        }
      }
    }
    return {'session': session, 'player': ?props};
  }

  static Future<Map<String, dynamic>> seek({double? to, double? by}) async {
    if ((to == null) == (by == null)) throw ArgumentError('Give either seconds or by.');
    final player = _requirePlayer();
    var target = to;
    if (by != null) {
      final now = double.tryParse(await player.getProperty('time-pos') ?? '') ?? 0;
      target = now + by;
    }
    final seconds = target!.clamp(0, double.infinity);
    await player.seek(Duration(milliseconds: (seconds * 1000).round()));
    return {'seconds': seconds};
  }

  static Future<Object?> tracks() async {
    final player = _requirePlayer();
    final raw = await player.getProperty('track-list');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final t in list.whereType<Map>())
          {
            'type': t['type'],
            'id': t['id'],
            'title': ?t['title'],
            'lang': ?t['lang'],
            'codec': ?t['codec'],
            'selected': t['selected'] == true,
          },
      ];
    } catch (_) {
      return raw;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _rootContext = () => null;
    _announce = (_) {};
    playerLookup = null;
  }
}
