import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/discover_screen.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';

/// Fan art motion: the item-page drift and the Discover banner's one-way moves
/// (local/plans/discover-banner-drift.md, discover-banner-motion.md).
void main() {
  Widget host({bool reduceMotion = false, bool randomMove = false, double drift = 0}) => MediaQuery(
    data: MediaQueryData(size: const Size(800, 400), disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 800,
        height: 400,
        child: CyclingMediaBackdrop(
          mediaKey: 'item',
          imagePaths: const [],
          client: null,
          width: 800,
          height: 400,
          fallbackColor: Colors.black,
          drift: drift,
          driftPeriod: const Duration(seconds: 28),
          randomMove: randomMove,
          moveDuration: const Duration(seconds: 9),
        ),
      ),
    ),
  );

  Transform moving(WidgetTester tester) => tester
      .widgetList<Transform>(find.descendant(of: find.byType(CyclingMediaBackdrop), matching: find.byType(Transform)))
      .first;

  testWidgets('drift moves, drawn between pixels', (tester) async {
    await tester.pumpWidget(host(drift: 0.04));
    await tester.pump(const Duration(seconds: 7));
    expect(moving(tester).transform.getTranslation().x, greaterThan(1));
    expect(moving(tester).filterQuality, FilterQuality.medium);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion keeps the art still', (tester) async {
    await tester.pumpWidget(host(drift: 0.04, reduceMotion: true));
    await tester.pump(const Duration(seconds: 7));
    expect(moving(tester).transform.getTranslation().x.abs(), lessThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a random move runs once at a steady speed, then holds still', (tester) async {
    await tester.pumpWidget(host(randomMove: true));
    Matrix4 now() => moving(tester).transform.clone();

    final start = now();
    await tester.pump(const Duration(milliseconds: 4500));
    final middle = now();
    await tester.pump(const Duration(milliseconds: 4500));
    final end = now();
    await tester.pump(const Duration(seconds: 5));
    final later = now();

    // Steady speed: halfway in time is halfway in position and zoom.
    for (final i in [0, 5, 12, 13]) {
      expect(middle.storage[i], closeTo((start.storage[i] + end.storage[i]) / 2, 0.01), reason: 'matrix entry $i');
    }
    expect(start.storage, isNot(equals(end.storage)), reason: 'it moved');
    expect(later.storage, end.storage, reason: 'it holds at the end, never reverses');
    expect(moving(tester).filterQuality, FilterQuality.medium);
    await tester.pumpWidget(const SizedBox());
  });

  group('BackdropMove', () {
    test('every move keeps the art covering the frame at both ends', () {
      const size = 0.03;
      const base = 1 + size * 2 + 0.02;
      for (final move in BackdropMove.values) {
        for (final t in [0.0, 0.5, 1.0]) {
          final p = move.at(t);
          expect(p.x.abs(), lessThanOrEqualTo(1));
          expect(p.y.abs(), lessThanOrEqualTo(1));
          // The enlarged art reaches (scale - 1) / 2 past each edge; the pan uses size.
          expect((base - 1) / 2, greaterThanOrEqualTo(size * p.x.abs()), reason: '$move at $t');
          expect(p.zoom, inInclusiveRange(0, 1));
        }
      }
    });

    test('pans, diagonals and zooms are all there', () {
      expect(BackdropMove.values, hasLength(8));
      expect(BackdropMove.panLeft.at(1).x, -1);
      expect(BackdropMove.downRight.at(1), (x: 1.0, y: 1.0, zoom: 0.0));
      expect(BackdropMove.zoomIn.at(1).zoom, 1);
      expect(BackdropMove.zoomOut.at(1).zoom, 0);
    });

    test('random never picks the same move twice in a row', () {
      var last = BackdropMove.random();
      for (var i = 0; i < 200; i++) {
        final next = BackdropMove.random();
        expect(next, isNot(last));
        last = next;
      }
    });
  });

  test('the Discover banner moves except on low-end devices and blurred test builds', () {
    expect(discoverBannerMovesFor(lowEnd: false, blurred: false), isTrue);
    expect(discoverBannerMovesFor(lowEnd: true, blurred: false), isFalse);
    expect(discoverBannerMovesFor(lowEnd: false, blurred: true), isFalse);
    expect(discoverBannerArtShare, 0.8);
    expect(discoverBannerMoveDuration, greaterThan(const Duration(seconds: 8)));
  });
}
