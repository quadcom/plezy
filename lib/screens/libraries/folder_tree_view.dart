import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../services/jellyfin_sequential_launcher.dart';
import '../../services/media_list_playback_launcher.dart';
import '../../services/play_queue_launcher.dart';
import '../../utils/app_logger.dart';
import '../../utils/error_message_utils.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../utils/grid_size_calculator.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/media_grid_delegate.dart';
import 'folder_grid_tile.dart';
import 'folder_tree_item.dart';
import 'state_messages.dart';

/// How the folder grid orders a folder's videos; sub-folders always come
/// first, by name (local/plans/home-video-grid.md).
enum FolderGridSort {
  name,
  newest,
  largest;

  static FolderGridSort parse(String? value) => values.firstWhere((s) => s.name == value, orElse: () => name);
}

/// Expandable tree view for browsing library folders
/// Shows a hierarchical file/folder structure
///
/// With [grid] it is the home-video folder grid instead
/// (local/plans/home-video-grid.md): the open folder's sub-folders and
/// videos as tiles, opened one level at a time, with a path bar to go back
/// up. Back also goes up a folder before it leaves the library.
class FolderTreeView extends StatefulWidget {
  final String libraryKey;
  final String? serverId; // Server this library belongs to
  final MediaKind? libraryKind;
  final void Function(MediaItem source)? onRefresh;
  final FocusNode? firstItemFocusNode;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;

  /// Tiles, one folder at a time, instead of the expandable tree.
  final bool grid;
  final FolderGridSort gridSort;

  /// The library's name, the first part of the grid's path bar.
  final String? libraryTitle;

  const FolderTreeView({
    super.key,
    required this.libraryKey,
    this.serverId,
    this.libraryKind,
    this.onRefresh,
    this.firstItemFocusNode,
    this.onNavigateUp,
    this.onNavigateLeft,
    this.onBack,
    this.grid = false,
    this.gridSort = FolderGridSort.name,
    this.libraryTitle,
  });

  @override
  State<FolderTreeView> createState() => FolderTreeViewState();
}

/// Public state so parents can trigger a refresh via GlobalKey.
class FolderTreeViewState extends State<FolderTreeView> {
  /// Reload the root folders. Exposed for parent-driven refreshes; resolves
  /// `true` only when the fresh root listing was applied under the current
  /// load epoch (not superseded, unmounted, or failed).
  Future<bool> refresh() => _trackRootLoad(_loadRootFolders());

  /// The root listing load already running — the one [initState] starts on
  /// mount — or a fresh reload when the tree is idle. Lets a parent that owns
  /// a load epoch credit the tree's own load instead of refetching it.
  Future<bool> ensureRootLoaded() => _rootLoad ?? refresh();

  /// The root listing load in flight, `null` when none is running.
  Future<bool>? _rootLoad;

  Future<bool> _trackRootLoad(Future<bool> load) {
    _rootLoad = load;
    return load.whenComplete(() {
      if (identical(_rootLoad, load)) _rootLoad = null;
    });
  }

  /// Folders/items returned by the backend's folder API and mapped to neutral
  /// [MediaItem]s. Plex folder URLs survive in [MediaItem.raw]['key'];
  /// MediaBrowser folders use the item id as their recursive parent id.
  List<MediaItem> _rootFolders = [];
  final Map<String, List<MediaItem>> _childrenCache = {};
  final Set<String> _expandedFolders = {};
  final Set<String> _loadingFolders = {};
  bool _isLoadingRoot = false;
  String? _errorMessage;

  /// Generation counter for in-flight loads. MediaBrowser folder fetches
  /// render page-by-page via `onPage`; a root reload or deletion refresh
  /// bumps the epoch so superseded pagination callbacks are dropped.
  int _loadEpoch = 0;

