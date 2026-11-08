import 'dart:convert';

import 'package:drift/drift.dart';

import '../crypto/jcs.dart';
import 'client_database_connection.dart';
import 'local_profile_namespace.dart';

/// Physically separate database for local-only profile metadata.
///
/// This catalog intentionally does not share the server-backed database schema. Its
/// only persisted secret-bearing fields are validated ciphertext envelopes.
const localProfileCatalogDatabaseName = 'atermius_profile_catalog';

const _profileFormatVersion = 1;
const _umkFormat = 'atermius-local-umk-envelope';
const _vaultKeyFormat = 'atermius-local-vault-key-envelope';
const _deviceIdentityFormat = 'atermius-local-device-identity-envelope';
const _umkPurpose = 'local-umk-wrap';
const _vaultKeyPurpose = 'local-vault-key-wrap';
const _deviceIdentityPurpose = 'local-device-identity-wrap';
const _keySuite = 'xchacha20-poly1305-ietf';
const _deviceSigningAlgorithm = 'ed25519';
const _deviceEncryptionAlgorithm = 'curve25519-xsalsa20-poly1305';
const _maxEnvelopeJsonChars = 4096;

const _kdfFields = {
  'id',
  'salt',
  'mem_kib',
  'iterations',
  'parallelism',
  'version',
};
const _umkEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'kdf',
  'nonce',
  'ciphertext',
};
const _vaultKeyEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'local_vault_id',
  'key_epoch',
  'suite',
  'nonce',
  'ciphertext',
};
const _deviceIdentityEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'local_device_id',
  'signing_algorithm',
  'signing_public',
  'encryption_algorithm',
  'encryption_public',
  'suite',
  'nonce',
  'ciphertext',
};

/// Validated, immutable catalog metadata for one local-only profile.
///
/// This object deliberately exposes the envelopes as maps but has no fields
/// for a plaintext UMK, Vault key, or device private key. The DeviceIdentity
/// envelope may include public keys, which are intentionally not secret.
class LocalProfileRecord {
  LocalProfileRecord._({
    required this.profileId,
    required this.localDataDomainId,
    required this.localVaultId,
    required this.localDeviceId,
    required this.profileVersion,
    required this.createdAt,
    required this.kdfMetadata,
    required this.umkEnvelope,
    required this.vaultKeyEnvelope,
    required this.deviceIdentityEnvelope,
    required this.vaultKeyEpoch,
    required this.deviceKeyVersion,
  });

  final String profileId;
  final String localDataDomainId;
  final String localVaultId;
  final String localDeviceId;
  final int profileVersion;
  final DateTime createdAt;
  final Map<String, Object?> kdfMetadata;
  final Map<String, Object?> umkEnvelope;
  final Map<String, Object?> vaultKeyEnvelope;
  final Map<String, Object?> deviceIdentityEnvelope;
  final int vaultKeyEpoch;
  final int deviceKeyVersion;

