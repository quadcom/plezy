import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/companion_remote/remote_command.dart';
import '../../mpv/mpv.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/companion_remote/companion_remote_receiver.dart';
import '../../services/fullscreen_state_manager.dart';
import '../../services/video_volume_controller.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';

/// Wires the player screen into the [CompanionRemoteReceiver] callback slots
/// and owns the home-button fallback plus the provider handle used for
/// player-active sync notifications.
///
/// Plain State-owned helper. [bind] installs this instance as the receiver's
/// `playerOwner` token; [unbind] restores the slots only while this instance
/// still owns them, so a replacement screen's wiring survives the outgoing
/// screen's dispose. The player and volume controller are injected as
/// late-bound getters because both are re-created across playback attempts,
/// and volume/seek dispatch must bind to the player at command receipt.
///
/// Also reports now-playing status (`syncState`) to the provider: on bind,
/// on every play/pause change, when the playhead jumps by more than
/// [_seekJumpThreshold] (mpv has no clean completed-seek signal — a seek
/// request lands on [Player.streams.playheadJump] before the backend has
/// acted on it), and on a 10s timer while playing. [attachPlayer] re-wires
/// the play/position subscriptions whenever the screen replaces its player.
class CompanionRemoteBinding {
  CompanionRemoteBinding({
    required this._player,
    required this._isMounted,
    required this._canControlPlayback,
    required this._volumeController,
    required this._hasNextItem,
    required this._onStop,
    required this._onNavigateToNextItem,
    required this._onNavigateToPreviousItem,
    required this._skipByConfiguredStep,
    required this._onCycleSubtitles,
    required this._onCycleAudio,
    required this._onHome,
    required this._readProvider,
    required this._serverId,
    required this._itemId,
  });

  final Player? Function() _player;
  final bool Function() _isMounted;
  final bool Function() _canControlPlayback;
  final VideoVolumeController? Function() _volumeController;
  final bool Function() _hasNextItem;
  final void Function() _onStop;
  final Future<void> Function() _onNavigateToNextItem;
  final Future<void> Function() _onNavigateToPreviousItem;
  final void Function({required bool forward}) _skipByConfiguredStep;
  final void Function() _onCycleSubtitles;
  final void Function() _onCycleAudio;
  final void Function() _onHome;
  final CompanionRemoteProvider Function() _readProvider;
  final String? Function() _serverId;
  final String Function() _itemId;

  /// A position jump larger than this, between two consecutive
  /// [PlayerStreams.position] ticks, is read as a landed seek.
  static const Duration _seekJumpThreshold = Duration(seconds: 2);

  CompanionRemoteProvider? _provider;
  VoidCallback? _savedOnHome;
  Player? _boundPlayer;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Duration? _lastPosition;
  Timer? _syncTimer;

  /// The MainScreen home callback saved while this screen overrides the
  /// receiver's home slot; the screen's home-button handler invokes it after
  /// popping back to the first route.
  VoidCallback? get savedOnHome => _savedOnHome;

