import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../media/episode_collection.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../providers/discover_provider.dart';
import '../../services/device_performance.dart';
import '../../services/scrub_preview_source.dart';
import '../../services/settings_service.dart' show EpisodePosterMode;
import '../../utils/app_logger.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/platform_detector.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/video_player_navigation.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/cycling_media_backdrop.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/video_controls/widgets/timeline_slider.dart' show ScrubFrameView;
import '../video_player/video_mini_player.dart';

const kUpNextRouteName = '/up_next';

/// The Up Next page (local/plans/video-mini-player.md, stage 2; mock-up
/// local/mockups/up-next). Back during the credits puts the video in the
/// corner box and this page under it: what to watch next. Back again stops the
/// video and returns to where playback started (this page took the player
/// page's place).
class UpNextRoute extends PageRouteBuilder<void> {
  UpNextRoute({required MediaItem item, MediaItem? nextEpisode, bool isOffline = false})
    : this._(item, nextEpisode, isOffline, ValueNotifier<int>(0));

  UpNextRoute._(MediaItem item, MediaItem? nextEpisode, bool isOffline, this._returned)
    : super(
        settings: const RouteSettings(name: kUpNextRouteName),
        pageBuilder: (context, _, _) =>
            UpNextScreen(item: item, nextEpisode: nextEpisode, isOffline: isOffline, returned: _returned),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );

  final ValueNotifier<int> _returned;

  /// A page above this one closed (the video's full-screen page, an item page).
  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    _returned.value++;
  }

  @override
  void dispose() {
    _returned.dispose();
    super.dispose();
  }
}

enum _RowKind { season, continueWatching, similar }

class _Row {
  const _Row(this.kind, this.title, this.items);

  final _RowKind kind;
  final String title;
  final List<MediaItem> items;
}

class UpNextScreen extends StatefulWidget {
  const UpNextScreen({super.key, required this.item, required this.returned, this.nextEpisode, this.isOffline = false});

  /// The item whose credits are playing in the box.
  final MediaItem item;
  final MediaItem? nextEpisode;
  final bool isOffline;
  final ValueListenable<int> returned;

  @override
  State<UpNextScreen> createState() => _UpNextScreenState();
}

class _UpNextScreenState extends State<UpNextScreen> with SingleTickerProviderStateMixin {
  // Design units: the mock-up is drawn on a 1920-wide screen.
  static const _design = 1920.0;

  // The hero logo slot, in design units.
  static const _logoWidth = 520.0;
  static const _logoHeight = 104.0;

  /// Logos to load ahead of the one shown: rows start at the far left and
  /// scroll right, and anything passed stays in the image cache, so only the
  /// next ones to the right (Adrian, 2026-11-12).
  static const _logoLookahead = 2;

