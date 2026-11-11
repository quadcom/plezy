import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/video_mini_player.dart';

/// The corner box's bookkeeping (local/plans/video-mini-player.md).
void main() {
  final mini = VideoMiniPlayer.instance;
  const screenA = SizedBox(key: ValueKey('a'));
  const screenB = SizedBox(key: ValueKey('b'));

  tearDown(() {
    mini.release(screenA);
    mini.release(screenB);
  });

  test('show puts the screen in the box; release takes it out', () {
    expect(mini.isShowing, isFalse);
    mini.show(screenA, stop: () async {}, onExpanded: () {});
    expect(mini.screen, same(screenA));
    mini.release(screenA);
    expect(mini.isShowing, isFalse);
  });

  test('a release for a screen no longer in the box changes nothing', () {
    mini.show(screenB, stop: () async {}, onExpanded: () {});
    mini.release(screenA);
    expect(mini.screen, same(screenB));
  });

  test('stop runs the screen\'s own stop', () async {
    var stopped = 0;
    mini.show(screenA, stop: () async => stopped++, onExpanded: () {});
    await mini.stop();
    expect(stopped, 1);
  });

  test('stop with nothing in the box does nothing', () async {
    await mini.stop();
    expect(mini.isShowing, isFalse);
  });

  test('release clears the time left, so the Up Next page sees the box gone', () {
    mini.show(screenA, stop: () async {}, onExpanded: () {});
    mini.timeLeft.value = const Duration(seconds: 3);
    mini.release(screenA);
    expect(mini.timeLeft.value, isNull);
  });

  test('the art grows before the box fades: grow at 4 s left, fade over the last 1.5 s', () {
    expect(VideoMiniPlayer.growAt, greaterThan(VideoMiniPlayer.fadeOut));
    expect(VideoMiniPlayer.growAt - VideoMiniPlayer.fadeOut, const Duration(milliseconds: 2500));
  });

  test('the box is a third of the window wide (flush in the corner)', () {
    expect(VideoMiniPlayer.widthShare, closeTo(1 / 3, 1e-9));
  });

  test('expand marks the box as gliding back, once', () {
    var notified = 0;
    void listener() => notified++;
    mini.addListener(listener);
    mini.show(screenA, stop: () async {}, onExpanded: () {});
    mini.expand();
    mini.expand();
    expect(mini.isExpanding, isTrue);
    expect(notified, 2, reason: 'show + the first expand');
    mini.removeListener(listener);
  });
}
