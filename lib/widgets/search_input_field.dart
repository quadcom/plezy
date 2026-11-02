import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';
import 'pill_input_decoration.dart';

/// The pill search field the search screens put above their results, with the
/// clear affordance that appears once there is text, an optional "Search in"
/// button and an optional voice button after it: RIGHT out of the field walks onto them, LEFT walks back,
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

  /// Shows the "Search in" button (sliders icon, a badge with [searchInCount])
  /// after the clear button and before the mic when set. It is handed the
  /// button's on-screen rectangle to anchor its pop-up to.
  final ValueChanged<Rect>? onSearchIn;
  final int searchInCount;
  final String? searchInTooltip;

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
    this.onSearchIn,
    this.searchInCount = 0,
    this.searchInTooltip,
  });

  @override
  State<SearchInputField> createState() => _SearchInputFieldState();
}

class _SearchInputFieldState extends State<SearchInputField> {
  late final FocusNode _clearFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.clear');
  late final FocusNode _ownVoiceFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.voice');
  late final FocusNode _searchInFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.searchIn');
  final GlobalKey _searchInKey = GlobalKey(debugLabel: 'search_in_button');
  FocusNode get _voiceFocusNode => widget.voiceFocusNode ?? _ownVoiceFocusNode;

  @override
  void dispose() {
    _clearFocusNode.dispose();
    _ownVoiceFocusNode.dispose();
    _searchInFocusNode.dispose();
    super.dispose();
  }

  void _openSearchIn() {
    final onSearchIn = widget.onSearchIn;
    final box = _searchInKey.currentContext?.findRenderObject() as RenderBox?;
    if (onSearchIn == null || box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    onSearchIn(topLeft & box.size);
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
    final hasSearchIn = widget.onSearchIn != null;
    // TV: mic before the field; elsewhere it trails the clear button.
    final voiceFirst = isTV && hasVoice;
    final hasTrailingVoice = hasVoice && !voiceFirst;

    // The buttons inside the field's right end, in D-pad order.
    final trailingNodes = [
      if (hasText) _clearFocusNode,
      if (hasSearchIn) _searchInFocusNode,
      if (hasTrailingVoice) _voiceFocusNode,
    ];
    VoidCallback leftOf(FocusNode node) {
      final index = trailingNodes.indexOf(node);
      return index <= 0 ? widget.focusNode.requestFocus : trailingNodes[index - 1].requestFocus;
    }

    VoidCallback? rightOf(FocusNode node) {
      final index = trailingNodes.indexOf(node);
      return index < 0 || index >= trailingNodes.length - 1 ? null : trailingNodes[index + 1].requestFocus;
    }

    final trailingCount = trailingNodes.length;

    final field = Stack(
      alignment: Alignment.centerRight,
      children: [
        FocusableTextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          tvTextInputController: widget.tvTextInputController,
          tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
          // Plezy's keyboard opens the moment the field is highlighted
          // (Adrian, 2026-10-31: "We also need the keyboard displayed if the
          // input is highlighted"). The page lands on the mic, not here.
          tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.automatic,
          textInputAction: TextInputAction.search,
          onNavigateLeft: voiceFirst ? _voiceFocusNode.requestFocus : widget.onNavigateLeft,
          onNavigateRight: trailingNodes.isEmpty ? null : trailingNodes.first.requestFocus,
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
                  onNavigateLeft: leftOf(_clearFocusNode),
                  onNavigateRight: rightOf(_clearFocusNode),
                  onNavigateDown: widget.onNavigateDown,
                  autoScroll: false,
                  child: IconButton(icon: const AppIcon(Symbols.clear_rounded, fill: 1), onPressed: _clearSearch),
                ),
              if (hasSearchIn)
                FocusableButton(
                  key: _searchInKey,
                  focusNode: _searchInFocusNode,
                  onPressed: _openSearchIn,
                  onNavigateLeft: leftOf(_searchInFocusNode),
                  onNavigateRight: rightOf(_searchInFocusNode),
                  onNavigateDown: widget.onNavigateDown,
                  autoScroll: false,
                  child: IconButton(
                    tooltip: widget.searchInTooltip,
                    onPressed: _openSearchIn,
                    icon: Badge(
                      isLabelVisible: widget.searchInCount > 0,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      textColor: Theme.of(context).colorScheme.onPrimary,
                      label: Text('${widget.searchInCount}'),
                      child: const AppIcon(Symbols.tune_rounded, fill: 1),
                    ),
                  ),
                ),
              if (hasTrailingVoice) _voiceButton(onNavigateLeft: leftOf(_voiceFocusNode)),
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