  final _mini = VideoMiniPlayer.instance;
  final _playNode = FocusNode(debugLabel: 'up_next_play');
  final _detailsNode = FocusNode(debugLabel: 'up_next_details');
  final _rowsScroll = ScrollController();
  late final AnimationController _grow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500));

  MediaServerClient? _client;
  List<_Row> _rows = const [];
  final List<List<FocusNode>> _cardNodes = [];
  final List<int> _col = [];
  MediaItem? _hero;
  _RowKind? _heroKind;
  int _heroRow = -1;
  bool _loaded = false;
  bool _shown = false;

  /// Page scale from the last layout (window width / [_design]); the logo
  /// preload needs it to ask for the same image size the page shows.
  double _k = 1;
  final Set<String> _preloadedLogos = {};

  /// The box's video has ended or stopped: the art grows to the full width.
  bool _gone = false;

  /// The box went back to full screen (not stopped); cleared when it comes back.
  bool _expandLatch = false;

  ScrubPreviewSource? _trick;
  String? _trickKey;

  bool get _isEpisodePage => widget.item.kind == MediaKind.episode;

  @override
  void initState() {
    super.initState();
    _mini.addListener(_boxChanged);
    _mini.timeLeft.addListener(_boxChanged);
    widget.returned.addListener(_returnedTo);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _client = context.getMediaClientForItemOrNull(widget.item, isOffline: widget.isOffline);
    unawaited(_load());
  }

  @override
  void dispose() {
    _mini.removeListener(_boxChanged);
    _mini.timeLeft.removeListener(_boxChanged);
    widget.returned.removeListener(_returnedTo);
    // Leaving this page some other way (Home, a new video) ends the box too.
    if (_mini.isShowing && !_mini.isExpanding) unawaited(_mini.stop());
    _trick?.dispose();
    _grow.dispose();
    _playNode.dispose();
    _detailsNode.dispose();
    for (final row in _cardNodes) {
      for (final node in row) {
        node.dispose();
      }
    }
    _rowsScroll.dispose();
    super.dispose();
  }

  // ---- the box ----

  void _boxChanged() {
    if (!mounted) return;
    if (_mini.isExpanding) _expandLatch = true;
    if (_mini.isShowing && !_mini.isExpanding) _expandLatch = false;
    final left = _mini.timeLeft.value;
    final ending = _mini.isShowing && left != null && left <= VideoMiniPlayer.growAt;
    final stopped = !_mini.isShowing && !_expandLatch;
    _setGone(ending || stopped);
  }

  void _returnedTo() {
    _expandLatch = false;
    _boxChanged();
  }

  void _setGone(bool gone) {
    if (gone == _gone) return;
    setState(() => _gone = gone);
    if (gone) {
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (reduce) {
        _grow.value = 1;
      } else {
        unawaited(_grow.forward());
      }
    } else {
      _grow.value = 0;
    }
  }

  Future<void> _stopBox() async {
    if (_mini.isShowing) await _mini.stop();
  }

  void _expandBox() {
    if (_mini.isShowing && !_mini.isExpanding) _mini.expand();
  }

  // ---- data ----

  MediaServerClient? _clientFor(MediaItem item) => item.serverId == widget.item.serverId
      ? _client
      : context.getMediaClientForItemOrNull(item, isOffline: widget.isOffline);

  Future<void> _load() async {
    final item = widget.item;
    final client = _client;
    var onDeck = const <MediaItem>[];
    try {
      onDeck = context.read<DiscoverProvider>().onDeck;
    } catch (_) {}

    Future<List<MediaItem>> season() async {
      final next = widget.nextEpisode;
      if (!_isEpisodePage) return const [];
      final parentId = item.parentId;
      if (client == null || parentId == null) return [?next];
      try {
        final children = await client.fetchChildren(parentId);
        final current = item.index ?? 0;
        final later = children.where((e) => e.kind == MediaKind.episode && (e.index ?? 0) > current).toList()
          ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
        if (later.isEmpty) return [?next];
        return later;
      } catch (e) {
        appLogger.d('Up Next: season episodes failed', error: e);
        return [?next];
      }
    }

    Future<List<MediaItem>> similar() async {
      final target = _isEpisodePage ? item.grandparentId : item.id;
      if (client == null || target == null || widget.isOffline) return const [];
      try {
        final hubs = await client.fetchRelatedHubs(target, count: 20);
        if (hubs.isEmpty) return const [];
        var hub = hubs.first;
        for (final h in hubs) {
          final title = h.title.toLowerCase();
          if (title.contains('similar') || title.contains('like')) {
            hub = h;
            break;
          }
        }
        return hub.items.where((i) => i.id != item.id && i.id != item.grandparentId).toList();
      } catch (e) {
        appLogger.d('Up Next: similar titles failed', error: e);
        return const [];
      }
    }

    final continueWatching = onDeck
        .where(
          (i) =>
              i.globalKey != item.globalKey &&
              !(_isEpisodePage && i.grandparentId != null && i.grandparentId == item.grandparentId),
        )
        .take(15)
        .toList();

    final results = await Future.wait([season(), similar()]);
    if (!mounted) return;
    final seasonItems = results[0];
    final similarItems = results[1];
    final rows = <_Row>[];
    final showName = item.grandparentTitle ?? item.title ?? '';
    if (_isEpisodePage) {
      if (seasonItems.isNotEmpty) {
        final number = seasonItems.first.parentIndex ?? item.parentIndex ?? 1;
        rows.add(_Row(_RowKind.season, t.upNext.nextInSeason(number: number), seasonItems));
      }
      if (continueWatching.isNotEmpty) {
        rows.add(_Row(_RowKind.continueWatching, t.discover.continueWatching, continueWatching));
      }
      if (similarItems.isNotEmpty) rows.add(_Row(_RowKind.similar, t.upNext.moreLike(title: showName), similarItems));
    } else {
      if (similarItems.isNotEmpty) {
        rows.add(_Row(_RowKind.similar, t.upNext.moreLike(title: item.title ?? ''), similarItems));
      }
      if (continueWatching.isNotEmpty) {
        rows.add(_Row(_RowKind.continueWatching, t.discover.continueWatching, continueWatching));
      }
    }
    setState(() {
      _rows = rows;
      _cardNodes
        ..clear()
        ..addAll([
          for (final row in rows) List.generate(row.items.length, (i) => FocusNode(debugLabel: 'up_next_card_$i')),
        ]);
      _col
        ..clear()
        ..addAll(List.filled(rows.length, 0));
      if (rows.isNotEmpty) _setHero(0, 0);
    });
    // Each row starts at its left end: its first logos are the next ones seen.
    _preloadLogos([
      for (var r = 0; r < rows.length; r++)
        for (var c = 0; c < rows[r].items.length && c < _logoLookahead; c++) (r, c),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playNode.requestFocus();
    });
    if (seasonItems.isNotEmpty) unawaited(_loadTrick(seasonItems.first));
  }

  /// The next episode's trick-play frames for its thumbnail (one item request
  /// when they are not cached; nothing else is fetched).
  Future<void> _loadTrick(MediaItem episode) async {
    final client = _clientFor(episode);
    if (client == null || widget.isOffline || DevicePerformance.isReduced) return;
    try {
      var source = await client.fetchCachedMediaSourceInfo(episode.id);
      var full = episode;
      if (source == null) {
        full = await client.fetchItem(episode.id) ?? episode;
        source = await client.fetchCachedMediaSourceInfo(episode.id);
      }
      if (source == null || !mounted) return;
      final preview = await client.createScrubPreviewSource(item: full, mediaSource: source);
      if (!mounted || preview == null || !preview.isAvailable) {
        preview?.dispose();
        return;
      }
      setState(() {
        _trick?.dispose();
        _trick = preview;
        _trickKey = episode.globalKey;
      });
    } catch (e) {
      appLogger.d('Up Next: trick-play frames unavailable', error: e);
    }
  }

  // ---- the chosen title ----

  void _setHero(int row, int col) {
    final item = _rows[row].items[col];
    if (identical(item, _hero)) return;
    _hero = item;
    _heroKind = _rows[row].kind;
    _heroRow = row;
    _preloadLogos([for (final c in upNextLookaheadColumns(col, _rows[row].items.length, _logoLookahead)) (row, c)]);
  }

  /// Starts downloading the logos of [cells] (row, column) so they show at
  /// once when reached. Runs after the frame: callers are inside setState, and
  /// [_k] is only known once the page has laid out.
  void _preloadLogos(List<(int, int)> cells) {
    if (cells.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final (row, col) in cells) {
        if (row >= _rows.length || col >= _rows[row].items.length) continue;
        final item = _rows[row].items[col];
        final path = item.clearLogoPath;
        if (path == null || path.isEmpty) continue;
        final image = UpNextLogo.imageFor(
          context,
          client: _clientFor(item),
          logoPath: path,
          width: _logoWidth * _k,
          height: _logoHeight * _k,
        );
        if (image == null || !_preloadedLogos.add(image.url)) continue;
        unawaited(precacheImage(image.provider, context, onError: (_, _) {}));
      }
    });
  }

  /// Movie page, or the episode page off its season row: the art sits on the
  /// left and fades out under the box (Adrian, 2026-11-10).
  bool get _wantSplit => !_isEpisodePage || _heroKind != _RowKind.season;

  Future<void> _play(MediaItem item) async {
    var target = item;
    if (item.kind == MediaKind.show) {
      final first = await _firstEpisode(item);
      if (first == null || !mounted) return;
      target = first;
    }
    if (!mounted) return;
    // The new video takes this page's place: Back from it returns to where
    // the first video started. Starting it stops the box.
    await navigateToVideoPlayer(context, metadata: target, usePushReplacement: true, isOffline: widget.isOffline);
  }

  Future<MediaItem?> _firstEpisode(MediaItem show) async {
    final client = _clientFor(show);
    if (client == null) return null;
    try {
      final seasons = await fetchShowSeasons(client, show.id);
      if (seasons.isEmpty) return null;
      final season = seasons.firstWhere((s) => (s.index ?? 0) >= 1, orElse: () => seasons.first);
      final episodes = (await client.fetchChildren(season.id)).where((e) => e.kind == MediaKind.episode).toList()
        ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
      return episodes.isEmpty ? null : episodes.first;
    } catch (e) {
      appLogger.d('Up Next: first episode lookup failed', error: e);
      return null;
    }
  }

  void _details(MediaItem item) => unawaited(navigateToMediaItemDetails(context, item, isOffline: widget.isOffline));

  // ---- keys ----

  /// Back closes the page (and stops the box), on the key's release. The Back
  /// press that opened this page lands here only half (its release): it was
  /// pressed on the player, so it is swallowed instead of closing the page.
  bool _backArmed = false;

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
    if (ModalRoute.of(context)?.isCurrent != true) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _backArmed = true;
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (_backArmed) {
        _backArmed = false;
        unawaited(Navigator.maybePop(context));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onButtonKey(KeyEvent event, int index) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key.isLeftKey && index == 1) {
      _playNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key.isRightKey && index == 0) {
      _detailsNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key.isDownKey && _rows.isNotEmpty) {
      _focusCard(0, _col[0]);
      return KeyEventResult.handled;
    }
    // Up past the top buttons: straight back to the video (Adrian, 2026-11-10).
    if (key.isUpKey) {
      _expandBox();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onCardKey(KeyEvent event, int row, int col) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key.isSelectKey) {
      setState(() => _setHero(row, col));
      _playNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key.isLeftKey) {
      if (col > 0) _focusCard(row, col - 1);
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (col < _rows[row].items.length - 1) _focusCard(row, col + 1);
      return KeyEventResult.handled;
    }
    if (key.isUpKey) {
      if (row == 0) {
        _playNode.requestFocus();
      } else {
        _focusCard(row - 1, _col[row - 1]);
      }
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      if (row < _rows.length - 1) _focusCard(row + 1, _col[row + 1]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusCard(int row, int col) {
    final count = _rows[row].items.length;
    if (count == 0) return;
    _cardNodes[row][col.clamp(0, count - 1)].requestFocus();
  }

  void _cardFocused(BuildContext cardContext, int row, int col) {
    _col[row] = col;
    setState(() => _setHero(row, col));
    unawaited(
      Scrollable.ensureVisible(
        cardContext,
        alignment: 0.05,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_stopBox());
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onRootKey,
        child: Material(
          color: bg,
          child: AnimatedOpacity(
            opacity: _shown ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final k = size.width / _design;
                _k = k;
                return Stack(
                  fit: StackFit.expand,
                  children: [_background(context, size, bg), _content(context, size, k)],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _background(BuildContext context, Size size, Color bg) {
    final hero = _hero;
    if (hero == null) return const SizedBox.shrink();
    final wantSplit = _wantSplit;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      child: KeyedSubtree(
        key: ValueKey<bool>(wantSplit),
        child: AnimatedBuilder(
          animation: _grow,
          builder: (context, _) {
            final split = wantSplit ? 1 - Curves.easeInOut.transform(_grow.value) : 0.0;
            return _art(context, hero, size, split, bg);
          },
        ),
      ),
    );
  }

  /// The title's fan art: full width, or (split = 1) the left 72% with its
  /// right edge faded out. In between while it grows. The image is always
  /// requested at the full size, so the grow never asks the server again.
  Widget _art(BuildContext context, MediaItem hero, Size size, double split, Color bg) {
    final aspect = size.height > 0 ? size.width / size.height : 16 / 9;
    final low = DevicePerformance.isLowEndHardware;
    Widget art = CyclingMediaBackdrop(
      mediaKey: hero.globalKey,
      imagePaths: hero.heroRotationPaths(containerAspectRatio: aspect),
      fallbackImagePaths: hero.heroArtCandidates(containerAspectRatio: aspect),
      client: _clientFor(hero),
      allowNetwork: !widget.isOffline,
      width: size.width,
      height: size.height,
      fallbackColor: bg,
      drift: low ? 0 : 0.04,
      rotationInterval: const Duration(seconds: 20),
      fadeDuration: const Duration(milliseconds: 1500),
    );
    if (split > 0) {
      final fadeFrom = 0.55 + 0.45 * (1 - split);
      art = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          colors: const [Colors.white, Colors.white, Color(0x00FFFFFF)],
          stops: [0, fadeFrom.clamp(0.0, 0.999), 1],
        ).createShader(rect),
        child: art,
      );
    }
    final artWidth = size.width * (1 - 0.28 * split);
    Color c(double a) => bg.withValues(alpha: a);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(left: 0, top: 0, bottom: 0, width: artWidth, child: art),
        // Left shade for the text (lighter with the split, so the art shows),
        // and the bottom shade for the rows.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color.lerp(c(0.96), c(0.88), split)!,
                Color.lerp(c(0.78), c(0.5), split)!,
                Color.lerp(c(0.25), c(0.12), split)!,
                Color.lerp(c(0.35), c(0), split)!,
              ],
              stops: [0, 0.3 + 0.08 * (1 - split), 0.55 + 0.2 * (1 - split), 1],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [c(1), c(0.85), c(0)],
              stops: const [0, 0.42, 0.7],
            ),
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, Size size, double k) {
    final top = MediaQuery.paddingOf(context).top + 48 * k;
    final hero = _hero;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hero != null) _topArea(context, hero, k),
          SizedBox(height: 34 * k),
          Expanded(child: _rowsList(context, k)),
        ],
      ),
    );
  }

  bool get _focusVisible => PlatformDetector.isTV() || InputModeTracker.isKeyboardMode(context);

  Widget _topArea(BuildContext context, MediaItem hero, double k) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isEp = hero.kind == MediaKind.episode;
    final inSeason = _heroKind == _RowKind.season;
    final isCW = _heroKind == _RowKind.continueWatching;
    final kind = switch (_heroKind) {
      _RowKind.season when _heroRow == 0 && identical(hero, _rows[0].items.first) => t.upNext.nextEpisode,
      _RowKind.season => t.common.seasonNumber(number: hero.parentIndex ?? 1),
      _RowKind.continueWatching => t.discover.continueWatching,
      _RowKind.similar => _rows[_heroRow].title,
      null => '',
    };
    final showThumbSlot = _isEpisodePage;
    final textWidth = (1120 - (showThumbSlot ? 440 : 0)) * k;
    final logo = hero.clearLogoPath;
    final name = isEp ? (hero.grandparentTitle ?? hero.title ?? '') : (hero.title ?? '');
    final episodeLine = isEp
        ? (inSeason
              ? 'E${hero.index ?? ''} · ${hero.title ?? ''}'
              : '${t.upNext.seasonEpisode(season: hero.parentIndex ?? 0, episode: hero.index ?? 0)} · ${hero.title ?? ''}')
        : null;
    final meta = <String>[
      if (isEp && inSeason) ...[
        t.common.seasonNumber(number: hero.parentIndex ?? 0),
        t.upNext.episodeNumber(number: hero.index ?? 0),
        if ((hero.durationMs ?? 0) > 0) t.upNext.minutes(count: (hero.durationMs! / 60000).round()),
      ] else if (!isEp) ...[
        if (hero.year != null) '${hero.year}',
        if ((hero.durationMs ?? 0) > 0) _hoursMinutes(hero.durationMs!),
        if (hero.rating != null && hero.rating! > 0) '★ ${hero.rating!.toStringAsFixed(1)}',
      ],
    ];
    final playLabel = switch (hero.kind) {
      MediaKind.episode when inSeason && identical(hero, _rows[0].items.first) => t.upNext.playNextEpisode,
      MediaKind.episode when inSeason => t.upNext.playEpisode,
      MediaKind.show => t.upNext.playFirstEpisode,
      _ when isCW || (hero.viewOffsetMs ?? 0) > 0 => t.common.resume,
      _ => t.common.play,
    };
    final white = Colors.white;
    return Padding(
      padding: EdgeInsets.only(left: 96 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showThumbSlot) ...[_thumbSlot(context, hero, k), SizedBox(width: 40 * k)],
          SizedBox(
            width: textWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: t.upNext.label.toUpperCase(),
                        style: TextStyle(color: accent, fontWeight: FontWeight.w700, letterSpacing: 3 * k),
                      ),
                      TextSpan(text: '  ·  ${kind.toUpperCase()}'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20 * k,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2 * k,
                    color: white.withValues(alpha: 0.66),
                  ),
                ),
                SizedBox(height: 12 * k),
                SizedBox(
                  height: _logoHeight * k,
                  width: _logoWidth * k,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: logo != null
                        ? UpNextLogo(
                            key: ValueKey(('logo', hero.globalKey)),
                            client: _clientFor(hero),
                            logoPath: logo,
                            width: _logoWidth * k,
                            height: _logoHeight * k,
                            fallback: _bigName(name, k),
                          )
                        : _bigName(name, k),
                  ),
                ),
                SizedBox(height: 12 * k),
                if (episodeLine != null) ...[
                  Text(
                    episodeLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 34 * k, fontWeight: FontWeight.w700, color: white, height: 1.1),
                  ),
                  SizedBox(height: 10 * k),
                ],
                if (meta.isNotEmpty || (!isEp && hero.contentRating != null)) ...[
                  Row(
                    children: [
                      for (final m in meta) ...[
                        Text(
                          m,
                          style: TextStyle(fontSize: 21 * k, color: const Color(0xFFD6D7DC)),
                        ),
                        SizedBox(width: 14 * k),
                      ],
                      if (!isEp && hero.contentRating != null)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 7 * k),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFF888888)),
                            borderRadius: BorderRadius.circular(4 * k),
                          ),
                          child: Text(
                            hero.contentRating!,
                            style: TextStyle(fontSize: 17 * k, color: const Color(0xFFD6D7DC), height: 1.5),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 14 * k),
                ],
                SizedBox(
                  height: 95 * k,
                  width: 820 * k,
                  child: Text(
                    hero.summary ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 21 * k, height: 1.5, color: const Color(0xFFC9CAD1)),
                  ),
                ),
                SizedBox(height: 22 * k),
                Row(
                  children: [
                    _UpNextButton(
                      node: _playNode,
                      k: k,
                      primary: true,
                      icon: Symbols.play_arrow_rounded,
                      label: playLabel,
                      showFocus: _focusVisible,
                      onPressed: () => unawaited(_play(hero)),
                      onKey: (event) => _onButtonKey(event, 0),
                    ),
                    SizedBox(width: 16 * k),
                    _UpNextButton(
                      node: _detailsNode,
                      k: k,
                      label: t.upNext.details,
                      showFocus: _focusVisible,
                      onPressed: () => _details(hero),
                      onKey: (event) => _onButtonKey(event, 1),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigName(String name, double k) => Text(
    name,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 50 * k, fontWeight: FontWeight.w700, color: Colors.white, height: 1.05),
  );

  String _hoursMinutes(int ms) {
    final minutes = (ms / 60000).round();
    if (minutes < 60) return t.upNext.minutes(count: minutes);
    return t.upNext.hoursMinutes(hours: minutes ~/ 60, minutes: minutes % 60);
  }

  /// Episode page: the next episode's still with its trick-play frames on the
  /// season row; the title's poster elsewhere, in the same spot so the text
  /// never moves (Adrian, 2026-11-10).
  Widget _thumbSlot(BuildContext context, MediaItem hero, double k) {
    final width = 400 * k;
    final client = _clientFor(hero);
    if (_heroKind == _RowKind.season && hero.kind == MediaKind.episode) {
      final trick = hero.globalKey == _trickKey ? _trick : null;
      return _Shadowed(
        k: k,
        child: SizedBox(
          width: width,
          height: width * 9 / 16,
          child: Stack(
            fit: StackFit.expand,
            children: [
              OptimizedMediaImage.thumb(
                client: client,
                imagePath: hero.thumbPath,
                width: width,
                height: width * 9 / 16,
              ),
              if (trick != null) _TrickPlayFrames(source: trick, durationMs: hero.durationMs ?? 0),
            ],
          ),
        ),
      );
    }
    final height = 360 * k;
    final poster = hero.posterThumb(mode: EpisodePosterMode.seasonPoster);
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: _Shadowed(
          k: k,
          child: SizedBox(
            width: height * 2 / 3,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                OptimizedMediaImage.poster(client: client, imagePath: poster, width: height * 2 / 3, height: height),
                if (_heroKind == _RowKind.continueWatching) _Progress(item: hero, k: k),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowsList(BuildContext context, double k) {
    return ListView.builder(
      controller: _rowsScroll,
      scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
      padding: EdgeInsets.only(bottom: 60 * k),
      itemCount: _rows.length,
      itemBuilder: (context, r) {
        final row = _rows[r];
        final wide = row.kind == _RowKind.season;
        final cardW = (wide ? 360 : 186) * k;
        final cardH = (wide ? 203 : 279) * k;
        return Padding(
          padding: EdgeInsets.only(bottom: 34 * k),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(left: 96 * k),
                child: Text(
                  row.title,
                  style: TextStyle(fontSize: 26 * k, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
              SizedBox(height: 14 * k),
              SizedBox(
                height: cardH + 16 * k,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  // Build every card (a row holds at most ~20), so the remote can
                  // always move focus to the next one.
                  scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(horizontal: 96 * k, vertical: 8 * k),
                  itemCount: row.items.length,
                  separatorBuilder: (_, _) => SizedBox(width: 18 * k),
                  itemBuilder: (context, c) {
                    final item = row.items[c];
                    return _UpNextCard(
                      node: _cardNodes[r][c],
                      k: k,
                      width: cardW,
                      height: cardH,
                      selected: identical(item, _hero),
                      showFocus: _focusVisible,
                      onFocused: (cardContext) => _cardFocused(cardContext, r, c),
                      onTap: () => setState(() => _setHero(r, c)),
                      onKey: (event) => _onCardKey(event, r, c),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (wide)
                            OptimizedMediaImage.thumb(
                              client: _clientFor(item),
                              imagePath: item.thumbPath,
                              width: cardW,
                              height: cardH,
                            )
                          else
                            OptimizedMediaImage.poster(
                              client: _clientFor(item),
                              imagePath: item.posterThumb(mode: EpisodePosterMode.seasonPoster),
                              width: cardW,
                              height: cardH,
                            ),
                          if (wide) _EpisodeCaption(item: item, k: k),
                          if (row.kind == _RowKind.continueWatching) _Progress(item: item, k: k),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Columns after [col] whose logos load ahead, at most [lookahead] and never
/// past the row's [count] items. Rows only scroll right from the left end, and
/// passed logos stay cached, so nothing to the left.
@visibleForTesting
List<int> upNextLookaheadColumns(int col, int count, int lookahead) => [
  for (var c = col + 1; c < count && c <= col + lookahead; c++) c,
];

/// The Up Next hero logo. While it downloads the slot stays empty: the default
/// loading tile is a solid box the size of the slot, which showed until the
/// logo's see-through picture arrived (Adrian, 2026-11-12). The title shows
/// only if the logo can't load.
@visibleForTesting
class UpNextLogo extends StatelessWidget {
  const UpNextLogo({
    super.key,
    required this.client,
    required this.logoPath,
    required this.width,
    required this.height,
    required this.fallback,
  });

  final MediaServerClient? client;
  final String logoPath;
  final double width;
  final double height;
  final Widget fallback;

  static const _type = ImageType.logo;

  /// The image this widget shows for these values, as [OptimizedMediaImage]
  /// builds it: same URL and decode size, so a preload lands in the same
  /// memory-cache entry. Null when no URL can be made.
  static ({String url, ImageProvider provider})? imageFor(
    BuildContext context, {
    required MediaServerClient? client,
    required String logoPath,
    required double width,
    required double height,
  }) {
    final pixelRatio = MediaImageHelper.artworkPixelRatio(context, imageType: _type);
    final url = MediaImageHelper.getOptimizedImageUrl(
      client: client,
      thumbPath: logoPath,
      maxWidth: width,
      maxHeight: height,
      pixelRatio: pixelRatio,
      imageType: _type,
    );
    if (url.isEmpty) return null;
    final scaledWidth = width * pixelRatio;
    final scaledHeight = height * pixelRatio;
    final (memWidth, memHeight) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: scaledWidth.isFinite && scaledWidth > 0 ? scaledWidth.round() : 0,
      displayHeight: scaledHeight.isFinite && scaledHeight > 0 ? scaledHeight.round() : 0,
      imageType: _type,
    );
    return (
      url: url,
      provider: MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: memWidth, memHeight: memHeight),
    );
  }

  @override
  Widget build(BuildContext context) => OptimizedMediaImage(
    client: client,
    imagePath: logoPath,
    imageType: _type,
    width: width,
    height: height,
    fit: BoxFit.contain,
    alignment: Alignment.bottomLeft,
    placeholder: (context, _) => const SizedBox.shrink(),
    errorWidget: (context, _, _) => fallback,
  );
}

class _Shadowed extends StatelessWidget {
  const _Shadowed({required this.k, required this.child});

  final double k;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10 * k),
        boxShadow: [BoxShadow(color: const Color(0x99000000), blurRadius: 40 * k, offset: Offset(0, 14 * k))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(10 * k), child: child),
    );
  }
}

/// Slow crossfades through the episode's own frames, a new one every 3 s,
/// spread over the whole episode (Adrian, 2026-11-10), after 2 s of the cover.
class _TrickPlayFrames extends StatefulWidget {
  const _TrickPlayFrames({required this.source, required this.durationMs});

  final ScrubPreviewSource source;
  final int durationMs;

  @override
  State<_TrickPlayFrames> createState() => _TrickPlayFramesState();
}

class _TrickPlayFramesState extends State<_TrickPlayFrames> {
  static const _frames = 40;
  Timer? _timer;
  int _step = -1;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _next();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _next());
    });
  }

  void _next() {
    if (!mounted) return;
    setState(() => _step = (_step + 1) % _frames);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_step < 0 || widget.durationMs <= 0 || reduce) return const SizedBox.shrink();
    // Skip the first and last few seconds (logos, black).
    final span = widget.durationMs - 60000;
    final at = Duration(milliseconds: 30000 + (span > 0 ? span * _step ~/ (_frames - 1) : 0));
    final frame = widget.source.getFrame(at);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1400),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: frame == null
          ? const SizedBox.shrink()
          : KeyedSubtree(
              key: ValueKey<int>(_step),
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: 320,
                    height: 320 / frame.aspectRatio,
                    child: ScrubFrameView(frame: frame),
                  ),
                ),
              ),
            ),
    );
  }
}

