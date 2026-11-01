import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/episode_navigation_service.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
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

/// PLAN_PFN_91 (local/plans/force-convert-quality-pick.md): a quality picked in
/// the player's own menu, other than Original, asks the server to convert the
/// picture. The pick lasts for its own item only: the next episode starts where
/// a fresh play would (Adrian, 2026-10-31).
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
    tmpRoot = await Directory.systemTemp.createTemp('quality_pick_force_conversion_test_');
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
    int? newAudioStreamId,
    TranscodeQualityPreset? newPreset,
  }) async {
    PlaybackSourceChangeOutcome? outcome;
    final switching = key.currentState!
        .debugSwitchPlaybackSourceForTesting(newAudioStreamId: newAudioStreamId, newPreset: newPreset)
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
    Future<void> Function(GlobalKey<VideoPlayerScreenState> key, _PickPlayer player, _PickClient client) body, {
    TranscodeQualityPreset startPreset = TranscodeQualityPreset.original,
  }) async {
    final fakePlayer = _PickPlayer();
    final client = _PickClient();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final key = await _pushScreen(tester, db: db, fakePlayer: fakePlayer, client: client, startPreset: startPreset);
        await body(key, fakePlayer, client);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('a quality picked in the player forces a conversion', (tester) async {
    await runWithScreen(tester, (key, player, client) async {
      expect(key.currentState!.debugQualityPickedInPlayer, isFalse);

      expect(
        await switchSource(tester, key, newPreset: TranscodeQualityPreset.p1080_8mbps),
        PlaybackSourceChangeOutcome.applied,
      );

      expect(client.requests.last.qualityPreset, TranscodeQualityPreset.p1080_8mbps);
      expect(client.requests.last.forceConversion, isTrue);
      expect(key.currentState!.debugQualityPickedInPlayer, isTrue);
    });
  });

  testWidgets('picking the quality a capped start is already on still forces a conversion', (tester) async {
    await runWithScreen(startPreset: TranscodeQualityPreset.p1080_8mbps, tester, (key, player, client) async {
      // The screen's own start-up request is already in; it is never forced.
      final before = client.requests.length;
      expect(client.requests.every((r) => !r.forceConversion), isTrue);
      expect(
        await switchSource(tester, key, newPreset: TranscodeQualityPreset.p1080_8mbps),
        PlaybackSourceChangeOutcome.applied,
      );

      expect(client.requests, hasLength(before + 1), reason: 'the same preset reloads once, now forced');
      expect(client.requests.last.qualityPreset, TranscodeQualityPreset.p1080_8mbps);
      expect(client.requests.last.forceConversion, isTrue);

      expect(
        await switchSource(tester, key, newPreset: TranscodeQualityPreset.p1080_8mbps),
        PlaybackSourceChangeOutcome.unchanged,
        reason: 'once forced, the same pick again changes nothing',
      );
    });
  });

  testWidgets('a later reload of the same item keeps forcing, and Original clears it', (tester) async {
    await runWithScreen(tester, (key, player, client) async {
      await switchSource(tester, key, newPreset: TranscodeQualityPreset.p720_2mbps);

      expect(await switchSource(tester, key, newAudioStreamId: 2), PlaybackSourceChangeOutcome.applied);
      expect(client.requests.last.qualityPreset, TranscodeQualityPreset.p720_2mbps);
      expect(client.requests.last.forceConversion, isTrue, reason: 'an audio change keeps the pick in force');

      expect(
        await switchSource(tester, key, newPreset: TranscodeQualityPreset.original),
        PlaybackSourceChangeOutcome.applied,
      );
      expect(client.requests.last.qualityPreset, TranscodeQualityPreset.original);
      expect(client.requests.last.forceConversion, isFalse);
      expect(key.currentState!.debugQualityPickedInPlayer, isFalse);
    });
  });

  testWidgets('the next episode drops the pick and starts at the start-up quality', (tester) async {
    await SettingsService.instance.write(SettingsService.autoPlayNextEpisode, true);
    await SettingsService.instance.write(SettingsService.playNextCountdown, 0);
    await runWithScreen(tester, (key, player, client) async {
      await switchSource(tester, key, newPreset: TranscodeQualityPreset.p1080_8mbps);
      expect(client.requests.last.forceConversion, isTrue);
      final opensBefore = player.openedUrls.length;

      key.currentState!.debugCommitAdjacentEpisodesForTesting(
        AdjacentEpisodes(
          next: testMediaItem(id: 'next', serverId: 'srv-1', backend: MediaBackend.jellyfin),
          nextStatus: QueueNavigationStatus.found,
          previousStatus: QueueNavigationStatus.boundary,
        ),
      );
      player.setPosition(player.state.duration);
      player.emitCompleted(true);
      for (var i = 0; i < 400 && player.openedUrls.length == opensBefore; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (player.openedUrls.length == opensBefore) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        }
      }
      await tester.pump();

      final next = client.requests.last;
      expect(next.metadata.id, 'next');
      // The harness never finishes start-up, so the screen has not learned the
      // server can convert and the start-up rule answers Original; the point is
      // that the 8 Mbps pick did not carry over.
      expect(next.qualityPreset, TranscodeQualityPreset.original);
      expect(next.forceConversion, isFalse);
      expect(key.currentState!.debugQualityPickedInPlayer, isFalse);
    });
  });
}

