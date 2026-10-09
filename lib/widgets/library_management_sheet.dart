import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/dpad_reorder_mixin.dart';
import '../focus/focus_theme.dart';
import '../focus/input_mode_tracker.dart';
import '../i18n/strings.g.dart';
import '../media/library_layout.dart';
import '../media/media_backend.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../utils/app_logger.dart';
import '../utils/content_utils.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'app_menu.dart';
import 'bottom_sheet_page_scaffold.dart';
import 'overlay_sheet.dart';

class ContextMenuItem {
  final String value;
  final IconData icon;
  final String label;
  final bool requiresConfirmation;
  final String? confirmationTitle;
  final String? confirmationMessage;
  final bool isDestructive;

  const ContextMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.requiresConfirmation = false,
    this.confirmationTitle,
    this.confirmationMessage,
    this.isDestructive = false,
  });
}

/// Shows the manage-libraries sheet (dialog on TV and desktop, overlay sheet
/// otherwise): every library in three sections, Shown, Folded and Not shown,
/// arranged by drag or by D-pad pick-up-and-move (Adrian, 2026-10-09). The
/// layout is provider-backed, so any screen can open it.
///
/// [onOrderChanged] runs after the new order is written to
/// [LibrariesProvider] (the libraries screen uses it to poke MainScreen's
/// side nav). [onStateChanged] runs after a library changes section (the
/// libraries screen moves off a library that is no longer reachable).
Future<void> showLibraryManagementSheet(
  BuildContext context, {
  VoidCallback? onOrderChanged,
  void Function(MediaLibrary library, LibraryState state)? onStateChanged,
}) {
  final librariesProvider = context.read<LibrariesProvider>();
  final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
  final allLibraries = librariesProvider.libraries;

  Future<void> saveArrangement(
    List<({MediaLibrary library, LibraryState state})> arrangement,
    ({int index, LibraryState state})? favorites,
  ) async {
    final before = {for (final library in allLibraries) library.globalKey: hiddenLibrariesProvider.stateOf(library)};
    unawaited(librariesProvider.updateLibraryOrder([for (final entry in arrangement) entry.library]));
    onOrderChanged?.call();
    try {
      await hiddenLibrariesProvider.saveArrangement(arrangement, favorites: favorites);
    } catch (e) {
      appLogger.w('Failed to save the library layout', error: e);
      if (context.mounted) showErrorSnackBar(context, t.messages.errorLoading(error: e.toString()));
      return;
    }
    for (final entry in arrangement) {
      if (before[entry.library.globalKey] != entry.state) onStateChanged?.call(entry.library, entry.state);
    }
  }

  // The rows outlive the page: opening a library's menu replaces the page, and
  // coming back builds it again from these.
  // The PlezyFin account's Favourites entry sits among the libraries of its
  // section, where the account places it.
  final favoritesState = hiddenLibrariesProvider.favoritesState;
  final rows = <_ManageRow>[];
  for (final state in LibraryState.values) {
    final section = [
      for (final library in allLibraries)
        if (hiddenLibrariesProvider.stateOf(library) == state) library,
    ];
    final sectionRows = <_ManageRow>[for (final library in section) _LibraryRow(library)];
    if (favoritesState == state) {
      sectionRows.insert(hiddenLibrariesProvider.favoritesIndexIn(section), const _FavoritesRow());
    }
    rows
      ..add(_SectionRow(state))
      ..addAll(sectionRows);
  }

  Widget buildSheet({required bool isDialog}) => _LibraryManagementSheet(
    isDialog: isDialog,
    rows: rows,
    onArrangementChanged: saveArrangement,
    getLibraryMenuItems: _getLibraryMenuItems,
    onLibraryMenuAction: (action, library) => _handleLibraryMenuAction(context, action, library),
  );

  // Desktop takes the TV's centred dialog too: it suits a big window better
  // than the slide-in sheet.
  if (PlatformDetector.isTV() || PlatformDetector.isDesktopOS()) {
    return showScopedDialog<void>(context: context, builder: (context) => buildSheet(isDialog: true));
  }
  // Use the host supplied by the calling screen when available while keeping
  // this reusable entry point safe for routes without one. isScrollControlled
  // keeps that modal fallback from capping the sheet at ~9/16 of the screen.
  return OverlaySheetController.showAdaptive<void>(
    context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => buildSheet(isDialog: false),
  );
}

