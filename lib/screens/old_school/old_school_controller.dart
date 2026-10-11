import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/old_school.dart';
import '../../services/jellyfin_client.dart';
import '../../utils/app_logger.dart';

/// State shared by the Old School guide and the player while Old School is
/// open: the line-up, the loaded guide, the server's clock, and which
/// channel is tuned. One instance lives for the whole visit, so the guide
/// keeps its place when the player takes over the page.
class OldSchoolController extends ChangeNotifier {
  OldSchoolController(this.client);

  final JellyfinClient client;

  /// The guide is fetched in blocks of this many hours (the server allows up
  /// to 24 per call) and grows forward as the viewer moves right, up to
  /// [maxGuideHours] (the server plans 7 days).
  static const blockHours = 12;
  static const maxGuideHours = 7 * 24;

  List<OldSchoolChannel> _channels = const [];
  final Map<String, List<OldSchoolEntry>> _entries = {};
  DateTime? _guideStart;
  DateTime? _guideEnd;
  Duration _clockSkew = Duration.zero;
  bool _loading = false;
  bool _extending = false;
  Object? _error;
  bool _disposed = false;

  String? _tunedChannelId;
  OldSchoolTune? _tune;

  List<OldSchoolChannel> get channels => _channels;
  bool get isLoading => _loading;
  bool get hasLoaded => _guideStart != null;
  Object? get error => _error;
  DateTime? get guideStart => _guideStart;
  DateTime? get guideEnd => _guideEnd;

  /// The channel playing, if any.
  String? get tunedChannelId => _tunedChannelId;
  OldSchoolChannel? get tunedChannel => channelById(_tunedChannelId);

  /// The last Tune answer for [tunedChannelId].
  OldSchoolTune? get tune => _tune;

  /// The server's time as this device reckons it.
  DateTime get serverNow => DateTime.now().toUtc().add(_clockSkew);

  OldSchoolChannel? channelById(String? id) {
    if (id == null) return null;
    for (final channel in _channels) {
      if (channel.id == id) return channel;
    }
    return null;
  }

  int indexOfChannel(String? id) => id == null ? -1 : _channels.indexWhere((c) => c.id == id);

  /// [channelId]'s entries in start order (programmes, trailers and standby).
  List<OldSchoolEntry> entriesFor(String channelId) => _entries[channelId] ?? const [];

  /// What the grid shows as blocks: programmes, and each trailer and standby
  /// gap as its own faded cell at its real span, as the web guide does
  /// (Adrian, 2026-10-11).
  List<OldSchoolEntry> guideEntriesFor(String channelId) =>
      entriesFor(channelId).where((e) => e.kind != OldSchoolEntryKind.unknown).toList(growable: false);

  /// [channelId]'s programmes only.
  List<OldSchoolEntry> programmesFor(String channelId) =>
      entriesFor(channelId).where((e) => e.isProgramme).toList(growable: false);

  /// The programme on [channelId] at [at] (default now), or null in a break.
  OldSchoolEntry? programmeAt(String channelId, [DateTime? at]) {
    final time = at ?? serverNow;
    for (final entry in entriesFor(channelId)) {
      if (entry.isProgramme && entry.isOnAt(time)) return entry;
    }
    return null;
  }

  /// The programme on now, else the next one coming up on [channelId].
  OldSchoolEntry? currentOrNextProgramme(String channelId) {
    final now = serverNow;
    for (final entry in entriesFor(channelId)) {
      if (entry.isProgramme && entry.end.isAfter(now)) return entry;
    }
    return null;
  }

  /// The channel [step] places from [channelId] in number order, wrapping.
  OldSchoolChannel? neighbourOf(String channelId, int step) {
    if (_channels.isEmpty) return null;
    final index = indexOfChannel(channelId);
    if (index < 0) return _channels.first;
    return _channels[(index + step) % _channels.length];
  }

  /// Load the line-up and the first guide block, starting at the half hour
  /// before now.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final channels = await client.fetchOldSchoolChannels();
      final now = DateTime.now().toUtc();
      final start = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
      final guide = await client.fetchOldSchoolGuide(start: start, hours: blockHours);
      if (_disposed) return;
      _channels = channels;
      _clockSkew = guide.serverTime.difference(DateTime.now().toUtc());
      _entries
        ..clear()
        ..addAll(guide.entriesByChannel);
      _guideStart = start;
      _guideEnd = start.add(const Duration(hours: blockHours));
    } catch (e, st) {
      appLogger.w('Old School: could not load the guide', error: e, stackTrace: st);
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Fetch the next guide block when [visibleEnd] comes within two hours of
  /// what is loaded.
  Future<void> extendIfNeeded(DateTime visibleEnd) async {
    final start = _guideStart;
    final end = _guideEnd;
    if (start == null || end == null || _extending) return;
    if (visibleEnd.isBefore(end.subtract(const Duration(hours: 2)))) return;
    if (end.difference(start).inHours >= maxGuideHours) return;
    _extending = true;
    try {
      final guide = await client.fetchOldSchoolGuide(start: end, hours: blockHours);
      if (_disposed) return;
      for (final row in guide.entriesByChannel.entries) {
        final list = _entries.putIfAbsent(row.key, () => []);
        for (final entry in row.value) {
          // Entries crossing the block edge come back in both answers.
          if (!list.any((e) => e.start == entry.start && e.itemId == entry.itemId)) list.add(entry);
        }
        list.sort((a, b) => a.start.compareTo(b.start));
      }
      _guideEnd = end.add(const Duration(hours: blockHours));
      _notify();
    } catch (e, st) {
      appLogger.w('Old School: could not load more of the guide', error: e, stackTrace: st);
    } finally {
      _extending = false;
    }
  }

  /// Ask the server what is on [channelId] now; remembers it as the tuned
  /// channel.
  Future<OldSchoolTune> tuneTo(String channelId) async {
    final tune = await client.tuneOldSchool(channelId);
    if (_disposed) return tune;
    _tunedChannelId = channelId;
    _tune = tune;
    _clockSkew = tune.serverTime.difference(tune.receivedAt.toUtc());
    _notify();
    return tune;
  }

  /// Forget the tuned channel (playback stopped).
  void clearTune() {
    if (_tunedChannelId == null && _tune == null) return;
    _tunedChannelId = null;
    _tune = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
