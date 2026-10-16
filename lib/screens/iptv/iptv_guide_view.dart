import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/dpad_select_long_press_controller.dart';
import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../models/iptv.dart';
import '../../providers/theme_provider.dart';
import '../../services/image_cache_service.dart';
import '../../services/settings_service.dart' as settings;
import '../../theme/mono_tokens.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../old_school/old_school_layout.dart';
import 'iptv_controller.dart';
import 'iptv_layout.dart';

/// The gold of channel numbers and the tuned channel (as Old School).
const iptvGold = Color(0xFFF5B400);

/// The warning colour of "may not be working".
const iptvWarning = Color(0xFFF59E0B);

enum _Zone { exit, window, filters, channel, grid }

/// The IPTV guide (PLAN_SHA_61a "Agreed design"): details of the picked
/// programme over its picture, the corner window (a hole the player's video
/// shows through, or a placeholder before anything plays), the group tabs
/// and the channel grid.
///
/// D-pad: up/down move between channels, left/right through time; OK on a
/// programme that's on now (or a channel without listings) tunes it, OK on a
/// later one shows its details, a long OK stars or unstars the channel.
/// Left past now picks the channel cell; Left again there, or Play/Pause,
/// goes back to the channel full screen. Up from the first row reaches the
/// tabs. Back is left to the page.
class IptvGuideView extends StatefulWidget {
  final IptvController controller;
  final IptvLayout layout;

  /// Whether a channel plays in the window. Without it the window shows a
  /// placeholder and nothing is cut out.
  final bool videoActive;

  /// Shown in the window instead of the video: the dead-channel message.
  final String? windowMessage;

  final ValueChanged<IptvChannel> onTune;

  /// Picking the window: back to full screen.
  final VoidCallback onEnlarge;
  final VoidCallback onExit;

  /// Channel up (+1) / down (-1) from the remote's channel keys.
  final ValueChanged<int>? onChannelStep;

  /// Keys the guide does not use (digits for number entry).
  final FocusOnKeyEventCallback? onOtherKey;
  final FocusNode? focusNode;

  const IptvGuideView({
    super.key,
    required this.controller,
    required this.layout,
    required this.videoActive,
    required this.onTune,
    required this.onEnlarge,
    required this.onExit,
    this.windowMessage,
    this.onChannelStep,
    this.onOtherKey,
    this.focusNode,
  });

  @override
  State<IptvGuideView> createState() => _IptvGuideViewState();
}

class _IptvGuideViewState extends State<IptvGuideView> {
  late final FocusNode _ownFocusNode = FocusNode(debugLabel: 'iptv_guide');
  FocusNode get _focusNode => widget.focusNode ?? _ownFocusNode;

  final ScrollController _rows = ScrollController();
  final ScrollController _tabs = ScrollController();
  final DpadSelectLongPressController _select = DpadSelectLongPressController();
  Timer? _clock;

  _Zone _zone = _Zone.grid;
  int _row = 0;
  IptvProgramme? _focused;
  DateTime? _viewStart;
  int _tabIndex = 0;
  bool _placedInitialFocus = false;
  IptvFilter? _lastFilter;
  String? _lastTuned;

