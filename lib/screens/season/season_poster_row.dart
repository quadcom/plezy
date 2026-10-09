import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../mixins/context_menu_tap_mixin.dart';
import '../../providers/watch_state_store.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/optimized_media_image.dart';
import 'season_detail_screen.dart';

/// The show screen's seasons as a row of posters, in place of the season tabs
/// and episode list when season pages are on. Opening one goes to its
/// [SeasonDetailScreen]. Fork-only (local/plans/season-rail-layout.md).
class SeasonPosterRow extends StatelessWidget {
  const SeasonPosterRow({
    super.key,
    required this.seasons,
    required this.client,
    required this.focusNodes,
    required this.onOpen,
    this.onNavigateDown,
    this.onRefresh,
    this.onListRefresh,
  });

  final List<MediaItem> seasons;
  final MediaServerClient? client;

  /// One per season, owned by the show screen so its focus routing can reach
  /// them (the same nodes its season tabs use).
  final List<FocusNode> focusNodes;
  final ValueChanged<int> onOpen;
  final VoidCallback? onNavigateDown;
  final void Function(MediaItem source)? onRefresh;
  final VoidCallback? onListRefresh;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width >= 700 ? 150.0 : 110.0;
    return SizedBox(
      height: width * 3 / 2 + 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: seasons.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) => _SeasonTile(
          season: seasons[i],
          client: client,
          width: width,
          focusNode: i < focusNodes.length ? focusNodes[i] : null,
          onOpen: () => onOpen(i),
          onNavigateLeft: i > 0 && i - 1 < focusNodes.length ? () => focusNodes[i - 1].requestFocus() : null,
          onNavigateRight: i + 1 < seasons.length && i + 1 < focusNodes.length
              ? () => focusNodes[i + 1].requestFocus()
              : null,
          onNavigateDown: onNavigateDown,
          onRefresh: onRefresh,
          onListRefresh: onListRefresh,
        ),
      ),
    );
  }
}

class _SeasonTile extends StatefulWidget {
  const _SeasonTile({
    required this.season,
    required this.client,
    required this.width,
    required this.focusNode,
    required this.onOpen,
    required this.onNavigateLeft,
    required this.onNavigateRight,
    required this.onNavigateDown,
    required this.onRefresh,
    required this.onListRefresh,
  });

  final MediaItem season;
  final MediaServerClient? client;
  final double width;
  final FocusNode? focusNode;
  final VoidCallback onOpen;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;
  final VoidCallback? onNavigateDown;
  final void Function(MediaItem source)? onRefresh;
  final VoidCallback? onListRefresh;

  @override
  State<_SeasonTile> createState() => _SeasonTileState();
}

class _SeasonTileState extends State<_SeasonTile> with ContextMenuTapMixin<_SeasonTile> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final season = context.withFreshWatchState(widget.season);
    final total = season.leafCount;
    final seen = season.viewedLeafCount ?? 0;
    final partial = !season.isWatched && total != null && total > 0 && seen > 0 ? seen / total : null;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FocusableWrapper(
            focusNode: widget.focusNode,
            borderRadius: 10,
            onSelect: widget.onOpen,
            enableLongPress: true,
            onLongPress: showContextMenu,
            onNavigateLeft: widget.onNavigateLeft ?? () {},
            onNavigateRight: widget.onNavigateRight ?? () {},
            onNavigateDown: widget.onNavigateDown,
            semanticLabel: seasonLabel(season),
            child: MediaContextMenu(
              key: contextMenuKey,
              item: season,
              onRefresh: widget.onRefresh,
              onListRefresh: widget.onListRefresh,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onOpen,
                onTapDown: storeTapPosition,
                onLongPress: showContextMenuFromTap,
                onSecondaryTapDown: storeTapPosition,
                onSecondaryTap: showContextMenuFromTap,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        OptimizedMediaImage.poster(client: widget.client, imagePath: season.thumbPath),
                        if (season.isWatched)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: theme.colorScheme.primary,
                              child: AppIcon(Symbols.check_rounded, size: 16, color: theme.colorScheme.onPrimary),
                            ),
                          ),
                        if (partial != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: partial.clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: Colors.black.withValues(alpha: 0.5),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            seasonLabel(season),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (total != null)
            Text(
              t.seasonPage.episodeCount(n: total),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
            ),
        ],
      ),
    );
  }
}
