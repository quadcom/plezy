import 'dart:async';

import '../../models/iptv.dart';
import '../../models/livetv_channel.dart';
import '../iptv/iptv_controller.dart';
import '../iptv/iptv_overlays.dart';

/// Launch parameters for an IPTV session (PlezyFin PLAN_SHA_61). A
/// [VideoPlayerScreen] plays IPTV iff it was built with one of these, on top
/// of the live-TV path (`live` is set too).
///
/// The channel plays straight from its source: no server step, no seeking,
/// nothing counted as watched, and the guide on the same page with the video
/// in its corner, as Old School.
class IptvSessionArgs {
  /// The guide's state, carried over from the guide page. The player owns it
  /// from here on and disposes it.
  final IptvController controller;

  /// The channel to start on.
  final IptvChannel channel;

  const IptvSessionArgs({required this.controller, required this.channel});
}

/// The stand-in live channel the player's live path carries for an IPTV
/// channel.
LiveTvChannel iptvLiveChannel(IptvChannel channel, {String? serverId, String? serverName}) => LiveTvChannel(
  key: channel.id,
  title: channel.name,
  number: channel.numberLabel,
  serverId: serverId,
  serverName: serverName,
);

/// The player's IPTV state.
class IptvPlayerState {
  /// Video full screen (true) or in the guide's corner window (false). The
  /// first pick plays in the corner (Adrian, 2026-10-16).
  bool fullScreen = false;

  /// When "Press Back again to leave" was shown.
  DateTime? backNoteShownAt;
  Timer? backNoteTimer;

  /// The full-screen banner shows until this time (5 s after the last
  /// mouse move or key, PLAN_SHA_61a).
  DateTime? bannerUntil;
  Timer? bannerTimer;

  /// The banner button the remote is on; null for mouse and touch.
  IptvBannerButton? bannerFocus;

  /// The channel that failed: its message shows, then the guide.
  String? deadChannelId;
  Timer? deadTimer;

  /// Waits for the first picture of a feed, or watches for a stall.
  Timer? watchdog;

  /// The player's position last time the watchdog looked, and when.
  Duration? lastPosition;
  DateTime? lastProgressAt;

  /// The current feed has shown a picture.
  bool feedStarted = false;

  /// When the current feed was opened, and whether the player has reported
  /// an error for it since.
  DateTime? openedAt;
  bool errorSeen = false;

  /// A tune or failover is in flight.
  int tuneGeneration = 0;
  bool failingOver = false;

  static const backAgainWindow = Duration(seconds: 3);
  static const bannerTime = Duration(seconds: 5);

  /// How long a feed has to start (plan 61: about 8 s per feed).
  static const feedStartTimeout = Duration(seconds: 8);

  /// How long a playing feed may sit still before it counts as dropped.
  static const stallTimeout = Duration(seconds: 12);

  /// How long the dead-channel message shows before the guide comes back.
  static const deadMessageTime = Duration(seconds: 4);

  bool get backNoteVisible {
    final shown = backNoteShownAt;
    return shown != null && DateTime.now().difference(shown) < backAgainWindow;
  }

  bool get bannerVisible {
    final until = bannerUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void dispose() {
    backNoteTimer?.cancel();
    bannerTimer?.cancel();
    deadTimer?.cancel();
    watchdog?.cancel();
  }
}
