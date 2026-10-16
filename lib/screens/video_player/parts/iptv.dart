part of '../../video_player_screen.dart';

/// IPTV (PlezyFin PLAN_SHA_61): live channels played straight from their
/// source, on the live-TV path, with the guide on the same page as Old
/// School. The video is full screen or in the guide's corner window; the
/// first pick plays in the corner, the second goes full screen.
///
/// A feed has about 8 s to show a picture; a feed that drops is tried once
/// more, then the next feed. When every feed has failed: "This channel isn't
/// working right now", the guide, and the channel marked "may not be
/// working" on this device.
extension _VideoPlayerIptvMethods on VideoPlayerScreenState {
  IptvController get _iptvController => widget.iptv!.controller;

  /// The playback session for [channel], starting at its best feed. Null for
  /// a channel this line-up no longer has.
  IptvPlaybackSession? _iptvStartSession(LiveTvChannel channel) {
    final iptvChannel = _iptvController.channelById(channel.key) ?? widget.iptv!.channel;
    if (iptvChannel.id != channel.key) return null;
    return _iptvController.client.startIptvPlayback(iptvChannel);
  }

  /// The first open, from the player's start: the channel is tuned and its
  /// feed opening; watch it come up.
  void _iptvDidStartSession(IptvPlaybackSession session) {
    _iptvController.setTuned(session.channel.id);
    _iptvBeganFeed(session, generation: ++_iptv.tuneGeneration);
  }

  /// The first open failed before anything played.
  void _iptvStartFailed() {
    final session = _live.session;
    if (session is IptvPlaybackSession) {
      unawaited(_iptvFailover('could not open'));
    } else {
      _iptvChannelDead(widget.iptv!.channel);
    }
  }

  // --- Tuning ---------------------------------------------------------------

  /// Play [channel] in place (from the guide, channel up/down, Last or a
  /// typed number).
  Future<void> _iptvTune(IptvChannel channel, {required String reason}) async {
    if (_shuttingDown) return;
    final generation = ++_iptv.tuneGeneration;
    _iptv.deadTimer?.cancel();
    if (_iptv.deadChannelId != null) _setPlayerState(() => _iptv.deadChannelId = null);
    appLogger.i('IPTV: tune ${channel.numberLabel} ${channel.name} ($reason)');
    _iptvController.setTuned(channel.id);
    if (_iptv.fullScreen) _iptvShowBanner();
    await _iptvOpen(_iptvController.client.startIptvPlayback(channel), generation: generation);
  }

  /// Open [session]'s feed. A new channel ends the previous channel's
  /// report first; a failover keeps it.
  Future<void> _iptvOpen(IptvPlaybackSession session, {required int generation}) async {
    final currentPlayer = player;
    if (currentPlayer == null || _shuttingDown) return;
    final feed = session.feed;
    if (feed == null) {
      _iptvChannelDead(session.channel);
      return;
    }
    final previous = _live.session;
    final channelChanged = previous is! IptvPlaybackSession || previous.channel.id != session.channel.id;
    if (channelChanged && previous != null) {
      _stopLiveTimelineUpdates();
      await _sendLiveTimeline('stopped');
      if (!mounted || generation != _iptv.tuneGeneration) return;
    }
    _live.adoptSession(session);
    _live.markStreamRestartedAtLiveEdge(null);
    _hasFatalPlaybackError = false;
    _setPlayerState(() => _firstFrame.reset());
    _iptvBeganFeed(session, generation: generation);
    final feeds = session.channel.feeds.length;
    appLogger.i(
      'IPTV: ${session.channel.numberLabel} feed ${session.feedIndex + 1}/$feeds'
      '${session.retried ? ' (again)' : ''} ${iptvLogUrl(feed.url)}',
    );
    try {
      await _openLiveStream(currentPlayer, feed.url, headers: session.headers);
    } catch (e) {
      appLogger.w('IPTV: feed would not open: $e');
      if (mounted && generation == _iptv.tuneGeneration) unawaited(_iptvFailover('open threw'));
      return;
    }
    if (!mounted || generation != _iptv.tuneGeneration) return;
    if (channelChanged) {
      final channel = session.channel;
      final live = iptvLiveChannel(
        channel,
        serverId: _currentMetadata.serverId,
        serverName: _currentMetadata.serverName,
      );
      _setPlayerState(() {
        _live.channelIndex = _iptvController.allChannels.indexWhere((c) => c.id == channel.id);
        _live.channelName = channel.name;
        _currentMetadata = liveTvChannelItem(
          live,
          backend: _currentMetadata.backend,
          serverId: _currentMetadata.serverId,
        );
      });
      final mediaControlsManager = _mediaControlsManager;
      if (mediaControlsManager != null) {
        unawaited(
          mediaControlsManager.updateMetadata(
            metadata: _currentMetadata,
            client: _getOnlineMediaServerClient(context),
            duration: null,
          ),
        );
      }
      unawaited(_mediaControls.syncAvailability());
      _startLiveTimelineUpdates();
    }
  }

