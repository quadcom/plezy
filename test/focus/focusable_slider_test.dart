import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_slider.dart';

void main() {
  testWidgets('each D-pad arrow reports a complete persisted change', (tester) async {
    final focusNode = FocusNode(debugLabel: 'slider');
    addTearDown(focusNode.dispose);
    final starts = <double>[];
    final changes = <double>[];
    final ends = <double>[];
    var value = 0.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FocusableSlider(
              focusNode: focusNode,
              value: value,
              min: 0,
              max: 10,
              divisions: 10,
              onChangeStart: starts.add,
              onChanged: (next) {
                changes.add(next);
                setState(() => value = next);
              },
              onChangeEnd: ends.add,
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(starts, [0.0, 1.0]);
    expect(changes, [1.0, 0.0]);
    expect(ends, [1.0, 0.0]);
    expect(value, 0.0);
  });

  testWidgets('preserves an inherited 12px slider overlay', (tester) async {
    const inheritedOverlay = RoundSliderOverlayShape(overlayRadius: 12);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderTheme(
            data: const SliderThemeData(overlayShape: inheritedOverlay),
            child: FocusableSlider(value: 0, onChanged: (_) {}),
          ),
        ),
      ),
    );

    final sliderContext = tester.element(find.byType(Slider));
    final overlay = SliderTheme.of(sliderContext).overlayShape;

    expect(overlay, same(inheritedOverlay));
    expect(overlay!.getPreferredSize(false, false), const Size.square(24));
  });

  testWidgets('SELECT invokes the slider action once', (tester) async {
    final focusNode = FocusNode(debugLabel: 'slider');
    addTearDown(focusNode.dispose);
    var selected = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableSlider(focusNode: focusNode, value: 0, onChanged: (_) {}, onSelect: () => selected++),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(selected, 1);
  });

  group('with a long select', () {
    late FocusNode focusNode;
    late int selected;
    late int longSelected;

    Future<void> pumpSlider(WidgetTester tester) async {
      focusNode = FocusNode(debugLabel: 'slider');
      addTearDown(focusNode.dispose);
      selected = 0;
      longSelected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusableSlider(
              focusNode: focusNode,
              value: 0,
              onChanged: (_) {},
              onSelect: () => selected++,
              onLongSelect: () => longSelected++,
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
    }

    testWidgets('a short press runs the select action on release', (tester) async {
      await pumpSlider(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(selected, 0, reason: 'nothing happens until the key is released');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 1));

      expect(selected, 1);
      expect(longSelected, 0);
    });

    testWidgets('holding select runs the long action only', (tester) async {
      await pumpSlider(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 800));
      expect(longSelected, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(selected, 0);
      expect(longSelected, 1);
    });

    testWidgets('a release with no press seen here does nothing', (tester) async {
      // The OK press that opened the sync bar ends on the newly focused slider.
      await pumpSlider(tester);
      focusNode.unfocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 1));

      expect(selected, 0);
      expect(longSelected, 0);
    });
  });
}
