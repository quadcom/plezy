import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/search_scope.dart';
import '../utils/focus_utils.dart';
import 'app_icon.dart';
import 'app_menu.dart';

/// The search field's hint for the ticked [scope], e.g. "Search titles,
/// actors and keywords", or "Tick at least one thing to search" when nothing
/// is ticked.
String searchScopeHint(Set<SearchScopeKind> scope) {
  if (scope.isEmpty) return t.search.scopeHint.nothingTicked;
  final names = [
    for (final kind in SearchScopeKind.values)
      if (scope.contains(kind))
        switch (kind) {
          SearchScopeKind.titles => t.search.scopeHint.titles,
          SearchScopeKind.actors => t.search.scopeHint.actors,
          SearchScopeKind.keywords => t.search.scopeHint.keywords,
          SearchScopeKind.crew => t.search.scopeHint.crew,
          SearchScopeKind.genres => t.search.scopeHint.genres,
          SearchScopeKind.studios => t.search.scopeHint.studios,
          SearchScopeKind.year => t.search.scopeHint.year,
        },
  ];
  final list = names.length == 1
      ? names.single
      : t.search.scopeHint.listAnd(first: names.sublist(0, names.length - 1).join(', '), last: names.last);
  return t.search.scopeHint.search(kinds: list);
}

/// The "Search in" pop-up: one tick per [SearchScopeKind], the usual three
/// first, then a divider, then the rest, and a footer saying where the ticks
/// are kept with a Reset back to [SearchScopeKind.defaults]
/// (local/plans/search-actors.md, mock-up `local/mockups/search-actors`).
///
/// Rows are [AppMenuItemTile]s, the same rows every Plezy menu uses, so the
/// D-pad moves between them, Select toggles and Back closes the panel that
/// hosts this ([showAnchoredPanel]). Every change is reported through
/// [onChanged] at once, so the search behind the panel re-runs.
class SearchScopePanel extends StatefulWidget {
  const SearchScopePanel({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.savedToAccount,
    this.focusFirstRow = false,
  });

  final Set<SearchScopeKind> initial;
  final ValueChanged<Set<SearchScopeKind>> onChanged;

  /// Whether the footer says "Saved to your account" or "on this device".
  final bool savedToAccount;

  /// Keyboard and D-pad sessions start on the first row.
  final bool focusFirstRow;

  /// Rows above the divider; the rest follow it.
  static const _usual = [SearchScopeKind.titles, SearchScopeKind.actors, SearchScopeKind.keywords];
  static const _more = [SearchScopeKind.crew, SearchScopeKind.genres, SearchScopeKind.studios, SearchScopeKind.year];

  static String labelOf(SearchScopeKind kind) => switch (kind) {
    SearchScopeKind.titles => t.search.searchIn.titles,
    SearchScopeKind.actors => t.search.searchIn.actors,
    SearchScopeKind.keywords => t.search.searchIn.keywords,
    SearchScopeKind.crew => t.search.searchIn.crew,
    SearchScopeKind.genres => t.search.searchIn.genres,
    SearchScopeKind.studios => t.search.searchIn.studios,
    SearchScopeKind.year => t.search.searchIn.year,
  };

  static String? subtitleOf(SearchScopeKind kind) => switch (kind) {
    SearchScopeKind.titles => t.search.searchIn.titlesSubtitle,
    SearchScopeKind.keywords => t.search.searchIn.keywordsSubtitle,
    SearchScopeKind.year => t.search.searchIn.yearSubtitle,
    _ => null,
  };

  @override
  State<SearchScopePanel> createState() => _SearchScopePanelState();
}

class _SearchScopePanelState extends State<SearchScopePanel> {
  late Set<SearchScopeKind> _kinds = {...widget.initial};
  final FocusNode _firstRow = FocusNode(debugLabel: 'SearchInFirstRow');

  @override
  void initState() {
    super.initState();
    if (widget.focusFirstRow) FocusUtils.requestFocusAfterBuild(this, _firstRow);
  }

  @override
  void dispose() {
    _firstRow.dispose();
    super.dispose();
  }

  void _set(Set<SearchScopeKind> kinds) {
    setState(() => _kinds = kinds);
    widget.onChanged({...kinds});
  }

  void _toggle(SearchScopeKind kind) {
    final next = {..._kinds};
    if (!next.remove(kind)) next.add(kind);
    _set(next);
  }

  Widget _row(SearchScopeKind kind) {
    final ticked = _kinds.contains(kind);
    final primary = Theme.of(context).colorScheme.primary;
    return AppMenuItemTile<SearchScopeKind>(
      key: ValueKey('search_in_${kind.id}'),
      focusNode: kind == SearchScopeKind.titles ? _firstRow : null,
      item: AppMenuItem(
        value: kind,
        label: SearchScopePanel.labelOf(kind),
        subtitle: SearchScopePanel.subtitleOf(kind),
        semanticLabel: SearchScopePanel.labelOf(kind),
        leading: AppIcon(
          ticked ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded,
          fill: ticked ? 1 : 0,
          color: ticked ? primary : null,
        ),
      ),
      onPressed: () => _toggle(kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.62);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text(
                t.search.searchIn.title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: muted,
                ),
              ),
            ),
            for (final kind in SearchScopePanel._usual) _row(kind),
            const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1)),
            for (final kind in SearchScopePanel._more) _row(kind),
            const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1)),
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text(
                      widget.savedToAccount ? t.search.searchIn.savedToAccount : t.search.searchIn.savedOnDevice,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: AppMenuItemTile<String>(
                    key: const ValueKey('search_in_reset'),
                    item: AppMenuItem(
                      value: 'reset',
                      label: t.search.searchIn.reset,
                      foregroundColor: theme.colorScheme.primary,
                    ),
                    onPressed: () => _set({...SearchScopeKind.defaults}),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
