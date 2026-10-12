import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

/// PlezyFin's own Continue Watching route (PLAN_SHA_29) feeds the home row,
/// so Plezy and Home Assistant show the same items; other servers keep the
/// plain resume route (local/plans/ha-theatre-remote.md, step 4).
void main() {
  Map<String, Object?> movie(String id) => {
    'Id': id,
    'Name': 'Movie $id',
    'Type': 'Movie',
    'UserData': {'PlaybackPositionTicks': 600000000, 'LastPlayedDate': '2026-10-12T05:00:00.0000000Z'},
  };

  test('a PlezyFin server answers the row from its own route', () async {
    final paths = <String>[];
    final client = testJellyfinClient(
      plezyFinRoutes: true,
      handler: (request) async {
        paths.add(request.url.path);
        if (request.url.path == '/PlezyFin/ContinueWatching') {
          expect(request.url.queryParameters['userId'], 'user-1');
          expect(request.url.queryParameters['Limit'], '5');
          return jsonResponse({
            'Items': [movie('a'), movie('b')],
            'TotalRecordCount': 2,
          });
        }
        return jsonResponse({'Items': <Object?>[], 'TotalRecordCount': 0});
      },
    );
    addTearDown(client.close);

    final rows = await client.fetchContinueWatching(count: 5);

    expect(rows.map((item) => item.id), ['a', 'b']);
    expect(paths, isNot(contains('/UserItems/Resume')));
  });

  test('a server without the route falls back to resume and remembers', () async {
    final paths = <String>[];
    final client = testJellyfinClient(
      plezyFinRoutes: true,
      handler: (request) async {
        paths.add(request.url.path);
        if (request.url.path == '/PlezyFin/ContinueWatching') return http.Response('', 404);
        if (request.url.path == '/UserItems/Resume') {
          return jsonResponse({
            'Items': [movie('r')],
            'TotalRecordCount': 1,
          });
        }
        return jsonResponse({'Items': <Object?>[], 'TotalRecordCount': 0});
      },
    );
    addTearDown(client.close);

    expect((await client.fetchContinueWatching(count: 5)).map((item) => item.id), ['r']);
    expect((await client.fetchContinueWatching(count: 5)).map((item) => item.id), ['r']);
    expect(paths.where((path) => path == '/PlezyFin/ContinueWatching'), hasLength(1));
    expect(paths.where((path) => path == '/UserItems/Resume'), hasLength(2));
  });

  test('a failing PlezyFin route falls back this time and is tried again next time', () async {
    final paths = <String>[];
    final client = testJellyfinClient(
      plezyFinRoutes: true,
      handler: (request) async {
        paths.add(request.url.path);
        if (request.url.path == '/PlezyFin/ContinueWatching') return http.Response('', 500);
        if (request.url.path == '/UserItems/Resume') {
          return jsonResponse({
            'Items': [movie('r')],
            'TotalRecordCount': 1,
          });
        }
        return jsonResponse({'Items': <Object?>[], 'TotalRecordCount': 0});
      },
    );
    addTearDown(client.close);

    expect((await client.fetchContinueWatching(count: 5)).map((item) => item.id), ['r']);
    await client.fetchContinueWatching(count: 5);
    expect(paths.where((path) => path == '/PlezyFin/ContinueWatching').length, greaterThanOrEqualTo(2));
  });
}
