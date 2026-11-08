import '../domain/window_combination.dart';

import 'dart:convert';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../domain/ansible_inventory_metadata.dart';
import '../domain/known_host.dart';
import '../domain/models.dart';
import '../domain/vault_preference.dart';
import '../domain/snippet_invocation.dart' show validateSnippetDefinition;
import '../ssh/openssh_certificate.dart';
import '../sync/known_host_decision_lock.dart';
import '../terminal/session_log_scope.dart';
import 'local_profile_namespace.dart';
import 'local_profile_service.dart';
import 'local_vault_database.dart';
import '../l10n/l10n.dart';

const _localRecordFormat = 'atermius-local-record-v1';
const _maxLocalEnvelopeJsonChars = 1024 * 1024;
const _maxMigrationTargetEnvelopeBytes = 1024 * 1024;
const _maxMigrationCreatePayloadBytes = 256 * 1024;
const _maxLocalKnownHostRecords = 4096;
const _requiredHostFields = {
  'id',
  'type',
  'name',
  'address',
  'port',
  'username',
  'group_id',
  'credential_id',
  'auth_kind',
  'color',
  'tags',
  'is_favorite',
};
const _allowedHostFields = {
  'protocol',
  'rdp_cert_sha256',
  ..._requiredHostFields,
  'login',
  'jump_host_id',
  'port_forward_profiles',
  '_manifest',
};
const _requiredGroupFields = {'id', 'type', 'name', 'color', 'parent_id'};
const _allowedGroupFields = {
  ..._requiredGroupFields,
  'default_credential_id',
  '_manifest',
};
const _requiredSnippetFields = {
  'id',
  'type',
  'title',
  'body',
  'shell_kind',
  'tags',
};
const _snippetStructuredFields = {
  'execution_mode',
  'program',
  'arguments',
  'parameters',
};
const _requiredPreferenceFields = {
  'id',
  'type',
  'scope',
  'key',
  'value',
  'platform_family',
};
const _outerEnvelopeFields = {
  'format',
  'header',
  'nonce',
  'ciphertext',
  'signature',
};
const _localHeaderFields = {
  'format',
  'schema_version',
  'profile_id',
  'local_data_domain_id',
  'local_vault_id',
  'record_id',
  'revision_id',
  'base_revision_id',
  'operation',
  'crypto_suite',
  'kdf_salt',
};
final _hostTextControl = RegExp(r'[\u0000-\u001f\u007f]');
final _credentialTextControl = RegExp(r'[\u0000-\u001f\u007f]');
final _privateKeyControl = RegExp(
  r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]',
);
final _groupTextControl = RegExp(r'[\u0000-\u001f\u007f]');
final _snippetTextControl = RegExp(r'[\u0000-\u001f\u007f-\u009f]');
final _snippetBodyControl = RegExp(
  r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]',
);
final _preferenceToken = RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$');
final _preferenceJsonKeyControl = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

enum LocalKnownHostTrustStatus { trusted, unknown, changed, revoked, conflict }

/// A first-seen or previously revoked local SSH key awaiting explicit review.
final class LocalKnownHostApprovalRequest {
  const LocalKnownHostApprovalRequest({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.previouslyRevoked,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final bool previouslyRevoked;
}

/// A stale local KnownHost write lost its compare-and-swap.
final class LocalKnownHostConflictException implements Exception {
  const LocalKnownHostConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() => 'Local SSH host-key trust changed while being updated.';
}

/// Decrypted Group data paired with the authenticated current head revision.
class LocalGroupRecord {
  const LocalGroupRecord({required this.group, required this.revisionId});

  final GroupRecord group;
  final String revisionId;

  String get id => group.id;
  String get name => group.name;
  int get color => group.color;
  String? get parentId => group.parentId;
  String? get defaultCredentialId => group.defaultCredentialId;
}

/// A Group create or compare-and-swap lost to another local writer.
class LocalGroupConflictException implements Exception {
  const LocalGroupConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() => 'Local Group changed while it was being edited.';
}

/// A sibling Group already uses this name, ignoring case and surrounding
/// whitespace. The persisted name itself is not included in the error.
class LocalGroupDuplicateException implements Exception {
  const LocalGroupDuplicateException();

  @override
  String toString() => 'A sibling Local Group already uses this name.';
}

enum LocalGroupReferenceKind { childGroup, host }

/// An active Host or child Group still references this Group.
class LocalGroupInUseException implements Exception {
  const LocalGroupInUseException({
    required this.recordId,
    required this.referenceKind,
  });

  final String recordId;
  final LocalGroupReferenceKind referenceKind;

  @override
  String toString() => 'Local Group is still referenced by active records.';
}

/// A decrypted Snippet paired with the authenticated current head revision.
class LocalSnippetRecord {
  const LocalSnippetRecord({required this.snippet, required this.revisionId});

  final SnippetRecord snippet;
  final String revisionId;

  String get id => snippet.id;
  String get title => snippet.title;
}

/// A Snippet create or compare-and-swap lost to another local writer.
class LocalSnippetConflictException implements Exception {
  const LocalSnippetConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() => 'Local Snippet changed while it was being edited.';
}

/// A decrypted local Preference and the authenticated revision of its head.
class LocalPreferenceRecord {
  const LocalPreferenceRecord({
    required this.id,
    required this.scope,
    required this.key,
    required this.value,
    required this.platformFamily,
    required this.revisionId,
  });

  final String id;
  final String scope;
  final String key;
  final Object? value;
  final String platformFamily;
  final String revisionId;
}

/// A Preference create or compare-and-swap lost to another local writer.
class LocalPreferenceConflictException implements Exception {
  const LocalPreferenceConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() => 'Local Preference changed while it was being edited.';
}

/// Another active Preference already occupies the (scope, key, platform) tuple.
class LocalPreferenceDuplicateException implements Exception {
  const LocalPreferenceDuplicateException();

  @override
  String toString() => 'A Local Preference already uses this key.';
}

/// Safe metadata for a Credential list. Secret material is never included in
/// this value or in its JSON representation; callers fetch one item on demand.
class LocalCredentialSummary {
  const LocalCredentialSummary({
    required this.id,
    required this.name,
    required this.username,
    required this.kind,
    required this.revisionId,
    this.fingerprint,
    this.certificate,
  });

  final String id;
  final String name;
  final String username;
  final AuthKind kind;
  final String revisionId;

  /// Public key fingerprint (SHA256:…) recorded when a key was saved.
  final String? fingerprint;

  /// Public OpenSSH user certificate line, if attached.
  final String? certificate;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.credential.name,
    'name': name,
    'username': username,
    'kind': kind.name,
    'revision_id': revisionId,
  };
}

/// One authenticated current LocalVault head. `recordJson` may include
/// Credential secrets and is deliberately an in-memory return value only.
class LocalMigrationSourceItem {
  const LocalMigrationSourceItem({
    required this.recordId,
    required this.sourceRevisionId,
    required this.recordType,
    required this.recordJson,
  });

  final String recordId;
  final String sourceRevisionId;
  final String recordType;
  final Map<String, Object?> recordJson;

  /// The decrypted logical payload; this is an in-memory alias only.
  Map<String, Object?> get plaintext => recordJson;
}

/// One validated plaintext record in the transient Local-only archive payload.
/// The object is never persisted directly; target import immediately signs and
/// encrypts it with the target profile's key hierarchy.
class LocalProfileArchiveRecord {
  const LocalProfileArchiveRecord({
    required this.recordId,
    required this.sourceRevisionId,
    required this.baseRevisionId,
    required this.updatedAtMs,
    required this.isDeleted,
    required this.plaintext,
  });

  final String recordId;
  final String sourceRevisionId;
  final String? baseRevisionId;
  final int updatedAtMs;
  final bool isDeleted;
  final Map<String, Object?> plaintext;

  Map<String, Object?> toJson() => {
    'record_id': recordId,
    'source_revision_id': sourceRevisionId,
    'base_revision_id': baseRevisionId,
    'updated_at_ms': updatedAtMs,
    'is_deleted': isDeleted,
    'plaintext': plaintext,
  };

  factory LocalProfileArchiveRecord.fromJson(Map<String, dynamic> json) {
    const fields = {
      'record_id',
      'source_revision_id',
      'base_revision_id',
      'updated_at_ms',
      'is_deleted',
      'plaintext',
    };
    if (json.keys.toSet().length != fields.length ||
        !json.keys.toSet().containsAll(fields)) {
      throw const FormatException('Local archive record fields are invalid.');
    }
    final recordId = json['record_id'];
    final revisionId = json['source_revision_id'];
    final baseRevisionId = json['base_revision_id'];
    final updatedAtMs = json['updated_at_ms'];
    final isDeleted = json['is_deleted'];
    final rawPlaintext = json['plaintext'];
    if (recordId is! String ||
        revisionId is! String ||
        (baseRevisionId != null && baseRevisionId is! String) ||
        updatedAtMs is! int ||
        updatedAtMs <= 0 ||
        isDeleted is! bool ||
        rawPlaintext is! Map ||
        rawPlaintext.keys.any((key) => key is! String)) {
      throw const FormatException('Local archive record metadata is invalid.');
    }
    _requireUuid(recordId, 'record_id');
    _requireUuid(revisionId, 'source_revision_id');
    if (baseRevisionId != null) {
      _requireUuid(baseRevisionId as String, 'base_revision_id');
    }
    final plaintext = Map<String, Object?>.from(rawPlaintext);
    if (plaintext['id'] != recordId ||
        !const {
          'host',
          'credential',
          'group',
          'snippet',
          'preference',
        }.contains(plaintext['type'])) {
      throw const FormatException('Local archive record context is invalid.');
    }
    if (isDeleted) {
      if (baseRevisionId == null) {
        throw const FormatException('Local archive tombstone base is missing.');
      }
      _validateTombstone(Map<String, dynamic>.from(plaintext), recordId);
    } else if (plaintext.containsKey('deleted')) {
      throw const FormatException('Local archive active record is invalid.');
    }
    return LocalProfileArchiveRecord(
      recordId: recordId,
      sourceRevisionId: revisionId,
      baseRevisionId: baseRevisionId as String?,
      updatedAtMs: updatedAtMs,
      isDeleted: isDeleted,
      plaintext: _immutableMigrationJson(plaintext),
    );
  }
}

/// One locked snapshot for a portable LocalVault archive. KnownHost records
/// remain separate from ordinary LocalVault records and from Vault sync.
class LocalVaultArchiveSnapshot {
  const LocalVaultArchiveSnapshot({
    required this.records,
    required this.knownHosts,
  });

  final List<LocalProfileArchiveRecord> records;
  final List<KnownHostRecord> knownHosts;
}

/// An archived active host-key decision awaiting an explicit destination
/// device review. This candidate is not an SSH trust decision.
class LocalKnownHostArchiveCandidate {
  const LocalKnownHostArchiveCandidate({
    required this.record,
    required this.sourceRevisionId,
  });

  final KnownHostRecord record;
  final String sourceRevisionId;
}

/// Consistent, fully authenticated source snapshot produced while writes are
/// blocked by the LocalVault database migration journal.
class LocalMigrationSnapshot {
  const LocalMigrationSnapshot({
    required this.migrationId,
    required this.targetInstanceId,
    required this.targetVaultId,
    required this.sourceFingerprint,
    required this.items,
  });

  final String migrationId;
  final String targetInstanceId;
  final String targetVaultId;
  final String sourceFingerprint;
  final List<LocalMigrationSourceItem> items;
}

/// Durable safe metadata paired with one exact target encrypted envelope.
class LocalMigrationStagedItem {
  const LocalMigrationStagedItem({
    required this.recordId,
    required this.sourceRevisionId,
    required this.recordType,
    required this.targetEnvelopeJson,
    required this.targetEnvelopeSha256,
  });

  final String recordId;
  final String sourceRevisionId;
  final String recordType;
  final String targetEnvelopeJson;
  final String targetEnvelopeSha256;
}

/// Bounded recovery-list metadata. It deliberately excludes plaintext source
/// records, target envelope JSON, and the staged Vault-create payload.
class LocalMigrationJournalSummary {
  const LocalMigrationJournalSummary({
    required this.migrationId,
    required this.targetInstanceId,
    required this.targetVaultId,
    required this.sourceFingerprint,
    required this.state,
    required this.itemCount,
    required this.stagedItemCount,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.finishedAtMs,
  });

  final String migrationId;
  final String targetInstanceId;
  final String targetVaultId;
  final String sourceFingerprint;
  final String state;
  final int itemCount;
  final int stagedItemCount;
  final int createdAtMs;
  final int updatedAtMs;
  final int? finishedAtMs;
}

/// A stale edit, duplicate create, or update of a deleted record lost its
/// compare-and-swap. Callers should reload the current head before retrying.
class LocalHostConflictException implements Exception {
  const LocalHostConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() => 'Local Host record changed while it was being edited.';
}

/// A Host is still referenced as another Host's Jump Host.
class LocalJumpHostInUseException implements Exception {
  const LocalJumpHostInUseException({
    required this.recordId,
    required this.referencingHostId,
  });

  final String recordId;
  final String referencingHostId;

  @override
  String toString() => 'Local Host is still referenced as a Jump Host.';
}

/// A stale edit, duplicate create, or update/delete of a removed Credential
/// lost its compare-and-swap.
class LocalCredentialConflictException implements Exception {
  const LocalCredentialConflictException({
    required this.recordId,
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  final String recordId;
  final String? expectedRevisionId;
  final String? actualRevisionId;

  @override
  String toString() =>
      'Local Credential record changed while it was being edited.';
}

/// A Credential cannot be deleted while an active Group uses it as a default.
final class LocalCredentialInUseException implements Exception {
  const LocalCredentialInUseException({
    required this.credentialId,
    this.groupId,
    this.hostId,
    this.snippetId,
  });

  final String credentialId;
  final String? groupId;
  final String? hostId;
  final String? snippetId;

  @override
  String toString() => 'A Local record still references this Credential.';
}

/// API-free encrypted CRUD for Host records in a single local-only Vault.
/// Every persisted payload is a signed, profile-bound local record envelope.
class LocalHostRepository {
  LocalHostRepository({
    required this._database,
    required this._profile,
    required this._crypto,
    this._uuid = const Uuid(),
    KnownHostDecisionLock? knownHostDecisionLock,
  }) : knownHostDecisionLock =
           knownHostDecisionLock ?? createKnownHostDecisionLock();

  final LocalVaultDatabase _database;
  final UnlockedLocalProfile _profile;
  final VaultCrypto _crypto;
  final Uuid _uuid;
  final KnownHostDecisionLock knownHostDecisionLock;

  String get profileId => _profile.record.profileId;
  String get localVaultId => _profile.record.localVaultId;
  String get localDeviceId => _profile.record.localDeviceId;
  KnownHostDecisionScope get knownHostDecisionScope => KnownHostDecisionScope(
    serverSpaceId: _profile.record.localDataDomainId,
    vaultId: localVaultId,
  );

  Future<bool> isEmptyForArchiveImport() => _withProfileLease((_, _) async {
    await _verifyContext();
    final row = await _database
        .customSelect(
          '''
          SELECT
            (SELECT COUNT(*) FROM local_vault_records WHERE local_vault_id = ?) +
            (SELECT COUNT(*) FROM local_vault_known_hosts WHERE local_vault_id = ?) +
            (SELECT COUNT(*) FROM local_vault_known_host_imports WHERE local_vault_id = ?)
            AS count
          ''',
          variables: [
            Variable<String>(localVaultId),
            Variable<String>(localVaultId),
            Variable<String>(localVaultId),
          ],
        )
        .getSingle();
    return row.read<int>('count') == 0;
  });

  /// Returns a consistent, authenticated in-memory snapshot for a separate
  /// password-encrypted Local-only archive. Plaintext is never stored in the
  /// LocalVault database; callers must encrypt this result before retaining it.
  Future<List<LocalProfileArchiveRecord>> exportArchiveSnapshot() =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        late final List<LocalProfileArchiveRecord> snapshot;
        await _database.transaction(() async {
          final records = <LocalProfileArchiveRecord>[];
          for (final row in await _listRows()) {
            final authenticated = await _decryptRowPayload(
              row,
              identity,
              vaultKey,
            );
            final plaintext = Map<String, Object?>.from(
              authenticated.plaintext,
            );
            if (_hasUnsupportedObjectReference(plaintext)) {
              throw const FormatException(
                'Local archive cannot include unsupported object references.',
              );
            }
            final baseRevisionId =
                authenticated.header['base_revision_id'] as String?;
            records.add(
              LocalProfileArchiveRecord(
                recordId: row.recordId,
                sourceRevisionId: row.revisionId,
                baseRevisionId: baseRevisionId,
                updatedAtMs: row.updatedAtMs,
                isDeleted: row.isDeleted,
                plaintext: _immutableMigrationJson(plaintext),
              ),
            );
          }
          records.sort((a, b) => a.recordId.compareTo(b.recordId));
          snapshot = List.unmodifiable(records);
        });
        return snapshot;
      });

  /// Captures ordinary records and local SSH trust under one profile lease,
  /// SQLite read transaction and KnownHost decision lock. This prevents a
  /// trust approval or revocation from racing a portable archive export.
  Future<LocalVaultArchiveSnapshot> exportPortableArchiveSnapshot() =>
      knownHostDecisionLock.run(
        knownHostDecisionScope,
        () => _withProfileLease((identity, vaultKey) async {
          await _verifyContext();
          late final LocalVaultArchiveSnapshot snapshot;
          await _database.transaction(() async {
            final records = <LocalProfileArchiveRecord>[];
            for (final row in await _listRows()) {
              final authenticated = await _decryptRowPayload(
                row,
                identity,
                vaultKey,
              );
              final plaintext = Map<String, Object?>.from(
                authenticated.plaintext,
              );
              if (_hasUnsupportedObjectReference(plaintext)) {
                throw const FormatException(
                  'Local archive cannot include unsupported object references.',
                );
              }
              records.add(
                LocalProfileArchiveRecord(
                  recordId: row.recordId,
                  sourceRevisionId: row.revisionId,
                  baseRevisionId:
                      authenticated.header['base_revision_id'] as String?,
                  updatedAtMs: row.updatedAtMs,
                  isDeleted: row.isDeleted,
                  plaintext: _immutableMigrationJson(plaintext),
                ),
              );
            }
            records.sort((a, b) => a.recordId.compareTo(b.recordId));
            final knownHosts = await _loadLocalKnownHosts(identity, vaultKey);
            snapshot = LocalVaultArchiveSnapshot(
              records: List.unmodifiable(records),
              knownHosts: List.unmodifiable(knownHosts),
            );
          });
          return snapshot;
        }),
        mode: KnownHostDecisionLockMode.shared,
      );

