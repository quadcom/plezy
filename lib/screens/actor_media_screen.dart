import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
import '../i18n/app_locale_utils.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import 'base_media_list_detail_screen.dart';
import 'focusable_detail_screen_mixin.dart';
import 'media_detail/big_screen_layout.dart';
import '../utils/platform_detector.dart';
import '../mixins/grid_focus_node_mixin.dart';
import '../focus/focusable_action_bar.dart';
import '../media/catalog_item_ref.dart';
import '../media/media_hub.dart';
import '../models/plezyfin_titles.dart';
import '../services/jellyfin_client.dart';
import '../services/plezyfin_title_source.dart';
import '../widgets/hub_section.dart';
import '../focus/input_mode_tracker.dart';
import '../widgets/media_card.dart' show cardSubtitleRawKey;
import '../widgets/app_icon.dart';
import '../widgets/collapsible_text.dart';
import 'catalog_item_detail_screen.dart';

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

  /// Fork: bio and the "Known for" row from PlezyFin (PLAN_PFN_114,
  /// local/plans/person-page.md); null until loaded, and for facets.
  PlezyFinPersonPage? _personPage;
  final _knownForFocusMemory = HubFocusMemory();

  /// Remote order on TV (local/plans/person-page-tv.md): bio -> Known for ->
  /// library grid, Up and Down one step at a time, each scrolled into view.
  final _knownForKey = GlobalKey<HubSectionState>();
  final _bioFocusNode = FocusNode(debugLabel: 'person_bio');
  final _bioKey = GlobalKey();

  bool get _hasKnownFor => _personPage?.knownFor.isNotEmpty ?? false;

  void _focusKnownFor() {
    setState(() => isAppBarFocused = false);
    _knownForKey.currentState?.requestFocusFromMemory();
  }

  void _focusBio() {
    _bioFocusNode.requestFocus();
    final context = _bioKey.currentContext;
    if (context != null) unawaited(Scrollable.ensureVisible(context, alignment: 0.2));
  }

  /// Up from the top section: the page scrolls back to the top, focus stays.
  void _showTop() =>
      unawaited(scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));

  /// The first section the remote lands on: Known for, else the library grid.
  void _focusFirstSection() {
    if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;
    if (_hasKnownFor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusKnownFor();
      });
    } else {
      autoFocusFirstItemAfterLoad();
    }
  }

  void _upFromKnownFor() {
    if (_personPage?.person?.biography != null && PlatformDetector.isTV()) {
      _focusBio();
    } else {
      _showTop();
    }
  }

  void _downFromKnownFor() {
    if (hasItems) {
      setState(() => isAppBarFocused = false);
      firstItemFocusNode.requestFocus();
    }
  }

  void _upFromGrid() {
    if (_hasKnownFor) {
      _focusKnownFor();
    } else if (_personPage?.person?.biography != null && PlatformDetector.isTV()) {
      _focusBio();
    } else {
      _showTop();
    }
  }

  void _downFromBio() {
    if (_hasKnownFor) {
      _focusKnownFor();
    } else {
      _downFromKnownFor();
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.facet == null && widget.personId.isNotEmpty) unawaited(_loadPersonPage());
  }

  /// One call per page open; a server without the route, or any failure,
  /// leaves today's page.
  Future<void> _loadPersonPage() async {
    final client = _mediaClient;
    if (client is! JellyfinClient) return;
    try {
      final page = await client.plezyFinPerson(widget.personId);
      if (!mounted || page == null) return;
      // The grid may have taken the remote's focus first; Known for comes first.
      final gridHadFirstFocus = firstItemFocusNode.hasFocus;
      setState(() => _personPage = page);
      if (gridHadFirstFocus || FocusManager.instance.primaryFocus == null || !hasItems) _focusFirstSection();
    } catch (e) {
      appLogger.d('PlezyFin person page failed for ${widget.personId}', error: e);
    }
  }

  /// "Known for" as hub cards: year, role and a TV tag under each poster.
  MediaHub? _knownForHub() {
    final page = _personPage;
    if (page == null) return null;
    final titles = page.knownFor;
    if (titles.isEmpty) return null;
    return MediaHub(
      id: 'person_known_for',
      title: t.outsideTitles.knownFor,
      type: 'mixed',
      items: [
        for (final title in titles)
          () {
            final item = title.toCatalogItem().toMediaItem();
            final line = [
              if (title.year case final year?) '$year',
              if (title.character case final character? when character.isNotEmpty)
                character
              else if (title.job case final job? when job.isNotEmpty)
                job,
              if (title.kind == MediaKind.show) t.outsideTitles.tvTag,
            ].join(' · ');
            return item.copyWith(raw: {...?item.raw, cardSubtitleRawKey: line});
          }(),
      ],
      size: titles.length,
    );
  }

  void _openKnownFor(MediaItem item) {
    final catalog = item.catalogItem;
    final client = _mediaClient;
    if (catalog == null || client is! JellyfinClient) return;
    final page = _personPage;
    PlezyFinRequestState? state;
    for (final title in page?.credits ?? const <PlezyFinTitle>[]) {
      if (title.tmdbId == catalog.ids.tmdb && title.kind == catalog.kind) state = title.requestState;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CatalogItemDetailScreen(
            item: catalog,
            plezyFin: PlezyFinTitleSource(client, canRequest: page?.canRequest ?? false),
            requestState: state,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _bioFocusNode.dispose();
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
        _focusFirstSection();
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
        // Big screens: in from the edge like the item page's title
        // (local/plans/detail-left-edge.md).
        padding: EdgeInsets.symmetric(horizontal: big?.titleLeft ?? 16, vertical: 8),
        child: DetailZoom(
          scale: big?.personHeaderZoom ?? 1,
          alignment: Alignment.topLeft,
          child: Row(
            // With PlezyFin's details the tall photo and the bio line up at the top.
            crossAxisAlignment: _personPage?.person == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (widget.facetIcon case final icon?)
                CircleAvatar(
                  radius: 40,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
                )
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(_personPage?.person == null ? _photoSize / 2 : 12),
                  child: widget.actorThumb == null && _personPage?.person?.profileUrl != null
                      ? Image.network(
                          _personPage!.person!.profileUrl!,
                          width: _photoSize,
                          height: _photoHeight,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => SizedBox(
                            width: _photoSize,
                            height: _photoHeight,
                            child: const Icon(Symbols.person_rounded),
                          ),
                        )
                      : OptimizedMediaImage(
                          client: _mediaClient,
                          imagePath: widget.actorThumb,
                          width: _photoSize,
                          height: _photoHeight,
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
                    ..._personFacts(theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// With PlezyFin's details the photo becomes a large portrait headshot
  /// (Adrian, 2026-11-15: "maybe the headshot could be bigger"); a round
  /// 80 otherwise.
  double get _photoSize => _personPage?.person == null ? 80 : 180;
  double get _photoHeight => _personPage?.person == null ? 80 : 270;

  /// Born / died with age, birthplace, known for, and the whole bio (Adrian,
  /// 2026-11-15: "we don't need to collapse the bio information").
  List<Widget> _personFacts(ThemeData theme) {
    final person = _personPage?.person;
    if (person == null) return const [];
    final locale = LocaleSettings.currentLocale.intlLocaleName;
    String day(DateTime date) => DateFormat.yMMMMd(locale).format(date);
    final age = person.ageOn(DateTime.now());
    final facts = [
      if (person.deathday case final died?)
        t.outsideTitles.died(date: day(died), age: age ?? '?')
      else if (person.birthday case final born?)
        age == null ? t.outsideTitles.born(date: day(born)) : t.outsideTitles.bornAge(date: day(born), age: age),
      if (person.placeOfBirth case final place?) t.outsideTitles.from(place: place),
      ?person.knownForDepartment,
    ];
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return [
      if (facts.isNotEmpty) ...[const SizedBox(height: 6), Text(facts.join('  ·  '), style: muted)],
      if (person.biography case final bio?) ...[
        const SizedBox(height: 10),
        ConstrainedBox(
          key: _bioKey,
          constraints: const BoxConstraints(maxWidth: 900),
          // TV: five lines and "More" (OK opens the rest), so the rows stay on
          // screen; PC and tablets show it all (Adrian, 2026-11-15).
          child: PlatformDetector.isTV()
              ? CollapsibleText(
                  text: bio,
                  maxLines: 5,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  focusNode: _bioFocusNode,
                  skipTraversal: false,
                  onNavigateUp: _showTop,
                  onNavigateDown: _downFromBio,
                  onNavigateLeft: () {},
                  onNavigateRight: () {},
                )
              : Text(bio, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
        ),
      ],
    ];
  }

  /// The page's left edge: the header's, which Known for and the library grid
  /// share (local/plans/person-page-tv.md).
  double _edge(DetailBigScreenLayout? big) => big?.titleLeft ?? 16;

  /// "In your library", drawn like the Known for row's heading (icon + title).
  Widget _sectionHeading(BuildContext context, String text, DetailBigScreenLayout? big) {
    final isTv = PlatformDetector.isTV();
    final style = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontSize: isTv ? 26 : null, fontWeight: isTv ? FontWeight.w700 : null);
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(_edge(big), 16, 16, 4),
        child: Row(
          children: [
            AppIcon(Symbols.video_library_rounded, fill: 1, size: isTv ? 28 : null),
            SizedBox(width: isTv ? 12 : 8),
            Flexible(
              child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final big = _bigLayout(context);
    final knownFor = _knownForHub();
    return buildDetailScaffold(
      slivers: [
        CustomAppBar(title: Text(widget.actorName), pinned: true, actions: buildFocusableAppBarActions()),
        _buildActorHeader(),
        // Fork: films and shows they're known for that aren't in the library
        // (local/plans/person-page.md). Above the library grid, which can run
        // long; its own row so it never pushes the library off the page.
        if (knownFor != null)
          SliverToBoxAdapter(
            child: Padding(
              // Inset row: heading and first card start at the page's edge,
              // like the header and the library grid.
              padding: EdgeInsets.only(left: _edge(big), top: 8),
              child: HubSection(
                key: _knownForKey,
                hub: knownFor,
                focusMemory: _knownForFocusMemory,
                icon: Symbols.movie_rounded,
                inset: true,
                cardWidth: big?.posterRowCardWidth,
                onItemTap: _openKnownFor,
                onVerticalNavigation: (isUp) {
                  if (isUp) {
                    _upFromKnownFor();
                  } else {
                    _downFromKnownFor();
                  }
                  return true;
                },
              ),
            ),
          ),
        if (knownFor != null && hasItems) _sectionHeading(context, t.outsideTitles.inYourLibrary, big),
        ...buildStateSlivers(),
        if (hasItems)
          buildSparseFocusableGrid(
            totalItems: totalSize,
            itemAt: (index) => loadedItems[index],
            onRefresh: updateItem,
            onSkeletonVisible: (index) => ensureIndexLoaded(index, pageSize: _pageSize),
            densityOverride: big?.personGridDensity(isTv: PlatformDetector.isTV()),
            // The grid keeps the header's edge (the header is 8 further in by default too).
            padding: big == null ? null : EdgeInsets.symmetric(horizontal: big.titleLeft - 8, vertical: 8),
            onNavigateUpFromFirstRow: _upFromGrid,
          ),
      ],
    );
  }
}
