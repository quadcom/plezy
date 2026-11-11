import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../mpv/mpv.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';

/// The video mini player (local/plans/video-mini-player.md, Adrian 2026-11-09/10).
///
/// Back during the credits (PC, tablets and TVs, not Old School) shrinks the
/// playing video into a box flush in the top-right corner, over the Up Next
/// page. It keeps playing with sound; expand takes it back to full screen, X
/// stops it, and at the end of the item it fades out and stops by itself.
///
/// The playing player screen itself moves into the box: the same widget (it
/// carries a GlobalKey) is taken off its page and shown in [VideoMiniPlayerLayer],
/// which sits above the profile's pages, so nothing restarts. Expand moves it
/// back into a new player page the same way.
class VideoMiniPlayer extends ChangeNotifier {
  VideoMiniPlayer._();

  static final instance = VideoMiniPlayer._();

  /// Box width as a share of the window. Flush to the top and right edges,
  /// square, like Old School's window (Adrian, 2026-11-10).
  static const widthShare = 1 / 3;
  static const glide = Duration(milliseconds: 420);

  /// The box fades out over the item's last [fadeOut], after the page's art
  /// has grown to the full width in the [growAt] before that.
  static const fadeOut = Duration(milliseconds: 1500);
  static const growAt = Duration(seconds: 4);

  /// Time left in the box's video (null: nothing in the box, or unknown).
  final ValueNotifier<Duration?> timeLeft = ValueNotifier(null);

  Widget? _screen;
  Future<void> Function()? _stop;
  VoidCallback? _land;
  bool _expanding = false;

  /// The player screen in the box, or null when there is none.
  Widget? get screen => _screen;
  bool get isShowing => _screen != null;

  /// The box is gliding back to full screen; it lands on [_land].
  bool get isExpanding => _expanding;

  /// PC, tablets and TVs (Adrian, 2026-11-10); not phones.
  static bool appliesOn(BuildContext context) {
    if (PlatformDetector.isTV()) return true;
    if (PlatformDetector.isPhone(context)) return false;
    return PlatformDetector.isDesktopOS() || PlatformDetector.isTablet(context);
  }

  /// Puts [screen] in the box. [stop] ends its playback and lets it go;
  /// [onExpanded] moves it back into a full-screen page once the box has
  /// glided back up.
  void show(Widget screen, {required Future<void> Function() stop, required VoidCallback onExpanded}) {
    _screen = screen;
    _stop = stop;
    _land = onExpanded;
    _expanding = false;
    notifyListeners();
  }

  /// Takes [screen] out of the box (expanded, or stopped).
  void release(Widget screen) {
    if (!identical(_screen, screen)) return;
    _screen = null;
    _stop = null;
    _land = null;
    _expanding = false;
    timeLeft.value = null;
    notifyListeners();
  }

  /// Glides the box back to full screen, then hands the screen back to a page.
  void expand() {
    if (_screen == null || _expanding) return;
    _expanding = true;
    notifyListeners();
  }

  void _landed() {
    final land = _land;
    if (_expanding && land != null) land();
  }

  /// Stops the box's video; another playback is about to start, and only one
  /// player may own the native video at a time.
  Future<void> stop() async {
    final stop = _stop;
    if (stop != null) await stop();
  }
}

/// Above the profile's pages: the box, gliding in from full screen and back.
class VideoMiniPlayerLayer extends StatefulWidget {
  const VideoMiniPlayerLayer({super.key});

  @override
  State<VideoMiniPlayerLayer> createState() => _VideoMiniPlayerLayerState();
}

