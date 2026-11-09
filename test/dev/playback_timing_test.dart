import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/dev/playback_timing.dart';

void main() {
  final t0 = DateTime(2026, 11, 9, 16, 0);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  PlaybackSample sample(
    int ms, {
    double? pos,
    int drop = 0,
    int late = 0,
    double avsync = 0,
    double fix = 0,
    double cache = 30,
    bool paused = false,
    bool buffering = false,
    double speed = 1,
  }) => PlaybackSample(
    wall: at(ms),
    position: pos ?? ms / 1000,
    paused: paused,
    droppedFrames: drop,
    decoderDroppedFrames: 0,
    delayedFrames: late,
    mistimedFrames: 0,
    avsync: avsync,
    totalAvsyncChange: fix,
    cacheSeconds: cache,
    pausedForCache: buffering,
    speed: speed,
    displayFps: 60,
  );

  late PlaybackTimingAnalyzer analyzer;
  setUp(() => analyzer = PlaybackTimingAnalyzer(expectedInterval: const Duration(milliseconds: 200)));

  test('smooth playback reports nothing', () {
    expect(analyzer.feed(sample(0)), isEmpty);
    expect(analyzer.feed(sample(200)), isEmpty);
    expect(analyzer.feed(sample(400)), isEmpty);
  });

  test('counts dropped and late frames', () {
    analyzer.feed(sample(0));
    final events = analyzer.feed(sample(200, drop: 2, late: 1));
    expect(events, contains('dropped frame +2 (total 2)'));
    expect(events, contains('late frame +1 (total 1)'));
  });

  test('a counter that resets for a new file is not an event', () {
    analyzer.feed(sample(0, drop: 5));
    expect(analyzer.feed(sample(200, drop: 0)).where((e) => e.startsWith('dropped')), isEmpty);
  });

  test('a picture that stops moving is reported', () {
    analyzer.feed(sample(0, pos: 10));
    final events = analyzer.feed(sample(200, pos: 10.02));
    expect(events.single, startsWith('position slow'));
  });

  test('a late sampler is reported as the app being busy', () {
    analyzer.feed(sample(0));
    expect(analyzer.feed(sample(600)), contains(startsWith('sampler late by 400 ms')));
  });

  test('sync drift is reported once when it starts and once when it ends', () {
    analyzer.feed(sample(0));
    expect(analyzer.feed(sample(200, avsync: 0.06)), ['picture and sound apart by 60 ms']);
    expect(analyzer.feed(sample(400, avsync: 0.07)), isEmpty);
    expect(analyzer.feed(sample(600, avsync: 0.01)), ['picture and sound back together']);
  });

  test('sync corrections and buffer dips are reported', () {
    analyzer.feed(sample(0));
    expect(analyzer.feed(sample(200, fix: 0.05)), ['sync correction 50 ms']);
    expect(analyzer.feed(sample(400, fix: 0.05, cache: 1)), ['buffer low: 1.0 s ahead']);
    expect(analyzer.feed(sample(600, fix: 0.05, cache: 1, buffering: true)), ['buffering started']);
  });

  test('a seek is a jump, not a stall', () {
    analyzer.feed(sample(0, pos: 10));
    expect(analyzer.feed(sample(200, pos: 70)).single, startsWith('position jumped'));
  });

  test('slower speed is accounted for', () {
    analyzer.feed(sample(0, pos: 10, speed: 0.5));
    expect(analyzer.feed(sample(200, pos: 10.1, speed: 0.5)), isEmpty);
  });

  test('pausing is not a stall', () {
    analyzer.feed(sample(0, pos: 10));
    expect(analyzer.feed(sample(200, pos: 10, paused: true)), ['paused']);
    expect(analyzer.feed(sample(400, pos: 10, paused: true)), isEmpty);
  });
}
