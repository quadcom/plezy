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

  testWidgets('on TV the mic answers OK and RIGHT walks onto the field without a keyboard', (tester) async {
    await useAndroidTv();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    voiceFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(voicePresses, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(fieldFocus.hasFocus, isTrue);
    // Passing over the field does not open a keyboard.
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
  });

  testWidgets("on TV OK on the field opens Plezy's own keyboard", (tester) async {
    await useAndroidTv();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    fieldFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);
  });

  testWidgets('off TV the mic stays at the end of the field', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final mic = tester.getCenter(find.byTooltip('Voice search'));
    final field = tester.getCenter(find.byType(TextField));
    expect(mic.dx, greaterThan(field.dx));
  });
}
