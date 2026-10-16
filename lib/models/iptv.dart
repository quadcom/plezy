/// IPTV (PlezyFin PLAN_SHA_61): public live channels as their own library.
/// The server holds only pointers - the channel list and the guide - and
/// Plezy plays each channel's stream straight from its source.
///
/// Shapes follow plan 61's "Server-to-player contract"
/// (`PlezyFin/Iptv/{libraryId}/...`). Like Old School's readers, these take
/// PascalCase or camelCase keys alike.
library;

/// The house-wide mark from the server's 6-hourly stream check.
enum IptvStatus {
  ok,

  /// No feed answered the last check. Shown, never hidden.
  mayNotWork;

  static IptvStatus parse(Object? raw) =>
      raw is String && raw.toLowerCase() == 'maynotwork' ? IptvStatus.mayNotWork : IptvStatus.ok;
}

/// One way to play a channel: a stream address on the source's own server.
class IptvFeed {
  final String url;

  /// The quality from the playlist name ("1080p", "720p"), or null.
  final String? quality;

  /// Exactly what the source needs sent with the request (the playlist's
  /// user agent or referrer, or a paid provider's login): nothing more is
  /// ever added.
  final Map<String, String> headers;

  final IptvStatus status;

  /// Whether a web browser may load it directly. Plezy is not a browser and
  /// ignores this.
  final bool browserCanLoad;

  const IptvFeed({
    required this.url,
    this.quality,
    this.headers = const {},
    this.status = IptvStatus.ok,
    this.browserCanLoad = false,
  });

  static IptvFeed? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final url = _string(map, 'Url');
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final rawHeaders = map['Headers'] ?? map['headers'];
    return IptvFeed(
      url: url!,
      quality: _string(map, 'Quality'),
      headers: {
        if (rawHeaders is Map)
          for (final entry in rawHeaders.entries)
            if (entry.key is String && entry.value is String && (entry.value as String).isNotEmpty)
              entry.key as String: entry.value as String,
      },
      status: IptvStatus.parse(map['Status'] ?? map['status']),
      browserCanLoad: _bool(map, 'BrowserCanLoad') ?? false,
    );
  }
}

/// A channel in an IPTV library.
class IptvChannel {
  /// The channel's item id on the server (stable across refreshes).
  final String id;
  final int number;
  final String name;

  /// The playlist's group ("News", "Undefined" ...), or null.
  final String? group;

  /// The logo's version; null when the channel has no logo.
  final String? imageTag;
  final String? tvgId;

  /// The playlist marks it "[Not 24/7]".
  final bool not247;
  final IptvStatus status;
  final bool hasGuide;
  final bool isFavorite;

  /// Best first.
  final List<IptvFeed> feeds;

  const IptvChannel({
    required this.id,
    required this.number,
    required this.name,
    this.group,
    this.imageTag,
    this.tvgId,
    this.not247 = false,
    this.status = IptvStatus.ok,
    this.hasGuide = false,
    this.isFavorite = false,
    this.feeds = const [],
  });

  /// "04", "42", "123": two digits up to 99, then as it is (Adrian,
  /// 2026-10-16).
  String get numberLabel => iptvNumberLabel(number);

  IptvChannel copyWith({bool? isFavorite}) => IptvChannel(
    id: id,
    number: number,
    name: name,
    group: group,
    imageTag: imageTag,
    tvgId: tvgId,
    not247: not247,
    status: status,
    hasGuide: hasGuide,
    isFavorite: isFavorite ?? this.isFavorite,
    feeds: feeds,
  );

  static IptvChannel? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final id = _string(map, 'Id');
    if (id == null) return null;
    final rawFeeds = map['Feeds'] ?? map['feeds'];
    return IptvChannel(
      id: id,
      number: _int(map, 'Number') ?? 0,
      name: _string(map, 'Name') ?? '',
      group: _string(map, 'Group'),
      imageTag: _string(map, 'ImageTag'),
      tvgId: _string(map, 'TvgId'),
      not247: _bool(map, 'Not247') ?? false,
      status: IptvStatus.parse(map['Status'] ?? map['status']),
      hasGuide: _bool(map, 'HasGuide') ?? false,
      isFavorite: _bool(map, 'IsFavorite') ?? false,
      feeds: [
        if (rawFeeds is List)
          for (final feed in rawFeeds) ?IptvFeed.fromJson(feed),
      ],
    );
  }
}

