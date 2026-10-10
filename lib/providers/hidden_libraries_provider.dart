import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../media/home_layout.dart';
import '../media/ids.dart';
import '../media/library_layout.dart';
import '../media/media_backend.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/jellyfin_client.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';

/// Each library's place in the user's layout: shown, folded into the Hidden
/// libraries section, or not shown at all (plan `local/plans/library-states.md`).
///
/// With a PlezyFin account (a connected Jellyfin server that reports
/// `PlezyFinVersion`) the layout lives on that server and covers every server
/// Plezy is connected to; every device follows it. Without one, the states are
/// kept on this device, and a Jellyfin library hidden on its own server
/// (`MyMediaExcludes`) reads as folded.
///
/// The class keeps its old name: most of the app only asks it which libraries
/// to leave out.
class HiddenLibrariesProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  StorageService? _storageService;
  final String? profileId;

  /// Device mode: folded libraries (the old per-device hidden list).
  Set<String> _folded = {};

  /// Device mode: libraries set to Not shown.
  Set<String> _off = {};

  /// Libraries the user hid on their own Jellyfin/Emby server.
  Set<String> _serverHidden = {};

  List<MediaLibrary> _libraries = const [];

  JellyfinClient? _account;
  String? _ownServerId;
  LibraryLayout? _layout;

  /// The admin's default layout, for row titles and home sections the user
  /// has not set.
  LibraryLayout? _defaults;

  /// Device mode: the home sections kept on this device.
  HomeLayout? _deviceHome;

  bool _isInitialized = false;
  late final Future<void> _initFuture;
  Future<void>? _accountRefresh;
  bool _accountRefreshQueued = false;
  DateTime? _accountCheckedAt;

  /// How stale the account layout may get before a library reload rereads it,
  /// so a change made in the web client or on another device shows up.
  static const _accountRecheck = Duration(minutes: 1);

  MediaServerClient? Function(ServerId serverId)? _clientFor;
  void Function(String globalKey, bool hidden)? _onServerHiddenChanged;

  HiddenLibrariesProvider({this._storageService, this.profileId}) {
    // Start initialization eagerly to reduce race conditions
    _initFuture = _initialize();
  }

  /// Ensures the provider is initialized. Call this before accessing hidden
  /// libraries in contexts where you need the actual persisted values.
  Future<void> ensureInitialized() => _initFuture;

  /// Check if the provider has completed initialization
  bool get isInitialized => _isInitialized;

  /// Whether the layout comes from a PlezyFin account (live or cached).
  bool get isAccountLayout => _layout != null && _ownServerId != null;

  /// Connect the provider to the session's servers: [clientFor] finds a
  /// server's client, and [onServerHiddenChanged] tells the library list when
  /// a Jellyfin library's server-side hidden flag changed.
  void bind({
    required MediaServerClient? Function(ServerId serverId) clientFor,
    required void Function(String globalKey, bool hidden) onServerHiddenChanged,
  }) {
    _clientFor = clientFor;
    _onServerHiddenChanged = onServerHiddenChanged;
  }

  /// Put the provider in account mode without a server round trip.
  @visibleForTesting
  void debugSetAccount(JellyfinClient account, LibraryLayout layout, {LibraryLayout? defaults}) {
    _account = account;
    _ownServerId = account.layoutServerId;
    _layout = layout;
    _defaults = defaults;
    safeNotifyListeners();
  }

  /// [library]'s state.
  LibraryState stateOf(MediaLibrary library) {
    final layout = _layout;
    if (layout != null && _ownServerId != null) {
      return layout.stateOf(libraryLayoutKey(library), ownServerId: _ownServerId);
    }
    final key = library.globalKey;
    if (_off.contains(key)) return LibraryState.off;
    if (_folded.contains(key) || _serverHidden.contains(key)) return LibraryState.folded;
    return LibraryState.shown;
  }

  Set<String> _keysIn(Set<LibraryState> states) => {
    for (final library in _libraries)
      if (states.contains(stateOf(library))) library.globalKey,
  };

  /// Libraries left out of the main list and home: folded and not shown.
  Set<String> get hiddenLibraryKeys {
    final loaded = _keysIn(const {LibraryState.folded, LibraryState.off});
    // Before the libraries load, the device lists still say what to leave out.
    return Set.unmodifiable(isAccountLayout ? loaded : {...loaded, ..._folded, ..._off, ..._serverHidden});
  }

  /// Libraries with no home rows: with an account, the Not shown ones and
  /// those whose home row is off (a folded library can keep its row, Adrian
  /// 2026-10-10); without one, the same as [hiddenLibraryKeys].
  Set<String> get homeHiddenLibraryKeys {
    final rows = homeRowsInForce;
    if (rows == null) return hiddenLibraryKeys;
    final on = {
      for (final row in rows)
        if (row.on) row.key,
    };
    return Set.unmodifiable({
      for (final library in _libraries)
        if (!on.contains(libraryLayoutKey(library))) library.globalKey,
    });
  }

  /// Libraries in the Hidden libraries fold.
  Set<String> get foldedLibraryKeys => Set.unmodifiable(_keysIn(const {LibraryState.folded}));

  /// Libraries shown nowhere. Their items also leave Continue Watching, Next
  /// Up and search; a folded library's items stay (Adrian, 2026-10-09).
  Set<String> get offLibraryKeys {
    final loaded = _keysIn(const {LibraryState.off});
    return Set.unmodifiable(isAccountLayout ? loaded : {...loaded, ..._off});
  }

  /// The account's library order as global keys, or null without an account.
  List<String>? get accountOrder {
    final layout = _layout;
    if (layout == null || _ownServerId == null) return null;
    final byKey = {for (final library in _libraries) libraryLayoutKey(library): library.globalKey};
    return [
      for (final key in layout.arrange(_libraries, ownServerId: _ownServerId).order)
        if (byKey[key] != null) byKey[key]!,
    ];
  }

  /// The PlezyFin server's client, for its Favourites entry; null without a
  /// reachable account.
  JellyfinClient? get accountClient => isAccountLayout ? _account : null;

  /// [entry]'s layout key, when there is an account.
  String? _entryKey(LayoutEntry entry) => isAccountLayout ? entry.keyFor(_ownServerId!) : null;

  /// Where an account entry sits: shown, folded or not shown. Null without a
  /// PlezyFin account; Favourites also needs the server reachable, to list
  /// them from.
  LibraryState? entryState(LayoutEntry entry) {
    final key = _entryKey(entry);
    if (key == null || (entry == LayoutEntry.favorites && _account == null)) return null;
    return _layout!.stateOf(key, ownServerId: _ownServerId);
  }

  /// Where the Favourites entry sits; see [entryState].
  LibraryState? get favoritesState => entryState(LayoutEntry.favorites);

  /// Every managed key in the account's order; Continue Watching and Next Up
  /// go first when the record does not place them yet.
  List<String> _arrangedKeys() => _layout!
      .arrangeKeys(
        _managedKeys(),
        ownServerId: _ownServerId,
        leading: [for (final entry in LayoutEntry.leading) entry.keyFor(_ownServerId!)],
      )
      .order;

  /// Where an entry goes among [ordered] libraries: the number of them the
  /// account places before it.
  int entryIndexIn(LayoutEntry entry, List<MediaLibrary> ordered) {
    final key = _entryKey(entry);
    if (key == null) return ordered.length;
    final rank = {for (final (index, k) in _arrangedKeys().indexed) k: index};
    final entryRank = rank[key] ?? rank.length;
    return ordered.where((library) => (rank[libraryLayoutKey(library)] ?? rank.length) < entryRank).length;
  }

  /// Where the Favourites entry goes among [ordered] libraries.
  int favoritesIndexIn(List<MediaLibrary> ordered) => entryIndexIn(LayoutEntry.favorites, ordered);

  /// [libraries] of one section, in the account's order, with the account
  /// entries in [state] placed among them. Each item is a [MediaLibrary] or a
  /// [LayoutEntry]. Without an account, just [libraries].
  List<Object> withEntries(List<MediaLibrary> libraries, LibraryState state) {
    if (!isAccountLayout) return libraries;
    final rank = {for (final (index, k) in _arrangedKeys().indexed) k: index};
    int rankOf(String key) => rank[key] ?? rank.length;
    final entries = [
      for (final entry in LayoutEntry.values)
        if (entryState(entry) == state) entry,
    ]..sort((a, b) => rankOf(_entryKey(a)!).compareTo(rankOf(_entryKey(b)!)));
    final result = <Object>[];
    var next = 0;
    for (final library in libraries) {
      final libraryRank = rankOf(libraryLayoutKey(library));
      while (next < entries.length && rankOf(_entryKey(entries[next])!) < libraryRank) {
        result.add(entries[next++]);
      }
      result.add(library);
    }
    result.addAll(entries.skip(next));
    return result;
  }

  /// The home rows' own order and switches: the record's, else the admin
  /// default's (per field, PlezyFin 2026-10-10); null keeps the old rule.
  HomeRows? get _rowsInForce => _layout?.home?.rows ?? _defaults?.home?.rows;

  List<({String key, bool on})>? _homeRowsCache;
  Object? _homeRowsCacheKey;

  /// With an account, every entry that can have a home row, in home order,
  /// each with whether its row is on; null without an account. Not shown
  /// entries and Favourites have none (Adrian, 2026-10-10; plan
  /// `local/plans/home-rows-apart.md`).
  ///
  /// Until the record has `home.rows`, the old rule holds: Shown entries on,
  /// in menu order, then the folded ones, off.
  List<({String key, bool on})>? get homeRowsInForce {
    if (!isAccountLayout) return null;
    final cacheKey = (_layout, _defaults, _libraries, _ownServerId);
    final cached = _homeRowsCache;
    if (cached != null && _homeRowsCacheKey == cacheKey) return cached;
    final layout = _layout!;
    final favorites = favoritesLayoutKey(_ownServerId!);
    final shown = <String>[];
    final folded = <String>[];
    for (final key in _arrangedKeys()) {
      if (key == favorites) continue;
      switch (layout.stateOf(key, ownServerId: _ownServerId)) {
        case LibraryState.shown:
          shown.add(key);
        case LibraryState.folded:
          folded.add(key);
        case LibraryState.off:
          break;
      }
    }
    final rows = _rowsInForce;
    final result = rows == null
        ? [for (final key in shown) (key: key, on: true), for (final key in folded) (key: key, on: false)]
        : [
            for (final key in rows.arrange([...shown, ...folded])) (key: key, on: !rows.off.contains(key)),
          ];
    _homeRowsCacheKey = cacheKey;
    return _homeRowsCache = List.unmodifiable(result);
  }

  /// Account mode: where [key]'s home row sits among the rows that are on;
  /// null without an account or when [key] has no row on home.
  int? homeRank(String key) {
    final rows = homeRowsInForce;
    if (rows == null) return null;
    var rank = 0;
    for (final row in rows) {
      if (!row.on) continue;
      if (row.key == key) return rank;
      rank++;
    }
    return null;
  }

  /// [entry]'s layout key, or null without an account.
  String? entryLayoutKey(LayoutEntry entry) => _entryKey(entry);

  /// Save the home rows from the Home page list: [rows] are the rows it shows,
  /// top to bottom, each on or off. Entries it does not show (views Plezy has
  /// no rows for) keep their place and switch; Not shown ones and other
  /// servers' keys keep theirs in the record. The first save writes every
  /// managed entry, so nothing changes on screen (PlezyFin, 2026-10-10).
  Future<void> saveHomeRows(List<({String key, bool on})> rows) async {
    final inForce = homeRowsInForce;
    if (inForce == null) throw StateError('Home rows need a PlezyFin account');
    final shownKeys = {for (final row in rows) row.key};
    final queue = List.of(rows);
    // The list's rows take the slots the shown rows held, in its order.
    final ordered = <({String key, bool on})>[];
    for (final row in inForce) {
      if (!shownKeys.contains(row.key)) {
        ordered.add(row);
      } else if (queue.isNotEmpty) {
        ordered.add(queue.removeAt(0));
      }
    }
    ordered.addAll(queue);
    final managed = {for (final row in ordered) row.key};
    await _saveHome(
      (base) => base.withRows(
        (base.rows ?? const HomeRows()).place(
          managed: managed,
          ordered: [for (final row in ordered) row.key],
          offKeys: {
            for (final row in ordered)
              if (!row.on) row.key,
          },
        ),
      ),
    );
  }

  /// Account mode: [entry]'s rank; see [homeRank].
  int? entryRank(LayoutEntry entry) {
    final key = _entryKey(entry);
    return key == null ? null : homeRank(key);
  }

  /// Account mode: [library]'s rank; see [homeRank].
  int? libraryRank(MediaLibrary library) => homeRank(libraryLayoutKey(library));

  /// The card key of the Continue Watching or Next Up row: the entry's layout
  /// key with an account (PlezyFin, 2026-10-09), else the section id.
  String sectionCardKey(String section) {
    final entry = section == HomeLayout.nextUp ? LayoutEntry.nextUp : LayoutEntry.continueWatching;
    return _entryKey(entry) ?? section;
  }

  /// The home row title the account sets for a library, or null for "Recently
  /// Added in `<library name>`".
  String? rowTitleFor({required String serverId, required String libraryId}) {
    final layout = _layout;
    if (layout == null) return null;
    final library = _libraries.where((l) => l.serverId == serverId && l.id == libraryId).firstOrNull;
    if (library == null) return null;
    return layout.titleFor(libraryLayoutKey(library), defaults: _defaults);
  }

  /// The home sections in force: with an account, the record's, else the
  /// admin default's, else all on; without one, this device's (PlezyFin,
  /// 2026-10-09). The banner's switch is only the account's: without an
  /// account the device's Show hero setting decides, as before.
  HomeLayout get home => (isAccountLayout ? _layout!.home ?? _defaults?.home : _deviceHome) ?? HomeLayout.standard;

  /// [row]'s card style: a section id or a library layout key. Without an
  /// account, null keeps the row's usual look. With one every row has a style:
  /// the account's, else the admin default's, else screen grabs for Continue
  /// Watching and Next Up and posters for libraries, as the web client shows
  /// them (PlezyFin, 2026-10-10).
  HomeCardStyle? cardStyleFor(String row) {
    if (!isAccountLayout) return _deviceHome?.cards[row];
    return _layout!.home?.cards[row] ?? _defaults?.home?.cards[row] ?? _builtInCardStyle(row);
  }

  HomeCardStyle _builtInCardStyle(String row) =>
      row == _entryKey(LayoutEntry.continueWatching) || row == _entryKey(LayoutEntry.nextUp)
      ? HomeCardStyle.thumb
      : HomeCardStyle.poster;

  /// [library]'s card style on home.
  HomeCardStyle? libraryCardStyle(MediaLibrary library) => cardStyleFor(_homeRowKey(library));

  /// The card key of [library]'s home rows: its layout key with an account,
  /// its global key on the device.
  String _homeRowKey(MediaLibrary library) => isAccountLayout ? libraryLayoutKey(library) : library.globalKey;

  /// The library a home row belongs to, by server and library id.
  MediaLibrary? libraryFor({required String serverId, required String libraryId}) =>
      _libraries.where((l) => l.serverId == serverId && l.id == libraryId).firstOrNull;

  /// The home sections a write starts from: the record's own, or the ones in
  /// force without the default's card choices, so those keep following the
  /// default.
  HomeLayout get _homeBase {
    if (isAccountLayout) {
      final own = _layout!.home;
      if (own != null) return own;
      final shown = home;
      return HomeLayout(order: shown.sections, off: shown.off);
    }
    return _deviceHome ?? HomeLayout.standard;
  }

  /// Put the home sections in [sections] order.
  Future<void> setHomeSections(List<String> sections) => _saveHome((base) => base.withSections(sections));

  /// Turn a home section on or off.
  Future<void> setHomeSectionOn(String id, {required bool on}) => _saveHome((base) => base.withSection(id, on: on));

  /// Set [row]'s card style; null goes back to the usual look.
  Future<void> setCardStyle(String row, HomeCardStyle? style) => _saveHome((base) => base.withCard(row, style));

  /// Set [library]'s home rows' card style.
  Future<void> setLibraryCardStyle(MediaLibrary library, HomeCardStyle? style) =>
      setCardStyle(_homeRowKey(library), style);

  Future<void> _saveHome(HomeLayout Function(HomeLayout base) change) async {
    await ensureInitialized();
    if (isDisposed) return;
    if (isAccountLayout) {
      final account = _account;
      final ownServerId = _ownServerId!;
      if (account == null) throw StateError('The PlezyFin server is not reachable');
      final fresh = await account.fetchLibraryLayout() ?? _layout ?? LibraryLayout.empty;
      // Start from the fresh record's own home, so a change made elsewhere
      // since this device last read it is kept.
      _layout = fresh;
      final next = fresh.withHome(change(_homeBase), now: DateTime.now());
      await account.saveLibraryLayout(next);
      if (isDisposed) return;
      await _setAccount(account, ownServerId, next);
      return;
    }
    final next = change(_homeBase);
    _deviceHome = next;
    await _storageService!.saveHomeLayout(jsonEncode(next.toJson()), profileId: profileId);
    safeNotifyListeners();
  }

  /// The server-hidden keys among [libraries]. Plex's own `hidden` flag is not
  /// a user choice made in a Plex client, so it does not count.
  static Set<String> serverHiddenKeysOf(Iterable<MediaLibrary> libraries) => {
    for (final library in libraries)
      if (library.hidden && library.backend != MediaBackend.plex) library.globalKey,
  };

  /// Follow the loaded [libraries], and check the PlezyFin account for them.
  void syncLibraries(Iterable<MediaLibrary> libraries) {
    final next = List<MediaLibrary>.of(libraries);
    final serverHidden = serverHiddenKeysOf(next);
    final changed =
        !setEquals(serverHidden, _serverHidden) ||
        !listEquals([for (final l in next) l.globalKey], [for (final l in _libraries) l.globalKey]);
    _libraries = next;
    _serverHidden = serverHidden;
    if (changed) safeNotifyListeners();
    final checkedAt = _accountCheckedAt;
    if (changed || checkedAt == null || DateTime.now().difference(checkedAt) > _accountRecheck) {
      unawaited(refreshAccount());
    }
  }

  /// Initialize the provider by loading hidden libraries from storage
  Future<void> _initialize() async {
    await _loadFromStorage();
    _isInitialized = true;
    safeNotifyListeners();
  }

  Future<void> _loadFromStorage() async {
    final storage = _storageService ??= await StorageService.getInstance();
    final scopedProfileId = profileId;
    _folded = scopedProfileId == null
        ? storage.getHiddenLibraries()
        : storage.getHiddenLibrariesForProfile(scopedProfileId);
    _off = storage.getOffLibraries(profileId: scopedProfileId);
    _deviceHome = _decodeHome(storage.getHomeLayout(profileId: scopedProfileId));
    final cached = storage.getAccountLibraryLayout(profileId: scopedProfileId);
    if (cached != null && _layout == null) {
      try {
        final json = jsonDecode(cached);
        if (json is Map<String, dynamic> && json['own'] is String && json['layout'] is Map<String, dynamic>) {
          _ownServerId = json['own'] as String;
          _layout = LibraryLayout.fromJson(json['layout'] as Map<String, dynamic>);
        }
      } on FormatException {
        // A bad cache just means waiting for the server.
      }
    }
  }

  static HomeLayout? _decodeHome(String? raw) {
    if (raw == null) return null;
    try {
      return HomeLayout.tryFrom(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Look for the PlezyFin account among the connected Jellyfin servers and
  /// load its layout. New libraries are written back with their starting
  /// state, and a user with no layout yet starts from the server's default.
  Future<void> refreshAccount() async {
    if (_accountRefresh != null) {
      _accountRefreshQueued = true;
      return _accountRefresh;
    }
    final run = _refreshAccountOnce();
    _accountRefresh = run;
    try {
      await run;
    } finally {
      _accountRefresh = null;
      if (_accountRefreshQueued && !isDisposed) {
        _accountRefreshQueued = false;
        unawaited(refreshAccount());
      }
    }
  }

  Future<void> _refreshAccountOnce() async {
    await ensureInitialized();
    final clientFor = _clientFor;
    if (isDisposed || clientFor == null) return;
    _accountCheckedAt = DateTime.now();
    final account = await _findAccount(clientFor);
    if (isDisposed) return;
    if (account == null) {
      // No PlezyFin among the servers that answered. A cached layout stays
      // until a check finds none at all among the libraries' own servers.
      if (_layout != null && !_libraries.any((l) => l.serverId != null && clientFor(ServerId(l.serverId!)) == null)) {
        await _setAccount(null, null, null);
      }
      return;
    }
    try {
      final ownServerId = account.layoutServerId;
      var layout = await account.fetchLibraryLayout() ?? LibraryLayout.empty;
      // Read every time: the default also carries the admin's row titles.
      final defaults = await account.fetchLibraryLayoutDefaults();
      _defaults = defaults;
      var seeded = false;
      // The PlezyFin server's libraries start from the admin's default until
      // the record knows them, even when another client wrote it first.
      if (!layout.known.containsKey(ownServerId)) {
        if (defaults != null) layout = layout.seededFrom(defaults, ownServerId: ownServerId);
        seeded = true;
      }
      if (isDisposed) return;
      await _setAccount(account, ownServerId, layout);
      if (seeded || layout.knownDiffers(_managedLibrariesByServer())) {
        await _writeAccount();
      }
    } catch (e, st) {
      appLogger.w('Library layout: could not read the PlezyFin layout', error: e, stackTrace: st);
    }
  }

  Future<JellyfinClient?> _findAccount(MediaServerClient? Function(ServerId) clientFor) async {
    final serverIds = {
      for (final library in _libraries)
        if (library.backend != MediaBackend.plex && library.serverId != null) library.serverId!,
    };
    for (final serverId in serverIds) {
      final client = clientFor(ServerId(serverId));
      if (client is JellyfinClient && await client.plezyFinVersion() != null) return client;
    }
    return null;
  }

  Future<void> _setAccount(JellyfinClient? account, String? ownServerId, LibraryLayout? layout) async {
    _account = account;
    _ownServerId = ownServerId;
    _layout = layout;
    final storage = _storageService;
    if (storage != null) {
      await storage.saveAccountLibraryLayout(
        layout == null || ownServerId == null ? null : jsonEncode({'own': ownServerId, 'layout': layout.toJson()}),
        profileId: profileId,
      );
    }
    safeNotifyListeners();
  }

  /// The servers this device manages in the layout: every one it has
  /// libraries from, with their layout ids.
  Map<String, List<String>> _managedLibrariesByServer() {
    final byServer = <String, List<String>>{};
    final jellyfinServers = <String, String>{};
    for (final library in _libraries) {
      if (library.serverId == null) continue;
      final key = libraryLayoutKey(library);
      final serverId = libraryLayoutServerId(library);
      byServer.putIfAbsent(serverId, () => []).add(key.substring(key.indexOf('/') + 1));
      if (library.backend != MediaBackend.plex) jellyfinServers[serverId] = library.serverId!;
    }
    // Collections and playlists views are not browsable libraries in Plezy,
    // but the layout keeps every view so no client takes one for a new
    // library (PlezyFin, 2026-10-09).
    for (final entry in jellyfinServers.entries) {
      final client = _clientFor?.call(ServerId(entry.value));
      if (client is! JellyfinClient) continue;
      final ids = byServer[entry.key]!;
      for (final id in client.allViewIds) {
        if (!ids.contains(id)) ids.add(id);
      }
    }
    final ownServerId = _ownServerId;
    if (ownServerId != null) {
      final ids = byServer.putIfAbsent(ownServerId, () => []);
      for (final entry in LayoutEntry.values) {
        if (!ids.contains(entry.id)) ids.add(entry.id);
      }
    }
    return byServer;
  }

  /// Every key this device manages: the libraries in the list's order, then
  /// the views Plezy does not list, then the account entries (Favourites
  /// starts after the libraries; Continue Watching and Next Up are put first
  /// by [_arrangedKeys]) (PlezyFin, 2026-10-09).
  List<String> _managedKeys() {
    final keys = [
      for (final library in _libraries)
        if (library.serverId != null) libraryLayoutKey(library),
    ];
    final byServer = _managedLibrariesByServer();
    final entryIds = {for (final entry in LayoutEntry.values) entry.id};
    for (final pass in [false, true]) {
      for (final entry in byServer.entries) {
        for (final id in entry.value) {
          if (entryIds.contains(id) != pass) continue;
          final key = '${entry.key}/$id';
          if (!keys.contains(key)) keys.add(key);
        }
      }
    }
    return keys;
  }

  /// Read the account's layout fresh, apply [order] and [states] to the
  /// servers this device manages, and write it back.
  Future<void> _writeAccount({List<String>? order, Map<String, LibraryState>? states}) async {
    final account = _account;
    final ownServerId = _ownServerId;
    if (account == null || ownServerId == null) {
      throw StateError('The PlezyFin server is not reachable');
    }
    final fresh = await account.fetchLibraryLayout() ?? _layout ?? LibraryLayout.empty;
    final arranged = fresh.arrangeKeys(
      _managedKeys(),
      ownServerId: ownServerId,
      leading: [for (final entry in LayoutEntry.leading) entry.keyFor(ownServerId)],
    );
    // Entries the caller did not place (views Plezy does not list) keep their
    // place relative to each other, after the ones it did.
    final placed = order ?? arranged.order;
    final next = fresh.withManaged(
      librariesByServer: _managedLibrariesByServer(),
      managedOrder: [
        ...placed,
        for (final key in arranged.order)
          if (!placed.contains(key)) key,
      ],
      managedState: {...arranged.state, ...?states},
      now: DateTime.now(),
    );
    await account.saveLibraryLayout(next);
    if (isDisposed) return;
    await _setAccount(account, ownServerId, next);
  }

  /// Put [library] in [state]. With a PlezyFin account this writes the
  /// account; otherwise it stays on this device, and a Jellyfin library is also
  /// hidden or shown on its own server so the web client agrees.
  Future<void> setLibraryState(MediaLibrary library, LibraryState state, {void Function()? checkCurrent}) async {
    await ensureInitialized();
    if (isDisposed) return;
    checkCurrent?.call();
    if (isAccountLayout) {
      await _writeAccount(states: {libraryLayoutKey(library): state});
      return;
    }
    final key = library.globalKey;
    if (library.backend != MediaBackend.plex) {
      final client = _clientFor?.call(ServerId(library.serverId ?? ''));
      if (client is! JellyfinClient) {
        throw StateError('No Jellyfin or Emby client for $key');
      }
      final hidden = state != LibraryState.shown;
      if (_serverHidden.contains(key) != hidden) {
        await client.setLibraryHiddenOnServer(library.id, hidden: hidden);
        checkCurrent?.call();
        _serverHidden = hidden ? {..._serverHidden, key} : ({..._serverHidden}..remove(key));
        _onServerHiddenChanged?.call(key, hidden);
      }
      await _saveDevice(folded: {..._folded}..remove(key), off: _withOff(key, state == LibraryState.off));
    } else {
      await _saveDevice(
        folded: state == LibraryState.folded ? {..._folded, key} : ({..._folded}..remove(key)),
        off: _withOff(key, state == LibraryState.off),
      );
    }
    checkCurrent?.call();
    safeNotifyListeners();
  }

  /// Save a whole arrangement from Manage Libraries: [ordered] libraries, all
  /// of them, each with its state. Device mode saves only the states; the
  /// order goes through [LibrariesProvider] as before.
  ///
  /// [entries] places the account entries, top to bottom: each before the
  /// library at its index in [ordered], in its state.
  Future<void> saveArrangement(
    List<({MediaLibrary library, LibraryState state})> ordered, {
    List<({LayoutEntry entry, int index, LibraryState state})> entries = const [],
  }) async {
    await ensureInitialized();
    if (isDisposed) return;
    if (isAccountLayout) {
      final order = <String>[];
      final states = <String, LibraryState>{};
      var next = 0;
      void addEntriesBefore(int index) {
        while (next < entries.length && entries[next].index <= index) {
          final key = _entryKey(entries[next].entry)!;
          order.add(key);
          states[key] = entries[next].state;
          next++;
        }
      }

      for (final (index, item) in ordered.indexed) {
        addEntriesBefore(index);
        final key = libraryLayoutKey(item.library);
        order.add(key);
        states[key] = item.state;
      }
      addEntriesBefore(ordered.length);
      await _writeAccount(order: order, states: states);
      return;
    }
    for (final entry in ordered) {
      if (stateOf(entry.library) != entry.state) await setLibraryState(entry.library, entry.state);
    }
  }

  Set<String> _withOff(String key, bool off) => off ? {..._off, key} : ({..._off}..remove(key));

  Future<void> _saveDevice({required Set<String> folded, required Set<String> off}) async {
    final storage = _storageService!;
    final scopedProfileId = profileId;
    if (!setEquals(folded, _folded)) {
      if (scopedProfileId == null) {
        await storage.saveHiddenLibraries(folded);
      } else {
        await storage.saveHiddenLibrariesForProfile(scopedProfileId, folded);
      }
    }
    if (!setEquals(off, _off)) await storage.saveOffLibraries(off, profileId: scopedProfileId);
    _folded = folded;
    _off = off;
  }

  /// Fold a library on this device (device mode).
  Future<void> hideLibrary(String libraryKey, {void Function()? checkCurrent}) =>
      setLibraryHidden(libraryKey, true, checkCurrent: checkCurrent);

  Future<void> unhideLibrary(String libraryKey, {void Function()? checkCurrent}) =>
      setLibraryHidden(libraryKey, false, checkCurrent: checkCurrent);

  /// Fold or unfold [libraryKey] in the device list, by key alone.
  Future<void> setLibraryHidden(String libraryKey, bool hidden, {void Function()? checkCurrent}) async {
    await ensureInitialized();
    if (isDisposed) return;
    checkCurrent?.call();
    if (_folded.contains(libraryKey) == hidden) return;
    await _saveDevice(folded: hidden ? {..._folded, libraryKey} : ({..._folded}..remove(libraryKey)), off: _off);
    if (isDisposed) return;
    checkCurrent?.call();
    safeNotifyListeners();
  }

  /// Check if a specific library is hidden
  @visibleForTesting
  bool isLibraryHidden(String libraryKey) => _folded.contains(libraryKey);

  /// Refresh hidden libraries from storage
  /// Useful if storage was modified outside the provider
  Future<void> refresh() async {
    await _loadFromStorage();
    _isInitialized = true;
    safeNotifyListeners();
  }
}
