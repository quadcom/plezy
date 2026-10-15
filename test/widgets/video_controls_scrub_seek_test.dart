import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/scrub_preview_source.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// Dragging the timeline must not hammer the server.
///
/// Each live seek outside the cache opens a new HTTP range request that the
/// server fills with tens of megabytes before the next seek abandons it. One
/// outside viewer's 9 s drag at five seeks a second cost ~600 MB of the home
/// upload. With scrub previews the drag only moves the preview and seeks once on
/// release; without them it seeks at most once a second.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();

    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  Future<void> pumpControls(WidgetTester tester, {ScrubFrame? Function(Duration)? previews}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'scrub-seek'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                thumbnailDataBuilder: previews,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    chrome.show();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TimelineSlider), findsOneWidget);
  }

  /// A slow drag across the slider: [steps] moves, 100 ms apart.
  Future<void> dragAcross(WidgetTester tester, {int steps = 20}) async {
    final rect = tester.getRect(find.byType(TimelineSlider));
    final gesture = await tester.startGesture(Offset(rect.left + rect.width * 0.2, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(Offset(rect.width * 0.6 / steps, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final duringDrag = List<Duration>.of(player.seeks);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    player.seeksDuringDrag = duringDrag;
  }

  testWidgets('with previews, a drag seeks once, on release', (tester) async {
    await pumpControls(tester, previews: (_) => BytesScrubFrame(Uint8List(0)));

    await dragAcross(tester);

    expect(player.seeksDuringDrag, isEmpty, reason: 'no live seeks while the preview moves');
    expect(player.seeks, hasLength(1), reason: 'one seek when the drag ends');
    final duration = player.state.duration;
    expect(player.seeks.single.inMilliseconds, closeTo(duration.inMilliseconds * 0.8, duration.inMilliseconds * 0.03));
  });

  testWidgets('without previews, live seeks are at most one a second', (tester) async {
    await pumpControls(tester);

    // 2 s of dragging: leading seek, then one per second.
    await dragAcross(tester);

    expect(player.seeksDuringDrag, isNotEmpty, reason: 'the picture still follows the drag');
    expect(player.seeksDuringDrag.length, lessThanOrEqualTo(3));
  });
}

class _RecordingPlayer implements Player {
  final List<Duration> seeks = [];
  List<Duration> seeksDuringDrag = const [];
  final StreamController<Duration?> _jumpController = StreamController<Duration?>.broadcast();

  bool _playing = true;
  Duration _position = const Duration(minutes: 10);

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: _playing, position: _position, duration: const Duration(minutes: 45), seekable: true);

  @override
  PlayerStreams get streams => PlayerStreams(
    playheadJump: _jumpController.stream,
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
    _jumpController.add(position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await _jumpController.close();
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> playOrPause() async => _playing = !_playing;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
