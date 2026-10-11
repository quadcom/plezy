import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/old_school.dart';

void main() {
  group('OldSchoolChannel', () {
    test('reads PascalCase and camelCase alike', () {
      final pascal = OldSchoolChannel.fromJson({'Id': 'c6', 'Number': 6, 'Name': 'Cosmic Cable', 'LogoTag': 'v2'})!;
      final camel = OldSchoolChannel.fromJson({'id': 'c6', 'number': '6', 'name': 'Cosmic Cable', 'logoTag': 'v2'})!;
      for (final channel in [pascal, camel]) {
        expect(channel.id, 'c6');
        expect(channel.number, 6);
        expect(channel.name, 'Cosmic Cable');
        expect(channel.logoTag, 'v2');
      }
    });

    test('a channel without an id is dropped', () {
      expect(OldSchoolChannel.fromJson({'Number': 2, 'Name': 'KABOOM!'}), isNull);
    });
  });

  group('OldSchoolEntry', () {
    test('an episode shows its series as the title', () {
      final entry = OldSchoolEntry.fromJson({
        'Kind': 'Episode',
        'ItemId': 'e1',
        'Start': '2026-10-11T00:30:00Z',
        'End': '2026-10-11T01:30:00Z',
        'Name': 'The Beginning',
        'SeriesName': 'The X-Files',
        'ParentIndexNumber': 6,
        'IndexNumber': 1,
        'RunTimeTicks': 26400000000,
        'ImageTags': {'Backdrop': 'b1', 'Logo': 'l1'},
      })!;
      expect(entry.kind, OldSchoolEntryKind.episode);
      expect(entry.isProgramme, isTrue);
      expect(entry.title, 'The X-Files');
      expect(entry.subtitle, 'S6 E1 · The Beginning');
      expect(entry.runTime, const Duration(minutes: 44));
      expect(entry.backdrop!.tag, 'b1');
      expect(entry.logo!.tag, 'l1');
    });

    test('pictures name their own owner (live PlezyFin shape)', () {
      final entry = OldSchoolEntry.fromJson({
        'channelId': 'the-truth-is-out-there',
        'kind': 'show',
        'itemType': 'Episode',
        'start': '2026-10-11T05:00:00.0000000Z',
        'end': '2026-10-11T05:48:14.23Z',
        'itemId': 'ep1',
        'imageItemId': 'ep1',
        'name': 'Pilot',
        'seriesName': 'The X-Files',
        'seriesId': 'ser1',
        'imageTags': {
          'primary': {'itemId': 'ep1', 'tag': 'p'},
          'backdrop': {'itemId': 'ser1', 'tag': 'b'},
          'logo': {'itemId': 'ser1', 'tag': 'l'},
        },
      })!;
      expect(entry.start, DateTime.utc(2026, 10, 11, 5));
      expect(entry.end, DateTime.utc(2026, 10, 11, 5, 48, 14, 230));
      expect(entry.poster!.itemId, 'ep1');
      expect(entry.backdrop!.itemId, 'ser1');
      expect(entry.logo!.tag, 'l');
      expect(entry.thumb, isNull);
    });

    test('a film shows its year and rating', () {
      final entry = OldSchoolEntry.fromJson({
        'kind': 'movie',
        'itemId': 'm1',
        'start': '2026-10-11T00:30:00Z',
        'end': '2026-10-11T02:30:00Z',
        'name': 'Galaxy Quest',
        'productionYear': 1999,
        'officialRating': 'PG',
      })!;
      expect(entry.title, 'Galaxy Quest');
      expect(entry.subtitle, '1999 · PG');
    });

    test("PlezyFin's show kind takes the item type", () {
      Map<String, dynamic> show(String? itemType) => {
        'channelId': 'c30',
        'kind': 'show',
        'itemType': ?itemType,
        'itemId': 'x1',
        'start': '2026-10-11T00:30:00Z',
        'end': '2026-10-11T01:30:00Z',
        'name': 'The Beginning',
        'seriesName': 'The X-Files',
        'seasonNumber': 6,
        'episodeNumber': 1,
        'imageTags': {'backdrop': 'b1'},
      };
      final episode = OldSchoolEntry.fromJson(show('Episode'))!;
      expect(episode.kind, OldSchoolEntryKind.episode);
      expect(episode.subtitle, 'S6 E1 · The Beginning');
      expect(episode.backdrop!.tag, 'b1');
      expect(OldSchoolEntry.fromJson(show('Movie'))!.kind, OldSchoolEntryKind.movie);
      final musicVideo = OldSchoolEntry.fromJson(show('MusicVideo'))!;
      expect(musicVideo.kind, OldSchoolEntryKind.musicVideo);
      expect(musicVideo.isProgramme, isTrue);
      // An item type this build doesn't know still counts as a programme.
      expect(OldSchoolEntry.fromJson(show('Featurette'))!.isProgramme, isTrue);
      expect(OldSchoolEntry.fromJson(show(null))!.isProgramme, isTrue);
    });

    test('standby has nothing to play and is not a programme', () {
      final entry = OldSchoolEntry.fromJson({
        'Kind': 'Standby',
        'Start': '2026-10-11T00:00:00Z',
        'End': '2026-10-11T00:30:00Z',
      })!;
      expect(entry.isPlayable, isFalse);
      expect(entry.isProgramme, isFalse);
    });

    test('a music video in a break plays but is not a programme', () {
      final entry = OldSchoolEntry.fromJson({
        'kind': 'music',
        'itemType': 'MusicVideo',
        'itemId': 'm1',
        'name': 'Artist - Title',
        'start': '2026-10-11T00:26:00Z',
        'end': '2026-10-11T00:30:00Z',
      })!;
      expect(entry.kind, OldSchoolEntryKind.music);
      expect(entry.isPlayable, isTrue);
      expect(entry.isProgramme, isFalse);
    });

    test('a trailer plays but is not a programme', () {
      final entry = OldSchoolEntry.fromJson({
        'Kind': 'Trailer',
        'ItemId': 't1',
        'Start': '2026-10-11T00:27:00Z',
        'End': '2026-10-11T00:30:00Z',
      })!;
      expect(entry.isPlayable, isTrue);
      expect(entry.isProgramme, isFalse);
    });
  });

  group('OldSchoolGuide', () {
    test('groups entries by channel in start order', () {
      final guide = OldSchoolGuide.fromJson({
        'ServerTime': '2026-10-11T00:40:00Z',
        'Channels': [
          {
            'ChannelId': 'c6',
            'Entries': [
              {'Kind': 'Movie', 'ItemId': 'b', 'Start': '2026-10-11T02:30:00Z', 'End': '2026-10-11T04:00:00Z'},
              {'Kind': 'Movie', 'ItemId': 'a', 'Start': '2026-10-11T00:30:00Z', 'End': '2026-10-11T02:30:00Z'},
            ],
          },
        ],
      })!;
      expect(guide.serverTime, DateTime.utc(2026, 10, 11, 0, 40));
      expect(guide.entriesByChannel['c6']!.map((e) => e.itemId), ['a', 'b']);
    });

    test("reads PlezyFin's camelCase shape", () {
      final guide = OldSchoolGuide.fromJson({
        'serverTime': '2026-10-11T00:40:00Z',
        'channels': [
          {
            'id': 'c2',
            'entries': [
              {
                'channelId': 'c2',
                'kind': 'standby',
                'start': '2026-10-11T00:30:00Z',
                'end': '2026-10-11T01:00:00Z',
                'name': '',
              },
            ],
          },
        ],
      })!;
      expect(guide.entriesByChannel['c2']!.single.kind, OldSchoolEntryKind.standby);
    });

    test('an answer without serverTime is refused', () {
      expect(OldSchoolGuide.fromJson({'Channels': []}), isNull);
    });
  });

  group('OldSchoolTune', () {
    Map<String, dynamic> answer({required String serverTime}) => {
      'ServerTime': serverTime,
      'Now': {'Kind': 'Movie', 'ItemId': 'm1', 'Start': '2026-10-11T00:30:00Z', 'End': '2026-10-11T02:30:00Z'},
      'Next': {'Kind': 'Trailer', 'ItemId': 't1', 'Start': '2026-10-11T02:12:00Z', 'End': '2026-10-11T02:14:00Z'},
    };

    test('the offset follows the server clock, not the device clock', () {
      // The device clock runs 5 minutes fast.
      final receivedAt = DateTime.utc(2026, 10, 11, 0, 52);
      final tune = OldSchoolTune.fromJson('c6', answer(serverTime: '2026-10-11T00:47:00Z'), receivedAt: receivedAt)!;
      expect(tune.liveOffset(receivedAt), const Duration(minutes: 17));
      // Ten seconds later (the item lookup), the offset has moved with it.
      expect(tune.liveOffset(receivedAt.add(const Duration(seconds: 10))), const Duration(minutes: 17, seconds: 10));
      expect(tune.next!.kind, OldSchoolEntryKind.trailer);
    });

    test('an entry not started yet plays from its beginning', () {
      final receivedAt = DateTime.utc(2026, 10, 11, 0, 20);
      final tune = OldSchoolTune.fromJson('c6', answer(serverTime: '2026-10-11T00:20:00Z'), receivedAt: receivedAt)!;
      expect(tune.liveOffset(receivedAt), Duration.zero);
    });

    test('an answer without a now entry is refused', () {
      expect(
        OldSchoolTune.fromJson('c6', {'ServerTime': '2026-10-11T00:20:00Z'}, receivedAt: DateTime.utc(2026)),
        isNull,
      );
    });
  });
}
