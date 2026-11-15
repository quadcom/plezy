import '../media/media_kind.dart';
import '../models/catalog/catalog_item.dart';
import '../models/plezyfin_titles.dart';
import '../services/catalog/catalog_source.dart';
import '../services/jellyfin_client.dart';

/// Feeds the Explore item page from a PlezyFin server instead of a catalog
/// sign-in on the device: the title's details and cast come from
/// `PlezyFin/Title`, and Request goes through `PlezyFin/Requests`, which only
/// accounts Adrian switched on may use (local/plans/search-request.md).
class PlezyFinTitleSource {
  PlezyFinTitleSource(this.client, {this.canRequest = false});

  final JellyfinClient client;

  /// Whether this account may request; updated by [fetchDetail].
  bool canRequest;

  /// Details, cast and the latest request state for [item]; null when the
  /// server has nothing (no tmdb id, refused, or no such route).
  Future<({CatalogDetail detail, PlezyFinRequestState? state})?> fetchDetail(CatalogItem item) async {
    final tmdbId = item.ids.tmdb;
    if (tmdbId == null) return null;
    final detail = await client.plezyFinTitle(item.kind, tmdbId);
    if (detail == null) return null;
    canRequest = detail.canRequest;
    final title = detail.title;
    final enriched =
        title?.toCatalogItem(
          genres: detail.genres.isEmpty ? null : detail.genres,
          runtimeMinutes: detail.runtimeMinutes,
          certification: detail.certification,
        ) ??
        item;
    return (detail: CatalogDetail(item: enriched, cast: detail.cast), state: title?.requestState);
  }

  /// Ask for [item] (a show: every season).
  Future<PlezyFinRequestResult> request(CatalogItem item) {
    final tmdbId = item.ids.tmdb;
    if (tmdbId == null) return Future.value(const PlezyFinRequestResult(ok: false));
    return client.plezyFinRequest(item.kind == MediaKind.show ? MediaKind.show : MediaKind.movie, tmdbId);
  }
}
