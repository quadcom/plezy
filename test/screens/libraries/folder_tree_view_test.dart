import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/libraries/folder_tree_view.dart';
import 'package:plezy/services/jellyfin_client.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('Jellyfin music artists and albums expand through direct children', (tester) async {
    final client = JellyfinClient.forTesting(
      connection: testJellyfinConnection(machineId: 'music-server'),
      httpClient: MockClient((request) async {
        final parentId = request.url.queryParameters['ParentId'];
        final foldersOnly = request.url.queryParameters['IncludeItemTypes'] == 'Folder,CollectionFolder,PhotoAlbum';
        final items = foldersOnly
            ? const <Map<String, Object?>>[]
            : switch (parentId) {
                'music-library' => const [
                  {'Id': 'artist-1', 'Name': 'Artist One', 'Type': 'MusicArtist', 'IsFolder': true},
                ],
                'artist-1' => const [
                  {
                    'Id': 'album-1',
                    'Name': 'Album One',
                    'Type': 'MusicAlbum',
                    'IsFolder': true,
                    'AlbumArtists': [
                      {'Id': 'artist-1', 'Name': 'Artist One'},
                    ],
                  },
                ],
                'album-1' => const [
                  {'Id': 'track-1', 'Name': 'Track One', 'Type': 'Audio', 'AlbumId': 'album-1', 'Album': 'Album One'},
                ],
                _ => const <Map<String, Object?>>[],
              };
        return http.Response(
          jsonEncode({'Items': items, 'TotalRecordCount': items.length}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final provider = testMultiServer(clients: [client]).provider;

    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: provider,
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: CustomScrollView(
                slivers: const [
                  FolderTreeView(libraryKey: 'music-library', serverId: 'music-server', libraryKind: MediaKind.artist),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Artist One'), findsOneWidget);
    expect(find.text('Album One'), findsNothing);

    await tester.tap(find.text('Artist One'));
    await tester.pumpAndSettle();
    expect(find.text('Album One'), findsOneWidget);
    expect(find.text('Track One'), findsNothing);

    await tester.tap(find.text('Album One'));
    await tester.pumpAndSettle();
    expect(find.text('Track One'), findsOneWidget);
  });

  testWidgets('refresh reports whether the root listing landed', (tester) async {
    var failNext = false;
    final client = JellyfinClient.forTesting(
      connection: testJellyfinConnection(machineId: 'srv'),
      httpClient: MockClient((request) async {
        if (failNext) return http.Response('down', 500);
        final foldersOnly = request.url.queryParameters['IncludeItemTypes'] == 'Folder,CollectionFolder,PhotoAlbum';
        final items = foldersOnly
            ? const <Map<String, Object?>>[]
            : const [
                {'Id': 'f1', 'Name': 'Folder One', 'Type': 'Folder', 'IsFolder': true},
              ];
        return http.Response(
          jsonEncode({'Items': items, 'TotalRecordCount': items.length}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final provider = testMultiServer(clients: [client]).provider;
    final key = GlobalKey<FolderTreeViewState>();

    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: provider,
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [FolderTreeView(key: key, libraryKey: 'lib', serverId: 'srv', libraryKind: MediaKind.movie)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Folder One'), findsOneWidget);

    final refreshed = key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(await refreshed, isTrue);

    failNext = true;
    final failed = key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(await failed, isFalse);
  });

  // local/plans/folder-view-up-jump.md: Up after moving down must go one row
  // up, not jump to the chips at the top of the library.
  group('arrow keys move one step', () {
    Future<({FocusNode first, List<int> upToChips, ScrollController scroll})> pumpLongFolder(
      WidgetTester tester, {
      required bool grid,
    }) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final client = JellyfinClient.forTesting(
        connection: testJellyfinConnection(machineId: 'srv'),
        httpClient: MockClient((request) async {
          final foldersOnly = request.url.queryParameters['IncludeItemTypes'] == 'Folder,CollectionFolder,PhotoAlbum';
          final items = foldersOnly
              ? const <Map<String, Object?>>[]
              : [
                  for (var i = 0; i < 60; i++)
                    {'Id': 'v$i', 'Name': 'Video ${i.toString().padLeft(2, '0')}', 'Type': 'MusicVideo'},
                ];
          return http.Response(
            jsonEncode({'Items': items, 'TotalRecordCount': items.length}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final provider = testMultiServer(clients: [client]).provider;
      final first = FocusNode(debugLabel: 'first');
      addTearDown(first.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final upToChips = <int>[];

      await tester.pumpWidget(
        ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(dark: true),
              home: Scaffold(
                body: CustomScrollView(
                  controller: scroll,
                  slivers: [
                    FolderTreeView(
                      libraryKey: 'lib',
                      serverId: 'srv',
                      libraryKind: MediaKind.clip,
                      grid: grid,
                      firstItemFocusNode: first,
                      onNavigateUp: () => upToChips.add(1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (first: first, upToChips: upToChips, scroll: scroll);
    }

    int focusedIndex() {
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
      if (label == 'first') return 0;
      final match = RegExp(r'^folder_item_(\d+)$').firstMatch(label);
      expect(match, isNotNull, reason: 'focus is on "$label", not a tile');
      return int.parse(match!.group(1)!);
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('grid: Up after several Downs goes one row up', (tester) async {
      final setup = await pumpLongFolder(tester, grid: true);
      setup.first.requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      final columns = focusedIndex();
      expect(columns, greaterThan(0));
      for (var i = 0; i < 5; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedIndex(), columns * 6);
      expect(setup.scroll.offset, greaterThan(0));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIndex(), columns * 5);
      expect(setup.upToChips, isEmpty);
      expect(setup.scroll.offset, greaterThan(0));

      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedIndex(), columns * 5 + 1);
    });

    testWidgets('grid: Up from the first row goes to the chips', (tester) async {
      final setup = await pumpLongFolder(tester, grid: true);
      setup.first.requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(setup.upToChips, hasLength(1));
    });

    testWidgets('list: Up after several Downs goes one row up', (tester) async {
      final setup = await pumpLongFolder(tester, grid: false);
      setup.first.requestFocus();
      await tester.pumpAndSettle();

      for (var i = 0; i < 20; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedIndex(), 20);
      expect(setup.scroll.offset, greaterThan(0));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIndex(), 19);
      expect(setup.upToChips, isEmpty);
      expect(setup.scroll.offset, greaterThan(0));

      for (var i = 0; i < 19; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedIndex(), 0);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(setup.upToChips, hasLength(1));
    });
  });
}