  /// Stable expand/cache key for an expandable row: the backend folder key
  /// where one exists (Plex `/folder` rows), the item id otherwise.
  String? _folderIdentity(MediaItem item) {
    if (!_isExpandable(item)) return null;
    return item.backendFolderKey ?? item.id;
  }

  /// The grid's open folders, outermost first; empty at the library's top.
  final List<MediaItem> _openPath = [];

  /// Folder tiles waiting for their contents (collage and count), loaded a
  /// few at a time so a big folder doesn't fire a burst of calls.
  final List<MediaItem> _prefetchQueue = [];
  int _prefetchesRunning = 0;
  static const _maxPrefetches = 3;

  /// One focus node per tile (grid) or row (tree), by its key, so the arrow
  /// keys move by index like the library's flat grid does. Left to
  /// Flutter's directional guess, Up after scrolling down jumped to the
  /// floating chips header and the page snapped to the top
  /// (local/plans/folder-view-up-jump.md). Index 0 uses the parent's
  /// [FolderTreeView.firstItemFocusNode] when it has one.
  final Map<String, FocusNode> _itemFocusNodes = {};

  /// The grid path bar's Up button: where Up from the first row goes inside
  /// a folder.
  final FocusNode _pathBarUpFocusNode = FocusNode(debugLabel: 'folder_path_up');

  FocusNode _itemFocusNode(String key, int index) {
    final first = widget.firstItemFocusNode;
    if (index == 0 && first != null) return first;
    return _itemFocusNodes.putIfAbsent(key, () => FocusNode(debugLabel: 'folder_item_$index'));
  }

  void _focusItem(List<String> keys, int index) {
    if (index < 0 || index >= keys.length) return;
    _itemFocusNode(keys[index], index).requestFocus();
  }

  /// Swallow the key: at an edge with nothing there, stay put rather than
  /// let Flutter guess a far-off target.
  static void _stay() {}

  /// Drop the nodes of the folder no longer shown, once its tiles unmount.
  void _resetItemFocusNodes() {
    if (_itemFocusNodes.isEmpty) return;
    final old = _itemFocusNodes.values.toList();
    _itemFocusNodes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in old) {
        node.dispose();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _trackRootLoad(_loadRootFolders());
  }

