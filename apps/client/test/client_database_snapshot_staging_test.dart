import 'dart:io';

import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _scope = SnapshotRecoveryScope(
  serverNamespace: 'https://sync.example.test',
  accountId: '11111111-1111-4111-8111-111111111111',
  instanceId: '22222222-2222-4222-8222-222222222222',
  serverSpaceId: '33333333-3333-4333-8333-333333333333',
  vaultId: '44444444-4444-4444-8444-444444444444',
  serverGeneration: '55555555-5555-4555-8555-555555555555',
);
const _snapshotId = '66666666-6666-4666-8666-666666666666';
const _checkpointCursor = 'snapshot-watermark-cursor';
const _expiresAt = '2030-01-01T00:00:00Z';

ClientDatabase _openDatabase() =>
    ClientDatabase.forTesting(NativeDatabase.memory());

Future<void> _beginStage(
  ClientDatabase database, {
  int? expectedItemCount,
  bool itemCountPresent = false,
}) => database.beginSnapshotRecoveryStage(
  scope: _scope,
  snapshotId: _snapshotId,
  highWatermark: '10',
  conflictHighWatermark: '0',
  checkpointCursor: _checkpointCursor,
  expiresAt: _expiresAt,
  itemCountPresent: itemCountPresent,
  expectedItemCount: expectedItemCount,
  createdAt: 1,
);

Future<SnapshotRecoveryStage> _persist({
  required ClientDatabase database,
  required String? requestedCursor,
  required List<SnapshotHead> heads,
  required bool hasMore,
  required String? nextCursor,
  bool itemCountPresent = false,
  int? itemCount,
}) => database.persistSnapshotRecoveryPage(
  scope: _scope,
  snapshotId: _snapshotId,
  highWatermark: '10',
  conflictHighWatermark: '0',
  checkpointCursor: _checkpointCursor,
  expiresAt: _expiresAt,
  requestedPageCursor: requestedCursor,
  heads: heads,
  serializedHeadBytes: heads.length,
  pageItemCountPresent: itemCountPresent,
  pageItemCount: itemCount,
  legacyFullManifest: false,
  hasMore: hasMore,
  nextPageCursor: nextCursor,
);

SnapshotHead _head(String recordId) => SnapshotHead(
  recordId: recordId,
  revisionId: 'revision-$recordId',
  deleted: false,
  envelope: {
    'header': {'record_id': recordId},
    'nonce': 'opaque',
    'ciphertext': 'opaque',
    'signature': 'opaque',
  },
  commitSeq: '1',
);

