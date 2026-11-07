import 'media_item.dart';
import 'media_kind.dart';

/// The trailer among an item's [extras], for the fork's course and season
/// pages. Plex names it as the item's primary extra; otherwise the first
/// extra marked as a trailer: Plex `subtype="trailer"`, Jellyfin
/// `Type`/`ExtraType` "Trailer". Same rule as the detail screen's trailer
/// button. PMB gives a Master Class course at most one, from its `Trailers`
/// folder.
MediaItem? pickTrailer(MediaItem item, List<MediaItem> extras) {
  if (item case PlexMediaItem(:final trailerKey?)) {
    final primaryId = trailerKey.split('/').last;
    for (final extra in extras) {
      if (extra.id == primaryId) return extra;
    }
  }
  for (final extra in extras) {
    if (isTrailerExtra(extra)) return extra;
  }
  return null;
}

bool isTrailerExtra(MediaItem extra) {
  if (extra case PlexMediaItem(:final subtype?)) return subtype.toLowerCase() == 'trailer';
  final raw = extra.raw;
  return (raw?['ExtraType'] as String?)?.toLowerCase() == 'trailer' ||
      (raw?['Type'] as String?)?.toLowerCase() == 'trailer';
}

/// The season a trailer's name gives: "S02", "s2", "Season 2", "Season02",
/// anywhere in the name, first match wins. PMB's own rule
/// (`requests/app/trailers.py` `season_of`), shared with the web fork
/// (PlezyFin PLAN_PFN_109) so all three agree on edge cases.
final _seasonInName = RegExp(r'(?<![A-Za-z0-9])(?:season\s*(\d{1,3})|s(\d{1,3}))(?!\d)', caseSensitive: false);

/// A YouTube id PMB leaves on a downloaded file ("... [1PgKjIosF50]"). Cut
/// before matching, so an "_s12" inside one never reads as a season.
final _youTubeIdSuffix = RegExp(r'\s*\[[\w-]{11}\]$');

final _extension = RegExp(r'\.[A-Za-z0-9]{1,5}$');

/// The trailer's file name without folder or extension, when the server
/// sends its path (Jellyfin `Path`, Plex part `file`).
String? trailerFileStem(MediaItem trailer) {
  var path = trailer.raw?['Path'] as String?;
  if (path == null || path.isEmpty) {
    for (final version in trailer.mediaVersions ?? const []) {
      for (final part in version.parts) {
        final file = part.file;
        if (file != null && file.isNotEmpty) {
          path = file;
          break;
        }
      }
      if (path != null) break;
    }
  }
  if (path == null || path.isEmpty) return null;
  return path.split(RegExp(r'[/\\]')).last.replaceFirst(_extension, '');
}

/// The season named in [name], or null when it names none.
int? seasonNumberInName(String name) {
  final match = _seasonInName.firstMatch(name.replaceFirst(_youTubeIdSuffix, ''));
  if (match == null) return null;
  return int.parse((match.group(1) ?? match.group(2))!);
}

/// The season a trailer is named for, or null when it names none. Reads the
/// file name first: Jellyfin titles are unreliable (both of WAR's trailers
/// are titled "WAR"), then the title.
int? trailerSeasonNumber(MediaItem trailer) {
  final stem = trailerFileStem(trailer);
  final fromFile = stem == null ? null : seasonNumberInName(stem);
  return fromFile ?? seasonNumberInName(trailer.title ?? '');
}

/// One season's trailer: its own (from the season's [seasonExtras]) first,
/// else the show trailer named for [seasonNumber]. Never another season's.
/// The show page's Season trailers row uses this.
MediaItem? pickSeasonTrailer({
  required int? seasonNumber,
  required List<MediaItem> seasonExtras,
  required List<MediaItem> showExtras,
}) {
  for (final extra in seasonExtras) {
    if (isTrailerExtra(extra)) return extra;
  }
  if (seasonNumber == null || seasonNumber <= 0) return null;
  for (final extra in showExtras) {
    if (isTrailerExtra(extra) && trailerSeasonNumber(extra) == seasonNumber) return extra;
  }
  return null;
}

/// The trailer a season page's button plays, and whether it is the show's
/// rather than the season's. The season's own, then the show trailer named
/// for this season, then the show's first trailer that names no season
/// (Adrian, 2026-11-07: "every season missing its trailer will play the
/// show's trailer"). A show trailer named for another season is never used.
/// Same order as the web fork (PLAN_PFN_109).
({MediaItem trailer, bool isShowTrailer})? pickSeasonPageTrailer({
  required int? seasonNumber,
  required List<MediaItem> seasonExtras,
  required List<MediaItem> showExtras,
}) {
  final own = pickSeasonTrailer(seasonNumber: seasonNumber, seasonExtras: seasonExtras, showExtras: showExtras);
  if (own != null) return (trailer: own, isShowTrailer: false);
  for (final extra in showExtras) {
    if (isTrailerExtra(extra) && trailerSeasonNumber(extra) == null) return (trailer: extra, isShowTrailer: true);
  }
  return null;
}

/// A season page's Trailers & Extras row: the season's trailers, then its
/// other extras, then the show's extras, each item once. A show trailer
/// named for another season is left out. Same as the web fork (PLAN_PFN_109).
List<MediaItem> seasonPageExtras({
  required int? seasonNumber,
  required List<MediaItem> seasonExtras,
  required List<MediaItem> showExtras,
}) {
  final seen = <String>{};
  bool otherSeasons(MediaItem extra) {
    if (seasonNumber == null || !isTrailerExtra(extra)) return false;
    final named = trailerSeasonNumber(extra);
    return named != null && named != seasonNumber;
  }

  return [
    for (final extra in seasonExtras)
      if (isTrailerExtra(extra) && seen.add(extra.id)) extra,
    for (final extra in seasonExtras)
      if (!isTrailerExtra(extra) && seen.add(extra.id)) extra,
    for (final extra in showExtras)
      if (!otherSeasons(extra) && seen.add(extra.id)) extra,
  ];
}

/// The trailer a show's Trailer button plays: the show trailer named for
/// the highest season, else [pickTrailer], else [newestSeasonTrailer] (the
/// highest season's own, when the show has none). Other items keep
/// [pickTrailer].
MediaItem? pickShowTrailer(MediaItem item, List<MediaItem> extras, {MediaItem? newestSeasonTrailer}) {
  if (item.kind != MediaKind.show) return pickTrailer(item, extras);
  MediaItem? newest;
  var newestSeason = 0;
  for (final extra in extras) {
    if (!isTrailerExtra(extra)) continue;
    final season = trailerSeasonNumber(extra);
    if (season != null && season > newestSeason) {
      newest = extra;
      newestSeason = season;
    }
  }
  return newest ?? pickTrailer(item, extras) ?? newestSeasonTrailer;
}
