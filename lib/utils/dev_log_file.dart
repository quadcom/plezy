import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Every log line also goes to `logs/plezy-dev.log` in the app's support
/// folder, written as it happens, so a developer can read what a running copy
/// is doing. On in test builds (`--dart-define=PLEZY_DEV_LOG=true`) and, in any
/// build, while the "Save Log to File" setting is on
/// (local/plans/dev-mode-toggle.md). The last run's file is kept as
/// `plezy-dev.prev.log`. Uncaught errors, including a widget that fails to
/// build, are logged too. Off, the file is never touched.
class DevLogFile {
  DevLogFile._();

  static const _buildFlag = bool.fromEnvironment('PLEZY_DEV_LOG');
  static bool _switchedOn = false;

  static bool get enabled => _buildFlag || _switchedOn;

  /// A file past this starts over, the old one kept as the `.prev` file.
  static const _maxBytes = 50 * 1024 * 1024;

  static RandomAccessFile? _file;
  static int _bytes = 0;
  static bool _hooked = false;
  static bool _watching = false;
  static final List<String> _pending = [];

  /// Where the file is, once open.
  static String? path;

  /// Switches read once at start from `logs/dev-flags.txt` (words separated
  /// by spaces, commas or lines), for trying a test build with parts turned
  /// off without rebuilding it. Empty in release builds.
  static Set<String> _flags = const {};
  static bool flag(String name) => _flags.contains(name);

  /// The "Save Log to File" setting: on opens the file at once, off closes
  /// it. A test build's flag keeps it on regardless.
  static Future<void> setSwitch(bool on) async {
    _switchedOn = on;
    refreshLoggerLevel();
    if (enabled) {
      await start();
    } else {
      await _close();
    }
  }

  static Future<void> _close() async {
    final file = _file;
    _file = null;
    path = null;
    _pending.clear();
    try {
      await file?.close();
    } catch (_) {}
  }

  /// Opens the file and hooks uncaught errors into the log. Does nothing
  /// unless [enabled]; safe to call again.
  static Future<void> start() async {
    if (!enabled || _file != null) return;
    _hookErrors();
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));
      await dir.create(recursive: true);
      final flagsFile = File(p.join(dir.path, 'dev-flags.txt'));
      if (await flagsFile.exists()) {
        _flags = (await flagsFile.readAsString())
            .split(RegExp(r'[\s,]+'))
            .where((w) => w.isNotEmpty)
            .map((w) => w.toLowerCase())
            .toSet();
      }
      final file = File(p.join(dir.path, 'plezy-dev.log'));
      if (await file.exists()) await file.rename(p.join(dir.path, 'plezy-dev.prev.log'));
      // Switched off, or opened by another call, while the folder was prepared.
      if (!enabled || _file != null) return;
      _file = await File(file.path).open(mode: FileMode.writeOnlyAppend);
      _bytes = 0;
      path = file.path;
      final waiting = List.of(_pending);
      _pending.clear();
      for (final line in waiting) {
        _write(line);
      }
      appLogger.i('Dev log: writing to ${file.path}; flags: ${_flags.isEmpty ? 'none' : _flags.join(', ')}');
      _watchFrames();
    } catch (e) {
      debugPrint('Dev log: could not open the file: $e');
    }
  }

  /// One log entry as a line (and its error and stack under it).
  static void add(LogEntry entry) {
    if (!enabled) return;
    final b = StringBuffer()
      ..write(entry.timestamp.toIso8601String())
      ..write(' ')
      ..write(entry.level.name.toUpperCase().padRight(7))
      ..write(entry.message);
    if (entry.error != null) b.write('\n  error: ${entry.error}');
    if (entry.stackTrace != null) b.write('\n  ${entry.stackTrace.toString().trim().replaceAll('\n', '\n  ')}');
    b.write('\n');
    final file = _file;
    if (file == null) {
      if (_pending.length < 2000) _pending.add(b.toString());
      return;
    }
    _write(b.toString());
  }

  static void _write(String line) {
    try {
      // Flushed per line, so the file is current while the app runs.
      _file!
        ..writeStringSync(line)
        ..flushSync();
      _bytes += line.length;
      if (_bytes > _maxBytes) _rollOver();
    } catch (_) {}
  }

  /// Keeps one full file as `.prev` and starts a fresh one.
  static void _rollOver() {
    final current = path;
    if (current == null) return;
    _file!.closeSync();
    final file = File(current);
    file.renameSync(p.join(file.parent.path, 'plezy-dev.prev.log'));
    _file = File(current).openSync(mode: FileMode.writeOnlyAppend);
    _bytes = 0;
  }

  /// Every 5 s while frames are being made: how many the framework built and
  /// how many the engine finished drawing. Built but not drawn means the
  /// picture on screen has stopped updating.
  static void _watchFrames() {
    if (_watching) return;
    _watching = true;
    var built = 0;
    var drawn = 0;
    SchedulerBinding.instance.addPersistentFrameCallback((_) => built++);
    SchedulerBinding.instance.addTimingsCallback((timings) => drawn += timings.length);
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (!enabled || (built == 0 && drawn == 0)) {
        built = 0;
        drawn = 0;
        return;
      }
      appLogger.d('Frames (5 s): built $built, drawn $drawn');
      built = 0;
      drawn = 0;
    });
  }

  static void _hookErrors() {
    if (_hooked) return;
    _hooked = true;
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      appLogger.e(
        'Flutter error: ${details.exceptionAsString()}${details.context == null ? '' : ' (${details.context})'}',
        error: details.exception,
        stackTrace: details.stack,
      );
      previousFlutter?.call(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      appLogger.e('Uncaught error', error: error, stackTrace: stack);
      return previousPlatform?.call(error, stack) ?? false;
    };
  }
}
