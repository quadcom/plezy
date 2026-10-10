/// How a home row draws its cards (Adrian, 2026-10-09; plan
/// `local/plans/settings-search-home-sections.md`).
enum HomeCardStyle {
  /// Posters; episodes use the series or season poster.
  poster('poster'),

  /// Screen grabs: films and shows use their backdrop, episodes their still.
  thumb('thumb');

  const HomeCardStyle(this.wire);

  /// The value the layout record stores.
  final String wire;

  static HomeCardStyle? fromWire(Object? value) {
    for (final style in values) {
      if (style.wire == value) return style;
    }
    return null;
  }
}

/// The home page's own row order and switches, apart from the menu (Adrian,
/// 2026-10-10; PlezyFin PLAN_SHA_13, plan `local/plans/home-rows-apart.md`):
/// `home.rows: {order, off}`, both lists of layout keys.
///
/// [order] holds every row's place, on or off, so a switched-off row keeps
/// the place it was moved to; [off] only marks the rows switched off. A row
/// shows when its entry is not Not shown and its key is not in [off]: a folded
/// library can still have a home row. Keys not in [order] go after it, in menu
/// order, and are on unless [off] names them.
class HomeRows {
  final List<String> order;
  final List<String> off;

  const HomeRows({this.order = const [], this.off = const []});

  /// Read a `rows` object, or null when it is not one. Repeats are dropped.
  static HomeRows? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    List<String> strings(Object? list) {
      final result = <String>[];
      if (list is List) {
        for (final value in list) {
          if (value is String && value.isNotEmpty && !result.contains(value)) result.add(value);
        }
      }
      return result;
    }

    return HomeRows(order: strings(raw['order']), off: strings(raw['off']));
  }

  Map<String, dynamic> toJson() => {'order': order, 'off': off};

  /// [keys] in home order: the ones [order] places first, in its order, then
  /// the rest in the order given.
  List<String> arrange(List<String> keys) {
    final rank = {for (final (index, key) in order.indexed) key: index};
    return [
      ...[
        for (final key in keys)
          if (rank.containsKey(key)) key,
      ]..sort((a, b) => rank[a]!.compareTo(rank[b]!)),
      for (final key in keys)
        if (!rank.containsKey(key)) key,
    ];
  }

  /// These rows after this device places the keys it manages: [ordered] is
  /// every managed key in its new order, [offKeys] the managed ones switched
  /// off. Keys outside [managed] (Not shown entries, other servers' keys)
  /// keep their slots and switches, so they come back where they were.
  HomeRows place({required Set<String> managed, required List<String> ordered, required Set<String> offKeys}) {
    final queue = List<String>.of(ordered);
    final nextOrder = <String>[];
    for (final key in order) {
      if (!managed.contains(key)) {
        if (!ordered.contains(key)) nextOrder.add(key);
      } else if (queue.isNotEmpty) {
        nextOrder.add(queue.removeAt(0));
      }
    }
    for (final key in queue) {
      if (!nextOrder.contains(key)) nextOrder.add(key);
    }
    return HomeRows(
      order: nextOrder,
      off: [
        for (final key in off)
          if (!managed.contains(key) && !ordered.contains(key)) key,
        for (final key in ordered)
          if (offKeys.contains(key)) key,
      ],
    );
  }

  @override
  bool operator ==(Object other) => other is HomeRows && _listEquals(order, other.order) && _listEquals(off, other.off);

  @override
  int get hashCode => Object.hash(Object.hashAll(order), Object.hashAll(off));
}

/// The home screen's sections, in the shape the PlezyFin layout record keeps
/// them under `home`: `{order, off, cards, rows}`.
///
/// Ids this version does not know are ignored on screen and kept on write, so
/// a newer client's sections survive an older one (PlezyFin, 2026-10-09).
class HomeLayout {
  /// The banner at the top.
  static const hero = 'hero';

  /// Continue Watching: items started and not finished.
  static const resume = 'resume';

  /// Next Up: the next episode of shows being watched.
  static const nextUp = 'nextup';

  /// Every library's rows, as one block.
  static const libraries = 'libraries';

  static const builtInOrder = [hero, resume, nextUp, libraries];

  final List<String> order;
  final List<String> off;

