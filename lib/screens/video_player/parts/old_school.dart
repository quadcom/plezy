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
    // The corner shows for the whole trailer, so OK opens it controls up or
    // down.
    promoAction: () {
      if (!_os.fullScreen || _os.playingPreRoll) return null;
      final promo = oldSchoolActivePromo(_osController);
      if (promo == null || !oldSchoolPromoOpens(promo)) return null;
      return () => unawaited(_oldSchoolOpenPromo(promo));
    },
    promoTrailer: () {
      if (!_os.fullScreen || _os.playingPreRoll) return null;
      final promo = oldSchoolPromoTrailer(_osController);
      return promo == null ? null : oldSchoolTrailerTitle(promo);
    },
    matchSourceActive: () => _oldSchoolMatchSourceOffered ? _os.matchSourceEntry != null : null,
    onToggleMatchSource: () => unawaited(_oldSchoolToggleMatchSource()),
  );

  /// Match source (local/plans/old-school-match-source.md) is offered on
  /// Android TV, where display modes can be switched, while a programme
  /// plays: not during a film's own trailer, which comes before the feature.
  bool get _oldSchoolMatchSourceOffered {
    if (!Platform.isAndroid || !PlatformDetector.isTV()) return false;
    final tune = _os.slotTune;
    return tune != null && tune.channelId == _osController.tunedChannelId && tune.now.isPlayable && !_os.playingPreRoll;
  }

  /// Whether [tune] plays the entry Match source was turned on for.
  bool _oldSchoolIsMatchedEntry(OldSchoolTune tune) {
    final matched = _os.matchSourceEntry;
    return matched != null &&
        tune.channelId == _os.matchSourceChannelId &&
        tune.now.start == matched.start &&
        tune.now.itemId == matched.itemId;
  }

  Future<void> _oldSchoolToggleMatchSource() async {
    if (_os.matchSourceBusy) return;
    if (_os.matchSourceEntry != null) {
      await _oldSchoolEndMatchSource(rejoin: true);
    } else if (_oldSchoolMatchSourceOffered) {
      await _oldSchoolStartMatchSource();
    }
  }

  /// Switch the display to the programme's own resolution and frame rate,
  /// so the TV or the receiver does the upscaling (Adrian, 2026-10-18: the
  /// Theater's Onkyo upscales 1080p better than the SHIELD). For this
  /// programme only; the next entry or a channel change ends it.
  Future<void> _oldSchoolStartMatchSource() async {
    final tune = _os.slotTune;
    final currentPlayer = player;
    if (tune == null || currentPlayer == null) return;
    _setPlayerState(() {
      _os.matchSourceEntry = tune.now;
      _os.matchSourceChannelId = tune.channelId;
      _os.matchSourceBusy = true;
    });
    try {
      final settingsService = await SettingsService.getInstance();
      final output = await PlayerOutputFormat.read(currentPlayer);
      if (!mounted || player != currentPlayer) return;
      final target = _displayTargetFor(settingsService, output);
      if (target == null) {
        appLogger.d('Old School: Match source found no display target');
        _setPlayerState(() => _os.matchSourceEntry = null);
        return;
      }
      await _oldSchoolSwitchDisplay(
        currentPlayer,
        () => _switchDisplayToTarget(
          currentPlayer: currentPlayer,
          settingsService: settingsService,
          target: target,
          reason: 'old school match source',
        ),
      );
      await _oldSchoolRejoinAfterSwitch(currentPlayer);
    } catch (e, st) {
      appLogger.w('Old School: Match source failed', error: e, stackTrace: st);
      if (mounted) _setPlayerState(() => _os.matchSourceEntry = null);
    } finally {
      if (mounted) _setPlayerState(() => _os.matchSourceBusy = false);
    }
  }

  /// Back to Old School's fixed mode: film rate at full resolution with the
  /// 24 Hz setting on, else the TV's own mode. [rejoin] (the button) picks
  /// the programme up again at its scheduled point; otherwise the next
  /// entry is about to open.
  Future<void> _oldSchoolEndMatchSource({required bool rejoin}) async {
    final currentPlayer = player;
    _setPlayerState(() {
      _os.matchSourceEntry = null;
      _os.matchSourceChannelId = null;
      _os.matchSourceBusy = true;
    });
    try {
      if (currentPlayer == null) return;
      final settingsService = await SettingsService.getInstance();
      if (!mounted || player != currentPlayer) return;
      await _oldSchoolSwitchDisplay(currentPlayer, () async {
        if (settingsService.read(SettingsService.oldSchoolFilmRate)) {
          await _switchDisplayToTarget(
            currentPlayer: currentPlayer,
            settingsService: settingsService,
            target: (fps: _oldSchoolFilmFps, width: _oldSchoolFixedWidth, height: _oldSchoolFixedHeight),
            reason: 'old school match source off',
            matchResolution: true,
            refreshDecoder: rejoin,
          );
        } else {
          await currentPlayer.clearVideoFrameRate();
          await Future<void>.delayed(_oldSchoolRestoreSettle);
          if (rejoin && mounted && player == currentPlayer) {
            await _refreshAndroidMpvDecoderAfterFrameRateSwitch(reason: 'old school match source off');
          }
        }
      });
      if (rejoin) await _oldSchoolRejoinAfterSwitch(currentPlayer);
    } catch (e, st) {
      appLogger.w('Old School: ending Match source failed', error: e, stackTrace: st);
    } finally {
      if (mounted) _setPlayerState(() => _os.matchSourceBusy = false);
    }
  }

  /// Run a display switch with playback paused, so the clock doesn't run on
  /// while the HDMI chain resyncs.
  Future<void> _oldSchoolSwitchDisplay(Player currentPlayer, Future<void> Function() doSwitch) async {
    try {
      await currentPlayer.pause();
    } catch (e) {
      appLogger.w('Old School: failed to pause before a display switch', error: e);
    }
    await doSwitch();
  }

  /// After a Match source switch: back to the programme's scheduled point
  /// (the switch paused it for a few seconds), or just play on after a
  /// Start over, which is off the schedule.
  Future<void> _oldSchoolRejoinAfterSwitch(Player currentPlayer) async {
    if (!mounted || player != currentPlayer) return;
    final tune = _os.slotTune;
    if (tune != null && !_os.filmFromStart && !_os.playingPreRoll && _currentMetadata.id == tune.now.itemId) {
      await _oldSchoolPlayFilm(tune, reason: 'match source', generation: _os.tuneGeneration);
      return;
    }
    await _playWithPlaybackIntent(currentPlayer);
  }

  /// A film's own trailer starts or stops playing (PLAN_SHA_46): while it
  /// plays, its "Up next" card is all that shows and the controls stay down.
  void _oldSchoolSetPreRoll(bool on) {
    _chromeController.setSuppressed(on);
    if (_os.playingPreRoll != on) _setPlayerState(() => _os.playingPreRoll = on);
  }

  /// The speed the open file plays at (PLAN_SHA_26 Amendment 1): the slot's
  /// stretch for its own item; 1 for a film's own trailer, and after Start
  /// over, which is off the schedule anyway (the web does the same).
  double get _oldSchoolRate {
    final entry = _os.slotTune?.now;
    if (entry == null || _os.playingPreRoll || _os.filmFromStart) return 1.0;
    return entry.rate;
  }

  /// Put the player at [_oldSchoolRate]. Every Old School open goes through
  /// here before the file starts; the player is thrown away when Old School
  /// is left, so normal viewing never inherits a slowed speed.
  Future<void> _oldSchoolApplyRate(Player currentPlayer) async {
    final rate = _oldSchoolRate;
    if (currentPlayer.state.rate == rate) return;
    appLogger.d('Old School: playback speed $rate');
    await currentPlayer.setRate(rate);
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

  /// Show the "Now playing" card for [entry] for
  /// [OldSchoolPlayerState.startCardTime].
  void _oldSchoolShowStartCard(OldSchoolEntry entry) {
    _os.startCardTimer?.cancel();
    _setPlayerState(() {
      _os.startCardEntry = entry;
      _os.startCardUntil = DateTime.now().add(OldSchoolPlayerState.startCardTime);
    });
    _os.startCardTimer = Timer(OldSchoolPlayerState.startCardTime, () {
      if (mounted) _setPlayerState(() {});
    });
  }

  void _oldSchoolHideStartCard() {
    _os.startCardTimer?.cancel();
    if (_os.startCardUntil == null) return;
    _setPlayerState(() => _os.startCardUntil = null);
  }

  /// Whether [entry] gets the "Now playing" card as it opens: a TV episode,
  /// or a film without a trailer of its own (one with a trailer had the
  /// "Up next" card over it), starting at its beginning on the schedule.
  bool _oldSchoolStartsWithCard(OldSchoolTune tune, OldSchoolEntry entry) {
    final kind = entry.kind;
    final counts = kind == OldSchoolEntryKind.episode || (kind == OldSchoolEntryKind.movie && !entry.hasPreRoll);
    if (!counts || _os.filmFromStart) return false;
    return tune.offsetInto(entry, DateTime.now()) < OldSchoolPlayerState.startCardWindow;
  }

  /// Tune [channelId] and play what's on at its scheduled point.
  Future<void> _oldSchoolTune(String channelId, {required String reason, bool showCard = true}) async {
    if (_shuttingDown) return;
    final generation = ++_os.tuneGeneration;
    _oldSchoolHideStartCard();
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
    // Match source lasts for its programme only: anything else on, or
    // another channel, goes back to the fixed mode first so quick channel
    // changes work again (Adrian, 2026-10-18).
    if (_os.matchSourceEntry != null && !_oldSchoolIsMatchedEntry(tune)) {
      await _oldSchoolEndMatchSource(rejoin: false);
      if (!mounted || generation != _os.tuneGeneration) return;
    }
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
        _oldSchoolSetPreRoll(true);
        if (currentPlayer != null) {
          await _oldSchoolApplyRate(currentPlayer);
          if (!mounted || generation != _os.tuneGeneration) return true;
          if (!currentPlayer.state.playing) await currentPlayer.play();
        }
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
        // Each file opens on its own default audio track: carrying the last
        // file's track matched a stereo trailer to a stereo commentary
        // (local/plans/old-school-audio-track.md). Only a subtitle choice
        // the viewer made carries over.
        preferredSubtitleTrackOverride: _sessionSubtitlePreference,
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
      await _oldSchoolApplyRate(currentPlayer);
      if (!mounted || generation != _os.tuneGeneration) return;
      await _performSeekPlayback(position());
      if (!mounted || generation != _os.tuneGeneration) return;
      if (!currentPlayer.state.playing) await currentPlayer.play();
      return;
    }
    final item = await _osController.client.fetchItem(entry.itemId!);
    if (!mounted || generation != _os.tuneGeneration) return;
    if (item == null) throw StateError('Old School item ${entry.itemId} not found');
    final startCard = _oldSchoolStartsWithCard(tune, entry);
    final outcome = await _reloadMediaInPlace(
      metadata: item,
      selectedMediaIndex: 0,
      // Worked out after the item lookup, so the request time is allowed for.
      resumePosition: position(),
      useCurrentAudioStreamSelection: false,
      // Same rule as the trailer above: the programme's own default audio.
      preferredSubtitleTrackOverride: _sessionSubtitlePreference,
      reason: 'old school $reason',
    );
    if (startCard && outcome == MediaReloadOutcome.opened && mounted && generation == _os.tuneGeneration) {
      _oldSchoolShowStartCard(entry);
    }
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
      // Off the schedule from here, so at normal speed.
      _os.filmFromStart = true;
      final currentPlayer = player;
      if (currentPlayer != null) await _oldSchoolApplyRate(currentPlayer);
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

  /// [video] as it is, or inside the Old School or IPTV page.
  Widget _wrapOldSchool(BuildContext context, Widget video) => widget.isOldSchool
      ? _buildOldSchoolPage(context, video)
      : widget.isIptv
      ? _buildIptvPage(context, video)
      : video;

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
            if (full && channel != null && !_os.playingPreRoll && _os.startCardShowing == null)
              ValueListenableBuilder<bool>(
                valueListenable: _chromeController,
                builder: (context, controlsVisible, _) =>
                    OldSchoolWatermark(controller: controller, channel: channel, controlsVisible: controlsVisible),
              ),
            if (full && channel != null)
              OldSchoolPromoCorner(controller: controller, onOpen: (entry) => unawaited(_oldSchoolOpenPromo(entry))),
            // The main feature's poster corner (local/plans/playback-corner.md).
            if (full && channel != null && _posterCornerShows(context)) _posterCorner(),
            if (full && channel != null)
              OldSchoolPreRollCard(
                controller: controller,
                channel: channel,
                film: _os.playingPreRoll ? _os.slotTune?.now : null,
                trailerLeft: _oldSchoolTrailerLeft,
              ),
            // The same card as "Now playing", no countdown, as a programme
            // starts (local/plans/old-school-episode-banner.md).
            if (full && channel != null)
              OldSchoolPreRollCard(controller: controller, channel: channel, film: _os.startCardShowing),
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
