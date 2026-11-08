import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:sodium/sodium_sumo.dart';

import '../api/api_client.dart';
import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../storage/client_database.dart';
import 'archive_codec.dart';
import '../l10n/l10n.dart';

const _format = 'atermius-portable-vault-data';
const _version = 1;
const _maxEntries = 100000;
const _maxObjects = 10000;
const _maxSnapshotManifestJsonBytes = 64 * 1024 * 1024;
const _uuid = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

/// Adds validated archive epochs to a live key map without replacing a key.
/// Call only after the archive's database transaction succeeds.
void mergeArchiveEpochKeys({
  required Map<String, Uint8List> current,
  required Map<String, Uint8List> imported,
}) {
  for (final entry in imported.entries) {
    final existing = current[entry.key];
    if (existing != null && !_equalArchiveBytes(existing, entry.value)) {
      throw FormatException(currentL10n.archiveEpochKeyKeyDoesntMatch(entry.key));
    }
  }
  for (final entry in imported.entries) {
    current.putIfAbsent(entry.key, () => Uint8List.fromList(entry.value));
  }
}

bool _equalArchiveBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

Map<String, dynamic> _requireArchiveEnvelope(
  Map<String, dynamic>? envelope,
  String entryKind,
) {
  if (envelope == null) {
    throw FormatException(
      'Portable archive v1 cannot represent redacted $entryKind history.',
    );
  }
  return envelope;
}

class VaultArchiveContext {
  const VaultArchiveContext({
    required this.instanceId,
    required this.serverSpaceId,
    required this.accountId,
    required this.device,
    required this.vault,
    required this.epochKeysByVersion,
  });

  final String instanceId;
  final String serverSpaceId;
  final String accountId;
  final DeviceIdentity device;
  final VaultDescriptor vault;
  final Map<String, Uint8List> epochKeysByVersion;
}

/// Fully validated import material. No database or API mutation occurs until
/// the caller explicitly passes this object to `applyPortableVaultArchive`.
class StagedVaultArchive {
  StagedVaultArchive({
    required this.sourceInstanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.snapshotId,
    required this.highWatermark,
    required this.conflictHighWatermark,
    required this.cursor,
    required this.serverGeneration,
    required this.heads,
    required this.operations,
    required this.conflicts,
    required this.objects,
    required this.sequenceFloors,
    required this.epochKeysByVersion,
    required this.recordCount,
    required this.conflictCount,
  });

  final String sourceInstanceId;
  final String serverSpaceId;
  final String vaultId;
  final String snapshotId;
  final String highWatermark;
  final String conflictHighWatermark;
  final String cursor;
  final String serverGeneration;
  final List<SnapshotHead> heads;
  final List<ArchivePendingOperation> operations;
  final List<ArchiveConflictBranch> conflicts;
  final List<ArchiveObjectBytes> objects;
  final Map<String, int> sequenceFloors;
  final Map<String, Uint8List> epochKeysByVersion;
  final int recordCount;
  final int conflictCount;

  void dispose() {
    for (final key in epochKeysByVersion.values) {
      key.fillRange(0, key.length, 0);
    }
    for (final object in objects) {
      object.bytes.fillRange(0, object.bytes.length, 0);
    }
  }
}

/// Checks the local-only links that have to remain satisfiable when an
/// archive is reopened. The exporter and importer share this validation so a
/// client does not emit an archive that its own strict reader must reject.
class PortableArchiveLocalStateValidator {
  static void validateForRoundTrip({
    required List<ArchivePendingOperation> operations,
    required List<ArchiveConflictBranch> conflicts,
    required Set<String> snapshotRevisionIds,
  }) {
    final operationById = <String, ArchivePendingOperation>{};
    for (final operation in operations) {
      final envelope = PortableVaultArchiveService._decodeObject(
        operation.envelopeJson,
        'outbox envelope',
      );
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final revisionId = header['revision_id'];
      if (header['op_id'] != operation.opId ||
          header['record_id'] != operation.recordId ||
          header['base_revision_id'] != operation.baseRevisionId ||
          revisionId is! String) {
        throw FormatException(currentL10n.theLocalOutboxMetadataDoesntMatch);
      }
      if (!const {'queued', 'sent', 'conflict'}.contains(operation.status)) {
        throw FormatException(currentL10n.theLocalOutboxStateCantSafely);
      }
      PortableVaultArchiveService._canonicalUuid(operation.opId, 'op_id');
      PortableVaultArchiveService._canonicalUuid(
        operation.recordId,
        'record_id',
      );
      PortableVaultArchiveService._canonicalUuid(revisionId, 'revision_id');
      if (operationById.containsKey(operation.opId)) {
        throw FormatException(currentL10n.theLocalOutboxContainsADuplicate);
      }
      operationById[operation.opId] = operation;

      final baseRevisionId = operation.baseRevisionId;
      final baseEnvelopeJson = operation.baseEnvelopeJson;
      if (baseRevisionId == null) {
        if (baseEnvelopeJson != null) {
          throw FormatException(
            currentL10n.theArchiveOutboxBaseEnvelopeIs,
          );
        }
        continue;
      }
      PortableVaultArchiveService._canonicalUuid(
        baseRevisionId,
        'base_revision_id',
      );
      if (baseEnvelopeJson == null) {
        if (!snapshotRevisionIds.contains(baseRevisionId)) {
          throw FormatException(currentL10n.theLocalOutboxBaseRevisionCant);
        }
        continue;
      }
      final baseEnvelope = PortableVaultArchiveService._decodeObject(
        baseEnvelopeJson,
        'outbox base',
      );
      final baseHeader = Map<String, dynamic>.from(
        baseEnvelope['header'] as Map,
      );
      if (baseHeader['record_id'] != operation.recordId ||
          baseHeader['revision_id'] != baseRevisionId) {
        throw FormatException(currentL10n.theLocalOutboxBaseEnvelopeDoesnt);
      }
    }

    final seenConflictIds = <String>{};
    for (final conflict in conflicts) {
      PortableVaultArchiveService._canonicalUuid(
        conflict.conflictId,
        'local conflict_id',
      );
      PortableVaultArchiveService._canonicalUuid(
        conflict.recordId,
        'local conflict record_id',
      );
      if (!seenConflictIds.add(conflict.conflictId) ||
          !const {
            'concurrent_edit',
            'delete_edit',
            'remote_delete',
            'id_reuse',
            'archive_from_other_device',
          }.contains(conflict.kind) ||
          !const {
            'open',
            'upload_pending',
            'resolution_pending',
            'resolution_ready',
            'resolved',
          }.contains(conflict.state)) {
        throw FormatException(currentL10n.aLocalConflictKindStateIs);
      }
      final resolutionOpId = conflict.resolutionOpId;
      final resolutionRevisionId = conflict.resolutionRevisionId;
      final hasResolutionLink =
          resolutionOpId != null && resolutionRevisionId != null;
      if ((resolutionOpId == null) != (resolutionRevisionId == null) ||
          ((conflict.state == 'resolution_pending' ||
                  conflict.state == 'resolution_ready' ||
                  conflict.state == 'resolved') &&
              !hasResolutionLink) ||
          ((conflict.state == 'open' || conflict.state == 'upload_pending') &&
              hasResolutionLink)) {
        throw FormatException(currentL10n.invalidLinkToTheLocalConflict);
      }
      if (resolutionOpId != null) {
        PortableVaultArchiveService._canonicalUuid(
          resolutionOpId,
          'resolution_op_id',
        );
        PortableVaultArchiveService._canonicalUuid(
          resolutionRevisionId!,
          'resolution_revision_id',
        );
        if (conflict.state == 'resolution_pending') {
          final linkedOperation = operationById[resolutionOpId];
          final linkedEnvelope = linkedOperation == null
              ? null
              : PortableVaultArchiveService._decodeObject(
                  linkedOperation.envelopeJson,
                  'outbox envelope',
                );
          final linkedHeader = linkedEnvelope?['header'];
          if (linkedOperation == null ||
              linkedOperation.recordId != conflict.recordId ||
              linkedHeader is! Map ||
              linkedHeader['revision_id'] != resolutionRevisionId) {
            throw FormatException(currentL10n.invalidLocalConflictResolutionOutboxLink);
          }
        }
      }
    }
  }
}

class PortableVaultArchiveService {
  PortableVaultArchiveService({
    required this.sodium,
    required this.api,
    required this.database,
    required this.crypto,
  }) : codec = VaultArchiveCodec(sodium);

  final SodiumSumo sodium;
  final ApiClient api;
  final ClientDatabase database;
  final VaultCrypto crypto;
  final VaultArchiveCodec codec;

