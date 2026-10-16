import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/old_school.dart';
import 'package:plezy/screens/old_school/old_school_controller.dart';
import 'package:plezy/screens/old_school/old_school_overlays.dart';
import 'package:plezy/widgets/video_controls/old_school_controls.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';

import '../../test_helpers/backend_client_fixtures.dart';

OldSchoolEntry _trailer(Map<String, Object?> promo) => OldSchoolEntry.fromJson({
  'kind': 'trailer',
  'itemId': 'trailer-file',
  'start': '2026-10-14T19:00:00Z',
  'end': '2026-10-14T19:02:21Z',
  'name': 'Trailer',
  'productionYear': 2010,
  'officialRating': 'G',
  ...promo,
})!;

void main() {
  group('Idle overlays in the player page', () {
    // The player's outer stack hands the Old School page loose constraints,
    // and a loose Stack takes the size of its un-positioned children. An
    // idle overlay that returned a 0x0 box collapsed the page and clipped
    // every control and overlay (Windows, 2026-10-14).
    testWidgets('never shrink a loose Stack to nothing', (tester) async {
      final controller = OldSchoolController(testJellyfinClient());
      addTearDown(controller.dispose);
      const channel = OldSchoolChannel(id: 'c1', number: 1, name: 'Giggle Box');
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Stack(
              children: [
                OldSchoolPromoCorner(controller: controller, controlsVisible: false),
                OldSchoolPreRollCard(controller: controller, channel: channel, film: null, trailerLeft: () => null),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(Stack)), tester.getSize(find.byType(Center)));
      // The overlays' timers stop with the tree.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Old School trailer title (PLAN_SHA_47)', () {
    test("names the film with its own year and rating, never the trailer file's", () {
      final title = oldSchoolTrailerTitle(
        _trailer({
          'promo': 'have',
          'promoItemId': 'm1',
          'promoName': 'Real Steel',
          'promoYear': 2011,
          'promoOfficialRating': 'PG-13',
        }),
      );
      expect(title.title, 'Real Steel');
      expect(title.line, 'Trailer · 2011 · PG-13');
    });

    test('without the year and rating, just "Trailer"', () {
      final title = oldSchoolTrailerTitle(_trailer({'promo': 'have', 'promoItemId': 'm1', 'promoName': 'Real Steel'}));
      expect(title.line, 'Trailer');
    });

    test('coming soon says so', () {
      final title = oldSchoolTrailerTitle(_trailer({'promo': 'coming', 'promoName': 'Toy Story 5', 'promoYear': 2026}));
      expect(title.title, 'Toy Story 5');
      expect(title.line, 'Trailer · coming soon');
    });
  });

  group('Old School promo opens', () {
    test('a film, show or course you have opens', () {
      expect(oldSchoolPromoOpens(_trailer({'promo': 'have', 'promoItemId': 'm1'})), isTrue);
      expect(oldSchoolPromoOpens(_trailer({'promo': 'course', 'promoItemId': 'c1'})), isTrue);
    });

    test('coming soon never opens, even with an item id', () {
      expect(oldSchoolPromoOpens(_trailer({'promo': 'coming', 'promoItemId': 's1'})), isFalse);
    });

    test('nothing to open without an item id', () {
      expect(oldSchoolPromoOpens(_trailer({'promo': 'have'})), isFalse);
    });
  });

  group('Channel logo with the controls (Adrian, 2026-10-15)', () {
    Future<void> pump(WidgetTester tester, OldSchoolController controller, {required bool up}) => tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            OldSchoolWatermark(
              controller: controller,
              channel: const OldSchoolChannel(id: 'c1', number: 1, name: 'Giggle Box', logoTag: 't1'),
              controlsVisible: up,
            ),
          ],
        ),
      ),
    );

    testWidgets('grows and shows in full with the controls, then goes back', (tester) async {
      final controller = OldSchoolController(testJellyfinClient());
      addTearDown(controller.dispose);
      await pump(tester, controller, up: false);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1 / oldSchoolLogoGrow);
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0.35);
      await pump(tester, controller, up: true);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).alignment, Alignment.bottomRight);
      // Lifted clear of the controls' button row.
      final lifted = tester.widget<AnimatedPadding>(find.byType(AnimatedPadding)).padding as EdgeInsets;
      expect(lifted.bottom + 600 * oldSchoolLogoBottom, oldSchoolLogoLiftedBottom);
      await pump(tester, controller, up: false);
      final settled = tester.widget<AnimatedPadding>(find.byType(AnimatedPadding)).padding as EdgeInsets;
      expect(settled.bottom, 0);
    });

    test('the timeline stops clear of the grown logo', () {
      const width = 960.0;
      final logoLeftEdge = width * (oldSchoolLogoRight + oldSchoolLogoWidth * oldSchoolLogoGrow);
      expect(oldSchoolTimelineClearance(width), greaterThan(logoLeftEdge));
    });
  });

  group('Old School running length', () {
    test('hours and minutes', () {
      expect(oldSchoolRunLength(const Duration(hours: 3, minutes: 21, seconds: 40)), '3 h 21 min');
    });

    test('under an hour, minutes only', () {
      expect(oldSchoolRunLength(const Duration(minutes: 47)), '47 min');
    });
  });

  group('PlayerChromeController suppressed (film trailer, PLAN_SHA_47)', () {
    test('hides the controls and nothing raises them', () {
      final chrome = PlayerChromeController();
      addTearDown(chrome.dispose);
      expect(chrome.controlsVisible, isTrue);
      chrome.setSuppressed(true);
      expect(chrome.controlsVisible, isFalse);
      chrome.show();
      chrome.toggle();
      chrome.recordPointerActivity();
      chrome.hold(PlayerChromeHold.scrub);
      expect(chrome.controlsVisible, isFalse);
      chrome.release(PlayerChromeHold.scrub);
    });

    test('lifting it lets the controls show again', () {
      final chrome = PlayerChromeController(initiallyVisible: false);
      addTearDown(chrome.dispose);
      chrome.setSuppressed(true);
      chrome.setSuppressed(false);
      chrome.show();
      expect(chrome.controlsVisible, isTrue);
    });
  });
}
