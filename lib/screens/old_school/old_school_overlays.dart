import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../services/image_cache_service.dart';
import '../../utils/platform_detector.dart';
import '../../utils/dev_log_file.dart';
import '../../utils/formatters.dart';
import '../../widgets/video_controls/old_school_controls.dart';
import 'old_school_controller.dart';

Widget _logo(OldSchoolController controller, OldSchoolChannel channel, double width, double dpr) {
  return Image(
    image: CachedNetworkImageProvider(
      controller.client.oldSchoolLogoUrl(channel, width: (width * dpr).round()),
      cacheManager: PlexImageCacheManager.instance,
    ),
    width: width,
    fit: BoxFit.contain,
    errorBuilder: (_, _, _) => SizedBox(width: width),
  );
}

/// The channel's logo, faint in the bottom-right corner of the full-screen
/// picture like a real channel's: about 35% opacity, about 6% of the
/// picture's width (about 230 px on 4K).
class OldSchoolWatermark extends StatelessWidget {
  final OldSchoolController controller;
  final OldSchoolChannel channel;

  const OldSchoolWatermark({super.key, required this.controller, required this.channel});

  @override
  Widget build(BuildContext context) {
    if (channel.logoTag == null) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    final width = size.width * 0.06;
    return Positioned(
      right: size.width * 0.03,
      bottom: size.height * 0.05,
      child: IgnorePointer(
        child: Opacity(opacity: 0.35, child: _logo(controller, channel, width, MediaQuery.devicePixelRatioOf(context))),
      ),
    );
  }
}

/// About 3 seconds after tuning or channel up/down: logo, number, name,
/// what's on and time left.
class OldSchoolChannelCard extends StatelessWidget {
  final OldSchoolController controller;
  final OldSchoolChannel channel;
  final OldSchoolEntry? entry;