  /// A feed is opening: give it [IptvPlayerState.feedStartTimeout] to show
  /// a picture, then watch it for stalls.
  void _iptvBeganFeed(IptvPlaybackSession session, {required int generation}) {
    _iptv.watchdog?.cancel();
    _iptv.feedStarted = false;
    _iptv.errorSeen = false;
    _iptv.failingOver = false;
    _iptv.lastPosition = null;
    _iptv.openedAt = DateTime.now();
    _iptv.lastProgressAt = DateTime.now();
    _iptv.watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _shuttingDown || generation != _iptv.tuneGeneration) {
        _iptv.watchdog?.cancel();
        return;
      }
      _iptvWatch();
    });
  }

  void _iptvWatch() {
    final currentPlayer = player;
    if (currentPlayer == null || _iptv.failingOver) return;
    final now = DateTime.now();
    final sinceOpen = now.difference(_iptv.openedAt ?? now);
    // A failed open reports straight away, often many times (a playlist
    // walk); the first second is left for the old feed's last errors.
    if (_iptv.errorSeen && sinceOpen > const Duration(seconds: 1)) {
      unawaited(_iptvFailover('player error'));
      return;
    }
    final position = currentPlayer.state.position;
    final moved = _iptv.lastPosition != null && position != _iptv.lastPosition;
    _iptv.lastPosition = position;
    if (!_iptv.feedStarted) {
      if (_firstFrame.rendered || (moved && position > const Duration(seconds: 1))) {
        _iptv.feedStarted = true;
        _iptv.lastProgressAt = now;
        return;
      }
      if (sinceOpen > IptvPlayerState.feedStartTimeout) unawaited(_iptvFailover('no picture in time'));
      return;
    }
    // Paused by the viewer: not a stall.
    if (moved || !currentPlayer.state.playing) {
      _iptv.lastProgressAt = now;
      return;
    }
    if (now.difference(_iptv.lastProgressAt ?? now) > IptvPlayerState.stallTimeout) {
      unawaited(_iptvFailover('stalled'));
    }
  }

  /// The player reported an error on the open feed.
  void _iptvOnPlayerError(PlayerError err) {
    if (_iptv.deadChannelId != null || _iptv.failingOver) return;
    _iptv.errorSeen = true;
    final sinceOpen = DateTime.now().difference(_iptv.openedAt ?? DateTime.now());
    if (sinceOpen > const Duration(seconds: 1)) unawaited(_iptvFailover('player error: ${err.cause}'));
  }

  /// A feed played to its end (a live list that stopped): treat it as a
  /// drop.
  void _iptvOnStreamEnded() {
    if (_iptv.deadChannelId != null || _iptv.failingOver || !_iptv.feedStarted) return;
    unawaited(_iptvFailover('stream ended'));
  }

  /// This feed failed: the same one once more if it had played, else the
  /// next one; none left means the channel is dead.
  Future<void> _iptvFailover(String reason) async {
    if (_iptv.failingOver || _shuttingDown) return;
    final session = _live.session;
    if (session is! IptvPlaybackSession) return;
    _iptv.failingOver = true;
    _iptv.watchdog?.cancel();
    final next = _iptv.feedStarted ? (session.retryCurrent() ?? session.nextFeed()) : session.nextFeed();
    appLogger.w('IPTV: ${session.channel.numberLabel} feed ${session.feedIndex + 1} failed ($reason)');
    final generation = ++_iptv.tuneGeneration;
    // Stop the failed load first: a dead HLS open keeps walking its
    // playlist and reporting errors until stopped.
    final currentPlayer = player;
    if (currentPlayer != null) {
      try {
        await currentPlayer.stop();
      } catch (e) {
        appLogger.d('IPTV: stop before failover failed: $e');
      }
    }
    if (!mounted || generation != _iptv.tuneGeneration) return;
    if (next == null) {
      _iptvChannelDead(session.channel);
      return;
    }
    await _iptvOpen(next, generation: generation);
  }

  /// Every feed of [channel] failed: say so, mark it on this device, and go
  /// back to the guide.
  void _iptvChannelDead(IptvChannel channel) {
    appLogger.w('IPTV: ${channel.numberLabel} ${channel.name}: no feed works');
    _iptv.watchdog?.cancel();
    _iptv.failingOver = false;
    final currentPlayer = player;
    if (currentPlayer != null) unawaited(currentPlayer.stop().catchError((Object _) {}));
    _stopLiveTimelineUpdates();
    unawaited(_sendLiveTimeline('stopped'));
    _iptvController.markDead(channel.id);
    final wasFull = _iptv.fullScreen;
    _setPlayerState(() => _iptv.deadChannelId = channel.id);
    _iptv.deadTimer?.cancel();
    if (wasFull) {
      // The message over the picture, then the guide (it stays in the
      // corner window there until another channel is picked).
      _iptv.deadTimer = Timer(IptvPlayerState.deadMessageTime, () {
        if (mounted && _iptv.deadChannelId == channel.id) _iptvSetFullScreen(false);
      });
    }
  }

  // --- Channel keys -------------------------------------------------------

  Future<void> _iptvChannelStep(int step) async {
    final current = _iptvController.tunedChannelId ?? widget.iptv!.channel.id;
    final next = _iptvController.neighbourOf(current, step);
    if (next == null || next.id == current) return;
    await _iptvTune(next, reason: 'channel ${step > 0 ? 'up' : 'down'}');
  }

  Future<void> _iptvLastChannel() async {
    final last = _iptvController.lastChannel;
    if (last == null) return;
    await _iptvTune(last, reason: 'last channel');
  }

  void _iptvTuneNumber(int number) {
    final channel = _iptvController.channelByNumber(number);
    if (channel == null) {
      showAppSnackBar(context, t.iptv.noChannelNumber(number: iptvNumberLabel(number)));
      return;
    }
    if (channel.id == _iptvController.tunedChannelId && _iptv.deadChannelId == null) return;
    unawaited(_iptvTune(channel, reason: 'number $number'));
  }

  // --- Full screen and back ------------------------------------------------

  void _iptvSetFullScreen(bool full) {
    if (_iptv.fullScreen == full) return;
    _setPlayerState(() {
      _iptv.fullScreen = full;
      _iptv.backNoteShownAt = null;
      if (!full) _iptv.bannerUntil = null;
    });
    _iptvApplyOrientation();
    if (full) {
      _iptvShowBanner();
      _iptvFullFocusNode.requestFocus();
    }
  }

  /// On a phone the guide stays upright (its video window on top) and only
  /// full screen turns sideways (Adrian, 2026-10-16). Full screen follows the
  /// player's rotation lock, as other video does; tablets and TVs keep their
  /// own rule.
  void _iptvApplyOrientation({bool? rotationLocked}) {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    if (!_iptv.fullScreen) {
      unawaited(OrientationHelper.lockPortraitOnPhone());
      return;
    }
    final locked = rotationLocked ?? SettingsService.instanceOrNull?.read(SettingsService.rotationLocked) ?? true;
    unawaited(locked ? OrientationHelper.lockLandscapeOrientation() : OrientationHelper.restoreDefaultOrientations());
  }

  /// The banner for 5 s more; the remote's place starts on Guide.
  void _iptvShowBanner({IptvBannerButton? focus}) {
    _iptv.bannerTimer?.cancel();
    _setPlayerState(() {
      _iptv.bannerUntil = DateTime.now().add(IptvPlayerState.bannerTime);
      if (focus != null) _iptv.bannerFocus = focus;
    });
    _iptv.bannerTimer = Timer(IptvPlayerState.bannerTime, () {
      if (mounted) _setPlayerState(() => _iptv.bannerFocus = null);
    });
  }

  void _iptvBannerPressed(IptvBannerButton button) {
    switch (button) {
      case IptvBannerButton.channelDown:
        unawaited(_iptvChannelStep(-1));
      case IptvBannerButton.channelUp:
        unawaited(_iptvChannelStep(1));
      case IptvBannerButton.last:
        unawaited(_iptvLastChannel());
      case IptvBannerButton.guide:
        _iptvSetFullScreen(false);
    }
  }

  /// Keys over the full-screen picture: up/down and CH+/- flip channels,
  /// OK brings up the banner (then presses its button), left/right move
  /// along the banner, digits type a channel number.
  KeyEventResult _iptvFullScreenKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key.isBackKey) return KeyEventResult.ignored;
    if (_iptvNumbers.handleKey(event) == KeyEventResult.handled) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.channelDown) {
      if (event is KeyDownEvent) unawaited(_iptvChannelStep(key == LogicalKeyboardKey.channelUp ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (event is KeyDownEvent) {
        final focus = _iptv.bannerFocus;
        if (_iptv.bannerVisible && focus != null) {
          _iptvBannerPressed(focus);
          if (focus != IptvBannerButton.guide) _iptvShowBanner();
        } else {
          _iptvShowBanner(focus: IptvBannerButton.guide);
        }
      }
      return KeyEventResult.handled;
    }
    if (!key.isDpadDirection) return KeyEventResult.ignored;
    if (!event.isActionable) return KeyEventResult.handled;
    if (key.isUpKey || key.isDownKey) {
      unawaited(_iptvChannelStep(key.isUpKey ? 1 : -1));
      return KeyEventResult.handled;
    }
    const order = IptvBannerButton.values;
    final current = _iptv.bannerVisible ? _iptv.bannerFocus : null;
    if (current == null) {
      _iptvShowBanner(focus: IptvBannerButton.guide);
    } else {
      final index = (order.indexOf(current) + (key.isRightKey ? 1 : -1)).clamp(0, order.length - 1);
      _iptvShowBanner(focus: order[index]);
    }
    return KeyEventResult.handled;
  }

  /// Back in IPTV: a half-typed number is dropped; full screen goes to the
  /// guide; on the guide the first Back shows "Press Back again to leave"
  /// and a second one inside 3 s leaves.
  void _iptvBack() {
    if (_iptvNumbers.digits.isNotEmpty) {
      _iptvNumbers.cancel();
      return;
    }
    if (_iptv.fullScreen) {
      _iptvSetFullScreen(false);
      return;
    }
    if (_iptv.backNoteVisible) {
      _iptv.backNoteTimer?.cancel();
      unawaited(_iptvExit());
      return;
    }
    _setPlayerState(() => _iptv.backNoteShownAt = DateTime.now());
    _iptv.backNoteTimer?.cancel();
    _iptv.backNoteTimer = Timer(IptvPlayerState.backAgainWindow, () {
      if (mounted) _setPlayerState(() {});
    });
  }

  /// Leave IPTV at once; playback stops.
  Future<void> _iptvExit() {
    _iptv.watchdog?.cancel();
    return _exitPlayerRoute(navigateHome: false, stop: true);
  }

  // --- The page -------------------------------------------------------------

  /// The page: the guide with the video in its corner window, or the video
  /// full screen with its banner.
  Widget _buildIptvPage(BuildContext context, Widget video) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final layout = IptvLayout.of(size);
        final full = _iptv.fullScreen;
        final controller = _iptvController;
        final channel = controller.tunedChannel ?? widget.iptv!.channel;
        final dead = _iptv.deadChannelId != null;
        // Always the whole page: a loose Stack takes the size of its
        // un-positioned children (the Old School collapse, 2026-10-14).
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!full)
              Positioned.fill(
                child: IptvGuideView(
                  controller: controller,
                  layout: layout,
                  videoActive: !dead,
                  windowMessage: dead ? t.iptv.channelDead : null,
                  onTune: (picked) {
                    if (picked.id == controller.tunedChannelId && !dead) {
                      _iptvSetFullScreen(true);
                    } else {
                      unawaited(_iptvTune(picked, reason: 'guide'));
                    }
                  },
                  onEnlarge: () {
                    if (!dead) _iptvSetFullScreen(true);
                  },
                  onExit: () => unawaited(_iptvExit()),
                  onChannelStep: (step) => unawaited(_iptvChannelStep(step)),
                  onOtherKey: (_, event) => _iptvNumbers.handleKey(event),
                ),
              ),
            // In the corner the video lies over the guide's window, and
            // Video's opaque box would take the tap meant to enlarge it.
            // Always wrapped, so toggling keeps the same tree and the
            // player's state; hidden while the dead message shows.
            Positioned.fromRect(
              rect: full ? Offset.zero & size : layout.windowRect,
              child: IgnorePointer(
                ignoring: !full,
                child: Opacity(opacity: dead ? 0 : 1, child: video),
              ),
            ),
            // Loading or buffering in the corner: the spinner sits in the
            // window, not in the middle of the guide.
            if (!full && !dead)
              Positioned.fromRect(
                rect: layout.windowRect,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _isBuffering,
                    builder: (context, buffering, _) => ValueListenableBuilder<bool>(
                      valueListenable: _firstFrame.uiReady,
                      builder: (context, hasFrame, _) => buffering || !hasFrame
                          ? const Center(
                              child: SizedBox.square(
                                dimension: 36,
                                child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                              ),
                            )
                          : const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            if (full)
              Positioned.fill(
                child: Focus(
                  focusNode: _iptvFullFocusNode,
                  autofocus: true,
                  onKeyEvent: _iptvFullScreenKey,
                  child: MouseRegion(
                    opaque: false,
                    onHover: (_) => _iptvShowBanner(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (_iptv.bannerVisible) {
                          _iptv.bannerTimer?.cancel();
                          _setPlayerState(() {
                            _iptv.bannerUntil = null;
                            _iptv.bannerFocus = null;
                          });
                        } else {
                          _iptvShowBanner();
                        }
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (dead) const IptvDeadMessage(),
                          if (_iptv.bannerVisible && !dead) ...[
                            const IptvLiveBadge(),
                            IptvBanner(
                              controller: controller,
                              channel: channel,
                              focused: _iptv.bannerFocus,
                              onPressed: (button) {
                                _iptvBannerPressed(button);
                                if (button != IptvBannerButton.guide) _iptvShowBanner();
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(child: IptvNumberEntryBadge(entry: _iptvNumbers)),
            if (_iptv.backNoteVisible) const OldSchoolBackNote(),
          ],
        );
      },
    );
  }
}
