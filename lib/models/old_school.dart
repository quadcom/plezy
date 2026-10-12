/// Old School (PlezyFin PLAN_SHA_21): pretend TV channels and a guide the
/// PlezyFin server builds from the library. Plezy plays the real file from
/// the scheduled point, as if live.
///
/// Shapes follow the plan's API table (`PlezyFin/OldSchool/...`). The readers
/// take PascalCase (Jellyfin's own casing) or camelCase keys alike, so a
/// casing choice on the server side never blanks the guide.
library;

/// What a guide entry is.
enum OldSchoolEntryKind {
  movie,
  episode,

  /// A music video as a programme (channel 33, Rock the Box): kind "show"
  /// with item type MusicVideo, named "Artist - Title".
  musicVideo,

  /// A trailer filling a break between programmes; it carries the trailer's
  /// own item id (always a local file).
  trailer,

  /// A music video filling what is left of a break after the trailers; a
  /// break like a trailer, with its own item id.
  music,

  /// Nothing to play: a gap the server could not fill. No item id.
  standby,

  /// A whole break as the guide shows it: a run of trailers, music and
  /// standby joined into one block (PLAN_SHA_28). Made by the client, never
  /// sent by the server; the parts are in [OldSchoolEntry.breakItems].
  intermission,

  /// A run of music video programmes (Rock the Box) with the breaks between
  /// them, as one solid block in the guide: dozens of four-minute slivers
  /// were unreadable (Adrian, 2026-10-11). Client-made like [intermission];
  /// the parts are in [OldSchoolEntry.breakItems].
  musicVideos,

  unknown;

  static OldSchoolEntryKind parse(Object? raw) {
    final value = raw is String ? raw.toLowerCase() : '';
    return switch (value) {
      'movie' || 'film' => movie,
      'episode' => episode,
      'trailer' => trailer,
      'musicvideo' => musicVideo,
      'music' => music,
      'standby' => standby,
      _ => unknown,
    };
  }
}

/// A channel in the line-up.
class OldSchoolChannel {
  final String id;
  final int number;
  final String name;

  /// What the channel plays ("films", "shows", "seasonal", ...), as sent.
  final String? kind;

  /// A short "what it plays" line, where the server sends one.
  final String? description;

  /// Version of the channel's logo; part of the logo address so a replaced
  /// logo is fetched again. Null: no logo.
  final String? logoTag;

  const OldSchoolChannel({
    required this.id,
    required this.number,
    required this.name,
    this.kind,
    this.description,
    this.logoTag,
  });

  static OldSchoolChannel? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final id = _string(map, 'Id');
    if (id == null) return null;
    return OldSchoolChannel(
      id: id,
      number: _int(map, 'Number') ?? 0,
      name: _string(map, 'Name') ?? '',
      kind: _string(map, 'Kind'),
      description: _string(map, 'Tagline') ?? _string(map, 'Description'),
      logoTag: _string(map, 'LogoTag'),
    );
  }
}

/// A picture of an entry: the item it belongs to (the entry's own item, its
/// series for an episode, the film a trailer is for) and the image tag.
class OldSchoolImage {
  final String itemId;
  final String tag;

  const OldSchoolImage({required this.itemId, required this.tag});

  /// PlezyFin sends `{itemId, tag}`; a bare tag string falls back to
  /// [fallbackItemId].
  static OldSchoolImage? fromJson(Object? json, String? fallbackItemId) {
    if (json is Map) {
      final map = json.cast<String, dynamic>();
      final itemId = _string(map, 'ItemId') ?? fallbackItemId;
      final tag = _string(map, 'Tag');
      return itemId == null || tag == null ? null : OldSchoolImage(itemId: itemId, tag: tag);
    }
    if (json is String && json.isNotEmpty && fallbackItemId != null) {
      return OldSchoolImage(itemId: fallbackItemId, tag: json);
    }
    return null;
  }
}

/// One programme (or trailer, or standby gap) in a channel's timetable.
class OldSchoolEntry {
  final OldSchoolEntryKind kind;

  /// The library item to play; null for [OldSchoolEntryKind.standby].
  final String? itemId;
  final DateTime start;
  final DateTime end;
  final String name;
  final String? seriesName;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? year;
  final String? rating;

  /// The file's own running time; a programme's slot can be longer.
  final Duration? runTime;
  final String? overview;
  final OldSchoolImage? poster;
  final OldSchoolImage? backdrop;
  final OldSchoolImage? logo;
  final OldSchoolImage? thumb;

  /// The item whose images the tags belong to, when it differs from
  /// [itemId] (an episode's series).
  final String? imageItemId;

  /// An [OldSchoolEntryKind.intermission]'s parts, in order.
  final List<OldSchoolEntry> breakItems;

  const OldSchoolEntry({
    required this.kind,
    required this.itemId,
    required this.start,
    required this.end,
    required this.name,
    this.seriesName,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.year,
    this.rating,
    this.runTime,
    this.overview,
    this.poster,
    this.backdrop,
    this.logo,
    this.thumb,
    this.imageItemId,
    this.breakItems = const [],
  });

