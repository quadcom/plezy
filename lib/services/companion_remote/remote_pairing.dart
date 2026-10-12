import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../credential_vault.dart';
import '../sensitive_prefs.dart';
import '../settings_service.dart';
import 'remote_auth_context.dart';
import 'remote_auth_service.dart';

/// Pair-once sign-in for a remote that has no media-server account of its
/// own, such as Home Assistant (local/plans/ha-theatre-remote.md).
///
/// The remote asks to pair, the TV shows an 8-character code, the remote's
/// owner types it in, and the code protects a one-time handover of a random
/// 32-byte secret. From then on that secret is one more auth context on the
/// host and the normal handshake applies. Message shapes and key derivation
/// are agreed with ha-plezy; change neither without changing both sides.
class RemotePairingCrypto {
  RemotePairingCrypto._();

  /// No 0, 1, I or O: the code is read off a TV and typed in elsewhere.
  static const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const codeLength = 8;

  static final _hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  static final _aesGcm = AesGcm.with256bits();

  /// A fresh code; 32 symbols make `byte & 31` uniform.
  static String generateCode([Random? random]) {
    final rng = random ?? Random.secure();
    return String.fromCharCodes(List.generate(codeLength, (_) => alphabet.codeUnitAt(rng.nextInt(256) & 31)));
  }

  /// `ABCDEFGH` as shown on the TV: `ABCD-EFGH`.
  static String formatCode(String code) => '${code.substring(0, 4)}-${code.substring(4)}';

  /// Trimmed, upper-cased, spaces and dashes removed; null unless it is then
  /// exactly [codeLength] symbols of [alphabet].
  static String? normaliseCode(String input) {
    final code = input.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (code.length != codeLength) return null;
    for (final unit in code.codeUnits) {
      if (!alphabet.codeUnits.contains(unit)) return null;
    }
    return code;
  }

  /// 16 random bytes, base64url without padding.
  static String newPairId([Random? random]) {
    final rng = random ?? Random.secure();
    return base64UrlEncode(List.generate(16, (_) => rng.nextInt(256))).replaceAll('=', '');
  }

