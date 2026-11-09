/// Turns a stream of player samples into short, human-readable timing events:
/// dropped or late frames, a picture that stopped moving, a sync jump, the
/// buffer running low. Pure logic, so it can be tested without a player.
/// Used by the dev channel (local/plans/player-inspector.md).
library;

class PlaybackSample {
  const PlaybackSample({
    required this.wall,
    this.position,
    this.paused = false,
    this.droppedFrames,
    this.decoderDroppedFrames,
    this.delayedFrames,
    this.mistimedFrames,
    this.avsync,
    this.totalAvsyncChange,
    this.cacheSeconds,
    this.pausedForCache = false,
    this.speed,
    this.displayFps,
  });

  final DateTime wall;
  final double? position;
  final bool paused;
  final int? droppedFrames;
  final int? decoderDroppedFrames;
  final int? delayedFrames;
  final int? mistimedFrames;
  final double? avsync;
  final double? totalAvsyncChange;
  final double? cacheSeconds;
  final bool pausedForCache;
  final double? speed;
  final double? displayFps;

  /// One compact line, for the log and the last-seconds buffer.
  String describe() {
    String f(double? v, [int digits = 3]) => v == null ? '-' : v.toStringAsFixed(digits);
    return 'pos ${f(position)} drop ${droppedFrames ?? '-'} dec ${decoderDroppedFrames ?? '-'} '
        'late ${delayedFrames ?? '-'} mistimed ${mistimedFrames ?? '-'} avsync ${f(avsync)} '
        'syncfix ${f(totalAvsyncChange)} cache ${f(cacheSeconds, 1)} speed ${f(speed, 5)} '
        'disp ${f(displayFps, 3)}${paused ? ' PAUSED' : ''}${pausedForCache ? ' BUFFERING' : ''}';
  }
}

class PlaybackTimingAnalyzer {
  PlaybackTimingAnalyzer({required this.expectedInterval});

  /// How often samples are meant to arrive.
  final Duration expectedInterval;

  PlaybackSample? _last;
  bool _avsyncOff = false;
  bool _cacheLow = false;

  /// Sync error, in seconds, past which the picture and sound count as apart.
  static const avsyncLimit = 0.040;

  /// Buffer, in seconds, below which it counts as running low.
  static const cacheLowLimit = 2.0;

  void reset() {
    _last = null;
    _avsyncOff = false;
    _cacheLow = false;
  }

  /// Events since the previous sample. Empty when nothing worth noting moved.
  List<String> feed(PlaybackSample s) {
    final prev = _last;
    _last = s;
    if (prev == null) return const [];
    final events = <String>[];

    void counter(String name, int? before, int? now) {
      if (before == null || now == null || now <= before) return;
      events.add('$name +${now - before} (total $now)');
    }

    counter('dropped frame', prev.droppedFrames, s.droppedFrames);
    counter('decoder dropped frame', prev.decoderDroppedFrames, s.decoderDroppedFrames);
    counter('late frame', prev.delayedFrames, s.delayedFrames);
    counter('mistimed frame', prev.mistimedFrames, s.mistimedFrames);

    final wallGap = s.wall.difference(prev.wall);
    final lateBy = wallGap - expectedInterval;
    if (lateBy > const Duration(milliseconds: 150)) {
      events.add('sampler late by ${lateBy.inMilliseconds} ms (app busy)');
    }

    if (!s.paused && !prev.paused && !s.pausedForCache && s.position != null && prev.position != null) {
      final speed = s.speed ?? 1.0;
      final expected = wallGap.inMicroseconds / 1e6 * speed;
      final actual = s.position! - prev.position!;
      if (expected >= 0.05 && actual < expected * 0.5 && actual > -0.5) {
        events.add('position slow: +${(actual * 1000).round()} ms in ${(expected * 1000).round()} ms');
      } else if (actual > expected * 1.5 + 0.1 || actual < -0.5) {
        events.add('position jumped ${(actual * 1000).round()} ms (seek or skip)');
      }
    }

    final avsync = s.avsync;
    if (avsync != null) {
      final off = avsync.abs() > avsyncLimit;
      if (off && !_avsyncOff) events.add('picture and sound apart by ${(avsync * 1000).round()} ms');
      if (!off && _avsyncOff) events.add('picture and sound back together');
      _avsyncOff = off;
    }

    final fixBefore = prev.totalAvsyncChange;
    final fixNow = s.totalAvsyncChange;
    if (fixBefore != null && fixNow != null && (fixNow - fixBefore).abs() > 0.020) {
      events.add('sync correction ${((fixNow - fixBefore) * 1000).round()} ms');
    }

    if (s.pausedForCache && !prev.pausedForCache) events.add('buffering started');
    if (!s.pausedForCache && prev.pausedForCache) events.add('buffering ended');
    final cache = s.cacheSeconds;
    if (cache != null && !s.paused) {
      final low = cache < cacheLowLimit;
      if (low && !_cacheLow) events.add('buffer low: ${cache.toStringAsFixed(1)} s ahead');
      if (!low && _cacheLow) events.add('buffer recovered: ${cache.toStringAsFixed(1)} s ahead');
      _cacheLow = low;
    }

    if (prev.speed != null && s.speed != null && (s.speed! - prev.speed!).abs() > 1e-6) {
      events.add('speed ${prev.speed!.toStringAsFixed(5)} -> ${s.speed!.toStringAsFixed(5)}');
    }
    if (prev.displayFps != null && s.displayFps != null && (s.displayFps! - prev.displayFps!).abs() > 0.5) {
      events.add('display rate ${prev.displayFps!.toStringAsFixed(3)} -> ${s.displayFps!.toStringAsFixed(3)}');
    }
    if (s.paused && !prev.paused) events.add('paused');
    if (!s.paused && prev.paused) events.add('resumed');
    return events;
  }
}
