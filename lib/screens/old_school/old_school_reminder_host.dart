import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../services/image_cache_service.dart';
import '../../services/old_school_reminder_alarms.dart';
import '../../services/old_school_reminders.dart';
import '../../services/playback_coordinator.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/corner_band.dart';
import 'old_school_screen.dart';

/// The app-wide Old School reminder notice
/// (local/plans/old-school-future-details.md). [OldSchoolReminderService]
/// raises it a minute before a reminded programme starts, on whatever screen
/// is up. At zero it changes the channel: in place when Old School is open,
/// else it stops what is playing and opens Old School on that channel.
///
/// It looks and arrives like Old School's top-right break block
/// (local/plans/old-school-reminder-banner.md, Adrian 2026-11-01): the
/// corner band along the top, "Starts on 4 Films", the name, the episode, an
/// amber "Switching in 0:42" and a hint line, the poster breaking out on the
/// right, step by step. No buttons: OK / Enter / a tap or click is Watch now;
/// Back / Esc, or swiping it away on a phone, is Stay.
class OldSchoolReminderHost extends StatefulWidget {
  final Widget child;
  final OldSchoolReminderService? service;

  /// Where Old School is opened from when it isn't already up; null uses the
  /// profile's navigator.
  final NavigatorState? Function()? navigator;

  const OldSchoolReminderHost({super.key, required this.child, this.service, this.navigator});

  @override
  State<OldSchoolReminderHost> createState() => _OldSchoolReminderHostState();
}

class _OldSchoolReminderHostState extends State<OldSchoolReminderHost> with SingleTickerProviderStateMixin {
  /// A notice that turns up late (the app was opened after the start) still
  /// counts down this long, so it can be answered.
  static const _minCountdown = Duration(seconds: 10);

  /// The entrance, timed as the break block's (OldSchoolPromoCorner).
  static const _steps = 20;
  static const _fadeOut = Duration(milliseconds: 350);

  /// A swipe this far, or this fast, to the right is Stay.
  static const _swipeDistance = 60.0;
  static const _swipeVelocity = 400.0;

  late final AnimationController _entrance = AnimationController(vsync: this, duration: cornerUnit * _steps);

  OldSchoolReminderService get _service => widget.service ?? OldSchoolReminderService.instance;

  /// The reminder being counted down, or null.
  OldSchoolReminder? _showing;

  /// What is drawn: [_showing], or the last one while it fades out.
  OldSchoolReminder? _drawn;
  String? _posterUrl;
  DateTime? _switchAt;
  Timer? _tick;
  Timer? _clearDrawn;
  double _drag = 0;
  FocusNode? _previousFocus;
  final FocusNode _noticeFocus = FocusNode(debugLabel: 'old_school_reminder_notice');

  /// A channel from a tapped phone notification, waiting until Old School
  /// can be opened (signed in, profile picked).
  String? _pendingOpen;
  StreamSubscription<String>? _opens;

