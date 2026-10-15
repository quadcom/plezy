import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Test builds only (`--dart-define=PLEZY_DEV_LOG=true`): every log line also
/// goes to `logs/plezy-dev.log` in the app's support folder, written as it
/// happens, so a developer can read what a running test copy is doing. The
/// last run's file is kept as `plezy-dev.prev.log`. Uncaught errors, including
/// a widget that fails to build, are logged too. Release builds leave this off
/// and never touch the file.
class DevLogFile {
  DevLogFile._();

  static const enabled = bool.fromEnvironment('PLEZY_DEV_LOG');

  static RandomAccessFile? _file;
  static final List<String> _pending = [];

  /// Where the file is, once open.
  static String? path;

  /// Switches read once at start from `logs/dev-flags.txt` (words separated
  /// by spaces, commas or lines), for trying a test build with parts turned
  /// off without rebuilding it. Empty in release builds.
  static Set<String> _flags = const {};
  static bool flag(String name) => _flags.contains(name);

  /// Opens the file and hooks uncaught errors into the log. Call once at
  /// start-up; does nothing unless [enabled].
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
      _file = await File(file.path).open(mode: FileMode.writeOnlyAppend);
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
    } catch (_) {}
  }

  /// Every 5 s while frames are being made: how many the framework built and
  /// how many the engine finished drawing. Built but not drawn means the
  /// picture on screen has stopped updating.
  static void _watchFrames() {
    var built = 0;
    var drawn = 0;
    SchedulerBinding.instance.addPersistentFrameCallback((_) => built++);
    SchedulerBinding.instance.addTimingsCallback((timings) => drawn += timings.length);
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (built == 0 && drawn == 0) return;
      appLogger.d('Frames (5 s): built $built, drawn $drawn');
      built = 0;
      drawn = 0;
    });
  }

  static void _hookErrors() {
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
