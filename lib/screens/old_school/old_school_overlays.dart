import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/old_school.dart';
import '../../services/image_cache_service.dart';
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
