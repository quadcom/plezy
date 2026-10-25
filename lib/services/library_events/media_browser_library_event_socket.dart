import 'dart:async';
import 'dart:convert';

import '../../media/media_browser_dialect.dart';
import 'library_event_socket.dart';
import 'old_school_guide_events.dart';

/// MediaBrowser (Jellyfin/Emby) session socket:
/// `ws(s)://<server><dialect.webSocketPath>?<dialect token key>=<token>&deviceId=<id>`.
///
/// Protocol (verified against Jellyfin 10.11 and Emby 4.9.5):
/// - The server opens with `ForceKeepAlive` whose `Data` is the timeout in
///   seconds; the client must send `{"MessageType": "KeepAlive"}` within it
///   or the session is dropped. jellyfin-web pings at half the timeout.
/// - `LibraryChanged` carries the batched change sets — the server already
///   coalesces a scan into one frame (~30 s trailing), delivered to admin
///   and non-admin sessions alike:
///
/// ```json
/// {"MessageType": "LibraryChanged", "Data": {
///   "FoldersAddedTo": [...], "FoldersRemovedFrom": [...],
///   "ItemsAdded": [...], "ItemsRemoved": [...], "ItemsUpdated": [...],
///   "CollectionFolders": ["f137a2dd..."], "IsEmpty": false}}
/// ```
///
/// Emby additionally requires the session to have registered device
/// capabilities before it routes `LibraryChanged` frames — see
/// [MediaBrowserDialect.requiresSessionCapabilitiesForLibraryEvents]; the
/// client supplies that call through [registerCapabilities].
/// - PlezyFin adds `OldSchoolGuideChanged` (`{"ChannelIds", "From", "To"}`)
///   when stored Old School guide entries change (PLAN_PFN_87); it goes to
///   [OldSchoolGuideEvents], not the library-change path.
class MediaBrowserLibraryEventSocket extends LibraryEventSocket {
  MediaBrowserLibraryEventSocket({
    required super.serverId,
    required this.dialect,
    required this.baseUrl,
    required this.accessToken,
    required this.deviceId,
    this.registerCapabilities,
    OldSchoolGuideEvents? oldSchoolGuideEvents,
    super.channelFactory,
    super.debounce = const Duration(seconds: 2),
    super.retryBaseDelay,
    super.maxConnectAttempts,
  }) : _oldSchoolGuideEvents = oldSchoolGuideEvents ?? OldSchoolGuideEvents.instance;

  final MediaBrowserDialect dialect;

  /// Read live so an endpoint failover lands on the next connect attempt.
  final String Function() baseUrl;
  final String accessToken;
  final String deviceId;

  /// Runs before each connect on dialects that need it (Emby's
  /// `POST /Sessions/Capabilities/Full`).
  final Future<void> Function()? registerCapabilities;

  final OldSchoolGuideEvents _oldSchoolGuideEvents;

  Timer? _keepAliveTimer;

  @override
  Uri buildUri() {
    final base = webSocketBase(baseUrl());
    return base.replace(
      path: '${base.path}${dialect.webSocketPath}',
      queryParameters: {dialect.tokenQueryParam: accessToken, 'deviceId': deviceId},
    );
  }

  @override
  Future<void> prepareConnection() async {
    if (!dialect.requiresSessionCapabilitiesForLibraryEvents) return;
    // Without this Emby accepts the socket but never routes LibraryChanged
    // to it. A failure fails the attempt into the normal retry path.
    await registerCapabilities?.call();
  }

  @override
  void onFrame(dynamic frame) {
    final message = tryDecodeJsonFrame(frame);
    if (message == null) return;
    switch (message['MessageType']) {
      case 'ForceKeepAlive':
        _startKeepAlive(message['Data']);
      case 'LibraryChanged':
        _handleLibraryChanged(message['Data']);
      case 'OldSchoolGuideChanged':
        final change = OldSchoolGuideChange.fromJson(serverId, message['Data']);
        if (change != null) _oldSchoolGuideEvents.notifyChanged(change);
      default:
        // KeepAlive acks, RefreshProgress, UserDataChanged (future watch-state
        // sync seam), session traffic — not library content.
        break;
    }
  }

  void _handleLibraryChanged(dynamic data) {
    if (data is! Map) return;
    bool nonEmpty(dynamic value) => value is List && value.isNotEmpty;
    final collectionFolders = data['CollectionFolders'];
    final itemsRemoved = data['ItemsRemoved'];
    final itemsUpdated = data['ItemsUpdated'];
    scheduleLibraryChange(
      libraryIds: [
        if (collectionFolders is List)
          for (final id in collectionFolders)
            if (id != null) id.toString(),
      ],
      removedItemIds: [
        if (itemsRemoved is List)
          for (final id in itemsRemoved)
            if (id != null) id.toString(),
      ],
      // A server-side file swap keeps the item id and arrives here, so open
      // screens can refetch exactly that item.
      updatedItemIds: [
        if (itemsUpdated is List)
          for (final id in itemsUpdated)
            if (id != null) id.toString(),
      ],
      added: nonEmpty(data['ItemsAdded']) || nonEmpty(data['FoldersAddedTo']),
      removed: nonEmpty(itemsRemoved) || nonEmpty(data['FoldersRemovedFrom']),
      updated: nonEmpty(itemsUpdated),
    );
  }

  void _startKeepAlive(dynamic timeoutSeconds) {
    final seconds = timeoutSeconds is num ? timeoutSeconds.toInt() : 60;
    // Half the advertised timeout, floored so a bogus tiny value cannot spin.
    final interval = Duration(seconds: (seconds ~/ 2).clamp(10, 300));
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(interval, (_) => _sendKeepAlive());
    _sendKeepAlive();
  }

  void _sendKeepAlive() => sendFrame(jsonEncode(const {'MessageType': 'KeepAlive'}));

  /// Notices may have been missed while the socket was down: an open Old
  /// School guide re-fetches once.
  @override
  void onConnected() => _oldSchoolGuideEvents.notifyConnected(serverId);

  @override
  void onDisconnected() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }
}
