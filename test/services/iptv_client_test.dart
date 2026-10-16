import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/models/iptv.dart';
import 'package:plezy/screens/iptv/iptv_controller.dart';
import 'package:plezy/screens/iptv/iptv_number_entry.dart';

import '../test_helpers/backend_client_fixtures.dart';

const _token = 'own-secret-token';

Map<String, dynamic> _channel(
  String id,
  int number, {
  String? group,
  List<Map<String, dynamic>> feeds = const [],
  bool favourite = false,
  String status = 'ok',
}) => {
  'id': id,
  'number': number,
  'name': 'Channel $number',
  'group': ?group,
  'isFavorite': favourite,
  'status': status,
  'feeds': feeds,
};

Map<String, dynamic> _lineup(List<Map<String, dynamic>> channels, {String checkedAt = '2026-10-16T12:00:00Z'}) => {
  'serverTime': '2026-10-16T14:40:00Z',
  'library': {'id': 'lib', 'name': 'IPTV'},
  'checkedAt': checkedAt,
  'channels': channels,
};

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

void main() {
  group('IPTV client calls', () {
    test('Channels and Guide use the contract routes', () async {
      final requests = <http.Request>[];
      final client = testJellyfinClient(
        connection: testJellyfinConnection(accessToken: _token),
        handler: (request) async {
          requests.add(request);
          if (request.url.path == '/PlezyFin/Iptv/lib/Channels') return _json(_lineup([_channel('c1', 1)]));
          if (request.url.path == '/PlezyFin/Iptv/lib/Guide') {
            return _json({'serverTime': '2026-10-16T14:40:00Z', 'channels': []});
          }
          return http.Response('unexpected', 500);
        },
      );
      addTearDown(client.close);

      final lineup = await client.fetchIptvLineup('lib');
      expect(lineup.channels.single.id, 'c1');
      await client.fetchIptvGuide('lib', start: DateTime.utc(2026, 10, 16, 14, 30), hours: 40);
      final guide = requests.last.url;
      expect(guide.queryParameters['start'], '2026-10-16T14:30:00.000Z');
      // The server takes 1-24 hours.
      expect(guide.queryParameters['hours'], '24');
    });

    test('a programme picture needs no sign-in', () {
      final client = testJellyfinClient(connection: testJellyfinConnection(accessToken: _token));
      addTearDown(client.close);
      final url = client.iptvProgrammeImageUrl('lib', 'img 1', width: 640);
      expect(url, 'https://jf.example.com/PlezyFin/Iptv/lib/ProgramImages/img%201?maxWidth=640');
      expect(url, isNot(contains(_token)));
    });
  });

  group('IptvPlaybackSession', () {
    IptvChannel channel(List<Map<String, dynamic>> feeds) => IptvChannel.fromJson(_channel('c1', 1, feeds: feeds))!;

    test('tries a played feed once more, then the next, then gives up', () {
      final client = testJellyfinClient(connection: testJellyfinConnection(accessToken: _token));
      addTearDown(client.close);
      final session = client.startIptvPlayback(
        channel([
          {
            'url': 'https://a.example/1.m3u8',
            'headers': {'User-Agent': 'UA'},
          },
          {'url': 'https://b.example/2.m3u8'},
        ]),
      );
      expect(session.feed!.url, 'https://a.example/1.m3u8');
      expect(session.headers, {'User-Agent': 'UA'});

      final again = session.retryCurrent()!;
      expect(again.feed!.url, 'https://a.example/1.m3u8');
      expect(again.retryCurrent(), isNull);

      final next = again.nextFeed()!;
      expect(next.feed!.url, 'https://b.example/2.m3u8');
      expect(next.headers, isEmpty);
      expect(next.nextFeed(), isNull);
    });

    test("a feed that would carry this server's own token is never opened", () {
      final client = testJellyfinClient(connection: testJellyfinConnection(accessToken: _token));
      addTearDown(client.close);
      final session = client.startIptvPlayback(
        channel([
          {'url': 'https://jf.example.com/Videos/x/stream?api_key=$_token'},
          {
            'url': 'https://c.example/3.m3u8',
            'headers': {'Authorization': 'MediaBrowser Token="$_token"'},
          },
          // A paid provider's own login is fine (plan 61b).
          {'url': 'https://provider.example/live/user/pass/4.m3u8?token=provider-key'},
        ]),
      );
      expect(session.feed!.url, 'https://provider.example/live/user/pass/4.m3u8?token=provider-key');
      expect(session.nextFeed(), isNull);
    });

    test('a channel without feeds has nothing to open', () {
      final client = testJellyfinClient();
      addTearDown(client.close);
      final session = client.startIptvPlayback(channel(const []));
      expect(session.hasFeed, isFalse);
      expect(session.nextFeed(), isNull);
    });

    test('reports start once and stop once, never progress', () async {
      final paths = <String>[];
      final bodies = <Map<String, dynamic>>[];
      final client = testJellyfinClient(
        handler: (request) async {
          paths.add(request.url.path);
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 204);
        },
      );
      addTearDown(client.close);
      final first = client.startIptvPlayback(
        channel([
          {'url': 'https://a.example/1.m3u8'},
          {'url': 'https://b.example/2.m3u8'},
        ]),
      );
      await first.reportTimeline(state: 'playing', positionMs: 0, durationMs: 0);
      await first.reportTimeline(state: 'playing', positionMs: 10000, durationMs: 0);
      // A failover to the next feed is the same viewing.
      final second = first.nextFeed()!;
      await second.reportTimeline(state: 'paused', positionMs: 20000, durationMs: 0);
      await second.reportTimeline(state: 'stopped', positionMs: 30000, durationMs: 0);
      await second.reportTimeline(state: 'stopped', positionMs: 30000, durationMs: 0);
      expect(paths, ['/Sessions/Playing', '/Sessions/Playing/Stopped']);
      expect(bodies.first['ItemId'], 'c1');
      expect(bodies.first['PlayMethod'], 'DirectPlay');
      expect(bodies.first['PlaySessionId'], bodies.last['PlaySessionId']);
    });
  });

  group('IptvController', () {
    Future<IptvController> loaded(
      List<Map<String, dynamic>> channels, {
      List<Map<String, dynamic>> Function()? refresh,
      String Function()? checkedAt,
      Future<http.Response> Function(http.Request)? other,
      Future<http.Response> Function(http.Request)? guide,
    }) async {
      final client = testJellyfinClient(
        handler: (request) async {
          if (request.url.path.endsWith('/Channels')) {
            return _json(_lineup(refresh?.call() ?? channels, checkedAt: checkedAt?.call() ?? '2026-10-16T12:00:00Z'));
          }
          if (request.url.path.endsWith('/Guide')) {
            if (guide != null) return guide(request);
            return _json({'serverTime': '2026-10-16T14:40:00Z', 'channels': []});
          }
          return other?.call(request) ?? http.Response('', 204);
        },
      );
      addTearDown(client.close);
      final controller = IptvController(client, libraryId: 'lib-${DateTime.now().microsecondsSinceEpoch}');
      addTearDown(controller.dispose);
      await controller.load();
      return controller;
    }

    test('groups go biggest first, with no group as one group', () async {
      final c = await loaded([
        _channel('a', 1, group: 'News'),
        _channel('b', 2, group: 'Undefined'),
        _channel('c', 3),
        _channel('d', 4, group: 'News'),
        _channel('e', 5, group: 'Sports'),
        _channel('f', 6, group: 'News'),
      ]);
      expect(c.groups.map((g) => (g.key, g.count)), [('News', 3), ('', 2), ('Sports', 1)]);
      c.setFilter(const IptvFilter.group(''));
      expect(c.channels.map((ch) => ch.id), ['b', 'c']);
    });

    test('a device clock that is off asks for the guide again by the server clock', () async {
      // The buildbox emulator ran 16 days behind (2026-10-16).
      final serverTime = DateTime.now().toUtc().add(const Duration(days: 16, minutes: 7));
      final starts = <DateTime>[];
      final client = testJellyfinClient(
        handler: (request) async {
          if (request.url.path.endsWith('/Channels')) return _json(_lineup([_channel('a', 1)]));
          if (request.url.path.endsWith('/Guide')) {
            starts.add(DateTime.parse(request.url.queryParameters['start']!));
            return _json({'serverTime': serverTime.toIso8601String(), 'channels': []});
          }
          return http.Response('', 204);
        },
      );
      addTearDown(client.close);
      final controller = IptvController(client, libraryId: 'lib-${DateTime.now().microsecondsSinceEpoch}');
      addTearDown(controller.dispose);
      await controller.load();

      final now = controller.serverNow;
      final expected = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
      expect(starts, hasLength(2));
      expect(starts.last, expected);
      expect(controller.guideStart, expected);
    });

    test('a failing guide still shows the channels', () async {
      // The real server's listings were empty or broken on 2026-10-16.
      final c = await loaded([
        _channel('a', 1),
        _channel('b', 2),
      ], guide: (_) async => http.Response('{"title":"Not Found"}', 404));
      expect(c.error, isNull);
      expect(c.hasLoaded, isTrue);
      expect(c.channels.map((ch) => ch.id), ['a', 'b']);
      expect(c.entriesFor('a'), isEmpty);
    });

    test('channel up and down wrap within the filter', () async {
      final c = await loaded([
        _channel('a', 1, group: 'News'),
        _channel('b', 2, group: 'Kids'),
        _channel('c', 3, group: 'News'),
      ]);
      c.setFilter(const IptvFilter.group('News'));
      expect(c.neighbourOf('c', 1)!.id, 'a');
      expect(c.neighbourOf('a', -1)!.id, 'c');
      // Tuned outside the filter (by number): the whole line-up.
      expect(c.neighbourOf('b', 1)!.id, 'c');
    });

    test('last channel follows tuning', () async {
      final c = await loaded([_channel('a', 1), _channel('b', 2)]);
      expect(c.lastChannel, isNull);
      c.setTuned('a');
      c.setTuned('b');
      expect(c.lastChannel!.id, 'a');
      c.setTuned('a');
      expect(c.lastChannel!.id, 'b');
    });

    test("this device's dead mark lasts until a newer stream check", () async {
      var checkedAt = '2026-10-16T12:00:00Z';
      final c = await loaded([_channel('a', 1)], checkedAt: () => checkedAt);
      final channel = c.channelById('a')!;
      expect(c.mayNotWork(channel), isFalse);
      c.markDead('a');
      expect(c.mayNotWork(channel), isTrue);
      await c.refreshLineup();
      expect(c.mayNotWork(channel), isTrue, reason: 'the same check');
      checkedAt = '2026-10-16T18:00:00Z';
      await c.refreshLineup();
      expect(c.mayNotWork(c.channelById('a')!), isFalse);
    });

    test("the server's mark shows on its own", () async {
      final c = await loaded([_channel('a', 1, status: 'mayNotWork')]);
      expect(c.mayNotWork(c.channelById('a')!), isTrue);
    });

    test('a favourite the server refuses is put back', () async {
      final c = await loaded([_channel('a', 1)], other: (_) async => http.Response('nope', 500));
      final pending = c.toggleFavourite(c.channelById('a')!);
      expect(c.channelById('a')!.isFavorite, isTrue);
      await pending;
      expect(c.channelById('a')!.isFavorite, isFalse);
    });

    test('number entry waits only while a longer number could follow', () async {
      final c = await loaded([_channel('a', 1), _channel('b', 12), _channel('c', 4)]);
      expect(c.numberCouldGrow('1'), isTrue);
      expect(c.numberCouldGrow('4'), isFalse);
      expect(c.numberCouldGrow('12'), isFalse);
    });
  });

  group('IptvNumberEntry', () {
    test('a number nothing longer starts with goes at once', () {
      final tuned = <int>[];
      final entry = IptvNumberEntry(onNumber: tuned.add, couldGrow: (d) => d == '1');
      addTearDown(entry.dispose);
      entry.add(4);
      expect(tuned, [4]);
      expect(entry.digits, isEmpty);
    });

    test('otherwise it waits, and a leading zero counts for nothing', () {
      fakeAsync((async) {
        final tuned = <int>[];
        final entry = IptvNumberEntry(onNumber: tuned.add, couldGrow: (d) => d == '1');
        entry.add(0);
        entry.add(1);
        expect(entry.digits, '1');
        expect(tuned, isEmpty);
        async.elapse(IptvNumberEntry.wait);
        expect(tuned, [1]);
        entry.dispose();
      });
    });

    test('cancel drops what was typed', () {
      fakeAsync((async) {
        final tuned = <int>[];
        final entry = IptvNumberEntry(onNumber: tuned.add, couldGrow: (_) => true);
        entry.add(2);
        entry.cancel();
        async.elapse(IptvNumberEntry.wait * 2);
        expect(tuned, isEmpty);
        entry.dispose();
      });
    });
  });
}
