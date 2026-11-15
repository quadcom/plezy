import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';

/// Coming Soon stand-ins: Media Bridge files an unreleased film as its trailer
/// (local/plans/detail-left-edge.md). Paths and ids as PlezyFin returned them, 2026-11-15.
void main() {
  const standIn = JellyfinMediaItem(
    id: 'ae00ec75b5194d441b128f7075fe6916',
    kind: MediaKind.movie,
    title: 'Poltergeist',
    raw: {
      'Path': '/knoxx/agregarr/movies/Poltergeist/Poltergeist {tmdb-609} {edition-Trailer}.mp4',
      'ProviderIds': {'Tmdb': '609'},
    },
  );

  test('a Media Bridge trailer file is a Coming Soon stand-in', () {
    expect(standIn.isComingSoonStandIn, isTrue);
    expect(standIn.tmdbIdFromProviderIds, 609);
  });

  test('the real film is not', () {
    const film = JellyfinMediaItem(
      id: 'real',
      kind: MediaKind.movie,
      title: 'Poltergeist',
      raw: {
        'Path':
            '/knoxx/Flicks/Poltergeist (2015) 243688-tt1029360/Poltergeist (2015) tt1029360 WEBDL-720p 10bit h265 AC35.1 [EN].mkv',
        'ProviderIds': {'Imdb': 'tt1029360', 'Tmdb': '243688'},
      },
    );
    expect(film.isComingSoonStandIn, isFalse);
    expect(film.tmdbIdFromProviderIds, 243688);
  });

  test('only films count, and an item without a path is not a stand-in', () {
    const show = JellyfinMediaItem(
      id: 'show',
      kind: MediaKind.show,
      raw: {'Path': '/knoxx/agregarr/tv/Show {edition-Trailer}'},
    );
    const row = JellyfinMediaItem(id: 'row', kind: MediaKind.movie, raw: {'ProviderIds': <String, Object?>{}});
    expect(show.isComingSoonStandIn, isFalse);
    expect(row.isComingSoonStandIn, isFalse);
    expect(row.tmdbIdFromProviderIds, isNull);
  });
}
