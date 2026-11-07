import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';

// local/plans/old-school-preroll-mouse.md: an Old School film and its own
// trailer share one guide block, so the bar runs over both.
void main() {
  const trailer = Duration(minutes: 2, seconds: 30);
  const film = Duration(hours: 1, minutes: 32);
  const total = Duration(hours: 1, minutes: 34, seconds: 30);

  test('while the trailer plays the bar starts at the block start', () {
    const block = TimelineBlock(offset: Duration.zero, total: total, split: trailer);
    expect(block.position(const Duration(seconds: 40)), const Duration(seconds: 40));
    expect(total, trailer + film);
  });

  test('the film carries on from the end of its trailer', () {
    const block = TimelineBlock(offset: trailer, total: total, split: trailer);
    expect(block.position(Duration.zero), trailer);
    expect(block.position(const Duration(minutes: 10)), const Duration(minutes: 12, seconds: 30));
  });

  test('positions stay on the bar', () {
    const block = TimelineBlock(offset: trailer, total: total, split: trailer);
    expect(block.position(const Duration(hours: 3)), total);
    expect(block.position(-const Duration(minutes: 5)), Duration.zero);
  });

  test('one gap where the trailer ends', () {
    const block = TimelineBlock(offset: Duration.zero, total: total, split: trailer);
    final chapters = block.chapters;
    expect(chapters, hasLength(2));
    expect(chapters[0].startTimeOffset, 0);
    expect(chapters[1].startTimeOffset, trailer.inMilliseconds);
    expect(chapters[1].endTimeOffset, total.inMilliseconds);
  });

  test('no gap without a split inside the bar', () {
    expect(const TimelineBlock(offset: Duration.zero, total: total).chapters, isEmpty);
    expect(const TimelineBlock(offset: Duration.zero, total: total, split: total).chapters, isEmpty);
  });
}
