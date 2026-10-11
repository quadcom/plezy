part of '../../video_player_screen.dart';

/// Old School (PLAN_SHA_21): the player shows scheduled library items as if
/// live, with the guide on the same page. The video is full screen or in the
/// guide's corner window; Back shrinks it, then asks "Press Back again to
/// leave".
extension _VideoPlayerOldSchoolMethods on VideoPlayerScreenState {
  OldSchoolController get _osController => widget.oldSchool!.controller;

  OldSchoolControls get _oldSchoolControls => OldSchoolControls(
    onRestart: () => unawaited(_seekPlayback(Duration.zero)),
    onBackToLive: () => unawaited(_oldSchoolBackToLive()),
    onChannelUp: () => unawaited(_oldSchoolChannelStep(1)),
    onChannelDown: () => unawaited(_oldSchoolChannelStep(-1)),
    onGuide: () => _oldSchoolSetFullScreen(false),
  );

  void _oldSchoolSetFullScreen(bool full) {
    if (_os.fullScreen == full) return;
    _setPlayerState(() {
      _os.fullScreen = full;
      _os.backNoteShownAt = null;
    });
    if (full) {
      // The guide that held focus is gone; put the remote on play/pause.
      _chromeController.show(focusPlayPause: true);
    } else {
      _chromeController.hide(ignoreHolds: true);
    }
  }

  /// Back in Old School: full-screen video shrinks to the corner; with the
  /// guide showing, the first Back shows "Press Back again to leave" for
  /// about 3 seconds and a second one inside that time leaves.
  void _oldSchoolBack() {
    if (_os.fullScreen) {
      _oldSchoolSetFullScreen(false);
      return;
    }
    if (_os.backNoteVisible) {
      _os.backNoteTimer?.cancel();
      unawaited(_oldSchoolExit());
      return;
    }
    _setPlayerState(() => _os.backNoteShownAt = DateTime.now());
    _os.backNoteTimer?.cancel();
    _os.backNoteTimer = Timer(OldSchoolPlayerState.backAgainWindow, () {
      if (mounted) _setPlayerState(() {});
    });
  }

  /// Leave Old School at once; playback stops.
  Future<void> _oldSchoolExit() {
    _os.standbyTimer?.cancel();
    return _exitPlayerRoute(navigateHome: false, stop: true);
  }

  void _oldSchoolShowCard() {
    _os.cardTimer?.cancel();
    _setPlayerState(() => _os.cardUntil = DateTime.now().add(OldSchoolPlayerState.cardTime));
    _os.cardTimer = Timer(OldSchoolPlayerState.cardTime, () {
      if (mounted) _setPlayerState(() {});
    });
  }

  /// Tune [channelId] and play what's on at its scheduled point.
  Future<void> _oldSchoolTune(String channelId, {required String reason, bool showCard = true}) async {
    if (_shuttingDown) return;
    final generation = ++_os.tuneGeneration;
    _os.standbyTimer?.cancel();
    _setPlayerState(() => _os.tuning = true);
    try {
      final tune = await _osController.tuneTo(channelId);
      if (!mounted || generation != _os.tuneGeneration) return;
      if (showCard) _oldSchoolShowCard();
      await _oldSchoolPlay(tune, reason: reason, generation: generation);
    } catch (e, st) {
      appLogger.w('Old School: tune failed ($reason)', error: e, stackTrace: st);
      if (mounted && generation == _os.tuneGeneration) showErrorSnackBar(context, t.oldSchool.tuneFailed);
    } finally {
      if (mounted && generation == _os.tuneGeneration) _setPlayerState(() => _os.tuning = false);
    }
  }

