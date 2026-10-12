import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/services/companion_remote/remote_auth_service.dart';
import 'package:plezy/services/companion_remote/remote_pairing.dart';
import 'package:plezy/services/credential_vault.dart';

import '../test_helpers/prefs.dart';

const _ioTimeout = Duration(seconds: 5);

// Shared with ha-plezy (local/plans/ha-theatre-remote.md): computed outside
// Plezy, with Python's `cryptography` package, so both sides prove the same
// bytes. Changing any of these breaks every paired Home Assistant.
const _code = 'K7QP2M9X';
final _hostNonce = List<int>.generate(32, (i) => i);
final _clientNonce = List<int>.generate(32, (i) => 32 + i);
const _pairId = 'AAECAwQFBgcICQoLDA0ODw';
final _secret = List<int>.generate(32, (i) => 64 + i);
final _wrapNonce = List<int>.generate(12, (i) => 96 + i);
const _expectedKey = 'fca6d2e481b5469cf87f37118fbc6f2438c09107142707d01d689d38f3824454';
const _expectedProof = 'ba4232cc9ce67df0c04842f3b83641bb02c604ea3a8414d287aeb201b3f6f437';
const _expectedCiphertext = '45h0Vkra1fnjrDlpjWnpL6Szy1Yimjqpd6P/cjmG1CiDkWDD1+FbV7kf7VE6m3nO';
const _expectedAuthContextId = 'v1._hbgwnpdIt-AJNmKY9iO_g';

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> _pairRequest({String clientIdentifier = 'ha-1'}) => {
  'type': 'pairRequest',
  'clientNonce': base64Encode(_clientNonce),
  'clientIdentifier': clientIdentifier,
  'deviceName': 'Home Assistant',
  'platform': 'homeassistant',
};

