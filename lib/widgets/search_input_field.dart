import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import 'app_icon.dart';
import 'pill_input_decoration.dart';

/// The pill search field the search screens put above their results, with the
/// clear affordance that appears once there is text and an optional voice
/// button after it: RIGHT out of the field walks onto them, LEFT walks back,
/// and each escapes down into the results.
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
  });

  @override
  State<SearchInputField> createState() => _SearchInputFieldState();
}

class _SearchInputFieldState extends State<SearchInputField> {
  late final FocusNode _clearFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.clear');
  late final FocusNode _voiceFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.voice');

  @override
  void dispose() {
    _clearFocusNode.dispose();
    _voiceFocusNode.dispose();
    super.dispose();
  }

  void _clearSearch() {
    widget.controller.clear();
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    final onVoiceSearch = widget.onVoiceSearch;
    final hasVoice = onVoiceSearch != null;
    final trailingCount = (hasText ? 1 : 0) + (hasVoice ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          FocusableTextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            tvTextInputController: widget.tvTextInputController,
            textInputAction: TextInputAction.search,
            onNavigateLeft: widget.onNavigateLeft,
            onNavigateRight: hasText ? _clearFocusNode.requestFocus : (hasVoice ? _voiceFocusNode.requestFocus : null),
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
                    onNavigateRight: hasVoice ? _voiceFocusNode.requestFocus : null,
                    onNavigateDown: widget.onNavigateDown,
                    autoScroll: false,
                    child: IconButton(icon: const AppIcon(Symbols.clear_rounded, fill: 1), onPressed: _clearSearch),
                  ),
                if (hasVoice)
                  FocusableButton(
                    focusNode: _voiceFocusNode,
                    onPressed: onVoiceSearch,
                    onNavigateLeft: hasText ? _clearFocusNode.requestFocus : widget.focusNode.requestFocus,
                    onNavigateDown: widget.onNavigateDown,
                    autoScroll: false,
                    child: IconButton(
                      icon: const AppIcon(Symbols.mic_rounded, fill: 1),
                      tooltip: widget.voiceSearchTooltip,
                      onPressed: onVoiceSearch,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
