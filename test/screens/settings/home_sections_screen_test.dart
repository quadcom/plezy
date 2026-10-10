import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/library_layout.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/screens/settings/home_sections_screen.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/jellyfin_client.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/http_fixtures.dart';
import '../../test_helpers/prefs.dart';

// testJellyfinConnection's server is 'srv-1', so its layout id is 'srv1'.
const _own = 'srv1';

const _movies = MediaLibrary(
  id: 'movies',
  backend: MediaBackend.jellyfin,
  title: 'Movies',
  kind: MediaKind.movie,
  serverId: 'srv-1',
);
const _tv = MediaLibrary(
  id: 'tv',
  backend: MediaBackend.jellyfin,
  title: 'TV',
  kind: MediaKind.show,
  serverId: 'srv-1',
);

/// A PlezyFin server keeping the user's layout record.
class _FakePlezyFin {
  String? storedLayout = jsonEncode({
    'v': 1,
    'rev': 1,
    'order': ['$_own/continuewatching', '$_own/nextup', '$_own/movies', '$_own/tv', '$_own/favorites'],
    'state': {'$_own/tv': 'folded'},
    'known': {
      _own: ['movies', 'tv', 'continuewatching', 'nextup', 'favorites'],
    },
  });

  Map<String, dynamic> get home => (jsonDecode(storedLayout!) as Map<String, dynamic>)['home'] as Map<String, dynamic>;

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/System/Info/Public') return jsonResponse({'Id': 'srv-1', 'PlezyFinVersion': '1'});
    if (path == '/PlezyFin/LibraryDefaults') return jsonResponse({'v': 1});
    if (path == '/Users/user-1/Views') {
      return jsonResponse({
        'Items': [
          {'Id': 'movies', 'Name': 'Movies', 'CollectionType': 'movies'},
          {'Id': 'tv', 'Name': 'TV', 'CollectionType': 'tvshows'},
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

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    // Ready before the widget test's fake clock starts.
    await StorageService.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    JellyfinApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<_FakePlezyFin> pumpScreen(WidgetTester tester) async {
    final server = _FakePlezyFin();
    final layout = HiddenLibrariesProvider();
    final libraries = LibrariesProvider();
    addTearDown(layout.dispose);
    addTearDown(libraries.dispose);
    final JellyfinClient client = testJellyfinClient(handler: server.handle);
    addTearDown(client.close);
    await layout.ensureInitialized();
    await libraries.updateLibraryOrder(const [_movies, _tv]);
    // The account without a server round trip; saves still reach [server].
    layout.syncLibraries(const [_movies, _tv]);
    layout.debugSetAccount(client, LibraryLayout.tryParse(server.storedLayout)!);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: layout),
          ],
          child: MaterialApp(theme: monoTheme(dark: true), home: const HomeSectionsScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return server;
  }

  Finder rowOf(String title) => find.byKey(
    ValueKey(switch (title) {
      'Continue Watching' => '$_own/continuewatching',
      'Next Up' => '$_own/nextup',
      _ => '$_own/${title.toLowerCase()}',
    }),
  );

  Future<void> settleSave(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('every home row has its card choice and a switch; episode rows offer both posters', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Next Up'), findsOneWidget);
    // A folded library keeps its home row in the list, switched off for now.
    expect(find.text('TV'), findsOneWidget);
    // The banner, the two device switches and four rows.
    expect(find.byType(Switch), findsNWidgets(7));

    expect(find.descendant(of: rowOf('Movies'), matching: find.text('Poster')), findsOneWidget);
    expect(find.descendant(of: rowOf('Movies'), matching: find.text('Season poster')), findsNothing);
    expect(find.descendant(of: rowOf('TV'), matching: find.text('Season poster')), findsOneWidget);
    expect(find.descendant(of: rowOf('Next Up'), matching: find.text('Show poster')), findsOneWidget);
  });

  testWidgets('a row switch and a card choice save with the account', (tester) async {
    final server = await pumpScreen(tester);

    await tester.tap(find.descendant(of: rowOf('Movies'), matching: find.byType(Switch)));
    await settleSave(tester);
    expect(server.home['rows'], {
      'order': ['$_own/continuewatching', '$_own/nextup', '$_own/movies', '$_own/tv'],
      'off': ['$_own/movies', '$_own/tv'],
    });

    await tester.tap(find.descendant(of: rowOf('Next Up'), matching: find.text('Season poster')));
    await settleSave(tester);
    expect(server.home['cards'], {'$_own/nextup': 'season'});
  });
}
