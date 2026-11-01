import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../exceptions/media_server_exceptions.dart';
import '../media/ids.dart';
import '../models/old_school.dart';
import '../utils/app_logger.dart';
import 'jellyfin_client.dart';
import 'library_events/old_school_guide_events.dart';
import 'old_school_reminder_alarms.dart';

/// Old School "Remind me" (local/plans/old-school-future-details.md, PlezyFin
/// PLAN_PFN_100). The user's reminders live on the server, so one set on a
/// phone fires on the TV in use. This keeps the list, times the next one and
/// raises [due] [lead] before it starts; the app-wide notice
/// (`OldSchoolReminderHost`) counts down and changes the channel.
///
/// The list is read when Old School becomes available, when the server says
/// it changed (`OldSchoolRemindersChanged`), when the guide changed (a
/// programme may have moved) and when the socket reconnects. Nothing is
/// polled.
class OldSchoolReminderService extends ChangeNotifier {
  OldSchoolReminderService({OldSchoolGuideEvents? events, DateTime Function()? clock, OldSchoolReminderAlarms? alarms})
    : _clock = clock ?? (() => DateTime.now().toUtc()),
      _alarms = alarms ?? OldSchoolReminderAlarms.instance {
    final source = events ?? OldSchoolGuideEvents.instance;
    _subscriptions = [
      source.remindersChanged.listen(_onServerNotice),
      source.connected.listen(_onServerNotice),
      source.changes.listen((change) => _onServerNotice(change.serverId)),
    ];
  }

  static final instance = OldSchoolReminderService();

  /// How long before the start the notice shows.
  static const lead = Duration(minutes: 1);

  /// Server notices are gathered for this long before the list is read again.
  static const _noticeBatch = Duration(seconds: 2);

  final DateTime Function() _clock;

  /// Phone and tablet notifications while Plezy is in the background.
  final OldSchoolReminderAlarms _alarms;
  late final List<StreamSubscription<Object?>> _subscriptions;

  JellyfinClient? _client;
  bool _available = false;
  List<OldSchoolReminder> _reminders = const [];
  Timer? _dueTimer;
  Timer? _noticeTimer;
  final Set<String> _shown = {};
  final Set<String> _busy = {};

  /// The reminder whose notice is up, or null.
  final ValueNotifier<OldSchoolReminder?> due = ValueNotifier(null);

  /// Set by an open Old School page: tunes [channelId] there and returns
  /// true. Without one, the notice opens Old School on the channel.
  bool Function(String channelId)? tuneInPlace;

  /// Whether the server keeps reminders (answered the list call). False on a
  /// PlezyFin without PLAN_PFN_100; the guide then offers no Remind me.
  bool get available => _available;

  List<OldSchoolReminder> get reminders => _reminders;

  JellyfinClient? get client => _client;

  /// Follow the Old School client (null when there is none).
  void attach(JellyfinClient? client) {
    if (identical(client, _client)) return;
    _client = client;
    _available = false;
    _reminders = const [];
    _shown.clear();
    due.value = null;
    _schedule();
    notifyListeners();
    if (client != null) unawaited(refresh());
  }

  void _onServerNotice(ServerId serverId) {
    final client = _client;
    if (client == null || serverId != client.serverId) return;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(_noticeBatch, () => unawaited(refresh()));
  }