  /// `K = HKDF-SHA256(code, salt = hostNonce ‖ clientNonce, info = "plezy-pair-v1")`.
  static Future<List<int>> deriveKey(String code, List<int> hostNonce, List<int> clientNonce) async {
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(code)),
      nonce: Uint8List.fromList([...hostNonce, ...clientNonce]),
      info: utf8.encode('plezy-pair-v1'),
    );
    return key.extractBytes();
  }

  /// Hex `HMAC-SHA256(K, "pair-proof|" + pairId)`, the remote's proof that its
  /// owner typed the right code.
  static String proof(List<int> key, String pairId) =>
      crypto.Hmac(crypto.sha256, key).convert(utf8.encode('pair-proof|$pairId')).toString();

  static bool verifyProof(List<int> key, String pairId, String received) {
    final expected = proof(key, pairId);
    if (expected.length != received.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ received.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<SecretKey> _wrapKey(List<int> key) async =>
      _hkdf.deriveKey(secretKey: SecretKey(key), nonce: const <int>[], info: utf8.encode('pair-wrap'));

  /// AES-256-GCM of [secret] under `HKDF(K, "pair-wrap")`, with the pairId as
  /// associated data. Returns ciphertext followed by the 16-byte tag.
  static Future<List<int>> wrapSecret({
    required List<int> key,
    required String pairId,
    required List<int> secret,
    required List<int> nonce,
  }) async {
    final box = await _aesGcm.encrypt(secret, secretKey: await _wrapKey(key), nonce: nonce, aad: utf8.encode(pairId));
    return [...box.cipherText, ...box.mac.bytes];
  }

  /// The remote's side of [wrapSecret]; Plezy uses it only in tests.
  static Future<List<int>> unwrapSecret({
    required List<int> key,
    required String pairId,
    required List<int> nonce,
    required List<int> ciphertext,
  }) async {
    final box = SecretBox(
      ciphertext.sublist(0, ciphertext.length - 16),
      nonce: nonce,
      mac: Mac(ciphertext.sublist(ciphertext.length - 16)),
    );
    return _aesGcm.decrypt(box, secretKey: await _wrapKey(key), aad: utf8.encode(pairId));
  }
}

/// A remote paired with this device. A device setting: it stays on the
/// device and applies whatever profile is active.
class PairedRemote {
  const PairedRemote({
    required this.clientIdentifier,
    required this.deviceName,
    required this.platform,
    required this.hostClientId,
    required this.secret,
    required this.pairedAt,
  });

  /// The remote's own id; a paired handshake must send it as `userUUID`.
  final String clientIdentifier;
  final String deviceName;
  final String platform;

  /// The id this device offers the remote in the challenge for this pairing.
  final String hostClientId;
  final List<int> secret;
  final DateTime pairedAt;

  Future<RemoteAuthContext> toAuthContext() async {
    final auth = RemoteAuthService.instance;
    return RemoteAuthContext(
      id: auth.computeAuthContextId(secret),
      backend: 'paired',
      connectionId: 'paired:$clientIdentifier',
      homeSecret: secret,
      discoveryKey: await auth.deriveDiscoveryKey(secret),
      clientIdentifier: hostClientId,
      userUuid: clientIdentifier,
      allowedUserUuids: [clientIdentifier],
    );
  }
}

/// Where pairings are kept: one preference holding a JSON list, each secret
/// sealed with [CredentialVault] like the server tokens.
class PairedRemoteStore {
  PairedRemoteStore({Future<String> Function()? read, Future<void> Function(String value)? write})
    : _read = read ?? _readPref,
      _write = write ?? _writePref;

  final Future<String> Function() _read;
  final Future<void> Function(String value) _write;

  static Future<String> _readPref() async =>
      (await SettingsService.getInstance()).readString(companionRemotePairingsPref, defaultValue: '');

  static Future<void> _writePref(String value) async =>
      (await SettingsService.getInstance()).writeString(companionRemotePairingsPref, value);

  Future<List<PairedRemote>> load() async {
    final raw = await _read();
    if (raw.isEmpty) return const [];
    final remotes = <PairedRemote>[];
    try {
      for (final entry in jsonDecode(raw) as List<dynamic>) {
        final map = entry as Map<String, dynamic>;
        final secret = await CredentialVault.reveal(map['secret'] as String);
        if (secret == null) {
          appLogger.w('CompanionRemote: Paired remote ${map['deviceName']} lost its secret; pair it again');
          continue;
        }
        remotes.add(
          PairedRemote(
            clientIdentifier: map['clientIdentifier'] as String,
            deviceName: map['deviceName'] as String,
            platform: map['platform'] as String,
            hostClientId: map['hostClientId'] as String,
            secret: base64Decode(secret),
            pairedAt: DateTime.parse(map['pairedAt'] as String),
          ),
        );
      }
    } catch (e) {
      appLogger.w('CompanionRemote: Unreadable paired remotes', error: e);
    }
    return remotes;
  }

  Future<void> save(List<PairedRemote> remotes) async {
    final entries = [
      for (final remote in remotes)
        {
          'clientIdentifier': remote.clientIdentifier,
          'deviceName': remote.deviceName,
          'platform': remote.platform,
          'hostClientId': remote.hostClientId,
          'secret': await CredentialVault.protect(base64Encode(remote.secret)),
          'pairedAt': remote.pairedAt.toUtc().toIso8601String(),
        },
    ];
    await _write(entries.isEmpty ? '' : jsonEncode(entries));
  }
}

/// A pairing the TV is showing a code for.
class PendingRemotePairing {
  PendingRemotePairing({
    required this.pairId,
    required this.code,
    required this.hostNonce,
    required this.clientNonce,
    required this.clientIdentifier,
    required this.deviceName,
    required this.platform,
    required this.sourceIp,
    required this.expiresAt,
  });

  final String pairId;
  final String code;
  final List<int> hostNonce;
  final List<int> clientNonce;
  final String clientIdentifier;
  final String deviceName;
  final String platform;
  final String sourceIp;
  final DateTime expiresAt;
}

/// The host's answer to one pairing message, and whether it counts toward the
/// sender's failed-sign-in lockout.
typedef RemotePairingReply = ({Map<String, dynamic> reply, bool countsAsFailure});

/// The host side of pairing: one code on screen at a time, one try per code.
class RemotePairingHost {
  RemotePairingHost({
    required this.onPaired,
    this.onPairingDelivered,
    DateTime Function()? now,
    Random? random,
    @visibleForTesting this._newSecret,
    @visibleForTesting this._newWrapNonce,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static const lifetime = Duration(seconds: 120);
  static const _maxEnded = 8;

  /// Saves a new pairing. Awaited before the secret is sent, so a remote never
  /// holds a secret the TV forgot.
  final Future<void> Function(PairedRemote remote) onPaired;

  /// Runs once the secret has gone out, so the host can restart with the new
  /// context without cutting off the reply.
  final void Function()? onPairingDelivered;

  final DateTime Function() _now;
  final Random _random;
  final List<int> Function()? _newSecret;
  final List<int> Function()? _newWrapNonce;

  final ValueNotifier<PendingRemotePairing?> pending = ValueNotifier(null);
  final Map<String, ({String reason, String sourceIp})> _ended = {};
  Timer? _expiryTimer;

  List<int> _randomBytes(int length) => List.generate(length, (_) => _random.nextInt(256));

  RemotePairingReply _failed(String reason, {required bool counts}) =>
      (reply: {'type': 'pairFailed', 'reason': reason}, countsAsFailure: counts);

  static bool _validText(Object? value, int maxLength) =>
      value is String && value.trim().isNotEmpty && value.length <= maxLength;

  RemotePairingReply handleRequest(Map<String, dynamic> message, String sourceIp) {
    final clientNonceB64 = message['clientNonce'];
    final clientIdentifier = message['clientIdentifier'];
    final deviceName = message['deviceName'];
    final platform = message['platform'];
    if (clientNonceB64 is! String ||
        !_validText(clientIdentifier, 128) ||
        !_validText(deviceName, 64) ||
        !_validText(platform, 64)) {
      return _failed('invalid', counts: true);
    }
    final List<int> clientNonce;
    try {
      clientNonce = base64Decode(clientNonceB64);
    } catch (_) {
      return _failed('invalid', counts: true);
    }
    if (clientNonce.length != 32) return _failed('invalid', counts: true);

    _expireIfDue();
    if (pending.value != null) return _failed('busy', counts: false);

    final pairing = PendingRemotePairing(
      pairId: RemotePairingCrypto.newPairId(_random),
      code: RemotePairingCrypto.generateCode(_random),
      hostNonce: _randomBytes(32),
      clientNonce: clientNonce,
      clientIdentifier: clientIdentifier as String,
      deviceName: (deviceName as String).trim(),
      platform: platform as String,
      sourceIp: sourceIp,
      expiresAt: _now().add(lifetime),
    );
    pending.value = pairing;
    _expiryTimer?.cancel();
    _expiryTimer = Timer(lifetime, () {
      if (identical(pending.value, pairing)) _end(pairing, 'expired');
    });
    appLogger.i('CompanionRemote: Pairing requested by ${pairing.deviceName} ($sourceIp)');
    return (
      reply: {
        'type': 'pairStarted',
        'pairId': pairing.pairId,
        'hostNonce': base64Encode(pairing.hostNonce),
        'expiresIn': lifetime.inSeconds,
      },
      countsAsFailure: false,
    );
  }

  Future<RemotePairingReply> handleComplete(Map<String, dynamic> message, String sourceIp) async {
    final pairId = message['pairId'];
    final proof = message['proof'];
    if (pairId is! String || pairId.isEmpty || proof is! String || proof.length != 64) {
      return _failed('invalid', counts: true);
    }

    _expireIfDue();
    final pairing = pending.value;
    if (pairing == null || pairing.pairId != pairId || pairing.sourceIp != sourceIp) {
      final ended = _ended[pairId];
      if (ended != null && ended.sourceIp == sourceIp && ended.reason != 'used') {
        return _failed(ended.reason, counts: false);
      }
      return _failed('unknown', counts: true);
    }

    // One try per code, right or wrong.
    _end(pairing, 'used');
    final key = await RemotePairingCrypto.deriveKey(pairing.code, pairing.hostNonce, pairing.clientNonce);
    if (!RemotePairingCrypto.verifyProof(key, pairId, proof.toLowerCase())) {
      appLogger.w('CompanionRemote: Wrong pairing code from ${pairing.deviceName} ($sourceIp)');
      return _failed('wrong_code', counts: true);
    }

    final secret = _newSecret?.call() ?? _randomBytes(32);
    final remote = PairedRemote(
      clientIdentifier: pairing.clientIdentifier,
      deviceName: pairing.deviceName,
      platform: pairing.platform,
      hostClientId: 'plezy-paired-${_randomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      secret: secret,
      pairedAt: _now(),
    );
    try {
      await onPaired(remote);
    } catch (e, st) {
      appLogger.e('CompanionRemote: Could not save pairing', error: e, stackTrace: st);
      return _failed('error', counts: false);
    }

    final nonce = _newWrapNonce?.call() ?? _randomBytes(12);
    final ciphertext = await RemotePairingCrypto.wrapSecret(key: key, pairId: pairId, secret: secret, nonce: nonce);
    appLogger.i('CompanionRemote: Paired with ${pairing.deviceName}');
    return (
      reply: {
        'type': 'pairSecret',
        'pairId': pairId,
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(ciphertext),
        'authContextId': RemoteAuthService.instance.computeAuthContextId(secret),
        'hostClientId': remote.hostClientId,
      },
      countsAsFailure: false,
    );
  }

  /// The TV's Cancel button.
  void cancel() {
    final pairing = pending.value;
    if (pairing != null) _end(pairing, 'cancelled');
  }

  void _expireIfDue() {
    final pairing = pending.value;
    if (pairing != null && !_now().isBefore(pairing.expiresAt)) _end(pairing, 'expired');
  }

  void _end(PendingRemotePairing pairing, String reason) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _ended[pairing.pairId] = (reason: reason, sourceIp: pairing.sourceIp);
    while (_ended.length > _maxEnded) {
      _ended.remove(_ended.keys.first);
    }
    if (identical(pending.value, pairing)) pending.value = null;
  }

  void dispose() {
    _expiryTimer?.cancel();
    pending.dispose();
  }
}
