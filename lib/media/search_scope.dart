/// What the Search screen looks for, beyond names (local/plans/search-actors.md).
///
/// Jellyfin's `/Items?SearchTerm=` matches item names only, so actors,
/// directors, genres, studios, keywords and years each need a route of their
/// own. The user ticks which kinds to search in the "Search in" pop-up; every
/// ticked kind other than [titles] costs exactly one request per server per
/// search, and an unticked kind costs nothing.
///
/// [id] is the stored form (the account's `DisplayPreferences` custom prefs);
/// never rename it.
enum SearchScopeKind {
  /// Films, shows and episodes by name: the search Plezy always had.
  titles('titles'),

  /// People who acted in something.
  actors('actors'),

  /// Whole-tag matches (Jellyfin `Tags`), any case.
  keywords('keywords'),

  /// Directors and writers.
  crew('crew'),
  genres('genres'),
  studios('studios'),

  /// Only when the query is a 4-digit year (see [searchYearOf]).
  year('year');

  const SearchScopeKind(this.id);

  final String id;

  /// Ticked until the user says otherwise (Adrian, 2026-11-01).
  static const Set<SearchScopeKind> defaults = {titles, actors, keywords};

  /// The order of the extra result rows under the title sections.
  static const List<SearchScopeKind> extraRowOrder = [actors, crew, keywords, genres, studios, year];

  /// Every kind but [titles] is answered by a route of its own.
  bool get isExtra => this != titles;

  static SearchScopeKind? fromId(String id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }

  /// Comma list in declaration order; an empty set is the empty string, which
  /// is a choice (nothing ticked), not "unset".
  static String encode(Set<SearchScopeKind> kinds) => [
    for (final kind in values)
      if (kinds.contains(kind)) kind.id,
  ].join(',');

  /// Reverse of [encode]. Unknown ids (a newer Plezy's kinds) are skipped.
  static Set<SearchScopeKind> decode(String raw) => {for (final part in raw.split(',')) ?fromId(part.trim())};
}

/// The year a query names, or null: only a bare 4-digit year from 1900 to
/// 2100 counts, so "1917" finds the year and "Blade Runner 2049" does not.
int? searchYearOf(String query) {
  final trimmed = query.trim();
  if (!RegExp(r'^\d{4}$').hasMatch(trimmed)) return null;
  final year = int.parse(trimmed);
  return year >= 1900 && year <= 2100 ? year : null;
}

/// What a filtered media grid narrows films and shows to.
enum MediaFacetKind { person, genre, studio, tag, year }

/// One filter value: a person, genre or studio id, a tag's text, or a year.
class MediaFacet {
  const MediaFacet(this.kind, this.value);

  final MediaFacetKind kind;
  final String value;

  @override
  bool operator ==(Object other) => other is MediaFacet && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'MediaFacet(${kind.name}, $value)';
}

/// One non-title search hit: a person, genre, studio, keyword or year on one
/// server. Tapping it opens the films and shows that match [facet].
class SearchFacetMatch {
  const SearchFacetMatch({
    required this.kind,
    required this.facet,
    required this.name,
    required this.serverId,
    this.serverName,
    this.imagePath,
    this.count,
  });

  final SearchScopeKind kind;
  final MediaFacet facet;
  final String name;
  final String serverId;
  final String? serverName;

  /// Server-relative or absolute image path (people only).
  final String? imagePath;

  /// How many films and shows match, when the answer came for free.
  final int? count;
}