  /// Imports a fully decoded archive only into a truly empty LocalVault.
  /// Every record is schema-validated and re-encrypted under the destination
  /// profile before a single SQL write begins; the destination insertion is one
  /// transaction, so a constraint or storage failure cannot leave a partial
  /// profile copy.
  Future<void> importArchiveSnapshot(
    List<LocalProfileArchiveRecord> sourceRecords, {
    List<KnownHostRecord> knownHosts = const [],
  }) => _withProfileLease((identity, vaultKey) async {
    await _verifyContext();
    if (sourceRecords.length > 50000 ||
        knownHosts.length > _maxLocalKnownHostRecords) {
      throw const FormatException('Local archive record count exceeds limit.');
    }

    final validatedKnownHosts = <KnownHostRecord>[];
    final knownHostIds = <String>{};
    for (final source in knownHosts) {
      final sourceRevisionId = source.revisionId;
      if (sourceRevisionId == null || !knownHostIds.add(source.id)) {
        throw const FormatException(
          'Local archive SSH trust metadata is invalid.',
        );
      }
      _requireUuid(source.id, 'known_host.record_id');
      _requireUuid(sourceRevisionId, 'known_host.source_revision_id');
      validatedKnownHosts.add(
        KnownHostRecord.fromJson({
          ...source.toJson(),
          '_record_id': source.id,
          '_revision_id': sourceRevisionId,
        }),
      );
    }

    final validated = <LocalProfileArchiveRecord>[];
    final seenIds = <String>{};
    final activeItems = <LocalMigrationSourceItem>[];
    for (final source in sourceRecords) {
      _requireUuid(source.recordId, 'record_id');
      _requireUuid(source.sourceRevisionId, 'source_revision_id');
      if (!seenIds.add(source.recordId) || source.updatedAtMs <= 0) {
        throw const FormatException(
          'Local archive record metadata is invalid.',
        );
      }
      if (source.plaintext['id'] != source.recordId) {
        throw const FormatException('Local archive record context is invalid.');
      }
      if (source.isDeleted) {
        if (source.baseRevisionId == null) {
          throw const FormatException(
            'Local archive tombstone base is missing.',
          );
        }
        _requireUuid(source.baseRevisionId!, 'base_revision_id');
        _validateTombstone(
          Map<String, dynamic>.from(source.plaintext),
          source.recordId,
        );
        validated.add(source);
        continue;
      }
      if (source.baseRevisionId != null) {
        _requireUuid(source.baseRevisionId!, 'base_revision_id');
      }
      late final Map<String, Object?> plaintext;
      switch (source.plaintext['type']) {
        case 'host':
          plaintext = _validatedHostJson(source.plaintext, id: source.recordId);
          break;
        case 'credential':
          plaintext = _validatedCredentialJson(
            source.plaintext,
            id: source.recordId,
          );
          break;
        case 'group':
          plaintext = _validatedGroupJson(
            source.plaintext,
            id: source.recordId,
          );
          break;
        case 'snippet':
          plaintext = _validatedSnippetJson(
            source.plaintext,
            id: source.recordId,
          );
          break;
        case 'preference':
          plaintext = _validatedPreferenceJson(
            source.plaintext,
            id: source.recordId,
          );
          break;
        default:
          throw const FormatException(
            'Local archive record type is unsupported.',
          );
      }
      if (_hasUnsupportedObjectReference(plaintext)) {
        throw const FormatException(
          'Local archive cannot include unsupported object references.',
        );
      }
      final immutable = _immutableMigrationJson(plaintext);
      final record = LocalProfileArchiveRecord(
        recordId: source.recordId,
        sourceRevisionId: source.sourceRevisionId,
        baseRevisionId: source.baseRevisionId,
        updatedAtMs: source.updatedAtMs,
        isDeleted: false,
        plaintext: immutable,
      );
      validated.add(record);
      activeItems.add(
        LocalMigrationSourceItem(
          recordId: record.recordId,
          sourceRevisionId: record.sourceRevisionId,
          recordType: record.plaintext['type']! as String,
          recordJson: immutable,
        ),
      );
    }
    validated.sort((a, b) => a.recordId.compareTo(b.recordId));
    activeItems.sort((a, b) => a.recordId.compareTo(b.recordId));
    _validateMigrationReferenceClosure(activeItems);

    // Fast fail before expensive envelope creation. The same predicate is
    // checked again under the insertion transaction to close writer races.
    final existingRows = await _database
        .customSelect(
          '''
          SELECT
            (SELECT COUNT(*) FROM local_vault_records WHERE local_vault_id = ?) +
            (SELECT COUNT(*) FROM local_vault_known_hosts WHERE local_vault_id = ?) +
            (SELECT COUNT(*) FROM local_vault_known_host_imports WHERE local_vault_id = ?)
            AS count
          ''',
          variables: [
            Variable<String>(localVaultId),
            Variable<String>(localVaultId),
            Variable<String>(localVaultId),
          ],
        )
        .getSingle();
    if (existingRows.read<int>('count') != 0) {
      throw StateError('Local archive import requires an empty profile.');
    }

    final destination = _profile.record;
    final staged = <_LocalArchiveImportRow>[];
    for (final record in validated) {
      final operation = record.isDeleted ? 'delete' : 'create';
      final baseRevisionId = record.isDeleted ? record.baseRevisionId : null;
      final envelope = await _encrypt(
        identity: identity,
        vaultKey: vaultKey,
        recordId: record.recordId,
        baseRevisionId: baseRevisionId,
        operation: operation,
        plaintext: record.plaintext,
      );
      final revisionId = _envelopeRevision(envelope);
      final envelopeJson = _encodeEnvelope(
        envelope,
        profileId: destination.profileId,
        localDataDomainId: destination.localDataDomainId,
        localVaultId: localVaultId,
        recordId: record.recordId,
        revisionId: revisionId,
        baseRevisionId: baseRevisionId,
        operation: operation,
      );
      staged.add(
        _LocalArchiveImportRow(
          recordId: record.recordId,
          revisionId: revisionId,
          envelopeJson: envelopeJson,
          isDeleted: record.isDeleted,
          updatedAtMs: record.updatedAtMs,
        ),
      );
    }

    final stagedKnownHosts = <_LocalArchiveKnownHostImportRow>[];
    Future<String> stageKnownHost({
      required KnownHostRecord source,
      required Map<String, Object?> plaintext,
      required bool isCandidate,
    }) async {
      final envelope = await _encrypt(
        identity: identity,
        vaultKey: vaultKey,
        recordId: source.id,
        baseRevisionId: null,
        operation: 'create',
        plaintext: plaintext,
      );
      final revisionId = _envelopeRevision(envelope);
      stagedKnownHosts.add(
        _LocalArchiveKnownHostImportRow(
          recordId: source.id,
          sourceRevisionId: source.revisionId!,
          revisionId: revisionId,
          envelopeJson: _encodeEnvelope(
            envelope,
            profileId: destination.profileId,
            localDataDomainId: destination.localDataDomainId,
            localVaultId: localVaultId,
            recordId: source.id,
            revisionId: revisionId,
            baseRevisionId: null,
            operation: 'create',
          ),
          importedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
          isCandidate: isCandidate,
        ),
      );
      return revisionId;
    }

    String sourceHeadKey(String recordId, String revisionId) =>
        '$recordId:$revisionId';
    final knownHostBySourceHead = {
      for (final record in validatedKnownHosts)
        sourceHeadKey(record.id, record.revisionId!): record,
    };
    final pendingRevocations = validatedKnownHosts
        .where((record) => record.state == KnownHostState.revoked)
        .toList();
    final importedRevocationRevisions = <String, String>{};
    for (final record in pendingRevocations) {
      for (final reference in record.observedRevocations) {
        final referenced =
            knownHostBySourceHead[sourceHeadKey(
              reference.recordId,
              reference.revisionId,
            )];
        if (referenced == null || referenced.state != KnownHostState.revoked) {
          throw const FormatException(
            'Local archive SSH revocation references are incomplete.',
          );
        }
      }
    }
    while (pendingRevocations.isNotEmpty) {
      final ready =
          pendingRevocations
              .where(
                (record) => record.observedRevocations.every(
                  (reference) => importedRevocationRevisions.containsKey(
                    sourceHeadKey(reference.recordId, reference.revisionId),
                  ),
                ),
              )
              .toList()
            ..sort((left, right) => left.id.compareTo(right.id));
      if (ready.isEmpty) {
        throw const FormatException(
          'Local archive SSH revocation history contains a cycle.',
        );
      }
      for (final source in ready) {
        final plaintext = source.toJson();
        if (source.observedRevocations.isNotEmpty) {
          plaintext['observed_revocations'] = source.observedRevocations
              .map(
                (reference) => {
                  'record_id': reference.recordId,
                  'revision_id':
                      importedRevocationRevisions[sourceHeadKey(
                        reference.recordId,
                        reference.revisionId,
                      )],
                },
              )
              .toList(growable: false);
        }
        final revisionId = await stageKnownHost(
          source: source,
          plaintext: plaintext,
          isCandidate: false,
        );
        importedRevocationRevisions[sourceHeadKey(
              source.id,
              source.revisionId!,
            )] =
            revisionId;
        pendingRevocations.remove(source);
      }
    }
    for (final source in validatedKnownHosts.where(
      (record) => record.state == KnownHostState.trusted,
    )) {
      await stageKnownHost(
        source: source,
        plaintext: source.toJson(),
        isCandidate: true,
      );
    }

    await _database.transaction(() async {
      await _verifyContext();
      final rows = await _database
          .customSelect(
            '''
            SELECT
              (SELECT COUNT(*) FROM local_vault_records WHERE local_vault_id = ?) +
              (SELECT COUNT(*) FROM local_vault_known_hosts WHERE local_vault_id = ?) +
              (SELECT COUNT(*) FROM local_vault_known_host_imports WHERE local_vault_id = ?)
              AS count
            ''',
            variables: [
              Variable<String>(localVaultId),
              Variable<String>(localVaultId),
              Variable<String>(localVaultId),
            ],
          )
          .getSingle();
      if (rows.read<int>('count') != 0) {
        throw StateError('Local archive import requires an empty profile.');
      }
      for (final row in staged) {
        await _database.customStatement(
          '''
          INSERT INTO local_vault_records (
            local_vault_id, record_id, revision_id, envelope_json,
            is_deleted, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ''',
          [
            localVaultId,
            row.recordId,
            row.revisionId,
            row.envelopeJson,
            row.isDeleted ? 1 : 0,
            row.updatedAtMs,
          ],
        );
      }
      for (final row in stagedKnownHosts) {
        if (row.isCandidate) {
          await _database.customStatement(
            '''
            INSERT INTO local_vault_known_host_imports (
              local_vault_id, record_id, source_revision_id, revision_id,
              envelope_json, imported_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?)
            ''',
            [
              localVaultId,
              row.recordId,
              row.sourceRevisionId,
              row.revisionId,
              row.envelopeJson,
              row.importedAtMs,
            ],
          );
        } else {
          await _database.customStatement(
            '''
            INSERT INTO local_vault_known_hosts (
              local_vault_id, record_id, revision_id, envelope_json, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            ''',
            [
              localVaultId,
              row.recordId,
              row.revisionId,
              row.envelopeJson,
              row.importedAtMs,
            ],
          );
        }
      }
    });
    await _database.flushCommittedWrites();
  });

  /// Authenticates and freezes every current source head in one SQLite
  /// transaction. A failed preflight rolls back both the temporary journal
  /// row and the database trigger gate.
  Future<LocalMigrationSnapshot> prepareMigrationSnapshot({
    required String migrationId,
    required String targetInstanceId,
    required String targetVaultId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(migrationId, 'migration_id');
    _requireUuid(targetInstanceId, 'target_instance_id');
    _requireUuid(targetVaultId, 'target_vault_id');
    await _verifyContext();
    LocalMigrationSnapshot? result;
    await _database.transaction(() async {
      final existing = await _migrationJournal(migrationId);
      if (existing != null) {
        if (existing['status'] == 'frozen' &&
            existing['local_vault_id'] == localVaultId &&
            existing['target_instance_id'] == targetInstanceId &&
            existing['target_vault_id'] == targetVaultId) {
          result = await _readFrozenSnapshot(existing, identity, vaultKey);
          return;
        }
        throw StateError('Local migration ID is already in use.');
      }
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _database.customStatement(
        '''
        INSERT INTO local_vault_migrations (
          migration_id, local_vault_id, target_instance_id, target_vault_id,
          source_fingerprint, expected_item_count, status, created_at_ms,
          finished_at_ms
        ) VALUES (?, ?, ?, ?, '', 0, 'preparing', ?, NULL)
        ''',
        [migrationId, localVaultId, targetInstanceId, targetVaultId, now],
      );
      final sourceItems = await _preflightMigrationItems(identity, vaultKey);
      final fingerprint = await _migrationFingerprint(sourceItems);
      await _database.customStatement(
        '''
        UPDATE local_vault_migrations
        SET source_fingerprint = ?, expected_item_count = ?, status = 'frozen'
        WHERE migration_id = ? AND status = 'preparing'
        ''',
        [fingerprint, sourceItems.length, migrationId],
      );
      result = LocalMigrationSnapshot(
        migrationId: migrationId,
        targetInstanceId: targetInstanceId,
        targetVaultId: targetVaultId,
        sourceFingerprint: fingerprint,
        items: List<LocalMigrationSourceItem>.unmodifiable(sourceItems),
      );
    });
    await _database.flushCommittedWrites();
    return result!;
  });

  /// Rebuilds the snapshot after a restart and checks the persisted source
  /// fingerprint before returning any plaintext to the caller.
  Future<LocalMigrationSnapshot> readMigrationSnapshot(String migrationId) =>
      _withProfileLease((identity, vaultKey) async {
        _requireUuid(migrationId, 'migration_id');
        await _verifyContext();
        return _database.transaction(() async {
          final journal = await _migrationJournal(migrationId);
          if (journal == null ||
              journal['local_vault_id'] != localVaultId ||
              journal['status'] != 'frozen') {
            throw StateError('Local migration is not active.');
          }
          return _readFrozenSnapshot(journal, identity, vaultKey);
        });
      });

