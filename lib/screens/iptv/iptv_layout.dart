import 'package:flutter/widgets.dart';

import '../old_school/old_school_layout.dart';

/// Where the IPTV page puts its parts (PLAN_SHA_61a "Agreed design"). The
/// corner window and the details panel are Old School's to the pixel, so the
/// two read as one feature; under them come the group tabs, then the grid.
class IptvLayout {
  final Size size;
  final bool isPortraitPhone;

  /// The corner window (the strip on an upright phone).
  final Rect windowRect;

  /// The details panel beside or under the window.
  final Rect infoRect;

  /// The row of group tabs.
  final Rect filterRect;

  /// The guide grid: time header, channel column and programme rows.
  final Rect gridRect;

  /// Hours across: 2.5 on a wide screen, 2 on a sideways phone, 1.5 upright.
  final double visibleHours;

  final double channelColumnWidth;

  /// A row's height, the 6 px gap under it included.
  final double rowHeight;
  final double timeHeaderHeight;

  const IptvLayout._({
    required this.size,
    required this.isPortraitPhone,
    required this.windowRect,
    required this.infoRect,
    required this.filterRect,
    required this.gridRect,
    required this.visibleHours,
    required this.channelColumnWidth,
    required this.rowHeight,
    required this.timeHeaderHeight,
  });

  /// The window rectangle the player draws the video in.
  static Rect windowRectFor(Size size) => OldSchoolLayout.of(size).windowRect;

  factory IptvLayout.of(Size size) {
    final base = OldSchoolLayout.of(size);
    if (base.isPortraitPhone) {
      final filters = Rect.fromLTWH(0, base.infoRect.bottom, size.width, 52);
      return IptvLayout._(
        size: size,
        isPortraitPhone: true,
        windowRect: base.windowRect,
        infoRect: base.infoRect,
        filterRect: filters,
        gridRect: Rect.fromLTRB(0, filters.bottom, size.width, size.height),
        visibleHours: 1.5,
        channelColumnWidth: 84,
        rowHeight: 68,
        timeHeaderHeight: 36,
      );
    }
    final sidewaysPhone = size.shortestSide < 500;
    final filterHeight = (size.height * 0.06).clamp(40.0, 60.0);
    final filters = Rect.fromLTWH(0, base.gridRect.top, size.width, filterHeight);
    final grid = Rect.fromLTRB(0, filters.bottom, size.width, size.height);
    final timeHeader = (size.height * 0.04).clamp(28.0, 44.0);
    // About seven rows, never shorter than a title and its time line need
    // on a 1080p TV (540 tall to Flutter): fewer rows show instead.
    final row = ((grid.height - timeHeader) / 7).clamp(56.0, 68.0);
    return IptvLayout._(
      size: size,
      isPortraitPhone: false,
      windowRect: base.windowRect,
      infoRect: base.infoRect,
      filterRect: filters,
      gridRect: grid,
      visibleHours: sidewaysPhone ? 2 : 2.5,
      // 260 on a desktop (Adrian's pick), narrower on small screens.
      channelColumnWidth: (size.width * 0.135).clamp(170.0, 260.0),
      rowHeight: row,
      timeHeaderHeight: timeHeader,
    );
  }
}
