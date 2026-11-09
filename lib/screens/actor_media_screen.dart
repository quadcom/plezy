import 'package:flutter/material.dart';
import '../media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../media/library_query.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/search_scope.dart';
import '../mixins/paginated_item_loader.dart';
import '../mixins/standard_paginated_view.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import '../utils/provider_extensions.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/optimized_media_image.dart';
import '../utils/media_image_helper.dart';
import '../i18n/strings.g.dart';
import 'base_media_list_detail_screen.dart';
import 'focusable_detail_screen_mixin.dart';
import 'media_detail/big_screen_layout.dart';
import '../utils/platform_detector.dart';
import '../mixins/grid_focus_node_mixin.dart';
import '../focus/focusable_action_bar.dart';

/// Screen to browse all media featuring a specific actor, or (through
/// [ActorMediaScreen.filtered]) the films and shows of one genre, studio,
/// keyword or year, as the Search screen's extra rows open them.
class ActorMediaScreen extends StatefulWidget {
  final String actorName;
  final String personId;
  final String? actorThumb;
  final String? characterName;
  final String serverId;
  final String? serverName;
  final MediaBackend backend;

  /// A non-person filter; null for a person, who keeps the actor page.
  final MediaFacet? facet;

  /// Stands in for the photo when [facet] is set.
  final IconData? facetIcon;

  const ActorMediaScreen({
    super.key,
    required this.actorName,
    required this.personId,
    this.actorThumb,
    this.characterName,
    required this.serverId,
    this.serverName,
    required this.backend,
  }) : facet = null,
       facetIcon = null;

  /// The films and shows matching [facet] (a genre, studio, tag or year),
  /// headed by [title] and [icon].
  const ActorMediaScreen.filtered({
    super.key,
    required String title,
    required MediaFacet this.facet,
    required IconData icon,
    required this.serverId,
    this.serverName,
    required this.backend,
  }) : actorName = title,
       personId = '',
       actorThumb = null,
       characterName = null,
       facetIcon = icon;

  @override
  State<ActorMediaScreen> createState() => _ActorMediaScreenState();
}

class _ActorMediaScreenState extends BaseMediaListDetailScreen<ActorMediaScreen>
    with
        GridFocusNodeMixin<ActorMediaScreen>,
        FocusableDetailScreenMixin<ActorMediaScreen>,
        PaginatedItemLoader<MediaItem, ActorMediaScreen>,
        PaginatedItemUpdatable<ActorMediaScreen>,
        StandardPaginatedView<MediaItem, ActorMediaScreen> {
  static const int _pageSize = 200;

  @override
  MediaItem get mediaItem => MediaItem(
    id: '',
    backend: widget.backend,
    kind: MediaKind.unknown,
    serverId: widget.serverId,
    serverName: widget.serverName,
  );

  @override
  String get title => widget.actorName;

  @override
  String get emptyMessage => t.discover.noContentAvailable;

  @override
  bool get hasItems => totalSize > 0;

  @override
  void dispose() {
    disposePagination();
    disposeFocusResources();
    super.dispose();
  }

  MediaServerClient get _mediaClient => context.getMediaClientForServer(ServerId(widget.serverId));

  @override
  Future<LibraryPage<MediaItem>> fetchPage(int start, int size, AbortController? abort) {
    final facet = widget.facet;
    if (facet != null) return _mediaClient.fetchFacetMediaPage(facet, start: start, size: size, abort: abort);
    return _mediaClient.fetchPersonMediaPage(widget.personId, start: start, size: size, abort: abort);
  }

  @override
  Future<void> loadItems() {
    return loadStandardPaginatedItems(
      pageSize: _pageSize,
      errorMessageFor: (error, stackTrace) {
        appLogger.e('Failed to load actor media', error: error, stackTrace: stackTrace);
        return t.messages.errorLoading(error: error.toString());
      },
      onLoaded: (loadedCount, totalCount) {
        appLogger.d('Loaded $loadedCount of $totalCount items for ${widget.facet ?? 'actor'}: ${widget.actorName}');
        autoFocusFirstItemAfterLoad();
      },
    );
  }

  @override
  List<FocusableAction> getAppBarActions() {
    return [];
  }

  /// Tablets and up: the header and grid grow with the window, like the item
  /// page (local/plans/movie-page-big-screens.md, stage 4); null elsewhere.
  DetailBigScreenLayout? _bigLayout(BuildContext context) => DetailBigScreenLayout.resolve(
    size: MediaQuery.sizeOf(context),
    isPhone: PlatformDetector.isPhone(context),
    isTv: PlatformDetector.isTV(),
  );

  Widget _buildActorHeader() {
    final theme = Theme.of(context);
    final big = _bigLayout(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: DetailZoom(
          scale: big?.personHeaderZoom ?? 1,
          alignment: Alignment.topLeft,
          child: Row(
          children: [
            if (widget.facetIcon case final icon?)
              CircleAvatar(
                radius: 40,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: OptimizedMediaImage(
                  client: _mediaClient,
                  imagePath: widget.actorThumb,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  imageType: ImageType.avatar,
                  fallbackIcon: Symbols.person_rounded,
                ),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Text(
                    widget.actorName,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: .bold),
                    maxLines: 2,
                    overflow: .ellipsis,
                  ),
                  if (widget.characterName != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.characterName!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: .ellipsis,
                    ),
                  ],
                  if (totalSize > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      t.discover.titleCount(n: totalSize),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final big = _bigLayout(context);
    return buildDetailScaffold(
      slivers: [
        CustomAppBar(title: Text(widget.actorName), pinned: true, actions: buildFocusableAppBarActions()),
        _buildActorHeader(),
        ...buildStateSlivers(),
        if (hasItems)
          buildSparseFocusableGrid(
            totalItems: totalSize,
            itemAt: (index) => loadedItems[index],
            onRefresh: updateItem,
            onSkeletonVisible: (index) => ensureIndexLoaded(index, pageSize: _pageSize),
            densityOverride: big?.personGridDensity(isTv: PlatformDetector.isTV()),
          ),
      ],
    );
  }
}