  const OldSchoolChannelCard({super.key, required this.controller, required this.channel, this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final entry = this.entry;
    final left = entry?.end.difference(controller.serverNow);
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final logoWidth = (240 / dpr).clamp(80.0, 160.0);
    return Positioned(
      left: size.width * 0.04,
      bottom: size.height * 0.08,
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: size.width * 0.6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisSize: .min,
                children: [
                  if (channel.logoTag != null) ...[
                    _logo(controller, channel, logoWidth, dpr),
                    const SizedBox(width: 16),
                  ],
                  Text(
                    '${channel.number}',
                    style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: .w800),
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: .start,
                      children: [
                        Text(
                          channel.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: const Color(0xFFF5B400),
                            fontWeight: .w800,
                          ),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                        if (entry != null)
                          Text(
                            entry.isProgramme ? entry.title : t.oldSchool.upNext,
                            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: .w700),
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                        if (entry != null)
                          Text(
                            [
                              if (entry.kind == OldSchoolEntryKind.musicVideo)
                                t.oldSchool.musicVideo
                              else if (entry.isProgramme && entry.subtitle.isNotEmpty)
                                entry.subtitle,
                              '${formatClockTime(entry.start.toLocal(), is24Hour: is24)} – ${formatClockTime(entry.end.toLocal(), is24Hour: is24)}',
                              if (left != null && !left.isNegative)
                                t.oldSchool.minutesLeft(minutes: '${left.inMinutes + 1}'),
                            ].join(' · '),
                            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Press Back again to leave", bottom centre.
class OldSchoolBackNote extends StatelessWidget {
  const OldSchoolBackNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.sizeOf(context).height * 0.06,
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(t.oldSchool.pressBackAgain, style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}

/// How long before a trailer's end its corner block shows by itself
/// (PLAN_SHA_43 default).
const oldSchoolPromoLead = Duration(seconds: 15);

/// The break trailer on the tuned channel now when it points at a film,
/// show or course (it has a promo); null otherwise.
OldSchoolEntry? oldSchoolPromoTrailer(OldSchoolController controller) {
  final channelId = controller.tunedChannelId;
  if (channelId == null) return null;
  final now = controller.serverNow;
  for (final entry in controller.entriesFor(channelId)) {
    if (!entry.isOnAt(now)) continue;
    return entry.kind == OldSchoolEntryKind.trailer && entry.promo != null ? entry : null;
  }
  return null;
}

/// [oldSchoolPromoTrailer] in its last [oldSchoolPromoLead], when its corner
/// block shows with the controls down. Null otherwise.
OldSchoolEntry? oldSchoolActivePromo(OldSchoolController controller) {
  final entry = oldSchoolPromoTrailer(controller);
  if (entry == null || entry.end.difference(controller.serverNow) > oldSchoolPromoLead) return null;
  return entry;
}

/// Whether OK (or a click) on [entry]'s corner block opens its item: a film,
/// show or course you have. Coming soon is never pressable (PLAN_SHA_47
/// Amendment 4).
bool oldSchoolPromoOpens(OldSchoolEntry entry) => entry.promo != OldSchoolPromo.coming && entry.promoItemId != null;

/// The promo item's name: the film, show or course, never the trailer file.
String _promoTitle(OldSchoolEntry entry) =>
    entry.promoName ?? ((entry.seriesName?.isNotEmpty ?? false) ? entry.seriesName! : entry.name);

/// The header over [entry]'s trailer: its item's name and "Trailer · 2011 ·
/// PG-13" (the promo item's year and rating; the entry's own belong to the
/// trailer file), or "Trailer · coming soon".
OldSchoolTrailerTitle oldSchoolTrailerTitle(OldSchoolEntry entry) {
  final parts = <String>[t.oldSchool.trailer];
  if (entry.promo == OldSchoolPromo.coming) {
    parts.add(t.oldSchool.trailerComingSoon);
  } else {
    if (entry.promoYear != null) parts.add('${entry.promoYear}');
    if (entry.promoRating?.isNotEmpty ?? false) parts.add(entry.promoRating!);
  }
  return OldSchoolTrailerTitle(title: _promoTitle(entry), line: parts.join(' · '));
}

/// "2 h 7 min", or "47 min" under an hour.
String oldSchoolRunLength(Duration length) {
  final minutes = length.inMinutes % 60;
  return length.inHours == 0
      ? t.oldSchool.runMinutes(minutes: '$minutes')
      : t.oldSchool.runHoursMinutes(hours: '${length.inHours}', minutes: '$minutes');
}

// The corner look agreed with Adrian on 2026-10-14 (local/plans/
// trailer-overlays.md): a square band flush to a screen edge with a 45-degree
// slant on its inner end, solid from the right edge to half its width, then
// fading to nothing at the tip; a square poster drawn over it, breaking out.
// Sizes are in units of a 960-wide screen (a 1080p TV) and grow with it.
const _amber = Color(0xFFF5B400);
const _bandColour = Color(0xF00E0F12); // the app's dark surface at 94%
const _unit = Duration(milliseconds: 120); // one step of the entrance

/// Slides of the entrance ease out like the mock-up's cubic-bezier(.2,.7,.2,1).
const _slideCurve = Cubic(0.2, 0.7, 0.2, 1);

class _CornerBand extends StatelessWidget {
  /// Sits on the top edge with its slant wider at the top; else on the bottom
  /// edge, wider at the bottom.
  final bool onTop;

  const _CornerBand({required this.onTop});

  @override
  Widget build(BuildContext context) =>
      DevLogFile.flag('noband') ? const SizedBox.expand() : CustomPaint(painter: _CornerBandPainter(onTop: onTop));
}

class _CornerBandPainter extends CustomPainter {
  final bool onTop;

  const _CornerBandPainter({required this.onTop});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final slant = h < w ? h : w;
    final path = Path();
    if (onTop) {
      path
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(slant, h);
    } else {
      path
        ..moveTo(slant, 0)
        ..lineTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(0, h);
    }
    path.close();
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerRight,
        end: Alignment.centerLeft,
        colors: [_bandColour, _bandColour, _bandColour.withValues(alpha: 0)],
        stops: const [0, 0.5, 1],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerBandPainter oldDelegate) => oldDelegate.onTop != onTop;
}

enum _Part { band, text, poster }

/// Lays the band, the text and the poster out over the whole screen: the
/// text against the right edge (beside the poster), the band as tall as the
/// text and flush to its edge, the poster breaking out of the band.
class _CornerLayout extends MultiChildLayoutDelegate {
  final bool onTop;
  final double scale;
  final bool hasPoster;

  _CornerLayout({required this.onTop, required this.scale, required this.hasPoster});

  static const posterHeight = 144.0;
  static const posterWidth = posterHeight * 2 / 3;

  @override
  void performLayout(Size size) {
    final s = scale;
    final panel = size.width * 0.66;
    final right = 24 * s + (hasPoster ? posterWidth * s + 16 * s : 0);
    final text = layoutChild(_Part.text, BoxConstraints(maxWidth: panel - right));
    final bandHeight = text.height;
    final bandWidth = panel * 0.78;
    layoutChild(_Part.band, BoxConstraints.tight(Size(bandWidth, bandHeight)));
    positionChild(_Part.band, Offset(size.width - bandWidth, onTop ? 0 : size.height - bandHeight));
    positionChild(_Part.text, Offset(size.width - right - text.width, onTop ? 0 : size.height - text.height));
    if (hasPoster) {
      final ph = posterHeight * s;
      layoutChild(_Part.poster, BoxConstraints.tight(Size(posterWidth * s, ph)));
      // On top: 22 down. At the bottom: its top 17 above the band's, never
      // closer than 22 to the bottom edge.
      final bottomGap = math.max(22 * s, bandHeight + 17 * s - ph);
      final top = onTop ? 22 * s : size.height - ph - bottomGap;
      positionChild(_Part.poster, Offset(size.width - 24 * s - posterWidth * s, top));
    }
  }

  @override
  bool shouldRelayout(_CornerLayout oldDelegate) =>
      oldDelegate.onTop != onTop || oldDelegate.scale != scale || oldDelegate.hasPoster != hasPoster;
}

/// A ClipRect, which a test build can switch off (dev-flags `noclip`).
class _DevClip extends StatelessWidget {
  final Widget child;

  const _DevClip({required this.child});

  @override
  Widget build(BuildContext context) => DevLogFile.flag('noclip') ? child : ClipRect(child: child);
}

/// The overlays' base text: the app's body font, whatever page they sit on.
Widget _textBase(BuildContext context, Widget child) => DefaultTextStyle(
  style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(decoration: TextDecoration.none),
  child: child,
);

/// One step of the entrance: [from]-[to] in units of [_unit] out of [total].
Animation<double> _step(Animation<double> parent, int from, int to, int total, Curve curve) => CurvedAnimation(
  parent: parent,
  curve: Interval(from / total, to / total, curve: curve),
);

/// Fades in over its step.
Widget _fadeStep(Animation<double> a, Widget child) => FadeTransition(opacity: a, child: child);

/// Slides in from 24 to the right, fading, over its step.
Widget _riseStep(Animation<double> a, double scale, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => Opacity(
    opacity: a.value.clamp(0.0, 1.0),
    child: Transform.translate(offset: Offset((1 - a.value) * 24 * scale, 0), child: child),
  ),
  child: child,
);

/// Slides in from beyond the right edge over its step: [distance] is how far
/// off it starts.
Widget _slideStep(Animation<double> a, double distance, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => Transform.translate(offset: Offset((1 - a.value) * distance, 0), child: child),
  child: child,
);

/// Slides in from its own width to the right over its step.
Widget _bandStep(Animation<double> a, Widget child) => AnimatedBuilder(
  animation: a,
  builder: (context, child) => FractionalTranslation(translation: Offset(1 - a.value, 0), child: child),
  child: child,
);

Widget _poster(OldSchoolController controller, String itemId, String tag, double scale, double dpr) {
  if (DevLogFile.flag('noposter')) return const SizedBox.expand();
  return Image(
    image: CachedNetworkImageProvider(
      controller.client.thumbnailUrl(
        '/Items/${Uri.encodeComponent(itemId)}/Images/Primary?tag=${Uri.encodeQueryComponent(tag)}',
        width: (_CornerLayout.posterWidth * scale * dpr).round(),
        height: (_CornerLayout.posterHeight * scale * dpr).round(),
      ),
      cacheManager: PlexImageCacheManager.instance,
    ),
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
}

/// The top-right block over a break trailer for a film, show or course
/// (PlezyFin PLAN_SHA_47): "Watch it now · Films › Real Steel · Also on … ·
/// Press OK to open it · Ends at 5:23 PM", with the item's poster. Shows
/// with the controls for the whole trailer, and by itself for its last
/// [oldSchoolPromoLead], arriving step by step. OK (or a click) opens a film,
/// show or course you have; coming soon is not pressable.
class OldSchoolPromoCorner extends StatefulWidget {
  final OldSchoolController controller;
  final bool controlsVisible;
  final ValueChanged<OldSchoolEntry>? onOpen;

  const OldSchoolPromoCorner({super.key, required this.controller, required this.controlsVisible, this.onOpen});

  @override
  State<OldSchoolPromoCorner> createState() => _OldSchoolPromoCornerState();
}

class _OldSchoolPromoCornerState extends State<OldSchoolPromoCorner> with SingleTickerProviderStateMixin {
  static const _steps = 20;
  late final AnimationController _entrance = AnimationController(vsync: this, duration: _unit * _steps, value: 1);
  Timer? _tick;

  /// The trailer whose block shows, or showed last (kept while it fades out).
  OldSchoolEntry? _entry;
  bool _visible = false;
  int? _minute;

  @override
  void initState() {
    super.initState();
    _update(initial: true);
    // The guide's clock decides when it shows, so a late tune-in or a
    // channel change lands right; checked twice a second.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _update());
  }

  @override
  void didUpdateWidget(OldSchoolPromoCorner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controlsVisible != widget.controlsVisible) _update();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  void _update({bool initial = false}) {
    if (!mounted) return;
    final entry = oldSchoolPromoTrailer(widget.controller);
    final lead = entry != null && entry.end.difference(widget.controller.serverNow) <= oldSchoolPromoLead;
    final visible = entry != null && (widget.controlsVisible || lead);
    // "Ends at" counts from now, so it moves on with the clock.
    final minute = DateTime.now().minute;
    // A guide refresh brings new objects for the same trailer.
    final sameEntry = entry == null || (entry.start == _entry?.start && entry.itemId == _entry?.itemId);
    if (visible == _visible && sameEntry && minute == _minute) return;
    final arriving = visible && (!_visible || !sameEntry);
    void apply() {
      _visible = visible;
      if (entry != null) _entry = entry;
      _minute = minute;
    }

    if (initial) {
      apply();
    } else {
      setState(apply);
    }
    if (arriving) {
      // With the controls down it arrives step by step; with them up it
      // comes in with them.
      if (widget.controlsVisible) {
        _entrance.value = 1;
      } else {
        unawaited(_entrance.forward(from: 0));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    // Idle: an empty box that still fills its space. A 0x0 box as an
    // un-positioned child shrinks a loose Stack to nothing and clips its
    // siblings (the player page lost every control, 2026-10-14).
    if (entry == null || DevLogFile.flag('nocorner')) return const SizedBox.expand();
    final canOpen = _visible && oldSchoolPromoOpens(entry) && widget.onOpen != null;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !canOpen,
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          // Comes and goes with the controls; the entrance does its own
          // arriving.
          duration: const Duration(milliseconds: 250),
          child: _block(context, entry, canOpen),
        ),
      ),
    );
  }

  Widget _block(BuildContext context, OldSchoolEntry entry, bool canOpen) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final s = size.width / 960;
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final title = _promoTitle(entry);
    final series = entry.promoItemType?.toLowerCase() == 'series';
    final date = entry.promoDate == null ? null : DateFormat('EEE d MMM').format(entry.promoDate!);
    final where = entry.promoLibrary == null
        ? title
        : t.oldSchool.promoWhere(library: entry.promoLibrary!, title: title);
    final (String headline, String? line) = switch (entry.promo!) {
      OldSchoolPromo.coming => (
        series ? t.oldSchool.promoNewSeries : t.oldSchool.promoComingSoon,
        date == null ? null : (series ? t.oldSchool.promoStarts(date: date) : t.oldSchool.promoArrives(date: date)),
      ),
      OldSchoolPromo.have => (series ? t.oldSchool.promoSeeShow : t.oldSchool.promoWatchNow, where),
      OldSchoolPromo.course => (t.oldSchool.promoWatchCourse, where),
    };
    final film = entry.promo == OldSchoolPromo.have && !series;
    final onAir = film ? entry.promoOnAir : null;
    final onAirLine = onAir == null
        ? null
        : t.oldSchool.promoAlsoOn(
            number: onAir.channelNumber,
            name: onAir.channelName,
            time:
                '${DateFormat('EEE').format(onAir.start.toLocal())} ${formatClockTime(onAir.start.toLocal(), is24Hour: is24)}',
          );
    // A film you have ends its full length from now, even if half-watched.
    final runTime = film ? entry.promoRunTime : null;
    final endsLine = runTime == null
        ? null
        : t.oldSchool.endsAt(time: formatClockTime(DateTime.now().add(runTime), is24Hour: is24));
    final opens = oldSchoolPromoOpens(entry);
    final hasPoster = entry.promoItemId != null && entry.promoImageTag != null;

    final a = _entrance;
    const n = _steps;
    final small = TextStyle(color: Colors.white70, fontSize: 14 * s, height: 1.25);
    final text = Padding(
      padding: EdgeInsets.fromLTRB(56 * s, 26 * s, 0, 10 * s),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .end,
        children: [
          _riseStep(
            _step(a, 4, 9, n, _slideCurve),
            s,
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .end,
              children: [
                Text(
                  headline,
                  textAlign: .right,
                  style: TextStyle(color: _amber, fontSize: 22 * s, fontWeight: .w800, height: 1.15),
                ),
                if (line != null)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * s),
                    child: Text(
                      line,
                      textAlign: .right,
                      style: TextStyle(color: Colors.white, fontSize: 19 * s, fontWeight: .w700, height: 1.2),
                    ),
                  ),
              ],
            ),
          ),
          if (onAirLine != null)
            _fadeStep(
              _step(a, 10, 14, n, Curves.ease),
              Padding(
                padding: EdgeInsets.only(top: 2 * s),
                child: Text(onAirLine, textAlign: .right, style: small),
              ),
            ),
          if (opens && PlatformDetector.isTV())
            _fadeStep(
              _step(a, 13, 17, n, Curves.ease),
              Padding(
                padding: EdgeInsets.only(top: 6 * s),
                child: Text(t.oldSchool.promoOpenHint, textAlign: .right, style: small),
              ),
            ),
          if (endsLine != null)
            _fadeStep(
              _step(a, 16, 20, n, Curves.ease),
              Padding(
                padding: EdgeInsets.only(top: 2 * s),
                child: Text(endsLine, textAlign: .right, style: small),
              ),
            ),
        ],
      ),
    );
    final layout = CustomMultiChildLayout(
      delegate: _CornerLayout(onTop: true, scale: s, hasPoster: hasPoster),
      children: [
        LayoutId(id: _Part.band, child: _bandStep(_step(a, 0, 5, n, _slideCurve), const _CornerBand(onTop: true))),
        LayoutId(id: _Part.text, child: text),
        if (hasPoster)
          LayoutId(
            id: _Part.poster,
            child: _slideStep(
              _step(a, 9, 14, n, _slideCurve),
              (_CornerLayout.posterWidth + 24 + 40) * s,
              _PulseGlow(
                active: canOpen,
                scale: s,
                child: _poster(widget.controller, entry.promoItemId!, entry.promoImageTag!, s, dpr),
              ),
            ),
          ),
      ],
    );
    return KeyedSubtree(
      key: ValueKey(entry.start),
      child: _textBase(
        context,
        _DevClip(
          child: canOpen
              ? GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: () => widget.onOpen!(entry),
                  child: layout,
                )
              : layout,
        ),
      ),
    );
  }
}

/// A slow amber glow pulsing round [child] while [active], so a poster
/// that OK (or a click) opens reads as pressable (Adrian, 2026-10-14).
class _PulseGlow extends StatefulWidget {
  final bool active;
  final double scale;
  final Widget child;

