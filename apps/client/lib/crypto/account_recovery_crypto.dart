import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:sodium/sodium.dart' as sodium_api;
import 'package:sodium/sodium_sumo.dart';

import 'jcs.dart';

const _recoveryProtocol = 'atermius-account-recovery-v1';
const _recoveryIdentityFormat = 'atermius-recovery-identity-v1';

/// Purpose-specific signing and box identities used only for account recovery.
/// Private keys are held in memory and must never be serialized to a store.
class RecoveryIdentity {
  const RecoveryIdentity({
    required this.accountId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.generation,
    required this.signing,
    required this.signingSeed,
    required this.encryption,
    required this.encryptionSeed,
  });

  final String accountId;
  final String instanceId;
  final String serverSpaceId;
  final int generation;
  final sodium_api.KeyPair signing;
  final sodium_api.SecureKey signingSeed;
  final sodium_api.KeyPair encryption;
  final sodium_api.SecureKey encryptionSeed;

  String get signingPublicKey => encodeBase64Url(signing.publicKey);
  String get encryptionPublicKey => encodeBase64Url(encryption.publicKey);

  void dispose() {
    signing.secretKey.dispose();
    signingSeed.dispose();
    encryption.secretKey.dispose();
    encryptionSeed.dispose();
  }
}

/// Client-side crypto for recovery envelopes and per-Vault epoch key boxes.
/// This is intentionally separate from device and Vault crypto.
class AccountRecoveryCrypto {
  AccountRecoveryCrypto(this.sodium);

  final SodiumSumo sodium;
  final crypto.Hkdf _hkdf = crypto.Hkdf(
    hmac: crypto.Hmac.sha256(),
    outputLength: 32,
  );

  Uint8List randomBytes(int count) => sodium.randombytes.buf(count);

  RecoveryIdentity createIdentity({
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required int generation,
  }) {
    final signingSeedBytes = randomBytes(sodium.crypto.sign.seedBytes);
    final encryptionSeedBytes = randomBytes(sodium.crypto.box.seedBytes);
    final signingSeed = sodium.secureCopy(signingSeedBytes);
    final encryptionSeed = sodium.secureCopy(encryptionSeedBytes);
    try {
      return RecoveryIdentity(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
        signing: sodium.crypto.sign.seedKeyPair(signingSeed),
        signingSeed: signingSeed,
        encryption: sodium.crypto.box.seedKeyPair(encryptionSeed),
        encryptionSeed: encryptionSeed,
      );
    } catch (_) {
      signingSeed.dispose();
      encryptionSeed.dispose();
      rethrow;
    } finally {
      signingSeedBytes.fillRange(0, signingSeedBytes.length, 0);
      encryptionSeedBytes.fillRange(0, encryptionSeedBytes.length, 0);
    }
  }