  @override
  void dispose() {
    for (final node in _itemFocusNodes.values) {
      node.dispose();
    }
    _itemFocusNodes.clear();
    _pathBarUpFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(FolderTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The grid asks for file details the tree leaves out: start over.
    if (oldWidget.grid != widget.grid) {
      _resetItemFocusNodes();
      _openPath.clear();
      _prefetchQueue.clear();
      _childrenCache.clear();
      _expandedFolders.clear();
      _trackRootLoad(_loadRootFolders());
    }
  }

  /// Back in the grid: up one folder. False at the top (or in the tree), so
  /// Back leaves the library as before.
  bool goUp() {
    if (!widget.grid || _openPath.isEmpty) return false;
    _resetItemFocusNodes();
    setState(() => _openPath.removeLast());
    _focusFirstTile();
    return true;
  }

  /// With a remote or keyboard, land on the first tile of the folder shown.
  void _focusFirstTile() {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = widget.firstItemFocusNode;
      if (mounted && node != null && node.context != null) node.requestFocus();
    });
  }

  void _goTo(int depth) {
    if (depth >= _openPath.length) return;
    _resetItemFocusNodes();
    setState(() => _openPath.removeRange(depth, _openPath.length));
    _focusFirstTile();
  }

  void _openFolder(MediaItem folder) {
    _resetItemFocusNodes();
    setState(() => _openPath.add(folder));
    _focusFirstTile();
    unawaited(_fetchChildren(folder, opened: true).then((_) => _focusFirstTile()));
  }

  /// Queue [folder]'s contents for its tile (collage and count).
  void _prefetch(MediaItem folder) {
    final key = _folderIdentity(folder);
    if (key == null || _childrenCache.containsKey(key) || _loadingFolders.contains(key)) return;
    if (_prefetchQueue.any((f) => _folderIdentity(f) == key)) return;
    _prefetchQueue.add(folder);
    _pumpPrefetches();
  }

  void _pumpPrefetches() {
    while (_prefetchesRunning < _maxPrefetches && _prefetchQueue.isNotEmpty) {
      final folder = _prefetchQueue.removeAt(0);
      _prefetchesRunning++;
      unawaited(
        _fetchChildren(folder, opened: false).whenComplete(() {
          _prefetchesRunning--;
          if (mounted) _pumpPrefetches();
        }),
      );
    }
  }

  /// Load [folder]'s contents into the cache for the grid. [opened]: the
  /// viewer opened it, so a failure is reported.
  Future<void> _fetchChildren(MediaItem folder, {required bool opened}) async {
    final key = _folderIdentity(folder);
    if (key == null || _childrenCache.containsKey(key) || _loadingFolders.contains(key)) return;
    final epoch = _loadEpoch;
    setState(() => _loadingFolders.add(key));
    try {
      final client = context.getMediaClientForServer(ServerId(widget.serverId!));
      final children = await client.fetchFolderChildren(
        folder,
        withFileDetails: true,
        onPage: (items) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() => _childrenCache[key] = items);
        },
      );
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _childrenCache[key] = children;
        _loadingFolders.remove(key);
      });
    } catch (e, stackTrace) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingFolders.remove(key);
        _childrenCache.remove(key);
      });
      if (opened && mounted) {
        showErrorSnackBar(context, localizedLoadErrorMessage(e, stackTrace, context: t.libraries.folders));
      }
    }
  }

  /// Sub-folders first by name, then videos in [FolderTreeView.gridSort].
  List<MediaItem> _gridOrder(List<MediaItem> items) {
    final folders = [
      for (final i in items)
        if (_isExpandable(i)) i,
    ];
    final videos = [
      for (final i in items)
        if (!_isExpandable(i)) i,
    ];
    int size(MediaItem i) => i.mediaVersions?.firstOrNull?.parts.firstOrNull?.sizeBytes ?? 0;
    switch (widget.gridSort) {
      case FolderGridSort.name:
        break;
      case FolderGridSort.newest:
        videos.sort((a, b) => (b.addedAt ?? 0).compareTo(a.addedAt ?? 0));
      case FolderGridSort.largest:
        videos.sort((a, b) => size(b).compareTo(size(a)));
    }
    return [...folders, ...videos];
  }

  /// Invalidate in-flight loads (epoch bump) and drop their partial results
  /// so superseded pagination can't leave truncated listings behind.
  int _supersedeInFlightLoads() {
    final epoch = ++_loadEpoch;
    for (final id in _loadingFolders) {
      _childrenCache.remove(id);
      _expandedFolders.remove(id);
    }
    _loadingFolders.clear();
    return epoch;
  }

  Future<bool> _loadRootFolders() async {
    final epoch = _supersedeInFlightLoads();
    setState(() {
      _isLoadingRoot = true;
      _errorMessage = null;
    });

    try {
      final client = context.getMediaClientForServer(ServerId(widget.serverId!));
      final folders = await _fetchRootFolders(
        client,
        onPage: (items) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _rootFolders = items;
            _isLoadingRoot = false;
          });
        },
      );

      if (!mounted || epoch != _loadEpoch) return false;

      setState(() {
        _rootFolders = folders;
        _isLoadingRoot = false;
      });

      appLogger.d('Loaded ${folders.length} root folders');
      return true;
    } catch (e, stackTrace) {
      if (!mounted || epoch != _loadEpoch) return false;

      final message = localizedLoadErrorMessage(e, stackTrace, context: t.libraries.folders);
      setState(() {
        _errorMessage = message;
        _isLoadingRoot = false;
      });
      return false;
    }
  }

  Future<void> _loadFolderChildren(MediaItem folder) async {
    final folderIdentity = _folderIdentity(folder);
    if (folderIdentity == null) return;

    // Already loading this folder — re-expand if partial pages are showing
    // (the user collapsed and re-expanded mid-pagination).
    if (_loadingFolders.contains(folderIdentity)) {
      if (_childrenCache.containsKey(folderIdentity)) {
        setState(() {
          _expandedFolders.add(folderIdentity);
        });
      }
      return;
    }

    // Already loaded and cached
    if (_childrenCache.containsKey(folderIdentity)) {
      setState(() {
        _expandedFolders.add(folderIdentity);
      });
      return;
    }

    final epoch = _loadEpoch;
    var pageDelivered = false;
    setState(() {
      _loadingFolders.add(folderIdentity);
    });

    try {
      final client = context.getMediaClientForServer(ServerId(widget.serverId!));
      final children = await _fetchFolderChildren(
        client,
        folder,
        onPage: (items) {
          if (!mounted || epoch != _loadEpoch) return;
          pageDelivered = true;
          setState(() {
            _childrenCache[folderIdentity] = items;
            _expandedFolders.add(folderIdentity);
          });
        },
      );

      if (!mounted || epoch != _loadEpoch) return;

      setState(() {
        _childrenCache[folderIdentity] = children;
        // Pages already expanded the folder; don't override a mid-load collapse.
        if (!pageDelivered) _expandedFolders.add(folderIdentity);
        _loadingFolders.remove(folderIdentity);
      });

      appLogger.d('Loaded ${children.length} children for folder: ${folder.title}');
    } catch (e, stackTrace) {
      if (!mounted || epoch != _loadEpoch) return;

      final message = localizedLoadErrorMessage(e, stackTrace, context: t.libraries.folders);
      setState(() {
        _loadingFolders.remove(folderIdentity);
        // Drop partial pages so a retry refetches instead of leaving a
        // truncated listing that looks complete.
        _childrenCache.remove(folderIdentity);
        _expandedFolders.remove(folderIdentity);
      });

      if (mounted) {
        showErrorSnackBar(context, message);
      }
    }
  }

  void _toggleFolder(MediaItem folder) {
    final folderIdentity = _folderIdentity(folder);
    if (folderIdentity == null) return;
    if (_expandedFolders.contains(folderIdentity)) {
      setState(() {
        _expandedFolders.remove(folderIdentity);
      });
    } else {
      _loadFolderChildren(folder);
    }
  }

  /// Refetch the listing containing a deleted item: the whole tree for root
  /// items, otherwise just the enclosing folder.
  void _refreshAfterDeletion(MediaItem? parent) {
    if (parent == null) {
      _loadRootFolders();
      return;
    }
    _supersedeInFlightLoads();
    final folderIdentity = _folderIdentity(parent);
    if (folderIdentity != null) {
      setState(() {
        _childrenCache.remove(folderIdentity);
      });
    }
    _loadFolderChildren(parent);
  }

  Future<void> _handleItemTap(MediaItem item, MediaItem? parent) async {
    final result = await navigateToMediaItem(context, item, onRefresh: widget.onRefresh);
    if (!mounted) return;
    switch (result) {
      case MediaNavigationResult.unsupported:
        showAppSnackBar(context, t.messages.musicNotSupported);
      case MediaNavigationResult.listRefreshNeeded:
        _refreshAfterDeletion(parent);
      case MediaNavigationResult.navigated:
      case MediaNavigationResult.librarySelected:
        break;
    }
  }

  /// Play (or shuffle) a folder row through the backend's launcher. Built
  /// here rather than via [MediaListPlaybackLauncher.forItem] because this
  /// tree is pinned to one server: the Plex client must be the one backing
  /// [widget.serverId], not `forItem`'s fall-back-to-any-online resolution.
  Future<void> _launchFolder(MediaItem folder, {required bool shuffle}) async {
    final MediaListPlaybackLauncher launcher;
    if (folder.backend.usesMediaBrowserApi) {
      launcher = JellyfinSequentialLauncher(context: context);
    } else {
      final client = context.getPlexClientForServer(ServerId(widget.serverId!));
      launcher = PlexPlayQueueLauncher(context: context, client: client, serverId: widget.serverId);
    }
    await launcher.launchFromFolder(folder: folder, shuffle: shuffle);
  }

  /// Expandable rows: directory rows plus MediaBrowser media containers whose
  /// direct children form the folder tree. Music libraries expose folder-
  /// backed artists and albums as MusicArtist/MusicAlbum rather than generic
  /// Folder DTOs, so those rows must expand instead of opening empty details.
  bool _isExpandable(MediaItem item) {
    return item.kind == MediaKind.folder || (item.backend.usesMediaBrowserApi && _isMediaBrowserMediaContainer(item));
  }

  bool _isMediaBrowserMediaContainer(MediaItem item) {
    if (item.kind == MediaKind.show || item.kind == MediaKind.season) return true;
    return widget.libraryKind?.isMusic == true && (item.kind == MediaKind.artist || item.kind == MediaKind.album);
  }

  bool _canPlayFolder(MediaItem item) {
    if (item.backend == MediaBackend.plex) return true;
    if (item.backend.usesMediaBrowserApi) return widget.libraryKind?.isMusic != true;
    return false;
  }

  Future<List<MediaItem>> _fetchRootFolders(
    MediaServerClient client, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) {
    return client.fetchLibraryFolders(widget.libraryKey, onPage: onPage, withFileDetails: widget.grid);
  }

  Future<List<MediaItem>> _fetchFolderChildren(
    MediaServerClient client,
    MediaItem folder, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) {
    return client.fetchFolderChildren(folder, onPage: onPage);
  }

  /// Flatten the visible tree into a list of (item, depth, path, parent)
  /// tuples so `ListView.builder` can lazy-build only the rows currently on
  /// screen. [parent] is the enclosing folder (null for root items).
  void _flattenTreeItems(
    List<MediaItem> items,
    int depth,
    String parentPath,
    MediaItem? parent,
    List<({MediaItem item, int depth, String path, MediaItem? parent})> out,
  ) {
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final itemPath = parentPath.isEmpty ? '$i' : '$parentPath-$i';
      out.add((item: item, depth: depth, path: itemPath, parent: parent));

      final folderKey = _folderIdentity(item);
      if (_isExpandable(item) &&
          folderKey != null &&
          _expandedFolders.contains(folderKey) &&
          _childrenCache.containsKey(folderKey)) {
        _flattenTreeItems(_childrenCache[folderKey]!, depth + 1, itemPath, item, out);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingRoot) {
      return const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
    }

    if (_errorMessage != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorStateWidget(
          message: _errorMessage!,
          icon: Symbols.error_outline_rounded,
          onRetry: _loadRootFolders,
          retryLabel: t.common.retry,
          actionFocusNode: widget.firstItemFocusNode,
          onActionNavigateUp: widget.onNavigateUp,
          onActionNavigateLeft: widget.onNavigateLeft,
          onActionBack: widget.onBack,
        ),
      );
    }

    if (_rootFolders.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyStateWidget(message: t.libraries.noFoldersFound, icon: Symbols.folder_open_rounded),
      );
    }

    if (widget.grid) return _buildGrid(context);

    final flattened = <({MediaItem item, int depth, String path, MediaItem? parent})>[];
    _flattenTreeItems(_rootFolders, 0, '', null, flattened);
    // Path alone isn't unique enough as identity (the same Plex item can
    // appear under two folders), so combine it with the item id.
    final keys = [for (final entry in flattened) '${entry.path}:${entry.item.id}'];

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverList.builder(
        itemCount: flattened.length,
        itemBuilder: (context, index) {
          final entry = flattened[index];
          final item = entry.item;
          final isExpandable = _isExpandable(item);
          final isPlainFolder = item.kind == MediaKind.folder;
          final folderKey = _folderIdentity(item);
          final isExpanded = folderKey != null && _expandedFolders.contains(folderKey);
          final isLoading = folderKey != null && _loadingFolders.contains(folderKey);
          final isFirstRootItem = index == 0;
          final canPlayFolder = isPlainFolder && _canPlayFolder(item);

          return FolderTreeItem(
            key: ValueKey(keys[index]),
            item: item,
            depth: entry.depth,
            isFolder: isPlainFolder,
            isExpandable: isExpandable,
            isExpanded: isExpanded,
            isLoading: isLoading,
            serverId: widget.serverId,
            onExpand: isExpandable ? () => _toggleFolder(item) : null,
            onTap: !isExpandable ? () => _handleItemTap(item, entry.parent) : null,
            onPlayAll: canPlayFolder ? () => _launchFolder(item, shuffle: false) : null,
            onShuffle: canPlayFolder ? () => _launchFolder(item, shuffle: true) : null,
            focusNode: _itemFocusNode(keys[index], index),
            onNavigateUp: isFirstRootItem ? widget.onNavigateUp : () => _focusItem(keys, index - 1),
            onNavigateDown: index + 1 < keys.length ? () => _focusItem(keys, index + 1) : _stay,
            onNavigateLeft: widget.onNavigateLeft,
            onRefresh: widget.onRefresh,
            onListRefresh: () => _refreshAfterDeletion(entry.parent),
          );
        },
      ),
    );
  }

  // --- Grid ---------------------------------------------------------------

  Widget _buildGrid(BuildContext context) {
    final open = _openPath.lastOrNull;
    final openKey = open == null ? null : _folderIdentity(open);
    final items = open == null ? _rootFolders : _childrenCache[openKey];
    final loading = open != null && items == null && _loadingFolders.contains(openKey);
    final atTop = _openPath.isEmpty;

    final Widget body;
    if (items == null && loading) {
      body = const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
    } else if (items == null || items.isEmpty) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyStateWidget(message: t.libraries.noFoldersFound, icon: Symbols.folder_open_rounded),
      );
    } else {
      body = _buildGridItems(context, _gridOrder(items), parent: open);
    }

    return PopScope(
      // A phone's Back gesture goes up a folder first.
      canPop: atTop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) goUp();
      },
      child: SliverMainAxisGroup(
        slivers: [
          if (!atTop) SliverToBoxAdapter(child: _buildPathBar(context)),
          body,
        ],
      ),
    );
  }

  String _folderName(MediaItem folder) {
    final title = folder.title?.trim();
    return title != null && title.isNotEmpty ? title : folder.displayTitle;
  }

  Widget _buildPathBar(BuildContext context) {
    final theme = Theme.of(context);
    final open = _openPath.last;
    final canPlay = open.kind == MediaKind.folder && _canPlayFolder(open);
    final crumbs = <Widget>[
      TextButton(
        onPressed: () => _goTo(0),
        child: Text(widget.libraryTitle ?? t.libraries.groupings.folders, maxLines: 1, overflow: .ellipsis),
      ),
      for (var i = 0; i < _openPath.length; i++) ...[
        AppIcon(Symbols.chevron_right_rounded, fill: 1, size: 18, color: theme.colorScheme.onSurfaceVariant),
        if (i == _openPath.length - 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              _folderName(_openPath[i]),
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: .w700),
              maxLines: 1,
              overflow: .ellipsis,
            ),
          )
        else
          TextButton(
            onPressed: () => _goTo(i + 1),
            child: Text(_folderName(_openPath[i]), maxLines: 1, overflow: .ellipsis),
          ),
      ],
    ];
    // Down from anywhere on the bar goes to the first tile, Up to the chips,
    // instead of Flutter's directional guess.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          widget.firstItemFocusNode?.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp && widget.onNavigateUp != null) {
          widget.onNavigateUp!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildPathBarRow(open, canPlay, crumbs),
    );
  }

  Widget _buildPathBarRow(MediaItem open, bool canPlay, List<Widget> crumbs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            focusNode: _pathBarUpFocusNode,
            tooltip: t.libraries.folderGrid.up,
            onPressed: goUp,
            icon: const AppIcon(Symbols.arrow_upward_rounded, fill: 1),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(children: crumbs),
            ),
          ),
          if (canPlay) ...[
            IconButton(
              tooltip: t.common.play,
              onPressed: () => unawaited(_launchFolder(open, shuffle: false)),
              icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
            ),
            IconButton(
              tooltip: t.common.shuffle,
              onPressed: () => unawaited(_launchFolder(open, shuffle: true)),
              icon: const AppIcon(Symbols.shuffle_rounded, fill: 1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGridItems(BuildContext context, List<MediaItem> items, {required MediaItem? parent}) {
    final density = SettingsService.instance.read(SettingsService.libraryDensity);
    final spacing = MediaGridDelegate.spacingFor(context: context, useWideAspectRatio: true);
    final textHeight = FolderGridTile.textHeight(MediaQuery.textScalerOf(context));
    // Wide cells, sized from the Library density setting like the
    // library's flat grid.
    final maxExtent = GridSizeCalculator.getMaxCrossAxisExtent(context, density) * 1.8;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = GridSizeCalculator.getColumnCount(width, maxExtent, crossAxisSpacing: spacing);
          final cellWidth = GridSizeCalculator.getCellWidthForColumnCount(width, columns, crossAxisSpacing: spacing);
          final keys = [for (final item in items) '${parent?.id ?? 'root'}:${item.id}'];
          final lastRow = (items.length - 1) ~/ columns;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing + 4,
              mainAxisExtent: cellWidth * 9 / 16 + textHeight,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isFolder = _isExpandable(item);
              final key = isFolder ? _folderIdentity(item) : null;
              final children = key == null ? null : _childrenCache[key];
              // A folder tile needs its contents for the collage and the
              // count; only built tiles ask, a few at a time.
              if (isFolder && children == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _prefetch(item);
                });
              }
              final canPlay = isFolder && item.kind == MediaKind.folder && _canPlayFolder(item);
              final column = index % columns;
              return FolderGridTile(
                key: ValueKey(keys[index]),
                item: item,
                isFolder: isFolder,
                serverId: widget.serverId,
                children: children,
                onTap: isFolder ? () => _openFolder(item) : () => unawaited(_handleItemTap(item, parent)),
                onPlayAll: canPlay ? () => unawaited(_launchFolder(item, shuffle: false)) : null,
                onShuffle: canPlay ? () => unawaited(_launchFolder(item, shuffle: true)) : null,
                focusNode: _itemFocusNode(keys[index], index),
                // Up: the tile one row up; from the first row, the chips at
                // the library's top, or the path bar inside a folder.
                onNavigateUp: index >= columns
                    ? () => _focusItem(keys, index - columns)
                    : _openPath.isEmpty
                    ? widget.onNavigateUp
                    : _pathBarUpFocusNode.requestFocus,
                // Down: the tile one row down, or the last tile when the
                // next row is shorter.
                onNavigateDown: index ~/ columns < lastRow
                    ? () => _focusItem(keys, math.min(index + columns, items.length - 1))
                    : _stay,
                onNavigateLeft: column == 0 ? widget.onNavigateLeft : () => _focusItem(keys, index - 1),
                onNavigateRight: column < columns - 1 && index + 1 < items.length
                    ? () => _focusItem(keys, index + 1)
                    : _stay,
                onBack: _openPath.isEmpty ? null : () => goUp(),
                onRefresh: widget.onRefresh,
                onListRefresh: () => _refreshAfterDeletion(parent),
              );
            },
          );
        },
      ),
    );
  }
}
