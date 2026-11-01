import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';
import 'pill_input_decoration.dart';

/// The pill search field the search screens put above their results, with the
/// clear affordance that appears once there is text and an optional voice
/// button after it: RIGHT out of the field walks onto them, LEFT walks back,
/// and each escapes down into the results.
///
/// On TV the field uses Plezy's own on-screen keyboard rather than the box's
/// (Gboard's pop-up and its broken mic on Google TV), and the voice button sits
/// first, before the field, where a remote reaches it at once (Adrian,
/// 2026-10-31: "relocate the voice button so it's the first thing highlighted").
///
/// [onBack] stays null unless the host wants the back key — a pushed route
/// needs it for its own pop.
class SearchInputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// Names the clear button's focus node.
  final String debugLabel;

  final TvTextInputController? tvTextInputController;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onBack;

  /// Shows a microphone button at the end of the field when set.
  final VoidCallback? onVoiceSearch;
  final String? voiceSearchTooltip;

  /// The voice button's focus node, for a host that focuses it first. Owned
  /// here when null.
  final FocusNode? voiceFocusNode;

  const SearchInputField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.debugLabel,
    this.tvTextInputController,
    this.onNavigateLeft,
    this.onNavigateDown,
    this.onEditingComplete,
    this.onBack,
    this.onVoiceSearch,
    this.voiceSearchTooltip,
    this.voiceFocusNode,
  });

  @override
  State<SearchInputField> createState() => _SearchInputFieldState();
}

class _SearchInputFieldState extends State<SearchInputField> {
  late final FocusNode _clearFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.clear');
  late final FocusNode _ownVoiceFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.voice');
  FocusNode get _voiceFocusNode => widget.voiceFocusNode ?? _ownVoiceFocusNode;

  @override
  void dispose() {
    _clearFocusNode.dispose();
    _ownVoiceFocusNode.dispose();
    super.dispose();
  }

  void _clearSearch() {
    widget.controller.clear();
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final isTV = PlatformDetector.isTV();
    final hasText = widget.controller.text.isNotEmpty;
    final onVoiceSearch = widget.onVoiceSearch;
    final hasVoice = onVoiceSearch != null;
    // TV: mic before the field; elsewhere it trails the clear button.
    final voiceFirst = isTV && hasVoice;
    final hasTrailingVoice = hasVoice && !voiceFirst;
    final trailingCount = (hasText ? 1 : 0) + (hasTrailingVoice ? 1 : 0);

    final field = Stack(
      alignment: Alignment.centerRight,
      children: [
        FocusableTextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          tvTextInputController: widget.tvTextInputController,
          tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
          // With the mic first, the remote passes over the field on its way
          // right or up; OK opens the keyboard instead of every pass.
          tvTextInputAutoOpenBehavior: voiceFirst
              ? TvTextInputAutoOpenBehavior.never
              : TvTextInputAutoOpenBehavior.automatic,
          textInputAction: TextInputAction.search,
          onNavigateLeft: voiceFirst ? _voiceFocusNode.requestFocus : widget.onNavigateLeft,
          onNavigateRight: hasText
              ? _clearFocusNode.requestFocus
              : (hasTrailingVoice ? _voiceFocusNode.requestFocus : null),
          onNavigateDown: widget.onNavigateDown,
          onEditingComplete: widget.onEditingComplete,
          onBack: widget.onBack,
          decoration: pillInputDecoration(
            context,
            hintText: widget.hintText,
            prefixIcon: const AppIcon(Symbols.search_rounded, fill: 1),
            suffixIcon: trailingCount > 0 ? SizedBox(width: 48.0 * trailingCount) : null,
          ),
        ),
        if (trailingCount > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                FocusableButton(
                  focusNode: _clearFocusNode,
                  onPressed: _clearSearch,
                  onNavigateLeft: widget.focusNode.requestFocus,
                  onNavigateRight: hasTrailingVoice ? _voiceFocusNode.requestFocus : null,
                  onNavigateDown: widget.onNavigateDown,
                  autoScroll: false,
                  child: IconButton(icon: const AppIcon(Symbols.clear_rounded, fill: 1), onPressed: _clearSearch),
                ),
              if (hasTrailingVoice)
                _voiceButton(onNavigateLeft: hasText ? _clearFocusNode.requestFocus : widget.focusNode.requestFocus),
            ],
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
      child: voiceFirst
          ? Row(
              children: [
                _voiceButton(onNavigateLeft: widget.onNavigateLeft, onNavigateRight: widget.focusNode.requestFocus),
                const SizedBox(width: 8),
                Expanded(child: field),
              ],
            )
          : field,
    );
  }

  Widget _voiceButton({VoidCallback? onNavigateLeft, VoidCallback? onNavigateRight}) {
    final onVoiceSearch = widget.onVoiceSearch!;
    return FocusableButton(
      focusNode: _voiceFocusNode,
      onPressed: onVoiceSearch,
      onNavigateLeft: onNavigateLeft,
      onNavigateRight: onNavigateRight,
      onNavigateDown: widget.onNavigateDown,
      autoScroll: false,
      child: IconButton(
        icon: const AppIcon(Symbols.mic_rounded, fill: 1),
        tooltip: widget.voiceSearchTooltip,
        onPressed: onVoiceSearch,
      ),
    );
  }
}
