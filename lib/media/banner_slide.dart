import 'media_item.dart';

/// What a home banner slide shows (PlezyFin PLAN_SHA_16, Adrian 2026-10-10).
enum BannerKind {
  /// Continue Watching and Next Up, as the banner always showed them; kept
  /// for devices without a PlezyFin account.
  onDeck,

  /// A new film in Movies.
  newMovie,

  /// A new episode of a show in TV.
  newEpisode,

  /// A Coming Soon film with a future release date.
  comingSoon,

  /// A New Shows series with a future first air date.
  newShow,
}

/// One slide of the home banner.
class BannerSlide {
  final MediaItem item;
  final BannerKind kind;

  const BannerSlide(this.item, this.kind);

  /// Coming Soon and New Shows slides: release date and trailer instead of
  /// Play.
  bool get isUpcoming => kind == BannerKind.comingSoon || kind == BannerKind.newShow;

  /// The release date an upcoming slide shows: the server's date as it is,
  /// with no time zone shift (Jellyfin stores midnight UTC, and the day
  /// before showed west of Greenwich on the web, 2026-10-10).
  DateTime? get releaseDate {
    final raw = item.originallyAvailableAt;
    return raw == null ? null : DateTime.tryParse(raw);
  }

  @override
  bool operator ==(Object other) =>
      other is BannerSlide && other.kind == kind && other.item.globalKey == item.globalKey;

  @override
  int get hashCode => Object.hash(kind, item.globalKey);
}

/// The banner's library names on the PlezyFin server, matched whole and
/// ignoring case: Adrian names his libraries, so the banner names them too
/// (2026-10-10).
abstract final class BannerLibraries {
  static const movies = 'movies';
  static const tv = 'tv';
  static const comingSoon = 'coming soon';
  static const newShows = 'new shows';
}

/// The banner's slide count: 15 new and 5 upcoming.
const bannerNewSlides = 15;
const bannerUpcomingSlides = 5;

/// [fresh] and [upcoming] mixed the way the banner shows them: three new
/// slides, then an upcoming one, so upcoming items land on slides 4, 8, 12,
/// 16 and 20. When either list runs short the rest close up; nothing is
/// padded.
List<BannerSlide> interleaveBanner(List<BannerSlide> fresh, List<BannerSlide> upcoming) {
  final newQueue = fresh.take(bannerNewSlides).toList();
  final upcomingQueue = upcoming.take(bannerUpcomingSlides).toList();
  final result = <BannerSlide>[];
  var n = 0;
  var u = 0;
  for (var slot = 1; slot <= bannerNewSlides + bannerUpcomingSlides; slot++) {
    if (slot % 4 == 0) {
      if (u < upcomingQueue.length) result.add(upcomingQueue[u++]);
    } else if (n < newQueue.length) {
      result.add(newQueue[n++]);
    }
  }
  return result;
}

/// The banner's "upcoming" cut-off for `MinPremiereDate`: today's local
/// calendar day at midnight UTC, the way release dates are stored, so a title
/// stays upcoming through its release day instead of leaving the evening
/// before (PlezyFin PLAN_SHA_16 correction, 2026-10-10).
String bannerUpcomingFrom(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}T00:00:00Z';
}
