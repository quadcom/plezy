import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/home_layout.dart';
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

/// A PlezyFin server with an admin default that may carry home sections, and
/// the user's layout record in DisplayPreferences.
class _FakePlezyFin {
  _FakePlezyFin({this.defaultHome, this.storedLayout});

  final Map<String, dynamic>? defaultHome;
  String? storedLayout;

  Map<String, dynamic> get stored => jsonDecode(storedLayout!) as Map<String, dynamic>;

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/System/Info/Public') return jsonResponse({'Id': 'srv-1', 'PlezyFinVersion': '1'});
    if (path == '/PlezyFin/LibraryDefaults') {
      return jsonResponse({
        'v': 1,
        'order': ['$_own/movies', '$_own/master'],
        'state': {'$_own/movies': 'shown', '$_own/master': 'shown'},
        'home': ?defaultHome,
      });
    }
    if (path == '/Users/user-1/Views') {
      return jsonResponse({
        'Items': [
          {'Id': 'movies', 'Name': 'Movies', 'CollectionType': 'movies'},
          {'Id': 'master', 'Name': 'Master Class', 'CollectionType': 'movies'},
        ],
      });
    }
    if (path == '/DisplayPreferences/plezyfin-libraries') {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        storedLayout = (body['CustomPrefs'] as Map<String, dynamic>)['layout'] as String;
        return http.Response('', 204);
      }
      return jsonResponse({
        'Id': 'plezyfin-libraries',
        'CustomPrefs': {'layout': ?storedLayout},
      });
    }
    if (path == '/Users/Me') {
      return jsonResponse({
        'Configuration': {'OrderedViews': <String>[]},
      });
    }
    if (path == '/Users/user-1/Configuration') return http.Response('', 204);
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

  Future<HiddenLibrariesProvider> connect(_FakePlezyFin server) async {
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
    provider.syncLibraries(const [_movies, _master]);
    await provider.refreshAccount();
    return provider;
  }

  test('with no home of its own, the account follows the default', () async {
    final server = _FakePlezyFin(
      defaultHome: {
        'order': ['libraries', 'resume'],
        'off': ['hero'],
        'cards': {'$_own/continuewatching': 'poster', '$_own/movies': 'thumb'},
      },
    );
    final provider = await connect(server);

    // Sections the default leaves out follow, in the built-in order.
    expect(provider.home.sections, [HomeLayout.libraries, HomeLayout.resume, HomeLayout.hero, HomeLayout.nextUp]);
    expect(provider.home.isOn(HomeLayout.hero), isFalse);
    expect(provider.cardStyleFor(provider.sectionCardKey(HomeLayout.resume)), HomeCardStyle.poster);
    // Rows neither sets fall back to the built-in style the web shows too.
    expect(provider.cardStyleFor(provider.sectionCardKey(HomeLayout.nextUp)), HomeCardStyle.thumb);
    expect(provider.libraryCardStyle(_movies), HomeCardStyle.thumb);
    expect(provider.libraryCardStyle(_master), HomeCardStyle.poster);
  });

  test("a card choice saves the user's own home; the default's other cards still apply", () async {
    final server = _FakePlezyFin(
      defaultHome: {
        'order': ['libraries', 'resume', 'nextup', 'hero'],
        'off': ['hero'],
        'cards': {'$_own/continuewatching': 'poster'},
      },
    );
    final provider = await connect(server);

    await provider.setCardStyle(provider.sectionCardKey(HomeLayout.nextUp), HomeCardStyle.thumb);

    final home = server.stored['home'] as Map<String, dynamic>;
    expect(home['order'], ['libraries', 'resume', 'nextup', 'hero']);
    expect(home['off'], ['hero']);
    expect(home['cards'], {'$_own/nextup': 'thumb'});
    expect(provider.cardStyleFor(provider.sectionCardKey(HomeLayout.nextUp)), HomeCardStyle.thumb);
    expect(provider.cardStyleFor(provider.sectionCardKey(HomeLayout.resume)), HomeCardStyle.poster);
  });

  test('home and layout writes keep each other and fields Plezy does not know', () async {
    final server = _FakePlezyFin(
      storedLayout: jsonEncode({
        'v': 1,
        'rev': 4,
        'order': ['$_own/continuewatching', '$_own/nextup', '$_own/movies', '$_own/master', '$_own/favorites'],
        'state': {'$_own/master': 'folded'},
        'known': {
          _own: ['movies', 'master', 'continuewatching', 'nextup', 'favorites'],
        },
        'home': {
          'order': ['resume', 'futureRow', 'nextup'],
          'off': <String>[],
          'cards': {'futureRow': 'thumb'},
          'futureHomeField': 1,
        },
        'futureField': {'kept': true},
      }),
    );
    final provider = await connect(server);

    await provider.setHomeSectionOn(HomeLayout.nextUp, on: false);
    var stored = server.stored;
    expect(stored['rev'], 5);
    expect(stored['state'], {'$_own/master': 'folded'});
    expect(stored['futureField'], {'kept': true});
    expect(stored['home'], {
      'order': ['resume', 'futureRow', 'nextup'],
      'off': ['nextup'],
      'cards': {'futureRow': 'thumb'},
      'futureHomeField': 1,
    });

    await provider.setHomeSections([HomeLayout.nextUp, HomeLayout.resume, HomeLayout.hero, HomeLayout.libraries]);
    expect((server.stored['home'] as Map<String, dynamic>)['order'], [
      'nextup',
      'futureRow',
      'resume',
      'hero',
      'libraries',
    ]);

    await provider.setLibraryState(_master, LibraryState.shown);
    stored = server.stored;
    expect(stored['state'], containsPair('$_own/master', 'shown'));
    expect(stored['futureField'], {'kept': true});
    expect((stored['home'] as Map<String, dynamic>)['off'], ['nextup']);
  });

  test('without an account the home sections stay on this device', () async {
    final provider = HiddenLibrariesProvider();
    addTearDown(provider.dispose);
    await provider.ensureInitialized();
    provider.syncLibraries(const [_movies]);

    expect(provider.home.sections, HomeLayout.builtInOrder);
    await provider.setHomeSectionOn(HomeLayout.nextUp, on: false);
    await provider.setLibraryCardStyle(_movies, HomeCardStyle.thumb);

    final reloaded = HiddenLibrariesProvider();
    addTearDown(reloaded.dispose);
    await reloaded.ensureInitialized();
    reloaded.syncLibraries(const [_movies]);
    expect(reloaded.home.isOn(HomeLayout.nextUp), isFalse);
    expect(reloaded.libraryCardStyle(_movies), HomeCardStyle.thumb);
  });

  group('home rows apart from the menu (PLAN_SHA_13)', () {
    String layoutWith({Map<String, String> state = const {}, Map<String, dynamic>? home}) => jsonEncode({
      'v': 1,
      'rev': 1,
      'order': ['$_own/continuewatching', '$_own/nextup', '$_own/movies', '$_own/master', '$_own/favorites'],
      'state': state,
      'known': {
        _own: ['movies', 'master', 'continuewatching', 'nextup', 'favorites'],
      },
      'home': ?home,
    });

    test('without rows the old rule holds: Shown on in menu order, folded after and off', () async {
      final server = _FakePlezyFin(storedLayout: layoutWith(state: {'$_own/master': 'folded'}));
      final provider = await connect(server);

      expect(provider.homeRowsInForce, [
        (key: '$_own/continuewatching', on: true),
        (key: '$_own/nextup', on: true),
        (key: '$_own/movies', on: true),
        (key: '$_own/master', on: false),
      ]);
      expect(provider.homeHiddenLibraryKeys, {_master.globalKey});
      expect(provider.homeRank('$_own/movies'), 2);
      expect(provider.homeRank('$_own/master'), isNull);
    });

    test('rows set the order and switches; a folded entry keeps its row, Not shown has none', () async {
      final server = _FakePlezyFin(
        storedLayout: layoutWith(
          state: {'$_own/master': 'folded', '$_own/continuewatching': 'folded', '$_own/nextup': 'off'},
          home: {
            'order': HomeLayout.builtInOrder,
            'off': <String>[],
            'rows': {
              'order': ['$_own/master', '$_own/nextup', '$_own/continuewatching'],
              'off': ['$_own/continuewatching'],
            },
          },
        ),
      );
      final provider = await connect(server);

      // Movies is in neither list: on, after the listed rows.
      expect(provider.homeRowsInForce, [
        (key: '$_own/master', on: true),
        (key: '$_own/continuewatching', on: false),
        (key: '$_own/movies', on: true),
      ]);
      expect(provider.homeHiddenLibraryKeys, isEmpty);
      expect(provider.homeRank('$_own/master'), 0);
      expect(provider.homeRank('$_own/movies'), 1);
      expect(provider.homeRank('$_own/continuewatching'), isNull);
      expect(provider.homeRank('$_own/nextup'), isNull);
    });

    test('with no rows of its own the account follows the rows of the default', () async {
      final server = _FakePlezyFin(
        defaultHome: {
          'rows': {
            'order': ['$_own/movies', '$_own/continuewatching'],
            'off': ['$_own/nextup'],
          },
        },
        storedLayout: layoutWith(
          home: {
            'order': HomeLayout.builtInOrder,
            'off': ['hero'],
          },
        ),
      );
      final provider = await connect(server);

      expect(provider.homeRowsInForce, [
        (key: '$_own/movies', on: true),
        (key: '$_own/continuewatching', on: true),
        (key: '$_own/nextup', on: false),
        (key: '$_own/master', on: true),
      ]);
    });

    test('the first save writes every entry, so only the change shows', () async {
      final server = _FakePlezyFin(storedLayout: layoutWith(state: {'$_own/master': 'folded'}));
      final provider = await connect(server);

      final rows = List.of(provider.homeRowsInForce!);
      rows[3] = (key: '$_own/master', on: true);
      await provider.saveHomeRows(rows);

      final home = server.stored['home'] as Map<String, dynamic>;
      expect(home['rows'], {
        'order': ['$_own/continuewatching', '$_own/nextup', '$_own/movies', '$_own/master'],
        'off': <String>[],
      });
      expect(server.stored['state'], {'$_own/master': 'folded'});
      expect(provider.homeHiddenLibraryKeys, isEmpty);
    });

    test('a Not shown entry keeps its place and switch while the rest move', () async {
      final server = _FakePlezyFin(
        storedLayout: layoutWith(
          state: {'$_own/master': 'off'},
          home: {
            'order': HomeLayout.builtInOrder,
            'off': <String>[],
            'rows': {
              'order': ['$_own/continuewatching', '$_own/master', '$_own/nextup', '$_own/movies'],
              'off': ['$_own/master'],
            },
          },
        ),
      );
      final provider = await connect(server);

      // Move Movies to the top.
      final rows = List.of(provider.homeRowsInForce!);
      expect(rows.map((r) => r.key), ['$_own/continuewatching', '$_own/nextup', '$_own/movies']);
      rows.insert(0, rows.removeAt(2));
      await provider.saveHomeRows(rows);

      final home = server.stored['home'] as Map<String, dynamic>;
      expect(home['rows'], {
        'order': ['$_own/movies', '$_own/master', '$_own/continuewatching', '$_own/nextup'],
        'off': ['$_own/master'],
      });
      expect(home['order'], HomeLayout.builtInOrder);
    });
  });
}
