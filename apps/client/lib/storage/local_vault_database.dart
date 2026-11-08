import 'package:drift/drift.dart';

import 'client_database_connection.dart';
import 'local_profile_service.dart';
import 'local_profile_namespace.dart';

/// Database name prefix reserved for the dedicated local-only Vault schema.
/// This is intentionally distinct from the legacy ClientDatabase prefix.
const localVaultDatabaseNamePrefix = 'atermius_local_vault_';

String localVaultDatabaseName(String profileId) {
  if (!isCanonicalLocalProfileId(profileId)) {
    throw const FormatException('Local profile ID is invalid.');
  }
  return '$localVaultDatabaseNamePrefix$profileId';
}

/// Controls whether opening a LocalVault may initialize its one-time profile
/// binding. A catalog profile is durable metadata, so only the create flow may
/// bind an empty database; unlocking must fail closed if that binding vanished.
enum LocalVaultOpenMode { createNew, openExisting }

/// The catalog still names a local profile, but its corresponding Vault
/// database no longer has the expected one-time binding. The message contains
/// no profile identifier, database name, filesystem path, or browser detail.
class LocalVaultBindingMissingException implements Exception {
  const LocalVaultBindingMissingException();

  @override
  String toString() => 'Local profile storage is missing or unavailable.';
}

/// A LocalVault database is physically and logically separate from the
/// server-backed ClientDatabase. Its migration journal contains only
/// non-secret metadata and already-encrypted target payloads.
class LocalVaultDatabase extends GeneratedDatabase {
  LocalVaultDatabase._(
    super.executor, {
    required this.profileId,
    required this.localDataDomainId,
    required this.localVaultId,
  });

  final String profileId;
  final String localDataDomainId;
  final String localVaultId;

