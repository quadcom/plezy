import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_library.dart';
import '../../models/iptv.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/jellyfin_client.dart';
import '../../services/settings_service.dart' as settings;
import '../../theme/mono_tokens.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../../utils/orientation_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';
import '../../watch_together/providers/watch_together_provider.dart';
import '../old_school/old_school_overlays.dart';
import '../video_player/iptv_session.dart';
import '../video_player/live_tv_session_args.dart';
import '../video_player_screen.dart';
import 'iptv_controller.dart';
import 'iptv_guide_view.dart';
import 'iptv_layout.dart';
import 'iptv_number_entry.dart';

/// The PlezyFin client that serves IPTV library [library], or null when it
/// cannot be opened here (not PlezyFin 3 or later, another server, or a
/// Plex profile).
JellyfinClient? iptvClientFor(BuildContext context, MediaLibrary library) {
  if (!library.isIptv) return null;
  final client = context.read<HiddenLibrariesProvider>().iptvClient;
  if (client == null) return null;
  // The library must be on the PlezyFin server itself.
  final serverId = library.serverId;
  if (serverId == null) return null;
  final owner = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
  return identical(owner, client) ? client : null;
}

/// Open IPTV library [library] full screen over the app (no side rail, top
/// bar or bottom bar), on its guide. Nothing plays until a channel is
/// picked. Returns false when this library cannot be opened here.
Future<bool> openIptv(BuildContext context, MediaLibrary library) async {
  final client = iptvClientFor(context, library);
  if (client == null) return false;
  // Watch Together re-seeks every viewer, which live channels can't follow.
  if (context.read<WatchTogetherProvider?>()?.isInSession ?? false) {
    showAppSnackBar(context, t.iptv.noWatchTogether);
    return true;
  }
  final controller = IptvController(client, libraryId: library.id, libraryTitle: library.title);
  unawaited(controller.load());
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      settings: const RouteSettings(name: '/iptv'),
      pageBuilder: (_, _, _) => IptvScreen(controller: controller, library: library),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
  return true;
}

/// Start playing [channel] in the player, which carries the same guide with
/// the video in its corner. [replaceCurrent] swaps out the guide-only page.
void pushIptvPlayer(
  NavigatorState navigator, {
  required IptvController controller,
  required IptvChannel channel,
  required MediaLibrary library,
  bool replaceCurrent = true,
}) {
  final client = controller.client;
  final live = iptvLiveChannel(channel, serverId: library.serverId, serverName: library.serverName);
  final channels = [
    for (final c in controller.allChannels)
      iptvLiveChannel(c, serverId: library.serverId, serverName: library.serverName),
  ];
  final route = VideoPlayerRoute(
    builder: (_) => VideoPlayerScreen(
      metadata: liveTvChannelItem(live, backend: client.backend, serverId: library.serverId),
      live: LiveTvSessionArgs(
        channel: live,
        channels: channels,
        currentChannelIndex: controller.allChannels.indexWhere((c) => c.id == channel.id),
      ),
      iptv: IptvSessionArgs(controller: controller, channel: channel),
    ),
  );
  unawaited(route.push(navigator, replaceCurrent: replaceCurrent));
}

/// The guide before anything plays. Picking a channel hands over to the
/// player.
class IptvScreen extends StatefulWidget {
  final IptvController controller;
  final MediaLibrary library;

  const IptvScreen({super.key, required this.controller, required this.library});

  @override
  State<IptvScreen> createState() => _IptvScreenState();
}

class _IptvScreenState extends State<IptvScreen> {
  bool _handedOver = false;
  DateTime? _backNoteAt;
  Timer? _backNoteTimer;
  late final IptvNumberEntry _numberEntry = IptvNumberEntry(
    onNumber: _tuneNumber,
    couldGrow: widget.controller.numberCouldGrow,
  );

  bool get _backNoteVisible {
    final at = _backNoteAt;
    return at != null && DateTime.now().difference(at) < IptvPlayerState.backAgainWindow;
  }

  @override
  void initState() {
    super.initState();
    // Upright on a phone, as the guide is laid out (Adrian, 2026-10-16).
    unawaited(OrientationHelper.lockPortraitOnPhone());
  }

  @override
  void dispose() {
    _backNoteTimer?.cancel();
    _numberEntry.dispose();
    // Once the player has taken over, it owns the controller and the
    // orientation; otherwise the app's default comes back.
    if (!_handedOver) {
      widget.controller.dispose();
      unawaited(OrientationHelper.restoreDefaultOrientations());
    }
    super.dispose();
  }

  void _leave() => Navigator.of(context).pop();

  void _onBack() {
    if (_numberEntry.digits.isNotEmpty) {
      _numberEntry.cancel();
      return;
    }
    if (_backNoteVisible) {
      _backNoteTimer?.cancel();
      _leave();
      return;
    }
    setState(() => _backNoteAt = DateTime.now());
    _backNoteTimer?.cancel();
    _backNoteTimer = Timer(IptvPlayerState.backAgainWindow, () {
      if (mounted) setState(() {});
    });
  }

  void _tune(IptvChannel channel) {
    if (_handedOver) return;
    _handedOver = true;
    pushIptvPlayer(Navigator.of(context), controller: widget.controller, channel: channel, library: widget.library);
  }

  void _tuneNumber(int number) {
    final channel = widget.controller.channelByNumber(number);
    if (channel == null) {
      showAppSnackBar(context, t.iptv.noChannelNumber(number: iptvNumberLabel(number)));
      return;
    }
    _tune(channel);
  }

  @override
  Widget build(BuildContext context) {
    // Dark like the guide, status bar included.
    final mode = context.select<ThemeProvider, settings.ThemeMode>((p) => p.themeMode);
    final dark = ThemeProvider.darkThemeFor(mode);
    final tk = dark.extension<MonoTokens>()!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || BackKeyCoordinator.consumeIfHandled()) return;
        _onBack();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => handleBackKeyAction(event, _onBack),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Theme(
            data: dark,
            child: Scaffold(
              backgroundColor: tk.bg,
              body: SafeArea(
                bottom: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final layout = IptvLayout.of(constraints.biggest);
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: IptvGuideView(
                            controller: widget.controller,
                            layout: layout,
                            videoActive: false,
                            onTune: _tune,
                            onEnlarge: () {},
                            onExit: _leave,
                            onOtherKey: (_, event) => _numberEntry.handleKey(event),
                          ),
                        ),
                        Positioned.fill(child: IptvNumberEntryBadge(entry: _numberEntry)),
                        if (_backNoteVisible) const OldSchoolBackNote(),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keys that count as the remote's digits.
bool iptvIsDigitKey(LogicalKeyboardKey key) => IptvNumberEntry.digitOf(key) != null;
