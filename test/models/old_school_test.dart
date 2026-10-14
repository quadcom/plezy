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

  group('OldSchoolEntry promo (PLAN_SHA_43)', () {
    test('a trailer for a film already in the library reads every field', () {
      final entry = OldSchoolEntry.fromJson({
        'kind': 'trailer',
        'itemId': 't1',
        'start': '2026-10-13T03:46:00Z',
        'end': '2026-10-13T03:48:30Z',
        'name': 'Blade Runner',
        'promo': 'have',
        'promoItemId': 'abc123',
        'promoItemType': 'Movie',
        'promoName': 'Blade Runner',
        'promoLibrary': 'Films',
        'promoOnAir': {
          'channelId': 'c12',
          'channelNumber': 12,
          'channelName': 'Cinema Classics',
          'start': '2026-10-16T01:00:00Z',
        },
      })!;
      expect(entry.promo, OldSchoolPromo.have);
      expect(entry.promoItemId, 'abc123');
      expect(entry.promoItemType, 'Movie');
      expect(entry.promoName, 'Blade Runner');
      expect(entry.promoLibrary, 'Films');
      expect(entry.promoOnAir!.channelNumber, '12');
      expect(entry.promoOnAir!.channelName, 'Cinema Classics');
      expect(entry.promoOnAir!.start, DateTime.utc(2026, 10, 16, 1));
    });

    test('a coming date is a local day, whatever the time zone', () {
      final entry = OldSchoolEntry.fromJson({
        'kind': 'trailer',
        'itemId': 't2',
        'start': '2026-10-13T03:46:00Z',
        'end': '2026-10-13T03:48:30Z',
        'name': '12 12 12',
        'promo': 'coming',
        'promoItemType': 'Series',
        'promoDate': '2026-11-13',
      })!;
      expect(entry.promo, OldSchoolPromo.coming);
      expect(entry.promoDate, DateTime(2026, 11, 13));
    });

    test('no promo, or one this build does not know, reads as none', () {
      final base = {'kind': 'trailer', 'itemId': 't3', 'start': '2026-10-13T03:46:00Z', 'end': '2026-10-13T03:48:30Z'};
      expect(OldSchoolEntry.fromJson(base)!.promo, isNull);
      expect(OldSchoolEntry.fromJson({...base, 'promo': 'later'})!.promo, isNull);
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

  group('OldSchoolTune pre-roll (PLAN_SHA_46)', () {
    // Heat's slot opens with its own 2-minute trailer, then the film.
    OldSchoolTune tuneAt(String serverTime, {bool preRoll = true}) => OldSchoolTune.fromJson('c2', {
      'serverTime': serverTime,
      'now': {
        'kind': 'show',
        'itemType': 'Movie',
        'itemId': 'heat',
        'name': 'Heat',
        'year': 1995,
        'start': '2026-10-14T01:00:00Z',
        'end': '2026-10-14T04:00:00Z',
        'runTimeTicks': 170 * 60 * 10000000,
        if (preRoll) 'preItemId': 'heattrailer',
        if (preRoll) 'preRunTimeTicks': 120 * 10000000,
      },
    }, receivedAt: DateTime.parse(serverTime))!;

    test('reads the trailer and counts it in the slot', () {
      final entry = tuneAt('2026-10-14T01:00:00Z').now;
      expect(entry.preItemId, 'heattrailer');
      expect(entry.hasPreRoll, isTrue);
      expect(entry.preRollTime, const Duration(minutes: 2));
      expect(entry.slotRunTime, const Duration(minutes: 172));
    });

    test('inside the trailer: the trailer plays from the slot offset, the film waits at 0', () {
      final tune = tuneAt('2026-10-14T01:00:45Z');
      final at = tune.receivedAt;
      expect(tune.inPreRoll(tune.now, at), isTrue);
      expect(tune.slotOffset(tune.now, at), const Duration(seconds: 45));
      expect(tune.offsetInto(tune.now, at), Duration.zero);
    });

    test('past the trailer: the film plays from offset minus the trailer', () {
      final tune = tuneAt('2026-10-14T01:30:00Z');
      final at = tune.receivedAt;
      expect(tune.inPreRoll(tune.now, at), isFalse);
      expect(tune.offsetInto(tune.now, at), const Duration(minutes: 28));
    });

    test('without one, nothing changes', () {
      final tune = tuneAt('2026-10-14T01:30:00Z', preRoll: false);
      final at = tune.receivedAt;
      expect(tune.now.hasPreRoll, isFalse);
      expect(tune.inPreRoll(tune.now, at), isFalse);
      expect(tune.offsetInto(tune.now, at), const Duration(minutes: 30));
      expect(tune.now.slotRunTime, const Duration(minutes: 170));
    });

    test('a zero-length trailer is no pre-roll', () {
      final entry = OldSchoolEntry.fromJson({
        'kind': 'show',
        'itemId': 'heat',
        'start': '2026-10-14T01:00:00Z',
        'end': '2026-10-14T04:00:00Z',
        'preItemId': 'heattrailer',
        'preRunTimeTicks': 0,
      })!;
      expect(entry.hasPreRoll, isFalse);
      expect(entry.preRollTime, Duration.zero);
    });
  });

  group('OldSchoolEntry.joinBreaks', () {
    OldSchoolEntry at(OldSchoolEntryKind kind, int startMin, int endMin, String name, {String? series}) =>
        OldSchoolEntry(
          kind: kind,
          itemId: kind == OldSchoolEntryKind.standby ? null : name,
          start: DateTime.utc(2026, 10, 11, 22).add(Duration(minutes: startMin)),
          end: DateTime.utc(2026, 10, 11, 22).add(Duration(minutes: endMin)),
          name: name,
          seriesName: series,
        );

    test('a run of trailers, music and standby becomes one intermission', () {
      final joined = OldSchoolEntry.joinBreaks([
        at(OldSchoolEntryKind.movie, 0, 100, 'Heat'),
        at(OldSchoolEntryKind.trailer, 100, 102, 'Trailer A'),
        at(OldSchoolEntryKind.trailer, 102, 104, 'Pilot', series: 'The X-Files'),
        at(OldSchoolEntryKind.music, 104, 108, 'Band - Song'),
        at(OldSchoolEntryKind.standby, 108, 110, ''),
        at(OldSchoolEntryKind.movie, 110, 200, 'Ronin'),
      ]);
      expect(joined.map((e) => e.kind), [
        OldSchoolEntryKind.movie,
        OldSchoolEntryKind.intermission,
        OldSchoolEntryKind.movie,
      ]);
      final intermission = joined[1];
      expect(intermission.start, DateTime.utc(2026, 10, 11, 23, 40));
      expect(intermission.end, DateTime.utc(2026, 10, 11, 23, 50));
      expect(intermission.isProgramme, isFalse);
      expect(intermission.breakItemNames, ['Trailer A', 'The X-Files', 'Band - Song']);
    });

    test('a run of music videos and the breaks between them is one music block', () {
      final joined = OldSchoolEntry.joinBreaks([
        at(OldSchoolEntryKind.trailer, 0, 2, 'Lead-in'),
        at(OldSchoolEntryKind.musicVideo, 2, 6, 'Artist - One'),
        at(OldSchoolEntryKind.trailer, 6, 8, 'Between'),
        at(OldSchoolEntryKind.musicVideo, 8, 12, 'Artist - Two'),
        at(OldSchoolEntryKind.standby, 12, 20, ''),
        at(OldSchoolEntryKind.movie, 20, 120, 'Heat'),
      ]);
      expect(joined.map((e) => e.kind), [
        OldSchoolEntryKind.intermission,
        OldSchoolEntryKind.musicVideos,
        OldSchoolEntryKind.intermission,
        OldSchoolEntryKind.movie,
      ]);
      final music = joined[1];
      expect(music.start, DateTime.utc(2026, 10, 11, 22, 2));
      expect(music.end, DateTime.utc(2026, 10, 11, 22, 12));
      expect(music.breakItems.map((e) => e.name), ['Artist - One', 'Between', 'Artist - Two']);
    });

    test('a break at either end of a music run stays an intermission', () {
      final joined = OldSchoolEntry.joinBreaks([
        at(OldSchoolEntryKind.trailer, 0, 2, 'Lead-in'),
        at(OldSchoolEntryKind.musicVideo, 2, 6, 'Artist - One'),
        at(OldSchoolEntryKind.trailer, 6, 8, 'Between'),
        at(OldSchoolEntryKind.musicVideo, 8, 12, 'Artist - Two'),
        at(OldSchoolEntryKind.standby, 12, 20, ''),
      ]);
      expect(joined.map((e) => e.kind), [
        OldSchoolEntryKind.intermission,
        OldSchoolEntryKind.musicVideos,
        OldSchoolEntryKind.intermission,
      ]);
      expect(joined.last.breakItemNames, isEmpty);
    });
  });
}