  /// Produces the printable 256-bit, base64url-without-padding recovery code.
  String createRecoveryCode() {
    final secret = randomBytes(32);
    try {
      return encodeBase64Url(secret);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  Future<Map<String, Object?>> sealIdentityWithRecoveryCode({
    required RecoveryIdentity identity,
    required String recoveryCode,
  }) async {
    final secret = _decodeCode(recoveryCode);
    try {
      return await _sealIdentity(
        identity,
        inputKey: sodium.secureCopy(secret),
        purpose: 'account-recovery-envelope',
        format: _recoveryProtocol,
        padToBytes: 512,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  Future<Map<String, Object?>> sealIdentityWithAccountKey({
    required RecoveryIdentity identity,
    required Uint8List accountKey,
  }) async {
    if (accountKey.length != 32) {
      throw const FormatException('Account key must be exactly 32 bytes.');
    }
    return _sealIdentity(
      identity,
      inputKey: sodium.secureCopy(accountKey),
      purpose: 'account-recovery-identity-wrap',
      format: 'atermius-account-recovery-identity-v1',
    );
  }

  Future<RecoveryIdentity> openIdentityWithRecoveryCode({
    required Map<String, dynamic> envelope,
    required String recoveryCode,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required int generation,
  }) async {
    final secret = _decodeCode(recoveryCode);
    try {
      return await _openIdentity(
        envelope: envelope,
        inputKey: sodium.secureCopy(secret),
        purpose: 'account-recovery-envelope',
        format: _recoveryProtocol,
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  Future<RecoveryIdentity> openIdentityWithAccountKey({
    required Map<String, dynamic> envelope,
    required Uint8List accountKey,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required int generation,
  }) async {
    if (accountKey.length != 32) {
      throw const FormatException('Account key must be exactly 32 bytes.');
    }
    return _openIdentity(
      envelope: envelope,
      inputKey: sodium.secureCopy(accountKey),
      purpose: 'account-recovery-identity-wrap',
      format: 'atermius-account-recovery-identity-v1',
      accountId: accountId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      generation: generation,
    );
  }

  Future<Map<String, Object?>> buildKeyEnvelope({
    required RecoveryIdentity identity,
    required String uploaderDeviceId,
    required String vaultId,
    required int keyEpoch,
    required Uint8List vaultKey,
  }) async {
    if (vaultKey.length != 32 || keyEpoch < 1) {
      throw const FormatException('Invalid Vault key context.');
    }
    final clear = <String, Object?>{
      'account_id': identity.accountId,
      'instance_id': identity.instanceId,
      'server_space_id': identity.serverSpaceId,
      'vault_id': vaultId,
      'key_epoch': keyEpoch,
      'vault_key': encodeBase64Url(vaultKey),
    };
    final clearBytes = Uint8List.fromList(utf8.encode(canonicalJson(clear)));
    Uint8List? sealed;
    try {
      sealed = sodium.crypto.box.seal(
        message: clearBytes,
        publicKey: identity.encryption.publicKey,
      );
      final envelope = <String, Object?>{
        'version': 1,
        'suite': 'crypto_box_seal',
        'ciphertext': encodeBase64Url(sealed),
      };
      // The protocol hashes the sealed ciphertext bytes, not their JSON
      // representation. Hash a copy because the helper wipes its input.
      final envelopeHash = await _sha256Hex(Uint8List.fromList(sealed));
      final descriptorHash = await recoveryDescriptorHash(
        accountId: identity.accountId,
        instanceId: identity.instanceId,
        serverSpaceId: identity.serverSpaceId,
        generation: identity.generation,
        signingPublicKey: identity.signingPublicKey,
        encryptionPublicKey: identity.encryptionPublicKey,
      );
      final signaturePayload = <String, Object?>{
        'protocol': _recoveryProtocol,
        'account_id': identity.accountId,
        'instance_id': identity.instanceId,
        'server_space_id': identity.serverSpaceId,
        'recovery_generation': identity.generation,
        'recovery_descriptor_hash': descriptorHash,
        'uploader_device_id': uploaderDeviceId,
        'vault_id': vaultId,
        'key_epoch': keyEpoch,
        'envelope_sha256': envelopeHash,
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(
          utf8.encode(canonicalJson(signaturePayload)),
        ),
        secretKey: identity.signing.secretKey,
      );
      return {
        'vault_id': vaultId,
        'key_epoch': keyEpoch,
        'uploader_device_id': uploaderDeviceId,
        'envelope': envelope,
        'envelope_sha256': envelopeHash,
        'recovery_signature': encodeBase64Url(signature),
      };
    } finally {
      clearBytes.fillRange(0, clearBytes.length, 0);
      sealed?.fillRange(0, sealed.length, 0);
    }
  }

  Future<Uint8List> openKeyEnvelope({
    required RecoveryIdentity identity,
    required String vaultId,
    required int keyEpoch,
    required Map<String, dynamic> envelope,
    required String uploaderDeviceId,
    required String recoverySignature,
    String? expectedEnvelopeSha256,
  }) async {
    if (envelope['version'] != 1 ||
        envelope['suite'] != 'crypto_box_seal' ||
        envelope['ciphertext'] is! String) {
      throw const FormatException('Unsupported recovery key envelope.');
    }
    final ciphertext = decodeBase64Url(envelope['ciphertext'] as String);
    final envelopeHash = await _sha256Hex(Uint8List.fromList(ciphertext));
    ciphertext.fillRange(0, ciphertext.length, 0);
    if ((expectedEnvelopeSha256 != null &&
            expectedEnvelopeSha256 != envelopeHash) ||
        (envelope['envelope_sha256'] is String &&
            envelope['envelope_sha256'] != envelopeHash)) {
      throw const FormatException('Recovery key envelope hash is invalid.');
    }
    final descriptorHash = await recoveryDescriptorHash(
      accountId: identity.accountId,
      instanceId: identity.instanceId,
      serverSpaceId: identity.serverSpaceId,
      generation: identity.generation,
      signingPublicKey: identity.signingPublicKey,
      encryptionPublicKey: identity.encryptionPublicKey,
    );
    final signed = <String, Object?>{
      'protocol': _recoveryProtocol,
      'account_id': identity.accountId,
      'instance_id': identity.instanceId,
      'server_space_id': identity.serverSpaceId,
      'recovery_generation': identity.generation,
      'recovery_descriptor_hash': descriptorHash,
      'uploader_device_id': uploaderDeviceId,
      'vault_id': vaultId,
      'key_epoch': keyEpoch,
      'envelope_sha256': envelopeHash,
    };
    final signatureBytes = decodeBase64Url(recoverySignature);
    try {
      if (encodeBase64Url(signatureBytes) != recoverySignature ||
          !sodium.crypto.sign.verifyDetached(
            message: Uint8List.fromList(utf8.encode(canonicalJson(signed))),
            signature: signatureBytes,
            publicKey: identity.signing.publicKey,
          )) {
        throw const FormatException(
          'Recovery key envelope signature is invalid.',
        );
      }
    } finally {
      signatureBytes.fillRange(0, signatureBytes.length, 0);
    }
    final clear = sodium.crypto.box.sealOpen(
      cipherText: decodeBase64Url(envelope['ciphertext'] as String),
      publicKey: identity.encryption.publicKey,
      secretKey: identity.encryption.secretKey,
    );
    try {
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.toSet().difference(const {
            'account_id',
            'instance_id',
            'server_space_id',
            'vault_id',
            'key_epoch',
            'vault_key',
          }).isNotEmpty ||
          decoded.length != 6 ||
          decoded['account_id'] != identity.accountId ||
          decoded['instance_id'] != identity.instanceId ||
          decoded['server_space_id'] != identity.serverSpaceId ||
          decoded['vault_id'] != vaultId ||
          decoded['key_epoch'] != keyEpoch ||
          decoded['vault_key'] is! String) {
        throw const FormatException('Recovery key envelope context mismatch.');
      }
      final key = decodeBase64Url(decoded['vault_key'] as String);
      if (key.length != 32) {
        key.fillRange(0, key.length, 0);
        throw const FormatException('Invalid recovered Vault key length.');
      }
      return key;
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  Future<String> recoveryDescriptorHash({
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required int generation,
    required String signingPublicKey,
    required String encryptionPublicKey,
  }) => _sha256Hex(
    Uint8List.fromList(
      utf8.encode(
        canonicalJson({
          'protocol': 'atermius-account-recovery-descriptor-v1',
          'account_id': accountId,
          'instance_id': instanceId,
          'server_space_id': serverSpaceId,
          'recovery_generation': generation,
          'recovery_public_signing_key': signingPublicKey,
          'recovery_public_encryption_key': encryptionPublicKey,
        }),
      ),
    ),
  );

  Future<String> sha256Hex(Uint8List bytes) => _sha256Hex(bytes);

  Uint8List detachedSignature({
    required RecoveryIdentity identity,
    required Map<String, Object?> payload,
  }) => sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
    secretKey: identity.signing.secretKey,
  );

  bool verifyDetached({
    required Uint8List signature,
    required Uint8List publicKey,
    required Map<String, Object?> payload,
  }) => sodium.crypto.sign.verifyDetached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
    signature: signature,
    publicKey: publicKey,
  );

  Future<Map<String, Object?>> _sealIdentity(
    RecoveryIdentity identity, {
    required sodium_api.SecureKey inputKey,
    required String purpose,
    required String format,
    int? padToBytes,
  }) async {
    final context = _identityContext(identity);
    Uint8List? signingSeed;
    Uint8List? encryptionSeed;
    Uint8List? clear;
    sodium_api.SecureKey? wrappingKey;
    try {
      signingSeed = identity.signingSeed.extractBytes();
      encryptionSeed = identity.encryptionSeed.extractBytes();
      final descriptorHash = await recoveryDescriptorHash(
        accountId: identity.accountId,
        instanceId: identity.instanceId,
        serverSpaceId: identity.serverSpaceId,
        generation: identity.generation,
        signingPublicKey: identity.signingPublicKey,
        encryptionPublicKey: identity.encryptionPublicKey,
      );
      clear = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'f': _recoveryIdentityFormat,
            'a': identity.accountId,
            'i': identity.instanceId,
            's': identity.serverSpaceId,
            'g': identity.generation,
            'd': descriptorHash,
            'p': identity.signingPublicKey,
            'q': encodeBase64Url(signingSeed),
            'x': identity.encryptionPublicKey,
            'y': encodeBase64Url(encryptionSeed),
          }),
        ),
      );
      if (padToBytes != null) {
        if (clear.length > padToBytes) {
          throw const FormatException(
            'Recovery package exceeds its fixed size.',
          );
        }
        final padded = Uint8List(padToBytes)..fillRange(0, padToBytes, 0x20);
        padded.setRange(0, clear.length, clear);
        clear.fillRange(0, clear.length, 0);
        clear = padded;
      }
      wrappingKey = await _deriveKey(
        inputKey,
        purpose: purpose,
        context: context,
      );
      final nonce = randomBytes(24);
      try {
        final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
          message: clear,
          nonce: nonce,
          key: wrappingKey,
          additionalData: Uint8List.fromList(
            utf8.encode(canonicalJson(_identityAad(identity, format))),
          ),
        );
        return {
          'version': 1,
          'suite': 'xchacha20-poly1305-ietf',
          'nonce': encodeBase64Url(nonce),
          'ciphertext': encodeBase64Url(ciphertext),
        };
      } finally {
        nonce.fillRange(0, nonce.length, 0);
      }
    } finally {
      wrappingKey?.dispose();
      signingSeed?.fillRange(0, signingSeed.length, 0);
      encryptionSeed?.fillRange(0, encryptionSeed.length, 0);
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<RecoveryIdentity> _openIdentity({
    required Map<String, dynamic> envelope,
    required sodium_api.SecureKey inputKey,
    required String purpose,
    required String format,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required int generation,
  }) async {
    if (envelope.keys.toSet().difference(const {
          'version',
          'suite',
          'nonce',
          'ciphertext',
        }).isNotEmpty ||
        envelope.length != 4 ||
        envelope['version'] != 1 ||
        envelope['suite'] != 'xchacha20-poly1305-ietf' ||
        envelope['nonce'] is! String ||
        envelope['ciphertext'] is! String) {
      inputKey.dispose();
      throw const FormatException('Unsupported Recovery identity envelope.');
    }
    final context = <String, Object?>{
      'account_id': accountId,
      'instance_id': instanceId,
      'server_space_id': serverSpaceId,
      'recovery_generation': generation,
    };
    sodium_api.SecureKey? wrappingKey;
    Uint8List? clear;
    Uint8List? ciphertext;
    Uint8List? nonce;
    try {
      wrappingKey = await _deriveKey(
        inputKey,
        purpose: purpose,
        context: context,
      );
      ciphertext = decodeBase64Url(envelope['ciphertext'] as String);
      nonce = decodeBase64Url(envelope['nonce'] as String);
      if (nonce.length != 24 ||
          (format == _recoveryProtocol && ciphertext.length != 528)) {
        throw const FormatException('Invalid Recovery envelope size.');
      }
      clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: wrappingKey,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson({'format': format, ...context})),
        ),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      const fields = {'f', 'a', 'i', 's', 'g', 'd', 'p', 'q', 'x', 'y'};
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.toSet().difference(fields).isNotEmpty ||
          decoded.length != fields.length ||
          decoded['f'] != _recoveryIdentityFormat ||
          decoded['a'] != accountId ||
          decoded['i'] != instanceId ||
          decoded['s'] != serverSpaceId ||
          decoded['g'] != generation ||
          decoded['d'] is! String ||
          decoded['p'] is! String ||
          decoded['q'] is! String ||
          decoded['x'] is! String ||
          decoded['y'] is! String) {
        throw const FormatException('Recovery identity context mismatch.');
      }
      final signingPublic = _decodeExact(
        decoded['p'],
        'signing public key',
        sodium.crypto.sign.publicKeyBytes,
      );
      final signingSeedBytes = _decodeExact(
        decoded['q'],
        'signing seed',
        sodium.crypto.sign.seedBytes,
      );
      final encryptionPublic = _decodeExact(
        decoded['x'],
        'encryption public key',
        sodium.crypto.box.publicKeyBytes,
      );
      final encryptionSeedBytes = _decodeExact(
        decoded['y'],
        'encryption seed',
        sodium.crypto.box.seedBytes,
      );
      final expectedDescriptorHash = await recoveryDescriptorHash(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
        signingPublicKey: encodeBase64Url(signingPublic),
        encryptionPublicKey: encodeBase64Url(encryptionPublic),
      );
      if (decoded['d'] != expectedDescriptorHash) {
        signingSeedBytes.fillRange(0, signingSeedBytes.length, 0);
        encryptionSeedBytes.fillRange(0, encryptionSeedBytes.length, 0);
        throw const FormatException(
          'Recovery identity descriptor hash mismatch.',
        );
      }
      final signingSeed = sodium.secureCopy(signingSeedBytes);
      final encryptionSeed = sodium.secureCopy(encryptionSeedBytes);
      signingSeedBytes.fillRange(0, signingSeedBytes.length, 0);
      encryptionSeedBytes.fillRange(0, encryptionSeedBytes.length, 0);
      final identity = RecoveryIdentity(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
        signing: sodium.crypto.sign.seedKeyPair(signingSeed),
        signingSeed: signingSeed,
        encryption: sodium.crypto.box.seedKeyPair(encryptionSeed),
        encryptionSeed: encryptionSeed,
      );
      if (!_sameBytes(identity.signing.publicKey, signingPublic) ||
          !_sameBytes(identity.encryption.publicKey, encryptionPublic)) {
        identity.dispose();
        throw const FormatException('Recovery identity public key mismatch.');
      }
      _verifyIdentityKeyPair(identity);
      return identity;
    } finally {
      wrappingKey?.dispose();
      ciphertext?.fillRange(0, ciphertext.length, 0);
      nonce?.fillRange(0, nonce.length, 0);
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<sodium_api.SecureKey> _deriveKey(
    sodium_api.SecureKey inputKey, {
    required String purpose,
    required Map<String, Object?> context,
  }) async {
    final input = inputKey.extractBytes();
    final info = Uint8List.fromList(
      utf8.encode(canonicalJson(['atermius', purpose, 1, context])),
    );
    try {
      final derived = await _hkdf.deriveKey(
        secretKey: crypto.SecretKey(input),
        nonce: Uint8List(32),
        info: info,
      );
      final bytes = await derived.extract();
      try {
        return sodium.secureCopy(Uint8List.fromList(bytes.bytes));
      } finally {
        bytes.destroy();
      }
    } finally {
      input.fillRange(0, input.length, 0);
      info.fillRange(0, info.length, 0);
      inputKey.dispose();
    }
  }

  Map<String, Object?> _identityContext(RecoveryIdentity identity) => {
    'account_id': identity.accountId,
    'instance_id': identity.instanceId,
    'server_space_id': identity.serverSpaceId,
    'recovery_generation': identity.generation,
  };

  Map<String, Object?> _identityAad(RecoveryIdentity identity, String format) =>
      {'format': format, ..._identityContext(identity)};

  void _verifyIdentityKeyPair(RecoveryIdentity identity) {
    final probe = randomBytes(32);
    Uint8List? sealed;
    Uint8List? opened;
    try {
      final publicFromSecret = sodium.crypto.sign.skToPk(
        identity.signing.secretKey,
      );
      if (!_sameBytes(publicFromSecret, identity.signing.publicKey)) {
        throw const FormatException('Recovery signing key pair is invalid.');
      }
      sealed = sodium.crypto.box.seal(
        message: probe,
        publicKey: identity.encryption.publicKey,
      );
      opened = sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: identity.encryption.publicKey,
        secretKey: identity.encryption.secretKey,
      );
      if (!_sameBytes(probe, opened)) {
        throw const FormatException('Recovery encryption key pair is invalid.');
      }
    } catch (_) {
      identity.dispose();
      rethrow;
    } finally {
      probe.fillRange(0, probe.length, 0);
      sealed?.fillRange(0, sealed.length, 0);
      opened?.fillRange(0, opened.length, 0);
    }
  }

  Uint8List _decodeCode(String value) {
    final bytes = decodeBase64Url(value);
    if (bytes.length != 32 || encodeBase64Url(bytes) != value) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException(
        'Recovery code must be canonical base64url for 32 random bytes.',
      );
    }
    return bytes;
  }

  Uint8List _decodeExact(Object? value, String label, int length) {
    if (value is! String) throw FormatException('Missing Recovery $label.');
    final bytes = decodeBase64Url(value);
    if (bytes.length != length || encodeBase64Url(bytes) != value) {
      bytes.fillRange(0, bytes.length, 0);
      throw FormatException('Invalid Recovery $label.');
    }
    return bytes;
  }

  Future<String> _sha256Hex(Uint8List bytes) async {
    try {
      final digest = await crypto.Sha256().hash(bytes);
      return digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  bool _sameBytes(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

String encodeBase64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List decodeBase64Url(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
