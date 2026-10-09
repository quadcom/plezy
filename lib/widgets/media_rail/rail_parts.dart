import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../mixins/context_menu_tap_mixin.dart';
import '../../providers/watch_state_store.dart';
import '../../utils/formatters.dart';
import '../app_icon.dart';
import '../media_context_menu.dart';
import '../optimized_media_image.dart';

/// Shared parts of the fork's rail screens (the Master Class course screen and
/// the season page): a darkening scrim for the cycling backdrop, a card for
/// one lesson or episode, and the panel with the selected one's description.
/// Layout settled with Adrian on 2026-10-08 (local/plans/masterclass-course-screen.md).

/// Darkens the backdrop so the text over it stays readable: heavy on the
/// left and along the bottom, where the header, rail and notes sit.
class RailScrim extends StatelessWidget {
  const RailScrim({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [color.withValues(alpha: 0.94), color.withValues(alpha: 0.74), color.withValues(alpha: 0.5)],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [color.withValues(alpha: 0.97), color.withValues(alpha: 0.6), color.withValues(alpha: 0)],
            stops: const [0, 0.45, 0.75],
          ),
        ),
      ),
    );
  }
}

/// One lesson or episode in a rail: its still with a number badge, a watched
/// check or progress bar, and the title and length below.
///
/// Remote and keyboard focus come through [FocusableWrapper] (OK calls
/// [onSelect], a long OK opens the item's menu); taps and clicks through the
/// inner gesture detector (long press or right click opens the menu).
class RailItemCard extends StatefulWidget {
  const RailItemCard({
    super.key,
    required this.item,
    required this.badge,
    required this.client,
    required this.width,
    required this.selected,
    required this.focusNode,
    required this.onFocused,
    required this.onSelect,
    required this.onNavigateUp,
    required this.semanticLabel,
    this.blurStill = false,
    this.onRefresh,
    this.onListRefresh,
  });

  final MediaItem item;
  final String badge;
  final MediaServerClient? client;
  final double width;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onFocused;
  final VoidCallback onSelect;
  final VoidCallback onNavigateUp;
  final String semanticLabel;

  /// Blurs the still (spoiler hiding for unwatched episodes).
  final bool blurStill;
  final void Function(MediaItem source)? onRefresh;
  final VoidCallback? onListRefresh;

  @override
  State<RailItemCard> createState() => _RailItemCardState();
}

class _RailItemCardState extends State<RailItemCard> with ContextMenuTapMixin<RailItemCard> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = context.withFreshWatchState(widget.item);
    final duration = item.durationMs;
    final offset = item.viewOffsetMs ?? 0;
    final partial = !item.isWatched && duration != null && duration > 0 && offset > 0 ? offset / duration : null;
    final still = OptimizedMediaImage.thumb(client: widget.client, imagePath: item.thumbPath);
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FocusableWrapper(
            focusNode: widget.focusNode,
            borderRadius: 10,
            onSelect: widget.onSelect,
            enableLongPress: true,
            onLongPress: showContextMenu,
            onNavigateUp: widget.onNavigateUp,
            onFocusChange: (focused) {
              if (focused) widget.onFocused();
            },
            semanticLabel: widget.semanticLabel,
            child: MediaContextMenu(
              key: contextMenuKey,
              item: item,
              onRefresh: widget.onRefresh,
              onListRefresh: widget.onListRefresh,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSelect,
                onTapDown: storeTapPosition,
                onLongPress: showContextMenuFromTap,
                onSecondaryTapDown: storeTapPosition,
                onSecondaryTap: showContextMenuFromTap,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.blurStill)
                          ClipRect(
                            child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: still),
                          )
                        else
                          still,
                        if (widget.selected)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.colorScheme.onSurface, width: 2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.badge,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        if (item.isWatched)
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
            item.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (duration != null)
            Text(
              formatDurationTextual(duration),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
            ),
        ],
      ),
    );
  }
}

/// The selected lesson's or episode's description, below the rail.
class RailNotesPanel extends StatelessWidget {
  const RailNotesPanel({super.key, required this.heading, this.body});

  /// "Lesson 3: Title  ·  12 min" and the like.
  final String heading;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = body;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(heading, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (text != null && text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
                  height: 1.45,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
