import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/app_bar_back_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required FocusNode focusNode,
    required VoidCallback onPressed,
    bool showOnTv = false,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: InputModeTracker(
            child: Scaffold(
              body: AppBarBackButton(focusNode: focusNode, onPressed: onPressed, showOnTv: showOnTv),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pointer, D-pad select, and Space activate exactly once', (tester) async {
    final focusNode = FocusNode(debugLabel: 'back_button_test');
    addTearDown(focusNode.dispose);
    var activations = 0;

    await pumpButton(tester, focusNode: focusNode, onPressed: () => activations++);

    await tester.tap(find.byType(AppBarBackButton));
    expect(activations, 1);

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activations, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(activations, 3);
  });

  testWidgets('exposes one localized operable button node', (tester) async {
    final semantics = tester.ensureSemantics();
    final focusNode = FocusNode(debugLabel: 'back_button_semantics');
    addTearDown(focusNode.dispose);

    await pumpButton(tester, focusNode: focusNode, onPressed: () {});

    final finder = find.bySemanticsLabel(t.common.back);
    expect(finder, findsOneWidget);
    final data = tester.getSemantics(finder).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  group('on a TV', () {
    setUp(() => TvDetectionService.debugSetAppleTVOverride(true));
    tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

    testWidgets('builds nothing: the remote has its own Back key', (tester) async {
      final focusNode = FocusNode(debugLabel: 'back_button_tv');
      addTearDown(focusNode.dispose);

      await pumpButton(tester, focusNode: focusNode, onPressed: () {});

      expect(find.byType(Tooltip), findsNothing);
      expect(find.bySemanticsLabel(t.common.back), findsNothing);
    });

    testWidgets('showOnTv keeps it', (tester) async {
      final focusNode = FocusNode(debugLabel: 'back_button_tv_kept');
      addTearDown(focusNode.dispose);
      var activations = 0;

      await pumpButton(tester, focusNode: focusNode, onPressed: () => activations++, showOnTv: true);

      await tester.tap(find.byType(AppBarBackButton));
      expect(activations, 1);
    });
  });
}
