import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_layout.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/focus/dpad_navigator.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/account_preferences.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/search_scope.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/mixins/refreshable.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/voice_search_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:plezy/widgets/backend_badge.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:plezy/widgets/focusable_tab_chip.dart';
import 'package:plezy/widgets/loading_indicator_box.dart';
import 'package:plezy/widgets/search_scope_panel.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

/// The library behind 'Movie 2' (`server_1:2`). Only Not shown takes a
/// library's items out of search; a folded one stays searchable.
const _libraryTwo = MediaLibrary(id: '2', backend: MediaBackend.plex, title: 'Library 2', serverId: 'server_1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() async {
    _resetGlobalTestState();
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    // HiddenLibrariesProvider resolves this lazily; the real SharedPreferences
    // round trip never completes inside a testWidgets fake-async zone, so warm
    // the singleton here.
    await StorageService.getInstance();
  });

  tearDown(_resetGlobalTestState);

  testWidgets('stale callbacks are no-ops after SearchScreen is disposed', (tester) async {
    final key = GlobalKey<State<SearchScreen>>();
    final item = testMediaItem(
      id: 'movie_1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Movie 1',
      serverId: 'server_1',
      serverName: 'Server',
    );

    final hiddenLibraries = HiddenLibrariesProvider();
    addTearDown(hiddenLibraries.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<HiddenLibrariesProvider>.value(
          value: hiddenLibraries,
          child: MaterialApp(home: SearchScreen(key: key)),
        ),
      ),
    );

    final state = key.currentState!;
    final searchInput = state as SearchInputFocusable;
    _searchController(tester).text = 'movie';
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(() => (state as Refreshable).refresh(), returnsNormally);
    expect(() => (state as dynamic).updateItem(item), returnsNormally);
    expect(() => (state as FullRefreshable).fullRefresh(), returnsNormally);
    expect(() => searchInput.submitSearchQuery('new movie'), returnsNormally);
    expect(() => (state as FocusableTab).focusActiveTabIfReady(), returnsNormally);
    expect(tester.takeException(), isNull);
  });

  // TV search uses Plezy's own keyboard, opened as soon as the field is
  // highlighted (Adrian, 2026-10-31), never the Android one.
  testWidgets("TV Search opens Plezy's keyboard and its Search key runs the query at once", (tester) async {
    final (client, _) = await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    _searchController(tester).text = 'movie';
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.queries, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(client.queries, ['movie']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchFirstResult');
  });

  testWidgets('companion-remote submitSearchQuery closes the keyboard and focuses results', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(client.queries, ['movie']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchFirstResult');

    // Selection updates must not re-arm the debounce into a second fetch.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(client.queries, ['movie']);

    // Re-submitting already-displayed results leaves result focus stable.
    final searchInput = key.currentState! as SearchInputFocusable;
    searchInput.submitSearchQuery('movie');
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchFirstResult');
    expect(client.queries, ['movie']);

    // Back up to the field (D-pad up from the first result): highlighting it
    // opens Plezy's keyboard again.
    searchInput.focusSearchInput();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('companion-remote query with no results leaves the keyboard closed', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester, items: []);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('zzz');
    await tester.pumpAndSettle();

    expect(client.queries, ['zzz']);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchInput');

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed companion-remote query leaves the keyboard closed', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester, registerClient: false);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(client.queries, isEmpty);
    // The screen's own error state; the error message bar carries the same
    // icon, so leave that one out.
    expect(
      find
          .byIcon(Symbols.error_rounded)
          .evaluate()
          .where((element) => element.findAncestorWidgetOfExactType<SnackBar>() == null),
      hasLength(1),
    );
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchInput');

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Adrian, 2026-10-31: "The search keyboard should only be displayed when the
  // input is in focus". Opening Search lands on the mic with no keyboard; the
  // keyboard opens only once the field itself is highlighted.
  testWidgets('TV Search with a mic opens on the mic without the keyboard', (tester) async {
    VoiceSearchService.debugSetAvailable(true);
    addTearDown(() => VoiceSearchService.debugSetAvailable(null));
    await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchVoice');
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('partial server failure shows available results and a warning', (tester) async {
    final failedClient = _FakeMediaServerClient(
      serverIdValue: 'server_2',
      serverNameValue: 'Offline Server',
      items: const [],
      searchError: MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'refused'),
    );
    final (client, key) = await _pumpTvSearchScreen(tester, additionalClients: [failedClient]);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(client.queries, ['movie']);
    expect(failedClient.queries, ['movie']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.text(t.messages.searchPartialResults), findsOneWidget);
  });

  testWidgets('results from a Not shown library never reach the list', (tester) async {
    final hiddenLibraries = HiddenLibrariesProvider();
    addTearDown(hiddenLibraries.dispose);
    await hiddenLibraries.ensureInitialized();
    await hiddenLibraries.setLibraryState(_libraryTwo, LibraryState.off);

    final (client, key) = await _pumpTvSearchScreen(
      tester,
      hiddenLibraries: hiddenLibraries,
      items: _twoLibraryMovies(),
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    // One request per user action: hydrating the hidden keys must not race the
    // first query into running twice.
    expect(client.queries, ['movie']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.text('Movie 2'), findsNothing);
  });

  testWidgets('setting a library to Not shown while results are shown re-runs the query', (tester) async {
    final hiddenLibraries = HiddenLibrariesProvider();
    addTearDown(hiddenLibraries.dispose);

    final (client, key) = await _pumpTvSearchScreen(
      tester,
      hiddenLibraries: hiddenLibraries,
      items: _twoLibraryMovies(),
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();
    expect(client.queries, ['movie']);
    expect(find.text('Movie 2'), findsOneWidget);

    await hiddenLibraries.setLibraryState(_libraryTwo, LibraryState.off);
    await tester.pumpAndSettle();

    expect(client.queries, ['movie', 'movie']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.text('Movie 2'), findsNothing);
  });

  testWidgets('all server failures render the failed state instead of empty results', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(
      tester,
      searchError: MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'refused'),
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(client.queries, ['movie']);
    expect(find.text(t.explore.searchFailed), findsOneWidget);
    expect(find.text(t.errors.searchUnavailable), findsOneWidget);
    expect(find.text(t.messages.noResultsFound), findsNothing);
  });

  testWidgets('editing cancels the stale server request before the next debounce', (tester) async {
    final (client, _) = await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    client.searchGate = gate;

    _searchController(tester).text = 'first';
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(client.queries, ['first']);
    final staleAbort = client.lastSearchAbort;
    expect(staleAbort, isNotNull);
    expect(staleAbort!.isAborted, isFalse);

    _searchController(tester).text = 'second';
    await tester.pump();

    expect(staleAbort.isAborted, isTrue);
    expect(client.queries, ['first']);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(client.queries, ['first', 'second']);
    expect(find.text(t.explore.searchFailed), findsNothing);
  });

  testWidgets('all-server cancellation preserves prior results without an error', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();
    expect(find.text('Movie 1'), findsOneWidget);

    client.searchError = MediaServerHttpException(
      type: MediaServerHttpErrorType.cancelled,
      message: 'connection replaced',
    );
    (key.currentState! as SearchInputFocusable).submitSearchQuery('second');
    await tester.pumpAndSettle();

    expect(client.queries, ['movie', 'second']);
    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.text(t.explore.searchFailed), findsNothing);
    expect(find.text(t.errors.searchUnavailable), findsNothing);
  });

  testWidgets('card refresh stays server-qualified without restarting search', (tester) async {
    final serverOneItem = testMediaItem(
      id: 'shared-id',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Shared',
      serverId: 'server_1',
      serverName: 'Server One',
    );
    final serverTwoItem = testMediaItem(
      id: 'shared-id',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Shared Alternate',
      serverId: 'server_2',
      serverName: 'Server Two',
    );
    final serverTwoClient = _FakeMediaServerClient(
      serverIdValue: 'server_2',
      serverNameValue: 'Server Two',
      items: [serverTwoItem],
    );
    final (serverOneClient, key) = await _pumpTvSearchScreen(
      tester,
      items: [serverOneItem],
      additionalClients: [serverTwoClient],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('shared');
    await tester.pumpAndSettle();

    expect(serverOneClient.queries, ['shared']);
    expect(serverTwoClient.queries, ['shared']);
    expect(find.byType(FocusableMediaCard), findsNWidgets(2));

    // The exact-title match is the first, focused card. Keep the fetch open
    // to observe the screen while the item-only refresh is in flight.
    final sourceFinder = find.byKey(Key(serverOneItem.globalKey));
    final untouchedFinder = find.byKey(Key(serverTwoItem.globalKey));
    final sourceCardState = tester.state(sourceFinder);
    final untouchedCardState = tester.state(untouchedFinder);
    final focusedNode = FocusManager.instance.primaryFocus;
    expect(focusedNode?.debugLabel, 'SearchFirstResult');

    final fetchGate = Completer<void>();
    final updated = serverOneItem.copyWith(title: 'Refreshed on Server One');
    serverOneClient
      ..itemResult = updated
      ..fetchGate = fetchGate;

    tester.widget<FocusableMediaCard>(sourceFinder).onRefresh!(serverOneItem);
    await tester.pump();

    // This used to fan the bare id out to every server and drive the whole
    // screen through another search/loading pass.
    expect(serverOneClient.fetchedItemIds, ['shared-id']);
    expect(serverTwoClient.fetchedItemIds, isEmpty);
    expect(serverOneClient.queries, ['shared']);
    expect(serverTwoClient.queries, ['shared']);
    expect(find.byWidget(LoadingIndicatorBox.sliver), findsNothing);
    expect(find.byType(FocusableMediaCard), findsNWidgets(2));
    expect(tester.state(sourceFinder), same(sourceCardState));
    expect(tester.state(untouchedFinder), same(untouchedCardState));
    expect(FocusManager.instance.primaryFocus, same(focusedNode));

    fetchGate.complete();
    await tester.pumpAndSettle();

    // The refresh lands as a merged copy (mergeFetchedMediaItem keeps the
    // search row's library/server context, #1970), not the fetched instance.
    final refreshedItem = tester.widget<FocusableMediaCard>(sourceFinder).item as MediaItem;
    expect(refreshedItem.title, 'Refreshed on Server One');
    expect(refreshedItem.serverId, 'server_1');
    expect(refreshedItem.serverName, 'Server One');
    expect(tester.widget<FocusableMediaCard>(untouchedFinder).item, same(serverTwoItem));
    expect(tester.state(sourceFinder), same(sourceCardState));
    expect(tester.state(untouchedFinder), same(untouchedCardState));
    expect(FocusManager.instance.primaryFocus, same(focusedNode));
    expect(serverOneClient.queries, ['shared']);
    expect(serverTwoClient.queries, ['shared']);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search results sit under a heading per library, in library order', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(
      tester,
      items: [
        testMediaItem(
          id: 'movie_1',
          backend: MediaBackend.plex,
          kind: MediaKind.movie,
          title: 'Movie 1',
          serverId: 'server_1',
          serverName: 'Server',
          libraryId: '1',
          libraryTitle: 'Movies',
        ),
        testMediaItem(
          id: 'movie_2',
          backend: MediaBackend.plex,
          kind: MediaKind.movie,
          title: 'Movie 2',
          serverId: 'server_1',
          serverName: 'Server',
          libraryId: '2',
          libraryTitle: 'Anime',
        ),
      ],
      libraries: [_library('1', 'Movies'), _library('2', 'Anime')],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(client.queries, ['movie']);
    // The library name moved from each card into its section's heading.
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Anime'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Movies')).dy, lessThan(tester.getTopLeft(find.text('Anime')).dy));
    expect(find.text('Server • Movies'), findsNothing);
  });

  testWidgets('library name back-fills from loaded libraries when the row only carries an id', (tester) async {
    // Plex search rows name their section only by librarySectionKey; the
    // title must resolve against the loaded libraries without a request.
    final (_, key) = await _pumpTvSearchScreen(
      tester,
      items: _twoLibraryMovies(),
      libraries: [_library('1', 'Movies'), _library('2', 'Anime')],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Anime'), findsOneWidget);
  });

  testWidgets('no library label on a single-library server', (tester) async {
    final (_, key) = await _pumpTvSearchScreen(
      tester,
      items: [
        testMediaItem(
          id: 'movie_1',
          backend: MediaBackend.plex,
          kind: MediaKind.movie,
          title: 'Movie 1',
          serverId: 'server_1',
          serverName: 'Server',
          libraryId: '1',
          libraryTitle: 'Movies',
        ),
      ],
      libraries: [_library('1', 'Movies')],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    expect(find.text('Movie 1'), findsOneWidget);
    expect(find.text('Server • Movies'), findsNothing);
    expect(find.byType(BackendBadge), findsNothing);
  });

  testWidgets('card refresh keeps the library stamp', (tester) async {
    final stamped = testMediaItem(
      id: 'movie_1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Movie 1',
      serverId: 'server_1',
      serverName: 'Server',
      libraryId: '1',
      libraryTitle: 'Movies',
    );
    final (client, key) = await _pumpTvSearchScreen(
      tester,
      items: [stamped],
      libraries: [_library('1', 'Movies'), _library('2', 'Anime')],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);

    // A fresh fetchItem carries no library context (a Jellyfin /Items/{id}
    // response has none); the merge must keep the stamp search applied.
    client.itemResult = testMediaItem(
      id: 'movie_1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Movie 1 (Refreshed)',
      serverId: 'server_1',
      serverName: 'Server',
    );
    final cardFinder = find.byKey(Key(stamped.globalKey));
    tester.widget<FocusableMediaCard>(cardFinder).onRefresh!(stamped);
    await tester.pumpAndSettle();

    expect(client.fetchedItemIds, ['movie_1']);
    expect(find.text('Movie 1 (Refreshed)'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    final refreshed = tester.widget<FocusableMediaCard>(cardFinder).item as MediaItem;
    expect(refreshed.libraryId, '1');
    expect(refreshed.libraryTitle, 'Movies');
  });

  testWidgets('kind chips appear only when results span multiple kinds', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
    await tester.pumpAndSettle();

    // Single-kind results have nothing to filter.
    expect(find.byType(FocusableTabChip), findsNothing);

    client.items
      ..clear()
      ..addAll(_mixedKindItems());
    (key.currentState! as SearchInputFocusable).submitSearchQuery('paw');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FocusableTabChip, t.libraries.groupings.all), findsOneWidget);
    expect(find.widgetWithText(FocusableTabChip, t.libraries.groupings.movies), findsOneWidget);
    expect(find.widgetWithText(FocusableTabChip, t.libraries.groupings.episodes), findsOneWidget);
    expect(find.widgetWithText(FocusableTabChip, t.libraries.groupings.tracks), findsOneWidget);
  });

  testWidgets('selecting a kind chip filters the list and All restores it', (tester) async {
    final (_, key) = await _pumpTvSearchScreen(tester, items: _mixedKindItems());
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('paw');
    await tester.pumpAndSettle();
    expect(find.text('Paw Patrol: The Movie'), findsOneWidget);
    expect(find.text('Paw Patrol Rescue'), findsOneWidget);

    await tester.tap(find.widgetWithText(FocusableTabChip, t.libraries.groupings.movies));
    await tester.pumpAndSettle();
    expect(find.text('Paw Patrol: The Movie'), findsOneWidget);
    expect(find.text('Paw Patrol Rescue'), findsNothing);
    expect(find.text('Paw Patrol Theme'), findsNothing);
    expect(find.byType(FocusableMediaCard), findsOneWidget);

    await tester.tap(find.widgetWithText(FocusableTabChip, t.libraries.groupings.all));
    await tester.pumpAndSettle();
    expect(find.byType(FocusableMediaCard), findsNWidgets(3));
  });

  testWidgets('a kind ranked out of the trimmed All view keeps its chip and full results', (tester) async {
    // 100 exact-title episodes fill the ranked display budget; the weakly
    // titled track only survives in the candidate pool behind it.
    final items = [
      for (var i = 0; i < 100; i++)
        testMediaItem(
          id: 'episode_$i',
          backend: MediaBackend.plex,
          kind: MediaKind.episode,
          title: 'Paw Patrol',
          serverId: 'server_1',
          serverName: 'Server',
        ),
      testMediaItem(
        id: 'track_1',
        backend: MediaBackend.plex,
        kind: MediaKind.track,
        title: 'Underwater Instrumental Extended Version (paw remix)',
        serverId: 'server_1',
        serverName: 'Server',
      ),
    ];
    final (_, key) = await _pumpTvSearchScreen(tester, items: items);
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('Paw Patrol');
    await tester.pumpAndSettle();

    // The track lost the ranked top-100, but its chip derives from the
    // pre-rank pool, so it must still be offered and show its rows.
    final tracksChip = find.widgetWithText(FocusableTabChip, t.libraries.groupings.tracks);
    expect(tracksChip, findsOneWidget);

    await tester.tap(tracksChip);
    await tester.pumpAndSettle();
    expect(find.byType(FocusableMediaCard), findsOneWidget);
    expect(find.text('Underwater Instrumental Extended Version (paw remix)'), findsOneWidget);
  });

  testWidgets('the filter falls back to All when its kind vanishes from a refined query', (tester) async {
    final (client, key) = await _pumpTvSearchScreen(tester, items: _mixedKindItems());
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('paw');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FocusableTabChip, t.libraries.groupings.episodes));
    await tester.pumpAndSettle();
    expect(find.byType(FocusableMediaCard), findsOneWidget);

    client.items.removeWhere((item) => item.kind == MediaKind.episode);
    (key.currentState! as SearchInputFocusable).submitSearchQuery('paw patrol');
    await tester.pumpAndSettle();

    // Episodes are gone: the chip disappears and every remaining row shows.
    expect(find.widgetWithText(FocusableTabChip, t.libraries.groupings.episodes), findsNothing);
    expect(find.byType(FocusableMediaCard), findsNWidgets(2));
  });

  testWidgets('D-pad walks first result to chips and back, and Select applies the filter', (tester) async {
    final (_, key) = await _pumpTvSearchScreen(tester, items: _mixedKindItems());
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('paw');
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchFirstResult');

    // Up from the first result lands on the active (All) chip.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchKindChipAll');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchKindChip_movie');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(FocusableMediaCard), findsOneWidget);
    expect(find.text('Paw Patrol Rescue'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchFirstResult');

    // Up returns to the selected chip, not All.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchKindChip_movie');
  });
  // local/plans/search-actors.md: the "Search in" ticks.
  group('Search in', () {
    test('the hint names the ticked kinds', () {
      expect(searchScopeHint(SearchScopeKind.defaults), 'Search titles, actors and keywords');
      expect(searchScopeHint({SearchScopeKind.titles}), 'Search titles');
      expect(searchScopeHint({SearchScopeKind.titles, SearchScopeKind.year}), 'Search titles and years');
      expect(searchScopeHint(const {}), 'Tick at least one thing to search');
    });

    testWidgets('the field and the empty screen say what is searched, and the badge counts the ticks', (tester) async {
      await _pumpTvSearchScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text(_defaultHint()), findsWidgets);
      expect(_badge('3'), findsOneWidget);
    });

    testWidgets('a Plex-only server is asked for titles alone', (tester) async {
      final (client, key) = await _pumpTvSearchScreen(tester);
      await tester.pumpAndSettle();

      (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
      await tester.pumpAndSettle();

      expect(client.queries, ['movie']);
      expect(client.facetQueries, isEmpty);
    });

    testWidgets('ticked kinds add one ask each; unticked kinds are never asked', (tester) async {
      final (client, key) = await _pumpTvSearchScreen(
        tester,
        items: const [],
        facets: {
          SearchScopeKind.actors: [_person('p1', 'Amanda Seyfried'), _person('p2', 'Amanda Peet')],
        },
      );
      await tester.pumpAndSettle();

      (key.currentState! as SearchInputFocusable).submitSearchQuery('amanda');
      await tester.pumpAndSettle();

      expect(client.queries, ['amanda']);
      expect(client.facetQueries, unorderedEquals([SearchScopeKind.actors, SearchScopeKind.keywords]));
      // No titles matched, but people did: the rows show instead of "No results".
      expect(find.text(t.messages.noResultsFound), findsNothing);
      expect(find.text(t.search.rows.people), findsOneWidget);
      expect(find.text('Amanda Seyfried'), findsOneWidget);
      expect(find.text('AS'), findsOneWidget, reason: 'initials stand in for a missing photo');
      expect(find.text(t.search.rows.noMatch(kind: t.search.rows.noMatchKeywords, query: 'amanda')), findsOneWidget);
      expect(find.text(t.search.rows.genres), findsNothing, reason: 'genres are not ticked');
    });

    testWidgets('nothing at all matched keeps the No results screen', (tester) async {
      final (_, key) = await _pumpTvSearchScreen(tester, items: const [], facets: const {});
      await tester.pumpAndSettle();

      (key.currentState! as SearchInputFocusable).submitSearchQuery('zzz');
      await tester.pumpAndSettle();

      expect(find.text(t.messages.noResultsFound), findsOneWidget);
    });

    testWidgets('unticking Titles skips the title search and re-runs the query', (tester) async {
      final (client, key) = await _pumpTvSearchScreen(tester, facets: const {});
      await tester.pumpAndSettle();
      (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
      await tester.pumpAndSettle();
      expect(client.queries, ['movie']);

      await _openSearchIn(tester);
      await tester.tap(find.text(t.search.searchIn.titles));
      await tester.pumpAndSettle();

      // The tick re-ran the query, without a title search this time.
      expect(client.queries, ['movie']);
      expect(client.facetQueries.where((kind) => kind == SearchScopeKind.actors), hasLength(2));
      await _closeSearchIn(tester);
      expect(find.text('Movie 1'), findsNothing);
      expect(_badge('2'), findsOneWidget, reason: 'the badge counts two ticks');
    });

    testWidgets('with nothing ticked no search runs and the screen asks for a tick', (tester) async {
      final (client, key) = await _pumpTvSearchScreen(tester, facets: const {});
      await tester.pumpAndSettle();
      // Close Plezy's TV keyboard, which opens over the page with the field.
      (key.currentState! as SearchInputFocusable).submitSearchQuery('');
      await tester.pumpAndSettle();

      await _openSearchIn(tester);
      for (final label in [t.search.searchIn.titles, t.search.searchIn.actors, t.search.searchIn.keywords]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      await _closeSearchIn(tester);

      (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
      await tester.pumpAndSettle();

      expect(client.queries, isEmpty);
      expect(client.facetQueries, isEmpty);
      expect(find.text(t.search.scopeHint.nothingTicked), findsWidgets);

      // Reset brings the defaults back and searches again.
      await _openSearchIn(tester);
      await tester.tap(find.text(t.search.searchIn.reset));
      await tester.pumpAndSettle();
      expect(client.queries, ['movie']);
    });

    testWidgets("the account's ticks apply, and a change is written to it once, on close", (tester) async {
      final accounts = _FakeAccounts(const AccountPreferences(searchScope: {SearchScopeKind.titles}));
      addTearDown(accounts.dispose);
      final (client, key) = await _pumpTvSearchScreen(tester, facets: const {}, accounts: accounts);
      await tester.pumpAndSettle();

      expect(find.text('Search titles'), findsWidgets);
      (key.currentState! as SearchInputFocusable).submitSearchQuery('movie');
      await tester.pumpAndSettle();
      expect(client.queries, ['movie']);
      expect(client.facetQueries, isEmpty, reason: 'only Titles is ticked on this account');

      await _openSearchIn(tester);
      expect(find.text(t.search.searchIn.savedToAccount), findsOneWidget);
      await tester.tap(find.text(t.search.searchIn.genres));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.search.searchIn.studios));
      await tester.pumpAndSettle();
      expect(accounts.writes, isEmpty, reason: 'ticking does not write; closing does');
      await _closeSearchIn(tester);

      expect(accounts.writes, hasLength(1));
      expect(accounts.writes.single[AccountPreferenceKey.searchScope], {
        SearchScopeKind.titles,
        SearchScopeKind.genres,
        SearchScopeKind.studios,
      });
    });

    testWidgets('D-pad walks the pop-up rows, Select ticks and Back closes it', (tester) async {
      final changes = <Set<SearchScopeKind>>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showAnchoredPanel<void>(
                      context,
                      anchorRect: const Rect.fromLTWH(600, 40, 48, 48),
                      builder: (_) => SearchScopePanel(
                        initial: SearchScopeKind.defaults,
                        savedToAccount: true,
                        focusFirstRow: true,
                        onChanged: changes.add,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'SearchInFirstRow');

      // Down from Titles to Actors, Select unticks it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(changes.single, {SearchScopeKind.titles, SearchScopeKind.keywords});

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SearchScopePanel), findsNothing);
    });
  });
}

Future<(_FakeMediaServerClient, GlobalKey<State<SearchScreen>>)> _pumpTvSearchScreen(
  WidgetTester tester, {
  List<MediaItem>? items,
  // When false, no server is registered, so performSearchQuery throws — the
  // path a companion-remote submit hits when the search fails outright.
  bool registerClient = true,
  Object? searchError,
  List<_FakeMediaServerClient> additionalClients = const [],
  HiddenLibrariesProvider? hiddenLibraries,
  List<MediaLibrary> libraries = const [],
  Map<SearchScopeKind, List<SearchFacetMatch>>? facets,
  AccountPreferencesController? accounts,
}) async {
  TvDetectionService.debugSetAppleTVOverride(true);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final client = _FakeMediaServerClient(
    items:
        items ??
        [
          testMediaItem(
            id: 'movie_1',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Movie 1',
            serverId: 'server_1',
            serverName: 'Server',
          ),
        ],
    searchError: searchError,
    facets: facets,
  );
  final manager = MultiServerManager();
  if (registerClient) manager.debugRegisterClientForTesting(client);
  for (final additionalClient in additionalClients) {
    manager.debugRegisterClientForTesting(additionalClient);
  }
  final provider = testMultiServerProvider(manager);
  addTearDown(provider.dispose);

  final hidden = hiddenLibraries ?? HiddenLibrariesProvider();
  if (hiddenLibraries == null) addTearDown(hidden.dispose);

  final librariesProvider = LibrariesProvider();
  addTearDown(librariesProvider.dispose);
  if (libraries.isNotEmpty) await librariesProvider.updateLibraryOrder(libraries);

  final key = GlobalKey<State<SearchScreen>>();
  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
          ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
          if (accounts != null) ChangeNotifierProvider<AccountPreferencesController>.value(value: accounts),
        ],
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: SearchScreen(key: key),
        ),
      ),
    ),
  );
  addTearDown(() async {
    // Dispose the search state (including its debounce, focus nodes, and any
    // hosted OSK route) before resetting process-wide focus/keyboard state.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  return (client, key);
}

/// Two movies on the same server in different libraries, so a test can hide
/// one library and assert only the other survives.
List<MediaItem> _twoLibraryMovies() => [
  testMediaItem(
    id: 'movie_1',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Movie 1',
    serverId: 'server_1',
    serverName: 'Server',
    libraryId: '1',
  ),
  testMediaItem(
    id: 'movie_2',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Movie 2',
    serverId: 'server_1',
    serverName: 'Server',
    libraryId: '2',
  ),
];

/// One result per kind on the same single-library server, so kind chips have
/// something to filter.
List<MediaItem> _mixedKindItems() => [
  testMediaItem(
    id: 'movie_1',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Paw Patrol: The Movie',
    serverId: 'server_1',
    serverName: 'Server',
  ),
  testMediaItem(
    id: 'episode_1',
    backend: MediaBackend.plex,
    kind: MediaKind.episode,
    title: 'Paw Patrol Rescue',
    serverId: 'server_1',
    serverName: 'Server',
  ),
  testMediaItem(
    id: 'track_1',
    backend: MediaBackend.plex,
    kind: MediaKind.track,
    title: 'Paw Patrol Theme',
    serverId: 'server_1',
    serverName: 'Server',
  ),
];

/// A library on `server_1`, keyed so `MediaItem.libraryGlobalKey` for items
/// with the same `libraryId` resolves to it.
MediaLibrary _library(String id, String title) =>
    MediaLibrary(id: id, backend: MediaBackend.plex, title: title, kind: MediaKind.movie, serverId: 'server_1');

TextEditingController _searchController(WidgetTester tester) {
  return tester.widget<FocusableTextField>(find.byType(FocusableTextField)).controller;
}

void _resetGlobalTestState() {
  SearchScreen.resetDeviceScopeForTesting();
  FocusManager.instance.primaryFocus?.unfocus();
  HardwareKeyboard.instance.clearState();
  SelectKeyUpSuppressor.clearSuppression();
  BackKeyUpSuppressor.clearSuppression();
  BackKeyCoordinator.clear();
  TvDetectionService.debugSetAppleTVOverride(null);
  TvDetectionService.setForceTVSync(false);
  SettingsService.resetForTesting();
}

/// An account whose server keeps the "Search in" ticks, recording each write.
class _FakeAccounts extends AccountPreferencesController {
  _FakeAccounts(this.preferences);

  AccountPreferences preferences;
  final writes = <AccountPreferencesPatch>[];

  @override
  bool activeSupports(AccountPreferenceKey key) => key == AccountPreferenceKey.searchScope;

  @override
  AccountPreferences? get activePreferences => preferences;

  @override
  Future<AccountPreferences> updateActive(AccountPreferencesPatch patch) async {
    writes.add(patch);
    preferences = AccountPreferences(searchScope: patch[AccountPreferenceKey.searchScope] as Set<SearchScopeKind>?);
    return preferences;
  }
}

SearchFacetMatch _person(String id, String name) => SearchFacetMatch(
  kind: SearchScopeKind.actors,
  facet: MediaFacet(MediaFacetKind.person, id),
  name: name,
  serverId: 'server_1',
);

String _defaultHint() => t.search.scopeHint.search(
  kinds: t.search.scopeHint.listAnd(
    first: '${t.search.scopeHint.titles}, ${t.search.scopeHint.actors}',
    last: t.search.scopeHint.keywords,
  ),
);

Finder _badge(String count) => find.descendant(of: find.byType(Badge), matching: find.text(count));

Future<void> _openSearchIn(WidgetTester tester) async {
  await tester.tap(find.byTooltip(t.search.searchIn.title));
  await tester.pumpAndSettle();
  expect(find.byType(SearchScopePanel), findsOneWidget);
}

Future<void> _closeSearchIn(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 700));
  await tester.pumpAndSettle();
  expect(find.byType(SearchScopePanel), findsNothing);
}

