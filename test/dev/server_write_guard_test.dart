import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/dev/server_write_guard.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';

/// Developer mode sends nothing to the media server (local/plans/dev-tools.md).
void main() {
  setUp(() {
    ServerWriteGuard.debugReset();
    setLoggerLevel(false);
  });
  tearDown(() {
    ServerWriteGuard.debugReset();
    MemoryLogOutput.clearLogs();
    setLoggerLevel(true);
  });

  ServerWriteVerdict v(String method, String path) =>
      ServerWriteGuard.verdict(method, Uri.parse('https://jf.example.com$path'));

  group('verdict', () {
    test('reads pass', () {
      expect(v('GET', '/Items/abc'), ServerWriteVerdict.allow);
      expect(v('GET', '/PlezyFin/ContinueWatching'), ServerWriteVerdict.allow);
      expect(v('HEAD', '/Videos/abc/stream'), ServerWriteVerdict.allow);
    });

    test('player reports are skipped quietly', () {
      expect(v('POST', '/Sessions/Playing'), ServerWriteVerdict.pretend);
      expect(v('POST', '/Sessions/Playing/Progress'), ServerWriteVerdict.pretend);
      expect(v('POST', '/Sessions/Playing/Stopped'), ServerWriteVerdict.pretend);
      expect(v('POST', '/jellyfin/Sessions/Playing/Progress'), ServerWriteVerdict.pretend);
      expect(v('POST', '/:/timeline'), ServerWriteVerdict.pretend);
    });

    test('what playback needs still passes', () {
      expect(v('POST', '/Items/abc/PlaybackInfo'), ServerWriteVerdict.allow);
      expect(v('POST', '/LiveStreams/Close'), ServerWriteVerdict.allow);
      expect(v('DELETE', '/Videos/ActiveEncodings'), ServerWriteVerdict.allow);
      expect(v('POST', '/Sessions/Playing/Ping'), ServerWriteVerdict.allow);
      expect(v('POST', '/playQueues'), ServerWriteVerdict.allow);
      expect(v('POST', '/livetv/dvrs/1/channels/5/tune'), ServerWriteVerdict.allow);
      expect(v('GET', '/:/timeline'), ServerWriteVerdict.allow, reason: 'Plex live TV heartbeat keeps the tuner');
    });

    test('watches, favourites, preferences and edits are refused', () {
      expect(v('POST', '/UserPlayedItems/abc'), ServerWriteVerdict.refuse);
      expect(v('DELETE', '/UserPlayedItems/abc'), ServerWriteVerdict.refuse);
      expect(v('POST', '/UserFavoriteItems/abc'), ServerWriteVerdict.refuse);
      expect(v('POST', '/Users/u1/Configuration'), ServerWriteVerdict.refuse);
      expect(v('POST', '/DisplayPreferences/plezyfin-libraries'), ServerWriteVerdict.refuse);
      expect(v('POST', '/Playlists'), ServerWriteVerdict.refuse);
      expect(v('DELETE', '/Items/abc'), ServerWriteVerdict.refuse);
      expect(v('POST', '/PlezyFin/OldSchool/Reminders'), ServerWriteVerdict.refuse);
      expect(v('PUT', '/:/rate'), ServerWriteVerdict.refuse);
    });

    test('Plex writes sent as GET are refused', () {
      expect(v('GET', '/:/scrobble'), ServerWriteVerdict.refuse);
      expect(v('GET', '/:/unscrobble'), ServerWriteVerdict.refuse);
      expect(v('GET', '/library/sections/3/refresh'), ServerWriteVerdict.refuse);
      expect(v('GET', '/library/sections/3/analyze'), ServerWriteVerdict.refuse);
      expect(v('GET', '/library/sections/3/all'), ServerWriteVerdict.allow);
    });
  });

  test('check lets everything through while developer mode is off', () {
    ServerWriteGuard.debugSetActive(false);
    expect(ServerWriteGuard.check('POST', Uri.parse('https://x/UserPlayedItems/a')), ServerWriteVerdict.allow);
    expect(ServerWriteGuard.blockedCount, 0);
  });

  test('check records what it holds back and tells the listener about refusals only', () {
    ServerWriteGuard.debugSetActive(true);
    final told = <String>[];
    ServerWriteGuard.onBlocked = (method, path) => told.add('$method $path');
    ServerWriteGuard.check('POST', Uri.parse('https://x/Sessions/Playing/Progress'));
    ServerWriteGuard.check('post', Uri.parse('https://x/UserPlayedItems/a'));
    expect(ServerWriteGuard.blockedCount, 2);
    expect(told, ['POST /UserPlayedItems/a']);
    expect(ServerWriteGuard.recentBlocked().first, contains('report, skipped quietly'));
  });

  group('media server client', () {
    late List<http.BaseRequest> sent;
    MediaServerHttpClient build({required bool guard}) {
      sent = [];
      return MediaServerHttpClient(
        baseUrl: 'https://jf.example.com',
        guardServerWrites: guard,
        client: MockClient((request) async {
          sent.add(request);
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }),
      );
    }

    test('a guarded client sends no write in developer mode', () async {
      ServerWriteGuard.debugSetActive(true);
      final client = build(guard: true);
      final refused = await client.post('/UserPlayedItems/abc');
      final report = await client.post('/Sessions/Playing/Progress', body: {'PositionTicks': 1});
      final read = await client.get('/Items/abc');
      expect(refused.statusCode, 403);
      expect(report.statusCode, 204);
      expect(read.statusCode, 200);
      expect(sent.map((r) => r.url.path), ['/Items/abc']);
    });

    test('an unguarded client (auth, artwork) is never held back', () async {
      ServerWriteGuard.debugSetActive(true);
      final client = build(guard: false);
      await client.post('/Users/AuthenticateByName');
      await client.post('/UserPlayedItems/abc');
      expect(sent, hasLength(2));
    });

    test('a guarded client sends everything while developer mode is off', () async {
      ServerWriteGuard.debugSetActive(false);
      final client = build(guard: true);
      await client.post('/UserPlayedItems/abc');
      expect(sent, hasLength(1));
    });
  });
}
