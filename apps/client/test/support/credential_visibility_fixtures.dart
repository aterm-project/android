// Shared fixtures for the Credential visibility v1 tests: a fake instance
// signing key that signs escrow key descriptors exactly like the server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:crypto/crypto.dart' as hashing;
import 'package:sodium/sodium_sumo.dart';

const escrowInstanceId = '11111111-1111-4111-8111-111111111111';
const escrowServerSpaceId = '22222222-2222-4222-8222-222222222222';
const escrowKeyId = '33333333-3333-4333-8333-333333333333';
const escrowVaultId = '44444444-4444-4444-8444-444444444444';
const escrowSecondVaultId = '45454545-4545-4545-8545-454545454545';
const escrowAdminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const escrowUserId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const escrowDeviceId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

Uint8List sha256Bytes(List<int> bytes) =>
    Uint8List.fromList(hashing.sha256.convert(bytes).bytes);

class EscrowTestInstance {
  EscrowTestInstance(this.sodium) : signing = sodium.crypto.sign.keyPair();

  final SodiumSumo sodium;
  final KeyPair signing;

  String get signingPublicKey => encodeBase64Url(signing.publicKey);

  /// Wire descriptor `{key_id, public_key, signed_payload, signature,
  /// created_at}` signed by this instance key.
  Map<String, dynamic> descriptor({
    required String keyId,
    required Uint8List publicKey,
    String instanceId = escrowInstanceId,
    String format = 'atermius-credential-escrow-key-v1',
    String createdAt = '2026-11-13T10:00:00Z',
  }) {
    final encoded = encodeBase64Url(publicKey);
    final payload = canonicalJson({
      'format': format,
      'instance_id': instanceId,
      'key_id': keyId,
      'public_key': encoded,
      'created_at': createdAt,
    });
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(payload)),
      secretKey: signing.secretKey,
    );
    return {
      'key_id': keyId,
      'public_key': encoded,
      'signed_payload': payload,
      'signature': encodeBase64Url(signature),
      'created_at': createdAt,
    };
  }
}
