import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/search_scope.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/services/jellyfin_client.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

/// A Jellyfin client whose requests are recorded and answered by [routes]
/// (path -> JSON body); any other path is a 404.
({JellyfinClient client, List<Uri> requests}) _client(Map<String, Object> routes) {
  final requests = <Uri>[];
  final client = JellyfinClient.forTesting(
    connection: testJellyfinConnection(userId: 'user-1'),
    httpClient: MockClient((request) async {
      requests.add(request.url);
      final body = routes[request.url.path];
      if (body == null) return http.Response('not found', 404);
      return jsonResponse(body);
    }),
  );
  addTearDown(client.close);
  return (client: client, requests: requests);
}

void main() {
  group('Search facets (local/plans/search-actors.md)', () {
    test('Jellyfin offers search facets; Plex and Emby do not', () {
      expect(ServerCapabilities.jellyfin.searchFacets, isTrue);
      expect(ServerCapabilities.plex.searchFacets, isFalse);
      expect(ServerCapabilities.emby.searchFacets, isFalse);
    });

    test('actors: one /Persons request narrowed to actors, with photos', () async {
      final routed = _client({
        '/Persons': {
          'Items': [
            {
              'Id': 'p1',
              'Name': 'Amanda Seyfried',
              'Type': 'Person',
              'ImageTags': {'Primary': 'abc'},
            },
            {'Id': 'p2', 'Name': 'Amanda Peet', 'Type': 'Person'},
            {'Name': 'No id'},
          ],
        },
      });

      final matches = await routed.client.searchFacet(SearchScopeKind.actors, ' amanda ');

      expect(routed.requests, hasLength(1));
      final query = routed.requests.single.queryParameters;
      expect(routed.requests.single.path, '/Persons');
      expect(query['searchTerm'], 'amanda');
      expect(query['userId'], 'user-1');
      expect(query['personTypes'], 'Actor');
      expect(query['limit'], '20');
      expect(query['enableTotalRecordCount'], 'false');
      expect(query['enableImageTypes'], 'Primary');

      expect(matches.map((match) => match.name), ['Amanda Seyfried', 'Amanda Peet']);
      expect(matches.first.kind, SearchScopeKind.actors);
      expect(matches.first.facet, const MediaFacet(MediaFacetKind.person, 'p1'));
      expect(matches.first.imagePath, contains('/Items/p1/Images/Primary?tag=abc'));
      expect(matches.last.imagePath, isNull);
      expect(matches.first.serverId, routed.client.serverId);
    });

    test('directors and writers ask /Persons for those roles only', () async {
      final routed = _client({
        '/Persons': {
          'Items': [
            {'Id': 'p9', 'Name': 'Amanda Sthers'},
          ],
        },
      });

      final matches = await routed.client.searchFacet(SearchScopeKind.crew, 'amanda');

      expect(routed.requests.single.queryParameters['personTypes'], 'Director,Writer');
      expect(matches.single.kind, SearchScopeKind.crew);
      expect(matches.single.facet.kind, MediaFacetKind.person);
    });

    test('genres and studios: one name search each, films and shows only', () async {
      final routed = _client({
        '/Genres': {
          'Items': [
            {'Id': 'g1', 'Name': 'Drama'},
          ],
        },
        '/Studios': {
          'Items': [
            {'Id': 's1', 'Name': 'Amanda Productions'},
          ],
        },
      });

      final genres = await routed.client.searchFacet(SearchScopeKind.genres, 'dram');
      final studios = await routed.client.searchFacet(SearchScopeKind.studios, 'amanda');

      expect(routed.requests.map((uri) => uri.path), ['/Genres', '/Studios']);
      for (final uri in routed.requests) {
        expect(uri.queryParameters['userId'], 'user-1');
        expect(uri.queryParameters['limit'], '20');
        expect(uri.queryParameters['IncludeItemTypes'], 'Movie,Series');
      }
      expect(routed.requests.first.queryParameters['searchTerm'], 'dram');
      expect(genres.single.facet, const MediaFacet(MediaFacetKind.genre, 'g1'));
      expect(genres.single.name, 'Drama');
      expect(studios.single.facet, const MediaFacet(MediaFacetKind.studio, 's1'));
    });

    test('keywords: an exact tag count, one chip with the count when any match', () async {
      final routed = _client({
        '/Items': {'Items': <Object>[], 'TotalRecordCount': 217},
      });

      final matches = await routed.client.searchFacet(SearchScopeKind.keywords, 'biography');

      final query = routed.requests.single.queryParameters;
      expect(routed.requests.single.path, '/Items');
      expect(query['Tags'], 'biography');
      expect(query['Recursive'], 'true');
      expect(query['IncludeItemTypes'], 'Movie,Series');
      expect(query['Limit'], '0');
      expect(query['userId'], 'user-1');
      expect(matches.single.name, 'biography');
      expect(matches.single.count, 217);
      expect(matches.single.facet, const MediaFacet(MediaFacetKind.tag, 'biography'));
    });

    test('keywords: no chip when nothing carries the tag', () async {
      final routed = _client({
        '/Items': {'Items': <Object>[], 'TotalRecordCount': 0},
      });

      expect(await routed.client.searchFacet(SearchScopeKind.keywords, 'biograph'), isEmpty);
      expect(routed.requests, hasLength(1));
    });

    test('year: a chip for a 4-digit year, with no request at all', () async {
      final routed = _client(const {});

      final year = await routed.client.searchFacet(SearchScopeKind.year, '2013');
      final notYear = await routed.client.searchFacet(SearchScopeKind.year, 'Blade Runner 2049');
      final tooOld = await routed.client.searchFacet(SearchScopeKind.year, '1500');

      expect(year.single.name, '2013');
      expect(year.single.facet, const MediaFacet(MediaFacetKind.year, '2013'));
      expect(notYear, isEmpty);
      expect(tooOld, isEmpty);
      expect(routed.requests, isEmpty);
    });

    test('titles and an empty query make no request', () async {
      final routed = _client(const {});

      expect(await routed.client.searchFacet(SearchScopeKind.titles, 'amanda'), isEmpty);
      expect(await routed.client.searchFacet(SearchScopeKind.actors, '   '), isEmpty);
      expect(routed.requests, isEmpty);
    });

    test('a failed facet request throws for the caller to treat as best-effort', () async {
      final routed = _client(const {});

      await expectLater(routed.client.searchFacet(SearchScopeKind.genres, 'drama'), throwsA(anything));
    });

    test('fetchFacetMediaPage filters films and shows by genre, studio, tag or year', () async {
      final routed = _client({
        '/Items': {
          'Items': [
            {'Id': 'movie-1', 'Name': 'Lovelace', 'Type': 'Movie'},
          ],
          'TotalRecordCount': 1,
        },
      });

      const cases = [
        (MediaFacet(MediaFacetKind.genre, 'g1'), 'GenreIds'),
        (MediaFacet(MediaFacetKind.studio, 's1'), 'StudioIds'),
        (MediaFacet(MediaFacetKind.tag, 'biography'), 'Tags'),
        (MediaFacet(MediaFacetKind.year, '2013'), 'Years'),
        (MediaFacet(MediaFacetKind.person, 'p1'), 'PersonIds'),
      ];
      for (final (facet, parameter) in cases) {
        routed.requests.clear();
        final page = await routed.client.fetchFacetMediaPage(facet, start: 0, size: 50);
        final query = routed.requests.single.queryParameters;
        expect(page.items.single.id, 'movie-1', reason: parameter);
        expect(query[parameter], facet.value, reason: parameter);
        expect(query['IncludeItemTypes'], 'Movie,Series');
        expect(query['Recursive'], 'true');
        expect(query['Limit'], '50');
      }
    });
  });

  group('SearchScopeKind', () {
    test('encode and decode round-trip, and an empty set stays a choice', () {
      expect(SearchScopeKind.encode(SearchScopeKind.defaults), 'titles,actors,keywords');
      expect(SearchScopeKind.decode('titles,actors,keywords'), SearchScopeKind.defaults);
      expect(SearchScopeKind.encode(const {}), '');
      expect(SearchScopeKind.decode(''), isEmpty);
      expect(SearchScopeKind.decode('year, genres,unknown'), {SearchScopeKind.genres, SearchScopeKind.year});
    });

    test('searchYearOf takes only a bare year from 1900 to 2100', () {
      expect(searchYearOf('1917'), 1917);
      expect(searchYearOf(' 2100 '), 2100);
      expect(searchYearOf('2101'), isNull);
      expect(searchYearOf('1899'), isNull);
      expect(searchYearOf('abc'), isNull);
      expect(searchYearOf('20133'), isNull);
    });
  });
}
