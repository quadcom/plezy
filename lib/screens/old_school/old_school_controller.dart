import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../media/ids.dart';
import '../../models/old_school.dart';
import '../../services/jellyfin_client.dart';
import '../../services/library_events/old_school_guide_events.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';

/// State shared by the Old School guide and the player while Old School is
/// open: the line-up, the loaded guide, the server's clock, and which
/// channel is tuned. One instance lives for the whole visit, so the guide
/// keeps its place when the player takes over the page.
class OldSchoolController extends ChangeNotifier {
  OldSchoolController(this.client, {OldSchoolGuideEvents? guideEvents}) {
    final events = guideEvents ?? OldSchoolGuideEvents.instance;
    _guideSubscriptions = [events.changes.listen(_onGuideChanged), events.connected.listen(_onSocketConnected)];
  }

  final JellyfinClient client;

  /// The guide is fetched in blocks of this many hours (the server allows up
  /// to 24 per call) and grows forward as the viewer moves right, up to
  /// [maxGuideHours] (the server plans 7 days).
  static const blockHours = 12;
  static const maxGuideHours = 7 * 24;

  /// The first guide call asks for only this many hours so the grid shows
  /// quickly: the server spends about 1 ms per entry, and 12 hours of every
  /// channel took it 2.5-6.5 s (PlezyFin PLAN_SHA_48). The next block is
  /// fetched straight after, in the background.
  static const firstBlockHours = 3;

  /// Live guide (PlezyFin PLAN_PFN_87, local/plans/old-school-live-guide.md):
  /// the server's change notices are gathered for this long, then the
  /// changed channels are fetched again in one go. Nothing is polled.
  static const changeBatch = Duration(seconds: 2);

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

  late final List<StreamSubscription<Object?>> _guideSubscriptions;
  Timer? _changeTimer;
  final Set<String> _changedChannels = {};
  bool _allChanged = false;
  DateTime? _changedFrom;
  DateTime? _changedTo;
  bool _refreshing = false;

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

  /// What the grid shows as blocks: programmes, and each break (its
  /// trailers, music and standby together) as one Intermission block, one
  /// stop for the remote (PLAN_SHA_28, replacing a cell per trailer).
  List<OldSchoolEntry> guideEntriesFor(String channelId) =>
      OldSchoolEntry.joinBreaks(entriesFor(channelId).where((e) => e.kind != OldSchoolEntryKind.unknown));

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

