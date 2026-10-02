import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';

/// Thrown when Android has not yet let this app install other apps
/// ("Install unknown apps"). The user has to allow it once in system settings.
class InstallPermissionRequiredException implements Exception {
  const InstallPermissionRequiredException();
}

/// Thrown when the downloaded APK does not match the release's listed size.
class UpdateDownloadIncompleteException implements Exception {
  const UpdateDownloadIncompleteException();
}

/// In-app updates for sideloaded Android installs: downloads the release APK
/// built for this device's CPU and hands it to the system installer.
class AndroidAppUpdater {
  AndroidAppUpdater._();

  static const _channel = MethodChannel('com.plezy/app_update');

  static bool _listening = false;

  static bool get isSupported => Platform.isAndroid;

  /// Logs an install the system installer ended without success after the
  /// APK was handed over (confirmation declined, or the APK was rejected).
  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onInstallStatus') return;
      final args = call.arguments as Map?;
      appLogger.w('Update install ended with status ${args?['status']}: ${args?['message']}');
    });
  }

  /// The release asset to install on a device whose CPU supports [abis]
  /// (most preferred first), or `null` when the release has none for it.
  ///
  /// Matches split-per-ABI APK names such as `plezy-2026.10.1-arm64-v8a.apk`
  /// and falls back to a universal APK (one naming no ABI).
  static Map<String, dynamic>? pickApkAsset(List<Map<String, dynamic>> assets, List<String> abis) {
    const knownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
    final apks = [
      for (final asset in assets)
        if ((asset['name'] as String).toLowerCase().endsWith('.apk')) asset,
    ];
    for (final abi in abis) {
      for (final asset in apks) {
        if ((asset['name'] as String).contains(abi)) return asset;
      }
    }
    for (final asset in apks) {
      final name = asset['name'] as String;
      if (!knownAbis.any(name.contains)) return asset;
    }
    return null;
  }

  /// This device's supported ABIs, most preferred first. A Chromecast or
  /// Google TV Streamer lists only `armeabi-v7a` even on a 64-bit chip.
  static Future<List<String>> supportedAbis() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis;
  }

  /// The APK in [updateInfo]'s release that suits this device, or `null`.
  static Future<Map<String, dynamic>?> apkFor(Map<String, dynamic> updateInfo) async {
    if (!isSupported) return null;
    final assets = (updateInfo['assets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (assets.isEmpty) return null;
    try {
      return pickApkAsset(assets, await supportedAbis());
    } catch (e, st) {
      appLogger.e('Could not read the device ABIs for an update', error: e, stackTrace: st);
      return null;
    }
  }

  static Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  /// Opens this app's "Install unknown apps" page in system settings.
  static Future<bool> openInstallSettings() async => await _channel.invokeMethod<bool>('openInstallSettings') ?? false;

  /// Downloads [asset] and starts the system install. Returns once the
  /// installer has the APK; Android then shows its confirmation screen (or,
  /// when allowed, installs straight away and restarts the app).
  static Future<void> downloadAndInstall(
    Map<String, dynamic> asset, {
    void Function(int received, int? total)? onProgress,
    AbortController? abort,
    MediaServerHttpClient? client,
  }) async {
    if (!await canInstall()) throw const InstallPermissionRequiredException();
    _ensureListening();

    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'app_update'));
    if (await dir.exists()) await dir.delete(recursive: true);
    final file = File(p.join(dir.path, 'update.apk'));

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

    await _channel.invokeMethod<bool>('install', {'path': file.path});
  }
}
