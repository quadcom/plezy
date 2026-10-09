import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

/// New Shows holds unreleased shows with only a trailer each, so Latest is
/// empty; the row falls back to the library's newest shows and movies
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

  test('an empty Latest falls back to the newest shows and movies', () async {
    final requests = <Uri>[];
    final client = testJellyfinClient(
      handler: (request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/Items/Latest')) return jsonResponse(<Object>[]);
        if (request.url.path == '/Items') {
          return jsonResponse({
            'Items': [
              {'Id': 'show-1', 'Type': 'Series', 'Name': 'Upcoming Show'},
            ],
            'TotalRecordCount': 1,
          });
        }
        return http.Response('unexpected ${request.url}', 500);
      },
    );
    addTearDown(client.close);

    final hubs = await client.fetchLibraryHubs(
      'newshows',
      libraryName: 'New Shows',
      limit: 12,
      includePlaybackHubs: false,
      libraryKind: MediaKind.show,
    );

    expect(hubs.single.items.single.title, 'Upcoming Show');
    final fallback = requests.singleWhere((uri) => uri.path == '/Items');
    expect(fallback.queryParameters['ParentId'], 'newshows');
    expect(fallback.queryParameters['IncludeItemTypes'], 'Series,Movie');
    expect(fallback.queryParameters['SortBy'], 'DateCreated');
  });

  test('a filled Latest is used as is', () async {
    final requests = <Uri>[];
    final client = testJellyfinClient(
      handler: (request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/Items/Latest')) {
          return jsonResponse([
            {'Id': 'movie-1', 'Type': 'Movie', 'Name': 'Trailer Movie'},
          ]);
        }
        return http.Response('unexpected ${request.url}', 500);
      },
    );
    addTearDown(client.close);

    final hubs = await client.fetchLibraryHubs(
      'comingsoon',
      libraryName: 'Coming Soon',
      limit: 12,
      includePlaybackHubs: false,
      libraryKind: MediaKind.movie,
    );

    expect(hubs.single.items.single.title, 'Trailer Movie');
    expect(requests.where((uri) => uri.path == '/Items'), isEmpty);
  });
}
