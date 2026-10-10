import 'dart:convert';

import 'home_layout.dart';
import 'media_backend.dart';
import 'media_library.dart';

/// Where a library sits in the user's layout (Adrian, 2026-10-09; plan
/// `local/plans/library-states.md`).
enum LibraryState {
  /// In the main menu and on home.
  shown('shown'),

  /// In the collapsed Hidden libraries section. Its items still appear in
  /// Continue Watching, Next Up and search.
  folded('folded'),

  /// Nowhere at all, as if there were no access.
  off('off');

  const LibraryState(this.wire);

  /// The value the layout record stores.
  final String wire;

  static LibraryState? fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// MediaBrowser ids come back with and without dashes, in either case; the
/// layout record stores them lower case without dashes.
String mediaBrowserIdKey(String id) => id.replaceAll('-', '').toLowerCase();

/// The server half of [library]'s layout key.
String libraryLayoutServerId(MediaLibrary library) {
  final serverId = library.serverId ?? '';
  return library.backend == MediaBackend.plex ? serverId : mediaBrowserIdKey(serverId);
}

/// [library]'s key in the layout record: `<serverId>/<libraryId>`. Plex keeps
/// its machine identifier and section key as they are.
String libraryLayoutKey(MediaLibrary library) {
  final libraryId = library.backend == MediaBackend.plex ? library.id : mediaBrowserIdKey(library.id);
  return '${libraryLayoutServerId(library)}/$libraryId';
}

/// The account's entries that are not libraries but are placed, folded and
/// switched off like one: Continue Watching and Next Up (their place among the
/// libraries is their place on home), and Favourites (PlezyFin and Adrian,
/// 2026-10-09).
enum LayoutEntry {
  continueWatching('continuewatching'),
  nextUp('nextup'),
  favorites('favorites');

  const LayoutEntry(this.id);

  /// The library id half of the entry's layout key.
  final String id;

  /// The entry's layout key on [serverId], the PlezyFin server.
  String keyFor(String serverId) => '$serverId/$id';

  /// The entries a record that lacks them places ahead of the libraries:
  /// Continue Watching, then Next Up, as home always showed them.
  static const leading = [continueWatching, nextUp];
}

/// The layout key of a server's Favourites entry, placed and hidden like a
/// library (PlezyFin, 2026-10-09).
String favoritesLayoutKey(String serverId) => LayoutEntry.favorites.keyFor(serverId);

/// The longest home row title the record keeps.
const libraryRowTitleMaxLength = 80;

String _serverOf(String key) {
  final slash = key.indexOf('/');
  return slash < 0 ? key : key.substring(0, slash);
}

String _libraryOf(String key) {
  final slash = key.indexOf('/');
  return slash < 0 ? '' : key.substring(slash + 1);
}

/// One user's library layout across every server, in the shape PlezyFin
/// stores it (DisplayPreferences `plezyfin-libraries`, CustomPrefs `layout`):
/// `{v, rev, updated, order, state, known}`. Without a PlezyFin account the
/// same record is kept on the device.
class LibraryLayout {
  static const version = 1;

  /// Bumped on every write; last write wins.
  final int rev;

  /// ISO 8601 UTC time of the last write.
  final String? updated;

  /// Every ordered library key, all servers mixed.
  final List<String> order;

  /// Explicit states. A key missing here follows [stateOf]'s rules.
  final Map<String, LibraryState> state;

  /// Library ids each server had when its layout was last written, to tell a
  /// new library from one that was simply never moved.
  final Map<String, List<String>> known;

  /// Home row titles by key; a missing or blank one means "Recently Added in
  /// `<library name>`".
  final Map<String, String> titles;

  /// The home screen's sections; null means the default's, else all on in the
  /// built-in order.
  final HomeLayout? home;

  /// Top-level keys this version does not know, kept on write so another
  /// client's fields survive (PlezyFin, 2026-10-09).
  final Map<String, dynamic> extra;

  const LibraryLayout({
    this.rev = 0,
    this.updated,
    this.order = const [],
    this.state = const {},
    this.known = const {},
    this.titles = const {},
    this.home,
    this.extra = const {},
  });

  static const _knownKeys = {'v', 'rev', 'updated', 'order', 'state', 'known', 'titles', 'home'};

