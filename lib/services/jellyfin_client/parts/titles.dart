part of '../../jellyfin_client.dart';

/// Titles from outside the library through a PlezyFin server: a cast member's
/// details and filmography (PLAN_PFN_114), search and one title's details
/// (PLAN_PFN_115), and requests to Radarr/Sonarr through the server's Seerr,
/// allowed only for accounts Adrian switched on. Plans:
/// local/plans/person-page.md, local/plans/search-request.md.
///
/// Each call is made once per page open or finished search, never on a timer;
/// the server caches TMDb and Seerr answers.
mixin _JellyfinTitleMethods on _JellyfinClientInternals {
  /// `GET /PlezyFin/Person/{personId}`. Null when the server has no such
  /// route (not PlezyFin, or an older one); other failures throw.
  Future<PlezyFinPersonPage?> plezyFinPerson(String personId) async {
    final response = await _http.get('/PlezyFin/Person/${_segment(personId)}');
    if (response.statusCode == 404) return null;
    throwIfHttpError(response);
    return PlezyFinPersonPage.fromJson(response.data);
  }

  /// `GET /PlezyFin/Search?q=`: films and shows on TMDb matching [query]. Null
  /// when this account may not request (403) or the route is missing (404):
  /// search then stays library-only. Other failures throw.
  Future<PlezyFinTitleSearch?> plezyFinTitleSearch(String query) async {
    if (query.trim().length < 2) return const PlezyFinTitleSearch();
    final response = await _http.get('/PlezyFin/Search', queryParameters: {'q': query.trim()});
    if (response.statusCode == 403 || response.statusCode == 404) return null;
    throwIfHttpError(response);
    return PlezyFinTitleSearch.fromJson(response.data);
  }

  /// `GET /PlezyFin/Title/{movie|tv}/{tmdbId}`: one title's details and cast.
  /// Null when refused or missing; other failures throw.
  Future<PlezyFinTitleDetail?> plezyFinTitle(MediaKind kind, int tmdbId) async {
    final type = kind == MediaKind.show ? 'tv' : 'movie';
    final response = await _http.get('/PlezyFin/Title/$type/$tmdbId');
    if (response.statusCode == 403 || response.statusCode == 404) return null;
    throwIfHttpError(response);
    return PlezyFinTitleDetail.fromJson(response.data);
  }

  /// `POST /PlezyFin/Requests`: a show asks for every season. Refusals
  /// (403 switch off, 409 already in the library, 400, 503 no Seerr) come
  /// back as a result with the server's sentence, not a throw.
  Future<PlezyFinRequestResult> plezyFinRequest(MediaKind kind, int tmdbId) async {
    final response = await _http.post(
      '/PlezyFin/Requests',
      body: {'TmdbId': tmdbId, 'MediaType': kind == MediaKind.show ? 'tv' : 'movie'},
    );
    if (response.statusCode >= 400 && response.statusCode < 600 && response.statusCode != 401) {
      return PlezyFinRequestResult.fromJson(response.data, statusCode: response.statusCode);
    }
    throwIfHttpError(response);
    return PlezyFinRequestResult.fromJson(response.data, statusCode: response.statusCode);
  }
}
