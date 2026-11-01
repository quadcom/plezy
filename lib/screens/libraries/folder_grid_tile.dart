import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../mixins/context_menu_tap_mixin.dart';
import '../../providers/watch_state_store.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/focus_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/watched_indicator.dart';

/// The text block under a folder grid tile's picture: a name of up to two
/// lines, then one detail line. [FolderGridTile.textHeight] sizes the cell.
const double _nameSize = 13;
const double _detailSize = 11;
const double _lineHeight = 1.25;
const double _textTop = 6;
const double _textGap = 2;
const double _textBottom = 6;

/// One cell of the home-video folder grid (local/plans/home-video-grid.md):
/// a video as its 16:9 frame with name, length and file details (size,
/// resolution, codec, as many as fit), or a folder as a collage of up to four
/// of its videos' frames (or the server's own folder picture) with the folder
/// name and how many videos it holds.
class FolderGridTile extends StatefulWidget {
  final MediaItem item;
  final bool isFolder;
  final String? serverId;

  /// For a folder: what it holds, once known (the collage and the count).
  final List<MediaItem>? children;
  final VoidCallback onTap;
  final VoidCallback? onPlayAll;
  final VoidCallback? onShuffle;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;
  final void Function(MediaItem source)? onRefresh;
  final VoidCallback? onListRefresh;

  const FolderGridTile({
    super.key,
    required this.item,
    required this.isFolder,
    required this.onTap,
    this.serverId,
    this.children,
    this.onPlayAll,
    this.onShuffle,
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.onNavigateLeft,
    this.onBack,
    this.onRefresh,
    this.onListRefresh,
  });

  /// Height of the text under the picture at [scaler].
  static double textHeight(TextScaler scaler) =>
      _textTop +
      scaler.scale(_nameSize) * _lineHeight * 2 +
      _textGap +
      scaler.scale(_detailSize) * _lineHeight +
      _textBottom;

  @override
  State<FolderGridTile> createState() => _FolderGridTileState();
}

class _FolderGridTileState extends State<FolderGridTile> with ContextMenuTapMixin {
  bool get _hasFolderMenu => widget.isFolder && (widget.onPlayAll != null || widget.onShuffle != null);

  String get _name {
    final title = widget.item.title?.trim();
    return title != null && title.isNotEmpty ? title : widget.item.displayTitle;
  }

  /// "12 min · 1080p · HEVC · 1.2 GB", trimmed to what [width] holds: codec
  /// goes first, then resolution, so length and size always show.
  String _videoDetails(double width) {
    final item = widget.item;
    final version = item.mediaVersions?.firstOrNull;
    final ms = item.durationMs;
    final length = ms != null && ms > 0 ? formatDurationTextual(ms) : null;
    final resolution = _resolutionLabel(version?.videoResolution);
    final codec = version?.videoCodec?.toUpperCase();
    final bytes = version?.parts.firstOrNull?.sizeBytes;
    final size = bytes != null && bytes > 0 ? ByteFormatter.formatBytes(bytes, decimals: 1) : null;
    return [?length, if (width >= 150) ?resolution, if (width >= 210) ?codec, ?size].join(' · ');
  }

  static String? _resolutionLabel(String? value) {
    if (value == null || value.isEmpty) return null;
    if (int.tryParse(value) != null) return '${value}p';
    return value.toUpperCase();
  }

  String _folderDetails() {
    final children = widget.children;
    if (children == null) return '';
    final videos = children.where((c) => c.kind != MediaKind.folder).length;
    final folders = children.length - videos;
    return [
      if (videos > 0) videos == 1 ? t.libraries.folderGrid.oneVideo : t.libraries.folderGrid.videos(count: videos),
      if (folders > 0) folders == 1 ? t.libraries.folderGrid.oneFolder : t.libraries.folderGrid.folders(count: folders),
    ].join(' · ');
  }

  void _showMenu() {
    if (widget.isFolder) {
      _showFolderMenu();
    } else {
      showContextMenuFromTap();
    }
  }

  Future<void> _showFolderMenu() async {
    final entries = <AppMenuEntry<String>>[
      if (widget.onPlayAll != null)
        AppMenuItem<String>(value: 'play', icon: Symbols.play_arrow_rounded, label: t.common.play),
      if (widget.onShuffle != null)
        AppMenuItem<String>(value: 'shuffle', icon: Symbols.shuffle_rounded, label: t.common.shuffle),
    ];
    if (entries.isEmpty) return;
    final previousFocus = FocusManager.instance.primaryFocus;
    final position = lastTapPosition;
    final box = context.findRenderObject() as RenderBox?;
    final center = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
    final selected = await showAdaptiveAppMenu<String>(
      context,
      title: _name,
      entries: entries,
      position: position ?? center,
      focusFirstItem: position == null,
    );
    if (!mounted) return;
    if (selected == null) {
      if (previousFocus != null) FocusUtils.restoreFocusAfterBuild(this, previousFocus);
      return;
    }
    switch (selected) {
      case 'play':
        widget.onPlayAll?.call();
      case 'shuffle':
        widget.onShuffle?.call();
    }
  }