void main() {
  group('RemotePairingCrypto test vectors', () {
    test('match the values ha-plezy checks against', () async {
      expect(base64UrlEncode(List<int>.generate(16, (i) => i)).replaceAll('=', ''), _pairId);
      final key = await RemotePairingCrypto.deriveKey(_code, _hostNonce, _clientNonce);
      expect(_hex(key), _expectedKey);
      expect(RemotePairingCrypto.proof(key, _pairId), _expectedProof);
      final ciphertext = await RemotePairingCrypto.wrapSecret(
        key: key,
        pairId: _pairId,
        secret: _secret,
        nonce: _wrapNonce,
      );
      expect(base64Encode(ciphertext), _expectedCiphertext);
      expect(RemoteAuthService.instance.computeAuthContextId(_secret), _expectedAuthContextId);
      expect(
        await RemotePairingCrypto.unwrapSecret(key: key, pairId: _pairId, nonce: _wrapNonce, ciphertext: ciphertext),
        _secret,
      );
    });

    test('the pairId is bound to the ciphertext', () async {
      final key = await RemotePairingCrypto.deriveKey(_code, _hostNonce, _clientNonce);
      final ciphertext = base64Decode(_expectedCiphertext);
      await expectLater(
        RemotePairingCrypto.unwrapSecret(key: key, pairId: 'other', nonce: _wrapNonce, ciphertext: ciphertext),
        throwsA(anything),
      );
    });
  });

  group('pairing codes', () {
    test('normalise trims, upper-cases and drops spaces and dashes', () {
      expect(RemotePairingCrypto.normaliseCode(' k7qp-2m9x '), _code);
      expect(RemotePairingCrypto.normaliseCode('K7QP 2M9X'), _code);
    });

    test('anything outside the alphabet or the length is refused', () {
      expect(RemotePairingCrypto.normaliseCode('K7QP-2M9'), isNull);
      expect(RemotePairingCrypto.normaliseCode('K7QP-2M9XA'), isNull);
      expect(RemotePairingCrypto.normaliseCode('K7QP-2M90'), isNull); // 0 is not in the alphabet
      expect(RemotePairingCrypto.normaliseCode('K7QP-2MOX'), isNull); // nor O
    });

    test('generated codes use only the alphabet and format as XXXX-XXXX', () {
      for (var i = 0; i < 200; i++) {
        final code = RemotePairingCrypto.generateCode();
        expect(RemotePairingCrypto.normaliseCode(code), code);
      }
      expect(RemotePairingCrypto.formatCode(_code), 'K7QP-2M9X');
    });
  });

  group('RemotePairingHost', () {
    late DateTime now;
    late List<PairedRemote> saved;
    late RemotePairingHost host;

    setUp(() {
      now = DateTime(2026, 10, 12, 20);
      saved = [];
      host = RemotePairingHost(onPaired: (remote) async => saved.add(remote), now: () => now, newSecret: () => _secret);
      addTearDown(host.dispose);
    });

    Future<String> proofFor(PendingRemotePairing pairing, {String? code}) async {
      final key = await RemotePairingCrypto.deriveKey(code ?? pairing.code, pairing.hostNonce, _clientNonce);
      return RemotePairingCrypto.proof(key, pairing.pairId);
    }

    test('the right code hands over the secret once', () async {
      final started = host.handleRequest(_pairRequest(), '10.0.0.5');
      expect(started.reply['type'], 'pairStarted');
      expect(started.reply['expiresIn'], 120);
      expect(started.countsAsFailure, isFalse);
      final pairing = host.pending.value!;
      expect(started.reply['pairId'], pairing.pairId);
      expect(base64Decode(started.reply['hostNonce'] as String), pairing.hostNonce);

      final done = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.5');
      final reply = done.reply;
      expect(reply['type'], 'pairSecret');
      expect(done.countsAsFailure, isFalse);
      expect(host.pending.value, isNull);

      final key = await RemotePairingCrypto.deriveKey(pairing.code, pairing.hostNonce, _clientNonce);
      final secret = await RemotePairingCrypto.unwrapSecret(
        key: key,
        pairId: pairing.pairId,
        nonce: base64Decode(reply['nonce'] as String),
        ciphertext: base64Decode(reply['ciphertext'] as String),
      );
      expect(secret, _secret);
      expect(reply['authContextId'], _expectedAuthContextId);
      expect(saved.single.clientIdentifier, 'ha-1');
      expect(saved.single.hostClientId, reply['hostClientId']);

      // Replaying the same proof finds nothing.
      final replay = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.5');
      expect(replay.reply['reason'], 'unknown');
      expect(replay.countsAsFailure, isTrue);
    });

    test('a wrong code spends the code and counts as a failure', () async {
      host.handleRequest(_pairRequest(), '10.0.0.5');
      final pairing = host.pending.value!;
      final wrongCode = pairing.code == 'AAAAAAAA' ? 'BBBBBBBB' : 'AAAAAAAA';
      final wrong = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing, code: wrongCode),
      }, '10.0.0.5');
      expect(wrong.reply, {'type': 'pairFailed', 'reason': 'wrong_code'});
      expect(wrong.countsAsFailure, isTrue);
      expect(host.pending.value, isNull);

      final retry = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.5');
      expect(retry.reply['reason'], 'unknown');
      expect(saved, isEmpty);
    });

    test('one pairing at a time', () {
      host.handleRequest(_pairRequest(), '10.0.0.5');
      final busy = host.handleRequest(_pairRequest(clientIdentifier: 'ha-2'), '10.0.0.6');
      expect(busy.reply, {'type': 'pairFailed', 'reason': 'busy'});
      expect(busy.countsAsFailure, isFalse);
    });

    test('a proof from another address is refused and leaves the code alive', () async {
      host.handleRequest(_pairRequest(), '10.0.0.5');
      final pairing = host.pending.value!;
      final other = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.9');
      expect(other.reply['reason'], 'unknown');
      expect(other.countsAsFailure, isTrue);
      expect(host.pending.value, same(pairing));
    });

    test('an expired code says so without counting', () async {
      host.handleRequest(_pairRequest(), '10.0.0.5');
      final pairing = host.pending.value!;
      now = now.add(const Duration(seconds: 121));
      final late = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.5');
      expect(late.reply, {'type': 'pairFailed', 'reason': 'expired'});
      expect(late.countsAsFailure, isFalse);
      expect(saved, isEmpty);
    });

    test('Cancel on the TV ends the pairing', () async {
      host.handleRequest(_pairRequest(), '10.0.0.5');
      final pairing = host.pending.value!;
      host.cancel();
      expect(host.pending.value, isNull);
      final after = await host.handleComplete({
        'type': 'pairComplete',
        'pairId': pairing.pairId,
        'proof': await proofFor(pairing),
      }, '10.0.0.5');
      expect(after.reply, {'type': 'pairFailed', 'reason': 'cancelled'});
    });

    test('bad fields are invalid and count', () async {
      final noNonce = host.handleRequest({
        ..._pairRequest(),
        'clientNonce': base64Encode([1, 2, 3]),
      }, '10.0.0.5');
      expect(noNonce.reply['reason'], 'invalid');
      expect(noNonce.countsAsFailure, isTrue);
      final noName = host.handleRequest({..._pairRequest(), 'deviceName': ' '}, '10.0.0.5');
      expect(noName.reply['reason'], 'invalid');
      final shortProof = await host.handleComplete({'type': 'pairComplete', 'pairId': 'x', 'proof': 'ab'}, '10.0.0.5');
      expect(shortProof.reply['reason'], 'invalid');
      expect(host.pending.value, isNull);
    });
  });

  group('PairedRemoteStore', () {
    setUp(() {
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();
    });

    test('round-trips pairings with the secret sealed', () async {
      var stored = '';
      final store = PairedRemoteStore(read: () async => stored, write: (value) async => stored = value);
      final remote = PairedRemote(
        clientIdentifier: 'ha-1',
        deviceName: 'Home Assistant',
        platform: 'homeassistant',
        hostClientId: 'plezy-paired-01',
        secret: _secret,
        pairedAt: DateTime.utc(2026, 10, 12),
      );
      await store.save([remote]);
      expect(stored, isNot(contains(base64Encode(_secret))));

      final loaded = (await store.load()).single;
      expect(loaded.clientIdentifier, 'ha-1');
      expect(loaded.secret, _secret);
      expect(loaded.pairedAt, DateTime.utc(2026, 10, 12));

      final context = await loaded.toAuthContext();
      expect(context.id, _expectedAuthContextId);
      expect(context.allowedUserUuids, ['ha-1']);
      expect(context.clientIdentifier, 'plezy-paired-01');

      await store.save(const []);
      expect(stored, isEmpty);
      expect(await store.load(), isEmpty);
    });
  });

  group('pairing over the host socket', () {
    final plexContext = RemoteAuthContext(
      id: 'context-1',
      backend: 'plex',
      connectionId: 'connection-1',
      homeSecret: List<int>.generate(32, (index) => index),
      discoveryKey: List<int>.generate(32, (index) => 255 - index),
      clientIdentifier: 'host-client',
      userUuid: 'user-1',
      allowedUserUuids: const ['user-1'],
    );

    test('request, prove, then sign in with the paired secret', () async {
      final saved = <PairedRemote>[];
      var delivered = 0;
      final pairing = RemotePairingHost(
        onPaired: (remote) async => saved.add(remote),
        onPairingDelivered: () => delivered++,
      );
      addTearDown(pairing.dispose);
      final host = CompanionRemotePeerService.forTesting()..pairingHost = pairing;
      addTearDown(host.dispose);
      final port = (await host.createSessionForContexts('Test Host', 'android', [plexContext])).port;

      final started = await _exchange(port, _pairRequest());
      expect(started.replies.single['type'], 'pairStarted');
      expect(started.closeCode, 1000);
      final pending = pairing.pending.value!;

      final key = await RemotePairingCrypto.deriveKey(
        pending.code,
        base64Decode(started.replies.single['hostNonce'] as String),
        _clientNonce,
      );
      final done = await _exchange(port, {
        'type': 'pairComplete',
        'pairId': pending.pairId,
        'proof': RemotePairingCrypto.proof(key, pending.pairId),
      });
      final reply = done.replies.single;
      expect(reply['type'], 'pairSecret');
      expect(done.closeCode, 1000);
      expect(delivered, 1);
      final secret = await RemotePairingCrypto.unwrapSecret(
        key: key,
        pairId: pending.pairId,
        nonce: base64Decode(reply['nonce'] as String),
        ciphertext: base64Decode(reply['ciphertext'] as String),
      );
      expect(secret, saved.single.secret);

      // The provider would now restart the host with the paired context.
      await host.disconnect();
      final pairedContext = await saved.single.toAuthContext();
      final port2 = (await host.createSessionForContexts('Test Host', 'android', [plexContext, pairedContext])).port;
      final socket = await WebSocket.connect('ws://127.0.0.1:$port2/ws').timeout(_ioTimeout);
      addTearDown(() => socket.close());
      final messages = StreamIterator(socket);
      expect(await messages.moveNext().timeout(_ioTimeout), isTrue);
      final challenge = jsonDecode(messages.current as String) as Map<String, dynamic>;
      final offered = (challenge['authContexts'] as List).cast<Map<String, dynamic>>();
      expect(offered.map((c) => c['id']), contains(reply['authContextId']));
      expect(offered.firstWhere((c) => c['id'] == reply['authContextId'])['hostClientId'], reply['hostClientId']);

      final clientNonce = RemoteAuthService.instance.generateNonce();
      socket.add(
        jsonEncode({
          'type': 'auth',
          'authContextId': reply['authContextId'],
          'clientNonce': base64Encode(clientNonce),
          'userUUID': 'ha-1',
          'clientIdentifier': 'ha-1',
          'deviceName': 'Home Assistant',
          'platform': 'homeassistant',
          'authTag': RemoteAuthService.instance.computeAuthTag(
            homeSecret: secret,
            hostNonce: base64Decode(challenge['nonce'] as String),
            clientNonce: clientNonce,
            hostClientId: reply['hostClientId'] as String,
            userUUID: 'ha-1',
            clientIdentifier: 'ha-1',
            deviceName: 'Home Assistant',
            platform: 'homeassistant',
          ),
        }),
      );
      // authSuccess comes encrypted; a failure would come as plain authFailed.
      expect(await messages.moveNext().timeout(_ioTimeout), isTrue);
      expect(messages.current, isNot(isA<String>()));
    });

    test('without a pairing host, pairing messages are refused like before', () async {
      final host = CompanionRemotePeerService.forTesting();
      addTearDown(host.dispose);
      final port = (await host.createSessionForContexts('Test Host', 'android', [plexContext])).port;
      final refused = await _exchange(port, _pairRequest());
      expect(refused.replies.single['type'], 'authFailed');
      expect(refused.closeCode, 4002);
    });
  });
}

/// Connect, skip the challenge, send [message] and collect the plain replies
/// until the host closes.
Future<({List<Map<String, dynamic>> replies, int? closeCode})> _exchange(int port, Map<String, dynamic> message) async {
  // The host closes it; the test waits for that.
  // ignore: close_sinks
  final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws').timeout(_ioTimeout);
  final replies = <Map<String, dynamic>>[];
  var challenged = false;
  final done = Completer<void>();
  socket.listen(
    (data) {
      if (data is! String) return;
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      if (!challenged && decoded['type'] == 'challenge') {
        challenged = true;
        socket.add(jsonEncode(message));
      } else {
        replies.add(decoded);
      }
    },
    onDone: done.complete,
    onError: (Object _) => done.complete(),
  );
  await done.future.timeout(_ioTimeout);
  return (replies: replies, closeCode: socket.closeCode);
}