  @override
  void initState() {
    super.initState();
    _service.due.addListener(_onDue);
    _service.addListener(_tryPendingOpen);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onDue();
    });
    if (OldSchoolReminderAlarms.supported) {
      _opens = OldSchoolReminderAlarms.instance.opens.listen(_openFromNotification);
      unawaited(
        OldSchoolReminderAlarms.instance.takeLaunchChannel().then((channelId) {
          if (channelId != null && mounted) _openFromNotification(channelId);
        }),
      );
    }
  }

  void _openFromNotification(String channelId) {
    _pendingOpen = channelId;
    _tryPendingOpen();
  }

  void _tryPendingOpen() {
    final channelId = _pendingOpen;
    if (channelId == null || !mounted) return;
    if (_service.client == null || profileNavigationRegistry.navigator == null) return;
    _pendingOpen = null;
    // The reminder it was for is done; its in-app notice won't show again.
    final reminder = _service.reminders.where((r) => r.channelId == channelId).firstOrNull;
    if (reminder != null) _service.finish(reminder);
    if (_showing?.channelId == channelId) _close(restoreFocus: false);
    unawaited(_tuneChannel(channelId));
  }

  @override
  void dispose() {
    _service.due.removeListener(_onDue);
    _service.removeListener(_tryPendingOpen);
    unawaited(_opens?.cancel());
    _tick?.cancel();
    _clearDrawn?.cancel();
    _entrance.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  void _onDue() {
    final reminder = _service.due.value;
    if (reminder?.id == _showing?.id) return;
    _tick?.cancel();
    if (reminder == null) {
      _close(restoreFocus: true);
      return;
    }
    final now = DateTime.now().toUtc();
    final start = reminder.start ?? now;
    final earliest = now.add(_minCountdown);
    _clearDrawn?.cancel();
    setState(() {
      _showing = reminder;
      _drawn = reminder;
      _posterUrl = null;
      _drag = 0;
      _switchAt = start.isAfter(earliest) ? start : earliest;
    });
    unawaited(_entrance.forward(from: 0));
    unawaited(_loadPoster(reminder));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // OK and Back reach the notice through focus; a phone just taps.
    if (!PlatformDetector.isMobile(context)) {
      _previousFocus ??= FocusManager.instance.primaryFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showing != null) _noticeFocus.requestFocus();
      });
    }
  }

  /// The poster: the reminder only names the item, so one look-up per
  /// notice; an episode shows its series' poster.
  Future<void> _loadPoster(OldSchoolReminder reminder) async {
    final client = _service.client;
    final itemId = reminder.itemId;
    if (client == null || itemId == null) return;
    try {
      final item = await client.fetchItem(itemId);
      final path = item?.posterThumb();
      if (!mounted || path == null || _drawn?.id != reminder.id) return;
      final size = MediaQuery.sizeOf(context);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final s = _scale(size);
      setState(
        () => _posterUrl = client.thumbnailUrl(
          path,
          width: (CornerLayout.posterWidth * s * dpr).round(),
          height: (CornerLayout.posterHeight * s * dpr).round(),
        ),
      );
    } catch (e, st) {
      appLogger.w('Old School reminder: poster look-up failed', error: e, stackTrace: st);
    }
  }

  void _onTick() {
    final at = _switchAt;
    if (!mounted || at == null) return;
    if (!DateTime.now().toUtc().isBefore(at)) {
      unawaited(_switch());
    } else {
      setState(() {});
    }
  }

  void _close({required bool restoreFocus}) {
    _tick?.cancel();
    _tick = null;
    final previous = _previousFocus;
    _previousFocus = null;
    if (mounted) {
      setState(() {
        _showing = null;
        _switchAt = null;
      });
      // Kept on screen while it fades out.
      _clearDrawn?.cancel();
      _clearDrawn = Timer(_fadeOut, () {
        if (mounted && _showing == null) {
          setState(() {
            _drawn = null;
            _posterUrl = null;
          });
        }
      });
    }
    if (restoreFocus && previous != null && previous.context != null && previous.canRequestFocus) {
      previous.requestFocus();
    } else if (_noticeFocus.hasFocus) {
      _noticeFocus.unfocus();
    }
  }

  void _stay() {
    final reminder = _showing;
    if (reminder == null) return;
    _close(restoreFocus: true);
    _service.finish(reminder);
  }

  Future<void> _switch() async {
    final reminder = _showing;
    if (reminder == null) return;
    // Focus goes to whatever the switch opens.
    _close(restoreFocus: false);
    _service.finish(reminder);
    await _tuneChannel(reminder.channelId);
  }

  /// Change to [channelId]: in place when Old School is open, else stop
  /// what plays and open Old School on it.
  Future<void> _tuneChannel(String channelId) async {
    if (_service.tuneInPlace?.call(channelId) ?? false) return;
    try {
      // Whatever plays outside Old School stops first.
      if (PlaybackCoordinator.instance.hasVideoSession) {
        await PlaybackCoordinator.instance.stopVideoAndExit();
      }
      final navigator = widget.navigator?.call() ?? profileNavigationRegistry.navigator;
      final overlayContext = navigator?.overlay?.context;
      if (overlayContext == null || !overlayContext.mounted) return;
      await openOldSchool(overlayContext, channelId: channelId);
    } catch (e, st) {
      appLogger.w('Old School reminder: could not open the channel', error: e, stackTrace: st);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_showing == null) return KeyEventResult.ignored;
    final back = handleBackKeyAction(event, _stay);
    if (back != KeyEventResult.ignored) return back;
    return handleOneShotSelect(event, () => unawaited(_switch()));
  }

  /// Sizes in units of a 960-wide screen, as the corner overlays; never so
  /// small on a phone that the text can't be read.
  static double _scale(Size size) => math.max(size.width / 960, 0.85);

  @override
  Widget build(BuildContext context) {
    final reminder = _drawn;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (reminder != null)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _showing == null,
              child: AnimatedOpacity(
                opacity: _showing == null ? 0 : 1,
                duration: _fadeOut,
                child: _notice(context, reminder),
              ),
            ),
          ),
      ],
    );
  }

  Widget _notice(BuildContext context, OldSchoolReminder reminder) {
    final size = MediaQuery.sizeOf(context);
    final s = _scale(size);
    final narrow = size.width < 700;
    final left = _switchAt == null ? Duration.zero : _switchAt!.difference(DateTime.now().toUtc());
    final seconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    final countdown = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final episode = reminder.seasonNumber != null && reminder.episodeNumber != null
        ? 'S${reminder.seasonNumber} E${reminder.episodeNumber}${reminder.name.isNotEmpty && reminder.name != reminder.title ? ' · ${reminder.name}' : ''}'
        : null;
    final hint = PlatformDetector.isTV()
        ? t.oldSchool.reminderHintTv
        : PlatformDetector.isMobile(context)
        ? t.oldSchool.reminderHintTouch
        : t.oldSchool.reminderHintPointer;
    final posterUrl = _posterUrl;
    final hasPoster = posterUrl != null;

    final a = _entrance;
    const n = _steps;
    final headline = TextStyle(color: cornerAmber, fontSize: 22 * s, fontWeight: .w800, height: 1.15);
    final small = TextStyle(color: Colors.white70, fontSize: 14 * s, height: 1.25);
    final text = Padding(
      padding: EdgeInsets.fromLTRB(56 * s, 26 * s, 0, 10 * s),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .end,
        children: [
          cornerRiseStep(
            cornerStep(a, 4, 9, n, cornerSlideCurve),
            s,
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .end,
              children: [
                Text(
                  t.oldSchool.reminderStartsOn(
                    number: reminder.channelNumber?.toString() ?? '',
                    name: reminder.channelName ?? '',
                  ),
                  textAlign: .right,
                  style: headline,
                ),
                Padding(
                  padding: EdgeInsets.only(top: 2 * s),
                  child: Text(
                    reminder.title,
                    textAlign: .right,
                    maxLines: 2,
                    overflow: .ellipsis,
                    style: TextStyle(color: Colors.white, fontSize: 19 * s, fontWeight: .w700, height: 1.2),
                  ),
                ),
                if (episode != null)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * s),
                    child: Text(
                      episode,
                      textAlign: .right,
                      maxLines: 1,
                      overflow: .ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: 16 * s, fontWeight: .w600, height: 1.2),
                    ),
                  ),
              ],
            ),
          ),
          cornerFadeStep(
            cornerStep(a, 13, 17, n, Curves.ease),
            Padding(
              padding: EdgeInsets.only(top: 6 * s),
              child: Text(
                t.oldSchool.reminderSwitchingIn(time: countdown),
                textAlign: .right,
                style: headline.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
          cornerFadeStep(
            cornerStep(a, 16, 20, n, Curves.ease),
            Padding(
              padding: EdgeInsets.only(top: 2 * s),
              child: Text(hint, textAlign: .right, style: small),
            ),
          ),
        ],
      ),
    );
    final layout = CustomMultiChildLayout(
      delegate: CornerLayout(
        onTop: true,
        scale: s,
        hasPoster: hasPoster,
        top: MediaQuery.paddingOf(context).top,
        panelFraction: narrow ? 1 : 0.66,
      ),
      children: [
        LayoutId(
          id: CornerPart.band,
          child: cornerBandStep(cornerStep(a, 0, 5, n, cornerSlideCurve), const CornerBand(onTop: true)),
        ),
        LayoutId(id: CornerPart.text, child: text),
        if (posterUrl != null)
          LayoutId(
            id: CornerPart.poster,
            // The poster arrives in its own step, or fades in when the
            // look-up lands after the entrance.
            child: cornerSlideStep(
              cornerStep(a, 9, 14, n, cornerSlideCurve),
              (CornerLayout.posterWidth + 24 + 40) * s,
              Image(
                image: CachedNetworkImageProvider(posterUrl, cacheManager: PlexImageCacheManager.instance),
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, wasSync) =>
                    wasSync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: _fadeOut, child: child),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
    return Focus(
      focusNode: _noticeFocus,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: cornerTextBase(
        context,
        CornerClip(
          child: Transform.translate(
            offset: Offset(_drag, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTap: () => unawaited(_switch()),
              onHorizontalDragUpdate: (d) => setState(() => _drag = math.max(0, _drag + d.delta.dx)),
              onHorizontalDragEnd: (d) {
                if (_drag > _swipeDistance || (d.primaryVelocity ?? 0) > _swipeVelocity) {
                  _stay();
                } else {
                  setState(() => _drag = 0);
                }
              },
              onHorizontalDragCancel: () => setState(() => _drag = 0),
              child: layout,
            ),
          ),
        ),
      ),
    );
  }
}