  Future<Uint8List> exportArchive({
    required VaultArchiveContext context,
    required String exportPassword,
    void Function(String phase)? onProgress,
  }) async {
    _validateContext(context);
    onProgress?.call(currentL10n.verifyingTheDeviceDirectoryAndSigned);
    final trust = await _loadAndVerifyTrust(context);
    final verifiedEnvelopes = <String>{};
    for (final rawEnvelope in context.vault.keyEnvelopes) {
      final envelope = Map<String, dynamic>.from(rawEnvelope);
      final epoch = _positiveInteger(envelope['key_epoch'], 'key_epoch');
      final membershipVersion = _positiveInteger(
        envelope['membership_version'],
        'membership_version',
      );
      final recipientId = _string(envelope, 'recipient_device_id');
      final signerId = _string(envelope, 'signer_device_id');
      final signerKey = trust.signerKeys[signerId];
      final membership = trust.memberships
          .where((item) => item.version == membershipVersion)
          .firstOrNull;
      if (recipientId != context.device.deviceId ||
          signerKey == null ||
          membership == null ||
          (membership.manifest['key_epoch'] as num?)?.toInt() != epoch ||
          !_isMemberAt(
            trust.memberships,
            trust.directory,
            membershipVersion,
            signerId,
            requireOwner: false,
          )) {
        throw FormatException(currentL10n.theCurrentDevicesKeyEnvelopeSource);
      }
      final opened = await crypto.openVaultKeyEnvelope(
        vaultId: context.vault.id,
        deviceId: context.device.deviceId,
        identity: context.device,
        keyEnvelope: envelope,
        signerPublicKey: signerKey,
      );
      final local = context.epochKeysByVersion['$epoch:$membershipVersion'];
      if (local == null || !_bytesEqual(opened, local)) {
        opened.fillRange(0, opened.length, 0);
        throw FormatException(currentL10n.theUnsealedKeyEnvelopeDoesntMatch);
      }
      opened.fillRange(0, opened.length, 0);
      if (!verifiedEnvelopes.add('$epoch:$membershipVersion')) {
        throw FormatException(currentL10n.duplicateServerKeyEnvelopeContext);
      }
    }
    if (verifiedEnvelopes.length != context.epochKeysByVersion.length) {
      throw FormatException(currentL10n.thisDevicesEpochKeysDontFully);
    }
    onProgress?.call(currentL10n.pinningTheServerHistorySnapshot);
    final created = await api.createSnapshot(context.vault.id);
    final snapshotId = _string(created, 'snapshot_id');
    _canonicalUuid(snapshotId, 'snapshot_id');
    final high = _decimal(created['high_watermark'], 'high_watermark');
    final conflictHigh = _decimal(
      created['conflict_high_watermark'],
      'conflict_high_watermark',
    );
    final cursor = _string(created, 'next_cursor');
    final expiresAt = _string(created, 'expires_at');
    final createdHasItemCount = created.containsKey('item_count');
    final createdItemCount = created['item_count'];
    if (createdHasItemCount &&
        (createdItemCount is! int || createdItemCount < 0)) {
      throw FormatException(currentL10n.invalidServerSnapshotItemCount);
    }
    if (createdItemCount is int && createdItemCount > _maxEntries) {
      throw FormatException(currentL10n.theSnapshotExceedsTheArchiveCapacity);
    }
    final snapshotHeads = await _readAllSnapshotHeads(
      snapshotId: snapshotId,
      highWatermark: high,
      conflictHighWatermark: conflictHigh,
      nextCursor: cursor,
      expiresAt: expiresAt,
      createdHasItemCount: createdHasItemCount,
      createdItemCount: createdItemCount is int ? createdItemCount : null,
    );

    onProgress?.call(currentL10n.readingEveryHistoryPageOfThe);
    final revisions = await _allRevisions(
      context.vault.id,
      snapshotId,
      high,
      conflictHigh,
    );
    final conflicts = await _allConflicts(
      context.vault.id,
      snapshotId,
      high,
      conflictHigh,
    );
    final generation = revisions.serverGeneration;
    if (conflicts.serverGeneration != generation) {
      throw FormatException(currentL10n.theServerGenerationDiffersBetweenRevision);
    }
    _validateSnapshotManifest(
      snapshotHeads,
      revisions.entries,
      highWatermark: high,
    );

    onProgress?.call(currentL10n.verifyingSignaturesKeyEpochsAndObject);
    final epochKeys = _selectEpochKeys(context.epochKeysByVersion);
    final references = <String>{};
    final revisionsJson = <Map<String, Object?>>[];
    final seenRevisions = <String>{};
    final previousByRecord = <String, String?>{};
    BigInt lastCommit = BigInt.zero;
    for (final revision in revisions.entries) {
      final revisionEnvelope = _requireArchiveEnvelope(
        revision.envelope,
        'revision',
      );
      final seq = BigInt.parse(revision.commitSeq);
      if (seq <= lastCommit || seq > BigInt.parse(high)) {
        throw FormatException(currentL10n.revisionCommitSeqIsntMonotonicOr);
      }
      lastCommit = seq;
      _canonicalUuid(revision.recordId, 'record_id');
      _canonicalUuid(revision.revisionId, 'revision_id');
      if (!seenRevisions.add(revision.revisionId)) {
        throw FormatException(currentL10n.theHistorySnapshotContainsADuplicate2);
      }
      if (revision.baseRevisionId != previousByRecord[revision.recordId]) {
        throw FormatException(currentL10n.theBaseRevisionChainForRecord(revision.recordId));
      }
      final payload = await _verifyRecordEnvelope(
        envelope: revisionEnvelope,
        recordId: revision.recordId,
        revisionId: revision.revisionId,
        baseRevisionId: revision.baseRevisionId,
        operation: revision.operation,
        deleted: revision.deleted,
        context: context,
        trust: trust,
        epochKeys: epochKeys,
      );
      references.addAll(payload.$2);
      previousByRecord[revision.recordId] = revision.revisionId;
      revisionsJson.add(revision.toJson());
    }

    final conflictsJson = <Map<String, Object?>>[];
    final seenConflictIds = <String>{};
    BigInt lastConflict = BigInt.zero;
    for (final conflict in conflicts.entries) {
      final seq = BigInt.parse(conflict.conflictSeq);
      if (seq <= lastConflict || seq > BigInt.parse(conflictHigh)) {
        throw FormatException(currentL10n.conflictSeqIsntMonotonicOrExceeds);
      }
      lastConflict = seq;
      _canonicalUuid(conflict.conflictId, 'conflict_id');
      _canonicalUuid(conflict.recordId, 'record_id');
      if (!seenConflictIds.add(conflict.conflictId)) {
        throw FormatException(currentL10n.theHistorySnapshotContainsADuplicate);
      }
      if (conflict.baseRevisionId != null &&
          !seenRevisions.contains(conflict.baseRevisionId)) {
        throw FormatException(currentL10n.aConflictBranchReferencesABase);
      }
      final conflictEnvelope = _requireArchiveEnvelope(
        conflict.envelope,
        'conflict',
      );
      final header = Map<String, dynamic>.from(
        conflictEnvelope['header'] as Map,
      );
      final payload = await _verifyRecordEnvelope(
        envelope: conflictEnvelope,
        recordId: conflict.recordId,
        revisionId: header['revision_id'] as String?,
        baseRevisionId: conflict.baseRevisionId,
        operation: header['operation'] as String?,
        deleted: header['operation'] == 'delete',
        context: context,
        trust: trust,
        epochKeys: epochKeys,
      );
      references.addAll(payload.$2);
      if ((conflict.resolvedRevisionId == null) !=
          (conflict.resolutionSeq == null)) {
        throw FormatException(currentL10n.theConflictResolutionStateAndResolution);
      }
      if (conflict.resolvedRevisionId != null &&
          !seenRevisions.contains(conflict.resolvedRevisionId)) {
        throw FormatException(currentL10n.aConflictResolutionReferencesARevision);
      }
      conflictsJson.add(conflict.toJson());
    }

    final localState = await database.transaction(
      () async => (
        pending: await database.allPendingOperations(
          context.vault.id,
          instanceId: context.instanceId,
          serverSpaceId: context.serverSpaceId,
        ),
        conflicts: await database.allConflictBranches(
          context.vault.id,
          instanceId: context.instanceId,
          serverSpaceId: context.serverSpaceId,
        ),
        sequenceFloors: await database.deviceSequenceFloors(),
      ),
    );
    final pending = localState.pending;
    final localConflicts = localState.conflicts;
    if (pending.length > _maxEntries || localConflicts.length > _maxEntries) {
      throw FormatException(currentL10n.localOutboxConflictsExceedTheArchive);
    }
    PortableArchiveLocalStateValidator.validateForRoundTrip(
      operations: [
        for (final item in pending)
          ArchivePendingOperation(
            opId: item.opId,
            recordId: item.recordId,
            baseRevisionId: item.baseRevisionId,
            baseEnvelopeJson: item.baseEnvelopeJson,
            envelopeJson: item.envelopeJson,
            status: item.status,
            attemptCount: item.attemptCount,
            createdAt: item.createdAt,
            lastAttemptAt: item.lastAttemptAt,
          ),
      ],
      conflicts: [
        for (final item in localConflicts)
          ArchiveConflictBranch(
            conflictId: item.conflictId,
            recordId: item.recordId,
            kind: item.kind,
            branchEnvelopeJson: item.branchEnvelopeJson,
            remoteEnvelopeJson: item.remoteEnvelopeJson,
            state: item.state,
            resolutionOpId: item.resolutionOpId,
            resolutionRevisionId: item.resolutionRevisionId,
            createdAt: item.createdAt,
          ),
      ],
      snapshotRevisionIds: seenRevisions,
    );
    final pendingJson = <Map<String, Object?>>[];
    final pendingOpIds = <String>{};
    final pendingRevisionIds = <String>{};
    for (final item in pending) {
      if (!pendingOpIds.add(item.opId)) {
        throw FormatException(currentL10n.theLocalOutboxContainsADuplicate);
      }
      final envelope = _decodeObject(item.envelopeJson, 'outbox envelope');
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      if (header['op_id'] != item.opId ||
          header['record_id'] != item.recordId ||
          header['base_revision_id'] != item.baseRevisionId) {
        throw FormatException(currentL10n.theLocalOutboxMetadataDoesntMatch);
      }
      _canonicalUuid(item.opId, 'op_id');
      _canonicalUuid(item.recordId, 'record_id');
      final revisionId = header['revision_id'] as String?;
      if (revisionId == null || !pendingRevisionIds.add(revisionId)) {
        throw FormatException(currentL10n.aLocalOutboxRevisionIdIs);
      }
      final payload = await _verifyRecordEnvelope(
        envelope: envelope,
        recordId: item.recordId,
        revisionId: revisionId,
        baseRevisionId: item.baseRevisionId,
        operation: header['operation'] as String?,
        deleted: header['operation'] == 'delete',
        context: context,
        trust: trust,
        epochKeys: epochKeys,
      );
      references.addAll(payload.$2);
      if (item.baseEnvelopeJson != null) {
        final base = _decodeObject(item.baseEnvelopeJson!, 'outbox base');
        final baseHeader = Map<String, dynamic>.from(base['header'] as Map);
        final basePayload = await _verifyRecordEnvelope(
          envelope: base,
          recordId: item.recordId,
          revisionId: item.baseRevisionId,
          baseRevisionId: baseHeader['base_revision_id'] as String?,
          operation: baseHeader['operation'] as String?,
          deleted: baseHeader['operation'] == 'delete',
          context: context,
          trust: trust,
          epochKeys: epochKeys,
        );
        references.addAll(basePayload.$2);
      }
      pendingJson.add({
        'op_id': item.opId,
        'record_id': item.recordId,
        'base_revision_id': item.baseRevisionId,
        'base_envelope': item.baseEnvelopeJson == null
            ? null
            : jsonDecode(item.baseEnvelopeJson!),
        'envelope': envelope,
        'status': item.status,
        'attempt_count': item.attemptCount,
        'created_at': item.createdAt,
        'last_attempt_at': item.lastAttemptAt,
      });
    }

    final localConflictJson = <Map<String, Object?>>[];
    for (final item in localConflicts) {
      final branch = _decodeObject(
        item.branchEnvelopeJson,
        'local conflict branch',
      );
      final branchHeader = Map<String, dynamic>.from(branch['header'] as Map);
      final branchPayload = await _verifyRecordEnvelope(
        envelope: branch,
        recordId: item.recordId,
        revisionId: branchHeader['revision_id'] as String?,
        baseRevisionId: branchHeader['base_revision_id'] as String?,
        operation: branchHeader['operation'] as String?,
        deleted: branchHeader['operation'] == 'delete',
        context: context,
        trust: trust,
        epochKeys: epochKeys,
      );
      references.addAll(branchPayload.$2);
      final remote = _decodeObject(
        item.remoteEnvelopeJson,
        'local conflict remote branch',
      );
      if (remote.isNotEmpty) {
        final remoteHeader = Map<String, dynamic>.from(remote['header'] as Map);
        final remotePayload = await _verifyRecordEnvelope(
          envelope: remote,
          recordId: item.recordId,
          revisionId: remoteHeader['revision_id'] as String?,
          baseRevisionId: remoteHeader['base_revision_id'] as String?,
          operation: remoteHeader['operation'] as String?,
          deleted: remoteHeader['operation'] == 'delete',
          context: context,
          trust: trust,
          epochKeys: epochKeys,
        );
        references.addAll(remotePayload.$2);
      }
      localConflictJson.add({
        'conflict_id': item.conflictId,
        'record_id': item.recordId,
        'kind': item.kind,
        'branch_envelope': branch,
        'remote_envelope': remote,
        'state': item.state,
        'resolution_op_id': item.resolutionOpId,
        'resolution_revision_id': item.resolutionRevisionId,
        'created_at': item.createdAt,
      });
    }

    final latestRevisions = <String, VaultRevisionEntry>{};
    for (final revision in revisions.entries) {
      latestRevisions[revision.recordId] = revision;
    }
    final graveyard =
        snapshotHeads
            .where((head) => head['deleted'] == true)
            .map((head) {
              final recordId = _string(head, 'record_id');
              final revision = latestRevisions[recordId];
              if (revision == null ||
                  revision.revisionId != head['revision_id'] ||
                  revision.operation != 'delete') {
                throw FormatException(currentL10n.theTombstoneGraveyardCouldntBeRebuilt);
              }
              return <String, Object?>{
                'record_id': recordId,
                'deleted_revision': revision.revisionId,
                'deleted_seq': revision.commitSeq,
              };
            })
            .toList(growable: false)
          ..sort(
            (left, right) => (left['record_id'] as String).compareTo(
              right['record_id'] as String,
            ),
          );

    if (references.length > _maxObjects) {
      throw FormatException(currentL10n.theNumberOfEncryptedObjectsReferenced);
    }
    onProgress?.call(currentL10n.collectingAndCheckingEncryptedObjects);
    final objectBlocks = <Uint8List>[];
    final keyBlocks = <Uint8List>[];
    final objectDescriptors = <Map<String, Object?>>[];
    Uint8List? clearPayload;
    var binaryOffset = 0;
    try {
      for (final id in references.toList()..sort()) {
        _canonicalUuid(id, 'object_id');
        Uint8List objectBytes;
        String declaredDigest;
        try {
          final downloaded = await api.downloadObjectWithDigest(
            context.vault.id,
            id,
          );
          objectBytes = downloaded.bytes;
          declaredDigest = downloaded.sha256;
        } on ApiException catch (error) {
          if (error.statusCode != 404) rethrow;
          final local = await database.archiveObject(context.vault.id, id);
          if (local == null) {
            throw FormatException(
              currentL10n.objectIdIsReferencedByVerified(id),
            );
          }
          objectBytes = local.bytes;
          declaredDigest = local.sha256;
        }
        final actualDigest = await _sha256Hex(objectBytes);
        if (actualDigest != declaredDigest) {
          objectBytes.fillRange(0, objectBytes.length, 0);
          throw FormatException(currentL10n.sha256OfObjectIdDoesnt(id));
        }
        objectDescriptors.add({
          'object_id': id,
          'offset': binaryOffset,
          'length': objectBytes.length,
          'sha256': actualDigest,
        });
        objectBlocks.add(objectBytes);
        binaryOffset += objectBytes.length;
      }

      onProgress?.call(currentL10n.encryptedArchiveFile);
      final keyDescriptors = <Map<String, Object?>>[];
      for (final entry
          in context.epochKeysByVersion.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key))) {
        final parsed = _parseEpochKeyName(entry.key);
        final versioned = epochKeys[parsed.$1]!;
        if (versioned.length != 32) {
          throw const FormatException('Vault epoch key must contain 32 bytes.');
        }
        final keyDigest = await _sha256B64(versioned);
        final signedPayload = <String, Object?>{
          'domain': 'atermius-archive-epoch-key-v1',
          'server_space_id': context.serverSpaceId,
          'vault_id': context.vault.id,
          'key_epoch': parsed.$1,
          'membership_version': parsed.$2,
          'key_sha256': keyDigest,
          'signer_device_id': context.device.deviceId,
        };
        final signature = sodium.crypto.sign.detached(
          message: Uint8List.fromList(
            utf8.encode(canonicalJson(signedPayload)),
          ),
          secretKey: context.device.signing.secretKey,
        );
        keyDescriptors.add({
          'key_epoch': parsed.$1,
          'membership_version': parsed.$2,
          'offset': binaryOffset,
          'length': versioned.length,
          'key_sha256': keyDigest,
          'signer_device_id': context.device.deviceId,
          'signature': encodeBase64Url(signature),
        });
        keyBlocks.add(Uint8List.fromList(versioned));
        binaryOffset += versioned.length;
      }
      final blockDescriptors = <Map<String, Object?>>[
        ...objectDescriptors.map((e) => {...e, 'kind': 'object'}),
        ...keyDescriptors.map((e) => {...e, 'kind': 'epoch_key'}),
      ]..sort((a, b) => (a['offset'] as int).compareTo(b['offset'] as int));

