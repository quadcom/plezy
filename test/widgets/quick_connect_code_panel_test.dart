import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/widgets/quick_connect_code_panel.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../test_helpers/theme.dart';

const _approveUrl = 'http://jf.example:8096/web/#/quickconnect?code=123456';

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  Future<void> pumpPanel(WidgetTester tester, {required Size screen, String? approveUrl}) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: Scaffold(
            body: Center(
              child: QuickConnectCodePanel(code: '123456', approveUrl: approveUrl, onCancel: () {}),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('wide screen shows the approve link as a QR beside the code', (tester) async {
    await pumpPanel(tester, screen: const Size(1920, 1080), approveUrl: _approveUrl);

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    expect(find.text(t.auth.quickConnectScanInstructions), findsOneWidget);
  });

  testWidgets('narrow screen keeps the code only', (tester) async {
    await pumpPanel(tester, screen: const Size(400, 800), approveUrl: _approveUrl);

    expect(find.byType(QrImageView), findsNothing);
    expect(find.text(t.auth.quickConnectInstructions), findsOneWidget);
  });

  testWidgets('no approve link means no QR, even on a wide screen', (tester) async {
    await pumpPanel(tester, screen: const Size(1920, 1080));

    expect(find.byType(QrImageView), findsNothing);
    expect(find.text(t.auth.quickConnectInstructions), findsOneWidget);
  });
}
