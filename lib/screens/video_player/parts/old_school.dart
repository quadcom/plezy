part of '../../video_player_screen.dart';

/// Old School (PLAN_SHA_21): the player shows scheduled library items as if
/// live, with the guide on the same page. The video is full screen or in the
/// guide's corner window; Back shrinks it, then asks "Press Back again to
/// leave".
extension _VideoPlayerOldSchoolMethods on VideoPlayerScreenState {
  OldSchoolController get _osController => widget.oldSchool!.controller;

  OldSchoolControls get _oldSchoolControls => OldSchoolControls(
    onRestart: () => unawaited(_oldSchoolRestart()),
    onBackToLive: () => unawaited(_oldSchoolBackToLive()),
    onChannelUp: () => unawaited(_oldSchoolChannelStep(1)),
    onChannelDown: () => unawaited(_oldSchoolChannelStep(-1)),
    onGuide: () => _oldSchoolSetFullScreen(false),
    promoAction: (controlsVisible) {
      if (!_os.fullScreen || _os.playingPreRoll) return null;
      final promo = controlsVisible ? oldSchoolPromoTrailer(_osController) : oldSchoolActivePromo(_osController);
      if (promo == null || !oldSchoolPromoOpens(promo)) return null;
      return () => unawaited(_oldSchoolOpenPromo(promo));
    },
    promoTrailer: () {
      if (!_os.fullScreen || _os.playingPreRoll) return null;
      final promo = oldSchoolPromoTrailer(_osController);
      return promo == null ? null : oldSchoolTrailerTitle(promo);
    },
  );

  /// A film's own trailer starts or stops playing (PLAN_SHA_46): while it
  /// plays, its "Up next" card is all that shows and the controls stay down.
  void _oldSchoolSetPreRoll(bool on) {
    _chromeController.setSuppressed(on);
    if (_os.playingPreRoll != on) _setPlayerState(() => _os.playingPreRoll = on);
  }

  /// How much of the playing film trailer is left: from the player once the
  /// trailer is the open file, else from the schedule.
  Duration? _oldSchoolTrailerLeft() {
    final tune = _os.slotTune;
    if (tune == null) return null;
    final entry = tune.now;
    final currentPlayer = player;
    if (currentPlayer != null && _currentMetadata.id == entry.preItemId) {
      final duration = currentPlayer.state.duration;
      if (duration > Duration.zero) return duration - currentPlayer.state.position;
    }
    if (_os.filmFromStart) return entry.preRollTime;
    return entry.start.add(entry.preRollTime).difference(tune.serverNow(DateTime.now()));
  }

  /// OK on a trailer's end banner: open its film, series or course page and
  /// leave live TV, as the exit button does (PLAN_SHA_43).
  Future<void> _oldSchoolOpenPromo(OldSchoolEntry entry) async {
    final id = entry.promoItemId;
    if (id == null || _shuttingDown) return;
    final navigator = Navigator.of(context);
    try {
      final item = await _osController.client.fetchItem(id);
      if (!mounted) return;
      if (item == null) throw StateError('Old School promo item $id not found');
      await _oldSchoolExit();
      unawaited(navigator.push(mediaDetailRoute(metadata: item)));
    } catch (e, st) {
      appLogger.w('Old School: could not open the banner item', error: e, stackTrace: st);
    }
  }

  void _oldSchoolSetFullScreen(bool full) {
    if (_os.fullScreen == full) return;
    _setPlayerState(() {
      _os.fullScreen = full;
      _os.backNoteShownAt = null;
    });
    if (full) {
      // The guide that held focus is gone. Hand the remote to the player
      // surface with the controls down, so the picture comes back clean; the
      // first press brings the controls up (Adrian, 2026-10-11).
      _chromeController.hide(ignoreHolds: true);
      _screenFocusNode.requestFocus();
    } else {
      _chromeController.hide(ignoreHolds: true);
    }
  }

