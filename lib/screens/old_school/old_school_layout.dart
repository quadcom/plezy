import 'package:flutter/widgets.dart';

/// Where the Old School page puts its parts, worked out from the screen
/// size alone so the guide and the player agree on the corner window to the
/// pixel (the player draws the video there; the guide leaves a hole for it).
///
/// Wide screens (TV, desktop, tablets, sideways phones): details top left,
/// the window top right, the grid below with about 3 hours across. Upright
/// phones: the window as a strip across the top, details under it, then the
/// grid with about 1.5 hours across (mock-up `?v=pip` and `?v=phone`,
/// 2026-10-11).
class OldSchoolLayout {
  final Size size;
  final bool isPortraitPhone;

  /// The corner window (the strip on an upright phone).
  final Rect windowRect;

  /// The details panel beside or under the window.
  final Rect infoRect;

  /// The guide grid: time header, channel column and programme rows.
  final Rect gridRect;

  /// Hours the grid shows across.
  final double visibleHours;

  final double channelColumnWidth;
  final double rowHeight;
  final double timeHeaderHeight;

  const OldSchoolLayout._({
    required this.size,
    required this.isPortraitPhone,
    required this.windowRect,
    required this.infoRect,
    required this.gridRect,
    required this.visibleHours,
    required this.channelColumnWidth,
    required this.rowHeight,
    required this.timeHeaderHeight,
  });

  factory OldSchoolLayout.of(Size size) {
    final portrait = size.height > size.width && size.width < 700;
    if (portrait) {
      final window = Rect.fromLTWH(0, 0, size.width, size.width * 9 / 16);
      final info = Rect.fromLTWH(0, window.bottom, size.width, 112);
      final grid = Rect.fromLTRB(0, info.bottom, size.width, size.height);
      return OldSchoolLayout._(
        size: size,
        isPortraitPhone: true,
        windowRect: window,
        infoRect: info,
        gridRect: grid,
        visibleHours: 1.5,
        channelColumnWidth: 92,
        rowHeight: 68,
        timeHeaderHeight: 36,
      );
    }
    // Details and window take the top 42%. The window is square-cornered,
    // flush to the top and right edges, as tall as that band so it sits on
    // the time row, always 16:9 and at most 60% of the width (Adrian,
    // 2026-10-11; web PLAN_SHA_21a).
    final topHeight = size.height * 0.42;
    var windowHeight = topHeight;
    var windowWidth = windowHeight * 16 / 9;
    if (windowWidth > size.width * 0.6) {
      windowWidth = size.width * 0.6;
      windowHeight = windowWidth * 9 / 16;
    }
    final window = Rect.fromLTWH(size.width - windowWidth, 0, windowWidth, windowHeight);
    final info = Rect.fromLTRB(0, 0, window.left, topHeight);
    final grid = Rect.fromLTRB(0, topHeight, size.width, size.height);
    final timeHeader = (size.height * 0.04).clamp(28.0, 44.0);
    // About 7.5 rows below the time header, but never shorter than a
    // programme's title and year line need: a 1080p TV is only 540 tall to
    // Flutter, and 40 cut both lines in half (Theater SHIELD, 2026-10-11).
    // Fewer rows show instead.
    final row = ((grid.height - timeHeader) / 7.5).clamp(56.0, 76.0);
    return OldSchoolLayout._(
      size: size,
      isPortraitPhone: false,
      windowRect: window,
      infoRect: info,
      gridRect: grid,
      visibleHours: 3,
      // Wide enough beside the logo and number for a short channel name.
      channelColumnWidth: (size.width * 0.13).clamp(176.0, 260.0),
      rowHeight: row,
      timeHeaderHeight: timeHeader,
    );
  }
}

/// Clips its child to everything except [hole], so a native video plane
/// behind the Flutter view shows through there.
class OldSchoolHoleClipper extends CustomClipper<Path> {
  final Rect hole;
  final double radius;

  const OldSchoolHoleClipper(this.hole, {this.radius = 0});

  @override
  Path getClip(Size size) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius)));
  }

  @override
  bool shouldReclip(OldSchoolHoleClipper oldClipper) => oldClipper.hole != hole || oldClipper.radius != radius;
}
