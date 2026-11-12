/// Field-level envelope detection and NaCl secretbox (`XSalsa20-Poly1305`)
/// decryption for local Termius Desktop vaults.
///
/// Format:
///   `base64( 0x04 0x01 | nonce[24] | XSalsa20-Poly1305(ciphertext + MAC[16]) )`
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart' as sodium_api;

/// Known 2-byte version header prepended to every encrypted Termius field.
const List<int> termiusVaultKnownHeader = [0x04, 0x01];

const int termiusVaultNonceBytes = 24;
const int termiusVaultMacBytes = 16;
const int termiusVaultKeyBytes = 32;
const int termiusVaultMinEnvelopeBytes =
    2 + termiusVaultNonceBytes + termiusVaultMacBytes;

class TermiusUnknownCipherVersionException implements Exception {
  const TermiusUnknownCipherVersionException(this.headerHex);

  final String headerHex;

  @override
  String toString() =>
      'TermiusUnknownCipherVersionException(header: $headerHex)';
}

class TermiusVaultDecryptionException implements Exception {
  const TermiusVaultDecryptionException(this.reason);

  final String reason;

  @override
  String toString() => 'TermiusVaultDecryptionException($reason)';
}

/// Decodes [value] when it can be a base64 cipher envelope by length alone.
Uint8List? decodeTermiusEnvelopeCandidate(Object? value) {
  if (value is! String || value.length < 24 || value.length % 4 != 0) {
    return null;
  }
  // Reject non-base64 characters up front so arbitrary text never allocates.
  if (!RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(value)) {
    return null;
  }
  try {
    final decoded = base64.decode(value);
    return decoded.length >= termiusVaultMinEnvelopeBytes ? decoded : null;
  } on FormatException {
    return null;
  }
}

bool hasKnownTermiusVaultHeader(Uint8List raw) =>
    raw.length >= 2 &&
    raw[0] == termiusVaultKnownHeader[0] &&
    raw[1] == termiusVaultKnownHeader[1];

/// True when [value] is a known `0x04 0x01` encrypted Termius field.
bool isTermiusEncryptedEnvelope(Object? value) {
  final raw = decodeTermiusEnvelopeCandidate(value);
  return raw != null && hasKnownTermiusVaultHeader(raw);
}

bool _isPlausibleUnknownEnvelope(Uint8List raw) =>
    raw.length >= termiusVaultMinEnvelopeBytes &&
    raw.length <= termiusVaultMinEnvelopeBytes + 8192;

/// Finds one `0x04 0x01` ciphertext anywhere in [node] so candidate keyring
/// entries can be verified against Poly1305 before decrypting the full store.
String? firstTermiusCiphertext(Object? node) {
  if (node is String) {
    return isTermiusEncryptedEnvelope(node) ? node : null;
  }
  if (node is Map) {
    for (final value in node.values) {
      final found = firstTermiusCiphertext(value);
      if (found != null) return found;
    }
    return null;
  }
  if (node is Iterable) {
    for (final item in node) {
      final found = firstTermiusCiphertext(item);
      if (found != null) return found;
    }
  }
  return null;
}

/// Decrypts Termius field-level `0x04 0x01` secretbox envelopes in memory.
class TermiusVaultDecryptor {
  TermiusVaultDecryptor(
    this._sodium,
    Uint8List rawKey, {
    this.strict = true,
  }) {
    if (rawKey.length != termiusVaultKeyBytes) {
      throw ArgumentError.value(
        rawKey.length,
        'rawKey.length',
        'Termius localKey must decode to $termiusVaultKeyBytes bytes',
      );
    }
    _key = _sodium.secureCopy(rawKey);
  }

  factory TermiusVaultDecryptor.fromBase64(
    sodium_api.Sodium sodium,
    String base64Key, {
    bool strict = true,
  }) {
    final decoded = Uint8List.fromList(base64.decode(base64Key.trim()));
    try {
      return TermiusVaultDecryptor(sodium, decoded, strict: strict);
    } finally {
      decoded.fillRange(0, decoded.length, 0);
    }
  }

  final sodium_api.Sodium _sodium;
  late final sodium_api.SecureKey _key;
  final bool strict;

  int decryptedFields = 0;
  int plainFields = 0;
  int failedFields = 0;

  void dispose() {
    _key.dispose();
  }

  /// Verifies that [_key] authenticates [envelope] with Poly1305.
  bool canDecryptEnvelope(String envelope) {
    final raw = decodeTermiusEnvelopeCandidate(envelope);
    if (raw == null || !hasKnownTermiusVaultHeader(raw)) return false;
    final nonce = Uint8List.sublistView(raw, 2, 2 + termiusVaultNonceBytes);
    final cipherWithMac = Uint8List.sublistView(raw, 2 + termiusVaultNonceBytes);
    Uint8List? plain;
    try {
      plain = _sodium.crypto.secretBox.openEasy(
        cipherText: cipherWithMac,
        nonce: nonce,
        key: _key,
      );
      return true;
    } on Object {
      return false;
    } finally {
      plain?.fillRange(0, plain.length, 0);
    }
  }

  /// Decrypts a single field; non-strings and unencrypted strings are unchanged.
  Object? decryptField(Object? value) {
    if (value is! String) return value;
    final raw = decodeTermiusEnvelopeCandidate(value);
    if (raw == null) {
      plainFields++;
      return value;
    }
    if (!hasKnownTermiusVaultHeader(raw)) {
      if (strict && _isPlausibleUnknownEnvelope(raw)) {
        final hex =
            '${raw[0].toRadixString(16).padLeft(2, '0')}'
            '${raw[1].toRadixString(16).padLeft(2, '0')}';
        throw TermiusUnknownCipherVersionException(hex);
      }
      plainFields++;
      return value;
    }

    final nonce = Uint8List.sublistView(raw, 2, 2 + termiusVaultNonceBytes);
    final cipherWithMac = Uint8List.sublistView(raw, 2 + termiusVaultNonceBytes);
    Uint8List? plain;
    try {
      plain = _sodium.crypto.secretBox.openEasy(
        cipherText: cipherWithMac,
        nonce: nonce,
        key: _key,
      );
      decryptedFields++;
      // Empty string ("") is a valid decrypted plaintext and must never be
      // treated as a decryption failure.
      return utf8.decode(plain, allowMalformed: true);
    } on Object {
      failedFields++;
      if (strict) {
        throw const TermiusVaultDecryptionException('macVerificationFailed');
      }
      return value;
    } finally {
      plain?.fillRange(0, plain.length, 0);
    }
  }

  /// Recursively decrypts all string fields inside [node].
  Object? walk(Object? node) {
    if (node is Map) {
      return <String, Object?>{
        for (final entry in node.entries)
          entry.key.toString(): walk(entry.value),
      };
    }
    if (node is List) {
      return <Object?>[for (final item in node) walk(item)];
    }
    return decryptField(node);
  }
}
