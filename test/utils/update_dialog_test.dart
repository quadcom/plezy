import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/update_dialog.dart';
import 'package:plezy/widgets/dialog_action_button.dart';

void main() {
  testWidgets('update dialog opens with its primary action focused', (tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // Off Android there is no installable APK, so the primary action is View Release.
    unawaited(
      showUpdateAvailableDialog(
        hostContext,
        {'latestVersion': '2026.10.3', 'currentVersion': '2026.10.2', 'releaseUrl': 'https://example.com/release'},
        title: 'Update available',
        dismissLabel: 'Later',
        showSkipVersion: true,
      ),
    );
    await tester.pumpAndSettle();

    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(focused!.findAncestorWidgetOfExactType<DialogActionButton>()?.label, t.update.viewRelease);
  });
}