String iptvNumberLabel(int number) => number < 100 ? number.toString().padLeft(2, '0') : number.toString();

/// `GET Iptv/{libraryId}/Channels`.
class IptvLineup {
  final DateTime serverTime;
  final String libraryId;
  final String? libraryName;

  /// When the server's last stream check ran. A channel this device found
  /// dead stays marked until a later check.
  final DateTime? checkedAt;

  /// In number order.
  final List<IptvChannel> channels;

  const IptvLineup({
    required this.serverTime,
    required this.libraryId,
    this.libraryName,
    this.checkedAt,
    this.channels = const [],
  });

  static IptvLineup? fromJson(Object? json, {required String libraryId}) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final serverTime = _date(map, 'ServerTime');
    if (serverTime == null) return null;
    final library = map['Library'] ?? map['library'];
    final libraryMap = library is Map ? library.cast<String, dynamic>() : const <String, dynamic>{};
    final rawChannels = map['Channels'] ?? map['channels'];
    return IptvLineup(
      serverTime: serverTime,
      libraryId: _string(libraryMap, 'Id') ?? libraryId,
      libraryName: _string(libraryMap, 'Name'),
      checkedAt: _date(map, 'CheckedAt'),
      channels: [
        if (rawChannels is List)
          for (final channel in rawChannels) ?IptvChannel.fromJson(channel),
      ]..sort((a, b) => a.number.compareTo(b.number)),
    );
  }
}

/// One programme in a channel's listings.
class IptvProgramme {
  final DateTime start;
  final DateTime end;
  final String title;
  final String? subtitle;
  final String? description;

  /// The listing's category ("Sports", "News" ...), or null.
  final String? kind;

  /// The server's cached copy of the programme picture, or null.
  final String? imageId;

  const IptvProgramme({
    required this.start,
    required this.end,
    required this.title,
    this.subtitle,
    this.description,
    this.kind,
    this.imageId,
  });

  Duration get runTime => end.difference(start);

  bool isOnAt(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  static IptvProgramme? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final start = _date(map, 'Start');
    final end = _date(map, 'End');
    if (start == null || end == null || !end.isAfter(start)) return null;
    return IptvProgramme(
      start: start,
      end: end,
      title: _string(map, 'Title') ?? '',
      subtitle: _string(map, 'Subtitle'),
      description: _string(map, 'Description'),
      kind: _string(map, 'Kind'),
      imageId: _string(map, 'ImageId'),
    );
  }
}

/// `GET Iptv/{libraryId}/Guide`: every channel's programmes overlapping a
/// window. Same envelope as Old School's guide.
class IptvGuide {
  final DateTime serverTime;
  final DateTime? start;
  final DateTime? end;

  /// Channel id -> programmes in start order. A channel with no listings has
  /// an empty list.
  final Map<String, List<IptvProgramme>> entriesByChannel;

  const IptvGuide({required this.serverTime, this.start, this.end, this.entriesByChannel = const {}});

  static IptvGuide? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final serverTime = _date(map, 'ServerTime');
    if (serverTime == null) return null;
    final channels = map['Channels'] ?? map['channels'] ?? const [];
    final byChannel = <String, List<IptvProgramme>>{};
    if (channels is List) {
      for (final row in channels) {
        if (row is! Map) continue;
        final rowMap = row.cast<String, dynamic>();
        final id = _string(rowMap, 'Id') ?? _string(rowMap, 'ChannelId');
        if (id == null) continue;
        final entries = rowMap['Entries'] ?? rowMap['entries'] ?? const [];
        byChannel[id] = [
          if (entries is List)
            for (final entry in entries) ?IptvProgramme.fromJson(entry),
        ]..sort((a, b) => a.start.compareTo(b.start));
      }
    }
    return IptvGuide(
      serverTime: serverTime,
      start: _date(map, 'Start'),
      end: _date(map, 'End'),
      entriesByChannel: byChannel,
    );
  }
}

/// [url] without its query or login, for logs: a paid provider's stream
/// address often carries the subscriber's login.
String iptvLogUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return '<feed>';
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path).toString();
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

bool? _bool(Map<String, dynamic> map, String pascal) {
  final value = map[pascal] ?? map[_camel(pascal)];
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return null;
}

DateTime? _date(Map<String, dynamic> map, String pascal) {
  final value = map[pascal] ?? map[_camel(pascal)];
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String _camel(String pascal) => pascal.isEmpty ? pascal : pascal[0].toLowerCase() + pascal.substring(1);
