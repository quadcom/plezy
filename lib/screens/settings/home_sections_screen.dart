import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../i18n/strings.g.dart';
import '../../media/home_layout.dart';
import '../../media/library_layout.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/content_utils.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';

/// The two Plex-era home switches, kept on this device: Plex's own home hubs,
/// and server names in row titles. They sit on the Home sections page for
/// now, under the banner, and go when Plezy leaves Plex behind (Adrian,
/// 2026-10-10).
List<Widget> homeHubSwitches() => [
  SettingSwitchTile(
    pref: SettingsService.useGlobalHubs,
    icon: Symbols.home_rounded,
    title: t.settings.useGlobalHubs,
    subtitle: t.settings.useGlobalHubsDescription,
  ),
  SettingSwitchTile(
    pref: SettingsService.showServerNameOnHubs,
    icon: Symbols.dns_rounded,
    title: t.settings.showServerNameOnHubs,
    subtitle: t.settings.showServerNameOnHubsDescription,
  ),
];

/// What the user can do to one home section (device mode).
enum _SectionAction { turnOn, turnOff, moveUp, moveDown, cardsUsual, cardsPosters, cardsSeason, cardsScreenGrabs }

/// Home sections: turn the banner, Continue Watching, Next Up and the library
/// rows on or off, put them in order, and pick how each row draws its cards.
/// With a PlezyFin account this is saved with the account, so every device
/// follows (Adrian, 2026-10-09; plan
/// `local/plans/settings-search-home-sections.md`).
///
/// With an account the page matches the web client's Home page: a Banner
/// switch, then one list of every home row, apart from the menu. Each row has
/// a drag handle, its card choice and an on/off switch; a folded library can
/// still have a row, and only Not shown takes it off home (Adrian, 2026-10-10;
/// plan `local/plans/home-rows-apart.md`).
class HomeSectionsScreen extends StatelessWidget {
  const HomeSectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<HiddenLibrariesProvider>();
    final libraries = context.watch<LibrariesProvider>().libraries;
    if (layout.isAccountLayout) return _accountPage(context, layout, libraries);
    final home = layout.home;
    final sections = home.sections;
    final rowLibraries = [
      for (final library in libraries)
        if (_hasHomeRows(library) && layout.stateOf(library) == LibraryState.shown) library,
    ];
    return SettingsPage(
      title: Text(t.settings.homeSections),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(t.settings.homeSectionsSavedDevice, style: Theme.of(context).textTheme.bodySmall),
        ),
        SettingsGroup(children: homeHubSwitches()),
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
          ],
        ),
        if (rowLibraries.isNotEmpty)
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

  Widget _accountPage(BuildContext context, HiddenLibrariesProvider layout, List<MediaLibrary> libraries) {
    final bannerOn = layout.home.isOn(HomeLayout.hero);
    return SettingsPage(
      title: Text(t.settings.homeSections),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(t.settings.homeSectionsSavedAccount, style: Theme.of(context).textTheme.bodySmall),
        ),
        SettingsGroup(
          children: [
            FocusableSwitchListTile(
              secondary: const AppIcon(Symbols.featured_play_list_rounded, fill: 1),
              title: Text(t.settings.homeSectionBanner),
              subtitle: Text(
                [
                  t.settings.homeBannerDescription,
                  if (PlatformDetector.isTV()) t.settings.homeSectionNotOnTv,
                ].join(' · '),
              ),
              value: bannerOn,
              onChanged: (on) => _save(context, () => layout.setHomeSectionOn(HomeLayout.hero, on: on)),
            ),
            ...homeHubSwitches(),
          ],
        ),
        SettingsSectionHeader(t.settings.homeSectionsRows),
        _HomeRowsEditor(rows: _homeRows(layout, libraries)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(t.settings.homeRowsNote, style: Theme.of(context).textTheme.bodySmall),
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
      final style = layout.cardStyleFor(row.key) ?? HomeCardStyle.poster;
      final sort = layout.rowSortFor(row.key);
      if (row.key == resume) {
        result.add(_HomeRow(key: row.key, on: row.on, style: style, section: HomeLayout.resume));
      } else if (row.key == nextUp) {
        result.add(_HomeRow(key: row.key, on: row.on, style: style, section: HomeLayout.nextUp));
      } else if (library != null) {
        result.add(_HomeRow(key: row.key, on: row.on, style: style, sort: sort, library: library));
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
        DialogOption(value: HomeCardStyle.season, title: t.settings.cardSeasonPoster),
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
  HomeCardStyle.season => t.settings.cardSeasonPoster,
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
  final HomeCardStyle style;

  /// The library row's item order; Continue Watching and Next Up keep the
  /// server's.
  final HomeRowSort sort;
  final String? section;
  final MediaLibrary? library;

  const _HomeRow({
    required this.key,
    required this.on,
    required this.style,
    this.sort = HomeRowSort.added,
    this.section,
    this.library,
  });

  _HomeRow withOn(bool on) => _HomeRow(key: key, on: on, style: style, sort: sort, section: section, library: library);

  String get title => library?.title ?? _sectionTitle(section!);

  IconData get icon => library == null ? _sectionIcon(section!) : ContentTypeHelper.getLibraryIcon(library!.kind.id);

  /// Rows that hold episodes choose between the show's and the season's
  /// poster; the rest have one poster (Adrian, 2026-10-10).
  bool get holdsEpisodes => library == null || library!.kind == MediaKind.show;

  List<({HomeCardStyle style, String label})> get choices => holdsEpisodes
      ? [
          (style: HomeCardStyle.poster, label: t.settings.cardShowPoster),
          (style: HomeCardStyle.season, label: t.settings.cardSeasonPoster),
          (style: HomeCardStyle.thumb, label: t.settings.cardScreenshot),
        ]
      : [
          (style: HomeCardStyle.poster, label: t.settings.cardPoster),
          (style: HomeCardStyle.thumb, label: t.settings.cardScreenshot),
        ];

  /// The choice to mark: a season choice on a row without seasons reads as
  /// its poster.
  HomeCardStyle get shownStyle => !holdsEpisodes && style == HomeCardStyle.season ? HomeCardStyle.poster : style;

  ({String key, bool on}) get entry => (key: key, on: on);
}

/// The account's home rows, as the web client's Home page draws them: one
/// rounded card, a row per entry, dragged by its handle. On a TV or keyboard,
/// SELECT on a handle picks the row up, UP/DOWN move it, and SELECT or BACK
/// puts it down; each move saves at once.
class _HomeRowsEditor extends StatefulWidget {
  final List<_HomeRow> rows;

  const _HomeRowsEditor({required this.rows});

  @override
  State<_HomeRowsEditor> createState() => _HomeRowsEditorState();
}

class _HomeRowsEditorState extends State<_HomeRowsEditor> {
  /// The rows as shown: the provider's, or this list's own order while a move
  /// is saving, so a dropped row does not jump back.
  late List<_HomeRow> _rows = widget.rows;

  /// The row picked up with the keyboard, by key.
  String? _moving;

  final Map<String, FocusNode> _handleNodes = {};

  @override
  void didUpdateWidget(_HomeRowsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rows, widget.rows)) _rows = widget.rows;
  }

  @override
  void dispose() {
    for (final node in _handleNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _handleNode(String key) => _handleNodes.putIfAbsent(key, () => FocusNode(debugLabel: 'homeRow:$key'));

  HiddenLibrariesProvider get _layout => context.read<HiddenLibrariesProvider>();

  Future<void> _saveRows(List<_HomeRow> rows) {
    setState(() => _rows = rows);
    return _save(context, () => _layout.saveHomeRows([for (final row in rows) row.entry]));
  }

  void _reorder(int from, int to) {
    final rows = List.of(_rows);
    rows.insert(to, rows.removeAt(from));
    _saveRows(rows);
  }

  void _setOn(_HomeRow row, bool on) => _saveRows([for (final r in _rows) r.key == row.key ? r.withOn(on) : r]);

  void _setStyle(_HomeRow row, HomeCardStyle style) => _save(context, () => _layout.setCardStyle(row.key, style));

  void _setSort(_HomeRow row, HomeRowSort sort) => _save(context, () => _layout.setRowSort(row.key, sort));

  KeyEventResult _onHandleKey(_HomeRow row, KeyEvent event) {
    if (_moving != row.key) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key.isBackKey) {
      if (event is KeyUpEvent) setState(() => _moving = null);
      return KeyEventResult.handled;
    }
    if (!event.isActionable) return KeyEventResult.ignored;
    final index = _rows.indexWhere((r) => r.key == row.key);
    if (key.isUpKey || key.isDownKey) {
      final to = key.isUpKey ? index - 1 : index + 1;
      if (index >= 0 && to >= 0 && to < _rows.length) {
        final rows = List.of(_rows);
        rows.insert(to, rows.removeAt(index));
        _saveRows(rows);
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleNode(row.key).requestFocus());
      }
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      setState(() => _moving = null);
      return KeyEventResult.handled;
    }
    // Left and right stay on the handle while the row is picked up.
    return key.isDpadDirection ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens(context);
    final count = _rows.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: count,
        onReorderItem: _reorder,
        proxyDecorator: (child, index, animation) => Material(
          elevation: 8,
          color: Colors.transparent,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(t.radiusLg),
          child: child,
        ),
        itemBuilder: (context, index) {
          final row = _rows[index];
          return Padding(
            key: ValueKey(row.key),
            padding: EdgeInsets.only(top: index == 0 ? 0 : t.groupGap),
            child: Material(
              color: _moving == row.key ? Theme.of(context).colorScheme.primaryContainer : t.surface,
              borderRadius: groupItemRadii(context, index, count),
              clipBehavior: Clip.antiAlias,
              child: _HomeRowTile(
                row: row,
                index: index,
                moving: _moving == row.key,
                handleNode: _handleNode(row.key),
                onHandlePressed: () => setState(() => _moving = _moving == row.key ? null : row.key),
                onHandleKey: (event) => _onHandleKey(row, event),
                onOn: (on) => _setOn(row, on),
                onStyle: (style) => _setStyle(row, style),
                onSort: (sort) => _setSort(row, sort),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeRowTile extends StatelessWidget {
  final _HomeRow row;
  final int index;
  final bool moving;
  final FocusNode handleNode;
  final VoidCallback onHandlePressed;
  final KeyEventResult Function(KeyEvent event) onHandleKey;
  final ValueChanged<bool> onOn;
  final ValueChanged<HomeCardStyle> onStyle;
  final ValueChanged<HomeRowSort> onSort;

  const _HomeRowTile({
    required this.row,
    required this.index,
    required this.moving,
    required this.handleNode,
    required this.onHandlePressed,
    required this.onHandleKey,
    required this.onOn,
    required this.onStyle,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final handle = ReorderableDragStartListener(
      index: index,
      child: Focus(
        focusNode: handleNode,
        onKeyEvent: (_, event) => onHandleKey(event),
        child: IconButton(
          tooltip: t.settings.homeRowDragToMove,
          onPressed: onHandlePressed,
          icon: AppIcon(
            moving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
            fill: 1,
            color: moving ? colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
    final name = Opacity(
      opacity: row.on ? 1 : 0.5,
      child: Row(
        children: [
          AppIcon(row.icon, fill: 1),
          const SizedBox(width: 12),
          Flexible(
            child: Text(row.title, overflow: TextOverflow.ellipsis, style: settingsOptionTitleStyle(context)),
          ),
        ],
      ),
    );
    // Library rows pick their item order, before the card choice; Continue
    // Watching and Next Up keep the server's (PlezyFin PLAN_SHA_12).
    final choice = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (row.library != null) _SortChoice(row: row, onSort: onSort),
        _CardChoice(row: row, onStyle: onStyle),
      ],
    );
    final toggle = Switch(value: row.on, onChanged: onOn);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone puts the card choice on its own line under the name.
        final narrow = constraints.maxWidth < 600;
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        handle,
                        const SizedBox(width: 4),
                        Expanded(child: name),
                        toggle,
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(52, 0, 0, 6),
                      child: Align(alignment: Alignment.centerLeft, child: choice),
                    ),
                  ],
                )
              : Row(
                  children: [
                    handle,
                    const SizedBox(width: 4),
                    Expanded(child: name),
                    const SizedBox(width: 12),
                    choice,
                    const SizedBox(width: 12),
                    toggle,
                  ],
                ),
        );
      },
    );
  }
}

String _rowSortLabel(HomeRowSort sort) => switch (sort) {
  HomeRowSort.added => t.settings.rowSortAdded,
  HomeRowSort.released => t.settings.rowSortReleased,
  HomeRowSort.upcoming => t.settings.rowSortUpcoming,
};

/// A library row's item order: a small pill naming the current order that
/// opens the three choices, which works the same with a pointer and a remote.
class _SortChoice extends StatelessWidget {
  final _HomeRow row;
  final ValueChanged<HomeRowSort> onSort;

  const _SortChoice({required this.row, required this.onSort});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusColor: colorScheme.onSurface.withValues(alpha: 0.2),
        onTap: () async {
          final picked = await showSelectionDialog<HomeRowSort>(
            context: context,
            title: t.settings.rowSortTitle,
            options: [for (final sort in HomeRowSort.values) DialogOption(value: sort, title: _rowSortLabel(sort))],
            currentValue: row.sort,
          );
          final sort = picked?.value;
          if (sort != null && sort != row.sort) onSort(sort);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_rowSortLabel(row.sort), style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 2),
              const AppIcon(Symbols.arrow_drop_down_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// The segmented pill for a row's cards: the picked choice filled light, the
/// others dark, as on the web client.
class _CardChoice extends StatelessWidget {
  final _HomeRow row;
  final ValueChanged<HomeCardStyle> onStyle;

  const _CardChoice({required this.row, required this.onStyle});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final picked = row.shownStyle;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final choice in row.choices)
            _PillButton(
              label: choice.label,
              selected: choice.style == picked,
              onPressed: () {
                if (choice.style != picked) onStyle(choice.style);
              },
            ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _PillButton({required this.label, required this.selected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colorScheme.onSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          focusColor: selected
              ? colorScheme.onSurface.withValues(alpha: 0.75)
              : colorScheme.onSurface.withValues(alpha: 0.2),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? colorScheme.surface : colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
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
          DialogOption(value: _SectionAction.cardsSeason, title: t.settings.cardSeasonPoster),
          DialogOption(value: _SectionAction.cardsScreenGrabs, title: t.settings.cardsScreenGrabs),
        ],
      ],
      // Marks the current card style; the other actions are never selected.
      currentValue: switch (cardStyle) {
        _ when !_hasCards(section) => null,
        HomeCardStyle.poster => _SectionAction.cardsPosters,
        HomeCardStyle.season => _SectionAction.cardsSeason,
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
        if (section == HomeLayout.hero) {
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
      case _SectionAction.cardsSeason:
        await layout.setCardStyle(layout.sectionCardKey(section), HomeCardStyle.season);
      case _SectionAction.cardsScreenGrabs:
        await layout.setCardStyle(layout.sectionCardKey(section), HomeCardStyle.thumb);
    }
  }
}
