import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/video_player/companion_remote_binding.dart';

/// Direct, non-widget tests of [CompanionRemoteBinding]'s now-playing
/// reporting: the full [VideoPlayerScreen] harness in
/// `companion_remote_callbacks_test.dart` never wires a
/// [CompanionRemoteProvider] into its widget tree, and its player double
/// does not implement `streams`, so bind/attachPlayer/unbind are exercised
/// here against fakes instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CompanionRemoteBinding — syncState reporting', () {
    test('bind sends playerActive plus the current player/item details', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: const Duration(seconds: 12), duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => 'srv-1', itemId: () => 'item-1');
      addTearDown(binding.unbind);

      binding.bind();

      expect(provider.sent, hasLength(1));
      final sent = provider.sent.single;
      expect(sent.key, RemoteCommandType.syncState);
      expect(sent.value, {
        'playerActive': true,
        'playing': false,
        'positionMs': 12000,
        'durationMs': 600000,
        'serverId': 'srv-1',
        'itemId': 'item-1',
        'sentAt': isA<int>(),
      });
    });

    test('bind sends only playerActive when the item has no server id', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: Duration.zero, duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => null, itemId: () => 'item-1');
      addTearDown(binding.unbind);

      binding.bind();

      expect(provider.sent.single.value, {'playerActive': true});
    });

    test('a play/pause change resends syncState with the updated playing value', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: Duration.zero, duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => 'srv-1', itemId: () => 'item-1');
      addTearDown(binding.unbind);

      binding.bind();
      binding.attachPlayer(player);
      provider.sent.clear();

      player.emitPlaying(true);

      expect(provider.sent, hasLength(1));
      expect(provider.sent.single.value?['playing'], isTrue);
    });

    test('attaching the same player instance twice does not double-subscribe', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: Duration.zero, duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => 'srv-1', itemId: () => 'item-1');
      addTearDown(binding.unbind);

      binding.bind();
      binding.attachPlayer(player);
      binding.attachPlayer(player); // same instance: must be a no-op
      provider.sent.clear();

      player.emitPlaying(true);

      expect(provider.sent, hasLength(1), reason: 'a duplicate subscription would send twice per change');
    });

    test('a position jump past the threshold resends syncState; a small delta does not', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: const Duration(seconds: 10), duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => 'srv-1', itemId: () => 'item-1');
      addTearDown(binding.unbind);

      binding.bind();
      binding.attachPlayer(player);
      provider.sent.clear();

      // First tick after attach only seeds the baseline; nothing to compare
      // against yet, so no send.
      player.emitPosition(const Duration(seconds: 10));
      expect(provider.sent, isEmpty);

      // A normal forward tick (well under the 2s seek threshold).
      player.emitPosition(const Duration(seconds: 11));
      expect(provider.sent, isEmpty);

      // A jump past the threshold reads as a landed seek.
      player.emitPosition(const Duration(seconds: 20));
      expect(provider.sent, hasLength(1));
      expect(provider.sent.single.value?['positionMs'], 20000);
    });

    test('unbind sends only {playerActive: false}', () {
      final provider = _RecordingProvider();
      addTearDown(provider.dispose);
      final player = _FakePlayer(position: const Duration(seconds: 5), duration: const Duration(minutes: 10));
      addTearDown(player.dispose);

      final binding = _binding(provider: provider, player: () => player, serverId: () => 'srv-1', itemId: () => 'item-1');

      binding.bind();
      provider.sent.clear();
      binding.unbind();

      expect(provider.sent, hasLength(1));
      final sent = provider.sent.single;
      expect(sent.key, RemoteCommandType.syncState);
      expect(sent.value, {'playerActive': false});
    });
  });
}

CompanionRemoteBinding _binding({
  required _RecordingProvider provider,
  required Player? Function() player,
  required String? Function() serverId,
  required String Function() itemId,
}) {
  return CompanionRemoteBinding(
    player: player,
    isMounted: () => true,
    canControlPlayback: () => true,
    volumeController: () => null,
    hasNextItem: () => false,
    onStop: () {},
    onPlay: () {},
    onPause: () {},
    onTogglePlayPause: () {},
    onNavigateToNextItem: () async {},
    onNavigateToPreviousItem: () async {},
    skipByConfiguredStep: ({required bool forward}) {},
    onCycleSubtitles: () {},
    onCycleAudio: () {},
    onHome: () {},
    readProvider: () => provider,
    serverId: serverId,
    itemId: itemId,
  );
}

/// Records every command the binding sends instead of touching the network
/// stack; the base class's own constructor work (device-info resolution
/// etc.) runs normally and is torn down in [dispose].
class _RecordingProvider extends CompanionRemoteProvider {
  final List<MapEntry<RemoteCommandType, Map<String, dynamic>?>> sent = [];

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) {
    sent.add(MapEntry(type, data));
  }
}

/// A minimal [Player] double exposing real `playing`/`position` streams so
/// [CompanionRemoteBinding.attachPlayer] can be exercised; every other member
/// falls through to [noSuchMethod] because nothing here calls it.
class _FakePlayer implements Player {
  _FakePlayer({required Duration position, required Duration duration})
    : _state = PlayerState(position: position, duration: duration, seekable: true);

  PlayerState _state;
  final StreamController<bool> _playingController = StreamController<bool>.broadcast(sync: true);
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast(sync: true);

  @override
  PlayerState get state => _state;

  @override
  Duration get currentPosition => _state.position;

  late final PlayerStreams _streams = PlayerStreams(
    playing: _playingController.stream,
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
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
  PlayerStreams get streams => _streams;

  void emitPlaying(bool playing) {
    _state = _state.copyWith(playing: playing);
    _playingController.add(playing);
  }

  void emitPosition(Duration position) {
    _state = _state.copyWith(position: position);
    _positionController.add(position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await _playingController.close();
    await _positionController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
