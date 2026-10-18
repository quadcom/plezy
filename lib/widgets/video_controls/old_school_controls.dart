import 'package:flutter/foundation.dart';

/// The channel logo's place in the bottom-right corner of the full-screen
/// picture, as fractions of the screen: [oldSchoolLogoRight] in from the right
/// edge, [oldSchoolLogoWidth] wide, [oldSchoolLogoBottom] up from the bottom.
/// With the controls up it grows by [oldSchoolLogoGrow] (Adrian, 2026-10-15).
const oldSchoolLogoRight = 0.03;
const oldSchoolLogoWidth = 0.06;
const oldSchoolLogoBottom = 0.05;
const oldSchoolLogoGrow = 1.25;

/// With the controls up the logo also lifts so its bottom sits this far
/// above the screen's bottom edge, clear of the controls' button row and
/// beside the shortened timeline (the Greatroom TV, 2026-10-15: the grown
/// logo covered the settings and subtitle buttons). Logical pixels, like
/// the controls themselves.
const oldSchoolLogoLiftedBottom = 72.0;

/// How far in from the right edge the Old School timeline stops, so the
/// grown channel logo sits clear of it (Adrian, 2026-10-15: the timeline
/// covered part of the logo).
double oldSchoolTimelineClearance(double screenWidth) =>
    screenWidth * (oldSchoolLogoRight + oldSchoolLogoWidth * oldSchoolLogoGrow + 0.015);

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
  /// trailer's item can be opened (PLAN_SHA_43/47): any time its corner block
  /// shows, controls up or down. Returns null when nothing can be opened.
  final VoidCallback? Function()? promoAction;

  /// The title over a break trailer with an item behind it, read when the
  /// controls build; null for anything else. While set, the header shows
  /// it and TVs show the progress bar alone, without buttons (PLAN_SHA_47).
  final OldSchoolTrailerTitle? Function()? promoTrailer;

  /// "Match source" (local/plans/old-school-match-source.md): whether it is
  /// on for the programme playing, read when the controls build; null while
  /// it can't be offered (not Android TV, a film's own trailer, nothing on).
  final bool? Function()? matchSourceActive;
  final VoidCallback? onToggleMatchSource;

  const OldSchoolControls({
    required this.onRestart,
    required this.onBackToLive,
    required this.onChannelUp,
    required this.onChannelDown,
    required this.onGuide,
    this.promoAction,
    this.promoTrailer,
    this.matchSourceActive,
    this.onToggleMatchSource,
  });
}
