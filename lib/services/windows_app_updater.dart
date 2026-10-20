import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/media_server_http_client.dart';
import 'android_app_updater.dart' show UpdateDownloadIncompleteException;

/// In-app updates for an installed Windows copy: downloads the release's
/// setup file and runs it silently. Setup closes Plezy if it is still running
/// and opens it again when it finishes. A portable copy has no installer to
/// run, so it keeps the "View Release" link.
class WindowsAppUpdater {
  WindowsAppUpdater._();

  /// Arguments for the Inno Setup installer: no wizard pages, no "This will
  /// install" prompt, and close a running Plezy before replacing its files.
  static const installerArguments = ['/SILENT', '/SP-', '/CLOSEAPPLICATIONS'];

  static bool get isSupported => Platform.isWindows && isInstalledCopy;

  /// Whether this copy was installed by the Inno Setup installer, which places
  /// unins000.exe next to the executable.
  static bool get isInstalledCopy {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return File(p.join(exeDir, 'unins000.exe')).existsSync();
  }

  /// The setup file in a release, such as `plezy-2026.10.30-windows-x64-setup.exe`,
  /// or `null` when the release has none.
  static Map<String, dynamic>? pickSetupAsset(List<Map<String, dynamic>> assets) {
    for (final asset in assets) {
      if ((asset['name'] as String).toLowerCase().endsWith('-windows-x64-setup.exe')) return asset;
    }
    return null;
  }

  /// The setup file in [updateInfo]'s release, or `null` when this copy
  /// cannot install it.
  static Map<String, dynamic>? setupFor(Map<String, dynamic> updateInfo) {
    if (!isSupported) return null;
    final assets = (updateInfo['assets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return pickSetupAsset(assets);
  }

  /// Downloads [asset] and starts it. Returns once Setup is running; the
  /// caller then closes Plezy so Setup can replace its files.
  static Future<void> downloadAndInstall(
    Map<String, dynamic> asset, {
    void Function(int received, int? total)? onProgress,
    AbortController? abort,
    MediaServerHttpClient? client,
  }) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'plezy_update'));
    if (await dir.exists()) await dir.delete(recursive: true);
    final file = File(p.join(dir.path, asset['name'] as String));

    await (client ?? httpClient).downloadFile(
      asset['url'] as String,
      file.path,
      timeout: const Duration(minutes: 30),
      abort: abort,
      onProgress: onProgress,
    );

    final expected = asset['size'] as int?;
    if (expected != null && await file.length() != expected) {
      await file.delete();
      throw const UpdateDownloadIncompleteException();
    }

    await Process.start(file.path, installerArguments, mode: ProcessStartMode.detached);
  }
}
