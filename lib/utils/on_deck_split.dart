import '../media/media_item.dart';

/// Whether an on-deck item has been started: any resume point counts, with or
/// without a known run time (items Plex Media Bridge adds to Jellyfin often
/// carry none). Started items make Continue Watching; the rest, Next Up
/// (Adrian, 2026-10-09).
bool isOnDeckStarted(MediaItem item) => (item.viewOffsetMs ?? 0) > 0;

/// [items] cut to at most [limit] started items and at most [limit] others,
/// keeping their order. Continue Watching and Next Up are separate rows, so a
/// cap over the mixed list let recent Next Up episodes push every started item
/// out (Adrian's home showed no Continue Watching, 2026-10-09).
List<MediaItem> limitOnDeckPerKind(List<MediaItem> items, int? limit) {
  if (limit == null) return items;
  var started = 0;
  var others = 0;
  final result = <MediaItem>[];
  for (final item in items) {
    if (isOnDeckStarted(item)) {
      if (started++ < limit) result.add(item);
    } else {
      if (others++ < limit) result.add(item);
    }
  }
  return result.length == items.length ? items : result;
}

/// Whether [items] hold more than [limit] of either kind.
bool exceedsOnDeckPerKind(List<MediaItem> items, int limit) {
  var started = 0;
  var others = 0;
  for (final item in items) {
    if (isOnDeckStarted(item) ? ++started > limit : ++others > limit) return true;
  }
  return false;
}
