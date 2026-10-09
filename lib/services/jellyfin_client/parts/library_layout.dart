part of '../../jellyfin_client.dart';

/// Where PlezyFin keeps each user's library layout (agreed with the PlezyFin
/// session, 2026-10-09; plan `local/plans/library-states.md`).
abstract final class PlezyFinLayoutStore {
  static const displayPreferencesId = 'plezyfin-libraries';
  static const client = 'plezyfin';

  /// CustomPrefs key; its value is the [LibraryLayout] record as a JSON string.
  static const key = 'layout';

  /// GET (any signed-in user): 200 with the admin's default record, 204 when
  /// none is set.
  static const defaultsPath = '/PlezyFin/LibraryDefaults';
}

mixin _JellyfinLibraryLayoutMethods on _JellyfinClientInternals {
  Future<String?>? _plezyFinVersion;

  /// The server's PlezyFin layout level from `/System/Info/Public`, or null
  /// for stock Jellyfin and Emby. A failed read is retried on the next call.
  Future<String?> plezyFinVersion() => _plezyFinVersion ??= _readPlezyFinVersion();

  Future<String?> _readPlezyFinVersion() async {
    try {
      final response = await _http.get('/System/Info/Public');
      throwIfHttpError(response);
      final data = response.data;
      final version = data is Map<String, dynamic> ? data['PlezyFinVersion'] : null;
      return version is String && version.isNotEmpty ? version : null;
    } catch (e) {
      appLogger.d('JellyfinClient: PlezyFin check failed: $e');
      _plezyFinVersion = null;
      return null;
    }
  }

  /// This server's half of its libraries' layout keys.
  String get layoutServerId => mediaBrowserIdKey(connection.serverMachineId);

  String get _layoutPath => MediaBrowserPaths.displayPreferences(PlezyFinLayoutStore.displayPreferencesId);

  Map<String, String> get _layoutQuery => {'userId': connection.userId, 'client': PlezyFinLayoutStore.client};

  /// The user's stored layout, or null when they have none yet.
  Future<LibraryLayout?> fetchLibraryLayout() async {
    final response = await _http.get(_layoutPath, queryParameters: _layoutQuery);
    throwIfHttpError(response);
    final prefs = _layoutCustomPrefs(response.data);
    final raw = prefs[PlezyFinLayoutStore.key];
    return LibraryLayout.tryParse(raw is String ? raw : null);
  }

  /// The admin's default layout, or null when none is set.
  Future<LibraryLayout?> fetchLibraryLayoutDefaults() async {
    final response = await _http.get(PlezyFinLayoutStore.defaultsPath);
    if (response.statusCode == 204) return null;
    throwIfHttpError(response);
    final data = response.data;
    return data is Map<String, dynamic> ? LibraryLayout.fromJson(data) : null;
  }

  /// Store [layout], then mirror this server's part into the user
  /// configuration the way the PlezyFin web client does: folded and off
  /// libraries into `MyMediaExcludes`, the order into `OrderedViews`, so other
  /// Jellyfin apps follow as far as they can.
  ///
  /// The DisplayPreferences POST replaces the whole row, so the rest of it
  /// travels back unchanged.
  Future<void> saveLibraryLayout(LibraryLayout layout) async {
    final readResponse = await _http.get(_layoutPath, queryParameters: _layoutQuery);
    throwIfHttpError(readResponse);
    final dto = readResponse.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(readResponse.data as Map<String, dynamic>)
        : <String, dynamic>{};
    dto['CustomPrefs'] = {..._layoutCustomPrefs(dto), PlezyFinLayoutStore.key: layout.encode()};
    final writeResponse = await _http.post(_layoutPath, queryParameters: _layoutQuery, body: dto);
    throwIfHttpError(writeResponse);
    await _mirrorLayoutIntoConfiguration(layout);
  }

  Future<void> _mirrorLayoutIntoConfiguration(LibraryLayout layout) async {
    final prefix = '$layoutServerId/';
    final ordered = [
      for (final key in layout.order)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    ];
    final excluded = [
      for (final entry in layout.state.entries)
        if (entry.key.startsWith(prefix) && entry.value != LibraryState.shown) entry.key.substring(prefix.length),
    ];
    final readResponse = await _http.get(paths.currentUser);
    throwIfHttpError(readResponse);
    final configuration = _accountConfiguration(readResponse.data);
    if (configuration == null) {
      throw const FormatException('MediaBrowser current-user response omitted Configuration');
    }
    final writeResponse = await _http.post(
      paths.userConfiguration,
      body: {...configuration, 'MyMediaExcludes': excluded, 'OrderedViews': ordered},
    );
    throwIfHttpError(writeResponse);
  }

  static Map<String, dynamic> _layoutCustomPrefs(Object? dto) {
    if (dto is! Map<String, dynamic>) return const {};
    final prefs = dto['CustomPrefs'];
    return prefs is Map<String, dynamic> ? prefs : const {};
  }
}
