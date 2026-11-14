// Client-side cryptography for Credential visibility v1 (admin escrow).
//
// Trust model (also shown to users in the UI): in `admin_visible` mode the
// user's client seals its Vault keys to an instance escrow public key whose
// private half exists only in instance-admin clients (wrapped under each
// admin's account key, plus one recovery-code wrap). The server stores only
// ciphertext and verifies shapes and signatures. The account master password
// never leaves the client in either mode.
//
// Only vetted primitives are used: libsodium (crypto_box_seal, Ed25519,
// XChaCha20-Poly1305, Argon2id) and the existing HKDF purpose-key helper.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';

const credentialEscrowKeyFormat = 'atermius-credential-escrow-key-v1';
const credentialEscrowKeyCreationFormat =
    'atermius-credential-escrow-key-creation-v1';
const credentialEscrowSealFormat = 'atermius-credential-escrow-v1';
const credentialEscrowDepositFormat = 'atermius-credential-escrow-deposit-v1';
const credentialEscrowAccountWrapPurpose = 'credential-escrow-key-wrap';
const credentialEscrowAccountWrapContext = 'credential-escrow-key';
const credentialEscrowRecoveryContext = 'credential-escrow-recovery';

/// Upper bound for a decoded `sealed` deposit (48 bytes of seal overhead plus
/// a small canonical JSON plaintext). Matches the server's limit.
const credentialEscrowMaxSealedBytes = 1024;

/// Exact Argon2id parameters of the recovery-code wrap. Any other value is
/// rejected so a server cannot downgrade (or inflate) the KDF.
const credentialEscrowRecoveryKdfId = 'argon2id13';
const credentialEscrowRecoveryKdfMemoryKib = 65536;
const credentialEscrowRecoveryKdfIterations = 3;
const credentialEscrowRecoveryKdfParallelism = 1;

const _recoveryCodeBytes = 20;
const _recoveryCodeLength = 32;
const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const _uuid = Uuid();

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(hashing.sha256.convert(bytes).bytes);

final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isCanonicalEscrowUuid(String value) => _canonicalUuid.hasMatch(value);

/// Decodes canonical unpadded base64url of an exact or bounded length.
Uint8List decodeEscrowBase64(
  Object? value, {
  required String field,
  int? exactBytes,
  int? maxBytes,
}) {
  if (value is! String ||
      value.isEmpty ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value) ||
      value.length % 4 == 1) {
    throw FormatException('Credential escrow $field encoding is invalid');
  }
  if (maxBytes != null && value.length > (maxBytes * 4 + 2) ~/ 3) {
    throw FormatException('Credential escrow $field is too large');
  }
  final Uint8List decoded;
  try {
    decoded = decodeBase64Url(value);
  } on FormatException {
    throw FormatException('Credential escrow $field encoding is invalid');
  }
  if (encodeBase64Url(decoded) != value ||
      (exactBytes != null && decoded.length != exactBytes) ||
      (maxBytes != null && decoded.length > maxBytes)) {
    throw FormatException('Credential escrow $field size is invalid');
  }
  return decoded;
}

void _requireExactKeys(
  Map<dynamic, dynamic> value,
  Set<String> keys,
  String what,
) {
  if (value.keys.any((key) => key is! String) ||
      value.length != keys.length ||
      !keys.containsAll(value.keys.cast<String>())) {
    throw FormatException('$what fields are invalid');
  }
}

/// An escrow public key whose instance signature was verified against the
/// already pinned instance signing key. Deposits are only ever sealed to a
/// verified key.
class VerifiedEscrowKey {
  const VerifiedEscrowKey({
    required this.keyId,
    required this.publicKey,
    required this.createdAt,
  });

  final String keyId;
  final Uint8List publicKey;
  final String createdAt;

  String get publicKeyText => encodeBase64Url(publicKey);
}

