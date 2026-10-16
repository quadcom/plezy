import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/iptv.dart';
import '../../services/jellyfin_client.dart';
import '../../utils/app_logger.dart';

/// The group filter above the guide: everything, the viewer's favourites, or
/// one playlist group.
@immutable
class IptvFilter {
  /// Null with [favourites] false: all channels.
  final String? group;
  final bool favourites;

  const IptvFilter.all() : group = null, favourites = false;
  const IptvFilter.favourites() : group = null, favourites = true;
  const IptvFilter.group(String this.group) : favourites = false;

  bool get isAll => group == null && !favourites;

  bool matches(IptvChannel channel) {
    if (favourites) return channel.isFavorite;
    final wanted = group;
    return wanted == null || iptvGroupKey(channel.group) == wanted;
  }

  @override
  bool operator ==(Object other) => other is IptvFilter && other.group == group && other.favourites == favourites;

  @override
  int get hashCode => Object.hash(group, favourites);
}

/// The group a channel is filed under; the playlist's "Undefined" and a
/// missing group are one group, shown as "Other" (PLAN_SHA_61a).
String iptvGroupKey(String? group) {
  final value = group?.trim() ?? '';
  return value.isEmpty || value.toLowerCase() == 'undefined' ? '' : value;
}

/// State shared by the IPTV guide and the player while IPTV is open: the
/// line-up, the loaded guide, the server's clock, the filter, and which
/// channel is tuned. One instance lives for the whole visit, so the guide
/// keeps its place when the player takes over the page.
class IptvController extends ChangeNotifier {
  IptvController(this.client, {required this.libraryId, this.libraryTitle});

  final JellyfinClient client;
  final String libraryId;
  final String? libraryTitle;

  /// The guide comes in blocks of this many hours (the server allows up to
  /// 24 per call) and grows forward as the viewer moves right, up to the
  /// seven days the server can hold.
  static const blockHours = 12;
  static const maxGuideHours = 7 * 24;
  static const firstBlockHours = 3;

  /// While the guide is open the line-up is read again this often, which is
  /// how a newer stream check clears this device's "may not be working"
  /// marks (plan 61: on open, then every 30 minutes).
  static const lineupRefresh = Duration(minutes: 30);

  /// Channels this device found dead, per library: channel id -> the stream
  /// check the line-up carried then. Kept for the app's life, so leaving and
  /// coming back keeps the mark until the server checks again.
  static final Map<String, Map<String, DateTime?>> _deadMarks = {};

  IptvLineup? _lineup;
  final Map<String, List<IptvProgramme>> _entries = {};
  DateTime? _guideStart;
  DateTime? _guideEnd;
  Duration _clockSkew = Duration.zero;
  bool _loading = false;
  bool _extending = false;
  Object? _error;
  bool _disposed = false;
  Timer? _refreshTimer;

  IptvFilter _filter = const IptvFilter.all();
  String? _tunedChannelId;
  String? _lastChannelId;

  List<IptvChannel> get allChannels => _lineup?.channels ?? const [];

  /// The channels the filter lets through, in number order.
  List<IptvChannel> get channels {
    final all = allChannels;
    return _filter.isAll ? all : all.where(_filter.matches).toList(growable: false);
  }

  IptvFilter get filter => _filter;
  bool get isLoading => _loading;
  bool get hasLoaded => _lineup != null && _guideStart != null;
  Object? get error => _error;
  DateTime? get guideStart => _guideStart;
  DateTime? get guideEnd => _guideEnd;
  String get title => _lineup?.libraryName ?? libraryTitle ?? 'IPTV';

  /// The server's time as this device reckons it.
  DateTime get serverNow => DateTime.now().toUtc().add(_clockSkew);

  String? get tunedChannelId => _tunedChannelId;
  IptvChannel? get tunedChannel => channelById(_tunedChannelId);

  /// The channel watched before this one, for the Last button.
  IptvChannel? get lastChannel => channelById(_lastChannelId);

  /// The groups, biggest first, for the filter tabs. "Other" (no group) goes
  /// where its size puts it, like the rest.
  List<({String key, int count})> get groups {
    final counts = <String, int>{};
    for (final channel in allChannels) {
      final key = iptvGroupKey(channel.group);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final list = [for (final entry in counts.entries) (key: entry.key, count: entry.value)];
    list.sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : a.key.compareTo(b.key));
    return list;
  }

  bool get hasFavourites => allChannels.any((c) => c.isFavorite);