  /// Load the line-up and the first [firstBlockHours] of the guide, starting
  /// at the half hour before now, then fetch the next block in the background.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final now = DateTime.now().toUtc();
      final start = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
      // Both calls at once. ignore() only stops a failed line-up call being
      // reported as unhandled when the guide call throws first.
      final channelsCall = client.fetchOldSchoolChannels()..ignore();
      final guide = await client.fetchOldSchoolGuide(start: start, hours: firstBlockHours);
      final channels = await channelsCall;
      if (_disposed) return;
      _channels = channels;
      _clockSkew = guide.serverTime.difference(DateTime.now().toUtc());
      _entries
        ..clear()
        ..addAll(guide.entriesByChannel);
      _guideStart = start;
      _guideEnd = start.add(const Duration(hours: firstBlockHours));
    } catch (e, st) {
      appLogger.w('Old School: could not load the guide', error: e, stackTrace: st);
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
    final end = _guideEnd;
    if (!_disposed && _error == null && end != null) unawaited(extendIfNeeded(end));
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
      final guide = await client.fetchOldSchoolGuide(start: end, hours: hours);
      // Gone, or reloaded from scratch while this block was on its way.
      if (_disposed || _guideStart != start || _guideEnd != end) return;
      // Entries crossing the block edge come back in both answers; the new
      // copy replaces the old, so one the server moved shows once.
      _replaceWindow(guide, end, end.add(Duration(hours: hours)));
      _guideEnd = end.add(Duration(hours: hours));
      _notify();
    } catch (e, st) {
      appLogger.w('Old School: could not load more of the guide', error: e, stackTrace: st);
    } finally {
      _extending = false;
    }
  }

  /// Put [guide]'s entries in place of what is loaded between [from] and
  /// [to], for every channel in the answer, or only [only].
  void _replaceWindow(OldSchoolGuide guide, DateTime from, DateTime to, {Set<String>? only}) {
    for (final row in guide.entriesByChannel.entries) {
      if (only != null && !only.contains(row.key)) continue;
      final list = _entries.putIfAbsent(row.key, () => [])
        ..removeWhere((e) => e.start.isBefore(to) && e.end.isAfter(from));
      for (final entry in row.value) {
        if (!list.any((e) => e.start == entry.start && e.itemId == entry.itemId)) list.add(entry);
      }
      list.sort((a, b) => a.start.compareTo(b.start));
    }
  }

  /// The server changed [change]'s channels: note the part that falls in
  /// the loaded window (the week's new day, at the 3 AM update, usually
  /// doesn't) and fetch it once the batch closes.
  void _onGuideChanged(OldSchoolGuideChange change) {
    if (_disposed || change.serverId != client.serverId) return;
    final start = _guideStart;
    final end = _guideEnd;
    if (start == null || end == null) return;
    final from = change.from.isBefore(start) ? start : change.from;
    final to = change.to.isAfter(end) ? end : change.to;
    if (!to.isAfter(from)) return;
    _changedChannels.addAll(change.channelIds);
    _markChanged(from, to);
  }

  /// The server's socket (re)connected: notices may have been missed, so
  /// everything loaded is fetched again, once.
  void _onSocketConnected(ServerId serverId) {
    if (_disposed || serverId != client.serverId) return;
    final start = _guideStart;
    final end = _guideEnd;
    if (start == null || end == null) return;
    _allChanged = true;
    _markChanged(start, end);
  }

  void _markChanged(DateTime from, DateTime to) {
    final changedFrom = _changedFrom;
    final changedTo = _changedTo;
    _changedFrom = changedFrom == null || from.isBefore(changedFrom) ? from : changedFrom;
    _changedTo = changedTo == null || to.isAfter(changedTo) ? to : changedTo;
    _changeTimer ??= Timer(changeBatch, () {
      _changeTimer = null;
      unawaited(_refreshChanged());
    });
  }

  /// Fetch the gathered changes: whole half hours, at most 24 hours a call
  /// (the server's limit), only the changed channels unless a reconnect
  /// asked for all of them.
  Future<void> _refreshChanged() async {
    if (_disposed) return;
    final from = _changedFrom;
    final to = _changedTo;
    if (from == null || to == null) return;
    if (_loading || _refreshing) {
      // Waits for the load or the last refresh, then tries again.
      _changeTimer ??= Timer(changeBatch, () {
        _changeTimer = null;
        unawaited(_refreshChanged());
      });
      return;
    }
    final channelIds = _allChanged ? null : Set<String>.of(_changedChannels);
    _changedChannels.clear();
    _allChanged = false;
    _changedFrom = null;
    _changedTo = null;
    final guideStart = _guideStart;
    _refreshing = true;
    try {
      var start = DateTime.utc(from.year, from.month, from.day, from.hour, from.minute >= 30 ? 30 : 0);
      while (start.isBefore(to)) {
        final hours = math.max(1, math.min(24, (to.difference(start).inMinutes / 60).ceil()));
        final guide = await client.fetchOldSchoolGuide(start: start, hours: hours, channelIds: channelIds);
        // Gone, or reloaded from scratch meanwhile.
        if (_disposed || _guideStart != guideStart) return;
        final end = start.add(Duration(hours: hours));
        _replaceWindow(guide, start, end, only: channelIds);
        start = end;
      }
      _notify();
    } catch (e, st) {
      appLogger.w('Old School: could not fetch the changed guide', error: e, stackTrace: st);
    } finally {
      _refreshing = false;
    }
  }

  /// Ask the server what is on [channelId] now; remembers it as the tuned
  /// channel, and on this device as the one to open on next time.
  Future<OldSchoolTune> tuneTo(String channelId) async {
    final tune = await client.tuneOldSchool(channelId);
    if (_disposed) return tune;
    _tunedChannelId = channelId;
    unawaited(SettingsService.instanceOrNull?.write(SettingsService.oldSchoolLastChannel, channelId));
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
    _changeTimer?.cancel();
    for (final subscription in _guideSubscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
