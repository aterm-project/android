import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production Dart crypto consumes the shared sync record vector',
    () async {
      final vector =
          jsonDecode(
                File(
                  '../../protocol/sync-fixtures/record-envelope-v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final envelope = Map<String, dynamic>.from(vector['envelope'] as Map);
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      expect(canonicalJson(header), vector['header_jcs_utf8']);
      final unsigned = <String, Object?>{
        'header': header,
        'nonce': envelope['nonce'],
        'ciphertext': envelope['ciphertext'],
      };
      final signedBytes = canonicalJson(unsigned);
      expect(signedBytes, vector['signed_payload_jcs_utf8']);
      final signedDigest = await cryptography.Sha256().hash(
        Uint8List.fromList(utf8.encode(signedBytes)),
      );
      expect(_hex(signedDigest.bytes), vector['signed_payload_sha256']);
      final envelopeDigest = await cryptography.Sha256().hash(
        Uint8List.fromList(utf8.encode(canonicalJson(envelope))),
      );
      expect(_hex(envelopeDigest.bytes), vector['envelope_jcs_sha256']);

      final sodium = await SodiumSumoInit.init();
      final vaultCrypto = VaultCrypto(sodium);
      final signingPublicKey = decodeBase64Url(
        vector['test_only']['signing_public_key_base64url'] as String,
      );
      vaultCrypto.verifyRecordSignature(
        envelope: envelope,
        authorPublicKey: signingPublicKey,
      );

      final plaintext = await vaultCrypto.decryptRecord(
        vaultKey: decodeBase64Url(
          vector['test_only']['vault_key_base64url'] as String,
        ),
        envelope: envelope,
        authorPublicKey: signingPublicKey,
      );
      expect(canonicalJson(plaintext), vector['plaintext_jcs_utf8']);

      final tamperedHeader = _copyEnvelope(envelope);
      (tamperedHeader['header'] as Map<String, dynamic>)['operation'] =
          'update';
      _expectInvalidSignature(vaultCrypto, tamperedHeader, signingPublicKey);

      for (final field in ['nonce', 'ciphertext', 'signature']) {
        final tampered = _copyEnvelope(envelope);
        tampered[field] = _flipFirstByte(tampered[field] as String);
        _expectInvalidSignature(vaultCrypto, tampered, signingPublicKey);
      }
    },
  );
}

Map<String, dynamic> _copyEnvelope(Map<String, dynamic> source) =>
    Map<String, dynamic>.from(
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>,
    );

String _flipFirstByte(String encoded) {
  final bytes = decodeBase64Url(encoded);
  bytes[0] ^= 1;
  return encodeBase64Url(bytes);
}

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

void _expectInvalidSignature(
  VaultCrypto crypto,
  Map<String, dynamic> envelope,
  Uint8List signingPublicKey,
) {
  expect(
    () => crypto.verifyRecordSignature(
      envelope: envelope,
      authorPublicKey: signingPublicKey,
    ),
    throwsFormatException,
  );
}
