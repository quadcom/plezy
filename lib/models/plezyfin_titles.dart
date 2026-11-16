/// Titles from outside the library, through a PlezyFin server: a cast
/// member's details and filmography (PlezyFin PLAN_PFN_114,
/// `PlezyFin/Person`), search beyond the library and one title's details
/// (PLAN_PFN_115, `PlezyFin/Search`, `PlezyFin/Title`), and requests
/// (`PlezyFin/Requests`, per-account switch). Plans:
/// local/plans/person-page.md, local/plans/search-request.md.
///
/// The readers take PascalCase (the server's casing) or camelCase keys, and
/// a missing field reads as empty rather than failing the whole answer.
library;

import '../media/media_kind.dart';
import '../utils/json_utils.dart';
import 'catalog/catalog_cast_member.dart';
import 'catalog/catalog_item.dart';

Object? _field(Map json, String name) => json[name] ?? json[name[0].toLowerCase() + name.substring(1)];

String? _text(Map json, String name) {
  final value = _field(json, name)?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

DateTime? _date(Map json, String name) {
  final text = _text(json, name);
  return text == null ? null : DateTime.tryParse(text);
}

List<Object?> _list(Map json, String name) {
  final value = _field(json, name);
  return value is List ? value : const [];
}

/// Where a title stands with Seerr for this server.
enum PlezyFinRequestState {
  none,
  requested,
  processing,
  partial,
  available,
  blocked;

  /// Null when the server didn't say (Seerr not set up or unreachable).
  static PlezyFinRequestState? parse(String? value) {
    if (value == null) return null;
    for (final state in values) {
      if (state.name == value.toLowerCase()) return state;
    }
    return null;
  }

  /// A request can still be made: nothing asked for yet, or only some
  /// seasons of a show.
  bool get canAsk => this == none || this == partial;
}

/// One film or show from TMDb: a search result, or one of a person's
/// credits (then [role], [character], [job] and [episodeCount] are set).
class PlezyFinTitle {
  final MediaKind kind;
  final int tmdbId;
  final String title;
  final int? year;

  /// Film release or show first air date; null when TMDb has none.
  final DateTime? releaseDate;
  final String? posterUrl;
  final String? backdropUrl;
  final String? overview;
  final double popularity;

  /// The library item when this account can see it in the library.
  final String? itemId;
  final PlezyFinRequestState? requestState;

  /// Person credits only: "cast" or "crew".
  final String? role;
  final String? character;
  final String? job;
  final int? episodeCount;

  const PlezyFinTitle({
    required this.kind,
    required this.tmdbId,
    required this.title,
    this.year,
    this.releaseDate,
    this.posterUrl,
    this.backdropUrl,
    this.overview,
    this.popularity = 0,
    this.itemId,
    this.requestState,
    this.role,
    this.character,
    this.job,
    this.episodeCount,
  });

  bool get inLibrary => itemId != null;

  /// Not out yet on [today] (a film's release, a show's first air date).
  bool isUpcoming(DateTime today) {
    final date = releaseDate;
    if (date == null) return false;
    return DateTime(date.year, date.month, date.day).isAfter(DateTime(today.year, today.month, today.day));
  }

  static PlezyFinTitle? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = switch (_text(json, 'MediaType')?.toLowerCase()) {
      'movie' => MediaKind.movie,
      'tv' => MediaKind.show,
      _ => null,
    };
    final tmdbId = flexibleInt(_field(json, 'TmdbId'));
    final title = _text(json, 'Title');
    if (kind == null || tmdbId == null || title == null) return null;
    final releaseDate = _date(json, 'ReleaseDate');
    return PlezyFinTitle(
      kind: kind,
      tmdbId: tmdbId,
      title: title,
      year: flexibleInt(_field(json, 'Year')) ?? releaseDate?.year,
      releaseDate: releaseDate,
      posterUrl: _text(json, 'PosterUrl'),
      backdropUrl: _text(json, 'BackdropUrl'),
      overview: _text(json, 'Overview'),
      popularity: flexibleDouble(_field(json, 'Popularity')) ?? 0,
      itemId: _text(json, 'ItemId'),
      requestState: PlezyFinRequestState.parse(_text(json, 'RequestState')),
      role: _text(json, 'Role'),
      character: _text(json, 'Character'),
      job: _text(json, 'Job'),
      episodeCount: flexibleInt(_field(json, 'EpisodeCount')),
    );
  }

  static List<PlezyFinTitle> listFromJson(List<Object?> json) => [for (final entry in json) ?fromJson(entry)];

  /// The Explore item page's shape, so a title opens on that page.
  CatalogItem toCatalogItem({List<String>? genres, int? runtimeMinutes, String? certification}) => CatalogItem(
    // TMDb data, as Seerr serves it; the page is given its PlezyFin source
    // directly, so this id never picks a per-device Seerr sign-in.
    source: CatalogSourceId.seerr,
    kind: kind,
    title: title,
    year: year,
    overview: overview,
    runtimeMinutes: runtimeMinutes,
    genres: genres,
    certification: certification,
    ids: CatalogItemIds(tmdb: tmdbId),
    posterUrl: posterUrl,
    backdropUrl: backdropUrl,
    releaseDate: releaseDate,
  );
}

