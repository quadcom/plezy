import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

const _views = [
  {'Id': 'a1b2c3d4movies', 'Name': 'Movies', 'CollectionType': 'movies', 'Type': 'CollectionFolder'},
  {'Id': 'a1b2c3d4kids', 'Name': 'Kids', 'CollectionType': 'movies', 'Type': 'CollectionFolder'},
];

/// Libraries hidden in the Jellyfin web client sit in the user's
/// `MyMediaExcludes`; Plezy lists them anyway and folds them away
/// (Adrian, 2026-10-09).
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    JellyfinApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('libraries come back with hidden ones, marked from MyMediaExcludes', () async {
    final views = <Uri>[];
    final client = testJellyfinClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/Users/user-1/Views') {
          views.add(request.url);
          return jsonResponse({'Items': _views});
        }
        if (request.url.path == '/Users/Me') {
          return jsonResponse({
            'Configuration': {
              // Dashed and upper-case: the server is not consistent about either.
              'MyMediaExcludes': ['A1B2-C3D4-KIDS'],
            },
          });
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    );
    addTearDown(client.close);

    final libraries = await client.fetchLibraries();

    expect(views.single.queryParameters['includeHidden'], 'true');
    expect({for (final lib in libraries) lib.title: lib.hidden}, {'Movies': false, 'Kids': true});
  });

  test('without the user record it lists only the shown libraries, as before', () async {
    final views = <Uri>[];
    final client = testJellyfinClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/Users/user-1/Views') {
          views.add(request.url);
          final all = request.url.queryParameters['includeHidden'] == 'true';
          return jsonResponse({'Items': all ? _views : _views.take(1).toList()});
        }
        return http.Response('down', 500);
      }),
    );
    addTearDown(client.close);

    final libraries = await client.fetchLibraries();

    expect(views.last.queryParameters.containsKey('includeHidden'), isFalse);
    expect(libraries.map((lib) => lib.title), ['Movies']);
    expect(libraries.single.hidden, isFalse);
  });

  group('setLibraryHiddenOnServer', () {
    Future<Map<String, dynamic>> postedConfiguration(List<String> excludes, String libraryId, bool hidden) async {
      Map<String, dynamic>? posted;
      final client = testJellyfinClient(
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/Users/Me') {
            return jsonResponse({
              'Configuration': {
                'MyMediaExcludes': excludes,
                'OrderedViews': ['a1b2c3d4movies'],
                'DisplayMissingEpisodes': true,
              },
            });
          }
          if (request.method == 'POST' && request.url.path == '/Users/user-1/Configuration') {
            posted = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('', 204);
          }
          return http.Response('unexpected ${request.method} ${request.url}', 500);
        }),
      );
      addTearDown(client.close);
      await client.setLibraryHiddenOnServer(libraryId, hidden: hidden);
      return posted!;
    }

    test('hiding adds the id and keeps the rest of the configuration', () async {
      final posted = await postedConfiguration(const ['other'], 'a1b2c3d4kids', true);
      expect(posted['MyMediaExcludes'], ['other', 'a1b2c3d4kids']);
      expect(posted['OrderedViews'], ['a1b2c3d4movies']);
      expect(posted['DisplayMissingEpisodes'], isTrue);
    });

    test('showing removes the id however the server spelled it', () async {
      final posted = await postedConfiguration(const ['A1B2-C3D4-KIDS', 'other'], 'a1b2c3d4kids', false);
      expect(posted['MyMediaExcludes'], ['other']);
    });

    test('hiding twice leaves one entry', () async {
      final posted = await postedConfiguration(const ['a1b2c3d4kids'], 'a1b2c3d4kids', true);
      expect(posted['MyMediaExcludes'], ['a1b2c3d4kids']);
    });
  });
}