  static Future<LocalVaultDatabase> open(
    UnlockedLocalProfile profile, {
    required LocalVaultOpenMode mode,
  }) async {
    final record = profile.record;
    final database = LocalVaultDatabase._(
      await openClientDatabaseConnection(
        name: localVaultDatabaseName(record.profileId),
      ),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
    try {
      await database.ensureReady();
      await database.bindContext(
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
        mode: mode,
      );
      return database;
    } on Object {
      try {
        await database.close();
      } on Object {
        // The executor may fail before its handle is ready.
      }
      rethrow;
    }
  }

  /// File-backed test seam that exercises the same schema and binding checks
  /// as production while allowing tests to choose a temporary SQLite file.
  static Future<LocalVaultDatabase> openForTesting({
    required QueryExecutor executor,
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    LocalVaultOpenMode mode = LocalVaultOpenMode.createNew,
  }) async {
    final database = LocalVaultDatabase._(
      executor,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
    );
    try {
      await database.ensureReady();
      await database.bindContext(
        profileId: profileId,
        localDataDomainId: localDataDomainId,
        localVaultId: localVaultId,
        mode: mode,
      );
      return database;
    } on Object {
      try {
        await database.close();
      } on Object {
        // The executor may fail before its handle is ready.
      }
      rethrow;
    }
  }

  @override
  int get schemaVersion => 5;

  @override
  Iterable<TableInfo> get allTables => const <TableInfo>[];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
        CREATE TABLE local_vault_binding (
          singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
          profile_id TEXT NOT NULL,
          local_data_domain_id TEXT NOT NULL,
          local_vault_id TEXT NOT NULL,
          schema_version INTEGER NOT NULL CHECK (schema_version = 1)
        )
      ''');
      await customStatement('''
        CREATE TABLE local_vault_records (
          local_vault_id TEXT NOT NULL,
          record_id TEXT NOT NULL,
          revision_id TEXT NOT NULL,
          envelope_json TEXT NOT NULL,
          is_deleted INTEGER NOT NULL CHECK (is_deleted IN (0, 1)),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms > 0),
          PRIMARY KEY (local_vault_id, record_id)
        )
      ''');
      await customStatement('''
        CREATE INDEX local_vault_records_list_idx
        ON local_vault_records (local_vault_id, updated_at_ms, record_id)
      ''');
      await _createMigrationSchema();
      await _createKnownHostSchema();
      await _createKnownHostArchiveSchema();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2 && to >= 2) {
        // v1 records already use the same ciphertext-only envelope table. Add
        // an ordering index without touching record contents or introducing
        // plaintext record metadata. The binding schema_version describes its
        // own immutable format and intentionally remains at version 1.
        await customStatement('''
          CREATE INDEX IF NOT EXISTS local_vault_records_list_idx
          ON local_vault_records (local_vault_id, updated_at_ms, record_id)
        ''');
      }
      if (from < 3 && to >= 3) await _createMigrationSchema();
      if (from < 4 && to >= 4) await _createKnownHostSchema();
      if (from < 5 && to >= 5) await _createKnownHostArchiveSchema();
      if (from > 5 || to > 5) {
        throw UnsupportedError(
          'Local Vault database migration $from -> $to is not implemented.',
        );
      }
    },
  );

  Future<void> _createMigrationSchema() async {
    await customStatement('''
      CREATE TABLE local_vault_migrations (
        migration_id TEXT NOT NULL PRIMARY KEY,
        local_vault_id TEXT NOT NULL,
        target_instance_id TEXT NOT NULL,
        target_vault_id TEXT NOT NULL,
        source_fingerprint TEXT NOT NULL,
        expected_item_count INTEGER NOT NULL CHECK (expected_item_count >= 0),
        status TEXT NOT NULL CHECK (
          status IN ('preparing', 'frozen', 'completed', 'cancelled')
        ),
        created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
        finished_at_ms INTEGER,
        CHECK (
          (status IN ('preparing', 'frozen') AND finished_at_ms IS NULL) OR
          (status IN ('completed', 'cancelled') AND finished_at_ms > 0)
        )
      )
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX local_vault_migrations_active_idx
      ON local_vault_migrations (local_vault_id)
      WHERE status IN ('preparing', 'frozen')
    ''');
    await customStatement('''
      CREATE TABLE local_vault_migration_items (
        migration_id TEXT NOT NULL,
        record_id TEXT NOT NULL,
        source_revision_id TEXT NOT NULL,
        record_type TEXT NOT NULL CHECK (
          record_type IN ('host', 'credential', 'group', 'snippet', 'preference')
        ),
        target_envelope_json TEXT NOT NULL,
        target_envelope_sha256 TEXT NOT NULL,
        staged_at_ms INTEGER NOT NULL CHECK (staged_at_ms > 0),
        PRIMARY KEY (migration_id, record_id),
        FOREIGN KEY (migration_id) REFERENCES local_vault_migrations(migration_id)
          ON DELETE CASCADE
      )
    ''');
    await customStatement('''
      CREATE TABLE local_vault_migration_create_payloads (
        migration_id TEXT NOT NULL PRIMARY KEY,
        payload_json TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL,
        staged_at_ms INTEGER NOT NULL CHECK (staged_at_ms > 0),
        FOREIGN KEY (migration_id) REFERENCES local_vault_migrations(migration_id)
          ON DELETE CASCADE
      )
    ''');
    // This is the storage-level write barrier. Repository/UI checks are only
    // advisory; a second SQLite connection or a direct SQL writer hits these
    // triggers too. `preparing` is transaction-local during source preflight.
    for (final action in const ['INSERT', 'UPDATE', 'DELETE']) {
      final refs = switch (action) {
        'INSERT' => 'NEW.local_vault_id',
        'UPDATE' => 'OLD.local_vault_id, NEW.local_vault_id',
        _ => 'OLD.local_vault_id',
      };
      await customStatement('''
        CREATE TRIGGER local_vault_records_${action.toLowerCase()}_freeze
        BEFORE $action ON local_vault_records
        WHEN EXISTS (
          SELECT 1 FROM local_vault_migrations
          WHERE status IN ('preparing', 'frozen')
            AND local_vault_id IN ($refs)
        )
        BEGIN
          SELECT RAISE(ABORT, 'LOCAL_VAULT_MIGRATION_FROZEN');
        END
      ''');
    }
  }

  /// Stores local SSH trust in a table that is intentionally outside the
  /// LocalVault record and migration/archive ledgers. The envelope remains
  /// encrypted and profile-bound; endpoint and fingerprint metadata are not
  /// exposed as SQLite columns.
  Future<void> _createKnownHostSchema() async {
    await customStatement('''
      CREATE TABLE local_vault_known_hosts (
        local_vault_id TEXT NOT NULL,
        record_id TEXT NOT NULL,
        revision_id TEXT NOT NULL,
        envelope_json TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms > 0),
        PRIMARY KEY (local_vault_id, record_id)
      )
    ''');
    await customStatement('''
      CREATE INDEX local_vault_known_hosts_list_idx
      ON local_vault_known_hosts (local_vault_id, record_id)
    ''');
  }

  /// Holds encrypted KnownHost approvals imported from a portable LocalVault
  /// archive until the user reviews each fingerprint and explicitly approves
  /// it on this device. Candidate rows are never consulted by SSH trust checks.
  Future<void> _createKnownHostArchiveSchema() async {
    await customStatement('''
      CREATE TABLE local_vault_known_host_imports (
        local_vault_id TEXT NOT NULL,
        record_id TEXT NOT NULL,
        source_revision_id TEXT NOT NULL,
        revision_id TEXT NOT NULL,
        envelope_json TEXT NOT NULL,
        imported_at_ms INTEGER NOT NULL CHECK (imported_at_ms > 0),
        PRIMARY KEY (local_vault_id, record_id)
      )
    ''');
    await customStatement('''
      CREATE INDEX local_vault_known_host_imports_list_idx
      ON local_vault_known_host_imports (local_vault_id, record_id)
    ''');
  }

  Future<void> ensureReady() async {
    _validateContext(profileId, localDataDomainId, localVaultId);
    // This probe also detects an unexpected database opened under this name.
    await customSelect(
      'SELECT profile_id FROM local_vault_binding LIMIT 0',
    ).get();
    await customSelect(
      'SELECT record_id FROM local_vault_records LIMIT 0',
    ).get();
    await customSelect(
      'SELECT migration_id FROM local_vault_migrations LIMIT 0',
    ).get();
    await customSelect(
      'SELECT record_id FROM local_vault_migration_items LIMIT 0',
    ).get();
    await customSelect(
      'SELECT migration_id FROM local_vault_migration_create_payloads LIMIT 0',
    ).get();
    await customSelect(
      'SELECT record_id FROM local_vault_known_hosts LIMIT 0',
    ).get();
    await customSelect(
      'SELECT record_id FROM local_vault_known_host_imports LIMIT 0',
    ).get();
  }

  /// Creates the one-time binding only for a new profile, or verifies the
  /// existing binding while unlocking. An empty unbound database is not proof
  /// that a profile is new: browser storage may have been cleared.
  Future<void> bindContext({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required LocalVaultOpenMode mode,
  }) async {
    _validateContext(profileId, localDataDomainId, localVaultId);
    if (profileId != this.profileId ||
        localDataDomainId != this.localDataDomainId ||
        localVaultId != this.localVaultId) {
      throw const FormatException('Local Vault database context mismatch.');
    }

    await transaction(() async {
      final binding = await customSelect(
        'SELECT * FROM local_vault_binding',
      ).get();
      if (binding.isEmpty) {
        if (mode == LocalVaultOpenMode.openExisting) {
          throw const LocalVaultBindingMissingException();
        }
        final recordCount = await customSelect('''
          SELECT
            (SELECT COUNT(*) FROM local_vault_records) +
            (SELECT COUNT(*) FROM local_vault_known_hosts) +
            (SELECT COUNT(*) FROM local_vault_known_host_imports)
            AS count
          ''').getSingle();
        if (recordCount.read<int>('count') != 0) {
          throw const LocalVaultBindingMissingException();
        }
        await customStatement(
          '''
          INSERT INTO local_vault_binding (
            singleton_id, profile_id, local_data_domain_id, local_vault_id,
            schema_version
          ) VALUES (1, ?, ?, ?, 1)
          ''',
          [profileId, localDataDomainId, localVaultId],
        );
      } else {
        _verifyBindingRow(binding, profileId, localDataDomainId, localVaultId);
      }
    });
    await flushCommittedWrites();
  }

  /// Forces committed SQLite page changes through Drift's Web IndexedDB VFS.
  ///
  /// Drift 2.35.0 runs SQLite COMMIT while its transaction flag is still set,
  /// so the Web delegate can defer its IndexedDB flush. This awaited statement
  /// runs after the transaction and acts as a persistence barrier. It is a
  /// read-only PRAGMA and does not modify the Vault schema or user records.
  Future<void> flushCommittedWrites() async {
    await customStatement('PRAGMA data_version');
  }

  /// Checks the persisted binding before each repository operation, so a
  /// database file swapped or modified after opening fails closed.
  Future<void> verifyContext({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
  }) async {
    _validateContext(profileId, localDataDomainId, localVaultId);
    if (profileId != this.profileId ||
        localDataDomainId != this.localDataDomainId ||
        localVaultId != this.localVaultId) {
      throw const FormatException('Local Vault database context mismatch.');
    }
    final binding = await customSelect(
      'SELECT * FROM local_vault_binding',
    ).get();
    _verifyBindingRow(binding, profileId, localDataDomainId, localVaultId);
  }

  /// Returns the exact schema table names for diagnostics and focused tests.
  Future<Set<String>> tableNames() async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ).get();
    return rows.map((row) => row.read<String>('name')).toSet();
  }

  /// Public, metadata-only shape used by migration journal readers.
  Future<Map<String, Object?>?> migrationJournal(String migrationId) async {
    final rows = await customSelect(
      'SELECT * FROM local_vault_migrations WHERE migration_id = ?',
      variables: [Variable<String>(migrationId)],
    ).get();
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const FormatException('Local migration journal is ambiguous.');
    }
    return Map<String, Object?>.unmodifiable(rows.single.data);
  }

  /// Returns staged ciphertext JSON plus its safe source metadata.
  Future<List<Map<String, Object?>>> migrationItems(String migrationId) async {
    final rows = await customSelect(
      '''
      SELECT record_id, source_revision_id, record_type,
             target_envelope_json, target_envelope_sha256, staged_at_ms
      FROM local_vault_migration_items
      WHERE migration_id = ?
      ORDER BY record_id ASC
      ''',
      variables: [Variable<String>(migrationId)],
    ).get();
    return rows
        .map((row) => Map<String, Object?>.unmodifiable(row.data))
        .toList(growable: false);
  }

  /// Returns the exact staged target Vault-creation payload, if present.
  Future<String?> migrationCreatePayload(String migrationId) async {
    final row = await migrationCreatePayloadRow(migrationId);
    return row?['payload_json'] as String?;
  }

  /// Returns opaque persisted request JSON and its digest for integrity checks.
  Future<Map<String, Object?>?> migrationCreatePayloadRow(
    String migrationId,
  ) async {
    final rows = await customSelect(
      'SELECT payload_json, payload_sha256, staged_at_ms '
      'FROM local_vault_migration_create_payloads '
      'WHERE migration_id = ?',
      variables: [Variable<String>(migrationId)],
    ).get();
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const FormatException('Local migration payload is ambiguous.');
    }
    return Map<String, Object?>.unmodifiable(rows.single.data);
  }

  void _verifyBindingRow(
    List<QueryRow> rows,
    String expectedProfileId,
    String expectedDomainId,
    String expectedVaultId,
  ) {
    if (rows.length != 1) {
      throw const FormatException('Local Vault database binding is invalid.');
    }
    final row = rows.single;
    if (row.read<int>('singleton_id') != 1 ||
        row.read<String>('profile_id') != expectedProfileId ||
        row.read<String>('local_data_domain_id') != expectedDomainId ||
        row.read<String>('local_vault_id') != expectedVaultId ||
        row.read<int>('schema_version') != 1) {
      throw const FormatException('Local Vault database context mismatch.');
    }
  }
}

void _validateContext(String profileId, String domainId, String vaultId) {
  if (!isCanonicalLocalProfileId(profileId) ||
      !isCanonicalLocalProfileId(domainId) ||
      !isCanonicalLocalProfileId(vaultId)) {
    throw const FormatException('Local Vault context ID is invalid.');
  }
}
