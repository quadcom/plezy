import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_item.dart';
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

  // local/plans/credits-guess.md: Kingsman on the SHIELD, 2026-11-16.
  group('where the credits start', () {
    const film = Duration(milliseconds: 7724544); // 128.7 min
    List<MediaChapter> chapters(List<double> minutes) => [
      for (final (i, m) in minutes.indexed) MediaChapter(id: i, startTimeOffset: (m * 60000).round()),
    ];

    test('the server marker wins', () {
      expect(
        VideoMiniPlayer.creditsStart(
          duration: film,
          marker: const Duration(minutes: 121),
          chapters: chapters([0, 50, 119.6]),
        ),
        const Duration(minutes: 121),
      );
    });

    test('no marker: the last chapter when it starts in the final 12 minutes', () {
      final start = VideoMiniPlayer.creditsStart(
        duration: film,
        chapters: chapters([0, 100, 104.1, 110.5, 118.4, 119.6]),
      )!;
      expect(start.inMilliseconds, (119.6 * 60000).round());
    });

    test('a last chapter further back, or too few chapters: the last 8 minutes', () {
      expect(
        VideoMiniPlayer.creditsStart(duration: film, chapters: chapters([0, 60, 100])),
        film - const Duration(minutes: 8),
      );
      expect(
        VideoMiniPlayer.creditsStart(duration: film, chapters: chapters([0, 125])),
        film - const Duration(minutes: 8),
      );
      expect(VideoMiniPlayer.creditsStart(duration: film), film - const Duration(minutes: 8));
    });

    test('a short item: its last tenth; unknown length: none', () {
      expect(
        VideoMiniPlayer.creditsStart(duration: const Duration(minutes: 22)),
        const Duration(minutes: 22) - const Duration(seconds: 132),
      );
      expect(VideoMiniPlayer.creditsStart(duration: Duration.zero), isNull);
    });
  });

  // local/plans/trailer-back.md (Adrian, 2026-11-15).
  test('Up Next never follows a trailer, extra or Coming Soon item', () {
    const episode = JellyfinMediaItem(id: 'e', kind: MediaKind.episode);
    const movie = JellyfinMediaItem(
      id: 'm',
      kind: MediaKind.movie,
      raw: {'Path': '/knoxx/Flicks/Film (2015)/Film.mkv'},
    );
    const trailer = JellyfinMediaItem(id: 't', kind: MediaKind.clip);
    const comingSoon = JellyfinMediaItem(
      id: 'c',
      kind: MediaKind.movie,
      raw: {'Path': '/knoxx/agregarr/movies/Poltergeist/Poltergeist {tmdb-609} {edition-Trailer}.mp4'},
    );
    expect(VideoMiniPlayer.upNextFollows(episode), isTrue);
    expect(VideoMiniPlayer.upNextFollows(movie), isTrue);
    expect(VideoMiniPlayer.upNextFollows(trailer), isFalse);
    expect(VideoMiniPlayer.upNextFollows(comingSoon), isFalse);
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
