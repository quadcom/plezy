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

/// The home screen's sections, in the shape the PlezyFin layout record keeps
/// them under `home`: `{order, off, cards}`.
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

  /// Keys of the `home` object this version does not know, kept on write.
  final Map<String, dynamic> extra;

  const HomeLayout({this.order = builtInOrder, this.off = const [], this.cards = const {}, this.extra = const {}});

  static const standard = HomeLayout();

  static const _knownKeys = {'order', 'off', 'cards'};

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
    return HomeLayout(order: next, off: off, cards: cards, extra: extra);
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
    extra: extra,
  );

  @override
  bool operator ==(Object other) =>
      other is HomeLayout &&
      _listEquals(order, other.order) &&
      _listEquals(off, other.off) &&
      _mapEquals(cards, other.cards);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAll(off),
    Object.hashAll(cards.entries.map((e) => '${e.key}=${e.value.wire}')),
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
