import 'package:flutter/foundation.dart';

/// The player controls' Old School mode (PLAN_SHA_21): no seeking ahead, no
/// item skipping, and its own buttons instead: Restart, Back to live,
/// Channel down/up and Guide.
@immutable
class OldSchoolControls {
  final VoidCallback onRestart;
  final VoidCallback onBackToLive;
  final VoidCallback onChannelUp;
  final VoidCallback onChannelDown;
  final VoidCallback onGuide;

  /// While a trailer's end banner shows (PLAN_SHA_43), what OK on the bare
  /// picture does instead of raising the controls: open the banner's item.
  /// Returns null when no banner shows.
  final VoidCallback? Function()? promoAction;

  const OldSchoolControls({
    required this.onRestart,
    required this.onBackToLive,
    required this.onChannelUp,
    required this.onChannelDown,
    required this.onGuide,
    this.promoAction,
  });
}
