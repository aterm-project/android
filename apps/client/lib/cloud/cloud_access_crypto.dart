// Client-side cryptography for cloud access (organizations, Host sharing and
// temporary links). Only vetted primitives are used: libsodium (sodium
// package) for crypto_box_seal, Ed25519 and XChaCha20-Poly1305, and the
// `cryptography` package for HKDF-SHA256.
//
// Trust model (also shown to owners in the UI): a temporary link lets guests
// connect through this server's trusted gateway. The Host login is sealed to
// the gateway key, which the server operator controls; this is NOT
// end-to-end encryption for guests.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:sodium/sodium_sumo.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';

const shareFragmentPrefix = 's1.';
const orgJoinFragmentPrefix = 'o1.';
const capsuleFormat = 'atermius-gateway-capsule-v1';
const capsuleInnerFormat = 'atermius-gateway-capsule-inner-v1';
const gatewayKeyFormat = 'atermius-share-gateway-key-v1';
const displayEnvelopeFormat = 'atermius-share-display-v1';

final _hkdf = cryptography.Hkdf(
  hmac: cryptography.Hmac.sha256(),
  outputLength: 32,
);

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

/// 32 random bytes that exist only in the link fragment and the creator's
/// memory/clipboard. The server only ever sees the derived redeem token.
class ShareLinkSecret {
  ShareLinkSecret._(this.bytes);

  factory ShareLinkSecret.random(SodiumSumo sodium) =>
      ShareLinkSecret._(sodium.randombytes.buf(32));

  /// Parses `s1.<base64url(32 bytes)>`; returns null for anything else.
  static ShareLinkSecret? fromFragment(String? fragment) {
    if (fragment == null || !fragment.startsWith(shareFragmentPrefix)) {
      return null;
    }
    final encoded = fragment.substring(shareFragmentPrefix.length);
    if (encoded.length != 43) return null;
    try {
      final bytes = decodeBase64Url(encoded);
      if (bytes.length != 32 || encodeBase64Url(bytes) != encoded) return null;
      return ShareLinkSecret._(bytes);
    } on FormatException {
      return null;
    }
  }

  final Uint8List bytes;

  String get fragment => '$shareFragmentPrefix${encodeBase64Url(bytes)}';

  Future<String> redeemToken() async {
    final key = await _hkdf.deriveKey(
      secretKey: cryptography.SecretKey(bytes),
      nonce: const <int>[],
      info: _utf8(canonicalJson(['atermius', 'share-link-redeem', 1])),
    );
    return encodeBase64Url(await key.extractBytes());
  }

  Future<Uint8List> displayKey(String linkId, int secretVersion) async {
    final key = await _hkdf.deriveKey(
      secretKey: cryptography.SecretKey(bytes),
      nonce: _utf8(linkId),
      info: _utf8(
        canonicalJson([
          'atermius',
          'share-link-display',
          1,
          linkId,
          secretVersion,
        ]),
      ),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  void wipe() => bytes.fillRange(0, bytes.length, 0);
}

/// Owner-chosen labels visible to guests after redemption; opaque to the
/// server (encrypted with a key derived from the fragment secret).
class ShareDisplay {
  const ShareDisplay({required this.title, required this.targets});

  final String title;

  /// target_id → label shown to the guest.
  final Map<String, String> targets;

  Map<String, Object?> toJson() => {
    'title': title,
    'targets': [
      for (final entry in targets.entries)
        {'target_id': entry.key, 'label': entry.value},
    ],
  };

  static ShareDisplay fromJson(Object? value) {
    if (value is! Map ||
        value['title'] is! String ||
        value['targets'] is! List) {
      throw const FormatException('Invalid share display envelope');
    }
    final targets = <String, String>{};
    for (final item in value['targets'] as List) {
      if (item is! Map ||
          item['target_id'] is! String ||
          item['label'] is! String) {
        throw const FormatException('Invalid share display target');
      }
      targets[item['target_id'] as String] = item['label'] as String;
    }
    return ShareDisplay(title: value['title'] as String, targets: targets);
  }
}

Uint8List _displayAad(String linkId, int secretVersion) => _utf8(
  canonicalJson({
    'format': displayEnvelopeFormat,
    'link_id': linkId,
    'secret_version': secretVersion,
  }),
);

String sealShareDisplay(
  SodiumSumo sodium,
  Uint8List key,
  String linkId,
  int secretVersion,
  ShareDisplay display,
) {
  final nonce = sodium.randombytes.buf(24);
  final secure = sodium.secureCopy(key);
  try {
    final sealed = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: _utf8(canonicalJson(display.toJson())),
      nonce: nonce,
      key: secure,
      additionalData: _displayAad(linkId, secretVersion),
    );
    return 'v1.${encodeBase64Url(nonce)}.${encodeBase64Url(sealed)}';
  } finally {
    secure.dispose();
  }
}

ShareDisplay openShareDisplay(
  SodiumSumo sodium,
  Uint8List key,
  String linkId,
  int secretVersion,
  String envelope,
) {
  final parts = envelope.split('.');
  if (parts.length != 3 || parts.first != 'v1') {
    throw const FormatException('Unsupported share display envelope');
  }
  final secure = sodium.secureCopy(key);
  try {
    final plain = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: decodeBase64Url(parts[2]),
      nonce: decodeBase64Url(parts[1]),
      key: secure,
      additionalData: _displayAad(linkId, secretVersion),
    );
    return ShareDisplay.fromJson(jsonDecode(utf8.decode(plain)));
  } finally {
    secure.dispose();
  }
}

