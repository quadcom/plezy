import 'dart:async';

import '../../models/old_school.dart';
import '../../screens/old_school/old_school_controller.dart';

/// Launch parameters for an Old School session (PLAN_SHA_21). A
/// [VideoPlayerScreen] plays Old School iff it was built with one of these.
///
/// Old School plays ordinary library items from a scheduled point, as if
/// live: no skipping ahead, nothing counted as watched, frame-rate matching
/// off, and the guide on the same page with the video in its corner.
class OldSchoolSessionArgs {
  /// The guide's state, carried over from the guide page. The player owns it
  /// from here on and disposes it.
  final OldSchoolController controller;

  /// The tune the first item comes from.
  final OldSchoolTune tune;

  /// The first item is the film's own trailer, played before the film
  /// (PLAN_SHA_46).
  final bool startsInPreRoll;

  /// Open with the guide showing and the video in its corner window, not
  /// full screen: the channel Old School resumes on start-up (Adrian,
  /// 2026-10-20, local/plans/old-school-open-on-guide.md). A pick goes full
  /// screen.
  final bool startInGuide;

  const OldSchoolSessionArgs({
    required this.controller,
    required this.tune,
    this.startsInPreRoll = false,
    this.startInGuide = false,
  });
}

/// What covers the picture during a standby gap
/// (local/plans/old-school-standby-card.md).
enum OldSchoolStandbyLayer {
  /// Nothing: no gap, or the filler video is playing.
  none,

  /// The filler picture, full screen on black.
  image,

  /// The plain "Back soon" card on black: no filler set, or it would not
  /// show.
  card,
}

/// The player's Old School state.
class OldSchoolPlayerState {
  /// Video full screen (true) or in the guide's corner window (false).
  bool fullScreen = true;

  /// When "Press Back again to leave" was shown; a second Back before
  /// [backAgainWindow] has passed leaves.
  DateTime? backNoteShownAt;
  Timer? backNoteTimer;

  /// Waits out an off-the-air gap, then tunes again.
  Timer? standbyTimer;

  /// The standby gap on the tuned channel while it lasts; null otherwise.
  OldSchoolTune? standbyTune;

  /// The gap's filler video is the open file; it loops until the gap ends.
  bool fillerVideoOpen = false;

  /// The filler would not open or play: the plain card shows instead.
  bool fillerFailed = false;

  /// The tune whose entry is playing (or held on, waiting for its slot to
  /// end).
  OldSchoolTune? slotTune;

  /// The film's own trailer is playing, ahead of the film in the same slot
  /// (PLAN_SHA_46). When it ends the film follows without a re-tune.
  bool playingPreRoll = false;

  /// Start over on a slot with a pre-roll: the film follows its trailer
  /// from 0, not at the live point.
  bool filmFromStart = false;

  /// "Match source" is on for this entry on [matchSourceChannelId]
  /// (local/plans/old-school-match-source.md): the display follows its
  /// resolution and frame rate until another entry plays.
  OldSchoolEntry? matchSourceEntry;
  String? matchSourceChannelId;

  /// A Match source switch, on or off, is under way.
  bool matchSourceBusy = false;

  /// The "Now playing" card for a programme that just started at its
  /// beginning: a TV episode, or a film with no trailer of its own
  /// (local/plans/old-school-episode-banner.md). Shows until [startCardUntil].
  OldSchoolEntry? startCardEntry;
  DateTime? startCardUntil;
  Timer? startCardTimer;

  /// A tune is in flight (channel change, carry-on or Back to live).
  bool tuning = false;
  int tuneGeneration = 0;

  static const backAgainWindow = Duration(seconds: 3);

  /// During a standby gap, how often the channel is asked again: PlezyFin
  /// may move the next programme up to 2 minutes earlier when it refills a
  /// break.
  static const standbyRecheck = Duration(seconds: 60);

  /// A gap shorter than this (the leftover after a break's trailers) is
  /// waited out on the last picture, with no filler or card.
  static const standbyShortGap = Duration(seconds: 5);

  /// When to tune again during [tune]'s standby gap: a second after the next
  /// entry starts, or after [standbyRecheck], whichever comes first.
  static Duration standbyWait(OldSchoolTune tune, DateTime deviceNow) {
    final next = tune.next;
    if (next == null) return standbyRecheck;
    final untilNext = next.start.difference(tune.serverNow(deviceNow)) + const Duration(seconds: 1);
    if (untilNext.isNegative) return Duration.zero;
    return untilNext < standbyRecheck ? untilNext : standbyRecheck;
  }

  /// What covers the picture now.
  OldSchoolStandbyLayer get standbyLayer {
    final entry = standbyTune?.now;
    if (entry == null) return OldSchoolStandbyLayer.none;
    if (!entry.hasFiller || fillerFailed) return OldSchoolStandbyLayer.card;
    return entry.fillerKind == OldSchoolFillerKind.image ? OldSchoolStandbyLayer.image : OldSchoolStandbyLayer.none;
  }

  /// How long the "Now playing" card shows (Adrian, 2026-10-18), and how far
  /// into its slot a programme may be and still count as starting.
  static const startCardTime = Duration(seconds: 5);
  static const startCardWindow = Duration(seconds: 15);

  /// The entry the "Now playing" card shows now, or null.
  OldSchoolEntry? get startCardShowing {
    final until = startCardUntil;
    return until != null && DateTime.now().isBefore(until) ? startCardEntry : null;
  }

  bool get backNoteVisible {
    final shown = backNoteShownAt;
    return shown != null && DateTime.now().difference(shown) < backAgainWindow;
  }

  void dispose() {
    backNoteTimer?.cancel();
    startCardTimer?.cancel();
    standbyTimer?.cancel();
  }
}
