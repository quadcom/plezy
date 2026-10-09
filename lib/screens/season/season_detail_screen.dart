import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../media/episode_collection.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_item_types.dart';
import '../../media/media_server_client.dart';
import '../../media/media_trailer.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
import '../../utils/platform_detector.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/video_player_navigation.dart';
import '../../widgets/app_bar_back_button.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/cycling_media_backdrop.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/media_rail/rail_parts.dart';
import '../../widgets/optimized_media_image.dart';

/// Whether seasons open on [SeasonDetailScreen] (the fork's default) rather
/// than as tabs on the show screen.
bool seasonPagesEnabled() => SettingsService.instanceOrNull?.read(SettingsService.seasonPages) ?? true;

/// One season of a show laid out like the Master Class course screen: the
/// season's header, its episodes in a rail, and the selected episode's
/// description below. Fork-only; Adrian, 2026-10-09
/// (local/plans/season-rail-layout.md).
///
/// The background cycles through the show's fan art. Plex keeps one backdrop
/// per show, so when there is only one the episode stills join the cycle.
/// Episodes play through the normal player, so the next one follows the
/// Auto-Play Next Episode and Play Next Countdown settings.
class SeasonDetailScreen extends StatefulWidget {
  const SeasonDetailScreen({
    super.key,
    required this.metadata,
    this.initialSeasonId,
    this.initialSeasonIndex,
    this.initialEpisodeId,
    this.wholeShow = false,
  });

  /// The season, or its show (possibly a stand-in built from an episode).
  final MediaItem metadata;

  /// Which season of the show [metadata] to open. With neither, the season of
  /// the show's next episode.
  final String? initialSeasonId;
  final int? initialSeasonIndex;

  /// Episode to select first, e.g. when opened from that episode.
  final String? initialEpisodeId;

  /// Every episode of the show in one rail: shows the server says to flatten
  /// (a single season, or Plex's "hide seasons").
  final bool wholeShow;

  @override
  State<SeasonDetailScreen> createState() => _SeasonDetailScreenState();
}

class _SeasonDetailScreenState extends State<SeasonDetailScreen> {
  static const _pageSize = 200;
  static const _artInterval = Duration(seconds: 9);
  static const _artFade = Duration(milliseconds: 2500);

  /// How many pages to look through for [SeasonDetailScreen.initialEpisodeId].
  static const _maxInitialPages = 10;

  MediaItem? _show;
  MediaItem? _season;
  List<MediaItem> _episodes = const [];
  int _total = 0;
  MediaItem? _onDeck;
  MediaItem? _trailer;
  bool _loading = true;
  bool _failed = false;
  bool _loadingMore = false;
  int _selected = 0;
  bool _firstLoad = true;

  final _primaryFocus = FocusNode(debugLabel: 'Season:Primary');
  final _moreMenuKey = GlobalKey<MediaContextMenuState>();
  final _railController = ScrollController();
  final List<FocusNode> _episodeFocus = [];

  MediaServerClient? get _client => context.tryGetMediaClientForServer(serverIdOrNull(widget.metadata.serverId));

  /// What the header describes: the season, or the show when it is one rail.
  MediaItem get _subject => _season ?? _show ?? widget.metadata;

  bool get _hasMore => _episodes.length < _total;