  /// One block for a break (or, with [kind] musicVideos, a run of music
  /// videos): from the first part's start to the last one's end. [parts]
  /// must be non-empty and in start order.
  factory OldSchoolEntry.intermission(
    List<OldSchoolEntry> parts, {
    OldSchoolEntryKind kind = OldSchoolEntryKind.intermission,
  }) => OldSchoolEntry(
    kind: kind,
    itemId: null,
    start: parts.first.start,
    end: parts.last.end,
    name: '',
    breakItems: List.unmodifiable(parts),
  );

  /// [entries] (in start order) as the guide's blocks: each run of break
  /// entries (anything that is not a programme) joined into one intermission
  /// (PLAN_SHA_28), and each run of music videos, with the breaks between
  /// them, into one musicVideos block.
  static List<OldSchoolEntry> joinBreaks(Iterable<OldSchoolEntry> entries) {
    final joined = <OldSchoolEntry>[];
    final run = <OldSchoolEntry>[];
    void flush() {
      if (run.isEmpty) return;
      final music = run.any((e) => e.kind == OldSchoolEntryKind.musicVideo);
      // A break before the first video or after the last stays its own
      // intermission; only what lies between music videos joins them.
      final first = music ? run.indexWhere((e) => e.kind == OldSchoolEntryKind.musicVideo) : run.length;
      final last = music ? run.lastIndexWhere((e) => e.kind == OldSchoolEntryKind.musicVideo) : -1;
      if (first > 0) joined.add(OldSchoolEntry.intermission(run.sublist(0, first)));
      if (music) {
        joined.add(OldSchoolEntry.intermission(run.sublist(first, last + 1), kind: OldSchoolEntryKind.musicVideos));
        if (last + 1 < run.length) joined.add(OldSchoolEntry.intermission(run.sublist(last + 1)));
      }
      run.clear();
    }

    for (final entry in entries) {
      if (entry.isProgramme && entry.kind != OldSchoolEntryKind.musicVideo) {
        flush();
        joined.add(entry);
      } else {
        run.add(entry);
      }
    }
    flush();
    return joined;
  }

  /// What a break plays, by name: trailers (a series' season-0 trailer by
  /// the series name) and music videos; standby is left out.
  List<String> get breakItemNames => [
    for (final part in breakItems)
      if (part.kind != OldSchoolEntryKind.standby)
        part.kind == OldSchoolEntryKind.trailer && (part.seriesName?.isNotEmpty ?? false)
            ? part.seriesName!
            : part.name,
  ];

  bool get isPlayable => itemId != null && kind != OldSchoolEntryKind.standby;

  bool get isProgramme =>
      kind == OldSchoolEntryKind.movie || kind == OldSchoolEntryKind.episode || kind == OldSchoolEntryKind.musicVideo;

  /// Whether the entry is on at [at].
  bool isOnAt(DateTime at) => !start.isAfter(at) && end.isAfter(at);

  /// The title the guide shows: the series for an episode, else the name.
  String get title => kind == OldSchoolEntryKind.episode && (seriesName?.isNotEmpty ?? false) ? seriesName! : name;

  /// "S6 E1 · The Beginning" for an episode, "1999 · PG" for a film.
  String get subtitle {
    final parts = <String>[];
    if (kind == OldSchoolEntryKind.episode) {
      if (seasonNumber != null && episodeNumber != null) parts.add('S$seasonNumber E$episodeNumber');
      if (name.isNotEmpty && name != title) parts.add(name);
    } else {
      if (year != null) parts.add('$year');
      if (rating != null && rating!.isNotEmpty) parts.add(rating!);
    }
    return parts.join(' · ');
  }

  /// PlezyFin sends `kind` as show / trailer / music / standby with the
  /// item's own type in `itemType` (Movie, Episode, MusicVideo, Trailer); a
  /// plain Movie / Episode kind is read too.
  static OldSchoolEntryKind _kindOf(Map<String, dynamic> map) {
    final raw = _string(map, 'Kind') ?? _string(map, 'Type');
    final kind = OldSchoolEntryKind.parse(raw);
    if (kind != OldSchoolEntryKind.unknown) return kind;
    final byItemType = OldSchoolEntryKind.parse(_string(map, 'ItemType'));
    if (byItemType != OldSchoolEntryKind.unknown) return byItemType;
    // A programme of a type this build doesn't know still shows and plays.
    final isShow = raw?.toLowerCase() == 'show' || raw?.toLowerCase() == 'programme';
    return isShow && _string(map, 'ItemId') != null ? OldSchoolEntryKind.movie : OldSchoolEntryKind.unknown;
  }

