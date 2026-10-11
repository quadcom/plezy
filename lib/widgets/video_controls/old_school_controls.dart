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

  const OldSchoolControls({
    required this.onRestart,
    required this.onBackToLive,
    required this.onChannelUp,
    required this.onChannelDown,
    required this.onGuide,
  });
}
