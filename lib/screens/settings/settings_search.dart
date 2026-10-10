import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../focus/input_mode_tracker.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import 'appearance_settings_screen.dart';
import 'general_settings_screen.dart';
import 'home_sections_screen.dart';
import 'playback_settings_screen.dart';
import 'services_settings_screen.dart';
import 'subtitle_styling_screen.dart';

/// One setting the settings search can find: its title, the page it lives
/// on, and how to open that page. A null [screen] means the main Settings
/// page (Adrian, 2026-10-09; plan `local/plans/settings-search-home-sections.md`).
class SettingsSearchEntry {
  final String title;
  final String section;
  final WidgetBuilder? screen;

  const SettingsSearchEntry({required this.title, required this.section, this.screen});

  /// Whether every word of [query] appears in the title or the page name.
  bool matches(String query) {
    final haystack = '${title.toLowerCase()} ${section.toLowerCase()}';
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    return words.isNotEmpty && words.every(haystack.contains);
  }
}

List<SettingsSearchEntry> _page(String section, WidgetBuilder? screen, List<String> titles) => [
  for (final title in titles) SettingsSearchEntry(title: title, section: section, screen: screen),
];

/// Every searchable setting, page by page. A setting a platform does not show
/// still opens its page.
List<SettingsSearchEntry> settingsSearchEntries() {
  final s = t.settings;
  return [
    ..._page(t.settings.title, null, [
      s.general,
      s.appearance,
      s.videoPlayback,
      t.libraries.manageLibraries,
      s.services,
      t.connections.sectionTitle,
      t.accountPreferences.sectionTitle,
      t.profiles.sectionTitle,
      s.downloads,
      s.downloadOnWifiOnly,
      s.autoRemoveWatchedDownloads,
      s.videoPlayerControls,
      s.videoPlayerNavigation,
      s.companionRemoteServer,
      s.watchTogetherRelay,
      s.crashReporting,
      s.debugLogging,
      s.autoHidePerformanceOverlay,
      s.viewLogs,
      s.clearImageCache,
      s.resetSettings,
      s.exportSettings,
      s.importSettings,
      s.autoCheckUpdatesOnStartup,
      s.checkForUpdates,
      s.about,
    ]),
    ..._page(s.general, (_) => const GeneralSettingsScreen(), [
      s.language,
      s.requireProfileSelectionOnOpen,
      s.forceTvMode,
      s.enableDownloads,
      s.startInFullscreen,
    ]),
    ..._page(s.appearance, (_) => const AppearanceSettingsScreen(), [
      s.theme,
      s.visualEffects,
      s.viewMode,
      s.libraryDensity,
      s.gridSpacing,
      s.episodePosterMode,
      s.showEpisodeNumberOnCards,
      s.seasonPages,
      s.showSeasonPostersOnTabs,
      s.hideSpoilers,
      s.showWatchedIndicators,
      s.tvFullCardLayout,
      s.tvCornerSpotlightBackdrop,
      s.focusGlow,
      s.homeSections,
      s.showHeroSection,
      s.continueWatchingAction,
      s.episodeAction,
      s.showExploreTab,
      s.alwaysKeepSidebarOpen,
      s.groupLibrariesByServer,
      s.showNavBarLabels,
      s.showUnwatchedCount,
      s.liveTvDefaultFavorites,
    ]),
    ..._page(s.homeSections, (_) => const HomeSectionsScreen(), [
      s.homeSectionBanner,
      t.discover.continueWatching,
      t.discover.nextUp,
      s.homeSectionLibraries,
      s.homeSectionsLibraryCards,
      s.useGlobalHubs,
      s.showServerNameOnHubs,
    ]),
    ..._page(s.videoPlayback, (_) => const PlaybackSettingsScreen(), [
      s.playerBackend,
      t.externalPlayer.title,
      s.hardwareDecoding,
      s.passengerScreenMode,
      s.autoPip,
      s.matchContentFrameRate,
      s.matchContentResolution,
      s.matchRefreshRate,
      s.matchDynamicRange,
      s.displaySwitchDelay,
      s.deinterlace,
      s.tunneledPlayback,
      s.dvConversionMode,
      s.audioPassthrough,
      s.audioDownmix,
      s.audioDownmixNormalize,
      s.maxVolume,
      s.playbackBuffer,
      s.defaultQualityTitle,
      s.cellularQualityTitle,
      s.directPlayCoveredQuality,
      s.musicQualityTitle,
      s.subtitles,
      s.subtitleStyling,
      s.smallSkipDuration,
      s.largeSkipDuration,
      s.rewindOnResume,
      s.defaultSleepTimer,
      s.rememberPlayerChanges,
      s.rememberTrackSelections,
      s.followServerTrackSelections,
      s.resumeMusicOnLaunch,
      s.showChapterMarkersOnTimeline,
      s.specialsOrdering,
      s.clickVideoTogglesPlayback,
      s.exitFullscreenOnPlayerClose,
      s.autoPlayNextEpisode,
      s.shuffleStartsFromBeginning,
      s.playNextCountdown,
      s.skipIntroMode,
      s.skipCreditsMode,
      s.forceSkipMarkerFallback,
      s.autoSkipDelay,
      s.introPattern,
      s.creditsPattern,
      s.gestureBrightnessSwipe,
      s.rememberBrightnessLevel,
      s.gestureVolumeSwipe,
      s.gesturePinchToZoom,
      t.mpvConfig.title,
    ]),
    ..._page(t.screens.subtitleStyling, (_) => const SubtitleStylingScreen(), [
      t.subtitlingStyling.fontSize,
      t.subtitlingStyling.textColor,
      t.subtitlingStyling.position,
      t.subtitlingStyling.useMargins,
      t.subtitlingStyling.anchorToScreen,
      t.subtitlingStyling.bold,
      t.subtitlingStyling.italic,
      t.subtitlingStyling.borderSize,
      t.subtitlingStyling.borderColor,
      t.subtitlingStyling.backgroundOpacity,
      t.subtitlingStyling.backgroundColor,
    ]),
    ..._page(s.services, (_) => const ServicesSettingsScreen(), [s.discordRichPresence, t.services.names.seerr]),
  ];
}

