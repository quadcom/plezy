import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/player_streams.dart';
import '../../test_helpers/prefs.dart';

/// local/plans/orphan-progress-tracker.md: wiring a progress tracker while
/// one was still wired used to overwrite the field and leave the old one's
/// periodic timer running, reporting its old item every 10 s with the live
/// player's position (Greatroom showed Inception during Star Trek,
/// 2026-11-01). Both the first open and every in-place reload wire through
/// `_rebindProgressTracker`, so a second wiring must retire the first.
///
/// The screen's full start needs a native core no widget test has, so this
/// drives the rebind through its test seam on a screen whose own start was
/// refused, the same way live_media_session_test.dart drives the services.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('wiring twice leaves exactly one running tracker', (tester) async {
    final shell = _Shell();
    final first = testMediaItem(id: 'inception', kind: MediaKind.movie, title: 'Inception', serverId: 'srv-1');
    final second = testMediaItem(id: 'first-contact', kind: MediaKind.movie, title: 'First Contact', serverId: 'srv-1');

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? false : null,
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(shell.screen(key: key, metadata: first));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final state = key.currentState!..player = _IdlePlayer();

        state.debugRebindProgressTrackerForTesting(metadata: first, mediaClient: shell.client);
        final firstTracker = state.debugProgressTracker!;
        expect(firstTracker.isTracking, isTrue);

        state.debugRebindProgressTrackerForTesting(metadata: second, mediaClient: shell.client);
        final secondTracker = state.debugProgressTracker!;

        expect(identical(firstTracker, secondTracker), isFalse);
        expect(secondTracker.metadata.id, 'first-contact');
        expect(secondTracker.isTracking, isTrue);
        expect(firstTracker.isTracking, isFalse, reason: 'the replaced tracker must not keep reporting its old item');

        await tester.pumpWidget(const SizedBox.shrink());
        expect(secondTracker.isTracking, isFalse, reason: 'closing the player stops the one left');
      },
    );
  });
}

class _Shell {
  _Shell() {
    serverManager.debugRegisterClientForTesting(client);
    addTearDown(() async {
      multiServer.dispose();
      offlineWatch.dispose();
      serverManager.dispose();
      await db.close();
    });
  }

  final _ReportingClient client = _ReportingClient();
  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  final MultiServerManager serverManager = MultiServerManager();
  late final MultiServerProvider multiServer = testMultiServerProvider(serverManager);
  late final OfflineWatchSyncService offlineWatch = OfflineWatchSyncService(database: db, serverManager: serverManager);

  Widget screen({required GlobalKey<VideoPlayerScreenState> key, required MediaItem metadata}) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
        ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
        ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
        ChangeNotifierProvider<OfflineModeProvider>(create: (_) => OfflineModeProvider(serverManager)),
      ],
      child: MaterialApp(
        home: VideoPlayerScreen(key: key, metadata: metadata),
      ),
    );
  }
}

/// A player that is loaded but paused, so a tracker starts its timer without
/// sending a first report.
class _IdlePlayer implements Player {
  @override
  PlayerState get state => const PlayerState();

  @override
  PlayerStreams get streams => emptyPlayerStreams();

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReportingClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('srv-1');

  @override
  String? get serverName => 'Server 1';

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities();

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