  Widget _image(BuildContext context, String? path, double width, double height) {
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(widget.serverId));
    return OptimizedMediaImage.thumb(client: client, imagePath: path, width: width, height: height, fit: BoxFit.cover);
  }

  Widget _placeholder(BuildContext context, IconData icon) {
    final tk = tokens(context);
    return ColoredBox(
      color: tk.surface,
      child: Center(child: AppIcon(icon, fill: 1, size: 36, color: tk.textMuted)),
    );
  }

  Widget _picture(BuildContext context, double width, double height) {
    final item = widget.item;
    if (!widget.isFolder) {
      final path = item.posterThumb(mode: SettingsService.instance.read(SettingsService.episodePosterMode));
      return Stack(
        fit: StackFit.expand,
        children: [
          if (path == null) _placeholder(context, Symbols.movie_rounded) else _image(context, path, width, height),
          WatchedIndicator(item: context.withFreshWatchState(item), size: WatchedIndicatorSize.compact),
        ],
      );
    }
    // The server's own folder picture (Jellyfin makes a collage) wins; else
    // up to four frames from inside.
    if (item.thumbPath != null) return _image(context, item.thumbPath, width, height);
    final frames = [
      for (final child in widget.children ?? const <MediaItem>[])
        if (child.kind != MediaKind.folder && child.thumbPath != null) child.thumbPath!,
    ].take(4).toList();
    if (frames.isEmpty) return _placeholder(context, Symbols.folder_rounded);
    if (frames.length == 1) return _image(context, frames.first, width, height);
    final cellWidth = width / 2;
    final cellHeight = height / 2;
    final cells = [
      for (var i = 0; i < 4; i++)
        i < frames.length
            ? _image(context, frames[i], cellWidth, cellHeight)
            : ColoredBox(color: tokens(context).surface),
    ];
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: cells[0]),
              Expanded(child: cells[1]),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: cells[2]),
              Expanded(child: cells[3]),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final hasMenu = !widget.isFolder || _hasFolderMenu;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final pictureHeight = width * 9 / 16;
        final details = widget.isFolder ? _folderDetails() : _videoDetails(width);
        final content = Column(
          crossAxisAlignment: .stretch,
          children: [
            SizedBox(
              height: pictureHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(tk.radiusSm),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _picture(context, width, pictureHeight),
                    if (widget.isFolder)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: AppIcon(Symbols.folder_rounded, fill: 1, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: _textTop),
            MiddleEllipsisText(
              _name,
              maxLines: 2,
              style: const TextStyle(fontSize: _nameSize, fontWeight: .w600, height: _lineHeight),
            ),
            const SizedBox(height: _textGap),
            Text(
              details,
              maxLines: 1,
              overflow: .ellipsis,
              style: TextStyle(fontSize: _detailSize, height: _lineHeight, color: tk.textMuted),
            ),
          ],
        );

        Widget gesture = GestureDetector(
          onTap: widget.onTap,
          onTapDown: hasMenu ? storeTapPosition : null,
          onLongPress: hasMenu ? _showMenu : null,
          onSecondaryTapDown: hasMenu ? storeTapPosition : null,
          onSecondaryTap: hasMenu ? _showMenu : null,
          behavior: HitTestBehavior.opaque,
          child: content,
        );
        if (!widget.isFolder) {
          gesture = MediaContextMenu(
            key: contextMenuKey,
            item: widget.item,
            onRefresh: widget.onRefresh,
            onListRefresh: widget.onListRefresh,
            child: gesture,
          );
        }
        return FocusableWrapper(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onSelect: widget.onTap,
          enableLongPress: hasMenu,
          onLongPress: hasMenu ? _showMenu : null,
          onNavigateUp: widget.onNavigateUp,
          onNavigateLeft: widget.onNavigateLeft,
          onBack: widget.onBack,
          semanticLabel: _name,
          descendantsAreFocusable: false,
          child: gesture,
        );
      },
    );
  }
}

/// [text] in up to [maxLines] lines; when it still doesn't fit, the middle
/// is cut ("Noise test hqdn3d…strength4_crf20") so both the start and the
/// end show. Test encodes usually differ only at the end of the name.
class MiddleEllipsisText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int maxLines;

  const MiddleEllipsisText(this.text, {super.key, required this.style, this.maxLines = 2});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = middleEllipsis(
          text,
          style: effective,
          maxWidth: constraints.maxWidth,
          maxLines: maxLines,
          textScaler: scaler,
          textDirection: direction,
        );
        return Text(fitted, style: style, maxLines: maxLines, overflow: .ellipsis);
      },
    );
  }
}

/// [text] cut in the middle with "…" until it fits [maxLines] lines of
/// [maxWidth]; [text] itself when it already fits.
String middleEllipsis(
  String text, {
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) return text;
  bool fits(String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      maxLines: maxLines,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return !exceeded;
  }

  if (fits(text)) return text;
  final chars = text.characters.toList();
  // Keep the end a little longer than the start: that's where names differ.
  var low = 0;
  var high = chars.length - 1;
  var best = '…';
  while (low <= high) {
    final keep = (low + high) ~/ 2;
    final head = (keep * 0.45).floor();
    final tail = keep - head;
    final candidate = '${chars.take(head).join()}…${chars.skip(chars.length - tail).join()}';
    if (fits(candidate)) {
      best = candidate;
      low = keep + 1;
    } else {
      high = keep - 1;
    }
  }
  return best;
}
