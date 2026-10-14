import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../services/image_cache_service.dart';
import '../../utils/platform_detector.dart';
import '../../utils/formatters.dart';
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

/// How long before a trailer's end its banner shows (PLAN_SHA_43 default).
const oldSchoolPromoLead = Duration(seconds: 15);

/// The trailer on the tuned channel whose end banner shows now: one with a
/// promo, in its last [oldSchoolPromoLead]. Null otherwise.
OldSchoolEntry? oldSchoolActivePromo(OldSchoolController controller) {
  final channelId = controller.tunedChannelId;
  if (channelId == null) return null;
  final now = controller.serverNow;
  for (final entry in controller.entriesFor(channelId)) {
    if (!entry.isOnAt(now)) continue;
    final active =
        entry.kind == OldSchoolEntryKind.trailer &&
        entry.promo != null &&
        entry.end.difference(now) <= oldSchoolPromoLead;
    return active ? entry : null;
  }
  return null;
}

/// The banner in the top-right corner near a trailer's end (PlezyFin
/// PLAN_SHA_43, the web's default look until Adrian's design session):
/// "Coming soon · Arrives Thu 13 Nov", "Watch it now · Films › Title" or
/// "Watch the whole course". OK opens the item (handled by the player).
/// Sits below the controls' top bar while the controls show.
class OldSchoolPromoBanner extends StatefulWidget {
  final OldSchoolController controller;
  final bool controlsVisible;
  final ValueChanged<OldSchoolEntry>? onOpen;

  const OldSchoolPromoBanner({super.key, required this.controller, required this.controlsVisible, this.onOpen});

  @override
  State<OldSchoolPromoBanner> createState() => _OldSchoolPromoBannerState();
}

class _OldSchoolPromoBannerState extends State<OldSchoolPromoBanner> {
  Timer? _tick;
  OldSchoolEntry? _entry;

  @override
  void initState() {
    super.initState();
    _entry = oldSchoolActivePromo(widget.controller);
    // The guide's clock decides when it shows, so a late tune-in or a
    // channel change lands right; checked twice a second.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final entry = oldSchoolActivePromo(widget.controller);
      if (!identical(entry, _entry) && mounted) setState(() => _entry = entry);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final entry = _entry;
    return Positioned(
      right: size.width * 0.03,
      top: size.height * (widget.controlsVisible ? 0.16 : 0.05),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: entry == null ? const SizedBox.shrink() : _card(context, entry, size),
      ),
    );
  }

  Widget _card(BuildContext context, OldSchoolEntry entry, Size size) {
    final theme = Theme.of(context);
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final title = entry.promoName ?? ((entry.seriesName?.isNotEmpty ?? false) ? entry.seriesName! : entry.name);
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
      OldSchoolPromo.have => (t.oldSchool.promoWatchNow, where),
      OldSchoolPromo.course => (t.oldSchool.promoWholeCourse, where),
    };
    final onAir = entry.promo == OldSchoolPromo.have ? entry.promoOnAir : null;
    final onAirLine = onAir == null
        ? null
        : t.oldSchool.promoAlsoOn(
            number: onAir.channelNumber,
            name: onAir.channelName,
            time:
                '${DateFormat('EEE').format(onAir.start.toLocal())} ${formatClockTime(onAir.start.toLocal(), is24Hour: is24)}',
          );
    final canOpen = entry.promoItemId != null && widget.onOpen != null;
    final card = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: size.width * 0.34),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: [
              Text(
                headline,
                style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFFF5B400), fontWeight: .w800),
              ),
              if (line != null)
                Text(
                  line,
                  style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: .w700),
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
              if (onAirLine != null)
                Text(
                  onAirLine,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
              if (canOpen && PlatformDetector.isTV())
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    t.oldSchool.promoOpenHint,
                    style: theme.textTheme.labelMedium?.copyWith(color: Colors.white60),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: ValueKey(entry.start),
      child: canOpen ? GestureDetector(onTap: () => widget.onOpen!(entry), child: card) : IgnorePointer(child: card),
    );
  }
}
