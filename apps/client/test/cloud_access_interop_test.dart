// Cross-implementation checks for cloud access cryptography, shared with
// server/src/share_gateway.rs (`sealed_box_and_capsule_interop_vector`) and
// the Python black-box suite (PyNaCl/libsodium + `cryptography` HKDF).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/cloud/cloud_access_crypto.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vectorPath = '../../protocol/test-vectors/share-gateway-v1.json';

void main() {
  late SodiumSumo sodium;
  late Map<String, dynamic> vector;
  Uint8List bytes(String key) => decodeBase64Url(vector[key] as String);

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    vector = jsonDecode(File(_vectorPath).readAsStringSync()) as Map<String, dynamic>;
  });

  test('libsodium-sealed and Rust-sealed boxes open with the client sodium', () {
    final secret = sodium.secureCopy(bytes('gateway_secret_key'));
    final public = bytes('gateway_public_key');
    for (final key in ['libsodium_sealed', 'rust_sealed']) {
      final opened = sodium.crypto.box.sealOpen(cipherText: bytes(key), publicKey: public, secretKey: secret);
      expect(opened, bytes('message'), reason: key);
    }
    secret.dispose();
  });

  test('link secret derivations and display envelope match the reference', () async {
    final secret = ShareLinkSecret.fromFragment(vector['link_fragment'] as String)!;
    expect(secret.fragment, vector['link_fragment']);
    expect(await secret.redeemToken(), vector['redeem_token']);
    final linkId = vector['link_id'] as String;
    final key = await secret.displayKey(linkId, 1);
    expect(encodeBase64Url(key), vector['display_key']);
    final display = openShareDisplay(sodium, key, linkId, 1, vector['display_envelope'] as String);
    expect(display.title, 'Fixture');
    expect(display.targets, {'t1': 'db'});
    // The AAD binds link and secret version.
    expect(() => openShareDisplay(sodium, key, linkId, 2, vector['display_envelope'] as String), throwsA(anything));
    final sealed = sealShareDisplay(sodium, key, linkId, 1, display);
    expect(openShareDisplay(sodium, key, linkId, 1, sealed).title, 'Fixture');
  });

  test('fragment parsing is strict', () {
    expect(ShareLinkSecret.fromFragment(null), isNull);
    expect(ShareLinkSecret.fromFragment('s1.short'), isNull);
    expect(ShareLinkSecret.fromFragment('o1.${'A' * 43}'), isNull);
    expect(ShareLinkSecret.fromFragment('s1.${'A' * 42}B'), isNull, reason: 'non-canonical base64url');
  });

  test('gateway key must be signed by the pinned instance key and bound to it', () {
    final instance = sodium.crypto.sign.keyPair();
    final gateway = bytes('gateway_public_key');
    Map<String, dynamic> signed(String instanceId, {SecureKey? by}) {
      final payload = canonicalJson({
        'format': gatewayKeyFormat,
        'instance_id': instanceId,
        'key_id': 'k1',
        'public_key': encodeBase64Url(gateway),
        'created_at': '2026-11-08T00:00:00Z',
      });
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(payload)),
        secretKey: by ?? instance.secretKey,
      );
      return {'key_id': 'k1', 'public_key': encodeBase64Url(gateway), 'signed_payload': payload, 'signature': encodeBase64Url(signature)};
    }

    final pinned = encodeBase64Url(instance.publicKey);
    final ok = verifyGatewayKey(sodium, key: signed('inst'), instanceId: 'inst', pinnedInstanceSigningKey: pinned);
    expect(ok.publicKey, gateway);
    expect(() => verifyGatewayKey(sodium, key: signed('other'), instanceId: 'inst', pinnedInstanceSigningKey: pinned), throwsFormatException);
    final rogue = sodium.crypto.sign.keyPair();
    expect(() => verifyGatewayKey(sodium, key: signed('inst', by: rogue.secretKey), instanceId: 'inst', pinnedInstanceSigningKey: pinned), throwsFormatException);
  });

  test('client-sealed capsule and box are in the vector for the Rust check', () async {
    final seed = sodium.secureCopy(bytes('device_signing_seed'));
    final identity = DeviceIdentity(
      deviceId: '22222222-2222-4222-8222-222222222222',
      signing: sodium.crypto.sign.seedKeyPair(seed),
      encryption: sodium.crypto.box.keyPair(),
    );
    final gateway = VerifiedGatewayKey(keyId: '33333333-3333-4333-8333-333333333333', publicKey: bytes('gateway_public_key'));
    final capsule = buildSealedCapsule(
      sodium,
      gateway: gateway,
      identity: identity,
      accountId: '44444444-4444-4444-8444-444444444444',
      vaultId: '55555555-5555-4555-8555-555555555555',
      hostRecordId: '66666666-6666-4666-8666-666666666666',
      hostRevisionId: '77777777-7777-4777-8777-777777777777',
      protocol: 'ssh',
      targetHost: 'db.internal.example',
      targetPort: 22,
      hostIdentity: 'SHA256:${base64.encode(List.filled(32, 7)).replaceAll('=', '')}',
      sshHostKeyAlgorithm: 'ssh-ed25519',
      login: const CapsuleLogin(username: 'fixture', password: 'interop-test-only'),
      now: DateTime.utc(2026, 11, 8),
    );
    final dartSealed = encodeBase64Url(sodium.crypto.box.seal(message: bytes('message'), publicKey: bytes('gateway_public_key')));
    if (Platform.environment['ATERMIUS_WRITE_SHARE_VECTOR'] != null) {
      vector['dart_sealed'] = dartSealed;
      vector['dart_capsule'] = capsule;
      File(_vectorPath).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(vector)}\n');
    }
    expect(vector['dart_sealed'], isA<String>());
    expect((vector['dart_capsule'] as Map)['header'], isA<Map>());
    // The client's own seal opens with the gateway secret (self-check).
    final secret = sodium.secureCopy(bytes('gateway_secret_key'));
    final inner = sodium.crypto.box.sealOpen(
      cipherText: decodeBase64Url(capsule['sealed']! as String),
      publicKey: bytes('gateway_public_key'),
      secretKey: secret,
    );
    expect(jsonDecode(utf8.decode(inner))['username'], 'fixture');
    secret.dispose();
    seed.dispose();
  });

  test('tokens sealed to a device open only with that device key', () {
    final device = sodium.crypto.box.keyPair();
    final other = sodium.crypto.box.keyPair();
    final identity = DeviceIdentity(deviceId: 'd', signing: sodium.crypto.sign.keyPair(), encryption: device);
    final sealed = sealTokenForDevice(sodium, 'invitation-token', device.publicKey);
    expect(openSealedToken(sodium, sealed, identity), 'invitation-token');
    final wrong = DeviceIdentity(deviceId: 'd', signing: sodium.crypto.sign.keyPair(), encryption: other);
    expect(() => openSealedToken(sodium, sealed, wrong), throwsA(anything));
    expect(deviceKeyFingerprint(device.publicKey), matches(RegExp(r'^[0-9A-F]{4}( [0-9A-F]{4}){4}$')));
  });
}