/// A gateway public key whose instance signature was verified against the
/// already pinned instance signing key.
class VerifiedGatewayKey {
  const VerifiedGatewayKey({required this.keyId, required this.publicKey});
  final String keyId;
  final Uint8List publicKey;
}

VerifiedGatewayKey verifyGatewayKey(
  SodiumSumo sodium, {
  required Map<String, dynamic> key,
  required String instanceId,
  required String pinnedInstanceSigningKey,
}) {
  final signedPayload = key['signed_payload'];
  final signature = key['signature'];
  final keyId = key['key_id'];
  final publicKey = key['public_key'];
  if (signedPayload is! String ||
      signature is! String ||
      keyId is! String ||
      publicKey is! String) {
    throw const FormatException('Gateway key response is malformed');
  }
  final ok = sodium.crypto.sign.verifyDetached(
    message: _utf8(signedPayload),
    signature: decodeBase64Url(signature),
    publicKey: decodeBase64Url(pinnedInstanceSigningKey),
  );
  if (!ok) {
    throw const FormatException('Gateway key is not signed by this server');
  }
  final payload = jsonDecode(signedPayload);
  if (payload is! Map ||
      payload['format'] != gatewayKeyFormat ||
      payload['instance_id'] != instanceId ||
      payload['key_id'] != keyId ||
      payload['public_key'] != publicKey) {
    throw const FormatException('Gateway key binding does not match');
  }
  final bytes = decodeBase64Url(publicKey);
  if (bytes.length != 32) {
    throw const FormatException('Gateway key has an invalid size');
  }
  return VerifiedGatewayKey(keyId: keyId, publicKey: bytes);
}

/// Login material for one Host, taken from the Host's own inline login.
class CapsuleLogin {
  const CapsuleLogin({
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
  });
  final String username;
  final String? password;
  final String? privateKey;
  final String? passphrase;
}

/// Builds `{header, sealed}` for `PUT …/gateway-capsule`.
Map<String, Object?> buildSealedCapsule(
  SodiumSumo sodium, {
  required VerifiedGatewayKey gateway,
  required DeviceIdentity identity,
  required String accountId,
  required String vaultId,
  required String hostRecordId,
  required String hostRevisionId,
  required String protocol,
  required String targetHost,
  required int targetPort,
  required String? hostIdentity,
  String? sshHostKeyAlgorithm,
  String? rdpSecurity,
  String? displayMode,
  int? displayWidth,
  int? displayHeight,
  required CapsuleLogin login,
  DateTime? now,
}) {
  final inner = <String, Object?>{
    'format': capsuleInnerFormat,
    'vault_id': vaultId,
    'host_record_id': hostRecordId,
    'host_revision_id': hostRevisionId,
    'gateway_key_id': gateway.keyId,
    'record_kind': 'host',
    'protocol': protocol,
    'target_host': targetHost,
    'target_port': targetPort,
    'username': login.username,
    'password': ?login.password,
    'private_key': ?login.privateKey,
    'passphrase': ?login.passphrase,
    'host_identity': hostIdentity,
    'ssh_host_key_algorithm': ?sshHostKeyAlgorithm,
    'rdp_security': ?rdpSecurity,
    'display_mode': ?displayMode,
    'display_width': ?displayWidth,
    'display_height': ?displayHeight,
  };
  final plaintext = _utf8(canonicalJson(inner));
  final Uint8List sealed;
  try {
    sealed = sodium.crypto.box.seal(
      message: plaintext,
      publicKey: gateway.publicKey,
    );
  } finally {
    plaintext.fillRange(0, plaintext.length, 0);
  }
  final sealedSha256 = encodeBase64Url(_sha256(sealed));
  final header = <String, Object?>{
    'format': capsuleFormat,
    'vault_id': vaultId,
    'host_record_id': hostRecordId,
    'host_revision_id': hostRevisionId,
    'gateway_key_id': gateway.keyId,
    'protocol': protocol,
    'target_host': targetHost,
    'target_port': targetPort,
    'host_identity': hostIdentity,
    'sealed_sha256': sealedSha256,
    'sealer_user_id': accountId,
    'sealer_device_id': identity.deviceId,
    'created_at': _rfc3339(now ?? DateTime.now()),
  };
  final signature = sodium.crypto.sign.detached(
    message: _utf8(canonicalJson(header)),
    secretKey: identity.signing.secretKey,
  );
  return {
    'header': {...header, 'signature': encodeBase64Url(signature)},
    'sealed': encodeBase64Url(sealed),
  };
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(hashing.sha256.convert(bytes).bytes);

String _rfc3339(DateTime value) {
  final utc = value.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

/// Seals a Vault invitation token to one recipient device key.
String sealTokenForDevice(
  SodiumSumo sodium,
  String token,
  Uint8List recipientEncryptionKey,
) => encodeBase64Url(
  sodium.crypto.box.seal(
    message: _utf8(token),
    publicKey: recipientEncryptionKey,
  ),
);

String openSealedToken(
  SodiumSumo sodium,
  String sealed,
  DeviceIdentity identity,
) => utf8.decode(
  sodium.crypto.box.sealOpen(
    cipherText: decodeBase64Url(sealed),
    publicKey: identity.encryption.publicKey,
    secretKey: identity.encryption.secretKey,
  ),
);

/// Short human-comparable fingerprint of a device encryption key.
String deviceKeyFingerprint(Uint8List encryptionPublicKey) {
  final hex = _sha256(encryptionPublicKey)
      .take(10)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
      .join(' ')
      .toUpperCase();
}
