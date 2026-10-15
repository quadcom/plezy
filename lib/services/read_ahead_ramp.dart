import 'dart:async';

import '../mpv/mpv.dart';
import '../utils/app_logger.dart';

/// Ramps mpv's read-ahead for network direct play, so a start or a seek does
/// not pull a whole read-ahead budget from the server before anyone has
/// watched it.
///
/// mpv reads ahead as far as `demuxer-max-bytes` allows (up to 100 MiB on a
/// big phone, see `DemuxerBudget.kt`), as fast as the link goes. Measured
/// 2026-10-14: every start read 94-240 MB even when only seconds were watched,
/// and before the resume seek mpv was already reading from the top of the file
/// while its decoders initialised (15-20 MB per start thrown away). For an
/// outside viewer every byte comes out of the home upload through Cloudflare.
///
/// `cache-secs` bounds read-ahead in seconds of the stream, on top of the byte
/// budget, and mpv re-reads it live:
/// - [startSeconds] while the file opens and seeks to its start position;
/// - [settledSeconds] from the first `playback-restart` (the first frame at the
///   start position) and again after every seek;
/// - mpv's default ([mpvDefaultSeconds], one hour, so the byte budget rules)
///   once playback has run [fullAfter] without a seek.
/// Long viewing ends up exactly where it was; sampling, stopping early and
/// seeking waste little.
class ReadAheadRamp {
  ReadAheadRamp({this.startSeconds = 2, this.settledSeconds = 15, this.fullAfter = const Duration(minutes: 3)});

  /// mpv's own `cache-secs` default.
  static const mpvDefaultSeconds = 3600;

  final int startSeconds;
  final int settledSeconds;
  final Duration fullAfter;

  Player? _player;
  StreamSubscription<void>? _restarts;
  Timer? _fullTimer;

  /// Call before each open. [enabled] is network direct play with no
  /// `cache-secs` line in the user's mpv.conf; otherwise mpv's default is put
  /// back (unless the user owns the option) so a reused player never carries
  /// one item's ramp into the next.
  Future<void> armForOpen(Player player, {required bool enabled, required bool userOwnsOption}) async {
    _cancel();
    if (userOwnsOption) return;
    if (!enabled) {
      await _write(player, mpvDefaultSeconds);
      return;
    }
    _player = player;
    // Listen before the first write: the first frame must not slip past
    // while that write is in flight.
    _restarts = player.streams.playbackRestart.listen((_) => _onRestart());
    await _write(player, startSeconds);
  }

  void _onRestart() {
    final player = _player;
    if (player == null) return;
    unawaited(_write(player, settledSeconds));
    _fullTimer?.cancel();
    _fullTimer = Timer(fullAfter, () {
      if (identical(_player, player)) unawaited(_write(player, mpvDefaultSeconds));
    });
  }

  Future<void> _write(Player player, int seconds) async {
    try {
      await player.setProperty('cache-secs', '$seconds');
    } catch (e) {
      // A refused write leaves mpv's previous bound in place; playback goes on.
      appLogger.w('ReadAheadRamp: cache-secs=$seconds not applied', error: e);
    }
  }

  void _cancel() {
    unawaited(_restarts?.cancel());
    _restarts = null;
    _fullTimer?.cancel();
    _fullTimer = null;
    _player = null;
  }

  void dispose() => _cancel();
}