  @override
  void initState() {
    super.initState();
    _railController.addListener(_onRailScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _railController.dispose();
    _primaryFocus.dispose();
    for (final node in _episodeFocus) {
      node.dispose();
    }
    super.dispose();
  }

  MediaItem _stamp(MediaItem item) => item.copyWith(
    serverId: item.serverId ?? widget.metadata.serverId,
    serverName: item.serverName ?? widget.metadata.serverName,
    libraryId: item.libraryId ?? widget.metadata.libraryId,
    libraryTitle: item.libraryTitle ?? widget.metadata.libraryTitle,
  );

  Future<List<MediaItem>> _fetchExtras(MediaServerClient client, String showId) async {
    try {
      return await client.fetchExtras(showId);
    } catch (e) {
      appLogger.d('Season page: extras for $showId failed to load', error: e);
      return const [];
    }
  }

  Future<LibraryPage<MediaItem>> _fetchPage(
    MediaServerClient client,
    MediaItem? show,
    MediaItem? season,
    int start,
  ) async {
    final LibraryPage<MediaItem> page;
    if (season != null && show != null) {
      page = await fetchSeasonEpisodePage(client, show: show, season: season, start: start, size: _pageSize);
    } else if (season != null) {
      page = await client.fetchChildrenPage(season.id, start: start, size: _pageSize);
    } else {
      page = await client.fetchPlayableDescendantsPage(show?.id ?? widget.metadata.id, start: start, size: _pageSize);
    }
    return LibraryPage<MediaItem>(
      items: [
        for (final episode in page.items)
          _stamp(
            episode.copyWith(
              parentId: episode.parentId ?? season?.id,
              parentIndex: episode.parentIndex ?? season?.index,
              grandparentId: episode.grandparentId ?? show?.id,
              grandparentTitle: episode.grandparentTitle ?? show?.title,
            ),
          ),
      ],
      totalCount: page.totalCount,
      offset: page.offset,
    );
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      MediaItem? season;
      String? showId;
      if (widget.metadata.isSeason) {
        season = _stamp((await client.fetchItemWithOnDeck(widget.metadata.id)).item ?? widget.metadata);
        showId = season.parentId ?? widget.metadata.parentId;
      } else {
        showId = widget.metadata.id;
      }

      MediaItem? show;
      MediaItem? onDeck;
      var extras = const <MediaItem>[];
      if (showId != null) {
        final (result, fetchedExtras) = await (client.fetchItemWithOnDeck(showId), _fetchExtras(client, showId)).wait;
        show = _stamp(
          result.item ?? (widget.metadata.isSeason ? widget.metadata.copyWith(id: showId) : widget.metadata),
        );
        onDeck = result.onDeckEpisode == null ? null : _stamp(result.onDeckEpisode!);
        extras = fetchedExtras;
      }

      if (season == null && !widget.wholeShow && show != null) {
        final seasons = [for (final s in await client.fetchChildren(show.id)) _stamp(s)];
        if (seasons.isNotEmpty) {
          season =
              seasons[preferredSeasonIndex(
                seasons,
                initialSeasonId: _season?.id ?? widget.initialSeasonId,
                initialSeasonIndex: widget.initialSeasonIndex,
                onDeckEpisode: onDeck,
              )];
        }
      }

      // On a reload, fetch as many episodes as were showing, so the
      // selection stays put in a long season.
      final want = _firstLoad ? 0 : _episodes.length;
      final wantedId = _firstLoad ? widget.initialEpisodeId : null;
      var page = await _fetchPage(client, show, season, 0);
      final episodes = [...page.items];
      var total = page.totalCount;
      var pages = 1;
      while (episodes.length < total &&
          page.items.isNotEmpty &&
          (episodes.length < want ||
              (wantedId != null && pages < _maxInitialPages && !episodes.any((e) => e.id == wantedId)))) {
        page = await _fetchPage(client, show, season, episodes.length);
        episodes.addAll(page.items);
        total = page.totalCount;
        pages++;
      }
      if (!mounted) return;

      final trailer = show == null
          ? null
          : pickTrailer(show, extras)?.copyWith(serverId: show.serverId, serverName: show.serverName);
      setState(() {
        _show = show;
        _season = season;
        _episodes = episodes;
        _total = total < episodes.length ? episodes.length : total;
        _onDeck = onDeck;
        _trailer = trailer;
        _selected = _firstLoad
            ? _initialSelection(episodes, onDeck)
            : _selected.clamp(0, episodes.isEmpty ? 0 : episodes.length - 1);
        _loading = false;
        _failed = false;
        _syncEpisodeFocus(episodes.length);
      });
      if (_firstLoad) {
        _firstLoad = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _primaryFocus.requestFocus();
        });
      }
    } catch (e, st) {
      appLogger.w('Season page for ${widget.metadata.id} failed to load', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _episodes.isEmpty;
      });
    }
  }

  Future<void> _loadMore() async {
    final client = _client;
    if (client == null || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await _fetchPage(client, _show, _season, _episodes.length);
      if (!mounted) return;
      setState(() {
        _episodes = [..._episodes, ...page.items];
        _total = page.items.isEmpty ? _episodes.length : page.totalCount;
        _syncEpisodeFocus(_episodes.length);
      });
    } catch (e) {
      appLogger.d('Season page: more episodes failed to load', error: e);
    } finally {
      _loadingMore = false;
    }
  }

  void _onRailScroll() {
    if (_railController.position.extentAfter < 800) unawaited(_loadMore());
  }

  int _initialSelection(List<MediaItem> episodes, MediaItem? onDeck) {
    if (episodes.isEmpty) return 0;
    final wanted = widget.initialEpisodeId;
    if (wanted != null) {
      final i = episodes.indexWhere((e) => e.id == wanted);
      if (i >= 0) return i;
    }
    return _resumeIndex(episodes, onDeck) ?? 0;
  }

  /// The episode to resume: the server's next episode when it is in this
  /// rail, else the first one not yet watched. Null when all are watched.
  static int? _resumeIndex(List<MediaItem> episodes, MediaItem? onDeck) {
    if (onDeck != null) {
      final i = episodes.indexWhere((e) => e.id == onDeck.id);
      if (i >= 0) return i;
    }
    final i = episodes.indexWhere((e) => !e.isWatched);
    return i >= 0 ? i : null;
  }

  void _syncEpisodeFocus(int count) {
    while (_episodeFocus.length < count) {
      _episodeFocus.add(FocusNode(debugLabel: 'Season:Episode${_episodeFocus.length + 1}'));
    }
    while (_episodeFocus.length > count) {
      _episodeFocus.removeLast().dispose();
    }
  }

  void _select(int i) {
    if (_selected != i) setState(() => _selected = i);
    if (i >= _episodes.length - 5) unawaited(_loadMore());
  }

  Future<void> _play(MediaItem episode) async {
    await navigateToVideoPlayerWithRefresh(
      context,
      metadata: episode,
      onRefresh: () => unawaited(_load()),
      isLaunchCurrent: () => mounted,
    );
  }

  void _openMoreMenu() => _moreMenuKey.currentState?.showContextMenu(context);

  void _focusSelectedEpisode() {
    if (_selected < _episodeFocus.length) _episodeFocus[_selected].requestFocus();
  }

  bool get _started => _episodes.any((e) => e.isWatched || (e.viewOffsetMs ?? 0) > 0);

  /// Badges read "S2 · E3" when one rail holds several seasons.
  bool get _mixedSeasons => _season == null && _episodes.map((e) => e.parentIndex).toSet().length > 1;

  int _numberOf(MediaItem episode, int i) => episode.index ?? i + 1;

  String _badgeFor(MediaItem episode, int i) {
    final number = _numberOf(episode, i);
    final season = episode.parentIndex;
    return _mixedSeasons && season != null ? 'S$season · E$number' : '$number';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = _client;
    final hideSpoilers = SettingsService.instanceOrNull?.read(SettingsService.hideSpoilers) ?? false;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final show = _show ?? widget.metadata;
          final fanArt = show.heroBackdropPaths;
          final stills = [
            for (final episode in _episodes)
              if (episode.thumbPath?.isNotEmpty == true && !(hideSpoilers && episode.shouldHideSpoiler))
                episode.thumbPath!,
          ];
          final images = fanArt.length > 1 ? fanArt : [...fanArt, ...stills];
          return Stack(
            children: [
              Positioned.fill(
                child: CyclingMediaBackdrop(
                  mediaKey: '${show.globalKey}:${images.length}',
                  imagePaths: images,
                  fallbackImagePaths: [?_subject.thumbPath, ?show.thumbPath],
                  client: client,
                  width: size.width,
                  height: size.height,
                  fallbackColor: theme.colorScheme.surface,
                  rotationInterval: _artInterval,
                  fadeDuration: _artFade,
                ),
              ),
              Positioned.fill(child: RailScrim(color: theme.colorScheme.surface)),
              SafeArea(child: _buildBody(context, client, size, hideSpoilers)),
              if (!PlatformDetector.isTV())
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: AppBarBackButton(onPressed: () => Navigator.pop(context)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, MediaServerClient? client, Size size, bool hideSpoilers) {
    final theme = Theme.of(context);
    if (_loading && _episodes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(child: Text(t.seasonPage.loadFailed, style: theme.textTheme.titleMedium));
    }
    final wide = size.width >= 700;
    final pad = EdgeInsets.fromLTRB(wide ? 48 : 20, wide ? 40 : 56, wide ? 48 : 20, 32);
    final ownSummary = _subject.summary;
    final summary = ownSummary != null && ownSummary.isNotEmpty ? ownSummary : _show?.summary;
    return SingleChildScrollView(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, client, size, wide),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Text(
                summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            t.libraries.groupings.episodes,
            style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 10),
          _buildRail(context, client, size, wide, hideSpoilers),
          if (_episodes.isNotEmpty) ...[const SizedBox(height: 16), _buildNotes(context, hideSpoilers)],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, MediaServerClient? client, Size size, bool wide) {
    final theme = Theme.of(context);
    final subject = _subject;
    final showTitle = _show?.title;
    final overline = _season != null && showTitle != null && showTitle.isNotEmpty ? showTitle : null;
    final title = _season != null ? (_season!.title ?? _season!.displayTitle) : (_show?.title ?? subject.displayTitle);
    final posterWidth = (size.width * 0.13).clamp(84.0, 200.0);
    final totalMs = _hasMore ? 0 : _episodes.fold<int>(0, (sum, e) => sum + (e.durationMs ?? 0));
    final year = subject.year ?? _show?.year;
    final rating = _show?.contentRating;
    final meta = [
      if (year != null) '$year',
      if (rating != null && rating.isNotEmpty) rating,
      t.seasonPage.episodeCount(n: _total),
      if (totalMs > 0) formatDurationTextual(totalMs),
    ].join('  ·  ');
    final watched = _hasMore
        ? (subject.viewedLeafCount ?? _episodes.where((e) => e.isWatched).length)
        : _episodes.where((e) => e.isWatched).length;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (overline != null)
          Text(
            overline.toUpperCase(),
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          title,
          style: (wide ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          meta,
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
        ),
        if (_total > 0) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (watched / _total).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.seasonPage.episodesWatched(watched: watched, total: _total),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
        ],
        const SizedBox(height: 14),
        _buildButtons(context),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: posterWidth,
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: OptimizedMediaImage.poster(client: client, imagePath: subject.thumbPath ?? _show?.thumbPath),
            ),
          ),
        ),
        SizedBox(width: wide ? 32 : 16),
        Expanded(child: info),
      ],
    );
  }

  Widget _buildButtons(BuildContext context) {
    final trailer = _trailer;
    final menuItem = _season ?? _show;
    final resume = _resumeIndex(_episodes, _onDeck);
    final started = _started;
    final target = _episodes.isEmpty ? null : _episodes[resume ?? 0];
    final label = started && resume != null && target != null
        ? t.seasonPage.resumeEpisode(number: _numberOf(target, resume), title: target.title ?? '')
        : t.common.play;
    void playPrimary() => unawaited(_play(target!));
    void startOver() => unawaited(_play(_episodes.first.copyWith(viewOffsetMs: 0)));
    void playTrailer() => unawaited(navigateToVideoPlayer(context, metadata: trailer!, isLaunchCurrent: () => mounted));
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (target != null)
          FocusableButton(
            focusNode: _primaryFocus,
            useBackgroundFocus: true,
            onPressed: playPrimary,
            onNavigateDown: _focusSelectedEpisode,
            child: FilledButton.icon(
              onPressed: playPrimary,
              icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
              label: Text(label, overflow: TextOverflow.ellipsis),
            ),
          ),
        if (started)
          FocusableButton(
            useBackgroundFocus: true,
            onPressed: startOver,
            onNavigateDown: _focusSelectedEpisode,
            child: OutlinedButton.icon(
              onPressed: startOver,
              icon: const AppIcon(Symbols.replay_rounded, fill: 1),
              label: Text(t.seasonPage.startOver),
            ),
          ),
        if (trailer != null)
          FocusableButton(
            focusNode: target == null ? _primaryFocus : null,
            useBackgroundFocus: true,
            onPressed: playTrailer,
            onNavigateDown: _focusSelectedEpisode,
            child: OutlinedButton.icon(
              onPressed: playTrailer,
              icon: const AppIcon(Symbols.theaters_rounded, fill: 1),
              label: Text(t.seasonPage.watchTrailer),
            ),
          ),
        if (menuItem != null)
          MediaContextMenu(
            key: _moreMenuKey,
            item: menuItem,
            onRefresh: (_) => unawaited(_load()),
            onListRefresh: () => unawaited(_load()),
            child: FocusableButton(
              focusNode: target == null && trailer == null ? _primaryFocus : null,
              useBackgroundFocus: true,
              onPressed: _openMoreMenu,
              onNavigateDown: _focusSelectedEpisode,
              child: IconButton.filledTonal(onPressed: _openMoreMenu, icon: const AppIcon(Symbols.more_vert_rounded)),
            ),
          ),
      ],
    );
  }

  Widget _buildRail(BuildContext context, MediaServerClient? client, Size size, bool wide, bool hideSpoilers) {
    final cardWidth = (size.width * (wide ? 0.2 : 0.55)).clamp(150.0, 320.0);
    final stillHeight = cardWidth * 9 / 16;
    return SizedBox(
      height: stillHeight + 60,
      child: ListView.separated(
        controller: _railController,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final episode = _episodes[i];
          return RailItemCard(
            item: episode,
            badge: _badgeFor(episode, i),
            semanticLabel: t.seasonPage.episodeHeading(number: _numberOf(episode, i), title: episode.title ?? ''),
            blurStill: hideSpoilers && episode.shouldHideSpoiler,
            onRefresh: (_) => unawaited(_load()),
            onListRefresh: () => unawaited(_load()),
            client: client,
            width: cardWidth,
            selected: i == _selected,
            focusNode: i < _episodeFocus.length ? _episodeFocus[i] : null,
            onFocused: () {
              // Remote and keyboard focus picks the episode. A tap focuses
              // too, but that is left to onSelect so it isn't two taps.
              if (InputModeTracker.currentMode != InputMode.keyboard) return;
              _select(i);
            },
            onNavigateUp: () => _primaryFocus.requestFocus(),
            onSelect: () {
              // Remote and keyboard: focus already picked the episode, so OK
              // plays it. Touch and mouse: the first tap picks it (its
              // description shows below), a second tap plays it.
              if (InputModeTracker.currentMode == InputMode.keyboard || _selected == i) {
                _select(i);
                unawaited(_play(episode));
              } else {
                _select(i);
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildNotes(BuildContext context, bool hideSpoilers) {
    final episode = _episodes[_selected];
    final heading = t.seasonPage.episodeHeading(number: _numberOf(episode, _selected), title: episode.title ?? '');
    final aired = episode.originallyAvailableAt;
    final parts = [
      _mixedSeasons && episode.parentIndex != null ? '${_badgeFor(episode, _selected)}  ·  $heading' : heading,
      if (episode.durationMs != null) formatDurationTextual(episode.durationMs!),
      if (aired != null && aired.isNotEmpty) formatFullDate(aired),
    ];
    final hidden = hideSpoilers && episode.shouldHideSpoiler;
    return RailNotesPanel(heading: parts.join('  ·  '), body: hidden ? t.seasonPage.spoilerHidden : episode.summary);
  }
}
