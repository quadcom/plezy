import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/companion_remote/remote_pairing.dart';
import '../dialog_action_button.dart';

/// The code a remote asked to pair with (Home Assistant), shown until it is
/// used, cancelled or runs out. Closes itself when the pairing ends.
class RemotePairingDialog extends StatefulWidget {
  const RemotePairingDialog({super.key, required this.pairing, required this.pending, required this.onCancel});

  final PendingRemotePairing pairing;
  final ValueListenable<PendingRemotePairing?> pending;
  final VoidCallback onCancel;

  /// Shows [pairing] on the root navigator, so it lands over the player too.
  static Future<void> show(
    BuildContext context, {
    required PendingRemotePairing pairing,
    required ValueListenable<PendingRemotePairing?> pending,
    required VoidCallback onCancel,
  }) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => RemotePairingDialog(pairing: pairing, pending: pending, onCancel: onCancel),
    );
  }

  @override
  State<RemotePairingDialog> createState() => _RemotePairingDialogState();
}

class _RemotePairingDialogState extends State<RemotePairingDialog> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.pending.addListener(_onPendingChanged);
  }

  @override
  void dispose() {
    widget.pending.removeListener(_onPendingChanged);
    super.dispose();
  }

  void _onPendingChanged() {
    if (!identical(widget.pending.value, widget.pairing)) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  void _cancel() {
    widget.onCancel();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = widget.pairing.deviceName;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: Text(t.companionRemote.paired.requestTitle(device: device)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.companionRemote.paired.requestBody(device: device)),
            const SizedBox(height: 24),
            SelectableText(
              RemotePairingCrypto.formatCode(widget.pairing.code),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
        actions: [
          DialogActionButton(
            autofocus: true,
            onPressed: _cancel,
            onBack: _cancel,
            useBackgroundFocus: true,
            label: t.common.cancel,
          ),
        ],
      ),
    );
  }
}
