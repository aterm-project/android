import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../crypto/jcs.dart';
import '../domain/conflict_feed.dart';
import 'client_database_connection.dart';
import 'local_profile_namespace.dart';

part 'client_database.g.dart';

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

int _max(int left, int right) => left > right ? left : right;

bool _hasCanonicalJson(String encoded, String expected) {
  try {
    return canonicalJson(jsonDecode(encoded)) == expected;
  } on Object {
    return false;
  }
}

int _compareDecimalSeq(String left, String right) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(left) ||
      !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(right)) {
    throw const FormatException('Sequence must be a canonical decimal string.');
  }
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}

const _uuid = Uuid();
const _maxSnapshotRecoveryHeads = 100000;
const _maxSnapshotRecoveryJsonBytes = 64 * 1024 * 1024;
final _canonicalObjectReference = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

class SnapshotHead {
  const SnapshotHead({
    required this.recordId,
    required this.revisionId,
    required this.deleted,
    required this.envelope,
    this.commitSeq,
    this.redactionProof,
  });

  final String recordId;
  final String revisionId;
  final bool deleted;
  final Map<String, dynamic> envelope;

  /// Present only for graveyard entries. In that case [envelope] is empty and
  /// the live record cache must never materialize it as an encrypted head.
  final Map<String, dynamic>? redactionProof;

  bool get isGraveyard => redactionProof != null;

  /// Sequence assigned by the server for this committed head. Portable legacy
  /// snapshots may omit it, in which case the cache must remain uncommitted.
  final String? commitSeq;
}

class SnapshotApplyResult {
  const SnapshotApplyResult({required this.localConflictIds});

  final List<String> localConflictIds;
}

/// The encrypted cache head changed after a caller read it and before its
/// local operation was committed. Callers that can safely rebase may reload
/// the head and retry; other callers should fail closed.
class LocalRecordHeadChangedException implements Exception {
  const LocalRecordHeadChangedException(this.recordId);

  final String recordId;

  @override
  String toString() => 'Local record head changed while saving $recordId.';
}

class SnapshotBootstrapLimitException implements Exception {
  const SnapshotBootstrapLimitException();

  static const message =
      'This snapshot exceeds the client staging limit (64 MiB serialized manifest or 100,000 heads). The existing cache, checkpoint, and pending operations are preserved. Repeating recovery will not help; contact the project maintainer for a higher-capacity client or migration guidance.';

  @override
  String toString() => message;
}

/// A previously verified local graveyard proof prevents a snapshot from
/// silently resurrecting that record, including after a server backup restore
/// advances the generation. The old cache and checkpoint remain active.
class SnapshotRedactionResurrectionException implements Exception {
  const SnapshotRedactionResurrectionException(this.recordId);

  final String recordId;

  @override
  String toString() =>
      'Snapshot contains record $recordId, which this device already redacted. '
      'The active local cache and checkpoint were preserved.';
}

class PushCommitReceipt {
  const PushCommitReceipt({
    required this.opId,
    required this.revisionId,
    required this.commitSeq,
  });

  final String opId;
  final String revisionId;
  final String commitSeq;
}

/// Result of persisting an immutable create envelope in the target Vault.
enum ExactCreateOperationResult { created, pending, committed }

class _ExactCreateEnvelope {
  const _ExactCreateEnvelope({
    required this.recordId,
    required this.revisionId,
    required this.opId,
    required this.nextSequence,
  });

  final String recordId;
  final String revisionId;
  final String opId;
  final int nextSequence;
}

class StaleOperationReplacement {
  const StaleOperationReplacement({
    required this.opId,
    required this.baseRevisionId,
    required this.baseEnvelopeJson,
    required this.envelopeJson,
  });

  final String opId;
  final String? baseRevisionId;
  final String? baseEnvelopeJson;
  final String envelopeJson;
}

class PendingConflictResolution {
  const PendingConflictResolution({
    required this.conflictId,
    required this.opId,
    required this.revisionId,
  });

  final String conflictId;
  final String opId;
  final String revisionId;
}

class ArchivePendingOperation {
  const ArchivePendingOperation({
    required this.opId,
    required this.recordId,
    required this.baseRevisionId,
    required this.baseEnvelopeJson,
    required this.envelopeJson,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.lastAttemptAt,
  });

  final String opId;
  final String recordId;
  final String? baseRevisionId;
  final String? baseEnvelopeJson;
  final String envelopeJson;
  final String status;
  final int attemptCount;
  final int createdAt;
  final int? lastAttemptAt;
}

class ArchiveConflictBranch {
  const ArchiveConflictBranch({
    required this.conflictId,
    required this.recordId,
    required this.kind,
    required this.branchEnvelopeJson,
    required this.remoteEnvelopeJson,
    required this.state,
    required this.resolutionOpId,
    required this.resolutionRevisionId,
    required this.createdAt,
  });

  final String conflictId;
  final String recordId;
  final String kind;
  final String branchEnvelopeJson;
  final String remoteEnvelopeJson;
  final String state;
  final String? resolutionOpId;
  final String? resolutionRevisionId;
  final int createdAt;
}

class ArchiveObjectBytes {
  const ArchiveObjectBytes({
    required this.objectId,
    required this.bytes,
    required this.sha256,
  });

  final String objectId;
  final Uint8List bytes;
  final String sha256;
}

class EncryptedRecords extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get revisionId => text().named('revision_id')();
  TextColumn get envelopeJson => text().named('envelope_json')();
  BoolColumn get isDeleted =>
      boolean().named('is_deleted').withDefault(const Constant(false))();
  TextColumn get commitSeq => text().named('commit_seq').nullable()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {vaultId, recordId, instanceId, serverSpaceId};
}

class PendingOperations extends Table {
  TextColumn get opId => text().named('op_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get baseRevisionId =>
      text().named('base_revision_id').nullable()();
  TextColumn get baseEnvelopeJson =>
      text().named('base_envelope_json').nullable()();
  TextColumn get envelopeJson => text().named('envelope_json')();
  TextColumn get status => text().withDefault(const Constant('queued'))();
  IntColumn get attemptCount =>
      integer().named('attempt_count').withDefault(const Constant(0))();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get lastAttemptAt =>
      integer().named('last_attempt_at').nullable()();

  @override
  Set<Column> get primaryKey => {opId};
}

/// Pending evidence that a locally submitted operation was committed by a
/// signed main-feed event. The active cache keeps only the newest head, so this
/// row lets a delayed push response be acknowledged after a descendant head has
/// replaced the operation's cached revision. A matching push receipt consumes
/// the evidence transactionally with acknowledgement.
class AuthenticatedPushReceipts extends Table {
  TextColumn get opId => text().named('op_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get revisionId => text().named('revision_id')();
  TextColumn get envelopeJson => text().named('envelope_json')();
  TextColumn get commitSeq => text().named('commit_seq')();
  IntColumn get createdAt =>
      integer().named('created_at').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {opId};
}

class SyncCheckpoints extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get cursor => text().nullable()();
  TextColumn get serverGeneration =>
      text().named('server_generation').nullable()();
  TextColumn get syncStatus =>
      text().named('sync_status').withDefault(const Constant('idle'))();
  IntColumn get lastSuccessAt =>
      integer().named('last_success_at').nullable()();

  @override
  Set<Column> get primaryKey => {vaultId, instanceId, serverSpaceId};
}

/// A separate authenticated cursor for pages received while a server workspace
/// is locked. These pages contain only verified signed ciphertext and are
/// replayed through the normal keyed repository after unlock. Keeping this
/// cursor apart from [SyncCheckpoints] prevents the ordinary sync cursor from
/// skipping work that still needs decryption and conflict reconciliation.
class LockedSyncCheckpoints extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get cursor => text().nullable()();
  IntColumn get nextPageIndex =>
      integer().named('next_page_index').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {vaultId, instanceId, serverSpaceId};
}

/// Opaque, signature-verified changes pages received by a locked workspace.
/// The event JSON retains ciphertext and protocol metadata only; it is never
/// decrypted or projected into the record cache until an unlocked repository
/// replays the page.
class LockedSyncInboxPages extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get serverGeneration => text().named('server_generation')();
  IntColumn get pageIndex => integer().named('page_index')();
  TextColumn get startCursor => text().named('start_cursor').nullable()();
  TextColumn get nextCursor => text().named('next_cursor').nullable()();
  BoolColumn get hasMore => boolean().named('has_more')();
  TextColumn get eventsJson => text().named('events_json')();

  @override
  Set<Column> get primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    pageIndex,
  };
}

/// Durable encrypted snapshot recovery metadata. The full authenticated server
/// scope and immutable snapshot identity form the primary key so an interrupted
/// recovery cannot be resumed under another account, instance, Vault, or
/// generation. Cursors and watermarks are protocol metadata; item payloads live
/// separately as opaque encrypted envelopes.
class SyncSnapshotRecoveryStages extends Table {
  TextColumn get serverNamespace => text().named('server_namespace')();
  TextColumn get accountId => text().named('account_id')();
  TextColumn get instanceId => text().named('instance_id')();
  TextColumn get serverSpaceId => text().named('server_space_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get snapshotId => text().named('snapshot_id')();
  TextColumn get highWatermark => text().named('high_watermark')();
  TextColumn get conflictHighWatermark =>
      text().named('conflict_high_watermark')();
  TextColumn get checkpointCursor => text().named('checkpoint_cursor')();
  TextColumn get expiresAt => text().named('expires_at')();
  TextColumn get nextPageCursor =>
      text().named('next_page_cursor').nullable()();
  TextColumn get lastRecordId => text().named('last_record_id').nullable()();
  IntColumn get expectedItemCount =>
      integer().named('expected_item_count').nullable()();
  BoolColumn get itemCountObserved => boolean()
      .named('item_count_observed')
      .withDefault(const Constant(false))();
  BoolColumn get itemCountPresent => boolean()
      .named('item_count_present')
      .withDefault(const Constant(false))();
  IntColumn get verifiedItemCount =>
      integer().named('verified_item_count').withDefault(const Constant(0))();
  IntColumn get serializedManifestBytes => integer()
      .named('serialized_manifest_bytes')
      .withDefault(const Constant(2))();
  IntColumn get pageCount =>
      integer().named('page_count').withDefault(const Constant(0))();
  BoolColumn get legacyFullManifest =>
      boolean().named('legacy_full_manifest').nullable()();
  BoolColumn get complete => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer().named('created_at')();

  @override
  Set<Column> get primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
  };
}

/// One already signature-verified, successfully decrypted snapshot head.
/// Only its signed/encrypted envelope and the minimum public head metadata are
/// stored here; decrypted Vault contents are never persisted in the stage.
@TableIndex(
  name: 'sync_snapshot_recovery_item_order',
  columns: {
    #serverNamespace,
    #accountId,
    #instanceId,
    #serverSpaceId,
    #vaultId,
    #serverGeneration,
    #snapshotId,
    #ordinal,
  },
)
class SyncSnapshotRecoveryItems extends Table {
  TextColumn get serverNamespace => text().named('server_namespace')();
  TextColumn get accountId => text().named('account_id')();
  TextColumn get instanceId => text().named('instance_id')();
  TextColumn get serverSpaceId => text().named('server_space_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get snapshotId => text().named('snapshot_id')();
  TextColumn get recordId => text().named('record_id')();
  IntColumn get ordinal => integer()();
  TextColumn get revisionId => text().named('revision_id')();
  BoolColumn get deleted => boolean()();
  TextColumn get envelopeJson => text().named('envelope_json')();
  TextColumn get commitSeq => text().named('commit_seq').nullable()();
  TextColumn get redactionJson => text().named('redaction_json').nullable()();

  @override
  Set<Column> get primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    recordId,
  };

  @override
  List<Set<Column>> get uniqueKeys => [
    {
      serverNamespace,
      accountId,
      instanceId,
      serverSpaceId,
      vaultId,
      serverGeneration,
      snapshotId,
      ordinal,
    },
  ];
}

/// Durable verified graveyard proof. A row reserves a record ID after its
/// encrypted head has been erased from the active cache.
class SyncRedactions extends Table {
  TextColumn get instanceId => text().named('instance_id')();
  TextColumn get serverSpaceId => text().named('server_space_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get redactionId => text().named('redaction_id')();
  TextColumn get deletedRevisionId => text().named('deleted_revision_id')();
  TextColumn get deletedSeq => text().named('deleted_seq')();
  TextColumn get redactionSeq => text().named('redaction_seq')();
  TextColumn get proofJson => text().named('proof_json')();
  TextColumn get serverGeneration => text().named('server_generation')();
  IntColumn get appliedAt => integer().named('applied_at')();

  @override
  Set<Column> get primaryKey => {instanceId, serverSpaceId, vaultId, recordId};
}

/// Persisted opaque page cursors prevent a resumed snapshot from accepting a
/// continuation cycle after process loss.
class SyncSnapshotRecoveryCursors extends Table {
  TextColumn get serverNamespace => text().named('server_namespace')();
  TextColumn get accountId => text().named('account_id')();
  TextColumn get instanceId => text().named('instance_id')();
  TextColumn get serverSpaceId => text().named('server_space_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get snapshotId => text().named('snapshot_id')();
  TextColumn get cursor => text()();

  @override
  Set<Column> get primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    cursor,
  };
}

/// Authenticated identity for durable snapshot recovery staging.
class SnapshotRecoveryScope {
  const SnapshotRecoveryScope({
    required this.serverNamespace,
    required this.accountId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.serverGeneration,
  });

  final String serverNamespace;
  final String accountId;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String serverGeneration;
}

/// In-memory protocol state for one opaque encrypted snapshot stage.
class SnapshotRecoveryStage {
  const SnapshotRecoveryStage({
    required this.scope,
    required this.snapshotId,
    required this.highWatermark,
    required this.conflictHighWatermark,
    required this.checkpointCursor,
    required this.expiresAt,
    required this.nextPageCursor,
    required this.lastRecordId,
    required this.expectedItemCount,
    required this.itemCountObserved,
    required this.itemCountPresent,
    required this.verifiedItemCount,
    required this.serializedManifestBytes,
    required this.pageCount,
    required this.legacyFullManifest,
    required this.complete,
  });

  final SnapshotRecoveryScope scope;
  final String snapshotId;
  final String highWatermark;
  final String conflictHighWatermark;
  final String checkpointCursor;
  final String expiresAt;
  final String? nextPageCursor;
  final String? lastRecordId;
  final int? expectedItemCount;
  final bool itemCountObserved;
  final bool itemCountPresent;
  final int verifiedItemCount;
  final int serializedManifestBytes;
  final int pageCount;
  final bool? legacyFullManifest;
  final bool complete;
}

class SnapshotRecoveryStagedHead {
  const SnapshotRecoveryStagedHead({
    required this.ordinal,
    required this.recordId,
    required this.revisionId,
    required this.deleted,
    required this.envelopeJson,
    required this.commitSeq,
    required this.redactionJson,
  });

  final int ordinal;
  final String recordId;
  final String revisionId;
  final bool deleted;
  final String envelopeJson;
  final String? commitSeq;
  final String? redactionJson;
}

class ConflictBranches extends Table {
  TextColumn get conflictId => text().named('conflict_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get kind => text()();
  TextColumn get branchEnvelopeJson => text().named('branch_envelope_json')();
  TextColumn get remoteEnvelopeJson => text().named('remote_envelope_json')();
  TextColumn get state => text().withDefault(const Constant('open'))();
  TextColumn get resolutionOpId =>
      text().named('resolution_op_id').nullable()();
  TextColumn get resolutionRevisionId =>
      text().named('resolution_revision_id').nullable()();
  TextColumn get redactionProofJson =>
      text().named('redaction_proof_json').nullable()();
  IntColumn get createdAt => integer().named('created_at')();

  @override
  Set<Column> get primaryKey => {conflictId};
}

/// Cursor for one server generation's independent conflict event stream.
class ConflictFeedCheckpoints extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get partitionId => text().named('partition_id')();
  TextColumn get afterSeq => text().named('after_seq')();

  @override
  Set<Column> get primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
  };
}

/// The generation whose inbox is currently visible for a Vault. Older
/// generation partitions stay durable but are hidden from the active feed.
class ConflictFeedStates extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get partitionId => text().named('partition_id')();

  @override
  Set<Column> get primaryKey => {vaultId, instanceId, serverSpaceId};
}

/// Metadata-only inbox for live conflict changes. Envelopes remain opaque
/// ciphertext and are never applied to EncryptedRecords or ConflictBranches.
class ConflictFeedInbox extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get serverGeneration => text().named('server_generation')();
  TextColumn get instanceId =>
      text().named('instance_id').withDefault(const Constant(''))();
  TextColumn get serverSpaceId =>
      text().named('server_space_id').withDefault(const Constant(''))();
  TextColumn get partitionId => text().named('partition_id')();
  TextColumn get seq => text()();
  TextColumn get conflictId => text().named('conflict_id')();
  TextColumn get eventType => text().named('event_type')();
  TextColumn get eventJson => text().named('event_json')();

  @override
  Set<Column> get primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
    seq,
  };
}

/// Durable resolution handoff for one server conflict. An operation id is
/// absent for the "keep current committed head" choice.
class FeedConflictResolutions extends Table {
  TextColumn get conflictId => text().named('conflict_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get opId => text().named('op_id').nullable()();
  TextColumn get resolutionRevisionId =>
      text().named('resolution_revision_id')();
  TextColumn get state => text()();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {conflictId};
}

class TrustedDevices extends Table {
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get signingPublicKey => text().named('signing_public_key')();
  TextColumn get displayNameEnvelope =>
      text().named('display_name_envelope').nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

class DeviceSequences extends Table {
  TextColumn get deviceId => text().named('device_id')();
  IntColumn get nextSequence =>
      integer().named('next_sequence').withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {deviceId};
}

class VaultArchiveObjects extends Table {
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get objectId => text().named('object_id')();
  BlobColumn get bytes => blob()();
  TextColumn get sha256 => text()();
  IntColumn get importedAt => integer().named('imported_at')();

  @override
  Set<Column> get primaryKey => {vaultId, objectId};
}

/// Durable attachment transfer state. It deliberately stores no filename,
/// media type, blob key, or plaintext; those remain in the encrypted Host
/// record. Object bytes stored alongside a job are ciphertext only.
class BlobJobs extends Table {
  TextColumn get jobId => text().named('job_id')();
  TextColumn get vaultId => text().named('vault_id')();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get instanceId => text().named('instance_id').nullable()();
  TextColumn get serverSpaceId => text().named('server_space_id').nullable()();
  TextColumn get blobId => text().named('blob_id')();
  TextColumn get direction => text()();
  TextColumn get state => text()();
  IntColumn get totalObjects =>
      integer().named('total_objects').withDefault(const Constant(0))();
  IntColumn get attemptCount =>
      integer().named('attempt_count').withDefault(const Constant(0))();
  TextColumn get lastErrorCode => text().named('last_error_code').nullable()();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {jobId};
}

/// Per-object retry state. For uploads `bytes` contains the full encrypted
/// object. For downloads it contains only the verified-by-ETag byte prefix
/// assembled from Range responses until the full object hash is checked.
class BlobJobObjects extends Table {
  TextColumn get jobId => text().named('job_id')();
  TextColumn get objectId => text().named('object_id')();
  TextColumn get sha256 => text()();
  IntColumn get size => integer()();
  BlobColumn get bytes => blob().nullable()();
  TextColumn get uploadId => text().named('upload_id').nullable()();
  IntColumn get uploadChunkSize =>
      integer().named('upload_chunk_size').nullable()();
  IntColumn get nextChunkIndex =>
      integer().named('next_chunk_index').withDefault(const Constant(0))();
  BoolColumn get transferred => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {jobId, objectId};
}

/// Encrypted terminal history payloads, partitioned by server/account/device.
/// This table deliberately has no command, host, or other searchable plaintext
/// fields. The client stores ciphertext as opaque bytes and indexes only the
/// namespace and timestamps needed for isolation and retention.
class TerminalHistoryEntries extends Table {
  TextColumn get serverNamespace => text().named('server_namespace')();
  TextColumn get accountId => text().named('account_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get entryId => text().named('entry_id')();
  BlobColumn get ciphertext => blob()();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {serverNamespace, accountId, deviceId, entryId};
}

/// An opaque encrypted terminal history row and its non-sensitive metadata.
class TerminalHistoryCiphertextEntry {
  const TerminalHistoryCiphertextEntry({
    required this.entryId,
    required this.ciphertext,
    required this.createdAt,
    required this.updatedAt,
  });

  final String entryId;
  final Uint8List ciphertext;
  final int createdAt;
  final int updatedAt;
}

/// Metadata-only view of one staged transfer object. Keeping this separate
/// from Drift's generated BlobJobObject makes progress and resume scans unable
/// to materialize the ciphertext BLOB column.
class BlobJobObjectProgress {
  const BlobJobObjectProgress({
    required this.objectId,
    required this.sha256,
    required this.size,
    required this.stagedBytes,
    required this.uploadId,
    required this.uploadChunkSize,
    required this.nextChunkIndex,
    required this.transferred,
  });

  final String objectId;
  final String sha256;
  final int size;
  final int stagedBytes;
  final String? uploadId;
  final int? uploadChunkSize;
  final int nextChunkIndex;
  final bool transferred;
}

@DriftDatabase(
  tables: [
    EncryptedRecords,
    PendingOperations,
    AuthenticatedPushReceipts,
    SyncCheckpoints,
    LockedSyncCheckpoints,
    LockedSyncInboxPages,
    SyncSnapshotRecoveryStages,
    SyncSnapshotRecoveryItems,
    SyncRedactions,
    SyncSnapshotRecoveryCursors,
    ConflictBranches,
    TrustedDevices,
    DeviceSequences,
    VaultArchiveObjects,
    BlobJobs,
    BlobJobObjects,
    ConflictFeedCheckpoints,
    ConflictFeedInbox,
    ConflictFeedStates,
    FeedConflictResolutions,
    TerminalHistoryEntries,
  ],
)
class ClientDatabase extends _$ClientDatabase {
  /// A push receipt normally arrives in the same HTTP request that submitted
  /// the operation. Keep event proofs for one day to cover delayed tabs and
  /// transient transport recovery, then discard them as redundant feed state.
  static const authenticatedPushReceiptRetention = Duration(days: 1);

  ClientDatabase._(super.e);

  ClientDatabase.forTesting(super.e);

  /// Preflights Web storage before opening Drift's Vault connection, then
  /// waits for the local database to be query-ready before returning it.
  static Future<ClientDatabase> open() => _openNamed(serverClientDatabaseName);

  /// Opens a physically separate database for one local-only profile. This
  /// factory does not configure a server session or imply that the existing
  /// server SyncRepository/outbox is appropriate for local use.
  static Future<ClientDatabase> openLocalProfile(String profileId) =>
      _openNamed(localProfileDatabaseName(profileId));

  static Future<ClientDatabase> _openNamed(String name) async {
    final connection = await openClientDatabaseConnection(name: name);
    final database = ClientDatabase._(connection);
    try {
      await database.ensureReady();
      return database;
    } on Object {
      try {
        await database.close();
      } on Object {
        // Some delayed native executors fail before they have an open handle.
      }
      rethrow;
    }
  }

  /// Forces the selected executor to finish opening before authentication UI
  /// or any account-backed controller can be mounted.
  Future<void> ensureReady() async {
    await customSelect('SELECT 1').get();
    await pruneAuthenticatedPushReceipts();
  }

  /// Removes only proofs older than the retention window. Their corresponding
  /// commits were already verified from the main feed before insertion, so
  /// this bounded local evidence is no longer needed after the grace period.
  /// The caller may supply [now] to make the expiry boundary deterministic in
  /// database tests.
  Future<int> pruneAuthenticatedPushReceipts({DateTime? now}) async {
    final currentTime = now ?? DateTime.now();
    final cutoff =
        currentTime.millisecondsSinceEpoch -
        authenticatedPushReceiptRetention.inMilliseconds;
    return transaction(
      () => (delete(
        authenticatedPushReceipts,
      )..where((row) => row.createdAt.isSmallerThanValue(cutoff))).go(),
    );
  }

  /// Forces committed SQLite page changes through Drift's Web IndexedDB VFS.
  /// Drift can return from COMMIT before its asynchronous file-system writes
  /// have finished; running this read-only statement outside the transaction
  /// awaits those pending writes before the caller reports the mutation saved.
  Future<void> flushCommittedWrites() async {
    await customStatement('PRAGMA data_version');
  }

  /// Returns the newest unexpired resumable snapshot for this authenticated
  /// scope. Incomplete legacy full-manifest responses have no server cursor,
  /// so they are discarded and fetched again after a process restart.
  Future<SnapshotRecoveryStage?> resumableSnapshotRecoveryStage(
    SnapshotRecoveryScope scope, {
    required DateTime now,
  }) async {
    final rows =
        await (select(syncSnapshotRecoveryStages)
              ..where(
                (row) =>
                    row.serverNamespace.equals(scope.serverNamespace) &
                    row.accountId.equals(scope.accountId) &
                    row.instanceId.equals(scope.instanceId) &
                    row.serverSpaceId.equals(scope.serverSpaceId) &
                    row.vaultId.equals(scope.vaultId) &
                    row.serverGeneration.equals(scope.serverGeneration),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
              ..limit(1))
            .get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    final expiration = DateTime.tryParse(row.expiresAt)?.toUtc();
    if (expiration == null || !expiration.isAfter(now.toUtc())) {
      await discardSnapshotRecoveryStage(scope, row.snapshotId);
      return null;
    }
    if (row.legacyFullManifest == true && !row.complete) {
      await discardSnapshotRecoveryStage(scope, row.snapshotId);
      return null;
    }
    if (row.verifiedItemCount < 0 ||
        row.verifiedItemCount > _maxSnapshotRecoveryHeads ||
        row.serializedManifestBytes < 2 ||
        row.serializedManifestBytes > _maxSnapshotRecoveryJsonBytes ||
        (row.itemCountPresent != (row.expectedItemCount != null)) ||
        (row.expectedItemCount != null &&
            (row.expectedItemCount! < 0 ||
                row.expectedItemCount! > _maxSnapshotRecoveryHeads ||
                row.expectedItemCount! < row.verifiedItemCount ||
                (row.complete &&
                    row.expectedItemCount != row.verifiedItemCount))) ||
        (row.complete && row.nextPageCursor != null)) {
      throw const FormatException('Stored snapshot recovery state is invalid.');
    }
    if (row.nextPageCursor != null &&
        !await _hasSnapshotRecoveryCursor(
          scope,
          row.snapshotId,
          row.nextPageCursor!,
        )) {
      throw const FormatException(
        'Stored snapshot continuation cursor was not committed with a page.',
      );
    }
    return SnapshotRecoveryStage(
      scope: scope,
      snapshotId: row.snapshotId,
      highWatermark: row.highWatermark,
      conflictHighWatermark: row.conflictHighWatermark,
      checkpointCursor: row.checkpointCursor,
      expiresAt: row.expiresAt,
      nextPageCursor: row.nextPageCursor,
      lastRecordId: row.lastRecordId,
      expectedItemCount: row.expectedItemCount,
      itemCountObserved: row.itemCountObserved,
      itemCountPresent: row.itemCountPresent,
      verifiedItemCount: row.verifiedItemCount,
      serializedManifestBytes: row.serializedManifestBytes,
      pageCount: row.pageCount,
      legacyFullManifest: row.legacyFullManifest,
      complete: row.complete,
    );
  }

  /// Starts one new immutable snapshot stage and removes only older stages in
  /// the same server/account/instance/space/Vault namespace.
  Future<void> beginSnapshotRecoveryStage({
    required SnapshotRecoveryScope scope,
    required String snapshotId,
    required String highWatermark,
    required String conflictHighWatermark,
    required String checkpointCursor,
    required String expiresAt,
    required bool itemCountPresent,
    required int? expectedItemCount,
    required int createdAt,
  }) => transaction(() async {
    await (delete(syncSnapshotRecoveryItems)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryCursors)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryStages)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId),
        ))
        .go();
    await into(syncSnapshotRecoveryStages).insert(
      SyncSnapshotRecoveryStagesCompanion.insert(
        serverNamespace: scope.serverNamespace,
        accountId: scope.accountId,
        instanceId: scope.instanceId,
        serverSpaceId: scope.serverSpaceId,
        vaultId: scope.vaultId,
        serverGeneration: scope.serverGeneration,
        snapshotId: snapshotId,
        highWatermark: highWatermark,
        conflictHighWatermark: conflictHighWatermark,
        checkpointCursor: checkpointCursor,
        expiresAt: expiresAt,
        itemCountObserved: Value(itemCountPresent),
        itemCountPresent: Value(itemCountPresent),
        expectedItemCount: Value(expectedItemCount),
        createdAt: createdAt,
      ),
    );
  });