/// Verifies a wire escrow key descriptor
/// `{key_id, public_key, signed_payload, signature, created_at}` exactly like
/// the gateway key: Ed25519 by the pinned instance key over the exact
/// signed_payload bytes, then format / instance / key binding.
VerifiedEscrowKey verifyEscrowKeyDescriptor(
  SodiumSumo sodium, {
  required Map<String, dynamic> descriptor,
  required String instanceId,
  required String pinnedInstanceSigningKey,
}) {
  final keyId = descriptor['key_id'];
  final publicKey = descriptor['public_key'];
  final signedPayload = descriptor['signed_payload'];
  final signature = descriptor['signature'];
  if (keyId is! String ||
      publicKey is! String ||
      signedPayload is! String ||
      signature is! String ||
      pinnedInstanceSigningKey.isEmpty) {
    throw const FormatException('Credential escrow key is malformed');
  }
  final signatureBytes = decodeEscrowBase64(
    signature,
    field: 'key signature',
    exactBytes: 64,
  );
  final pinned = decodeEscrowBase64(
    pinnedInstanceSigningKey,
    field: 'instance key',
    exactBytes: 32,
  );
  final ok = sodium.crypto.sign.verifyDetached(
    message: _utf8(signedPayload),
    signature: signatureBytes,
    publicKey: pinned,
  );
  if (!ok) {
    throw const FormatException(
      'Credential escrow key is not signed by this server',
    );
  }
  final Object? payload;
  try {
    payload = jsonDecode(signedPayload);
  } on FormatException {
    throw const FormatException('Credential escrow key payload is invalid');
  }
  if (payload is! Map ||
      payload['format'] != credentialEscrowKeyFormat ||
      payload['instance_id'] != instanceId ||
      payload['key_id'] != keyId ||
      payload['public_key'] != publicKey ||
      payload['created_at'] is! String) {
    throw const FormatException('Credential escrow key binding does not match');
  }
  _requireExactKeys(payload, const {
    'format',
    'instance_id',
    'key_id',
    'public_key',
    'created_at',
  }, 'Credential escrow key payload');
  final bytes = decodeEscrowBase64(
    publicKey,
    field: 'public key',
    exactBytes: 32,
  );
  return VerifiedEscrowKey(
    keyId: keyId,
    publicKey: bytes,
    createdAt: payload['created_at'] as String,
  );
}

/// A freshly generated escrow X25519 key pair. The secret key lives only in
/// libsodium secure memory; call [dispose] as soon as it was wrapped.
class GeneratedEscrowKey {
  GeneratedEscrowKey._(this.keyId, this.keyPair);

  factory GeneratedEscrowKey.generate(SodiumSumo sodium) =>
      GeneratedEscrowKey._(_uuid.v4(), sodium.crypto.box.keyPair());

  final String keyId;
  final KeyPair keyPair;

  String get publicKeyText => encodeBase64Url(keyPair.publicKey);

  void dispose() => keyPair.dispose();
}

/// Admin device Ed25519 signature that binds a new escrow key to the creating
/// account and device. The server verifies it with the caller device key.
String signEscrowKeyCreation(
  SodiumSumo sodium, {
  required DeviceIdentity identity,
  required String instanceId,
  required String accountId,
  required String keyId,
  required String publicKey,
}) {
  final payload = canonicalJson({
    'format': credentialEscrowKeyCreationFormat,
    'instance_id': instanceId,
    'key_id': keyId,
    'public_key': publicKey,
    'account_id': accountId,
    'device_id': identity.deviceId,
  });
  return encodeBase64Url(
    sodium.crypto.sign.detached(
      message: _utf8(payload),
      secretKey: identity.signing.secretKey,
    ),
  );
}

// Account wrap ---------------------------------------------------------------

Uint8List _accountWrapAad({
  required String instanceId,
  required String keyId,
  required String accountId,
}) => _utf8(
  canonicalJson({
    'context': credentialEscrowAccountWrapContext,
    'version': 1,
    'instance_id': instanceId,
    'key_id': keyId,
    'account_id': accountId,
  }),
);

Future<SecureKey> _accountWrapKey(
  VaultCrypto crypto, {
  required Uint8List accountKey,
  required String keyId,
}) async {
  if (accountKey.length != 32) {
    throw const FormatException('Invalid account key length');
  }
  final input = crypto.sodium.secureCopy(accountKey);
  Uint8List? derived;
  try {
    derived = await crypto.derivePurposeKey(
      inputKey: input,
      purpose: credentialEscrowAccountWrapPurpose,
      context: {'version': 1, 'key_id': keyId},
    );
    return crypto.sodium.secureCopy(derived);
  } finally {
    input.dispose();
    derived?.fillRange(0, derived.length, 0);
  }
}