Future<GlobalKey<VideoPlayerScreenState>> _pushScreen(
  WidgetTester tester, {
  required AppDatabase db,
  required _PickPlayer fakePlayer,
  required _PickClient client,
  required TranscodeQualityPreset startPreset,
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
        metadata: testMediaItem(id: 'pick', serverId: 'srv-1', backend: MediaBackend.jellyfin),
        selectedQualityPreset: startPreset,
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

class _PickPlayer extends FakeSyncPlayer {
  _PickPlayer() : super(playing: true, position: const Duration(seconds: 121), duration: const Duration(minutes: 40));

  final openedUrls = <String>[];
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<PlayerError>.broadcast();

  void emitCompleted(bool value) {
    setCompleted(value);
    _completedController.add(value);
  }

  @override
  PlayerStreams get streams {
    final base = super.streams;
    return PlayerStreams(
      playing: base.playing,
      completed: _completedController.stream,
      buffering: base.buffering,
      position: base.position,
      duration: base.duration,
      seekable: base.seekable,
      buffer: base.buffer,
      volume: base.volume,
      rate: base.rate,
      tracks: base.tracks,
      track: base.track,
      log: base.log,
      error: _errorController.stream,
      audioDevice: base.audioDevice,
      audioDevices: base.audioDevices,
      bufferRanges: base.bufferRanges,
      playbackRestart: base.playbackRestart,
      fileStarted: base.fileStarted,
      backendSwitched: base.backendSwitched,
    );
  }

  @override
  Future<void> stop() async {
    setPosition(Duration.zero);
    emitPlaying(false);
  }

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
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
  }) async {
    openedUrls.add(media.uri);
    setPosition(media.start ?? Duration.zero);
    setCompleted(false);
    _completedController.add(false);
    emitPlaying(play);
    emitFileStarted();
    emitPlaybackRestart();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (disposed) return;
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
    await _completedController.close();
    await _errorController.close();
  }
}

/// Records every playback request so a test can read what the player asked for.
class _PickClient with PlaybackReportRecorder implements MediaServerClient {
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
    return PlaybackInitializationResult(
      availableVersions: const [],
      activeAudioStreamId: options.selectedAudioStreamId,
      videoUrl:
          'https://example.invalid/${options.metadata.id}/${options.qualityPreset.name}'
          '/audio-${options.selectedAudioStreamId}/force-${options.forceConversion}',
    );
  }

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
