import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../i18n/strings.g.dart';
import '../services/voice_search_service.dart';
import 'app_icon.dart';
import 'corner_band.dart';

/// Plezy's own listening card for voice search: an amber mic that pulses
/// while someone speaks, the words as they are heard, and Cancel. Replaces
/// Google's voice bar that covered Plezy's search page (Adrian, 2026-10-31).
///
/// Resolves with what was said; Back or Cancel resolves with nothing.
Future<VoiceSearchResult> showVoiceListeningDialog(BuildContext context, {String? prompt}) async {
  final result = await showGeneralDialog<VoiceSearchResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, _, _) => VoiceListeningCard(prompt: prompt),
    transitionBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
  return result ?? const VoiceSearchResult(VoiceSearchOutcome.nothing);
}

class VoiceListeningCard extends StatefulWidget {
  final String? prompt;

  const VoiceListeningCard({super.key, this.prompt});

  @override
  State<VoiceListeningCard> createState() => _VoiceListeningCardState();
}

class _VoiceListeningCardState extends State<VoiceListeningCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  StreamSubscription<VoiceSearchEvent>? _events;
  String _heard = '';
  bool _speaking = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _events = VoiceSearchService.events.listen(_onEvent);
    unawaited(VoiceSearchService.listen(prompt: widget.prompt).then(_close));
  }

  void _onEvent(VoiceSearchEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case VoiceSearchEventType.speech:
        setState(() => _speaking = true);
        unawaited(_pulse.repeat(reverse: true));
      case VoiceSearchEventType.partial:
        setState(() => _heard = event.text ?? _heard);
      case VoiceSearchEventType.end:
        setState(() => _speaking = false);
        _pulse.stop();
      case VoiceSearchEventType.ready:
        break;
    }
  }

  void _close(VoiceSearchResult result) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  void _cancel() {
    if (_closed) return;
    unawaited(VoiceSearchService.cancel());
    _close(const VoiceSearchResult(VoiceSearchOutcome.nothing));
  }

  @override
  void dispose() {
    // Back or a barrier tap closes the route without [_cancel].
    if (!_closed) unawaited(VoiceSearchService.cancel());
    _closed = true;
    unawaited(_events?.cancel());
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final heard = _heard.isNotEmpty;

    return Center(
      child: Material(
        color: colorScheme.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, minWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final grow = _speaking ? _pulse.value : 0.0;
                    return Container(
                      width: 96,
                      height: 96,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cornerAmber.withValues(alpha: 0.18 + 0.22 * grow),
                      ),
                      child: Container(
                        width: 64 + 12 * grow,
                        height: 64 + 12 * grow,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: cornerAmber),
                        child: child,
                      ),
                    );
                  },
                  child: const AppIcon(Symbols.mic_rounded, fill: 1, color: Colors.black, size: 34),
                ),
                const SizedBox(height: 20),
                Text(
                  heard ? _heard : t.search.voiceListening,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: heard ? colorScheme.onSurface : cornerAmber,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.prompt ?? t.search.voicePrompt,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FocusableButton(
                  autofocus: true,
                  onPressed: _cancel,
                  onBack: _cancel,
                  autoScroll: false,
                  child: OutlinedButton(onPressed: _cancel, child: Text(t.common.cancel)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
