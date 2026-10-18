import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../models/old_school.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';
import '../../watch_together/providers/watch_together_provider.dart';
import '../video_player/old_school_session.dart';
import '../video_player_screen.dart';
import 'old_school_controller.dart';
import 'old_school_guide_view.dart';
import 'old_school_layout.dart';
import 'old_school_overlays.dart';

/// Whether Old School can be opened: signed in to a PlezyFin server that
/// offers it (PlezyFinVersion 2 or later).
bool oldSchoolAvailable(BuildContext context) => context.watch<HiddenLibrariesProvider>().oldSchoolClient != null;

/// Open Old School full screen over the app (no side rail, top bar or
/// bottom bar). It starts on the channel last tuned on this device; with none
/// remembered, nothing plays until a programme that's on now is picked.
Future<void> openOldSchool(BuildContext context) async {
  final client = context.read<HiddenLibrariesProvider>().oldSchoolClient;
  if (client == null) return;
  // Watch Together re-seeks every viewer, which Old School can't allow.
  if (context.read<WatchTogetherProvider?>()?.isInSession ?? false) {
    showAppSnackBar(context, t.oldSchool.noWatchTogether);
    return;
  }
  final controller = OldSchoolController(client);
  unawaited(controller.load());
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      settings: const RouteSettings(name: '/old_school'),
      pageBuilder: (_, _, _) => OldSchoolScreen(controller: controller),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}

/// The guide before anything plays. Picking a programme that's on now hands
/// over to the player, which carries the same guide with the video in its
/// corner window.
class OldSchoolScreen extends StatefulWidget {
  final OldSchoolController controller;

  const OldSchoolScreen({super.key, required this.controller});

  @override
  State<OldSchoolScreen> createState() => _OldSchoolScreenState();
}

class _OldSchoolScreenState extends State<OldSchoolScreen> {
  bool _handedOver = false;
  bool _tuning = false;
  bool _resumeChecked = false;
  DateTime? _backNoteAt;
  Timer? _backNoteTimer;

  bool get _backNoteVisible {
    final at = _backNoteAt;
    return at != null && DateTime.now().difference(at) < OldSchoolPlayerState.backAgainWindow;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resumeLastChannel);
    _resumeLastChannel();
  }

  /// Once the line-up is in, tune the channel last played on this device
  /// (Adrian, 2026-10-18). A channel that's gone, or one with nothing on,
  /// leaves the guide as it is.
  void _resumeLastChannel() {
    final controller = widget.controller;
    if (_resumeChecked || !controller.hasLoaded) return;
    _resumeChecked = true;
    controller.removeListener(_resumeLastChannel);
    final channel = controller.channelById(SettingsService.instanceOrNull?.read(SettingsService.oldSchoolLastChannel));
    if (channel != null) unawaited(_tune(channel, quiet: true));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resumeLastChannel);
    _backNoteTimer?.cancel();
    // Once the player has taken over, it owns the controller.
    if (!_handedOver) widget.controller.dispose();
    super.dispose();
  }

  void _leave() => Navigator.of(context).pop();

  /// First Back: "Press Back again to leave" for about 3 seconds; a second
  /// Back inside that time leaves.
  void _onBack() {
    if (_backNoteVisible) {
      _backNoteTimer?.cancel();
      _leave();
      return;
    }
    setState(() => _backNoteAt = DateTime.now());
    _backNoteTimer?.cancel();
    _backNoteTimer = Timer(OldSchoolPlayerState.backAgainWindow, () {
      if (mounted) setState(() {});
    });
  }

  /// [quiet] (the automatic start) shows no message when nothing is on or
  /// the tune fails; the guide is still there to pick from.
  Future<void> _tune(OldSchoolChannel channel, {bool quiet = false}) async {
    if (_tuning) return;
    setState(() => _tuning = true);
    final controller = widget.controller;
    try {
      var tune = await controller.tuneTo(channel.id);
      // A standby gap can be under a second (the leftover after trailers,
      // PlezyFin): wait it out and tune again once.
      final gapLeft = tune.next?.start.difference(tune.serverNow(DateTime.now()));
      if (!tune.now.isPlayable && gapLeft != null && gapLeft < const Duration(seconds: 5)) {
        await Future<void>.delayed((gapLeft.isNegative ? Duration.zero : gapLeft) + const Duration(milliseconds: 300));
        if (!mounted) return;
        tune = await controller.tuneTo(channel.id);
      }
      final entry = tune.now;
      if (!mounted) return;
      if (!entry.isPlayable) {
        if (!quiet) showAppSnackBar(context, t.oldSchool.nothingOn);
        return;
      }
      // A film's own trailer first while it is still on (PLAN_SHA_46); a
      // trailer that can't be found leaves the film to start at once.
      MediaItem? trailer;
      if (tune.inPreRoll(entry, DateTime.now())) {
        try {
          trailer = await controller.client.fetchItem(entry.preItemId!);
        } catch (e, st) {
          appLogger.w('Old School: pre-roll trailer lookup failed', error: e, stackTrace: st);
        }
        if (!mounted) return;
      }
      final item = trailer ?? await controller.client.fetchItem(entry.itemId!);
      if (!mounted) return;
      if (item == null) throw StateError('Old School item ${entry.itemId} not found');
      _handedOver = true;
      final route = VideoPlayerRoute(
        builder: (_) => VideoPlayerScreen(
          metadata: item,
          // Worked out when the player is built, so the lookups above are
          // allowed for.
          initialPosition: trailer != null
              ? tune.slotOffset(entry, DateTime.now())
              : tune.offsetInto(entry, DateTime.now()),
          oldSchool: OldSchoolSessionArgs(controller: controller, tune: tune, startsInPreRoll: trailer != null),
        ),
      );
      unawaited(route.push(Navigator.of(context), replaceCurrent: true));
    } catch (e, st) {
      appLogger.w('Old School: could not start playback', error: e, stackTrace: st);
      _handedOver = false;
      if (mounted && !quiet) showErrorSnackBar(context, t.oldSchool.tuneFailed);
    } finally {
      if (mounted) setState(() => _tuning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || BackKeyCoordinator.consumeIfHandled()) return;
        _onBack();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => handleBackKeyAction(event, _onBack),
        child: Scaffold(
          backgroundColor: tk.bg,
          body: SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final layout = OldSchoolLayout.of(constraints.biggest);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: OldSchoolGuideView(
                        controller: widget.controller,
                        layout: layout,
                        videoActive: false,
                        onTune: (channel) => unawaited(_tune(channel)),
                        onEnlarge: () {},
                        onExit: _leave,
                      ),
                    ),
                    if (_tuning)
                      Positioned.fromRect(
                        rect: layout.windowRect,
                        child: const ColoredBox(
                          color: Colors.black,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    if (_backNoteVisible) const OldSchoolBackNote(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
