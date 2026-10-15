import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_trailer.dart';

PlexMediaItem _trailer(String id, String title) =>
    PlexMediaItem(id: id, kind: MediaKind.clip, subtype: 'trailer', title: title);

void main() {
  const show = PlexMediaItem(id: 'show', kind: MediaKind.show, title: 'Monster');

  group('trailerSeasonNumber', () {
    test('reads the season from PMB names', () {
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02-trailer')), 2);
      expect(trailerSeasonNumber(_trailer('a', 'monster s4')), 4);
      expect(trailerSeasonNumber(_trailer('a', 'Show S123')), 123);
    });

    test('ignores names without a season', () {
      expect(trailerSeasonNumber(_trailer('a', 'Monster')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'Monster S02 Behind the scenes')), isNull);
      expect(trailerSeasonNumber(_trailer('a', 'Monsters')), isNull);
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
