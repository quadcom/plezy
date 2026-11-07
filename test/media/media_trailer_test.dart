import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_trailer.dart';

PlexMediaItem _trailer(String id, String title) =>
    PlexMediaItem(id: id, kind: MediaKind.clip, subtype: 'trailer', title: title);

/// A Jellyfin trailer whose title and file name can differ.
JellyfinMediaItem _jfTrailer(String id, String title, {String? path}) =>
    JellyfinMediaItem(id: id, kind: MediaKind.clip, title: title, raw: {'ExtraType': 'Trailer', 'Path': ?path});

void main() {
  const show = PlexMediaItem(id: 'show', kind: MediaKind.show, title: 'Monster');

  group('trailerSeasonNumber', () {
    test('reads the season from PMB names', () {
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02-trailer')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'monster s4')), 4);
      expect(trailerSeasonNumber(_trailer('a', 'Show S123')), 123);
    });

    test('reads "Season N" and a season anywhere in the name (PMB season_of)', () {
      expect(trailerSeasonNumber(_trailer('a', 'Black Doves - Season 2')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'Black Doves - Season 2 Trailer')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'Show Season02')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02 Behind the scenes')), 2);
    });

    test('reads the file name before the title', () {
      // Both of WAR's trailers are titled "WAR" (MediaBridge, 2026-11-07).
      final war = _jfTrailer('w', 'WAR', path: '/knoxx/TV/WAR (2026)/trailers/WAR S01-trailer.mkv');
      expect(trailerSeasonNumber(war), 1);
      final titled = _jfTrailer('t', 'Show S03', path: '/knoxx/TV/Show/trailers/Show - Trailer.mkv');
      expect(trailerSeasonNumber(titled), 3);
    });

    test('a YouTube id on the end never reads as a season', () {
      final tagged = _jfTrailer(
        'a',
        'Monster',
        path: '/tv/Monster/trailers/Monster (2022) S01-trailer [1PgKjIosF50].mkv',
      );
      expect(trailerSeasonNumber(tagged), 1);
      final untagged = _jfTrailer('b', 'Monster -', path: '/tv/Monster/trailers/Monster - Trailer [ab_s12cdefg].mkv');
      expect(trailerSeasonNumber(untagged), isNull);
    });

    test('ignores names without a season', () {
      expect(trailerSeasonNumber(_trailer('a', 'Monster')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'Monster -')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'Monsters')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'Mrs Davis 2')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'S.W.A.T.')), isNull);
      expect(trailerSeasonNumber(const PlexMediaItem(id: 'a', kind: MediaKind.clip)), isNull);
    });
  });

  group('pickSeasonTrailer', () {
    final showExtras = [_trailer('s1', 'Monster S01'), _trailer('s2', 'Monster S02')];

    test("the season's own trailer comes first", () {
      final own = _trailer('own', 'Monster S02');
      expect(pickSeasonTrailer(seasonNumber: 2, seasonExtras: [own], showExtras: showExtras)?.id, 'own');
    });

    test("else the show's trailer named for the season", () {
      expect(pickSeasonTrailer(seasonNumber: 1, seasonExtras: const [], showExtras: showExtras)?.id, 's1');
    });

    test("never another season's trailer", () {
      expect(pickSeasonTrailer(seasonNumber: 3, seasonExtras: const [], showExtras: showExtras), isNull);
      expect(pickSeasonTrailer(seasonNumber: 0, seasonExtras: const [], showExtras: showExtras), isNull);
      expect(
        pickSeasonTrailer(seasonNumber: 1, seasonExtras: const [], showExtras: [_trailer('plain', 'Monster')]),
        isNull,
      );
    });

    test('non-trailer extras are not trailers', () {
      const featurette = PlexMediaItem(id: 'f', kind: MediaKind.clip, subtype: 'featurette', title: 'Monster S01');
      expect(
        pickSeasonTrailer(seasonNumber: 1, seasonExtras: const [featurette], showExtras: const [featurette]),
        isNull,
      );
    });
  });

  group('pickSeasonPageTrailer', () {
    test("the season's own, then the show's named for it", () {
      final own = _trailer('own', 'Monster S02');
      final named = [_trailer('s2', 'Monster S02'), _trailer('plain', 'Monster -')];
      final a = pickSeasonPageTrailer(seasonNumber: 2, seasonExtras: [own], showExtras: named);
      expect((a?.trailer.id, a?.isShowTrailer), ('own', false));
      final b = pickSeasonPageTrailer(seasonNumber: 2, seasonExtras: const [], showExtras: named);
      expect((b?.trailer.id, b?.isShowTrailer), ('s2', false));
    });

    test("else the show's trailer that names no season (Adrian, 2026-11-07)", () {
      final showExtras = [_trailer('s5', 'Show S05'), _trailer('plain', 'Show -')];
      final picked = pickSeasonPageTrailer(seasonNumber: 1, seasonExtras: const [], showExtras: showExtras);
      expect((picked?.trailer.id, picked?.isShowTrailer), ('plain', true));
    });

    test("last, the show trailer named for the highest season (the show copy)", () {
      final showExtras = [_trailer('s2', 'Scrubs S02'), _trailer('s1', 'Scrubs S01-x')];
      final picked = pickSeasonPageTrailer(seasonNumber: 3, seasonExtras: const [], showExtras: showExtras);
      expect((picked?.trailer.id, picked?.isShowTrailer), ('s2', true));
      expect(pickSeasonPageTrailer(seasonNumber: 1, seasonExtras: const [], showExtras: const []), isNull);
    });
  });

  group('seasonPageExtras', () {
    test("season trailers, season extras, then the show's, each once", () {
      const featurette = PlexMediaItem(id: 'f', kind: MediaKind.clip, subtype: 'featurette', title: 'Making of');
      final seasonTrailer = _trailer('st', 'Show S01');
      final showTrailer = _trailer('sh', 'Show -');
      final ids = seasonPageExtras(
        seasonNumber: 1,
        seasonExtras: [featurette, seasonTrailer],
        showExtras: [showTrailer, seasonTrailer],
      ).map((e) => e.id);
      expect(ids, ['st', 'f', 'sh']);
    });

    test("leaves out show trailers named for another season", () {
      final ids = seasonPageExtras(
        seasonNumber: 1,
        seasonExtras: const [],
        showExtras: [_trailer('s2', 'Black Doves - Season 2'), _trailer('plain', 'Black Doves -')],
      ).map((e) => e.id);
      expect(ids, ['plain']);
    });
  });

  group('pickShowTrailer', () {
    test('a show plays the trailer named for its highest season', () {
      final extras = [_trailer('s1', 'Monster S01'), _trailer('s4', 'Monster S04'), _trailer('s2', 'Monster S02')];
      expect(pickShowTrailer(show, extras)?.id, 's4');
    });

    test("else the show's own trailer", () {
      expect(pickShowTrailer(show, [_trailer('plain', 'Monster')])?.id, 'plain');
    });

    test("else the newest season's own", () {
      final newest = _trailer('own4', 'Monster S04');
      expect(pickShowTrailer(show, const [], newestSeasonTrailer: newest)?.id, 'own4');
    });

    test('a movie keeps the usual rule', () {
      const movie = PlexMediaItem(id: 'm', kind: MediaKind.movie, title: 'Film');
      final extras = [_trailer('a', 'Film S01'), _trailer('b', 'Film S02')];
      expect(pickShowTrailer(movie, extras)?.id, 'a');
    });
  });
}
