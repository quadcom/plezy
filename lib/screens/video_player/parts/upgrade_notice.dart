part of '../../video_player_screen.dart';

/// Fork: "Upgrade Ready" while watching (local/plans/new-copy-toast.md). When
/// Radarr/Sonarr replaces the film or episode being watched with a better copy,
/// Media Bridge asks the server to tell this session (PLAN_PMB_91); the message
/// shows over the picture without pausing, with "Switch now", which reopens the
/// same item at the same spot so the new copy plays.
extension _VideoPlayerUpgradeNoticeMethods on VideoPlayerScreenState {
  static const _defaultTimeout = Duration(seconds: 15);

  void _onServerMessage(ServerMessage message) {
    if (!mounted || _shuttingDown || player == null) return;
    // Not for programmes the schedule picks (Old School), live channels, or a
    // shared session whose host decides what plays.
    if (widget.isOldSchool || widget.isLive || widget.isIptv) return;
    if (_watchTogetherProvider?.isInSession == true) return;
    if (message.serverId != _currentMetadata.serverId) return;
    appLogger.d('Server message during ${_currentMetadata.displayTitle}: ${message.text}');
    final isKeyboardMode = PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false);
    _setPlayerState(() => _upgradeNotice = message.text);
    if (isKeyboardMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _upgradeNotice != null) _upgradeSwitchFocusNode.requestFocus();
      });
    }
    _upgradeNoticeTimer?.cancel();
    _upgradeNoticeTimer = Timer(message.timeout ?? _defaultTimeout, _hideUpgradeNotice);
  }

  void _hideUpgradeNotice() {
    _upgradeNoticeTimer?.cancel();
    _upgradeNoticeTimer = null;
    _upgradeNotNowFocusNode.unfocus();
    _upgradeSwitchFocusNode.unfocus();
    if (mounted && _upgradeNotice != null) _setPlayerState(() => _upgradeNotice = null);
  }

  /// Reopens the item at the current spot on the file the server lists now. The
  /// item is read from the network first (not the 5-minute playback cache, which
  /// may still hold the old file), and the audio and subtitle choices carry over.
  Future<void> _switchToUpgradedCopy() async {
    _hideUpgradeNotice();
    final current = _currentMetadata;
    final position = player?.state.position;
    var fresh = current;
    final client = context.tryGetMediaClientForServer(serverIdOrNull(current.serverId));
    if (client != null) {
      try {
        final item = await client.fetchItem(current.id);
        if (item != null) {
          fresh = item.copyWith(
            serverId: item.serverId ?? current.serverId,
            serverName: item.serverName ?? current.serverName,
          );
        }
      } catch (e) {
        appLogger.d('Upgrade switch: item refresh failed, reopening with what we have', error: e);
      }
    }
    if (!mounted || _shuttingDown) return;
    await _reloadMediaInPlace(
      metadata: fresh,
      resumePosition: position,
      preserveCurrentTrackSelection: true,
      reason: 'switch to the upgraded copy',
    );
  }
}
