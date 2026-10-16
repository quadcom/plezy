import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/dev_log_file.dart';

// The corner look agreed with Adrian on 2026-10-14 (local/plans/
// trailer-overlays.md): a square band flush to a screen edge with a 45-degree
// slant on its inner end, solid from the right edge to half its width, then
// fading to nothing at the tip; a square poster drawn over it, breaking out.
// Sizes are in units of a 960-wide screen (a 1080p TV) and grow with it.
// Shared by Old School's break overlays and the player's poster corner.
const cornerAmber = Color(0xFFF5B400);
const _bandColour = Color(0xF00E0F12); // the app's dark surface at 94%

class CornerBand extends StatelessWidget {
  /// Sits on the top edge with its slant wider at the top; else on the bottom
  /// edge, wider at the bottom.
  final bool onTop;

  const CornerBand({super.key, required this.onTop});

  @override
  Widget build(BuildContext context) =>
      DevLogFile.flag('noband') ? const SizedBox.expand() : CustomPaint(painter: _CornerBandPainter(onTop: onTop));
}

class _CornerBandPainter extends CustomPainter {
  final bool onTop;

  const _CornerBandPainter({required this.onTop});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final slant = h < w ? h : w;
    final path = Path();
    if (onTop) {
      path
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(slant, h);
    } else {
      path
        ..moveTo(slant, 0)
        ..lineTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(0, h);
    }
    path.close();
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerRight,
        end: Alignment.centerLeft,
        colors: [_bandColour, _bandColour, _bandColour.withValues(alpha: 0)],
        stops: const [0, 0.5, 1],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerBandPainter oldDelegate) => oldDelegate.onTop != onTop;
}

enum CornerPart { band, text, poster }

/// Lays the band, the text and the poster out over the whole screen: the
/// text against the right edge (beside the poster), the band as tall as the
/// text and flush to its edge, the poster breaking out of the band. [top]
/// moves a top block down, below whatever sits along the screen's top.
class CornerLayout extends MultiChildLayoutDelegate {
  final bool onTop;
  final double scale;
  final bool hasPoster;
  final double top;

  CornerLayout({required this.onTop, required this.scale, required this.hasPoster, this.top = 0});

  static const posterHeight = 144.0;
  static const posterWidth = posterHeight * 2 / 3;

  @override
  void performLayout(Size size) {
    final s = scale;
    final panel = size.width * 0.66;
    final right = 24 * s + (hasPoster ? posterWidth * s + 16 * s : 0);
    final text = layoutChild(CornerPart.text, BoxConstraints(maxWidth: panel - right));
    final bandHeight = text.height;
    final bandWidth = panel * 0.78;
    layoutChild(CornerPart.band, BoxConstraints.tight(Size(bandWidth, bandHeight)));
    positionChild(CornerPart.band, Offset(size.width - bandWidth, onTop ? top : size.height - bandHeight));
    positionChild(CornerPart.text, Offset(size.width - right - text.width, onTop ? top : size.height - text.height));
    if (hasPoster) {
      final ph = posterHeight * s;
      layoutChild(CornerPart.poster, BoxConstraints.tight(Size(posterWidth * s, ph)));
      // On top: 22 down. At the bottom: its top 17 above the band's, never
      // closer than 22 to the bottom edge.
      final bottomGap = math.max(22 * s, bandHeight + 17 * s - ph);
      final posterTop = onTop ? top + 22 * s : size.height - ph - bottomGap;
      positionChild(CornerPart.poster, Offset(size.width - 24 * s - posterWidth * s, posterTop));
    }
  }

  @override
  bool shouldRelayout(CornerLayout oldDelegate) =>
      oldDelegate.onTop != onTop ||
      oldDelegate.scale != scale ||
      oldDelegate.hasPoster != hasPoster ||
      oldDelegate.top != top;
}

/// A ClipRect, which a test build can switch off (dev-flags `noclip`).
class CornerClip extends StatelessWidget {
  final Widget child;

  const CornerClip({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DevLogFile.flag('noclip') ? child : ClipRect(child: child);
}

/// The overlays' base text: the app's body font, whatever page they sit on.
Widget cornerTextBase(BuildContext context, Widget child) => DefaultTextStyle(
  style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(decoration: TextDecoration.none),
  child: child,
);

// The step-by-step entrance (Adrian, 2026-10-14), one step = [cornerUnit].
const cornerUnit = Duration(milliseconds: 120); // one step of the entrance

/// Slides of the entrance ease out like the mock-up's cubic-bezier(.2,.7,.2,1).
const cornerSlideCurve = Cubic(0.2, 0.7, 0.2, 1);

/// One step of the entrance: [from]-[to] in units of [cornerUnit] out of [total].
Animation<double> cornerStep(Animation<double> parent, int from, int to, int total, Curve curve) => CurvedAnimation(
  parent: parent,
  curve: Interval(from / total, to / total, curve: curve),
);

/// Fades in over its step.
Widget cornerFadeStep(Animation<double> a, Widget child) => FadeTransition(opacity: a, child: child);

/// Slides in from 24 to the right, fading, over its step.
Widget cornerRiseStep(Animation<double> a, double scale, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => Opacity(
    opacity: a.value.clamp(0.0, 1.0),
    child: Transform.translate(offset: Offset((1 - a.value) * 24 * scale, 0), child: child),
  ),
  child: child,
);

/// Slides in from beyond the right edge over its step: [distance] is how far
/// off it starts.
Widget cornerSlideStep(Animation<double> a, double distance, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => Transform.translate(offset: Offset((1 - a.value) * distance, 0), child: child),
  child: child,
);

/// Slides in from its own width to the right over its step.
Widget cornerBandStep(Animation<double> a, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => FractionalTranslation(translation: Offset(1 - a.value, 0), child: child),
  child: child,
);
