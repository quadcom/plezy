import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/voice_search_service.dart';
import 'package:plezy/widgets/voice_listening_dialog.dart';

/// Adrian, 2026-10-31: voice search shows Plezy's own listening card, not
/// Google's voice bar, and what was said comes back to the search page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.plezy/voice_search');

  late Completer<String?> answer;
  var cancels = 0;

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    answer = Completer<String?>();
    cancels = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'listen':
          return answer.future;
        case 'cancel':
          cancels++;
          if (!answer.isCompleted) answer.complete(null);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> sendEvent(WidgetTester tester, String type, [String? text]) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('onEvent', {'type': type, 'text': text}));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      data,
      (_) {},
    );
    await tester.pump();
  }

  Future<VoiceSearchResult?> Function() open(WidgetTester tester) {
    VoiceSearchResult? result;
    var done = false;
    return () async {
      if (!done) {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showVoiceListeningDialog(context);
                    done = true;
                  },
                  child: const Text('mic'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('mic'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }
      return result;
    };
  }

  testWidgets('shows the words as they are heard and returns the final text', (tester) async {
    VoiceSearchResult? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showVoiceListeningDialog(context),
              child: const Text('mic'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('mic'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Listening...'), findsOneWidget);

    await sendEvent(tester, 'speech');
    await sendEvent(tester, 'partial', 'alien rom');
    expect(find.text('alien rom'), findsOneWidget);

    await sendEvent(tester, 'end');
    // The platform answer crosses the message channel outside the fake clock.
    await tester.runAsync(() async {
      answer.complete('alien romulus');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(VoiceListeningCard), findsNothing);
    expect(result?.outcome, VoiceSearchOutcome.heard);
    expect(result?.text, 'alien romulus');
  });

  testWidgets('Cancel stops listening and returns nothing', (tester) async {
    final opened = open(tester);
    await opened();
    expect(find.byType(VoiceListeningCard), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(VoiceListeningCard), findsNothing);
    expect(cancels, 1);
    expect((await opened())?.outcome, VoiceSearchOutcome.nothing);
  });

  testWidgets('a refused microphone comes back as permissionDenied', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') throw PlatformException(code: 'PERMISSION_DENIED');
      return null;
    });
    final opened = open(tester);
    await opened();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(VoiceListeningCard), findsNothing);
    expect((await opened())?.outcome, VoiceSearchOutcome.permissionDenied);
  });
}
