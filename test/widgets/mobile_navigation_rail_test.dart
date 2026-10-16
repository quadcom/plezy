import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/mobile_navigation_rail.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugReset();
    addTearDown(TvDetectionService.debugReset);
  });

  final tabs = allNavigationTabs.where((tab) => tab.id != NavigationTabId.settings).toList();

  Widget wrap(Widget rail, {TextDirection direction = TextDirection.ltr}) {
    return MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Row(
            children: [
              rail,
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('tapping a destination reports its tab', (tester) async {
    NavigationTabId? selected;
    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: true,
          onDestinationSelected: (id) => selected = id,
        ),
      ),
    );

    await tester.tap(find.text(t.common.search));
    expect(selected, NavigationTabId.search);
  });

  testWidgets('labels follow the nav bar label setting', (tester) async {
    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: false,
          onDestinationSelected: (_) {},
        ),
      ),
    );
    // The rail keeps the label for semantics, but gives it no space.
    expect(tester.getSize(find.text(t.navigation.libraries)), Size.zero);

    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: true,
          onDestinationSelected: (_) {},
        ),
      ),
    );
    expect(tester.getSize(find.text(t.navigation.libraries)).width, greaterThan(0));
  });

  testWidgets('labels give way on a viewport too short to show every destination', (tester) async {
    // A landscape phone: ~410dp tall, six labelled destinations need ~430.
    tester.view.physicalSize = const Size(900, 410);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: true,
          onDestinationSelected: (_) {},
        ),
      ),
    );
    expect(tester.getSize(find.text(t.navigation.libraries)), Size.zero);
    expect(tester.takeException(), isNull);
    // Every destination is still reachable without scrolling.
    expect(tester.getBottomLeft(find.byType(NavigationRail)).dy, lessThanOrEqualTo(410));

    expect(MobileNavigationRail.labelsFit(destinations: 6, hasLeading: false, height: 410), isFalse);
    expect(MobileNavigationRail.labelsFit(destinations: 6, hasLeading: false, height: 600), isTrue);
    expect(MobileNavigationRail.labelsFit(destinations: 7, hasLeading: true, height: 500), isFalse);
  });

  testWidgets('long-pressing Libraries opens the quick picker; a tap still selects it', (tester) async {
    NavigationTabId? selected;
    var quickPicks = 0;
    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: true,
          onDestinationSelected: (id) => selected = id,
          onLibrariesLongPress: () => quickPicks++,
        ),
      ),
    );

    final librariesTab = tabs.firstWhere((tab) => tab.id == NavigationTabId.libraries);
    final icon = find.byWidgetPredicate((w) => w is Icon && w.icon == librariesTab.icon);
    await tester.longPress(icon);
    await tester.pump();
    expect(quickPicks, 1);
    expect(selected, isNull);

    await tester.tap(icon);
    expect(selected, NavigationTabId.libraries);
    expect(quickPicks, 1);
  });

  testWidgets('offline shows a reconnect action that is inert while reconnecting', (tester) async {
    var reconnects = 0;
    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.downloads,
          showLabels: true,
          onDestinationSelected: (_) {},
          isOffline: true,
          onReconnect: () => reconnects++,
        ),
      ),
    );
    final reconnect = find.byTooltip(t.common.reconnect);
    expect(reconnect, findsOneWidget);
    await tester.tap(reconnect);
    expect(reconnects, 1);

    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.downloads,
          showLabels: true,
          onDestinationSelected: (_) {},
          isOffline: true,
          isReconnecting: true,
          onReconnect: () => reconnects++,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip(t.common.reconnect), warnIfMissed: false);
    expect(reconnects, 1);

    await tester.pumpWidget(
      wrap(
        MobileNavigationRail(
          tabs: tabs,
          selectedTab: NavigationTabId.discover,
          showLabels: true,
          onDestinationSelected: (_) {},
        ),
      ),
    );
    expect(find.byTooltip(t.common.reconnect), findsNothing);
  });

  group('shouldUseLandscapeNavigationRail', () {
    Future<bool> evaluate(
      WidgetTester tester, {
      required Size size,
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      late bool result;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Builder(
            builder: (context) {
              result = PlatformDetector.shouldUseLandscapeNavigationRail(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('a landscape phone or head unit uses the rail', (tester) async {
      expect(await evaluate(tester, size: const Size(1080, 600)), isTrue);
    });

    testWidgets('portrait keeps the bottom bar', (tester) async {
      expect(await evaluate(tester, size: const Size(600, 1080)), isFalse);
    });

    testWidgets('desktop keeps its own sidebar', (tester) async {
      expect(await evaluate(tester, size: const Size(1080, 600), platform: TargetPlatform.macOS), isFalse);
    });

    testWidgets('TV keeps its own sidebar', (tester) async {
      TvDetectionService.debugSetAppleTVOverride(true);
      addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
      expect(await evaluate(tester, size: const Size(1080, 600)), isFalse);
    });
  });

  group('camera hole on the rail edge (sideways phone)', () {
    // The Pixel 11 Pro held sideways: 952 x 427, a 37-tall hole centred on
    // the left edge with Android's 68 reserved along it (2026-10-16).
    const hole = Rect.fromLTWH(0, 195, 68, 37);

    Widget withHole(Widget rail, {Rect bounds = hole}) {
      return MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              displayFeatures: [
                DisplayFeature(bounds: bounds, type: DisplayFeatureType.cutout, state: DisplayFeatureState.unknown),
              ],
            ),
            child: Scaffold(
              body: Row(
                children: [
                  rail,
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
    }

    void phoneSideways(WidgetTester tester) {
      tester.view.physicalSize = const Size(952, 427);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    final four = tabs
        .where(
          (tab) => const {
            NavigationTabId.discover,
            NavigationTabId.libraries,
            NavigationTabId.search,
            NavigationTabId.downloads,
          }.contains(tab.id),
        )
        .toList();

    testWidgets('splits the destinations around the hole, close to the edge', (tester) async {
      phoneSideways(tester);
      NavigationTabId? selected;
      await tester.pumpWidget(
        withHole(
          MobileNavigationRail(
            tabs: four,
            selectedTab: NavigationTabId.discover,
            showLabels: true,
            onDestinationSelected: (id) => selected = id,
          ),
        ),
      );

      expect(find.byType(NavigationRail), findsNothing);
      final libraries = tester.getRect(find.text(t.navigation.libraries));
      final search = tester.getRect(find.text(t.common.search));
      expect(libraries.bottom, lessThanOrEqualTo(hole.top));
      expect(
        tester.getRect(find.byIcon(four.firstWhere((x) => x.id == NavigationTabId.search).icon)).top,
        greaterThanOrEqualTo(hole.bottom),
      );
      expect(search.top, greaterThan(hole.bottom));
      // Clear of the hole's spot only, not Android's whole reserved strip.
      expect(libraries.center.dx, lessThan(hole.right));

      await tester.tap(find.text(t.common.search));
      expect(selected, NavigationTabId.search);
    });

    testWidgets('no hole on the rail edge keeps the standard rail', (tester) async {
      phoneSideways(tester);
      await tester.pumpWidget(
        withHole(
          MobileNavigationRail(
            tabs: four,
            selectedTab: NavigationTabId.discover,
            showLabels: true,
            onDestinationSelected: (_) {},
          ),
          // The phone turned the other way: the hole is on the right.
          bounds: const Rect.fromLTWH(884, 195, 68, 37),
        ),
      );
      expect(find.byType(NavigationRail), findsOneWidget);
    });
  });
}