/// Validates the `{version, nonce, ciphertext}` account wrap shape.
void validateEscrowAccountWrap(Map<String, dynamic> wrap) {
  _requireExactKeys(wrap, const {
    'version',
    'nonce',
    'ciphertext',
  }, 'Credential escrow account wrap');
  if (wrap['version'] != 1) {
    throw const FormatException('Unsupported credential escrow account wrap');
  }
  decodeEscrowBase64(wrap['nonce'], field: 'wrap nonce', exactBytes: 24);
  decodeEscrowBase64(wrap['ciphertext'], field: 'wrap', exactBytes: 48);
}

/// Wraps the 32-byte escrow secret key under the admin's account key.
Future<Map<String, Object?>> wrapEscrowSecretKeyForAccount(
  VaultCrypto crypto, {
  required Uint8List accountKey,
  required SecureKey secretKey,
  required String instanceId,
  required String keyId,
  required String accountId,
}) async {
  final sodium = crypto.sodium;
  final key = await _accountWrapKey(
    crypto,
    accountKey: accountKey,
    keyId: keyId,
  );
  final secret = secretKey.extractBytes();
  try {
    if (secret.length != 32) {
      throw const FormatException('Invalid escrow secret key length');
    }
    final nonce = sodium.randombytes.buf(24);
    final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: secret,
      nonce: nonce,
      key: key,
      additionalData: _accountWrapAad(
        instanceId: instanceId,
        keyId: keyId,
        accountId: accountId,
      ),
    );
    return {
      'version': 1,
      'nonce': encodeBase64Url(nonce),
      'ciphertext': encodeBase64Url(ciphertext),
    };
  } finally {
    secret.fillRange(0, secret.length, 0);
    key.dispose();
  }
}

/// Opens an account wrap. Throws if the account key, account, instance or
/// key id does not match (AEAD authentication failure).
Future<SecureKey> unwrapEscrowSecretKeyForAccount(
  VaultCrypto crypto, {
  required Uint8List accountKey,
  required Map<String, dynamic> wrap,
  required String instanceId,
  required String keyId,
  required String accountId,
}) async {
  validateEscrowAccountWrap(wrap);
  final sodium = crypto.sodium;
  final key = await _accountWrapKey(
    crypto,
    accountKey: accountKey,
    keyId: keyId,
  );
  Uint8List? clear;
  try {
    try {
      clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: decodeBase64Url(wrap['ciphertext'] as String),
        nonce: decodeBase64Url(wrap['nonce'] as String),
        key: key,
        additionalData: _accountWrapAad(
          instanceId: instanceId,
          keyId: keyId,
          accountId: accountId,
        ),
      );
    } on SodiumException {
      throw const FormatException(
        'Credential escrow account wrap could not be opened',
      );
    }
    if (clear.length != 32) {
      throw const FormatException('Invalid escrow secret key length');
    }
    return sodium.secureCopy(clear);
  } finally {
    clear?.fillRange(0, clear.length, 0);
    key.dispose();
  }
}

/// Returns true if [secretKey] is the X25519 secret of [key]'s public key.
bool escrowSecretKeyMatches(
  SodiumSumo sodium, {
  required VerifiedEscrowKey key,
  required SecureKey secretKey,
}) {
  final derived = sodium.crypto.scalarmult.base(n: secretKey);
  if (derived.length != key.publicKey.length) return false;
  var difference = 0;
  for (var i = 0; i < derived.length; i++) {
    difference |= derived[i] ^ key.publicKey[i];
  }
  return difference == 0;
}

// Recovery code --------------------------------------------------------------

String _base32Encode(Uint8List bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_base32Alphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List _base32Decode(String text) {
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in text.split('')) {
    final value = _base32Alphabet.indexOf(char);
    if (value < 0) throw const FormatException('Invalid recovery code');
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
    buffer &= (1 << bits) - 1;
  }
  return Uint8List.fromList(out);
}

/// A one-time escrow recovery code: 20 random bytes as uppercase RFC 4648
/// Base32 without padding (32 characters).
class EscrowRecoveryCode {
  EscrowRecoveryCode._(this.normalized);

