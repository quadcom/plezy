import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../models/iptv.dart';
import '../../services/image_cache_service.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import 'iptv_controller.dart';
import 'iptv_guide_view.dart';

/// The buttons on the full-screen banner, left to right.
enum IptvBannerButton { channelDown, channelUp, last, guide }

/// The full-screen banner (PLAN_SHA_61a): logo, the big gold number, the
/// channel name, what's on with its times and what's next, and the buttons
/// channel down / up / Last / Guide. It fades after 5 s and comes back on a
/// mouse move or a key.
class IptvBanner extends StatelessWidget {
  final IptvController controller;
  final IptvChannel channel;

  /// The button the remote is on, or null (mouse and touch).
  final IptvBannerButton? focused;
  final ValueChanged<IptvBannerButton> onPressed;

  const IptvBanner({
    super.key,
    required this.controller,
    required this.channel,
    required this.focused,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final narrow = size.width < 700;
    // Sideways phones and small windows: the buttons get their own row.
    final medium = !narrow && size.width < 1100;
    final now = controller.programmeAt(channel.id);
    final next = controller.nextProgramme(channel.id);
    String clock(DateTime t) => formatClockTime(t.toLocal(), is24Hour: is24);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logoHeight = narrow ? 48.0 : (medium ? 56.0 : 72.0);
    final logoUrl = controller.client.iptvLogoUrl(channel, width: (logoHeight * 2.2 * dpr).round());
    final muted = Colors.white.withValues(alpha: 0.6);

    final identity = Row(
      mainAxisSize: .min,
      children: [
        if (logoUrl != null) ...[
          Container(
            height: logoHeight,
            width: logoHeight * 2.2,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image(
              image: CachedNetworkImageProvider(logoUrl, cacheManager: PlexImageCacheManager.instance),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(width: 20),
        ],
        Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(
              channel.numberLabel,
              style: (narrow ? theme.textTheme.headlineMedium : theme.textTheme.displaySmall)?.copyWith(
                color: iptvGold,
                fontWeight: .w800,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                channel.name.toUpperCase(),
                style: theme.textTheme.labelLarge?.copyWith(color: muted, fontWeight: .w800, letterSpacing: 1.5),
                maxLines: 1,
                overflow: .ellipsis,
              ),
            ),
          ],
        ),
      ],
    );

    final programme = Column(
      mainAxisSize: .min,
      crossAxisAlignment: .start,
      children: [
        Text(
          now?.title.isNotEmpty == true ? now!.title : channel.name,
          style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: .w800),
          maxLines: 1,
          overflow: .ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          now == null
              ? t.iptv.noListings
              : [if (now.kind != null) now.kind!, '${clock(now.start)} – ${clock(now.end)}'].join(' · '),
          style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          maxLines: 1,
          overflow: .ellipsis,
        ),
        if (next != null) ...[
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${t.iptv.nextAt(time: clock(next.start))} · ',
                  style: TextStyle(color: muted),
                ),
                TextSpan(
                  text: next.title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            style: theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: .ellipsis,
          ),
        ],
      ],
    );

    final buttons = Row(
      mainAxisSize: .min,
      children: [
        _BannerButton(
          icon: Symbols.keyboard_arrow_down_rounded,
          tooltip: t.iptv.channelDown,
          focused: focused == IptvBannerButton.channelDown,
          onTap: () => onPressed(IptvBannerButton.channelDown),
        ),
        const SizedBox(width: 10),
        _BannerButton(
          icon: Symbols.keyboard_arrow_up_rounded,
          tooltip: t.iptv.channelUp,
          focused: focused == IptvBannerButton.channelUp,
          onTap: () => onPressed(IptvBannerButton.channelUp),
        ),
        const SizedBox(width: 10),
        _BannerButton(
          icon: Symbols.history_rounded,
          label: t.iptv.last,
          focused: focused == IptvBannerButton.last,
          enabled: controller.lastChannel != null,
          onTap: () => onPressed(IptvBannerButton.last),
        ),
        const SizedBox(width: 10),
        _BannerButton(
          icon: Symbols.grid_view_rounded,
          label: t.iptv.guide,
          focused: focused == IptvBannerButton.guide,
          primary: true,
          onTap: () => onPressed(IptvBannerButton.guide),
        ),
      ],
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.85), Colors.black.withValues(alpha: 0)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left + (narrow ? 16 : (medium ? 28 : 48)),
            narrow || medium ? 40 : 64,
            padding.right + (narrow ? 16 : (medium ? 28 : 48)),
            padding.bottom + (narrow || medium ? 16 : 32),
          ),
          // Stacked in rows on an upright phone (PLAN_SHA_61a).
          child: narrow
              ? Column(
                  mainAxisSize: .min,
                  crossAxisAlignment: .start,
                  children: [identity, const SizedBox(height: 12), programme, const SizedBox(height: 16), buttons],
                )
              : medium
              ? Column(
                  mainAxisSize: .min,
                  crossAxisAlignment: .stretch,
                  children: [
                    Row(
                      crossAxisAlignment: .end,
                      children: [
                        identity,
                        const SizedBox(width: 24),
                        Expanded(child: programme),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Align(alignment: Alignment.centerRight, child: buttons),
                  ],
                )
              : Row(
                  crossAxisAlignment: .end,
                  children: [
                    identity,
                    const SizedBox(width: 28),
                    Expanded(child: programme),
                    const SizedBox(width: 24),
                    buttons,
                  ],
                ),
        ),
      ),
    );
  }
}

class _BannerButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool focused;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;

  const _BannerButton({
    required this.icon,
    this.label,
    this.tooltip,
    required this.focused,
    this.primary = false,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = primary ? Colors.black : Colors.white.withValues(alpha: enabled ? 0.9 : 0.35);
    final button = Material(
      color: primary ? Colors.white : Colors.white.withValues(alpha: 0.12),
      shape: StadiumBorder(side: focused ? BorderSide(color: theme.colorScheme.primary, width: 3) : BorderSide.none),
      child: InkWell(
        customBorder: const StadiumBorder(),
        canRequestFocus: false,
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: label == null ? 14 : 18, vertical: 12),
          child: Row(
            mainAxisSize: .min,
            children: [
              AppIcon(icon, size: 22, color: fg),
              if (label != null) ...[
                const SizedBox(width: 8),
                Text(
                  label!,
                  style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: .w700),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The red LIVE pill in the top left of the full-screen picture.
class IptvLiveBadge extends StatelessWidget {
  const IptvLiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Positioned(
      top: padding.top + 12,
      left: padding.left + 12,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xFFE53935), borderRadius: BorderRadius.circular(4)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              t.iptv.live,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: .w800, letterSpacing: 1.2),
            ),
          ),
        ),
      ),
    );
  }
}

/// "This channel isn't working right now. Try another channel." over the
/// whole picture, before the guide comes back.
class IptvDeadMessage extends StatelessWidget {
  const IptvDeadMessage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: .min,
            children: [
              const AppIcon(Symbols.signal_disconnected_rounded, color: iptvWarning, size: 56),
              const SizedBox(height: 16),
              Text(
                t.iptv.channelDead,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: .w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
