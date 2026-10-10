import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/home_layout.dart';
import '../../media/library_layout.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/content_utils.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';

/// What the user can do to one home section.
enum _SectionAction { turnOn, turnOff, moveUp, moveDown, cardsUsual, cardsPosters, cardsScreenGrabs }

/// Home sections: turn the banner, Continue Watching, Next Up and the library
/// rows on or off, put them in order, and pick posters or screen grabs per
/// row. With a PlezyFin account this is saved with the account, so every
/// device follows (Adrian, 2026-10-09; plan
/// `local/plans/settings-search-home-sections.md`).
///
/// With an account the list holds every home row, apart from the menu: a
/// folded library or Continue Watching can still have one, and only Not shown
/// takes a row off home (Adrian, 2026-10-10; plan
/// `local/plans/home-rows-apart.md`).
class HomeSectionsScreen extends StatelessWidget {
  const HomeSectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<HiddenLibrariesProvider>();
    final libraries = context.watch<LibrariesProvider>().libraries;
    final home = layout.home;
    final account = layout.isAccountLayout;
    final sections = account ? const [HomeLayout.hero] : home.sections;
    final rowLibraries = [
      for (final library in libraries)
        if (_hasHomeRows(library) && layout.stateOf(library) == LibraryState.shown) library,
    ];
    final homeRows = account ? _homeRows(layout, libraries) : const <_HomeRow>[];
    return SettingsPage(
      title: Text(t.settings.homeSections),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            layout.isAccountLayout ? t.settings.homeSectionsSavedAccount : t.settings.homeSectionsSavedDevice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsGroup(
          title: t.settings.homeSectionsRows,
          children: [
            for (final (index, section) in sections.indexed)
              _SectionTile(
                key: ValueKey(section),
                section: section,
                index: index,
                count: sections.length,
                on: _isOn(context, layout, section),
                cardStyle: _hasCards(section) ? layout.cardStyleFor(layout.sectionCardKey(section)) : null,
              ),
            for (final (index, row) in homeRows.indexed)
              _HomeRowTile(key: ValueKey('row:${row.key}'), rows: homeRows, index: index),
          ],
        ),
        if (!account && rowLibraries.isNotEmpty)
          SettingsGroup(
            title: t.settings.homeSectionsLibraryCards,
            children: [
              for (final library in rowLibraries)
                FocusableListTile(
                  key: ValueKey(library.globalKey),
                  leading: AppIcon(ContentTypeHelper.getLibraryIcon(library.kind.id), fill: 1),
                  title: Text(library.title),
                  subtitle: Text(_cardStyleLabel(layout.libraryCardStyle(library))),
                  onTap: () => _pickLibraryCards(context, layout, library),
                ),
            ],
          ),
      ],
    );
  }

  /// The account's home rows this list shows, in home order: Continue
  /// Watching, Next Up and the libraries that have home rows. Views Plezy has
  /// no rows for are left out and keep their place.
  static List<_HomeRow> _homeRows(HiddenLibrariesProvider layout, List<MediaLibrary> libraries) {
    final byKey = {
      for (final library in libraries)
        if (_hasHomeRows(library)) libraryLayoutKey(library): library,
    };
    final resume = layout.entryLayoutKey(LayoutEntry.continueWatching);
    final nextUp = layout.entryLayoutKey(LayoutEntry.nextUp);
    final result = <_HomeRow>[];
    for (final row in layout.homeRowsInForce ?? const <({String key, bool on})>[]) {
      final library = byKey[row.key];
      if (row.key == resume) {
        result.add(_HomeRow(key: row.key, on: row.on, section: HomeLayout.resume));
      } else if (row.key == nextUp) {
        result.add(_HomeRow(key: row.key, on: row.on, section: HomeLayout.nextUp));
      } else if (library != null) {
        result.add(_HomeRow(key: row.key, on: row.on, library: library));
      }
    }
    return result;
  }

  static bool _hasHomeRows(MediaLibrary library) =>
      const {MediaKind.movie, MediaKind.show, MediaKind.clip, MediaKind.artist}.contains(library.kind);

  static Future<void> _pickLibraryCards(
    BuildContext context,
    HiddenLibrariesProvider layout,
    MediaLibrary library,
  ) async {
    final picked = await _pickCardStyle(context, library.title, layout.libraryCardStyle(library));
    if (picked == null || !context.mounted) return;
    await _save(context, () => layout.setLibraryCardStyle(library, picked.value));
  }
}

Future<DialogOption<HomeCardStyle?>?> _pickCardStyle(BuildContext context, String title, HomeCardStyle? current) =>
    showSelectionDialog<HomeCardStyle?>(
      context: context,
      title: title,
      options: [
        DialogOption(value: null, title: t.settings.cardsUsual),
        DialogOption(value: HomeCardStyle.poster, title: t.settings.cardsPosters),
        DialogOption(value: HomeCardStyle.thumb, title: t.settings.cardsScreenGrabs),
      ],
      currentValue: current,
    );