  factory EscrowRecoveryCode.generate(SodiumSumo sodium) {
    final bytes = sodium.randombytes.buf(_recoveryCodeBytes);
    try {
      return EscrowRecoveryCode._(_base32Encode(bytes));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Accepts the displayed form with any `-`/whitespace and any case.
  /// Throws [FormatException] unless it is exactly 32 Base32 characters that
  /// encode 20 bytes canonically.
  factory EscrowRecoveryCode.parse(String input) {
    final normalized = normalizeEscrowRecoveryCode(input);
    if (normalized.length != _recoveryCodeLength ||
        !RegExp(r'^[A-Z2-7]+$').hasMatch(normalized)) {
      throw const FormatException('Invalid recovery code');
    }
    final decoded = _base32Decode(normalized);
    final canonical =
        decoded.length == _recoveryCodeBytes &&
        _base32Encode(decoded) == normalized;
    decoded.fillRange(0, decoded.length, 0);
    if (!canonical) throw const FormatException('Invalid recovery code');
    return EscrowRecoveryCode._(normalized);
  }

  /// 32 uppercase Base32 characters; the Argon2id password input.
  final String normalized;

  /// 8 groups of 4 joined by `-` for display.
  String get display => formatEscrowRecoveryCode(normalized);
}

String normalizeEscrowRecoveryCode(String input) =>
    input.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

String formatEscrowRecoveryCode(String normalized) => [
  for (var i = 0; i < normalized.length; i += 4)
    normalized.substring(
      i,
      i + 4 > normalized.length ? normalized.length : i + 4,
    ),
].join('-');

Uint8List _recoveryAad({required String instanceId, required String keyId}) =>
    _utf8(
      canonicalJson({
        'context': credentialEscrowRecoveryContext,
        'version': 1,
        'instance_id': instanceId,
        'key_id': keyId,
      }),
    );

SecureKey _recoveryWrapKey(
  VaultCrypto crypto,
  EscrowRecoveryCode code,
  Uint8List salt,
) => crypto.derivePasswordKey(
  code.normalized,
  KdfParameters(
    salt: salt,
    memoryKib: credentialEscrowRecoveryKdfMemoryKib,
    iterations: credentialEscrowRecoveryKdfIterations,
    parallelism: credentialEscrowRecoveryKdfParallelism,
  ),
);

/// Validates the recovery wrap shape and its exact KDF parameters; returns
/// the decoded salt.
Uint8List validateEscrowRecoveryWrap(Map<String, dynamic> wrap) {
  _requireExactKeys(wrap, const {
    'version',
    'kdf',
    'nonce',
    'ciphertext',
  }, 'Credential escrow recovery wrap');
  final kdf = wrap['kdf'];
  if (wrap['version'] != 1 || kdf is! Map) {
    throw const FormatException('Unsupported credential escrow recovery wrap');
  }
  _requireExactKeys(kdf, const {
    'id',
    'salt',
    'mem_kib',
    'iterations',
    'parallelism',
  }, 'Credential escrow recovery KDF');
  if (kdf['id'] != credentialEscrowRecoveryKdfId ||
      kdf['mem_kib'] != credentialEscrowRecoveryKdfMemoryKib ||
      kdf['iterations'] != credentialEscrowRecoveryKdfIterations ||
      kdf['parallelism'] != credentialEscrowRecoveryKdfParallelism) {
    throw const FormatException('Unsupported credential escrow recovery KDF');
  }
  decodeEscrowBase64(wrap['nonce'], field: 'recovery nonce', exactBytes: 24);
  decodeEscrowBase64(
    wrap['ciphertext'],
    field: 'recovery wrap',
    exactBytes: 48,
  );
  return decodeEscrowBase64(
    kdf['salt'],
    field: 'recovery salt',
    exactBytes: 16,
  );
}

/// Wraps the escrow secret key under an Argon2id key derived from [code].
Map<String, Object?> wrapEscrowSecretKeyForRecovery(
  VaultCrypto crypto, {
  required EscrowRecoveryCode code,
  required SecureKey secretKey,
  required String instanceId,
  required String keyId,
}) {
  final sodium = crypto.sodium;
  final salt = sodium.randombytes.buf(16);
  final key = _recoveryWrapKey(crypto, code, salt);
  final secret = secretKey.extractBytes();
  try {
    if (secret.length != 32) {
      throw const FormatException('Invalid escrow secret key length');
    }
    final nonce = sodium.randombytes.buf(24);
    final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: secret,
      nonce: nonce,
      key: key,
      additionalData: _recoveryAad(instanceId: instanceId, keyId: keyId),
    );
    return {
      'version': 1,
      'kdf': {
        'id': credentialEscrowRecoveryKdfId,
        'salt': encodeBase64Url(salt),
        'mem_kib': credentialEscrowRecoveryKdfMemoryKib,
        'iterations': credentialEscrowRecoveryKdfIterations,
        'parallelism': credentialEscrowRecoveryKdfParallelism,
      },
      'nonce': encodeBase64Url(nonce),
      'ciphertext': encodeBase64Url(ciphertext),
    };
  } finally {
    secret.fillRange(0, secret.length, 0);
    key.dispose();
  }
}

/// Opens the recovery wrap with [code]. Throws [FormatException] for a wrong
/// code or a wrap bound to another instance/key.
SecureKey unwrapEscrowSecretKeyWithRecoveryCode(
  VaultCrypto crypto, {
  required EscrowRecoveryCode code,
  required Map<String, dynamic> wrap,
  required String instanceId,
  required String keyId,
}) {
  final salt = validateEscrowRecoveryWrap(wrap);
  final sodium = crypto.sodium;
  final key = _recoveryWrapKey(crypto, code, salt);
  Uint8List? clear;
  try {
    try {
      clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: decodeBase64Url(wrap['ciphertext'] as String),
        nonce: decodeBase64Url(wrap['nonce'] as String),
        key: key,
        additionalData: _recoveryAad(instanceId: instanceId, keyId: keyId),
      );
    } on SodiumException {
      throw const FormatException('The recovery code is not correct');
    }
    if (clear.length != 32) {
      throw const FormatException('Invalid escrow secret key length');
    }
    return sodium.secureCopy(clear);
  } finally {
    clear?.fillRange(0, clear.length, 0);
    key.dispose();
  }
}