      final sequenceFloors = localState.sequenceFloors;
      final archiveDeviceIds = <String>{context.device.deviceId};
      for (final membership in trust.memberships) {
        archiveDeviceIds.add(membership.signerDeviceId);
      }
      for (final envelope in context.vault.keyEnvelopes) {
        final signerId = envelope['signer_device_id'];
        final recipientId = envelope['recipient_device_id'];
        if (signerId is String) archiveDeviceIds.add(signerId);
        if (recipientId is String) archiveDeviceIds.add(recipientId);
      }
      final referencedEnvelopes = <Map<String, dynamic>>[
        ...revisions.entries.map(
          (item) => _requireArchiveEnvelope(item.envelope, 'revision'),
        ),
        ...conflicts.entries.map(
          (item) => _requireArchiveEnvelope(item.envelope, 'conflict'),
        ),
        ...pending.map((item) => _decodeObject(item.envelopeJson, 'outbox')),
        ...localConflicts.map(
          (item) => _decodeObject(item.branchEnvelopeJson, 'local conflict'),
        ),
        ...localConflicts
            .map(
              (item) => _decodeObject(
                item.remoteEnvelopeJson,
                'local conflict remote',
              ),
            )
            .where((envelope) => envelope.isNotEmpty),
      ];
      for (final envelope in referencedEnvelopes) {
        final header = envelope['header'];
        if (header is Map && header['device_id'] is String) {
          archiveDeviceIds.add(header['device_id'] as String);
        }
      }
      final archiveDevices =
          archiveDeviceIds
              .map((id) {
                final device = trust.directory[id];
                if (device == null) {
                  throw FormatException(currentL10n.historicalSigningDeviceIdIsntIn(id));
                }
                // Account and Vault device APIs include operational fields
                // such as revocation and signed capability reports. Archive
                // v1 has a strict, portable device-directory schema; persist
                // only its stable identity and key fields.
                return <String, Object?>{
                  'device_id': _string(device, 'device_id'),
                  'user_id': _string(device, 'user_id'),
                  'name': _string(device, 'name'),
                  'signing_public_key': _string(device, 'signing_public_key'),
                  'encryption_public_key': _string(
                    device,
                    'encryption_public_key',
                  ),
                  'status': _string(device, 'status'),
                  'created_at': _string(device, 'created_at'),
                };
              })
              .toList(growable: false)
            ..sort(
              (a, b) => (a['device_id'] as String).compareTo(
                b['device_id'] as String,
              ),
            );