List<ContextMenuItem> _getLibraryMenuItems(MediaLibrary library) {
  // Refresh metadata is the only admin action every backend supports — Plex
  // hits `/library/sections/{id}/refresh?force=1`; MediaBrowser servers post
  // to `/Items/{id}/Refresh` (the library view is itself an item).
  final refresh = ContextMenuItem(
    value: 'refresh',
    icon: Symbols.sync_rounded,
    label: t.libraries.refreshMetadata,
    requiresConfirmation: true,
    confirmationTitle: t.libraries.refreshMetadata,
    confirmationMessage: t.libraries.refreshMetadataConfirm(title: library.title),
    isDestructive: true,
  );
  // Scan / analyze / empty trash hit Plex-only endpoints, so backend
  // capability gating keeps them out of MediaBrowser menus. The library-qualified
  // resolver independently requires the exact owning Plex server.
  if (library.backend != MediaBackend.plex) return [refresh];
  return [
    ContextMenuItem(
      value: 'scan',
      icon: Symbols.refresh_rounded,
      label: t.libraries.scanLibraryFiles,
      requiresConfirmation: true,
      confirmationTitle: t.libraries.scanLibrary,
      confirmationMessage: t.libraries.scanLibraryConfirm(title: library.title),
    ),
    ContextMenuItem(
      value: 'analyze',
      icon: Symbols.analytics_rounded,
      label: t.libraries.analyze,
      requiresConfirmation: true,
      confirmationTitle: t.libraries.analyzeLibrary,
      confirmationMessage: t.libraries.analyzeLibraryConfirm(title: library.title),
    ),
    refresh,
    ContextMenuItem(
      value: 'empty_trash',
      icon: Symbols.delete_outline_rounded,
      label: t.libraries.emptyTrash,
      requiresConfirmation: true,
      confirmationTitle: t.libraries.emptyTrash,
      confirmationMessage: t.libraries.emptyTrashConfirm(title: library.title),
      isDestructive: true,
    ),
  ];
}

Future<void> _handleLibraryMenuAction(BuildContext context, String action, MediaLibrary library) async {
  // Find the menu item for confirmation details
  final menuItems = _getLibraryMenuItems(library);
  final item = menuItems.where((i) => i.value == action).firstOrNull;
  if (item == null) return;

  if (item.requiresConfirmation) {
    final confirmed = await showConfirmDialog(
      context,
      title: item.confirmationTitle ?? t.dialog.confirmAction,
      message: item.confirmationMessage ?? t.libraries.confirmActionMessage,
      confirmText: t.common.confirm,
      isDestructive: item.isDestructive,
    );
    if (!confirmed || !context.mounted) return;
  }

  switch (action) {
    case 'scan':
      unawaited(_scanLibrary(context, library));
      break;
    case 'analyze':
      unawaited(_analyzeLibrary(context, library));
      break;
    case 'refresh':
      unawaited(_refreshLibraryMetadata(context, library));
      break;
    case 'empty_trash':
      unawaited(_emptyLibraryTrash(context, library));
      break;
  }
}

/// Runs a library admin action, wrapping it in progress/success/failure
/// snackbars.
///
/// [resolveClient] picks the client flavour: `getPlexClientForLibrary` for the
/// Plex-only endpoints (scan / analyze / empty trash), `getMediaClientForLibrary`
/// for ops that exist on the backend-neutral [MediaServerClient] interface
/// (currently just refresh metadata). Both resolvers require the library's exact
/// owning server and throw the same error when it isn't available.
Future<void> _performLibraryAction<T extends MediaServerClient>(
  BuildContext context, {
  required T Function(BuildContext context) resolveClient,
  required Future<void> Function(T client) action,
  required String progressMessage,
  required String successMessage,
  required String Function(Object error) failureMessage,
}) async {
  try {
    final client = resolveClient(context);

    if (context.mounted) {
      showAppSnackBar(context, progressMessage, duration: const Duration(seconds: 2));
    }

    await action(client);

    if (context.mounted) {
      showSuccessSnackBar(context, successMessage);
    }
  } catch (e) {
    appLogger.e('Library action failed', error: e);
    if (context.mounted) {
      showErrorSnackBar(context, failureMessage(e));
    }
  }
}