  /// Stages one exact target ciphertext. Repeating the same source head and
  /// JSON bytes is idempotent; reusing its ID for different bytes is rejected.
  Future<LocalMigrationStagedItem> stageMigrationItem({
    required String migrationId,
    required String recordId,
    required String sourceRevisionId,
    required String recordType,
    required String targetEnvelopeJson,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(migrationId, 'migration_id');
    _requireUuid(recordId, 'record_id');
    _requireUuid(sourceRevisionId, 'source_revision_id');
    if (!const {
      'host',
      'credential',
      'group',
      'snippet',
      'preference',
    }.contains(recordType)) {
      throw const FormatException('Local migration record type is invalid.');
    }
    _validateTargetRecordEnvelope(
      targetEnvelopeJson,
      recordId: recordId,
      targetVaultId: null,
    );
    await _verifyContext();
    final hash = await _sha256Hex(utf8.encode(targetEnvelopeJson));
    await _database.transaction(() async {
      final journal = await _migrationJournal(migrationId);
      if (journal == null ||
          journal['local_vault_id'] != localVaultId ||
          journal['status'] != 'frozen') {
        throw StateError('Local migration is not active.');
      }
      _validateTargetRecordEnvelope(
        targetEnvelopeJson,
        recordId: recordId,
        targetVaultId: journal['target_vault_id']! as String,
      );
      final sourceRow = await _readRow(recordId);
      if (sourceRow == null ||
          sourceRow.isDeleted ||
          sourceRow.revisionId != sourceRevisionId) {
        throw const FormatException('Local migration source head changed.');
      }
      final authenticated = await _decryptRowPayload(
        sourceRow,
        identity,
        vaultKey,
      );
      if (authenticated.isDeleted ||
          authenticated.plaintext['type'] != recordType) {
        throw const FormatException('Local migration source head changed.');
      }
      final existing = await _database
          .customSelect(
            '''
        SELECT source_revision_id, record_type, target_envelope_json,
               target_envelope_sha256
        FROM local_vault_migration_items
        WHERE migration_id = ? AND record_id = ?
        ''',
            variables: [
              Variable<String>(migrationId),
              Variable<String>(recordId),
            ],
          )
          .get();
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row.read<String>('source_revision_id') == sourceRevisionId &&
            row.read<String>('record_type') == recordType &&
            row.read<String>('target_envelope_json') == targetEnvelopeJson &&
            row.read<String>('target_envelope_sha256') == hash) {
          return;
        }
        throw StateError('Local migration item is already staged.');
      }
      await _database.customStatement(
        '''
        INSERT INTO local_vault_migration_items (
          migration_id, record_id, source_revision_id, record_type,
          target_envelope_json, target_envelope_sha256, staged_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          migrationId,
          recordId,
          sourceRevisionId,
          recordType,
          targetEnvelopeJson,
          hash,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
    });
    await _database.flushCommittedWrites();
    return LocalMigrationStagedItem(
      recordId: recordId,
      sourceRevisionId: sourceRevisionId,
      recordType: recordType,
      targetEnvelopeJson: targetEnvelopeJson,
      targetEnvelopeSha256: hash,
    );
  });

  /// Reads staged target envelopes in stable record-ID order and verifies
  /// their stored digest before exposing the exact JSON to a retrying caller.
  Future<List<LocalMigrationStagedItem>> listStagedMigrationItems(
    String migrationId,
  ) async {
    _requireUuid(migrationId, 'migration_id');
    await _verifyContext();
    final journal = await _migrationJournal(migrationId);
    if (journal == null || journal['local_vault_id'] != localVaultId) {
      throw StateError('Local migration is unavailable.');
    }
    final rows = await _database.migrationItems(migrationId);
    final result = <LocalMigrationStagedItem>[];
    for (final row in rows) {
      final envelopeJson = row['target_envelope_json']! as String;
      final digest = row['target_envelope_sha256']! as String;
      if (await _sha256Hex(utf8.encode(envelopeJson)) != digest) {
        throw const FormatException('Local migration staging is damaged.');
      }
      _validateTargetRecordEnvelope(
        envelopeJson,
        recordId: row['record_id']! as String,
        targetVaultId: journal['target_vault_id']! as String,
      );
      result.add(
        LocalMigrationStagedItem(
          recordId: row['record_id']! as String,
          sourceRevisionId: row['source_revision_id']! as String,
          recordType: row['record_type']! as String,
          targetEnvelopeJson: envelopeJson,
          targetEnvelopeSha256: digest,
        ),
      );
    }
    return List<LocalMigrationStagedItem>.unmodifiable(result);
  }

  /// Lists a bounded set of recovery journals without exposing any record or
  /// encrypted payload contents.
  Future<List<LocalMigrationJournalSummary>> listMigrationJournals({
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 50) {
      throw RangeError('Local migration journal limit must be 1..50.');
    }
    await _verifyContext();
    final rows = await _database
        .customSelect(
          '''
          SELECT j.migration_id, j.target_instance_id, j.target_vault_id,
                 j.source_fingerprint, j.expected_item_count, j.status,
                 j.created_at_ms, j.finished_at_ms,
                 MAX(j.created_at_ms, COALESCE(j.finished_at_ms, 0),
                   COALESCE((SELECT MAX(i.staged_at_ms)
                     FROM local_vault_migration_items i
                     WHERE i.migration_id = j.migration_id), 0))
                   AS updated_at_ms,
                 (SELECT COUNT(*) FROM local_vault_migration_items i
                  WHERE i.migration_id = j.migration_id) AS staged_item_count
          FROM local_vault_migrations j
          WHERE j.local_vault_id = ?
          ORDER BY j.created_at_ms DESC, j.migration_id DESC
          LIMIT ?
          ''',
          variables: [Variable<String>(localVaultId), Variable<int>(limit)],
        )
        .get();
    return List<LocalMigrationJournalSummary>.unmodifiable(
      rows.map((row) {
        final state = row.read<String>('status');
        if (!const {'frozen', 'completed', 'cancelled'}.contains(state)) {
          throw const FormatException('Local migration journal is invalid.');
        }
        return LocalMigrationJournalSummary(
          migrationId: row.read<String>('migration_id'),
          targetInstanceId: row.read<String>('target_instance_id'),
          targetVaultId: row.read<String>('target_vault_id'),
          sourceFingerprint: row.read<String>('source_fingerprint'),
          state: state,
          itemCount: row.read<int>('expected_item_count'),
          stagedItemCount: row.read<int>('staged_item_count'),
          createdAtMs: row.read<int>('created_at_ms'),
          updatedAtMs: row.read<int>('updated_at_ms'),
          finishedAtMs: row.readNullable<int>('finished_at_ms'),
        );
      }),
    );
  }

  /// Stores the exact one-time target Vault creation request before its POST.
  /// It is opaque JSON; raw key and record secret fields are rejected.
  Future<String> stageMigrationCreatePayload({
    required String migrationId,
    required String payloadJson,
  }) async {
    _requireUuid(migrationId, 'migration_id');
    _validateMigrationCreatePayload(payloadJson);
    await _verifyContext();
    final digest = await _sha256Hex(utf8.encode(payloadJson));
    await _database.transaction(() async {
      final journal = await _migrationJournal(migrationId);
      if (journal == null ||
          journal['local_vault_id'] != localVaultId ||
          journal['status'] != 'frozen') {
        throw StateError('Local migration is not active.');
      }
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      if (payload['vault_id'] != journal['target_vault_id']) {
        throw const FormatException('Target Vault payload context mismatch.');
      }
      final existing = await _database
          .customSelect(
            'SELECT payload_json, payload_sha256 '
            'FROM local_vault_migration_create_payloads WHERE migration_id = ?',
            variables: [Variable<String>(migrationId)],
          )
          .get();
      if (existing.isNotEmpty) {
        if (existing.single.read<String>('payload_json') == payloadJson &&
            existing.single.read<String>('payload_sha256') == digest) {
          return;
        }
        throw StateError('Target Vault creation payload is already staged.');
      }
      await _database.customStatement(
        '''
        INSERT INTO local_vault_migration_create_payloads (
          migration_id, payload_json, payload_sha256, staged_at_ms
        ) VALUES (?, ?, ?, ?)
        ''',
        [
          migrationId,
          payloadJson,
          digest,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
    });
    await _database.flushCommittedWrites();
    return digest;
  }

  /// Returns the exact previously staged Vault create body for retry or
  /// uncertain-ACK reconciliation.
  Future<String?> readMigrationCreatePayload(String migrationId) async {
    _requireUuid(migrationId, 'migration_id');
    await _verifyContext();
    final journal = await _migrationJournal(migrationId);
    if (journal == null || journal['local_vault_id'] != localVaultId) {
      throw StateError('Local migration is unavailable.');
    }
    final stored = await _database.migrationCreatePayloadRow(migrationId);
    final payload = stored?['payload_json'] as String?;
    if (payload != null) {
      if (await _sha256Hex(utf8.encode(payload)) != stored!['payload_sha256']) {
        throw const FormatException('Local migration staging is damaged.');
      }
      _validateMigrationCreatePayload(payload);
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      if (decoded['vault_id'] != journal['target_vault_id']) {
        throw const FormatException('Target Vault payload context mismatch.');
      }
    }
    return payload;
  }

  /// Completes the source-side journal and removes the persistent write gate.
  /// Caller must only invoke this after independently verifying the target.
  Future<void> finishMigration(String migrationId) async => _withProfileLease((
    identity,
    vaultKey,
  ) async {
    _requireUuid(migrationId, 'migration_id');
    await _verifyContext();
    await _database.transaction(() async {
      final journal = await _migrationJournal(migrationId);
      if (journal == null ||
          journal['local_vault_id'] != localVaultId ||
          journal['status'] != 'frozen') {
        throw StateError('Local migration is not active.');
      }
      final sourceItems = await _preflightMigrationItems(identity, vaultKey);
      final fingerprint = await _migrationFingerprint(sourceItems);
      if (fingerprint != journal['source_fingerprint'] ||
          sourceItems.length != journal['expected_item_count']) {
        throw const FormatException('Local migration source changed.');
      }
      final itemRows = await _database
          .customSelect(
            'SELECT COUNT(*) AS count FROM local_vault_migration_items '
            'WHERE migration_id = ?',
            variables: [Variable<String>(migrationId)],
          )
          .getSingle();
      if (itemRows.read<int>('count') != journal['expected_item_count'] ||
          await _database.migrationCreatePayload(migrationId) == null) {
        throw StateError('Local migration staging is incomplete.');
      }
      await _validateStoredMigrationStaging(migrationId, journal, sourceItems);
      await _database.customStatement(
        '''
        UPDATE local_vault_migrations
        SET status = 'completed', finished_at_ms = ?
        WHERE migration_id = ? AND status = 'frozen'
        ''',
        [DateTime.now().toUtc().millisecondsSinceEpoch, migrationId],
      );
    });
    await _database.flushCommittedWrites();
  });

  /// Cancels an empty preparation before Vault creation is staged.
  /// Use [abandonMigration] to stop after staging has begun.
  Future<void> cancelMigration(String migrationId) async {
    _requireUuid(migrationId, 'migration_id');
    await _verifyContext();
    await _database.transaction(() async {
      final journal = await _migrationJournal(migrationId);
      if (journal == null ||
          journal['local_vault_id'] != localVaultId ||
          journal['status'] != 'frozen') {
        throw StateError('Local migration is not active.');
      }
      final stagedCount = await _database
          .customSelect(
            'SELECT COUNT(*) AS count FROM local_vault_migration_items '
            'WHERE migration_id = ?',
            variables: [Variable<String>(migrationId)],
          )
          .getSingle();
      if (stagedCount.read<int>('count') != 0 ||
          await _database.migrationCreatePayload(migrationId) != null) {
        throw StateError(
          'Local migration cannot be cancelled after target staging begins.',
        );
      }
      await _database.customStatement(
        '''
        UPDATE local_vault_migrations
        SET status = 'cancelled', finished_at_ms = ?
        WHERE migration_id = ? AND status = 'frozen'
        ''',
        [DateTime.now().toUtc().millisecondsSinceEpoch, migrationId],
      );
    });
    await _database.flushCommittedWrites();
  }

  /// Stops any still-frozen migration and restores source writes. Target Vault
  /// creation, committed envelopes, and queued target operations are retained;
  /// this method never deletes or rewrites destination data.
  Future<void> abandonMigration(String migrationId) async {
    _requireUuid(migrationId, 'migration_id');
    await _verifyContext();
    await _database.transaction(() async {
      final journal = await _migrationJournal(migrationId);
      if (journal == null ||
          journal['local_vault_id'] != localVaultId ||
          journal['status'] != 'frozen') {
        throw StateError('Local migration is not active.');
      }
      await _database.customStatement(
        '''
        UPDATE local_vault_migrations
        SET status = 'cancelled', finished_at_ms = ?
        WHERE migration_id = ? AND status = 'frozen'
        ''',
        [DateTime.now().toUtc().millisecondsSinceEpoch, migrationId],
      );
    });
    await _database.flushCommittedWrites();
  }

  /// Creates a Host under a new stable UUID unless an import supplies one.
  /// Caller-supplied IDs are still required to be canonical UUIDs.
  Future<HostRecord> createHost(HostRecord draft, {String? recordId}) =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final id = recordId ?? _uuid.v4();
        _requireUuid(id, 'record_id');
        final plaintext = _validatedHostJson(draft.toJson(), id: id);
        final envelope = await _encrypt(
          identity: identity,
          vaultKey: vaultKey,
          recordId: id,
          baseRevisionId: null,
          operation: 'create',
          plaintext: plaintext,
        );
        final revisionId = _envelopeRevision(envelope);
        final envelopeJson = _encodeEnvelope(
          envelope,
          profileId: _profile.record.profileId,
          localDataDomainId: _profile.record.localDataDomainId,
          localVaultId: localVaultId,
          recordId: id,
          revisionId: revisionId,
          baseRevisionId: null,
          operation: 'create',
        );
        final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        try {
          await _database.transaction(() async {
            await _requireActiveGroupId(draft.groupId, identity, vaultKey);
            await _requireActiveCredentialId(
              draft.credentialId,
              identity,
              vaultKey,
            );
            await _requireActiveJumpHost(
              hostId: id,
              jumpHostId: draft.jumpHostId,
              identity: identity,
              vaultKey: vaultKey,
            );
            await _database.customStatement(
              '''
              INSERT INTO local_vault_records (
                local_vault_id, record_id, revision_id, envelope_json,
                is_deleted, updated_at_ms
              ) VALUES (?, ?, ?, ?, 0, ?)
              ''',
              [localVaultId, id, revisionId, envelopeJson, updatedAtMs],
            );
          });
        } on Object {
          final existing = await _readRow(id);
          if (existing != null) {
            throw LocalHostConflictException(
              recordId: id,
              expectedRevisionId: null,
              actualRevisionId: existing.revisionId,
            );
          }
          rethrow;
        }
        await _database.flushCommittedWrites();
        return _hostWithRevision(plaintext, revisionId, null);
      });

  /// Creates a Credential with its caller supplied stable UUID. Credential
  /// fields are validated before they enter the signed encrypted envelope.
  Future<CredentialRecord> createCredential(CredentialRecord draft) =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final id = draft.id;
        _requireUuid(id, 'record_id');
        final plaintext = _validatedCredentialJson(draft.toJson(), id: id);
        final envelope = await _encrypt(
          identity: identity,
          vaultKey: vaultKey,
          recordId: id,
          baseRevisionId: null,
          operation: 'create',
          plaintext: plaintext,
        );
        final revisionId = _envelopeRevision(envelope);
        final envelopeJson = _encodeEnvelope(
          envelope,
          profileId: _profile.record.profileId,
          localDataDomainId: _profile.record.localDataDomainId,
          localVaultId: localVaultId,
          recordId: id,
          revisionId: revisionId,
          baseRevisionId: null,
          operation: 'create',
        );
        final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        try {
          await _database.transaction(() async {
            await _database.customStatement(
              '''
              INSERT INTO local_vault_records (
                local_vault_id, record_id, revision_id, envelope_json,
                is_deleted, updated_at_ms
              ) VALUES (?, ?, ?, ?, 0, ?)
              ''',
              [localVaultId, id, revisionId, envelopeJson, updatedAtMs],
            );
          });
        } on Object {
          final existing = await _readRow(id);
          if (existing != null) {
            throw LocalCredentialConflictException(
              recordId: id,
              expectedRevisionId: null,
              actualRevisionId: existing.revisionId,
            );
          }
          rethrow;
        }
        await _database.flushCommittedWrites();
        return _credentialWithRevision(plaintext, revisionId);
      });

  /// Reads one Credential on demand. Deleted records and IDs belonging to a
  /// different record kind are reported as absent after envelope validation.
  Future<CredentialRecord?> getCredential(String recordId) =>
      _withProfileLease((identity, vaultKey) async {
        _requireUuid(recordId, 'record_id');
        await _verifyContext();
        final row = await _readRow(recordId);
        if (row == null) return null;
        return _decryptCredentialRow(row, identity, vaultKey);
      });

  /// Resolves an explicit Host Credential first, then walks the Host's Group
  /// ancestry from nearest to farthest for a default Credential. Broken
  /// references and cyclic Group data fail closed.
  Future<CredentialRecord?> resolveCredentialForHost(HostRecord host) async {
    if (host.login != null) {
      final issue = host.validate();
      if (issue != null) throw FormatException(issue);
      // Inline secrets obey the same unlocked-profile boundary as legacy
      // credential reads, including after the caller retained a Host object.
      return _withProfileLease((_, _) async {
        await _verifyContext();
        return host.login!.forHost(host);
      });
    }
    final explicitCredentialId = host.credentialId;
    if (explicitCredentialId != null) {
      final credential = await getCredential(explicitCredentialId);
      if (credential == null) {
        throw const FormatException('Local Host Credential is unavailable.');
      }
      return credential;
    }

    final initialGroupId = host.groupId;
    if (initialGroupId == null) return null;
    final groups = {for (final item in await listGroups()) item.id: item.group};
    final visited = <String>{};
    var currentId = initialGroupId;
    while (true) {
      if (!visited.add(currentId)) {
        throw const FormatException('Local Group hierarchy contains a cycle.');
      }
      final group = groups[currentId];
      if (group == null) {
        throw const FormatException(
          'Local Host Group reference is unavailable.',
        );
      }
      final defaultCredentialId = group.defaultCredentialId;
      if (defaultCredentialId != null) {
        final credential = await getCredential(defaultCredentialId);
        if (credential == null) {
          throw const FormatException(
            'Local Group default Credential is unavailable.',
          );
        }
        return credential;
      }
      final parentId = group.parentId;
      if (parentId == null) return null;
      currentId = parentId;
    }
  }

  /// Decrypts active Credentials for callers that explicitly need their
  /// secrets. Prefer [listCredentialSummaries] for list and picker UI state.
  Future<List<CredentialRecord>> listCredentials() => _withProfileLease((
    identity,
    vaultKey,
  ) async {
    await _verifyContext();
    final rows = await _listRows();
    final credentials = <CredentialRecord>[];
    for (final row in rows) {
      final credential = await _decryptCredentialRow(row, identity, vaultKey);
      if (credential != null) credentials.add(credential);
    }
    return List.unmodifiable(credentials);
  });

  /// Returns metadata-only Credential values suitable for persistent UI
  /// state. No password, private key, or passphrase is copied into the result.
  Future<List<LocalCredentialSummary>> listCredentialSummaries() =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final rows = await _listRows();
        final summaries = <LocalCredentialSummary>[];
        for (final row in rows) {
          final authenticated = await _decryptRowPayload(
            row,
            identity,
            vaultKey,
          );
          if (authenticated.isDeleted ||
              authenticated.plaintext['type'] != RecordKind.credential.name) {
            continue;
          }
          final credential = _credentialWithRevision(
            _validatedCredentialJson(authenticated.plaintext, id: row.recordId),
            row.revisionId,
          );
          summaries.add(
            LocalCredentialSummary(
              id: credential.id,
              name: credential.name,
              username: credential.username,
              kind: credential.kind,
              revisionId: row.revisionId,
              fingerprint: credential.fingerprint,
              certificate: credential.certificate,
            ),
          );
        }
        return List.unmodifiable(summaries);
      });

  /// Replaces the current Credential only if [baseRevisionId] is still its
  /// authenticated current head. Cross-kind ID collisions cannot change a
  /// Host into a Credential.
  Future<CredentialRecord> updateCredential({
    required CredentialRecord credential,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(credential.id, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = _validatedCredentialJson(
      credential.toJson(),
      id: credential.id,
    );
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: credential.id,
      baseRevisionId: baseRevisionId,
      operation: 'update',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: credential.id,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'update',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(credential.id);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.credential.name) {
          throw LocalCredentialConflictException(
            recordId: credential.id,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalCredentialConflictException(
          recordId: credential.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 0,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          credential.id,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(credential.id);
      if (updated.length != 1 || updated.single['revision_id'] != revisionId) {
        throw LocalCredentialConflictException(
          recordId: credential.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
    return _credentialWithRevision(plaintext, revisionId);
  });

  /// Stores an authenticated encrypted tombstone for a Credential.
  Future<void> deleteCredential({
    required String recordId,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(recordId, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = <String, Object?>{
      'id': recordId,
      'type': RecordKind.credential.name,
      'deleted': true,
    };
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(recordId);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.credential.name) {
          throw LocalCredentialConflictException(
            recordId: recordId,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalCredentialConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireCredentialHasNoReferences(recordId, identity, vaultKey);
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 1,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          recordId,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(recordId);
      if (updated.length != 1 ||
          updated.single['revision_id'] != revisionId ||
          updated.single['is_deleted'] != 1) {
        throw LocalCredentialConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
  });

  /// Creates an encrypted Group with the stable ID in [group]. A parent must
  /// already be active in this same LocalVault, and the hierarchy is checked
  /// while holding the SQLite write transaction.
  Future<LocalGroupRecord> createGroup(GroupRecord group) =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final id = group.id;
        _requireUuid(id, 'record_id');
        final plaintext = _validatedGroupJson(group.toJson(), id: id);
        final envelope = await _encrypt(
          identity: identity,
          vaultKey: vaultKey,
          recordId: id,
          baseRevisionId: null,
          operation: 'create',
          plaintext: plaintext,
        );
        final revisionId = _envelopeRevision(envelope);
        final envelopeJson = _encodeEnvelope(
          envelope,
          profileId: _profile.record.profileId,
          localDataDomainId: _profile.record.localDataDomainId,
          localVaultId: localVaultId,
          recordId: id,
          revisionId: revisionId,
          baseRevisionId: null,
          operation: 'create',
        );
        final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        try {
          await _database.transaction(() async {
            await _requireAcyclicParent(
              groupId: id,
              parentId: group.parentId,
              identity: identity,
              vaultKey: vaultKey,
            );
            await _requireActiveCredentialId(
              group.defaultCredentialId,
              identity,
              vaultKey,
            );
            await _requireUniqueGroupName(
              groupId: id,
              name: group.name,
              parentId: group.parentId,
              identity: identity,
              vaultKey: vaultKey,
            );
            await _database.customStatement(
              '''
              INSERT INTO local_vault_records (
                local_vault_id, record_id, revision_id, envelope_json,
                is_deleted, updated_at_ms
              ) VALUES (?, ?, ?, ?, 0, ?)
              ''',
              [localVaultId, id, revisionId, envelopeJson, updatedAtMs],
            );
          });
        } on LocalGroupConflictException {
          rethrow;
        } on FormatException {
          rethrow;
        } on Object {
          final existing = await _readRow(id);
          if (existing != null) {
            throw LocalGroupConflictException(
              recordId: id,
              expectedRevisionId: null,
              actualRevisionId: existing.revisionId,
            );
          }
          rethrow;
        }
        await _database.flushCommittedWrites();
        return LocalGroupRecord(
          group: _groupFromPlaintext(plaintext),
          revisionId: revisionId,
        );
      });

  /// Reads and authenticates one active Group. IDs owned by another record
  /// kind and encrypted tombstones are returned as absent.
  Future<LocalGroupRecord?> getGroup(String recordId) =>
      _withProfileLease((identity, vaultKey) async {
        _requireUuid(recordId, 'record_id');
        await _verifyContext();
        final row = await _readRow(recordId);
        if (row == null) return null;
        return _decryptGroupRow(row, identity, vaultKey);
      });

  /// Lists active Groups in deterministic storage order.
  Future<List<LocalGroupRecord>> listGroups() =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final rows = await _listRows();
        final groups = <LocalGroupRecord>[];
        for (final row in rows) {
          final group = await _decryptGroupRow(row, identity, vaultKey);
          if (group != null) groups.add(group);
        }
        return List.unmodifiable(groups);
      });

  /// Replaces a Group only if the current head still matches
  /// [baseRevisionId]. Parent existence and cycle validation share the write
  /// transaction with the CAS so concurrent hierarchy changes cannot race.
  Future<LocalGroupRecord> updateGroup({
    required GroupRecord group,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(group.id, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = _validatedGroupJson(group.toJson(), id: group.id);
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: group.id,
      baseRevisionId: baseRevisionId,
      operation: 'update',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: group.id,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'update',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(group.id);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.group.name) {
          throw LocalGroupConflictException(
            recordId: group.id,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalGroupConflictException(
          recordId: group.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireAcyclicParent(
        groupId: group.id,
        parentId: group.parentId,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _requireActiveCredentialId(
        group.defaultCredentialId,
        identity,
        vaultKey,
      );
      await _requireUniqueGroupName(
        groupId: group.id,
        name: group.name,
        parentId: group.parentId,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 0,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          group.id,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(group.id);
      if (updated.length != 1 || updated.single['revision_id'] != revisionId) {
        throw LocalGroupConflictException(
          recordId: group.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
    return LocalGroupRecord(
      group: _groupFromPlaintext(plaintext),
      revisionId: revisionId,
    );
  });

  /// Stores an authenticated Group tombstone when no active Host or child
  /// Group refers to it. Reference checks and the CAS are atomic.
  Future<void> deleteGroup({
    required String recordId,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(recordId, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = <String, Object?>{
      'id': recordId,
      'type': RecordKind.group.name,
      'deleted': true,
    };
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(recordId);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.group.name) {
          throw LocalGroupConflictException(
            recordId: recordId,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalGroupConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireGroupHasNoReferences(recordId, identity, vaultKey);
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 1,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          recordId,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(recordId);
      if (updated.length != 1 ||
          updated.single['revision_id'] != revisionId ||
          updated.single['is_deleted'] != 1) {
        throw LocalGroupConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
  });

  /// Creates a local Snippet in the existing ciphertext-only record table.
  /// The supplied Snippet ID remains stable across file reopen and edits.
  Future<LocalSnippetRecord> createSnippet(SnippetRecord snippet) =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        _requireUuid(snippet.id, 'record_id');
        final plaintext = _validatedSnippetJson(
          snippet.toJson(),
          id: snippet.id,
        );
        final envelope = await _encrypt(
          identity: identity,
          vaultKey: vaultKey,
          recordId: snippet.id,
          baseRevisionId: null,
          operation: 'create',
          plaintext: plaintext,
        );
        final revisionId = _envelopeRevision(envelope);
        final envelopeJson = _encodeEnvelope(
          envelope,
          profileId: _profile.record.profileId,
          localDataDomainId: _profile.record.localDataDomainId,
          localVaultId: localVaultId,
          recordId: snippet.id,
          revisionId: revisionId,
          baseRevisionId: null,
          operation: 'create',
        );
        final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        try {
          await _database.transaction(() async {
            await _requireSnippetCredentialReferences(
              plaintext,
              identity,
              vaultKey,
            );
            await _database.customStatement(
              '''
              INSERT INTO local_vault_records (
                local_vault_id, record_id, revision_id, envelope_json,
                is_deleted, updated_at_ms
              ) VALUES (?, ?, ?, ?, 0, ?)
              ''',
              [localVaultId, snippet.id, revisionId, envelopeJson, updatedAtMs],
            );
          });
        } on Object {
          final existing = await _readRow(snippet.id);
          if (existing != null) {
            throw LocalSnippetConflictException(
              recordId: snippet.id,
              expectedRevisionId: null,
              actualRevisionId: existing.revisionId,
            );
          }
          rethrow;
        }
        await _database.flushCommittedWrites();
        return LocalSnippetRecord(
          snippet: _snippetWithRevision(plaintext, revisionId),
          revisionId: revisionId,
        );
      });

  /// Reads one active Snippet. Tombstones and IDs belonging to another record
  /// kind are authenticated and returned as absent.
  Future<LocalSnippetRecord?> getSnippet(String recordId) =>
      _withProfileLease((identity, vaultKey) async {
        _requireUuid(recordId, 'record_id');
        await _verifyContext();
        final row = await _readRow(recordId);
        if (row == null) return null;
        return _decryptSnippetRow(row, identity, vaultKey);
      });

  /// Lists all active Snippets in the deterministic LocalVault record order.
  Future<List<LocalSnippetRecord>> listSnippets() =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final rows = await _listRows();
        final snippets = <LocalSnippetRecord>[];
        for (final row in rows) {
          final snippet = await _decryptSnippetRow(row, identity, vaultKey);
          if (snippet != null) snippets.add(snippet);
        }
        return List.unmodifiable(snippets);
      });

  /// Replaces a Snippet only when [expectedRevisionId] still identifies its
  /// active head. Type and revision checks are made in the same SQL transaction.
  Future<LocalSnippetRecord> updateSnippet(
    SnippetRecord snippet, {
    required String expectedRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(snippet.id, 'record_id');
    _requireUuid(expectedRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = _validatedSnippetJson(snippet.toJson(), id: snippet.id);
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: snippet.id,
      baseRevisionId: expectedRevisionId,
      operation: 'update',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: snippet.id,
      revisionId: revisionId,
      baseRevisionId: expectedRevisionId,
      operation: 'update',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(snippet.id);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.snippet.name) {
          throw LocalSnippetConflictException(
            recordId: snippet.id,
            expectedRevisionId: expectedRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != expectedRevisionId) {
        throw LocalSnippetConflictException(
          recordId: snippet.id,
          expectedRevisionId: expectedRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireSnippetCredentialReferences(plaintext, identity, vaultKey);
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 0,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          snippet.id,
          expectedRevisionId,
        ],
      );
      final updated = await _selectRow(snippet.id);
      if (updated.length != 1 || updated.single['revision_id'] != revisionId) {
        throw LocalSnippetConflictException(
          recordId: snippet.id,
          expectedRevisionId: expectedRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
    return LocalSnippetRecord(
      snippet: _snippetWithRevision(plaintext, revisionId),
      revisionId: revisionId,
    );
  });

  /// Writes an encrypted Snippet tombstone. A later create cannot silently
  /// resurrect the removed record ID.
  Future<void> deleteSnippet(
    String recordId, {
    required String expectedRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(recordId, 'record_id');
    _requireUuid(expectedRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = <String, Object?>{
      'id': recordId,
      'type': RecordKind.snippet.name,
      'deleted': true,
    };
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: recordId,
      baseRevisionId: expectedRevisionId,
      operation: 'delete',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: expectedRevisionId,
      operation: 'delete',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(recordId);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.snippet.name) {
          throw LocalSnippetConflictException(
            recordId: recordId,
            expectedRevisionId: expectedRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != expectedRevisionId) {
        throw LocalSnippetConflictException(
          recordId: recordId,
          expectedRevisionId: expectedRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 1,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          recordId,
          expectedRevisionId,
        ],
      );
      final updated = await _selectRow(recordId);
      if (updated.length != 1 ||
          updated.single['revision_id'] != revisionId ||
          updated.single['is_deleted'] != 1) {
        throw LocalSnippetConflictException(
          recordId: recordId,
          expectedRevisionId: expectedRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
  });

  /// Lists every active local Preference. Values are JSON-only and returned
  /// as immutable nested maps/lists.
  Future<List<LocalPreferenceRecord>> listPreferences() => _withProfileLease((
    identity,
    vaultKey,
  ) async {
    await _verifyContext();
    final rows = await _listRows();
    final preferences = <LocalPreferenceRecord>[];
    for (final row in rows) {
      final preference = await _decryptPreferenceRow(row, identity, vaultKey);
      if (preference != null) preferences.add(preference);
    }
    return List.unmodifiable(preferences);
  });

  /// Looks up an active Preference by its unique logical key. It fails closed
  /// if storage contains more than one active record for the same tuple.
  Future<LocalPreferenceRecord?> getPreference({
    required String scope,
    required String key,
    required String platformFamily,
  }) => _withProfileLease((identity, vaultKey) async {
    _validatePreferenceTuple(scope, key, platformFamily);
    await _verifyContext();
    LocalPreferenceRecord? match;
    for (final row in await _listRows()) {
      final preference = await _decryptPreferenceRow(row, identity, vaultKey);
      if (preference == null ||
          preference.scope != scope ||
          preference.key != key ||
          preference.platformFamily != platformFamily) {
        continue;
      }
      if (match != null) {
        throw const FormatException('Local Preference key is ambiguous.');
      }
      match = preference;
    }
    return match;
  });

  /// Creates an encrypted local Preference. `(scope, key, platformFamily)`
  /// must be unique among active Preference records.
  Future<LocalPreferenceRecord> createPreference({
    required String scope,
    required String key,
    required Object? value,
    required String platformFamily,
  }) => _withProfileLease((identity, vaultKey) async {
    await _verifyContext();
    _validatePreferenceTuple(scope, key, platformFamily);
    final id = _uuid.v4();
    _requireUuid(id, 'record_id');
    final plaintext = _validatedPreferenceJson({
      'id': id,
      'type': RecordKind.preference.name,
      'scope': scope,
      'key': key,
      'value': value,
      'platform_family': platformFamily,
    }, id: id);
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: id,
      baseRevisionId: null,
      operation: 'create',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: id,
      revisionId: revisionId,
      baseRevisionId: null,
      operation: 'create',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      await _requireUniquePreferenceTuple(
        id: id,
        scope: scope,
        key: key,
        platformFamily: platformFamily,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _database.customStatement(
        '''
        INSERT INTO local_vault_records (
          local_vault_id, record_id, revision_id, envelope_json,
          is_deleted, updated_at_ms
        ) VALUES (?, ?, ?, ?, 0, ?)
        ''',
        [localVaultId, id, revisionId, envelopeJson, updatedAtMs],
      );
    });
    await _database.flushCommittedWrites();
    return _preferenceWithRevision(plaintext, revisionId);
  });

  /// Replaces a Preference only if [baseRevisionId] still identifies its
  /// active head. The unique logical key is checked in the same transaction.
  Future<LocalPreferenceRecord> updatePreference({
    required LocalPreferenceRecord preference,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(preference.id, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    _validatePreferenceTuple(
      preference.scope,
      preference.key,
      preference.platformFamily,
    );
    final plaintext = _validatedPreferenceJson({
      'id': preference.id,
      'type': RecordKind.preference.name,
      'scope': preference.scope,
      'key': preference.key,
      'value': preference.value,
      'platform_family': preference.platformFamily,
    }, id: preference.id);
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: preference.id,
      baseRevisionId: baseRevisionId,
      operation: 'update',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: preference.id,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'update',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(preference.id);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.preference.name) {
          throw LocalPreferenceConflictException(
            recordId: preference.id,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalPreferenceConflictException(
          recordId: preference.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireUniquePreferenceTuple(
        id: preference.id,
        scope: preference.scope,
        key: preference.key,
        platformFamily: preference.platformFamily,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 0,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          preference.id,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(preference.id);
      if (updated.length != 1 || updated.single['revision_id'] != revisionId) {
        throw LocalPreferenceConflictException(
          recordId: preference.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
    return _preferenceWithRevision(plaintext, revisionId);
  });

  /// Replaces an active Preference with an authenticated encrypted tombstone.
  Future<void> deletePreference({
    required String recordId,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(recordId, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = <String, Object?>{
      'id': recordId,
      'type': RecordKind.preference.name,
      'deleted': true,
    };
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(recordId);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.preference.name) {
          throw LocalPreferenceConflictException(
            recordId: recordId,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalPreferenceConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 1,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          recordId,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(recordId);
      if (updated.length != 1 ||
          updated.single['revision_id'] != revisionId ||
          updated.single['is_deleted'] != 1) {
        throw LocalPreferenceConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
  });

  /// Reads and decrypts a Host. Tombstones are authenticated and returned as
  /// absent records, so callers cannot accidentally revive a deleted head.
  Future<HostRecord?> getHost(String recordId) =>
      _withProfileLease((identity, vaultKey) async {
        _requireUuid(recordId, 'record_id');
        await _verifyContext();
        final row = await _readRow(recordId);
        if (row == null) return null;
        return _decryptHostRow(row, identity, vaultKey);
      });

  /// Lists all active Hosts in deterministic order and authenticates every
  /// envelope before returning any decrypted record.
  Future<List<HostRecord>> listHosts() =>
      _withProfileLease((identity, vaultKey) async {
        await _verifyContext();
        final rows = await _listRows();
        final hosts = <HostRecord>[];
        for (final row in rows) {
          final host = await _decryptHostRow(row, identity, vaultKey);
          if (host != null) hosts.add(host);
        }
        return List.unmodifiable(hosts);
      });

  /// Writes an update only if the current head still has [baseRevisionId].
  /// The SQL transaction makes the head check and replacement one CAS.
  Future<HostRecord> updateHost({
    required HostRecord host,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(host.id, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = _validatedHostJson(host.toJson(), id: host.id);
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: host.id,
      baseRevisionId: baseRevisionId,
      operation: 'update',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: host.id,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'update',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(host.id);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.host.name) {
          throw LocalHostConflictException(
            recordId: host.id,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalHostConflictException(
          recordId: host.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireActiveGroupId(host.groupId, identity, vaultKey);
      await _requireActiveCredentialId(host.credentialId, identity, vaultKey);
      await _requireActiveJumpHost(
        hostId: host.id,
        jumpHostId: host.jumpHostId,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 0,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          host.id,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(host.id);
      if (updated.length != 1 || updated.single['revision_id'] != revisionId) {
        throw LocalHostConflictException(
          recordId: host.id,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
    return _hostWithRevision(plaintext, revisionId, baseRevisionId);
  });

  /// Stores an encrypted, signed tombstone. It remains in the database so
  /// local history cannot silently resurrect a removed Host.
  Future<void> deleteHost({
    required String recordId,
    required String baseRevisionId,
  }) => _withProfileLease((identity, vaultKey) async {
    _requireUuid(recordId, 'record_id');
    _requireUuid(baseRevisionId, 'base_revision_id');
    await _verifyContext();
    final plaintext = <String, Object?>{
      'id': recordId,
      'type': RecordKind.host.name,
      'deleted': true,
    };
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: 'delete',
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _database.transaction(() async {
      final rows = await _selectRow(recordId);
      if (rows.isNotEmpty && rows.single['is_deleted'] == 0) {
        final current = await _decryptRowPayload(
          _decodeRow(rows.single),
          identity,
          vaultKey,
        );
        if (current.plaintext['type'] != RecordKind.host.name) {
          throw LocalHostConflictException(
            recordId: recordId,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: rows.single['revision_id'] as String?,
          );
        }
      }
      if (rows.isEmpty ||
          rows.single['is_deleted'] == 1 ||
          rows.single['revision_id'] != baseRevisionId) {
        throw LocalHostConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: rows.isEmpty
              ? null
              : rows.single['revision_id'] as String?,
        );
      }
      await _requireNoJumpDependants(
        recordId: recordId,
        identity: identity,
        vaultKey: vaultKey,
      );
      await _database.customStatement(
        '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?, is_deleted = 1,
            updated_at_ms = ?
        WHERE local_vault_id = ? AND record_id = ?
          AND revision_id = ? AND is_deleted = 0
        ''',
        [
          revisionId,
          envelopeJson,
          updatedAtMs,
          localVaultId,
          recordId,
          baseRevisionId,
        ],
      );
      final updated = await _selectRow(recordId);
      if (updated.length != 1 ||
          updated.single['revision_id'] != revisionId ||
          updated.single['is_deleted'] != 1) {
        throw LocalHostConflictException(
          recordId: recordId,
          expectedRevisionId: baseRevisionId,
          actualRevisionId: updated.isEmpty
              ? null
              : updated.single['revision_id'] as String?,
        );
      }
    });
    await _database.flushCommittedWrites();
  });

  Future<void> _verifyContext() async {
    final record = _profile.record;
    if (record.profileId != _database.profileId ||
        record.localDataDomainId != _database.localDataDomainId ||
        record.localVaultId != _database.localVaultId) {
      throw const FormatException('Local Host repository context mismatch.');
    }
    await _database.verifyContext(
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
  }

  Future<Map<String, Object?>?> _migrationJournal(String migrationId) =>
      _database.migrationJournal(migrationId);

  Future<LocalMigrationSnapshot> _readFrozenSnapshot(
    Map<String, Object?> journal,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    if (journal['local_vault_id'] != localVaultId ||
        journal['status'] != 'frozen' ||
        journal['migration_id'] is! String ||
        journal['target_instance_id'] is! String ||
        journal['target_vault_id'] is! String ||
        journal['source_fingerprint'] is! String ||
        journal['expected_item_count'] is! int) {
      throw const FormatException('Local migration journal is invalid.');
    }
    final items = await _preflightMigrationItems(identity, vaultKey);
    final fingerprint = await _migrationFingerprint(items);
    if (fingerprint != journal['source_fingerprint'] ||
        items.length != journal['expected_item_count']) {
      throw const FormatException('Local migration source changed.');
    }
    return LocalMigrationSnapshot(
      migrationId: journal['migration_id']! as String,
      targetInstanceId: journal['target_instance_id']! as String,
      targetVaultId: journal['target_vault_id']! as String,
      sourceFingerprint: fingerprint,
      items: List<LocalMigrationSourceItem>.unmodifiable(items),
    );
  }

  Future<List<LocalMigrationSourceItem>> _preflightMigrationItems(
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final items = <LocalMigrationSourceItem>[];
    for (final row in await _listRows()) {
      final authenticated = await _decryptRowPayload(row, identity, vaultKey);
      if (authenticated.isDeleted) {
        throw const FormatException(
          'Local migration cannot include tombstone history.',
        );
      }
      final type = authenticated.plaintext['type']! as String;
      late final Map<String, Object?> recordJson;
      switch (type) {
        case 'host':
          recordJson = _validatedHostJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          break;
        case 'credential':
          recordJson = _validatedCredentialJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          break;
        case 'group':
          recordJson = _validatedGroupJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          break;
        case 'snippet':
          recordJson = _validatedSnippetJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          break;
        case 'preference':
          recordJson = _validatedPreferenceJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          // Device-local terminal history stays in its encrypted source Profile.
          // It is never implicitly uploaded as a Vault preference during migration.
          if (recordJson['scope'] == 'terminal-history' &&
              recordJson['platform_family'] == 'all' &&
              (recordJson['key'] as String).startsWith('host-'))
            continue;
          // Device-local session logs/transcripts never enter a sync Vault.
          if (recordJson['scope'] == localSessionLogPreferenceScope &&
              recordJson['platform_family'] == 'all')
            continue;
          _validateSupportedMigrationPreference(recordJson);
          break;
        default:
          throw const FormatException(
            'Local migration record type is unsupported.',
          );
      }
      if (_hasUnsupportedObjectReference(recordJson)) {
        throw const FormatException(
          'Local migration cannot include object references.',
        );
      }
      items.add(
        LocalMigrationSourceItem(
          recordId: row.recordId,
          sourceRevisionId: row.revisionId,
          recordType: type,
          recordJson: _immutableMigrationJson(recordJson),
        ),
      );
    }
    items.sort((a, b) => a.recordId.compareTo(b.recordId));
    _validateMigrationReferenceClosure(items);
    return items;
  }

  Future<String> _migrationFingerprint(
    List<LocalMigrationSourceItem> items,
  ) async {
    final rows = items
        .map(
          (item) => {
            'record_id': item.recordId,
            'revision_id': item.sourceRevisionId,
            'type': item.recordType,
          },
        )
        .toList(growable: false);
    return _sha256Hex(utf8.encode(canonicalJson(rows)));
  }

  Future<void> _validateStoredMigrationStaging(
    String migrationId,
    Map<String, Object?> journal,
    List<LocalMigrationSourceItem> sourceItems,
  ) async {
    final createPayloadRows = await _database
        .customSelect(
          'SELECT payload_json, payload_sha256 '
          'FROM local_vault_migration_create_payloads WHERE migration_id = ?',
          variables: [Variable<String>(migrationId)],
        )
        .get();
    if (createPayloadRows.length != 1) {
      throw StateError('Local migration Vault payload is missing.');
    }
    final createPayload = createPayloadRows.single.read<String>('payload_json');
    if (await _sha256Hex(utf8.encode(createPayload)) !=
        createPayloadRows.single.read<String>('payload_sha256')) {
      throw const FormatException('Local migration staging is damaged.');
    }
    _validateMigrationCreatePayload(createPayload);
    final parsedCreatePayload =
        jsonDecode(createPayload) as Map<String, dynamic>;
    if (parsedCreatePayload['vault_id'] != journal['target_vault_id']) {
      throw const FormatException('Target Vault payload context mismatch.');
    }
    final staged = await _database.migrationItems(migrationId);
    final byRecordId = <String, Map<String, Object?>>{};
    for (final row in staged) {
      final recordId = row['record_id']! as String;
      if (byRecordId.containsKey(recordId)) {
        throw const FormatException('Local migration staging is ambiguous.');
      }
      final envelopeJson = row['target_envelope_json']! as String;
      final digest = row['target_envelope_sha256']! as String;
      if (await _sha256Hex(utf8.encode(envelopeJson)) != digest) {
        throw const FormatException('Local migration staging is damaged.');
      }
      _validateTargetRecordEnvelope(
        envelopeJson,
        recordId: recordId,
        targetVaultId: journal['target_vault_id']! as String,
      );
      byRecordId[recordId] = row;
    }
    if (byRecordId.length != sourceItems.length) {
      throw const FormatException('Local migration staging is inconsistent.');
    }
    for (final source in sourceItems) {
      final stagedRow = byRecordId[source.recordId];
      if (stagedRow == null ||
          stagedRow['source_revision_id'] != source.sourceRevisionId ||
          stagedRow['record_type'] != source.recordType) {
        throw const FormatException('Local migration staging is incomplete.');
      }
    }
  }

  Future<void> _requireActiveGroupId(
    String? groupId,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    if (groupId == null) return;
    _requireUuid(groupId, 'group_id');
    final row = await _readRow(groupId);
    if (row == null ||
        await _decryptGroupRow(row, identity, vaultKey) == null) {
      throw const FormatException('Local Host Group reference is invalid.');
    }
  }

  Future<void> _requireActiveCredentialId(
    String? credentialId,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    if (credentialId == null) return;
    _requireUuid(credentialId, 'default_credential_id');
    final row = await _readRow(credentialId);
    if (row == null ||
        await _decryptCredentialRow(row, identity, vaultKey) == null) {
      throw const FormatException('Local Credential reference is invalid.');
    }
  }

  Future<void> _requireSnippetCredentialReferences(
    Map<String, Object?> plaintext,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    if (!plaintext.containsKey('parameters')) return;
    final parameters = plaintext['parameters'];
    if (parameters is! List) {
      throw const FormatException('Local Snippet parameters are invalid.');
    }
    final checkedCredentialIds = <String>{};
    for (final rawParameter in parameters) {
      if (rawParameter is! Map || rawParameter['type'] != 'credentialSecret') {
        continue;
      }
      final credentialId = rawParameter['credential_id'];
      if (credentialId is! String) {
        throw const FormatException('Local Credential parameter is invalid.');
      }
      if (!checkedCredentialIds.add(credentialId)) continue;
      await _requireActiveCredentialId(credentialId, identity, vaultKey);
    }
  }

  Future<void> _requireCredentialHasNoReferences(
    String credentialId,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    for (final row in await _listRows()) {
      if (row.recordId == credentialId) continue;
      final authenticated = await _decryptRowPayload(row, identity, vaultKey);
      if (authenticated.isDeleted) continue;
      switch (authenticated.plaintext['type']) {
        case 'host':
          final host = _validatedHostJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          if (host['credential_id'] == credentialId) {
            throw LocalCredentialInUseException(
              credentialId: credentialId,
              hostId: row.recordId,
            );
          }
          break;
        case 'group':
          final group = _validatedGroupJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          if (group['default_credential_id'] == credentialId) {
            throw LocalCredentialInUseException(
              credentialId: credentialId,
              groupId: row.recordId,
            );
          }
          break;
        case 'snippet':
          final snippet = _validatedSnippetJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          final parameters = snippet['parameters']! as List;
          if (parameters.any(
            (parameter) =>
                parameter is Map &&
                parameter['type'] == 'credentialSecret' &&
                parameter['credential_id'] == credentialId,
          )) {
            throw LocalCredentialInUseException(
              credentialId: credentialId,
              snippetId: row.recordId,
            );
          }
      }
    }
  }

  Future<void> _requireActiveJumpHost({
    required String hostId,
    required String? jumpHostId,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
  }) async {
    if (jumpHostId != null) _requireUuid(jumpHostId, 'jump_host_id');
    final routes = <String, String?>{};
    for (final row in await _listRows()) {
      final host = await _decryptHostRow(row, identity, vaultKey);
      if (host != null) routes[host.id] = host.jumpHostId;
    }
    routes[hostId] = jumpHostId;
    if (jumpHostId != null && !routes.containsKey(jumpHostId)) {
      throw const FormatException('Local Jump Host reference is not active.');
    }
    _validateJumpHostRoutes(routes, changedHostId: hostId);
  }

  void _validateJumpHostRoutes(
    Map<String, String?> routes, {
    required String changedHostId,
  }) {
    for (final startId in routes.keys) {
      var currentId = startId;
      var routeLength = 0;
      var includesChangedHost = startId == changedHostId;
      final seen = <String>{startId};
      while (true) {
        final nextId = routes[currentId];
        if (nextId == null) break;
        if (nextId == changedHostId) includesChangedHost = true;
        final exists = routes.containsKey(nextId);
        if (!exists) {
          if (includesChangedHost) {
            throw const FormatException(
              'Local Jump Host reference is not active.',
            );
          }
          break;
        }
        routeLength++;
        if (!seen.add(nextId)) {
          if (includesChangedHost) {
            throw const FormatException(
              'Local Jump Host route contains a cycle.',
            );
          }
          break;
        }
        if (routeLength > maxJumpHostHops) {
          if (includesChangedHost) {
            throw const FormatException(
              'Local Jump Host route exceeds the 8-hop limit.',
            );
          }
          break;
        }
        currentId = nextId;
      }
    }
  }

  Future<void> _requireNoJumpDependants({
    required String recordId,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
  }) async {
    for (final row in await _listRows()) {
      if (row.recordId == recordId) continue;
      final host = await _decryptHostRow(row, identity, vaultKey);
      if (host?.jumpHostId == recordId) {
        throw LocalJumpHostInUseException(
          recordId: recordId,
          referencingHostId: host!.id,
        );
      }
    }
  }

  Future<void> _requireAcyclicParent({
    required String groupId,
    required String? parentId,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
  }) async {
    final visited = <String>{groupId};
    var nextParentId = parentId;
    while (nextParentId != null) {
      if (!visited.add(nextParentId)) {
        throw const FormatException('Local Group hierarchy contains a cycle.');
      }
      final row = await _readRow(nextParentId);
      if (row == null) {
        throw const FormatException('Local Group parent is not active.');
      }
      final parent = await _decryptGroupRow(row, identity, vaultKey);
      if (parent == null) {
        throw const FormatException('Local Group parent is not active.');
      }
      nextParentId = parent.parentId;
    }
  }

  Future<void> _requireUniqueGroupName({
    required String groupId,
    required String name,
    required String? parentId,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
  }) async {
    final normalizedName = name.trim().toLowerCase();
    for (final row in await _listRows()) {
      if (row.recordId == groupId || row.isDeleted) continue;
      final existing = await _decryptGroupRow(row, identity, vaultKey);
      if (existing != null &&
          existing.parentId == parentId &&
          existing.name.trim().toLowerCase() == normalizedName) {
        throw const LocalGroupDuplicateException();
      }
    }
  }

  Future<void> _requireUniquePreferenceTuple({
    required String id,
    required String scope,
    required String key,
    required String platformFamily,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
  }) async {
    for (final row in await _listRows()) {
      if (row.recordId == id) continue;
      final existing = await _decryptPreferenceRow(row, identity, vaultKey);
      if (existing != null &&
          existing.scope == scope &&
          existing.key == key &&
          existing.platformFamily == platformFamily) {
        throw const LocalPreferenceDuplicateException();
      }
    }
  }

  Future<void> _requireGroupHasNoReferences(
    String groupId,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    for (final row in await _listRows()) {
      if (row.recordId == groupId) continue;
      final authenticated = await _decryptRowPayload(row, identity, vaultKey);
      if (authenticated.isDeleted) continue;
      switch (authenticated.plaintext['type']) {
        case 'host':
          final host = _validatedHostJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          if (host['group_id'] == groupId) {
            throw LocalGroupInUseException(
              recordId: row.recordId,
              referenceKind: LocalGroupReferenceKind.host,
            );
          }
          break;
        case 'group':
          final child = _validatedGroupJson(
            authenticated.plaintext,
            id: row.recordId,
          );
          if (child['parent_id'] == groupId) {
            throw LocalGroupInUseException(
              recordId: row.recordId,
              referenceKind: LocalGroupReferenceKind.childGroup,
            );
          }
          break;
        default:
          break;
      }
    }
  }

  /// Lists only the encrypted KnownHost side table for this LocalVault. These
  /// records are intentionally excluded from archive export and local-to-sync
  /// migration, so local trust can never become synchronized Vault trust.
  Future<List<KnownHostRecord>> listKnownHosts() => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => _withProfileLease((identity, vaultKey) async {
      await _verifyContext();
      return _loadLocalKnownHosts(identity, vaultKey);
    }),
    mode: KnownHostDecisionLockMode.shared,
  );

  /// Returns archived active approvals that are encrypted locally but do not
  /// participate in SSH trust evaluation until explicitly approved.
  Future<List<LocalKnownHostArchiveCandidate>>
  listImportedKnownHostCandidates() => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => _withProfileLease((identity, vaultKey) async {
      await _verifyContext();
      final rows = await _database
          .customSelect(
            '''
            SELECT local_vault_id, record_id, revision_id, envelope_json,
                   imported_at_ms AS updated_at_ms, source_revision_id
            FROM local_vault_known_host_imports
            WHERE local_vault_id = ?
            ORDER BY record_id
            LIMIT ?
            ''',
            variables: [
              Variable<String>(localVaultId),
              const Variable<int>(_maxLocalKnownHostRecords + 1),
            ],
          )
          .get();
      if (rows.length > _maxLocalKnownHostRecords) {
        throw const FormatException(
          'Imported SSH trust candidate count exceeds limit.',
        );
      }
      final candidates = <LocalKnownHostArchiveCandidate>[];
      for (final row in rows) {
        final data = row.data;
        final sourceRevisionId = data['source_revision_id'];
        if (sourceRevisionId is! String) {
          throw const FormatException(
            'Imported SSH trust candidate metadata is invalid.',
          );
        }
        _requireUuid(sourceRevisionId, 'known_host.source_revision_id');
        final record = await _decryptLocalKnownHostRow(
          _decodeLocalKnownHostRow(data),
          identity,
          vaultKey,
        );
        if (record.state != KnownHostState.trusted) {
          throw const FormatException(
            'Imported SSH trust candidate state is invalid.',
          );
        }
        candidates.add(
          LocalKnownHostArchiveCandidate(
            record: record,
            sourceRevisionId: sourceRevisionId,
          ),
        );
      }
      return List.unmodifiable(candidates);
    }),
    mode: KnownHostDecisionLockMode.shared,
  );

  /// Converts one pending archive candidate into a fresh local approval only
  /// after explicit destination-device confirmation. Archived active records
  /// themselves never become trust heads; the fresh approval observes the
  /// destination's current revocation revisions.
  Future<KnownHostRecord> approveImportedKnownHost({
    required String candidateId,
    required bool explicitlyConfirmed,
    DateTime? approvedAt,
  }) => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => _withProfileLease((identity, vaultKey) async {
      await _verifyContext();
      _requireUuid(candidateId, 'known_host_candidate_id');
      if (!explicitlyConfirmed) {
        throw StateError(
          'Imported SSH host-key approval requires explicit confirmation.',
        );
      }
      final candidateRows = await _database
          .customSelect(
            '''
            SELECT local_vault_id, record_id, revision_id, envelope_json,
                   imported_at_ms AS updated_at_ms, source_revision_id
            FROM local_vault_known_host_imports
            WHERE local_vault_id = ? AND record_id = ?
            ''',
            variables: [
              Variable<String>(localVaultId),
              Variable<String>(candidateId),
            ],
          )
          .get();
      if (candidateRows.length != 1) {
        throw StateError('Imported SSH host-key candidate was not found.');
      }
      final candidateRow = candidateRows.single.data;
      final candidate = await _decryptLocalKnownHostRow(
        _decodeLocalKnownHostRow(candidateRow),
        identity,
        vaultKey,
      );
      if (candidate.state != KnownHostState.trusted ||
          candidate.id != candidateId) {
        throw const FormatException(
          'Imported SSH host-key candidate context is invalid.',
        );
      }

      final currentRecords = await _loadLocalKnownHosts(identity, vaultKey);
      final status = _localKnownHostStatus(
        currentRecords,
        endpoint: candidate.endpoint,
        algorithm: candidate.algorithm,
        fingerprint: candidate.fingerprint,
      );
      if (status == LocalKnownHostTrustStatus.changed ||
          status == LocalKnownHostTrustStatus.conflict) {
        throw StateError(
          'A different or conflicting SSH key is trusted for this endpoint; resolve it before importing this approval.',
        );
      }
      if (status == LocalKnownHostTrustStatus.trusted) {
        final existing = currentRecords.singleWhere(
          (record) =>
              record.state == KnownHostState.trusted &&
              record.endpoint == candidate.endpoint &&
              record.matchesKey(
                algorithm: candidate.algorithm,
                fingerprint: candidate.fingerprint,
              ),
        );
        await _database.transaction(() async {
          await _deleteKnownHostImportCandidate(
            candidateId: candidateId,
            expectedRevisionId: candidateRow['revision_id']! as String,
          );
        });
        await _database.flushCommittedWrites();
        return existing;
      }

      final observedRevocations = <KnownHostRevocationReference>[];
      for (final revoked in currentRecords.where(
        (record) =>
            record.endpoint == candidate.endpoint &&
            record.state == KnownHostState.revoked &&
            record.matchesKey(
              algorithm: candidate.algorithm,
              fingerprint: candidate.fingerprint,
            ),
      )) {
        final revisionId = revoked.revisionId;
        if (revisionId == null) {
          throw StateError(
            'Local SSH revocation history is incomplete; imported approval is blocked.',
          );
        }
        observedRevocations.add(
          KnownHostRevocationReference(
            recordId: revoked.id,
            revisionId: revisionId,
          ),
        );
      }
      final approved = KnownHostRecord.approve(
        host: candidate.host,
        port: candidate.port,
        algorithm: candidate.algorithm,
        fingerprint: candidate.fingerprint,
        approvalSource: KnownHostApprovalSource.knownHostsImport,
        approvedByDeviceId: identity.deviceId,
        approvedAt: (approvedAt ?? DateTime.now().toUtc()).toUtc(),
        observedRevocations: observedRevocations,
      );
      final envelope = await _encrypt(
        identity: identity,
        vaultKey: vaultKey,
        recordId: approved.id,
        baseRevisionId: null,
        operation: 'create',
        plaintext: approved.toJson(),
      );
      final revisionId = _envelopeRevision(envelope);
      final envelopeJson = _encodeEnvelope(
        envelope,
        profileId: _profile.record.profileId,
        localDataDomainId: _profile.record.localDataDomainId,
        localVaultId: localVaultId,
        recordId: approved.id,
        revisionId: revisionId,
        baseRevisionId: null,
        operation: 'create',
      );
      final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _database.transaction(() async {
        await _database.customStatement(
          '''
          INSERT INTO local_vault_known_hosts (
            local_vault_id, record_id, revision_id, envelope_json, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          [localVaultId, approved.id, revisionId, envelopeJson, updatedAtMs],
        );
        await _deleteKnownHostImportCandidate(
          candidateId: candidateId,
          expectedRevisionId: candidateRow['revision_id']! as String,
        );
      });
      await _database.flushCommittedWrites();
      return KnownHostRecord.fromJson({
        ...approved.toJson(),
        '_record_id': approved.id,
        '_revision_id': revisionId,
      });
    }),
  );

  Future<void> _deleteKnownHostImportCandidate({
    required String candidateId,
    required String expectedRevisionId,
  }) async {
    final matching = await _database
        .customSelect(
          '''
          SELECT COUNT(*) AS count FROM local_vault_known_host_imports
          WHERE local_vault_id = ? AND record_id = ? AND revision_id = ?
          ''',
          variables: [
            Variable<String>(localVaultId),
            Variable<String>(candidateId),
            Variable<String>(expectedRevisionId),
          ],
        )
        .getSingle();
    if (matching.read<int>('count') != 1) {
      throw StateError(
        'Imported SSH host-key candidate changed during review.',
      );
    }
    await _database.customStatement(
      '''
      DELETE FROM local_vault_known_host_imports
      WHERE local_vault_id = ? AND record_id = ? AND revision_id = ?
      ''',
      [localVaultId, candidateId, expectedRevisionId],
    );
    final remaining = await _database
        .customSelect(
          '''
          SELECT COUNT(*) AS count FROM local_vault_known_host_imports
          WHERE local_vault_id = ? AND record_id = ?
          ''',
          variables: [
            Variable<String>(localVaultId),
            Variable<String>(candidateId),
          ],
        )
        .getSingle();
    if (remaining.read<int>('count') != 0) {
      throw StateError(
        'Imported SSH host-key candidate changed during review.',
      );
    }
  }

  Future<LocalKnownHostTrustStatus> knownHostTrustStatus({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => knownHostTrustStatusWhileDecisionLockHeld(
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
    ),
    mode: KnownHostDecisionLockMode.shared,
  );

  /// Reads the local trust projection without reacquiring its decision lock.
  /// Call only while holding [knownHostDecisionLock] in shared mode for
  /// [knownHostDecisionScope]. This supports the SSH handshake path, which
  /// holds that lock through user authentication and must not queue a nested
  /// reader behind a pending writer.
  Future<LocalKnownHostTrustStatus> knownHostTrustStatusWhileDecisionLockHeld({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) => _withProfileLease((identity, vaultKey) async {
    await _verifyContext();
    final canonicalHost = canonicalizeKnownHost(host);
    final endpoint = endpointKey(host: canonicalHost, port: port);
    return _localKnownHostStatus(
      await _loadLocalKnownHosts(identity, vaultKey),
      endpoint: endpoint,
      algorithm: algorithm,
      fingerprint: fingerprint,
    );
  });

  /// Persists an approval only after the caller received an explicit user
  /// confirmation. A changed key must first have its old approval revoked;
  /// revocations are retained as authenticated history rather than deleted.
  Future<KnownHostRecord> approveKnownHost({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
    required bool explicitlyConfirmed,
    KnownHostApprovalSource approvalSource =
        KnownHostApprovalSource.interactiveConfirmation,
    DateTime? approvedAt,
  }) => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => _withProfileLease((identity, vaultKey) async {
      await _verifyContext();
      if (!explicitlyConfirmed ||
          approvalSource != KnownHostApprovalSource.interactiveConfirmation) {
        throw StateError(
          'Local SSH host-key approval requires explicit user confirmation.',
        );
      }
      final canonicalHost = canonicalizeKnownHost(host);
      final endpoint = endpointKey(host: canonicalHost, port: port);
      final records = await _loadLocalKnownHosts(identity, vaultKey);
      final status = _localKnownHostStatus(
        records,
        endpoint: endpoint,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
      if (status == LocalKnownHostTrustStatus.trusted) {
        return records.singleWhere(
          (record) =>
              record.endpoint == endpoint &&
              record.state == KnownHostState.trusted &&
              record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
        );
      }
      if (status == LocalKnownHostTrustStatus.changed ||
          status == LocalKnownHostTrustStatus.conflict) {
        throw StateError(
          'A different or conflicting SSH key is trusted for this endpoint; revoke its trust before approving another key.',
        );
      }
      if (status == LocalKnownHostTrustStatus.revoked &&
          records.any(
            (record) =>
                record.endpoint == endpoint &&
                record.state == KnownHostState.trusted &&
                record.matchesKey(
                  algorithm: algorithm,
                  fingerprint: fingerprint,
                ),
          )) {
        throw StateError(
          'A stale active SSH approval must be revoked before approving this previously revoked key.',
        );
      }

      final observedRevocations = <KnownHostRevocationReference>[];
      for (final revoked in records.where(
        (record) =>
            record.endpoint == endpoint &&
            record.state == KnownHostState.revoked &&
            record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
      )) {
        final revisionId = revoked.revisionId;
        if (revisionId == null) {
          throw StateError(
            'Local SSH revocation history is incomplete; approval is blocked.',
          );
        }
        observedRevocations.add(
          KnownHostRevocationReference(
            recordId: revoked.id,
            revisionId: revisionId,
          ),
        );
      }
      final approved = KnownHostRecord.approve(
        host: canonicalHost,
        port: port,
        algorithm: algorithm,
        fingerprint: fingerprint,
        approvalSource: approvalSource,
        approvedByDeviceId: identity.deviceId,
        approvedAt: (approvedAt ?? DateTime.now().toUtc()).toUtc(),
        observedRevocations: observedRevocations,
      );
      return _persistLocalKnownHost(
        record: approved,
        identity: identity,
        vaultKey: vaultKey,
        operation: 'create',
      );
    }),
  );

  Future<KnownHostRecord> revokeKnownHost({
    required String recordId,
    DateTime? revokedAt,
  }) => knownHostDecisionLock.run(
    knownHostDecisionScope,
    () => _withProfileLease((identity, vaultKey) async {
      await _verifyContext();
      _requireUuid(recordId, 'record_id');
      final records = await _loadLocalKnownHosts(identity, vaultKey);
      final current = records
          .where((record) => record.id == recordId)
          .firstOrNull;
      if (current == null) {
        throw StateError('Local SSH host-key approval was not found.');
      }
      if (current.state == KnownHostState.revoked) return current;
      final revisionId = current.revisionId;
      if (revisionId == null) {
        throw StateError('Local SSH host-key revision is missing.');
      }
      final revoked = current.revoke(
        revokedByDeviceId: identity.deviceId,
        revokedAt: (revokedAt ?? DateTime.now().toUtc()).toUtc(),
      );
      return _persistLocalKnownHost(
        record: revoked,
        identity: identity,
        vaultKey: vaultKey,
        baseRevisionId: revisionId,
        operation: 'update',
      );
    }),
  );

  Future<List<KnownHostRecord>> _loadLocalKnownHosts(
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final rows = await _database
        .customSelect(
          '''
          SELECT * FROM local_vault_known_hosts
          WHERE local_vault_id = ?
          ORDER BY record_id
          LIMIT ?
          ''',
          variables: [
            Variable<String>(localVaultId),
            const Variable<int>(_maxLocalKnownHostRecords + 1),
          ],
        )
        .get();
    if (rows.length > _maxLocalKnownHostRecords) {
      throw const FormatException(
        'Local SSH trust record count exceeds limit.',
      );
    }
    final records = <KnownHostRecord>[];
    for (final row in rows) {
      records.add(
        await _decryptLocalKnownHostRow(
          _decodeLocalKnownHostRow(row.data),
          identity,
          vaultKey,
        ),
      );
    }
    return records;
  }

  Future<KnownHostRecord> _persistLocalKnownHost({
    required KnownHostRecord record,
    required DeviceIdentity identity,
    required Uint8List vaultKey,
    required String operation,
    String? baseRevisionId,
  }) async {
    final plaintext = record.toJson();
    final envelope = await _encrypt(
      identity: identity,
      vaultKey: vaultKey,
      recordId: record.id,
      baseRevisionId: baseRevisionId,
      operation: operation,
      plaintext: plaintext,
    );
    final revisionId = _envelopeRevision(envelope);
    final envelopeJson = _encodeEnvelope(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: record.id,
      revisionId: revisionId,
      baseRevisionId: baseRevisionId,
      operation: operation,
    );
    final updatedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (operation == 'create') {
      try {
        await _database.transaction(() async {
          await _database.customStatement(
            '''
            INSERT INTO local_vault_known_hosts (
              local_vault_id, record_id, revision_id, envelope_json, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            ''',
            [localVaultId, record.id, revisionId, envelopeJson, updatedAtMs],
          );
        });
      } on Object {
        final existing = await _readLocalKnownHostRows(record.id);
        if (existing.isNotEmpty) {
          throw LocalKnownHostConflictException(
            recordId: record.id,
            expectedRevisionId: null,
            actualRevisionId: existing.single['revision_id'] as String?,
          );
        }
        rethrow;
      }
    } else {
      await _database.transaction(() async {
        await _database.customStatement(
          '''
          UPDATE local_vault_known_hosts
          SET revision_id = ?, envelope_json = ?, updated_at_ms = ?
          WHERE local_vault_id = ? AND record_id = ? AND revision_id = ?
          ''',
          [
            revisionId,
            envelopeJson,
            updatedAtMs,
            localVaultId,
            record.id,
            baseRevisionId,
          ],
        );
        final updated = await _readLocalKnownHostRows(record.id);
        if (updated.length != 1 ||
            updated.single['revision_id'] != revisionId) {
          throw LocalKnownHostConflictException(
            recordId: record.id,
            expectedRevisionId: baseRevisionId,
            actualRevisionId: updated.isEmpty
                ? null
                : updated.single['revision_id'] as String?,
          );
        }
      });
    }
    await _database.flushCommittedWrites();
    return KnownHostRecord.fromJson({
      ...record.toJson(),
      '_record_id': record.id,
      '_revision_id': revisionId,
    });
  }

  Future<KnownHostRecord> _decryptLocalKnownHostRow(
    _LocalKnownHostRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    _requireUuid(row.recordId, 'record_id');
    _requireUuid(row.revisionId, 'revision_id');
    if (row.localVaultId != localVaultId || row.updatedAtMs <= 0) {
      throw const FormatException('Local SSH trust metadata is invalid.');
    }
    final envelope = _decodeEnvelope(row.envelopeJson);
    final header = _validateEnvelopeHeader(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: row.recordId,
      revisionId: row.revisionId,
    );
    if (!const {'create', 'update'}.contains(header['operation'])) {
      throw const FormatException('Local SSH trust operation is invalid.');
    }
    final record = _profile.record;
    final plaintext = await _crypto.decryptLocalRecord(
      vaultKey: vaultKey,
      envelope: envelope,
      expectedProfileId: record.profileId,
      expectedLocalDataDomainId: record.localDataDomainId,
      expectedLocalVaultId: record.localVaultId,
      authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
    );
    if (plaintext['id'] != row.recordId ||
        plaintext['type'] != 'knownHost' ||
        plaintext.containsKey('deleted')) {
      throw const FormatException('Local SSH trust record context is invalid.');
    }
    return KnownHostRecord.fromJson({
      ...plaintext,
      '_record_id': row.recordId,
      '_revision_id': row.revisionId,
    });
  }

  Future<List<Map<String, Object?>>> _readLocalKnownHostRows(
    String recordId,
  ) async =>
      (await _database
              .customSelect(
                '''
                SELECT * FROM local_vault_known_hosts
                WHERE local_vault_id = ? AND record_id = ?
                ''',
                variables: [
                  Variable<String>(localVaultId),
                  Variable<String>(recordId),
                ],
              )
              .get())
          .map((row) => row.data)
          .toList(growable: false);

  _LocalKnownHostRow _decodeLocalKnownHostRow(Map<String, Object?> row) {
    final vaultId = row['local_vault_id'];
    final recordId = row['record_id'];
    final revisionId = row['revision_id'];
    final envelopeJson = row['envelope_json'];
    final updatedAt = row['updated_at_ms'];
    if (vaultId is! String ||
        recordId is! String ||
        revisionId is! String ||
        envelopeJson is! String ||
        updatedAt is! int) {
      throw const FormatException('Local SSH trust row is invalid.');
    }
    return _LocalKnownHostRow(
      localVaultId: vaultId,
      recordId: recordId,
      revisionId: revisionId,
      envelopeJson: envelopeJson,
      updatedAtMs: updatedAt,
    );
  }

  Future<Map<String, Object?>> _encrypt({
    required DeviceIdentity identity,
    required Uint8List vaultKey,
    required String recordId,
    required String? baseRevisionId,
    required String operation,
    required Map<String, Object?> plaintext,
  }) async {
    final record = _profile.record;
    return _crypto.encryptLocalRecord(
      vaultKey: vaultKey,
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: operation,
      plaintext: plaintext,
      identity: identity,
    );
  }

  Future<HostRecord?> _decryptHostRow(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final authenticated = await _decryptRowPayload(row, identity, vaultKey);
    if (authenticated.isDeleted ||
        authenticated.plaintext['type'] != RecordKind.host.name) {
      return null;
    }
    final host = _validatedHostJson(authenticated.plaintext, id: row.recordId);
    return _hostWithRevision(
      host,
      row.revisionId,
      authenticated.header['base_revision_id'] as String?,
    );
  }

  Future<CredentialRecord?> _decryptCredentialRow(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final authenticated = await _decryptRowPayload(row, identity, vaultKey);
    if (authenticated.isDeleted ||
        authenticated.plaintext['type'] != RecordKind.credential.name) {
      return null;
    }
    return _credentialWithRevision(
      _validatedCredentialJson(authenticated.plaintext, id: row.recordId),
      row.revisionId,
    );
  }

  Future<LocalGroupRecord?> _decryptGroupRow(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final authenticated = await _decryptRowPayload(row, identity, vaultKey);
    if (authenticated.isDeleted ||
        authenticated.plaintext['type'] != RecordKind.group.name) {
      return null;
    }
    final json = _validatedGroupJson(authenticated.plaintext, id: row.recordId);
    return LocalGroupRecord(
      group: _groupFromPlaintext(json),
      revisionId: row.revisionId,
    );
  }

  Future<LocalSnippetRecord?> _decryptSnippetRow(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final authenticated = await _decryptRowPayload(row, identity, vaultKey);
    if (authenticated.isDeleted ||
        authenticated.plaintext['type'] != RecordKind.snippet.name) {
      return null;
    }
    final json = _validatedSnippetJson(
      authenticated.plaintext,
      id: row.recordId,
    );
    return LocalSnippetRecord(
      snippet: _snippetWithRevision(json, row.revisionId),
      revisionId: row.revisionId,
    );
  }

  Future<LocalPreferenceRecord?> _decryptPreferenceRow(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    final authenticated = await _decryptRowPayload(row, identity, vaultKey);
    if (authenticated.isDeleted ||
        authenticated.plaintext['type'] != RecordKind.preference.name) {
      return null;
    }
    return _preferenceWithRevision(
      _validatedPreferenceJson(authenticated.plaintext, id: row.recordId),
      row.revisionId,
    );
  }

  Future<_AuthenticatedLocalRecord> _decryptRowPayload(
    _LocalVaultRow row,
    DeviceIdentity identity,
    Uint8List vaultKey,
  ) async {
    _requireUuid(row.recordId, 'record_id');
    _requireUuid(row.revisionId, 'revision_id');
    if (row.localVaultId != localVaultId || row.updatedAtMs <= 0) {
      throw const FormatException('Local Vault record metadata is invalid.');
    }
    final envelope = _decodeEnvelope(row.envelopeJson);
    final header = _validateEnvelopeHeader(
      envelope,
      profileId: _profile.record.profileId,
      localDataDomainId: _profile.record.localDataDomainId,
      localVaultId: localVaultId,
      recordId: row.recordId,
      revisionId: row.revisionId,
      isDeleted: row.isDeleted,
    );
    final expectedOperation = row.isDeleted ? 'delete' : header['operation'];
    if (header['operation'] != expectedOperation) {
      throw const FormatException('Local Vault tombstone operation mismatch.');
    }

    final record = _profile.record;
    final plaintext = await _crypto.decryptLocalRecord(
      vaultKey: vaultKey,
      envelope: envelope,
      expectedProfileId: record.profileId,
      expectedLocalDataDomainId: record.localDataDomainId,
      expectedLocalVaultId: record.localVaultId,
      authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
    );
    if (plaintext['id'] != row.recordId ||
        !const {
          'host',
          'credential',
          'group',
          'snippet',
          'preference',
        }.contains(plaintext['type'])) {
      throw const FormatException('Local Vault record context mismatch.');
    }
    if (row.isDeleted) {
      _validateTombstone(plaintext, row.recordId);
    } else if (plaintext.containsKey('deleted')) {
      throw const FormatException('Active Local Vault record is invalid.');
    } else {
      switch (plaintext['type']) {
        case 'host':
          _validatedHostJson(plaintext, id: row.recordId);
          break;
        case 'credential':
          _validatedCredentialJson(plaintext, id: row.recordId);
          break;
        case 'group':
          _validatedGroupJson(plaintext, id: row.recordId);
          break;
        case 'snippet':
          _validatedSnippetJson(plaintext, id: row.recordId);
          break;
        case 'preference':
          _validatedPreferenceJson(plaintext, id: row.recordId);
          break;
        default:
          throw const FormatException('Local Vault record kind is invalid.');
      }
    }
    return _AuthenticatedLocalRecord(
      header: header,
      plaintext: plaintext,
      isDeleted: row.isDeleted,
    );
  }

  Future<T> _withProfileLease<T>(
    Future<T> Function(DeviceIdentity identity, Uint8List vaultKey) operation,
  ) => _profile.withDeviceIdentity((identity) async {
    // The lease is acquired first. This synchronous copy happens before the
    // callback yields, while lock is still guaranteed to accept key access.
    final vaultKey = _profile.copyVaultKey();
    try {
      return await operation(identity, vaultKey);
    } finally {
      vaultKey.fillRange(0, vaultKey.length, 0);
    }
  });

  Future<_LocalVaultRow?> _readRow(String recordId) async {
    final rows = await _selectRow(recordId);
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const FormatException('Local Vault record key is ambiguous.');
    }
    return _decodeRow(rows.single);
  }

  Future<List<_LocalVaultRow>> _listRows() async {
    final rows = await _database
        .customSelect(
          '''
          SELECT * FROM local_vault_records
          WHERE local_vault_id = ?
          ORDER BY updated_at_ms ASC, record_id ASC
          ''',
          variables: [Variable<String>(localVaultId)],
        )
        .get();
    return rows.map((row) => _decodeRow(row.data)).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _selectRow(String recordId) async {
    final rows = await _database
        .customSelect(
          '''
          SELECT * FROM local_vault_records
          WHERE local_vault_id = ? AND record_id = ?
          ''',
          variables: [
            Variable<String>(localVaultId),
            Variable<String>(recordId),
          ],
        )
        .get();
    return rows.map((row) => row.data).toList(growable: false);
  }

  _LocalVaultRow _decodeRow(Map<String, Object?> row) {
    final vaultId = row['local_vault_id'];
    final recordId = row['record_id'];
    final revisionId = row['revision_id'];
    final envelopeJson = row['envelope_json'];
    final deleted = row['is_deleted'];
    final updatedAt = row['updated_at_ms'];
    if (vaultId is! String ||
        recordId is! String ||
        revisionId is! String ||
        envelopeJson is! String ||
        deleted is! int ||
        (deleted != 0 && deleted != 1) ||
        updatedAt is! int) {
      throw const FormatException('Local Vault record row is invalid.');
    }
    return _LocalVaultRow(
      localVaultId: vaultId,
      recordId: recordId,
      revisionId: revisionId,
      envelopeJson: envelopeJson,
      isDeleted: deleted == 1,
      updatedAtMs: updatedAt,
    );
  }
}

class _LocalVaultRow {
  const _LocalVaultRow({
    required this.localVaultId,
    required this.recordId,
    required this.revisionId,
    required this.envelopeJson,
    required this.isDeleted,
    required this.updatedAtMs,
  });

  final String localVaultId;
  final String recordId;
  final String revisionId;
  final String envelopeJson;
  final bool isDeleted;
  final int updatedAtMs;
}

class _LocalKnownHostRow {
  const _LocalKnownHostRow({
    required this.localVaultId,
    required this.recordId,
    required this.revisionId,
    required this.envelopeJson,
    required this.updatedAtMs,
  });

  final String localVaultId;
  final String recordId;
  final String revisionId;
  final String envelopeJson;
  final int updatedAtMs;
}

LocalKnownHostTrustStatus _localKnownHostStatus(
  List<KnownHostRecord> records, {
  required String endpoint,
  required String algorithm,
  required String fingerprint,
}) {
  final atEndpoint = records
      .where((record) => record.endpoint == endpoint)
      .toList(growable: false);
  final trusted = atEndpoint
      .where((record) => record.state == KnownHostState.trusted)
      .toList(growable: false);
  if (trusted.length > 1) return LocalKnownHostTrustStatus.conflict;
  if (trusted.length == 1) {
    final approval = trusted.single;
    if (!approval.matchesKey(algorithm: algorithm, fingerprint: fingerprint)) {
      return LocalKnownHostTrustStatus.changed;
    }
    final matchingRevocations = atEndpoint.where(
      (record) =>
          record.state == KnownHostState.revoked &&
          record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
    );
    final acknowledgesAllRevocations = matchingRevocations.every(
      (revoked) =>
          revoked.revisionId != null &&
          approval.observedRevocations.any(
            (reference) =>
                reference.recordId == revoked.id &&
                reference.revisionId == revoked.revisionId,
          ),
    );
    return acknowledgesAllRevocations
        ? LocalKnownHostTrustStatus.trusted
        : LocalKnownHostTrustStatus.revoked;
  }
  if (atEndpoint.any(
    (record) =>
        record.state == KnownHostState.revoked &&
        record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
  )) {
    return LocalKnownHostTrustStatus.revoked;
  }
  return LocalKnownHostTrustStatus.unknown;
}

class _LocalArchiveImportRow {
  const _LocalArchiveImportRow({
    required this.recordId,
    required this.revisionId,
    required this.envelopeJson,
    required this.isDeleted,
    required this.updatedAtMs,
  });

  final String recordId;
  final String revisionId;
  final String envelopeJson;
  final bool isDeleted;
  final int updatedAtMs;
}

class _LocalArchiveKnownHostImportRow {
  const _LocalArchiveKnownHostImportRow({
    required this.recordId,
    required this.sourceRevisionId,
    required this.revisionId,
    required this.envelopeJson,
    required this.importedAtMs,
    required this.isCandidate,
  });

  final String recordId;
  final String sourceRevisionId;
  final String revisionId;
  final String envelopeJson;
  final int importedAtMs;
  final bool isCandidate;
}

class _AuthenticatedLocalRecord {
  const _AuthenticatedLocalRecord({
    required this.header,
    required this.plaintext,
    required this.isDeleted,
  });

  final Map<String, dynamic> header;
  final Map<String, dynamic> plaintext;
  final bool isDeleted;
}

Map<String, Object?> _validatedHostJson(
  Map<String, Object?> source, {
  required String id,
}) {
  _requireUuid(id, 'record_id');
  final json = Map<String, Object?>.from(source)..['id'] = id;
  json['type'] = RecordKind.host.name;
  final keys = json.keys.toSet();
  if (!keys.containsAll(_requiredHostFields) ||
      keys.difference(_allowedHostFields).isNotEmpty) {
    throw const FormatException('Local Host fields are invalid.');
  }
  final name = _boundedHostText(json['name'], 'name', maxBytes: 256);
  final address = _boundedHostText(json['address'], 'address', maxBytes: 1024);
  final username = _boundedHostText(
    json['username'],
    'username',
    maxBytes: 256,
    allowEmpty: HostProtocol.parse(json['protocol']) != HostProtocol.ssh,
  );
  final port = json['port'];
  final color = json['color'];
  final authKind = json['auth_kind'];
  final favorite = json['is_favorite'];
  final tagsValue = json['tags'];
  if (name.trim().isEmpty ||
      address.trim().isEmpty ||
      (HostProtocol.parse(json['protocol']) == HostProtocol.ssh &&
          username.trim().isEmpty) ||
      port is! int ||
      port < 1 ||
      port > 65535 ||
      color is! int ||
      color < 0 ||
      color > 0x7fffffff ||
      authKind is! String ||
      !AuthKind.values.any((value) => value.name == authKind) ||
      favorite is! bool ||
      tagsValue is! List ||
      tagsValue.length > 128) {
    throw const FormatException('Local Host fields are invalid.');
  }
  final hostIssue = HostRecord.fromJson(Map<String, dynamic>.from(json))
      .validate();
  if (hostIssue != null) throw FormatException(hostIssue);
  final groupId = json['group_id'];
  final credentialId = json['credential_id'];
  final jumpHostId = json['jump_host_id'];
  if ((groupId != null && !_isCanonicalUuidValue(groupId)) ||
      (credentialId != null && !_isCanonicalUuidValue(credentialId)) ||
      (jumpHostId != null && !_isCanonicalUuidValue(jumpHostId))) {
    throw const FormatException('Local Host reference ID is invalid.');
  }
  final tags = <String>[];
  final seenTags = <String>{};
  for (final rawTag in tagsValue) {
    final tag = _boundedHostText(rawTag, 'tag', maxBytes: 64);
    if (tag.trim().isEmpty ||
        tag != tag.trim() ||
        !seenTags.add(tag.toLowerCase())) {
      throw const FormatException('Local Host tags are invalid.');
    }
    tags.add(tag);
  }
  json['tags'] = List<String>.unmodifiable(tags);
  if (json.containsKey('login')) {
    final host = HostRecord.fromJson(Map<String, dynamic>.from(json));
    final issue = host.validate();
    if (issue != null) throw FormatException(issue);
    json['login'] = host.login!.toJson();
  }
  if (json.containsKey('port_forward_profiles')) {
    final profiles = HostRecord.fromJson(Map<String, dynamic>.from(json))
        .portForwardProfiles;
    json['port_forward_profiles'] = profiles
        .map((profile) => profile.toJson())
        .toList(growable: false);
  }
  if (json.containsKey('_manifest')) {
    final manifest = json['_manifest'];
    if (manifest is! Map || manifest.keys.any((key) => key is! String)) {
      throw const FormatException('Local Host manifest is invalid.');
    }
    final copied = <String, Object?>{
      for (final entry in manifest.entries) entry.key as String: entry.value,
    };
    final canonicalManifest = canonicalJson(copied);
    if (utf8.encode(canonicalManifest).length > 32768) {
      throw const FormatException('Local Host manifest is too large.');
    }
    json['_manifest'] = Map<String, Object?>.from(
      jsonDecode(canonicalManifest) as Map,
    );
    readAnsibleInventoryMetadata(
      Map<String, Object?>.from(json['_manifest']! as Map),
    );
  }
  if (json['type'] != RecordKind.host.name || json['id'] != id) {
    throw const FormatException('Local Host record context mismatch.');
  }
  return json;
}

HostRecord _hostWithRevision(
  Map<String, Object?> json,
  String revisionId,
  String? baseRevisionId,
) {
  _requireUuid(revisionId, 'revision_id');
  if (baseRevisionId != null) _requireUuid(baseRevisionId, 'base_revision_id');
  return HostRecord.fromJson({
    ...json,
    'revision_id': revisionId,
    if (baseRevisionId != null) 'base_revision_id': baseRevisionId,
  });
}

void _validateTombstone(Map<String, dynamic> plaintext, String recordId) {
  const expectedFields = {'id', 'type', 'deleted'};
  if (plaintext.keys.toSet().difference(expectedFields).isNotEmpty ||
      !plaintext.keys.toSet().containsAll(expectedFields) ||
      plaintext['id'] != recordId ||
      !const {
        'host',
        'credential',
        'group',
        'snippet',
        'preference',
      }.contains(plaintext['type']) ||
      plaintext['deleted'] != true) {
    throw const FormatException('Local record tombstone is invalid.');
  }
}

void _validateSupportedMigrationPreference(Map<String, Object?> json) {
  try {
    // Keep migration support aligned with the strict cross-client preference
    // DTO. LocalVault may preserve other local preference tuples in archives,
    // but only these explicitly supported records can enter a sync Vault.
    VaultPreferenceRecord.fromJson(json);
  } on FormatException {
    throw const FormatException('Local migration Preference is not supported.');
  }
}

bool _hasUnsupportedObjectReference(Object? value) {
  const objectReferenceFields = {
    'attachments',
    'blob_id',
    'blob_ids',
    'blob_refs',
    'object_id',
    'object_ids',
    'object_ref',
    'object_refs',
    'objects',
  };
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String &&
          objectReferenceFields.contains((entry.key as String).toLowerCase())) {
        return true;
      }
      if (_hasUnsupportedObjectReference(entry.value)) return true;
    }
  } else if (value is List) {
    for (final item in value) {
      if (_hasUnsupportedObjectReference(item)) return true;
    }
  }
  return false;
}

void _validateMigrationReferenceClosure(List<LocalMigrationSourceItem> items) {
  final hosts = <String, Map<String, Object?>>{};
  final credentials = <String, Map<String, Object?>>{};
  final groups = <String, Map<String, Object?>>{};
  for (final item in items) {
    switch (item.recordType) {
      case 'host':
        hosts[item.recordId] = item.recordJson;
        break;
      case 'credential':
        credentials[item.recordId] = item.recordJson;
        break;
      case 'group':
        groups[item.recordId] = item.recordJson;
        break;
    }
  }

  for (final entry in hosts.entries) {
    final host = entry.value;
    final groupId = host['group_id'];
    final credentialId = host['credential_id'];
    if (groupId != null && !groups.containsKey(groupId)) {
      throw const FormatException('Local migration has a missing Group.');
    }
    if (credentialId != null && !credentials.containsKey(credentialId)) {
      throw const FormatException('Local migration has a missing Credential.');
    }
  }

  for (final group in groups.values) {
    final defaultCredentialId = group['default_credential_id'];
    if (defaultCredentialId != null &&
        !credentials.containsKey(defaultCredentialId)) {
      throw const FormatException(
        'Local migration has a missing Group default Credential.',
      );
    }
  }

  for (final entry in hosts.entries) {
    var currentId = entry.key;
    var routeLength = 0;
    final seen = <String>{entry.key};
    while (true) {
      final jumpHostId = hosts[currentId]?['jump_host_id'];
      if (jumpHostId == null) break;
      if (jumpHostId is! String || !hosts.containsKey(jumpHostId)) {
        throw const FormatException(
          'Local migration Jump Host reference is missing.',
        );
      }
      routeLength++;
      if (!seen.add(jumpHostId)) {
        throw const FormatException(
          'Local migration Jump Host route contains a cycle.',
        );
      }
      if (routeLength > maxJumpHostHops) {
        throw const FormatException(
          'Local migration Jump Host route exceeds the 8-hop limit.',
        );
      }
      currentId = jumpHostId;
    }
  }

  final siblingGroupNames = <String>{};
  for (final entry in groups.entries) {
    final groupName = entry.value['name'];
    if (groupName is! String ||
        !siblingGroupNames.add(
          canonicalJson([
            entry.value['parent_id'],
            groupName.trim().toLowerCase(),
          ]),
        )) {
      throw const FormatException(
        'Local migration has duplicate sibling Groups.',
      );
    }
    final seen = <String>{entry.key};
    Object? parentId = entry.value['parent_id'];
    while (parentId != null) {
      if (parentId is! String || !seen.add(parentId)) {
        throw const FormatException('Local migration Group tree is invalid.');
      }
      final parent = groups[parentId];
      if (parent == null) {
        throw const FormatException('Local migration has a missing Group.');
      }
      parentId = parent['parent_id'];
    }
  }

  final preferenceTuples = <String>{};
  for (final item in items) {
    if (item.recordType == 'preference') {
      final preference = item.recordJson;
      final tuple = canonicalJson([
        preference['scope'],
        preference['key'],
        preference['platform_family'],
      ]);
      if (!preferenceTuples.add(tuple)) {
        throw const FormatException(
          'Local migration has duplicate Preferences.',
        );
      }
    } else if (item.recordType == 'snippet') {
      final parameters = item.recordJson['parameters'];
      if (parameters is List) {
        for (final parameter in parameters) {
          if (parameter is Map && parameter['type'] == 'credentialSecret') {
            final credentialId = parameter['credential_id'];
            if (credentialId is! String ||
                !credentials.containsKey(credentialId)) {
              throw const FormatException(
                'Local migration Snippet Credential is missing.',
              );
            }
          }
        }
      }
    }
  }
}

Map<String, Object?> _immutableMigrationJson(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _immutableMigrationValue(entry.value),
    });

Object? _immutableMigrationValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _immutableMigrationValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableMigrationValue));
  }
  return value;
}

Future<String> _sha256Hex(List<int> bytes) async {
  final digest = await cryptography.Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

void _validateTargetRecordEnvelope(
  String envelopeJson, {
  required String recordId,
  required String? targetVaultId,
}) {
  if (utf8.encode(envelopeJson).length > _maxMigrationTargetEnvelopeBytes) {
    throw const FormatException('Target record envelope is too large.');
  }
  final decoded = jsonDecode(envelopeJson);
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.toSet().length != 4 ||
      !decoded.keys.toSet().containsAll(const {
        'header',
        'nonce',
        'ciphertext',
        'signature',
      }) ||
      decoded['header'] is! Map<String, dynamic> ||
      decoded['nonce'] is! String ||
      decoded['ciphertext'] is! String ||
      decoded['signature'] is! String) {
    throw const FormatException('Target record envelope is invalid.');
  }
  final header = Map<String, dynamic>.from(decoded['header'] as Map);
  const requiredHeader = {
    'wire_version',
    'server_space_id',
    'vault_id',
    'record_id',
    'revision_id',
    'base_revision_id',
    'op_id',
    'device_id',
    'device_seq',
    'key_epoch',
    'membership_version',
    'record_schema',
    'operation',
    'crypto_suite',
    'kdf_salt',
  };
  if (header.keys.toSet().length != requiredHeader.length ||
      !header.keys.toSet().containsAll(requiredHeader) ||
      header['wire_version'] != 1 ||
      !const {1, 2}.contains(header['record_schema']) ||
      header['crypto_suite'] != 'atermius-vault-v1' ||
      header['record_id'] != recordId ||
      header['operation'] != 'create' ||
      header['base_revision_id'] != null ||
      (targetVaultId != null && header['vault_id'] != targetVaultId)) {
    throw const FormatException('Target record envelope header is invalid.');
  }
  for (final field in const [
    'server_space_id',
    'vault_id',
    'record_id',
    'revision_id',
    'op_id',
    'device_id',
  ]) {
    _requireUuid(header[field], 'target_$field');
  }
  for (final field in const ['device_seq', 'key_epoch', 'membership_version']) {
    final value = header[field];
    if (value is! String ||
        value.length > 20 ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
      throw const FormatException('Target record envelope header is invalid.');
    }
  }
  try {
    final nonce = decodeBase64Url(decoded['nonce']! as String);
    final ciphertext = decodeBase64Url(decoded['ciphertext']! as String);
    final signature = decodeBase64Url(decoded['signature']! as String);
    final salt = decodeBase64Url(header['kdf_salt'] as String);
    if (encodeBase64Url(nonce) != decoded['nonce'] ||
        encodeBase64Url(ciphertext) != decoded['ciphertext'] ||
        encodeBase64Url(signature) != decoded['signature'] ||
        encodeBase64Url(salt) != header['kdf_salt'] ||
        nonce.length != 24 ||
        ciphertext.length < 16 ||
        ciphertext.length > _maxMigrationTargetEnvelopeBytes ||
        signature.length != 64 ||
        salt.length != 32) {
      throw const FormatException(
        'Target record envelope encoding is invalid.',
      );
    }
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Target record envelope encoding is invalid.');
  }
}

void _validateMigrationCreatePayload(String payloadJson) {
  if (utf8.encode(payloadJson).length > _maxMigrationCreatePayloadBytes) {
    throw const FormatException('Target Vault payload is too large.');
  }
  final decoded = jsonDecode(payloadJson);
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.toSet().length != 6 ||
      !decoded.keys.toSet().containsAll(const {
        'vault_id',
        'name_envelope',
        'key_epoch',
        'membership_version',
        'key_envelope',
        'membership',
      }) ||
      decoded['vault_id'] is! String ||
      decoded['name_envelope'] is! Map ||
      decoded['key_envelope'] is! Map ||
      decoded['membership'] is! Map ||
      decoded['key_epoch'] != 1 ||
      decoded['membership_version'] != 1) {
    throw const FormatException('Target Vault payload is invalid.');
  }
  _requireUuid(decoded['vault_id'], 'target_vault_id');
  final nameRaw = decoded['name_envelope'];
  final keyRaw = decoded['key_envelope'];
  final membershipRaw = decoded['membership'];
  if (nameRaw is! Map ||
      keyRaw is! Map ||
      membershipRaw is! Map ||
      keyRaw['envelope'] is! Map ||
      membershipRaw['manifest'] is! Map) {
    throw const FormatException('Target Vault payload is invalid.');
  }
  final nameEnvelope = Map<String, dynamic>.from(nameRaw);
  final keyEnvelope = Map<String, dynamic>.from(keyRaw);
  final keyCipher = Map<String, dynamic>.from(keyRaw['envelope'] as Map);
  final membership = Map<String, dynamic>.from(membershipRaw);
  final manifestRaw = membershipRaw['manifest'];
  if (manifestRaw is! Map) {
    throw const FormatException('Target Vault payload is invalid.');
  }
  final manifest = Map<String, dynamic>.from(manifestRaw);
  final members = manifest['members'];
  if (!_hasExactKeys(nameEnvelope, const {'version', 'nonce', 'ciphertext'}) ||
      nameEnvelope['version'] != 1 ||
      !_hasExactKeys(keyEnvelope, const {
        'recipient_device_id',
        'key_epoch',
        'membership_version',
        'envelope',
        'signature',
      }) ||
      !_hasExactKeys(keyCipher, const {'version', 'suite', 'ciphertext'}) ||
      keyCipher['version'] != 1 ||
      keyCipher['suite'] != 'crypto_box_seal' ||
      !_hasExactKeys(membership, const {
        'membership_version',
        'previous_digest',
        'manifest',
        'signature',
      }) ||
      membership['previous_digest'] != null ||
      !_hasExactKeys(manifest, const {
        'key_epoch',
        'display_name_envelope',
        'members',
        'signer_device_id',
      }) ||
      members is! List ||
      members.length != 1 ||
      members.single is! Map) {
    throw const FormatException('Target Vault payload is invalid.');
  }
  final member = Map<String, dynamic>.from(members.single as Map);
  if (!_hasExactKeys(member, const {
        'user_id',
        'role',
        'state',
        'encryption_key_fingerprint',
      }) ||
      member['role'] != 'owner' ||
      member['state'] != 'active' ||
      keyEnvelope['key_epoch'] != 1 ||
      keyEnvelope['membership_version'] != 1 ||
      membership['membership_version'] != 1 ||
      manifest['key_epoch'] != 1 ||
      keyEnvelope['recipient_device_id'] != manifest['signer_device_id'] ||
      canonicalJson(manifest['display_name_envelope']) !=
          canonicalJson(nameEnvelope)) {
    throw const FormatException('Target Vault payload is invalid.');
  }
  _requireUuid(keyEnvelope['recipient_device_id'], 'target_device_id');
  _requireUuid(manifest['signer_device_id'], 'target_device_id');
  _requireUuid(member['user_id'], 'target_account_id');
  _validateMigrationBase64(nameEnvelope['nonce'], expectedLength: 24);
  _validateMigrationBase64(nameEnvelope['ciphertext'], minLength: 16);
  _validateMigrationBase64(keyEnvelope['signature'], expectedLength: 64);
  _validateMigrationBase64(keyCipher['ciphertext'], minLength: 48);
  _validateMigrationBase64(membership['signature'], expectedLength: 64);
  _validateMigrationBase64(
    member['encryption_key_fingerprint'],
    expectedLength: 32,
  );
  const forbiddenCleartextKeys = {
    'credentialsecret',
    'encryptionsecret',
    'passphrase',
    'password',
    'plaintext',
    'privatekey',
    'recordjson',
    'secret',
    'signingsecret',
    'umk',
    'vaultkey',
  };
  void inspect(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('Target Vault payload is invalid.');
        }
        final normalized = (entry.key as String).toLowerCase().replaceAll(
          RegExp(r'[_\-\s]'),
          '',
        );
        if (forbiddenCleartextKeys.contains(normalized)) {
          throw const FormatException(
            'Target Vault payload contains cleartext key material.',
          );
        }
        inspect(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        inspect(item);
      }
    }
  }

  inspect(decoded);
}

void _validateMigrationBase64(
  Object? value, {
  int? expectedLength,
  int? minLength,
}) {
  if (value is! String) {
    throw const FormatException('Target Vault payload encoding is invalid.');
  }
  try {
    final decoded = decodeBase64Url(value);
    if (encodeBase64Url(decoded) != value ||
        (expectedLength != null && decoded.length != expectedLength) ||
        (minLength != null && decoded.length < minLength)) {
      throw const FormatException('Target Vault payload encoding is invalid.');
    }
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Target Vault payload encoding is invalid.');
  }
}

Map<String, Object?> _validatedPreferenceJson(
  Map<String, Object?> source, {
  required String id,
}) {
  _requireUuid(id, 'record_id');
  final json = Map<String, Object?>.from(source);
  if (!_hasExactPreferenceKeys(json.keys.toSet()) ||
      json['id'] != id ||
      json['type'] != RecordKind.preference.name) {
    throw const FormatException('Local Preference fields are invalid.');
  }
  final scope = json['scope'];
  final key = json['key'];
  final platformFamily = json['platform_family'];
  if (scope is! String || key is! String || platformFamily is! String) {
    throw const FormatException('Local Preference key fields are invalid.');
  }
  _validatePreferenceTuple(scope, key, platformFamily);
  final value = _normalizePreferenceJsonValue(
    json['value'],
    depth: 0,
    ancestors: Set<Object>.identity(),
    budget: _PreferenceJsonBudget(),
  );
  final serializedValue = canonicalJson(value);
  if (utf8.encode(serializedValue).length > 65536) {
    throw const FormatException('Local Preference value is too large.');
  }
  if (key == 'windowCombinations') {
    if (scope != 'workspace' || platformFamily != 'all' || value is! String) {
      throw FormatException(currentL10n.invalidWindowSetPreferenceFormat);
    }
    WindowCombination.decode(value);
  }
  json['value'] = jsonDecode(serializedValue);
  return json;
}

bool _hasExactPreferenceKeys(Set<String> keys) =>
    keys.length == _requiredPreferenceFields.length &&
    keys.containsAll(_requiredPreferenceFields);

void _validatePreferenceTuple(String scope, String key, String platformFamily) {
  if (!_preferenceToken.hasMatch(scope) ||
      utf8.encode(scope).length > 64 ||
      !_preferenceToken.hasMatch(key) ||
      utf8.encode(key).length > 128 ||
      !_preferenceToken.hasMatch(platformFamily) ||
      utf8.encode(platformFamily).length > 32) {
    throw const FormatException('Local Preference key fields are invalid.');
  }
}

Object? _normalizePreferenceJsonValue(
  Object? value, {
  required int depth,
  required Set<Object> ancestors,
  required _PreferenceJsonBudget budget,
}) {
  budget.consumeNode();
  if (depth > 16) {
    throw const FormatException('Local Preference value is too deeply nested.');
  }
  if (value == null || value is bool || value is int) return value;
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Local Preference number is invalid.');
    }
    return value;
  }
  if (value is String) {
    if (utf8.encode(value).length > 32768) {
      throw const FormatException('Local Preference string is too large.');
    }
    budget.consumeText(value);
    return value;
  }
  if (value is List) {
    if (value.length > 512 || !ancestors.add(value)) {
      throw const FormatException('Local Preference array is invalid.');
    }
    try {
      return [
        for (final item in value)
          _normalizePreferenceJsonValue(
            item,
            depth: depth + 1,
            ancestors: ancestors,
            budget: budget,
          ),
      ];
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map) {
    if (value.length > 512 || !ancestors.add(value)) {
      throw const FormatException('Local Preference object is invalid.');
    }
    try {
      final normalized = <String, Object?>{};
      for (final entry in value.entries) {
        final rawKey = entry.key;
        if (rawKey is! String ||
            utf8.encode(rawKey).length > 256 ||
            _preferenceJsonKeyControl.hasMatch(rawKey)) {
          throw const FormatException(
            'Local Preference object key is invalid.',
          );
        }
        budget.consumeText(rawKey);
        normalized[rawKey] = _normalizePreferenceJsonValue(
          entry.value,
          depth: depth + 1,
          ancestors: ancestors,
          budget: budget,
        );
      }
      return normalized;
    } finally {
      ancestors.remove(value);
    }
  }
  throw const FormatException('Local Preference value is not JSON data.');
}

class _PreferenceJsonBudget {
  static const maxNodes = 4096;
  static const maxTextBytes = 65536;

  int _nodes = 0;
  int _textBytes = 0;

  void consumeNode() {
    if (++_nodes > maxNodes) {
      throw const FormatException('Local Preference value has too many items.');
    }
  }

  void consumeText(String value) {
    _textBytes += utf8.encode(value).length;
    if (_textBytes > maxTextBytes) {
      throw const FormatException('Local Preference text is too large.');
    }
  }
}

Object? _freezePreferenceJsonValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezePreferenceJsonValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezePreferenceJsonValue));
  }
  return value;
}

LocalPreferenceRecord _preferenceWithRevision(
  Map<String, Object?> json,
  String revisionId,
) {
  _requireUuid(revisionId, 'revision_id');
  return LocalPreferenceRecord(
    id: json['id']! as String,
    scope: json['scope']! as String,
    key: json['key']! as String,
    value: _freezePreferenceJsonValue(json['value']),
    platformFamily: json['platform_family']! as String,
    revisionId: revisionId,
  );
}

Map<String, Object?> _validatedGroupJson(
  Map<String, Object?> source, {
  required String id,
}) {
  _requireUuid(id, 'record_id');
  final json = Map<String, Object?>.from(source);
  final keys = json.keys.toSet();
  if (!keys.containsAll(_requiredGroupFields) ||
      keys.difference(_allowedGroupFields).isNotEmpty ||
      json['id'] != id ||
      json['type'] != RecordKind.group.name) {
    throw const FormatException('Local Group fields are invalid.');
  }
  final name = _boundedGroupText(json['name'], 'name', maxBytes: 256);
  final color = json['color'];
  final parentId = json['parent_id'];
  final defaultCredentialId = json['default_credential_id'];
  if (name.trim().isEmpty ||
      color is! int ||
      color < 0 ||
      color > 0x7fffffff ||
      (parentId != null && !_isCanonicalUuidValue(parentId)) ||
      (defaultCredentialId != null &&
          !_isCanonicalUuidValue(defaultCredentialId))) {
    throw const FormatException('Local Group fields are invalid.');
  }
  if (keys.contains('_manifest')) {
    final manifest = json['_manifest'];
    if (manifest is! Map || manifest.keys.any((key) => key is! String)) {
      throw const FormatException('Local Group manifest is invalid.');
    }
    final copied = <String, Object?>{
      for (final entry in manifest.entries) entry.key as String: entry.value,
    };
    final canonicalManifest = canonicalJson(copied);
    if (utf8.encode(canonicalManifest).length > 32768) {
      throw const FormatException('Local Group manifest is too large.');
    }
    json['_manifest'] = Map<String, Object?>.from(
      jsonDecode(canonicalManifest) as Map,
    );
  }
  return json;
}

GroupRecord _groupFromPlaintext(Map<String, Object?> json) => GroupRecord(
  id: json['id']! as String,
  name: json['name']! as String,
  color: json['color']! as int,
  parentId: json['parent_id'] as String?,
  defaultCredentialId: json['default_credential_id'] as String?,
  manifest: json['_manifest'] == null
      ? null
      : Map<String, Object?>.unmodifiable(
          json['_manifest']! as Map<String, Object?>,
        ),
);

Map<String, Object?> _validatedSnippetJson(
  Map<String, Object?> source, {
  required String id,
}) {
  _requireUuid(id, 'record_id');
  final json = Map<String, Object?>.from(source);
  if (json['id'] != id || json['type'] != RecordKind.snippet.name) {
    throw const FormatException('Local Snippet record context is invalid.');
  }
  final keys = json.keys.toSet();
  if (!keys.containsAll(_requiredSnippetFields)) {
    throw const FormatException('Local Snippet fields are invalid.');
  }
  final hasStructuredMode = keys.contains('execution_mode');
  final expectedFields = {
    ..._requiredSnippetFields,
    if (hasStructuredMode) ..._snippetStructuredFields,
    if (keys.contains('_manifest')) '_manifest',
  };
  if (keys.difference(expectedFields).isNotEmpty ||
      !keys.containsAll(expectedFields)) {
    throw const FormatException('Local Snippet fields are invalid.');
  }

  final title = _boundedSnippetText(json['title'], 'title', maxBytes: 256);
  final body = _boundedSnippetText(
    json['body'],
    'body',
    maxBytes: 262144,
    allowEmpty: true,
    allowScriptControls: true,
  );
  final shell = _boundedSnippetText(
    json['shell_kind'],
    'shell_kind',
    maxBytes: 64,
  );
  if (title.trim().isEmpty || shell.trim().isEmpty) {
    throw const FormatException('Local Snippet fields are invalid.');
  }

  final tagsValue = json['tags'];
  if (tagsValue is! List || tagsValue.length > 128) {
    throw const FormatException('Local Snippet tags are invalid.');
  }
  final tags = <String>[];
  final seenTags = <String>{};
  for (final rawTag in tagsValue) {
    final tag = _boundedSnippetText(rawTag, 'tag', maxBytes: 64);
    if (tag.trim().isEmpty ||
        tag != tag.trim() ||
        !seenTags.add(tag.toLowerCase())) {
      throw const FormatException('Local Snippet tags are invalid.');
    }
    tags.add(tag);
  }
  json['title'] = title;
  json['body'] = body;
  json['shell_kind'] = shell;
  json['tags'] = List<String>.unmodifiable(tags);

  if (hasStructuredMode) {
    if (json['execution_mode'] != SnippetExecutionMode.bashCommand.name) {
      throw const FormatException('Local Snippet execution mode is invalid.');
    }
    json['program'] = _boundedSnippetText(
      json['program'],
      'program',
      maxBytes: 4096,
    );
    final argumentsValue = json['arguments'];
    if (argumentsValue is! List || argumentsValue.length > 128) {
      throw const FormatException('Local Snippet arguments are invalid.');
    }
    final arguments = <Map<String, Object?>>[];
    for (final rawArgument in argumentsValue) {
      final argument = _snippetObject(rawArgument, 'argument');
      switch (argument['kind']) {
        case 'literal':
          if (!_hasExactSnippetKeys(argument, const {'kind', 'value'}) ||
              argument['value'] is! String) {
            throw const FormatException('Local Snippet literal is invalid.');
          }
          argument['value'] = _boundedSnippetText(
            argument['value'],
            'argument',
            maxBytes: 4096,
            allowEmpty: true,
          );
          break;
        case 'parameter':
          if (!_hasExactSnippetKeys(argument, const {'kind', 'name'}) ||
              argument['name'] is! String ||
              !_snippetParameterName.hasMatch(argument['name']! as String)) {
            throw const FormatException('Local Snippet reference is invalid.');
          }
          break;
        default:
          throw const FormatException('Local Snippet argument is invalid.');
      }
      arguments.add(Map<String, Object?>.from(argument));
    }
    final parametersValue = json['parameters'];
    if (parametersValue is! List || parametersValue.length > 32) {
      throw const FormatException('Local Snippet parameters are invalid.');
    }
    final parameters = <Map<String, Object?>>[];
    final parameterNames = <String>{};
    for (final rawParameter in parametersValue) {
      final parameter = _snippetObject(rawParameter, 'parameter');
      final name = parameter['name'];
      if (name is! String || !_snippetParameterName.hasMatch(name)) {
        throw const FormatException('Local Snippet parameter name is invalid.');
      }
      if (!parameterNames.add(name)) {
        throw const FormatException('Local Snippet parameter names repeat.');
      }
      switch (parameter['type']) {
        case 'text':
          if (!_hasAllowedSnippetKeys(
            parameter,
            const {'name', 'type'},
            const {'default'},
          )) {
            throw const FormatException('Local text parameter is invalid.');
          }
          if (parameter.containsKey('default')) {
            parameter['default'] = _boundedSnippetText(
              parameter['default'],
              'parameter default',
              maxBytes: 16384,
              allowEmpty: true,
            );
          }
          break;
        case 'credentialSecret':
          if (!_hasExactSnippetKeys(parameter, const {
                'name',
                'type',
                'credential_id',
              }) ||
              !_isCanonicalUuidValue(parameter['credential_id'])) {
            throw const FormatException(
              'Local Credential parameter is invalid.',
            );
          }
          break;
        default:
          throw const FormatException(
            'Local Snippet parameter type is invalid.',
          );
      }
      parameters.add(Map<String, Object?>.from(parameter));
    }
    for (final argument in arguments) {
      if (argument['kind'] == 'parameter' &&
          !parameterNames.contains(argument['name'])) {
        throw const FormatException('Local Snippet reference is undefined.');
      }
    }
    json['arguments'] = List<Map<String, Object?>>.unmodifiable(arguments);
    json['parameters'] = List<Map<String, Object?>>.unmodifiable(parameters);
  }

  if (json.containsKey('_manifest')) {
    final manifest = json['_manifest'];
    if (manifest is! Map || manifest.keys.any((key) => key is! String)) {
      throw const FormatException('Local Snippet manifest is invalid.');
    }
    final copied = <String, Object?>{
      for (final entry in manifest.entries) entry.key as String: entry.value,
    };
    final canonicalManifest = canonicalJson(copied);
    if (utf8.encode(canonicalManifest).length > 32768) {
      throw const FormatException('Local Snippet manifest is too large.');
    }
    json['_manifest'] = Map<String, Object?>.from(
      jsonDecode(canonicalManifest) as Map,
    );
  }

  final parsed = SnippetRecord.fromJson(Map<String, dynamic>.from(json));
  validateSnippetDefinition(parsed);
  return json;
}

final _snippetParameterName = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

Map<String, dynamic> _snippetObject(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Local Snippet $field must be an object.');
  }
  return Map<String, dynamic>.from(value);
}

bool _hasExactSnippetKeys(Map<String, dynamic> value, Set<String> keys) =>
    value.keys.toSet().length == keys.length &&
    value.keys.toSet().containsAll(keys);

bool _hasAllowedSnippetKeys(
  Map<String, dynamic> value,
  Set<String> required,
  Set<String> optional,
) =>
    value.keys.toSet().containsAll(required) &&
    value.keys.toSet().difference({...required, ...optional}).isEmpty;

SnippetRecord _snippetWithRevision(
  Map<String, Object?> json,
  String revisionId,
) {
  _requireUuid(revisionId, 'revision_id');
  final parsed = SnippetRecord.fromJson(Map<String, dynamic>.from(json));
  return SnippetRecord(
    id: parsed.id,
    title: parsed.title,
    body: parsed.body,
    shell: parsed.shell,
    executionMode: parsed.executionMode,
    program: parsed.program,
    arguments: List<SnippetArgument>.unmodifiable(parsed.arguments),
    parameters: List<SnippetParameter>.unmodifiable(parsed.parameters),
    tags: List<String>.unmodifiable(parsed.tags),
    revisionId: revisionId,
    manifest: parsed.manifest == null
        ? null
        : Map<String, Object?>.unmodifiable(parsed.manifest!),
  );
}

Map<String, Object?> _validatedCredentialJson(
  Map<String, Object?> source, {
  required String id,
}) {
  _requireUuid(id, 'record_id');
  final json = Map<String, Object?>.from(source)..['id'] = id;
  json['type'] = RecordKind.credential.name;
  const requiredFields = {'id', 'type', 'name', 'username', 'kind'};
  const allowedFields = {
    ...requiredFields,
    'secret',
    'private_key',
    'passphrase',
    'fingerprint',
    'certificate',
    '_manifest',
  };
  final keys = json.keys.toSet();
  if (!keys.containsAll(requiredFields) ||
      keys.difference(allowedFields).isNotEmpty) {
    throw const FormatException('Local Credential fields are invalid.');
  }
  final name = _boundedCredentialText(json['name'], 'name', maxBytes: 256);
  final username = _boundedCredentialText(
    json['username'],
    'username',
    maxBytes: 256,
  );
  if (name.trim().isEmpty || username.trim().isEmpty) {
    throw const FormatException('Local Credential fields are invalid.');
  }
  final kindName = json['kind'];
  if (kindName is! String ||
      !AuthKind.values.any((value) => value.name == kindName)) {
    throw const FormatException('Local Credential kind is invalid.');
  }
  final kind = AuthKind.values.byName(kindName);
  if (kind == AuthKind.password) {
    if (!keys.contains('secret') ||
        keys.contains('private_key') ||
        keys.contains('passphrase')) {
      throw const FormatException(
        'Local password Credential fields are invalid.',
      );
    }
    json['secret'] = _boundedCredentialText(
      json['secret'],
      'secret',
      maxBytes: 65536,
    );
  } else {
    if (!keys.contains('private_key') || keys.contains('secret')) {
      throw const FormatException('Local key Credential fields are invalid.');
    }
    json['private_key'] = _boundedPrivateKey(json['private_key']);
    if (keys.contains('passphrase')) {
      json['passphrase'] = _boundedCredentialText(
        json['passphrase'],
        'passphrase',
        maxBytes: 16384,
        allowEmpty: true,
      );
    }
    if (keys.contains('certificate')) {
      // Structural validation only: the key binding is checked by the editor
      // (it needs the passphrase) and again before every authentication.
      final rawCertificate = json['certificate'];
      final certificate = _boundedCredentialText(
        // `*-cert.pub` files end with a newline; only surrounding whitespace
        // is normalized, the strict control-character check still applies.
        rawCertificate is String ? rawCertificate.trim() : rawCertificate,
        'certificate',
        maxBytes: openSshCertificateMaxTextBytes,
      );
      try {
        final parsed = OpenSshCertificate.parse(certificate);
        if (!parsed.isUserCertificate) throw const FormatException('host');
        json['certificate'] = parsed.canonicalLine;
      } on Object {
        throw const FormatException('Local Credential certificate is invalid.');
      }
    }
  }
  if (kind == AuthKind.password && keys.contains('certificate')) {
    throw const FormatException('Local password Credential fields are invalid.');
  }
  if (keys.contains('fingerprint')) {
    json['fingerprint'] = _boundedCredentialText(
      json['fingerprint'],
      'fingerprint',
      maxBytes: 256,
    );
  }
  if (keys.contains('_manifest')) {
    final manifest = json['_manifest'];
    if (manifest is! Map || manifest.keys.any((key) => key is! String)) {
      throw const FormatException('Local Credential manifest is invalid.');
    }
    final copied = <String, Object?>{
      for (final entry in manifest.entries) entry.key as String: entry.value,
    };
    final canonicalManifest = canonicalJson(copied);
    if (utf8.encode(canonicalManifest).length > 32768) {
      throw const FormatException('Local Credential manifest is too large.');
    }
    json['_manifest'] = Map<String, Object?>.from(
      jsonDecode(canonicalManifest) as Map,
    );
  }
  return json;
}

CredentialRecord _credentialWithRevision(
  Map<String, Object?> json,
  String revisionId,
) {
  _requireUuid(revisionId, 'revision_id');
  return CredentialRecord(
    id: json['id']! as String,
    name: json['name']! as String,
    username: json['username']! as String,
    kind: AuthKind.values.byName(json['kind']! as String),
    secret: json['secret'] as String?,
    privateKey: json['private_key'] as String?,
    passphrase: json['passphrase'] as String?,
    fingerprint: json['fingerprint'] as String?,
    certificate: json['certificate'] as String?,
    revisionId: revisionId,
    manifest: json['_manifest'] == null
        ? null
        : Map<String, Object?>.unmodifiable(
            json['_manifest']! as Map<String, Object?>,
          ),
  );
}

String _boundedCredentialText(
  Object? value,
  String field, {
  required int maxBytes,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      _credentialTextControl.hasMatch(value)) {
    throw FormatException('Local Credential $field is invalid.');
  }
  if (utf8.encode(value).length > maxBytes) {
    throw FormatException('Local Credential $field is too long.');
  }
  return value;
}

String _boundedGroupText(Object? value, String field, {required int maxBytes}) {
  if (value is! String || value.isEmpty || _groupTextControl.hasMatch(value)) {
    throw FormatException('Local Group $field is invalid.');
  }
  if (utf8.encode(value).length > maxBytes) {
    throw FormatException('Local Group $field is too long.');
  }
  return value;
}

String _boundedSnippetText(
  Object? value,
  String field, {
  required int maxBytes,
  bool allowEmpty = false,
  bool allowScriptControls = false,
}) {
  final controls = allowScriptControls
      ? _snippetBodyControl
      : _snippetTextControl;
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      controls.hasMatch(value)) {
    throw FormatException('Local Snippet $field is invalid.');
  }
  if (utf8.encode(value).length > maxBytes) {
    throw FormatException('Local Snippet $field is too long.');
  }
  return value;
}

String _boundedPrivateKey(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      _privateKeyControl.hasMatch(value) ||
      utf8.encode(value).length > 262144) {
    throw const FormatException('Local Credential private key is invalid.');
  }
  return value;
}

Map<String, dynamic> _decodeEnvelope(String json) {
  if (json.length > _maxLocalEnvelopeJsonChars) {
    throw const FormatException('Local record envelope is too large.');
  }
  final decoded = jsonDecode(json);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Local record envelope must be an object.');
  }
  _exactKeys(decoded, _outerEnvelopeFields, 'Local record envelope');
  if (decoded['format'] != _localRecordFormat ||
      decoded['header'] is! Map<String, dynamic> ||
      decoded['nonce'] is! String ||
      decoded['ciphertext'] is! String ||
      decoded['signature'] is! String) {
    throw const FormatException('Local record envelope is invalid.');
  }
  return decoded;
}

String _encodeEnvelope(
  Map<String, Object?> envelope, {
  required String profileId,
  required String localDataDomainId,
  required String localVaultId,
  required String recordId,
  required String revisionId,
  required String? baseRevisionId,
  required String operation,
}) {
  final json = canonicalJson(envelope);
  if (json.length > _maxLocalEnvelopeJsonChars) {
    throw const FormatException('Local record envelope is too large.');
  }
  final decoded = _decodeEnvelope(json);
  _validateEnvelopeHeader(
    decoded,
    profileId: profileId,
    localDataDomainId: localDataDomainId,
    localVaultId: localVaultId,
    recordId: recordId,
    revisionId: revisionId,
    expectedBaseRevisionId: baseRevisionId,
    expectedOperation: operation,
  );
  return json;
}

Map<String, dynamic> _validateEnvelopeHeader(
  Map<String, dynamic> envelope, {
  required String profileId,
  required String localDataDomainId,
  required String localVaultId,
  required String recordId,
  required String revisionId,
  String? expectedBaseRevisionId,
  String? expectedOperation,
  bool? isDeleted,
}) {
  _exactKeys(envelope, _outerEnvelopeFields, 'Local record envelope');
  if (envelope['format'] != _localRecordFormat ||
      envelope['header'] is! Map<String, dynamic>) {
    throw const FormatException('Local record envelope format is invalid.');
  }
  final header = Map<String, dynamic>.from(envelope['header'] as Map);
  _exactKeys(header, _localHeaderFields, 'Local record header');
  if (header['format'] != _localRecordFormat ||
      header['schema_version'] != 1 ||
      header['profile_id'] != profileId ||
      header['local_data_domain_id'] != localDataDomainId ||
      header['local_vault_id'] != localVaultId ||
      header['record_id'] != recordId ||
      header['revision_id'] != revisionId ||
      header['crypto_suite'] != 'xchacha20-poly1305-ietf+hkdf-sha256+ed25519' ||
      header['kdf_salt'] is! String) {
    throw const FormatException('Local record header context is invalid.');
  }
  final base = header['base_revision_id'];
  if (base != null) _requireUuid(base, 'base_revision_id');
  if (expectedBaseRevisionId != null && base != expectedBaseRevisionId) {
    throw const FormatException('Local record base revision mismatch.');
  }
  final operation = header['operation'];
  if (operation is! String ||
      !const {'create', 'update', 'delete'}.contains(operation) ||
      (operation == 'create' && base != null) ||
      (operation != 'create' && base == null) ||
      (expectedOperation != null && operation != expectedOperation) ||
      (isDeleted != null && (operation == 'delete') != isDeleted)) {
    throw const FormatException('Local record operation is invalid.');
  }
  _requireUuid(header['record_id'], 'record_id');
  _requireUuid(header['revision_id'], 'revision_id');
  return header;
}

String _envelopeRevision(Map<String, Object?> envelope) {
  final header = envelope['header'];
  if (header is! Map || header['revision_id'] is! String) {
    throw const FormatException('Local record revision is missing.');
  }
  final revision = header['revision_id']! as String;
  _requireUuid(revision, 'revision_id');
  return revision;
}

String _boundedHostText(
  Object? value,
  String field, {
  required int maxBytes,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      _hostTextControl.hasMatch(value)) {
    throw FormatException('Local Host $field is invalid.');
  }
  if (utf8.encode(value).length > maxBytes) {
    throw FormatException('Local Host $field is too long.');
  }
  return value;
}

void _exactKeys(Map<String, dynamic> value, Set<String> fields, String label) {
  if (value.keys.toSet().difference(fields).isNotEmpty ||
      !value.keys.toSet().containsAll(fields)) {
    throw FormatException('$label fields are invalid.');
  }
}

bool _hasExactKeys(Map<String, dynamic> value, Set<String> fields) =>
    value.keys.toSet().length == fields.length &&
    value.keys.toSet().containsAll(fields);

bool _isCanonicalUuidValue(Object? value) =>
    value is String && isCanonicalLocalProfileId(value);

void _requireUuid(Object? value, String field) {
  if (!_isCanonicalUuidValue(value)) {
    throw FormatException('Local $field is invalid.');
  }
}
