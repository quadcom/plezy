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

/// PMB names a season's trailer `<Show> S<NN>-trailer.<ext>` (PLAN_PMB_56),
/// which both servers title `<Show> S<NN>`.
final _seasonTrailerTitle = RegExp(r'\bS(\d{1,3})(?:[-_ ]?trailer)?\s*$', caseSensitive: false);

/// The season a trailer is named for, or null when its title names none.
/// Same rule as the web fork (PlezyFin PLAN_SHA_55).
int? trailerSeasonNumber(MediaItem trailer) {
  final match = _seasonTrailerTitle.firstMatch(trailer.title ?? '');
  return match == null ? null : int.parse(match.group(1)!);
}

/// One season's trailer: its own (from the season's [seasonExtras]) first,
/// else the show trailer named for [seasonNumber]. Never another season's.
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
