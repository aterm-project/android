import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/record_redaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _instanceId = '11111111-1111-4111-8111-111111111111';
const _serverSpaceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _recordId = '44444444-4444-4444-8444-444444444444';
const _deletedRevisionId = '55555555-5555-4555-8555-555555555555';
const _redactionId = '66666666-6666-4666-8666-666666666666';

void main() {
  late SodiumSumo sodium;
  late DeviceIdentity pinnedInstanceKey;
  late DeviceIdentity unpinnedInstanceKey;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() {
    pinnedInstanceKey = DeviceIdentity.create(sodium);
    unpinnedInstanceKey = DeviceIdentity.create(sodium);
  });

  tearDown(() {
    pinnedInstanceKey.dispose();
    unpinnedInstanceKey.dispose();
  });

  Map<String, Object?> signedProof({
    DeviceIdentity? signer,
    String instanceId = _instanceId,
    String serverSpaceId = _serverSpaceId,
    String vaultId = _vaultId,
    String recordId = _recordId,
    String deletedSeq = '8',
    String redactionSeq = '9',
  }) {
    final signingIdentity = signer ?? pinnedInstanceKey;
    final payload = <String, Object?>{
      'format': recordRedactionProofFormat,
      'redaction_id': _redactionId,
      'instance_id': instanceId,
      'server_space_id': serverSpaceId,
      'vault_id': vaultId,
      'record_id': recordId,
      'deleted_revision_id': _deletedRevisionId,
      'deleted_seq': deletedSeq,
      'redaction_seq': redactionSeq,
      'signing_public_key': signingIdentity.signingPublicKey,
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
      secretKey: signingIdentity.signing.secretKey,
    );
    return {...payload, 'signature': encodeBase64Url(signature)};
  }

  RecordRedactionProof verify(
    Map<String, dynamic> proof, {
    String instanceId = _instanceId,
    String serverSpaceId = _serverSpaceId,
    String vaultId = _vaultId,
    String recordId = _recordId,
    String? pinnedSigningKey,
  }) => RecordRedactionProof.verify(
    proof,
    crypto: VaultCrypto(sodium),
    expectedInstanceId: instanceId,
    expectedServerSpaceId: serverSpaceId,
    expectedVaultId: vaultId,
    expectedRecordId: recordId,
    currentPinnedSigningPublicKey:
        pinnedSigningKey ?? pinnedInstanceKey.signingPublicKey,
  );

  test('valid signature is bound to the complete instance and Vault scope', () {
    final proof = signedProof();
    final verified = verify(Map<String, dynamic>.from(proof));
    expect(verified.toJson(), proof);

    for (final wrongContext in [
      {'instanceId': '77777777-7777-4777-8777-777777777777'},
      {'serverSpaceId': '88888888-8888-4888-8888-888888888888'},
      {'vaultId': '99999999-9999-4999-8999-999999999999'},
      {'recordId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
    ]) {
      expect(
        () => verify(
          Map<String, dynamic>.from(proof),
          instanceId: wrongContext['instanceId'] as String? ?? _instanceId,
          serverSpaceId:
              wrongContext['serverSpaceId'] as String? ?? _serverSpaceId,
          vaultId: wrongContext['vaultId'] as String? ?? _vaultId,
          recordId: wrongContext['recordId'] as String? ?? _recordId,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects an unpinned signer even when that signer made a valid proof',
    () {
      final proof = signedProof(signer: unpinnedInstanceKey);
      expect(
        () => verify(Map<String, dynamic>.from(proof)),
        throwsFormatException,
      );
    },
  );

  test('rejects malformed or non-monotone sequence metadata before use', () {
    for (final malformed in [
      signedProof(deletedSeq: '08'),
      signedProof(deletedSeq: '0'),
      signedProof(deletedSeq: '9', redactionSeq: '9'),
      signedProof(deletedSeq: '10', redactionSeq: '9'),
    ]) {
      expect(
        () => verify(Map<String, dynamic>.from(malformed)),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects signature tampering, noncanonical encoding, and extra fields',
    () {
      final proof = signedProof();
      final badSignature = Map<String, dynamic>.from(proof)
        ..['signature'] = encodeBase64Url(Uint8List(64));
      expect(() => verify(badSignature), throwsFormatException);

      final extraField = Map<String, dynamic>.from(proof)..['history'] = [];
      expect(() => verify(extraField), throwsFormatException);

      final badEncoding = Map<String, dynamic>.from(proof)
        ..['signing_public_key'] = '${proof['signing_public_key']}=';
      expect(() => verify(badEncoding), throwsFormatException);
    },
  );
}
