import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Typing a channel number on the remote, like a cable box (Adrian,
/// 2026-10-16): digits gather for a moment, then the channel is tuned. It
/// goes at once when no longer number could start with what was typed.
class IptvNumberEntry extends ChangeNotifier {
  IptvNumberEntry({required this.onNumber, required this.couldGrow});

  /// The typed number, once entry ends.
  final ValueChanged<int> onNumber;

  /// Whether a channel number starts with these digits and is longer.
  final bool Function(String digits) couldGrow;

  static const wait = Duration(milliseconds: 1800);
  static const maxDigits = 4;

  String _digits = '';
  Timer? _timer;
  bool _disposed = false;

  /// What has been typed so far; empty when no entry is going on.
  String get digits => _digits;

  /// The digit [key] stands for, or null.
  static int? digitOf(LogicalKeyboardKey key) {
    const keys = [
      [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0],
      [LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1],
      [LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2],
      [LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3],
      [LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4],
      [LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5],
      [LogicalKeyboardKey.digit6, LogicalKeyboardKey.numpad6],
      [LogicalKeyboardKey.digit7, LogicalKeyboardKey.numpad7],
      [LogicalKeyboardKey.digit8, LogicalKeyboardKey.numpad8],
      [LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad9],
    ];
    for (var digit = 0; digit < keys.length; digit++) {
      if (keys[digit].contains(key)) return digit;
    }
    return null;
  }

  /// Handle a key: digits are taken (key down only), anything else ignored.
  KeyEventResult handleKey(KeyEvent event) {
    final digit = digitOf(event.logicalKey);
    if (digit == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) add(digit);
    return KeyEventResult.handled;
  }

  void add(int digit) {
    if (_digits.isEmpty && digit == 0) {
      // A leading zero ("04") is part of how numbers are shown; keep it on
      // screen but it changes nothing.
      _digits = '0';
    } else {
      _digits = _digits == '0' ? '$digit' : '$_digits$digit';
    }
    _timer?.cancel();
    final value = _digits.replaceFirst(RegExp('^0+'), '');
    if (_digits.length >= maxDigits || (value.isNotEmpty && !couldGrow(value))) {
      _commit();
      return;
    }
    _timer = Timer(wait, _commit);
    _notify();
  }

  void cancel() {
    _timer?.cancel();
    if (_digits.isEmpty) return;
    _digits = '';
    _notify();
  }

  void _commit() {
    _timer?.cancel();
    final value = int.tryParse(_digits);
    _digits = '';
    _notify();
    if (value != null && value > 0) onNumber(value);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// The digits being typed, large in the top right corner. Put it in a
/// [Positioned.fill] over the page.
class IptvNumberEntryBadge extends StatelessWidget {
  final IptvNumberEntry entry;

  const IptvNumberEntryBadge({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        final digits = entry.digits;
        if (digits.isEmpty) return const SizedBox.shrink();
        final padding = MediaQuery.paddingOf(context);
        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: EdgeInsets.only(top: padding.top + 24, right: padding.right + 32),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text(
                    digits.padRight(digits.length < 2 ? 2 : digits.length, '-'),
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: const Color(0xFFF5B400),
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