  Future<void> _oldSchoolPlay(OldSchoolTune tune, {required String reason, required int generation}) async {
    final entry = tune.now;
    final currentPlayer = player;
    if (currentPlayer == null) return;
    if (!entry.isPlayable) {
      // Off the air: hold on the last picture until the next entry starts.
      await currentPlayer.pause();
      final next = tune.next;
      final wait = next == null ? const Duration(minutes: 1) : next.start.difference(tune.serverNow(DateTime.now()));
      _os.standbyTimer = Timer(wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1), () {
        if (mounted && generation == _os.tuneGeneration) {
          unawaited(_oldSchoolTune(tune.channelId, reason: 'after standby', showCard: false));
        }
      });
      return;
    }
    if (_currentMetadata.id == entry.itemId) {
      // Same file (Back to live, or the channel's next slot is the same
      // item): jump to the scheduled point. This is the one forward seek Old
      // School makes, so it goes past the lock.
      await _performSeekPlayback(tune.offsetInto(entry, DateTime.now()));
      if (!mounted || generation != _os.tuneGeneration) return;
      if (!currentPlayer.state.playing) await currentPlayer.play();
      return;
    }
    final item = await _osController.client.fetchItem(entry.itemId!);
    if (!mounted || generation != _os.tuneGeneration) return;
    if (item == null) throw StateError('Old School item ${entry.itemId} not found');
    await _reloadMediaInPlace(
      metadata: item,
      selectedMediaIndex: 0,
      // Worked out after the item lookup, so the request time is allowed for.
      resumePosition: tune.offsetInto(entry, DateTime.now()),
      useCurrentAudioStreamSelection: false,
      preserveCurrentTrackSelection: true,
      preservedAudioTrack: _sessionAudioPreference,
      preservedSubtitleTrack: _sessionSubtitlePreference,
      reason: 'old school $reason',
    );
  }

  /// Channel up (+1) or down (-1), wrapping round the line-up.
  Future<void> _oldSchoolChannelStep(int step) async {
    final current = _osController.tunedChannelId;
    if (current == null) return;
    final next = _osController.neighbourOf(current, step);
    if (next == null || next.id == current) return;
    await _oldSchoolTune(next.id, reason: 'channel step');
  }

  /// Back to the scheduled point on the tuned channel.
  Future<void> _oldSchoolBackToLive() async {
    final current = _osController.tunedChannelId;
    if (current == null) return;
    await _oldSchoolTune(current, reason: 'back to live', showCard: false);
  }

  /// A file ended: the channel's next entry joins at its scheduled point
  /// (jump to live, even after a pause).
  void _oldSchoolCarryOn() {
    final current = _osController.tunedChannelId;
    if (current == null) return;
    unawaited(_oldSchoolTune(current, reason: 'carry on', showCard: false));
  }

  /// [video] as it is, or inside the Old School page.
  Widget _wrapOldSchool(BuildContext context, Widget video) =>
      widget.isOldSchool ? _buildOldSchoolPage(context, video) : video;

  /// The page: the guide with the video in its corner window, or the video
  /// full screen with the channel watermark.
  Widget _buildOldSchoolPage(BuildContext context, Widget video) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final layout = OldSchoolLayout.of(size);
        final full = _os.fullScreen;
        final controller = _osController;
        final channel = controller.tunedChannel;
        return Stack(
          children: [
            if (!full)
              Positioned.fill(
                child: OldSchoolGuideView(
                  controller: controller,
                  layout: layout,
                  videoActive: true,
                  onTune: (picked) {
                    if (picked.id == controller.tunedChannelId) {
                      _oldSchoolSetFullScreen(true);
                    } else {
                      unawaited(_oldSchoolTune(picked.id, reason: 'guide'));
                    }
                  },
                  onEnlarge: () => _oldSchoolSetFullScreen(true),
                  onExit: () => unawaited(_oldSchoolExit()),
                  onChannelStep: (step) => unawaited(_oldSchoolChannelStep(step)),
                ),
              ),
            // In the corner the video lies over the guide's window, and Video's
            // opaque ColoredBox would take the tap meant to enlarge it. Always
            // wrapped, so toggling keeps the same tree and the player's state.
            Positioned.fromRect(
              rect: full ? Offset.zero & size : layout.windowRect,
              child: IgnorePointer(ignoring: !full, child: video),
            ),
            if (full && channel != null) OldSchoolWatermark(controller: controller, channel: channel),
            if (full && channel != null && _os.cardVisible)
              OldSchoolChannelCard(
                controller: controller,
                channel: channel,
                entry: controller.programmeAt(channel.id) ?? controller.tune?.now,
              ),
            if (_os.backNoteVisible) const OldSchoolBackNote(),
          ],
        );
      },
    );
  }
}
