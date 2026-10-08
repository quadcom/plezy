import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../focus/focusable_button.dart';
import '../i18n/strings.g.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';
import 'loading_indicator_box.dart';

/// Whether [QuickConnectCodePanel] shows its approve QR code here: wide
/// screens only (a TV, a desktop).
bool quickConnectQrFits(BuildContext context) => MediaQuery.sizeOf(context).width > 700;

/// The Quick Connect waiting panel: the code to type into Jellyfin, a
/// "waiting for approval" line, and a cancel affordance.
///
/// Shared by the MediaBrowser add-server flow and the Seerr connect flow —
/// the same panel for the same interaction, only the server polling the code
/// differs. Callers place it in a filling slot (`SliverFillRemaining` + a
/// centering `Padding`) and own the poll itself.
///
/// With an [approveUrl], wide screens (a TV, a desktop) also show it as a QR
/// code beside the code, so a phone can approve without typing. Narrow
/// screens skip it: that phone is usually the device signing in.
class QuickConnectCodePanel extends StatelessWidget {
  /// Code the user types into Jellyfin's Quick Connect screen.
  final String code;

  /// Page that approves [code] when opened on a signed-in phone. Only the
  /// Jellyfin add-server flow has one; Seerr's Quick Connect has no such page.
  final String? approveUrl;

  /// Focused after the panel appears so a remote can dismiss it.
  final FocusNode? cancelFocusNode;

  final VoidCallback onCancel;

  /// Inline failure text under the cancel button, styled like
  /// `AsyncFormStateMixin.buildInlineError`.
  final String? errorText;

  const QuickConnectCodePanel({
    super.key,
    required this.code,
    required this.onCancel,
    this.approveUrl,
    this.cancelFocusNode,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final showQr = approveUrl != null && quickConnectQrFits(context);
    final panel = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: .min,
        children: [
          Text(
            showQr ? t.auth.quickConnectScanInstructions : t.auth.quickConnectInstructions,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
          const SizedBox(height: 32),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              // letterSpacing adds a trailing gap after the last glyph;
              // matching left padding keeps the code optically centered.
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                code,
                style: theme.textTheme.displayLarge?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: .bold,
                  letterSpacing: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisSize: .min,
            children: [
              const LoadingIndicatorBox(size: 16),
              const SizedBox(width: 10),
              Text(t.auth.quickConnectWaiting, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            ],
          ),
          const SizedBox(height: 32),
          FocusableButton(
            focusNode: cancelFocusNode,
            useBackgroundFocus: true,
            onPressed: onCancel,
            child: OutlinedButton.icon(
              onPressed: onCancel,
              icon: const AppIcon(Symbols.close_rounded, fill: 1),
              label: Text(t.auth.quickConnectCancel),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 16),
            Text(
              errorText!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
    if (!showQr) return panel;
    return Row(
      mainAxisSize: .min,
      children: [
        // Tight SizedBox so ancestors that measure intrinsics (e.g.
        // SliverFillRemaining with hasScrollBody: false) never recurse into
        // QrImageView's internal LayoutBuilder, which doesn't support them.
        SizedBox.square(
          dimension: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(tokens(context).radiusMd),
            child: QrImageView(data: approveUrl!, size: 240, version: QrVersions.auto, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(width: 48),
        Flexible(child: panel),
      ],
    );
  }
}
