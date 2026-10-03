import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/android_app_updater.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'app_logger.dart';
import 'dialogs.dart';
import 'media_server_http_client.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) async {
  // On Android, a release APK for this device turns "View Release" into an
  // in-app install.
  final apk = await AndroidAppUpdater.apkFor(updateInfo);
  if (!context.mounted) return;

  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) {
      final latestVersion = updateInfo['latestVersion'] as String;
      final releaseUrl = updateInfo['releaseUrl'] as String;

      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(
              t.update.versionAvailable(version: latestVersion),
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              t.update.currentVersion(version: updateInfo['currentVersion']),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          DialogActionButton(onPressed: () => Navigator.pop(dialogContext), label: dismissLabel),
          if (showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                await UpdateService.skipVersion(latestVersion);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.skipVersion,
            ),
          if (apk != null)
            DialogActionButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_showInstallDialog(context, apk));
              },
              label: t.update.install,
              isPrimary: true,
              autofocus: true,
            )
          else
            DialogActionButton(
              onPressed: () async {
                final url = Uri.parse(releaseUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.viewRelease,
              isPrimary: true,
              autofocus: true,
            ),
        ],
      );
    },
  );
}

Future<void> _showInstallDialog(BuildContext context, Map<String, dynamic> apk) {
  if (!context.mounted) return Future.value();
  return showScopedDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateInstallDialog(apk: apk),
  );
}

enum _InstallStage { downloading, installing, needsPermission, failed }

/// Downloads the update APK with progress, then hands it to the installer.
class _UpdateInstallDialog extends StatefulWidget {
  const _UpdateInstallDialog({required this.apk});

  final Map<String, dynamic> apk;

  @override
  State<_UpdateInstallDialog> createState() => _UpdateInstallDialogState();
}

class _UpdateInstallDialogState extends State<_UpdateInstallDialog> {
  _InstallStage _stage = _InstallStage.downloading;
  double? _progress;
  AbortController? _abort;

  /// The action a D-pad user most likely wants once the dialog changes stage
  /// (Open Settings, or Retry). Focused explicitly: the Cancel button from the
  /// downloading stage is kept by the rebuild and would otherwise hold focus.
  final _stageActionFocus = FocusNode(debugLabel: 'UpdateInstallStageAction');

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _abort?.abort();
    _stageActionFocus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final abort = AbortController();
    _abort = abort;
    setState(() {
      _stage = _InstallStage.downloading;
      _progress = null;
    });
    try {
      await AndroidAppUpdater.downloadAndInstall(
        widget.apk,
        abort: abort,
        onProgress: (received, total) {
          if (!mounted || total == null || total == 0) return;
          final progress = received / total;
          // Only repaint on whole-percent steps; the stream delivers many small chunks.
          if (_progress == null || (progress * 100).floor() != (_progress! * 100).floor()) {
            setState(() => _progress = progress);
          }
        },
      );
      if (!mounted) return;
      setState(() => _stage = _InstallStage.installing);
      // The system installer takes over from here.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context);
    } on InstallPermissionRequiredException {
      if (mounted) _showStage(_InstallStage.needsPermission);
    } catch (e, st) {
      if (abort.isAborted) return;
      appLogger.e('Update download or install failed', error: e, stackTrace: st);
      if (mounted) _showStage(_InstallStage.failed);
    } finally {
      if (identical(_abort, abort)) _abort = null;
    }
  }

  void _showStage(_InstallStage stage) {
    setState(() => _stage = stage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _stageActionFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    final List<Widget> actions;
    switch (_stage) {
      case _InstallStage.downloading:
        final percent = _progress == null ? null : (_progress! * 100).floor();
        content = Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(percent == null ? t.update.downloading : t.update.downloadingPercent(percent: percent)),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
          ],
        );
        actions = [
          DialogActionButton(
            onPressed: () {
              _abort?.abort();
              Navigator.pop(context);
            },
            label: t.common.cancel,
          ),
        ];
      case _InstallStage.installing:
        content = Text(t.update.installing);
        actions = const [];
      case _InstallStage.needsPermission:
        content = Text(t.update.installPermissionNeeded);
        actions = [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.cancel),
          DialogActionButton(
            onPressed: AndroidAppUpdater.openInstallSettings,
            label: t.update.openSettings,
            focusNode: _stageActionFocus,
          ),
          DialogActionButton(onPressed: _start, label: t.update.install, isPrimary: true),
        ];
      case _InstallStage.failed:
        content = Text(t.update.installFailed);
        actions = [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.close),
          DialogActionButton(onPressed: _start, label: t.common.retry, isPrimary: true, focusNode: _stageActionFocus),
        ];
    }
    return AlertDialog(title: Text(t.update.available), content: content, actions: actions);
  }
}