  void bind() {
    final receiver = CompanionRemoteReceiver.instance;
    receiver.playerHomeFallback ??= receiver.onHome;
    receiver.playerOwner = this;
    receiver.onStop = () {
      if (_isMounted()) _onStop();
    };
    receiver.onNextTrack = () {
      if (_isMounted() && _hasNextItem()) unawaited(_onNavigateToNextItem());
    };
    receiver.onPreviousTrack = () {
      if (_isMounted()) unawaited(_onNavigateToPreviousItem());
    };
    receiver.onSeekForward = () => _dispatchSeek(forward: true);
    receiver.onSeekBackward = () => _dispatchSeek(forward: false);
    receiver.onVolumeUp = () => _dispatchVolume(10);
    receiver.onVolumeDown = () => _dispatchVolume(-10);
    receiver.onVolumeMute = _dispatchMute;
    receiver.onSubtitles = () {
      if (_canControlPlayback()) _onCycleSubtitles();
    };
    receiver.onAudioTracks = () {
      if (_canControlPlayback()) _onCycleAudio();
    };
    receiver.onFullscreen = _toggleFullscreen;

    // Override home to exit the player first. Replacements inherit the base
    // MainScreen callback rather than chaining through the outgoing player.
    _savedOnHome = receiver.playerHomeFallback;
    receiver.onHome = () {
      if (_isMounted()) _onHome();
    };

    // Store provider reference for use in dispose and notify remote
    try {
      _provider = _readProvider();
      _sendSyncState();
    } catch (e) {
      appLogger.d('CompanionRemote provider unavailable', error: e);
    }

    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_isMounted() && (_player()?.state.isActive ?? false)) _sendSyncState();
    });
  }

  /// Re-wires the play/position subscriptions to [player]. Call whenever the
  /// screen (re)creates its player, so a swap mid-session is not missed.
  /// A no-op when [player] is already the one currently wired.
  void attachPlayer(Player player) {
    if (identical(_boundPlayer, player)) return;
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _boundPlayer = player;
    _lastPosition = null;
    _playingSubscription = player.streams.playing.listen((_) => _sendSyncState());
    _positionSubscription = player.streams.position.listen(_onPositionTick);
  }

  void _onPositionTick(Duration position) {
    final last = _lastPosition;
    _lastPosition = position;
    if (last == null) return;
    if ((position - last).abs() > _seekJumpThreshold) _sendSyncState();
  }

  void _sendSyncState() {
    if (!_isMounted()) return;
    _provider?.sendCommand(RemoteCommandType.syncState, data: _syncStatePayload());
  }

  /// `playerActive` alone when the current item has no server/item id to
  /// report — never a made-up one.
  Map<String, dynamic> _syncStatePayload() {
    final data = <String, dynamic>{'playerActive': true};
    final currentPlayer = _player();
    final serverId = _serverId();
    if (currentPlayer != null && serverId != null) {
      final state = currentPlayer.state;
      data['playing'] = state.isActive;
      data['positionMs'] = currentPlayer.currentPosition.inMilliseconds;
      data['durationMs'] = state.duration.inMilliseconds > 0 ? state.duration.inMilliseconds : 0;
      data['serverId'] = serverId;
      data['itemId'] = _itemId();
      data['sentAt'] = DateTime.now().millisecondsSinceEpoch;
    }
    return data;
  }

  void _dispatchSeek({required bool forward}) {
    final currentPlayer = _player();
    if (!_isMounted() || currentPlayer == null || !_canControlPlayback()) return;
    // The viewer's configured step, like every other skip source, and the
    // screen coalesces a burst of these into one absolute seek so a remote
    // held on skip cannot dispatch a native seek per repeat.
    _skipByConfiguredStep(forward: forward);
  }

  void _dispatchVolume(double delta) {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.adjust(delta);
  }

  void _dispatchMute() {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.toggleMute();
  }

  Future<void> _toggleFullscreen() async {
    if (!PlatformDetector.isDesktopOS()) return;
    await FullscreenStateManager().toggleFullscreen();
  }

  void unbind() {
    _playingSubscription?.cancel();
    _playingSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _boundPlayer = null;
    _lastPosition = null;

    final receiver = CompanionRemoteReceiver.instance;
    if (!identical(receiver.playerOwner, this)) {
      _provider = null;
      return;
    }
    receiver.onStop = null;
    receiver.onNextTrack = null;
    receiver.onPreviousTrack = null;
    receiver.onSeekForward = null;
    receiver.onSeekBackward = null;
    receiver.onVolumeUp = null;
    receiver.onVolumeDown = null;
    receiver.onVolumeMute = null;
    receiver.onSubtitles = null;
    receiver.onAudioTracks = null;
    receiver.onFullscreen = null;
    receiver.onHome = receiver.playerHomeFallback;
    receiver.playerHomeFallback = null;
    receiver.playerOwner = null;
    _savedOnHome = null;

    // Notify only when the active player owner exits.
    _provider?.sendCommand(RemoteCommandType.syncState, data: {'playerActive': false});
    _provider = null;
  }
}