class _FakeMediaServerClient implements MediaServerClient {
  final String serverIdValue;
  final String serverNameValue;
  final List<MediaItem> items;
  Object? searchError;
  final List<String> queries = [];
  final List<String> fetchedItemIds = [];
  MediaItem? itemResult;
  Completer<void>? fetchGate;
  Completer<void>? searchGate;
  AbortController? lastSearchAbort;

  /// Set: a Jellyfin-like server that answers the extra search kinds.
  final Map<SearchScopeKind, List<SearchFacetMatch>>? facets;
  final List<SearchScopeKind> facetQueries = [];

  _FakeMediaServerClient({
    required this.items,
    this.serverIdValue = 'server_1',
    this.serverNameValue = 'Server',
    this.searchError,
    this.facets,
  });

  @override
  ServerId get serverId => ServerId(serverIdValue);

  @override
  String? get serverName => serverNameValue;

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => facets == null ? ServerCapabilities.plex : ServerCapabilities.jellyfin;

  @override
  Future<List<SearchFacetMatch>> searchFacet(SearchScopeKind kind, String query, {AbortController? abort}) async {
    facetQueries.add(kind);
    return facets?[kind] ?? const [];
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    queries.add(query);
    lastSearchAbort = abort;
    abort?.throwIfAborted();
    if (searchError != null) throw searchError!;
    final gate = searchGate;
    if (gate != null) await gate.future;
    abort?.throwIfAborted();
    return items;
  }

  @override
  Future<MediaItem?> fetchItem(String id, {bool useCache = true}) async {
    fetchedItemIds.add(id);
    final gate = fetchGate;
    if (gate != null) await gate.future;
    return itemResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
