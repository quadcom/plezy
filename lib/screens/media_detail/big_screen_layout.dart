import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Sizes for the item page on tablets and up (local/plans/movie-page-big-screens.md).
///
/// One layout, scaled to the window: every size is the value Adrian agreed for
/// his 2560x1410 PC window times [k], where k is how big this window is next to
/// that one. Text, buttons and cards never drop below a readable size. Phones,
/// TVs (their own layout for now; [tvBoost] is the agreed extra for when they
/// move) and upright windows get null and stay as they were.
@immutable
class DetailBigScreenLayout {
  const DetailBigScreenLayout._(this.size, this.k);

  static const designWidth = 2560.0;
  static const designHeight = 1410.0;

  /// TVs are seen from further away (agreed in the mock-up, 2026-11-09).
  static const tvBoost = 1.2;

  /// Below this width the page keeps its old layout (a narrow desktop window).
  static const minWidth = 900.0;

  final Size size;

  /// This window's size next to the design window (1 on his PC).
  final double k;

  static DetailBigScreenLayout? resolve({required Size size, required bool isPhone, required bool isTv}) {
    // The design is for wide screens; an upright window (a phone-shaped desktop
    // window, a tablet held upright) keeps the old page.
    // TVs keep their own item layout for now: it has TV-only parts (the episode
    // rail the top section follows, remote focus on the info area) that this
    // page doesn't have (stage 3 of the plan, held 2026-11-09).
    if (isPhone || isTv || size.width < minWidth || size.height <= 0 || size.height > size.width) return null;
    final k = math.min(size.width / designWidth, size.height / designHeight);
    return DetailBigScreenLayout._(size, k);
  }

  double _z(double v) => v * k;

  /// The top section's agreed height; it grows if its contents need more.
  double get topHeight => _z(560);

  double get posterWidth => math.max(_z(690), 200);
  double get posterHeight => posterWidth * 1.5;
  double get posterEdge => math.max(_z(24), 12);
  double get posterRadius => math.max(_z(8), 4);

  /// Left edge of the poster, from the window's left edge.
  double get posterLeft => size.width - posterEdge - posterWidth;

  double get titleLeft => math.max(_z(96), 16);
  double get titleLift => _z(90);
  double get logoHeight => math.max(_z(240), 70);
  double get logoMaxWidth => math.max(_z(1120), 300);

  /// The chips, round buttons and file-specs line are drawn at their old sizes
  /// and zoomed by this, so a 13 px chip becomes 16 on his PC and never under 12.
  double get heroZoom => math.max(1.25 * k, 12 / 13);

  /// Room the zoomed block leaves free to the right of the title for the poster.
  double get heroRightInset => posterWidth + posterEdge + math.max(_z(24), 12);

  double get overviewFontSize => math.max(28 * k, 17);
  double get headingFontSize => math.max(26.4 * k, 19);

  /// Width the Overview text may use from the content's left edge (16 in), so
  /// its lines stop short of the poster.
  double overviewMaxWidth(double contentLeft) => math.max(posterLeft - _z(48) - contentLeft, 320);

  /// Cast photo width (square), names and roles scaled with it.
  double get castCardWidth => math.max(_z(210), 110);
  double get castTextScale => math.max(1.3 * k, 1.0);

  /// Width of the dark fade over the cast row before it slides under the poster.
  double get castFade => math.max(_z(200), 60);

  /// Trailers & Extras card width, 16:9 (the row's 8 px padding each side included).
  double get extrasCardWidth => math.max(_z(300), 160) + 16;

  /// More Like This / other poster rows card width (the hub row's 3 px padding each side included).
  double get posterRowCardWidth => math.max(_z(210), 110) + 6;

  /// The season page keeps its own layout and grows as a whole: 1.5x on his PC,
  /// never smaller than it is today.
  double get seasonZoom => math.max(1.5 * k, 1.0);

  /// The cast member page's header (photo, name, counts) grows as a whole, like the season page.
  double get personHeaderZoom => seasonZoom;

  /// The Library density (1-5) whose grid cards come closest to the item page's
  /// poster rows (210 wide on his PC), so the cast member page's grid matches them.
  /// Desktop grid cards run 140-280 wide over densities 1-5; TVs 120-220.
  int personGridDensity({required bool isTv}) {
    final want = math.max(_z(210), 110);
    final (lo, hi) = isTv ? (120.0, 220.0) : (140.0, 280.0);
    final f = ((want - lo) / (hi - lo)).clamp(0.0, 1.0);
    return (1 + 4 * f).round();
  }

  /// The art behind the top section: the top section plus a short fade.
  double artHeight(double headerHeight) => headerHeight * 1.25;
}

/// Lays [child] out at 1/[scale] of the width it gets, then paints it [scale]
/// times bigger, so a block drawn at its old sizes fills the width at new ones.
/// Taps and focus follow the zoom.
class DetailZoom extends StatelessWidget {
  const DetailZoom({super.key, required this.scale, required this.child, this.alignment = Alignment.bottomLeft});

  final double scale;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 1000.0;
        // The outer box pins the width, so the fitted child is blown up to it
        // (a loose width would let FittedBox keep the child's own, smaller size).
        return SizedBox(
          width: width,
          child: FittedBox(
            fit: BoxFit.fitWidth,
            alignment: alignment,
            child: SizedBox(width: width / scale, child: child),
          ),
        );
      },
    );
  }
}

/// A subtle entrance when the item page opens on big screens (Adrian, 2026-11-09):
/// [child] fades in while moving from [offset] to its place. [delay] (0-1) holds
/// it back for that share of [duration], so the parts arrive one after another.
/// Skipped when the system asks for reduced motion.
class DetailEntrance extends StatelessWidget {
  const DetailEntrance({
    super.key,
    required this.child,
    this.offset = const Offset(0, 20),
    this.delay = 0,
    this.duration = const Duration(milliseconds: 650),
  });

  final Widget child;
  final Offset offset;
  final double delay;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Interval(delay, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: offset * (1 - t), child: child),
      ),
    );
  }
}
