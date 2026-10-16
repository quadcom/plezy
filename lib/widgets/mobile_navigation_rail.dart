import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../navigation/navigation_tabs.dart';
import 'app_icon.dart';

/// The mobile shell's navigation in landscape: the bottom [NavigationBar]'s
/// destinations on a leading Material [NavigationRail], so a wide, short
/// viewport keeps its height for content. Deliberately not the desktop/TV
/// sidebar — it carries no libraries, no expansion, no focus choreography.
///
/// Mirrors the bottom bar's extras: the offline reconnect affordance (as the
/// rail's leading action) and the long-press library quick picker on the
/// Libraries destination.
class MobileNavigationRail extends StatelessWidget {
  const MobileNavigationRail({
    super.key,
    required this.tabs,
    required this.selectedTab,
    required this.showLabels,
    required this.onDestinationSelected,
    this.onLibrariesLongPress,
    this.isOffline = false,
    this.isReconnecting = false,
    this.onReconnect,
  });

  final List<NavigationTab> tabs;
  final NavigationTabId selectedTab;
  final bool showLabels;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onLibrariesLongPress;
  final bool isOffline;
  final bool isReconnecting;
  final VoidCallback? onReconnect;

  /// Material 3 rail indicator size; the long-press target matches it so the
  /// hold works anywhere on the visible pill, not only on the glyph.
  static const Size _indicatorSize = Size(56, 32);

  /// Material 3 labelled-destination extent (indicator, label, spacing) and
  /// the leading action's extent, used to decide whether labels fit.
  /// Estimates: the scroll view below is the exact fallback.
  static const double _labelledExtent = 72;
  static const double _unlabelledExtent = 56;
  static const double _leadingExtent = 56;

  /// Material 3 rail width.
  static const double _railWidth = 80;

  /// Whether every destination fits at once with labels on a rail of
  /// [height]: a phone in landscape has ~410dp, six labelled destinations
  /// need more, so labels give way before anything has to scroll.
  @visibleForTesting
  static bool labelsFit({required int destinations, required bool hasLeading, required double height}) {
    final needed = destinations * _labelledExtent + (hasLeading ? _leadingExtent : 0);
    return needed <= height;
  }

  /// Space kept between the screen edge and the destinations when the camera
  /// hole, not the whole edge, is what has to be avoided.
  static const double _cutoutEdgeMargin = 8;

  /// Space kept above and below the camera hole.
  static const double _cutoutGapMargin = 10;