/// Whether [section] is on. Without an account the banner follows this
/// device's Show hero setting, as it always did.
bool _isOn(BuildContext context, HiddenLibrariesProvider layout, String section) {
  if (section == HomeLayout.hero && !layout.isAccountLayout) {
    return SettingsService.instance.read(SettingsService.showHeroSection);
  }
  return layout.home.isOn(section);
}

bool _hasCards(String section) => section == HomeLayout.resume || section == HomeLayout.nextUp;

String _sectionTitle(String section) => switch (section) {
  HomeLayout.hero => t.settings.homeSectionBanner,
  HomeLayout.resume => t.discover.continueWatching,
  HomeLayout.nextUp => t.discover.nextUp,
  _ => t.settings.homeSectionLibraries,
};

IconData _sectionIcon(String section) => switch (section) {
  HomeLayout.hero => Symbols.featured_play_list_rounded,
  HomeLayout.resume => Symbols.play_circle_rounded,
  HomeLayout.nextUp => Symbols.skip_next_rounded,
  _ => Symbols.video_library_rounded,
};

String _cardStyleLabel(HomeCardStyle? style) => switch (style) {
  HomeCardStyle.poster => t.settings.cardsPosters,
  HomeCardStyle.thumb => t.settings.cardsScreenGrabs,
  null => t.settings.cardsUsual,
};

Future<void> _save(BuildContext context, Future<void> Function() write) async {
  try {
    await write();
  } catch (e, st) {
    appLogger.w('Home sections: could not save', error: e, stackTrace: st);
    if (context.mounted) showErrorSnackBar(context, t.settings.saveFailed);
  }
}

/// One row of the account's home rows list: Continue Watching or Next Up
/// ([section]), or a library's rows ([library]).
class _HomeRow {
  final String key;
  final bool on;
  final String? section;
  final MediaLibrary? library;

  const _HomeRow({required this.key, required this.on, this.section, this.library});

  String get title => library?.title ?? _sectionTitle(section!);

  IconData get icon => library == null ? _sectionIcon(section!) : ContentTypeHelper.getLibraryIcon(library!.kind.id);
}

class _HomeRowTile extends StatelessWidget {
  final List<_HomeRow> rows;
  final int index;

  const _HomeRowTile({super.key, required this.rows, required this.index});

  _HomeRow get row => rows[index];

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<HiddenLibrariesProvider>();
    final cardStyle = layout.cardStyleFor(row.key);
    final parts = [
      row.on ? t.settings.homeSectionOn : t.settings.homeSectionOff,
      _cardStyleLabel(cardStyle),
      if (_isFolded(layout)) t.libraries.sectionFolded,
    ];
    return FocusableListTile(
      leading: AppIcon(row.icon, fill: 1),
      title: Text(row.title),
      subtitle: Text(parts.join(' · ')),
      trailing: AppIcon(row.on ? Symbols.toggle_on_rounded : Symbols.toggle_off_rounded, fill: 1),
      onTap: () => _showActions(context, layout, cardStyle),
    );
  }

  /// Whether the row's library or entry sits in the menu's folded section.
  bool _isFolded(HiddenLibrariesProvider layout) {
    final library = row.library;
    if (library != null) return layout.stateOf(library) == LibraryState.folded;
    final entry = row.section == HomeLayout.nextUp ? LayoutEntry.nextUp : LayoutEntry.continueWatching;
    return layout.entryState(entry) == LibraryState.folded;
  }

  Future<void> _showActions(BuildContext context, HiddenLibrariesProvider layout, HomeCardStyle? cardStyle) async {
    final picked = await showSelectionDialog<_SectionAction?>(
      context: context,
      title: row.title,
      options: [
        DialogOption(
          value: row.on ? _SectionAction.turnOff : _SectionAction.turnOn,
          title: row.on ? t.settings.homeSectionTurnOff : t.settings.homeSectionTurnOn,
        ),
        if (index > 0) DialogOption(value: _SectionAction.moveUp, title: t.settings.homeSectionMoveUp),
        if (index < rows.length - 1)
          DialogOption(value: _SectionAction.moveDown, title: t.settings.homeSectionMoveDown),
        DialogOption(value: _SectionAction.cardsUsual, title: t.settings.cardsUsual),
        DialogOption(value: _SectionAction.cardsPosters, title: t.settings.cardsPosters),
        DialogOption(value: _SectionAction.cardsScreenGrabs, title: t.settings.cardsScreenGrabs),
      ],
      // Marks the current card style; the other actions are never selected.
      currentValue: switch (cardStyle) {
        HomeCardStyle.poster => _SectionAction.cardsPosters,
        HomeCardStyle.thumb => _SectionAction.cardsScreenGrabs,
        null => _SectionAction.cardsUsual,
      },
    );
    final action = picked?.value;
    if (action == null || !context.mounted) return;
    await _save(context, () => _apply(layout, action));
  }

  Future<void> _apply(HiddenLibrariesProvider layout, _SectionAction action) {
    final next = [for (final r in rows) (key: r.key, on: r.on)];
    switch (action) {
      case _SectionAction.turnOn || _SectionAction.turnOff:
        next[index] = (key: row.key, on: action == _SectionAction.turnOn);
        return layout.saveHomeRows(next);
      case _SectionAction.moveUp || _SectionAction.moveDown:
        next.insert(action == _SectionAction.moveUp ? index - 1 : index + 1, next.removeAt(index));
        return layout.saveHomeRows(next);
      case _SectionAction.cardsUsual:
        return layout.setCardStyle(row.key, null);
      case _SectionAction.cardsPosters:
        return layout.setCardStyle(row.key, HomeCardStyle.poster);
      case _SectionAction.cardsScreenGrabs:
        return layout.setCardStyle(row.key, HomeCardStyle.thumb);
    }
  }
}

