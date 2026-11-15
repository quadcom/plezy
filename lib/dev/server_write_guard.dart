import 'dart:collection';

import '../utils/app_logger.dart';
import '../utils/dev_log_file.dart';

/// What happens to one request while developer mode is on.
enum ServerWriteVerdict {
  /// Sent as normal: a read, or something playback needs.
  allow,

  /// Not sent; the caller is told it worked. Used for the reports a player
  /// sends on its own (progress, start, stop), so nothing queues them to be
  /// sent again later.
  pretend,

  /// Not sent; the caller gets an error, as a server refusal would give.
  refuse,
}

/// Thrown instead of sending a server write while developer mode is on.
class ServerWriteBlockedException implements Exception {
  ServerWriteBlockedException(this.method, this.path);

  final String method;
  final String path;

  @override
  String toString() => 'Developer mode is on: $method $path was not sent to the server.';
}

/// The developer switch file stops every change to the media server (Adrian,
/// 2026-11-15: "while in debug mode, nothing actually gets pushed to the
/// server. So no watches, no change to a profile setting."; then, the same day,
/// only the switch file `plezy-debug-on` does it, not "Save Log to File";
/// local/plans/dev-tools.md). Reads and playback still work.
///
/// Checked by the media server HTTP clients (Jellyfin and Plex), the offline
/// watch sync, the trackers and the plex.tv account writes.
class ServerWriteGuard {
  ServerWriteGuard._();

  static bool? _debugActive;

  static bool get active => _debugActive ?? DevLogFile.switchFileOn;

  /// Told about each blocked write (the dev channel shows a note).
  static void Function(String method, String path)? onBlocked;

  static int _blockedCount = 0;
  static int get blockedCount => _blockedCount;
  static final ListQueue<String> _recent = ListQueue();

  static List<String> recentBlocked() => _recent.toList();

  /// Non-GET requests that are reads, or that playback needs.
  static const _allowedWrites = [
    '/playbackinfo', // Jellyfin: picks the stream (POST, a read)
    '/livestreams/', // Jellyfin: opens and closes a live stream (tuner)
    '/videos/activeencodings', // Jellyfin: stops a server transcode
    '/sessions/capabilities', // Emby: needed for library change events; no user data
    '/sessions/playing/ping', // Jellyfin: keeps a transcode alive; saves nothing
    '/users/authenticatebyname',
    '/users/authenticatewithquickconnect',
    '/quickconnect/',
    '/playqueues', // Plex: a play queue is needed to start playback
    '/tune', // Plex live TV: tunes a channel
    '/library/parts/', // Plex: stream pick for subtitle burn-in (track memory is off in developer mode)
    '/transcode/', // Plex transcoder session calls
  ];

  /// Plex sends these writes as GET.
  static final _plexGetWrites = RegExp(
    r'(/:/scrobble|/:/unscrobble|/:/rate|/library/sections/[^/]+/(refresh|analyze))$',
    caseSensitive: false,
  );

  /// Reports a player sends by itself; pretending they worked keeps every
  /// retry queue empty.
  static final _reports = RegExp(r'(/sessions/playing(/progress|/stopped)?$|/:/timeline$)', caseSensitive: false);

  static ServerWriteVerdict verdict(String method, Uri uri) {
    final m = method.toUpperCase();
    final path = uri.path.toLowerCase();
    if (m == 'GET' || m == 'HEAD' || m == 'OPTIONS') {
      return _plexGetWrites.hasMatch(path) ? ServerWriteVerdict.refuse : ServerWriteVerdict.allow;
    }
    if (_reports.hasMatch(path)) return ServerWriteVerdict.pretend;
    for (final allowed in _allowedWrites) {
      if (path.contains(allowed)) return ServerWriteVerdict.allow;
    }
    return ServerWriteVerdict.refuse;
  }

  /// What to do with [method] [uri] now: always [ServerWriteVerdict.allow]
  /// while developer mode is off. Records and logs anything held back.
  static ServerWriteVerdict check(String method, Uri uri) {
    if (!active) return ServerWriteVerdict.allow;
    final result = verdict(method, uri);
    if (result != ServerWriteVerdict.allow) {
      record(method.toUpperCase(), uri.path, pretended: result == ServerWriteVerdict.pretend);
    }
    return result;
  }

  /// Records a write held back somewhere other than the HTTP clients.
  static void record(String method, String path, {bool pretended = false}) {
    _blockedCount++;
    final line =
        '${DateTime.now().toIso8601String().substring(11, 19)} $method $path${pretended ? ' (report, skipped quietly)' : ''}';
    _recent.addLast(line);
    while (_recent.length > 100) {
      _recent.removeFirst();
    }
    appLogger.i('[DEV] Server write not sent (developer mode): $method $path');
    if (!pretended) onBlocked?.call(method, path);
  }

  static void debugSetActive(bool? value) => _debugActive = value;

  static void debugReset() {
    _debugActive = null;
    _blockedCount = 0;
    _recent.clear();
    onBlocked = null;
  }
}