class _VideoMiniPlayerLayerState extends State<VideoMiniPlayerLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: VideoMiniPlayer.glide);
  final _mini = VideoMiniPlayer.instance;
  Widget? _shown;

  @override
  void initState() {
    super.initState();
    _mini.addListener(_changed);
  }

  @override
  void dispose() {
    _mini.removeListener(_changed);
    _t.dispose();
    super.dispose();
  }

  void _changed() {
    final screen = _mini.screen;
    if (screen != null && !identical(screen, _shown)) {
      // A new arrival glides down from full screen.
      _shown = screen;
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      _t.value = reduce ? 1 : 0;
      if (!reduce) _t.forward();
    } else if (screen == null) {
      _shown = null;
      _t.value = 0;
    } else if (_mini.isExpanding) {
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (reduce) {
        _mini._landed();
      } else {
        _t.reverse().whenComplete(() {
          if (mounted) _mini._landed();
        });
      }
    }
    setState(() {});
  }

  /// How much of the video shows: all of it, until the last
  /// [VideoMiniPlayer.fadeOut] of the item, when the page takes over.
  double _strength(Duration? left) {
    if (left == null || _mini.isExpanding) return 1;
    final f = left.inMilliseconds / VideoMiniPlayer.fadeOut.inMilliseconds;
    return Curves.easeInOut.transform(f.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final screen = _mini.screen;
    if (screen == null) return const SizedBox.shrink();
    final top = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final width = size.width * VideoMiniPlayer.widthShare;
        final box = Rect.fromLTWH(size.width - width, top, width, width * 9 / 16);
        final full = Offset.zero & size;
        return AnimatedBuilder(
          animation: _t,
          child: screen,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(_t.value);
            final rect = Rect.lerp(full, box, t)!;
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: ValueListenableBuilder<Duration?>(
                    valueListenable: _mini.timeLeft,
                    child: child,
                    builder: (context, left, child) => _MiniBox(strength: _strength(left), child: child!),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The box's frame. The video is a native surface behind the app window; the
/// pages underneath would paint over it, so the box cuts its own area out of
/// them and the moving picture shows through the hole. [strength] below 1
/// cuts only part of the way, so the page shows through: the fade at the end.
/// (An Opacity would draw the cut into a layer of its own and lose the hole.)
class _MiniBox extends StatelessWidget {
  const _MiniBox({required this.strength, required this.child});

  final double strength;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.6 * strength), blurRadius: 40, offset: const Offset(-10, 14)),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // willChange: never raster-cache the hole. A cached copy draws the
          // cut as an image over the page, which hides the video again; it
          // flashed on and off on Windows as the cache came and went (2026-11-10).
          CustomPaint(painter: _HolePainter(strength), willChange: true),
          if (strength > 0) Opacity(opacity: strength, child: child) else const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _HolePainter extends CustomPainter {
  const _HolePainter(this.strength);

  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    // dstOut keeps (1 - strength) of what is under the box.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..color = Color.fromRGBO(0, 0, 0, strength),
    );
  }

  @override
  bool shouldRepaint(covariant _HolePainter old) => old.strength != strength;
}

/// What the player screen shows while it is in the box: the picture, and on
/// hover (or a tap, on a tablet) expand, stop, play/pause and the title. No
/// progress line (Adrian, 2026-11-10). On a TV nothing: Up on the page below
/// takes the video back to full screen.
class VideoMiniChrome extends StatefulWidget {
  const VideoMiniChrome({
    super.key,
    required this.player,
    required this.title,
    required this.onExpand,
    required this.onStop,
    this.hasFirstFrame,
  });

  final Player player;
  final String title;
  final VoidCallback onExpand;
  final VoidCallback onStop;
  final ValueListenable<bool>? hasFirstFrame;

  @override
  State<VideoMiniChrome> createState() => _VideoMiniChromeState();
}

class _VideoMiniChromeState extends State<VideoMiniChrome> {
  bool _hover = false;
  Timer? _tapHide;
  StreamSubscription<Duration>? _position;

  @override
  void initState() {
    super.initState();
    // The time left drives the end of the box: the page's art grows, then
    // the box fades out.
    _position = widget.player.streams.position.listen(_track);
    _track(widget.player.state.position);
  }

  void _track(Duration position) {
    final duration = widget.player.state.duration;
    VideoMiniPlayer.instance.timeLeft.value = duration > Duration.zero ? duration - position : null;
  }

  @override
  void dispose() {
    _tapHide?.cancel();
    unawaited(_position?.cancel());
    super.dispose();
  }

  void _showForTap() {
    _tapHide?.cancel();
    setState(() => _hover = true);
    _tapHide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hover = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    if (PlatformDetector.isTV()) return Video(player: p, hasFirstFrame: widget.hasFirstFrame);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showForTap,
        onDoubleTap: widget.onExpand,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(player: p, hasFirstFrame: widget.hasFirstFrame),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(ignoring: !_hover, child: _controls(context, p)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, Player p) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x8C000000), Color(0x00000000), Color(0x00000000), Color(0xBF000000)],
          stops: [0, 0.35, 0.5, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 8,
            left: 8,
            child: _RoundButton(
              icon: Symbols.open_in_full_rounded,
              tooltip: t.videoControls.fullscreenButton,
              onTap: widget.onExpand,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: _RoundButton(icon: Symbols.close_rounded, tooltip: t.common.close, onTap: widget.onStop),
          ),
          Center(
            child: StreamBuilder<bool>(
              stream: p.streams.playing,
              initialData: p.state.playing,
              builder: (context, snap) => _RoundButton(
                icon: snap.data == true ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                tooltip: snap.data == true ? t.common.pause : t.common.play,
                size: 60,
                onTap: () => unawaited(p.playOrPause()),
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap, this.size = 44});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x8C000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: AppIcon(icon, fill: 1, size: size * 0.5, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
