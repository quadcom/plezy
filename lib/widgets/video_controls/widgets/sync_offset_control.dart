import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_slider.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../mpv/mpv.dart';
import '../../../services/scoped_player_prefs.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/formatters.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/latest_async_write.dart';

/// Reusable widget for adjusting sync offsets (audio or subtitle)
class SyncOffsetControl extends StatefulWidget {
  final Player player;
  final String propertyName; // 'audio-delay' or 'sub-delay'
  final int initialOffset;
  final Future<void> Function(int offset) onOffsetChanged;

  /// Focus node for the reset button. When provided from the parent, allows
  /// the close button's left-press to focus the reset button.
  final FocusNode? resetFocusNode;

  /// Focus node for the close button. When provided, pressing select/enter
  /// on the slider moves focus here.
  final FocusNode? closeFocusNode;

  /// Focus node for the slider. When provided, allows the parent to
  /// auto-focus the slider when the bar opens.
  final FocusNode? sliderFocusNode;

  /// The -/+ buttons either side of the slider.
  final bool showStepButtons;

  /// The reset button after the value.
  final bool showReset;

  /// No button backgrounds, and a shadow on the value so it reads straight
  /// over the picture (the bare sync bar, local/plans/subtitle-download-fixes.md part 4).
  final bool overVideo;

  /// A short select press on the slider. Falls back to focusing
  /// [closeFocusNode].
  final VoidCallback? onDone;

  /// Holding select on the slider resets the offset to 0 (the TV's reset,
  /// where a reset button can't be reached).
  final bool resetOnLongSelect;

  const SyncOffsetControl({
    super.key,
    required this.player,
    required this.propertyName,
    required this.initialOffset,
    required this.onOffsetChanged,
    this.resetFocusNode,
    this.closeFocusNode,
    this.sliderFocusNode,
    this.showStepButtons = true,
    this.showReset = true,
    this.overVideo = false,
    this.onDone,
    this.resetOnLongSelect = false,
  });

  /// Keeps light text and icons readable on bright video without a panel.
  static const overVideoShadows = [
    Shadow(color: Color(0xCC000000), blurRadius: 6),
    Shadow(color: Color(0x99000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  @override
  State<SyncOffsetControl> createState() => _SyncOffsetControlState();
}

final Expando<LatestAsyncWrite<String>> _syncOffsetWrites = Expando<LatestAsyncWrite<String>>();

class _SyncOffsetControlState extends State<SyncOffsetControl> {
  // Range constants
  static const double _sliderMin = -10_000; // ±10s slider range for fine control
  static const double _sliderMax = 10_000;
  static const double _absoluteMin = ScopedPlayerPrefs.minimumSyncOffsetMs * 1.0;
  static const double _absoluteMax = ScopedPlayerPrefs.maximumSyncOffsetMs * 1.0;
  static const double _tapStep = 50; // 50ms per tap
  static const double _longPressStep = 1000; // 1s per long-press tick
  static const int _sliderDivisions = 400; // 50ms steps for ±10s range

  late double _currentOffset;
  late double _confirmedOffset;
  int _writeGeneration = 0;
  int _bindingGeneration = 0;
  Timer? _longPressTimer;

  @override
  void initState() {
    super.initState();
    _currentOffset = widget.initialOffset.toDouble();
    _confirmedOffset = _currentOffset;
  }

  @override
  void didUpdateWidget(SyncOffsetControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialOffset != oldWidget.initialOffset ||
        widget.player != oldWidget.player ||
        widget.propertyName != oldWidget.propertyName) {
      ++_writeGeneration;
      ++_bindingGeneration;
      _currentOffset = widget.initialOffset.toDouble();
      _confirmedOffset = _currentOffset;
    }
  }

  @override
  void dispose() {
    ++_writeGeneration;
    ++_bindingGeneration;
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _applyOffset(double offsetMs) {
    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    final persistOffset = widget.onOffsetChanged;
    final coordinator = _syncOffsetWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    unawaited(() async {
      try {
        final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
          // Convert milliseconds to seconds for mpv. Keep the native write and
          // persistence on the same per-player/property queue so an older
          // native write can never complete after a newer one.
          final offsetSeconds = offsetMs / 1000.0;
          await targetPlayer.setProperty(propertyName, offsetSeconds.toString());
          await persistOffset(offsetMs.round());
          if (mounted &&
              bindingGeneration == _bindingGeneration &&
              targetPlayer == widget.player &&
              propertyName == widget.propertyName) {
            // A write may finish successfully after a newer intent was queued.
            // Keep it as the rollback baseline without replacing the newer
            // optimistic value currently shown by the control.
            _confirmedOffset = offsetMs;
          }
        });
        if (!committed ||
            !mounted ||
            generation != _writeGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
      } catch (error, stackTrace) {
        appLogger.w('Failed to update playback sync offset', error: error, stackTrace: stackTrace);
        if (!mounted ||
            generation != _writeGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
        setState(() {
          _currentOffset = _confirmedOffset;
        });
      }
    }());
  }

  void _resetOffset() {
    setState(() {
      _currentOffset = 0;
    });
    _applyOffset(0);
  }

  void _incrementOffset() {
    final newOffset = (_currentOffset + _tapStep).clamp(_absoluteMin, _absoluteMax);
    setState(() {
      _currentOffset = newOffset;
    });
    _applyOffset(newOffset);
  }

  void _decrementOffset() {
    final newOffset = (_currentOffset - _tapStep).clamp(_absoluteMin, _absoluteMax);
    setState(() {
      _currentOffset = newOffset;
    });
    _applyOffset(newOffset);
  }

  void _startLongPressIncrement() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final newOffset = (_currentOffset + _longPressStep).clamp(_absoluteMin, _absoluteMax);
      setState(() {
        _currentOffset = newOffset;
      });
      _applyOffset(newOffset);
    });
  }

