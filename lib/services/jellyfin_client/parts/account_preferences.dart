part of '../../jellyfin_client.dart';

Map<String, dynamic>? _accountConfiguration(Object? userDto) {
  if (userDto is! Map<String, dynamic>) {
    throw const FormatException('MediaBrowser current-user response is not an object');
  }
  final configuration = userDto['Configuration'];
  if (configuration == null) return null;
  if (configuration is Map<String, dynamic>) return configuration;
  throw const FormatException('MediaBrowser user Configuration is not an object');
}

/// The user's server-side hidden libraries (`Configuration.MyMediaExcludes`),
/// as [mediaBrowserIdKey]s, or `null` when [response] cannot say.
Set<String>? _myMediaExcludes(MediaServerResponse? response) {
  if (response == null || response.statusCode < 200 || response.statusCode >= 300) return null;
  try {
    final excludes = _accountConfiguration(response.data)?['MyMediaExcludes'];
    if (excludes is! List) return const {};
    return {
      for (final id in excludes)
        if (id is String) mediaBrowserIdKey(id),
    };
  } on FormatException {
    return null;
  }
}

/// Keys stored in the account's `DisplayPreferences` row rather than
/// `UserConfiguration`, which has no field for either on any dialect.
const _displayPreferenceKeys = {AccountPreferenceKey.rewatchingInNextUp, AccountPreferenceKey.searchScope};

/// Account preferences span two server stores: `UserConfiguration` for the
/// language, subtitle and library fields, and the account's
/// `DisplayPreferences` row for [_displayPreferenceKeys].
mixin _JellyfinAccountPreferencesMethods on _JellyfinClientInternals {
  Map<String, String> get _displayPreferencesQuery => {
    'userId': connection.userId,
    'client': JellyfinDisplayPreferences.client,
  };

  Future<AccountPreferences> fetchAccountPreferences({void Function()? checkCurrent}) async {
    // Independent rows on the same server; the pair costs one round trip.
    final responses = await Future.wait([
      _http.get(paths.currentUser),
      _http.get(
        MediaBrowserPaths.displayPreferences(JellyfinDisplayPreferences.displayPreferencesId),
        queryParameters: _displayPreferencesQuery,
      ),
    ]);
    for (final response in responses) {
      throwIfHttpError(response);
    }

    final rewatching = JellyfinDisplayPreferences.readRewatchingInNextUp(responses[1].data);
    final searchScope = JellyfinDisplayPreferences.readSearchScope(responses[1].data);
    checkCurrent?.call();
    _rewatchingInNextUp = rewatching ?? false;
    return JellyfinAccountPreferences.fromConfiguration(
      _accountConfiguration(responses.first.data) ?? const {},
      rewatchingInNextUp: rewatching,
      searchScope: searchScope,
    );
  }

  Future<AccountPreferences> updateAccountPreferences(
    AccountPreferencesPatch patch, {
    void Function()? checkCurrent,
  }) async {
    (dialect == MediaBrowserDialect.emby
            ? AccountPreferencesCapabilities.emby
            : AccountPreferencesCapabilities.jellyfin)
        .validate(patch);
    checkCurrent?.call();
    final configurationPatch = AccountPreferencesPatch({
      for (final entry in patch.values.entries)
        if (!_displayPreferenceKeys.contains(entry.key)) entry.key: entry.value,
    });

    final customPrefs = <String, String>{
      if (patch.contains(AccountPreferenceKey.rewatchingInNextUp))
        // Values are strings on this API; `true`/`false` matches what
        // jellyfin-web writes for its own boolean prefs.
        JellyfinDisplayPreferences.rewatchingInNextUpKey: patch
            .boolAt(AccountPreferenceKey.rewatchingInNextUp)!
            .toString(),
      if (patch.contains(AccountPreferenceKey.searchScope))
        JellyfinDisplayPreferences.searchScopeKey: SearchScopeKind.encode(
          patch[AccountPreferenceKey.searchScope]! as Set<SearchScopeKind>,
        ),
    };
    if (customPrefs.isNotEmpty) {
      await _writeDisplayPreferences(customPrefs, checkCurrent: checkCurrent);
      if (patch.contains(AccountPreferenceKey.rewatchingInNextUp)) {
        _rewatchingInNextUp = patch.boolAt(AccountPreferenceKey.rewatchingInNextUp)!;
      }
    }
    if (configurationPatch.isEmpty) {
      // Re-read so the caller still gets the whole account, including the
      // fields this write did not touch.
      return fetchAccountPreferences(checkCurrent: checkCurrent);
    }

    final readResponse = await _http.get(paths.currentUser);
    throwIfHttpError(readResponse);
    final configuration = _accountConfiguration(readResponse.data);
    if (configuration == null) {
      throw const FormatException('MediaBrowser current-user response omitted Configuration');
    }
    final merged = JellyfinAccountPreferences.mergePatch(configuration, configurationPatch);
    checkCurrent?.call();

    final writeResponse = await _http.post(paths.userConfiguration, body: merged);
    throwIfHttpError(writeResponse);
    checkCurrent?.call();
    return fetchAccountPreferences(checkCurrent: checkCurrent);
  }

  /// Hide or show [libraryId] for this user on the server, as the web
  /// client's hide does: its id goes into or out of
  /// `Configuration.MyMediaExcludes`. The POST replaces the whole
  /// configuration, so it travels back with only that list changed.
  Future<void> setLibraryHiddenOnServer(String libraryId, {required bool hidden}) async {
    final readResponse = await _http.get(paths.currentUser);
    throwIfHttpError(readResponse);
    final configuration = _accountConfiguration(readResponse.data);
    if (configuration == null) {
      throw const FormatException('MediaBrowser current-user response omitted Configuration');
    }
    final target = mediaBrowserIdKey(libraryId);
    final current = configuration['MyMediaExcludes'];
    final excludes = [
      if (current is List)
        for (final id in current)
          if (id is String && mediaBrowserIdKey(id) != target) id,
      if (hidden) libraryId,
    ];
    final writeResponse = await _http.post(
      paths.userConfiguration,
      body: {...configuration, 'MyMediaExcludes': excludes},
    );
    throwIfHttpError(writeResponse);
  }

  /// Read-modify-write the `DisplayPreferences` row: the `POST` replaces it, so
  /// anything already in `CustomPrefs` has to travel back with the change.
  Future<void> _writeDisplayPreferences(Map<String, String> values, {void Function()? checkCurrent}) async {
    final path = MediaBrowserPaths.displayPreferences(JellyfinDisplayPreferences.displayPreferencesId);
    final readResponse = await _http.get(path, queryParameters: _displayPreferencesQuery);
    throwIfHttpError(readResponse);

    final merged = JellyfinDisplayPreferences.mergeCustomPrefs(readResponse.data, values);
    checkCurrent?.call();
    final writeResponse = await _http.post(path, queryParameters: _displayPreferencesQuery, body: merged);
    throwIfHttpError(writeResponse);
    checkCurrent?.call();
  }
}
