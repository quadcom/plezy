import 'dart:async';

import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_server_client.dart';
import '../../../mpv/mpv.dart';
import '../../../services/pip_service.dart';
import '../../../services/settings_service.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/formatters.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/corner_band.dart';
import '../../old_school/old_school_overlays.dart' show oldSchoolRunLength;
import '../../../widgets/optimized_media_image.dart';

/// Libraries whose items never get the corner, matched whole and ignoring
/// case: Adrian names his libraries (2026-10-15: "skip it on music videos
/// and YouTube videos").
const _skippedLibraries = {'youtube', 'music videos'};

/// Which playing items get the poster corner (local/plans/playback-corner.md):
/// films and episodes - Movies, TV and Master Class courses - but never on a
/// phone, and never from the YouTube or Music Videos libraries. A Jellyfin
/// item's playback details name no library, so its library is looked up
/// once (`/Items/{id}/Ancestors`); the corner waits for the answer, so a
/// YouTube video never flashes one.
class PlaybackCornerGate {
  final VoidCallback onChanged;

  PlaybackCornerGate({required this.onChanged});

  /// Library names found per item id; null when the lookup found none.
  final _libraries = <String, String?>{};
  final _pending = <String>{};

  bool shows(BuildContext context, MediaItem item) {
    if (PlatformDetector.isPhone(context)) return false;
    final isFilm = item.kind == MediaKind.movie && !item.usesWideAspectRatio(EpisodePosterMode.seasonPoster);
    if (!isFilm && item.kind != MediaKind.episode) return false;
    final String? library;
    if (item.libraryTitle != null) {
      library = item.libraryTitle;
    } else if (_libraries.containsKey(item.id)) {
      library = _libraries[item.id];
    } else {
      final client = context.tryGetMediaClientForServer(serverIdOrNull(item.serverId));
      // Offline with no library on the row: nothing to ask, so it shows.
      if (client == null) return true;
      _lookUp(client, item);
      return false;
    }
    return !_skippedLibraries.contains(library?.trim().toLowerCase());
  }

  /// Asks [client] for [item]'s library once; [onChanged] runs when the
  /// answer lands, never during the build that asked.
  void _lookUp(MediaServerClient client, MediaItem item) {
    if (!_pending.add(item.id)) return;
    // Future.sync: a client that throws at once must not throw into the
    // build that asked.
    unawaited(
      Future.sync(() => client.stampLibrary(item))
          .then((stamped) => stamped.libraryTitle)
          .catchError((Object e) {
            appLogger.d('Playback corner: library lookup failed for ${item.id}', error: e);
            return null;
          })
          .then((library) {
            _libraries[item.id] = library;
            _pending.remove(item.id);
            onChanged();
          }),
    );
  }
}

/// The top-right poster corner over a film or episode (local/plans/
/// playback-corner.md): the Old School corner band with the item's poster
/// (an episode's season poster, else its show's), its name, details, the
/// clock and when it ends. Each time the controls come up it arrives step by
/// step like Old School's break corner (Adrian, 2026-10-15); it fades out
/// with them. The header's clock and title stand down while it shows. Never
/// pressable.
class PlaybackCorner extends StatefulWidget {
  final MediaItem metadata;
  final Player player;
  final bool controlsVisible;

  const PlaybackCorner({super.key, required this.metadata, required this.player, required this.controlsVisible});

  @override
  State<PlaybackCorner> createState() => _PlaybackCornerState();
}

class _PlaybackCornerState extends State<PlaybackCorner> with SingleTickerProviderStateMixin {
  /// Band 0-5, name 4-9, poster 9-14, details 10-14, times 13-17, in steps of
  /// [cornerUnit]: Old School's break corner order.
  static const _steps = 17;
  late final AnimationController _entrance = AnimationController(vsync: this, duration: cornerUnit * _steps);
  Timer? _tick;

