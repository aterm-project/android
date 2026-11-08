/// Frozen strict KnownHost v1 payload reader used to test wire compatibility
/// with clients that predate schema-v2 revocation acknowledgements.
///
/// Keep this intentionally independent from `KnownHostRecord.fromJson`: that
/// model evolves with the current client and cannot act as a legacy oracle.
/// The record envelope still uses the shared Vault crypto wire format; this
/// class models the old client's strict decrypted-payload boundary.
final class LegacyKnownHostV1Client {
  static const _requiredFields = {
    'id',
    'type',
    'host',
    'port',
    'algorithm',
    'fingerprint',
    'state',
    'approval_source',
    'approved_by_device_id',
    'approved_at',
    'revoked_by_device_id',
    'revoked_at',
  };
  static const _localMetadataFields = {
    '_record_id',
    '_revision_id',
    '_manifest',
  };

  Map<String, dynamic> decode(Map<String, dynamic> payload) {
    final keys = payload.keys.toSet();
    if (!keys.containsAll(_requiredFields) ||
        keys.any(
          (key) =>
              !_requiredFields.contains(key) &&
              !_localMetadataFields.contains(key),
        )) {
      throw const FormatException(
        'Legacy KnownHost v1 record fields are incomplete or unknown',
      );
    }
    if (payload['type'] != 'knownHost' ||
        payload['state'] != 'trusted' && payload['state'] != 'revoked') {
      throw const FormatException('Legacy KnownHost v1 record is invalid');
    }
    return Map<String, dynamic>.unmodifiable(payload);
  }
}