  IptvController get _c => widget.controller;
  IptvLayout get _layout => widget.layout;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChanged);
    FocusManager.instance.addListener(_onPrimaryFocusChanged);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => _onClockTick());
    _onControllerChanged();
    // The player's controls may still hold focus as the video shrinks into
    // the corner; the remote must land here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(IptvGuideView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (!widget.videoActive && _zone == _Zone.window) _zone = _Zone.grid;
    // The screen turned or resized after the row was scrolled into view.
    if (oldWidget.layout.size != widget.layout.size) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealRow(_row, animate: false);
      });
    }
    // A dead channel stops the player, and focus can go with it: the remote
    // must still land here (a lost first key, 2026-10-16).
    if (widget.windowMessage != null && oldWidget.windowMessage == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
      });
    }
  }

  /// Focus can fall to nothing under the guide: the screen it replaced
  /// lets go of focus after the guide asked for it, and the first remote key
  /// was then lost (2026-10-16). While this screen is on top, the guide takes
  /// focus back whenever nothing real holds it (a dialog is its own route).
  void _onPrimaryFocusChanged() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNode.hasFocus) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final now = FocusManager.instance.primaryFocus;
      if (now == null || now is FocusScopeNode) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onPrimaryFocusChanged);
    _c.removeListener(_onControllerChanged);
    _clock?.cancel();
    _rows.dispose();
    _tabs.dispose();
    _select.dispose();
    _ownFocusNode.dispose();
    super.dispose();
  }

  // --- Time ---------------------------------------------------------------

  static DateTime _floorHalfHour(DateTime t) => DateTime.utc(t.year, t.month, t.day, t.hour, t.minute >= 30 ? 30 : 0);

  DateTime get _earliestStart => _floorHalfHour(_c.serverNow);

  DateTime get _start => _viewStart ?? _earliestStart;

  Duration get _visibleSpan => Duration(minutes: (_layout.visibleHours * 60).round());

  DateTime get _viewEnd => _start.add(_visibleSpan);

  double get _blocksWidth => _layout.gridRect.width - _layout.channelColumnWidth - 6;

  double get _pixelsPerMinute => _blocksWidth / (_layout.visibleHours * 60);

  double _xFor(DateTime t) => t.difference(_start).inSeconds / 60 * _pixelsPerMinute;

  void _onClockTick() {
    if (!mounted) return;
    setState(() {
      if (_start.isBefore(_earliestStart)) _viewStart = _earliestStart;
      final focused = _focused;
      if (focused != null && !focused.end.isAfter(_c.serverNow)) {
        final channel = _channelAt(_row);
        _focused = channel == null ? null : _c.currentOrNextProgramme(channel.id);
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

  void _revealEntry(IptvProgramme entry) {
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
      final filterChanged = _lastFilter != _c.filter;
      _lastFilter = _c.filter;
      if (channels.isEmpty) return;
      if (_row >= channels.length) _row = channels.length - 1;
      if (filterChanged && _placedInitialFocus) {
        _row = 0;
        _focused = _c.currentOrNextProgramme(channels.first.id);
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(0, animate: false));
      }
      // A channel key or typed number tuned another channel: the highlight
      // and the info panel follow it (when the filter shows it).
      final tunedId = _c.tunedChannelId;
      final tunedChanged = tunedId != _lastTuned;
      _lastTuned = tunedId;
      if (tunedChanged && _placedInitialFocus && tunedId != null && _channelAt(_row)?.id != tunedId) {
        final index = _c.indexOfChannel(tunedId);
        if (index >= 0) {
          _row = index;
          if (_zone != _Zone.window) _zone = _Zone.grid;
          _focused = _c.currentOrNextProgramme(channels[index].id);
          WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(index));
        }
      }
      if (!_placedInitialFocus && _c.hasLoaded) {
        _placedInitialFocus = true;
        final tuned = _c.indexOfChannel(_c.tunedChannelId);
        _row = tuned >= 0 ? tuned : 0;
        _focused = _c.currentOrNextProgramme(channels[_row].id);
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(_row, animate: false));
      }
    });
  }

  IptvChannel? _channelAt(int index) {
    final channels = _c.channels;
    return index >= 0 && index < channels.length ? channels[index] : null;
  }

  /// Programmes with less than this left are passed over by the remote: at
  /// the grid's scale they are slivers (as Old School, 2026-10-14).
  static const _minStop = Duration(minutes: 5);

  bool _isStop(IptvProgramme p) {
    final now = _c.serverNow;
    return p.end.difference(p.start.isAfter(now) ? p.start : now) >= _minStop;
  }

  IptvProgramme? _programmeNear(IptvChannel channel, DateTime focusTime) {
    final now = _c.serverNow;
    final at = focusTime.isBefore(now) ? now : focusTime;
    final live = _c.entriesFor(channel.id).where((p) => p.end.isAfter(now)).toList(growable: false);
    return live.where((p) => _isStop(p) && p.isOnAt(at)).firstOrNull ??
        live.where((p) => _isStop(p) && p.start.isAfter(at)).firstOrNull ??
        live.where((p) => p.isOnAt(at) || p.start.isAfter(at)).firstOrNull;
  }

  void _moveRow(int delta) {
    final next = _row + delta;
    final channel = _channelAt(next);
    if (channel == null) return;
    final focusTime = _focused == null ? _c.serverNow : _focused!.start.add(const Duration(minutes: 1));
    setState(() {
      _row = next;
      _focused = _programmeNear(channel, focusTime);
    });
    _revealRow(next);
  }

  bool _moveTime(int delta) {
    final channel = _channelAt(_row);
    if (channel == null) return false;
    final programmes = _c.entriesFor(channel.id);
    final focused = _focused;
    if (focused == null) {
      if (delta < 0) return false;
      final first = _programmeNear(channel, _start);
      if (first == null) return false;
      setState(() => _focused = first);
      return true;
    }
    final index = programmes.indexWhere((p) => p.start == focused.start);
    if (index < 0) return false;
    IptvProgramme? target;
    for (var i = index + delta; i >= 0 && i < programmes.length; i += delta) {
      final candidate = programmes[i];
      if (!candidate.end.isAfter(_c.serverNow)) break;
      if (_isStop(candidate)) {
        target = candidate;
        break;
      }
    }
    final picked = target;
    if (picked == null) return false;
    setState(() {
      _focused = picked;
      _revealEntry(picked);
    });
    return true;
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

  void _activate(IptvChannel channel, IptvProgramme? entry) {
    // No listings, or on now (within a sliver of starting): tune.
    if (entry == null || entry.start.isBefore(_c.serverNow.add(_minStop))) {
      widget.onTune(channel);
      return;
    }
    unawaited(_showDetails(channel, entry));
  }

  // --- Tabs ---------------------------------------------------------------

  List<({IptvFilter filter, String label})> get _tabsList => [
    (filter: const IptvFilter.all(), label: t.iptv.all),
    if (_c.hasFavourites) (filter: const IptvFilter.favourites(), label: '★ ${t.iptv.favourites}'),
    for (final group in _c.groups)
      (filter: IptvFilter.group(group.key), label: group.key.isEmpty ? t.iptv.otherGroup : group.key),
  ];

  void _pickTab(int index) {
    final tabs = _tabsList;
    if (index < 0 || index >= tabs.length) return;
    setState(() => _tabIndex = index);
    _c.setFilter(tabs[index].filter);
  }

  void _moveTab(int delta) {
    final tabs = _tabsList;
    final next = (_tabIndex + delta).clamp(0, tabs.length - 1);
    if (next == _tabIndex) return;
    setState(() => _tabIndex = next);
    _revealTab(next);
  }

  final Map<int, GlobalKey> _tabKeys = {};

  void _revealTab(int index) {
    final context = _tabKeys[index]?.currentContext;
    if (context == null) return;
    unawaited(Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 160)));
  }

  // --- Words --------------------------------------------------------------

  String _groupLabel(IptvChannel channel) {
    final key = iptvGroupKey(channel.group);
    return key.isEmpty ? t.iptv.otherGroup : key;
  }

  /// "Reality · 10:30 am" under a programme's title in the grid.
  String _blockSubtitle(IptvProgramme p, {required bool is24}) =>
      [if (p.kind != null) p.kind!, formatClockTime(p.start.toLocal(), is24Hour: is24)].join(' · ');

  /// "Reality · 10:30 am – 11:30 am · Entertainment" in the details panel.
  String _detailLine(IptvChannel channel, IptvProgramme? p, {required bool is24}) {
    if (p == null) return '${_groupLabel(channel)} · ${t.iptv.noListings}';
    return [
      if (p.kind != null) p.kind!,
      '${formatClockTime(p.start.toLocal(), is24Hour: is24)} – ${formatClockTime(p.end.toLocal(), is24Hour: is24)}',
      _groupLabel(channel),
    ].join(' · ');
  }

  Future<void> _showDetails(IptvChannel channel, IptvProgramme entry) async {
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(entry.title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Text('${channel.numberLabel} · ${channel.name}', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(_detailLine(channel, entry, is24: is24), style: theme.textTheme.bodyMedium),
                if (entry.subtitle case final subtitle? when subtitle.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: .w700)),
                ],
                if (entry.description case final description? when description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(description, style: theme.textTheme.bodyMedium, maxLines: 8, overflow: .ellipsis),
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

  // --- Keys ---------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key.isBackKey) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.channelDown) {
      if (event is KeyDownEvent) widget.onChannelStep?.call(key == LogicalKeyboardKey.channelUp ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) return KeyEventResult.handled;
      if (_zone == _Zone.channel || _zone == _Zone.grid) {
        return _select.handleKeyEvent(
          event,
          isOwnerActive: () => mounted && _focusNode.hasFocus,
          onShortPress: _activateZone,
          onLongPress: () {
            final channel = _channelAt(_row);
            if (channel != null) unawaited(_c.toggleFavourite(channel));
          },
        );
      }
      return handleOneShotSelect(event, _activateZone);
    }
    if (widget.videoActive && (key == LogicalKeyboardKey.mediaPlayPause || key == LogicalKeyboardKey.mediaPlay)) {
      if (event is KeyDownEvent) widget.onEnlarge();
      return KeyEventResult.handled;
    }
    if (!key.isDpadDirection) return widget.onOtherKey?.call(node, event) ?? KeyEventResult.ignored;
    if (!event.isActionable) return KeyEventResult.handled;
    final hasWindowStop = widget.videoActive && !_layout.isPortraitPhone;
    switch (_zone) {
      case _Zone.exit:
        if (key.isRightKey && hasWindowStop) {
          setState(() => _zone = _Zone.window);
        } else if (key.isDownKey) {
          setState(() => _zone = _Zone.filters);
          _revealTab(_tabIndex);
        }
      case _Zone.window:
        if (key.isLeftKey) {
          setState(() => _zone = _Zone.exit);
        } else if (key.isDownKey) {
          setState(() => _zone = _Zone.filters);
          _revealTab(_tabIndex);
        }
      case _Zone.filters:
        if (key.isLeftKey) {
          _moveTab(-1);
        } else if (key.isRightKey) {
          _moveTab(1);
        } else if (key.isUpKey) {
          setState(() => _zone = hasWindowStop ? _Zone.window : _Zone.exit);
        } else if (key.isDownKey && _c.channels.isNotEmpty) {
          setState(() => _zone = _Zone.grid);
          _revealRow(_row);
        }
      case _Zone.channel:
        if (key.isUpKey) {
          if (_row == 0) {
            setState(() => _zone = _Zone.filters);
            _revealTab(_tabIndex);
          } else {
            _moveRow(-1);
          }
        } else if (key.isDownKey) {
          _moveRow(1);
        } else if (key.isRightKey) {
          setState(() => _zone = _Zone.grid);
        } else if (key.isLeftKey) {
          // Left from the channel cell goes back to the channel full screen,
          // as in Old School. A held key's repeats don't count.
          if (event is KeyDownEvent && widget.videoActive) widget.onEnlarge();
        }
      case _Zone.grid:
        if (key.isUpKey) {
          if (_row == 0) {
            setState(() => _zone = _Zone.filters);
            _revealTab(_tabIndex);
          } else {
            _moveRow(-1);
          }
        } else if (key.isDownKey) {
          _moveRow(1);
        } else if (key.isLeftKey) {
          if (!_moveTime(-1) && event is KeyDownEvent) setState(() => _zone = _Zone.channel);
        } else if (key.isRightKey) {
          _moveTime(1);
        }
    }
    return KeyEventResult.handled;
  }

  void _activateZone() {
    switch (_zone) {
      case _Zone.exit:
        widget.onExit();
      case _Zone.window:
        if (widget.videoActive) widget.onEnlarge();
      case _Zone.filters:
        _pickTab(_tabIndex);
      case _Zone.channel:
        final channel = _channelAt(_row);
        if (channel != null) widget.onTune(channel);
      case _Zone.grid:
        final channel = _channelAt(_row);
        if (channel != null) _activate(channel, _focused);
    }
  }

  // --- Build --------------------------------------------------------------

  /// The guide is always dark (the agreed design), whatever the app's theme.
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.dark) return _buildGuide(context);
    final mode = context.select<ThemeProvider, settings.ThemeMode>((p) => p.themeMode);
    return Theme(
      data: ThemeProvider.darkThemeFor(mode),
      child: Builder(builder: _buildGuide),
    );
  }

  Widget _buildGuide(BuildContext context) {
    final tk = tokens(context);
    final layout = _layout;
    // The window is cut out only while video shows through it.
    final cutOut = widget.videoActive && widget.windowMessage == null;
    final content = Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: tk.bg)),
        _buildBackdrop(context),
        Positioned.fromRect(rect: layout.infoRect, child: _buildInfo(context)),
        Positioned.fromRect(rect: layout.filterRect, child: _buildTabs(context)),
        Positioned.fromRect(rect: layout.gridRect, child: _buildGrid(context)),
      ],
    );
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      onFocusChange: (_) => setState(() {}),
      child: Stack(
        children: [
          Positioned.fill(
            child: cutOut ? ClipPath(clipper: OldSchoolHoleClipper(layout.windowRect), child: content) : content,
          ),
          Positioned.fromRect(rect: layout.windowRect, child: _buildWindow(context)),
          _buildExit(context),
        ],
      ),
    );
  }

  /// The channel and programme the details panel describes: the tuned
  /// channel while the window has focus, else the focused row.
  ({IptvChannel channel, IptvProgramme? entry})? _described() {
    if (_zone == _Zone.window || (_layout.isPortraitPhone && _zone != _Zone.grid && _zone != _Zone.channel)) {
      final tuned = _c.tunedChannel;
      if (tuned != null) return (channel: tuned, entry: _c.programmeAt(tuned.id));
    }
    final channel = _channelAt(_row);
    if (channel == null) return null;
    return (channel: channel, entry: _focused ?? _c.programmeAt(channel.id));
  }

  /// The info panel's background: the programme's picture, else a wash of
  /// the channel logo's colours over a soft gold glow (Adrian: "use the
  /// color wash as a backup").
  Widget _buildBackdrop(BuildContext context) {
    final described = _described();
    if (described == null) return const SizedBox.shrink();
    final layout = _layout;
    final tk = tokens(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final entry = described.entry;
    final pictureUrl = entry?.imageId == null
        ? null
        : _c.client.iptvProgrammeImageUrl(_c.libraryId, entry!.imageId!, width: (layout.size.width * dpr).round());
    final logoUrl = _c.client.iptvLogoUrl(described.channel, width: 128);
    final bottom = layout.isPortraitPhone ? layout.infoRect.bottom : layout.filterRect.top;
    final top = layout.isPortraitPhone ? layout.infoRect.top : 0.0;
    final right = layout.isPortraitPhone ? 0.0 : layout.size.width - layout.windowRect.left;
    final wash = _ColourWash(key: ValueKey(logoUrl), logoUrl: logoUrl);
    return Positioned(
      left: 0,
      right: right,
      top: top,
      height: bottom - top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (pictureUrl == null)
            wash
          else
            Image(
              key: ValueKey(pictureUrl),
              image: CachedNetworkImageProvider(pictureUrl, cacheManager: PlexImageCacheManager.instance),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => wash,
            ),
          // Fades out on both sides, so the picture never looks tucked under
          // the video, and darkest behind the text.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  tk.bg.withValues(alpha: 0.9),
                  tk.bg.withValues(alpha: 0.55),
                  tk.bg.withValues(alpha: 0.2),
                  tk.bg.withValues(alpha: 0.2),
                  tk.bg.withValues(alpha: layout.isPortraitPhone ? 0.4 : 0.85),
                ],
                stops: const [0, 0.3, 0.55, 0.85, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tk.bg.withValues(alpha: 0), tk.bg],
                stops: const [0.55, 1],
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
    final onNow = entry != null && entry.isOnAt(_c.serverNow);
    final label = '${channel.numberLabel} · ${channel.name}'.toUpperCase();
    final title = entry?.title.isNotEmpty == true ? entry!.title : channel.name;
    final tags = [
      if (_c.mayNotWork(channel)) _Tag(text: t.iptv.mayNotWork, icon: Symbols.warning_rounded, color: iptvWarning),
      if (channel.not247) _Tag(text: t.iptv.not247, color: tk.textMuted),
    ];

    if (layout.isPortraitPhone) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                _LogoChip(controller: _c, channel: channel, height: 26),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(color: iptvGold, fontWeight: .w800, letterSpacing: 1.2),
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ),
                for (final tag in tags) ...[const SizedBox(width: 6), tag],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: .w800),
              maxLines: 1,
              overflow: .ellipsis,
            ),
            Text(
              _detailLine(channel, entry, is24: is24),
              style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
              maxLines: 1,
              overflow: .ellipsis,
            ),
          ],
        ),
      );
    }

    // Pinned to the top left, under Exit, so a long description grows
    // downward and the title never moves (Adrian, 2026-10-16).
    final horizontal = math.max(20.0, layout.size.width * 0.021);
    final top = MediaQuery.paddingOf(context).top + 16 + 44;
    final description = entry?.description;
    // A short panel (a sideways phone) drops the description, then the
    // progress bar, rather than spill them under the tabs.
    final room = layout.infoRect.height - top - 8;
    const baseHeight = 112.0;
    // Too short even for the title block: smaller type.
    final tight = room < baseHeight;
    final showProgress = onNow && room >= baseHeight + 30;
    final showDescription =
        description != null && description.isNotEmpty && room >= baseHeight + (showProgress ? 30 : 0) + 34;
    return ClipRect(
      child: Padding(
        padding: EdgeInsets.fromLTRB(horizontal, top, horizontal, 8),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                _LogoChip(controller: _c, channel: channel, height: tight ? 28 : 36),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(color: iptvGold, fontWeight: .w800, letterSpacing: 2),
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ),
                for (final tag in tags) ...[const SizedBox(width: 10), tag],
              ],
            ),
            SizedBox(height: tight ? 4 : 10),
            Text(
              title,
              style: (tight ? theme.textTheme.headlineSmall : theme.textTheme.headlineMedium)?.copyWith(
                fontWeight: .w800,
              ),
              maxLines: 1,
              overflow: .ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              _detailLine(channel, entry, is24: is24),
              style: (tight ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)?.copyWith(color: tk.textMuted),
              maxLines: 1,
              overflow: .ellipsis,
            ),
            if (showProgress) ...[const SizedBox(height: 10), _progress(context, entry)],
            if (showDescription) ...[
              const SizedBox(height: 10),
              Flexible(
                child: Text(description, style: theme.textTheme.bodyMedium, maxLines: 2, overflow: .ellipsis),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, IptvProgramme entry) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final runTime = entry.runTime;
    final done = _c.serverNow.difference(entry.start);
    final fraction = (done.inSeconds / math.max(1, runTime.inSeconds)).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 230,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              color: Colors.white,
              backgroundColor: tk.text.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          t.iptv.minutesOf(done: '${math.min(done.inMinutes, runTime.inMinutes)}', total: '${runTime.inMinutes}'),
          style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
        ),
      ],
    );
  }

  Widget _buildWindow(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final focused = _zone == _Zone.window && _focusNode.hasFocus;
    final message = widget.windowMessage;
    if (message != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: .min,
              children: [
                const AppIcon(Symbols.signal_disconnected_rounded, color: iptvWarning, size: 40),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: .w700),
                ),
              ],
            ),
          ),
        ),
      );
    }
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
                  t.iptv.pickChannel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Nothing drawn over the picture: a 2 px line on its two inner edges in
    // the on-now grey, exactly as Old School.
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
                t.iptv.exit,
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

  Widget _buildTabs(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final tabs = _tabsList;
    if (!_c.hasLoaded || tabs.length < 2) return const SizedBox.shrink();
    if (_tabIndex >= tabs.length) _tabIndex = 0;
    final selected = tabs.indexWhere((tab) => tab.filter == _c.filter);
    final horizontal = _layout.isPortraitPhone ? 12.0 : math.max(20.0, _layout.size.width * 0.012);
    return ListView.separated(
      controller: _tabs,
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 6),
      itemCount: tabs.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final isSelected = index == selected;
        final isFocused = _zone == _Zone.filters && index == _tabIndex && _focusNode.hasFocus;
        return Material(
          key: _tabKeys.putIfAbsent(index, GlobalKey.new),
          color: isSelected ? Colors.white : tk.surface,
          shape: StadiumBorder(
            side: isFocused ? BorderSide(color: theme.colorScheme.primary, width: 3) : BorderSide.none,
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            canRequestFocus: false,
            onTap: () {
              setState(() => _zone = _Zone.grid);
              _pickTab(index);
              _focusNode.requestFocus();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  tabs[index].label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: isSelected ? Colors.black : tk.textMuted,
                    fontWeight: .w700,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
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
              Text(t.iptv.loadFailed, style: theme.textTheme.bodyLarge),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _c.filter.favourites ? t.iptv.noFavourites : t.iptv.noChannels,
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final nowX = _xFor(_c.serverNow);
    final left = layout.isPortraitPhone ? 8.0 : math.max(20.0, layout.size.width * 0.012);
    return Padding(
      padding: EdgeInsets.only(left: left),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          final minutes = -details.delta.dx / _pixelsPerMinute;
          setState(() => _setViewStart(_start.add(Duration(seconds: (minutes * 60).round()))));
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final blocksLeft = layout.channelColumnWidth + 6;
            return Stack(
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
                    left: blocksLeft + nowX - 1,
                    top: layout.timeHeaderHeight - 6,
                    bottom: 0,
                    child: const IgnorePointer(
                      child: SizedBox(width: 2, child: ColoredBox(color: Color(0xFFE53935))),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTimeHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final layout = _layout;
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final startLocal = _start.toLocal();
    final today = DateUtils.isSameDay(startLocal, widget.controller.serverNow.toLocal());
    final date = DateFormat('EEE, MMM d').format(startLocal);
    final dayLabel = today
        ? (layout.isPortraitPhone ? t.iptv.today : '${t.iptv.today} · $date')
        : (layout.isPortraitPhone ? DateFormat('EEE d').format(startLocal) : date);
    final slots = <Widget>[];
    for (var slot = _start; slot.isBefore(_viewEnd); slot = slot.add(const Duration(minutes: 30))) {
      slots.add(
        Positioned(
          left: _xFor(slot),
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
          width: layout.channelColumnWidth + 6,
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
    final rowHasFocus = _zone == _Zone.grid && index == _row && _focusNode.hasFocus;
    final programmes = _c
        .entriesFor(channel.id)
        .where((p) => p.end.isAfter(start) && p.start.isBefore(end))
        .toList(growable: false);
    final isTuned = channel.id == _c.tunedChannelId;
    final dead = _c.mayNotWork(channel);
    final Widget blocks;
    if (_c.entriesFor(channel.id).isEmpty) {
      blocks = _buildNoListings(context, channel, index: index, focused: rowHasFocus);
    } else {
      blocks = ClipRect(
        child: Stack(
          children: [
            for (final p in programmes)
              if (!(rowHasFocus && _isFocused(p))) _buildBlock(context, channel, p, index: index, focused: false),
            for (final p in programmes)
              if (rowHasFocus && _isFocused(p)) _buildBlock(context, channel, p, index: index, focused: true),
          ],
        ),
      );
    }
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
              // Too narrow for the logo beside the name (sideways phones,
              // 960-wide TVs): the logo goes over the name.
              stacked: !layout.isPortraitPhone && layout.channelColumnWidth < 230,
              tuned: isTuned,
              mayNotWork: dead,
              focused: _zone == _Zone.channel && index == _row && _focusNode.hasFocus,
              onTap: () {
                setState(() {
                  _zone = _Zone.channel;
                  _row = index;
                });
                _focusNode.requestFocus();
                widget.onTune(channel);
              },
              onLongPress: () => unawaited(_c.toggleFavourite(channel)),
            ),
          ),
          const SizedBox(width: 6),
          // "May not be working": the row greyed out as well as marked.
          Expanded(
            child: Opacity(opacity: dead ? 0.45 : 1, child: blocks),
          ),
        ],
      ),
    );
  }

  bool _isFocused(IptvProgramme p) {
    final focused = _focused;
    return focused != null && p.start == focused.start;
  }

  static const double _minFocusedWidth = 96;

  /// A row with no listings: one striped cell across it with the channel's
  /// name and group (Adrian's pick on the mock-up).
  Widget _buildNoListings(BuildContext context, IptvChannel channel, {required int index, required bool focused}) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final radius = BorderRadius.circular(tk.radiusSm);
    return Material(
      color: tk.surface.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: focused ? const BorderSide(color: Colors.white, width: 2) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        canRequestFocus: false,
        onTap: () {
          setState(() {
            _zone = _Zone.grid;
            _row = index;
            _focused = null;
          });
          _focusNode.requestFocus();
          widget.onTune(channel);
        },
        child: CustomPaint(
          painter: _StripePainter(color: tk.text.withValues(alpha: 0.04)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Column(
              crossAxisAlignment: .start,
              mainAxisAlignment: .center,
              children: [
                Text(
                  channel.name,
                  style: theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted, fontWeight: .w600),
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
                Text(
                  _groupLabel(channel),
                  style: theme.textTheme.labelSmall?.copyWith(color: tk.textMuted.withValues(alpha: 0.7)),
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlock(
    BuildContext context,
    IptvChannel channel,
    IptvProgramme p, {
    required int index,
    required bool focused,
  }) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    var left = math.max(0.0, _xFor(p.start));
    final right = math.min(_blocksWidth, _xFor(p.end));
    var width = right - left - 6;
    if (focused && width < _minFocusedWidth) {
      width = math.min(_minFocusedWidth, _blocksWidth);
      left = math.min(left, _blocksWidth - width);
    }
    if (width <= 4) return const SizedBox.shrink();
    final continues = p.start.isBefore(_start);
    final onNow = p.isOnAt(_c.serverNow);
    final base = onNow ? Color.alphaBlend(tk.text.withValues(alpha: 0.08), tk.surface) : tk.surface;
    final fill = focused ? Color.alphaBlend(tk.text.withValues(alpha: 0.08), base) : base;
    final radius = BorderRadius.circular(tk.radiusSm);
    return Positioned(
      left: left,
      width: width,
      top: 0,
      bottom: 0,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: focused ? const BorderSide(color: Colors.white, width: 2) : BorderSide.none,
        ),
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
            padding: EdgeInsets.fromLTRB(continues ? 6 : 16, 4, 8, 4),
            child: Row(
              children: [
                if (continues)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('‹', style: TextStyle(color: tk.textMuted)),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: .start,
                    mainAxisAlignment: .center,
                    children: [
                      Text(
                        p.title,
                        style: theme.textTheme.bodyMedium?.copyWith(color: tk.text, fontWeight: .w700),
                        maxLines: 1,
                        overflow: .ellipsis,
                      ),
                      Text(
                        _blockSubtitle(p, is24: is24),
                        style: theme.textTheme.labelSmall?.copyWith(color: tk.textMuted),
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
    );
  }
}

/// A channel's cell in the guide's left column: the number big and faint in
/// the corner like a watermark, the logo partly over it, the name after it,
/// and the star and warning at the right (PLAN_SHA_61a).
class _ChannelCell extends StatelessWidget {
  final IptvController controller;
  final IptvChannel channel;
  final bool compact;
  final bool stacked;
  final bool tuned;
  final bool mayNotWork;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChannelCell({
    required this.controller,
    required this.channel,
    required this.compact,
    required this.stacked,
    required this.tuned,
    required this.mayNotWork,
    required this.focused,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final radius = BorderRadius.circular(tk.radiusSm);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logoWidth = compact ? 52.0 : 56.0;
    final logoHeight = stacked ? 26.0 : 34.0;
    final logoUrl = controller.client.iptvLogoUrl(channel, width: (logoWidth * dpr).round());
    final nameStyle = theme.textTheme.bodyMedium?.copyWith(fontWeight: .w700);
    Widget name({int maxLines = 2, TextStyle? style, TextAlign? align}) => Opacity(
      opacity: mayNotWork ? 0.6 : 1,
      child: Text(channel.name, style: style ?? nameStyle, maxLines: maxLines, overflow: .ellipsis, textAlign: align),
    );
    // With no logo, the logo-only cells show the name instead.
    final nameInstead = name(
      style: theme.textTheme.labelMedium?.copyWith(fontWeight: .w700),
      align: .center,
    );
    final blank = compact || stacked ? nameInstead : SizedBox(width: logoWidth, height: 32);
    final logo = logoUrl == null
        ? blank
        : Image(
            image: CachedNetworkImageProvider(logoUrl, cacheManager: PlexImageCacheManager.instance),
            width: logoWidth,
            height: logoHeight,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => blank,
          );
    // Big and faint like a watermark: white at 6%, gold when tuned (26 px,
    // Adrian's numbers on the mock-up).
    final number = Positioned(
      left: 6,
      top: stacked ? 4 : 0,
      child: Text(
        channel.numberLabel,
        style: TextStyle(
          fontSize: stacked ? 18 : 26,
          height: 1,
          fontWeight: FontWeight.w900,
          color: tuned ? iptvGold.withValues(alpha: 0.9) : Colors.white.withValues(alpha: stacked ? 0.4 : 0.06),
        ),
      ),
    );
    final marks = [
      if (mayNotWork) const AppIcon(Symbols.warning_rounded, fill: 1, size: 18, color: iptvWarning),
      if (channel.isFavorite) const AppIcon(Symbols.star_rounded, fill: 1, size: 18, color: iptvGold),
    ];
    return Material(
      color: tk.surface.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: focused ? const BorderSide(color: Colors.white, width: 2) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        canRequestFocus: false,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Stack(
          children: [
            // The tuned channel's gold edge (mock-up).
            if (tuned)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(width: 3, child: ColoredBox(color: iptvGold)),
              ),
            number,
            if (compact)
              Center(
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: logo),
              )
            else if (stacked)
              Padding(
                // Clear of the number in the corner.
                padding: const EdgeInsets.fromLTRB(30, 4, 6, 4),
                child: Column(
                  mainAxisAlignment: .center,
                  children: [
                    if (logoUrl == null)
                      nameInstead
                    else ...[
                      logo,
                      const SizedBox(height: 2),
                      name(
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(fontWeight: .w700),
                        align: .center,
                      ),
                    ],
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 52, right: 8),
                child: Row(
                  children: [
                    logo,
                    const SizedBox(width: 10),
                    Expanded(child: name()),
                    for (final mark in marks) Padding(padding: const EdgeInsets.only(left: 4), child: mark),
                  ],
                ),
              ),
            if ((compact || stacked) && marks.isNotEmpty)
              Positioned(
                right: 4,
                top: 4,
                child: Row(mainAxisSize: .min, children: marks),
              ),
          ],
        ),
      ),
    );
  }
}

/// The channel logo on a small rounded chip, as in the details panel.
class _LogoChip extends StatelessWidget {
  final IptvController controller;
  final IptvChannel channel;
  final double height;

  const _LogoChip({required this.controller, required this.channel, required this.height});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = height * 1.6;
    final url = controller.client.iptvLogoUrl(channel, width: (width * dpr).round());
    if (url == null) return const SizedBox.shrink();
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: tk.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
      child: Image(
        image: CachedNetworkImageProvider(url, cacheManager: PlexImageCacheManager.instance),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// A small tag beside the channel label: "May not be working", "Not 24/7".
class _Tag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;

  const _Tag({required this.text, this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: .min,
          children: [
            if (icon != null) ...[AppIcon(icon!, fill: 1, size: 14, color: color), const SizedBox(width: 4)],
            Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: .w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// The logo stretched and blurred to its colours over a soft gold glow, so a
/// black logo still shows the glow.
class _ColourWash extends StatelessWidget {
  final String? logoUrl;

  const _ColourWash({super.key, required this.logoUrl});

  @override
  Widget build(BuildContext context) {
    final url = logoUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.2),
              radius: 1.1,
              colors: [iptvGold.withValues(alpha: 0.22), iptvGold.withValues(alpha: 0)],
            ),
          ),
        ),
        if (url != null)
          Opacity(
            opacity: 0.5,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.decal),
              child: Image(
                image: CachedNetworkImageProvider(url, cacheManager: PlexImageCacheManager.instance),
                fit: BoxFit.fill,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
  }
}

class _StripePainter extends CustomPainter {
  final Color color;

  const _StripePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 8;
    for (var x = -size.height; x < size.width; x += 22) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => oldDelegate.color != color;
}
