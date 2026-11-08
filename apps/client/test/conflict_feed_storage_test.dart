import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';
const _instanceId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _serverSpaceId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _conflictId = '55555555-5555-4555-8555-555555555555';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _resolvedRevision = '66666666-6666-4666-8666-666666666666';
const _generationA = '77777777-7777-4777-8777-777777777777';
const _generationB = '88888888-8888-4888-8888-888888888888';
const _chainOp1 = '99999999-9999-4999-8999-999999999991';
const _chainOp2 = '99999999-9999-4999-8999-999999999992';
const _unrelatedOp = '99999999-9999-4999-8999-999999999993';
const _chainRevision1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const _chainRevision2 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
const _unrelatedRevision = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3';
const _redactionProof = <String, dynamic>{
  'format': 'atermius-record-redaction-proof-v1',
  'redaction_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'instance_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'server_space_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'vault_id': _vaultId,
  'record_id': _recordId,
  'deleted_revision_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  'deleted_seq': '8',
  'redaction_seq': '9',
  'signing_public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  'signature':
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
};

void main() {
  test(
    'inbox checkpoint is generation-scoped and replay is idempotent',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final page = _page(
        generation: _generationA,
        after: '0',
        highWatermark: '2',
        next: '2',
        events: [
          _created(seq: '1'),
          _resolved(seq: '2'),
        ],
      );

      await database.saveConflictChangesPage(
        page,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.saveConflictChangesPage(
        page,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );

      expect(
        await database.conflictFeedCursor(
          _vaultId,
          _generationA,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        '2',
      );
      expect(
        await database.conflictFeedCursor(
          _vaultId,
          _generationB,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        '0',
      );
      final inbox = await database.listConflictFeedInbox(
        _vaultId,
        _generationA,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      expect(inbox.map((event) => event.type), ['created', 'resolved']);
      expect(inbox.last.resolvedRevisionId, _resolvedRevision);
      // The independent feed is only an inbox; it leaves record heads and the
      // user-facing ConflictBranches table untouched.
      expect(
        await database.cachedEnvelopes(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        isEmpty,
      );
      expect(
        await database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        isEmpty,
      );

      await database.close();
    },
  );

  test(
    'resolved feed event closes matching uploaded local branch and preserves ciphertext',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const branchEnvelope = {'ciphertext': 'branch-secret-bytes'};
      const remoteEnvelope = {'ciphertext': 'remote-secret-bytes'};
      await database.saveConflict(
        conflictId: _conflictId,
        vaultId: _vaultId,
        recordId: _recordId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        kind: 'concurrent_edit',
        branchEnvelope: branchEnvelope,
        remoteEnvelope: remoteEnvelope,
      );

      await database.saveConflictChangesPage(
        _page(
          generation: _generationA,
          after: '0',
          highWatermark: '2',
          next: '2',
          events: [
            _created(seq: '1'),
            _resolved(seq: '2'),
          ],
        ),
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );

      expect(
        await database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        ),
        isEmpty,
      );
      final history = await (database.select(
        database.conflictBranches,
      )..where((row) => row.conflictId.equals(_conflictId))).getSingle();
      expect(history.state, 'resolved');
      expect(
        history.branchEnvelopeJson,
        '{"ciphertext":"branch-secret-bytes"}',
      );
      expect(
        history.remoteEnvelopeJson,
        '{"ciphertext":"remote-secret-bytes"}',
      );
      expect(
        (await database.listConflictFeedInbox(
          _vaultId,
          _generationA,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).map((event) => event.type),
        ['created', 'resolved'],
      );

      await database.close();
    },
  );

  test(
    'remote resolution retires only the exact local conflict outbox chain',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final firstEnvelope = _operationEnvelope(
        opId: _chainOp1,
        revisionId: _chainRevision1,
      );
      final branchEnvelope = _operationEnvelope(
        opId: _chainOp2,
        revisionId: _chainRevision2,
      );
      final unrelatedEnvelope = _operationEnvelope(
        opId: _unrelatedOp,
        revisionId: _unrelatedRevision,
      );
      await database.saveConflict(
        conflictId: _conflictId,
        vaultId: _vaultId,
        recordId: _recordId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        kind: 'concurrent_edit',
        branchEnvelope: branchEnvelope,
        remoteEnvelope: const {'ciphertext': 'remote-opaque-bytes'},
      );
      await _insertConflictOperation(
        database,
        opId: _chainOp1,
        envelope: firstEnvelope,
      );
      await _insertConflictOperation(
        database,
        opId: _chainOp2,
        baseRevisionId: _chainRevision1,
        baseEnvelope: jsonEncode(firstEnvelope),
        envelope: branchEnvelope,
      );
      await _insertConflictOperation(
        database,
        opId: _unrelatedOp,
        envelope: unrelatedEnvelope,
      );

      expect(await database.countPending(_vaultId), 3);
      await database.saveConflictChangesPage(
        _page(
          generation: _generationA,
          after: '0',
          highWatermark: '2',
          next: '2',
          events: [
            _created(seq: '1'),
            _resolved(seq: '2'),
          ],
        ),
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );

      expect(await database.countPending(_vaultId), 1);
      expect(
        (await database.allPendingOperations(_vaultId)).single.opId,
        _unrelatedOp,
      );
      final retired = await database.supersededOperations(_vaultId);
      expect(retired.map((operation) => operation.opId).toSet(), {
        _chainOp1,
        _chainOp2,
      });
      expect(
        retired.every((operation) => operation.status == 'superseded'),
        isTrue,
      );
      expect(
        (await database.allPendingOperations(_vaultId)).single.status,
        'conflict',
      );
      final history = await (database.select(
        database.conflictBranches,
      )..where((row) => row.conflictId.equals(_conflictId))).getSingle();
      expect(history.state, 'resolved');
      expect(history.branchEnvelopeJson, jsonEncode(branchEnvelope));
      expect(
        history.remoteEnvelopeJson,
        '{"ciphertext":"remote-opaque-bytes"}',
      );
      expect(
        (await database.listConflictFeedInbox(
          _vaultId,
          _generationA,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).map((event) => event.type),
        ['created', 'resolved'],
      );

      await database.close();
    },
  );

  test(
    'a conflicting replay rolls back earlier events and cursor update',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const otherConflict = '77777777-7777-4777-8777-777777777777';
      final seeded = ConflictChangeEvent.fromJson({
        ..._created(seq: '2'),
        'conflict_id': otherConflict,
      });
      await database
          .into(database.conflictFeedInbox)
          .insert(
            ConflictFeedInboxCompanion.insert(
              vaultId: _vaultId,
              serverGeneration: _generationA,
              partitionId: 'legacy-$_generationA',
              seq: '2',
              conflictId: otherConflict,
              eventType: 'created',
              eventJson: seeded.canonicalEventJson,
            ),
          );
      final page = _page(
        generation: _generationA,
        after: '0',
        highWatermark: '2',
        next: '2',
        events: [
          _created(seq: '1'),
          _resolved(seq: '2'),
        ],
      );

      await expectLater(
        database.saveConflictChangesPage(page),
        throwsFormatException,
      );

      expect(await database.conflictFeedCursor(_vaultId, _generationA), '0');
      final inbox = await database.listConflictFeedInbox(
        _vaultId,
        _generationA,
      );
      expect(inbox, hasLength(1));
      expect(inbox.single.conflictId, otherConflict);

      await database.close();
    },
  );

  test('redacted feed erasure and cursor commit in one transaction', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.storeRemoteEnvelope(
      vaultId: _vaultId,
      instanceId: _instanceId,
      serverSpaceId: _serverSpaceId,
      recordId: _recordId,
      revisionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      envelope: const {'ciphertext': 'cached-before-redaction'},
      commitSeq: '8',
      deleted: true,
    );
    final page = _page(
      generation: _generationA,
      after: '0',
      highWatermark: '1',
      next: '1',
      events: [
        {
          'seq': '1',
          'type': 'redacted',
          'conflict_id': _conflictId,
          'record_id': _recordId,
          'redaction': _redactionProof,
        },
      ],
    );

    await database.customStatement(
      "CREATE TRIGGER reject_redacted_inbox BEFORE INSERT ON conflict_feed_inbox "
      "BEGIN SELECT RAISE(ABORT, 'injected inbox failure'); END",
    );
    await expectLater(
      database.saveConflictChangesPage(
        page,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        verifiedRedactionProofs: {'1': _redactionProof},
      ),
      throwsA(anything),
    );
    expect(
      await database.cachedEnvelopes(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      ),
      hasLength(1),
    );
    expect(
      await database.conflictFeedCursor(
        _vaultId,
        _generationA,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      ),
      '0',
    );
    expect(
      await database.redactionProofForRecord(
        instanceId: _redactionProof['instance_id']! as String,
        serverSpaceId: _redactionProof['server_space_id']! as String,
        vaultId: _vaultId,
        recordId: _recordId,
      ),
      isNull,
    );

    await database.customStatement('DROP TRIGGER reject_redacted_inbox');
    await database.saveConflictChangesPage(
      page,
      instanceId: _instanceId,
      serverSpaceId: _serverSpaceId,
      verifiedRedactionProofs: {'1': _redactionProof},
    );
    expect(
      await database.cachedEnvelopes(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      ),
      isEmpty,
    );
    expect(
      await database.conflictFeedCursor(
        _vaultId,
        _generationA,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      ),
      '1',
    );
    expect(
      (await database.listConflictFeedInbox(
        _vaultId,
        _generationA,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      )).single.type,
      'redacted',
    );
  });

  test('page object is revalidated before persistence', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    const malformed = ConflictChangesPage(
      vaultId: _vaultId,
      afterSeq: '0',
      highWatermark: '4',
      events: [
        ConflictChangeEvent(
          seq: '01',
          type: 'created',
          conflictId: _conflictId,
          recordId: _recordId,
          baseRevisionId: null,
          resolvedRevisionId: null,
          createdAt: '2026-09-27T12:30:00Z',
          envelope: {'ciphertext': 'opaque'},
        ),
      ],
      nextAfterSeq: '01',
      hasMore: false,
      serverGeneration: _generationA,
    );

    await expectLater(
      database.saveConflictChangesPage(malformed),
      throwsFormatException,
    );
    expect(await database.conflictFeedCursor(_vaultId, _generationA), '0');
    expect(
      await database.listConflictFeedInbox(_vaultId, _generationA),
      isEmpty,
    );

    await database.close();
  });

  test(
    'schema v4 upgrade creates feed tables and preserves vault data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-conflict-feed-migration-',
      );
      final file = File('${directory.path}/client.sqlite');
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      await database.saveCheckpoint(
        vaultId: _vaultId,
        cursor: 'main-cursor',
        serverGeneration: 'main-generation',
      );
      await database.saveConflict(
        conflictId: _conflictId,
        vaultId: _vaultId,
        recordId: _recordId,
        kind: 'concurrent_edit',
        branchEnvelope: const {'opaque': 'local'},
        remoteEnvelope: const {'opaque': 'remote'},
      );
      await database.customStatement('DROP TABLE conflict_feed_inbox');
      await database.customStatement('DROP TABLE conflict_feed_checkpoints');
      await database.customStatement('DROP TABLE conflict_feed_states');
      await database.customStatement('DROP TABLE feed_conflict_resolutions');
      await database.customStatement('PRAGMA user_version = 4');
      await database.close();

      final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
      final feedTables = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'conflict_feed_%'",
          )
          .get();
      expect(feedTables.map((row) => row.read<String>('name')).toSet(), {
        'conflict_feed_inbox',
        'conflict_feed_checkpoints',
        'conflict_feed_states',
      });
      expect((await upgraded.checkpoint(_vaultId))?.cursor, 'main-cursor');
      expect(
        (await upgraded.openConflicts(_vaultId)).single.conflictId,
        _conflictId,
      );
      expect(await upgraded.activeConflictFeedGeneration(_vaultId), isNull);
      expect(await upgraded.conflictFeedCursor(_vaultId, 'initial'), '0');

      await upgraded.close();
      await directory.delete(recursive: true);
    },
  );
}

