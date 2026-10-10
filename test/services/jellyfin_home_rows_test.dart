import 'package:plezy/media/home_layout.dart';
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

  group('rows by release date (PLAN_SHA_12)', () {
    test('newest release first asks for dated items, then fills with undated ones', () async {
      final requests = <Uri>[];
      final client = testJellyfinClient(
        handler: (request) async {
          requests.add(request.url);
          if (request.url.path == '/Items' && request.url.queryParameters['SortBy'] == 'PremiereDate,SortName') {
            return jsonResponse({
              'Items': [
                {'Id': 'new', 'Type': 'Movie', 'Name': 'New Film', 'PremiereDate': '2026-09-01T00:00:00Z'},
                {'Id': 'old', 'Type': 'Movie', 'Name': 'Old Film', 'PremiereDate': '1999-01-01T00:00:00Z'},
              ],
              'TotalRecordCount': 2,
            });
          }
          if (request.url.path == '/Items') {
            return jsonResponse({
              'Items': [
                {'Id': 'new', 'Type': 'Movie', 'Name': 'New Film', 'PremiereDate': '2026-09-01T00:00:00Z'},
                {'Id': 'undated', 'Type': 'Movie', 'Name': 'Undated Film'},
              ],
              'TotalRecordCount': 2,
            });
          }
          return http.Response('unexpected ${request.url}', 500);
        },
      );
      addTearDown(client.close);

      final hubs = await client.fetchLibraryHubs(
        'movies',
        libraryName: 'Movies',
        limit: 12,
        includePlaybackHubs: false,
        libraryKind: MediaKind.movie,
        recentSort: HomeRowSort.released,
      );

      final hub = hubs.single;
      expect(hub.title, 'New Releases in Movies');
      expect(hub.identifier, endsWith('.released'));
      expect([for (final item in hub.items) item.title], ['New Film', 'Old Film', 'Undated Film']);
      final dated = requests.firstWhere((uri) => uri.queryParameters['SortBy'] == 'PremiereDate,SortName');
      expect(dated.queryParameters['SortOrder'], 'Descending');
      expect(dated.queryParameters['MinPremiereDate'], isNotNull);
      expect(dated.queryParameters['IncludeItemTypes'], 'Movie,Series');
      expect(requests.where((uri) => uri.path.endsWith('/Items/Latest')), isEmpty);
    });

    test('soonest release first sorts ascending and is titled Coming Up', () async {
      final requests = <Uri>[];
      final client = testJellyfinClient(
        handler: (request) async {
          requests.add(request.url);
          if (request.url.path == '/Items') {
            return jsonResponse({
              'Items': [
                for (var i = 0; i < 3; i++)
                  {'Id': 'm$i', 'Type': 'Movie', 'Name': 'Film $i', 'PremiereDate': '2027-0${i + 1}-01T00:00:00Z'},
              ],
              'TotalRecordCount': 3,
            });
          }
          return http.Response('unexpected ${request.url}', 500);
        },
      );
      addTearDown(client.close);

      final hubs = await client.fetchLibraryHubs(
        'comingsoon',
        libraryName: 'Coming Soon',
        limit: 3,
        includePlaybackHubs: false,
        libraryKind: MediaKind.movie,
        recentSort: HomeRowSort.upcoming,
      );

      expect(hubs.single.title, 'Coming Up in Coming Soon');
      // A full dated row needs no undated fill.
      expect(requests.single.queryParameters['SortOrder'], 'Ascending');
    });
  });
}
