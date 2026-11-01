import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/old_school.dart';
import 'package:plezy/screens/old_school/old_school_reminder_host.dart';
import 'package:plezy/services/library_events/old_school_guide_events.dart';
import 'package:plezy/services/old_school_reminders.dart';

// local/plans/old-school-reminder-banner.md: the notice in the corner-overlay
// look, no buttons. OK / Enter / a tap is Watch now; Back / Esc is Stay.
void main() {
  late OldSchoolReminderService service;
  late List<String> tuned;

  OldSchoolReminder reminder() => OldSchoolReminder(
    id: 'r1',
    channelId: 'films',
    channelNumber: 4,
    channelName: 'Films',
    itemId: 'blade-runner',
    name: 'Blade Runner',
    start: DateTime.now().toUtc().add(const Duration(seconds: 45)),
  );

  setUp(() {
    service = OldSchoolReminderService(events: OldSchoolGuideEvents());
    tuned = [];
    service.tuneInPlace = (channelId) {
      tuned.add(channelId);
      return true;
    };
  });

  tearDown(() => service.dispose());

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OldSchoolReminderHost(
          service: service,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    service.due.value = reminder();
    await tester.pump();
    // The step-by-step entrance.
    await tester.pump(const Duration(seconds: 3));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('shows the corner block with the countdown and a hint, no buttons', (tester) async {
    await pumpHost(tester);
    expect(find.text('Starts on 4 Films'), findsOneWidget);
    expect(find.text('Blade Runner'), findsOneWidget);
    expect(find.textContaining('Switching in 0:'), findsOneWidget);
    expect(find.text('Tap to watch now · Swipe away to stay'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await finish(tester);
  });

  testWidgets('a tap watches now', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('Blade Runner'));
    await tester.pump();
    expect(tuned, ['films']);
    expect(service.due.value, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Blade Runner'), findsNothing);
    await finish(tester);
  });

  testWidgets('swiping it away stays', (tester) async {
    await pumpHost(tester);
    await tester.drag(find.text('Blade Runner'), const Offset(200, 0));
    await tester.pump();
    expect(tuned, isEmpty);
    expect(service.due.value, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Blade Runner'), findsNothing);
    await finish(tester);
  });

  testWidgets('with a keyboard, Esc stays and Enter watches now', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpHost(tester);
      expect(find.text('Click to watch now · Esc to stay'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tuned, isEmpty);
      expect(service.due.value, isNull);

      await tester.pump(const Duration(seconds: 1));
      service.due.value = OldSchoolReminder(
        id: 'r2',
        channelId: 'news',
        channelNumber: 7,
        channelName: 'News',
        name: 'The Evening News',
        start: DateTime.now().toUtc().add(const Duration(seconds: 45)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tuned, ['news']);
      await finish(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