class _EpisodeCaption extends StatelessWidget {
  const _EpisodeCaption({required this.item, required this.k});

  final MediaItem item;
  final double k;

  @override
  Widget build(BuildContext context) {
    final minutes = (item.durationMs ?? 0) > 0 ? t.upNext.minutes(count: (item.durationMs! / 60000).round()) : '';
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(12 * k, 26 * k, 12 * k, 10 * k),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xD9000000), Color(0x00000000)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'E${item.index ?? ''} · ${item.title ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 17 * k, color: Colors.white),
            ),
            if (minutes.isNotEmpty)
              Text(
                minutes,
                style: TextStyle(fontSize: 14 * k, color: const Color(0xFFBBBBBB)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.item, required this.k});

  final MediaItem item;
  final double k;

  @override
  Widget build(BuildContext context) {
    final duration = item.durationMs ?? 0;
    final offset = item.viewOffsetMs ?? 0;
    if (duration <= 0 || offset <= 0) return const SizedBox.shrink();
    final f = (offset / duration).clamp(0.0, 1.0);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(10 * k, 0, 10 * k, 8 * k),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3 * k),
          child: SizedBox(
            height: 5 * k,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0x4DFFFFFF)),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: f,
                  child: ColoredBox(color: Theme.of(context).colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpNextButton extends StatefulWidget {
  const _UpNextButton({
    required this.node,
    required this.k,
    required this.label,
    required this.showFocus,
    required this.onPressed,
    required this.onKey,
    this.icon,
    this.primary = false,
  });

  final FocusNode node;
  final double k;
  final String label;
  final IconData? icon;
  final bool primary;
  final bool showFocus;
  final VoidCallback onPressed;
  final KeyEventResult Function(KeyEvent event) onKey;

  @override
  State<_UpNextButton> createState() => _UpNextButtonState();
}

class _UpNextButtonState extends State<_UpNextButton> {
  bool _focused = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final k = widget.k;
    final accent = Theme.of(context).colorScheme.primary;
    final ring = _focused && widget.showFocus;
    final fg = widget.primary ? Colors.black : Colors.white;
    final fill = widget.primary
        ? (_hover ? Colors.white : const Color(0xFFF2F2F4))
        : Colors.white.withValues(alpha: _hover ? 0.25 : 0.14);
    return Focus(
      focusNode: widget.node,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey.isSelectKey) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return widget.onKey(event);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: ring ? 1.05 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 26 * k, vertical: 14 * k),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(8 * k),
                border: Border.all(color: ring ? accent : Colors.transparent, width: 3 * k),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    AppIcon(widget.icon!, fill: 1, size: 26 * k, color: fg),
                    SizedBox(width: 10 * k),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(fontSize: 21 * k, fontWeight: FontWeight.w600, color: fg),
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

class _UpNextCard extends StatefulWidget {
  const _UpNextCard({
    required this.node,
    required this.k,
    required this.width,
    required this.height,
    required this.selected,
    required this.showFocus,
    required this.onFocused,
    required this.onTap,
    required this.onKey,
    required this.child,
  });

  final FocusNode node;
  final double k;
  final double width;
  final double height;
  final bool selected;
  final bool showFocus;
  final void Function(BuildContext cardContext) onFocused;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;
  final Widget child;

  @override
  State<_UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<_UpNextCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final k = widget.k;
    final accent = Theme.of(context).colorScheme.primary;
    final ring = _focused && widget.showFocus;
    final border = ring
        ? accent
        : widget.selected
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.transparent;
    return Focus(
      focusNode: widget.node,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocused(context);
      },
      onKeyEvent: (node, event) => widget.onKey(event),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: ring ? 1.06 : 1,
            duration: const Duration(milliseconds: 160),
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8 * k),
                border: Border.all(color: border, width: 4 * k),
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(5 * k), child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}