Future<void> _scanLibrary(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getPlexClientForLibrary(library),
    action: (client) => client.scanLibrary(library.id),
    progressMessage: t.messages.libraryScanning(title: library.title),
    successMessage: t.messages.libraryScanStarted(title: library.title),
    failureMessage: (error) => t.messages.libraryScanFailed(error: error.toString()),
  );
}

Future<void> _refreshLibraryMetadata(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getMediaClientForLibrary(library),
    action: (client) => client.refreshLibraryMetadata(library.id),
    progressMessage: t.messages.metadataRefreshing(title: library.title),
    successMessage: t.messages.metadataRefreshStarted(title: library.title),
    failureMessage: (error) => t.messages.metadataRefreshFailed(error: error.toString()),
  );
}

Future<void> _emptyLibraryTrash(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getPlexClientForLibrary(library),
    action: (client) => client.emptyLibraryTrash(library.id),
    progressMessage: t.libraries.emptyingTrash(title: library.title),
    successMessage: t.libraries.trashEmptied(title: library.title),
    failureMessage: (error) => t.libraries.failedToEmptyTrash(error: error),
  );
}

Future<void> _analyzeLibrary(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getPlexClientForLibrary(library),
    action: (client) => client.analyzeLibrary(library.id),
    progressMessage: t.libraries.analyzing(title: library.title),
    successMessage: t.libraries.analysisStarted(title: library.title),
    failureMessage: (error) => t.libraries.failedToAnalyze(error: error),
  );
}

sealed class _ManageRow {
  const _ManageRow();
}

/// A section header; every library below it, down to the next header, is in
/// [state].
class _SectionRow extends _ManageRow {
  final LibraryState state;
  const _SectionRow(this.state);
}

class _LibraryRow extends _ManageRow {
  final MediaLibrary library;
  const _LibraryRow(this.library);
}

/// The PlezyFin account's Favourites entry, arranged like a library.
class _FavoritesRow extends _ManageRow {
  const _FavoritesRow();
}

class _LibraryManagementSheet extends StatefulWidget {
  final bool isDialog;

  /// Section headers with the libraries between them; changed in place.
  final List<_ManageRow> rows;
  final Future<void> Function(
    List<({MediaLibrary library, LibraryState state})> arrangement,
    ({int index, LibraryState state})? favorites,
  )
  onArrangementChanged;
  final List<ContextMenuItem> Function(MediaLibrary) getLibraryMenuItems;
  final void Function(String action, MediaLibrary library) onLibraryMenuAction;

  const _LibraryManagementSheet({
    this.isDialog = false,
    required this.rows,
    required this.onArrangementChanged,
    required this.getLibraryMenuItems,
    required this.onLibraryMenuAction,
  });

  @override
  State<_LibraryManagementSheet> createState() => _LibraryManagementSheetState();
}