  const _PulseGlow({required this.active, required this.scale, required this.child});

  @override
  State<_PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<_PulseGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_PulseGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  void _sync() {
    if (widget.active) {
      unawaited(_pulse.repeat(reverse: true));
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final s = widget.scale;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_pulse.value);
        // The glow sits behind the poster, the edge on top of it.
        return DecoratedBox(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: _amber.withValues(alpha: 0.25 + 0.45 * t),
                blurRadius: (10 + 14 * t) * s,
                spreadRadius: (1 + 3 * t) * s,
              ),
            ],
          ),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(
                color: _amber.withValues(alpha: 0.55 + 0.45 * t),
                width: 2.5 * s,
              ),
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Over a film's own trailer (PlezyFin PLAN_SHA_46/47): a band on the
/// bottom-right edge with "Up next", the film's name (wrapping, in full),
/// "2003 · PG-13 · 3 h 21 min · Ends at 6:34 PM" and an amber "Starts in
/// 1:22" counting down to the film, its poster breaking out above, and the
/// channel's logo in the top-right corner instead of the watermark. Shows
/// for the whole trailer and arrives step by step (PLAN_SHA_47 Amendment
/// 6); nothing else shows meanwhile (the player keeps its controls down).
class OldSchoolPreRollCard extends StatefulWidget {
  final OldSchoolController controller;
  final OldSchoolChannel channel;

