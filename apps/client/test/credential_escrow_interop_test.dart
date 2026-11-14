// Cross-implementation checks for Credential visibility v1 escrow formats,
// against the shared vector protocol/test-vectors/credential-escrow-v1.json
// that server/src/credential_visibility_tests.rs also checks. Round trips
// through Dart alone cannot catch a mistake made the same way on both sides
// (JCS field names, integer vs string epochs, HKDF info, AAD layouts), so
// every value here is compared byte for byte with the Rust reference.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/credential_visibility/credential_escrow_crypto.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vectorPath = '../../protocol/test-vectors/credential-escrow-v1.json';

void main() {
  late SodiumSumo sodium;
  late VaultCrypto crypto;
  late Map<String, dynamic> vector;

  String text(String key) => vector[key] as String;
  Uint8List bytes(String key) => decodeBase64Url(text(key));
  Map<String, dynamic> object(String key) =>
      Map<String, dynamic>.from(vector[key] as Map);
  Uint8List utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

  DeviceIdentity identityFromSeed(String deviceId, String seedKey) {
    final seed = sodium.secureCopy(bytes(seedKey));
    try {
      return DeviceIdentity(
        deviceId: deviceId,
        signing: sodium.crypto.sign.seedKeyPair(seed),
        encryption: sodium.crypto.box.keyPair(),
      );
    } finally {
      seed.dispose();
    }
  }

  VerifiedEscrowKey verifiedKey() => verifyEscrowKeyDescriptor(
    sodium,
    descriptor: object('descriptor'),
    instanceId: text('instance_id'),
    pinnedInstanceSigningKey: text('instance_signing_public_key'),
  );

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
    vector = jsonDecode(
      File(_vectorPath).readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  test('the instance-signed descriptor verifies and parses', () {
    final descriptor = object('descriptor');
    // The vector's signed payload is exactly the client's JCS of the fields.
    expect(
      descriptor['signed_payload'],
      canonicalJson({
        'format': credentialEscrowKeyFormat,
        'instance_id': text('instance_id'),
        'key_id': text('key_id'),
        'public_key': text('escrow_public_key'),
        'created_at': text('created_at'),
      }),
    );
    final key = verifiedKey();
    expect(key.keyId, text('key_id'));
    expect(key.publicKey, bytes('escrow_public_key'));
    expect(key.createdAt, text('created_at'));
    final parsed = CredentialEscrowKeyDescriptor.fromJson(descriptor);
    expect(parsed.toJson(), descriptor);
    // Bound to the pinned instance key and instance id.
    expect(
      () => verifyEscrowKeyDescriptor(
        sodium,
        descriptor: descriptor,
        instanceId: text('admin_account_id'),
        pinnedInstanceSigningKey: text('instance_signing_public_key'),
      ),
      throwsFormatException,
    );
    expect(
      () => verifyEscrowKeyDescriptor(
        sodium,
        descriptor: descriptor,
        instanceId: text('instance_id'),
        pinnedInstanceSigningKey: text('admin_device_signing_public_key'),
      ),
      throwsFormatException,
    );
  });

  test('the creator signature is byte-identical to the reference', () {
    final admin = identityFromSeed(
      text('admin_device_id'),
      'admin_device_signing_seed',
    );
    expect(admin.signingPublicKey, text('admin_device_signing_public_key'));
    final signature = signEscrowKeyCreation(
      sodium,
      identity: admin,
      instanceId: text('instance_id'),
      accountId: text('admin_account_id'),
      keyId: text('key_id'),
      publicKey: text('escrow_public_key'),
    );
    // Ed25519 is deterministic: equal signatures mean equal statements.
    expect(signature, text('creator_signature'));
    expect(
      sodium.crypto.sign.verifyDetached(
        message: utf8Bytes(text('creation_statement')),
        signature: bytes('creator_signature'),
        publicKey: admin.signing.publicKey,
      ),
      isTrue,
    );
    admin.signing.dispose();
    admin.encryption.dispose();
  });

  test('the account wrap key, AAD and wrap match the reference', () async {
    expect(
      canonicalJson([
        'atermius',
        credentialEscrowAccountWrapPurpose,
        1,
        {'version': 1, 'key_id': text('key_id')},
      ]),
      text('account_wrap_info'),
    );
    final input = sodium.secureCopy(bytes('admin_account_key'));
    final derived = await crypto.derivePurposeKey(
      inputKey: input,
      purpose: credentialEscrowAccountWrapPurpose,
      context: {'version': 1, 'key_id': text('key_id')},
    );
    input.dispose();
    expect(encodeBase64Url(derived), text('account_wrap_key'));
    expect(
      canonicalJson({
        'context': credentialEscrowAccountWrapContext,
        'version': 1,
        'instance_id': text('instance_id'),
        'key_id': text('key_id'),
        'account_id': text('admin_account_id'),
      }),
      text('account_wrap_aad'),
    );

    final secret = await unwrapEscrowSecretKeyForAccount(
      crypto,
      accountKey: bytes('admin_account_key'),
      wrap: object('account_wrap'),
      instanceId: text('instance_id'),
      keyId: text('key_id'),
      accountId: text('admin_account_id'),
    );
    expect(secret.extractBytes(), bytes('escrow_secret_key'));
    expect(
      escrowSecretKeyMatches(sodium, key: verifiedKey(), secretKey: secret),
      isTrue,
    );
    secret.dispose();
    // Another account id is a different AAD.
    await expectLater(
      unwrapEscrowSecretKeyForAccount(
        crypto,
        accountKey: bytes('admin_account_key'),
        wrap: object('account_wrap'),
        instanceId: text('instance_id'),
        keyId: text('key_id'),
        accountId: text('depositor_account_id'),
      ),
      throwsFormatException,
    );
  });

  test('the recovery code, Argon2id key and recovery wrap match', () {
    final display = text('recovery_code');
    final normalized = text('recovery_code_normalized');
    expect(normalizeEscrowRecoveryCode(display), normalized);
    expect(formatEscrowRecoveryCode(normalized), display);
    final code = EscrowRecoveryCode.parse(display);
    expect(code.normalized, normalized);
    expect(code.display, display);
    expect(EscrowRecoveryCode.parse(normalized.toLowerCase()).display, display);
    // RFC 4648 Base32 of the 20 code bytes, without padding.
    expect(_base32(bytes('recovery_code_bytes')), normalized);

    final wrap = object('recovery_wrap');
    final salt = validateEscrowRecoveryWrap(wrap);
    final kdfKey = crypto.derivePasswordKey(
      normalized,
      KdfParameters(
        salt: salt,
        memoryKib: credentialEscrowRecoveryKdfMemoryKib,
        iterations: credentialEscrowRecoveryKdfIterations,
        parallelism: credentialEscrowRecoveryKdfParallelism,
      ),
    );
    expect(kdfKey.extractBytes(), bytes('recovery_kdf_key'));
    kdfKey.dispose();
    expect(
      canonicalJson({
        'context': credentialEscrowRecoveryContext,
        'version': 1,
        'instance_id': text('instance_id'),
        'key_id': text('key_id'),
      }),
      text('recovery_wrap_aad'),
    );
    final secret = unwrapEscrowSecretKeyWithRecoveryCode(
      crypto,
      code: code,
      wrap: wrap,
      instanceId: text('instance_id'),
      keyId: text('key_id'),
    );
    expect(secret.extractBytes(), bytes('escrow_secret_key'));
    secret.dispose();
  });

  test('the Rust-built deposit opens and verifies on the admin side', () {
    final deposit = object('deposit');
    final sealed = decodeBase64Url(deposit['sealed'] as String);
    final statement = jsonDecode(text('deposit_statement')) as Map;
    expect(
      statement['sealed_sha256'],
      encodeBase64Url(hashing.sha256.convert(sealed).bytes),
    );
    expect(statement['key_epoch'], vector['key_epoch']);
    // Parsed exactly as the admin escrow listing delivers it.
    final envelope = AdminEscrowEnvelope.fromJson({
      'key_epoch': vector['key_epoch'],
      'sealed': deposit['sealed'],
      'signature': deposit['signature'],
      'depositor_device_id': text('depositor_device_id'),
      'depositor_signing_public_key': text(
        'depositor_device_signing_public_key',
      ),
    });
    final secret = sodium.secureCopy(bytes('escrow_secret_key'));
    final vaultKey = openEscrowDeposit(
      sodium,
      key: verifiedKey(),
      secretKey: secret,
      instanceId: text('instance_id'),
      vaultId: text('vault_id'),
      keyEpoch: envelope.keyEpoch,
      sealed: envelope.sealed,
      signature: envelope.signature,
      depositorSigningPublicKey: envelope.depositorSigningPublicKey!,
    );
    expect(vaultKey, bytes('vault_key'));
    final opened = sodium.crypto.box.sealOpen(
      cipherText: sealed,
      publicKey: bytes('escrow_public_key'),
      secretKey: secret,
    );
    expect(utf8.decode(opened), text('deposit_plaintext'));
    // Any other epoch is a different signed statement.
    expect(
      () => openEscrowDeposit(
        sodium,
        key: verifiedKey(),
        secretKey: secret,
        instanceId: text('instance_id'),
        vaultId: text('vault_id'),
        keyEpoch: envelope.keyEpoch + 1,
        sealed: envelope.sealed,
        signature: envelope.signature,
        depositorSigningPublicKey: envelope.depositorSigningPublicKey!,
      ),
      throwsFormatException,
    );
    secret.dispose();
  });

  test('a client-built deposit has the reference plaintext and statement', () {
    final depositor = identityFromSeed(
      text('depositor_device_id'),
      'depositor_device_signing_seed',
    );
    expect(
      depositor.signingPublicKey,
      text('depositor_device_signing_public_key'),
    );
    final body = buildEscrowDeposit(
      sodium,
      key: verifiedKey(),
      identity: depositor,
      instanceId: text('instance_id'),
      vaultId: text('vault_id'),
      keyEpoch: vector['key_epoch'] as int,
      vaultKey: bytes('vault_key'),
    );
    expect(body.keys.toSet(), {'key_id', 'sealed', 'signature'});
    expect(body['key_id'], text('key_id'));
    final sealed = decodeBase64Url(body['sealed']! as String);
    // crypto_box_seal is randomized: open it and compare the plaintext.
    final secret = sodium.secureCopy(bytes('escrow_secret_key'));
    final opened = sodium.crypto.box.sealOpen(
      cipherText: sealed,
      publicKey: bytes('escrow_public_key'),
      secretKey: secret,
    );
    secret.dispose();
    expect(utf8.decode(opened), text('deposit_plaintext'));
    // The reference statement with this seal's hash is what was signed.
    final statement =
        Map<String, Object?>.from(jsonDecode(text('deposit_statement')) as Map)
          ..['sealed_sha256'] = encodeBase64Url(
            hashing.sha256.convert(sealed).bytes,
          );
    expect(
      sodium.crypto.sign.verifyDetached(
        message: utf8Bytes(canonicalJson(statement)),
        signature: decodeBase64Url(body['signature']! as String),
        publicKey: depositor.signing.publicKey,
      ),
      isTrue,
    );
    depositor.signing.dispose();
    depositor.encryption.dispose();
  });
}

/// Independent RFC 4648 Base32 (no padding) for the vector check.
String _base32(Uint8List data) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = '';
  for (final byte in data) {
    bits += byte.toRadixString(2).padLeft(8, '0');
  }
  final out = StringBuffer();
  for (var i = 0; i < bits.length; i += 5) {
    final chunk = bits.substring(i, i + 5 > bits.length ? bits.length : i + 5);
    out.write(alphabet[int.parse(chunk.padRight(5, '0'), radix: 2)]);
  }
  return out.toString();
}
