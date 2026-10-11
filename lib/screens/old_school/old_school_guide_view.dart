import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../services/image_cache_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import 'old_school_controller.dart';
import 'old_school_layout.dart';

enum _Zone { exit, window, grid }

/// The Old School guide: details of the picked programme, the corner window
/// (a hole the player's video shows through, or a placeholder before
/// anything plays) and the channel grid.
///
/// D-pad: up/down move between channels, left/right through time, OK tunes
/// a programme that's on now or shows a later one's details. Back is left to
/// the page (it shrinks the video or asks "Press Back again to leave").
class OldSchoolGuideView extends StatefulWidget {
  final OldSchoolController controller;
  final OldSchoolLayout layout;

  /// Whether a channel plays in the window (the player is up). Without it
  /// the window shows a placeholder and nothing is cut out.
  final bool videoActive;
  final ValueChanged<OldSchoolChannel> onTune;

  /// Picking the window: back to full screen.
  final VoidCallback onEnlarge;
  final VoidCallback onExit;

  /// Channel up (+1) / down (-1) from the remote's channel keys.
  final ValueChanged<int>? onChannelStep;
  final FocusNode? focusNode;

  const OldSchoolGuideView({
    super.key,
    required this.controller,
    required this.layout,
    required this.videoActive,
    required this.onTune,
    required this.onEnlarge,
    required this.onExit,
    this.onChannelStep,
    this.focusNode,
  });

  @override
  State<OldSchoolGuideView> createState() => _OldSchoolGuideViewState();
}

class _OldSchoolGuideViewState extends State<OldSchoolGuideView> {
  late final FocusNode _ownFocusNode = FocusNode(debugLabel: 'old_school_guide');
  FocusNode get _focusNode => widget.focusNode ?? _ownFocusNode;

  final ScrollController _rows = ScrollController();
  Timer? _clock;

  _Zone _zone = _Zone.grid;
  int _row = 0;
  OldSchoolEntry? _focused;
  DateTime? _viewStart;
  bool _placedInitialFocus = false;

