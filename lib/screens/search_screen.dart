import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../exceptions/media_server_exceptions.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/account_preferences.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_item_merge.dart';
import '../media/search_scope.dart';
import '../mixins/debounced_media_search.dart';
import '../mixins/mounted_set_state_mixin.dart';
import '../mixins/refreshable.dart';
import '../providers/account_preferences_controller.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/data_aggregation_service.dart';
import '../services/settings_service.dart';
import '../services/voice_search_service.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/snackbar_helper.dart';
import '../utils/media_server_http_client.dart';
import '../utils/search_relevance.dart';
import '../utils/search_result_sections.dart';
import '../widgets/app_menu.dart';
import '../widgets/cast_member_strip.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/focusable_filter_chip.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/media_card_sliver_layout.dart';
import '../widgets/search_input_field.dart';
import '../widgets/search_scope_panel.dart';
import '../widgets/voice_listening_dialog.dart';
import '../widgets/focusable_media_card.dart';
import '../widgets/focusable_tab_chip.dart';
import '../widgets/settings_builder.dart';
import '../focus/input_mode_tracker.dart';
import '../utils/focus_utils.dart';
import 'actor_media_screen.dart';
import 'libraries/state_messages.dart';
import 'main_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Where the "Search in" ticks live for an account that cannot store them
  /// on its server (anything but Jellyfin): this app run only.
  static Set<SearchScopeKind>? _deviceScope;

  @visibleForTesting
  static void resetDeviceScopeForTesting() => _deviceScope = null;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with
        Refreshable,
        ManualRefreshable,
        FullRefreshable,
        SearchInputFocusable,
        FocusableTab,
        MountedSetStateMixin,
        DebouncedMediaSearch {
  String? _focusResultsForQuery;
  final _tvTextInputController = TvTextInputController();
  AbortController? _activeSearchAbort;
  ({
    String query,
    SearchAggregationResult? result,
    Set<String> ownServerIds,
    List<SearchFacetMatch> facets,
    Set<SearchScopeKind> scope,
  })?
  _pendingSearchOutcome;

  /// The "Search in" ticks the user changed on this screen, until the screen
  /// is reset; null means "as the account (or this device) has them".
  Set<SearchScopeKind>? _chosenScope;

  /// People, genres, studios, keywords and years matching the visible query,
  /// own servers first, one per name; and the kinds that query searched, so a
  /// ticked kind with no match can say so.
  List<SearchFacetMatch> _facetMatches = const [];
  Set<SearchScopeKind> _searchedScope = const {};
  final Map<SearchScopeKind, GlobalKey<CastMemberStripState>> _peopleStripKeys = {};
  final Map<SearchScopeKind, List<FocusNode>> _facetChipNodes = {};

  /// Servers the user owns (or administers) among those that answered the
  /// visible query. Their libraries' sections come before shared servers'.
  Set<String> _ownServerIds = const {};

  /// Media-kind filter over the current results. Chips and the filtered view
  /// derive from [_searchCandidates] — the pre-rank pool behind the ranked
  /// [searchResults] — so a kind ranked out of the "All" top-N still gets a
  /// chip, and selecting it shows everything the servers returned for it.
  MediaKind? _selectedKind;
  List<MediaItem> _searchCandidates = const [];
  List<MediaKind> _candidateKinds = const [];
  List<MediaItem>? _rankedKindResults;
  late final FocusNode _allChipFocusNode = FocusNode(debugLabel: 'SearchKindChipAll');
  final Map<MediaKind, FocusNode> _kindChipFocusNodes = {};

  HiddenLibrariesProvider? _hiddenLibraries;
  Set<String> _lastSeenHiddenKeys = const {};

  /// A voice input app answers on this device, so the field shows a mic.
  bool _voiceSearchAvailable = false;
  bool _voiceSearchActive = false;
  final FocusNode _voiceFocusNode = FocusNode(debugLabel: 'SearchVoice');

  /// On TV the mic is the first thing highlighted (Adrian, 2026-10-31).
  bool get _voiceFirst => _voiceSearchAvailable && PlatformDetector.isTV();

  /// Whether the voice check has answered. On TV nothing takes focus before
  /// it does: focusing the field first popped Plezy's keyboard open over the
  /// mic (Adrian, 2026-10-31: "The search keyboard should only be displayed
  /// when the input is in focus").
  bool _voiceChecked = false;
  bool _focusWhenVoiceChecked = false;

  /// Where focus lands when Search opens or the user comes back up to the bar.
  void _focusSearchBar() {
    if (PlatformDetector.isTV() && !_voiceChecked) {
      _focusWhenVoiceChecked = true;
      return;
    }
    (_voiceFirst ? _voiceFocusNode : searchFocusNode).requestFocus();
  }

  @override
  void initState() {
    super.initState();
    if (PlatformDetector.isTV()) {
      _focusWhenVoiceChecked = true;
    } else {
      FocusUtils.requestFocusAfterBuild(this, searchFocusNode);
    }
    unawaited(_bindHiddenLibraries());
    unawaited(_checkVoiceSearch());
  }

  Future<void> _checkVoiceSearch() async {
    final available = await VoiceSearchService.isAvailable();
    if (!mounted) return;
    setState(() {
      _voiceSearchAvailable = available;
      _voiceChecked = true;
    });
    if (!_focusWhenVoiceChecked) return;
    _focusWhenVoiceChecked = false;
    // The mic exists from this frame on; focus it (or the field without one).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusSearchBar();
    });
  }

  /// Plezy's own listening card over Android's speech service (Google TV's
  /// voice screen heard the words but never handed them back, 2026-10-31).
  /// What was said runs as a submitted query.
  Future<void> _startVoiceSearch() async {
    if (_voiceSearchActive) return;
    _voiceSearchActive = true;
    try {
      _tvTextInputController.closeTextInput();
      final result = await showVoiceListeningDialog(context, prompt: t.search.voicePrompt);
      if (!mounted) return;
      final text = result.text;
      if (result.outcome != VoiceSearchOutcome.heard || text == null) {
        // Back or Cancel says nothing; a miss or a refused mic gets a reason.
        if (result.outcome == VoiceSearchOutcome.permissionDenied) {
          showAppSnackBar(context, t.search.voiceNeedsMic);
        } else if (result.outcome == VoiceSearchOutcome.failed) {
          showAppSnackBar(context, t.search.voiceNoMatch);
        }
        if (_voiceFirst) _voiceFocusNode.requestFocus();
        return;
      }
      submitSearchQuery(text);
    } finally {
      _voiceSearchActive = false;
    }
  }

  @override
  void dispose() {
    _hiddenLibraries?.removeListener(_onHiddenLibrariesChanged);
    _allChipFocusNode.dispose();
    _voiceFocusNode.dispose();
    for (final node in _kindChipFocusNodes.values) {
      node.dispose();
    }
    for (final nodes in _facetChipNodes.values) {
      for (final node in nodes) {
        node.dispose();
      }
    }
    super.dispose();
  }

  /// Re-run the visible query when a library is hidden or unhidden while
  /// results are on screen. The listener is attached only after the provider
  /// has hydrated, so its initial load notification cannot race the first
  /// query — which awaits that same hydration — into running twice.
  Future<void> _bindHiddenLibraries() async {
    final hiddenLibraries = context.read<HiddenLibrariesProvider>();
    await hiddenLibraries.ensureInitialized();
    if (!mounted) return;
    _lastSeenHiddenKeys = Set.of(hiddenLibraries.hiddenLibraryKeys);
    _hiddenLibraries = hiddenLibraries..addListener(_onHiddenLibrariesChanged);
  }

  void _onHiddenLibrariesChanged() {
    final hiddenLibraries = _hiddenLibraries;
    if (hiddenLibraries == null || !mounted) return;
    final currentKeys = hiddenLibraries.hiddenLibraryKeys;
    if (currentKeys.length == _lastSeenHiddenKeys.length && currentKeys.containsAll(_lastSeenHiddenKeys)) {
      return;
    }
    _lastSeenHiddenKeys = Set.of(currentKeys);
    final query = searchController.text.trim();
    if (query.isEmpty || !hasSearched) return;
    unawaited(runSearch(query));
  }

  @override
  String get searchDebugLabel => 'Search';

  /// The ticks in force: this screen's latest change, else the account's
  /// (Jellyfin keeps them on the server), else this device's, else the
  /// defaults. Reads only cached values, never the network.
  Set<SearchScopeKind> _scopeFor(AccountPreferencesController? accounts) {
    final chosen = _chosenScope;
    if (chosen != null) return chosen;
    if (accounts != null && accounts.activeSupports(AccountPreferenceKey.searchScope)) {
      return accounts.activePreferences?.searchScope ?? SearchScopeKind.defaults;
    }
    return SearchScreen._deviceScope ?? SearchScopeKind.defaults;
  }

  bool _savesToAccount(AccountPreferencesController? accounts) =>
      accounts != null && accounts.activeSupports(AccountPreferenceKey.searchScope);

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    final scope = _scopeFor(context.read<AccountPreferencesController?>());
    if (scope.isEmpty) {
      // Nothing ticked: no request at all; the screen asks for a tick.
      _pendingSearchOutcome = (query: query, result: null, ownServerIds: const {}, facets: const [], scope: scope);
      return const [];
    }

    final multiServerProvider = Provider.of<MultiServerProvider>(context, listen: false);
    if (!multiServerProvider.hasConnectedServers) {
      throw const _SearchUnavailableException();
    }

    // Hidden-library keys must be hydrated before the first query, or a cold
    // start would filter nothing. Read before any await: the profile subtree
    // can be torn down mid-search.
    final hiddenLibraries = context.read<HiddenLibrariesProvider>();
    await hiddenLibraries.ensureInitialized();
    if (!mounted) return const [];

    final abort = AbortController();
    _activeSearchAbort = abort;
    try {
      final aggregation = multiServerProvider.aggregationService;
      // Titles and the extra kinds run side by side. The extras are
      // best-effort (failures come back empty), so only titles can fail the
      // search; Future.wait settles both before reporting either's error.
      final legs = await Future.wait<Object?>([
        if (scope.contains(SearchScopeKind.titles))
          aggregation.searchAcrossServers(
            query,
            // Search still finds what is in a folded library; only a Not shown one
            // is left out (Adrian, 2026-10-09).
            hiddenLibraryKeys: hiddenLibraries.offLibraryKeys,
            abort: abort,
          )
        else
          Future<Object?>.value(),
        aggregation.searchFacetsAcrossServers(query, scope, abort: abort),
      ]);
      abort.throwIfAborted();
      final result = legs[0] as SearchAggregationResult?;
      final facets = legs[1]! as List<SearchFacetMatch>;
      if (result != null && result.succeededServerIds.isEmpty && facets.isEmpty) {
        if (result.failedServerIds.isNotEmpty) throw const _SearchUnavailableException();
        if (result.cancelledServerIds.isNotEmpty) {
          throw MediaServerHttpException(
            type: MediaServerHttpErrorType.cancelled,
            message: 'Search was cancelled before any server completed',
          );
        }
      }
      final serverManager = multiServerProvider.serverManager;
      final answered = result?.succeededServerIds ?? serverManager.onlineClients.keys.toSet();
      final ownServerIds = {
        for (final id in answered)
          if (serverManager.isOwnerOrAdmin(ServerId(id))) id,
      };
      _pendingSearchOutcome = (
        query: query,
        result: result,
        ownServerIds: ownServerIds,
        facets: _orderFacets(facets, ownServerIds),
        scope: scope,
      );
      return result?.items ?? const [];
    } finally {
      if (identical(_activeSearchAbort, abort)) _activeSearchAbort = null;
    }
  }

  /// Own servers' matches first (as for titles), then one entry per kind and
  /// name: the same genre on two servers is one chip.
  static List<SearchFacetMatch> _orderFacets(List<SearchFacetMatch> facets, Set<String> ownServerIds) {
    final ordered = [
      ...facets.where((match) => ownServerIds.contains(match.serverId)),
      ...facets.where((match) => !ownServerIds.contains(match.serverId)),
    ];
    final seen = <(SearchScopeKind, String)>{};
    return [
      for (final match in ordered)
        if (seen.add((match.kind, match.name.toLowerCase()))) match,
    ];
  }

  /// Open the "Search in" pop-up under its button. Each tick re-runs the
  /// visible query at once; the account is written once, when the pop-up
  /// closes with a change (one write per visit, not per tick).
  Future<void> _openSearchIn(Rect anchor) async {
    final accounts = context.read<AccountPreferencesController?>();
    final before = _scopeFor(accounts);
    final savesToAccount = _savesToAccount(accounts);
    await showAnchoredPanel<void>(
      context,
      anchorRect: anchor,
      anchorAlignment: AppMenuAnchorAlignment.end,
      width: 340,
      builder: (_) => SearchScopePanel(
        initial: before,
        savedToAccount: savesToAccount,
        focusFirstRow: InputModeTracker.isKeyboardMode(context, listen: false),
        onChanged: _applyScope,
      ),
    );
    final after = _chosenScope;
    if (after == null || (after.length == before.length && after.containsAll(before))) return;
    if (savesToAccount) {
      try {
        await accounts!.updateActive(AccountPreferencesPatch.of(AccountPreferenceKey.searchScope, {...after}));
      } catch (error, stackTrace) {
        // The ticks still apply on this screen; only the account copy failed.
        appLogger.w('Search: could not save the Search in ticks to the account', error: error, stackTrace: stackTrace);
      }
    } else {
      SearchScreen._deviceScope = {...after};
    }
  }

  void _applyScope(Set<SearchScopeKind> scope) {
    if (!mounted) return;
    setState(() => _chosenScope = {...scope});
    final query = searchController.text.trim();
    if (query.isEmpty) return;
    if (scope.isEmpty) {
      // Nothing to search: drop any request still out and show the prompt.
      onSearchInvalidated();
      return;
    }
    unawaited(runSearch(query));
  }

  @override
  void onSearchInvalidated() {
    _activeSearchAbort?.abort();
    _activeSearchAbort = null;
    _pendingSearchOutcome = null;
  }

  @override
  void onSearchError(Object error) {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
    _resetKindFilter();
    _resetFacets();
    final message = error is _SearchUnavailableException
        ? t.errors.searchUnavailable
        : t.errors.searchFailed(error: error);
    showErrorSnackBar(context, message);
  }

  @override
  void onSearchCleared() {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
    _resetKindFilter();
    _resetFacets();
  }

  void _resetFacets() {
    _facetMatches = const [];
    _searchedScope = const {};
  }

  @override
  void onSearchCompleted(String query, List<MediaItem> results) {
    final outcome = _pendingSearchOutcome;
    _pendingSearchOutcome = null;
    final matchedOutcome = outcome != null && outcome.query == query ? outcome : null;
    final matched = matchedOutcome?.result;
    _ownServerIds = matchedOutcome?.ownServerIds ?? const {};
    _facetMatches = matchedOutcome?.facets ?? const [];
    _searchedScope = matchedOutcome?.scope ?? const {};

    // Committed alongside the results the pending setState renders (build has
    // not run yet): the pre-rank pool the kind chips derive from. A selected
    // filter survives a refined query as long as its kind still has
    // candidates; otherwise it falls back to "All".
    _searchCandidates = matched?.candidates ?? results;
    _candidateKinds = _kindsIn(_searchCandidates);
    if (_selectedKind != null && !_candidateKinds.contains(_selectedKind)) _selectedKind = null;
    _rankedKindResults = _rankKindResults(_selectedKind, query);

    if (matched != null && matched.failedServerIds.isNotEmpty) {
      showAppSnackBar(context, t.messages.searchPartialResults);
    }

    if (_focusResultsForQuery == null || _focusResultsForQuery != query) return;
    _focusResultsForQuery = null;
    if (searchController.text.trim() != query) return; // user kept editing
    if (results.isEmpty) {
      // No titles: the first extra row (People, ...) takes the focus instead.
      if (_extraRowKinds.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusExtraRow(0);
        });
      }
      return;
    }
    FocusUtils.requestFocusAfterBuild(this, firstResultFocusNode);
  }

  /// OSK "Search" / hardware Enter on TV additionally focuses the results
  /// when the forced search lands.
  @override
  void handleSearchSubmit() {
    final query = searchController.text.trim();
    if (query.isEmpty) return;
    if (searchResults.isEmpty && _extraRowKinds.isNotEmpty && !isSearching && query == lastSearchedQuery) {
      _focusExtraRow(0);
      return;
    }
    if (searchResults.isEmpty || isSearching || query != lastSearchedQuery) {
      _focusResultsForQuery = query;
    }
    super.handleSearchSubmit();
  }

  @override
  void refresh() {
    if (!mounted) return;
    runSearch(searchController.text.trim());
  }

  /// Cmd+R / Ctrl+R re-runs the query currently on screen; `runSearch` no-ops
  /// on an empty field.
  @override
  void manualRefresh() => refresh();

  /// Focus the search input field
  @override
  void focusSearchInput() {
    if (!mounted) return;
    _focusSearchBar();
  }

  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    _focusSearchBar();
  }

  /// Apply a complete query submitted from the Plezy companion remote: set the
  /// text, dismiss any open on-screen keyboard, land focus on the input without
  /// (re)opening the OSK, and run the search now — the first result takes focus
  /// when it lands (via onSearchCompleted). The user already typed the query on
  /// their phone, so the TV keyboard must never be up afterwards.
  @override
  void submitSearchQuery(String query) {
    if (!mounted) return;
    final trimmed = query.trim();
    searchController.text = trimmed; // listener arms the debounce / resets state

    // Focusing the field normally auto-opens the OSK; a remote search must not
    // show it, and must dismiss one the TV user already had open (the phone's
    // Search chip sends tabSearch before the query arrives).
    _tvTextInputController.closeTextInput();
    if (trimmed.isEmpty) return;

    // Land focus on the (visible) input immediately so the D-pad remote is
    // never stranded on the hidden previous tab — while the search is in
    // flight, when it fails, and when it returns nothing.
    _tvTextInputController.focusInputWithoutOpening();

    // Same path as the OSK Search key: jumps straight to already-matching
    // results, or cancels the debounce and runs now; the screen override arms
    // _focusResultsForQuery so results take focus when they land.
    handleSearchSubmit();
  }

  // Public method to fully reload all content (for profile switches)
  @override
  void fullRefresh() {
    if (!mounted) return;
    appLogger.d('SearchScreen.fullRefresh() called - clearing search and reloading');
    // Clearing the field resets the search state through the text listener.
    _focusResultsForQuery = null;
    // A profile switch brings another account's ticks.
    _chosenScope = null;
    searchController.clear();
  }

  Future<void> updateItem(MediaItem source) async {
    if (!mounted) return;
    final serverId = source.serverId;
    if (serverId == null) return;

    try {
      final multiServer = context.read<MultiServerProvider>();
      final updated = await multiServer.getClientForServer(ServerId(serverId))?.fetchItem(source.id);
      if (!mounted || updated == null) return;
      // A fresh Jellyfin `fetchItem` carries no library field, and a
      // library-less row would lose its label (#1970); keep the identity
      // and library context the search stamped on the original row.
      final merged = mergeFetchedMediaItem(fetched: updated, fallbackServerId: ServerId(serverId), existing: source);
      // The same row can sit in the ranked "All" list, the kind-filtered
      // view, and the candidate pool; refresh every copy so a later chip
      // switch cannot resurrect the stale row.
      var replaced = _replaceByGlobalKey(searchResults, source.globalKey, merged);
      replaced = _replaceByGlobalKey(_searchCandidates, source.globalKey, merged) || replaced;
      final filtered = _rankedKindResults;
      if (filtered != null) {
        replaced = _replaceByGlobalKey(filtered, source.globalKey, merged) || replaced;
      }
      if (replaced) setState(() {});
    } catch (e) {
      appLogger.d('Search item refresh skipped for ${source.globalKey}', error: e);
    }
  }

  void _navigateToSidebar() {
    MainScreenFocusScope.focusSidebarOf(context);
  }

  /// Chip display order. `folder`/`unknown` are never search kinds, and
  /// `clip`/`photo` rows (rare Plex extras) stay reachable under "All"
  /// without a chip of their own.
  static const List<MediaKind> _kindFilterOrder = [
    MediaKind.movie,
    MediaKind.show,
    MediaKind.season,
    MediaKind.episode,
    MediaKind.artist,
    MediaKind.album,
    MediaKind.track,
    MediaKind.collection,
    MediaKind.playlist,
  ];

  static List<MediaKind> _kindsIn(List<MediaItem> candidates) {
    if (candidates.isEmpty) return const [];
    final present = {for (final item in candidates) item.kind};
    return [
      for (final kind in _kindFilterOrder)
        if (present.contains(kind)) kind,
    ];
  }

  static bool _replaceByGlobalKey(List<MediaItem> items, String globalKey, MediaItem replacement) {
    final index = items.indexWhere((item) => item.globalKey == globalKey);
    if (index == -1) return false;
    items[index] = replacement;
    return true;
  }

  /// The list the results sliver renders: the aggregation's ranked list, or
  /// the selected kind's candidates re-ranked with the full display budget.
  List<MediaItem> get _visibleResults => _rankedKindResults ?? searchResults;

  /// A single-kind result set has nothing to filter.
  bool get _showKindChips => _candidateKinds.length > 1;

  List<MediaItem>? _rankKindResults(MediaKind? kind, String query) {
    if (kind == null) return null;
    return rankMediaSearchResults(
      [
        for (final item in _searchCandidates)
          if (item.kind == kind) item,
      ],
      query,
      limit: defaultMediaSearchLimit,
    );
  }

  void _selectKindFilter(MediaKind? kind) {
    if (kind == _selectedKind) return;
    setState(() {
      _selectedKind = kind;
      _rankedKindResults = _rankKindResults(kind, lastSearchedQuery);
    });
  }

  void _resetKindFilter() {
    _selectedKind = null;
    _searchCandidates = const [];
    _candidateKinds = const [];
    _rankedKindResults = null;
    _ownServerIds = const {};
  }

  FocusNode _chipFocusNode(MediaKind? kind) {
    if (kind == null) return _allChipFocusNode;
    return _kindChipFocusNodes.putIfAbsent(kind, () => FocusNode(debugLabel: 'SearchKindChip_${kind.id}'));
  }

  /// D-pad landing point for the chip row: the chip that is currently active.
  void _focusKindChips() => _chipFocusNode(_selectedKind).requestFocus();

  void _focusFirstResult() {
    if (_visibleResults.isNotEmpty) firstResultFocusNode.requestFocus();
  }

  String _kindFilterLabel(MediaKind kind) => switch (kind) {
    MediaKind.movie => t.libraries.groupings.movies,
    MediaKind.show => t.libraries.groupings.shows,
    MediaKind.season => t.libraries.groupings.seasons,
    MediaKind.episode => t.libraries.groupings.episodes,
    MediaKind.artist => t.libraries.groupings.artists,
    MediaKind.album => t.libraries.groupings.albums,
    MediaKind.track => t.libraries.groupings.tracks,
    MediaKind.collection => t.libraries.tabs.collections,
    MediaKind.playlist => t.libraries.tabs.playlists,
    // Unreachable: excluded from _kindFilterOrder.
    MediaKind.clip || MediaKind.photo || MediaKind.folder || MediaKind.unknown => kind.id,
  };

  Widget _buildKindFilterChips() {
    // Chips trap RIGHT to keep focus inside the strip (see
    // FocusableChipStateMixin), so left/right neighbors are wired explicitly,
    // like every other tab-chip strip.
    final kinds = <MediaKind?>[null, ..._candidateKinds];
    return SliverToBoxAdapter(
      child: Padding(
        // The search field's own bottom padding provides the gap above; the
        // results sliver below shrinks its top padding to match (16/16 visual
        // rhythm around the strip instead of the default 24/24).
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TabChipStrip(
          children: [
            for (final (index, kind) in kinds.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              FocusableTabChip(
                label: kind == null ? t.libraries.groupings.all : _kindFilterLabel(kind),
                isSelected: _selectedKind == kind,
                focusNode: _chipFocusNode(kind),
                onSelect: () => _selectKindFilter(kind),
                onNavigateLeft: index == 0 ? _navigateToSidebar : () => _chipFocusNode(kinds[index - 1]).requestFocus(),
                onNavigateRight: index < kinds.length - 1
                    ? () => _chipFocusNode(kinds[index + 1]).requestFocus()
                    : null,
                onNavigateUp: focusSearchInput,
                onNavigateDown: _focusFirstResult,
                onBack: _navigateToSidebar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One heading and poster grid per library (see [sectionSearchResults]).
  List<Widget> _buildResultSections(BuildContext context) {
    final multiServer = context.watch<MultiServerProvider>();
    final libraries = context.watch<LibrariesProvider>();
    final settings = SettingsService.instance;
    final density = settings.read(SettingsService.libraryDensity);
    final fullCardLayout = PlatformDetector.isTV() && settings.read(SettingsService.tvFullCardLayout);
    final sections = sectionSearchResults(
      _visibleResults,
      ownServerIds: _ownServerIds,
      libraries: libraries.libraries,
      serverNameOf: (serverId) => multiServer.serverManager.serverDisplayName(ServerId(serverId)),
    );
    return [
      for (final (sectionIndex, section) in sections.indexed) ...[
        SliverToBoxAdapter(
          child: _SearchSectionHeader(section: section, isFirst: sectionIndex == 0),
        ),
        MediaCardSliverLayout(
          viewMode: ViewMode.grid,
          itemCount: section.items.length,
          density: density,
          // Room for the focus decoration (scale + border) around the cards.
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          fullBleedImage: fullCardLayout,
          itemBuilder: (context, position) {
            final item = section.items[position.index];
            final isFirstCard = sectionIndex == 0 && position.index == 0;
            return FocusableMediaCard(
              key: Key(item.globalKey),
              item: item,
              viewModeOverride: ViewMode.grid,
              disableScale: position.disableScale,
              fullBleedImage: fullCardLayout && position.isGrid,
              focusNode: isFirstCard ? firstResultFocusNode : null,
              onRefresh: updateItem,
              onListRefresh: refresh,
              onNavigateLeft: position.isFirstColumn ? _navigateToSidebar : null,
              onNavigateUp: sectionIndex == 0 && position.isFirstRow
                  ? (_showKindChips ? _focusKindChips : focusSearchInput)
                  : null,
            );
          },
        ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }

  /// Extra rows (People, Keywords, ...) the visible query asked for, in
  /// display order. Year shows only for a query that is a year.
  List<SearchScopeKind> get _shownExtraRowKinds => [
    for (final kind in SearchScopeKind.extraRowOrder)
      if (_searchedScope.contains(kind) && (kind != SearchScopeKind.year || searchYearOf(lastSearchedQuery) != null))
        kind,
  ];

  /// The extra rows that have something to focus.
  List<SearchScopeKind> get _extraRowKinds => [
    for (final kind in _shownExtraRowKinds)
      if (_matchesOf(kind).isNotEmpty) kind,
  ];

  List<SearchFacetMatch> _matchesOf(SearchScopeKind kind) => [
    for (final match in _facetMatches)
      if (match.kind == kind) match,
  ];

  static bool _isPeopleRow(SearchScopeKind kind) => kind == SearchScopeKind.actors || kind == SearchScopeKind.crew;

  bool get _hasAnyResult => searchResults.isNotEmpty || _facetMatches.isNotEmpty;

  /// Focus the first person or chip of the [index]th focusable extra row.
  void _focusExtraRow(int index) {
    final rows = _extraRowKinds;
    if (index < 0 || index >= rows.length) return;
    final kind = rows[index];
    if (_isPeopleRow(kind)) {
      final strip = _peopleStripKeys[kind]?.currentState;
      strip?.requestFocus();
      final stripContext = _peopleStripKeys[kind]?.currentContext;
      if (stripContext != null) unawaited(Scrollable.ensureVisible(stripContext, alignment: 0.5));
    } else {
      final nodes = _facetChipNodes[kind];
      if (nodes != null && nodes.isNotEmpty) nodes.first.requestFocus();
    }
  }

  /// Up out of the first extra row: back into the titles (the focus system
  /// finds the card above), or to the search bar when there are none.
  VoidCallback? _upFromExtraRow(int index) {
    if (index > 0) return () => _focusExtraRow(index - 1);
    return searchResults.isEmpty ? focusSearchInput : null;
  }

  VoidCallback? _downFromExtraRow(int index) =>
      index < _extraRowKinds.length - 1 ? () => _focusExtraRow(index + 1) : null;

  List<FocusNode> _chipNodesFor(SearchScopeKind kind, int count) {
    final nodes = _facetChipNodes.putIfAbsent(kind, () => []);
    while (nodes.length < count) {
      nodes.add(FocusNode(debugLabel: 'SearchFacetChip_${kind.id}_${nodes.length}'));
    }
    return nodes;
  }

  String _extraRowTitle(SearchScopeKind kind) => switch (kind) {
    SearchScopeKind.actors => t.search.rows.people,
    SearchScopeKind.crew => t.search.rows.crew,
    SearchScopeKind.keywords => t.search.rows.keywords,
    SearchScopeKind.genres => t.search.rows.genres,
    SearchScopeKind.studios => t.search.rows.studios,
    SearchScopeKind.year => t.search.rows.year,
    SearchScopeKind.titles => '',
  };

  String _noMatchText(SearchScopeKind kind) => t.search.rows.noMatch(
    kind: switch (kind) {
      SearchScopeKind.actors => t.search.rows.noMatchPeople,
      SearchScopeKind.crew => t.search.rows.noMatchCrew,
      SearchScopeKind.keywords => t.search.rows.noMatchKeywords,
      SearchScopeKind.genres => t.search.rows.noMatchGenres,
      SearchScopeKind.studios => t.search.rows.noMatchStudios,
      SearchScopeKind.year => t.search.rows.noMatchYear,
      SearchScopeKind.titles => '',
    },
    query: lastSearchedQuery,
  );

  static IconData _facetIcon(SearchScopeKind kind) => switch (kind) {
    SearchScopeKind.keywords => Symbols.sell_rounded,
    SearchScopeKind.genres => Symbols.theater_comedy_rounded,
    SearchScopeKind.studios => Symbols.movie_rounded,
    SearchScopeKind.year => Symbols.calendar_month_rounded,
    _ => Symbols.person_rounded,
  };

  void _openFacet(SearchFacetMatch match) {
    final client = context.read<MultiServerProvider>().getClientForServer(ServerId(match.serverId));
    if (client == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => match.facet.kind == MediaFacetKind.person
            ? ActorMediaScreen(
                actorName: match.name,
                personId: match.facet.value,
                actorThumb: match.imagePath,
                serverId: match.serverId,
                serverName: match.serverName,
                backend: client.backend,
              )
            : ActorMediaScreen.filtered(
                title: match.name,
                facet: match.facet,
                icon: _facetIcon(match.kind),
                serverId: match.serverId,
                serverName: match.serverName,
                backend: client.backend,
              ),
      ),
    );
  }

  /// One row per ticked extra kind under the title sections: round photos
  /// for people, chips for the rest, or a short line when nothing matched.
  List<Widget> _buildExtraRows(BuildContext context) {
    final focusable = _extraRowKinds;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final rows = <Widget>[];
    for (final kind in _shownExtraRowKinds) {
      final matches = _matchesOf(kind);
      final index = focusable.indexOf(kind);
      rows.add(
        SliverToBoxAdapter(
          key: ValueKey('search_row_${kind.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_extraRowTitle(kind), style: textTheme.titleMedium),
                    if (matches.isNotEmpty) ...[const SizedBox(width: 8), Text('${matches.length}', style: muted)],
                  ],
                ),
                const SizedBox(height: 8),
                if (matches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(_noMatchText(kind), style: muted),
                  )
                else if (_isPeopleRow(kind))
                  CastMemberStrip(
                    key: _peopleStripKeys.putIfAbsent(kind, () => GlobalKey<CastMemberStripState>()),
                    circular: true,
                    debugLabel: 'SearchPeople_${kind.id}',
                    members: [
                      for (final match in matches)
                        (
                          name: match.name,
                          secondary: kind == SearchScopeKind.actors ? t.search.rows.actorRole : t.search.rows.crewRole,
                          imagePath: match.imagePath,
                        ),
                    ],
                    imageClient: context.read<MultiServerProvider>().getClientForServer(
                      ServerId(matches.first.serverId),
                    ),
                    onMemberTap: (i) => _openFacet(matches[i]),
                    onNavigateUp: _upFromExtraRow(index),
                    onNavigateDown: _downFromExtraRow(index),
                  )
                else
                  _buildFacetChips(kind, matches, index),
              ],
            ),
          ),
        ),
      );
    }
    if (rows.isNotEmpty) rows.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return rows;
  }

  Widget _buildFacetChips(SearchScopeKind kind, List<SearchFacetMatch> matches, int rowIndex) {
    final nodes = _chipNodesFor(kind, matches.length);
    return TabChipStrip(
      children: [
        for (final (i, match) in matches.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          FocusableFilterChip(
            icon: _facetIcon(kind),
            label: match.count == null ? match.name : '${match.name} · ${match.count}',
            focusNode: nodes[i],
            onPressed: () => _openFacet(match),
            onNavigateLeft: i == 0 ? _navigateToSidebar : nodes[i - 1].requestFocus,
            onNavigateRight: i < matches.length - 1 ? nodes[i + 1].requestFocus : null,
            onNavigateUp: _upFromExtraRow(rowIndex),
            onNavigateDown: _downFromExtraRow(rowIndex),
            onBack: _navigateToSidebar,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scopeFor(context.watch<AccountPreferencesController?>());
    final hint = searchScopeHint(scope);
    final hasExtraRows = _extraRowKinds.isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: SettingsBuilder(
          prefs: const [SettingsService.libraryDensity, SettingsService.tvFullCardLayout],
          builder: (context) => CustomScrollView(
            primary: false,
            slivers: [
              DesktopSliverAppBar(title: Text(t.common.search), floating: true),
              SliverToBoxAdapter(
                child: SearchInputField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  debugLabel: searchDebugLabel,
                  hintText: hint,
                  tvTextInputController: _tvTextInputController,
                  onNavigateLeft: _navigateToSidebar,
                  onNavigateDown: isSearching || scope.isEmpty
                      ? null
                      : searchResults.isNotEmpty
                      ? (_showKindChips ? _focusKindChips : firstResultFocusNode.requestFocus)
                      : (hasExtraRows ? () => _focusExtraRow(0) : null),
                  onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
                  onVoiceSearch: _voiceSearchAvailable ? _startVoiceSearch : null,
                  voiceSearchTooltip: t.search.voiceSearch,
                  voiceFocusNode: _voiceFocusNode,
                  onSearchIn: (anchor) => unawaited(_openSearchIn(anchor)),
                  searchInCount: scope.length,
                  searchInTooltip: t.search.searchIn.title,
                  onBack: () {
                    if (searchController.text.isNotEmpty) {
                      searchController.clear();
                    } else {
                      _navigateToSidebar();
                    }
                  },
                ),
              ),
              if (scope.isEmpty)
                SliverFillRemaining(
                  child: StateMessageWidget(
                    message: t.search.searchYourMedia,
                    subtitle: t.search.scopeHint.nothingTicked,
                    icon: Symbols.tune_rounded,
                    iconSize: 80,
                  ),
                )
              else if (isSearching)
                LoadingIndicatorBox.sliver
              else if (!hasSearched)
                SliverFillRemaining(
                  child: StateMessageWidget(
                    message: t.search.searchYourMedia,
                    subtitle: hint,
                    icon: Symbols.search_rounded,
                    iconSize: 80,
                  ),
                )
              else if (lastSearchFailed)
                SliverFillRemaining(
                  child: StateMessageWidget(message: t.explore.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
                )
              else if (!_hasAnyResult)
                SliverFillRemaining(
                  child: StateMessageWidget(
                    message: t.messages.noResultsFound,
                    subtitle: t.search.tryDifferentTerm,
                    icon: Symbols.search_off_rounded,
                    iconSize: 80,
                  ),
                )
              else ...[
                if (_showKindChips) _buildKindFilterChips(),
                if (searchResults.isNotEmpty) ..._buildResultSections(context),
                ..._buildExtraRows(context),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A library's heading over its results; libraries on servers the user does
/// not own also name the server.
class _SearchSectionHeader extends StatelessWidget {
  final SearchResultSection section;
  final bool isFirst;

  const _SearchSectionHeader({required this.section, required this.isFirst});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final subtitle = section.subtitle;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, isFirst ? 8 : 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isFirst) const Divider(height: 1, thickness: 1),
          if (!isFirst) const SizedBox(height: 16),
          Text(section.title, style: textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (subtitle != null && subtitle.isNotEmpty)
            Text(
              subtitle,
              style: textTheme.bodySmall?.copyWith(color: textTheme.bodySmall?.color?.withValues(alpha: 0.7)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

final class _SearchUnavailableException implements Exception {
  const _SearchUnavailableException();
}
