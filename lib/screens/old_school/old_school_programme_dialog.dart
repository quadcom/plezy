import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_rating.dart';
import '../../media/media_role.dart';
import '../../models/old_school.dart';
import '../../services/image_cache_service.dart';
import '../../services/old_school_reminders.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/corner_band.dart';
import '../../widgets/media_rating_badge.dart';
import 'old_school_controller.dart';
import 'old_school_overlays.dart';

/// The details of a programme that starts later, picked in the Old School
/// guide (local/plans/old-school-future-details.md): its backdrop across the
/// top with the poster breaking out of it, then when and where it airs, the
/// facts, genres, scores, overview and people, and a Remind me checkbox. In
/// the Old School overlay style: square corners, dark, amber labels.
///
/// The guide entry carries the pictures, times and year/rating/length; one
/// item call when it opens adds genres, people, scores and watched.
Future<void> showOldSchoolProgrammeDialog(
  BuildContext context, {
  required OldSchoolController controller,
  required OldSchoolChannel channel,
  required OldSchoolEntry entry,
  required String title,
  required String timeLine,
  String? detail,
  OldSchoolReminderService? reminders,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => OldSchoolProgrammeDialog(
      controller: controller,
      channel: channel,
      entry: entry,
      title: title,
      timeLine: timeLine,
      detail: detail,
      reminders: reminders ?? OldSchoolReminderService.instance,
    ),
  );
}

class OldSchoolProgrammeDialog extends StatefulWidget {
  final OldSchoolController controller;
  final OldSchoolChannel channel;
  final OldSchoolEntry entry;
  final String title;
  final String timeLine;
  final String? detail;
  final OldSchoolReminderService reminders;

  const OldSchoolProgrammeDialog({
    super.key,
    required this.controller,
    required this.channel,
    required this.entry,
    required this.title,
    required this.timeLine,
    required this.reminders,
    this.detail,
  });

  @override
  State<OldSchoolProgrammeDialog> createState() => _OldSchoolProgrammeDialogState();
}

class _OldSchoolProgrammeDialogState extends State<OldSchoolProgrammeDialog> {
  MediaItem? _item;

  OldSchoolEntry get _entry => widget.entry;

  /// Remind me is offered for programmes with an item, on a server that
  /// keeps reminders.
  bool get _canRemind => widget.reminders.available && _entry.isProgramme && _entry.itemId != null;

  @override
  void initState() {
    super.initState();
    widget.reminders.addListener(_onRemindersChanged);
    final itemId = _entry.itemId;
    if (_entry.isProgramme && itemId != null) unawaited(_loadItem(itemId));
  }

  @override
  void dispose() {
    widget.reminders.removeListener(_onRemindersChanged);
    super.dispose();
  }

  void _onRemindersChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadItem(String itemId) async {
    try {
      final item = await widget.controller.client.fetchItem(itemId);
      if (mounted && item != null) setState(() => _item = item);
    } catch (e, st) {
      appLogger.w('Old School: programme details lookup failed', error: e, stackTrace: st);
    }
  }

  Future<void> _toggleReminder(bool on) async {
    final ok = await widget.reminders.setReminder(widget.channel.id, _entry, on: on);
    if (!ok && mounted) showErrorSnackBar(context, t.oldSchool.reminderFailed);
  }

  String? _imageUrl(OldSchoolImage? image, String type, int width) {
    if (image == null) return null;
    return widget.controller.client.thumbnailUrl(
      '/Items/${Uri.encodeComponent(image.itemId)}/Images/$type?tag=${Uri.encodeQueryComponent(image.tag)}',
      width: width,
    );
  }

  /// "TOMORROW · 4 · FILMS" for a day other than today; "4 · FILMS" today.
  String _label() {
    final start = _entry.start.toLocal();
    final now = widget.controller.serverNow.toLocal();
    // Calendar days as UTC dates: a local midnight-to-midnight span is 23 or
    // 25 hours on a clock-change day.
    final today = DateTime.utc(now.year, now.month, now.day);
    final day = DateTime.utc(start.year, start.month, start.day);
    final days = day.difference(today).inDays;
    final dayWord = switch (days) {
      0 => null,
      1 => t.oldSchool.tomorrow,
      _ => DateFormat.EEEE().format(start),
    };
    return [?dayWord, '${widget.channel.number}', widget.channel.name].join(' · ').toUpperCase();
  }

  /// Length, then genres, as one line: "2 h 16 min · Sci-Fi · Action".
  String _factsLine() {
    final runTime = _entry.runTime ?? _durationOf(_item);
    final genres = _item?.genres ?? const <String>[];
    return [if (runTime != null && runTime > Duration.zero) oldSchoolRunLength(runTime), ...genres.take(3)].join(' · ');
  }

  static Duration? _durationOf(MediaItem? item) {
    final ms = item?.durationMs;
    return ms == null ? null : Duration(milliseconds: ms);
  }

