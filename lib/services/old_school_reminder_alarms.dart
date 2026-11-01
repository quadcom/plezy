import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.g.dart';
import '../models/old_school.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';

/// Old School reminders as Android notifications while Plezy is in the
/// background, on phones and tablets only (local/plans/old-school-future-details.md,
/// stage 2). The native side (`OldSchoolReminderAlarms.kt`) sets an alarm per
/// reminder and posts the notice; tapping it brings Plezy back with the
/// channel, which arrives on [opens] or, for a cold start, through
/// [takeLaunchChannel].
class OldSchoolReminderAlarms {
  OldSchoolReminderAlarms._();

  static final instance = OldSchoolReminderAlarms._();

  static const _channel = MethodChannel('com.plezy/old_school_reminders');

  final _opens = StreamController<String>.broadcast();
  bool _listening = false;
  bool _askedPermission = false;

  /// Android phones and tablets; a TV has the in-app notice only.
  static bool get supported => !kIsWeb && Platform.isAndroid && !PlatformDetector.isTV();

  /// Channels to tune, from a tapped notification while Plezy was running.
  Stream<String> get opens {
    _listen();
    return _opens.stream;
  }

  void _listen() {
    if (_listening || !supported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) _opens.add(call.arguments as String);
    });
  }

  /// The channel from the notification that started Plezy, once.
  Future<String?> takeLaunchChannel() async {
    if (!supported) return null;
    _listen();
    try {
      return await _channel.invokeMethod<String>('takeLaunchChannel');
    } catch (e) {
      appLogger.w('Old School reminders: launch channel lookup failed', error: e);
      return null;
    }
  }

  /// Replace the scheduled alarms with [reminders], each due [lead] before
  /// its start.
  Future<void> sync(List<OldSchoolReminder> reminders, {required Duration lead}) async {
    if (!supported) return;
    final now = DateTime.now().toUtc();
    final items = [
      for (final r in reminders)
        if (r.start != null && r.start!.subtract(lead).isAfter(now))
          {
            'id': r.id,
            'at': r.start!.subtract(lead).millisecondsSinceEpoch,
            'title': r.title,
            'text': [
              t.oldSchool.reminderStartsOn(number: r.channelNumber?.toString() ?? '', name: r.channelName ?? ''),
              if (r.seasonNumber != null && r.episodeNumber != null) 'S${r.seasonNumber} E${r.episodeNumber}',
            ].join(' · '),
            'channelId': r.channelId,
          },
    ];
    try {
      await _channel.invokeMethod<void>('schedule', {'reminders': items});
    } catch (e) {
      appLogger.w('Old School reminders: scheduling alarms failed', error: e);
    }
  }

  /// Ask once per run for the notification permission (Android 13+), when
  /// the first reminder is set.
  Future<void> askPermissionOnce() async {
    if (!supported || _askedPermission) return;
    _askedPermission = true;
    try {
      await _channel.invokeMethod<bool>('requestPermission');
    } catch (e) {
      appLogger.w('Old School reminders: permission request failed', error: e);
    }
  }
}
