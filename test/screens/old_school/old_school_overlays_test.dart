import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/old_school.dart';
import 'package:plezy/screens/old_school/old_school_controller.dart';
import 'package:plezy/screens/old_school/old_school_overlays.dart';
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
