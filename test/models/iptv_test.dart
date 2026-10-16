import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/iptv.dart';

void main() {
  group('IptvLineup', () {
    // The example answer from plan 61's "Server-to-player contract".
    final contract = {
      'serverTime': '2026-10-16T14:40:00Z',
      'library': {'id': 'lib1', 'name': 'IPTV'},
      'browserRelay': false,
      'checkedAt': '2026-10-16T12:00:00Z',
      'channels': [
        {
          'id': 'c2',
          'number': 2,
          'name': 'A&E',
          'group': 'Entertainment',
          'imageTag': null,
          'status': 'mayNotWork',
          'not247': true,
          'feeds': [],
        },
        {
          'id': 'c1',
          'number': 1,
          'name': '3ABN Canada',
          'group': 'Religious',
          'imageTag': 'tag1',
          'tvgId': '3ABNCanada.ca',
          'not247': false,
          'status': 'ok',
          'hasGuide': true,
          'isFavorite': true,
          'feeds': [
            {
              'url': 'https://example.org/live/master.m3u8',
              'quality': '720p',
              'headers': {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://example.org/'},
              'status': 'ok',
              'browserCanLoad': true,
            },
            {'url': 'not a url', 'quality': null, 'headers': {}, 'status': 'ok'},
            {'url': 'http://backup.example.org/a.m3u8', 'quality': null, 'headers': {}, 'status': 'mayNotWork'},
          ],
        },
      ],
    };

    test('reads the contract example', () {
      final lineup = IptvLineup.fromJson(contract, libraryId: 'fallback')!;
      expect(lineup.libraryId, 'lib1');
      expect(lineup.libraryName, 'IPTV');
      expect(lineup.serverTime, DateTime.utc(2026, 10, 16, 14, 40));
      expect(lineup.checkedAt, DateTime.utc(2026, 10, 16, 12));
      // Number order, whatever order the answer came in.
      expect(lineup.channels.map((c) => c.id), ['c1', 'c2']);

      final first = lineup.channels.first;
      expect(first.name, '3ABN Canada');
      expect(first.group, 'Religious');
      expect(first.imageTag, 'tag1');
      expect(first.tvgId, '3ABNCanada.ca');
      expect(first.hasGuide, isTrue);
      expect(first.isFavorite, isTrue);
      expect(first.status, IptvStatus.ok);
      // A feed without a usable address is dropped; the order is kept.
      expect(first.feeds.map((f) => f.url), [
        'https://example.org/live/master.m3u8',
        'http://backup.example.org/a.m3u8',
      ]);
      expect(first.feeds.first.quality, '720p');
      expect(first.feeds.first.headers, {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://example.org/'});
      expect(first.feeds.first.browserCanLoad, isTrue);
      expect(first.feeds.last.status, IptvStatus.mayNotWork);

      final second = lineup.channels.last;
      expect(second.imageTag, isNull);
      expect(second.not247, isTrue);
      expect(second.status, IptvStatus.mayNotWork);
      expect(second.feeds, isEmpty);
    });

    test('reads PascalCase too', () {
      final lineup = IptvLineup.fromJson({
        'ServerTime': '2026-10-16T14:40:00Z',
        'Channels': [
          {
            'Id': 'c9',
            'Number': '9',
            'Name': 'Autentic History',
            'IsFavorite': true,
            'Feeds': [
              {
                'Url': 'https://example.org/9.m3u8',
                'Headers': {'User-Agent': 'x'},
              },
            ],
          },
        ],
      }, libraryId: 'lib9')!;
      expect(lineup.libraryId, 'lib9');
      final channel = lineup.channels.single;
      expect(channel.number, 9);
      expect(channel.isFavorite, isTrue);
      expect(channel.feeds.single.headers, {'User-Agent': 'x'});
    });

    test('an answer without serverTime is refused', () {
      expect(IptvLineup.fromJson({'channels': []}, libraryId: 'x'), isNull);
    });
  });

  group('channel numbers', () {
    test('two digits up to 99, then as they are', () {
      expect(iptvNumberLabel(1), '01');
      expect(iptvNumberLabel(42), '42');
      expect(iptvNumberLabel(99), '99');
      expect(iptvNumberLabel(100), '100');
      expect(iptvNumberLabel(223), '223');
    });
  });

  group('IptvGuide', () {
    test('reads the contract example and sorts each channel', () {
      final guide = IptvGuide.fromJson({
        'serverTime': '2026-10-16T14:40:00Z',
        'start': '2026-10-16T14:30:00Z',
        'end': '2026-10-16T17:30:00Z',
        'channels': [
          {
            'id': 'c1',
            'entries': [
              {'start': '2026-10-16T15:00:00Z', 'end': '2026-10-16T16:00:00Z', 'title': 'Later'},
              {
                'start': '2026-10-16T14:00:00Z',
                'end': '2026-10-16T15:00:00Z',
                'title': 'Hockey Tonight',
                'subtitle': null,
                'description': 'Leafs at Habs.',
                'kind': 'Sports',
                'imageId': 'img1',
              },
              {'start': '2026-10-16T16:00:00Z', 'end': '2026-10-16T16:00:00Z', 'title': 'No length'},
            ],
          },
          {'id': 'c2', 'entries': []},
        ],
      })!;
      expect(guide.start, DateTime.utc(2026, 10, 16, 14, 30));
      expect(guide.end, DateTime.utc(2026, 10, 16, 17, 30));
      final c1 = guide.entriesByChannel['c1']!;
      // A programme with no length is dropped.
      expect(c1.map((p) => p.title), ['Hockey Tonight', 'Later']);
      final hockey = c1.first;
      expect(hockey.description, 'Leafs at Habs.');
      expect(hockey.kind, 'Sports');
      expect(hockey.imageId, 'img1');
      expect(hockey.runTime, const Duration(hours: 1));
      expect(hockey.isOnAt(DateTime.utc(2026, 10, 16, 14, 40)), isTrue);
      expect(hockey.isOnAt(DateTime.utc(2026, 10, 16, 15)), isFalse);
      expect(guide.entriesByChannel['c2'], isEmpty);
    });
  });

  group('iptvLogUrl', () {
    test('drops the query and any login', () {
      expect(
        iptvLogUrl('http://user:pass@provider.example:8080/live/abc/def/1.m3u8?username=u&password=p'),
        'http://provider.example:8080/live/abc/def/1.m3u8',
      );
      expect(iptvLogUrl('garbage'), '<feed>');
    });
  });
}
