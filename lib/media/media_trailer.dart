import 'media_item.dart';

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
    if (_isTrailer(extra)) return extra;
  }
  return null;
}

bool _isTrailer(MediaItem extra) {
  if (extra case PlexMediaItem(:final subtype?)) return subtype.toLowerCase() == 'trailer';
  final raw = extra.raw;
  return (raw?['ExtraType'] as String?)?.toLowerCase() == 'trailer' ||
      (raw?['Type'] as String?)?.toLowerCase() == 'trailer';
}