  static const empty = LibraryLayout();

  /// Read a record, skipping anything malformed rather than failing on it.
  factory LibraryLayout.fromJson(Map<String, dynamic> json) {
    final rawState = json['state'];
    final rawKnown = json['known'];
    final rawOrder = json['order'];
    final rawTitles = json['titles'];
    return LibraryLayout(
      rev: json['rev'] is int ? json['rev'] as int : 0,
      updated: json['updated'] is String ? json['updated'] as String : null,
      order: [
        if (rawOrder is List)
          for (final key in rawOrder)
            if (key is String) key,
      ],
      state: {
        if (rawState is Map)
          for (final entry in rawState.entries)
            if (entry.key is String && LibraryState.fromWire(entry.value) != null)
              entry.key as String: LibraryState.fromWire(entry.value)!,
      },
      known: {
        if (rawKnown is Map)
          for (final entry in rawKnown.entries)
            if (entry.key is String && entry.value is List)
              entry.key as String: [
                for (final id in entry.value as List)
                  if (id is String) id,
              ],
      },
      titles: {
        if (rawTitles is Map)
          for (final entry in rawTitles.entries)
            if (entry.key is String && entry.value is String && (entry.value as String).trim().isNotEmpty)
              entry.key as String: _clampTitle((entry.value as String).trim()),
      },
      home: HomeLayout.tryFrom(json['home']),
      extra: {
        for (final entry in json.entries)
          if (!_knownKeys.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  static String _clampTitle(String title) =>
      title.length <= libraryRowTitleMaxLength ? title : title.substring(0, libraryRowTitleMaxLength);

  /// [raw] parsed, or null when it is missing or not a record.
  static LibraryLayout? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? LibraryLayout.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'v': version,
    'rev': rev,
    if (updated != null) 'updated': updated,
    'order': order,
    'state': {for (final entry in state.entries) entry.key: entry.value.wire},
    'known': known,
    if (titles.isNotEmpty) 'titles': titles,
    if (home != null) 'home': home!.toJson(),
  };

  /// The next record with the home sections replaced and everything else kept.
  LibraryLayout withHome(HomeLayout home, {required DateTime now}) => LibraryLayout(
    rev: rev + 1,
    updated: now.toUtc().toIso8601String(),
    order: order,
    state: state,
    known: known,
    titles: titles,
    home: home,
    extra: extra,
  );

  String encode() => jsonEncode(toJson());

  /// [key]'s state. When the record does not say: libraries on the own
  /// (PlezyFin) server are shown; another server's are folded until they are
  /// known, then shown. With no [ownServerId] (no PlezyFin account) every
  /// library starts shown, as Plezy always did.
  LibraryState stateOf(String key, {String? ownServerId}) {
    final explicit = state[key];
    if (explicit != null) return explicit;
    final serverId = _serverOf(key);
    if (ownServerId == null || serverId == ownServerId) return LibraryState.shown;
    return (known[serverId]?.contains(_libraryOf(key)) ?? false) ? LibraryState.shown : LibraryState.folded;
  }

  /// [libraries] arranged by this layout: the keys it orders first, in its
  /// order, then the rest in the order given; and each one's state.
  ({List<String> order, Map<String, LibraryState> state}) arrange(
    Iterable<MediaLibrary> libraries, {
    String? ownServerId,
  }) => arrangeKeys([for (final library in libraries) libraryLayoutKey(library)], ownServerId: ownServerId);

  /// [arrange] for raw keys, which also covers entries that are not browsable
  /// libraries: collections and playlists views, and Favourites.
  ///
  /// Keys in [leading] that this layout does not order go first instead.
  ({List<String> order, Map<String, LibraryState> state}) arrangeKeys(
    List<String> keys, {
    String? ownServerId,
    List<String> leading = const [],
  }) {
    final rank = {for (final (index, key) in order.indexed) key: index};
    final ranked = [
      for (final key in keys)
        if (rank.containsKey(key)) key,
    ]..sort((a, b) => rank[a]!.compareTo(rank[b]!));
    return (
      order: [
        for (final key in leading)
          if (keys.contains(key) && !rank.containsKey(key)) key,
        ...ranked,
        for (final key in keys)
          if (!rank.containsKey(key) && !leading.contains(key)) key,
      ],
      state: {for (final key in keys) key: stateOf(key, ownServerId: ownServerId)},
    );
  }

  /// This layout with the PlezyFin server's libraries started from the
  /// admin's [defaults]: their states where this record names none, and their
  /// order ahead of everything else. Used whenever the record has no `known`
  /// entry for [ownServerId] yet, not only when there is no record at all, so
  /// a record another client started with other servers' keys still gets the
  /// default for the own server (PlezyFin, 2026-10-09).
  LibraryLayout seededFrom(LibraryLayout defaults, {required String ownServerId}) {
    final prefix = '$ownServerId/';
    final ownOrder = [
      for (final key in defaults.order)
        if (key.startsWith(prefix) && !order.contains(key)) key,
    ];
    return LibraryLayout(
      rev: rev,
      updated: updated,
      order: [...ownOrder, ...order],
      state: {
        for (final entry in defaults.state.entries)
          if (entry.key.startsWith(prefix)) entry.key: entry.value,
        ...state,
      },
      known: known,
      titles: titles,
      home: home,
      extra: extra,
    );
  }

  /// Whether writing [librariesByServer] would change what [known] says.
  bool knownDiffers(Map<String, List<String>> librariesByServer) {
    for (final entry in librariesByServer.entries) {
      final current = known[entry.key];
      if (current == null || current.length != entry.value.length || !current.toSet().containsAll(entry.value)) {
        return true;
      }
    }
    return false;
  }

  /// The next record after writing the servers in [librariesByServer] (the
  /// ones this client manages, each with its current library ids).
  ///
  /// Other servers' keys keep their states and their order slots; the managed
  /// servers' keys fill the slots managed keys held before, in
  /// [managedOrder], with anything left over appended.
  LibraryLayout withManaged({
    required Map<String, List<String>> librariesByServer,
    required List<String> managedOrder,
    required Map<String, LibraryState> managedState,
    required DateTime now,
  }) {
    bool isManaged(String key) => librariesByServer.containsKey(_serverOf(key));
    final queue = List<String>.of(managedOrder);
    final nextOrder = <String>[];
    for (final key in order) {
      if (!isManaged(key)) {
        nextOrder.add(key);
      } else if (queue.isNotEmpty) {
        nextOrder.add(queue.removeAt(0));
      }
    }
    nextOrder.addAll(queue);
    return LibraryLayout(
      rev: rev + 1,
      updated: now.toUtc().toIso8601String(),
      order: nextOrder,
      state: {
        for (final entry in state.entries)
          if (!isManaged(entry.key)) entry.key: entry.value,
        ...managedState,
      },
      known: {...known, ...librariesByServer},
      titles: titles,
      home: home,
      extra: extra,
    );
  }

  /// [key]'s library page sort from the record's top-level `sort` (PlezyFin
  /// PLAN_SHA_12): Jellyfin's own `SortBy` string, compared whole, and the
  /// direction. Null when the record has none. Kept as the raw field, so
  /// another client's entries survive unchanged.
  ({String by, bool descending})? librarySortOf(String key) {
    final raw = extra['sort'];
    if (raw is! Map) return null;
    final entry = raw[key];
    if (entry is! Map) return null;
    final by = entry['by'];
    if (by is! String || by.isEmpty) return null;
    return (by: by, descending: entry['order'] == 'Descending');
  }

  /// The next record with [key]'s library page sort set, or removed when
  /// [sort] is null, and everything else kept.
  LibraryLayout withLibrarySort(String key, ({String by, bool descending})? sort, {required DateTime now}) {
    final raw = extra['sort'];
    final sorts = <String, dynamic>{if (raw is Map) ...raw.cast<String, dynamic>()}..remove(key);
    if (sort != null) sorts[key] = {'by': sort.by, 'order': sort.descending ? 'Descending' : 'Ascending'};
    return LibraryLayout(
      rev: rev + 1,
      updated: now.toUtc().toIso8601String(),
      order: order,
      state: state,
      known: known,
      titles: titles,
      home: home,
      extra: {...extra, 'sort': sorts},
    );
  }

  /// The home row title for [key]: this record's, else [defaults]', else null
  /// for "Recently Added in `<library name>`".
  String? titleFor(String key, {LibraryLayout? defaults}) => titles[key] ?? defaults?.titles[key];
}
