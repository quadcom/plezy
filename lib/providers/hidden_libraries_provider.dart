import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  /// The admin's default layout, for row titles the user has not set.
  LibraryLayout? _defaults;

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

  /// The Favourites entry's key, when the account has one.
  String? get _favoritesKey => isAccountLayout ? favoritesLayoutKey(_ownServerId!) : null;

  /// Where the Favourites entry sits: shown, folded or not shown. Null when
  /// there is no PlezyFin account to show it from.
  LibraryState? get favoritesState {
    final key = _favoritesKey;
    if (key == null || _account == null) return null;
    return _layout!.stateOf(key, ownServerId: _ownServerId);
  }

  /// Where the Favourites entry goes among [ordered] libraries: the number of
  /// them the account places before it.
  int favoritesIndexIn(List<MediaLibrary> ordered) {
    final key = _favoritesKey;
    if (key == null) return ordered.length;
    final arranged = _layout!.arrangeKeys(_managedKeys(), ownServerId: _ownServerId).order;
    final rank = {for (final (index, k) in arranged.indexed) k: index};
    final favoritesRank = rank[key] ?? rank.length;
    return ordered.where((library) => (rank[libraryLayoutKey(library)] ?? rank.length) < favoritesRank).length;
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
    if (ownServerId != null) byServer.putIfAbsent(ownServerId, () => []).add('favorites');
    return byServer;
  }

  /// Every key this device manages: the libraries in the list's order, then
  /// the views Plezy does not list, then Favourites, which starts after the
  /// libraries (PlezyFin, 2026-10-09).
  List<String> _managedKeys() {
    final keys = [
      for (final library in _libraries)
        if (library.serverId != null) libraryLayoutKey(library),
    ];
    final byServer = _managedLibrariesByServer();
    for (final pass in [false, true]) {
      for (final entry in byServer.entries) {
        for (final id in entry.value) {
          if ((id == 'favorites') != pass) continue;
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
    final arranged = fresh.arrangeKeys(_managedKeys(), ownServerId: ownServerId);
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
  /// [favorites] places the Favourites entry: before the library at its index
  /// in [ordered], in its state.
  Future<void> saveArrangement(
    List<({MediaLibrary library, LibraryState state})> ordered, {
    ({int index, LibraryState state})? favorites,
  }) async {
    await ensureInitialized();
    if (isDisposed) return;
    if (isAccountLayout) {
      final order = [for (final entry in ordered) libraryLayoutKey(entry.library)];
      final states = {for (final entry in ordered) libraryLayoutKey(entry.library): entry.state};
      final favoritesKey = _favoritesKey;
      if (favorites != null && favoritesKey != null) {
        order.insert(favorites.index.clamp(0, order.length), favoritesKey);
        states[favoritesKey] = favorites.state;
      }
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