  /// Atomically stores one already verified page and its continuation state.
  /// The caller flushes Web IndexedDB writes after this transaction commits.
  Future<SnapshotRecoveryStage> persistSnapshotRecoveryPage({
    required SnapshotRecoveryScope scope,
    required String snapshotId,
    required String highWatermark,
    required String conflictHighWatermark,
    required String checkpointCursor,
    required String expiresAt,
    required String? requestedPageCursor,
    required List<SnapshotHead> heads,
    required int serializedHeadBytes,
    required bool pageItemCountPresent,
    required int? pageItemCount,
    required bool legacyFullManifest,
    required bool hasMore,
    required String? nextPageCursor,
  }) => transaction(() async {
    final current = await _readSnapshotRecoveryStage(scope, snapshotId);
    if (current == null ||
        current.highWatermark != highWatermark ||
        current.conflictHighWatermark != conflictHighWatermark ||
        current.checkpointCursor != checkpointCursor ||
        current.expiresAt != expiresAt ||
        current.complete ||
        current.nextPageCursor != requestedPageCursor ||
        (current.pageCount > 0 &&
            current.legacyFullManifest != legacyFullManifest) ||
        (legacyFullManifest && requestedPageCursor != null)) {
      throw const FormatException(
        'Snapshot page does not continue the persisted stage boundary.',
      );
    }
    if (requestedPageCursor != null &&
        !await _hasSnapshotRecoveryCursor(
          scope,
          snapshotId,
          requestedPageCursor,
        )) {
      throw const FormatException(
        'Snapshot request cursor was not committed with a prior page.',
      );
    }
    if (current.itemCountObserved &&
        current.itemCountPresent != pageItemCountPresent) {
      throw const FormatException(
        'Snapshot item_count presence changed between pages.',
      );
    }
    if (pageItemCountPresent &&
        (pageItemCount == null ||
            pageItemCount < 0 ||
            pageItemCount > _maxSnapshotRecoveryHeads ||
            (current.expectedItemCount != null &&
                current.expectedItemCount != pageItemCount))) {
      throw const FormatException(
        'Snapshot item_count is invalid or changed between pages.',
      );
    }
    if (!pageItemCountPresent && pageItemCount != null) {
      throw const FormatException('Snapshot item_count metadata is invalid.');
    }
    if ((hasMore &&
            ((legacyFullManifest && nextPageCursor != null) ||
                (!legacyFullManifest &&
                    (nextPageCursor == null ||
                        nextPageCursor.trim().isEmpty ||
                        nextPageCursor.length > 2048 ||
                        nextPageCursor == requestedPageCursor)))) ||
        (!hasMore && nextPageCursor != null) ||
        (hasMore && heads.isEmpty)) {
      throw const FormatException('Snapshot continuation cursor is invalid.');
    }

    final nextHeadCount = current.verifiedItemCount + heads.length;
    final separatorBytes = heads.isEmpty
        ? 0
        : current.verifiedItemCount == 0
        ? heads.length - 1
        : heads.length;
    final nextJsonBytes =
        current.serializedManifestBytes + serializedHeadBytes + separatorBytes;
    if (nextHeadCount > _maxSnapshotRecoveryHeads ||
        nextJsonBytes > _maxSnapshotRecoveryJsonBytes) {
      throw const SnapshotBootstrapLimitException();
    }
    if (pageItemCountPresent && pageItemCount! < nextHeadCount) {
      throw const FormatException(
        'Snapshot item_count is smaller than its received pages.',
      );
    }
    if (!hasMore && pageItemCountPresent && pageItemCount != nextHeadCount) {
      throw const FormatException(
        'Snapshot item_count does not match the complete manifest.',
      );
    }

    var previousRecordId = current.lastRecordId;
    for (final head in heads) {
      if (head.recordId.isEmpty ||
          (previousRecordId != null &&
              head.recordId.compareTo(previousRecordId) <= 0)) {
        throw const FormatException(
          'Snapshot record ids are duplicate or out of order.',
        );
      }
      previousRecordId = head.recordId;
    }

    if (hasMore && !legacyFullManifest) {
      await into(syncSnapshotRecoveryCursors).insert(
        SyncSnapshotRecoveryCursorsCompanion.insert(
          serverNamespace: scope.serverNamespace,
          accountId: scope.accountId,
          instanceId: scope.instanceId,
          serverSpaceId: scope.serverSpaceId,
          vaultId: scope.vaultId,
          serverGeneration: scope.serverGeneration,
          snapshotId: snapshotId,
          cursor: nextPageCursor!,
        ),
      );
    }
    for (var index = 0; index < heads.length; index++) {
      final head = heads[index];
      await into(syncSnapshotRecoveryItems).insert(
        SyncSnapshotRecoveryItemsCompanion.insert(
          serverNamespace: scope.serverNamespace,
          accountId: scope.accountId,
          instanceId: scope.instanceId,
          serverSpaceId: scope.serverSpaceId,
          vaultId: scope.vaultId,
          serverGeneration: scope.serverGeneration,
          snapshotId: snapshotId,
          recordId: head.recordId,
          ordinal: current.verifiedItemCount + index,
          revisionId: head.revisionId,
          deleted: head.deleted,
          envelopeJson: head.isGraveyard ? '{}' : jsonEncode(head.envelope),
          commitSeq: Value(head.commitSeq),
          redactionJson: Value(
            head.redactionProof == null
                ? null
                : jsonEncode(head.redactionProof),
          ),
        ),
      );
    }
    await (update(syncSnapshotRecoveryStages)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .write(
          SyncSnapshotRecoveryStagesCompanion(
            itemCountObserved: const Value(true),
            itemCountPresent: Value(pageItemCountPresent),
            expectedItemCount: Value(
              pageItemCountPresent ? pageItemCount : current.expectedItemCount,
            ),
            verifiedItemCount: Value(nextHeadCount),
            serializedManifestBytes: Value(nextJsonBytes),
            pageCount: Value(current.pageCount + 1),
            legacyFullManifest: Value(legacyFullManifest),
            lastRecordId: Value(previousRecordId),
            nextPageCursor: Value(nextPageCursor),
            complete: Value(!hasMore),
          ),
        );
    return (await _readSnapshotRecoveryStage(scope, snapshotId))!;
  });

  Future<void> discardSnapshotRecoveryStage(
    SnapshotRecoveryScope scope,
    String snapshotId,
  ) => transaction(() async {
    await (delete(syncSnapshotRecoveryItems)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryCursors)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryStages)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
  });