  IptvChannel? channelById(String? id) {
    if (id == null) return null;
    for (final channel in allChannels) {
      if (channel.id == id) return channel;
    }
    return null;
  }

  /// The channel with this number, in the whole line-up (number entry is not
  /// limited by the filter).
  IptvChannel? channelByNumber(int number) {
    for (final channel in allChannels) {
      if (channel.number == number) return channel;
    }
    return null;
  }

  /// Whether some channel's number starts with [digits] and is longer, so
  /// number entry should wait for another digit.
  bool numberCouldGrow(String digits) =>
      allChannels.any((c) => '${c.number}'.length > digits.length && '${c.number}'.startsWith(digits));

  int indexOfChannel(String? id) => id == null ? -1 : channels.indexWhere((c) => c.id == id);

  /// [channelId]'s programmes in start order; empty without listings.
  List<IptvProgramme> entriesFor(String channelId) => _entries[channelId] ?? const [];

  IptvProgramme? programmeAt(String channelId, [DateTime? at]) {
    final time = at ?? serverNow;
    for (final entry in entriesFor(channelId)) {
      if (entry.isOnAt(time)) return entry;
    }
    return null;
  }

  /// The programme after the one on at [at] (default now).
  IptvProgramme? nextProgramme(String channelId, [DateTime? at]) {
    final time = at ?? serverNow;
    for (final entry in entriesFor(channelId)) {
      if (entry.start.isAfter(time)) return entry;
    }
    return null;
  }

  /// The programme on now, else the next one coming up.
  IptvProgramme? currentOrNextProgramme(String channelId) {
    final now = serverNow;
    for (final entry in entriesFor(channelId)) {
      if (entry.end.isAfter(now)) return entry;
    }
    return null;
  }

  /// The channel [step] places from [channelId] among the filtered channels,
  /// wrapping. Falls back to the whole line-up when the tuned channel is not
  /// in the filter.
  IptvChannel? neighbourOf(String channelId, int step) {
    var list = channels;
    var index = list.indexWhere((c) => c.id == channelId);
    if (index < 0) {
      list = allChannels;
      index = list.indexWhere((c) => c.id == channelId);
    }
    if (list.isEmpty) return null;
    if (index < 0) return list.first;
    return list[(index + step) % list.length];
  }

  /// "May not be working": the server's last check, or this device found
  /// every feed dead since that check.
  bool mayNotWork(IptvChannel channel) => channel.status == IptvStatus.mayNotWork || isMarkedDead(channel.id);

  bool isMarkedDead(String channelId) => _deadMarks[libraryId]?.containsKey(channelId) ?? false;

  /// Every feed of [channelId] failed on this device. The mark lasts until a
  /// line-up with a newer stream check arrives.
  void markDead(String channelId) {
    (_deadMarks[libraryId] ??= {})[channelId] = _lineup?.checkedAt;
    _notify();
  }

  void setFilter(IptvFilter filter) {
    if (_filter == filter) return;
    _filter = filter;
    _notify();
  }