  /// Builds a catalog row only when its identifiers and all encrypted package
  /// headers agree exactly. Extra fields (including plaintext key fields) are
  /// rejected before any database write occurs.
  factory LocalProfileRecord.create({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required String localDeviceId,
    DateTime? createdAt,
    required Map<String, Object?> kdfMetadata,
    required Map<String, Object?> umkEnvelope,
    required Map<String, Object?> vaultKeyEnvelope,
    required Map<String, Object?> deviceIdentityEnvelope,
  }) {
    _requireUuid(profileId, 'profile_id');
    _requireUuid(localDataDomainId, 'local_data_domain_id');
    _requireUuid(localVaultId, 'local_vault_id');
    _requireUuid(localDeviceId, 'local_device_id');

    final validatedKdf = _validateKdf(kdfMetadata);
    final umk = _validateUmkEnvelope(
      umkEnvelope,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      kdfMetadata: validatedKdf,
    );
    final vault = _validateVaultKeyEnvelope(
      vaultKeyEnvelope,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
    );
    final identity = _validateDeviceIdentityEnvelope(
      deviceIdentityEnvelope,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localDeviceId: localDeviceId,
    );
    final timestamp = (createdAt ?? DateTime.now()).toUtc();
    final createdAtMs = timestamp.millisecondsSinceEpoch;
    if (createdAtMs <= 0) {
      throw const FormatException('Local profile created_at is invalid.');
    }

    return LocalProfileRecord._(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      localDeviceId: localDeviceId,
      profileVersion: _profileFormatVersion,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      kdfMetadata: Map.unmodifiable(validatedKdf),
      umkEnvelope: Map.unmodifiable(umk),
      vaultKeyEnvelope: Map.unmodifiable(vault),
      deviceIdentityEnvelope: Map.unmodifiable(identity),
      vaultKeyEpoch: vault['key_epoch']! as int,
      deviceKeyVersion: identity['key_version']! as int,
    );
  }

  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'local_data_domain_id': localDataDomainId,
    'local_vault_id': localVaultId,
    'local_device_id': localDeviceId,
    'profile_version': profileVersion,
    'created_at_ms': createdAt.millisecondsSinceEpoch,
    'kdf_metadata': kdfMetadata,
    'umk_envelope': umkEnvelope,
    'vault_key_envelope': vaultKeyEnvelope,
    'device_identity_envelope': deviceIdentityEnvelope,
  };
}

/// A small Drift database with a schema owned exclusively by this catalog.
///
/// Production uses [openClientDatabaseConnection] so Web storage is
/// preflighted independently under the catalog's own database name. Tests can
/// inject a file-backed NativeDatabase without changing the production path.
class LocalProfileCatalog extends GeneratedDatabase {
  LocalProfileCatalog._(super.executor);

  factory LocalProfileCatalog.forTesting(QueryExecutor executor) =>
      LocalProfileCatalog._(executor);