  /// Reads a bounded chunk of staged opaque envelopes for integrity
  /// re-verification after a process restart.
  Future<List<SnapshotRecoveryStagedHead>> snapshotRecoveryStagedHeads({
    required SnapshotRecoveryScope scope,
    required String snapshotId,
    required int afterOrdinal,
    int limit = 100,
  }) async {
    if (afterOrdinal < -1 || limit < 1 || limit > 1000) {
      throw ArgumentError('Invalid snapshot staging page bounds.');
    }
    final rows =
        await (select(syncSnapshotRecoveryItems)
              ..where(
                (row) =>
                    row.serverNamespace.equals(scope.serverNamespace) &
                    row.accountId.equals(scope.accountId) &
                    row.instanceId.equals(scope.instanceId) &
                    row.serverSpaceId.equals(scope.serverSpaceId) &
                    row.vaultId.equals(scope.vaultId) &
                    row.serverGeneration.equals(scope.serverGeneration) &
                    row.snapshotId.equals(snapshotId) &
                    row.ordinal.isBiggerThanValue(afterOrdinal),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)])
              ..limit(limit))
            .get();
    return [
      for (final row in rows)
        SnapshotRecoveryStagedHead(
          ordinal: row.ordinal,
          recordId: row.recordId,
          revisionId: row.revisionId,
          deleted: row.deleted,
          envelopeJson: row.envelopeJson,
          commitSeq: row.commitSeq,
          redactionJson: row.redactionJson,
        ),
    ];
  }

  Future<SnapshotRecoveryStage?> _readSnapshotRecoveryStage(
    SnapshotRecoveryScope scope,
    String snapshotId,
  ) async {
    final row =
        await (select(syncSnapshotRecoveryStages)..where(
              (row) =>
                  row.serverNamespace.equals(scope.serverNamespace) &
                  row.accountId.equals(scope.accountId) &
                  row.instanceId.equals(scope.instanceId) &
                  row.serverSpaceId.equals(scope.serverSpaceId) &
                  row.vaultId.equals(scope.vaultId) &
                  row.serverGeneration.equals(scope.serverGeneration) &
                  row.snapshotId.equals(snapshotId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return SnapshotRecoveryStage(
      scope: scope,
      snapshotId: row.snapshotId,
      highWatermark: row.highWatermark,
      conflictHighWatermark: row.conflictHighWatermark,
      checkpointCursor: row.checkpointCursor,
      expiresAt: row.expiresAt,
      nextPageCursor: row.nextPageCursor,
      lastRecordId: row.lastRecordId,
      expectedItemCount: row.expectedItemCount,
      itemCountObserved: row.itemCountObserved,
      itemCountPresent: row.itemCountPresent,
      verifiedItemCount: row.verifiedItemCount,
      serializedManifestBytes: row.serializedManifestBytes,
      pageCount: row.pageCount,
      legacyFullManifest: row.legacyFullManifest,
      complete: row.complete,
    );
  }

  /// Local proofs remain an anti-resurrection guard across server generations.
  /// A pre-purge server backup may reintroduce the payload remotely, but the
  /// client must stop and preserve its current cache until an operator
  /// reconciles that restore explicitly.
  Future<void> _rejectSnapshotLiveHeadsWithRedactionProof({
    required String vaultId,
    required Set<String> liveRecordIds,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    if (liveRecordIds.isEmpty) return;
    final existing =
        await (select(syncRedactions)..where((row) {
              Expression<bool> predicate =
                  row.vaultId.equals(vaultId) &
                  row.recordId.isIn(liveRecordIds);
              if (instanceId != null) {
                predicate = predicate & row.instanceId.equals(instanceId);
              }
              if (serverSpaceId != null) {
                predicate = predicate & row.serverSpaceId.equals(serverSpaceId);
              }
              return predicate;
            }))
            .get();
    if (existing.isNotEmpty) {
      throw SnapshotRedactionResurrectionException(existing.first.recordId);
    }
  }

  Future<bool> _hasSnapshotRecoveryCursor(
    SnapshotRecoveryScope scope,
    String snapshotId,
    String cursor,
  ) async =>
      await (select(syncSnapshotRecoveryCursors)..where(
            (row) =>
                row.serverNamespace.equals(scope.serverNamespace) &
                row.accountId.equals(scope.accountId) &
                row.instanceId.equals(scope.instanceId) &
                row.serverSpaceId.equals(scope.serverSpaceId) &
                row.vaultId.equals(scope.vaultId) &
                row.serverGeneration.equals(scope.serverGeneration) &
                row.snapshotId.equals(snapshotId) &
                row.cursor.equals(cursor),
          ))
          .getSingleOrNull() !=
      null;

  Future<SnapshotApplyResult> applyStagedVaultSnapshot({
    required SnapshotRecoveryScope scope,
    required String snapshotId,
  }) => transaction(() async {
    final stage = await _readSnapshotRecoveryStage(scope, snapshotId);
    if (stage == null || !stage.complete || stage.nextPageCursor != null) {
      throw const FormatException('Snapshot stage is not complete.');
    }
    if (stage.expectedItemCount != null &&
        stage.expectedItemCount != stage.verifiedItemCount) {
      throw const FormatException('Snapshot stage count is inconsistent.');
    }
    final itemCount =
        await (selectOnly(syncSnapshotRecoveryItems)
              ..addColumns([syncSnapshotRecoveryItems.recordId.count()])
              ..where(
                syncSnapshotRecoveryItems.serverNamespace.equals(
                      scope.serverNamespace,
                    ) &
                    syncSnapshotRecoveryItems.accountId.equals(
                      scope.accountId,
                    ) &
                    syncSnapshotRecoveryItems.instanceId.equals(
                      scope.instanceId,
                    ) &
                    syncSnapshotRecoveryItems.serverSpaceId.equals(
                      scope.serverSpaceId,
                    ) &
                    syncSnapshotRecoveryItems.vaultId.equals(scope.vaultId) &
                    syncSnapshotRecoveryItems.serverGeneration.equals(
                      scope.serverGeneration,
                    ) &
                    syncSnapshotRecoveryItems.snapshotId.equals(snapshotId),
              ))
            .getSingle();
    if (itemCount.read<int>(syncSnapshotRecoveryItems.recordId.count()) !=
        stage.verifiedItemCount) {
      throw const FormatException('Snapshot stage items are incomplete.');
    }

    final stagedLiveRecords =
        await (select(syncSnapshotRecoveryItems)..where(
              (row) =>
                  row.serverNamespace.equals(scope.serverNamespace) &
                  row.accountId.equals(scope.accountId) &
                  row.instanceId.equals(scope.instanceId) &
                  row.serverSpaceId.equals(scope.serverSpaceId) &
                  row.vaultId.equals(scope.vaultId) &
                  row.serverGeneration.equals(scope.serverGeneration) &
                  row.snapshotId.equals(snapshotId) &
                  row.redactionJson.isNull(),
            ))
            .get();
    await _rejectSnapshotLiveHeadsWithRedactionProof(
      vaultId: scope.vaultId,
      liveRecordIds: stagedLiveRecords.map((row) => row.recordId).toSet(),
      instanceId: scope.instanceId,
      serverSpaceId: scope.serverSpaceId,
    );

    final stagedRedactions =
        await (select(syncSnapshotRecoveryItems)..where(
              (row) =>
                  row.serverNamespace.equals(scope.serverNamespace) &
                  row.accountId.equals(scope.accountId) &
                  row.instanceId.equals(scope.instanceId) &
                  row.serverSpaceId.equals(scope.serverSpaceId) &
                  row.vaultId.equals(scope.vaultId) &
                  row.serverGeneration.equals(scope.serverGeneration) &
                  row.snapshotId.equals(snapshotId) &
                  row.redactionJson.isNotNull(),
            ))
            .get();
    final redactedRecordIds = <String>{};
    for (final row in stagedRedactions) {
      final decoded = jsonDecode(row.redactionJson!);
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw const FormatException('Staged redaction proof is malformed.');
      }
      final proof = Map<String, dynamic>.from(decoded);
      redactedRecordIds.add(row.recordId);
      await _applyRecordRedactionInTransaction(
        instanceId: scope.instanceId,
        serverSpaceId: scope.serverSpaceId,
        vaultId: scope.vaultId,
        serverGeneration: scope.serverGeneration,
        proof: proof,
        preserveSnapshotId: snapshotId,
      );
    }

    final existingCacheRows = await (select(
      encryptedRecords,
    )..where((row) => row.vaultId.equals(scope.vaultId))).get();
    for (final row in existingCacheRows) {
      final sameRecordId = stagedLiveRecords.any(
        (staged) => staged.recordId == row.recordId,
      );
      if (!sameRecordId) continue;
      final sameScope = _scopeMatchesOrThrow(
        rowType: 'encrypted record',
        rowInstanceId: row.instanceId,
        rowServerSpaceId: row.serverSpaceId,
        instanceId: scope.instanceId,
        serverSpaceId: scope.serverSpaceId,
      );
      // A known different scope owns an independent row under the composite
      // cache key. Preserve it while replacing this scope's snapshot.
      if (!sameScope) continue;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final conflictIds = <String>[];

    await (delete(encryptedRecords)..where(
          (row) =>
              row.vaultId.equals(scope.vaultId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId),
        ))
        .go();
    await customStatement(
      'INSERT INTO encrypted_records '
      '(vault_id, record_id, instance_id, server_space_id, revision_id, envelope_json, is_deleted, commit_seq, updated_at) '
      'SELECT ?, record_id, ?, ?, revision_id, envelope_json, deleted, commit_seq, ? '
      'FROM sync_snapshot_recovery_items '
      'WHERE server_namespace = ? AND account_id = ? AND instance_id = ? '
      'AND server_space_id = ? AND vault_id = ? AND server_generation = ? '
      'AND snapshot_id = ? AND redaction_json IS NULL ORDER BY ordinal',
      [
        scope.vaultId,
        scope.instanceId,
        scope.serverSpaceId,
        now,
        scope.serverNamespace,
        scope.accountId,
        scope.instanceId,
        scope.serverSpaceId,
        scope.vaultId,
        scope.serverGeneration,
        snapshotId,
      ],
    );

    final pending = await allPendingOperations(
      scope.vaultId,
      instanceId: scope.instanceId,
      serverSpaceId: scope.serverSpaceId,
    );
    final pendingBefore = {
      for (final item in pending)
        item.opId: (item.envelopeJson, item.baseRevisionId, item.recordId),
    };

    final operationsByRecord = <String, List<PendingOperation>>{};
    for (final operation in pending) {
      operationsByRecord
          .putIfAbsent(operation.recordId, () => <PendingOperation>[])
          .add(operation);
    }
    for (final entry in operationsByRecord.entries) {
      final operations = entry.value;
      final active = operations
          .where(
            (operation) =>
                operation.status == 'queued' ||
                operation.status == 'sent' ||
                operation.status == 'cas_wait',
          )
          .toList(growable: false);
      if (active.isEmpty) continue;
      if (redactedRecordIds.contains(entry.key)) continue;

      final remote =
          await (select(syncSnapshotRecoveryItems)..where(
                (row) =>
                    row.serverNamespace.equals(scope.serverNamespace) &
                    row.accountId.equals(scope.accountId) &
                    row.instanceId.equals(scope.instanceId) &
                    row.serverSpaceId.equals(scope.serverSpaceId) &
                    row.vaultId.equals(scope.vaultId) &
                    row.serverGeneration.equals(scope.serverGeneration) &
                    row.snapshotId.equals(snapshotId) &
                    row.recordId.equals(entry.key),
              ))
              .getSingleOrNull();
      var committedThrough = -1;
      var reusedIdentifierWithDifferentEnvelope = false;
      if (remote != null) {
        final remoteEnvelope =
            jsonDecode(remote.envelopeJson) as Map<String, dynamic>;
        final remoteHeader = Map<String, dynamic>.from(
          remoteEnvelope['header'] as Map,
        );
        for (var index = 0; index < active.length; index++) {
          final envelope =
              jsonDecode(active[index].envelopeJson) as Map<String, dynamic>;
          final header = Map<String, dynamic>.from(envelope['header'] as Map);
          if (header['op_id'] == remoteHeader['op_id'] &&
              header['revision_id'] == remote.revisionId) {
            if (canonicalJson(envelope) == canonicalJson(remoteEnvelope)) {
              committedThrough = index;
            } else {
              reusedIdentifierWithDifferentEnvelope = true;
            }
          }
        }
      }

      if (committedThrough >= 0) {
        for (final operation in active.take(committedThrough + 1)) {
          await (delete(
            pendingOperations,
          )..where((row) => row.opId.equals(operation.opId))).go();
        }
      }
      final remaining = committedThrough >= 0
          ? active.skip(committedThrough + 1).toList(growable: false)
          : active;
      if (remaining.isEmpty) continue;

      final first = remaining.first;
      final sameBase =
          !reusedIdentifierWithDifferentEnvelope &&
          first.baseRevisionId == remote?.revisionId;
      final latest = remaining.last;
      final latestEnvelope =
          jsonDecode(latest.envelopeJson) as Map<String, dynamic>;
      if (sameBase) {
        final latestHeader = Map<String, dynamic>.from(
          latestEnvelope['header'] as Map,
        );
        await into(encryptedRecords).insertOnConflictUpdate(
          EncryptedRecordsCompanion.insert(
            vaultId: scope.vaultId,
            recordId: latest.recordId,
            instanceId: Value(scope.instanceId),
            serverSpaceId: Value(scope.serverSpaceId),
            revisionId: latestHeader['revision_id'] as String,
            envelopeJson: latest.envelopeJson,
            isDeleted: Value(latestHeader['operation'] == 'delete'),
            commitSeq: const Value(null),
            updatedAt: now,
          ),
        );
        continue;
      }

      final localConflictId = _uuid.v4();
      final localHeader = Map<String, dynamic>.from(
        latestEnvelope['header'] as Map,
      );
      final remoteEnvelope = remote == null
          ? <String, dynamic>{}
          : jsonDecode(remote.envelopeJson) as Map<String, dynamic>;
      final remoteDeleted = remote?.deleted ?? false;
      final kind = reusedIdentifierWithDifferentEnvelope
          ? 'id_reuse'
          : localHeader['operation'] == 'delete' || remoteDeleted
          ? 'delete_edit'
          : remote == null
          ? 'remote_delete'
          : 'concurrent_edit';
      await into(conflictBranches).insert(
        ConflictBranchesCompanion.insert(
          conflictId: localConflictId,
          vaultId: scope.vaultId,
          recordId: latest.recordId,
          instanceId: Value(scope.instanceId),
          serverSpaceId: Value(scope.serverSpaceId),
          kind: kind,
          branchEnvelopeJson: latest.envelopeJson,
          remoteEnvelopeJson: jsonEncode(remoteEnvelope),
          state: const Value('upload_pending'),
          createdAt: now,
        ),
      );
      conflictIds.add(localConflictId);
      for (final operation in remaining) {
        await (update(pendingOperations)
              ..where((row) => row.opId.equals(operation.opId)))
            .write(const PendingOperationsCompanion(status: Value('conflict')));
      }
    }

    final pendingAfter = await allPendingOperations(
      scope.vaultId,
      instanceId: scope.instanceId,
      serverSpaceId: scope.serverSpaceId,
    );
    for (final item in pendingAfter) {
      final previous = pendingBefore[item.opId];
      if (previous == null ||
          previous.$1 != item.envelopeJson ||
          previous.$2 != item.baseRevisionId ||
          previous.$3 != item.recordId) {
        throw StateError('Outbox changed while applying a snapshot.');
      }
    }

    await into(syncCheckpoints).insertOnConflictUpdate(
      SyncCheckpointsCompanion.insert(
        vaultId: scope.vaultId,
        instanceId: Value(scope.instanceId),
        serverSpaceId: Value(scope.serverSpaceId),
        cursor: Value(stage.checkpointCursor),
        serverGeneration: Value(scope.serverGeneration),
        syncStatus: const Value('idle'),
        lastSuccessAt: Value(now),
      ),
    );
    await (delete(syncSnapshotRecoveryItems)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryCursors)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
    await (delete(syncSnapshotRecoveryStages)..where(
          (row) =>
              row.serverNamespace.equals(scope.serverNamespace) &
              row.accountId.equals(scope.accountId) &
              row.instanceId.equals(scope.instanceId) &
              row.serverSpaceId.equals(scope.serverSpaceId) &
              row.vaultId.equals(scope.vaultId) &
              row.serverGeneration.equals(scope.serverGeneration) &
              row.snapshotId.equals(snapshotId),
        ))
        .go();
    return SnapshotApplyResult(localConflictIds: conflictIds);
  });

  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      Future<bool> hasColumn(String table, String column) async {
        final rows = await customSelect('PRAGMA table_info($table)').get();
        return rows.any((row) => row.read<String>('name') == column);
      }

      if (from < 2) {
        await m.addColumn(conflictBranches, conflictBranches.resolutionOpId);
        await m.addColumn(
          conflictBranches,
          conflictBranches.resolutionRevisionId,
        );
      }
      if (from < 3) {
        await m.createTable(vaultArchiveObjects);
      }
      if (from < 4) {
        await m.createTable(blobJobs);
        await m.createTable(blobJobObjects);
      }
      if (from < 5) {
        await m.createTable(conflictFeedCheckpoints);
        await m.createTable(conflictFeedInbox);
        await m.createTable(conflictFeedStates);
        await m.createTable(feedConflictResolutions);
      } else if (from < 6) {
        // v5 stored one cursor per server generation. Copy those durable rows
        // into a named partition so a sequence-ahead recovery can begin a new
        // cursor without deleting or colliding with the old inbox.
        await customStatement(
          'CREATE TABLE conflict_feed_checkpoints_v6 ('
          'vault_id TEXT NOT NULL, server_generation TEXT NOT NULL, '
          'partition_id TEXT NOT NULL, after_seq TEXT NOT NULL, '
          'PRIMARY KEY (vault_id, server_generation, partition_id))',
        );
        await customStatement(
          "INSERT INTO conflict_feed_checkpoints_v6 "
          "(vault_id, server_generation, partition_id, after_seq) "
          "SELECT vault_id, server_generation, 'legacy-' || server_generation, after_seq "
          'FROM conflict_feed_checkpoints',
        );
        await customStatement('DROP TABLE conflict_feed_checkpoints');
        await customStatement(
          'ALTER TABLE conflict_feed_checkpoints_v6 '
          'RENAME TO conflict_feed_checkpoints',
        );
        await customStatement(
          'CREATE TABLE conflict_feed_inbox_v6 ('
          'vault_id TEXT NOT NULL, server_generation TEXT NOT NULL, '
          'partition_id TEXT NOT NULL, seq TEXT NOT NULL, conflict_id TEXT NOT NULL, '
          'event_type TEXT NOT NULL, event_json TEXT NOT NULL, '
          'PRIMARY KEY (vault_id, server_generation, partition_id, seq))',
        );
        await customStatement(
          "INSERT INTO conflict_feed_inbox_v6 "
          "(vault_id, server_generation, partition_id, seq, conflict_id, event_type, event_json) "
          "SELECT vault_id, server_generation, 'legacy-' || server_generation, seq, conflict_id, event_type, event_json "
          'FROM conflict_feed_inbox',
        );
        await customStatement('DROP TABLE conflict_feed_inbox');
        await customStatement(
          'ALTER TABLE conflict_feed_inbox_v6 RENAME TO conflict_feed_inbox',
        );
        await customStatement(
          "ALTER TABLE conflict_feed_states ADD COLUMN partition_id TEXT NOT NULL DEFAULT ''",
        );
        await customStatement(
          "UPDATE conflict_feed_states SET partition_id='legacy-' || server_generation",
        );
        await m.createTable(feedConflictResolutions);
      }
      if (from < 7) {
        // Drift emits CREATE TABLE IF NOT EXISTS here, so a retry after a
        // partially completed upgrade safely preserves an existing table.
        await m.createTable(terminalHistoryEntries);
      }
      if (from < 8) {
        await m.createTable(syncSnapshotRecoveryStages);
        await m.createTable(syncSnapshotRecoveryItems);
        await m.createTable(syncSnapshotRecoveryCursors);
      }
      if (from < 9) {
        await m.createTable(authenticatedPushReceipts);
      }
      if (from >= 9 && from < 10) {
        await m.addColumn(
          authenticatedPushReceipts,
          authenticatedPushReceipts.createdAt,
        );
      }
      if (from < 10) {
        // Existing proofs receive a fresh retention window. A v8 upgrade may
        // have created the current table definition above, so this update is
        // intentionally shared by both upgrade paths.
        await customStatement(
          'UPDATE authenticated_push_receipts SET created_at = ?',
          [DateTime.now().millisecondsSinceEpoch],
        );
      }
      if (from >= 8 && from < 11) {
        if (!await hasColumn(
          'sync_snapshot_recovery_items',
          'redaction_json',
        )) {
          await m.addColumn(
            syncSnapshotRecoveryItems,
            syncSnapshotRecoveryItems.redactionJson,
          );
        }
      }
      if (from < 11) {
        if (!await hasColumn('conflict_branches', 'redaction_proof_json')) {
          await m.addColumn(
            conflictBranches,
            conflictBranches.redactionProofJson,
          );
        }
        await m.createTable(syncRedactions);
      }
      if (from == 11 && from < 12) {
        await customStatement(
          'CREATE TABLE sync_redactions_v12 ('
          'instance_id TEXT NOT NULL, server_space_id TEXT NOT NULL, '
          'vault_id TEXT NOT NULL, record_id TEXT NOT NULL, '
          'redaction_id TEXT NOT NULL, deleted_revision_id TEXT NOT NULL, '
          'deleted_seq TEXT NOT NULL, redaction_seq TEXT NOT NULL, '
          'proof_json TEXT NOT NULL, server_generation TEXT NOT NULL, '
          'applied_at INTEGER NOT NULL, '
          'PRIMARY KEY (instance_id, server_space_id, vault_id, record_id))',
        );
        await customStatement(
          'INSERT INTO sync_redactions_v12 '
          '(instance_id, server_space_id, vault_id, record_id, redaction_id, '
          'deleted_revision_id, deleted_seq, redaction_seq, proof_json, '
          'server_generation, applied_at) '
          'SELECT instance_id, server_space_id, vault_id, record_id, redaction_id, '
          'deleted_revision_id, deleted_seq, redaction_seq, proof_json, \'\', applied_at '
          'FROM sync_redactions',
        );
        await customStatement('DROP TABLE sync_redactions');
        await customStatement(
          'ALTER TABLE sync_redactions_v12 RENAME TO sync_redactions',
        );
      }
      if (from < 13) {
        // Payload rows predate the instance-scoped redaction ledger. Keep
        // their provenance nullable: a null legacy row is ambiguous and must
        // make a matching redaction transaction fail closed rather than
        // guessing which server's bytes it belongs to.
        Future<void> addScopeColumn(
          String table,
          String column,
          Future<void> Function() add,
        ) async {
          if (!await hasColumn(table, column)) await add();
        }

        // A Vault ID may be reused against independent server instances. Keep
        // each main-feed cursor isolated; legacy cursor rows move to an
        // unscoped sentinel and are never advanced by an authenticated scope.
        await customStatement(
          'CREATE TABLE sync_checkpoints_v13 ('
          'vault_id TEXT NOT NULL, instance_id TEXT NOT NULL DEFAULT \'\', '
          'server_space_id TEXT NOT NULL DEFAULT \'\', cursor TEXT NULL, '
          'server_generation TEXT NULL, sync_status TEXT NOT NULL DEFAULT \'idle\', '
          'last_success_at INTEGER NULL, '
          'PRIMARY KEY (vault_id, instance_id, server_space_id))',
        );
        if (await hasColumn('sync_checkpoints', 'instance_id') &&
            await hasColumn('sync_checkpoints', 'server_space_id')) {
          await customStatement(
            'INSERT INTO sync_checkpoints_v13 '
            '(vault_id, instance_id, server_space_id, cursor, server_generation, sync_status, last_success_at) '
            'SELECT vault_id, instance_id, server_space_id, cursor, server_generation, sync_status, last_success_at '
            'FROM sync_checkpoints',
          );
        } else {
          await customStatement(
            'INSERT INTO sync_checkpoints_v13 '
            '(vault_id, instance_id, server_space_id, cursor, server_generation, sync_status, last_success_at) '
            'SELECT vault_id, \'\', \'\', cursor, server_generation, sync_status, last_success_at '
            'FROM sync_checkpoints',
          );
        }
        await customStatement('DROP TABLE sync_checkpoints');
        await customStatement(
          'ALTER TABLE sync_checkpoints_v13 RENAME TO sync_checkpoints',
        );

        final feedCheckpointScoped =
            await hasColumn('conflict_feed_checkpoints', 'instance_id') &&
            await hasColumn('conflict_feed_checkpoints', 'server_space_id');
        await customStatement(
          'CREATE TABLE conflict_feed_checkpoints_v13 ('
          'vault_id TEXT NOT NULL, instance_id TEXT NOT NULL DEFAULT \'\', '
          'server_space_id TEXT NOT NULL DEFAULT \'\', '
          'server_generation TEXT NOT NULL, partition_id TEXT NOT NULL, '
          'after_seq TEXT NOT NULL, '
          'PRIMARY KEY (vault_id, instance_id, server_space_id, server_generation, partition_id))',
        );
        await customStatement(
          feedCheckpointScoped
              ? 'INSERT INTO conflict_feed_checkpoints_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id, after_seq) '
                    'SELECT vault_id, COALESCE(instance_id, \'\'), COALESCE(server_space_id, \'\'), server_generation, partition_id, after_seq '
                    'FROM conflict_feed_checkpoints'
              : 'INSERT INTO conflict_feed_checkpoints_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id, after_seq) '
                    'SELECT vault_id, \'\', \'\', server_generation, partition_id, after_seq '
                    'FROM conflict_feed_checkpoints',
        );
        await customStatement('DROP TABLE conflict_feed_checkpoints');
        await customStatement(
          'ALTER TABLE conflict_feed_checkpoints_v13 RENAME TO conflict_feed_checkpoints',
        );

        final feedStateScoped =
            await hasColumn('conflict_feed_states', 'instance_id') &&
            await hasColumn('conflict_feed_states', 'server_space_id');
        await customStatement(
          'CREATE TABLE conflict_feed_states_v13 ('
          'vault_id TEXT NOT NULL, instance_id TEXT NOT NULL DEFAULT \'\', '
          'server_space_id TEXT NOT NULL DEFAULT \'\', '
          'server_generation TEXT NOT NULL, partition_id TEXT NOT NULL, '
          'PRIMARY KEY (vault_id, instance_id, server_space_id))',
        );
        await customStatement(
          feedStateScoped
              ? 'INSERT INTO conflict_feed_states_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id) '
                    'SELECT vault_id, COALESCE(instance_id, \'\'), COALESCE(server_space_id, \'\'), server_generation, partition_id '
                    'FROM conflict_feed_states'
              : 'INSERT INTO conflict_feed_states_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id) '
                    'SELECT vault_id, \'\', \'\', server_generation, partition_id '
                    'FROM conflict_feed_states',
        );
        await customStatement('DROP TABLE conflict_feed_states');
        await customStatement(
          'ALTER TABLE conflict_feed_states_v13 RENAME TO conflict_feed_states',
        );

        final feedInboxScoped =
            await hasColumn('conflict_feed_inbox', 'instance_id') &&
            await hasColumn('conflict_feed_inbox', 'server_space_id');
        await customStatement(
          'CREATE TABLE conflict_feed_inbox_v13 ('
          'vault_id TEXT NOT NULL, instance_id TEXT NOT NULL DEFAULT \'\', '
          'server_space_id TEXT NOT NULL DEFAULT \'\', '
          'server_generation TEXT NOT NULL, partition_id TEXT NOT NULL, '
          'seq TEXT NOT NULL, conflict_id TEXT NOT NULL, event_type TEXT NOT NULL, '
          'event_json TEXT NOT NULL, '
          'PRIMARY KEY (vault_id, instance_id, server_space_id, server_generation, partition_id, seq))',
        );
        await customStatement(
          feedInboxScoped
              ? 'INSERT INTO conflict_feed_inbox_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id, seq, conflict_id, event_type, event_json) '
                    'SELECT vault_id, COALESCE(instance_id, \'\'), COALESCE(server_space_id, \'\'), server_generation, partition_id, seq, conflict_id, event_type, event_json '
                    'FROM conflict_feed_inbox'
              : 'INSERT INTO conflict_feed_inbox_v13 '
                    '(vault_id, instance_id, server_space_id, server_generation, partition_id, seq, conflict_id, event_type, event_json) '
                    'SELECT vault_id, \'\', \'\', server_generation, partition_id, seq, conflict_id, event_type, event_json '
                    'FROM conflict_feed_inbox',
        );
        await customStatement('DROP TABLE conflict_feed_inbox');
        await customStatement(
          'ALTER TABLE conflict_feed_inbox_v13 RENAME TO conflict_feed_inbox',
        );

        await addScopeColumn(
          'encrypted_records',
          'instance_id',
          () => m.addColumn(encryptedRecords, encryptedRecords.instanceId),
        );
        await addScopeColumn(
          'encrypted_records',
          'server_space_id',
          () => m.addColumn(encryptedRecords, encryptedRecords.serverSpaceId),
        );
        // Cache heads from independent server instances can share a Vault and
        // record UUID. Keep legacy null-provenance rows as their own entries;
        // a later proof must fail closed when it cannot establish ownership.
        await customStatement(
          'CREATE TABLE encrypted_records_v13 ('
          'vault_id TEXT NOT NULL, record_id TEXT NOT NULL, '
          'instance_id TEXT NULL, server_space_id TEXT NULL, '
          'revision_id TEXT NOT NULL, envelope_json TEXT NOT NULL, '
          'is_deleted INTEGER NOT NULL DEFAULT 0, commit_seq TEXT NULL, '
          'updated_at INTEGER NOT NULL, '
          'PRIMARY KEY (vault_id, record_id, instance_id, server_space_id))',
        );
        await customStatement(
          'INSERT INTO encrypted_records_v13 '
          '(vault_id, record_id, instance_id, server_space_id, revision_id, envelope_json, is_deleted, commit_seq, updated_at) '
          'SELECT vault_id, record_id, instance_id, server_space_id, revision_id, envelope_json, is_deleted, commit_seq, updated_at '
          'FROM encrypted_records',
        );
        await customStatement('DROP TABLE encrypted_records');
        await customStatement(
          'ALTER TABLE encrypted_records_v13 RENAME TO encrypted_records',
        );
        await addScopeColumn(
          'pending_operations',
          'instance_id',
          () => m.addColumn(pendingOperations, pendingOperations.instanceId),
        );
        await addScopeColumn(
          'pending_operations',
          'server_space_id',
          () => m.addColumn(pendingOperations, pendingOperations.serverSpaceId),
        );
        await addScopeColumn(
          'authenticated_push_receipts',
          'instance_id',
          () => m.addColumn(
            authenticatedPushReceipts,
            authenticatedPushReceipts.instanceId,
          ),
        );
        await addScopeColumn(
          'authenticated_push_receipts',
          'server_space_id',
          () => m.addColumn(
            authenticatedPushReceipts,
            authenticatedPushReceipts.serverSpaceId,
          ),
        );
        await addScopeColumn(
          'conflict_branches',
          'instance_id',
          () => m.addColumn(conflictBranches, conflictBranches.instanceId),
        );
        await addScopeColumn(
          'conflict_branches',
          'server_space_id',
          () => m.addColumn(conflictBranches, conflictBranches.serverSpaceId),
        );
        await addScopeColumn(
          'feed_conflict_resolutions',
          'instance_id',
          () => m.addColumn(
            feedConflictResolutions,
            feedConflictResolutions.instanceId,
          ),
        );
        await addScopeColumn(
          'feed_conflict_resolutions',
          'server_space_id',
          () => m.addColumn(
            feedConflictResolutions,
            feedConflictResolutions.serverSpaceId,
          ),
        );
        await addScopeColumn(
          'blob_jobs',
          'instance_id',
          () => m.addColumn(blobJobs, blobJobs.instanceId),
        );
        await addScopeColumn(
          'blob_jobs',
          'server_space_id',
          () => m.addColumn(blobJobs, blobJobs.serverSpaceId),
        );
      }
      if (from < 14) {
        await m.createTable(lockedSyncCheckpoints);
        await m.createTable(lockedSyncInboxPages);
      }
    },
  );

  /// Stores opaque ciphertext in a device-local history namespace. The row ID
  /// is generated randomly here so callers cannot choose or reuse one.
  Future<String> insertTerminalHistoryCiphertext({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
    required Uint8List ciphertext,
    int? createdAt,
  }) async {
    _validateTerminalHistoryNamespace(serverNamespace, accountId, deviceId);
    final now = createdAt ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final entryId = _uuid.v4();
    await into(terminalHistoryEntries).insert(
      TerminalHistoryEntriesCompanion.insert(
        serverNamespace: serverNamespace,
        accountId: accountId,
        deviceId: deviceId,
        entryId: entryId,
        ciphertext: Uint8List.fromList(ciphertext),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return entryId;
  }

  /// Lists only the selected server/account/device partition. Payloads are
  /// returned as bytes and never decoded or inspected by this storage layer.
  Future<List<TerminalHistoryCiphertextEntry>>
  terminalHistoryCiphertextEntries({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
  }) async {
    _validateTerminalHistoryNamespace(serverNamespace, accountId, deviceId);
    final rows =
        await (select(terminalHistoryEntries)
              ..where(
                (row) =>
                    row.serverNamespace.equals(serverNamespace) &
                    row.accountId.equals(accountId) &
                    row.deviceId.equals(deviceId),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.createdAt),
                (row) => OrderingTerm.desc(row.entryId),
              ]))
            .get();
    return rows
        .map(
          (row) => TerminalHistoryCiphertextEntry(
            entryId: row.entryId,
            ciphertext: Uint8List.fromList(row.ciphertext),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
          ),
        )
        .toList(growable: false);
  }

  /// Deletes one row from the selected namespace and reports whether it existed.
  Future<bool> deleteTerminalHistoryCiphertext({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
    required String entryId,
  }) async {
    _validateTerminalHistoryNamespace(serverNamespace, accountId, deviceId);
    final deleted =
        await (delete(terminalHistoryEntries)..where(
              (row) =>
                  row.serverNamespace.equals(serverNamespace) &
                  row.accountId.equals(accountId) &
                  row.deviceId.equals(deviceId) &
                  row.entryId.equals(entryId),
            ))
            .go();
    return deleted == 1;
  }

  /// Keeps the most recent [maxEntries] rows in one exact namespace and
  /// removes older excess rows. A zero cap clears that namespace.
  Future<int> pruneTerminalHistoryCiphertext({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
    required int maxEntries,
  }) async {
    _validateTerminalHistoryNamespace(serverNamespace, accountId, deviceId);
    if (maxEntries < 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }

    return transaction(() async {
      final overflow = selectOnly(terminalHistoryEntries)
        ..addColumns([terminalHistoryEntries.entryId])
        ..where(
          terminalHistoryEntries.serverNamespace.equals(serverNamespace) &
              terminalHistoryEntries.accountId.equals(accountId) &
              terminalHistoryEntries.deviceId.equals(deviceId),
        )
        ..orderBy([
          OrderingTerm.desc(terminalHistoryEntries.createdAt),
          OrderingTerm.desc(terminalHistoryEntries.entryId),
        ]);
      if (maxEntries > 0) {
        overflow.limit(maxEntries, offset: maxEntries);
      }
      final overflowIds = (await overflow.get())
          .map((row) => row.read<String>(terminalHistoryEntries.entryId)!)
          .toList(growable: false);
      if (overflowIds.isEmpty) return 0;

      return (delete(terminalHistoryEntries)..where(
            (row) =>
                row.serverNamespace.equals(serverNamespace) &
                row.accountId.equals(accountId) &
                row.deviceId.equals(deviceId) &
                row.entryId.isIn(overflowIds),
          ))
          .go();
    });
  }

  /// Clears every entry in one exact server/account/device namespace.
  Future<int> clearTerminalHistoryCiphertext({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
  }) async {
    _validateTerminalHistoryNamespace(serverNamespace, accountId, deviceId);
    return (delete(terminalHistoryEntries)..where(
          (row) =>
              row.serverNamespace.equals(serverNamespace) &
              row.accountId.equals(accountId) &
              row.deviceId.equals(deviceId),
        ))
        .go();
  }

  void _validateTerminalHistoryNamespace(
    String serverNamespace,
    String accountId,
    String deviceId,
  ) {
    if (serverNamespace.isEmpty || accountId.isEmpty || deviceId.isEmpty) {
      throw ArgumentError(
        'Terminal history namespace fields must not be empty.',
      );
    }
  }

  Future<void> beginBlobJob({
    required String jobId,
    required String vaultId,
    required String recordId,
    required String blobId,
    required String direction,
    required String state,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (!const {'upload', 'download'}.contains(direction)) {
      throw ArgumentError.value(direction, 'direction');
    }
    final existing = await (select(
      blobJobs,
    )..where((row) => row.jobId.equals(jobId))).getSingleOrNull();
    if (existing != null) {
      if (existing.vaultId != vaultId ||
          existing.recordId != recordId ||
          existing.blobId != blobId ||
          existing.direction != direction ||
          (instanceId != null &&
              (existing.instanceId != instanceId ||
                  existing.serverSpaceId != serverSpaceId))) {
        throw StateError(
          'Attachment transfer job ID conflicts with another task.',
        );
      }
      await (update(blobJobs)..where((row) => row.jobId.equals(jobId))).write(
        BlobJobsCompanion(
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          state: Value(state),
          lastErrorCode: const Value(null),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await into(blobJobs).insert(
      BlobJobsCompanion.insert(
        jobId: jobId,
        vaultId: vaultId,
        recordId: recordId,
        instanceId: Value(instanceId),
        serverSpaceId: Value(serverSpaceId),
        blobId: blobId,
        direction: direction,
        state: state,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> stageBlobUploadObject({
    required String jobId,
    required String objectId,
    required String sha256,
    required Uint8List bytes,
  }) async {
    final existing =
        await (select(blobJobObjects)..where(
              (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
            ))
            .getSingleOrNull();
    if (existing != null) {
      if (existing.sha256 != sha256 ||
          existing.size != bytes.length ||
          existing.bytes == null ||
          !_sameBytes(existing.bytes!, bytes)) {
        throw StateError('Attachment transfer object changed during retry.');
      }
      return;
    }
    await into(blobJobObjects).insert(
      BlobJobObjectsCompanion.insert(
        jobId: jobId,
        objectId: objectId,
        sha256: sha256,
        size: bytes.length,
        bytes: Value(Uint8List.fromList(bytes)),
      ),
    );
  }

  Future<void> prepareBlobDownloadObjects({
    required String jobId,
    required List<({String objectId, String sha256, int size})> objects,
  }) async {
    await transaction(() async {
      for (final object in objects) {
        final existing =
            await (select(blobJobObjects)..where(
                  (row) =>
                      row.jobId.equals(jobId) &
                      row.objectId.equals(object.objectId),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.sha256 != object.sha256 ||
              existing.size != object.size) {
            throw StateError(
              'Attachment download metadata changed for an object.',
            );
          }
          continue;
        }
        await into(blobJobObjects).insert(
          BlobJobObjectsCompanion.insert(
            jobId: jobId,
            objectId: object.objectId,
            sha256: object.sha256,
            size: object.size,
            bytes: const Value(null),
          ),
        );
      }
      await (update(blobJobs)..where((row) => row.jobId.equals(jobId))).write(
        BlobJobsCompanion(
          totalObjects: Value(objects.length),
          state: const Value('downloading'),
          lastErrorCode: const Value(null),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
    });
  }

  Future<BlobJob?> blobJob(String jobId) => (select(
    blobJobs,
  )..where((row) => row.jobId.equals(jobId))).getSingleOrNull();

  Future<List<BlobJob>> blobJobsForRecord(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(blobJobs)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    if (instanceId == null) return rows;
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'attachment job',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  Future<List<BlobJobObject>> blobJobObjectRows(String jobId) =>
      (select(blobJobObjects)..where((row) => row.jobId.equals(jobId))).get();

  /// Reads durable transfer metadata without selecting ciphertext BLOBs.
  Future<List<BlobJobObjectProgress>> blobJobObjectProgressRows(
    String jobId,
  ) async {
    final rows = await customSelect(
      'SELECT object_id,sha256,size,COALESCE(length(bytes),0) AS staged_bytes,'
      'upload_id,upload_chunk_size,next_chunk_index,transferred '
      'FROM blob_job_objects WHERE job_id=? ORDER BY object_id',
      variables: [Variable.withString(jobId)],
      readsFrom: {blobJobObjects},
    ).get();
    return rows
        .map(
          (row) => BlobJobObjectProgress(
            objectId: row.read<String>('object_id'),
            sha256: row.read<String>('sha256'),
            size: row.read<int>('size'),
            stagedBytes: row.read<int>('staged_bytes'),
            uploadId: row.read<String?>('upload_id'),
            uploadChunkSize: row.read<int?>('upload_chunk_size'),
            nextChunkIndex: row.read<int>('next_chunk_index'),
            transferred: row.read<int>('transferred') != 0,
          ),
        )
        .toList(growable: false);
  }

  Future<BlobJobObject?> blobJobObject(String jobId, String objectId) =>
      (select(blobJobObjects)..where(
            (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
          ))
          .getSingleOrNull();

  Future<void> updateBlobJobState(
    String jobId,
    String state, {
    String? errorCode,
  }) async {
    final current = await blobJob(jobId);
    if (current == null) return;
    await (update(blobJobs)..where((row) => row.jobId.equals(jobId))).write(
      BlobJobsCompanion(
        state: Value(state),
        attemptCount: Value(current.attemptCount + (state == 'failed' ? 1 : 0)),
        lastErrorCode: Value(errorCode),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> updateBlobUploadProgress({
    required String jobId,
    required String objectId,
    required String? uploadId,
    required int? chunkSize,
    required int nextChunkIndex,
  }) async {
    await (update(blobJobObjects)..where(
          (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
        ))
        .write(
          BlobJobObjectsCompanion(
            uploadId: Value(uploadId),
            uploadChunkSize: Value(chunkSize),
            nextChunkIndex: Value(nextChunkIndex),
          ),
        );
  }

  Future<void> appendBlobDownloadRange({
    required String jobId,
    required String objectId,
    required int start,
    required Uint8List bytes,
  }) async {
    await transaction(() async {
      final row =
          await (select(blobJobObjects)..where(
                (item) =>
                    item.jobId.equals(jobId) & item.objectId.equals(objectId),
              ))
              .getSingleOrNull();
      if (row == null || row.transferred) {
        throw StateError(
          'Attachment download range has no active object task.',
        );
      }
      final current = row.bytes ?? Uint8List(0);
      if (start < current.length) {
        final end = start + bytes.length;
        if (end > current.length ||
            !_sameBytes(current.sublist(start, end), bytes)) {
          throw StateError(
            'Attachment download retry changed an existing range.',
          );
        }
        return;
      }
      if (start != current.length || start + bytes.length > row.size) {
        throw StateError('Attachment download ranges are not contiguous.');
      }
      final appended = Uint8List(current.length + bytes.length)
        ..setRange(0, current.length, current)
        ..setRange(current.length, current.length + bytes.length, bytes);
      try {
        await (update(blobJobObjects)..where(
              (item) =>
                  item.jobId.equals(jobId) & item.objectId.equals(objectId),
            ))
            .write(BlobJobObjectsCompanion(bytes: Value(appended)));
      } finally {
        appended.fillRange(0, appended.length, 0);
        if (current.isNotEmpty) current.fillRange(0, current.length, 0);
      }
    });
  }

  Future<void> markBlobObjectTransferred(String jobId, String objectId) async {
    await (update(blobJobObjects)..where(
          (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
        ))
        .write(const BlobJobObjectsCompanion(transferred: Value(true)));
  }

  Future<void> resetBlobDownloadObject(String jobId, String objectId) async {
    await (update(blobJobObjects)..where(
          (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
        ))
        .write(
          const BlobJobObjectsCompanion(
            bytes: Value(null),
            transferred: Value(false),
          ),
        );
  }

  Future<void> markBlobUploadObjectTransferred(
    String jobId,
    String objectId,
  ) async {
    await (update(blobJobObjects)..where(
          (row) => row.jobId.equals(jobId) & row.objectId.equals(objectId),
        ))
        .write(
          const BlobJobObjectsCompanion(
            bytes: Value(null),
            uploadId: Value(null),
            uploadChunkSize: Value(null),
            nextChunkIndex: Value(0),
            transferred: Value(true),
          ),
        );
  }

  Future<void> updateBlobJobObjectCount(String jobId, int count) async {
    await (update(blobJobs)..where((row) => row.jobId.equals(jobId))).write(
      BlobJobsCompanion(
        totalObjects: Value(count),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> deleteBlobJob(String jobId) async {
    await transaction(() async {
      await (delete(
        blobJobObjects,
      )..where((row) => row.jobId.equals(jobId))).go();
      await (delete(blobJobs)..where((row) => row.jobId.equals(jobId))).go();
    });
  }

  Future<List<PendingOperation>> pushableOperations(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final rows = await queuedOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (rows.isEmpty) return rows;
    var jobs =
        await (select(blobJobs)..where(
              (job) =>
                  job.vaultId.equals(vaultId) &
                  job.direction.equals('upload') &
                  job.state.isNotIn(const ['complete']),
            ))
            .get();
    if (instanceId != null) {
      jobs = jobs
          .where(
            (job) => _scopeMatchesOrThrow(
              rowType: 'attachment job',
              rowInstanceId: job.instanceId,
              rowServerSpaceId: job.serverSpaceId,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId!,
            ),
          )
          .toList(growable: false);
    }
    final blockedRecords = jobs.map((job) => job.recordId).toSet();
    return rows
        .where(
          (operation) =>
              operation.status != 'cas_wait' &&
              !blockedRecords.contains(operation.recordId),
        )
        .toList(growable: false);
  }

  Future<void> putLocalOperation({
    required String vaultId,
    required String recordId,
    required String? baseRevisionId,
    required Map<String, Object?> envelope,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    bool cleanupAttachmentJobsOnDelete = false,
  }) async {
    final encoded = jsonEncode(envelope);
    final header = envelope['header']! as Map<String, dynamic>;
    final opId = header['op_id']! as String;
    final revisionId = header['revision_id']! as String;
    if (expectedVaultHeadRevisionIds != null &&
        expectedVaultHeadRevisionIds.entries.any(
          (entry) => entry.key.isEmpty || entry.value.isEmpty,
        )) {
      throw const FormatException(
        'Expected local record head snapshot is malformed.',
      );
    }
    if (cleanupAttachmentJobsOnDelete &&
        (!deleted ||
            header['record_id'] != recordId ||
            header['operation'] != 'delete')) {
      throw StateError(
        'Attachment jobs can only be retired with a persisted record tombstone.',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _validateOptionalSyncScope(instanceId, serverSpaceId);

    await transaction(() async {
      await _ensureRecordNotRedacted(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (expectedVaultHeadRevisionIds != null) {
        final scopeClause = instanceId == null
            ? ''
            : ' AND instance_id = ? AND server_space_id = ?';
        final variables = <Variable<Object>>[
          Variable.withString(vaultId),
          if (instanceId != null) Variable.withString(instanceId),
          if (serverSpaceId != null) Variable.withString(serverSpaceId),
        ];
        final currentRows = await customSelect(
          'SELECT record_id, revision_id FROM encrypted_records WHERE vault_id = ?$scopeClause',
          variables: variables,
          readsFrom: {encryptedRecords},
        ).get();
        final currentHeads = {
          for (final row in currentRows)
            row.read<String>('record_id'): row.read<String>('revision_id'),
        };
        for (final entry in expectedVaultHeadRevisionIds.entries) {
          if (currentHeads[entry.key] != entry.value) {
            throw LocalRecordHeadChangedException(entry.key);
          }
        }
        if (currentHeads.length != expectedVaultHeadRevisionIds.length) {
          String? addedRecordId;
          for (final id in currentHeads.keys) {
            if (!expectedVaultHeadRevisionIds.containsKey(id)) {
              addedRecordId = id;
              break;
            }
          }
          throw LocalRecordHeadChangedException(addedRecordId ?? recordId);
        }
      }

      // An operation that has never been sent may be compacted into the latest
      // user intent. Once sent, its bytes and id are immutable for retry safety.
      final replaceable = preserveOutboxChain
          ? null
          : await (select(pendingOperations)
                  ..where(
                    (row) =>
                        row.vaultId.equals(vaultId) &
                        row.recordId.equals(recordId) &
                        row.status.equals('queued') &
                        (instanceId == null
                            ? const Constant(true)
                            : row.instanceId.equals(instanceId)) &
                        (serverSpaceId == null
                            ? const Constant(true)
                            : row.serverSpaceId.equals(serverSpaceId)),
                  )
                  ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
                  ..limit(1))
                .getSingleOrNull();
      final existingRecord = (await _encryptedRecordsForScope(
        vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      if (expectedCachedHeadRevisionId != null &&
          existingRecord?.revisionId != expectedCachedHeadRevisionId) {
        throw LocalRecordHeadChangedException(recordId);
      }
      _checkRecordScopeCollision(
        existingRecord,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final baseEnvelopeJson = replaceable != null
          ? replaceable.baseEnvelopeJson
          : existingRecord?.revisionId == baseRevisionId
          ? existingRecord?.envelopeJson
          : null;
      final storedBaseRevisionId = replaceable != null
          ? replaceable.baseRevisionId
          : baseRevisionId;
      if (replaceable != null) {
        await (delete(
          pendingOperations,
        )..where((row) => row.opId.equals(replaceable.opId))).go();
      }

      await into(encryptedRecords).insertOnConflictUpdate(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: revisionId,
          envelopeJson: encoded,
          isDeleted: Value(deleted),
          // This is a new local revision, so a previously committed head's
          // sequence no longer describes the visible optimistic cache row.
          commitSeq: const Value(null),
          updatedAt: now,
        ),
      );
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: opId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: Value(storedBaseRevisionId),
          baseEnvelopeJson: Value(baseEnvelopeJson),
          envelopeJson: encoded,
          createdAt: now,
        ),
      );
      await into(syncCheckpoints).insertOnConflictUpdate(
        SyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          syncStatus: const Value('pending'),
        ),
      );
      if (cleanupAttachmentJobsOnDelete) {
        await _cleanupAttachmentJobsAfterTombstone(
          vaultId,
          recordId,
          opId,
          instanceId,
          serverSpaceId,
        );
      }
    });
    await flushCommittedWrites();
  }

  /// Stores an already signed server envelope without applying the ordinary
  /// local-edit queued-row compaction rules. This is intended for migration
  /// staging: the caller supplies the complete target Vault envelope, and the
  /// database persists its bytes as an immutable create operation.
  ///
  /// Repeating the same envelope is idempotent. A matching active outbox row
  /// returns [ExactCreateOperationResult.pending]; a matching committed cache
  /// head returns [ExactCreateOperationResult.committed]. Any partial or
  /// conflicting local state fails closed.
  Future<ExactCreateOperationResult> putExactCreateOperation({
    required String vaultId,
    required String deviceId,
    required Map<String, Object?> envelope,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final exact = _validateExactCreateEnvelope(
      vaultId: vaultId,
      deviceId: deviceId,
      envelope: envelope,
    );
    final encoded = canonicalJson(envelope);
    final now = DateTime.now().millisecondsSinceEpoch;

    return transaction(() async {
      await _ensureRecordNotRedacted(
        vaultId,
        exact.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final operation = await (select(
        pendingOperations,
      )..where((row) => row.opId.equals(exact.opId))).getSingleOrNull();
      final record = (await _encryptedRecordsForScope(
        vaultId,
        recordId: exact.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      final allRecordOperations =
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(exact.recordId),
              ))
              .get();
      final recordOperations = instanceId == null
          ? allRecordOperations
          : allRecordOperations
                .where(
                  (row) => _scopeMatchesOrThrow(
                    rowType: 'pending operation',
                    rowInstanceId: row.instanceId,
                    rowServerSpaceId: row.serverSpaceId,
                    instanceId: instanceId,
                    serverSpaceId: serverSpaceId!,
                  ),
                )
                .toList(growable: false);
      _checkRecordScopeCollision(
        record,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (operation != null &&
          instanceId != null &&
          (operation.instanceId != instanceId ||
              operation.serverSpaceId != serverSpaceId)) {
        throw StateError(
          'Exact create operation is stored under another server scope.',
        );
      }

      if (operation != null) {
        if (operation.vaultId != vaultId ||
            operation.recordId != exact.recordId ||
            operation.baseRevisionId != null ||
            operation.baseEnvelopeJson != null ||
            !_hasCanonicalJson(operation.envelopeJson, encoded) ||
            record == null ||
            record.revisionId != exact.revisionId ||
            !_hasCanonicalJson(record.envelopeJson, encoded) ||
            record.isDeleted ||
            record.commitSeq != null ||
            recordOperations.length != 1 ||
            recordOperations.single.opId != exact.opId) {
          throw StateError(
            'Exact create operation collides with different local state.',
          );
        }
        await _advanceExactCreateSequence(deviceId, exact.nextSequence);
        return ExactCreateOperationResult.pending;
      }

      if (record != null) {
        if (record.vaultId != vaultId ||
            record.revisionId != exact.revisionId ||
            !_hasCanonicalJson(record.envelopeJson, encoded) ||
            record.isDeleted ||
            record.commitSeq == null ||
            recordOperations.isNotEmpty ||
            !_isCanonicalSignedCounter(record.commitSeq!, allowZero: false)) {
          throw StateError(
            'Exact create record collides with a different local head.',
          );
        }
        await _advanceExactCreateSequence(deviceId, exact.nextSequence);
        return ExactCreateOperationResult.committed;
      }

      if (recordOperations.isNotEmpty) {
        throw StateError(
          'Exact create record already has another pending operation.',
        );
      }

      await into(encryptedRecords).insert(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: exact.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: exact.revisionId,
          envelopeJson: encoded,
          isDeleted: const Value(false),
          commitSeq: const Value(null),
          updatedAt: now,
        ),
      );
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: exact.opId,
          vaultId: vaultId,
          recordId: exact.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: const Value(null),
          baseEnvelopeJson: const Value(null),
          envelopeJson: encoded,
          createdAt: now,
        ),
      );
      await _advanceExactCreateSequence(deviceId, exact.nextSequence);

      final checkpoint =
          await (select(syncCheckpoints)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.instanceId.equals(instanceId ?? '') &
                    row.serverSpaceId.equals(serverSpaceId ?? ''),
              ))
              .getSingleOrNull();
      if (checkpoint == null) {
        await into(syncCheckpoints).insert(
          SyncCheckpointsCompanion.insert(
            vaultId: vaultId,
            instanceId: Value(instanceId ?? ''),
            serverSpaceId: Value(serverSpaceId ?? ''),
            syncStatus: const Value('pending'),
          ),
        );
      } else {
        await (update(syncCheckpoints)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .write(
              const SyncCheckpointsCompanion(syncStatus: Value('pending')),
            );
      }
      return ExactCreateOperationResult.created;
    });
  }

  Future<void> _advanceExactCreateSequence(
    String deviceId,
    int requiredNextSequence,
  ) async {
    final current = await (select(
      deviceSequences,
    )..where((row) => row.deviceId.equals(deviceId))).getSingleOrNull();
    final currentSequence = current?.nextSequence ?? 1;
    if (currentSequence < 1 || currentSequence >= 9007199254740000) {
      throw StateError('Device sequence floor is outside its safe limit.');
    }
    final next = _max(currentSequence, requiredNextSequence);
    await into(deviceSequences).insertOnConflictUpdate(
      DeviceSequencesCompanion.insert(
        deviceId: deviceId,
        nextSequence: Value(next),
      ),
    );
  }

  _ExactCreateEnvelope _validateExactCreateEnvelope({
    required String vaultId,
    required String deviceId,
    required Map<String, Object?> envelope,
  }) {
    if (!_canonicalObjectReference.hasMatch(vaultId) ||
        !_canonicalObjectReference.hasMatch(deviceId)) {
      throw const FormatException('Target Vault or device ID is invalid.');
    }
    _validateExactFieldSet(envelope, const {
      'header',
      'nonce',
      'ciphertext',
      'signature',
    }, 'envelope');
    final rawHeader = envelope['header'];
    if (rawHeader is! Map || rawHeader.keys.any((key) => key is! String)) {
      throw const FormatException('Exact create envelope header is invalid.');
    }
    final header = Map<String, Object?>.from(rawHeader);
    const requiredHeaderFields = {
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
    _validateExactFieldSet(
      header,
      header.containsKey('object_refs')
          ? {...requiredHeaderFields, 'object_refs'}
          : requiredHeaderFields,
      'header',
    );
    for (final field in const [
      'server_space_id',
      'vault_id',
      'record_id',
      'revision_id',
      'op_id',
      'device_id',
    ]) {
      final value = header[field];
      if (value is! String || !_canonicalObjectReference.hasMatch(value)) {
        throw FormatException('Exact create $field is invalid.');
      }
    }
    if (header['vault_id'] != vaultId || header['device_id'] != deviceId) {
      throw const FormatException(
        'Exact create envelope does not match the target Vault and device.',
      );
    }
    if (header['wire_version'] is! int ||
        header['wire_version'] != 1 ||
        header['record_schema'] is! int ||
        !const {1, 2}.contains(header['record_schema']) ||
        header['operation'] != 'create' ||
        header['base_revision_id'] != null ||
        header['crypto_suite'] != 'atermius-vault-v1') {
      throw const FormatException('Exact create envelope header is invalid.');
    }
    final sequenceText = header['device_seq'];
    final keyEpoch = header['key_epoch'];
    final membershipVersion = header['membership_version'];
    if (sequenceText is! String ||
        !_isCanonicalBoundedDecimal(sequenceText, allowZero: false) ||
        keyEpoch is! String ||
        !_isCanonicalSignedCounter(keyEpoch, allowZero: false) ||
        membershipVersion is! String ||
        !_isCanonicalSignedCounter(membershipVersion, allowZero: false)) {
      throw const FormatException(
        'Exact create sequence or membership header is invalid.',
      );
    }
    if (header.containsKey('object_refs')) {
      final refs = header['object_refs'];
      if (refs is! List || refs.length > 1024) {
        throw const FormatException('Exact create object_refs is invalid.');
      }
      String? previous;
      for (final reference in refs) {
        if (reference is! String ||
            !_canonicalObjectReference.hasMatch(reference) ||
            (previous != null && previous.compareTo(reference) >= 0)) {
          throw const FormatException('Exact create object_refs is invalid.');
        }
        previous = reference;
      }
    }
    _validateCanonicalBase64Url(envelope['nonce'], 'nonce', expectedLength: 24);
    _validateCanonicalBase64Url(
      envelope['signature'],
      'signature',
      expectedLength: 64,
    );
    _validateCanonicalBase64Url(
      header['kdf_salt'],
      'kdf_salt',
      expectedLength: 32,
    );
    _validateCanonicalBase64Url(
      envelope['ciphertext'],
      'ciphertext',
      minimumLength: 16,
      maximumLength: 1024 * 1024,
    );

    final sequence = int.parse(sequenceText);
    if (sequence + 1 >= 9007199254740000) {
      throw const FormatException(
        'Exact create sequence exceeds its safe limit.',
      );
    }
    return _ExactCreateEnvelope(
      recordId: header['record_id']! as String,
      revisionId: header['revision_id']! as String,
      opId: header['op_id']! as String,
      nextSequence: sequence + 1,
    );
  }

  void _validateExactFieldSet(
    Map<Object?, Object?> value,
    Set<String> expected,
    String source,
  ) {
    if (value.keys.any((key) => key is! String) ||
        value.keys.toSet().difference(expected).isNotEmpty ||
        !value.keys.toSet().containsAll(expected)) {
      throw FormatException('Exact create $source fields are invalid.');
    }
  }

  bool _isCanonicalBoundedDecimal(String value, {required bool allowZero}) {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) return false;
    final parsed = int.tryParse(value);
    return parsed != null &&
        (allowZero || parsed > 0) &&
        parsed < 9007199254740000;
  }

  bool _isCanonicalSignedCounter(String value, {required bool allowZero}) {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value) || value.length > 19) {
      return false;
    }
    if (!allowZero && value == '0') return false;
    const maxSignedCounter = '9223372036854775807';
    return value.length < maxSignedCounter.length ||
        (value.length == maxSignedCounter.length &&
            value.compareTo(maxSignedCounter) <= 0);
  }

  void _validateCanonicalBase64Url(
    Object? value,
    String field, {
    int? expectedLength,
    int? minimumLength,
    int? maximumLength,
  }) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value) ||
        (maximumLength != null &&
            value.length > (maximumLength * 8 + 5) ~/ 6)) {
      throw FormatException('Exact create $field encoding is invalid.');
    }
    try {
      final bytes = base64Url.decode(
        value.padRight((value.length + 3) ~/ 4 * 4, '='),
      );
      if (base64Url.encode(bytes).replaceAll('=', '') != value ||
          (expectedLength != null && bytes.length != expectedLength) ||
          (minimumLength != null && bytes.length < minimumLength) ||
          (maximumLength != null && bytes.length > maximumLength)) {
        throw FormatException('Exact create $field size is invalid.');
      }
    } on FormatException {
      rethrow;
    } on Object {
      throw FormatException('Exact create $field encoding is invalid.');
    }
  }

  /// Retires local transfer material only in the transaction that stores the
  /// Host tombstone. A still-pending operation that references an upload keeps
  /// its durable bytes and continues to hold the outbox gate.
  Future<void> _cleanupAttachmentJobsAfterTombstone(
    String vaultId,
    String recordId,
    String opId,
    String? instanceId,
    String? serverSpaceId,
  ) async {
    final cached = (await _encryptedRecordsForScope(
      vaultId,
      recordId: recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    )).firstOrNull;
    final tombstone =
        await (select(pendingOperations)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(recordId) &
                  row.opId.equals(opId) &
                  (instanceId == null
                      ? row.instanceId.isNull()
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? row.serverSpaceId.isNull()
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (cached == null || !cached.isDeleted || tombstone == null) {
      throw StateError(
        'Attachment cleanup requires the Host tombstone in the local outbox.',
      );
    }
    final decoded = jsonDecode(tombstone.envelopeJson);
    if (decoded is! Map || decoded['header'] is! Map) {
      throw StateError('Cannot safely verify the Host tombstone envelope.');
    }
    final header = decoded['header'] as Map;
    if (header['record_id'] != recordId || header['operation'] != 'delete') {
      throw StateError('Cannot safely verify the Host tombstone operation.');
    }

    final jobs = await blobJobsForRecord(
      vaultId,
      recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final job in jobs) {
      var referencedByPendingOperation = false;
      if (job.direction == 'upload') {
        final objects = await (select(
          blobJobObjects,
        )..where((item) => item.jobId.equals(job.jobId))).get();
        for (final object in objects) {
          if (await pendingRecordReferencesObject(
            vaultId: vaultId,
            recordId: recordId,
            objectId: object.objectId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          )) {
            referencedByPendingOperation = true;
            break;
          }
        }
      }
      if (referencedByPendingOperation) continue;
      await (delete(
        blobJobObjects,
      )..where((item) => item.jobId.equals(job.jobId))).go();
      await (delete(
        blobJobs,
      )..where((item) => item.jobId.equals(job.jobId))).go();
    }
  }

  Future<List<PendingOperation>> queuedOperations(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(pendingOperations)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    (row.status.equals('queued') |
                        row.status.equals('sent') |
                        row.status.equals('cas_wait')),
              )
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.opId),
              ]))
            .get();
    if (instanceId == null) return rows;
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'pending operation',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  /// Atomically replaces a complete optimistic outbox chain with one freshly
  /// signed three-way merge based on the current remote head. Returns false
  /// when another tab changed the outbox or cached head while the merge was
  /// being prepared; callers should reread and reconcile the event again.
  Future<bool> replaceOutboxWithMergedOperation({
    required String vaultId,
    required String recordId,
    required List<PendingOperation> original,
    required String baseRevisionId,
    required Map<String, dynamic> baseEnvelope,
    required Map<String, dynamic> replacementEnvelope,
  }) async {
    if (original.isEmpty ||
        original.map((item) => item.opId).toSet().length != original.length) {
      throw const FormatException('Merged outbox chain is malformed.');
    }
    final instanceId = original.first.instanceId;
    final serverSpaceId = original.first.serverSpaceId;
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (original.any(
      (item) =>
          item.instanceId != instanceId || item.serverSpaceId != serverSpaceId,
    )) {
      throw const FormatException('Merged outbox chain crosses server scopes.');
    }
    final baseRawHeader = baseEnvelope['header'];
    final replacementRawHeader = replacementEnvelope['header'];
    if (baseRawHeader is! Map || replacementRawHeader is! Map) {
      throw const FormatException('Merged envelopes have invalid headers.');
    }
    final baseHeader = Map<String, dynamic>.from(baseRawHeader);
    final replacementHeader = Map<String, dynamic>.from(replacementRawHeader);
    final baseEnvelopeJson = jsonEncode(baseEnvelope);
    final replacementEnvelopeJson = jsonEncode(replacementEnvelope);
    final replacementOpId = replacementHeader['op_id'];
    final replacementRevisionId = replacementHeader['revision_id'];
    if (baseHeader['vault_id'] != vaultId ||
        baseHeader['record_id'] != recordId ||
        baseHeader['revision_id'] != baseRevisionId ||
        replacementHeader['vault_id'] != vaultId ||
        replacementHeader['record_id'] != recordId ||
        replacementHeader['operation'] != 'update' ||
        replacementHeader['base_revision_id'] != baseRevisionId ||
        replacementOpId is! String ||
        replacementRevisionId is! String ||
        replacementOpId.isEmpty ||
        replacementRevisionId.isEmpty ||
        replacementEnvelope['signature'] is! String ||
        replacementEnvelope['ciphertext'] is! String ||
        replacementEnvelope['nonce'] is! String) {
      throw const FormatException('Merged operation does not match its head.');
    }

    final replaced = await transaction(() async {
      final rows = _filterScopedRows(
        rows:
            await (select(pendingOperations)
                  ..where(
                    (row) =>
                        row.vaultId.equals(vaultId) &
                        row.recordId.equals(recordId) &
                        (row.status.equals('queued') |
                            row.status.equals('sent') |
                            row.status.equals('cas_wait') |
                            row.status.equals('conflict')),
                  )
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.createdAt),
                    (row) => OrderingTerm.asc(row.opId),
                  ]))
                .get(),
        rowType: 'pending operation',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final rowsById = {for (final row in rows) row.opId: row};
      if (rows.length != original.length ||
          rows.any(
            (row) => row.status == 'conflict' || row.status == 'cas_wait',
          ) ||
          rowsById.length != original.length ||
          !rowsById.keys.toSet().containsAll(
            original.map((item) => item.opId),
          )) {
        return false;
      }

      for (var index = 0; index < original.length; index++) {
        final expected = original[index];
        final row = rowsById[expected.opId]!;
        if ((row.status != 'queued' && row.status != 'sent') ||
            row.opId != expected.opId ||
            row.vaultId != vaultId ||
            row.recordId != recordId ||
            row.baseRevisionId != expected.baseRevisionId ||
            row.baseEnvelopeJson != expected.baseEnvelopeJson ||
            row.envelopeJson != expected.envelopeJson) {
          return false;
        }
        final raw = jsonDecode(expected.envelopeJson);
        if (raw is! Map || raw['header'] is! Map) {
          throw const FormatException('Pending merge operation is malformed.');
        }
        final header = Map<String, dynamic>.from(raw['header'] as Map);
        if (header['vault_id'] != vaultId ||
            header['record_id'] != recordId ||
            header['operation'] != 'update' ||
            header['base_revision_id'] != expected.baseRevisionId) {
          throw const FormatException(
            'Pending merge operation has an invalid base.',
          );
        }
        if (index == 0) {
          final originalBase = expected.baseEnvelopeJson;
          if (expected.baseRevisionId == null || originalBase == null) {
            return false;
          }
          final decodedBase = jsonDecode(originalBase);
          if (decodedBase is! Map || decodedBase['header'] is! Map) {
            throw const FormatException('Pending merge base is malformed.');
          }
          final originalBaseHeader = Map<String, dynamic>.from(
            decodedBase['header'] as Map,
          );
          if (originalBaseHeader['vault_id'] != vaultId ||
              originalBaseHeader['record_id'] != recordId ||
              originalBaseHeader['revision_id'] != expected.baseRevisionId) {
            throw const FormatException('Pending merge base does not match.');
          }
        } else {
          final previous = original[index - 1];
          final previousEnvelope = jsonDecode(previous.envelopeJson);
          final previousHeader = Map<String, dynamic>.from(
            (previousEnvelope as Map)['header'] as Map,
          );
          if (expected.baseRevisionId != previousHeader['revision_id'] ||
              !_hasCanonicalJson(
                expected.baseEnvelopeJson ?? '',
                canonicalJson(previousEnvelope),
              )) {
            throw const FormatException(
              'Pending merge operations do not form a chain.',
            );
          }
        }
      }

      final currentHead = (await _encryptedRecordsForScope(
        vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      final latestOriginal = jsonDecode(original.last.envelopeJson);
      final latestHeader = Map<String, dynamic>.from(
        (latestOriginal as Map)['header'] as Map,
      );
      if (currentHead == null ||
          currentHead.commitSeq != null ||
          currentHead.revisionId != latestHeader['revision_id'] ||
          !_hasCanonicalJson(
            currentHead.envelopeJson,
            canonicalJson(latestOriginal),
          )) {
        return false;
      }

      final openConflicts = _filterScopedRows(
        rows:
            await (select(conflictBranches)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.recordId.equals(recordId) &
                      row.state.isNotValue('resolved'),
                ))
                .get(),
        rowType: 'conflict branch',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (openConflicts.isNotEmpty) return false;
      if (await (select(pendingOperations)
                ..where((row) => row.opId.equals(replacementOpId)))
              .getSingleOrNull() !=
          null) {
        throw const FormatException('Merged operation ID is already in use.');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final operation in original) {
        await (update(
          pendingOperations,
        )..where((row) => row.opId.equals(operation.opId))).write(
          const PendingOperationsCompanion(status: Value('superseded')),
        );
      }
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: replacementOpId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: Value(baseRevisionId),
          baseEnvelopeJson: Value(baseEnvelopeJson),
          envelopeJson: replacementEnvelopeJson,
          status: const Value('queued'),
          createdAt: now,
        ),
      );
      await into(encryptedRecords).insertOnConflictUpdate(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: replacementRevisionId,
          envelopeJson: replacementEnvelopeJson,
          isDeleted: const Value(false),
          commitSeq: const Value(null),
          updatedAt: now,
        ),
      );
      await into(syncCheckpoints).insertOnConflictUpdate(
        SyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          syncStatus: const Value('pending'),
        ),
      );
      return true;
    });
    if (replaced) await flushCommittedWrites();
    return replaced;
  }

  Future<bool> pendingRecordReferencesObject({
    required String vaultId,
    required String recordId,
    required String objectId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final operations =
        await (select(pendingOperations)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(recordId) &
                  (row.status.equals('queued') |
                      row.status.equals('sent') |
                      row.status.equals('cas_wait')),
            ))
            .get();
    final scopedOperations = instanceId == null
        ? operations
        : operations
              .where(
                (row) => _scopeMatchesOrThrow(
                  rowType: 'pending operation',
                  rowInstanceId: row.instanceId,
                  rowServerSpaceId: row.serverSpaceId,
                  instanceId: instanceId,
                  serverSpaceId: serverSpaceId!,
                ),
              )
              .toList(growable: false);
    for (final operation in scopedOperations) {
      final decoded = jsonDecode(operation.envelopeJson);
      if (decoded is! Map || decoded['header'] is! Map) {
        throw StateError('Cannot safely inspect a pending record envelope.');
      }
      final header = decoded['header'] as Map;
      if (!header.containsKey('object_refs')) continue;
      final rawRefs = header['object_refs'];
      if (rawRefs is! List ||
          rawRefs.length > 1024 ||
          rawRefs.any(
            (value) =>
                value is! String || !_canonicalObjectReference.hasMatch(value),
          )) {
        throw StateError('Cannot safely inspect pending object references.');
      }
      final refs = rawRefs.cast<String>();
      if (refs.toSet().length != refs.length) {
        throw StateError('Cannot safely inspect duplicate pending references.');
      }
      if (refs.contains(objectId)) return true;
    }
    return false;
  }

  Future<List<PendingOperation>> allPendingOperations(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(pendingOperations)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.status.isNotValue('superseded'),
              )
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.opId),
              ]))
            .get();
    if (instanceId == null) return rows;
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'pending operation',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  Future<List<PendingOperation>> supersededOperations(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(pendingOperations)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.status.equals('superseded'),
              )
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.opId),
              ]))
            .get();
    if (instanceId == null) return rows;
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'pending operation',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  Future<List<ConflictBranche>> allConflictBranches(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(conflictBranches)
              ..where((row) => row.vaultId.equals(vaultId))
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    if (instanceId == null) return rows;
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'conflict branch',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, int>> deviceSequenceFloors() async {
    final rows = await select(deviceSequences).get();
    return {for (final row in rows) row.deviceId: row.nextSequence};
  }

  Future<ArchiveObjectBytes?> archiveObject(
    String vaultId,
    String objectId,
  ) async {
    final row =
        await (select(vaultArchiveObjects)..where(
              (item) =>
                  item.vaultId.equals(vaultId) & item.objectId.equals(objectId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return ArchiveObjectBytes(
      objectId: row.objectId,
      bytes: Uint8List.fromList(row.bytes),
      sha256: row.sha256,
    );
  }

  /// Imports a fully verified portable archive atomically. It merges the
  /// archive's immutable outbox/conflict/object material without replacing
  /// unrelated Vault state, then reuses snapshot reconciliation for the
  /// committed record cache. Sequence counters only move forward.
  Future<SnapshotApplyResult> applyPortableVaultArchive({
    required String vaultId,
    required String instanceId,
    required String serverSpaceId,
    required List<SnapshotHead> heads,
    required String? cursor,
    required String serverGeneration,
    required List<ArchivePendingOperation> operations,
    required List<ArchiveConflictBranch> conflicts,
    required List<ArchiveObjectBytes> objects,
    required Map<String, int> sequenceFloors,
  }) => transaction(() async {
    final existingOperations = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final existingById = {for (final row in existingOperations) row.opId: row};
    final importedIds = <String>{};
    for (final item in operations) {
      if (!importedIds.add(item.opId)) {
        throw StateError('Portable archive has a duplicate outbox op_id.');
      }
      final existing = existingById[item.opId];
      if (existing != null) {
        if (existing.vaultId != vaultId ||
            existing.recordId != item.recordId ||
            existing.baseRevisionId != item.baseRevisionId ||
            canonicalJson(jsonDecode(existing.envelopeJson)) !=
                canonicalJson(jsonDecode(item.envelopeJson))) {
          throw StateError(
            'Portable archive outbox op_id collides with different local data.',
          );
        }
        continue;
      }
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: item.opId,
          vaultId: vaultId,
          recordId: item.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: Value(item.baseRevisionId),
          baseEnvelopeJson: Value(item.baseEnvelopeJson),
          envelopeJson: item.envelopeJson,
          status: Value(item.status),
          attemptCount: Value(item.attemptCount),
          createdAt: item.createdAt,
          lastAttemptAt: Value(item.lastAttemptAt),
        ),
      );
    }

    final existingConflicts = await allConflictBranches(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final existingConflictById = {
      for (final row in existingConflicts) row.conflictId: row,
    };
    final importedConflictIds = <String>{};
    for (final item in conflicts) {
      if (!importedConflictIds.add(item.conflictId)) {
        throw StateError('Portable archive has a duplicate conflict_id.');
      }
      final existing = existingConflictById[item.conflictId];
      if (existing != null) {
        if (existing.recordId != item.recordId ||
            existing.kind != item.kind ||
            canonicalJson(jsonDecode(existing.branchEnvelopeJson)) !=
                canonicalJson(jsonDecode(item.branchEnvelopeJson)) ||
            canonicalJson(jsonDecode(existing.remoteEnvelopeJson)) !=
                canonicalJson(jsonDecode(item.remoteEnvelopeJson))) {
          throw StateError(
            'Portable archive conflict_id collides with different local data.',
          );
        }
        continue;
      }
      await into(conflictBranches).insert(
        ConflictBranchesCompanion.insert(
          conflictId: item.conflictId,
          vaultId: vaultId,
          recordId: item.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          kind: item.kind,
          branchEnvelopeJson: item.branchEnvelopeJson,
          remoteEnvelopeJson: item.remoteEnvelopeJson,
          state: Value(item.state),
          resolutionOpId: Value(item.resolutionOpId),
          resolutionRevisionId: Value(item.resolutionRevisionId),
          createdAt: item.createdAt,
        ),
      );
    }

    final existingObjects = await (select(
      vaultArchiveObjects,
    )..where((row) => row.vaultId.equals(vaultId))).get();
    final existingObjectById = {
      for (final row in existingObjects) row.objectId: row,
    };
    final importedObjectIds = <String>{};
    for (final item in objects) {
      if (!importedObjectIds.add(item.objectId)) {
        throw StateError('Portable archive has a duplicate object_id.');
      }
      final existing = existingObjectById[item.objectId];
      if (existing != null) {
        if (existing.sha256 != item.sha256 ||
            !_sameBytes(existing.bytes, item.bytes)) {
          throw StateError(
            'Portable archive object_id collides with different local bytes.',
          );
        }
        continue;
      }
      await into(vaultArchiveObjects).insert(
        VaultArchiveObjectsCompanion.insert(
          vaultId: vaultId,
          objectId: item.objectId,
          bytes: item.bytes,
          sha256: item.sha256,
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    final floors = Map<String, int>.from(sequenceFloors);
    for (final item in operations) {
      final envelope = jsonDecode(item.envelopeJson);
      final header = envelope is Map && envelope['header'] is Map
          ? Map<String, dynamic>.from(envelope['header'] as Map)
          : throw const FormatException(
              'Archived outbox envelope has no header.',
            );
      final deviceId = header['device_id'];
      final sequenceText = header['device_seq'];
      if (deviceId is! String ||
          sequenceText is! String ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(sequenceText)) {
        throw const FormatException('Archived outbox sequence is invalid.');
      }
      final parsed = int.tryParse(sequenceText);
      if (parsed == null || parsed >= 9007199254740000) {
        throw const FormatException(
          'Archived device sequence exceeds its limit.',
        );
      }
      floors[deviceId] = _max(floors[deviceId] ?? 1, parsed + 1);
    }
    for (final entry in floors.entries) {
      if (entry.key.isEmpty ||
          entry.value < 1 ||
          entry.value >= 9007199254740000) {
        throw const FormatException('Archived sequence floor is invalid.');
      }
      final current = await (select(
        deviceSequences,
      )..where((row) => row.deviceId.equals(entry.key))).getSingleOrNull();
      final next = _max(current?.nextSequence ?? 1, entry.value);
      await into(deviceSequences).insertOnConflictUpdate(
        DeviceSequencesCompanion.insert(
          deviceId: entry.key,
          nextSequence: Value(next),
        ),
      );
    }

    return applyVaultSnapshot(
      vaultId: vaultId,
      heads: heads,
      cursor: cursor,
      serverGeneration: serverGeneration,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
  });

  Future<int> countPending(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final rows = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return rows
        .where((row) => !const {'superseded', 'redacted'}.contains(row.status))
        .length;
  }

  /// Returns an opaque fingerprint for the encrypted outbox material that a
  /// portable Vault archive must preserve. Retry scheduling does not change
  /// the fingerprint; replacing or acknowledging an operation does.
  Future<String> pendingOutboxFingerprint(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final operations = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final operationsState =
        [
          for (final operation in operations)
            <Object?>[
              operation.opId,
              operation.recordId,
              operation.baseRevisionId,
              operation.baseEnvelopeJson,
              operation.envelopeJson,
              operation.status,
            ],
        ]..sort(
          (left, right) =>
              (left.first! as String).compareTo(right.first! as String),
        );
    final state = <Object?>[instanceId, serverSpaceId, operationsState];
    return crypto.sha256.convert(utf8.encode(jsonEncode(state))).toString();
  }

  /// Atomically archives an exact stale outbox chain and replaces it with
  /// freshly signed operations. The retired envelopes remain in the table as
  /// immutable evidence, but are excluded from active queues and exports.
  Future<void> replaceStaleOutboxChain({
    required String vaultId,
    required String recordId,
    required List<PendingOperation> original,
    required List<StaleOperationReplacement> replacements,
  }) async {
    if (original.isEmpty || original.length != replacements.length) {
      throw const FormatException('Stale outbox replacement is malformed.');
    }
    final originalIds = original.map((item) => item.opId).toSet();
    final replacementIds = replacements.map((item) => item.opId).toSet();
    if (originalIds.length != original.length ||
        replacementIds.length != replacements.length ||
        originalIds.intersection(replacementIds).isNotEmpty ||
        original.any(
          (item) => item.vaultId != vaultId || item.recordId != recordId,
        )) {
      throw const FormatException('Stale outbox replacement is malformed.');
    }
    final instanceId = original.first.instanceId;
    final serverSpaceId = original.first.serverSpaceId;
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (original.any(
      (item) =>
          item.instanceId != instanceId || item.serverSpaceId != serverSpaceId,
    )) {
      throw const FormatException('Stale outbox chain crosses server scopes.');
    }

    await transaction(() async {
      final current = _filterScopedRows(
        rows:
            await (select(pendingOperations)
                  ..where(
                    (row) =>
                        row.vaultId.equals(vaultId) &
                        row.recordId.equals(recordId),
                  )
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.createdAt),
                    (row) => OrderingTerm.asc(row.opId),
                  ]))
                .get(),
        rowType: 'pending operation',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final active = current
          .where(
            (item) =>
                item.status == 'queued' ||
                item.status == 'sent' ||
                item.status == 'cas_wait' ||
                item.status == 'conflict',
          )
          .toList(growable: false);
      if (active.length != original.length ||
          !active.map((item) => item.opId).toSet().containsAll(originalIds) ||
          !originalIds.containsAll(active.map((item) => item.opId))) {
        throw StateError('Outbox changed or is conflicted during key update.');
      }
      for (var index = 0; index < original.length; index++) {
        final expected = original[index];
        final row = active.firstWhere((item) => item.opId == expected.opId);
        if ((row.status != 'queued' && row.status != 'sent') ||
            row.vaultId != expected.vaultId ||
            row.recordId != expected.recordId ||
            row.baseRevisionId != expected.baseRevisionId ||
            row.baseEnvelopeJson != expected.baseEnvelopeJson ||
            row.envelopeJson != expected.envelopeJson) {
          throw StateError('Outbox changed during key update.');
        }
        final envelope =
            jsonDecode(expected.envelopeJson) as Map<String, dynamic>;
        final header = Map<String, dynamic>.from(envelope['header'] as Map);
        if (index > 0) {
          final previous = original[index - 1];
          final previousEnvelope =
              jsonDecode(previous.envelopeJson) as Map<String, dynamic>;
          final previousHeader = Map<String, dynamic>.from(
            previousEnvelope['header'] as Map,
          );
          if (expected.baseRevisionId != previousHeader['revision_id'] ||
              expected.baseEnvelopeJson != previous.envelopeJson) {
            throw const FormatException(
              'Original stale outbox chain is not contiguous.',
            );
          }
        } else if (expected.baseEnvelopeJson != null) {
          final baseEnvelope =
              jsonDecode(expected.baseEnvelopeJson!) as Map<String, dynamic>;
          final baseHeader = Map<String, dynamic>.from(
            baseEnvelope['header'] as Map,
          );
          if (baseHeader['vault_id'] != vaultId ||
              baseHeader['record_id'] != recordId ||
              baseHeader['revision_id'] != expected.baseRevisionId) {
            throw const FormatException(
              'Original stale outbox base does not match its envelope.',
            );
          }
        }
        if (header['base_revision_id'] != expected.baseRevisionId) {
          throw const FormatException(
            'Original stale outbox header does not match its base.',
          );
        }
      }

      final latestOriginal = original.last;
      final latestEnvelope =
          jsonDecode(latestOriginal.envelopeJson) as Map<String, dynamic>;
      final latestHeader = Map<String, dynamic>.from(
        latestEnvelope['header'] as Map,
      );
      final cached = (await _encryptedRecordsForScope(
        vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      if (cached == null ||
          cached.commitSeq != null ||
          cached.revisionId != latestHeader['revision_id'] ||
          cached.envelopeJson != latestOriginal.envelopeJson) {
        throw StateError('Local record head changed during key update.');
      }

      final prepared =
          <
            ({
              StaleOperationReplacement replacement,
              Map<String, dynamic> envelope,
              Map<String, dynamic> header,
            })
          >[];
      final seenReplacementIds = <String>{};
      for (var index = 0; index < replacements.length; index++) {
        final replacement = replacements[index];
        final envelope =
            jsonDecode(replacement.envelopeJson) as Map<String, dynamic>;
        final rawHeader = envelope['header'];
        if (rawHeader is! Map) {
          throw const FormatException('Re-signed operation is malformed.');
        }
        final header = Map<String, dynamic>.from(rawHeader);
        final expectedBase = index == 0
            ? original.first.baseRevisionId
            : (jsonDecode(replacements[index - 1].envelopeJson)
                      as Map<String, dynamic>)['header']['revision_id']
                  as String;
        final existingReplacement = await (select(
          pendingOperations,
        )..where((row) => row.opId.equals(replacement.opId))).getSingleOrNull();
        if (!seenReplacementIds.add(replacement.opId) ||
            existingReplacement != null ||
            header['op_id'] != replacement.opId ||
            header['vault_id'] != vaultId ||
            header['record_id'] != recordId ||
            header['base_revision_id'] != replacement.baseRevisionId ||
            replacement.baseRevisionId != expectedBase ||
            header['revision_id'] is! String ||
            header['device_id'] is! String ||
            header['device_seq'] is! String ||
            header['key_epoch'] is! String ||
            header['membership_version'] is! String ||
            envelope['signature'] is! String ||
            envelope['ciphertext'] is! String ||
            envelope['nonce'] is! String) {
          throw const FormatException('Re-signed operation is malformed.');
        }
        if (index > 0 &&
            replacement.baseEnvelopeJson !=
                replacements[index - 1].envelopeJson) {
          throw const FormatException(
            'Re-signed operation chain is not contiguous.',
          );
        }
        prepared.add((
          replacement: replacement,
          envelope: envelope,
          header: header,
        ));
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in original) {
        await (update(
          pendingOperations,
        )..where((item) => item.opId.equals(row.opId))).write(
          const PendingOperationsCompanion(status: Value('superseded')),
        );
      }
      for (var index = 0; index < prepared.length; index++) {
        final item = prepared[index];
        await into(pendingOperations).insert(
          PendingOperationsCompanion.insert(
            opId: item.replacement.opId,
            vaultId: vaultId,
            recordId: recordId,
            instanceId: Value(instanceId),
            serverSpaceId: Value(serverSpaceId),
            baseRevisionId: Value(item.replacement.baseRevisionId),
            baseEnvelopeJson: Value(item.replacement.baseEnvelopeJson),
            envelopeJson: item.replacement.envelopeJson,
            status: const Value('queued'),
            createdAt: now + index,
          ),
        );
      }
      final latestReplacement = prepared.last;
      await into(encryptedRecords).insertOnConflictUpdate(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: latestReplacement.header['revision_id'] as String,
          envelopeJson: latestReplacement.replacement.envelopeJson,
          isDeleted: Value(latestReplacement.header['operation'] == 'delete'),
          commitSeq: const Value(null),
          updatedAt: now,
        ),
      );
      await into(syncCheckpoints).insertOnConflictUpdate(
        SyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          syncStatus: const Value('pending'),
        ),
      );
    });
  }

  Future<Set<String>> markAttempted(Iterable<String> opIds) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final marked = <String>{};
    await transaction(() async {
      for (final id in opIds.toSet()) {
        final row = await (select(
          pendingOperations,
        )..where((item) => item.opId.equals(id))).getSingleOrNull();
        if (row == null || (row.status != 'queued' && row.status != 'sent')) {
          continue;
        }
        await (update(
          pendingOperations,
        )..where((item) => item.opId.equals(id))).write(
          PendingOperationsCompanion(
            status: const Value('sent'),
            attemptCount: Value(row.attemptCount + 1),
            lastAttemptAt: Value(now),
          ),
        );
        marked.add(id);
      }
    });
    return marked;
  }

  /// Reverts only the retry metadata written immediately before a push that
  /// the server explicitly rejected because its generation changed. An
  /// operation acknowledged or otherwise changed by another tab is left
  /// untouched.
  Future<void> restoreUnacceptedPushAttempts(
    Iterable<PendingOperation> attempted,
  ) async {
    final beforeAttempt = attempted.toList(growable: false);
    await transaction(() async {
      for (final previous in beforeAttempt) {
        final current = await (select(
          pendingOperations,
        )..where((row) => row.opId.equals(previous.opId))).getSingleOrNull();
        if (current == null ||
            current.recordId != previous.recordId ||
            current.baseRevisionId != previous.baseRevisionId ||
            current.envelopeJson != previous.envelopeJson ||
            current.status != 'sent' ||
            current.attemptCount != previous.attemptCount + 1) {
          continue;
        }
        await (update(
          pendingOperations,
        )..where((row) => row.opId.equals(previous.opId))).write(
          PendingOperationsCompanion(
            status: Value(previous.status),
            attemptCount: Value(previous.attemptCount),
            lastAttemptAt: Value(previous.lastAttemptAt),
          ),
        );
      }
    });
  }

  Future<void> markConflicted(String opId) =>
      (update(pendingOperations)..where((row) => row.opId.equals(opId))).write(
        const PendingOperationsCompanion(status: Value('conflict')),
      );

  Future<PendingOperation?> conflictedOperation(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final rows = _filterScopedRows(
      rows:
          await (select(pendingOperations)
                ..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.recordId.equals(recordId) &
                      row.status.equals('conflict'),
                )
                ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return rows.firstOrNull;
  }

  Future<void> discardConflictedOperations({
    required String vaultId,
    required String recordId,
  }) =>
      (delete(pendingOperations)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.recordId.equals(recordId) &
                row.status.equals('conflict'),
          ))
          .go();

  /// Removes one locally staged create only when it is still queued and its
  /// optimistic cache row is provably uncommitted. This is used when a user
  /// disables an opt-in feature that may have staged Vault records. Sent,
  /// conflicted, chained, or committed operations are intentionally retained.
  Future<bool> discardQueuedCreateOperationIfUncommitted({
    required String vaultId,
    required String recordId,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    final operations = _filterScopedRows(
      rows:
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(recordId) &
                    row.status.isNotValue('superseded'),
              ))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (operations.length != 1) return false;
    final operation = operations.single;
    if (operation.status != 'queued' || operation.baseRevisionId != null) {
      return false;
    }

    final decoded = jsonDecode(operation.envelopeJson);
    if (decoded is! Map || decoded['header'] is! Map) return false;
    final header = decoded['header'] as Map;
    if (header['vault_id'] != vaultId ||
        header['record_id'] != recordId ||
        header['op_id'] != operation.opId ||
        header['operation'] != 'create' ||
        header['base_revision_id'] != null ||
        header['revision_id'] is! String) {
      return false;
    }

    final cached = (await _encryptedRecordsForScope(
      vaultId,
      recordId: recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    )).firstOrNull;
    final revisionId = header['revision_id'] as String;
    if (cached == null ||
        cached.revisionId != revisionId ||
        cached.envelopeJson != operation.envelopeJson ||
        cached.commitSeq != null ||
        cached.isDeleted) {
      return false;
    }

    final removedCacheRows =
        await (delete(encryptedRecords)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(recordId) &
                  row.revisionId.equals(revisionId) &
                  row.commitSeq.isNull() &
                  row.isDeleted.equals(false) &
                  (instanceId == null
                      ? row.instanceId.isNull()
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? row.serverSpaceId.isNull()
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .go();
    if (removedCacheRows != 1) return false;
    await (delete(
      pendingOperations,
    )..where((row) => row.opId.equals(operation.opId))).go();

    final remainingOperations = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final checkpoint =
        await (select(syncCheckpoints)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (checkpoint != null) {
      await (update(syncCheckpoints)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.instanceId.equals(instanceId ?? '') &
                row.serverSpaceId.equals(serverSpaceId ?? ''),
          ))
          .write(
            SyncCheckpointsCompanion(
              syncStatus: Value(
                remainingOperations.isEmpty ? 'idle' : 'pending',
              ),
            ),
          );
    }
    return true;
  });

  Future<String> nextDeviceSequence(String deviceId) async {
    return transaction(() async {
      final current = await (select(
        deviceSequences,
      )..where((row) => row.deviceId.equals(deviceId))).getSingleOrNull();
      final value = current?.nextSequence ?? 1;
      if (value >= 9007199254740000)
        throw StateError('Device sequence is at its safe limit');
      await into(deviceSequences).insertOnConflictUpdate(
        DeviceSequencesCompanion.insert(
          deviceId: deviceId,
          nextSequence: Value(value + 1),
        ),
      );
      return '$value';
    });
  }

  Future<void> markCommitted({
    required String opId,
    required String commitSeq,

    /// Pass only after the sync pull path has verified and decrypted this exact
    /// event envelope. It creates the durable proof for a delayed push receipt.
    Map<String, dynamic>? authenticatedEventEnvelope,
  }) async {
    await transaction(() async {
      final operation = await (select(
        pendingOperations,
      )..where((row) => row.opId.equals(opId))).getSingleOrNull();
      if (operation == null) return;
      final envelope =
          jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
      final header = envelope['header'] as Map<String, dynamic>;
      final instanceId = operation.instanceId;
      final serverSpaceId = operation.serverSpaceId;
      if (authenticatedEventEnvelope != null) {
        final rawEventHeader = authenticatedEventEnvelope['header'];
        if (rawEventHeader is! Map ||
            canonicalJson(authenticatedEventEnvelope) !=
                canonicalJson(envelope)) {
          throw StateError(
            'Authenticated commit event does not match the pending operation.',
          );
        }
        final eventHeader = Map<String, dynamic>.from(rawEventHeader);
        if (header['op_id'] != opId ||
            eventHeader['op_id'] != opId ||
            eventHeader['vault_id'] != operation.vaultId ||
            eventHeader['record_id'] != operation.recordId ||
            eventHeader['revision_id'] != header['revision_id'] ||
            !_isCanonicalSignedCounter(commitSeq, allowZero: false)) {
          throw StateError(
            'Authenticated commit event metadata does not match its operation.',
          );
        }
        final priorProof = await (select(
          authenticatedPushReceipts,
        )..where((row) => row.opId.equals(opId))).getSingleOrNull();
        if (priorProof != null &&
            (priorProof.vaultId != operation.vaultId ||
                priorProof.recordId != operation.recordId ||
                priorProof.revisionId != header['revision_id'] ||
                canonicalJson(jsonDecode(priorProof.envelopeJson)) !=
                    canonicalJson(authenticatedEventEnvelope) ||
                priorProof.commitSeq != commitSeq)) {
          throw StateError('Authenticated commit receipt changed on replay.');
        }
        if (priorProof == null) {
          await into(authenticatedPushReceipts).insert(
            AuthenticatedPushReceiptsCompanion.insert(
              opId: opId,
              vaultId: operation.vaultId,
              recordId: operation.recordId,
              instanceId: Value(instanceId),
              serverSpaceId: Value(serverSpaceId),
              revisionId: header['revision_id'] as String,
              envelopeJson: canonicalJson(authenticatedEventEnvelope),
              commitSeq: commitSeq,
              createdAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
        }
      }
      final resolution =
          await (select(conflictBranches)..where(
                (row) =>
                    row.vaultId.equals(operation.vaultId) &
                    row.resolutionOpId.equals(opId) &
                    (instanceId == null
                        ? row.instanceId.isNull()
                        : row.instanceId.equals(instanceId)) &
                    (serverSpaceId == null
                        ? row.serverSpaceId.isNull()
                        : row.serverSpaceId.equals(serverSpaceId)),
              ))
              .getSingleOrNull();
      if (resolution != null) {
        if (resolution.state != 'resolution_pending' ||
            resolution.resolutionRevisionId != header['revision_id']) {
          throw StateError(
            'Conflict resolution operation no longer matches its saved branch.',
          );
        }
        await (update(
          conflictBranches,
        )..where((row) => row.conflictId.equals(resolution.conflictId))).write(
          const ConflictBranchesCompanion(state: Value('resolution_ready')),
        );
      }
      await (update(encryptedRecords)..where(
            (row) =>
                row.vaultId.equals(operation.vaultId) &
                row.recordId.equals(operation.recordId) &
                row.revisionId.equals(header['revision_id'] as String) &
                (instanceId == null
                    ? row.instanceId.isNull()
                    : row.instanceId.equals(instanceId)) &
                (serverSpaceId == null
                    ? row.serverSpaceId.isNull()
                    : row.serverSpaceId.equals(serverSpaceId)),
          ))
          .write(EncryptedRecordsCompanion(commitSeq: Value(commitSeq)));
      await (delete(
        pendingOperations,
      )..where((row) => row.opId.equals(opId))).go();
    });
  }

  /// Validates the whole server receipt before changing any durable state, then
  /// acknowledges the batch and records any conflict resolution handoff in one
  /// SQLite transaction. A process crash can replay the same immutable outbox.
  Future<void> _validateAlreadyAcknowledgedPush({
    required String vaultId,
    required PendingOperation expected,
    required PushCommitReceipt? receipt,
  }) async {
    final envelope = jsonDecode(expected.envelopeJson) as Map<String, dynamic>;
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    if (expected.vaultId != vaultId ||
        header['op_id'] != expected.opId ||
        header['record_id'] != expected.recordId ||
        header['vault_id'] != vaultId ||
        header['revision_id'] != receipt?.revisionId ||
        receipt?.opId != expected.opId ||
        receipt?.commitSeq.isEmpty == true ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(receipt!.commitSeq)) {
      throw StateError(
        'Push receipt does not match operation ${expected.opId}.',
      );
    }

    final proof = await (select(
      authenticatedPushReceipts,
    )..where((row) => row.opId.equals(expected.opId))).getSingleOrNull();
    final instanceId = expected.instanceId;
    final serverSpaceId = expected.serverSpaceId;
    var consumedEventProof = false;
    if (proof != null) {
      if (proof.vaultId != vaultId ||
          proof.recordId != expected.recordId ||
          proof.instanceId != instanceId ||
          proof.serverSpaceId != serverSpaceId ||
          proof.revisionId != receipt.revisionId ||
          canonicalJson(jsonDecode(proof.envelopeJson)) !=
              canonicalJson(envelope) ||
          proof.commitSeq != receipt.commitSeq) {
        throw StateError(
          'Authenticated commit proof does not match receipt for ${expected.opId}.',
        );
      }
      consumedEventProof = true;
    } else {
      // Preserve idempotency for duplicate acknowledgements while the exact
      // committed revision remains the active cache head.
      final committed = (await _encryptedRecordsForScope(
        vaultId,
        recordId: expected.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).where((row) => row.revisionId == receipt.revisionId).firstOrNull;
      if (committed == null ||
          canonicalJson(jsonDecode(committed.envelopeJson)) !=
              canonicalJson(envelope) ||
          committed.commitSeq != receipt.commitSeq ||
          committed.isDeleted != (header['operation'] == 'delete')) {
        throw StateError(
          'Missing pending operation ${expected.opId} has no matching committed cache receipt.',
        );
      }
    }

    final resolution =
        await (select(conflictBranches)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.resolutionOpId.equals(expected.opId) &
                  (instanceId == null
                      ? row.instanceId.isNull()
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? row.serverSpaceId.isNull()
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (resolution != null &&
        (resolution.vaultId != vaultId ||
            resolution.recordId != expected.recordId ||
            resolution.instanceId != instanceId ||
            resolution.serverSpaceId != serverSpaceId ||
            !const {
              'resolution_ready',
              'resolved',
            }.contains(resolution.state) ||
            resolution.resolutionRevisionId != receipt.revisionId)) {
      throw StateError(
        'Conflict resolution metadata changed before acknowledgement.',
      );
    }

    final feedResolution =
        await (select(feedConflictResolutions)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.opId.equals(expected.opId) &
                  (instanceId == null
                      ? row.instanceId.isNull()
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? row.serverSpaceId.isNull()
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (feedResolution != null &&
        (feedResolution.vaultId != vaultId ||
            feedResolution.recordId != expected.recordId ||
            feedResolution.instanceId != instanceId ||
            feedResolution.serverSpaceId != serverSpaceId ||
            !const {'committed', 'resolved'}.contains(feedResolution.state) ||
            feedResolution.resolutionRevisionId != receipt.revisionId)) {
      throw StateError(
        'Feed conflict resolution metadata changed before acknowledgement.',
      );
    }
    if (consumedEventProof) {
      await (delete(
        authenticatedPushReceipts,
      )..where((row) => row.opId.equals(expected.opId))).go();
    }
  }

  Future<void> acknowledgePushBatch({
    required String vaultId,
    required List<PendingOperation> requested,
    required Map<String, PushCommitReceipt> receipts,
  }) async {
    await transaction(() async {
      final requestedById = <String, PendingOperation>{};
      for (final operation in requested) {
        if (requestedById.containsKey(operation.opId)) {
          throw StateError('Push request contains a duplicate operation ID.');
        }
        requestedById[operation.opId] = operation;
      }
      if (requestedById.isEmpty ||
          requestedById.length != receipts.length ||
          !requestedById.keys.toSet().containsAll(receipts.keys)) {
        throw StateError('Push receipts do not exactly match the request.');
      }

      final currentRows = <String, PendingOperation>{};
      final resolutionRows = <String, ConflictBranche>{};
      final feedResolutionRows = <String, FeedConflictResolution>{};
      for (final expected in requested) {
        final current = await (select(
          pendingOperations,
        )..where((row) => row.opId.equals(expected.opId))).getSingleOrNull();
        if (current == null) {
          // Two tabs can submit the same immutable operation before either
          // receives its receipt. Treat the second local acknowledgement as a
          // no-op only when an authenticated event proof or the exact committed
          // cache head proves the first acknowledgement already applied its
          // receipt and resolution side effects.
          await _validateAlreadyAcknowledgedPush(
            vaultId: vaultId,
            expected: expected,
            receipt: receipts[expected.opId],
          );
          continue;
        }
        if (current.vaultId != vaultId ||
            current.instanceId != expected.instanceId ||
            current.serverSpaceId != expected.serverSpaceId ||
            current.status != 'sent' ||
            current.envelopeJson != expected.envelopeJson ||
            current.recordId != expected.recordId ||
            current.baseRevisionId != expected.baseRevisionId) {
          throw StateError(
            'Pending operation ${expected.opId} changed before acknowledgement.',
          );
        }
        final envelope =
            jsonDecode(current.envelopeJson) as Map<String, dynamic>;
        final header = Map<String, dynamic>.from(envelope['header'] as Map);
        final receipt = receipts[current.opId];
        if (header['op_id'] != current.opId ||
            header['record_id'] != current.recordId ||
            header['revision_id'] != receipt?.revisionId ||
            receipt?.opId != current.opId ||
            receipt?.commitSeq.isEmpty == true ||
            !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(receipt!.commitSeq)) {
          throw StateError(
            'Push receipt does not match operation ${current.opId}.',
          );
        }
        currentRows[current.opId] = current;

        final resolution =
            await (select(conflictBranches)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.resolutionOpId.equals(current.opId) &
                      (current.instanceId == null
                          ? row.instanceId.isNull()
                          : row.instanceId.equals(current.instanceId!)) &
                      (current.serverSpaceId == null
                          ? row.serverSpaceId.isNull()
                          : row.serverSpaceId.equals(current.serverSpaceId!)),
                ))
                .getSingleOrNull();
        if (resolution != null) {
          if (resolution.state != 'resolution_pending' ||
              resolution.resolutionRevisionId != receipt.revisionId) {
            throw StateError(
              'Conflict resolution metadata changed before acknowledgement.',
            );
          }
          resolutionRows[current.opId] = resolution;
        }
        final feedResolution =
            await (select(feedConflictResolutions)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.opId.equals(current.opId) &
                      (current.instanceId == null
                          ? row.instanceId.isNull()
                          : row.instanceId.equals(current.instanceId!)) &
                      (current.serverSpaceId == null
                          ? row.serverSpaceId.isNull()
                          : row.serverSpaceId.equals(current.serverSpaceId!)),
                ))
                .getSingleOrNull();
        if (feedResolution != null) {
          if (feedResolution.state != 'awaiting_commit' ||
              feedResolution.resolutionRevisionId != receipt.revisionId) {
            throw StateError(
              'Feed conflict resolution changed before push acknowledgement.',
            );
          }
          feedResolutionRows[current.opId] = feedResolution;
        }
      }

      for (final operation in currentRows.values) {
        final receipt = receipts[operation.opId]!;
        await (update(encryptedRecords)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(operation.recordId) &
                  row.revisionId.equals(receipt.revisionId) &
                  (operation.instanceId == null
                      ? row.instanceId.isNull()
                      : row.instanceId.equals(operation.instanceId!)) &
                  (operation.serverSpaceId == null
                      ? row.serverSpaceId.isNull()
                      : row.serverSpaceId.equals(operation.serverSpaceId!)),
            ))
            .write(
              EncryptedRecordsCompanion(commitSeq: Value(receipt.commitSeq)),
            );
        await (delete(
          pendingOperations,
        )..where((row) => row.opId.equals(operation.opId))).go();
        final resolution = resolutionRows[operation.opId];
        if (resolution != null) {
          await (update(conflictBranches)
                ..where((row) => row.conflictId.equals(resolution.conflictId)))
              .write(
                const ConflictBranchesCompanion(
                  state: Value('resolution_ready'),
                ),
              );
        }
        final feedResolution = feedResolutionRows[operation.opId];
        if (feedResolution != null) {
          final envelope =
              jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
          final header = Map<String, dynamic>.from(envelope['header'] as Map);
          await into(encryptedRecords).insertOnConflictUpdate(
            EncryptedRecordsCompanion.insert(
              vaultId: vaultId,
              recordId: operation.recordId,
              instanceId: Value(operation.instanceId),
              serverSpaceId: Value(operation.serverSpaceId),
              revisionId: receipt.revisionId,
              envelopeJson: operation.envelopeJson,
              isDeleted: Value(header['operation'] == 'delete'),
              commitSeq: Value(receipt.commitSeq),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          await (update(feedConflictResolutions)..where(
                (row) => row.conflictId.equals(feedResolution.conflictId),
              ))
              .write(
                FeedConflictResolutionsCompanion(
                  state: const Value('committed'),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
        }
      }
    });
  }

  /// Persists a chosen conflict branch as a new outbox operation without ever
  /// removing the original encrypted conflict branch from local storage.
  Future<void> queueConflictResolution({
    required String conflictId,
    required String vaultId,
    required String recordId,
    required String? baseRevisionId,
    required Map<String, Object?> envelope,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final encoded = jsonEncode(envelope);
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw const FormatException('Conflict resolution has no signed header.');
    }
    final header = Map<String, dynamic>.from(rawHeader);
    final opId = header['op_id'];
    final revisionId = header['revision_id'];
    if (opId is! String ||
        opId.isEmpty ||
        revisionId is! String ||
        revisionId.isEmpty ||
        header['record_id'] != recordId ||
        header['vault_id'] != vaultId) {
      throw const FormatException(
        'Conflict resolution envelope does not match its local context.',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await _ensureRecordNotRedacted(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final conflict =
          await (select(conflictBranches)..where(
                (row) =>
                    row.conflictId.equals(conflictId) &
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(recordId) &
                    (instanceId == null
                        ? row.instanceId.isNull()
                        : row.instanceId.equals(instanceId)) &
                    (serverSpaceId == null
                        ? row.serverSpaceId.isNull()
                        : row.serverSpaceId.equals(serverSpaceId)),
              ))
              .getSingleOrNull();
      if (conflict == null || conflict.state != 'open') {
        throw StateError('Conflict is not ready for local resolution.');
      }
      final feedTarget = await feedConflictResolution(
        conflictId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (feedTarget != null && feedTarget.state != 'needs_review') {
        throw StateError(
          'Conflict already has an active feed resolution target.',
        );
      }
      final remoteEnvelope = jsonDecode(conflict.remoteEnvelopeJson);
      final remoteHeader =
          remoteEnvelope is Map && remoteEnvelope['header'] is Map
          ? Map<String, dynamic>.from(remoteEnvelope['header'] as Map)
          : null;
      final remoteRevisionId = remoteHeader?['revision_id'] as String?;
      if (remoteRevisionId != baseRevisionId) {
        throw StateError(
          'Conflict resolution base no longer matches its remote branch.',
        );
      }

      final active = _filterScopedRows(
        rows:
            await (select(pendingOperations)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.recordId.equals(recordId) &
                      (row.status.equals('queued') |
                          row.status.equals('sent') |
                          row.status.equals('cas_wait')),
                ))
                .get(),
        rowType: 'pending operation',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (active.isNotEmpty) {
        throw StateError(
          'Finish or reconcile newer local edits before resolving this branch.',
        );
      }
      final cached = (await _encryptedRecordsForScope(
        vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      final baseEnvelopeJson = cached?.revisionId == baseRevisionId
          ? cached?.envelopeJson
          : conflict.remoteEnvelopeJson == '{}'
          ? null
          : conflict.remoteEnvelopeJson;

      await into(encryptedRecords).insertOnConflictUpdate(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: revisionId,
          envelopeJson: encoded,
          isDeleted: Value(deleted),
          commitSeq: const Value(null),
          updatedAt: now,
        ),
      );
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: opId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: Value(baseRevisionId),
          baseEnvelopeJson: Value(baseEnvelopeJson),
          envelopeJson: encoded,
          createdAt: now,
        ),
      );
      await (delete(pendingOperations)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.recordId.equals(recordId) &
                row.status.equals('conflict') &
                (instanceId == null
                    ? row.instanceId.isNull()
                    : row.instanceId.equals(instanceId)) &
                (serverSpaceId == null
                    ? row.serverSpaceId.isNull()
                    : row.serverSpaceId.equals(serverSpaceId)),
          ))
          .go();
      await (update(
        conflictBranches,
      )..where((row) => row.conflictId.equals(conflictId))).write(
        ConflictBranchesCompanion(
          state: const Value('resolution_pending'),
          resolutionOpId: Value(opId),
          resolutionRevisionId: Value(revisionId),
        ),
      );
      await into(syncCheckpoints).insertOnConflictUpdate(
        SyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          syncStatus: const Value('pending'),
        ),
      );
    });
  }

  Future<List<ConflictBranche>> pendingConflictResolutions(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => _filterScopedRows(
    rows:
        await (select(conflictBranches)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.state.equals('resolution_ready'),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get(),
    rowType: 'conflict branch',
    rowInstanceId: (row) => row.instanceId,
    rowServerSpaceId: (row) => row.serverSpaceId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );

  Future<void> markConflictResolutionCompleted({
    required String conflictId,
    required String opId,
    required String revisionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    await transaction(() async {
      final row =
          await (select(conflictBranches)..where(
                (item) =>
                    item.conflictId.equals(conflictId) &
                    (instanceId == null
                        ? const Constant(true)
                        : item.instanceId.equals(instanceId)) &
                    (serverSpaceId == null
                        ? const Constant(true)
                        : item.serverSpaceId.equals(serverSpaceId)),
              ))
              .getSingleOrNull();
      if (row == null) {
        throw StateError('Resolved conflict branch is missing locally.');
      }
      if (row.state == 'resolved' &&
          row.resolutionOpId == opId &&
          row.resolutionRevisionId == revisionId) {
        return;
      }
      if (row.state != 'resolution_ready' ||
          row.resolutionOpId != opId ||
          row.resolutionRevisionId != revisionId) {
        throw StateError('Conflict resolution receipt no longer matches.');
      }
      await (update(conflictBranches)..where(
            (item) =>
                item.conflictId.equals(conflictId) &
                (instanceId == null
                    ? const Constant(true)
                    : item.instanceId.equals(instanceId)) &
                (serverSpaceId == null
                    ? const Constant(true)
                    : item.serverSpaceId.equals(serverSpaceId)),
          ))
          .write(const ConflictBranchesCompanion(state: Value('resolved')));
    });
  }

  Future<void> storeRemoteEnvelope({
    required String vaultId,
    required String recordId,
    required String revisionId,
    required Map<String, dynamic> envelope,
    required String commitSeq,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    await _storeRemoteEnvelopeInTransaction(
      vaultId: vaultId,
      recordId: recordId,
      revisionId: revisionId,
      envelope: envelope,
      commitSeq: commitSeq,
      deleted: deleted,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
  });

  Future<Map<String, dynamic>?> redactionProofForRecord({
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String recordId,
  }) async {
    final row =
        await (select(syncRedactions)..where(
              (item) =>
                  item.instanceId.equals(instanceId) &
                  item.serverSpaceId.equals(serverSpaceId) &
                  item.vaultId.equals(vaultId) &
                  item.recordId.equals(recordId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.proofJson);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('Stored redaction proof is malformed.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// Atomically applies an already signature-verified redaction marker before
  /// the caller advances the corresponding change or conflict feed cursor.
  Future<void> applyRecordRedaction({
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String serverGeneration,
    required Map<String, dynamic> proof,
  }) {
    if (proof['instance_id'] != instanceId ||
        proof['server_space_id'] != serverSpaceId ||
        proof['vault_id'] != vaultId) {
      throw const FormatException('Redaction proof scope does not match.');
    }
    return applyRecordRedactions(
      serverGeneration: serverGeneration,
      proofs: [proof],
    );
  }

  Future<void> applyRecordRedactions({
    required String serverGeneration,
    required List<Map<String, dynamic>> proofs,
  }) => transaction(() async {
    for (final proof in proofs) {
      final instanceId = proof['instance_id'];
      final serverSpaceId = proof['server_space_id'];
      final vaultId = proof['vault_id'];
      if (instanceId is! String ||
          serverSpaceId is! String ||
          vaultId is! String) {
        throw const FormatException('Verified redaction proof is malformed.');
      }
      await _applyRecordRedactionInTransaction(
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        serverGeneration: serverGeneration,
        proof: proof,
      );
    }
  });

  Future<void> _applyRecordRedactionInTransaction({
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String serverGeneration,
    required Map<String, dynamic> proof,
    String? preserveSnapshotId,
  }) async {
    final recordId = proof['record_id'];
    final redactionId = proof['redaction_id'];
    final proofJson = canonicalJson(proof);
    if (recordId is! String || redactionId is! String) {
      throw const FormatException('Verified redaction proof is malformed.');
    }
    if (proof['instance_id'] != instanceId ||
        proof['server_space_id'] != serverSpaceId ||
        proof['vault_id'] != vaultId) {
      throw const FormatException('Redaction proof scope does not match.');
    }
    final existing =
        await (select(syncRedactions)..where(
              (row) =>
                  row.instanceId.equals(instanceId) &
                  row.serverSpaceId.equals(serverSpaceId) &
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(recordId),
            ))
            .getSingleOrNull();
    if (existing != null) {
      final decoded = jsonDecode(existing.proofJson);
      if (decoded is! Map ||
          decoded['redaction_id'] != redactionId ||
          decoded['instance_id'] != proof['instance_id'] ||
          decoded['server_space_id'] != proof['server_space_id'] ||
          decoded['vault_id'] != proof['vault_id'] ||
          decoded['record_id'] != proof['record_id'] ||
          decoded['deleted_revision_id'] != proof['deleted_revision_id'] ||
          decoded['deleted_seq'] != proof['deleted_seq'] ||
          decoded['redaction_seq'] != proof['redaction_seq']) {
        throw const FormatException(
          'A record was replayed with a different redaction proof.',
        );
      }
    }

    // Resolve every potentially affected row before the first write. A null
    // provenance pair comes from a pre-v13 database and could belong to this
    // instance, so it must abort the surrounding proof/cursor transaction.
    // Rows whose complete scope belongs to another server are intentionally
    // excluded from this proof's erasure and quarantine set.
    final recordRows =
        await (select(encryptedRecords)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    for (final row in recordRows) {
      _scopeMatchesOrThrow(
        rowType: 'encrypted record',
        rowInstanceId: row.instanceId,
        rowServerSpaceId: row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
    }
    final receiptRows =
        await (select(authenticatedPushReceipts)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    final affectedReceipts = receiptRows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'push receipt',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
        )
        .toList(growable: false);
    final operationRows =
        await (select(pendingOperations)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    final affectedOperations = operationRows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'pending operation',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
        )
        .toList(growable: false);
    final localBranches =
        await (select(conflictBranches)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    final affectedBranches = localBranches
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'conflict branch',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
        )
        .toList(growable: false);
    final resolutionRows =
        await (select(feedConflictResolutions)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    final affectedResolutions = resolutionRows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'feed conflict resolution',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
        )
        .toList(growable: false);
    final feedRows = await (select(
      conflictFeedInbox,
    )..where((row) => row.vaultId.equals(vaultId))).get();
    final affectedFeedRows = <ConflictFeedInboxData>[];
    for (final row in feedRows) {
      final decoded = jsonDecode(row.eventJson);
      if (decoded is! Map || decoded['record_id'] != recordId) continue;
      if (_scopeMatchesOrThrow(
        rowType: 'conflict feed inbox',
        rowInstanceId: row.instanceId,
        rowServerSpaceId: row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )) {
        affectedFeedRows.add(row);
      }
    }
    final jobRows =
        await (select(blobJobs)..where(
              (row) =>
                  row.vaultId.equals(vaultId) & row.recordId.equals(recordId),
            ))
            .get();
    final affectedJobs = jobRows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'attachment job',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
        )
        .toList(growable: false);

    await into(syncRedactions).insertOnConflictUpdate(
      SyncRedactionsCompanion.insert(
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: recordId,
        redactionId: redactionId,
        deletedRevisionId: proof['deleted_revision_id'] as String,
        deletedSeq: proof['deleted_seq'] as String,
        redactionSeq: proof['redaction_seq'] as String,
        proofJson: proofJson,
        serverGeneration: serverGeneration,
        appliedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    await (delete(encryptedRecords)..where(
          (item) =>
              item.vaultId.equals(vaultId) &
              item.recordId.equals(recordId) &
              item.instanceId.equals(instanceId) &
              item.serverSpaceId.equals(serverSpaceId),
        ))
        .go();
    for (final receipt in affectedReceipts) {
      await (delete(
        authenticatedPushReceipts,
      )..where((row) => row.opId.equals(receipt.opId))).go();
    }

    final orderedOperations = affectedOperations.toList()
      ..sort((left, right) {
        final byCreatedAt = left.createdAt.compareTo(right.createdAt);
        return byCreatedAt != 0 ? byCreatedAt : left.opId.compareTo(right.opId);
      });
    final activeDrafts = orderedOperations
        .where((row) => row.status != 'superseded')
        .toList(growable: false);
    for (final operation in activeDrafts) {
      await (update(pendingOperations)..where(
            (row) =>
                row.opId.equals(operation.opId) &
                row.instanceId.equals(instanceId) &
                row.serverSpaceId.equals(serverSpaceId),
          ))
          .write(
            const PendingOperationsCompanion(
              status: Value('redacted'),
              baseEnvelopeJson: Value(null),
            ),
          );
    }

    if (affectedBranches.isEmpty && activeDrafts.isNotEmpty) {
      await into(conflictBranches).insert(
        ConflictBranchesCompanion.insert(
          conflictId: _uuid.v4(),
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          kind: 'record_redacted',
          branchEnvelopeJson: activeDrafts.last.envelopeJson,
          remoteEnvelopeJson: '{}',
          state: const Value('redacted_draft'),
          redactionProofJson: Value(proofJson),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      for (final branch in affectedBranches) {
        await (update(
          conflictBranches,
        )..where((row) => row.conflictId.equals(branch.conflictId))).write(
          ConflictBranchesCompanion(
            kind: const Value('record_redacted'),
            remoteEnvelopeJson: const Value('{}'),
            state: const Value('redacted_draft'),
            resolutionOpId: const Value(null),
            resolutionRevisionId: const Value(null),
            redactionProofJson: Value(proofJson),
          ),
        );
      }
    }

    for (final resolution in affectedResolutions) {
      await (update(
        feedConflictResolutions,
      )..where((row) => row.conflictId.equals(resolution.conflictId))).write(
        FeedConflictResolutionsCompanion(
          state: const Value('redacted'),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
    }
    for (final row in affectedFeedRows) {
      final safeEvent = <String, Object?>{
        'seq': row.seq,
        'type': 'redacted',
        'conflict_id': row.conflictId,
        'record_id': recordId,
        'redaction': proof,
      };
      await (update(conflictFeedInbox)..where(
            (item) =>
                item.vaultId.equals(row.vaultId) &
                item.serverGeneration.equals(row.serverGeneration) &
                item.partitionId.equals(row.partitionId) &
                item.seq.equals(row.seq),
          ))
          .write(
            ConflictFeedInboxCompanion(
              eventType: Value('redacted'),
              eventJson: Value(canonicalJson(safeEvent)),
            ),
          );
    }

    final jobIds = affectedJobs.map((job) => job.jobId).toList(growable: false);
    if (jobIds.isNotEmpty) {
      await (delete(
        blobJobObjects,
      )..where((row) => row.jobId.isIn(jobIds))).go();
      await (delete(blobJobs)..where((row) => row.jobId.isIn(jobIds))).go();
    }

    // Any unfinished recovery stage may contain stale ciphertext from a
    // pre-redaction snapshot. Discard it atomically, except while applying the
    // just-verified complete stage that supplied this graveyard entry.
    await (delete(syncSnapshotRecoveryItems)..where((row) {
          var predicate =
              row.instanceId.equals(instanceId) &
              row.serverSpaceId.equals(serverSpaceId) &
              row.vaultId.equals(vaultId);
          if (preserveSnapshotId != null) {
            predicate =
                predicate & row.snapshotId.isNotValue(preserveSnapshotId);
          }
          return predicate;
        }))
        .go();
    await (delete(syncSnapshotRecoveryCursors)..where((row) {
          var predicate =
              row.instanceId.equals(instanceId) &
              row.serverSpaceId.equals(serverSpaceId) &
              row.vaultId.equals(vaultId);
          if (preserveSnapshotId != null) {
            predicate =
                predicate & row.snapshotId.isNotValue(preserveSnapshotId);
          }
          return predicate;
        }))
        .go();
    await (delete(syncSnapshotRecoveryStages)..where((row) {
          var predicate =
              row.instanceId.equals(instanceId) &
              row.serverSpaceId.equals(serverSpaceId) &
              row.vaultId.equals(vaultId);
          if (preserveSnapshotId != null) {
            predicate =
                predicate & row.snapshotId.isNotValue(preserveSnapshotId);
          }
          return predicate;
        }))
        .go();
  }

  /// Atomically abandons one restore operation that the server definitively
  /// rejected as past its retention window and reinstalls the already
  /// signature-verified current tombstone. This never removes a later local
  /// edit or a different outbox operation for the record.
  Future<bool> rejectExpiredRestoreAndInstallServerTombstone({
    required String vaultId,
    required String recordId,
    required String restoreOpId,
    required String restoreRevisionId,
    required String tombstoneRevisionId,
    required Map<String, dynamic> tombstoneEnvelope,
    required String tombstoneCommitSeq,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (!_canonicalObjectReference.hasMatch(vaultId) ||
        !_canonicalObjectReference.hasMatch(recordId) ||
        !_canonicalObjectReference.hasMatch(restoreOpId) ||
        !_canonicalObjectReference.hasMatch(restoreRevisionId) ||
        !_canonicalObjectReference.hasMatch(tombstoneRevisionId)) {
      return false;
    }
    _compareDecimalSeq(tombstoneCommitSeq, '0');
    final operation =
        await (select(pendingOperations)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.recordId.equals(recordId) &
                  row.opId.equals(restoreOpId),
            ))
            .getSingleOrNull();
    if (operation == null ||
        operation.instanceId != instanceId ||
        operation.serverSpaceId != serverSpaceId ||
        !{'queued', 'sent', 'cas_wait'}.contains(operation.status) ||
        operation.baseRevisionId != tombstoneRevisionId ||
        operation.baseEnvelopeJson == null) {
      return false;
    }
    final decodedOperation = jsonDecode(operation.envelopeJson);
    final decodedBase = jsonDecode(operation.baseEnvelopeJson!);
    if (decodedOperation is! Map ||
        decodedOperation['header'] is! Map ||
        decodedBase is! Map ||
        decodedBase['header'] is! Map) {
      return false;
    }
    final restoreHeader = Map<String, dynamic>.from(
      decodedOperation['header'] as Map,
    );
    final tombstoneHeader = Map<String, dynamic>.from(
      decodedBase['header'] as Map,
    );
    if (restoreHeader['vault_id'] != vaultId ||
        restoreHeader['record_id'] != recordId ||
        restoreHeader['op_id'] != restoreOpId ||
        restoreHeader['revision_id'] != restoreRevisionId ||
        restoreHeader['operation'] != 'restore' ||
        restoreHeader['base_revision_id'] != tombstoneRevisionId ||
        tombstoneHeader['vault_id'] != vaultId ||
        tombstoneHeader['record_id'] != recordId ||
        tombstoneHeader['revision_id'] != tombstoneRevisionId ||
        tombstoneHeader['operation'] != 'delete' ||
        canonicalJson(decodedBase) != canonicalJson(tombstoneEnvelope)) {
      return false;
    }
    final current = (await _encryptedRecordsForScope(
      vaultId,
      recordId: recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    )).firstOrNull;
    if (current == null ||
        current.revisionId != restoreRevisionId ||
        current.commitSeq != null ||
        current.isDeleted ||
        current.envelopeJson != operation.envelopeJson) {
      return false;
    }
    final otherOperations = _filterScopedRows(
      rows:
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(recordId) &
                    row.opId.isNotValue(restoreOpId) &
                    row.status.isNotValue('superseded'),
              ))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (otherOperations.isNotEmpty) return false;

    await (delete(
      pendingOperations,
    )..where((row) => row.opId.equals(restoreOpId))).go();
    await _storeRemoteEnvelopeInTransaction(
      vaultId: vaultId,
      recordId: recordId,
      revisionId: tombstoneRevisionId,
      envelope: tombstoneEnvelope,
      commitSeq: tombstoneCommitSeq,
      deleted: true,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return true;
  });

  /// Stores a pulled head only when no local operation for the record has
  /// appeared since the caller inspected the outbox. The check and cache
  /// update share one transaction with [putLocalOperation], so another Web
  /// tab cannot have its optimistic head overwritten between those steps.
  /// Returns false when the caller must re-read the outbox and reconcile the
  /// event through the normal local-change path.
  Future<bool> storeRemoteEnvelopeIfNoPendingOperation({
    required String vaultId,
    required String recordId,
    required String revisionId,
    required Map<String, dynamic> envelope,
    required String commitSeq,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final localOperations = _filterScopedRows(
      rows:
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(recordId) &
                    (row.status.equals('queued') |
                        row.status.equals('sent') |
                        row.status.equals('cas_wait')),
              ))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (localOperations.isNotEmpty) return false;
    await _storeRemoteEnvelopeInTransaction(
      vaultId: vaultId,
      recordId: recordId,
      revisionId: revisionId,
      envelope: envelope,
      commitSeq: commitSeq,
      deleted: deleted,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return true;
  });

  Future<void> _storeRemoteEnvelopeInTransaction({
    required String vaultId,
    required String recordId,
    required String revisionId,
    required Map<String, dynamic> envelope,
    required String commitSeq,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    _compareDecimalSeq(commitSeq, '0');
    await _ensureRecordNotRedacted(
      vaultId,
      recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final incomingCanonicalEnvelope = canonicalJson(envelope);
    final current = (await _encryptedRecordsForScope(
      vaultId,
      recordId: recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    )).firstOrNull;
    if (current?.commitSeq != null) {
      final sequenceOrder = _compareDecimalSeq(current!.commitSeq!, commitSeq);
      if (sequenceOrder > 0) return;
      if (sequenceOrder == 0) {
        if (current.revisionId != revisionId ||
            current.isDeleted != deleted ||
            !_hasCanonicalJson(
              current.envelopeJson,
              incomingCanonicalEnvelope,
            )) {
          throw const FormatException(
            'Conflicting remote envelopes share one commit sequence.',
          );
        }
        return;
      }
    }
    _checkRecordScopeCollision(
      current,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    await into(encryptedRecords).insertOnConflictUpdate(
      EncryptedRecordsCompanion.insert(
        vaultId: vaultId,
        recordId: recordId,
        instanceId: Value(instanceId),
        serverSpaceId: Value(serverSpaceId),
        revisionId: revisionId,
        envelopeJson: jsonEncode(envelope),
        isDeleted: Value(deleted),
        commitSeq: Value(commitSeq),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _validateOptionalSyncScope(String? instanceId, String? serverSpaceId) {
    if (instanceId == null && serverSpaceId == null) return;
    if (instanceId == null ||
        serverSpaceId == null ||
        instanceId.isEmpty ||
        serverSpaceId.isEmpty) {
      throw ArgumentError(
        'Sync provenance must include both non-empty instance and server-space IDs.',
      );
    }
  }

  bool _scopeMatchesOrThrow({
    required String rowType,
    required String? rowInstanceId,
    required String? rowServerSpaceId,
    required String instanceId,
    required String serverSpaceId,
  }) {
    if (rowInstanceId == null ||
        rowServerSpaceId == null ||
        rowInstanceId.isEmpty ||
        rowServerSpaceId.isEmpty) {
      throw StateError(
        'Cannot apply a record redaction because a matching legacy $rowType row has ambiguous server provenance.',
      );
    }
    return rowInstanceId == instanceId && rowServerSpaceId == serverSpaceId;
  }

  List<T> _filterScopedRows<T>({
    required Iterable<T> rows,
    required String rowType,
    required String? Function(T) rowInstanceId,
    required String? Function(T) rowServerSpaceId,
    required String? instanceId,
    required String? serverSpaceId,
  }) {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (instanceId == null) return rows.toList(growable: false);
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: rowType,
            rowInstanceId: rowInstanceId(row),
            rowServerSpaceId: rowServerSpaceId(row),
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  void _checkRecordScopeCollision(
    EncryptedRecord? existing, {
    String? instanceId,
    String? serverSpaceId,
  }) {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (existing == null || instanceId == null || serverSpaceId == null) {
      return;
    }
    if (existing.instanceId == null || existing.serverSpaceId == null) {
      throw StateError(
        'The local record has legacy unknown server provenance; synchronize or resolve it before writing.',
      );
    }
    // A row already scoped to another instance is independent data. It is
    // preserved beside this scope under the composite cache key.
  }

  Future<void> _ensureRecordNotRedacted(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final query = select(syncRedactions)
      ..where(
        (row) =>
            row.vaultId.equals(vaultId) &
            row.recordId.equals(recordId) &
            (instanceId == null
                ? const Constant(true)
                : row.instanceId.equals(instanceId)) &
            (serverSpaceId == null
                ? const Constant(true)
                : row.serverSpaceId.equals(serverSpaceId)),
      );
    final redaction = await query.getSingleOrNull();
    if (redaction != null) {
      throw StateError(
        'This record ID is guarded by a locally verified redaction proof and cannot be recreated or uploaded.',
      );
    }
  }

  Future<List<EncryptedRecord>> cachedEnvelopes(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => _encryptedRecordsForScope(
    vaultId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );

  Future<EncryptedRecord?> cachedEnvelope(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => (await _encryptedRecordsForScope(
    vaultId,
    recordId: recordId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  )).firstOrNull;

  Future<List<EncryptedRecord>> _encryptedRecordsForScope(
    String vaultId, {
    String? recordId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(encryptedRecords)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  (recordId == null
                      ? const Constant(true)
                      : row.recordId.equals(recordId)),
            ))
            .get();
    if (instanceId == null) {
      final scopes = rows
          .map((row) => (row.instanceId, row.serverSpaceId))
          .toSet();
      if (scopes.length > 1) {
        throw StateError(
          'Cache read is ambiguous across server scopes; specify instance provenance.',
        );
      }
      return rows;
    }
    return rows
        .where(
          (row) => _scopeMatchesOrThrow(
            rowType: 'encrypted record',
            rowInstanceId: row.instanceId,
            rowServerSpaceId: row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId!,
          ),
        )
        .toList(growable: false);
  }

  /// Atomically replaces one Vault's committed cache, reconciles the current
  /// outbox against snapshot heads, and advances its cursor/generation.
  /// Other Vaults and device sequence rows are deliberately untouched.
  Future<SnapshotApplyResult> applyVaultSnapshot({
    required String vaultId,
    required List<SnapshotHead> heads,
    required String? cursor,
    required String serverGeneration,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final headsById = {
      for (final head in heads)
        if (!head.isGraveyard) head.recordId: head,
    };
    final redactedRecordIds = <String>{};
    await _rejectSnapshotLiveHeadsWithRedactionProof(
      vaultId: vaultId,
      liveRecordIds: headsById.keys.toSet(),
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final existingCacheRows = await (select(
      encryptedRecords,
    )..where((row) => row.vaultId.equals(vaultId))).get();
    for (final row in existingCacheRows) {
      if (!headsById.containsKey(row.recordId)) continue;
      if (instanceId == null) {
        if (row.instanceId != null || row.serverSpaceId != null) {
          throw StateError(
            'Snapshot has no authenticated provenance and cannot replace a scoped cache row.',
          );
        }
      } else {
        _scopeMatchesOrThrow(
          rowType: 'encrypted record',
          rowInstanceId: row.instanceId,
          rowServerSpaceId: row.serverSpaceId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId!,
        );
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final conflictIds = <String>[];

    await (delete(encryptedRecords)..where(
          (row) =>
              row.vaultId.equals(vaultId) &
              (instanceId == null
                  ? row.instanceId.isNull()
                  : row.instanceId.equals(instanceId)) &
              (serverSpaceId == null
                  ? row.serverSpaceId.isNull()
                  : row.serverSpaceId.equals(serverSpaceId)),
        ))
        .go();
    for (final head in heads) {
      if (head.isGraveyard) {
        final proof = head.redactionProof!;
        redactedRecordIds.add(head.recordId);
        await _applyRecordRedactionInTransaction(
          instanceId: proof['instance_id'] as String,
          serverSpaceId: proof['server_space_id'] as String,
          vaultId: vaultId,
          serverGeneration: serverGeneration,
          proof: proof,
        );
        continue;
      }
      await into(encryptedRecords).insert(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: head.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: head.revisionId,
          envelopeJson: jsonEncode(head.envelope),
          isDeleted: Value(head.deleted),
          commitSeq: Value(head.commitSeq),
          updatedAt: now,
        ),
      );
    }

    final pending = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final pendingBefore = {
      for (final item in pending)
        item.opId: (item.envelopeJson, item.baseRevisionId, item.recordId),
    };

    final operationsByRecord = <String, List<PendingOperation>>{};
    for (final operation in pending) {
      operationsByRecord
          .putIfAbsent(operation.recordId, () => <PendingOperation>[])
          .add(operation);
    }
    for (final entry in operationsByRecord.entries) {
      final operations = entry.value;
      final active = operations
          .where(
            (operation) =>
                operation.status == 'queued' ||
                operation.status == 'sent' ||
                operation.status == 'cas_wait',
          )
          .toList(growable: false);
      if (active.isEmpty) continue;
      if (redactedRecordIds.contains(entry.key)) continue;

      final remote = headsById[entry.key];
      var committedThrough = -1;
      var reusedIdentifierWithDifferentEnvelope = false;
      if (remote != null) {
        final remoteHeader = Map<String, dynamic>.from(
          remote.envelope['header'] as Map,
        );
        for (var index = 0; index < active.length; index++) {
          final envelope =
              jsonDecode(active[index].envelopeJson) as Map<String, dynamic>;
          final header = Map<String, dynamic>.from(envelope['header'] as Map);
          if (header['op_id'] == remoteHeader['op_id'] &&
              header['revision_id'] == remote.revisionId) {
            if (canonicalJson(envelope) == canonicalJson(remote.envelope)) {
              committedThrough = index;
            } else {
              reusedIdentifierWithDifferentEnvelope = true;
            }
          }
        }
      }

      if (committedThrough >= 0) {
        for (final operation in active.take(committedThrough + 1)) {
          await (delete(
            pendingOperations,
          )..where((row) => row.opId.equals(operation.opId))).go();
        }
      }
      final remaining = committedThrough >= 0
          ? active.skip(committedThrough + 1).toList(growable: false)
          : active;
      if (remaining.isEmpty) continue;

      final first = remaining.first;
      final sameBase =
          !reusedIdentifierWithDifferentEnvelope &&
          first.baseRevisionId == remote?.revisionId;
      final latest = remaining.last;
      final latestEnvelope =
          jsonDecode(latest.envelopeJson) as Map<String, dynamic>;
      if (sameBase) {
        final latestHeader = Map<String, dynamic>.from(
          latestEnvelope['header'] as Map,
        );
        await into(encryptedRecords).insertOnConflictUpdate(
          EncryptedRecordsCompanion.insert(
            vaultId: vaultId,
            recordId: latest.recordId,
            revisionId: latestHeader['revision_id'] as String,
            envelopeJson: latest.envelopeJson,
            isDeleted: Value(latestHeader['operation'] == 'delete'),
            commitSeq: const Value(null),
            updatedAt: now,
          ),
        );
        continue;
      }

      // The local branch is now based on an obsolete head. Keep every original
      // operation and its CAS base, but prevent the stale branch from being
      // pushed as a main-head update. The newest signed local revision is the
      // displayed conflict branch; the verified snapshot head remains visible.
      final localConflictId = _uuid.v4();
      final localHeader = Map<String, dynamic>.from(
        latestEnvelope['header'] as Map,
      );
      final remoteEnvelope = remote?.envelope ?? <String, dynamic>{};
      final remoteDeleted = remote?.deleted ?? false;
      final kind = reusedIdentifierWithDifferentEnvelope
          ? 'id_reuse'
          : localHeader['operation'] == 'delete' || remoteDeleted
          ? 'delete_edit'
          : remote == null
          ? 'remote_delete'
          : 'concurrent_edit';
      await into(conflictBranches).insert(
        ConflictBranchesCompanion.insert(
          conflictId: localConflictId,
          vaultId: vaultId,
          recordId: latest.recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          kind: kind,
          branchEnvelopeJson: latest.envelopeJson,
          remoteEnvelopeJson: jsonEncode(remoteEnvelope),
          state: const Value('upload_pending'),
          createdAt: now,
        ),
      );
      conflictIds.add(localConflictId);
      for (final operation in remaining) {
        await (update(pendingOperations)
              ..where((row) => row.opId.equals(operation.opId)))
            .write(const PendingOperationsCompanion(status: Value('conflict')));
      }
    }

    // Ensure the outbox used above was the same immutable set read at the
    // transaction boundary. A concurrent writer must abort this transaction.
    final pendingAfter = await allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final item in pendingAfter) {
      final previous = pendingBefore[item.opId];
      if (previous == null ||
          previous.$1 != item.envelopeJson ||
          previous.$2 != item.baseRevisionId ||
          previous.$3 != item.recordId) {
        throw StateError('Outbox changed while applying a snapshot.');
      }
    }

    await into(syncCheckpoints).insertOnConflictUpdate(
      SyncCheckpointsCompanion.insert(
        vaultId: vaultId,
        instanceId: Value(instanceId ?? ''),
        serverSpaceId: Value(serverSpaceId ?? ''),
        cursor: Value(cursor),
        serverGeneration: Value(serverGeneration),
        syncStatus: const Value('idle'),
        lastSuccessAt: Value(now),
      ),
    );
    return SnapshotApplyResult(localConflictIds: conflictIds);
  });

  Future<void> markSnapshotConflictUploaded({
    required String localConflictId,
    required String serverConflictId,
  }) async {
    await transaction(() async {
      final row =
          await (select(conflictBranches)
                ..where((item) => item.conflictId.equals(localConflictId)))
              .getSingleOrNull();
      if (row == null) return;
      if (localConflictId != serverConflictId) {
        await (delete(
          conflictBranches,
        )..where((item) => item.conflictId.equals(localConflictId))).go();
        await into(conflictBranches).insertOnConflictUpdate(
          ConflictBranchesCompanion.insert(
            conflictId: serverConflictId,
            vaultId: row.vaultId,
            recordId: row.recordId,
            instanceId: Value(row.instanceId),
            serverSpaceId: Value(row.serverSpaceId),
            kind: row.kind,
            branchEnvelopeJson: row.branchEnvelopeJson,
            remoteEnvelopeJson: row.remoteEnvelopeJson,
            state: const Value('open'),
            resolutionOpId: Value(row.resolutionOpId),
            resolutionRevisionId: Value(row.resolutionRevisionId),
            createdAt: row.createdAt,
          ),
        );
      } else {
        await (update(conflictBranches)
              ..where((item) => item.conflictId.equals(localConflictId)))
            .write(const ConflictBranchesCompanion(state: Value('open')));
      }
    });
  }

  Future<List<ConflictBranche>> pendingConflictUploads(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => _filterScopedRows(
    rows:
        await (select(conflictBranches)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.state.equals('upload_pending'),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get(),
    rowType: 'conflict branch',
    rowInstanceId: (row) => row.instanceId,
    rowServerSpaceId: (row) => row.serverSpaceId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );

  Future<void> saveCheckpoint({
    required String vaultId,
    required String? cursor,
    required String serverGeneration,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    await into(syncCheckpoints).insertOnConflictUpdate(
      SyncCheckpointsCompanion.insert(
        vaultId: vaultId,
        instanceId: Value(instanceId ?? ''),
        serverSpaceId: Value(serverSpaceId ?? ''),
        cursor: Value(cursor),
        serverGeneration: Value(serverGeneration),
        syncStatus: const Value('idle'),
        lastSuccessAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Advances the ordinary changes cursor only if the checkpoint read before
  /// the page request is still current. Separate Web tabs have independent
  /// SyncRepository queues but share this database; this compare-and-set keeps
  /// a slower page response from overwriting a checkpoint another tab saved.
  Future<bool> saveCheckpointIfCurrent({
    required String vaultId,
    required String? expectedCursor,
    required String? expectedServerGeneration,
    required String? cursor,
    required String serverGeneration,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final current = await checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (current?.cursor == cursor &&
        current?.serverGeneration == serverGeneration) {
      await saveCheckpoint(
        vaultId: vaultId,
        cursor: cursor,
        serverGeneration: serverGeneration,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      return true;
    }
    if (current?.cursor != expectedCursor ||
        current?.serverGeneration != expectedServerGeneration) {
      return false;
    }
    await saveCheckpoint(
      vaultId: vaultId,
      cursor: cursor,
      serverGeneration: serverGeneration,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return true;
  });

  Future<SyncCheckpoint?> checkpoint(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    return (select(syncCheckpoints)..where(
          (row) =>
              row.vaultId.equals(vaultId) &
              row.instanceId.equals(instanceId ?? '') &
              row.serverSpaceId.equals(serverSpaceId ?? ''),
        ))
        .getSingleOrNull();
  }

  Future<LockedSyncCheckpoint> ensureLockedSyncCheckpoint({
    required String vaultId,
    required String serverGeneration,
    required String? initialCursor,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final current =
        await (select(lockedSyncCheckpoints)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (current == null) {
      await into(lockedSyncCheckpoints).insert(
        LockedSyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          serverGeneration: serverGeneration,
          cursor: Value(initialCursor),
        ),
      );
    } else if (current.serverGeneration != serverGeneration) {
      await (delete(lockedSyncInboxPages)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.instanceId.equals(instanceId ?? '') &
                row.serverSpaceId.equals(serverSpaceId ?? ''),
          ))
          .go();
      await (update(lockedSyncCheckpoints)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.instanceId.equals(instanceId ?? '') &
                row.serverSpaceId.equals(serverSpaceId ?? ''),
          ))
          .write(
            LockedSyncCheckpointsCompanion(
              serverGeneration: Value(serverGeneration),
              cursor: const Value(null),
              nextPageIndex: const Value(0),
            ),
          );
    }
    return (await (select(lockedSyncCheckpoints)..where(
          (row) =>
              row.vaultId.equals(vaultId) &
              row.instanceId.equals(instanceId ?? '') &
              row.serverSpaceId.equals(serverSpaceId ?? ''),
        ))
        .getSingle());
  });

  Future<List<LockedSyncInboxPage>> readLockedSyncInboxPages({
    required String vaultId,
    required String serverGeneration,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    return (select(lockedSyncInboxPages)
          ..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.instanceId.equals(instanceId ?? '') &
                row.serverSpaceId.equals(serverSpaceId ?? '') &
                row.serverGeneration.equals(serverGeneration),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.pageIndex)]))
        .get();
  }

  /// Persists a fully verified page and advances only the locked receiver's
  /// cursor in one transaction. A replayed or stale page cannot advance it.
  Future<bool> stageLockedSyncPage({
    required String vaultId,
    required String serverGeneration,
    required int expectedPageIndex,
    required String? expectedCursor,
    required String? nextCursor,
    required bool hasMore,
    required bool hasEvents,
    required String eventsJson,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final checkpoint =
        await (select(lockedSyncCheckpoints)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (checkpoint == null ||
        checkpoint.serverGeneration != serverGeneration ||
        checkpoint.nextPageIndex != expectedPageIndex ||
        checkpoint.cursor != expectedCursor) {
      return false;
    }
    if (hasEvents) {
      await into(lockedSyncInboxPages).insert(
        LockedSyncInboxPagesCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          serverGeneration: serverGeneration,
          pageIndex: expectedPageIndex,
          startCursor: Value(expectedCursor),
          nextCursor: Value(nextCursor),
          hasMore: hasMore,
          eventsJson: eventsJson,
        ),
      );
    }
    final cursorChanged = nextCursor != expectedCursor;
    if (!hasEvents && !cursorChanged) return true;
    await (update(lockedSyncCheckpoints)..where(
          (row) =>
              row.vaultId.equals(vaultId) &
              row.instanceId.equals(instanceId ?? '') &
              row.serverSpaceId.equals(serverSpaceId ?? ''),
        ))
        .write(
          LockedSyncCheckpointsCompanion(
            cursor: Value(nextCursor),
            nextPageIndex: Value(
              expectedPageIndex + (hasEvents || cursorChanged ? 1 : 0),
            ),
          ),
        );
    return true;
  });

  /// Completes replay after every event in the staged page has been accepted
  /// by the keyed repository. The main checkpoint advances only if it still
  /// equals this page's starting cursor, so another unlocked tab cannot be
  /// moved backwards by a delayed locked page.
  Future<void> completeLockedSyncInboxPage({
    required LockedSyncInboxPage page,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    final main = await checkpoint(
      page.vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if ((main == null && page.startCursor == null) ||
        (main?.serverGeneration == page.serverGeneration &&
            main?.cursor == page.startCursor)) {
      await saveCheckpoint(
        vaultId: page.vaultId,
        cursor: page.nextCursor,
        serverGeneration: page.serverGeneration,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
    }
    await (delete(lockedSyncInboxPages)..where(
          (row) =>
              row.vaultId.equals(page.vaultId) &
              row.instanceId.equals(instanceId ?? '') &
              row.serverSpaceId.equals(serverSpaceId ?? '') &
              row.serverGeneration.equals(page.serverGeneration) &
              row.pageIndex.equals(page.pageIndex),
        ))
        .go();
  });

  Future<void> finishLockedSyncInboxReplay({
    required String vaultId,
    required String serverGeneration,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    final main = await checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final remaining =
        await (select(lockedSyncInboxPages)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(serverGeneration),
            ))
            .get();
    if (remaining.isEmpty &&
        (main == null || main.serverGeneration == serverGeneration)) {
      await into(lockedSyncCheckpoints).insertOnConflictUpdate(
        LockedSyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          serverGeneration: serverGeneration,
          cursor: Value(
            main?.serverGeneration == serverGeneration ? main?.cursor : null,
          ),
          nextPageIndex: const Value(0),
        ),
      );
    }
  });

  Future<String> conflictFeedCursor(
    String vaultId,
    String serverGeneration, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final state =
        await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    final rows =
        await (select(conflictFeedCheckpoints)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(serverGeneration),
            ))
            .get();
    if (rows.isEmpty) return '0';
    final active = rows.where(
      (row) => row.partitionId == (partitionId ?? state?.partitionId),
    );
    return (active.isNotEmpty ? active.first : rows.last).afterSeq;
  }

  Future<ConflictFeedCheckpoint?> conflictFeedCheckpoint(
    String vaultId,
    String serverGeneration, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final requestedPartition = partitionId;
    final state =
        await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    final selectedPartition =
        requestedPartition ??
        (state?.serverGeneration == serverGeneration
            ? state?.partitionId
            : null);
    if (selectedPartition != null) {
      return (select(conflictFeedCheckpoints)..where(
            (row) =>
                row.vaultId.equals(vaultId) &
                row.instanceId.equals(instanceId ?? '') &
                row.serverSpaceId.equals(serverSpaceId ?? '') &
                row.serverGeneration.equals(serverGeneration) &
                row.partitionId.equals(selectedPartition),
          ))
          .getSingleOrNull();
    }
    return (select(conflictFeedCheckpoints)..where(
          (row) =>
              row.vaultId.equals(vaultId) &
              row.instanceId.equals(instanceId ?? '') &
              row.serverSpaceId.equals(serverSpaceId ?? '') &
              row.serverGeneration.equals(serverGeneration),
        ))
        .getSingleOrNull();
  }

  Future<String?> activeConflictFeedGeneration(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    return (await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull())
        ?.serverGeneration;
  }

  Future<String?> activeConflictFeedPartitionId(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    return (await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull())
        ?.partitionId;
  }

  Future<List<ConflictChangeEvent>> activeConflictFeedInbox(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final state =
        await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (state == null) return const [];
    return listConflictFeedInbox(
      vaultId,
      state.serverGeneration,
      partitionId: state.partitionId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
  }

  Future<List<ConflictChangeEvent>> listConflictFeedInbox(
    String vaultId,
    String serverGeneration, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(conflictFeedInbox)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(serverGeneration),
            ))
            .get();
    final selectedRows = partitionId == null
        ? rows
        : rows.where((row) => row.partitionId == partitionId).toList();
    selectedRows.sort((left, right) => _compareDecimalSeq(left.seq, right.seq));
    return selectedRows
        .map(
          (row) => ConflictChangeEvent.fromJson(
            Map<String, dynamic>.from(jsonDecode(row.eventJson) as Map),
          ),
        )
        .toList(growable: false);
  }

  /// Stores a fully validated feed page and its generation-scoped cursor in
  /// one transaction. Replayed pages are idempotent; conflicting sequence or
  /// conflict/type identities reject the transaction without cursor movement.
  Future<void> saveConflictChangesPage(
    ConflictChangesPage page, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
    Map<String, Map<String, dynamic>> verifiedRedactionProofs = const {},
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    page.validate();
    final redactedEvents = page.events
        .where((event) => event.type == 'redacted')
        .toList(growable: false);
    if (verifiedRedactionProofs.length != redactedEvents.length) {
      throw const FormatException(
        'Conflict feed redaction proofs were not verified as a complete page.',
      );
    }
    for (final event in redactedEvents) {
      final proof = verifiedRedactionProofs[event.seq];
      if (proof == null ||
          proof['record_id'] != event.recordId ||
          (instanceId != null && proof['instance_id'] != instanceId) ||
          (serverSpaceId != null &&
              proof['server_space_id'] != serverSpaceId) ||
          event.redaction == null ||
          canonicalJson(proof) != canonicalJson(event.redaction)) {
        throw const FormatException(
          'Conflict feed redaction proof does not match its event.',
        );
      }
    }
    final selectedPartitionId =
        partitionId ?? 'legacy-${page.serverGeneration}';
    if (selectedPartitionId.isEmpty) {
      throw const FormatException('Conflict feed partition id is empty.');
    }
    await transaction(() async {
      final storedCheckpoint =
          await (select(conflictFeedCheckpoints)..where(
                (row) =>
                    row.vaultId.equals(page.vaultId) &
                    row.instanceId.equals(instanceId ?? '') &
                    row.serverSpaceId.equals(serverSpaceId ?? '') &
                    row.serverGeneration.equals(page.serverGeneration) &
                    row.partitionId.equals(selectedPartitionId),
              ))
              .getSingleOrNull();
      if (storedCheckpoint != null &&
          storedCheckpoint.serverGeneration != page.serverGeneration) {
        throw const FormatException(
          'Conflict feed partition changed server generation.',
        );
      }
      final storedAfter = storedCheckpoint?.afterSeq ?? '0';
      if (page.afterSeq != storedAfter) {
        final pageEndCompare = _compareDecimalSeq(
          page.nextAfterSeq,
          storedAfter,
        );
        if (pageEndCompare > 0) {
          throw const FormatException(
            'Conflict feed checkpoint changed while a page was in flight.',
          );
        }
        for (final event in page.events) {
          await _verifyConflictFeedReplay(
            page,
            event,
            selectedPartitionId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
        }
        return;
      }

      // Erasure/quarantine, proof persistence, inbox projection, and feed
      // cursor activation share this transaction. A crash cannot advance the
      // independent history cursor before the local payload is removed.
      for (final event in redactedEvents) {
        await _applyRecordRedactionInTransaction(
          instanceId: event.redaction!['instance_id']! as String,
          serverSpaceId: event.redaction!['server_space_id']! as String,
          vaultId: page.vaultId,
          serverGeneration: page.serverGeneration,
          proof: verifiedRedactionProofs[event.seq]!,
        );
      }

      for (final event in page.events) {
        final canonicalEvent = event.canonicalEventJson;
        final existingSequence =
            await (select(conflictFeedInbox)..where(
                  (row) =>
                      row.vaultId.equals(page.vaultId) &
                      row.instanceId.equals(instanceId ?? '') &
                      row.serverSpaceId.equals(serverSpaceId ?? '') &
                      row.serverGeneration.equals(page.serverGeneration) &
                      row.partitionId.equals(selectedPartitionId) &
                      row.seq.equals(event.seq),
                ))
                .getSingleOrNull();
        if (existingSequence != null) {
          if (existingSequence.eventJson != canonicalEvent ||
              existingSequence.conflictId != event.conflictId ||
              existingSequence.eventType != event.type) {
            throw const FormatException(
              'Conflict feed sequence was replayed with different content.',
            );
          }
          continue;
        }
        final existingIdentity =
            await (select(conflictFeedInbox)..where(
                  (row) =>
                      row.vaultId.equals(page.vaultId) &
                      row.instanceId.equals(instanceId ?? '') &
                      row.serverSpaceId.equals(serverSpaceId ?? '') &
                      row.serverGeneration.equals(page.serverGeneration) &
                      row.partitionId.equals(selectedPartitionId) &
                      row.conflictId.equals(event.conflictId) &
                      row.eventType.equals(event.type),
                ))
                .getSingleOrNull();
        if (existingIdentity != null) {
          throw const FormatException(
            'Conflict feed repeated a conflict event at a new sequence.',
          );
        }
        await into(conflictFeedInbox).insert(
          ConflictFeedInboxCompanion.insert(
            vaultId: page.vaultId,
            serverGeneration: page.serverGeneration,
            instanceId: Value(instanceId ?? ''),
            serverSpaceId: Value(serverSpaceId ?? ''),
            partitionId: selectedPartitionId,
            seq: event.seq,
            conflictId: event.conflictId,
            eventType: event.type,
            eventJson: canonicalEvent,
          ),
        );
        if (event.type == 'resolved') {
          final localBranch =
              await (select(conflictBranches)..where(
                    (row) =>
                        row.vaultId.equals(page.vaultId) &
                        row.instanceId.equals(instanceId ?? '') &
                        row.serverSpaceId.equals(serverSpaceId ?? '') &
                        row.conflictId.equals(event.conflictId) &
                        row.recordId.equals(event.recordId),
                  ))
                  .getSingleOrNull();
          if (localBranch != null && localBranch.state != 'resolved') {
            // Keep both ciphertexts and the local history row; only retire its
            // open action because the authoritative server feed resolved it.
            await _retireResolvedConflictOutboxChain(localBranch);
            await (update(conflictBranches)..where(
                  (row) =>
                      row.vaultId.equals(page.vaultId) &
                      row.instanceId.equals(instanceId ?? '') &
                      row.serverSpaceId.equals(serverSpaceId ?? '') &
                      row.conflictId.equals(event.conflictId) &
                      row.recordId.equals(event.recordId),
                ))
                .write(
                  const ConflictBranchesCompanion(state: Value('resolved')),
                );
          }
          final target =
              await (select(feedConflictResolutions)..where(
                    (row) =>
                        row.conflictId.equals(event.conflictId) &
                        row.instanceId.equals(instanceId ?? '') &
                        row.serverSpaceId.equals(serverSpaceId ?? ''),
                  ))
                  .getSingleOrNull();
          if (target != null && target.state != 'resolved') {
            await (update(feedConflictResolutions)..where(
                  (row) =>
                      row.conflictId.equals(event.conflictId) &
                      row.instanceId.equals(instanceId ?? '') &
                      row.serverSpaceId.equals(serverSpaceId ?? ''),
                ))
                .write(
                  FeedConflictResolutionsCompanion(
                    state: const Value('resolved'),
                    updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                  ),
                );
          }
        }
      }
      await into(conflictFeedCheckpoints).insertOnConflictUpdate(
        ConflictFeedCheckpointsCompanion.insert(
          vaultId: page.vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          serverGeneration: page.serverGeneration,
          partitionId: selectedPartitionId,
          afterSeq: page.nextAfterSeq,
        ),
      );
      await into(conflictFeedStates).insertOnConflictUpdate(
        ConflictFeedStatesCompanion.insert(
          vaultId: page.vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          serverGeneration: page.serverGeneration,
          partitionId: selectedPartitionId,
        ),
      );
    });
  }

  /// Archives only the conflicted outbox chain represented by a locally stored
  /// branch. The feed event is authoritative that this branch can no longer be
  /// resolved locally, while the signed operations and encrypted branch remain
  /// available as history.
  Future<void> _retireResolvedConflictOutboxChain(
    ConflictBranche conflict,
  ) async {
    Map<String, dynamic> decodeEnvelope(String encoded) {
      final raw = jsonDecode(encoded);
      if (raw is! Map || raw.keys.any((key) => key is! String)) {
        throw const FormatException('Conflict operation envelope is invalid.');
      }
      return Map<String, dynamic>.from(raw);
    }

    Map<String, dynamic> decodeHeader(Map<String, dynamic> envelope) {
      final raw = envelope['header'];
      if (raw is! Map || raw.keys.any((key) => key is! String)) {
        throw const FormatException('Conflict operation header is invalid.');
      }
      return Map<String, dynamic>.from(raw);
    }

    late final Map<String, dynamic> branchEnvelope;
    late final Map<String, dynamic> branchHeader;
    late final String canonicalBranchEnvelope;
    try {
      branchEnvelope = decodeEnvelope(conflict.branchEnvelopeJson);
      branchHeader = decodeHeader(branchEnvelope);
      canonicalBranchEnvelope = canonicalJson(branchEnvelope);
    } on Object {
      return;
    }
    final branchOpId = branchHeader['op_id'];
    if (branchOpId is! String ||
        branchHeader['revision_id'] is! String ||
        branchHeader['vault_id'] != conflict.vaultId ||
        branchHeader['record_id'] != conflict.recordId) {
      return;
    }

    final rows = _filterScopedRows(
      rows:
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(conflict.vaultId) &
                    row.recordId.equals(conflict.recordId) &
                    row.status.equals('conflict'),
              ))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: conflict.instanceId,
      serverSpaceId: conflict.serverSpaceId,
    );
    final anchors = rows.where((row) => row.opId == branchOpId).toList();
    if (anchors.length != 1 ||
        !_hasCanonicalJson(
          anchors.single.envelopeJson,
          canonicalBranchEnvelope,
        )) {
      return;
    }

    final rowsByEnvelope = <String, List<PendingOperation>>{};
    final headersByOpId = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      try {
        final envelope = decodeEnvelope(row.envelopeJson);
        final header = decodeHeader(envelope);
        if (header['op_id'] != row.opId ||
            header['vault_id'] != row.vaultId ||
            header['record_id'] != row.recordId ||
            header['revision_id'] is! String) {
          continue;
        }
        final canonicalEnvelope = canonicalJson(envelope);
        rowsByEnvelope
            .putIfAbsent(canonicalEnvelope, () => <PendingOperation>[])
            .add(row);
        headersByOpId[row.opId] = header;
      } on Object {
        // A malformed unrelated conflict row cannot broaden this retirement.
      }
    }

    final chain = <PendingOperation>[];
    final seen = <String>{};
    var current = anchors.single;
    while (seen.add(current.opId)) {
      chain.add(current);
      final baseRevisionId = current.baseRevisionId;
      final baseEnvelopeJson = current.baseEnvelopeJson;
      if (baseRevisionId == null || baseEnvelopeJson == null) break;
      String canonicalBase;
      try {
        canonicalBase = canonicalJson(jsonDecode(baseEnvelopeJson));
      } on Object {
        break;
      }
      final candidates = (rowsByEnvelope[canonicalBase] ?? const [])
          .where(
            (candidate) =>
                candidate.opId != current.opId &&
                headersByOpId[candidate.opId]?['revision_id'] == baseRevisionId,
          )
          .toList(growable: false);
      if (candidates.length != 1) break;
      current = candidates.single;
    }

    for (final operation in chain) {
      await (update(pendingOperations)..where(
            (row) =>
                row.opId.equals(operation.opId) &
                row.vaultId.equals(conflict.vaultId) &
                row.recordId.equals(conflict.recordId) &
                row.status.equals('conflict') &
                (conflict.instanceId == null
                    ? row.instanceId.isNull()
                    : row.instanceId.equals(conflict.instanceId!)) &
                (conflict.serverSpaceId == null
                    ? row.serverSpaceId.isNull()
                    : row.serverSpaceId.equals(conflict.serverSpaceId!)),
          ))
          .write(const PendingOperationsCompanion(status: Value('superseded')));
    }
  }

  Future<void> _verifyConflictFeedReplay(
    ConflictChangesPage page,
    ConflictChangeEvent event,
    String partitionId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final existing =
        await (select(conflictFeedInbox)..where(
              (row) =>
                  row.vaultId.equals(page.vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(page.serverGeneration) &
                  row.partitionId.equals(partitionId) &
                  row.seq.equals(event.seq),
            ))
            .getSingleOrNull();
    if (existing == null ||
        existing.eventJson != event.canonicalEventJson ||
        existing.conflictId != event.conflictId ||
        existing.eventType != event.type) {
      throw const FormatException(
        'Conflict feed replay does not match the durable inbox.',
      );
    }
  }

  Future<EncryptedRecord?> encryptedRecord(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => (await _encryptedRecordsForScope(
    vaultId,
    recordId: recordId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  )).firstOrNull;

  Future<ConflictChangeEvent?> activeCreatedConflictEvent({
    required String vaultId,
    required String conflictId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final state =
        await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (state == null) return null;
    final row =
        await (select(conflictFeedInbox)..where(
              (item) =>
                  item.vaultId.equals(vaultId) &
                  item.instanceId.equals(instanceId ?? '') &
                  item.serverSpaceId.equals(serverSpaceId ?? '') &
                  item.serverGeneration.equals(state.serverGeneration) &
                  item.partitionId.equals(state.partitionId) &
                  item.conflictId.equals(conflictId) &
                  item.eventType.equals('created'),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return ConflictChangeEvent.fromJson(
      Map<String, dynamic>.from(jsonDecode(row.eventJson) as Map),
    );
  }

  Future<List<FeedConflictResolution>> listFeedConflictResolutions(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => _filterScopedRows(
    rows: await (select(
      feedConflictResolutions,
    )..where((row) => row.vaultId.equals(vaultId))).get(),
    rowType: 'feed conflict resolution',
    rowInstanceId: (row) => row.instanceId,
    rowServerSpaceId: (row) => row.serverSpaceId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );

  Future<List<FeedConflictResolution>> pendingFeedConflictResolutions(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => _filterScopedRows(
    rows:
        await (select(feedConflictResolutions)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) & row.state.equals('committed'),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get(),
    rowType: 'feed conflict resolution',
    rowInstanceId: (row) => row.instanceId,
    rowServerSpaceId: (row) => row.serverSpaceId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );

  Future<Set<String>> pendingFeedConflictOperationIds(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rows =
        await (select(feedConflictResolutions)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.state.equals('awaiting_commit') &
                  row.opId.isNotNull(),
            ))
            .get();
    final scoped = _filterScopedRows(
      rows: rows,
      rowType: 'feed conflict resolution',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return scoped.map((row) => row.opId!).toSet();
  }

  Future<FeedConflictResolution?> feedConflictResolution(
    String conflictId, {
    String? instanceId,
    String? serverSpaceId,
  }) {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    return (select(feedConflictResolutions)..where(
          (row) =>
              row.conflictId.equals(conflictId) &
              (instanceId == null
                  ? const Constant(true)
                  : row.instanceId.equals(instanceId)) &
              (serverSpaceId == null
                  ? const Constant(true)
                  : row.serverSpaceId.equals(serverSpaceId)),
        ))
        .getSingleOrNull();
  }

  /// Atomically stages a newly signed local adoption against the exact cached
  /// head reviewed by the user. The remote branch envelope itself is never
  /// installed as the record head.
  Future<void> stageFeedConflictAdoption({
    required String vaultId,
    required String conflictId,
    required String serverGeneration,
    required String partitionId,
    required String recordId,
    required String? expectedHeadRevisionId,
    required Map<String, Object?> envelope,
    required bool deleted,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw const FormatException('Adopted branch has no signed header.');
    }
    final header = Map<String, dynamic>.from(rawHeader);
    final opId = header['op_id'];
    final revisionId = header['revision_id'];
    if (opId is! String ||
        revisionId is! String ||
        header['vault_id'] != vaultId ||
        header['record_id'] != recordId ||
        header['base_revision_id'] != expectedHeadRevisionId ||
        (header['operation'] == 'delete') != deleted) {
      throw const FormatException(
        'Adoption operation does not match the reviewed record head.',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await _ensureRecordNotRedacted(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      await _requireUnresolvedFeedEvent(
        vaultId: vaultId,
        conflictId: conflictId,
        serverGeneration: serverGeneration,
        partitionId: partitionId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final current = await encryptedRecord(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (current?.revisionId != expectedHeadRevisionId ||
          (current != null && current.commitSeq == null)) {
        throw StateError('Current record head changed before adoption.');
      }
      await _ensureNoActiveRecordOperation(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      await _ensureNoActiveLocalConflictResolution(
        vaultId: vaultId,
        conflictId: conflictId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final target = await feedConflictResolution(
        conflictId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (target != null && target.state != 'needs_review') {
        throw StateError('Conflict already has an active resolution target.');
      }
      final baseEnvelopeJson = current?.envelopeJson;
      await into(pendingOperations).insert(
        PendingOperationsCompanion.insert(
          opId: opId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          baseRevisionId: Value(expectedHeadRevisionId),
          baseEnvelopeJson: Value(baseEnvelopeJson),
          envelopeJson: jsonEncode(envelope),
          createdAt: now,
        ),
      );
      await into(feedConflictResolutions).insertOnConflictUpdate(
        FeedConflictResolutionsCompanion.insert(
          conflictId: conflictId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          opId: Value(opId),
          resolutionRevisionId: revisionId,
          state: 'awaiting_commit',
          createdAt: target?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      await into(syncCheckpoints).insertOnConflictUpdate(
        SyncCheckpointsCompanion.insert(
          vaultId: vaultId,
          instanceId: Value(instanceId ?? ''),
          serverSpaceId: Value(serverSpaceId ?? ''),
          syncStatus: const Value('pending'),
        ),
      );
    });
  }

  /// Records a no-op choice against an already committed current head. This
  /// cannot resolve a feed conflict while the current bytes are only local.
  Future<void> stageFeedConflictRetainCurrent({
    required String vaultId,
    required String conflictId,
    required String serverGeneration,
    required String partitionId,
    required String recordId,
    required String expectedHeadRevisionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await _ensureRecordNotRedacted(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      await _requireUnresolvedFeedEvent(
        vaultId: vaultId,
        conflictId: conflictId,
        serverGeneration: serverGeneration,
        partitionId: partitionId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final current = await encryptedRecord(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (current == null ||
          current.revisionId != expectedHeadRevisionId ||
          current.commitSeq == null) {
        throw StateError(
          'Only the current committed record head can be retained.',
        );
      }
      await _ensureNoActiveRecordOperation(
        vaultId,
        recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      await _ensureNoActiveLocalConflictResolution(
        vaultId: vaultId,
        conflictId: conflictId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final target = await feedConflictResolution(
        conflictId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (target != null && target.state != 'needs_review') {
        throw StateError('Conflict already has an active resolution target.');
      }
      await into(feedConflictResolutions).insertOnConflictUpdate(
        FeedConflictResolutionsCompanion.insert(
          conflictId: conflictId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          opId: const Value(null),
          resolutionRevisionId: expectedHeadRevisionId,
          state: 'committed',
          createdAt: target?.createdAt ?? now,
          updatedAt: now,
        ),
      );
    });
  }

  Future<void> _requireUnresolvedFeedEvent({
    required String vaultId,
    required String conflictId,
    required String serverGeneration,
    required String partitionId,
    required String recordId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final activeState =
        await (select(conflictFeedStates)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? ''),
            ))
            .getSingleOrNull();
    if (activeState?.serverGeneration != serverGeneration ||
        activeState?.partitionId != partitionId) {
      throw StateError('Conflict feed partition changed before resolution.');
    }
    final created =
        await (select(conflictFeedInbox)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(serverGeneration) &
                  row.partitionId.equals(partitionId) &
                  row.conflictId.equals(conflictId) &
                  row.eventType.equals('created'),
            ))
            .getSingleOrNull();
    if (created == null) throw StateError('Conflict is missing from inbox.');
    final event = ConflictChangeEvent.fromJson(
      Map<String, dynamic>.from(jsonDecode(created.eventJson) as Map),
    );
    if (event.recordId != recordId) {
      throw StateError('Conflict record does not match the requested record.');
    }
    final resolved =
        await (select(conflictFeedInbox)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.instanceId.equals(instanceId ?? '') &
                  row.serverSpaceId.equals(serverSpaceId ?? '') &
                  row.serverGeneration.equals(serverGeneration) &
                  row.partitionId.equals(partitionId) &
                  row.conflictId.equals(conflictId) &
                  row.eventType.equals('resolved'),
            ))
            .getSingleOrNull();
    final localTarget = await feedConflictResolution(
      conflictId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (resolved != null || localTarget?.state == 'resolved') {
      throw StateError('Conflict has already been resolved.');
    }
  }

  Future<void> _ensureNoActiveRecordOperation(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final active = _filterScopedRows(
      rows:
          await (select(pendingOperations)..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    row.recordId.equals(recordId) &
                    (row.status.equals('queued') |
                        row.status.equals('sent') |
                        row.status.equals('cas_wait')),
              ))
              .get(),
      rowType: 'pending operation',
      rowInstanceId: (row) => row.instanceId,
      rowServerSpaceId: (row) => row.serverSpaceId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (active.isNotEmpty) {
      throw StateError('Record has another active local operation.');
    }
  }

  Future<void> _ensureNoActiveLocalConflictResolution({
    required String vaultId,
    required String conflictId,
    required String recordId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    final branch =
        await (select(conflictBranches)..where(
              (row) =>
                  row.vaultId.equals(vaultId) &
                  row.conflictId.equals(conflictId) &
                  row.recordId.equals(recordId) &
                  (instanceId == null
                      ? const Constant(true)
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? const Constant(true)
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (branch != null &&
        const {
          'resolution_pending',
          'resolution_ready',
        }.contains(branch.state)) {
      throw StateError(
        'Conflict already has an active local resolution target.',
      );
    }
  }

  Future<bool> markFeedConflictCasRefresh(
    String opId, {
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final target =
        await (select(feedConflictResolutions)..where(
              (row) =>
                  row.opId.equals(opId) &
                  (instanceId == null
                      ? const Constant(true)
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? const Constant(true)
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (target == null || target.state != 'awaiting_commit') return false;
    final operation = await (select(
      pendingOperations,
    )..where((row) => row.opId.equals(opId))).getSingleOrNull();
    if (operation == null || operation.status != 'sent') return false;
    await (update(pendingOperations)..where((row) => row.opId.equals(opId)))
        .write(const PendingOperationsCompanion(status: Value('cas_wait')));
    await (update(
      feedConflictResolutions,
    )..where((row) => row.conflictId.equals(target.conflictId))).write(
      FeedConflictResolutionsCompanion(
        state: const Value('cas_refresh'),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    return true;
  });

  Future<void> markFeedResolutionNeedsReview({
    required String conflictId,
    required String resolutionRevisionId,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    await (update(feedConflictResolutions)..where(
          (row) =>
              row.conflictId.equals(conflictId) &
              row.resolutionRevisionId.equals(resolutionRevisionId) &
              row.state.equals('committed') &
              (instanceId == null
                  ? const Constant(true)
                  : row.instanceId.equals(instanceId)) &
              (serverSpaceId == null
                  ? const Constant(true)
                  : row.serverSpaceId.equals(serverSpaceId)),
        ))
        .write(
          FeedConflictResolutionsCompanion(
            state: const Value('needs_review'),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  Future<void> releaseUnmatchedFeedCasTargets(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    await transaction(() async {
      final targets = _filterScopedRows(
        rows:
            await (select(feedConflictResolutions)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.state.equals('cas_refresh') &
                      row.opId.isNotNull(),
                ))
                .get(),
        rowType: 'feed conflict resolution',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      for (final target in targets) {
        final operation = await (select(
          pendingOperations,
        )..where((row) => row.opId.equals(target.opId!))).getSingleOrNull();
        if (operation?.status == 'cas_wait') {
          await (update(
            pendingOperations,
          )..where((row) => row.opId.equals(target.opId!))).write(
            const PendingOperationsCompanion(status: Value('conflict')),
          );
        }
        await (update(
          feedConflictResolutions,
        )..where((row) => row.conflictId.equals(target.conflictId))).write(
          FeedConflictResolutionsCompanion(
            state: const Value('needs_review'),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      }
    });
  }

  Future<void> markFeedConflictResolved({
    required String conflictId,
    required String resolutionRevisionId,
    String? instanceId,
    String? serverSpaceId,
  }) => transaction(() async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    final target =
        await (select(feedConflictResolutions)..where(
              (row) =>
                  row.conflictId.equals(conflictId) &
                  (instanceId == null
                      ? const Constant(true)
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? const Constant(true)
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .getSingleOrNull();
    if (target == null || target.resolutionRevisionId != resolutionRevisionId) {
      throw StateError('Conflict resolution target changed before completion.');
    }
    if (target.state == 'resolved') return;
    if (target.state != 'committed') {
      throw StateError('Conflict resolution target changed before completion.');
    }

    final changed =
        await (update(feedConflictResolutions)..where(
              (row) =>
                  row.conflictId.equals(conflictId) &
                  row.resolutionRevisionId.equals(resolutionRevisionId) &
                  row.state.equals('committed') &
                  (instanceId == null
                      ? const Constant(true)
                      : row.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? const Constant(true)
                      : row.serverSpaceId.equals(serverSpaceId)),
            ))
            .write(
              FeedConflictResolutionsCompanion(
                state: const Value('resolved'),
                updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
              ),
            );
    if (changed != 1) {
      final latest =
          await (select(feedConflictResolutions)..where(
                (row) =>
                    row.conflictId.equals(conflictId) &
                    (instanceId == null
                        ? const Constant(true)
                        : row.instanceId.equals(instanceId)) &
                    (serverSpaceId == null
                        ? const Constant(true)
                        : row.serverSpaceId.equals(serverSpaceId)),
              ))
              .getSingleOrNull();
      if (latest?.resolutionRevisionId == resolutionRevisionId &&
          latest?.state == 'resolved') {
        return;
      }
      throw StateError('Conflict resolution target changed before completion.');
    }
  });

  Future<void> saveConflict({
    required String conflictId,
    required String vaultId,
    required String recordId,
    required String kind,
    required Map<String, dynamic> branchEnvelope,
    required Map<String, dynamic> remoteEnvelope,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    await into(conflictBranches).insertOnConflictUpdate(
      ConflictBranchesCompanion.insert(
        conflictId: conflictId,
        vaultId: vaultId,
        recordId: recordId,
        instanceId: Value(instanceId),
        serverSpaceId: Value(serverSpaceId),
        kind: kind,
        branchEnvelopeJson: jsonEncode(branchEnvelope),
        remoteEnvelopeJson: jsonEncode(remoteEnvelope),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Durably records a pulled CAS conflict before the pull cursor advances.
  /// The local branch, its queued operations and the remote head are updated in
  /// one transaction so a restart can resume conflict upload safely.
  Future<bool> recordPulledConflict({
    required List<String> conflictedOperationIds,
    required String conflictId,
    required String vaultId,
    required String recordId,
    required String kind,
    required Map<String, dynamic> branchEnvelope,
    required Map<String, dynamic> remoteEnvelope,
    required String remoteRevisionId,
    required String remoteCommitSeq,
    required bool remoteDeleted,
    String? instanceId,
    String? serverSpaceId,
  }) async {
    _validateOptionalSyncScope(instanceId, serverSpaceId);
    if (conflictedOperationIds.isEmpty ||
        conflictedOperationIds.toSet().length !=
            conflictedOperationIds.length) {
      throw const FormatException(
        'Conflict must refer to a unique, non-empty outbox operation set.',
      );
    }
    final branchHeader = branchEnvelope['header'];
    final remoteHeader = remoteEnvelope['header'];
    if (branchHeader is! Map || remoteHeader is! Map) {
      throw const FormatException(
        'Conflict branches must have signed headers.',
      );
    }
    final local = Map<String, dynamic>.from(branchHeader);
    final remote = Map<String, dynamic>.from(remoteHeader);
    if (local['record_id'] != recordId ||
        local['vault_id'] != vaultId ||
        remote['record_id'] != recordId ||
        remote['vault_id'] != vaultId ||
        remote['revision_id'] != remoteRevisionId) {
      throw const FormatException(
        'Conflict metadata does not match its envelopes.',
      );
    }
    _compareDecimalSeq(remoteCommitSeq, '0');
    return transaction(() async {
      final currentHead = (await _encryptedRecordsForScope(
        vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).firstOrNull;
      _checkRecordScopeCollision(
        currentHead,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (currentHead?.commitSeq != null) {
        final sequenceOrder = _compareDecimalSeq(
          currentHead!.commitSeq!,
          remoteCommitSeq,
        );
        if (sequenceOrder > 0) return false;
        if (sequenceOrder == 0) {
          if (currentHead.revisionId != remoteRevisionId ||
              !_hasCanonicalJson(
                currentHead.envelopeJson,
                canonicalJson(remoteEnvelope),
              )) {
            throw const FormatException(
              'Conflicting remote envelopes share one commit sequence.',
            );
          }
          final existingBranches = _filterScopedRows(
            rows:
                await (select(conflictBranches)..where(
                      (row) =>
                          row.vaultId.equals(vaultId) &
                          row.recordId.equals(recordId) &
                          (instanceId == null
                              ? const Constant(true)
                              : row.instanceId.equals(instanceId)) &
                          (serverSpaceId == null
                              ? const Constant(true)
                              : row.serverSpaceId.equals(serverSpaceId)),
                    ))
                    .get(),
            rowType: 'conflict branch',
            rowInstanceId: (row) => row.instanceId,
            rowServerSpaceId: (row) => row.serverSpaceId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          if (existingBranches.any(
            (branch) =>
                branch.state != 'resolved' &&
                _hasCanonicalJson(
                  branch.remoteEnvelopeJson,
                  canonicalJson(remoteEnvelope),
                ),
          )) {
            return false;
          }
        }
      }
      final activeRows = _filterScopedRows(
        rows:
            await (select(pendingOperations)..where(
                  (item) =>
                      item.vaultId.equals(vaultId) &
                      item.recordId.equals(recordId) &
                      (instanceId == null
                          ? const Constant(true)
                          : item.instanceId.equals(instanceId)) &
                      (serverSpaceId == null
                          ? const Constant(true)
                          : item.serverSpaceId.equals(serverSpaceId)) &
                      (item.status.equals('queued') |
                          item.status.equals('sent') |
                          item.status.equals('cas_wait')),
                ))
                .get(),
        rowType: 'pending operation',
        rowInstanceId: (row) => row.instanceId,
        rowServerSpaceId: (row) => row.serverSpaceId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final activeIds = activeRows.map((operation) => operation.opId).toSet();
      if (!activeIds.containsAll(conflictedOperationIds) ||
          !conflictedOperationIds.toSet().containsAll(activeIds)) {
        throw StateError('Outbox changed while recording a pulled conflict.');
      }
      final operations = <PendingOperation>[];
      for (final opId in conflictedOperationIds) {
        final row = await (select(
          pendingOperations,
        )..where((item) => item.opId.equals(opId))).getSingleOrNull();
        if (row == null ||
            row.vaultId != vaultId ||
            row.recordId != recordId ||
            row.instanceId != instanceId ||
            row.serverSpaceId != serverSpaceId ||
            (row.status != 'queued' &&
                row.status != 'sent' &&
                row.status != 'cas_wait')) {
          throw StateError('Outbox changed while recording a pulled conflict.');
        }
        operations.add(row);
      }
      if (!operations.any((operation) => operation.opId == local['op_id'])) {
        throw const FormatException(
          'Conflict branch does not match the local outbox.',
        );
      }
      await into(conflictBranches).insert(
        ConflictBranchesCompanion.insert(
          conflictId: conflictId,
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          kind: kind,
          branchEnvelopeJson: jsonEncode(branchEnvelope),
          remoteEnvelopeJson: jsonEncode(remoteEnvelope),
          state: const Value('upload_pending'),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      for (final operation in operations) {
        await (update(pendingOperations)..where(
              (item) =>
                  item.opId.equals(operation.opId) &
                  (instanceId == null
                      ? item.instanceId.isNull()
                      : item.instanceId.equals(instanceId)) &
                  (serverSpaceId == null
                      ? item.serverSpaceId.isNull()
                      : item.serverSpaceId.equals(serverSpaceId)),
            ))
            .write(const PendingOperationsCompanion(status: Value('conflict')));
        final feedTarget =
            await (select(feedConflictResolutions)..where(
                  (row) =>
                      row.vaultId.equals(vaultId) &
                      row.opId.equals(operation.opId) &
                      (instanceId == null
                          ? const Constant(true)
                          : row.instanceId.equals(instanceId)) &
                      (serverSpaceId == null
                          ? const Constant(true)
                          : row.serverSpaceId.equals(serverSpaceId)),
                ))
                .getSingleOrNull();
        if (feedTarget != null &&
            (feedTarget.state == 'cas_refresh' ||
                feedTarget.state == 'awaiting_commit')) {
          await (update(feedConflictResolutions)..where(
                (row) =>
                    row.conflictId.equals(feedTarget.conflictId) &
                    (instanceId == null
                        ? row.instanceId.isNull()
                        : row.instanceId.equals(instanceId)) &
                    (serverSpaceId == null
                        ? row.serverSpaceId.isNull()
                        : row.serverSpaceId.equals(serverSpaceId)),
              ))
              .write(
                FeedConflictResolutionsCompanion(
                  state: const Value('needs_review'),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
        }
      }
      await into(encryptedRecords).insertOnConflictUpdate(
        EncryptedRecordsCompanion.insert(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: Value(instanceId),
          serverSpaceId: Value(serverSpaceId),
          revisionId: remoteRevisionId,
          envelopeJson: jsonEncode(remoteEnvelope),
          isDeleted: Value(remoteDeleted),
          commitSeq: Value(remoteCommitSeq),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return true;
    });
  }

  Future<void> closeConflict(String conflictId) =>
      (update(conflictBranches)
            ..where((row) => row.conflictId.equals(conflictId)))
          .write(const ConflictBranchesCompanion(state: Value('resolved')));

  Future<List<ConflictBranche>> openConflicts(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) async => _filterScopedRows(
    rows:
        await (select(conflictBranches)
              ..where(
                (row) =>
                    row.vaultId.equals(vaultId) &
                    (row.state.equals('open') |
                        row.state.equals('upload_pending') |
                        row.state.equals('resolution_pending') |
                        row.state.equals('resolution_ready') |
                        row.state.equals('redacted_draft')),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]))
            .get(),
    rowType: 'conflict branch',
    rowInstanceId: (row) => row.instanceId,
    rowServerSpaceId: (row) => row.serverSpaceId,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
  );
}
