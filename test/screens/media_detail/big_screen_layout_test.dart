import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/media_detail/big_screen_layout.dart';

/// The item page's one scaled layout for tablets and up (local/plans/movie-page-big-screens.md).
void main() {
  DetailBigScreenLayout? at(double w, double h, {bool phone = false, bool tv = false}) =>
      DetailBigScreenLayout.resolve(size: Size(w, h), isPhone: phone, isTv: tv);

  test('his PC window gets the agreed sizes', () {
    final big = at(2560, 1410)!;
    expect(big.k, 1);
    expect(big.topHeight, 560);
    expect(big.posterWidth, 690);
    expect(big.posterHeight, 1035);
    expect(big.posterEdge, 24);
    expect(big.logoHeight, 240);
    expect(big.titleLeft, 96);
    expect(big.overviewFontSize, 28);
    expect(big.castCardWidth, 210);
    expect(big.castTextScale, 1.3);
    expect(big.heroZoom, 1.25);
    expect(big.extrasCardWidth, 316);
    expect(big.posterRowCardWidth, 216);
    expect(big.artHeight(560), 700);
  });

  test('a smaller window scales everything by the same amount', () {
    final big = at(1920, 1040)!;
    expect(big.k, closeTo(1040 / 1410, 1e-9));
    expect(big.posterWidth, closeTo(690 * big.k, 1e-9));
    expect(big.castCardWidth, closeTo(210 * big.k, 1e-9));
  });

  test('a tablet keeps text and cards readable', () {
    final big = at(1280, 800)!;
    expect(big.k, closeTo(0.5, 1e-9));
    expect(big.overviewFontSize, 17, reason: '28 x 0.5 = 14 is below the floor');
    expect(big.headingFontSize, 19);
    expect(big.castCardWidth, 110);
    expect(big.castTextScale, 1.0);
    expect(big.heroZoom, closeTo(12 / 13, 1e-9), reason: 'chips never under 12 px');
    expect(big.logoHeight, 120);
  });

  test('phones, TVs (own layout for now) and narrow windows keep the old page', () {
    expect(at(412, 915, phone: true), isNull);
    expect(at(1920, 1080, tv: true), isNull);
    expect(at(800, 900), isNull);
    expect(at(1100, 2400), isNull, reason: 'upright windows keep the old page');
  });

  test('the overview stops short of the poster', () {
    final big = at(2560, 1410)!;
    expect(big.posterLeft, 2560 - 24 - 690);
    expect(big.overviewMaxWidth(16), 2560 - 24 - 690 - 48 - 16);
  });
}