/// Search over every setting. Nothing is listed until something is typed; on
/// the TV the on-screen keyboard is the only input (Adrian, 2026-10-09).
///
/// Picking a setting on the main Settings page pops back with it; picking one
/// on another page replaces this screen with that page, scrolled to it.
class SettingsSearchScreen extends StatefulWidget {
  const SettingsSearchScreen({super.key});

  @override
  State<SettingsSearchScreen> createState() => _SettingsSearchScreenState();
}

class _SettingsSearchScreenState extends State<SettingsSearchScreen> {
  final _controller = TextEditingController();
  late final List<SettingsSearchEntry> _entries = settingsSearchEntries();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<SettingsSearchEntry> get _results {
    final seen = <String>{};
    return [
      for (final entry in _entries)
        if (entry.matches(_query) && seen.add('${entry.section}|${entry.title}')) entry,
    ];
  }

  void _open(SettingsSearchEntry entry) {
    final screen = entry.screen;
    if (screen == null) {
      Navigator.pop(context, entry);
      return;
    }
    unawaited(
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (context) => SettingsRevealTarget(title: entry.title, child: screen(context)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().isEmpty ? const <SettingsSearchEntry>[] : _results;
    return SettingsPage(
      title: Text(t.settings.searchSettings),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.settings.searchSettingsHint,
              prefixIcon: const AppIcon(Symbols.search_rounded),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
            onSubmitted: (_) {
              final first = results.firstOrNull;
              if (first != null) _open(first);
            },
          ),
        ),
        if (_query.trim().isNotEmpty && results.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(t.settings.searchSettingsNoResults)),
        for (final entry in results)
          FocusableListTile(
            leading: const AppIcon(Symbols.settings_rounded),
            title: Text(entry.title),
            subtitle: Text(entry.section),
            onTap: () => _open(entry),
          ),
      ],
    );
  }
}

/// Opens [child] scrolled to the setting titled [title], briefly highlighted
/// (and focused when moving with a remote or keyboard).
class SettingsRevealTarget extends StatefulWidget {
  final String title;
  final Widget child;

  const SettingsRevealTarget({super.key, required this.title, required this.child});

  @override
  State<SettingsRevealTarget> createState() => _SettingsRevealTargetState();
}

class _SettingsRevealTargetState extends State<SettingsRevealTarget> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Let the page's route finish sliding in first.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) await revealSetting(context, widget.title);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Scroll the page under [context] to the setting titled [title], highlight it
/// for a moment, and focus it when moving with a remote or keyboard. Settings
/// pages build lazily, so the page is stepped down until the title is built.
/// Returns whether the setting was found.
Future<bool> revealSetting(BuildContext context, String title) async {
  if (!context.mounted) return false;
  final keyboardMode = InputModeTracker.isKeyboardMode(context, listen: false);
  final overlay = Overlay.maybeOf(context);
  final color = Theme.of(context).colorScheme.primary;
  final root = context as Element;
  final scrollable = _findVerticalScrollable(root);
  var target = _findTitle(root, title);
  if (scrollable != null) {
    final position = scrollable.position;
    var steps = 0;
    while (target == null && position.pixels < position.maxScrollExtent && steps++ < 40) {
      position.jumpTo((position.pixels + position.viewportDimension * 0.8).clamp(0.0, position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
      if (!root.mounted) return false;
      target = _findTitle(root, title);
    }
    if (target == null) position.jumpTo(0);
  }
  final found = target;
  if (found == null || !found.mounted) return false;
  await Scrollable.ensureVisible(found, alignment: 0.3, duration: const Duration(milliseconds: 250));
  if (!found.mounted) return false;
  if (keyboardMode) Focus.maybeOf(found, createDependency: false)?.requestFocus();
  if (overlay != null && overlay.mounted) _flash(overlay, _rowOf(found), color);
  return true;
}

ScrollableState? _findVerticalScrollable(Element root) {
  ScrollableState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is ScrollableState) {
      final state = element.state as ScrollableState;
      if (state.axisDirection == AxisDirection.down) {
        found = state;
        return;
      }
    }
    element.visitChildren(visit);
  }

  visit(root);
  return found;
}

Element? _findTitle(Element root, String title) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Text && (widget.data ?? widget.textSpan?.toPlainText()) == title) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

/// The setting's row around its title: the nearest card or list row.
Element _rowOf(Element title) {
  Element row = title;
  title.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Material || widget is ListTile) {
      row = ancestor;
      return false;
    }
    return true;
  });
  return row;
}

void _flash(OverlayState overlay, Element row, Color color) {
  final box = row.renderObject;
  final overlayBox = overlay.context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || overlayBox is! RenderBox) return;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
  final entry = OverlayEntry(
    builder: (_) => Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(child: _Flash(color: color)),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(milliseconds: 1600), entry.remove);
}

class _Flash extends StatefulWidget {
  final Color color;

  const _Flash({required this.color});

  @override
  State<_Flash> createState() => _FlashState();
}

class _FlashState extends State<_Flash> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = (1 - Curves.easeIn.transform(_controller.value)).clamp(0.0, 1.0);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.18 * opacity),
            border: Border.all(color: widget.color.withValues(alpha: opacity), width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }
}