  /// Load the line-up and the first [firstBlockHours] of the guide, from the
  /// half hour before now, then the next block in the background. Starts the
  /// 30-minute line-up refresh.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      var start = _halfHourBefore(DateTime.now().toUtc());
      final lineupCall = client.fetchIptvLineup(libraryId)..ignore();
      // The channels show even when the listings fail (an empty or broken
      // guide on the server): every row then says "No listings".
      IptvGuide? guide;
      try {
        guide = await client.fetchIptvGuide(libraryId, start: start, hours: firstBlockHours);
        _clockSkew = guide.serverTime.difference(DateTime.now().toUtc());
        // A device clock that is off asked for the wrong hours: ask again by
        // the server's clock.
        final serverStart = _halfHourBefore(serverNow);
        if (serverStart != start) {
          start = serverStart;
          guide = await client.fetchIptvGuide(libraryId, start: start, hours: firstBlockHours);
        }
      } catch (e, st) {
        appLogger.w('IPTV: could not load the listings; showing the channels without them', error: e, stackTrace: st);
        guide = null;
      }
      final lineup = await lineupCall;
      if (_disposed) return;
      if (guide == null) {
        _clockSkew = lineup.serverTime.difference(DateTime.now().toUtc());
        start = _halfHourBefore(serverNow);
      }
      _applyLineup(lineup);
      _entries
        ..clear()
        ..addAll(guide?.entriesByChannel ?? const {});
      _guideStart = start;
      _guideEnd = start.add(const Duration(hours: firstBlockHours));
    } catch (e, st) {
      appLogger.w('IPTV: could not load the channels', error: e, stackTrace: st);
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
    _refreshTimer?.cancel();
    if (_disposed) return;
    _refreshTimer = Timer.periodic(lineupRefresh, (_) => unawaited(refreshLineup()));
    final end = _guideEnd;
    if (_error == null && end != null) unawaited(extendIfNeeded(end));
  }

  static DateTime _halfHourBefore(DateTime t) => DateTime.utc(t.year, t.month, t.day, t.hour, t.minute >= 30 ? 30 : 0);

  /// Read the line-up again (favourites, marks and new channels). A failure
  /// keeps what is shown.
  Future<void> refreshLineup() async {
    try {
      final lineup = await client.fetchIptvLineup(libraryId);
      if (_disposed) return;
      _applyLineup(lineup);
      _notify();
    } catch (e, st) {
      appLogger.w('IPTV: could not refresh the channels', error: e, stackTrace: st);
    }
  }

  void _applyLineup(IptvLineup lineup) {
    _lineup = lineup;
    // A stream check newer than the one a mark was made under clears it.
    final marks = _deadMarks[libraryId];
    final checkedAt = lineup.checkedAt;
    if (marks != null && checkedAt != null) {
      marks.removeWhere((_, markedUnder) => markedUnder == null || checkedAt.isAfter(markedUnder));
    }
    if (_filter.favourites && !lineup.channels.any((c) => c.isFavorite)) _filter = const IptvFilter.all();
  }

  /// Fetch the next guide block when [visibleEnd] comes within two hours of
  /// what is loaded.
  Future<void> extendIfNeeded(DateTime visibleEnd) async {
    final start = _guideStart;
    final end = _guideEnd;
    if (start == null || end == null || _extending) return;
    if (visibleEnd.isBefore(end.subtract(const Duration(hours: 2)))) return;
    final loadedHours = end.difference(start).inHours;
    if (loadedHours >= maxGuideHours) return;
    final hours = math.min(blockHours, maxGuideHours - loadedHours);
    _extending = true;
    try {
      final guide = await client.fetchIptvGuide(libraryId, start: end, hours: hours);
      if (_disposed || _guideStart != start || _guideEnd != end) return;
      for (final row in guide.entriesByChannel.entries) {
        final list = _entries.putIfAbsent(row.key, () => []);
        for (final entry in row.value) {
          // Programmes crossing the block edge come back in both answers.
          if (!list.any((e) => e.start == entry.start)) list.add(entry);
        }
        list.sort((a, b) => a.start.compareTo(b.start));
      }
      _guideEnd = end.add(Duration(hours: hours));
      _notify();
    } catch (e, st) {
      appLogger.w('IPTV: could not load more of the guide', error: e, stackTrace: st);
    } finally {
      _extending = false;
    }
  }

  /// [channelId] is now playing; the one before it becomes "Last".
  void setTuned(String? channelId) {
    if (channelId == _tunedChannelId) return;
    if (_tunedChannelId != null) _lastChannelId = _tunedChannelId;
    _tunedChannelId = channelId;
    _notify();
  }

  /// Star or unstar [channel]. Shown at once; put back if the server refuses.
  Future<void> toggleFavourite(IptvChannel channel) async {
    final lineup = _lineup;
    if (lineup == null) return;
    final wanted = !channel.isFavorite;
    _replaceChannel(channel.id, (c) => c.copyWith(isFavorite: wanted));
    try {
      await client.setIptvFavorite(channel.id, wanted);
    } catch (e, st) {
      appLogger.w('IPTV: could not change the favourite', error: e, stackTrace: st);
      _replaceChannel(channel.id, (c) => c.copyWith(isFavorite: !wanted));
    }
  }

  void _replaceChannel(String id, IptvChannel Function(IptvChannel) change) {
    final lineup = _lineup;
    if (lineup == null || _disposed) return;
    _lineup = IptvLineup(
      serverTime: lineup.serverTime,
      libraryId: lineup.libraryId,
      libraryName: lineup.libraryName,
      checkedAt: lineup.checkedAt,
      channels: [for (final c in lineup.channels) c.id == id ? change(c) : c],
    );
    if (_filter.favourites && !_lineup!.channels.any((c) => c.isFavorite)) _filter = const IptvFilter.all();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    super.dispose();
  }
}
