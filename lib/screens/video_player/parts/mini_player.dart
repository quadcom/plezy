part of '../../video_player_screen.dart';

/// Back during the credits: the video goes into the corner box and the Up Next
/// page opens under it (local/plans/video-mini-player.md, stage 2).
extension _VideoPlayerMiniPlayerMethods on VideoPlayerScreenState {
  /// With no credits marker, this last stretch of the item counts as the
  /// credits: 3 minutes, or a tenth of a short item.
  static const _creditsFallback = Duration(minutes: 3);

  /// Whether playback is in the credits: from the server's credits marker, or
  /// the last stretch of the item when there is none.
  bool _inCredits() {
    final p = player;
    if (p == null) return false;
    final position = p.state.position;
    final duration = p.state.duration;
    if (duration <= Duration.zero) return false;
    final marker = _creditsStart;
    if (marker != null && marker > Duration.zero && marker < duration) return position >= marker;
    final tenth = Duration(milliseconds: duration.inMilliseconds ~/ 10);
    final stretch = tenth < _creditsFallback ? tenth : _creditsFallback;
    return position >= duration - stretch;
  }

  /// Back goes to the Up Next page instead of closing the video: PC, tablets
  /// and TVs, the setting on, an item (not Old School, live TV, IPTV or a Watch
  /// Together session) that is really playing and in its credits.
  bool _canMinimize() {
    if (_mini || _routeExitOperation != null || !mounted) return false;
    if (widget.isOldSchool || widget.isLive || widget.isIptv || player == null) return false;
    if (_playbackFailureMessage != null || _playerInitializationError != null) return false;
    if (_watchTogetherProvider?.isInSession == true) return false;
    if (!SettingsService.instance.read(SettingsService.videoMiniPlayerOnBack)) return false;
    if (!VideoMiniPlayer.appliesOn(context)) return false;
    if (!_inCredits()) return false;
    final route = ModalRoute.of(context);
    return route != null && route.isCurrent && Navigator.of(context).canPop();
  }

  /// Moves this screen, still playing, from its page into the box: the page
  /// goes and the box takes the same widget in the same frame, so its state
  /// (and the player) carries on. The player page is replaced by the Up Next
  /// page, so Back from there returns to where playback started; coming back
  /// from full screen, the Up Next page is already there.
  void _minimizeToMiniPlayer() {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final key = _videoPlayerRoute?.screenKey;
    if (route == null || key == null) return;
    _miniNavigator = navigator;
    _miniKey = key;
    final entry = KeyedSubtree(key: key, child: widget);
    _miniEntry = entry;
    appLogger.d('Mini player: Back in the credits of ${_currentMetadata.displayTitle} opens Up Next');
    // Leave a full-screen window and any locked orientation, as a normal exit would.
    unawaited(_restoreSystemUiAndOrientation());
    // The whole picture in the box, whatever the zoom or fill setting.
    _preparePipFiltersForEntry();
    _setPlayerState(() => _mini = true);
    VideoMiniPlayer.instance.show(entry, stop: _stopMiniPlayer, onExpanded: _expandMiniPlayer);
    PlaybackCoordinator.instance.registerMiniVideo(stop: _stopMiniPlayer);
    _videoPlayerRoute?.releaseScreen();
    final upNext = _upNextRoute;
    if (upNext != null && upNext.isActive) {
      navigator.removeRoute(route);
      return;
    }
    final newRoute = UpNextRoute(item: _currentMetadata, nextEpisode: _episode.next, isOffline: widget.isOffline);
    _upNextRoute = newRoute;
    navigator.replace(oldRoute: route, newRoute: newRoute);
  }

  /// The box glided back up: move the screen into a new full-screen page,
  /// over the Up Next page.
  void _expandMiniPlayer() {
    final navigator = _miniNavigator;
    final key = _miniKey;
    final entry = _miniEntry;
    if (navigator == null || !navigator.mounted || !_mini || key == null || entry == null) return;
    appLogger.d('Mini player: back to full screen');
    PlaybackCoordinator.instance.unregisterMiniVideo(_stopMiniPlayer);
    final screen = widget;
    _restorePipFiltersAfterExit();
    _setPlayerState(() => _mini = false);
    VideoMiniPlayer.instance.release(entry);
    _miniEntry = null;
    // The same key: the new page takes this screen over without restarting it.
    unawaited(VideoPlayerRoute(builder: (_) => screen, screenKey: key).push(navigator));
  }

  /// Ends playback in the box (X, the end of the item, Back from Up Next, or
  /// another video starting) and lets the screen go, as a normal exit would.
  Future<void> _stopMiniPlayer() async {
    if (!_mini) return;
    final existing = _miniStop;
    if (existing != null) return existing;
    final done = Completer<void>();
    _miniStop = done.future;
    appLogger.d('Mini player: stop');
    PlaybackCoordinator.instance.unregisterMiniVideo(_stopMiniPlayer);
    try {
      await _shutdownVideo(pauseForRouteExit: true);
    } catch (error, stackTrace) {
      appLogger.w('Mini player: shutdown failed', error: error, stackTrace: stackTrace);
    }
    final entry = _miniEntry;
    if (entry != null) VideoMiniPlayer.instance.release(entry);
    _miniEntry = null;
    // The screen leaves the tree at the end of this frame; wait until its
    // player is fully gone, so a new player can take the native video.
    try {
      await _routeDisposed.future.timeout(const Duration(seconds: 5));
      await _nativeDisposal;
    } catch (_) {}
    done.complete();
  }

  /// What the screen shows while it is in the box.
  Widget _buildMiniPlayer(BuildContext context) {
    final p = player;
    if (p == null) return const ColoredBox(color: Colors.black);
    return VideoMiniChrome(
      player: p,
      title: _currentMetadata.displayTitle,
      hasFirstFrame: _firstFrame.uiReady,
      onExpand: VideoMiniPlayer.instance.expand,
      onStop: () => unawaited(_stopMiniPlayer()),
    );
  }
}
