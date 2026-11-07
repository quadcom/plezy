import 'package:flutter/material.dart';

import '../../../mpv/mpv.dart';
import '../../../media/media_source_info.dart';
import '../../../services/scrub_preview_source.dart';
import '../../../utils/formatters.dart';
import 'timeline_slider.dart';

/// The open file as one part of a longer timeline: an Old School film's own
/// trailer and the film share one guide block, so the bar runs over both
/// (local/plans/old-school-preroll-mouse.md). The file's position is drawn at
/// [offset] into [total]; a gap marks [split], where the trailer ends.
@immutable
class TimelineBlock {
  final Duration offset;
  final Duration total;
  final Duration? split;

  const TimelineBlock({required this.offset, required this.total, this.split});

  /// The block's position for the file's own [position].
  Duration position(Duration position) => VideoTimelineBar.clampDuration(offset + position, total);

  /// The two parts as chapters, so the slider draws its gap at [split].
  List<MediaChapter> get chapters {
    final at = split;
    if (at == null || at <= Duration.zero || at >= total) return const [];
    return [
      MediaChapter(id: 0, index: 0, startTimeOffset: 0, endTimeOffset: at.inMilliseconds),
      MediaChapter(id: 1, index: 1, startTimeOffset: at.inMilliseconds, endTimeOffset: total.inMilliseconds),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is TimelineBlock && other.offset == offset && other.total == total && other.split == split;

  @override
  int get hashCode => Object.hash(offset, total, split);
}

/// Encapsulates the StreamBuilder stack for video timeline with timestamps.
///
/// This widget listens to player position and duration streams, and displays
/// a timeline slider with formatted timestamps. Supports both horizontal
/// layout (timestamps beside slider) and vertical layout (timestamps below slider).
class VideoTimelineBar extends StatelessWidget {
  final Player player;
  final List<MediaChapter> chapters;
  final bool chaptersLoaded;
  final bool showChapterMarkersOnTimeline;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSeekEnd;
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// If true, timestamps are shown in a row beside the slider (desktop layout).
  /// If false, timestamps are shown in a row below the slider (mobile layout).
  final bool horizontalLayout;

  /// Optional FocusNode for D-pad/keyboard navigation.
  final FocusNode? focusNode;

  /// Custom key event handler for focus navigation.
  final KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent;

  /// Called when focus changes.
  final ValueChanged<bool>? onFocusChange;

  final bool enabled;

  /// Whether to show the estimated finish time next to the remaining timestamp (mobile).
  final bool showFinishTime;

  /// Optional callback that returns thumbnail image bytes for a given timestamp.
  final ScrubFrame? Function(Duration time)? thumbnailDataBuilder;

  /// When true, show the preview thumbnail at the current playback position
  /// (used during sustained dpad/keyboard key-repeat seeking).
  final bool showKeyRepeatThumbnail;

  /// Optional UI-only position used while a remote/keyboard seek is pending.
  final Duration? previewPosition;

  /// Read on every position update: when it gives a block, the bar shows
  /// the whole block instead of the open file alone. Display only; seeking
  /// is off wherever a block is used (Old School).
  final TimelineBlock? Function()? block;

  const VideoTimelineBar({
    super.key,
    required this.player,
    required this.chapters,
    required this.chaptersLoaded,
    this.showChapterMarkersOnTimeline = true,
    required this.onSeek,
    required this.onSeekEnd,
    this.onScrubStart,
    this.onScrubEnd,
    this.horizontalLayout = true,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChange,
    this.enabled = true,
    this.showFinishTime = false,
    this.thumbnailDataBuilder,
    this.showKeyRepeatThumbnail = false,
    this.previewPosition,
    this.block,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.streams.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: player.streams.duration,
          initialData: player.state.duration,
          builder: (context, durationSnapshot) {
            return StreamBuilder<List<BufferRange>>(
              stream: player.streams.bufferRanges,
              initialData: player.state.bufferRanges,
              builder: (context, bufferRangesSnapshot) {
                final rawPosition = positionSnapshot.data ?? Duration.zero;
                final fileDuration = durationSnapshot.data ?? Duration.zero;
                final filePosition = previewPosition == null
                    ? rawPosition
                    : clampDuration(previewPosition!, fileDuration);
                final fileBuffered = bufferRangesSnapshot.data ?? const <BufferRange>[];
                final block = this.block?.call();
                final duration = block?.total ?? fileDuration;
                final position = block?.position(filePosition) ?? filePosition;
                final bufferRanges = block == null
                    ? fileBuffered
                    : [
                        for (final r in fileBuffered)
                          BufferRange(start: block.offset + r.start, end: block.offset + r.end),
                      ];
                final remaining = position - duration; // We want this to be negative
                final blockChapters = block?.chapters;

                return RepaintBoundary(
                  child: horizontalLayout
                      ? _buildHorizontalLayout(position, duration, remaining, bufferRanges, blockChapters)
                      : _buildVerticalLayout(position, duration, remaining, bufferRanges, blockChapters),
                );
              },
            );
          },
        );
      },
    );
  }