  static Future<LocalProfileCatalog> open() async {
    final connection = await openClientDatabaseConnection(
      name: localProfileCatalogDatabaseName,
    );
    final database = LocalProfileCatalog._(connection);
    try {
      await database.ensureReady();
      return database;
    } on Object {
      try {
        await database.close();
      } on Object {
        // A delayed executor may fail before it has an open handle.
      }
      rethrow;
    }
  }

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => const <TableInfo>[];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => customStatement('''
      CREATE TABLE local_profile_catalog (
        profile_id TEXT NOT NULL PRIMARY KEY,
        local_data_domain_id TEXT NOT NULL UNIQUE,
        local_vault_id TEXT NOT NULL UNIQUE,
        local_device_id TEXT NOT NULL UNIQUE,
        profile_version INTEGER NOT NULL CHECK (profile_version = 1),
        created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
        vault_key_epoch INTEGER NOT NULL CHECK (vault_key_epoch > 0),
        device_key_version INTEGER NOT NULL CHECK (device_key_version > 0),
        kdf_json TEXT NOT NULL,
        umk_envelope_json TEXT NOT NULL,
        vault_key_envelope_json TEXT NOT NULL,
        device_identity_envelope_json TEXT NOT NULL
      )
    '''),
    onUpgrade: (migrator, from, to) async {
      throw UnsupportedError(
        'Local profile catalog migration $from -> $to is not implemented.',
      );
    },
  );

  Future<void> ensureReady() async {
    await customSelect(
      'SELECT profile_id FROM local_profile_catalog LIMIT 0',
    ).get();
  }

  /// Atomically inserts a new profile. Profile and identity IDs are unique in
  /// this catalog; an existing profile is never silently overwritten.
  Future<LocalProfileRecord> create({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required String localDeviceId,
    DateTime? createdAt,
    required Map<String, Object?> kdfMetadata,
    required Map<String, Object?> umkEnvelope,
    required Map<String, Object?> vaultKeyEnvelope,
    required Map<String, Object?> deviceIdentityEnvelope,
  }) async {
    final profile = LocalProfileRecord.create(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      localDeviceId: localDeviceId,
      createdAt: createdAt,
      kdfMetadata: kdfMetadata,
      umkEnvelope: umkEnvelope,
      vaultKeyEnvelope: vaultKeyEnvelope,
      deviceIdentityEnvelope: deviceIdentityEnvelope,
    );
    await ensureReady();
    final json = profile.toJson();
    await transaction(() async {
      await customStatement(
        '''
        INSERT INTO local_profile_catalog (
          profile_id, local_data_domain_id, local_vault_id, local_device_id,
          profile_version, created_at_ms, vault_key_epoch, device_key_version,
          kdf_json, umk_envelope_json, vault_key_envelope_json,
          device_identity_envelope_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          profile.profileId,
          profile.localDataDomainId,
          profile.localVaultId,
          profile.localDeviceId,
          profile.profileVersion,
          profile.createdAt.millisecondsSinceEpoch,
          profile.vaultKeyEpoch,
          profile.deviceKeyVersion,
          canonicalJson(json['kdf_metadata']),
          canonicalJson(profile.umkEnvelope),
          canonicalJson(profile.vaultKeyEnvelope),
          canonicalJson(profile.deviceIdentityEnvelope),
        ],
      );
    });
    // Drift's IndexedDB VFS defers page writes while `isInTransaction` is
    // true. Its COMMIT statement runs before Drift releases that flag, so the
    // transaction can return before IndexedDB has received the dirty blocks.
    // Run an awaited statement outside the transaction to trigger the VFS
    // flush before reporting profile creation as durable.
    await customStatement('PRAGMA data_version');
    return profile;
  }

  Future<LocalProfileRecord?> get(String profileId) async {
    _requireUuid(profileId, 'profile_id');
    await ensureReady();
    final rows = await customSelect(
      'SELECT * FROM local_profile_catalog WHERE profile_id = ?',
      variables: [Variable<String>(profileId)],
    ).get();
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const FormatException('Local profile catalog key is ambiguous.');
    }
    return _decodeRow(rows.single.data);
  }

  Future<List<LocalProfileRecord>> list() async {
    await ensureReady();
    final rows = await customSelect(
      'SELECT * FROM local_profile_catalog '
      'ORDER BY created_at_ms ASC, profile_id ASC',
    ).get();
    return List.unmodifiable(rows.map((row) => _decodeRow(row.data)));
  }

  LocalProfileRecord _decodeRow(Map<String, Object?> row) {
    final profileId = row['profile_id'];
    final domainId = row['local_data_domain_id'];
    final vaultId = row['local_vault_id'];
    final deviceId = row['local_device_id'];
    final profileVersion = row['profile_version'];
    final createdAtMs = row['created_at_ms'];
    final vaultKeyEpoch = row['vault_key_epoch'];
    final deviceKeyVersion = row['device_key_version'];
    if (profileId is! String ||
        domainId is! String ||
        vaultId is! String ||
        deviceId is! String ||
        profileVersion != _profileFormatVersion ||
        createdAtMs is! int ||
        createdAtMs <= 0 ||
        vaultKeyEpoch is! int ||
        vaultKeyEpoch <= 0 ||
        deviceKeyVersion is! int ||
        deviceKeyVersion <= 0) {
      throw const FormatException('Stored local profile metadata is invalid.');
    }
    final kdf = _decodeCanonicalObject(row['kdf_json'], 'KDF metadata');
    final umk = _decodeCanonicalObject(
      row['umk_envelope_json'],
      'UMK envelope',
    );
    final vault = _decodeCanonicalObject(
      row['vault_key_envelope_json'],
      'Vault key envelope',
    );
    final identity = _decodeCanonicalObject(
      row['device_identity_envelope_json'],
      'Device identity envelope',
    );
    final profile = LocalProfileRecord.create(
      profileId: profileId,
      localDataDomainId: domainId,
      localVaultId: vaultId,
      localDeviceId: deviceId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      kdfMetadata: kdf,
      umkEnvelope: umk,
      vaultKeyEnvelope: vault,
      deviceIdentityEnvelope: identity,
    );
    if (profile.profileVersion != profileVersion ||
        profile.vaultKeyEpoch != vaultKeyEpoch ||
        profile.deviceKeyVersion != deviceKeyVersion) {
      throw const FormatException(
        'Stored local profile versions do not match their envelopes.',
      );
    }
    return profile;
  }
}

Map<String, Object?> _validateKdf(Map<String, Object?> kdf) {
  _requireExactFields(kdf, _kdfFields, 'KDF metadata');
  if (kdf['id'] != 'argon2id13' ||
      kdf['salt'] is! String ||
      kdf['mem_kib'] is! int ||
      kdf['iterations'] is! int ||
      kdf['parallelism'] is! int ||
      kdf['version'] is! int) {
    throw const FormatException('Local profile KDF metadata is invalid.');
  }
  final salt = _decodeCanonicalBytes(
    kdf['salt']! as String,
    'KDF salt',
    expectedByteLength: 16,
  );
  final memoryKib = kdf['mem_kib']! as int;
  final iterations = kdf['iterations']! as int;
  if (salt.length != 16 ||
      memoryKib != 65536 ||
      iterations != 3 ||
      kdf['parallelism'] != 1 ||
      kdf['version'] != 1) {
    throw const FormatException('Local profile KDF parameters are invalid.');
  }
  return {
    'id': 'argon2id13',
    'salt': kdf['salt']! as String,
    'mem_kib': memoryKib,
    'iterations': iterations,
    'parallelism': 1,
    'version': 1,
  };
}

Map<String, Object?> _validateUmkEnvelope(
  Map<String, Object?> value, {
  required String profileId,
  required String localDataDomainId,
  required Map<String, Object?> kdfMetadata,
}) {
  _requireExactFields(value, _umkEnvelopeFields, 'UMK envelope');
  if (value['format'] != _umkFormat ||
      value['envelope_version'] != 1 ||
      value['key_version'] != 1 ||
      value['purpose'] != _umkPurpose ||
      value['profile_id'] != profileId ||
      value['local_data_domain_id'] != localDataDomainId ||
      value['nonce'] is! String ||
      value['ciphertext'] is! String) {
    throw const FormatException('Local UMK envelope context is invalid.');
  }
  final envelopeKdf = value['kdf'];
  if (envelopeKdf is! Map<String, Object?> ||
      canonicalJson(_validateKdf(envelopeKdf)) != canonicalJson(kdfMetadata)) {
    throw const FormatException(
      'Local UMK envelope KDF does not match catalog metadata.',
    );
  }
  _validateCipherPair(
    value['nonce']! as String,
    value['ciphertext']! as String,
    ciphertextLength: 48,
    label: 'UMK envelope',
  );
  return Map<String, Object?>.from(value)
    ..['kdf'] = Map<String, Object?>.unmodifiable(kdfMetadata);
}

Map<String, Object?> _validateVaultKeyEnvelope(
  Map<String, Object?> value, {
  required String profileId,
  required String localDataDomainId,
  required String localVaultId,
}) {
  _requireExactFields(value, _vaultKeyEnvelopeFields, 'Vault key envelope');
  if (value['format'] != _vaultKeyFormat ||
      value['envelope_version'] != 1 ||
      value['key_version'] != 1 ||
      value['purpose'] != _vaultKeyPurpose ||
      value['profile_id'] != profileId ||
      value['local_data_domain_id'] != localDataDomainId ||
      value['local_vault_id'] != localVaultId ||
      value['key_epoch'] is! int ||
      (value['key_epoch']! as int) < 1 ||
      value['suite'] != _keySuite ||
      value['nonce'] is! String ||
      value['ciphertext'] is! String) {
    throw const FormatException('Local Vault key envelope context is invalid.');
  }
  _validateCipherPair(
    value['nonce']! as String,
    value['ciphertext']! as String,
    ciphertextLength: 48,
    label: 'Vault key envelope',
  );
  return Map<String, Object?>.from(value);
}

Map<String, Object?> _validateDeviceIdentityEnvelope(
  Map<String, Object?> value, {
  required String profileId,
  required String localDataDomainId,
  required String localDeviceId,
}) {
  _requireExactFields(
    value,
    _deviceIdentityEnvelopeFields,
    'Device identity envelope',
  );
  if (value['format'] != _deviceIdentityFormat ||
      value['envelope_version'] != 1 ||
      value['key_version'] is! int ||
      (value['key_version']! as int) < 1 ||
      value['purpose'] != _deviceIdentityPurpose ||
      value['profile_id'] != profileId ||
      value['local_data_domain_id'] != localDataDomainId ||
      value['local_device_id'] != localDeviceId ||
      value['signing_algorithm'] != _deviceSigningAlgorithm ||
      value['encryption_algorithm'] != _deviceEncryptionAlgorithm ||
      value['suite'] != _keySuite ||
      value['signing_public'] is! String ||
      value['encryption_public'] is! String ||
      value['nonce'] is! String ||
      value['ciphertext'] is! String) {
    throw const FormatException(
      'Local DeviceIdentity envelope context is invalid.',
    );
  }
  if (_decodeCanonicalBytes(
            value['signing_public']! as String,
            'signing public key',
            expectedByteLength: 32,
          ).length !=
          32 ||
      _decodeCanonicalBytes(
            value['encryption_public']! as String,
            'encryption public key',
            expectedByteLength: 32,
          ).length !=
          32) {
    throw const FormatException(
      'Local DeviceIdentity public keys are invalid.',
    );
  }
  _validateCipherPair(
    value['nonce']! as String,
    value['ciphertext']! as String,
    ciphertextLength: 112,
    label: 'DeviceIdentity envelope',
  );
  return Map<String, Object?>.from(value);
}

void _validateCipherPair(
  String nonceText,
  String ciphertextText, {
  required int ciphertextLength,
  required String label,
}) {
  _decodeCanonicalBytes(nonceText, '$label nonce', expectedByteLength: 24);
  _decodeCanonicalBytes(
    ciphertextText,
    '$label ciphertext',
    expectedByteLength: ciphertextLength,
  );
}

Map<String, Object?> _decodeCanonicalObject(Object? source, String label) {
  if (source is! String || source.length > _maxEnvelopeJsonChars) {
    throw FormatException('Stored $label is invalid.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw FormatException('Stored $label is invalid.');
  }
  if (decoded is! Map) throw FormatException('Stored $label is invalid.');
  final value = <String, Object?>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String) {
      throw FormatException('Stored $label is invalid.');
    }
    value[entry.key as String] = entry.value;
  }
  if (canonicalJson(value) != source) {
    throw FormatException('Stored $label is not canonical JSON.');
  }
  return value;
}

void _requireExactFields(
  Map<String, Object?> value,
  Set<String> expected,
  String label,
) {
  final actual = value.keys.toSet();
  if (actual.length != value.length ||
      actual.length != expected.length ||
      !actual.containsAll(expected)) {
    throw FormatException('$label fields are invalid.');
  }
}

void _requireUuid(String value, String label) {
  if (!isCanonicalLocalProfileId(value)) {
    throw FormatException('Local profile $label is invalid.');
  }
}

List<int> _decodeCanonicalBytes(
  String value,
  String label, {
  required int expectedByteLength,
}) {
  // Check the exact unpadded Base64URL size before decoding so a corrupted
  // catalog row cannot force an unbounded temporary allocation here.
  final expectedCharacterLength = (expectedByteLength * 8 + 5) ~/ 6;
  if (value.length != expectedCharacterLength) {
    throw FormatException('$label has an invalid encoded length.');
  }
  try {
    final decoded = base64Url.decode(base64Url.normalize(value));
    final canonical = base64Url.encode(decoded).replaceAll('=', '');
    if (canonical != value) throw FormatException('$label is not canonical.');
    if (decoded.length != expectedByteLength) {
      throw FormatException('$label has an invalid byte length.');
    }
    return decoded;
  } on FormatException {
    rethrow;
  } on Object {
    throw FormatException('$label is invalid.');
  }
}