  /// The clock and "Ends at" lines as last shown; rebuilt only when either
  /// changes, checked every second while the block shows.
  String? _times;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PlaybackCorner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controlsVisible != widget.controlsVisible) _sync();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  void _sync() {
    _tick?.cancel();
    _tick = null;
    if (!widget.controlsVisible) return;
    unawaited(_entrance.forward(from: 0));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final times = _timesLine(context);
      if (times != _times) setState(() {});
    });
  }

  /// "9:12 PM · Ends at 9:40 PM": the clock, and now plus the time left at
  /// the playing speed.
  String _timesLine(BuildContext context) {
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final clock = formatClockTime(DateTime.now(), is24Hour: is24);
    final state = widget.player.state;
    final left = state.duration - state.position;
    if (state.duration <= Duration.zero || left.inSeconds <= 0) return clock;
    final ends = formatFinishTime(left, rate: state.rate, is24Hour: is24);
    return '$clock · ${t.oldSchool.endsAt(time: ends)}';
  }

  @override
  Widget build(BuildContext context) {
    // Idle it still fills its space: a 0x0 child shrinks a loose Stack to
    // nothing and clips its siblings (2026-10-14).
    return ValueListenableBuilder<bool>(
      valueListenable: PipService().isPipActive,
      builder: (context, inPip, _) => Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: widget.controlsVisible && !inPip ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: _block(context),
          ),
        ),
      ),
    );
  }

  Widget _block(BuildContext context) {
    final item = widget.metadata;
    final size = MediaQuery.sizeOf(context);
    final s = size.width / 960;
    final episode = item.kind == MediaKind.episode;
    final headline = episode ? (item.grandparentTitle ?? item.title ?? '') : (item.title ?? '');
    final episodeLine = episode ? _episodeLine(item) : null;
    final details = [
      if (!episode && item.year != null) '${item.year}',
      if (item.contentRating?.isNotEmpty ?? false) item.contentRating!,
      if ((item.durationMs ?? 0) >= 60000) oldSchoolRunLength(Duration(milliseconds: item.durationMs!)),
    ].join(' · ');
    final times = _times = _timesLine(context);
    final posterPath = item.posterThumb(mode: EpisodePosterMode.seasonPoster);
    final fallbackPath = item.posterThumbFallback(mode: EpisodePosterMode.seasonPoster);
    final hasPoster = posterPath != null;
    // On a tablet the controls' top row holds the audio and subtitle buttons,
    // so the block starts below it.
    final top = PlatformDetector.isMobile(context) ? MediaQuery.paddingOf(context).top + 80 : 0.0;

    final a = _entrance;
    const n = _steps;
    final small = TextStyle(color: Colors.white70, fontSize: 14 * s, height: 1.25);
    final text = Padding(
      padding: EdgeInsets.fromLTRB(56 * s, 26 * s, 0, 10 * s),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .end,
        children: [
          cornerRiseStep(
            cornerStep(a, 4, 9, n, cornerSlideCurve),
            s,
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .end,
              children: [
                Text(
                  headline,
                  textAlign: .right,
                  maxLines: 2,
                  overflow: .ellipsis,
                  style: TextStyle(color: cornerAmber, fontSize: 22 * s, fontWeight: .w800, height: 1.15),
                ),
                if (episodeLine != null)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * s),
                    child: Text(
                      episodeLine,
                      textAlign: .right,
                      maxLines: 2,
                      overflow: .ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: 19 * s, fontWeight: .w700, height: 1.2),
                    ),
                  ),
              ],
            ),
          ),
          if (details.isNotEmpty)
            cornerFadeStep(
              cornerStep(a, 10, 14, n, Curves.ease),
              Padding(
                padding: EdgeInsets.only(top: 2 * s),
                child: Text(details, textAlign: .right, style: small),
              ),
            ),
          cornerFadeStep(
            cornerStep(a, 13, 17, n, Curves.ease),
            Padding(
              padding: EdgeInsets.only(top: 6 * s),
              child: Text(times, textAlign: .right, style: small),
            ),
          ),
        ],
      ),
    );
    return cornerTextBase(
      context,
      CornerClip(
        child: CustomMultiChildLayout(
          delegate: CornerLayout(onTop: true, scale: s, hasPoster: hasPoster, top: top),
          children: [
            LayoutId(
              id: CornerPart.band,
              child: cornerBandStep(cornerStep(a, 0, 5, n, cornerSlideCurve), const CornerBand(onTop: true)),
            ),
            LayoutId(id: CornerPart.text, child: text),
            if (hasPoster)
              LayoutId(
                id: CornerPart.poster,
                child: cornerSlideStep(
                  cornerStep(a, 9, 14, n, cornerSlideCurve),
                  (CornerLayout.posterWidth + 24 + 40) * s,
                  _poster(context, posterPath, fallbackPath),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _poster(BuildContext context, String path, String? fallback) {
    final client = context.tryGetMediaClientForServer(serverIdOrNull(widget.metadata.serverId));
    Widget image(String path, {Widget Function(BuildContext, String, dynamic)? errorWidget}) => OptimizedMediaImage(
      client: client,
      imagePath: path,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      placeholder: (_, _) => const SizedBox.shrink(),
      errorWidget: errorWidget ?? (_, _, _) => const SizedBox.shrink(),
    );
    return image(path, errorWidget: fallback == null ? null : (context, _, _) => image(fallback));
  }
}

/// "S2 · E5 · The Name", or as much of it as the episode has.
String? _episodeLine(MediaItem item) {
  final parts = [
    if (item.parentIndex != null) 'S${item.parentIndex}',
    if (item.index != null) 'E${item.index}',
    if (item.title?.isNotEmpty ?? false) item.title!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