  static Duration clampDuration(Duration position, Duration duration) {
    if (position.isNegative) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  Widget _buildHorizontalLayout(
    Duration position,
    Duration duration,
    Duration remaining,
    List<BufferRange> bufferRanges,
    List<MediaChapter>? blockChapters,
  ) {
    return Row(
      children: [
        _buildTimestamp(position),
        const SizedBox(width: 12),
        Expanded(child: _buildSlider(position, duration, bufferRanges, blockChapters)),
        const SizedBox(width: 12),
        _buildTimestamp(remaining),
      ],
    );
  }

  Widget _buildVerticalLayout(
    Duration position,
    Duration duration,
    Duration remaining,
    List<BufferRange> bufferRanges,
    List<MediaChapter>? blockChapters,
  ) {
    return Column(
      children: [
        _buildSlider(position, duration, bufferRanges, blockChapters),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: .spaceBetween,
            children: [_buildTimestamp(position), _buildRemainingTimestamp(remaining)],
          ),
        ),
      ],
    );
  }

  static const _timestampStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget _buildTimestamp(Duration time) {
    return Text(formatDurationTimestamp(time), style: _timestampStyle);
  }

  Widget _buildRemainingTimestamp(Duration remaining) {
    if (!showFinishTime || remaining.inSeconds >= 0) {
      return _buildTimestamp(remaining);
    }
    return StreamBuilder<double>(
      stream: player.streams.rate,
      initialData: player.state.rate,
      builder: (context, rateSnap) {
        final rate = rateSnap.data ?? 1.0;
        final text =
            '${formatDurationTimestamp(remaining)} · ${formatFinishTime(remaining.abs(), rate: rate, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';
        return Text(text, style: _timestampStyle);
      },
    );
  }

  Widget _buildSlider(
    Duration position,
    Duration duration,
    List<BufferRange> bufferRanges,
    List<MediaChapter>? blockChapters,
  ) {
    return TimelineSlider(
      position: position,
      duration: duration,
      bufferRanges: bufferRanges,
      // A block marks only where its parts meet; the file's own chapters
      // would sit at the wrong places on the longer bar.
      chapters: blockChapters ?? chapters,
      chaptersLoaded: blockChapters != null || chaptersLoaded,
      showChapterMarkersOnTimeline: blockChapters != null || showChapterMarkersOnTimeline,
      onSeek: onSeek,
      onSeekEnd: onSeekEnd,
      onScrubStart: onScrubStart,
      onScrubEnd: onScrubEnd,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      onFocusChange: onFocusChange,
      enabled: enabled,
      thumbnailDataBuilder: thumbnailDataBuilder,
      showKeyRepeatThumbnail: showKeyRepeatThumbnail,
    );
  }
}