class _SectionTile extends StatelessWidget {
  final String section;
  final int index;
  final int count;
  final bool on;
  final HomeCardStyle? cardStyle;

  const _SectionTile({
    super.key,
    required this.section,
    required this.index,
    required this.count,
    required this.on,
    required this.cardStyle,
  });

  @override
  Widget build(BuildContext context) {
    final parts = [
      on ? t.settings.homeSectionOn : t.settings.homeSectionOff,
      if (_hasCards(section)) _cardStyleLabel(cardStyle),
      if (section == HomeLayout.hero && PlatformDetector.isTV()) t.settings.homeSectionNotOnTv,
    ];
    return FocusableListTile(
      leading: AppIcon(_sectionIcon(section), fill: 1),
      title: Text(_sectionTitle(section)),
      subtitle: Text(parts.join(' · ')),
      trailing: AppIcon(on ? Symbols.toggle_on_rounded : Symbols.toggle_off_rounded, fill: 1),
      onTap: () => _showActions(context),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final layout = context.read<HiddenLibrariesProvider>();
    final picked = await showSelectionDialog<_SectionAction?>(
      context: context,
      title: _sectionTitle(section),
      options: [
        DialogOption(
          value: on ? _SectionAction.turnOff : _SectionAction.turnOn,
          title: on ? t.settings.homeSectionTurnOff : t.settings.homeSectionTurnOn,
        ),
        if (index > 0) DialogOption(value: _SectionAction.moveUp, title: t.settings.homeSectionMoveUp),
        if (index < count - 1) DialogOption(value: _SectionAction.moveDown, title: t.settings.homeSectionMoveDown),
        if (_hasCards(section)) ...[
          DialogOption(value: _SectionAction.cardsUsual, title: t.settings.cardsUsual),
          DialogOption(value: _SectionAction.cardsPosters, title: t.settings.cardsPosters),
          DialogOption(value: _SectionAction.cardsScreenGrabs, title: t.settings.cardsScreenGrabs),
        ],
      ],
      // Marks the current card style; the other actions are never selected.
      currentValue: switch (cardStyle) {
        _ when !_hasCards(section) => null,
        HomeCardStyle.poster => _SectionAction.cardsPosters,
        HomeCardStyle.thumb => _SectionAction.cardsScreenGrabs,
        null => _SectionAction.cardsUsual,
      },
    );
    final action = picked?.value;
    if (action == null || !context.mounted) return;
    await _save(context, () => _apply(layout, action));
  }

  Future<void> _apply(HiddenLibrariesProvider layout, _SectionAction action) async {
    switch (action) {
      case _SectionAction.turnOn || _SectionAction.turnOff:
        final turnOn = action == _SectionAction.turnOn;
        if (section == HomeLayout.hero && !layout.isAccountLayout) {
          await SettingsService.instance.write(SettingsService.showHeroSection, turnOn);
          // Notify the screen, which reads the setting through the provider.
          await layout.setHomeSectionOn(HomeLayout.hero, on: true);
        } else {
          await layout.setHomeSectionOn(section, on: turnOn);
        }
      case _SectionAction.moveUp || _SectionAction.moveDown:
        final sections = List<String>.of(layout.home.sections);
        final from = sections.indexOf(section);
        final to = action == _SectionAction.moveUp ? from - 1 : from + 1;
        if (from < 0 || to < 0 || to >= sections.length) return;
        sections
          ..removeAt(from)
          ..insert(to, section);
        await layout.setHomeSections(sections);
      case _SectionAction.cardsUsual:
        await layout.setCardStyle(layout.sectionCardKey(section), null);
      case _SectionAction.cardsPosters:
        await layout.setCardStyle(layout.sectionCardKey(section), HomeCardStyle.poster);
      case _SectionAction.cardsScreenGrabs:
        await layout.setCardStyle(layout.sectionCardKey(section), HomeCardStyle.thumb);
    }
  }
}