  String? _peopleLine() {
    final item = _item;
    if (item == null) return null;
    final directors = item.directors ?? const <String>[];
    final cast = [for (final role in item.roles ?? const <MediaRole>[]) role.tag].take(4).toList();
    final parts = [
      if (directors.isNotEmpty) t.oldSchool.directedBy(names: directors.take(2).join(', ')),
      if (cast.isNotEmpty) t.oldSchool.starring(names: cast.join(', ')),
    ];
    return parts.isEmpty ? null : parts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final theme = Theme.of(context);
    final tk = tokens(context);
    final narrow = size.width < 600;
    final width = narrow ? size.width - 32 : (size.width * 0.62).clamp(560.0, 900.0);
    final headerHeight = (width * (narrow ? 0.42 : 0.30)).roundToDouble();
    final posterWidth = narrow ? 96.0 : (width * 0.19).clamp(120.0, 180.0);
    final posterHeight = posterWidth * 1.5;
    final overlap = posterHeight * 0.45;
    final pad = narrow ? 16.0 : 24.0;

    final backdropUrl = _imageUrl(
      _entry.backdrop ?? _entry.thumb,
      _entry.backdrop != null ? 'Backdrop' : 'Thumb',
      (width * dpr).round(),
    );
    final posterUrl = _imageUrl(_entry.poster, 'Primary', (posterWidth * dpr).round());
    final reminder = widget.reminders.reminderFor(widget.channel.id, _entry);
    final busy = widget.reminders.isBusy(widget.channel.id, _entry);
    final facts = _factsLine();
    final people = _peopleLine();
    final item = _item;
    final ratings = item == null ? const <MediaRatingSource>[] : mediaRatingsFor(item);
    final watched = item != null && item.isWatched;
    final overview = widget.detail ?? '';

    final header = SizedBox(
      height: headerHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropUrl != null)
            Image(
              image: CachedNetworkImageProvider(backdropUrl, cacheManager: PlexImageCacheManager.instance),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tk.bg.withValues(alpha: 0.05), tk.bg.withValues(alpha: 0.35), tk.bg],
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
          if (widget.channel.logoTag != null)
            Positioned(
              top: pad * 0.6,
              right: pad * 0.6,
              height: narrow ? 28 : 40,
              child: Image(
                image: CachedNetworkImageProvider(
                  widget.controller.client.oldSchoolLogoUrl(widget.channel, width: ((narrow ? 56 : 80) * dpr).round()),
                  cacheManager: PlexImageCacheManager.instance,
                ),
                fit: BoxFit.contain,
                alignment: Alignment.topRight,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );

    final poster = posterUrl == null
        ? null
        : SizedBox(
            width: posterWidth,
            height: posterHeight - overlap,
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: posterHeight,
              maxHeight: posterHeight,
              child: Container(
                width: posterWidth,
                height: posterHeight,
                decoration: BoxDecoration(
                  color: tk.surface,
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 6))],
                ),
                child: Image(
                  image: CachedNetworkImageProvider(posterUrl, cacheManager: PlexImageCacheManager.instance),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          );

    final muted = theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted);
    final text = Column(
      mainAxisSize: .min,
      crossAxisAlignment: .start,
      children: [
        Text(
          _label(),
          style: theme.textTheme.labelLarge?.copyWith(color: cornerAmber, fontWeight: .w800, letterSpacing: 1.6),
          maxLines: 1,
          overflow: .ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          widget.title,
          style: (narrow ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall)?.copyWith(fontWeight: .w800),
          maxLines: 2,
          overflow: .ellipsis,
        ),
        const SizedBox(height: 4),
        Text(widget.timeLine, style: theme.textTheme.bodyLarge, maxLines: 2, overflow: .ellipsis),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(facts, style: muted, maxLines: 2, overflow: .ellipsis),
        ],
        if (ratings.isNotEmpty || watched) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (ratings.isNotEmpty) InlineRatingBadges(ratings: ratings),
              if (watched)
                Row(
                  mainAxisSize: .min,
                  children: [
                    AppIcon(Symbols.check_circle_rounded, fill: 1, size: 16, color: tk.textMuted),
                    const SizedBox(width: 4),
                    Text(t.oldSchool.watched, style: muted),
                  ],
                ),
            ],
          ),
        ],
      ],
    );

    final body = Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, 0),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          Row(
            crossAxisAlignment: .start,
            children: [
              if (poster != null) ...[poster, SizedBox(width: pad)],
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: poster != null ? pad * 0.5 : 0),
                  child: text,
                ),
              ),
            ],
          ),
          if (overview.isNotEmpty) ...[SizedBox(height: pad * 0.6), Text(overview, style: theme.textTheme.bodyMedium)],
          if (people != null) ...[SizedBox(height: pad * 0.5), Text(people, style: muted)],
        ],
      ),
    );

    final actions = Padding(
      padding: EdgeInsets.fromLTRB(pad, pad * 0.6, pad, pad * 0.75),
      child: Row(
        children: [
          if (_canRemind)
            OutlinedButton.icon(
              autofocus: true,
              style: OutlinedButton.styleFrom(shape: const RoundedRectangleBorder()),
              onPressed: busy ? null : () => unawaited(_toggleReminder(reminder == null)),
              icon: AppIcon(
                reminder != null ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded,
                fill: reminder != null ? 1 : 0,
                color: reminder != null ? cornerAmber : null,
              ),
              label: Text(t.oldSchool.remindMe),
            ),
          const Spacer(),
          TextButton(
            autofocus: !_canRemind,
            style: TextButton.styleFrom(shape: const RoundedRectangleBorder()),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.common.close),
          ),
        ],
      ),
    );

    return Dialog(
      backgroundColor: tk.bg,
      shape: const RoundedRectangleBorder(),
      clipBehavior: Clip.antiAlias,
      insetPadding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 40, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: size.height * 0.88),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: .min, crossAxisAlignment: .stretch, children: [header, body]),
              ),
            ),
            actions,
          ],
        ),
      ),
    );
  }
}