  /// The camera hole on this rail's edge when a phone held sideways has one
  /// there: a small cut-out touching the leading edge, in logical pixels of
  /// the screen (the rail starts at its top). Android reserves the hole's
  /// depth down the whole edge; the rail only needs to clear the hole itself
  /// (Adrian, 2026-10-16).
  @visibleForTesting
  static Rect? leadingCutout(MediaQueryData media, TextDirection direction) {
    final width = media.size.width;
    for (final feature in media.displayFeatures) {
      if (feature.type != DisplayFeatureType.cutout) continue;
      final bounds = feature.bounds;
      final onEdge = direction == TextDirection.rtl ? bounds.right >= width - 1 : bounds.left <= 1;
      // A punch hole, not a notch along most of the side.
      if (onEdge && !bounds.isEmpty && bounds.height < media.size.height * 0.4) return bounds;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tabs.indexWhere((tab) => tab.id == selectedTab);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final hole = leadingCutout(MediaQuery.of(context), Directionality.of(context));
        if (hole != null) {
          final split = _aroundCutout(context, hole, height);
          if (split != null) return split;
        }
        final labelled = showLabels && labelsFit(destinations: tabs.length, hasLeading: isOffline, height: height);
        final rail = NavigationRail(
          selectedIndex: selectedIndex >= 0 ? selectedIndex : null,
          onDestinationSelected: (index) => onDestinationSelected(tabs[index].id),
          labelType: labelled ? NavigationRailLabelType.all : NavigationRailLabelType.none,
          groupAlignment: 0,
          leading: isOffline ? _reconnectAction(context) : null,
          destinations: [for (final tab in tabs) _destination(context, tab)],
        );
        // NavigationRail needs a bounded height. Give it at least the viewport
        // and let it grow past that inside a scroll view when even icon-only
        // destinations cannot fit (seven tabs plus reconnect on a small phone).
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: IntrinsicHeight(child: rail),
          ),
        );
      },
    );
  }

  /// The destinations in two groups with the camera hole between them: the
  /// first half above it, the rest below, close to the edge. Null when they
  /// do not fit either side of the hole (the normal rail then).
  Widget? _aroundCutout(BuildContext context, Rect hole, double height) {
    final upperCount = (tabs.length + 1) ~/ 2;
    final gapTop = hole.top - _cutoutGapMargin;
    final gapBottom = hole.bottom + _cutoutGapMargin;
    bool fits(double extent) =>
        upperCount * extent + (isOffline ? _leadingExtent : 0) <= gapTop &&
        (tabs.length - upperCount) * extent <= height - gapBottom;
    final bool labelled;
    if (showLabels && fits(_labelledExtent)) {
      labelled = true;
    } else if (fits(_unlabelledExtent)) {
      labelled = false;
    } else {
      return null;
    }
    final theme = Theme.of(context);
    final background = NavigationRailTheme.of(context).backgroundColor ?? theme.colorScheme.surface;
    Widget item(NavigationTab tab) => _CutoutRailItem(
      tab: tab,
      selected: tab.id == selectedTab,
      labelled: labelled,
      extent: labelled ? _labelledExtent : _unlabelledExtent,
      onTap: () => onDestinationSelected(tab.id),
      onLongPress: tab.id == NavigationTabId.libraries ? onLibrariesLongPress : null,
    );
    return ColoredBox(
      color: background,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: _cutoutEdgeMargin),
        child: SizedBox(
          width: _railWidth,
          height: height,
          child: Column(
            children: [
              SizedBox(
                height: gapTop,
                child: Column(
                  mainAxisAlignment: .end,
                  children: [
                    if (isOffline) _reconnectAction(context),
                    for (final tab in tabs.take(upperCount)) item(tab),
                  ],
                ),
              ),
              SizedBox(height: gapBottom - gapTop),
              Expanded(
                child: Column(
                  mainAxisAlignment: .start,
                  children: [for (final tab in tabs.skip(upperCount)) item(tab)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reconnectAction(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IconButton(
        tooltip: t.common.reconnect,
        onPressed: isReconnecting ? null : onReconnect,
        icon: isReconnecting
            ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: primary))
            : AppIcon(Symbols.wifi_rounded, size: 18, color: primary),
      ),
    );
  }

  NavigationRailDestination _destination(BuildContext context, NavigationTab tab) {
    Widget icon = AppIcon(tab.icon, fill: 1);
    final onLongPress = onLibrariesLongPress;
    if (tab.id == NavigationTabId.libraries && onLongPress != null) {
      // Only a long-press recogniser: taps fall through to the rail's own
      // destination handling, exactly like the bottom bar's overlay.
      icon = GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: () {
          Feedback.forLongPress(context);
          onLongPress();
        },
        child: SizedBox.fromSize(
          size: _indicatorSize,
          child: Center(child: icon),
        ),
      );
    }
    return NavigationRailDestination(icon: icon, label: Text(tab.getLabel()));
  }
}

/// One destination of the rail split around the camera hole, drawn as
/// Material 3's rail draws it: the icon on a pill when selected, the label
/// under it.
class _CutoutRailItem extends StatelessWidget {
  const _CutoutRailItem({
    required this.tab,
    required this.selected,
    required this.labelled,
    required this.extent,
    required this.onTap,
    this.onLongPress,
  });

  final NavigationTab tab;
  final bool selected;
  final bool labelled;
  final double extent;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final railTheme = NavigationRailTheme.of(context);
    final iconColor = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final labelStyle =
        (selected ? railTheme.selectedLabelTextStyle : railTheme.unselectedLabelTextStyle) ??
        theme.textTheme.labelMedium?.copyWith(color: selected ? scheme.onSurface : scheme.onSurfaceVariant);
    final longPress = onLongPress;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: MobileNavigationRail._railWidth,
          height: extent,
          child: Column(
            mainAxisAlignment: .center,
            children: [
              Material(
                color: selected ? (railTheme.indicatorColor ?? scheme.secondaryContainer) : Colors.transparent,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  onLongPress: longPress == null
                      ? null
                      : () {
                          Feedback.forLongPress(context);
                          longPress();
                        },
                  child: SizedBox.fromSize(
                    size: MobileNavigationRail._indicatorSize,
                    child: Center(child: AppIcon(tab.icon, fill: 1, color: iconColor)),
                  ),
                ),
              ),
              if (labelled) ...[
                const SizedBox(height: 4),
                Text(tab.getLabel(), style: labelStyle, maxLines: 1, overflow: .ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
