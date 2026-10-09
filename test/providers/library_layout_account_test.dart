import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/library_layout.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/jellyfin_client.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';
import '../test_helpers/prefs.dart';

// testJellyfinConnection's server is 'srv-1', so its layout id is 'srv1'.
const _own = 'srv1';

const _movies = MediaLibrary(id: 'movies', backend: MediaBackend.jellyfin, title: 'Movies', serverId: 'srv-1');
const _master = MediaLibrary(id: 'master', backend: MediaBackend.jellyfin, title: 'Master Class', serverId: 'srv-1');
const _dadsPlex = MediaLibrary(id: '1', backend: MediaBackend.plex, title: 'Dad Movies', serverId: 'plexmachine');

/// A PlezyFin server: reports PlezyFinVersion, serves the admin default, and
/// keeps the user's layout record in DisplayPreferences.
class _FakePlezyFin {
  String? storedLayout;
  Map<String, dynamic>? postedConfiguration;
  int layoutWrites = 0;

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/System/Info/Public') return jsonResponse({'Id': 'srv-1', 'PlezyFinVersion': '1'});
    if (path == '/PlezyFin/LibraryDefaults') {
      return jsonResponse({
        'v': 1,
        'order': ['$_own/movies', '$_own/master', '$_own/collections'],
        'state': {'$_own/movies': 'shown', '$_own/master': 'folded', '$_own/collections': 'folded'},
        'titles': {'$_own/movies': 'New Movies'},
      });
    }
    if (path == '/Users/user-1/Views') {
      // Collections is a boxsets view: Plezy does not list it as a library.
      return jsonResponse({
        'Items': [
          {'Id': 'movies', 'Name': 'Movies', 'CollectionType': 'movies'},
          {'Id': 'master', 'Name': 'Master Class', 'CollectionType': 'movies'},
          {'Id': 'collections', 'Name': 'Collections', 'CollectionType': 'boxsets'},
        ],
      });
    }
    if (path == '/DisplayPreferences/plezyfin-libraries') {
      expect(request.url.queryParameters['client'], 'plezyfin');
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        storedLayout = (body['CustomPrefs'] as Map<String, dynamic>)['layout'] as String;
        layoutWrites++;
        return http.Response('', 204);
      }
      return jsonResponse({
        'Id': 'plezyfin-libraries',
        'CustomPrefs': {if (storedLayout != null) 'layout': storedLayout},
      });
    }
    if (path == '/Users/Me') {
      return jsonResponse({
        'Configuration': {'OrderedViews': <String>[]},
      });
    }
    if (path == '/Users/user-1/Configuration') {
      postedConfiguration = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('', 204);
    }
    return http.Response('unexpected ${request.method} ${request.url}', 500);
  }
}

void main() {
  late AppDatabase db;

  setUp(() {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    JellyfinApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<(HiddenLibrariesProvider, _FakePlezyFin)> connect() async {
    final server = _FakePlezyFin();
    final JellyfinClient client = testJellyfinClient(handler: server.handle);
    addTearDown(client.close);
    final provider = HiddenLibrariesProvider();
    addTearDown(provider.dispose);
    await provider.ensureInitialized();
    provider.bind(
      clientFor: (serverId) => serverId.toString() == 'srv-1' ? client : null,
      onServerHiddenChanged: (_, _) {},
    );
    await client.fetchLibraries();
    provider.syncLibraries(const [_movies, _master, _dadsPlex]);
    await provider.refreshAccount();
    return (provider, server);
  }

  test('a first connection starts from the admin default and writes it once', () async {
    final (provider, server) = await connect();

    expect(provider.isAccountLayout, isTrue);
    expect(provider.stateOf(_movies), LibraryState.shown);
    expect(provider.stateOf(_master), LibraryState.folded);
    // Another server's library starts folded.
    expect(provider.stateOf(_dadsPlex), LibraryState.folded);

    expect(server.layoutWrites, 1);
    final stored = LibraryLayout.tryParse(server.storedLayout)!;
    // Every view is kept, Collections included, and the Favourites entry.
    expect(stored.known, {
      _own: ['movies', 'master', 'collections', 'favorites'],
      'plexmachine': ['1'],
    });
    expect(stored.state['plexmachine/1'], LibraryState.folded);
    expect(stored.state['$_own/collections'], LibraryState.folded);
    expect(stored.state['$_own/favorites'], LibraryState.shown);
    // Folded and off libraries of the PlezyFin server are mirrored for other apps.
    expect(server.postedConfiguration!['MyMediaExcludes'], ['master', 'collections']);
  });

  test('Favourites starts shown, after the libraries', () async {
    final (provider, _) = await connect();
    expect(provider.favoritesState, LibraryState.shown);
    expect(provider.favoritesIndexIn(const [_movies, _master, _dadsPlex]), 3);

    await provider.saveArrangement(
      [
        (library: _movies, state: LibraryState.shown),
        (library: _master, state: LibraryState.shown),
        (library: _dadsPlex, state: LibraryState.shown),
      ],
      favorites: (index: 1, state: LibraryState.folded),
    );
    expect(provider.favoritesState, LibraryState.folded);
    expect(provider.favoritesIndexIn(const [_movies, _master, _dadsPlex]), 1);
  });

  test('row titles come from the record, then the default', () async {
    final (provider, _) = await connect();
    expect(provider.rowTitleFor(serverId: 'srv-1', libraryId: 'movies'), 'New Movies');
    expect(provider.rowTitleFor(serverId: 'srv-1', libraryId: 'master'), isNull);
  });

  test('a change is written to the account and every list follows it', () async {
    final (provider, server) = await connect();

    await provider.saveArrangement([
      (library: _dadsPlex, state: LibraryState.shown),
      (library: _movies, state: LibraryState.shown),
      (library: _master, state: LibraryState.off),
    ]);

    expect(provider.stateOf(_dadsPlex), LibraryState.shown);
    expect(provider.offLibraryKeys, {_master.globalKey});
    expect(provider.foldedLibraryKeys, isEmpty);
    expect(provider.accountOrder, [_dadsPlex.globalKey, _movies.globalKey, _master.globalKey]);
    // Collections and Favourites, which this arrangement did not place, follow.
    expect(LibraryLayout.tryParse(server.storedLayout)!.order.take(3), [
      'plexmachine/1',
      '$_own/movies',
      '$_own/master',
    ]);
  });

  test('an existing record is followed without another write', () async {
    final server = _FakePlezyFin()
      ..storedLayout = jsonEncode({
        'v': 1,
        'rev': 7,
        'order': ['plexmachine/1', '$_own/movies', '$_own/master'],
        'state': {'plexmachine/1': 'shown', '$_own/master': 'off'},
        'known': {
          _own: ['movies', 'master', 'favorites'],
          'plexmachine': ['1'],
        },
      });
    final JellyfinClient client = testJellyfinClient(handler: server.handle);
    addTearDown(client.close);
    final provider = HiddenLibrariesProvider();
    addTearDown(provider.dispose);
    await provider.ensureInitialized();
    provider.bind(clientFor: (serverId) => client, onServerHiddenChanged: (_, _) {});
    provider.syncLibraries(const [_movies, _master, _dadsPlex]);
    await provider.refreshAccount();

    expect(server.layoutWrites, 0);
    expect(provider.stateOf(_master), LibraryState.off);
    expect(provider.stateOf(_movies), LibraryState.shown);
    expect(provider.accountOrder, [_dadsPlex.globalKey, _movies.globalKey, _master.globalKey]);
  });
}
