import 'dart:convert';

import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _instanceId = '11111111-1111-4111-8111-111111111111';
const _serverSpaceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _recordId = '44444444-4444-4444-8444-444444444444';
const _otherRecordId = '55555555-5555-4555-8555-555555555555';
const _deletedRevisionId = '66666666-6666-4666-8666-666666666666';
const _localRevisionId = '77777777-7777-4777-8777-777777777777';
const _redactionId = '88888888-8888-4888-8888-888888888888';
const _generation = '99999999-9999-4999-8999-999999999999';
const _snapshotId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _operationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _otherInstanceId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _otherServerSpaceId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

Map<String, dynamic> _proof() => {
  'format': 'atermius-record-redaction-proof-v1',
  'redaction_id': _redactionId,
  'instance_id': _instanceId,
  'server_space_id': _serverSpaceId,
  'vault_id': _vaultId,
  'record_id': _recordId,
  'deleted_revision_id': _deletedRevisionId,
  'deleted_seq': '8',
  'redaction_seq': '9',
  'signing_public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  'signature':
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
};

const _scope = SnapshotRecoveryScope(
  serverNamespace: 'https://sync.example.test',
  accountId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  instanceId: _instanceId,
  serverSpaceId: _serverSpaceId,
  vaultId: _vaultId,
  serverGeneration: _generation,
);

Future<void> _beginStage(ClientDatabase database, int itemCount) =>
    database.beginSnapshotRecoveryStage(
      scope: _scope,
      snapshotId: _snapshotId,
      highWatermark: '20',
      conflictHighWatermark: '0',
      checkpointCursor: 'snapshot-cursor',
      expiresAt: '2030-01-01T00:00:00Z',
      itemCountPresent: true,
      expectedItemCount: itemCount,
      createdAt: 1,
    );

Future<void> _persistStage(
  ClientDatabase database,
  List<SnapshotHead> heads,
) async {
  await database.persistSnapshotRecoveryPage(
    scope: _scope,
    snapshotId: _snapshotId,
    highWatermark: '20',
    conflictHighWatermark: '0',
    checkpointCursor: 'snapshot-cursor',
    expiresAt: '2030-01-01T00:00:00Z',
    requestedPageCursor: null,
    heads: heads,
    serializedHeadBytes: heads.length,
    pageItemCountPresent: true,
    pageItemCount: heads.length,
    legacyFullManifest: false,
    hasMore: false,
    nextPageCursor: null,
  );
}

SnapshotHead _liveHead(String recordId, String revisionId) => SnapshotHead(
  recordId: recordId,
  revisionId: revisionId,
  deleted: false,
  envelope: {
    'header': {'record_id': recordId},
    'nonce': 'opaque',
    'ciphertext': 'opaque',
    'signature': 'opaque',
  },
  commitSeq: '10',
);