void main() {
  test(
    'page item and continuation cursor roll back together on insert failure',
    () async {
      final database = _openDatabase();
      addTearDown(database.close);
      await _beginStage(database);
      var stage = await _persist(
        database: database,
        requestedCursor: null,
        heads: [_head('a')],
        hasMore: true,
        nextCursor: 'cursor-1',
      );
      expect(stage.verifiedItemCount, 1);
      expect(stage.nextPageCursor, 'cursor-1');

      await database.customStatement(
        "CREATE TRIGGER reject_snapshot_item BEFORE INSERT ON sync_snapshot_recovery_items "
        "WHEN NEW.record_id = 'b' BEGIN SELECT RAISE(ABORT, 'injected page failure'); END",
      );
      await expectLater(
        _persist(
          database: database,
          requestedCursor: 'cursor-1',
          heads: [_head('b'), _head('c')],
          hasMore: true,
          nextCursor: 'cursor-2',
        ),
        throwsA(anything),
      );

      stage = (await database.resumableSnapshotRecoveryStage(
        _scope,
        now: DateTime.utc(2029),
      ))!;
      expect(stage.verifiedItemCount, 1);
      expect(stage.lastRecordId, 'a');
      expect(stage.nextPageCursor, 'cursor-1');
      final rows = await database.snapshotRecoveryStagedHeads(
        scope: _scope,
        snapshotId: _snapshotId,
        afterOrdinal: -1,
      );
      expect(rows.map((row) => row.recordId), ['a']);
      final cursor2 = await database
          .customSelect(
            'SELECT COUNT(*) AS count FROM sync_snapshot_recovery_cursors '
            'WHERE snapshot_id = ? AND cursor = ?',
            variables: [
              Variable.withString(_snapshotId),
              Variable.withString('cursor-2'),
            ],
          )
          .getSingle();
      expect(cursor2.read<int>('count'), 0);
    },
  );

  test(
    'failed final activation preserves cache checkpoint and complete stage',
    () async {
      final database = _openDatabase();
      addTearDown(database.close);
      await database.storeRemoteEnvelope(
        vaultId: _scope.vaultId,
        recordId: 'old-record',
        revisionId: 'old-revision',
        envelope: const {'ciphertext': 'old-ciphertext'},
        commitSeq: '4',
        deleted: false,
      );
      await database.saveCheckpoint(
        vaultId: _scope.vaultId,
        cursor: 'old-checkpoint',
        serverGeneration: 'old-generation',
      );
      await _beginStage(database, expectedItemCount: 1, itemCountPresent: true);
      final completeStage = await _persist(
        database: database,
        requestedCursor: null,
        heads: [_head('new-record')],
        hasMore: false,
        nextCursor: null,
        itemCountPresent: true,
        itemCount: 1,
      );
      expect(completeStage.complete, isTrue);
      await database.customStatement(
        "CREATE TRIGGER reject_snapshot_checkpoint BEFORE INSERT ON sync_checkpoints "
        "BEGIN SELECT RAISE(ABORT, 'injected activation failure'); END",
      );

      await expectLater(
        database.applyStagedVaultSnapshot(
          scope: _scope,
          snapshotId: _snapshotId,
        ),
        throwsA(anything),
      );

      expect(
        (await database.cachedEnvelopes(
          _scope.vaultId,
        )).map((row) => row.recordId),
        ['old-record'],
      );
      expect(
        (await database.checkpoint(_scope.vaultId))?.cursor,
        'old-checkpoint',
      );
      final stage = await database.resumableSnapshotRecoveryStage(
        _scope,
        now: DateTime.utc(2029),
      );
      expect(stage?.complete, isTrue);
      expect(
        (await database.snapshotRecoveryStagedHeads(
          scope: _scope,
          snapshotId: _snapshotId,
          afterOrdinal: -1,
        )).map((row) => row.recordId),
        ['new-record'],
      );
    },
  );

  test(
    'bad staged count, cursor and record ordering cannot advance a page',
    () async {
      final database = _openDatabase();
      addTearDown(database.close);
      await _beginStage(database, expectedItemCount: 3, itemCountPresent: true);
      final firstPage = await _persist(
        database: database,
        requestedCursor: null,
        heads: [_head('a')],
        hasMore: true,
        nextCursor: 'cursor-1',
        itemCountPresent: true,
        itemCount: 3,
      );
      expect(firstPage.nextPageCursor, 'cursor-1');

      Future<void> reject({
        required String? requestedCursor,
        required List<SnapshotHead> heads,
        required String? nextCursor,
        int itemCount = 3,
      }) async => expectLater(
        _persist(
          database: database,
          requestedCursor: requestedCursor,
          heads: heads,
          hasMore: true,
          nextCursor: nextCursor,
          itemCountPresent: true,
          itemCount: itemCount,
        ),
        throwsA(anything),
      );

      await reject(
        requestedCursor: 'uncommitted-cursor',
        heads: [_head('b')],
        nextCursor: 'cursor-2',
      );
      await reject(
        requestedCursor: 'cursor-1',
        heads: [_head('b')],
        nextCursor: 'cursor-2',
        itemCount: 4,
      );
      await reject(
        requestedCursor: 'cursor-1',
        heads: [_head('a')],
        nextCursor: 'cursor-2',
      );
      await reject(
        requestedCursor: 'cursor-1',
        heads: [_head('0')],
        nextCursor: 'cursor-2',
      );
      await reject(
        requestedCursor: 'cursor-1',
        heads: [_head('b')],
        nextCursor: 'cursor-1',
      );

      final stage = (await database.resumableSnapshotRecoveryStage(
        _scope,
        now: DateTime.utc(2029),
      ))!;
      expect(stage.verifiedItemCount, 1);
      expect(stage.nextPageCursor, 'cursor-1');
      expect(stage.lastRecordId, 'a');
    },
  );

  test(
    'schema v7 upgrade creates staging tables and preserves the cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-snapshot-stage-migration-',
      );
      final file = File('${directory.path}/client.sqlite');
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      await database.storeRemoteEnvelope(
        vaultId: _scope.vaultId,
        recordId: 'existing-record',
        revisionId: 'existing-revision',
        envelope: const {'ciphertext': 'existing-ciphertext'},
        commitSeq: '9',
        deleted: false,
      );
      await database.customStatement('DROP TABLE sync_snapshot_recovery_items');
      await database.customStatement(
        'DROP TABLE sync_snapshot_recovery_cursors',
      );
      await database.customStatement(
        'DROP TABLE sync_snapshot_recovery_stages',
      );
      await database.customStatement('PRAGMA user_version = 7');
      await database.close();

      final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await upgraded.close();
        await directory.delete(recursive: true);
      });
      final tables = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'sync_snapshot_recovery_%'",
          )
          .get();
      expect(tables.map((row) => row.read<String>('name')).toSet(), {
        'sync_snapshot_recovery_stages',
        'sync_snapshot_recovery_items',
        'sync_snapshot_recovery_cursors',
      });
      expect(
        (await upgraded.cachedEnvelopes(_scope.vaultId)).single.envelopeJson,
        '{"ciphertext":"existing-ciphertext"}',
      );
    },
  );
}