// Deposits -------------------------------------------------------------------

/// Picks this device's Vault key for [keyEpoch] out of [keysByVersion], the
/// per-Vault map AppController keeps (`'<epoch>:<membership version>'` →
/// key). Returns a private copy only when at least one version of exactly
/// that epoch is held and every held version is the same 32-byte key (one
/// epoch never has two keys; disagreeing copies mean local state is not
/// trustworthy, so nothing is escrowed). The caller zeroes the copy.
Uint8List? selectEscrowVaultKey(
  Map<String, Uint8List> keysByVersion,
  int keyEpoch,
) {
  final epoch = '$keyEpoch';
  final candidates = [
    for (final entry in keysByVersion.entries)
      if (entry.key.split(':').first == epoch) entry.value,
  ];
  if (candidates.isEmpty) return null;
  final first = candidates.first;
  var mismatch = 0;
  for (final candidate in candidates) {
    if (candidate.length != 32) return null;
    for (var i = 0; i < 32; i++) {
      mismatch |= candidate[i] ^ first[i];
    }
  }
  return mismatch == 0 ? Uint8List.fromList(first) : null;
}

String _depositSignedPayload({
  required String instanceId,
  required String keyId,
  required String vaultId,
  required int keyEpoch,
  required Uint8List sealed,
}) => canonicalJson({
  'format': credentialEscrowDepositFormat,
  'instance_id': instanceId,
  'key_id': keyId,
  'vault_id': vaultId,
  'key_epoch': keyEpoch,
  'sealed_sha256': encodeBase64Url(_sha256(sealed)),
});

