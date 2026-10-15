import 'package:flutter/foundation.dart';

/// The top-left title over a break trailer that points at a film, show or
/// course (PLAN_SHA_47): the item's name, never the trailer file's, and
/// "Trailer · 2011 · PG-13" (or "Trailer · coming soon").
@immutable
class OldSchoolTrailerTitle {
  final String title;
  final String line;

  const OldSchoolTrailerTitle({required this.title, required this.line});
}

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

  /// What OK on the bare picture does instead of toggling playback while a
  /// trailer's item can be opened (PLAN_SHA_43/47): during the trailer with
  /// the controls up, or in its last seconds. Given whether the controls
  /// show; returns null when nothing can be opened.
  final VoidCallback? Function(bool controlsVisible)? promoAction;

  /// The title over a break trailer with an item behind it, read when the
  /// controls build; null for anything else. While set, the header shows
  /// it and TVs show the progress bar alone, without buttons (PLAN_SHA_47).
  final OldSchoolTrailerTitle? Function()? promoTrailer;

  const OldSchoolControls({
    required this.onRestart,
    required this.onBackToLive,
    required this.onChannelUp,
    required this.onChannelDown,
    required this.onGuide,
    this.promoAction,
    this.promoTrailer,
  });
}
