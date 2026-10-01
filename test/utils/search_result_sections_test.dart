import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/utils/search_result_sections.dart';

import '../test_helpers/media_items.dart';

void main() {
  final now = DateTime(2026, 9, 30);

  MediaLibrary library(String serverId, String id, String title) =>
      MediaLibrary(id: id, backend: MediaBackend.plex, title: title, kind: MediaKind.movie, serverId: serverId);

  MediaItem item(String id, String serverId, String libraryId, {String? date, int? year}) =>
      testMediaItem(id: id, serverId: serverId, libraryId: libraryId, originallyAvailableAt: date, year: year);

  List<SearchResultSection> sections(
    List<MediaItem> items, {
    Set<String> own = const {'ldc'},
    required List<MediaLibrary> libraries,
  }) => sectionSearchResults(
    items,
    ownServerIds: own,
    libraries: libraries,
    serverNameOf: (serverId) => serverId.toUpperCase(),
    now: now,
  );

  List<String> titles(List<SearchResultSection> sections) => [for (final s in sections) s.title];
  List<String> ids(SearchResultSection section) => [for (final i in section.items) i.id];

  final ldcLibraries = [
    library('ldc', 'movies', 'Movies'),
    library('ldc', 'tv', 'TV Shows'),
    library('ldc', 'soon', 'Coming Soon'),
    library('ldc', 'new', 'New Shows'),
  ];

  test('follows the main-screen library order, own servers first', () {
    final result = sections(
      [
        item('trailer', 'ldc', 'soon', date: '2026-11-20'),
        item('nfl-movie', 'nfl', 'films', date: '2015-11-20'),
        item('show', 'ldc', 'tv', date: '2020-01-01'),
        item('movie', 'ldc', 'movies', date: '2012-03-23'),
      ],
      // The shared server's library is listed first on the main screen, but
      // own servers still lead.
      libraries: [library('nfl', 'films', 'Films'), ...ldcLibraries],
    );

    expect(titles(result), ['Movies', 'TV Shows', 'Coming Soon', 'Films']);
    expect(result.first.subtitle, isNull);
    expect(result.last.subtitle, 'NFL');
  });

  test('sorts released media newest first and upcoming media soonest first', () {
    final result = sections([
      item('hg-1', 'ldc', 'movies', date: '2012-03-23'),
      item('hg-3', 'ldc', 'movies', date: '2014-11-21'),
      item('prequel', 'ldc', 'movies', date: '2023-11-17'),
      item('hg-2', 'ldc', 'movies', date: '2013-11-22'),
      item('later', 'ldc', 'soon', date: '2027-03-01'),
      item('next', 'ldc', 'soon', date: '2026-11-20'),
    ], libraries: ldcLibraries);

    expect(ids(result[0]), ['prequel', 'hg-3', 'hg-2', 'hg-1']);
    expect(ids(result[1]), ['next', 'later']);
  });

  test('falls back to the year, and puts undated results last in relevance order', () {
    final result = sections([
      item('undated-a', 'ldc', 'movies'),
      item('year-only', 'ldc', 'movies', year: 2015),
      item('undated-b', 'ldc', 'movies'),
      item('dated', 'ldc', 'movies', date: '2013-11-22'),
    ], libraries: ldcLibraries);

    expect(ids(result.single), ['year-only', 'dated', 'undated-a', 'undated-b']);
  });

  test('keeps each shared server together, and unlisted libraries after listed ones', () {
    final result = sections(
      [
        item('b-unlisted', 'b', 'x'),
        item('a-movie', 'a', 'films'),
        item('b-movie', 'b', 'films'),
        item('a-tv', 'a', 'tv'),
      ],
      own: const {},
      libraries: [library('b', 'films', 'B Films'), library('a', 'films', 'A Films'), library('a', 'tv', 'A TV')],
    );

    expect([for (final s in result) s.key], ['b:films', 'b:x', 'a:films', 'a:tv']);
  });

  test('returns nothing for no results', () {
    expect(sections(const [], libraries: ldcLibraries), isEmpty);
  });
}