Map<String, Object?> _operationEnvelope({
  required String opId,
  required String revisionId,
}) => {
  'header': {
    'op_id': opId,
    'revision_id': revisionId,
    'record_id': _recordId,
    'vault_id': _vaultId,
  },
  'ciphertext': 'opaque-operation-bytes',
};

Future<void> _insertConflictOperation(
  ClientDatabase database, {
  required String opId,
  required Map<String, Object?> envelope,
  String? baseRevisionId,
  String? baseEnvelope,
}) => database
    .into(database.pendingOperations)
    .insert(
      PendingOperationsCompanion.insert(
        opId: opId,
        vaultId: _vaultId,
        recordId: _recordId,
        instanceId: Value(_instanceId),
        serverSpaceId: Value(_serverSpaceId),
        baseRevisionId: Value(baseRevisionId),
        baseEnvelopeJson: Value(baseEnvelope),
        envelopeJson: jsonEncode(envelope),
        status: const Value('conflict'),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

ConflictChangesPage _page({
  required String generation,
  required String after,
  required String highWatermark,
  required String next,
  required List<Map<String, Object?>> events,
}) => ConflictChangesPage.fromJson(
  {
    'vault_id': _vaultId,
    'after_seq': after,
    'high_watermark': highWatermark,
    'events': events,
    'next_after_seq': next,
    'has_more': false,
    'server_generation': generation,
  },
  expectedVaultId: _vaultId,
  expectedAfterSeq: after,
  limit: 100,
);

Map<String, Object?> _created({required String seq}) => {
  'seq': seq,
  'type': 'created',
  'conflict_id': _conflictId,
  'record_id': _recordId,
  'base_revision_id': null,
  'resolved_revision_id': null,
  'created_at': '2026-09-27T12:30:00Z',
  'envelope': {'ciphertext': 'opaque'},
};

Map<String, Object?> _resolved({required String seq}) => {
  'seq': seq,
  'type': 'resolved',
  'conflict_id': _conflictId,
  'record_id': _recordId,
  'base_revision_id': null,
  'resolved_revision_id': _resolvedRevision,
  'created_at': '2026-09-27T12:31:00Z',
};
