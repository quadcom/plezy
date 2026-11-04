import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/playback_subtitle_resolver.dart';
import 'package:plezy/services/scrub_preview_source.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/subtitle_preference.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/stub_music_playback_service.dart';
import '../../test_helpers/watch_together_fakes.dart';

/// local/plans/subtitle-download-fixes.md part 2: a subtitle file downloaded
/// mid-play is missing from (or, on Jellyfin, shifted in) the catalog the
/// player opened with. Switching to it must reload and pick it by its id in
/// the fresh catalog, and only report success when it is the one on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    await SettingsService.getInstance();
    tmpRoot = await Directory.systemTemp.createTemp('downloaded_subtitle_reload_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  Future<PlaybackSourceChangeOutcome> switchSource(
    WidgetTester tester,
    GlobalKey<VideoPlayerScreenState> key, {
    PlaybackSourceSubtitleChoice? subtitle,
    int? audio,
  }) async {
    PlaybackSourceChangeOutcome? outcome;
    final switching = key.currentState!
        .debugSwitchPlaybackSourceForTesting(newSubtitleChoice: subtitle, newAudioStreamId: audio)
        .then((value) => outcome = value);
    for (var i = 0; i < 400 && outcome == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (outcome == null) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      }
    }
    await switching;
    return outcome!;
  }

  Future<void> runWithScreen(
    WidgetTester tester,
    _SubClient client,
    Future<void> Function(GlobalKey<VideoPlayerScreenState> key) body,
  ) async {
    final fakePlayer = _SubPlayer();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final key = await _pushScreen(tester, db: db, fakePlayer: fakePlayer, client: client);
        // The harness never finishes start-up; one ordinary reload leaves the
        // screen holding the catalog it opened with, as real playback does.
        expect(await switchSource(tester, key, audio: 2), PlaybackSourceChangeOutcome.applied);
        await body(key);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  String? requestedSubtitleId(PlaybackInitializationOptions options) => switch (options.preferredSubtitleTrack) {
    SubtitleTrackPreference(:final track) => track.id,
    _ => null,
  };

  testWidgets('a downloaded file the opening catalog lacked is reloaded and switched on', (tester) async {
    // Opened with no subtitles at all, like Super 8 before its download.
    final client = _SubClient(before: const [], after: [_external(0, 'Downloaded')]);
    await runWithScreen(tester, client, (key) async {
      final before = client.requests.length;
      client.downloaded = true;

      final outcome = await switchSource(tester, key, subtitle: const PlaybackSourceSubtitleChoice.downloaded(0));

      expect(outcome, PlaybackSourceChangeOutcome.applied);
      expect(client.requests, hasLength(before + 1));
      expect(requestedSubtitleId(client.requests.last), 'source:0');
    });
  });

  testWidgets('a downloaded file whose id an older file had is still reloaded, not switched locally', (tester) async {
    // Jellyfin lists external files first: the new one takes index 0 and the
    // file that had index 0 moves to 1. The old catalog's row 0 is the old
    // file, which a local switch would have picked.
    final client = _SubClient(
      before: [_external(0, 'Old file')],
      after: [_external(0, 'Downloaded'), _external(1, 'Old file')],
    );
    await runWithScreen(tester, client, (key) async {
      final before = client.requests.length;
      client.downloaded = true;

      final outcome = await switchSource(tester, key, subtitle: const PlaybackSourceSubtitleChoice.downloaded(0));

      expect(outcome, PlaybackSourceChangeOutcome.applied);
      expect(client.requests, hasLength(before + 1), reason: 'the stale catalog must not be trusted');
      expect(requestedSubtitleId(client.requests.last), 'source:0');
    });
  });

  testWidgets('reports a failure when the downloaded file is not in the fresh catalog either', (tester) async {
    final client = _SubClient(before: const [], after: const []);
    await runWithScreen(tester, client, (key) async {
      client.downloaded = true;

      final outcome = await switchSource(tester, key, subtitle: const PlaybackSourceSubtitleChoice.downloaded(0));

      expect(outcome, PlaybackSourceChangeOutcome.failed);
    });
  });
}

MediaSubtitleTrack _external(int id, String title) => MediaSubtitleTrack(
  id: id,
  index: id,
  codec: 'srt',
  language: 'English',
  languageCode: 'eng',
  title: title,
  selected: false,
  forced: false,
  external: true,
);

Future<GlobalKey<VideoPlayerScreenState>> _pushScreen(
  WidgetTester tester, {
  required AppDatabase db,
  required _SubPlayer fakePlayer,
  required _SubClient client,
}) async {
  final multi = testMultiServer(clients: [client]);
  final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
  final offlineMode = OfflineModeProvider(multi.manager);
  final accountPreferences = AccountPreferencesController();
  final initializationHold = Completer<void>();
  Future<void> holdInitialization() => initializationHold.future;
  PlaybackCoordinator.instance.registerMusicSession(stopAndDispose: holdInitialization);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    PlaybackCoordinator.instance.unregisterMusicSession(holdInitialization);
    initializationHold.complete();
    await tester.pump();
    offlineWatch.dispose();
    offlineMode.dispose();
    accountPreferences.dispose();
    await fakePlayer.dispose();
  });
  final navigator = GlobalKey<NavigatorState>();
  final key = GlobalKey<VideoPlayerScreenState>();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
        ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
        ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
        ChangeNotifierProvider<OfflineModeProvider>.value(value: offlineMode),
        ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
        ChangeNotifierProvider<MusicPlaybackService>(create: (_) => StubMusicPlaybackService()),
        Provider<AppDatabase>.value(value: db),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Browse')),
      ),
    ),
  );
  unawaited(
    VideoPlayerRoute(
      builder: (_) => VideoPlayerScreen(
        key: key,
        metadata: testMediaItem(id: 'film', serverId: 'srv-1', backend: MediaBackend.jellyfin),
        selectedAudioStreamId: 1,
      ),
    ).push(navigator.currentState!),
  );
  await tester.pump();
  key.currentState!.player = fakePlayer;
  await key.currentState!.debugWirePlayerStreamsForTesting();
  fakePlayer.emitPlaybackRestart();
  await tester.pump();
  return key;
}

class _SubPlayer extends FakeSyncPlayer {
  _SubPlayer() : super(playing: true, position: const Duration(seconds: 121), duration: const Duration(minutes: 110));

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> awaitDisplayModeSwitch({int extraDelayMs = 0}) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> stop() async {
    setPosition(Duration.zero);
    emitPlaying(false);
  }

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
  }) async {
    setPosition(media.start ?? Duration.zero);
    emitPlaying(play);
    emitFileStarted();
    emitPlaybackRestart();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}
}

/// Serves [before] until [downloaded] is set, then [after]: the listing a
/// server gives once the new file is saved beside the video.
class _SubClient with PlaybackReportRecorder implements MediaServerClient {
  _SubClient({required this.before, required this.after});

  final List<MediaSubtitleTrack> before;
  final List<MediaSubtitleTrack> after;
  bool downloaded = false;
  final requests = <PlaybackInitializationOptions>[];

  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.jellyfin;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    requests.add(options);
    const url = 'https://example.invalid/film/stream';
    return PlaybackInitializationResult(
      availableVersions: const [],
      activeAudioStreamId: options.selectedAudioStreamId,
      videoUrl: url,
      mediaInfo: MediaSourceInfo(
        videoUrl: url,
        audioTracks: const [],
        subtitleTracks: downloaded ? after : before,
        chapters: const [],
        mediaSourceId: 'film-source',
      ),
    );
  }

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async => null;

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
