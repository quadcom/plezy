part of '../../jellyfin_client.dart';

/// Subtitle search through a PlezyFin server (PlezyFin PLAN_PFN_103, routes
/// `PlezyFin/Subtitles`): the server asks Bazarr, so no provider login or
/// key ever reaches a device. Plan: local/plans/subtitle-search-plezyfin.md.
mixin _JellyfinSubtitleMethods on _JellyfinClientInternals {
  static const _base = '/PlezyFin/Subtitles';

  /// How long a failed status read (not a 404) keeps the row hidden before
  /// the next player open may ask again.
  static const _statusRetryAfter = Duration(minutes: 5);

  PlezyFinSubtitleStatus? _subtitleStatus;
  bool _subtitleStatusKnown = false;
  DateTime? _subtitleStatusFailedAt;
  Future<PlezyFinSubtitleStatus?>? _subtitleStatusRequest;

  /// Whether the player may offer "Search subtitles": the route exists and
  /// says Enabled and Allowed. Null until [subtitleSearchStatus] has
  /// answered once for this connection, and again five minutes after a
  /// failed read, so the next player open asks once more.
  bool? get cachedSubtitleSearchAvailable {
    if (_subtitleStatusKnown) return _subtitleStatus?.searchAvailable ?? false;
    final failedAt = _subtitleStatusFailedAt;
    if (failedAt != null && DateTime.now().difference(failedAt) < _statusRetryAfter) return false;
    return null;
  }

  /// A status read is in flight.
  bool get subtitleSearchStatusPending => _subtitleStatusRequest != null;

  /// `GET /PlezyFin/Subtitles/Status`, read once per connection and kept:
  /// later calls return the same answer without a request. A 404 (not a
  /// PlezyFin server, or an older one) is kept as "no support". Any other
  /// failure hides the row too, and is asked again after five minutes at the
  /// earliest. Concurrent callers share one request.
  Future<PlezyFinSubtitleStatus?> subtitleSearchStatus() {
    if (_subtitleStatusKnown) return Future.value(_subtitleStatus);
    final failedAt = _subtitleStatusFailedAt;
    if (failedAt != null && DateTime.now().difference(failedAt) < _statusRetryAfter) return Future.value();
    return _subtitleStatusRequest ??= _readSubtitleStatus().whenComplete(() => _subtitleStatusRequest = null);
  }

  Future<PlezyFinSubtitleStatus?> _readSubtitleStatus() async {
    try {
      final response = await _http.get('$_base/Status');
      if (response.statusCode == 404) {
        _subtitleStatus = null;
        _subtitleStatusKnown = true;
        return null;
      }
      throwIfHttpError(response);
      _subtitleStatus = PlezyFinSubtitleStatus.fromJson(response.data);
      _subtitleStatusKnown = true;
      _subtitleStatusFailedAt = null;
      return _subtitleStatus;
    } catch (e) {
      appLogger.w('JellyfinClient: PlezyFin subtitle status failed', error: e);
      _subtitleStatusFailedAt = DateTime.now();
      return null;
    }
  }

  /// `GET /PlezyFin/Subtitles/Search` for [itemId] (a film or an episode).
  /// [mediaSourceId] is the version playing; [language] a two-letter code.
  /// [forced] / [hearingImpaired] filter only when given. A 200 always comes
  /// back, found or not; HTTP failures throw.
  Future<PlezyFinSubtitleSearch> searchSubtitlesViaServer(
    String itemId, {
    String? mediaSourceId,
    required String language,
    bool? forced,
    bool? hearingImpaired,
  }) async {
    final response = await _http.get(
      '$_base/Search',
      queryParameters: {
        'itemId': itemId,
        if (mediaSourceId != null && mediaSourceId.isNotEmpty) 'mediaSourceId': mediaSourceId,
        'language': language,
        if (forced != null) 'forced': '$forced',
        if (hearingImpaired != null) 'hearingImpaired': '$hearingImpaired',
      },
    );
    throwIfHttpError(response);
    return PlezyFinSubtitleSearch.fromJson(response.data);
  }

  /// `POST /PlezyFin/Subtitles/Download` for a search result's [id]. The
  /// answer comes once the file is saved; the server then refreshes the item.
  /// A refusal (403 not allowed, 400 no item) comes back as a result with
  /// its status, not a throw, so the sheet can show the server's sentence.
  Future<PlezyFinSubtitleDownload> downloadSubtitleViaServer(String id, {String? itemId}) async {
    final response = await _http.post('$_base/Download', body: {'Id': id, 'ItemId': ?itemId});
    if (response.statusCode >= 400 && response.statusCode < 500) {
      return PlezyFinSubtitleDownload.fromJson(response.data, statusCode: response.statusCode);
    }
    throwIfHttpError(response);
    return PlezyFinSubtitleDownload.fromJson(response.data, statusCode: response.statusCode);
  }
}