/// `GET PlezyFin/Person/{personId}`'s person.
class PlezyFinPerson {
  final String? id;
  final String name;
  final String? imageTag;
  final String? profileUrl;
  final String? biography;
  final DateTime? birthday;
  final DateTime? deathday;
  final String? placeOfBirth;
  final String? knownForDepartment;
  final int? tmdbId;

  const PlezyFinPerson({
    this.id,
    required this.name,
    this.imageTag,
    this.profileUrl,
    this.biography,
    this.birthday,
    this.deathday,
    this.placeOfBirth,
    this.knownForDepartment,
    this.tmdbId,
  });

  static PlezyFinPerson? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = _text(json, 'Name');
    if (name == null) return null;
    return PlezyFinPerson(
      id: _text(json, 'Id'),
      name: name,
      imageTag: _text(json, 'ImageTag'),
      profileUrl: _text(json, 'ProfileUrl'),
      biography: cleanBiography(_text(json, 'Biography')),
      birthday: _date(json, 'Birthday'),
      deathday: _date(json, 'Deathday'),
      placeOfBirth: _text(json, 'PlaceOfBirth'),
      knownForDepartment: _text(json, 'KnownForDepartment'),
      tmdbId: flexibleInt(_field(json, 'TmdbId')),
    );
  }

  static final _wikipediaCredit = RegExp(r'\s*Description above from the Wikipedia article[\s\S]*$');

  /// TMDb's bio without its closing "Description above from the Wikipedia
  /// article ..." credit line (local/plans/person-page-tv.md).
  static String? cleanBiography(String? bio) {
    if (bio == null) return null;
    final cleaned = bio.replaceFirst(_wikipediaCredit, '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  /// Age in whole years today, or at death.
  int? ageOn(DateTime today) {
    final born = birthday;
    if (born == null) return null;
    final end = deathday ?? today;
    var age = end.year - born.year;
    if (end.month < born.month || (end.month == born.month && end.day < born.day)) age--;
    return age < 0 ? null : age;
  }
}

/// `GET PlezyFin/Person/{personId}`.
class PlezyFinPersonPage {
  final PlezyFinPerson? person;
  final List<PlezyFinTitle> credits;
  final bool canRequest;

  /// One sentence when part of the page could not be filled.
  final String? message;

  const PlezyFinPersonPage({this.person, this.credits = const [], this.canRequest = false, this.message});

  static PlezyFinPersonPage fromJson(Object? json) {
    if (json is! Map) return const PlezyFinPersonPage();
    return PlezyFinPersonPage(
      person: PlezyFinPerson.fromJson(_field(json, 'Person')),
      credits: PlezyFinTitle.listFromJson(_list(json, 'Credits')),
      canRequest: flexibleBool(_field(json, 'CanRequest')),
      message: _text(json, 'Message'),
    );
  }

  /// "Known for": credits not in the library, one per title (an actor who also
  /// directed it is listed once), talk-show and news appearances as themselves
  /// left out, most popular first.
  List<PlezyFinTitle> get knownFor {
    final byTitle = <String, PlezyFinTitle>{};
    for (final credit in credits) {
      if (credit.inLibrary || isSelfAppearance(credit)) continue;
      final key = '${credit.kind.id}/${credit.tmdbId}';
      final kept = byTitle[key];
      // Keep the acting credit's character when there is one.
      if (kept == null || (kept.role != 'cast' && credit.role == 'cast')) byTitle[key] = credit;
    }
    final list = byTitle.values.toList()..sort((a, b) => b.popularity.compareTo(a.popularity));
    return list;
  }

  static final _selfPattern = RegExp(r'^(self|himself|herself|themselves|narrator - self)\b', caseSensitive: false);

  /// A guest spot as themselves (talk shows, award shows, news): TMDb credits
  /// these as Character "Self" / "Himself" / "Herself".
  static bool isSelfAppearance(PlezyFinTitle credit) {
    final character = credit.character;
    return character != null && _selfPattern.hasMatch(character.trim());
  }
}

/// `GET PlezyFin/Search?q=`.
class PlezyFinTitleSearch {
  final bool canRequest;
  final List<PlezyFinTitle> results;
  final String? message;

  const PlezyFinTitleSearch({this.canRequest = false, this.results = const [], this.message});

  static PlezyFinTitleSearch fromJson(Object? json) {
    if (json is! Map) return const PlezyFinTitleSearch();
    return PlezyFinTitleSearch(
      canRequest: flexibleBool(_field(json, 'CanRequest')),
      results: PlezyFinTitle.listFromJson(_list(json, 'Results')),
      message: _text(json, 'Message'),
    );
  }
}

/// `GET PlezyFin/Title/{movie|tv}/{tmdbId}`.
class PlezyFinTitleDetail {
  final PlezyFinTitle? title;
  final List<String> genres;
  final int? runtimeMinutes;
  final String? certification;
  final List<CatalogCastMember> cast;
  final bool canRequest;
  final String? message;

  const PlezyFinTitleDetail({
    this.title,
    this.genres = const [],
    this.runtimeMinutes,
    this.certification,
    this.cast = const [],
    this.canRequest = false,
    this.message,
  });

  static PlezyFinTitleDetail fromJson(Object? json) {
    if (json is! Map) return const PlezyFinTitleDetail();
    final titleJson = _field(json, 'Title');
    final cast = <CatalogCastMember>[];
    if (titleJson is Map) {
      for (final member in _list(titleJson, 'Cast')) {
        if (member is! Map) continue;
        final name = _text(member, 'Name');
        if (name == null) continue;
        cast.add(
          CatalogCastMember(name: name, secondary: _text(member, 'Character'), imageUrl: _text(member, 'ProfileUrl')),
        );
      }
    }
    return PlezyFinTitleDetail(
      title: PlezyFinTitle.fromJson(titleJson),
      genres: titleJson is Map
          ? [
              for (final genre in _list(titleJson, 'Genres'))
                if (genre != null && genre.toString().trim().isNotEmpty) genre.toString().trim(),
            ]
          : const [],
      runtimeMinutes: titleJson is Map ? flexibleInt(_field(titleJson, 'Runtime')) : null,
      certification: titleJson is Map ? _text(titleJson, 'Certification') : null,
      cast: cast,
      canRequest: flexibleBool(_field(json, 'CanRequest')),
      message: _text(json, 'Message'),
    );
  }
}

/// `POST PlezyFin/Requests`.
class PlezyFinRequestResult {
  final bool ok;
  final PlezyFinRequestState? requestState;
  final String? message;

  /// The HTTP status when the server refused (403 switch off, 409 already in
  /// the library, 400 bad input, 503 Seerr not set up).
  final int? statusCode;

  const PlezyFinRequestResult({required this.ok, this.requestState, this.message, this.statusCode});

  static PlezyFinRequestResult fromJson(Object? json, {int? statusCode}) {
    if (json is Map) {
      return PlezyFinRequestResult(
        ok: flexibleBool(_field(json, 'Ok')),
        requestState: PlezyFinRequestState.parse(_text(json, 'RequestState')),
        message: _text(json, 'Message'),
        statusCode: statusCode,
      );
    }
    final text = json is String ? json.trim() : null;
    final usable = text != null && text.isNotEmpty && !text.startsWith('<');
    return PlezyFinRequestResult(ok: false, message: usable ? text : null, statusCode: statusCode);
  }
}