void main() {
  test(
    'redaction erases active bytes, quarantines outbox, and blocks writes',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      const oldEnvelope = {'ciphertext': 'old-server-ciphertext'};
      const localEnvelope = {
        'header': {
          'op_id': _operationId,
          'record_id': _recordId,
          'revision_id': _localRevisionId,
          'operation': 'update',
        },
        'ciphertext': 'pending-local-ciphertext',
      };
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: _deletedRevisionId,
        envelope: oldEnvelope,
        commitSeq: '8',
        deleted: true,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.putLocalOperation(
        vaultId: _vaultId,
        recordId: _recordId,
        baseRevisionId: _deletedRevisionId,
        envelope: localEnvelope,
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _otherRecordId,
        revisionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        envelope: const {'ciphertext': 'unrelated-live-cache'},
        commitSeq: '6',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database
          .into(database.authenticatedPushReceipts)
          .insert(
            AuthenticatedPushReceiptsCompanion.insert(
              opId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_instanceId),
              serverSpaceId: const Value(_serverSpaceId),
              revisionId: _deletedRevisionId,
              envelopeJson: jsonEncode(oldEnvelope),
              commitSeq: '8',
            ),
          );

      await database.applyRecordRedaction(
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        serverGeneration: _generation,
        proof: _proof(),
      );

      expect(
        (await database.cachedEnvelopes(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).map((row) => row.recordId),
        [_otherRecordId],
      );
      expect(
        await database.countPending(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        0,
      );
      expect(
        await database.queuedOperations(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        isEmpty,
      );
      expect(
        await database.select(database.authenticatedPushReceipts).get(),
        isEmpty,
      );
      final quarantined = await (database.select(
        database.pendingOperations,
      )..where((row) => row.opId.equals(_operationId))).getSingle();
      expect(quarantined.status, 'redacted');
      expect(quarantined.envelopeJson, jsonEncode(localEnvelope));
      expect(quarantined.baseEnvelopeJson, isNull);
      final drafts = await database.openConflicts(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      expect(drafts, hasLength(1));
      expect(drafts.single.kind, 'record_redacted');
      expect(drafts.single.state, 'redacted_draft');
      expect(drafts.single.branchEnvelopeJson, jsonEncode(localEnvelope));
      expect(jsonDecode(drafts.single.redactionProofJson!), _proof());
      expect(
        await database.redactionProofForRecord(
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        _proof(),
      );

      await expectLater(
        database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: _deletedRevisionId,
          envelope: oldEnvelope,
          commitSeq: '8',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        throwsStateError,
      );
      await expectLater(
        database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: _deletedRevisionId,
          envelope: localEnvelope,
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        throwsStateError,
      );
    },
  );

  test('outbox fingerprint binds the authenticated server scope', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final first = await database.pendingOutboxFingerprint(
      _vaultId,
      instanceId: _instanceId,
      serverSpaceId: _serverSpaceId,
    );
    final second = await database.pendingOutboxFingerprint(
      _vaultId,
      instanceId: _otherInstanceId,
      serverSpaceId: _otherServerSpaceId,
    );
    expect(first, isNot(second));
  });

  test(
    'snapshot resurrection fails atomically across server generations',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        envelope: const {'ciphertext': 'live-before-redaction'},
        commitSeq: '7',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _otherRecordId,
        revisionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        envelope: const {'ciphertext': 'unrelated-live-cache'},
        commitSeq: '6',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'old-checkpoint',
        serverGeneration: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.applyRecordRedaction(
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        serverGeneration: _generation,
        proof: _proof(),
      );
      await _beginStage(database, 1);
      await _persistStage(database, [
        _liveHead(_recordId, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
      ]);

      await expectLater(
        database.applyStagedVaultSnapshot(
          scope: _scope,
          snapshotId: _snapshotId,
        ),
        throwsA(isA<SnapshotRedactionResurrectionException>()),
      );

      final cache = await database.cachedEnvelopes(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      expect(cache.map((row) => row.recordId), [_otherRecordId]);
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.cursor,
        'old-checkpoint',
      );
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.serverGeneration,
        'ffffffff-ffff-4fff-8fff-ffffffffffff',
      );
      expect(
        (await database.resumableSnapshotRecoveryStage(
          _scope,
          now: DateTime.utc(2029),
        ))?.complete,
        isTrue,
      );
    },
  );

  test(
    'graveyard rows and live heads apply as one complete snapshot union',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        revisionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        envelope: const {'ciphertext': 'old-cache'},
        commitSeq: '4',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'old-checkpoint',
        serverGeneration: _generation,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await _beginStage(database, 2);
      await _persistStage(database, [
        SnapshotHead(
          recordId: _recordId,
          revisionId: _deletedRevisionId,
          deleted: true,
          envelope: const {},
          redactionProof: _proof(),
        ),
        _liveHead(_otherRecordId, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
      ]);

      await database.applyStagedVaultSnapshot(
        scope: _scope,
        snapshotId: _snapshotId,
      );

      final cache = await database.cachedEnvelopes(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      expect(cache.map((row) => row.recordId), [_otherRecordId]);
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.cursor,
        'snapshot-cursor',
      );
      expect(
        await database.redactionProofForRecord(
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        _proof(),
      );
    },
  );

  test(
    'same Vault and record UUID coexist across instances during snapshot and redaction',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: _deletedRevisionId,
        envelope: const {
          'header': {'scope': 'instance-a'},
          'ciphertext': 'a',
        },
        commitSeq: '8',
        deleted: true,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        envelope: const {
          'header': {'scope': 'instance-b'},
          'ciphertext': 'b',
        },
        commitSeq: '12',
        deleted: false,
        instanceId: _otherInstanceId,
        serverSpaceId: _otherServerSpaceId,
      );

      await _beginStage(database, 1);
      await _persistStage(database, [
        _liveHead(_recordId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      ]);
      await database.applyStagedVaultSnapshot(
        scope: _scope,
        snapshotId: _snapshotId,
      );
      final instanceAHead = await database.cachedEnvelope(
        _vaultId,
        _recordId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      final instanceBHead = await database.cachedEnvelope(
        _vaultId,
        _recordId,
        instanceId: _otherInstanceId,
        serverSpaceId: _otherServerSpaceId,
      );
      expect(instanceAHead?.revisionId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(instanceBHead?.revisionId, 'ffffffff-ffff-4fff-8fff-ffffffffffff');
      await database.putLocalOperation(
        vaultId: _vaultId,
        recordId: _recordId,
        baseRevisionId: instanceAHead!.revisionId,
        expectedCachedHeadRevisionId: instanceAHead.revisionId,
        envelope: const {
          'header': {
            'op_id': _operationId,
            'record_id': _recordId,
            'revision_id': 'bbbbbbbb-cccc-4bbb-8bbb-bbbbbbbbbbbb',
            'operation': 'update',
          },
          'ciphertext': 'instance-a-draft',
        },
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.putLocalOperation(
        vaultId: _vaultId,
        recordId: _recordId,
        baseRevisionId: instanceBHead!.revisionId,
        expectedCachedHeadRevisionId: instanceBHead.revisionId,
        envelope: const {
          'header': {
            'op_id': 'cccccccc-dddd-4ccc-8ccc-cccccccccccc',
            'record_id': _recordId,
            'revision_id': 'bbbbbbbb-dddd-4bbb-8bbb-bbbbbbbbbbbb',
            'operation': 'update',
          },
          'ciphertext': 'instance-b-draft',
        },
        deleted: false,
        instanceId: _otherInstanceId,
        serverSpaceId: _otherServerSpaceId,
      );
      await database
          .into(database.authenticatedPushReceipts)
          .insert(
            AuthenticatedPushReceiptsCompanion.insert(
              opId: 'cccccccc-eeee-4ccc-8ccc-cccccccccccc',
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_otherInstanceId),
              serverSpaceId: const Value(_otherServerSpaceId),
              revisionId: 'bbbbbbbb-dddd-4bbb-8bbb-bbbbbbbbbbbb',
              envelopeJson: jsonEncode(const {
                'header': {'scope': 'instance-b'},
                'ciphertext': 'instance-b-receipt',
              }),
              commitSeq: '12',
            ),
          );
      await database
          .into(database.conflictBranches)
          .insert(
            ConflictBranchesCompanion.insert(
              conflictId: 'cccccccc-ffff-4ccc-8ccc-cccccccccccc',
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_otherInstanceId),
              serverSpaceId: const Value(_otherServerSpaceId),
              kind: 'concurrent_edit',
              branchEnvelopeJson: jsonEncode(const {
                'header': {'scope': 'instance-b'},
                'ciphertext': 'instance-b-conflict',
              }),
              remoteEnvelopeJson: '{}',
              createdAt: 1,
            ),
          );
      await database
          .into(database.feedConflictResolutions)
          .insert(
            FeedConflictResolutionsCompanion.insert(
              conflictId: 'dddddddd-ffff-4ddd-8ddd-dddddddddddd',
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_otherInstanceId),
              serverSpaceId: const Value(_otherServerSpaceId),
              resolutionRevisionId: 'bbbbbbbb-dddd-4bbb-8bbb-bbbbbbbbbbbb',
              state: 'committed',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database
          .into(database.conflictFeedInbox)
          .insert(
            ConflictFeedInboxCompanion.insert(
              vaultId: _vaultId,
              serverGeneration: _generation,
              instanceId: const Value(_otherInstanceId),
              serverSpaceId: const Value(_otherServerSpaceId),
              partitionId: 'instance-b-partition',
              seq: '13',
              conflictId: 'eeeeeeee-ffff-4eee-8eee-eeeeeeeeeeee',
              eventType: 'created',
              eventJson: jsonEncode({
                'type': 'created',
                'seq': '13',
                'conflict_id': 'eeeeeeee-ffff-4eee-8eee-eeeeeeeeeeee',
                'record_id': _recordId,
              }),
            ),
          );
      await database.beginBlobJob(
        jobId:
            'download:$_otherInstanceId:$_otherServerSpaceId:$_vaultId:$_recordId:blob-b',
        vaultId: _vaultId,
        recordId: _recordId,
        blobId: 'blob-b',
        direction: 'download',
        state: 'downloading',
        instanceId: _otherInstanceId,
        serverSpaceId: _otherServerSpaceId,
      );

      await database.applyRecordRedaction(
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        serverGeneration: _generation,
        proof: _proof(),
      );
      expect(
        await database.cachedEnvelope(
          _vaultId,
          _recordId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        isNull,
      );
      expect(
        (await database.cachedEnvelope(
          _vaultId,
          _recordId,
          instanceId: _otherInstanceId,
          serverSpaceId: _otherServerSpaceId,
        ))?.revisionId,
        'bbbbbbbb-dddd-4bbb-8bbb-bbbbbbbbbbbb',
      );
      final instanceAOutbox = await database.allPendingOperations(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      final instanceBOutbox = await database.allPendingOperations(
        _vaultId,
        instanceId: _otherInstanceId,
        serverSpaceId: _otherServerSpaceId,
      );
      expect(instanceAOutbox.single.status, 'redacted');
      expect(instanceBOutbox.single.status, 'queued');
      expect(
        (await database.select(database.authenticatedPushReceipts).get())
            .single
            .instanceId,
        _otherInstanceId,
      );
      expect(
        (await database.openConflicts(
          _vaultId,
          instanceId: _otherInstanceId,
          serverSpaceId: _otherServerSpaceId,
        )).single.state,
        'open',
      );
      expect(
        (await database.select(database.feedConflictResolutions).get())
            .single
            .state,
        'committed',
      );
      expect(
        (await database.select(database.conflictFeedInbox).get())
            .single
            .eventType,
        'created',
      );
      expect(
        (await database.select(database.blobJobs).get()).single.instanceId,
        _otherInstanceId,
      );
      expect(
        await database.redactionProofForRecord(
          instanceId: _otherInstanceId,
          serverSpaceId: _otherServerSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        isNull,
      );
    },
  );

  test(
    'legacy null-provenance operation aborts redaction without moving checkpoint',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: _deletedRevisionId,
        envelope: const {
          'header': {'scope': 'instance-a'},
          'ciphertext': 'a',
        },
        commitSeq: '8',
        deleted: true,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database
          .into(database.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              opId: _operationId,
              vaultId: _vaultId,
              recordId: _recordId,
              baseRevisionId: Value(_deletedRevisionId),
              envelopeJson: jsonEncode(const {'ciphertext': 'legacy-pending'}),
              createdAt: 1,
            ),
          );
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'cursor-before-redaction',
        serverGeneration: _generation,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );

      await expectLater(
        database.applyRecordRedaction(
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          serverGeneration: _generation,
          proof: _proof(),
        ),
        throwsStateError,
      );
      expect(
        (await database.cachedEnvelope(
          _vaultId,
          _recordId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.revisionId,
        _deletedRevisionId,
      );
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.cursor,
        'cursor-before-redaction',
      );
      expect(
        await database.redactionProofForRecord(
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        isNull,
      );
      expect(
        (await database.select(database.pendingOperations).getSingle()).status,
        'queued',
      );
    },
  );

  test(
    'legacy null-provenance cache blocks scoped snapshot replacement atomically',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database
          .into(database.encryptedRecords)
          .insert(
            EncryptedRecordsCompanion.insert(
              vaultId: _vaultId,
              recordId: _recordId,
              revisionId: _deletedRevisionId,
              envelopeJson: jsonEncode(const {'ciphertext': 'legacy-cache'}),
              isDeleted: const Value(true),
              commitSeq: const Value('8'),
              updatedAt: 1,
            ),
          );
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'cursor-before-snapshot',
        serverGeneration: _generation,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await _beginStage(database, 1);
      await _persistStage(database, [
        _liveHead(_recordId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      ]);

      await expectLater(
        database.applyStagedVaultSnapshot(
          scope: _scope,
          snapshotId: _snapshotId,
        ),
        throwsStateError,
      );

      final legacyCache = await database
          .select(database.encryptedRecords)
          .get();
      expect(legacyCache, hasLength(1));
      expect(
        legacyCache.single.envelopeJson,
        jsonEncode(const {'ciphertext': 'legacy-cache'}),
      );
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.cursor,
        'cursor-before-snapshot',
      );
      expect(
        (await database.resumableSnapshotRecoveryStage(
          _scope,
          now: DateTime.utc(2029),
        ))?.complete,
        isTrue,
      );
    },
  );

  test(
    'scoped snapshot leaves the legacy checkpoint sentinel untouched',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'legacy-unknown-cursor',
        serverGeneration: _generation,
      );
      await _beginStage(database, 1);
      await _persistStage(database, [_liveHead(_recordId, _deletedRevisionId)]);
      await database.applyStagedVaultSnapshot(
        scope: _scope,
        snapshotId: _snapshotId,
      );
      final checkpoints = await (database.select(
        database.syncCheckpoints,
      )..where((row) => row.vaultId.equals(_vaultId))).get();
      expect(
        checkpoints
            .singleWhere(
              (row) => row.instanceId.isEmpty && row.serverSpaceId.isEmpty,
            )
            .cursor,
        'legacy-unknown-cursor',
      );
      expect(
        (await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ))?.cursor,
        'snapshot-cursor',
      );
    },
  );
}