  static OldSchoolEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final start = _date(map, 'Start') ?? _date(map, 'StartDate');
    final end = _date(map, 'End') ?? _date(map, 'EndDate');
    if (start == null || end == null) return null;
    final images = map['ImageTags'] ?? map['imageTags'];
    final imageMap = images is Map ? images.cast<String, dynamic>() : const <String, dynamic>{};
    final ticks = _int(map, 'RunTimeTicks');
    final itemId = _string(map, 'ItemId');
    final imageItemId = _string(map, 'ImageItemId');
    final ownImageId = imageItemId ?? itemId;
    final artImageId = imageItemId ?? _string(map, 'SeriesId') ?? itemId;
    Object? image(String pascal) => imageMap[pascal] ?? imageMap[_camel(pascal)];
    return OldSchoolEntry(
      kind: _kindOf(map),
      itemId: itemId,
      start: start,
      end: end,
      name: _string(map, 'Name') ?? '',
      seriesName: _string(map, 'SeriesName'),
      seriesId: _string(map, 'SeriesId'),
      seasonNumber: _int(map, 'ParentIndexNumber') ?? _int(map, 'SeasonNumber'),
      episodeNumber: _int(map, 'IndexNumber') ?? _int(map, 'EpisodeNumber'),
      year: _int(map, 'ProductionYear') ?? _int(map, 'Year'),
      rating: _string(map, 'OfficialRating') ?? _string(map, 'Rating'),
      runTime: ticks == null ? null : Duration(microseconds: ticks ~/ 10),
      overview: _string(map, 'Overview'),
      poster: OldSchoolImage.fromJson(image('Primary') ?? image('Poster'), ownImageId),
      backdrop: OldSchoolImage.fromJson(image('Backdrop'), artImageId),
      logo: OldSchoolImage.fromJson(image('Logo'), artImageId),
      thumb: OldSchoolImage.fromJson(image('Thumb'), artImageId),
      imageItemId: imageItemId,
    );
  }
}

/// `GET Guide`: the server's clock and every channel's entries overlapping
/// the asked window.
class OldSchoolGuide {
  final DateTime serverTime;
  final Map<String, List<OldSchoolEntry>> entriesByChannel;

  const OldSchoolGuide({required this.serverTime, required this.entriesByChannel});

  static OldSchoolGuide? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final serverTime = _date(map, 'ServerTime');
    if (serverTime == null) return null;
    final channels = map['Channels'] ?? map['channels'] ?? const [];
    final byChannel = <String, List<OldSchoolEntry>>{};
    if (channels is List) {
      for (final row in channels) {
        if (row is! Map) continue;
        final rowMap = row.cast<String, dynamic>();
        final id = _string(rowMap, 'ChannelId') ?? _string(rowMap, 'Id');
        if (id == null) continue;
        final entries = rowMap['Entries'] ?? rowMap['entries'] ?? const [];
        byChannel[id] = [
          if (entries is List)
            for (final entry in entries) ?OldSchoolEntry.fromJson(entry),
        ]..sort((a, b) => a.start.compareTo(b.start));
      }
    }
    return OldSchoolGuide(serverTime: serverTime, entriesByChannel: byChannel);
  }
}

/// `GET Tune/{channelId}`: what is on now and next, with the server's clock.
class OldSchoolTune {
  final String channelId;
  final DateTime serverTime;
  final OldSchoolEntry now;
  final OldSchoolEntry? next;

  /// This device's clock when the answer arrived, for [liveOffset].
  final DateTime receivedAt;

  const OldSchoolTune({
    required this.channelId,
    required this.serverTime,
    required this.now,
    required this.next,
    required this.receivedAt,
  });

  static OldSchoolTune? fromJson(String channelId, Object? json, {required DateTime receivedAt}) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final serverTime = _date(map, 'ServerTime');
    final now = OldSchoolEntry.fromJson(map['Now'] ?? map['now']);
    if (serverTime == null || now == null) return null;
    return OldSchoolTune(
      channelId: channelId,
      serverTime: serverTime,
      now: now,
      next: OldSchoolEntry.fromJson(map['Next'] ?? map['next']),
      receivedAt: receivedAt,
    );
  }

  /// The server's time as this device reckons it at [deviceNow]: the
  /// server's clock when it answered plus the time since (Plezzy's request:
  /// the offset is worked out at play time, allowing for request delay and
  /// clock skew).
  DateTime serverNow(DateTime deviceNow) => serverTime.add(deviceNow.difference(receivedAt));

  /// Where in [now]'s file playback should be at [deviceNow].
  Duration liveOffset(DateTime deviceNow) => offsetInto(now, deviceNow);

  /// Where in [entry]'s file playback should be at [deviceNow], never
  /// negative.
  Duration offsetInto(OldSchoolEntry entry, DateTime deviceNow) {
    final offset = serverNow(deviceNow).difference(entry.start);
    return offset.isNegative ? Duration.zero : offset;
  }
}

String? _string(Map<String, dynamic> map, String pascal) {
  final value = map[pascal] ?? map[_camel(pascal)];
  if (value is String && value.isNotEmpty) return value;
  if (value is num) return value.toString();
  return null;
}

int? _int(Map<String, dynamic> map, String pascal) {
  final value = map[pascal] ?? map[_camel(pascal)];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _date(Map<String, dynamic> map, String pascal) {
  final value = map[pascal] ?? map[_camel(pascal)];
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String _camel(String pascal) => pascal.isEmpty ? pascal : pascal[0].toLowerCase() + pascal.substring(1);
