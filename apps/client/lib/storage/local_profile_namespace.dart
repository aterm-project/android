/// The database used by server-authenticated profiles.
const serverClientDatabaseName = 'atermius_vault';

final _canonicalLocalProfileId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Returns true only for a lower-case, RFC 4122 variant UUID with a supported
/// version. Profile IDs are untrusted storage identifiers and must be checked
/// before they are used to derive a database name or secure-store namespace.
bool isCanonicalLocalProfileId(String value) =>
    _canonicalLocalProfileId.hasMatch(value);

/// Stable, filesystem-safe name for a single local profile database.
///
/// UUID validation makes the result a fixed ASCII prefix plus a bounded,
/// delimiter-safe identifier. Never pass user-entered labels or server URLs
/// into a database-name parameter.
String localProfileDatabaseName(String profileId) {
  if (!isCanonicalLocalProfileId(profileId)) {
    throw const FormatException('Local profile ID is invalid.');
  }
  return 'atermius_local_$profileId';
}

/// Logical key prefix for local profile metadata/private-key envelopes.
///
/// The prefix is only a namespace. Private material still must be encrypted
/// with the profile UMK before it is written to storage.
String localProfileSecureStorageNamespace(String profileId) {
  if (!isCanonicalLocalProfileId(profileId)) {
    throw const FormatException('Local profile ID is invalid.');
  }
  return 'local:$profileId';
}
