import 'dart:convert';
import 'dart:typed_data';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';

const recordRedactionProofFormat = 'atermius-record-redaction-proof-v1';

/// Verified immutable proof that a server permanently redacted one Vault
/// record. The carried signer is accepted only when it equals the current
/// instance key that AppController already verified against the stored pin.
class RecordRedactionProof {
  const RecordRedactionProof({
    required this.redactionId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.recordId,
    required this.deletedRevisionId,
    required this.deletedSeq,
    required this.redactionSeq,
    required this.signingPublicKey,
    required this.signature,
  });

  final String redactionId;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String recordId;
  final String deletedRevisionId;
  final String deletedSeq;
  final String redactionSeq;
  final String signingPublicKey;
  final String signature;

  Map<String, Object?> signedPayload() => {
    'format': recordRedactionProofFormat,
    'redaction_id': redactionId,
    'instance_id': instanceId,
    'server_space_id': serverSpaceId,
    'vault_id': vaultId,
    'record_id': recordId,
    'deleted_revision_id': deletedRevisionId,
    'deleted_seq': deletedSeq,
    'redaction_seq': redactionSeq,
    'signing_public_key': signingPublicKey,
  };

  Map<String, Object?> toJson() => {
    ...signedPayload(),
    'signature': signature,
  };

  static RecordRedactionProof verify(
    Map<String, dynamic> json, {
    required VaultCrypto crypto,
    required String expectedInstanceId,
    required String expectedServerSpaceId,
    required String expectedVaultId,
    required String expectedRecordId,
    required String currentPinnedSigningPublicKey,
  }) {
    const fields = {
      'format',
      'redaction_id',
      'instance_id',
      'server_space_id',
      'vault_id',
      'record_id',
      'deleted_revision_id',
      'deleted_seq',
      'redaction_seq',
      'signing_public_key',
      'signature',
    };
    if (json.keys.toSet().length != fields.length ||
        !json.keys.toSet().containsAll(fields) ||
        json['format'] != recordRedactionProofFormat) {
      throw const FormatException('Record redaction proof fields are invalid.');
    }
    String uuid(String field) {
      final value = json[field];
      if (value is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(value)) {
        throw FormatException('Record redaction proof $field is invalid.');
      }
      return value;
    }

    String positiveSequence(String field) {
      final value = json[field];
      if (value is! String || !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
        throw FormatException('Record redaction proof $field is invalid.');
      }
      return value;
    }

    final redactionId = uuid('redaction_id');
    final instanceId = uuid('instance_id');
    final serverSpaceId = uuid('server_space_id');
    final vaultId = uuid('vault_id');
    final recordId = uuid('record_id');
    final deletedRevisionId = uuid('deleted_revision_id');
    final deletedSeq = positiveSequence('deleted_seq');
    final redactionSeq = positiveSequence('redaction_seq');
    final signingPublicKey = json['signing_public_key'];
    final signatureText = json['signature'];
    if (instanceId != expectedInstanceId ||
        serverSpaceId != expectedServerSpaceId ||
        vaultId != expectedVaultId ||
        recordId != expectedRecordId ||
        signingPublicKey != currentPinnedSigningPublicKey ||
        signingPublicKey is! String ||
        signatureText is! String ||
        _compareDecimal(deletedSeq, redactionSeq) >= 0) {
      throw const FormatException(
        'Record redaction proof does not match the pinned Vault context.',
      );
    }
    final publicKey = decodeBase64Url(signingPublicKey);
    final signature = decodeBase64Url(signatureText);
    if (publicKey.length != 32 ||
        signature.length != 64 ||
        encodeBase64Url(publicKey) != signingPublicKey ||
        encodeBase64Url(signature) != signatureText) {
      throw const FormatException('Record redaction proof signature is invalid.');
    }
    final proof = RecordRedactionProof(
      redactionId: redactionId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      vaultId: vaultId,
      recordId: recordId,
      deletedRevisionId: deletedRevisionId,
      deletedSeq: deletedSeq,
      redactionSeq: redactionSeq,
      signingPublicKey: signingPublicKey,
      signature: signatureText,
    );
    if (!crypto.sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(proof.signedPayload()))),
      signature: signature,
      publicKey: publicKey,
    )) {
      throw const FormatException('Record redaction proof signature is invalid.');
    }
    return proof;
  }
}

int _compareDecimal(String left, String right) {
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}
