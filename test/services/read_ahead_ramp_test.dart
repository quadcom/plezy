import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/read_ahead_ramp.dart';

/// Read-ahead for network direct play: tiny while the file opens, a short
/// window after the first frame and after each seek, and back to mpv's default
/// once playback has run a while without a seek.
void main() {
  test('opens small, settles at the first frame, goes full after three quiet minutes', () {
    fakeAsync((async) {
      final player = _Player();
      final ramp = ReadAheadRamp();

      unawaited(ramp.armForOpen(player, enabled: true, userOwnsOption: false));
      async.flushMicrotasks();
      expect(player.cacheSecs, ['2']);

      player.restart();
      async.flushMicrotasks();
      expect(player.cacheSecs.last, '15');

      async.elapse(const Duration(minutes: 2, seconds: 59));
      expect(player.cacheSecs.last, '15');
      async.elapse(const Duration(seconds: 2));
      expect(player.cacheSecs.last, '3600');
      ramp.dispose();
    });
  });

  test('a seek drops back to the short window and restarts the clock', () {
    fakeAsync((async) {
      final player = _Player();
      final ramp = ReadAheadRamp();
      unawaited(ramp.armForOpen(player, enabled: true, userOwnsOption: false));
      player.restart();
      async.elapse(const Duration(minutes: 2));

      player.restart(); // a seek
      async.flushMicrotasks();
      expect(player.cacheSecs.last, '15');
      async.elapse(const Duration(minutes: 2));
      expect(player.cacheSecs.last, '15', reason: 'the clock restarted at the seek');
      async.elapse(const Duration(minutes: 1, seconds: 1));
      expect(player.cacheSecs.last, '3600');
      ramp.dispose();
    });
  });

  test('local, live and transcoded opens put mpv\'s default back', () {
    fakeAsync((async) {
      final player = _Player();
      final ramp = ReadAheadRamp();
      unawaited(ramp.armForOpen(player, enabled: false, userOwnsOption: false));
      async.flushMicrotasks();
      expect(player.cacheSecs, ['3600']);
      player.restart();
      async.elapse(const Duration(minutes: 5));
      expect(player.cacheSecs, ['3600'], reason: 'no ramp when disabled');
      ramp.dispose();
    });
  });

  test('a cache-secs line in the user\'s mpv.conf is never overwritten', () {
    fakeAsync((async) {
      final player = _Player();
      final ramp = ReadAheadRamp();
      unawaited(ramp.armForOpen(player, enabled: true, userOwnsOption: true));
      player.restart();
      async.elapse(const Duration(minutes: 5));
      expect(player.cacheSecs, isEmpty);
      ramp.dispose();
    });
  });

  test('a new open stops the previous item\'s ramp', () {
    fakeAsync((async) {
      final first = _Player();
      final ramp = ReadAheadRamp();
      unawaited(ramp.armForOpen(first, enabled: true, userOwnsOption: false));
      first.restart();
      async.flushMicrotasks();

      unawaited(ramp.armForOpen(first, enabled: false, userOwnsOption: false));
      async.elapse(const Duration(minutes: 5));
      expect(first.cacheSecs, ['2', '15', '3600']);
      ramp.dispose();
    });
  });
}

class _Player implements Player {
  final List<String> cacheSecs = [];
  final StreamController<void> _restarts = StreamController<void>.broadcast(sync: true);

  void restart() => _restarts.add(null);

  @override
  Future<void> setProperty(String name, String value) async {
    if (name == 'cache-secs') cacheSecs.add(value);
  }

  @override
  PlayerStreams get streams => PlayerStreams(
    playheadJump: const Stream<Duration?>.empty(),
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: _restarts.stream,
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