/// Builds the `PUT …/escrow/{vault_id}/{key_epoch}` body
/// `{key_id, sealed, signature}`. [key] must come from
/// [verifyEscrowKeyDescriptor]; the vault key is never sealed to anything
/// else.
Map<String, Object?> buildEscrowDeposit(
  SodiumSumo sodium, {
  required VerifiedEscrowKey key,
  required DeviceIdentity identity,
  required String instanceId,
  required String vaultId,
  required int keyEpoch,
  required Uint8List vaultKey,
}) {
  if (vaultKey.length != 32) {
    throw const FormatException('Invalid vault key length');
  }
  if (keyEpoch < 1) throw const FormatException('Invalid key epoch');
  final encodedKey = encodeBase64Url(vaultKey);
  final plaintext = _utf8(
    canonicalJson({
      'format': credentialEscrowSealFormat,
      'instance_id': instanceId,
      'key_id': key.keyId,
      'vault_id': vaultId,
      'key_epoch': keyEpoch,
      'vault_key': encodedKey,
    }),
  );
  final Uint8List sealed;
  try {
    sealed = sodium.crypto.box.seal(
      message: plaintext,
      publicKey: key.publicKey,
    );
  } finally {
    plaintext.fillRange(0, plaintext.length, 0);
  }
  if (sealed.length > credentialEscrowMaxSealedBytes) {
    throw const FormatException('Credential escrow deposit is too large');
  }
  final signature = sodium.crypto.sign.detached(
    message: _utf8(
      _depositSignedPayload(
        instanceId: instanceId,
        keyId: key.keyId,
        vaultId: vaultId,
        keyEpoch: keyEpoch,
        sealed: sealed,
      ),
    ),
    secretKey: identity.signing.secretKey,
  );
  return {
    'key_id': key.keyId,
    'sealed': encodeBase64Url(sealed),
    'signature': encodeBase64Url(signature),
  };
}

/// Admin side: verifies the depositor device signature, opens the seal with
/// the escrow secret key and checks every inner field. Returns the 32-byte
/// Vault key; the caller zeroes it when done.
Uint8List openEscrowDeposit(
  SodiumSumo sodium, {
  required VerifiedEscrowKey key,
  required SecureKey secretKey,
  required String instanceId,
  required String vaultId,
  required int keyEpoch,
  required String sealed,
  required String signature,
  required String depositorSigningPublicKey,
}) {
  final sealedBytes = decodeEscrowBase64(
    sealed,
    field: 'sealed',
    maxBytes: credentialEscrowMaxSealedBytes,
  );
  final signatureBytes = decodeEscrowBase64(
    signature,
    field: 'deposit signature',
    exactBytes: 64,
  );
  final depositor = decodeEscrowBase64(
    depositorSigningPublicKey,
    field: 'depositor key',
    exactBytes: 32,
  );
  final verified = sodium.crypto.sign.verifyDetached(
    message: _utf8(
      _depositSignedPayload(
        instanceId: instanceId,
        keyId: key.keyId,
        vaultId: vaultId,
        keyEpoch: keyEpoch,
        sealed: sealedBytes,
      ),
    ),
    signature: signatureBytes,
    publicKey: depositor,
  );
  if (!verified) {
    throw const FormatException(
      'Credential escrow deposit signature is invalid',
    );
  }
  Uint8List? opened;
  try {
    try {
      opened = sodium.crypto.box.sealOpen(
        cipherText: sealedBytes,
        publicKey: key.publicKey,
        secretKey: secretKey,
      );
    } on SodiumException {
      throw const FormatException(
        'Credential escrow deposit could not be opened',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(opened));
    } on FormatException {
      throw const FormatException('Credential escrow deposit is malformed');
    }
    if (decoded is! Map) {
      throw const FormatException('Credential escrow deposit is malformed');
    }
    _requireExactKeys(decoded, const {
      'format',
      'instance_id',
      'key_id',
      'vault_id',
      'key_epoch',
      'vault_key',
    }, 'Credential escrow deposit');
    if (decoded['format'] != credentialEscrowSealFormat ||
        decoded['instance_id'] != instanceId ||
        decoded['key_id'] != key.keyId ||
        decoded['vault_id'] != vaultId ||
        decoded['key_epoch'] != keyEpoch) {
      throw const FormatException(
        'Credential escrow deposit context does not match',
      );
    }
    return decodeEscrowBase64(
      decoded['vault_key'],
      field: 'vault key',
      exactBytes: 32,
    );
  } finally {
    opened?.fillRange(0, opened.length, 0);
  }
}
