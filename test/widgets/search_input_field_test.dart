import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/search_input_field.dart';

import '../test_helpers/prefs.dart';

/// Adrian, 2026-10-31: on TV the search bar uses Plezy's own keyboard, not
/// the box's (Gboard and its broken mic), and the mic comes first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TextEditingController controller;
  late FocusNode fieldFocus;
  late FocusNode voiceFocus;
  var voicePresses = 0;

  setUp(() {
    resetSharedPreferencesForTest();
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
    controller = TextEditingController();
    fieldFocus = FocusNode(debugLabel: 'Search:Field');
    voiceFocus = FocusNode(debugLabel: 'Search:Voice');
    voicePresses = 0;
  });

  tearDown(() {
    controller.dispose();
    fieldFocus.dispose();
    voiceFocus.dispose();
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
  });

  Future<void> useAndroidTv() async {
    await TvDetectionService.getInstance(forceTv: true);
    TvDetectionService.setForceTVSync(true);
  }

  Widget app() => TranslationProvider(
    child: InputModeTracker(
      child: MaterialApp(
        home: Scaffold(
          body: SearchInputField(
            controller: controller,
            focusNode: fieldFocus,
            hintText: 'Search',
            debugLabel: 'Search',
            onVoiceSearch: () => voicePresses++,
            voiceSearchTooltip: 'Voice search',
            voiceFocusNode: voiceFocus,
          ),
        ),
      ),
    ),
  );

  testWidgets('on TV the mic sits before the field', (tester) async {
    await useAndroidTv();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final mic = tester.getCenter(find.byTooltip('Voice search'));
    final field = tester.getCenter(find.byType(TextField));
    expect(mic.dx, lessThan(field.dx));
  });

  testWidgets("on TV the mic answers OK and RIGHT onto the field opens Plezy's keyboard", (tester) async {
    await useAndroidTv();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    voiceFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(voicePresses, 1);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);

    // Adrian, 2026-10-31: "We also need the keyboard displayed if the input is
    // highlighted."
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);
  });

  testWidgets('on TV Back closes the keyboard without a lock-up', (tester) async {
    await useAndroidTv();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    fieldFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Greatroom TV, 2026-10-31: after voice search the field was rebuilt as a new
  // host on the same FocusNode; the new host chained to the disposed one's key
  // handler, so every key threw ("Null check operator" in State.context): no
  // keyboard and Back dead.
  testWidgets('a field rebuilt on the same focus node still takes keys', (tester) async {
    await useAndroidTv();
    var generation = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return KeyedSubtree(
                    key: ValueKey(generation),
                    child: SearchInputField(
                      controller: controller,
                      focusNode: fieldFocus,
                      hintText: 'Search',
                      debugLabel: 'Search',
                      onVoiceSearch: () => voicePresses++,
                      voiceSearchTooltip: 'Voice search',
                      voiceFocusNode: voiceFocus,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    rebuild(() => generation++);
    await tester.pumpAndSettle();
    rebuild(() => generation++);
    await tester.pumpAndSettle();

    fieldFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(voiceFocus.hasFocus, isTrue);
  });

  testWidgets('off TV the mic stays at the end of the field', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final mic = tester.getCenter(find.byTooltip('Voice search'));
    final field = tester.getCenter(find.byType(TextField));
    expect(mic.dx, greaterThan(field.dx));
  });
}
