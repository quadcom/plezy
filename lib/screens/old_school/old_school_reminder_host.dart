import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../services/old_school_reminder_alarms.dart';
import '../../services/old_school_reminders.dart';
import '../../services/playback_coordinator.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/corner_band.dart';
import 'old_school_screen.dart';

/// The app-wide Old School reminder notice
/// (local/plans/old-school-future-details.md). [OldSchoolReminderService]
/// raises it a minute before a reminded programme starts, on whatever screen
/// is up: "Blade Runner · Starts on 4 Films · Switching in 0:42", with Watch
/// now and Stay. At zero it changes the channel: in place when Old School is
/// open, else it stops what is playing and opens Old School on that channel.
/// Stay (or Back on a TV) cancels it.
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

class _OldSchoolReminderHostState extends State<OldSchoolReminderHost> {
  /// A notice that turns up late (the app was opened after the start) still
  /// counts down this long, so it can be answered.
  static const _minCountdown = Duration(seconds: 10);

  OldSchoolReminderService get _service => widget.service ?? OldSchoolReminderService.instance;

  OldSchoolReminder? _showing;
  DateTime? _switchAt;
  Timer? _tick;
  FocusNode? _previousFocus;
  final FocusNode _stayFocus = FocusNode(debugLabel: 'old_school_reminder_stay');

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
    _stayFocus.dispose();
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
    setState(() {
      _showing = reminder;
      _switchAt = start.isAfter(earliest) ? start : earliest;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // A TV remote must be able to reach Stay; pointers and touch just tap.
    if (PlatformDetector.isTV()) {
      _previousFocus = FocusManager.instance.primaryFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showing != null) _stayFocus.requestFocus();
      });
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
    }
    if (restoreFocus && previous != null && previous.context != null && previous.canRequestFocus) {
      previous.requestFocus();
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

  @override
  Widget build(BuildContext context) {
    final reminder = _showing;
    return Stack(fit: StackFit.expand, children: [widget.child, if (reminder != null) _notice(context, reminder)]);
  }

  Widget _notice(BuildContext context, OldSchoolReminder reminder) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final size = MediaQuery.sizeOf(context);
    final left = _switchAt == null ? Duration.zero : _switchAt!.difference(DateTime.now().toUtc());
    final seconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    final countdown = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final episode = reminder.seasonNumber != null && reminder.episodeNumber != null
        ? 'S${reminder.seasonNumber} E${reminder.episodeNumber}${reminder.name.isNotEmpty && reminder.name != reminder.title ? ' · ${reminder.name}' : ''}'
        : null;
    final width = size.width < 600 ? size.width - 32 : 420.0;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 16,
      right: 16,
      width: width,
      // Back on the notice is Stay, never a page's Back.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => handleBackKeyAction(event, _stay),
        child: Material(
          color: tk.bg,
          elevation: 12,
          shape: const RoundedRectangleBorder(),
          child: Container(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: cornerAmber, width: 4)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Row(
                  children: [
                    const AppIcon(Symbols.notifications_active_rounded, fill: 1, size: 18, color: cornerAmber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        t.oldSchool
                            .reminderStartsOn(
                              number: reminder.channelNumber?.toString() ?? '',
                              name: reminder.channelName ?? '',
                            )
                            .toUpperCase(),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: cornerAmber,
                          fontWeight: .w800,
                          letterSpacing: 1.2,
                        ),
                        maxLines: 1,
                        overflow: .ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  reminder.title,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: .w800),
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
                if (episode != null)
                  Text(
                    episode,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted),
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                const SizedBox(height: 6),
                Text(
                  t.oldSchool.reminderSwitchingIn(time: countdown),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: cornerAmber,
                    fontWeight: .w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: .end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(shape: const RoundedRectangleBorder()),
                      onPressed: () => unawaited(_switch()),
                      child: Text(t.oldSchool.reminderSwitchNow),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      focusNode: _stayFocus,
                      style: FilledButton.styleFrom(shape: const RoundedRectangleBorder()),
                      onPressed: _stay,
                      child: Text(t.oldSchool.reminderStay),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