  /// Card style per row: a section id (`resume`, `nextup`) or a library
  /// layout key. A missing row keeps its usual look.
  final Map<String, HomeCardStyle> cards;

  /// The home rows' own order and switches; null keeps the old rule (Shown
  /// entries, in menu order). With an account only; `off` keeps the banner.
  final HomeRows? rows;

  /// Keys of the `home` object this version does not know, kept on write.
  final Map<String, dynamic> extra;

  const HomeLayout({
    this.order = builtInOrder,
    this.off = const [],
    this.cards = const {},
    this.rows,
    this.extra = const {},
  });

  static const standard = HomeLayout();

  static const _knownKeys = {'order', 'off', 'cards', 'rows'};

  /// Read a `home` object, skipping anything malformed rather than failing.
  factory HomeLayout.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? raw) => [
      if (raw is List)
        for (final value in raw)
          if (value is String && value.isNotEmpty) value,
    ];
    final rawCards = json['cards'];
    return HomeLayout(
      order: strings(json['order']),
      off: strings(json['off']),
      cards: {
        if (rawCards is Map)
          for (final entry in rawCards.entries)
            if (entry.key is String && HomeCardStyle.fromWire(entry.value) != null)
              entry.key as String: HomeCardStyle.fromWire(entry.value)!,
      },
      rows: HomeRows.tryFrom(json['rows']),
      extra: {
        for (final entry in json.entries)
          if (!_knownKeys.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// [raw] as a home layout, or null when it is not an object.
  static HomeLayout? tryFrom(Object? raw) => raw is Map<String, dynamic> ? HomeLayout.fromJson(raw) : null;

  Map<String, dynamic> toJson() => {
    ...extra,
    'order': order,
    'off': off,
    if (cards.isNotEmpty) 'cards': {for (final entry in cards.entries) entry.key: entry.value.wire},
    if (rows != null) 'rows': rows!.toJson(),
  };

  /// The known sections in display order: those [order] names first, then any
  /// it leaves out, in the built-in order.
  List<String> get sections {
    final result = <String>[];
    for (final id in order) {
      if (builtInOrder.contains(id) && !result.contains(id)) result.add(id);
    }
    for (final id in builtInOrder) {
      if (!result.contains(id)) result.add(id);
    }
    return result;
  }

  bool isOn(String id) => !off.contains(id);

  /// This layout with the known sections in [sections] order. Unknown ids in
  /// [order] keep their slots.
  HomeLayout withSections(List<String> sections) {
    final queue = List<String>.of(sections);
    final next = <String>[];
    final seen = <String>{};
    for (final id in order) {
      if (!builtInOrder.contains(id)) {
        next.add(id);
      } else if (seen.add(id) && queue.isNotEmpty) {
        next.add(queue.removeAt(0));
      }
    }
    next.addAll(queue.where((id) => !next.contains(id)));
    return HomeLayout(order: next, off: off, cards: cards, rows: rows, extra: extra);
  }

  HomeLayout withSection(String id, {required bool on}) => HomeLayout(
    order: order,
    off: on
        ? [
            for (final o in off)
              if (o != id) o,
          ]
        : [...off.where((o) => o != id), id],
    cards: cards,
    rows: rows,
    extra: extra,
  );

  /// This layout with [row]'s card style set, or cleared back to the usual look.
  HomeLayout withCard(String row, HomeCardStyle? style) => HomeLayout(
    order: order,
    off: off,
    cards: {
      for (final entry in cards.entries)
        if (entry.key != row) entry.key: entry.value,
      row: ?style,
    },
    rows: rows,
    extra: extra,
  );

  /// This layout with the home rows replaced.
  HomeLayout withRows(HomeRows rows) => HomeLayout(order: order, off: off, cards: cards, rows: rows, extra: extra);

  @override
  bool operator ==(Object other) =>
      other is HomeLayout &&
      _listEquals(order, other.order) &&
      _listEquals(off, other.off) &&
      _mapEquals(cards, other.cards) &&
      rows == other.rows;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAll(off),
    Object.hashAll(cards.entries.map((e) => '${e.key}=${e.value.wire}')),
    rows,
  );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, HomeCardStyle> a, Map<String, HomeCardStyle> b) =>
    a.length == b.length && a.entries.every((entry) => b[entry.key] == entry.value);
