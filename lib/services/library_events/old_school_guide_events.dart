import 'dart:async';

import '../../media/ids.dart';

/// A PlezyFin notice that stored Old School guide entries changed
/// (PLAN_PFN_87, local/plans/old-school-live-guide.md): which channels, and
/// the span the changes cover across them.
class OldSchoolGuideChange {
  final ServerId serverId;
  final Set<String> channelIds;
  final DateTime from;
  final DateTime to;

  const OldSchoolGuideChange({required this.serverId, required this.channelIds, required this.from, required this.to});

  /// `{"ChannelIds": [...], "From": "<utc>", "To": "<utc>"}`; null when a
  /// part is missing, names no channel or the span is empty.
  static OldSchoolGuideChange? fromJson(ServerId serverId, Object? data) {
    if (data is! Map) return null;
    final ids = data['ChannelIds'] ?? data['channelIds'];
    final from = _date(data['From'] ?? data['from']);
    final to = _date(data['To'] ?? data['to']);
    if (ids is! List || from == null || to == null || !to.isAfter(from)) return null;
    final channelIds = {
      for (final id in ids)
        if (id != null && id.toString().isNotEmpty) id.toString(),
    };
    if (channelIds.isEmpty) return null;
    return OldSchoolGuideChange(serverId: serverId, channelIds: channelIds, from: from, to: to);
  }

  static DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

/// App-wide bus from the server sockets to an open Old School guide: guide
/// change notices, and each (re)connect of a server's socket, after which
/// notices may have been missed.
class OldSchoolGuideEvents {
  OldSchoolGuideEvents();

  static final instance = OldSchoolGuideEvents();

  final _changes = StreamController<OldSchoolGuideChange>.broadcast(sync: true);
  final _connected = StreamController<ServerId>.broadcast(sync: true);

  Stream<OldSchoolGuideChange> get changes => _changes.stream;
  Stream<ServerId> get connected => _connected.stream;

  void notifyChanged(OldSchoolGuideChange change) => _changes.add(change);
  void notifyConnected(ServerId serverId) => _connected.add(serverId);
}
