import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/theme_provider.dart';
import 'package:plezy/screens/settings/appearance_settings_screen.dart';
import 'package:plezy/screens/settings/settings_search.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  test('every word must appear in the title or the page name', () {
    const entry = SettingsSearchEntry(title: 'Show Hero Section', section: 'Appearance');
    expect(entry.matches('hero'), isTrue);
    expect(entry.matches('HERO appear'), isTrue);
    expect(entry.matches('hero playback'), isFalse);
    expect(entry.matches('   '), isFalse);
  });

  test('the index has no blank titles', () {
    final entries = settingsSearchEntries();
    expect(entries, isNotEmpty);
    expect(entries.where((entry) => entry.title.trim().isEmpty || entry.section.trim().isEmpty), isEmpty);
  });

  Future<void> pumpSearch(WidgetTester tester, {required ValueChanged<SettingsSearchEntry?> onResult}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await Navigator.push<SettingsSearchEntry>(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsSearchScreen()),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing is listed until something is typed', (tester) async {
    await pumpSearch(tester, onResult: (_) {});

    expect(find.text(t.settings.showHeroSection), findsNothing);
    await tester.enterText(find.byType(TextField), 'hero');
    await tester.pumpAndSettle();
    expect(find.text(t.settings.showHeroSection), findsOneWidget);
    expect(find.text(t.settings.appearance), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text(t.settings.searchSettingsNoResults), findsOneWidget);
  });

  testWidgets('a setting on the main page comes back to it', (tester) async {
    SettingsSearchEntry? result;
    await pumpSearch(tester, onResult: (entry) => result = entry);

    await tester.enterText(find.byType(TextField), 'crash');
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.settings.crashReporting));
    await tester.pumpAndSettle();

    expect(result?.title, t.settings.crashReporting);
    expect(result?.screen, isNull);
  });

  testWidgets('a setting further down its page is scrolled to', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final theme = ThemeProvider();
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: theme,
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: SettingsRevealTarget(title: t.settings.liveTvDefaultFavorites, child: const AppearanceSettingsScreen()),
        ),
      ),
    );
    expect(find.text(t.settings.liveTvDefaultFavorites), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    final title = find.text(t.settings.liveTvDefaultFavorites);
    expect(title, findsOneWidget);
    final box = tester.getRect(title);
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(600));
  });
}