  OldSchoolController get _c => widget.controller;
  OldSchoolLayout get _layout => widget.layout;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChanged);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => _onClockTick());
    _onControllerChanged();
    // Autofocus is not enough when the video shrinks into the corner: the
    // player's controls still hold focus then, and the remote must land here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(OldSchoolGuideView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (!widget.videoActive && _zone == _Zone.window) _zone = _Zone.grid;
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    _clock?.cancel();
    _rows.dispose();
    _ownFocusNode.dispose();
    super.dispose();
  }

  // --- Time ---------------------------------------------------------------

  static DateTime _floorHalfHour(DateTime t) => DateTime.utc(t.year, t.month, t.day, t.hour, t.minute >= 30 ? 30 : 0);

  /// The earliest the grid may start: the half hour now falls in. Past
  /// programmes can't be watched, so the guide never shows them.
  DateTime get _earliestStart => _floorHalfHour(_c.serverNow);

  DateTime get _start => _viewStart ?? _earliestStart;

  Duration get _visibleSpan => Duration(minutes: (_layout.visibleHours * 60).round());

  DateTime get _viewEnd => _start.add(_visibleSpan);

  double get _blocksWidth => _layout.gridRect.width - _layout.channelColumnWidth;

  double get _pixelsPerMinute => _blocksWidth / (_layout.visibleHours * 60);

  double _xFor(DateTime t) => t.difference(_start).inSeconds / 60 * _pixelsPerMinute;

  void _onClockTick() {
    if (!mounted) return;
    setState(() {
      if (_start.isBefore(_earliestStart)) _viewStart = _earliestStart;
      final focused = _focused;
      if (focused != null && !focused.end.isAfter(_c.serverNow)) {
        _focused = _channelAt(_row) == null ? null : _c.currentOrNextProgramme(_channelAt(_row)!.id);
      }
    });
  }

  void _setViewStart(DateTime start) {
    final earliest = _earliestStart;
    final latest = (_c.guideEnd ?? start).subtract(_visibleSpan);
    var next = start.isBefore(earliest) ? earliest : start;
    if (next.isAfter(latest) && latest.isAfter(earliest)) next = latest;
    if (next == _viewStart) return;
    _viewStart = next;
    unawaited(_c.extendIfNeeded(next.add(_visibleSpan)));
  }

  /// Shift the grid so [entry] is in view, leaving half an hour of context.
  void _revealEntry(OldSchoolEntry entry) {
    final viewEnd = _viewEnd;
    if (entry.start.isBefore(_start) && entry.end.isAfter(_start)) return;
    if (!entry.start.isBefore(_start) && entry.start.isBefore(viewEnd.subtract(const Duration(minutes: 30)))) return;
    _setViewStart(_floorHalfHour(entry.start).subtract(const Duration(minutes: 30)));
  }

  // --- Focus --------------------------------------------------------------

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      final channels = _c.channels;
      if (channels.isEmpty) return;
      if (_row >= channels.length) _row = channels.length - 1;
      if (!_placedInitialFocus && _c.hasLoaded) {
        _placedInitialFocus = true;
        final tuned = _c.indexOfChannel(_c.tunedChannelId);
        _row = tuned >= 0 ? tuned : 0;
        _focused = _c.currentOrNextProgramme(channels[_row].id);
        if (widget.videoActive) _zone = _Zone.grid;
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(_row, animate: false));
      }
    });
  }

  OldSchoolChannel? _channelAt(int index) {
    final channels = _c.channels;
    return index >= 0 && index < channels.length ? channels[index] : null;
  }

  /// The cell on [channel] closest to [focusTime]: the one airing then,
  /// else the next.
  OldSchoolEntry? _programmeNear(OldSchoolChannel channel, DateTime focusTime) {
    final programmes = _c.guideEntriesFor(channel.id);
    for (final p in programmes) {
      if (p.isOnAt(focusTime)) return p;
    }
    for (final p in programmes) {
      if (p.start.isAfter(focusTime) && p.end.isAfter(_c.serverNow)) return p;
    }
    return null;
  }

  void _moveRow(int delta) {
    final next = _row + delta;
    final channel = _channelAt(next);
    if (channel == null) return;
    final focusTime = _focused == null
        ? _start
        : (_focused!.start.isBefore(_start) ? _start : _focused!.start).add(const Duration(minutes: 1));
    setState(() {
      _row = next;
      _focused = _programmeNear(channel, focusTime);
    });
    _revealRow(next);
  }

  void _moveTime(int delta) {
    final channel = _channelAt(_row);
    if (channel == null) return;
    final programmes = _c.guideEntriesFor(channel.id);
    final focused = _focused;
    if (focused == null) {
      final first = _programmeNear(channel, _start);
      if (first != null) setState(() => _focused = first);
      return;
    }
    final index = programmes.indexWhere((p) => p.start == focused.start);
    final target = index < 0
        ? null
        : (index + delta >= 0 && index + delta < programmes.length ? programmes[index + delta] : null);
    if (target == null || !target.end.isAfter(_c.serverNow)) return;
    setState(() {
      _focused = target;
      _revealEntry(target);
    });
  }

  void _revealRow(int index, {bool animate = true}) {
    if (!_rows.hasClients) return;
    final rowHeight = _layout.rowHeight;
    final viewport = _rows.position.viewportDimension;
    final top = index * rowHeight;
    var offset = _rows.offset;
    if (top < offset + rowHeight) offset = top - rowHeight;
    if (top + rowHeight > offset + viewport - rowHeight) offset = top + 2 * rowHeight - viewport;
    offset = offset.clamp(0.0, _rows.position.maxScrollExtent);
    if (offset == _rows.offset) return;
    if (animate) {
      unawaited(_rows.animateTo(offset, duration: const Duration(milliseconds: 160), curve: Curves.easeOut));
    } else {
      _rows.jumpTo(offset);
    }
  }

  void _activate(OldSchoolChannel channel, OldSchoolEntry? entry) {
    if (entry == null || entry.isOnAt(_c.serverNow) || entry.start.isBefore(_c.serverNow)) {
      widget.onTune(channel);
      return;
    }
    unawaited(_showDetails(channel, entry));
  }

  /// The big line for a cell, as the web guide words it: standby reads
  /// "Back soon"; a trailer keeps its own name.
  static String _entryTitle(OldSchoolEntry entry) =>
      entry.kind == OldSchoolEntryKind.standby ? t.oldSchool.backSoon : entry.title;

  /// The small line: "Coming attraction" for a trailer, "Music video" for a
  /// music video, "Programmes resume shortly" for standby, else season and
  /// episode or year and rating.
  static String _entrySubtitle(OldSchoolEntry entry) => switch (entry.kind) {
    OldSchoolEntryKind.trailer => t.oldSchool.comingAttraction,
    OldSchoolEntryKind.music || OldSchoolEntryKind.musicVideo => t.oldSchool.musicVideo,
    OldSchoolEntryKind.standby => t.oldSchool.resumeShortly,
    _ => entry.subtitle,
  };

  Future<void> _showDetails(OldSchoolChannel channel, OldSchoolEntry entry) async {
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(_entryTitle(entry)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Text(
                  t.oldSchool.channelLine(number: '${channel.number}', name: channel.name),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (_entrySubtitle(entry).isNotEmpty) _entrySubtitle(entry),
                    '${formatClockTime(entry.start.toLocal(), is24Hour: is24)} – ${formatClockTime(entry.end.toLocal(), is24Hour: is24)}',
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
                if (entry.overview != null) ...[
                  const SizedBox(height: 12),
                  Text(entry.overview!, style: theme.textTheme.bodyMedium, maxLines: 8, overflow: .ellipsis),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(t.common.close)),
          ],
        );
      },
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key.isBackKey) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.channelDown) {
      if (event is KeyDownEvent) widget.onChannelStep?.call(key == LogicalKeyboardKey.channelUp ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) return KeyEventResult.handled;
      return handleOneShotSelect(event, _activateZone);
    }
    if (!event.isActionable) return KeyEventResult.ignored;
    switch (_zone) {
      case _Zone.exit:
        if (key.isRightKey && widget.videoActive && !_layout.isPortraitPhone) {
          setState(() => _zone = _Zone.window);
        } else if (key.isDownKey) {
          setState(() => _zone = _Zone.grid);
        }
      case _Zone.window:
        if (key.isLeftKey) {
          setState(() => _zone = _Zone.exit);
        } else if (key.isDownKey) {
          setState(() => _zone = _Zone.grid);
        }
      case _Zone.grid:
        if (key.isUpKey) {
          if (_row == 0) {
            setState(() => _zone = widget.videoActive && !_layout.isPortraitPhone ? _Zone.window : _Zone.exit);
          } else {
            _moveRow(-1);
          }
        } else if (key.isDownKey) {
          _moveRow(1);
        } else if (key.isLeftKey) {
          _moveTime(-1);
        } else if (key.isRightKey) {
          _moveTime(1);
        } else {
          return KeyEventResult.ignored;
        }
    }
    return key.isDpadDirection ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _activateZone() {
    switch (_zone) {
      case _Zone.exit:
        widget.onExit();
      case _Zone.window:
        if (widget.videoActive) widget.onEnlarge();
      case _Zone.grid:
        final channel = _channelAt(_row);
        if (channel != null) _activate(channel, _focused);
    }
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final layout = _layout;
    final content = Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: tk.bg)),
        _buildBackdrop(context),
        Positioned.fromRect(rect: layout.infoRect, child: _buildInfo(context)),
        Positioned.fromRect(rect: layout.gridRect, child: _buildGrid(context)),
      ],
    );
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          Positioned.fill(
            child: widget.videoActive
                ? ClipPath(clipper: OldSchoolHoleClipper(layout.windowRect), child: content)
                : content,
          ),
          Positioned.fromRect(rect: layout.windowRect, child: _buildWindow(context)),
          _buildExit(context),
        ],
      ),
    );
  }

  /// The entry the details panel describes: the window's programme while
  /// the window has focus, else the focused grid cell.
  ({OldSchoolChannel channel, OldSchoolEntry? entry})? _described() {
    if (_zone == _Zone.window || (_layout.isPortraitPhone && _zone != _Zone.grid)) {
      final tuned = _c.tunedChannel;
      if (tuned != null) return (channel: tuned, entry: _c.programmeAt(tuned.id) ?? _c.tune?.now);
    }
    final channel = _channelAt(_row);
    if (channel == null) return null;
    return (channel: channel, entry: _focused);
  }

  String? _imageUrl(OldSchoolImage? image, String type, int width) {
    if (image == null) return null;
    return _c.client.thumbnailUrl(
      '/Items/${Uri.encodeComponent(image.itemId)}/Images/$type?tag=${Uri.encodeQueryComponent(image.tag)}',
      width: width,
    );
  }

  Widget _buildBackdrop(BuildContext context) {
    final described = _described();
    final entry = described?.entry;
    final layout = _layout;
    if (entry == null || layout.isPortraitPhone) return const SizedBox.shrink();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final url = _imageUrl(entry.backdrop, 'Backdrop', (layout.size.width * dpr).round());
    if (url == null) return const SizedBox.shrink();
    final tk = tokens(context);
    final top = layout.gridRect.top;
    // While a channel plays, the fan art sits beside the window rather than
    // mostly under it (web PLAN_SHA_21a, 2026-10-11).
    final playing = widget.videoActive;
    return Positioned(
      left: layout.size.width * (playing ? 0.15 : 0.3),
      right: playing ? layout.size.width - layout.windowRect.left : 0,
      top: 0,
      height: top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Inset a little from the fade's solid edge: the picture's own edge
          // showed as a thin seam on the desktop (2026-10-11).
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Image(
              key: ValueKey(url),
              image: CachedNetworkImageProvider(url, cacheManager: PlexImageCacheManager.instance),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [tk.bg, tk.bg, tk.bg.withValues(alpha: 0.55), tk.bg.withValues(alpha: 0.15)],
                stops: const [0, 0.06, 0.4, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tk.bg.withValues(alpha: 0), tk.bg],
                stops: const [0.6, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final layout = _layout;
    final described = _described();
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    if (described == null) return const SizedBox.shrink();
    final channel = described.channel;
    final entry = described.entry;
    final now = _c.serverNow;
    final onNow = entry != null && entry.isOnAt(now);
    final accent = const Color(0xFFF5B400);
    final label = ['${channel.number}', channel.name, if (onNow) t.oldSchool.onNow].join(' · ').toUpperCase();

    final timeLine = entry == null
        ? t.oldSchool.nothingOn
        : [
            if (_entrySubtitle(entry).isNotEmpty) _entrySubtitle(entry),
            '${formatClockTime(entry.start.toLocal(), is24Hour: is24)} – ${formatClockTime(entry.end.toLocal(), is24Hour: is24)}',
          ].join(' · ');

    if (layout.isPortraitPhone) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: accent, fontWeight: .w800, letterSpacing: 1.2),
              maxLines: 1,
              overflow: .ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              entry == null ? channel.name : _entryTitle(entry),
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: .w800),
              maxLines: 1,
              overflow: .ellipsis,
            ),
            Text(
              timeLine,
              style: theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted),
              maxLines: 1,
              overflow: .ellipsis,
            ),
          ],
        ),
      );
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logoHeight = (layout.infoRect.height * 0.2).clamp(36.0, 96.0);
    final logoUrl = entry == null ? null : _imageUrl(entry.logo, 'Logo', (logoHeight * 3 * dpr).round());
    final horizontal = layout.size.width * 0.029;
    final runTime = entry?.runTime;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontal, layout.infoRect.height * 0.2, horizontal, 8),
      child: Column(
        crossAxisAlignment: .start,
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(color: accent, fontWeight: .w800, letterSpacing: 2),
            maxLines: 1,
            overflow: .ellipsis,
          ),
          SizedBox(height: logoHeight * 0.2),
          SizedBox(
            height: logoHeight,
            child: logoUrl == null
                ? Align(alignment: Alignment.centerLeft, child: _titleText(theme, entry, channel))
                : Image(
                    key: ValueKey(logoUrl),
                    image: CachedNetworkImageProvider(logoUrl, cacheManager: PlexImageCacheManager.instance),
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        Align(alignment: Alignment.centerLeft, child: _titleText(theme, entry, channel)),
                  ),
          ),
          SizedBox(height: logoHeight * 0.2),
          Text(
            timeLine,
            style: theme.textTheme.bodyLarge?.copyWith(color: tk.textMuted),
            maxLines: 1,
            overflow: .ellipsis,
          ),
          if (onNow && runTime != null && runTime > Duration.zero) ...[
            const SizedBox(height: 8),
            _progress(context, entry, runTime),
          ],
          if (entry?.overview != null) ...[
            const SizedBox(height: 8),
            Flexible(
              child: Text(entry!.overview!, style: theme.textTheme.bodyMedium, maxLines: 3, overflow: .ellipsis),
            ),
          ],
        ],
      ),
    );
  }

  Widget _titleText(ThemeData theme, OldSchoolEntry? entry, OldSchoolChannel channel) => Text(
    entry == null ? channel.name : _entryTitle(entry),
    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: .w800),
    maxLines: 1,
    overflow: .ellipsis,
  );

  Widget _progress(BuildContext context, OldSchoolEntry entry, Duration runTime) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final done = _c.serverNow.difference(entry.start);
    final fraction = (done.inSeconds / runTime.inSeconds).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: tk.text.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          t.oldSchool.minutesOf(done: '${math.min(done.inMinutes, runTime.inMinutes)}', total: '${runTime.inMinutes}'),
          style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
        ),
      ],
    );
  }

  Widget _buildWindow(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final focused = _zone == _Zone.window && _focusNode.hasFocus;
    if (!widget.videoActive) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: .min,
              children: [
                const AppIcon(Symbols.live_tv_rounded, color: Colors.white54, size: 36),
                const SizedBox(height: 8),
                Text(
                  t.oldSchool.pickOnNow,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Nothing drawn over the picture (Adrian, 2026-10-11): no badge, arrows
    // or caption. A 2px line on the left and bottom, inside the box, in the
    // grey of the grid's on-now cells; a tap anywhere enlarges it.
    final edge = BorderSide(color: Color.alphaBlend(tk.text.withValues(alpha: 0.1), tk.surface), width: 2);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onEnlarge,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: focused
              ? Border.all(color: theme.colorScheme.primary, width: 3)
              : (_layout.isPortraitPhone ? null : Border(left: edge, bottom: edge)),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildExit(BuildContext context) {
    final theme = Theme.of(context);
    final focused = _zone == _Zone.exit && _focusNode.hasFocus;
    final button = Material(
      color: focused ? theme.colorScheme.primary : Colors.black.withValues(alpha: 0.55),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        canRequestFocus: false,
        onTap: widget.onExit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
          child: Row(
            mainAxisSize: .min,
            children: [
              AppIcon(
                Symbols.chevron_left_rounded,
                size: 20,
                color: focused ? theme.colorScheme.onPrimary : Colors.white,
              ),
              const SizedBox(width: 4),
              Text(
                t.oldSchool.exit,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: focused ? theme.colorScheme.onPrimary : Colors.white,
                  fontWeight: .w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final padding = MediaQuery.paddingOf(context);
    return _layout.isPortraitPhone
        ? Positioned(top: padding.top + 12, right: 12, child: button)
        : Positioned(top: 16 + padding.top, left: 16 + padding.left, child: button);
  }

  Widget _buildGrid(BuildContext context) {
    final theme = Theme.of(context);
    final layout = _layout;
    if (!_c.hasLoaded) {
      if (_c.error != null) {
        return Center(
          child: Column(
            mainAxisSize: .min,
            children: [
              Text(t.oldSchool.loadFailed, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 12),
              FilledButton(autofocus: true, onPressed: () => unawaited(_c.load()), child: Text(t.common.retry)),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (_c.channels.isEmpty) {
      return Center(
        child: Text(t.oldSchool.noChannels, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
      );
    }
    final now = _c.serverNow;
    final nowX = _xFor(now);
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        final minutes = -details.delta.dx / _pixelsPerMinute;
        setState(() => _setViewStart(_start.add(Duration(seconds: (minutes * 60).round()))));
      },
      child: Stack(
        children: [
          Column(
            children: [
              SizedBox(height: layout.timeHeaderHeight, child: _buildTimeHeader(context)),
              Expanded(
                child: ListView.builder(
                  controller: _rows,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemExtent: layout.rowHeight,
                  itemCount: _c.channels.length,
                  itemBuilder: (context, index) => _buildRow(context, index),
                ),
              ),
            ],
          ),
          if (nowX >= 0 && nowX <= _blocksWidth)
            Positioned(
              left: layout.channelColumnWidth + nowX - 1,
              top: layout.timeHeaderHeight - 6,
              bottom: 0,
              child: IgnorePointer(
                child: Column(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      transform: Matrix4.translationValues(-4, 0, 0),
                      decoration: const BoxDecoration(color: Color(0xFFE53935), shape: BoxShape.circle),
                    ),
                    Expanded(child: Container(width: 2, color: const Color(0xFFE53935))),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final layout = _layout;
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final startLocal = _start.toLocal();
    final today = DateUtils.isSameDay(startLocal, DateTime.now());
    // "Today · Sun 11 Oct" like the web guide; the narrow phone column keeps
    // just the day.
    final date = DateFormat('EEE d MMM').format(startLocal);
    final dayLabel = today
        ? (layout.isPortraitPhone ? t.oldSchool.today : '${t.oldSchool.today} · $date')
        : (layout.isPortraitPhone ? DateFormat('EEE d').format(startLocal) : date);
    final slots = <Widget>[];
    for (var slot = _start; slot.isBefore(_viewEnd); slot = slot.add(const Duration(minutes: 30))) {
      slots.add(
        Positioned(
          left: _xFor(slot) + 4,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              formatClockTime(slot.toLocal(), is24Hour: is24),
              style: theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted),
            ),
          ),
        ),
      );
    }
    return Row(
      children: [
        SizedBox(
          width: layout.channelColumnWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                dayLabel,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: .w800),
                maxLines: 1,
                overflow: .ellipsis,
              ),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(child: Stack(children: slots)),
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final channel = _c.channels[index];
    final layout = _layout;
    final start = _start;
    final end = _viewEnd;
    final selectedRow = _zone == _Zone.grid && index == _row && _focusNode.hasFocus;
    final programmes = _c
        .guideEntriesFor(channel.id)
        .where((p) => p.end.isAfter(start) && p.start.isBefore(end))
        .toList(growable: false);
    final isTuned = widget.videoActive && channel.id == _c.tunedChannelId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, right: 6),
      child: Row(
        crossAxisAlignment: .stretch,
        children: [
          SizedBox(
            width: layout.channelColumnWidth,
            child: _ChannelCell(
              controller: _c,
              channel: channel,
              compact: layout.isPortraitPhone,
              tuned: isTuned,
              onTap: () => widget.onTune(channel),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  for (final p in programmes)
                    _buildBlock(context, channel, p, index: index, focused: selectedRow && _isFocused(p)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isFocused(OldSchoolEntry p) {
    final focused = _focused;
    return focused != null && p.start == focused.start && p.itemId == focused.itemId;
  }

  Widget _buildBlock(
    BuildContext context,
    OldSchoolChannel channel,
    OldSchoolEntry p, {
    required int index,
    required bool focused,
  }) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final left = math.max(0.0, _xFor(p.start));
    final right = math.min(_blocksWidth, _xFor(p.end));
    final width = right - left - 6;
    if (width <= 4) return const SizedBox.shrink();
    final continues = p.start.isBefore(_start);
    final onNow = p.isOnAt(_c.serverNow);
    final fill = focused
        ? theme.colorScheme.primary
        : onNow
        ? Color.alphaBlend(tk.text.withValues(alpha: 0.1), tk.surface)
        : tk.surface;
    final fg = focused ? theme.colorScheme.onPrimary : tk.text;
    final muted = focused ? theme.colorScheme.onPrimary.withValues(alpha: 0.75) : tk.textMuted;
    final radius = BorderRadius.circular(tk.radiusSm);
    // Trailers and standby are faded like the web's break cells (opacity
    // 0.6); the focused cell stays solid so the remote's place is clear.
    final faded = !p.isProgramme && !focused;
    return Positioned(
      left: left,
      width: width,
      top: 0,
      bottom: 0,
      child: Opacity(
        opacity: faded ? 0.6 : 1,
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(borderRadius: radius),
          child: InkWell(
            borderRadius: radius,
            canRequestFocus: false,
            onTap: () {
              setState(() {
                _zone = _Zone.grid;
                _row = index;
                _focused = p;
              });
              _focusNode.requestFocus();
              _activate(channel, p);
            },
            child: Padding(
              padding: EdgeInsets.fromLTRB(continues ? 6 : 12, 4, 8, 4),
              child: Row(
                children: [
                  if (continues)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text('‹', style: TextStyle(color: muted)),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      mainAxisAlignment: .center,
                      children: [
                        Text(
                          _entryTitle(p),
                          style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: .w700),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                        if (_entrySubtitle(p).isNotEmpty)
                          Text(
                            _entrySubtitle(p),
                            style: theme.textTheme.labelSmall?.copyWith(color: muted),
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A channel's cell in the guide's left column: logo, number and name (two
/// lines on phones, "..." only past that).
class _ChannelCell extends StatelessWidget {
  final OldSchoolController controller;
  final OldSchoolChannel channel;
  final bool compact;
  final bool tuned;
  final VoidCallback onTap;

  const _ChannelCell({
    required this.controller,
    required this.channel,
    required this.compact,
    required this.tuned,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final radius = BorderRadius.circular(tk.radiusSm);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const logoWidth = 56.0;
    final logo = channel.logoTag == null
        ? null
        : Image(
            image: CachedNetworkImageProvider(
              controller.client.oldSchoolLogoUrl(channel, width: (logoWidth * dpr).round()),
              cacheManager: PlexImageCacheManager.instance,
            ),
            width: logoWidth,
            height: 32,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox(width: logoWidth, height: 32),
          );
    final number = Text(
      '${channel.number}',
      style: (compact ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)?.copyWith(
        fontWeight: .w800,
        color: tk.textMuted,
      ),
    );
    final name = Text(
      channel.name,
      style: (compact ? theme.textTheme.labelMedium : theme.textTheme.bodyMedium)?.copyWith(fontWeight: .w700),
      maxLines: 2,
      overflow: .ellipsis,
      textAlign: compact ? TextAlign.center : TextAlign.start,
    );
    return Material(
      color: tk.surface.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: tuned ? const BorderSide(color: Color(0xFFF5B400), width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: radius,
        canRequestFocus: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: compact
              ? Column(
                  mainAxisAlignment: .center,
                  children: [
                    if (logo != null) SizedBox(height: 22, child: logo) else number,
                    Flexible(child: name),
                  ],
                )
              : Row(
                  children: [
                    if (logo != null) ...[logo, const SizedBox(width: 6)],
                    number,
                    const SizedBox(width: 8),
                    Expanded(child: name),
                  ],
                ),
        ),
      ),
    );
  }
}