class _LibraryManagementSheetState extends State<_LibraryManagementSheet>
    with DpadReorderListMixin<_ManageRow, _LibraryManagementSheet> {
  List<_ManageRow> get _rows => widget.rows;

  final FocusNode _listFocusNode = FocusNode();
  final ScrollController _dialogScrollController = ScrollController();
  final ScrollController _sheetScrollController = ScrollController();

  static const _moveActions = {
    LibraryState.shown: 'move:shown',
    LibraryState.folded: 'move:folded',
    LibraryState.off: 'move:off',
  };

  @override
  List<_ManageRow> get reorderItems => _rows;

  @override
  set reorderItems(List<_ManageRow> value) => _rows
    ..clear()
    ..addAll(value);

  @override
  int get lastReorderColumn => 1;

  @override
  int lastReorderColumnAt(int index) => _rows[index] is _SectionRow ? 0 : 1;

  @override
  bool canMoveReorderItem(int index) => _rows[index] is! _SectionRow;

  @override
  int get firstReorderMoveIndex => 1;

  /// Both layouts scroll the focused row into view: the TV dialog is the D-pad
  /// surface, and the sheet still shows the same cursor to a keyboard user.
  @override
  ScrollController? get reorderScrollController => widget.isDialog ? _dialogScrollController : _sheetScrollController;

  @override
  void onReorderMoveConfirmed() => _save();

  @override
  void onReorderColumnActivated(int column, int index) {
    final row = _rows[index];
    if (column != 1) return;
    switch (row) {
      case _LibraryRow():
        _showLibraryMenuBottomSheet(context, row.library);
      case _FavoritesRow():
        _showFavoritesMenu(context);
      case _SectionRow():
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    // Start on the first library, not on the Shown header.
    focusedIndex = 1;
  }

  @override
  void dispose() {
    _listFocusNode.dispose();
    _dialogScrollController.dispose();
    _sheetScrollController.dispose();
    super.dispose();
  }

  /// Every library with the section it sits in, top to bottom, and where the
  /// Favourites entry sits among them.
  ({List<({MediaLibrary library, LibraryState state})> libraries, ({int index, LibraryState state})? favorites})
  get _arrangement {
    final libraries = <({MediaLibrary library, LibraryState state})>[];
    ({int index, LibraryState state})? favorites;
    var state = LibraryState.shown;
    for (final row in _rows) {
      switch (row) {
        case _SectionRow():
          state = row.state;
        case _LibraryRow():
          libraries.add((library: row.library, state: state));
        case _FavoritesRow():
          favorites = (index: libraries.length, state: state);
      }
    }
    return (libraries: libraries, favorites: favorites);
  }

  void _save() {
    final arrangement = _arrangement;
    unawaited(widget.onArrangementChanged(arrangement.libraries, arrangement.favorites));
  }

  void _reorderRows(int oldIndex, int newIndex) {
    if (_rows[oldIndex] is _SectionRow) return;
    setState(() {
      final row = _rows.removeAt(oldIndex);
      // Nothing goes above the first header.
      _rows.insert(newIndex.clamp(firstReorderMoveIndex, _rows.length), row);
    });
    _save();
  }

  /// Move [library] to the end of [state]'s section. The menu that asks for
  /// it has replaced this page by then, so the shared rows change and the page
  /// built on return shows them.
  void _moveToSection(MediaLibrary library, LibraryState state) => _moveRowToSection(
    _rows.indexWhere((row) => row is _LibraryRow && row.library.globalKey == library.globalKey),
    state,
  );

  void _moveRowToSection(int index, LibraryState state) {
    if (index < 0) return;
    final row = _rows.removeAt(index);
    final nextHeader = _rows.indexWhere((r) => r is _SectionRow && r.state.index > state.index);
    _rows.insert(nextHeader < 0 ? _rows.length : nextHeader, row);
    if (mounted) {
      setState(() {
        focusedIndex = _rows.indexOf(row);
        focusedColumn = 0;
      });
    }
    _save();
  }

  LibraryState _stateAt(int index) {
    for (var i = index; i >= 0; i--) {
      final row = _rows[i];
      if (row is _SectionRow) return row.state;
    }
    return LibraryState.shown;
  }

  void _showLibraryMenuBottomSheet(BuildContext outerContext, MediaLibrary library) {
    final index = _rows.indexWhere((row) => row is _LibraryRow && row.library.globalKey == library.globalKey);
    final current = index < 0 ? LibraryState.shown : _stateAt(index);
    final menuItems = widget.getLibraryMenuItems(library);
    OverlaySheetController.pushAdaptive<String>(
      outerContext,
      builder: (menuContext) => AppMenuSheet<String>(
        title: library.title,
        // A move pops only this menu, back to the sections; a library action
        // closes the whole sheet before its confirmation, as before.
        closeOnSelected: false,
        entries: [
          for (final state in LibraryState.values)
            if (state != current)
              AppMenuItem<String>(value: _moveActions[state]!, icon: _sectionIcon(state), label: _moveLabel(state)),
          if (menuItems.isNotEmpty) const AppMenuDivider<String>(),
          for (final item in menuItems)
            AppMenuItem<String>(value: item.value, icon: item.icon, label: item.label, destructive: item.isDestructive),
        ],
        onSelected: (value) {
          final move = _moveActions.entries.where((entry) => entry.value == value).firstOrNull;
          if (move != null) {
            OverlaySheetController.popAdaptive(menuContext);
            _moveToSection(library, move.key);
          } else {
            OverlaySheetController.closeAdaptive(menuContext, value);
            widget.onLibraryMenuAction(value, library);
          }
        },
      ),
    );
  }

  void _showFavoritesMenu(BuildContext outerContext) {
    final index = _rows.indexWhere((row) => row is _FavoritesRow);
    final current = index < 0 ? LibraryState.shown : _stateAt(index);
    OverlaySheetController.pushAdaptive<String>(
      outerContext,
      builder: (menuContext) => AppMenuSheet<String>(
        title: t.navigation.favorites,
        closeOnSelected: false,
        entries: [
          for (final state in LibraryState.values)
            if (state != current)
              AppMenuItem<String>(value: _moveActions[state]!, icon: _sectionIcon(state), label: _moveLabel(state)),
        ],
        onSelected: (value) {
          final move = _moveActions.entries.where((entry) => entry.value == value).firstOrNull;
          OverlaySheetController.popAdaptive(menuContext);
          if (move != null) _moveRowToSection(_rows.indexWhere((row) => row is _FavoritesRow), move.key);
        },
      ),
    );
  }

  static IconData _sectionIcon(LibraryState state) => switch (state) {
    LibraryState.shown => Symbols.visibility_rounded,
    LibraryState.folded => Symbols.visibility_off_rounded,
    LibraryState.off => Symbols.block_rounded,
  };

  static String _sectionLabel(LibraryState state) => switch (state) {
    LibraryState.shown => t.libraries.sectionShown,
    LibraryState.folded => t.libraries.sectionFolded,
    LibraryState.off => t.libraries.sectionNotShown,
  };

  static String _moveLabel(LibraryState state) => switch (state) {
    LibraryState.shown => t.libraries.moveToShown,
    LibraryState.folded => t.libraries.moveToFolded,
    LibraryState.off => t.libraries.moveToNotShown,
  };

  /// Whether the libraries span more than one connected server.
  bool _hasMultipleServers() {
    final serverIds = {
      for (final row in _rows)
        if (row is _LibraryRow && row.library.serverId != null) row.library.serverId,
    };
    return serverIds.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isDialog) {
      return Dialog(
        child: PopScope(
          canPop: false, // Prevent system back from double-popping; handled by handleReorderKeyEvent
          // ignore: no-empty-block - required callback, blocks system back on Android TV
          onPopInvokedWithResult: (didPop, result) {},
          child: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  const AppIcon(Symbols.edit_rounded, fill: 1),
                  const SizedBox(width: 12),
                  Text(t.libraries.manageLibraries),
                ],
              ),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const AppIcon(Symbols.close_rounded, fill: 1),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            body: Focus(
              focusNode: _listFocusNode,
              descendantsAreFocusable: false,
              autofocus: InputModeTracker.isKeyboardMode(context),
              onKeyEvent: handleReorderKeyEvent,
              child: _buildRowList(_dialogScrollController, shrinkWrap: false),
            ),
          ),
        ),
      );
    }

    return BottomSheetPageScaffold(
      title: t.libraries.manageLibraries,
      icon: Symbols.edit_rounded,
      child: Focus(
        focusNode: _listFocusNode,
        descendantsAreFocusable: false,
        autofocus: InputModeTracker.isKeyboardMode(context),
        onKeyEvent: handleReorderKeyEvent,
        child: _buildRowList(_sheetScrollController, shrinkWrap: true),
      ),
    );
  }

  /// One reorderable list: three section headers with the libraries between
  /// them. Each layout passes its own controller, which is also what
  /// [reorderScrollController] scrolls when the keyboard cursor moves.
  Widget _buildRowList(ScrollController scrollController, {required bool shrinkWrap}) {
    final showServerNames = _hasMultipleServers();
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);

    return ReorderableListView.builder(
      scrollController: scrollController,
      shrinkWrap: shrinkWrap,
      onReorderItem: _reorderRows,
      itemCount: _rows.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final isFocused = isKeyboardMode && index == focusedIndex;
        return switch (_rows[index]) {
          _SectionRow(:final state) => _buildSectionHeader(state, index, isFocused: isFocused),
          _LibraryRow(:final library) => _buildLibraryTile(
            library,
            index,
            _stateAt(index),
            showServerName: showServerNames && library.serverName != null,
            isFocused: isFocused,
            isMoving: index == movingIndex,
            focusedColumn: isFocused ? focusedColumn : null,
          ),
          _FavoritesRow() => _buildFavoritesTile(
            index,
            _stateAt(index),
            isFocused: isFocused,
            isMoving: index == movingIndex,
            focusedColumn: isFocused ? focusedColumn : null,
          ),
        };
      },
    );
  }

  Widget _buildSectionHeader(LibraryState state, int index, {required bool isFocused}) {
    final theme = Theme.of(context);
    var count = 0;
    for (var i = index + 1; i < _rows.length && _rows[i] is! _SectionRow; i++) {
      count++;
    }
    return Container(
      key: ValueKey('section:${state.wire}'),
      color: isFocused ? theme.colorScheme.surfaceContainerHighest : null,
      padding: EdgeInsets.fromLTRB(16, index == 0 ? 4 : 16, 16, 4),
      child: Row(
        children: [
          AppIcon(_sectionIcon(state), fill: 1, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '${_sectionLabel(state)} ($count)',
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesTile(
    int index,
    LibraryState state, {
    bool isFocused = false,
    bool isMoving = false,
    int? focusedColumn,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    Color? tileColor;
    if (isMoving) {
      tileColor = colorScheme.primaryContainer;
    } else if (isFocused && focusedColumn == 0) {
      tileColor = colorScheme.surfaceContainerHighest;
    }
    return Opacity(
      key: const ValueKey('favorites'),
      opacity: switch (state) {
        LibraryState.shown => 1.0,
        LibraryState.folded => 0.7,
        LibraryState.off => 0.45,
      },
      child: ListTile(
        tileColor: tileColor,
        leading: Row(
          mainAxisSize: .min,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: AppIcon(
                isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
                fill: 1,
                color: isMoving ? colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
            const AppIcon(Symbols.favorite_rounded, fill: 1),
          ],
        ),
        title: Text(t.navigation.favorites),
        trailing: Container(
          decoration: FocusTheme.focusBackgroundDecoration(
            isFocused: isFocused && focusedColumn == 1,
            borderRadius: 20,
          ),
          child: IconButton(
            icon: const AppIcon(Symbols.more_vert_rounded, fill: 1),
            tooltip: t.libraries.libraryOptions,
            onPressed: () => _showFavoritesMenu(context),
          ),
        ),
      ),
    );
  }

  /// Build a single library tile
  Widget _buildLibraryTile(
    MediaLibrary library,
    int index,
    LibraryState state, {
    bool showServerName = false,
    bool isFocused = false,
    bool isMoving = false,
    int? focusedColumn,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    Color? tileColor;
    if (isMoving) {
      tileColor = colorScheme.primaryContainer;
    } else if (isFocused && focusedColumn == 0) {
      tileColor = colorScheme.surfaceContainerHighest;
    }

    final isOptionsButtonFocused = isFocused && focusedColumn == 1;

    return Opacity(
      key: ValueKey(library.globalKey),
      opacity: switch (state) {
        LibraryState.shown => 1.0,
        LibraryState.folded => 0.7,
        LibraryState.off => 0.45,
      },
      child: ListTile(
        tileColor: tileColor,
        leading: Row(
          mainAxisSize: .min,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: AppIcon(
                isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
                fill: 1,
                color: isMoving ? colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
            AppIcon(ContentTypeHelper.getLibraryIcon(library.kind.id), fill: 1),
          ],
        ),
        title: Text(library.title),
        subtitle: showServerName
            ? Text(
                library.serverName!,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                ),
              )
            : null,
        trailing: Container(
          decoration: FocusTheme.focusBackgroundDecoration(isFocused: isOptionsButtonFocused, borderRadius: 20),
          child: IconButton(
            icon: const AppIcon(Symbols.more_vert_rounded, fill: 1),
            tooltip: t.libraries.libraryOptions,
            onPressed: () => _showLibraryMenuBottomSheet(context, library),
          ),
        ),
      ),
    );
  }
}