  /// The film whose trailer is playing; null hides the card.
  final OldSchoolEntry? film;

  /// How much of the trailer is left; null when unknown.
  final Duration? Function() trailerLeft;

  const OldSchoolPreRollCard({
    super.key,
    required this.controller,
    required this.channel,
    required this.film,
    required this.trailerLeft,
  });

  @override
  State<OldSchoolPreRollCard> createState() => _OldSchoolPreRollCardState();
}

class _OldSchoolPreRollCardState extends State<OldSchoolPreRollCard> with SingleTickerProviderStateMixin {
  static const _steps = 17;
  late final AnimationController _entrance = AnimationController(vsync: this, duration: _unit * _steps);
  Timer? _tick;

  /// The film shown, or shown last (kept while the card fades out).
  OldSchoolEntry? _film;

  @override
  void initState() {
    super.initState();
    _film = widget.film;
    if (_film != null) unawaited(_entrance.forward(from: 0));
    // The countdown ticks every second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.film != null) setState(() {});
    });
  }

  @override
  void didUpdateWidget(OldSchoolPreRollCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final film = widget.film;
    if (film == null || identical(film, _film)) return;
    final arriving = oldWidget.film == null || film.start != _film?.start || film.itemId != _film?.itemId;
    _film = film;
    if (arriving) unawaited(_entrance.forward(from: 0));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final film = _film;
    // Idle: fills its space, never a 0x0 box (see OldSchoolPromoCorner).
    if (film == null || DevLogFile.flag('nopreroll')) return const SizedBox.expand();
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: widget.film == null ? 0 : 1,
          duration: const Duration(milliseconds: 350),
          child: _card(context, film),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, OldSchoolEntry film) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final s = size.width / 960;
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final left = widget.trailerLeft() ?? Duration.zero;
    final leftSeconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).round();
    final countdown = '${leftSeconds ~/ 60}:${(leftSeconds % 60).toString().padLeft(2, '0')}';
    final runTime = film.runTime;
    // The film starts when its trailer ends.
    final ends = runTime == null ? null : DateTime.now().add(Duration(seconds: leftSeconds)).add(runTime);
    final details = [
      if (film.year != null) '${film.year}',
      if (film.rating?.isNotEmpty ?? false) film.rating!,
      if (runTime != null) oldSchoolRunLength(runTime),
      if (ends != null) t.oldSchool.endsAt(time: formatClockTime(ends, is24Hour: is24)),
    ].join(' · ');
    final poster = film.poster;

    final a = _entrance;
    const n = _steps;
    final headline = TextStyle(color: _amber, fontSize: 22 * s, fontWeight: .w800, height: 1.15);
    final text = Padding(
      // The band's top edge sits a fixed 7 above "Up next", so a long name
      // makes it taller with the same gap.
      padding: EdgeInsets.fromLTRB(56 * s, 7 * s, 0, 16 * s),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .end,
        children: [
          _riseStep(
            _step(a, 4, 9, n, _slideCurve),
            s,
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .end,
              children: [
                Text(t.oldSchool.upNext, textAlign: .right, style: headline),
                Padding(
                  padding: EdgeInsets.only(top: 2 * s),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 300 * s),
                    child: Text(
                      film.title,
                      textAlign: .right,
                      style: TextStyle(color: Colors.white, fontSize: 19 * s, fontWeight: .w700, height: 1.2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (details.isNotEmpty)
            _fadeStep(
              _step(a, 10, 14, n, Curves.ease),
              Padding(
                padding: EdgeInsets.only(top: 6 * s),
                child: Text(
                  details,
                  textAlign: .right,
                  style: TextStyle(color: Colors.white70, fontSize: 14 * s, height: 1.25),
                ),
              ),
            ),
          _fadeStep(
            _step(a, 13, 17, n, Curves.ease),
            Padding(
              padding: EdgeInsets.only(top: 6 * s),
              child: Text(
                t.oldSchool.startsIn(time: countdown),
                textAlign: .right,
                style: headline.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
        ],
      ),
    );
    final logoHeight = 54 * s;
    return _textBase(
      context,
      _DevClip(
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomMultiChildLayout(
                delegate: _CornerLayout(onTop: false, scale: s, hasPoster: poster != null),
                children: [
                  LayoutId(
                    id: _Part.band,
                    child: _bandStep(_step(a, 0, 5, n, _slideCurve), const _CornerBand(onTop: false)),
                  ),
                  LayoutId(id: _Part.text, child: text),
                  if (poster != null)
                    LayoutId(
                      id: _Part.poster,
                      child: _slideStep(
                        _step(a, 9, 14, n, _slideCurve),
                        (_CornerLayout.posterWidth + 24 + 40) * s,
                        _poster(widget.controller, poster.itemId, poster.tag, s, dpr),
                      ),
                    ),
                ],
              ),
            ),
            // The channel's logo, top right, at full strength; it stands in for
            // the watermark, which the band covers. Fades in with the band.
            if (widget.channel.logoTag != null)
              Positioned(
                top: size.height * 0.04,
                right: size.width * 0.025,
                height: logoHeight,
                child: _fadeStep(
                  _step(a, 0, 5, n, Curves.ease),
                  Image(
                    image: CachedNetworkImageProvider(
                      widget.controller.client.oldSchoolLogoUrl(widget.channel, width: (logoHeight * 2 * dpr).round()),
                      cacheManager: PlexImageCacheManager.instance,
                    ),
                    height: logoHeight,
                    fit: BoxFit.contain,
                    alignment: Alignment.topRight,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