  /// Back in Old School: full-screen video first puts away the content strip
  /// and the controls (and the stats with them), as Back does in any
  /// playback, then shrinks to the corner; with the guide showing, the first
  /// Back shows "Press Back again to leave" for about 3 seconds and a second
  /// one inside that time leaves.
  void _oldSchoolBack() {
    if (_os.fullScreen) {
      if (_chromeController.contentStripVisible) {
        _chromeController.setContentStripVisible(false);
      } else if (_chromeController.controlsVisible) {
        _chromeController.hide();
      } else {
        _oldSchoolSetFullScreen(false);
      }
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
    _os.filmFromStart = false;
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
      _oldSchoolSetPreRoll(false);
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
    _os.slotTune = tune;
    // A film's own trailer first, while its share of the slot lasts
    // (PLAN_SHA_46); one that won't play leaves the film to start at once.
    if (tune.inPreRoll(entry, DateTime.now()) &&
        await _oldSchoolPlayPreRoll(tune, reason: reason, generation: generation)) {
      return;
    }
    if (!mounted || generation != _os.tuneGeneration) return;
    await _oldSchoolPlayFilm(tune, reason: reason, generation: generation);
  }

  /// Play [tune]'s film's own trailer: from its start on Start over, else
  /// where the slot is now. False when it would not open (no error shown),
  /// so the caller plays the film instead.
  Future<bool> _oldSchoolPlayPreRoll(OldSchoolTune tune, {required String reason, required int generation}) async {
    final entry = tune.now;
    final trailerId = entry.preItemId!;
    Duration position() => _os.filmFromStart ? Duration.zero : tune.slotOffset(entry, DateTime.now());
    try {
      if (_currentMetadata.id == trailerId) {
        await _performSeekPlayback(position());
        if (!mounted || generation != _os.tuneGeneration) return true;
        final currentPlayer = player;
        if (currentPlayer != null && !currentPlayer.state.playing) await currentPlayer.play();
        _oldSchoolSetPreRoll(true);
        return true;
      }
      final item = await _osController.client.fetchItem(trailerId);
      if (!mounted || generation != _os.tuneGeneration) return true;
      if (item == null) return false;
      _oldSchoolSetPreRoll(true);
      final outcome = await _reloadMediaInPlace(
        metadata: item,
        selectedMediaIndex: 0,
        resumePosition: position(),
        useCurrentAudioStreamSelection: false,
        preserveCurrentTrackSelection: true,
        preservedAudioTrack: _sessionAudioPreference,
        preservedSubtitleTrack: _sessionSubtitlePreference,
        showErrorUi: false,
        reason: 'old school trailer $reason',
      );
      if (outcome == MediaReloadOutcome.opened || outcome == MediaReloadOutcome.superseded) return true;
    } catch (e, st) {
      appLogger.w('Old School: pre-roll trailer would not play ($reason)', error: e, stackTrace: st);
    }
    if (mounted) _oldSchoolSetPreRoll(false);
    return false;
  }

  /// Play [tune]'s programme: at its scheduled point (after its trailer, if
  /// it has one), or from 0 after a Start over.
  Future<void> _oldSchoolPlayFilm(OldSchoolTune tune, {required String reason, required int generation}) async {
    final entry = tune.now;
    final currentPlayer = player;
    if (currentPlayer == null) return;
    Duration position() => _os.filmFromStart ? Duration.zero : tune.offsetInto(entry, DateTime.now());
    _oldSchoolSetPreRoll(false);
    if (_currentMetadata.id == entry.itemId) {
      // Same file (Back to live, or the channel's next slot is the same
      // item): jump to the scheduled point. This is the one forward seek Old
      // School makes, so it goes past the lock.
      await _performSeekPlayback(position());
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
      resumePosition: position(),
      useCurrentAudioStreamSelection: false,
      preserveCurrentTrackSelection: true,
      preservedAudioTrack: _sessionAudioPreference,
      preservedSubtitleTrack: _sessionSubtitlePreference,
      reason: 'old school $reason',
    );
  }

  /// The pre-roll trailer ended or would not play: the film follows in the
  /// same slot, with no re-tune and no channel card (PLAN_SHA_46).
  Future<void> _oldSchoolFilmAfterPreRoll(OldSchoolTune tune, {required String reason}) async {
    if (_shuttingDown) return;
    final generation = ++_os.tuneGeneration;
    try {
      await _oldSchoolPlayFilm(tune, reason: reason, generation: generation);
    } catch (e, st) {
      appLogger.w('Old School: film after its trailer failed ($reason)', error: e, stackTrace: st);
      if (mounted && generation == _os.tuneGeneration) showErrorSnackBar(context, t.oldSchool.tuneFailed);
    }
  }

  /// A pre-roll trailer that failed while opening or playing: the film plays
  /// instead, with no error shown. True when handled.
  bool _oldSchoolPreRollFailed() {
    final tune = _os.slotTune;
    if (!widget.isOldSchool || !_os.playingPreRoll || tune == null) return false;
    appLogger.w('Old School: pre-roll trailer failed, playing the film');
    unawaited(_oldSchoolFilmAfterPreRoll(tune, reason: 'trailer failed'));
    return true;
  }

  /// Start over: the file from its beginning. On a film with its own
  /// trailer, the trailer from its start and then the film from 0, not the
  /// live point (PLAN_SHA_46; the web does the same).
  Future<void> _oldSchoolRestart() async {
    final tune = _os.slotTune;
    if (tune == null || !tune.now.hasPreRoll || tune.channelId != _osController.tunedChannelId) {
      await _seekPlayback(Duration.zero);
      return;
    }
    final generation = ++_os.tuneGeneration;
    _os.standbyTimer?.cancel();
    _os.filmFromStart = true;
    try {
      if (await _oldSchoolPlayPreRoll(tune, reason: 'start over', generation: generation)) return;
      if (!mounted || generation != _os.tuneGeneration) return;
      await _oldSchoolPlayFilm(tune, reason: 'start over', generation: generation);
    } catch (e, st) {
      appLogger.w('Old School: start over failed', error: e, stackTrace: st);
    }
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
  /// (jump to live, even after a pause). A film's own trailer hands over to
  /// the film; a programme that ended before its slot did (its trailer would
  /// not play) holds on its last picture until the slot ends.
  void _oldSchoolCarryOn() {
    final current = _osController.tunedChannelId;
    if (current == null) return;
    final slot = _os.slotTune;
    if (slot != null && slot.channelId == current) {
      if (_os.playingPreRoll) {
        unawaited(_oldSchoolFilmAfterPreRoll(slot, reason: 'after trailer'));
        return;
      }
      final left = slot.now.end.difference(slot.serverNow(DateTime.now()));
      if (slot.now.isProgramme && left > const Duration(seconds: 1)) {
        final generation = _os.tuneGeneration;
        _os.standbyTimer?.cancel();
        _os.standbyTimer = Timer(left + const Duration(milliseconds: 500), () {
          if (mounted && generation == _os.tuneGeneration) {
            unawaited(_oldSchoolTune(current, reason: 'carry on', showCard: false));
          }
        });
        return;
      }
    }
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
        // Always the whole page. The outer player stack hands this one loose
        // constraints, and a loose Stack takes the size of its un-positioned
        // children: an idle overlay that returned an empty box collapsed the
        // page to 0x0 and clipped every control and overlay (Windows,
        // 2026-10-14; the native video plane is placed by its own layout, so
        // only the picture survived).
        return Stack(
          fit: StackFit.expand,
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
            // During a film's own trailer its card's logo stands in for the
            // watermark, and nothing else shows (PLAN_SHA_46/47).
            if (full && channel != null && !_os.playingPreRoll)
              OldSchoolWatermark(controller: controller, channel: channel),
            if (full && channel != null)
              ValueListenableBuilder<bool>(
                valueListenable: _chromeController,
                builder: (context, controlsVisible, _) => OldSchoolPromoCorner(
                  controller: controller,
                  controlsVisible: controlsVisible,
                  onOpen: (entry) => unawaited(_oldSchoolOpenPromo(entry)),
                ),
              ),
            if (full && channel != null)
              OldSchoolPreRollCard(
                controller: controller,
                channel: channel,
                film: _os.playingPreRoll ? _os.slotTune?.now : null,
                trailerLeft: _oldSchoolTrailerLeft,
              ),
            if (full && channel != null && _os.cardVisible && !_os.playingPreRoll)
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