      final manifest = <String, Object?>{
        'format': _format,
        'version': _version,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'instance_id': context.instanceId,
        'server_space_id': context.serverSpaceId,
        'account_id': context.accountId,
        'vault_id': context.vault.id,
        'vault_role': context.vault.role,
        'name_envelope': context.vault.encryptedDisplayNameEnvelope,
        'snapshot': {
          'snapshot_id': snapshotId,
          'high_watermark': high,
          'conflict_high_watermark': conflictHigh,
          'next_cursor': cursor,
          'server_generation': generation,
        },
        'devices': archiveDevices,
        'membership_chain': trust.rawMemberships,
        'key_envelopes': context.vault.keyEnvelopes,
        'epoch_keys': keyDescriptors,
        'snapshot_heads': snapshotHeads,
        'graveyard': graveyard,
        'revisions': revisionsJson,
        'conflicts': conflictsJson,
        'local_pending': {
          'operations': pendingJson,
          'conflict_branches': localConflictJson,
          'device_sequence_floors': sequenceFloors,
        },
        'binary_blocks': blockDescriptors,
      };
      clearPayload = VaultArchiveCodec.packPayload(
        manifest: manifest,
        objectBytes: [...objectBlocks, ...keyBlocks],
      );
      return await codec.seal(
        password: exportPassword,
        payload: clearPayload,
        serverSpaceId: context.serverSpaceId,
        vaultId: context.vault.id,
      );
    } finally {
      clearPayload?.fillRange(0, clearPayload.length, 0);
      for (final block in objectBlocks) {
        block.fillRange(0, block.length, 0);
      }
      for (final block in keyBlocks) {
        block.fillRange(0, block.length, 0);
      }
    }
  }

  Future<StagedVaultArchive> stageImport({
    required Uint8List container,
    required String exportPassword,
    required VaultArchiveContext target,
    void Function(String phase)? onProgress,
  }) async {
    _validateContext(target);
    onProgress?.call(currentL10n.decryptingTheArchiveContainer);
    final clearPayload = await codec.open(
      password: exportPassword,
      container: container,
      expectedServerSpaceId: target.serverSpaceId,
      expectedVaultId: target.vault.id,
    );
    final stagedEpochKeys = <int, Uint8List>{};
    final stagedEpochKeysByVersion = <String, Uint8List>{};
    final stagedObjects = <ArchiveObjectBytes>[];
    try {
      onProgress?.call(currentL10n.readingTheArchiveManifestAndBinary);
      final unpacked = VaultArchiveCodec.unpackPayload(clearPayload);
      final manifest = unpacked.manifest;
      onProgress?.call(currentL10n.verifyingArchiveFormatAndTarget);
      _validateManifestShape(
        manifest,
        expectedServerSpaceId: target.serverSpaceId,
        expectedVaultId: target.vault.id,
        onProgress: onProgress,
      );
      onProgress?.call(currentL10n.verifyingTheMemberSignatureChainAnd);
      final trust = await _loadArchiveTrust(target, manifest);
      onProgress?.call(currentL10n.verifyingArchiveKeyEnvelopesAndEpoch);
      final snapshot = Map<String, dynamic>.from(manifest['snapshot'] as Map);
      final high = _decimal(snapshot['high_watermark'], 'high_watermark');
      final conflictHigh = _decimal(
        snapshot['conflict_high_watermark'],
        'conflict_high_watermark',
      );
      final snapshotId = _string(snapshot, 'snapshot_id');
      _canonicalUuid(snapshotId, 'snapshot_id');
      final cursor = _string(snapshot, 'next_cursor');
      final generation = _string(snapshot, 'server_generation');
      final rawEpochKeys = manifest['epoch_keys'] as List;
      final blocks = _validateBlocks(
        manifest['binary_blocks'] as List,
        unpacked.objectRegion.length,
      );
      final blockByOffset = {for (final block in blocks) block.offset: block};
      final rawBlocksByOffset = {
        for (final raw in manifest['binary_blocks'] as List)
          (raw as Map)['offset'] as int: Map<String, dynamic>.from(raw),
      };
      final envelopeContexts = <String>{};
      String? exportDeviceId;
      for (final rawEnvelope in manifest['key_envelopes'] as List) {
        final envelope = Map<String, dynamic>.from(rawEnvelope as Map);
        _requireKeys(envelope, const {
          'recipient_device_id',
          'key_epoch',
          'membership_version',
          'envelope',
          'signature',
          'signer_device_id',
        }, 'key envelope');
        final recipientId = _string(envelope, 'recipient_device_id');
        final signerId = _string(envelope, 'signer_device_id');
        final epoch = _positiveInteger(envelope['key_epoch'], 'key_epoch');
        final membershipVersion = _positiveInteger(
          envelope['membership_version'],
          'membership_version',
        );
        final contextKey = '$epoch:$membershipVersion';
        final signerKey = trust.signerKeys[signerId];
        final membership = trust.memberships
            .where((item) => item.version == membershipVersion)
            .firstOrNull;
        if (!envelopeContexts.add(contextKey) ||
            (exportDeviceId != null && exportDeviceId != recipientId) ||
            !trust.directory.containsKey(recipientId) ||
            signerKey == null ||
            membership == null ||
            (membership.manifest['key_epoch'] as num?)?.toInt() != epoch ||
            !_isMemberAt(
              trust.memberships,
              trust.directory,
              membershipVersion,
              signerId,
              requireOwner: false,
            )) {
          throw FormatException(currentL10n.invalidArchiveKeyEnvelopeContextOr);
        }
        exportDeviceId = recipientId;
        final signedPayload = <String, Object?>{
          'vault_id': target.vault.id,
          'recipient_device_id': recipientId,
          'key_epoch': epoch,
          'membership_version': membershipVersion,
          'envelope': envelope['envelope'],
        };
        if (!sodium.crypto.sign.verifyDetached(
          message: Uint8List.fromList(
            utf8.encode(canonicalJson(signedPayload)),
          ),
          signature: decodeBase64Url(_string(envelope, 'signature')),
          publicKey: signerKey,
        )) {
          throw FormatException(currentL10n.invalidArchiveKeyEnvelopeSignature);
        }
        final sealed = envelope['envelope'];
        if (sealed is! Map ||
            sealed['version'] != 1 ||
            sealed['suite'] != 'crypto_box_seal' ||
            sealed['ciphertext'] is! String) {
          throw FormatException(currentL10n.invalidArchiveKeyEnvelopeSealingFormat);
        }
      }
      if (exportDeviceId == null) {
        throw FormatException(currentL10n.theArchiveMustBeBoundTo);
      }
      final keyDescriptors = <Map<String, dynamic>>[];
      final keyContexts = <String>{};
      final keyOffsets = <int>{};
      final objectDescriptors = <Map<String, dynamic>>[];
      for (final raw in rawEpochKeys) {
        final entry = Map<String, dynamic>.from(raw as Map);
        final epoch = _positiveInteger(entry['key_epoch'], 'key_epoch');
        final membershipVersion = _positiveInteger(
          entry['membership_version'],
          'membership_version',
        );
        final offset = _nonNegativeInteger(entry['offset'], 'key offset');
        final length = _positiveInteger(entry['length'], 'key length');
        _requireKeys(entry, const {
          'key_epoch',
          'membership_version',
          'offset',
          'length',
          'key_sha256',
          'signer_device_id',
          'signature',
        }, 'epoch key descriptor');
        final keyContext = '$epoch:$membershipVersion';
        if (length != 32 ||
            blockByOffset[offset]?.kind != 'epoch_key' ||
            blockByOffset[offset]?.length != length ||
            !keyOffsets.add(offset) ||
            !keyContexts.add(keyContext) ||
            !envelopeContexts.contains(keyContext) ||
            entry['signer_device_id'] != exportDeviceId) {
          throw FormatException(currentL10n.invalidArchiveEpochKeyBinaryBlock);
        }
        final binaryDescriptor = rawBlocksByOffset[offset];
        if (binaryDescriptor == null ||
            binaryDescriptor['key_epoch'] != epoch ||
            binaryDescriptor['membership_version'] != membershipVersion ||
            binaryDescriptor['key_sha256'] != entry['key_sha256'] ||
            binaryDescriptor['signer_device_id'] != entry['signer_device_id'] ||
            binaryDescriptor['signature'] != entry['signature']) {
          throw FormatException(currentL10n.theArchiveEpochKeyBlockDoesnt);
        }
        final signerId = _string(entry, 'signer_device_id');
        final signerKey = trust.signerKeys[signerId];
        if (signerKey == null ||
            !_isMemberAt(
              trust.memberships,
              trust.directory,
              membershipVersion,
              signerId,
              requireOwner: false,
            )) {
          throw FormatException(currentL10n.theEpochKeyProofSignerIsnt);
        }
        final key = Uint8List.sublistView(
          unpacked.objectRegion,
          offset,
          offset + length,
        ).toList().cast<int>();
        final keyBytes = Uint8List.fromList(key);
        final keyDigest = await _sha256B64(keyBytes);
        if (entry['key_sha256'] != keyDigest) {
          keyBytes.fillRange(0, keyBytes.length, 0);
          throw FormatException(currentL10n.theEpochKeySha256Doesnt);
        }
        final attestationPayload = <String, Object?>{
          'domain': 'atermius-archive-epoch-key-v1',
          'server_space_id': target.serverSpaceId,
          'vault_id': target.vault.id,
          'key_epoch': epoch,
          'membership_version': membershipVersion,
          'key_sha256': keyDigest,
          'signer_device_id': signerId,
        };
        if (!sodium.crypto.sign.verifyDetached(
          message: Uint8List.fromList(
            utf8.encode(canonicalJson(attestationPayload)),
          ),
          signature: decodeBase64Url(_string(entry, 'signature')),
          publicKey: signerKey,
        )) {
          keyBytes.fillRange(0, keyBytes.length, 0);
          throw FormatException(currentL10n.invalidDeviceSignatureOnTheEpoch);
        }
        if (stagedEpochKeys.containsKey(epoch)) {
          final prior = stagedEpochKeys[epoch]!;
          if (!_bytesEqual(prior, keyBytes)) {
            keyBytes.fillRange(0, keyBytes.length, 0);
            throw FormatException(currentL10n.epochEpochMapsToInconsistentVault(epoch));
          }
          stagedEpochKeysByVersion[keyContext] = Uint8List.fromList(prior);
          keyBytes.fillRange(0, keyBytes.length, 0);
        } else {
          stagedEpochKeys[epoch] = keyBytes;
          stagedEpochKeysByVersion[keyContext] = Uint8List.fromList(keyBytes);
        }
        keyDescriptors.add(entry);
      }
      if (keyDescriptors.length !=
              blocks.where((item) => item.kind == 'epoch_key').length ||
          keyOffsets.length !=
              blocks.where((item) => item.kind == 'epoch_key').length ||
          keyContexts.length != envelopeContexts.length) {
        throw FormatException(
          currentL10n.theEpochKeyDescriptorsDontMatch,
        );
      }
      onProgress?.call(currentL10n.verifyingArchiveEncryptedObjectBlocks);
      for (final block in blocks.where((item) => item.kind == 'object')) {
        final objectId = block.objectId;
        _canonicalUuid(objectId!, 'object_id');
        final bytes = Uint8List.fromList(
          unpacked.objectRegion.sublist(
            block.offset,
            block.offset + block.length,
          ),
        );
        final digest = await _sha256Hex(bytes);
        if (digest != block.sha256) {
          bytes.fillRange(0, bytes.length, 0);
          throw FormatException(currentL10n.sha256MismatchForArchiveObject(objectId));
        }
        objectDescriptors.add({
          'object_id': objectId,
          'offset': block.offset,
          'length': block.length,
          'sha256': digest,
        });
        stagedObjects.add(
          ArchiveObjectBytes(objectId: objectId, bytes: bytes, sha256: digest),
        );
      }

      final revisions = (manifest['revisions'] as List)
          .map(
            (e) => VaultRevisionEntry.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(growable: false);
      final conflicts = (manifest['conflicts'] as List)
          .map(
            (e) => VaultConflictEntry.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(growable: false);
      if (revisions.length > _maxEntries || conflicts.length > _maxEntries) {
        throw FormatException(currentL10n.historyEntriesExceedTheArchiveResource);
      }
      onProgress?.call(currentL10n.verifyingArchiveHistoryRevisions);
      final uniqueRevisions = <String>{};
      final revisionEnvelopes = <String, Map<String, dynamic>>{};
      final previousByRecord = <String, String?>{};
      BigInt lastCommit = BigInt.zero;
      final expectedRefs = <String>{};
      for (final revision in revisions) {
        final revisionEnvelope = _requireArchiveEnvelope(
          revision.envelope,
          'revision',
        );
        final seq = BigInt.parse(revision.commitSeq);
        if (seq <= lastCommit || seq > BigInt.parse(high)) {
          throw FormatException(currentL10n.invalidArchiveRevisionOrderOrWatermark);
        }
        lastCommit = seq;
        if (!uniqueRevisions.add(revision.revisionId) ||
            revision.baseRevisionId != previousByRecord[revision.recordId]) {
          throw FormatException(currentL10n.anArchiveRevisionIsDuplicatedOr);
        }
        final result = await _verifyRecordEnvelope(
          envelope: revisionEnvelope,
          recordId: revision.recordId,
          revisionId: revision.revisionId,
          baseRevisionId: revision.baseRevisionId,
          operation: revision.operation,
          deleted: revision.deleted,
          context: target,
          trust: trust,
          epochKeys: stagedEpochKeys,
        );
        expectedRefs.addAll(result.$2);
        revisionEnvelopes[revision.revisionId] = revisionEnvelope;
        previousByRecord[revision.recordId] = revision.revisionId;
      }
      final manifestHeads = (manifest['snapshot_heads'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      _validateSnapshotManifest(manifestHeads, revisions, highWatermark: high);
      final latestByRecord = <String, VaultRevisionEntry>{};
      for (final revision in revisions) {
        latestByRecord[revision.recordId] = revision;
      }
      final expectedGraveyard =
          manifestHeads
              .where((head) => head['deleted'] == true)
              .map((head) {
                final recordId = _string(head, 'record_id');
                final revision = latestByRecord[recordId];
                if (revision == null ||
                    revision.revisionId != head['revision_id'] ||
                    revision.operation != 'delete') {
                  throw FormatException(currentL10n.anArchiveTombstoneDoesntMatchThe);
                }
                return <String, Object?>{
                  'record_id': recordId,
                  'deleted_revision': revision.revisionId,
                  'deleted_seq': revision.commitSeq,
                };
              })
              .toList(growable: false)
            ..sort(
              (left, right) => (left['record_id'] as String).compareTo(
                right['record_id'] as String,
              ),
            );
      final rawGraveyard = manifest['graveyard'] as List;
      if (rawGraveyard.length != expectedGraveyard.length) {
        throw FormatException(currentL10n.theArchiveGraveyardCountDoesntMatch);
      }
      final importedGraveyard =
          rawGraveyard
              .map((raw) {
                final item = Map<String, dynamic>.from(raw as Map);
                _requireKeys(item, const {
                  'record_id',
                  'deleted_revision',
                  'deleted_seq',
                }, 'graveyard entry');
                _canonicalUuid(
                  _string(item, 'record_id'),
                  'graveyard record_id',
                );
                _canonicalUuid(
                  _string(item, 'deleted_revision'),
                  'graveyard deleted_revision',
                );
                _decimal(item['deleted_seq'], 'graveyard deleted_seq');
                return item;
              })
              .toList(growable: false)
            ..sort(
              (left, right) => (left['record_id'] as String).compareTo(
                right['record_id'] as String,
              ),
            );
      if (canonicalJson(importedGraveyard) !=
          canonicalJson(expectedGraveyard)) {
        throw FormatException(currentL10n.theArchiveGraveyardDoesntMatchThe);
      }
      final seenConflicts = <String>{};
      onProgress?.call(currentL10n.verifyingArchiveHistoryConflicts);
      BigInt lastConflict = BigInt.zero;
      for (final conflict in conflicts) {
        final seq = BigInt.parse(conflict.conflictSeq);
        if (seq <= lastConflict ||
            seq > BigInt.parse(conflictHigh) ||
            !seenConflicts.add(conflict.conflictId)) {
          throw FormatException(currentL10n.invalidArchiveConflictOrderWatermarkOr);
        }
        lastConflict = seq;
        if (conflict.baseRevisionId != null &&
            !revisionEnvelopes.containsKey(conflict.baseRevisionId)) {
          throw FormatException(currentL10n.theArchiveConflictBaseRevisionDoesnt);
        }
        final conflictEnvelope = _requireArchiveEnvelope(
          conflict.envelope,
          'conflict',
        );
        final rawHeader = conflictEnvelope['header'];
        if (rawHeader is! Map) {
          throw FormatException(currentL10n.anArchiveConflictEnvelopeHasNo);
        }
        final header = Map<String, dynamic>.from(rawHeader);
        final result = await _verifyRecordEnvelope(
          envelope: conflictEnvelope,
          recordId: conflict.recordId,
          revisionId: header['revision_id'] as String?,
          baseRevisionId: conflict.baseRevisionId,
          operation: header['operation'] as String?,
          deleted: header['operation'] == 'delete',
          context: target,
          trust: trust,
          epochKeys: stagedEpochKeys,
        );
        expectedRefs.addAll(result.$2);
        if ((conflict.resolvedRevisionId == null) !=
                (conflict.resolutionSeq == null) ||
            (conflict.resolvedRevisionId != null &&
                !revisionEnvelopes.containsKey(conflict.resolvedRevisionId))) {
          throw FormatException(currentL10n.anArchiveConflictResolutionPointsTo);
        }
      }
      final local = Map<String, dynamic>.from(manifest['local_pending'] as Map);
      onProgress?.call(currentL10n.verifyingTheArchivesLocalOutboxAnd);
      final pendingDtos = <ArchivePendingOperation>[];
      final pendingIds = <String>{};
      final pendingRevisionIds = <String>{};
      final pendingBaseEnvelopes = <Map<String, dynamic>>[];
      final branchDtos = <ArchiveConflictBranch>[];
      final branchIds = <String>{};
      final currentHeadsByRecord = {
        for (final item in manifestHeads) item['record_id'] as String: item,
      };
      for (final raw in local['operations'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        final envelope = Map<String, dynamic>.from(item['envelope'] as Map);
        final header = Map<String, dynamic>.from(envelope['header'] as Map);
        final opId = _string(item, 'op_id');
        final recordId = _string(item, 'record_id');
        final baseRevisionId = item['base_revision_id'] as String?;
        final revisionId = header['revision_id'] as String?;
        if (!pendingIds.add(opId) ||
            header['op_id'] != opId ||
            header['record_id'] != recordId ||
            header['base_revision_id'] != baseRevisionId ||
            revisionId == null ||
            !pendingRevisionIds.add(revisionId)) {
          throw FormatException(currentL10n.theArchivesLocalOutboxMetadataIs);
        }
        _canonicalUuid(opId, 'op_id');
        _canonicalUuid(recordId, 'record_id');
        final operationStatus = _string(item, 'status');
        if (!const {'queued', 'sent', 'conflict'}.contains(operationStatus)) {
          throw FormatException(currentL10n.invalidArchiveOutboxState);
        }
        final result = await _verifyRecordEnvelope(
          envelope: envelope,
          recordId: recordId,
          revisionId: revisionId,
          baseRevisionId: baseRevisionId,
          operation: header['operation'] as String?,
          deleted: header['operation'] == 'delete',
          context: target,
          trust: trust,
          epochKeys: stagedEpochKeys,
        );
        expectedRefs.addAll(result.$2);
        final foreignDevice = header['device_id'] != target.device.deviceId;
        Map<String, dynamic>? baseEnvelope;
        if (item['base_envelope'] != null) {
          baseEnvelope = Map<String, dynamic>.from(
            item['base_envelope'] as Map,
          );
          final baseHeader = Map<String, dynamic>.from(
            baseEnvelope['header'] as Map,
          );
          final baseResult = await _verifyRecordEnvelope(
            envelope: baseEnvelope,
            recordId: recordId,
            revisionId: baseRevisionId,
            baseRevisionId: baseHeader['base_revision_id'] as String?,
            operation: baseHeader['operation'] as String?,
            deleted: baseHeader['operation'] == 'delete',
            context: target,
            trust: trust,
            epochKeys: stagedEpochKeys,
          );
          expectedRefs.addAll(baseResult.$2);
          pendingBaseEnvelopes.add(baseEnvelope);
        } else if (baseRevisionId != null &&
            !revisionEnvelopes.containsKey(baseRevisionId)) {
          throw FormatException(currentL10n.theArchivesLocalOutboxBaseRevision);
        }
        final createdAt = _nonNegativeInteger(item['created_at'], 'created_at');
        pendingDtos.add(
          ArchivePendingOperation(
            opId: opId,
            recordId: recordId,
            baseRevisionId: baseRevisionId,
            baseEnvelopeJson: baseEnvelope == null
                ? null
                : jsonEncode(baseEnvelope),
            envelopeJson: jsonEncode(envelope),
            // An outbox envelope is bound to its author device. Keep its exact
            // ciphertext/op id, but never let a different device identity
            // replay it as an ordinary queued write.
            status: foreignDevice ? 'conflict' : operationStatus,
            attemptCount: _nonNegativeInteger(
              item['attempt_count'],
              'attempt_count',
            ),
            createdAt: createdAt,
            lastAttemptAt: item['last_attempt_at'] == null
                ? null
                : _nonNegativeInteger(
                    item['last_attempt_at'],
                    'last_attempt_at',
                  ),
          ),
        );
        if (foreignDevice) {
          final syntheticId = await _derivedUuid(
            'atermius-archive-device-pending:${target.vault.id}:$opId',
          );
          if (!branchIds.add(syntheticId)) {
            throw FormatException(currentL10n.duplicateExternalDeviceOutboxConflictId);
          }
          final remoteHead = currentHeadsByRecord[recordId];
          final remote = remoteHead == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(remoteHead['envelope'] as Map);
          branchDtos.add(
            ArchiveConflictBranch(
              conflictId: syntheticId,
              recordId: recordId,
              kind: 'archive_from_other_device',
              branchEnvelopeJson: jsonEncode(envelope),
              remoteEnvelopeJson: jsonEncode(remote),
              state: 'open',
              resolutionOpId: null,
              resolutionRevisionId: null,
              createdAt: createdAt,
            ),
          );
        }
      }
      for (final raw in local['conflict_branches'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        final conflictId = _string(item, 'conflict_id');
        final recordId = _string(item, 'record_id');
        _canonicalUuid(conflictId, 'local conflict_id');
        _canonicalUuid(recordId, 'local conflict record_id');
        if (!branchIds.add(conflictId)) {
          throw FormatException(currentL10n.duplicateArchiveLocalConflictId);
        }
        _requireKeys(item, const {
          'conflict_id',
          'record_id',
          'kind',
          'branch_envelope',
          'remote_envelope',
          'state',
          'resolution_op_id',
          'resolution_revision_id',
          'created_at',
        }, 'local conflict branch');
        final kind = _string(item, 'kind');
        final state = _string(item, 'state');
        if (!const {
              'concurrent_edit',
              'delete_edit',
              'remote_delete',
              'id_reuse',
              'archive_from_other_device',
            }.contains(kind) ||
            !const {
              'open',
              'upload_pending',
              'resolution_pending',
              'resolution_ready',
              'resolved',
            }.contains(state)) {
          throw FormatException(currentL10n.unsupportedArchiveLocalConflictKindState);
        }
        final branch = Map<String, dynamic>.from(
          item['branch_envelope'] as Map,
        );
        final branchHeader = Map<String, dynamic>.from(branch['header'] as Map);
        final branchResult = await _verifyRecordEnvelope(
          envelope: branch,
          recordId: recordId,
          revisionId: branchHeader['revision_id'] as String?,
          baseRevisionId: branchHeader['base_revision_id'] as String?,
          operation: branchHeader['operation'] as String?,
          deleted: branchHeader['operation'] == 'delete',
          context: target,
          trust: trust,
          epochKeys: stagedEpochKeys,
        );
        expectedRefs.addAll(branchResult.$2);
        final remote = Map<String, dynamic>.from(
          item['remote_envelope'] as Map,
        );
        if (remote.isNotEmpty) {
          final remoteHeader = Map<String, dynamic>.from(
            remote['header'] as Map,
          );
          final remoteResult = await _verifyRecordEnvelope(
            envelope: remote,
            recordId: recordId,
            revisionId: remoteHeader['revision_id'] as String?,
            baseRevisionId: remoteHeader['base_revision_id'] as String?,
            operation: remoteHeader['operation'] as String?,
            deleted: remoteHeader['operation'] == 'delete',
            context: target,
            trust: trust,
            epochKeys: stagedEpochKeys,
          );
          expectedRefs.addAll(remoteResult.$2);
        }
        final resolutionOp = item['resolution_op_id'] as String?;
        final resolutionRevision = item['resolution_revision_id'] as String?;
        final hasResolutionLink =
            resolutionOp != null && resolutionRevision != null;
        if ((resolutionOp == null) != (resolutionRevision == null) ||
            ((state == 'resolution_pending' ||
                    state == 'resolution_ready' ||
                    state == 'resolved') &&
                !hasResolutionLink) ||
            ((state == 'open' || state == 'upload_pending') &&
                hasResolutionLink)) {
          throw FormatException(currentL10n.invalidLinkBetweenArchiveLocalConflict);
        }
        if (resolutionOp != null) {
          _canonicalUuid(resolutionOp, 'resolution_op_id');
          _canonicalUuid(resolutionRevision!, 'resolution_revision_id');
          final linked = pendingDtos.where(
            (operation) => operation.opId == resolutionOp,
          );
          if (state == 'resolution_pending' &&
              (linked.length != 1 ||
                  linked.single.recordId != recordId ||
                  Map<String, dynamic>.from(
                        jsonDecode(linked.single.envelopeJson) as Map,
                      )['header']['revision_id'] !=
                      resolutionRevision)) {
            throw FormatException(currentL10n.invalidArchiveConflictResolutionOutboxLink);
          }
        }
        branchDtos.add(
          ArchiveConflictBranch(
            conflictId: conflictId,
            recordId: recordId,
            kind: kind,
            branchEnvelopeJson: jsonEncode(branch),
            remoteEnvelopeJson: jsonEncode(remote),
            state: state,
            resolutionOpId: resolutionOp,
            resolutionRevisionId: resolutionRevision,
            createdAt: _nonNegativeInteger(item['created_at'], 'created_at'),
          ),
        );
      }

      PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: pendingDtos,
        conflicts: branchDtos,
        snapshotRevisionIds: revisionEnvelopes.keys.toSet(),
      );

      final refsInManifest = objectDescriptors
          .map((e) => e['object_id'] as String)
          .toSet();
      if (!refsInManifest.containsAll(expectedRefs) ||
          !expectedRefs.containsAll(refsInManifest)) {
        throw FormatException(
          currentL10n.theArchiveObjectBlockSetDiffers,
        );
      }
      onProgress?.call(currentL10n.verifyingArchiveDeviceSequenceWatermarks);
      final floors = _readSequenceFloors(local['device_sequence_floors']);
      final sequenceEnvelopes = <Map<String, dynamic>>[
        ...revisions.map(
          (item) => _requireArchiveEnvelope(item.envelope, 'revision'),
        ),
        ...conflicts.map(
          (item) => _requireArchiveEnvelope(item.envelope, 'conflict'),
        ),
        ...pendingDtos.map(
          (item) => jsonDecode(item.envelopeJson) as Map<String, dynamic>,
        ),
        ...pendingBaseEnvelopes,
        ...branchDtos.map(
          (item) => jsonDecode(item.branchEnvelopeJson) as Map<String, dynamic>,
        ),
        ...branchDtos
            .map(
              (item) =>
                  jsonDecode(item.remoteEnvelopeJson) as Map<String, dynamic>,
            )
            .where((item) => item.isNotEmpty),
      ];
      for (final envelope in sequenceEnvelopes) {
        _raiseSequenceFloor(floors, envelope);
      }
      for (final pending in pendingDtos) {
        final header = Map<String, dynamic>.from(
          (jsonDecode(pending.envelopeJson) as Map)['header'] as Map,
        );
        final deviceId = _string(header, 'device_id');
        final seq = BigInt.parse(_decimal(header['device_seq'], 'device_seq'));
        if (seq >= BigInt.from(9007199254740000)) {
          throw FormatException(currentL10n.anArchiveOutboxDeviceSeqIs);
        }
        final next = seq.toInt() + 1;
        floors[deviceId] = floors[deviceId] == null || floors[deviceId]! < next
            ? next
            : floors[deviceId]!;
      }
      final sequenceByRevision = {
        for (final revision in revisions)
          revision.revisionId: revision.commitSeq,
      };
      final heads = manifestHeads
          .map((item) {
            final headerEnvelope = Map<String, dynamic>.from(
              item['envelope'] as Map,
            );
            final revisionId = _string(item, 'revision_id');
            // Legacy portable archives omitted the sequence from snapshot
            // heads, but their validated immutable revision history still
            // carries it. Use only the exact matching head revision; never
            // invent a sentinel or infer from a different revision.
            final commitSeq = item.containsKey('commit_seq')
                ? _decimal(item['commit_seq'], 'snapshot head commit_seq')
                : sequenceByRevision[revisionId];
            return SnapshotHead(
              recordId: _string(item, 'record_id'),
              revisionId: revisionId,
              deleted: item['deleted'] as bool,
              envelope: headerEnvelope,
              commitSeq: commitSeq,
            );
          })
          .toList(growable: false);
      final stage = StagedVaultArchive(
        sourceInstanceId: _string(manifest, 'instance_id'),
        serverSpaceId: target.serverSpaceId,
        vaultId: target.vault.id,
        snapshotId: snapshotId,
        highWatermark: high,
        conflictHighWatermark: conflictHigh,
        cursor: cursor,
        serverGeneration: generation,
        heads: heads,
        operations: pendingDtos,
        conflicts: branchDtos,
        objects: stagedObjects,
        sequenceFloors: floors,
        epochKeysByVersion: stagedEpochKeysByVersion,
        recordCount: revisions.length,
        conflictCount: conflicts.length + branchDtos.length,
      );
      for (final key in stagedEpochKeys.values) {
        key.fillRange(0, key.length, 0);
      }
      return stage;
    } catch (_) {
      for (final key in stagedEpochKeys.values) {
        key.fillRange(0, key.length, 0);
      }
      for (final object in stagedObjects) {
        object.bytes.fillRange(0, object.bytes.length, 0);
      }
      for (final key in stagedEpochKeysByVersion.values) {
        key.fillRange(0, key.length, 0);
      }
      rethrow;
    } finally {
      clearPayload.fillRange(0, clearPayload.length, 0);
    }
  }

  Future<void> applyStage(
    StagedVaultArchive stage, {
    required String instanceId,
  }) async {
    await _ensureArchiveObjectsUploaded(stage);
    await database.applyPortableVaultArchive(
      vaultId: stage.vaultId,
      instanceId: instanceId,
      serverSpaceId: stage.serverSpaceId,
      heads: stage.heads,
      cursor: stage.cursor,
      serverGeneration: stage.serverGeneration,
      operations: stage.operations,
      conflicts: stage.conflicts,
      objects: stage.objects,
      sequenceFloors: stage.sequenceFloors,
    );
  }

  Future<void> _ensureArchiveObjectsUploaded(StagedVaultArchive stage) async {
    final ids = <String>{};
    for (final object in stage.objects) {
      _canonicalUuid(object.objectId, 'object_id');
      if (!ids.add(object.objectId) ||
          object.bytes.isEmpty ||
          object.bytes.length > 32 * 1024 * 1024 ||
          await _sha256Hex(object.bytes) != object.sha256) {
        throw FormatException(
          currentL10n.anArchiveObjectIdLengthOr,
        );
      }
    }
    for (final object in stage.objects) {
      if (await _remoteObjectMatches(stage.vaultId, object)) {
        continue;
      }

      late final Map<String, dynamic> upload;
      try {
        upload = await api.initUpload(stage.vaultId, {
          'object_id': object.objectId,
          'size': object.bytes.length,
          'sha256': object.sha256,
        });
      } on ApiException catch (error) {
        // Another writer may create an immutable object after our GET but
        // before the upload reservation reaches the server. Only treat this
        // as success after retrieving and comparing the exact bytes.
        if (error.code == 'OBJECT_EXISTS' &&
            await _remoteObjectMatches(stage.vaultId, object)) {
          continue;
        }
        rethrow;
      }
      final uploadId = _string(upload, 'upload_id');
      final chunkSize = _positiveInteger(upload['chunk_size'], 'chunk_size');
      var index = 0;
      for (var offset = 0; offset < object.bytes.length; offset += chunkSize) {
        final end = offset + chunkSize < object.bytes.length
            ? offset + chunkSize
            : object.bytes.length;
        final chunk = Uint8List.sublistView(object.bytes, offset, end);
        await api.uploadChunk(
          uploadId: uploadId,
          index: index,
          bytes: chunk,
          sha256: await _sha256Hex(chunk),
        );
        index++;
      }
      try {
        await api.completeUpload(uploadId, const {});
      } on ApiException catch (error) {
        // An object may win the race after init; accept only an exact match.
        if (error.code != 'OBJECT_EXISTS' ||
            !await _remoteObjectMatches(stage.vaultId, object)) {
          rethrow;
        }
      }
      if (!await _remoteObjectMatches(stage.vaultId, object)) {
        throw StateError(currentL10n.uploadedObjectObjectidFailedReadBack(object.objectId));
      }
    }
  }

  Future<bool> _remoteObjectMatches(
    String vaultId,
    ArchiveObjectBytes object,
  ) async {
    try {
      final downloaded = await api.downloadObjectWithDigest(
        vaultId,
        object.objectId,
      );
      try {
        if (downloaded.sha256 != object.sha256 ||
            !_bytesEqual(downloaded.bytes, object.bytes)) {
          throw StateError(currentL10n.serverObjectObjectidConflictsWithThe(object.objectId));
        }
        return true;
      } finally {
        downloaded.bytes.fillRange(0, downloaded.bytes.length, 0);
      }
    } on ApiException catch (error) {
      if (error.statusCode == 404) return false;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _readAllSnapshotHeads({
    required String snapshotId,
    required String highWatermark,
    required String conflictHighWatermark,
    required String nextCursor,
    required String expiresAt,
    required bool createdHasItemCount,
    required int? createdItemCount,
  }) async {
    final heads = <Map<String, dynamic>>[];
    final seenPageCursors = <String>{};
    var pageCountFieldPresent = createdHasItemCount ? true : null;
    var expectedItemCount = createdItemCount;
    var manifestJsonBytes = 2; // The opening and closing JSON array brackets.
    String? pageCursor;
    while (true) {
      final page = await api.snapshot(
        snapshotId,
        limit: 100,
        pageCursor: pageCursor,
      );
      final manifest = page['manifest'];
      final hasMoreFieldPresent = page.containsKey('has_more');
      final nextPageCursorFieldPresent = page.containsKey('next_page_cursor');
      final legacyFullManifest =
          !hasMoreFieldPresent && !nextPageCursorFieldPresent;
      final pageItemCountPresent = page.containsKey('item_count');
      if (page['snapshot_id'] != snapshotId ||
          page['high_watermark'] != highWatermark ||
          page['conflict_high_watermark'] != conflictHighWatermark ||
          page['next_cursor'] != nextCursor ||
          page['expires_at'] != expiresAt ||
          manifest is! List ||
          (hasMoreFieldPresent != nextPageCursorFieldPresent) ||
          (!legacyFullManifest && page['has_more'] is! bool) ||
          (legacyFullManifest && pageCursor != null)) {
        throw FormatException(currentL10n.invalidServerSnapshotPageBoundaryOr);
      }
      if (pageCountFieldPresent == null) {
        pageCountFieldPresent = pageItemCountPresent;
      } else if (pageCountFieldPresent != pageItemCountPresent) {
        throw FormatException(currentL10n.theServerSnapshotItemCountIs);
      }
      if (pageItemCountPresent) {
        final rawItemCount = page['item_count'];
        if (rawItemCount is! int ||
            rawItemCount < 0 ||
            (expectedItemCount != null && expectedItemCount != rawItemCount)) {
          throw FormatException(currentL10n.theServerSnapshotItemCountIs2);
        }
        if (rawItemCount > _maxEntries) {
          throw FormatException(currentL10n.theSnapshotExceedsTheArchiveCapacity);
        }
        expectedItemCount = rawItemCount;
      }
      if ((pageCursor != null && manifest.isEmpty) ||
          (!legacyFullManifest &&
              page['has_more'] == true &&
              manifest.isEmpty)) {
        throw FormatException(currentL10n.theServerSnapshotReturnedAnEmpty);
      }
      if (heads.length + manifest.length > _maxEntries) {
        throw FormatException(currentL10n.theSnapshotExceedsTheArchiveCapacity);
      }
      if (!legacyFullManifest && manifest.length > 100) {
        throw FormatException(currentL10n.theServerSnapshotPageManifestHas);
      }
      for (final rawHead in manifest) {
        if (rawHead is! Map) {
          throw FormatException(currentL10n.theServerSnapshotContainsInvalidRecords);
        }
        final serializedHeadBytes = utf8.encode(jsonEncode(rawHead)).length;
        final nextManifestBytes =
            manifestJsonBytes + serializedHeadBytes + (heads.isEmpty ? 0 : 1);
        if (nextManifestBytes > _maxSnapshotManifestJsonBytes) {
          throw FormatException(currentL10n.theServerSnapshotManifestExceedsThe);
        }
        manifestJsonBytes = nextManifestBytes;
        heads.add(Map<String, dynamic>.from(rawHead));
      }

      if (legacyFullManifest) {
        if (expectedItemCount != null && heads.length != expectedItemCount) {
          throw FormatException(currentL10n.theServerSnapshotItemCountDoesnt2);
        }
        return List<Map<String, dynamic>>.unmodifiable(heads);
      }

      final hasMore = page['has_more'] as bool;
      final nextPageCursor = page['next_page_cursor'];
      if (!hasMore) {
        if (nextPageCursor != null) {
          throw FormatException(currentL10n.theLastSnapshotPageStillContains);
        }
        if (expectedItemCount != null && heads.length != expectedItemCount) {
          throw FormatException(currentL10n.theServerSnapshotItemCountDoesnt);
        }
        return List<Map<String, dynamic>>.unmodifiable(heads);
      }
      if (nextPageCursor is! String ||
          nextPageCursor.trim().isEmpty ||
          nextPageCursor.length > 2048 ||
          !seenPageCursors.add(nextPageCursor)) {
        throw FormatException(currentL10n.theServerSnapshotContinuationCursorIs);
      }
      pageCursor = nextPageCursor;
    }
  }

  Future<({List<VaultRevisionEntry> entries, String serverGeneration})>
  _allRevisions(
    String vaultId,
    String snapshotId,
    String high,
    String conflictHigh,
  ) async {
    final entries = <VaultRevisionEntry>[];
    final seenCursors = <String>{};
    String? cursor;
    String? expectedGeneration;
    late String generation;
    do {
      final page = await api.revisions(
        vaultId,
        snapshotId: snapshotId,
        cursor: cursor,
        limit: 500,
      );
      _checkPage(
        page,
        snapshotId,
        vaultId,
        high,
        conflictHigh,
        expectedGeneration,
      );
      generation = page.serverGeneration;
      expectedGeneration = generation;
      entries.addAll(page.entries);
      if (entries.length > _maxEntries) {
        throw FormatException(currentL10n.theRevisionHistoryExceedsTheArchive);
      }
      if (page.hasMore) {
        final next = page.nextCursor;
        if (next == null || next.isEmpty || !seenCursors.add(next)) {
          throw FormatException(currentL10n.theRevisionHistoryCursorIsInvalid);
        }
        cursor = next;
      } else {
        cursor = null;
      }
    } while (cursor != null);
    return (entries: entries, serverGeneration: generation);
  }

  Future<({List<VaultConflictEntry> entries, String serverGeneration})>
  _allConflicts(
    String vaultId,
    String snapshotId,
    String high,
    String conflictHigh,
  ) async {
    final entries = <VaultConflictEntry>[];
    final seenCursors = <String>{};
    String? cursor;
    String? expectedGeneration;
    late String generation;
    do {
      final page = await api.conflicts(
        vaultId,
        snapshotId: snapshotId,
        cursor: cursor,
        limit: 500,
      );
      _checkPage(
        page,
        snapshotId,
        vaultId,
        high,
        conflictHigh,
        expectedGeneration,
      );
      generation = page.serverGeneration;
      expectedGeneration = generation;
      entries.addAll(page.entries);
      if (entries.length > _maxEntries) {
        throw FormatException(currentL10n.theConflictHistoryExceedsTheArchive);
      }
      if (page.hasMore) {
        final next = page.nextCursor;
        if (next == null || next.isEmpty || !seenCursors.add(next)) {
          throw FormatException(currentL10n.theConflictHistoryCursorIsInvalid);
        }
        cursor = next;
      } else {
        cursor = null;
      }
    } while (cursor != null);
    return (entries: entries, serverGeneration: generation);
  }

  void _checkPage<T>(
    VaultHistoryPage<T> page,
    String snapshotId,
    String vaultId,
    String high,
    String conflictHigh,
    String? expectedGeneration,
  ) {
    if (page.snapshotId != snapshotId ||
        page.vaultId != vaultId ||
        page.highWatermark != high ||
        page.conflictHighWatermark != conflictHigh ||
        (expectedGeneration != null &&
            expectedGeneration != page.serverGeneration)) {
      throw FormatException(currentL10n.aHistoryPageDoesntMatchThe);
    }
  }

  Future<_ArchiveTrust> _loadAndVerifyTrust(VaultArchiveContext context) async {
    final accountDevices = await api.devices();
    final vaultDevices = await api.vaultDevices(context.vault.id);
    final directory = <String, Map<String, dynamic>>{};
    for (final raw in [...accountDevices, ...vaultDevices]) {
      final device = Map<String, dynamic>.from(raw);
      final id = device['device_id'];
      final userId = device['user_id'];
      final signingText = device['signing_public_key'];
      final encryptionText = device['encryption_public_key'];
      if (id is! String ||
          !_isCanonicalUuid(id) ||
          signingText is! String ||
          encryptionText is! String) {
        continue;
      }
      if (userId is! String) {
        // The account-scoped /devices response has no user_id. The vault
        // directory is authoritative for that binding.
        continue;
      }
      final existing = directory[id];
      if (existing != null &&
          (existing['user_id'] != userId ||
              existing['signing_public_key'] != signingText ||
              existing['encryption_public_key'] != encryptionText)) {
        throw FormatException(currentL10n.theSameDeviceIdHasConflicting);
      }
      directory[id] = device;
    }
    final localDevice = directory[context.device.deviceId];
    if (localDevice == null ||
        localDevice['user_id'] != context.accountId ||
        !_bytesEqual(
          decodeBase64Url(localDevice['signing_public_key'] as String),
          context.device.signing.publicKey,
        ) ||
        !_bytesEqual(
          decodeBase64Url(localDevice['encryption_public_key'] as String),
          context.device.encryption.publicKey,
        )) {
      throw FormatException(currentL10n.thisDevicesPublicKeyDoesntMatch);
    }
    final keys = <String, Uint8List>{};
    for (final item in directory.values) {
      final key = decodeBase64Url(item['signing_public_key'] as String);
      if (key.length != 32) throw FormatException(currentL10n.invalidDeviceSigningKeyLength);
      keys[item['device_id'] as String] = key;
    }
    final response = await api.membership(context.vault.id);
    final raw =
        response['manifests'] ??
        response['memberships'] ??
        response['entries'] ??
        response['chain'];
    if (raw is! List || raw.isEmpty || raw.length > 10000) {
      throw FormatException(currentL10n.theVaultMembershipChainIsMissing);
    }
    final memberships = raw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final verified = await crypto.verifyMembershipChain(
      vaultId: context.vault.id,
      entries: memberships,
      signerPublicKeys: keys,
      expectedLatestVersion: int.parse(context.vault.membershipVersion),
    );
    _verifyMembershipOwners(verified, directory);
    final currentMember = (verified.last.manifest['members'] as List).any(
      (member) =>
          member is Map &&
          member['user_id'] == context.accountId &&
          member['state'] == 'active',
    );
    if (!currentMember) throw FormatException(currentL10n.theCurrentAccountIsntInThe);
    return _ArchiveTrust(
      directory: directory,
      signerKeys: keys,
      rawMemberships: memberships,
      memberships: verified,
    );
  }

  Future<_ArchiveTrust> _loadArchiveTrust(
    VaultArchiveContext target,
    Map<String, dynamic> manifest,
  ) async {
    final rawDevices = manifest['devices'];
    final rawMemberships = manifest['membership_chain'];
    if (rawDevices is! List ||
        rawDevices.isEmpty ||
        rawDevices.length > 100000 ||
        rawMemberships is! List) {
      throw FormatException(currentL10n.invalidArchiveDeviceDirectoryOrMembership);
    }
    final directory = <String, Map<String, dynamic>>{};
    final signerKeys = <String, Uint8List>{};
    for (final raw in rawDevices) {
      final item = Map<String, dynamic>.from(raw as Map);
      final id = _string(item, 'device_id');
      _canonicalUuid(id, 'device_id');
      final userId = _string(item, 'user_id');
      _canonicalUuid(userId, 'device user_id');
      final signingText = _string(item, 'signing_public_key');
      final encryptionText = _string(item, 'encryption_public_key');
      final signingKey = decodeBase64Url(signingText);
      final encryptionKey = decodeBase64Url(encryptionText);
      if (signingKey.length != 32 ||
          encryptionKey.length != 32 ||
          directory.containsKey(id)) {
        throw FormatException(currentL10n.anArchiveDevicePublicKeyIs);
      }
      directory[id] = item;
      signerKeys[id] = signingKey;
    }
    final currentDevices = await api.vaultDevices(target.vault.id);
    final currentById = {
      for (final item in currentDevices) item['device_id']: item,
    };
    for (final entry in directory.entries) {
      final current = currentById[entry.key];
      if (current == null ||
          current['user_id'] != entry.value['user_id'] ||
          current['signing_public_key'] != entry.value['signing_public_key'] ||
          current['encryption_public_key'] !=
              entry.value['encryption_public_key']) {
        throw FormatException(currentL10n.archiveDeviceDirectoryKeyDoesntMatch(entry.key));
      }
    }
    final currentLocal = currentById[target.device.deviceId];
    if (currentLocal == null ||
        currentLocal['user_id'] != target.accountId ||
        currentLocal['signing_public_key'] != target.device.signingPublicKey ||
        currentLocal['encryption_public_key'] !=
            target.device.encryptionPublicKey) {
      throw FormatException(currentL10n.thisDevicesIdentityCouldntBeMatched);
    }
    for (final raw in currentDevices) {
      final device = Map<String, dynamic>.from(raw);
      final id = _string(device, 'device_id');
      final signing = _string(device, 'signing_public_key');
      final encryption = _string(device, 'encryption_public_key');
      final prior = directory[id];
      if (prior != null &&
          (prior['signing_public_key'] != signing ||
              prior['encryption_public_key'] != encryption ||
              prior['user_id'] != device['user_id'])) {
        throw FormatException(currentL10n.theHistoryDirectoryOfDeviceId(id));
      }
      directory[id] = device;
      signerKeys[id] = decodeBase64Url(signing);
    }
    final archivedMemberships = rawMemberships
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final latestMembershipResponse = await api.membership(target.vault.id);
    final currentRaw =
        latestMembershipResponse['manifests'] ??
        latestMembershipResponse['memberships'] ??
        latestMembershipResponse['entries'] ??
        latestMembershipResponse['chain'];
    if (currentRaw is! List) {
      throw FormatException(currentL10n.theCurrentVaultMembershipChainIs);
    }
    final currentMemberships = currentRaw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final verified = await crypto.verifyMembershipChain(
      vaultId: target.vault.id,
      entries: currentMemberships,
      signerPublicKeys: signerKeys,
      expectedLatestVersion: int.parse(target.vault.membershipVersion),
    );
    _verifyMembershipOwners(verified, directory);
    final verifiedArchivePrefix = await crypto.verifyMembershipChain(
      vaultId: target.vault.id,
      entries: archivedMemberships,
      signerPublicKeys: signerKeys,
      expectedLatestVersion: archivedMemberships.length,
    );
    if (verifiedArchivePrefix.length > verified.length) {
      throw FormatException(currentL10n.theArchiveMembershipIsNewerThan);
    }
    for (var index = 0; index < verifiedArchivePrefix.length; index++) {
      if (verifiedArchivePrefix[index].digest != verified[index].digest ||
          verifiedArchivePrefix[index].signerDeviceId !=
              verified[index].signerDeviceId) {
        throw FormatException(currentL10n.theArchiveMembershipIsntAValid);
      }
    }
    final currentMember = (verified.last.manifest['members'] as List).any(
      (member) =>
          member is Map &&
          member['user_id'] == target.accountId &&
          member['state'] == 'active',
    );
    if (!currentMember) throw FormatException(currentL10n.theArchiveMembershipDoesntIncludeThe);
    return _ArchiveTrust(
      directory: directory,
      signerKeys: signerKeys,
      rawMemberships: archivedMemberships,
      memberships: verified,
    );
  }

  void _verifyMembershipOwners(
    List<VerifiedMembership> memberships,
    Map<String, Map<String, dynamic>> directory,
  ) {
    for (final membership in memberships) {
      final signer = directory[membership.signerDeviceId];
      final userId = signer?['user_id'];
      final isActiveOwner = (membership.manifest['members'] as List).any(
        (member) =>
            member is Map &&
            member['user_id'] == userId &&
            member['role'] == 'owner' &&
            member['state'] == 'active',
      );
      if (userId is! String || !isActiveOwner) {
        throw FormatException(currentL10n.theMembershipSignerWasntAnActive);
      }
    }
  }

  Future<(Map<String, Object?>, Set<String>)> _verifyRecordEnvelope({
    required Map<String, dynamic> envelope,
    required String recordId,
    required String? revisionId,
    required String? baseRevisionId,
    required String? operation,
    required bool deleted,
    required VaultArchiveContext context,
    required _ArchiveTrust trust,
    required Map<int, Uint8List> epochKeys,
  }) async {
    final rawHeader = envelope['header'];
    if (rawHeader is! Map)
      {
throw FormatException(currentL10n.aRecordEnvelopeIsMissingIts);
}
    final header = Map<String, dynamic>.from(rawHeader);
    final headerRecordId = header['record_id'];
    final headerRevisionId = header['revision_id'];
    final deviceId = header['device_id'];
    final opId = header['op_id'];
    final deviceSequence = header['device_seq'];
    final epoch = int.tryParse(header['key_epoch']?.toString() ?? '');
    final membershipVersion = int.tryParse(
      header['membership_version']?.toString() ?? '',
    );
    if (header['server_space_id'] != context.serverSpaceId ||
        header['vault_id'] != context.vault.id ||
        headerRecordId != recordId ||
        (revisionId != null && headerRevisionId != revisionId) ||
        header['base_revision_id'] != baseRevisionId ||
        header['operation'] != operation ||
        (operation == 'delete') != deleted ||
        deviceId is! String ||
        opId is! String ||
        !_isCanonicalUuid(opId) ||
        deviceSequence is! String ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(deviceSequence) ||
        !_isSupportedOperation(operation) ||
        epoch == null ||
        membershipVersion == null ||
        !_isCanonicalUuid(recordId) ||
        (headerRevisionId is! String || !_isCanonicalUuid(headerRevisionId))) {
      throw FormatException(currentL10n.theRecordSignatureHeaderDoesntMatch);
    }
    _canonicalUuid(deviceId, 'device_id');
    if (baseRevisionId != null) {
      _canonicalUuid(baseRevisionId, 'base_revision_id');
    }
    final signer = trust.signerKeys[deviceId];
    final key = epochKeys[epoch];
    if (signer == null || key == null) {
      throw FormatException(currentL10n.trustCouldntBeEstablishedForThe);
    }
    final membership = trust.memberships
        .where((m) => m.version == membershipVersion)
        .firstOrNull;
    if (membership == null ||
        (membership.manifest['key_epoch'] as num?)?.toInt() != epoch ||
        !_isMemberAt(
          trust.memberships,
          trust.directory,
          membershipVersion,
          deviceId,
          requireOwner: false,
        )) {
      throw FormatException(currentL10n.theRecordSignerEpochDoesntBelong);
    }
    final clear = await crypto.decryptRecord(
      vaultKey: key,
      envelope: envelope,
      authorPublicKey: signer,
    );
    final rawRefs = header['object_refs'];
    final refs = rawRefs == null ? <String>[] : _validateObjectRefs(rawRefs);
    final plainManifest = clear['_manifest'];
    final plainRefs =
        plainManifest is Map && plainManifest['object_refs'] != null
        ? _validateObjectRefs(plainManifest['object_refs'])
        : <String>[];
    if (canonicalJson(refs) != canonicalJson(plainRefs)) {
      throw FormatException(currentL10n.theSignedObjectRefsDontMatch);
    }
    return (clear, refs.toSet());
  }

  static bool _isMemberAt(
    List<VerifiedMembership> memberships,
    Map<String, Map<String, dynamic>> directory,
    int version,
    String deviceId, {
    required bool requireOwner,
  }) {
    final member = memberships
        .where((item) => item.version == version)
        .firstOrNull;
    final device = directory[deviceId];
    final userId = device?['user_id'];
    if (member == null || userId is! String) return false;
    return (member.manifest['members'] as List).any(
      (candidate) =>
          candidate is Map &&
          candidate['user_id'] == userId &&
          candidate['state'] == 'active' &&
          const {'owner', 'editor', 'viewer'}.contains(candidate['role']) &&
          (!requireOwner || candidate['role'] == 'owner'),
    );
  }

  Map<int, Uint8List> _selectEpochKeys(Map<String, Uint8List> byVersion) {
    final result = <int, Uint8List>{};
    for (final entry in byVersion.entries) {
      final parsed = _parseEpochKeyName(entry.key);
      if (entry.value.length != 32)
        throw const FormatException('Vault epoch key length is invalid.');
      final prior = result[parsed.$1];
      if (prior != null && !_bytesEqual(prior, entry.value)) {
        throw FormatException(currentL10n.keyEpochLocalMismatch(parsed.$1));
      }
      result.putIfAbsent(parsed.$1, () => entry.value);
    }
    if (result.isEmpty)
      {
throw FormatException(currentL10n.thisDeviceHasNoVaultEpoch);
}
    return result;
  }

  void _validateSnapshotManifest(
    List<Map<String, dynamic>> heads,
    List<VaultRevisionEntry> revisions, {
    required String highWatermark,
  }) {
    final high = BigInt.parse(_decimal(highWatermark, 'high_watermark'));
    final latest = <String, VaultRevisionEntry>{};
    for (final revision in revisions) {
      latest[revision.recordId] = revision;
    }
    final seen = <String>{};
    for (final head in heads) {
      final recordId = _string(head, 'record_id');
      final revisionId = _string(head, 'revision_id');
      final deleted = head['deleted'];
      final envelope = head['envelope'];
      if (deleted is! bool || envelope is! Map || !seen.add(recordId)) {
        throw FormatException(currentL10n.aSnapshotHeadIsMissingFields);
      }
      final historical = latest[recordId];
      if (historical == null ||
          historical.revisionId != revisionId ||
          historical.deleted != deleted ||
          canonicalJson(historical.envelope) != canonicalJson(envelope)) {
        throw FormatException(currentL10n.theSnapshotCurrentHeadIsInconsistent);
      }
      if (head.containsKey('commit_seq')) {
        final commitSeq = BigInt.parse(
          _decimal(head['commit_seq'], 'snapshot head commit_seq'),
        );
        if (commitSeq > high ||
            commitSeq != BigInt.parse(historical.commitSeq)) {
          throw FormatException(currentL10n.theSnapshotHeadCommitSeqDoesnt);
        }
      }
    }
    if (seen.length != latest.length) {
      throw FormatException(currentL10n.theSnapshotHeadSetDoesntCover);
    }
  }

  static List<String> _validateObjectRefs(Object? raw) {
    if (raw is! List || raw.length > 1024) {
      throw FormatException(currentL10n.objectRefsIsntAnArrayOr);
    }
    String? previous;
    for (final item in raw) {
      if (item is! String ||
          !_isCanonicalUuid(item) ||
          (previous != null && previous.compareTo(item) >= 0)) {
        throw FormatException(currentL10n.objectRefsMustBeUniqueLowercase);
      }
      previous = item;
    }
    return raw.cast<String>();
  }

  void _validateManifestShape(
    Map<String, dynamic> manifest, {
    required String expectedServerSpaceId,
    required String expectedVaultId,
    void Function(String phase)? onProgress,
  }) {
    onProgress?.call(currentL10n.checkingArchiveManifestTopLevelFields);
    const fields = {
      'format',
      'version',
      'created_at',
      'instance_id',
      'server_space_id',
      'account_id',
      'vault_id',
      'vault_role',
      'name_envelope',
      'snapshot',
      'devices',
      'membership_chain',
      'key_envelopes',
      'epoch_keys',
      'snapshot_heads',
      'graveyard',
      'revisions',
      'conflicts',
      'local_pending',
      'binary_blocks',
    };
    if (manifest.keys.toSet().difference(fields).isNotEmpty ||
        !manifest.keys.toSet().containsAll(fields) ||
        manifest['format'] != _format ||
        manifest['version'] != _version ||
        manifest['server_space_id'] != expectedServerSpaceId ||
        manifest['vault_id'] != expectedVaultId) {
      throw FormatException(currentL10n.theArchiveFormatFieldsAreInvalid);
    }
    onProgress?.call(currentL10n.checkingArchiveManifestIdentityAndRole);
    _canonicalUuid(_string(manifest, 'instance_id'), 'instance_id');
    _canonicalUuid(_string(manifest, 'account_id'), 'account_id');
    final role = _string(manifest, 'vault_role');
    if (!const {'owner', 'editor', 'viewer'}.contains(role)) {
      throw FormatException(currentL10n.unsupportedArchiveVaultRole);
    }
    if (manifest['created_at'] is! String ||
        DateTime.tryParse(manifest['created_at'] as String) == null) {
      throw FormatException(currentL10n.theArchiveCreatedAtIsntAn);
    }
    onProgress?.call(currentL10n.checkingArchiveManifestFieldTypes);
    if (manifest['snapshot'] is! Map ||
        manifest['devices'] is! List ||
        manifest['membership_chain'] is! List ||
        manifest['key_envelopes'] is! List ||
        manifest['epoch_keys'] is! List ||
        manifest['snapshot_heads'] is! List ||
        manifest['graveyard'] is! List ||
        manifest['revisions'] is! List ||
        manifest['conflicts'] is! List ||
        manifest['local_pending'] is! Map ||
        manifest['binary_blocks'] is! List) {
      throw FormatException(currentL10n.invalidArchiveFieldType);
    }
    final local = Map<String, dynamic>.from(manifest['local_pending'] as Map);
    if (local.keys.toSet().difference(const {
          'operations',
          'conflict_branches',
          'device_sequence_floors',
        }).isNotEmpty ||
        !local.keys.toSet().containsAll(const {
          'operations',
          'conflict_branches',
          'device_sequence_floors',
        }) ||
        local['operations'] is! List ||
        local['conflict_branches'] is! List) {
      throw FormatException(currentL10n.invalidArchiveLocalPendingSchema);
    }
    onProgress?.call(currentL10n.checkingArchiveSnapshotSchema);
    final snapshot = Map<String, dynamic>.from(manifest['snapshot'] as Map);
    _requireKeys(snapshot, const {
      'snapshot_id',
      'high_watermark',
      'conflict_high_watermark',
      'next_cursor',
      'server_generation',
    }, 'snapshot');
    _decimal(snapshot['high_watermark'], 'high_watermark');
    _decimal(snapshot['conflict_high_watermark'], 'conflict_high_watermark');
    if (snapshot['next_cursor'] is! String ||
        (snapshot['server_generation'] is! String)) {
      throw FormatException(currentL10n.invalidArchiveSnapshotCursorGeneration);
    }
    onProgress?.call(currentL10n.checkingArchiveManifestEntryLimits);
    const limits = <String, int>{
      'devices': 100000,
      'membership_chain': 10000,
      'key_envelopes': 10000,
      'epoch_keys': 10000,
      'snapshot_heads': _maxEntries,
      'revisions': _maxEntries,
      'conflicts': _maxEntries,
      'graveyard': _maxEntries,
      'binary_blocks': _maxObjects + 10000,
    };
    for (final entry in limits.entries) {
      final values = manifest[entry.key] as List;
      if (values.length > entry.value) {
        throw FormatException('${entry.key} exceeds the archive item limit.');
      }
    }
    onProgress?.call(currentL10n.checkingArchiveSnapshotHeadFields);
    for (final raw in manifest['snapshot_heads'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(
        item,
        const {'record_id', 'revision_id', 'deleted', 'envelope'},
        'snapshot head',
        optional: const {'commit_seq'},
      );
      if (item.containsKey('commit_seq')) {
        final sequence = BigInt.parse(
          _decimal(item['commit_seq'], 'snapshot head commit_seq'),
        );
        if (sequence >
            BigInt.parse(
              _decimal(snapshot['high_watermark'], 'high_watermark'),
            )) {
          throw FormatException(currentL10n.theSnapshotHeadCommitSeqExceeds);
        }
      }
    }
    onProgress?.call(currentL10n.checkingArchiveRevisionFields);
    for (final raw in manifest['revisions'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'record_id',
        'revision_id',
        'base_revision_id',
        'commit_seq',
        'operation',
        'deleted',
        'created_at',
        'envelope',
      }, 'revision entry');
    }
    onProgress?.call(currentL10n.checkingArchiveConflictFields);
    for (final raw in manifest['conflicts'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'conflict_id',
        'conflict_seq',
        'record_id',
        'base_revision_id',
        'resolved_revision_id',
        'resolution_seq',
        'created_at',
        'envelope',
      }, 'conflict entry');
    }
    onProgress?.call(currentL10n.checkingArchiveDeviceDirectoryFields);
    for (final raw in manifest['devices'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'device_id',
        'user_id',
        'name',
        'signing_public_key',
        'encryption_public_key',
        'status',
        'created_at',
      }, 'device directory entry');
    }
    onProgress?.call(currentL10n.checkingArchiveMembershipFields);
    _validateMembershipChainShape(
      manifest['membership_chain'] as List,
      expectedVaultId: expectedVaultId,
    );
    onProgress?.call(currentL10n.checkingArchiveOutboxFields);
    for (final raw in local['operations'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'op_id',
        'record_id',
        'base_revision_id',
        'base_envelope',
        'envelope',
        'status',
        'attempt_count',
        'created_at',
        'last_attempt_at',
      }, 'local outbox entry');
    }
    onProgress?.call(currentL10n.checkingArchiveConflictBranchFields);
    for (final raw in local['conflict_branches'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'conflict_id',
        'record_id',
        'kind',
        'branch_envelope',
        'remote_envelope',
        'state',
        'resolution_op_id',
        'resolution_revision_id',
        'created_at',
      }, 'local conflict branch');
    }
  }

  void _validateMembershipChainShape(
    List rawEntries, {
    required String expectedVaultId,
  }) {
    for (final raw in rawEntries) {
      final item = Map<String, dynamic>.from(raw as Map);
      _requireKeys(item, const {
        'membership_version',
        'previous_digest',
        'manifest',
        'digest',
        'signer_device_id',
        'signature',
        'created_at',
      }, 'membership chain entry');
      final version = _positiveInteger(
        item['membership_version'],
        'membership_version',
      );
      final previousDigest = item['previous_digest'];
      if (previousDigest != null && previousDigest is! String) {
        throw const FormatException('membership previous_digest is invalid.');
      }
      final rowSignature = _string(item, 'signature');
      if (item['manifest'] is! Map) {
        throw const FormatException('membership manifest must be an object.');
      }
      final storedManifest = Map<String, dynamic>.from(item['manifest'] as Map);
      final isSignedWrapper =
          storedManifest.containsKey('vault_id') ||
          storedManifest.containsKey('membership_version') ||
          storedManifest.containsKey('previous_digest') ||
          storedManifest.containsKey('signature') ||
          storedManifest.containsKey('manifest');
      final Map<String, dynamic> signedManifest;
      if (isSignedWrapper) {
        _requireKeys(storedManifest, const {
          'vault_id',
          'membership_version',
          'previous_digest',
          'manifest',
          'signature',
        }, 'signed membership wrapper');
        final wrapperVersion = _positiveInteger(
          storedManifest['membership_version'],
          'signed membership_version',
        );
        if (storedManifest['vault_id'] != expectedVaultId ||
            wrapperVersion != version ||
            storedManifest['previous_digest'] != previousDigest ||
            storedManifest['signature'] != rowSignature) {
          throw const FormatException(
            'signed membership wrapper context differs from its archive row.',
          );
        }
        if (storedManifest['manifest'] is! Map) {
          throw const FormatException(
            'signed membership wrapper manifest must be an object.',
          );
        }
        signedManifest = Map<String, dynamic>.from(
          storedManifest['manifest'] as Map,
        );
      } else {
        // Archives created before the API began returning the signed wrapper
        // stored only its inner body. It still passes through the exact same
        // signature-chain verifier in _loadArchiveTrust below.
        signedManifest = storedManifest;
      }
      _requireKeys(
        signedManifest,
        const {'key_epoch', 'members', 'signer_device_id'},
        'membership manifest',
        optional: const {'display_name_envelope'},
      );
      _positiveInteger(signedManifest['key_epoch'], 'membership key_epoch');
      final nameEnvelope = signedManifest['display_name_envelope'];
      if (nameEnvelope != null) {
        if (nameEnvelope is! Map) {
          throw const FormatException(
            'membership display_name_envelope must be an object.',
          );
        }
        final envelope = Map<String, dynamic>.from(nameEnvelope);
        _requireKeys(envelope, const {
          'version',
          'nonce',
          'ciphertext',
        }, 'membership display_name_envelope');
        if (envelope['version'] != 1 ||
            decodeBase64Url(_string(envelope, 'nonce')).length != 24 ||
            decodeBase64Url(_string(envelope, 'ciphertext')).length < 17) {
          throw const FormatException(
            'membership display_name_envelope shape is invalid.',
          );
        }
      }
      if (signedManifest['signer_device_id'] != item['signer_device_id']) {
        throw const FormatException(
          'membership signer differs from the signed manifest body.',
        );
      }
      if (signedManifest['members'] is! List ||
          (signedManifest['members'] as List).isEmpty ||
          (signedManifest['members'] as List).length > 100000) {
        throw const FormatException('membership members array is invalid.');
      }
      final memberIds = <String>{};
      for (final rawMember in signedManifest['members'] as List) {
        final member = Map<String, dynamic>.from(rawMember as Map);
        _requireKeys(member, const {
          'user_id',
          'role',
          'state',
          'encryption_key_fingerprint',
        }, 'membership member');
        _canonicalUuid(_string(member, 'user_id'), 'membership user_id');
        if (!memberIds.add(member['user_id'] as String) ||
            !const {'owner', 'editor', 'viewer'}.contains(member['role']) ||
            !const {'active', 'removed', 'invited'}.contains(member['state'])) {
          throw FormatException(currentL10n.invalidMembershipMemberRoleStateId);
        }
        final fingerprint = _string(member, 'encryption_key_fingerprint');
        if (decodeBase64Url(fingerprint).length != 32) {
          throw FormatException(currentL10n.invalidMembershipEncryptionFingerprint);
        }
      }
    }
  }

  List<_BinaryBlock> _validateBlocks(List raw, int binaryLength) {
    if (raw.length > _maxObjects + 10000) {
      throw FormatException(currentL10n.tooManyArchiveBinaryBlocks);
    }
    final blocks =
        raw
            .map((value) {
              final item = Map<String, dynamic>.from(value as Map);
              final kind = _string(item, 'kind');
              if (kind == 'object') {
                _requireKeys(item, const {
                  'kind',
                  'object_id',
                  'offset',
                  'length',
                  'sha256',
                }, 'object binary descriptor');
              } else if (kind == 'epoch_key') {
                _requireKeys(item, const {
                  'kind',
                  'key_epoch',
                  'membership_version',
                  'offset',
                  'length',
                  'key_sha256',
                  'signer_device_id',
                  'signature',
                }, 'epoch key binary descriptor');
              }
              final offset = _nonNegativeInteger(
                item['offset'],
                'binary offset',
              );
              final length = _positiveInteger(item['length'], 'binary length');
              if (kind == 'object') {
                return _BinaryBlock(
                  kind: kind,
                  offset: offset,
                  length: length,
                  objectId: _string(item, 'object_id'),
                  sha256: _string(item, 'sha256'),
                );
              }
              if (kind == 'epoch_key') {
                _positiveInteger(item['key_epoch'], 'binary key_epoch');
                _positiveInteger(
                  item['membership_version'],
                  'binary membership_version',
                );
                _canonicalUuid(
                  _string(item, 'signer_device_id'),
                  'binary signer_device_id',
                );
                _string(item, 'signature');
                _string(item, 'key_sha256');
                return _BinaryBlock(kind: kind, offset: offset, length: length);
              }
              throw FormatException(currentL10n.unsupportedArchiveBinaryBlockKind);
            })
            .toList(growable: false)
          ..sort((a, b) => a.offset.compareTo(b.offset));
    var cursor = 0;
    final ids = <String>{};
    for (final block in blocks) {
      if (block.offset != cursor || block.length > 32 * 1024 * 1024) {
        throw FormatException(currentL10n.archiveBinaryBlockOffsetsHaveGaps);
      }
      if (block.objectId != null && !ids.add(block.objectId!)) {
        throw FormatException(currentL10n.duplicateArchiveBinaryObjectId);
      }
      cursor += block.length;
    }
    if (cursor != binaryLength) {
      throw FormatException(currentL10n.theArchiveBinaryBlocksDontCover);
    }
    return blocks;
  }

  Map<String, int> _readSequenceFloors(Object? raw) {
    if (raw is! Map || raw.length > 100000)
      {
throw FormatException(currentL10n.invalidDeviceSequenceFloorsFormat);
}
    final result = <String, int>{};
    for (final entry in raw.entries) {
      final id = entry.key;
      _canonicalUuid(id, 'sequence device_id');
      final value = _positiveInteger(entry.value, 'device sequence floor');
      if (value >= 9007199254740000)
        {
throw FormatException(currentL10n.aDeviceSequenceFloorIsOut);
}
      result[id] = value;
    }
    return result;
  }

  void _raiseSequenceFloor(
    Map<String, int> floors,
    Map<String, dynamic> envelope,
  ) {
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw FormatException(currentL10n.anArchiveSignedEnvelopeIsMissing);
    }
    final header = Map<String, dynamic>.from(rawHeader);
    final deviceId = _string(header, 'device_id');
    _canonicalUuid(deviceId, 'sequence device_id');
    final sequence = BigInt.parse(_decimal(header['device_seq'], 'device_seq'));
    if (sequence >= BigInt.from(9007199254740000)) {
      throw FormatException(currentL10n.anArchiveRecordDeviceSeqIs);
    }
    final next = sequence.toInt() + 1;
    final current = floors[deviceId] ?? 1;
    if (next > current) floors[deviceId] = next;
  }

  void _validateContext(VaultArchiveContext context) {
    _canonicalUuid(context.instanceId, 'instance_id');
    _canonicalUuid(context.serverSpaceId, 'server_space_id');
    _canonicalUuid(context.accountId, 'account_id');
    _canonicalUuid(context.vault.id, 'vault_id');
    if (context.device.deviceId.isEmpty || context.vault.keyEnvelopes.isEmpty) {
      throw FormatException(currentL10n.theCurrentVaultDeviceIsntUnlocked);
    }
  }

  static Map<String, dynamic> _decodeObject(String json, String label) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) throw FormatException(currentL10n.labelMustBeAJsonObject(label));
    return Map<String, dynamic>.from(decoded);
  }

  static (int, int) _parseEpochKeyName(String value) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*):(0|[1-9][0-9]*)$',
    ).firstMatch(value);
    if (match == null) throw FormatException(currentL10n.invalidLocalEpochKeyIdentifierValuevalue(value));
    final epoch = int.parse(match.group(1)!);
    final version = int.parse(match.group(2)!);
    if (epoch < 1 || version < 1)
      {
throw FormatException(currentL10n.invalidLocalEpochKeyIdentifierValuevalue(value));
}
    return (epoch, version);
  }

  static String _string(Map<String, dynamic> object, String key) {
    final value = object[key];
    if (value is! String || value.isEmpty)
      {
throw FormatException(currentL10n.archiveFieldKeyIsMissingOr(key));
}
    return value;
  }

  static void _requireKeys(
    Map<String, dynamic> object,
    Set<String> required,
    String field, {
    Set<String> optional = const {},
  }) {
    if (object.keys.toSet().difference({...required, ...optional}).isNotEmpty ||
        !object.keys.toSet().containsAll(required)) {
      throw FormatException('$field contains unknown or missing fields.');
    }
  }

  static String _decimal(Object? raw, String field) {
    if (raw is! String || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
      throw FormatException(currentL10n.fieldMustBeADecimalString(field));
    }
    return raw;
  }

  static int _positiveInteger(Object? raw, String field) {
    if (raw is! int || raw < 1)
      throw FormatException('$field must be positive integer.');
    return raw;
  }

  static int _nonNegativeInteger(Object? raw, String field) {
    if (raw is! int || raw < 0)
      throw FormatException('$field must be non-negative integer.');
    return raw;
  }

  static void _canonicalUuid(String value, String field) {
    if (!_isCanonicalUuid(value))
      throw FormatException('$field must be a canonical lowercase UUID.');
  }

  static bool _isCanonicalUuid(String value) => RegExp(_uuid).hasMatch(value);

  static bool _isSupportedOperation(String? operation) =>
      const {'create', 'update', 'delete', 'restore'}.contains(operation);

  static Future<String> _sha256Hex(List<int> bytes) async {
    final digest = await cryptography.Sha256().hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String> _derivedUuid(String input) async {
    final digest = await cryptography.Sha256().hash(utf8.encode(input));
    final bytes = digest.bytes.sublist(0, 16);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static Future<String> _sha256B64(List<int> bytes) async {
    return encodeBase64Url((await cryptography.Sha256().hash(bytes)).bytes);
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}

class _ArchiveTrust {
  const _ArchiveTrust({
    required this.directory,
    required this.signerKeys,
    required this.rawMemberships,
    required this.memberships,
  });

  final Map<String, Map<String, dynamic>> directory;
  final Map<String, Uint8List> signerKeys;
  final List<Map<String, dynamic>> rawMemberships;
  final List<VerifiedMembership> memberships;
}

class _BinaryBlock {
  const _BinaryBlock({
    required this.kind,
    required this.offset,
    required this.length,
    this.objectId,
    this.sha256,
  });

  final String kind;
  final int offset;
  final int length;
  final String? objectId;
  final String? sha256;
}