  void _startLongPressDecrement() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final newOffset = (_currentOffset - _longPressStep).clamp(_absoluteMin, _absoluteMax);
      setState(() {
        _currentOffset = newOffset;
      });
      _applyOffset(newOffset);
    });
  }

  void _stopLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  Widget _buildStepButton({
    required IconData icon,
    required VoidCallback onTap,
    required VoidCallback onLongPressStart,
  }) {
    return FocusableWrapper(
      onSelect: onTap,
      borderRadius: 18,
      autoScroll: false,
      useBackgroundFocus: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPressStart: (_) => onLongPressStart(),
        onLongPressEnd: (_) => _stopLongPress(),
        onLongPressCancel: _stopLongPress,
        child: Container(
          width: 36,
          height: 36,
          decoration: widget.overVideo
              ? null
              : BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
          child: AppIcon(
            icon,
            color: tokens(context).text,
            size: 22,
            shadows: widget.overVideo ? SyncOffsetControl.overVideoShadows : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sliderValue = _currentOffset.clamp(_sliderMin, _sliderMax);

    final overVideo = widget.overVideo;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: overVideo ? 8 : 16, vertical: 8),
      child: Row(
        children: [
          if (widget.showStepButtons)
            _buildStepButton(
              icon: Symbols.remove_rounded,
              onTap: _decrementOffset,
              onLongPressStart: _startLongPressDecrement,
            ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(
                context,
              ).copyWith(tickMarkShape: SliderTickMarkShape.noTickMark, trackHeight: overVideo ? 4 : null),
              child: FocusableSlider(
                focusNode: widget.sliderFocusNode,
                value: sliderValue,
                min: _sliderMin,
                max: _sliderMax,
                divisions: _sliderDivisions,
                activeColor: colorScheme.primary,
                inactiveColor: overVideo ? Colors.white.withValues(alpha: 0.45) : colorScheme.outlineVariant,
                onSelect: widget.onDone ?? widget.closeFocusNode?.requestFocus,
                onLongSelect: widget.resetOnLongSelect ? _resetOffset : null,
                onChanged: (value) => setState(() => _currentOffset = value),
                onChangeEnd: _applyOffset,
              ),
            ),
          ),
          if (widget.showStepButtons)
            _buildStepButton(
              icon: Symbols.add_rounded,
              onTap: _incrementOffset,
              onLongPressStart: _startLongPressIncrement,
            ),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Text(
              formatSyncOffset(_currentOffset),
              style: TextStyle(
                fontSize: overVideo ? 15 : 16,
                fontWeight: .bold,
                color: overVideo ? Colors.white : null,
                shadows: overVideo ? SyncOffsetControl.overVideoShadows : null,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (widget.showReset) ...[const SizedBox(width: 8), _buildResetButton(context)],
        ],
      ),
    );
  }

  Widget _buildResetButton(BuildContext context) {
    return FocusableWrapper(
      focusNode: widget.resetFocusNode,
      onSelect: _currentOffset != 0 ? _resetOffset : null,
      borderRadius: 18,
      autoScroll: false,
      useBackgroundFocus: true,
      child: GestureDetector(
        onTap: _currentOffset != 0 ? _resetOffset : null,
        child: Container(
          width: 36,
          height: 36,
          alignment: .center,
          child: AppIcon(
            Symbols.restart_alt_rounded,
            fill: 1,
            color: _currentOffset != 0 ? tokens(context).text : tokens(context).textMuted,
            size: 22,
            shadows: widget.overVideo ? SyncOffsetControl.overVideoShadows : null,
          ),
        ),
      ),
    );
  }
}