  /// Read the list from the server.
  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    try {
      final list = await client.fetchOldSchoolReminders();
      if (!identical(client, _client)) return;
      _available = true;
      _reminders = List.unmodifiable(list);
    } on MediaServerHttpException catch (e) {
      if (!identical(client, _client)) return;
      if (e.statusCode == 404 || e.statusCode == 405) {
        _available = false;
        _reminders = const [];
      } else {
        appLogger.w('Old School reminders: list failed', error: e);
      }
    } catch (e, st) {
      appLogger.w('Old School reminders: list failed', error: e, stackTrace: st);
    }
    // A notice up for a reminder removed elsewhere goes away.
    final showing = due.value;
    if (showing != null && !_reminders.any((r) => r.id == showing.id)) due.value = null;
    _schedule();
    notifyListeners();
  }

  /// The reminder for [entry] on [channelId], if one is set.
  OldSchoolReminder? reminderFor(String channelId, OldSchoolEntry entry) =>
      _reminders.firstWhereOrNull((r) => r.matches(channelId, entry));

  bool isBusy(String channelId, OldSchoolEntry entry) => _busy.contains(_key(channelId, entry));

  static String _key(String channelId, OldSchoolEntry entry) =>
      '$channelId|${entry.itemId}|${entry.start.toIso8601String()}';

  /// Set or clear the reminder for [entry] on [channelId]. Returns false when
  /// the server refused or could not be reached; the list is unchanged then.
  Future<bool> setReminder(String channelId, OldSchoolEntry entry, {required bool on}) async {
    final client = _client;
    final itemId = entry.itemId;
    if (client == null || itemId == null) return false;
    final key = _key(channelId, entry);
    if (!_busy.add(key)) return false;
    notifyListeners();
    try {
      if (on) {
        unawaited(_alarms.askPermissionOnce());
        final added = await client.addOldSchoolReminder(channelId: channelId, start: entry.start, itemId: itemId);
        if (!identical(client, _client)) return false;
        _reminders = List.unmodifiable(
          [..._reminders.where((r) => r.id != added.id), added]
            ..sort((a, b) => (a.start ?? DateTime(9999)).compareTo(b.start ?? DateTime(9999))),
        );
      } else {
        final existing = reminderFor(channelId, entry);
        if (existing == null) return true;
        await client.removeOldSchoolReminder(existing.id);
        if (!identical(client, _client)) return false;
        _reminders = List.unmodifiable(_reminders.where((r) => r.id != existing.id));
        if (due.value?.id == existing.id) due.value = null;
      }
      _schedule();
      return true;
    } catch (e, st) {
      appLogger.w('Old School reminders: ${on ? 'add' : 'remove'} failed', error: e, stackTrace: st);
      return false;
    } finally {
      _busy.remove(key);
      notifyListeners();
    }
  }

  /// The notice was answered (Stay, switch, or the switch happened): it
  /// won't show again, and the reminder is cleared on the server.
  void finish(OldSchoolReminder reminder) {
    _shown.add(reminder.id);
    if (due.value?.id == reminder.id) due.value = null;
    _reminders = List.unmodifiable(_reminders.where((r) => r.id != reminder.id));
    _schedule();
    notifyListeners();
    final client = _client;
    if (client != null) {
      unawaited(
        client.removeOldSchoolReminder(reminder.id).catchError((Object e, StackTrace st) {
          appLogger.w('Old School reminders: clear after notice failed', error: e, stackTrace: st);
        }),
      );
    }
  }

  /// The next reminder to show, not yet shown and not over.
  OldSchoolReminder? get _next {
    final now = _clock();
    return _reminders.firstWhereOrNull((r) {
      final start = r.start;
      return start != null && !_shown.contains(r.id) && start.isAfter(now.subtract(const Duration(minutes: 5)));
    });
  }

  void _schedule() {
    _dueTimer?.cancel();
    _dueTimer = null;
    unawaited(
      _alarms.sync([
        for (final r in _reminders)
          if (!_shown.contains(r.id)) r,
      ], lead: lead),
    );
    final next = _next;
    if (next == null) return;
    final wait = next.start!.subtract(lead).difference(_clock());
    if (wait <= Duration.zero) {
      _raise(next);
      return;
    }
    _dueTimer = Timer(wait, () => _raise(next));
  }

  void _raise(OldSchoolReminder reminder) {
    final showing = due.value;
    if (showing != null && showing.id != reminder.id) {
      // One notice at a time: the later one waits for this one to finish.
      return;
    }
    due.value = reminder;
  }

  @visibleForTesting
  void debugSetReminders(List<OldSchoolReminder> reminders, {bool available = true}) {
    _available = available;
    _reminders = List.unmodifiable(reminders);
    _schedule();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _dueTimer?.cancel();
    _noticeTimer?.cancel();
    due.dispose();
    super.dispose();
  }
}
