import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// Speech-to-text through the platform's own voice input screen (Android's
/// RECOGNIZE_SPEECH). The voice app records and recognises; Plezy only gets
/// the text back, so it needs no microphone permission.
class VoiceSearchService {
  static const MethodChannel _channel = MethodChannel('com.plezy/voice_search');

  static Future<bool>? _available;

  /// Whether a voice input app answers on this device. Resolved once.
  static Future<bool> isAvailable() {
    if (!Platform.isAndroid) return Future.value(false);
    return _available ??= _queryAvailable();
  }

  static Future<bool> _queryAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      appLogger.w('Voice search availability check failed', error: e);
      return false;
    }
  }

  /// Opens the voice screen and returns what was said, or null when the user
  /// backed out or nothing was recognised.
  static Future<String?> listen({String? prompt}) async {
    try {
      final text = await _channel.invokeMethod<String>('listen', {'prompt': prompt});
      final trimmed = text?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      appLogger.w('Voice search failed', error: e);
      return null;
    }
  }
}
