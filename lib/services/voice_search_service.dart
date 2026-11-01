import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// What happened while listening, for Plezy's listening card.
enum VoiceSearchEventType { ready, speech, partial, end }

class VoiceSearchEvent {
  final VoiceSearchEventType type;

  /// The words so far, for [VoiceSearchEventType.partial].
  final String? text;

  const VoiceSearchEvent(this.type, [this.text]);
}

/// How a listen ended.
enum VoiceSearchOutcome { heard, nothing, permissionDenied, failed }

class VoiceSearchResult {
  final VoiceSearchOutcome outcome;
  final String? text;

  const VoiceSearchResult(this.outcome, [this.text]);
}

/// Speech-to-text through Android's speech service, driven from Plezy's own
/// listening card (Greatroom TV, 2026-10-31: Google TV's voice screen heard
/// the words but gave Plezy nothing back). Needs the microphone permission,
/// which Android asks for the first time. Devices without the service fall
/// back to the system voice screen, which only returns a final text.
class VoiceSearchService {
  static const MethodChannel _channel = MethodChannel('com.plezy/voice_search');

  static Future<bool>? _available;
  static final StreamController<VoiceSearchEvent> _events = StreamController<VoiceSearchEvent>.broadcast();
  static bool _handlerSet = false;

  /// Live events while listening.
  static Stream<VoiceSearchEvent> get events {
    _ensureHandler();
    return _events.stream;
  }

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onEvent') return;
      final args = call.arguments;
      if (args is! Map) return;
      final type = switch (args['type']) {
        'ready' => VoiceSearchEventType.ready,
        'speech' => VoiceSearchEventType.speech,
        'partial' => VoiceSearchEventType.partial,
        'end' => VoiceSearchEventType.end,
        _ => null,
      };
      if (type == null) return;
      final text = args['text'];
      _events.add(VoiceSearchEvent(type, text is String ? text : null));
    });
  }

  static bool? _debugAvailable;

  /// Tests: pretend voice search is (or is not) available; null restores.
  @visibleForTesting
  static void debugSetAvailable(bool? available) => _debugAvailable = available;

  /// Whether this device can do voice search. Resolved once.
  static Future<bool> isAvailable() {
    final debug = _debugAvailable;
    if (debug != null) return Future.value(debug);
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

  /// Listens once and returns what was said.
  static Future<VoiceSearchResult> listen({String? prompt}) async {
    _ensureHandler();
    try {
      final text = (await _channel.invokeMethod<String>('listen', {'prompt': prompt}))?.trim();
      // Length only: what someone says stays out of the log.
      appLogger.i('Voice search returned ${text == null || text.isEmpty ? 'nothing' : '${text.length} chars'}');
      return text == null || text.isEmpty
          ? const VoiceSearchResult(VoiceSearchOutcome.nothing)
          : VoiceSearchResult(VoiceSearchOutcome.heard, text);
    } on MissingPluginException {
      return const VoiceSearchResult(VoiceSearchOutcome.failed);
    } on PlatformException catch (e) {
      appLogger.w('Voice search failed', error: e);
      return VoiceSearchResult(
        e.code == 'PERMISSION_DENIED' ? VoiceSearchOutcome.permissionDenied : VoiceSearchOutcome.failed,
      );
    }
  }

  /// Stops listening; the pending [listen] answers with nothing.
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Nothing to cancel.
    } on PlatformException catch (e) {
      appLogger.w('Voice search cancel failed', error: e);
    }
  }
}
