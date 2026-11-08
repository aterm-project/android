import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _oldRecordId = '44444444-4444-4444-8444-444444444444';
const _snapshotId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _serverConflictId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _otherVaultId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _preservedConflictId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

String _repeatX(int count) {
  var block = 'x';
  var remaining = count;
  final buffer = StringBuffer();
  while (remaining > 0) {
    if (remaining.isOdd) buffer.write(block);
    remaining >>= 1;
    if (remaining > 0) block += block;
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'snapshot recovery atomically installs empty snapshot cursor and keeps offline create',
    () async {
      final h = _Harness(sodium);
      final first = await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Offline'},
        operation: 'create',
      );
      final firstHeader = first['header'] as Map<String, dynamic>;
      final compacted = await h.repository.saveRecord(
        recordId: _recordId,
        baseRevisionId: firstHeader['revision_id'] as String,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Latest offline',
        },
        operation: 'update',
      );
      final queuedBefore = (await h.database.queuedOperations(_vaultId)).single;
      expect(queuedBefore.baseRevisionId, isNull);
      expect(queuedBefore.opId, (compacted['header'] as Map)['op_id']);
      final originalEnvelopeJson = queuedBefore.envelopeJson;
      final originalOpId = queuedBefore.opId;
      final otherVaultEnvelope = await h.recordEnvelope(
        recordId: _oldRecordId,
        vaultId: _otherVaultId,
        name: 'Other vault cache',
      );
      final otherVaultPendingEnvelope = await h.recordEnvelope(
        recordId: _recordId,
        vaultId: _otherVaultId,
        name: 'Other vault pending operation',
      );
      await h.database.storeRemoteEnvelope(
        vaultId: _otherVaultId,
        recordId: _oldRecordId,
        revisionId:
            (otherVaultEnvelope['header'] as Map)['revision_id'] as String,
        envelope: Map<String, dynamic>.from(otherVaultEnvelope),
        commitSeq: '20',
        deleted: false,
      );
      await h.database.putLocalOperation(
        vaultId: _otherVaultId,
        recordId: _recordId,
        baseRevisionId: null,
        envelope: otherVaultPendingEnvelope,
        deleted: false,
      );
      await h.database.saveCheckpoint(
        vaultId: _otherVaultId,
        cursor: 'other-vault-cursor',
        serverGeneration: 'other-generation',
      );
      await h.database.saveConflict(
        conflictId: _preservedConflictId,
        vaultId: _vaultId,
        recordId: _oldRecordId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        kind: 'pre-existing',
        branchEnvelope: Map<String, dynamic>.from(compacted),
        remoteEnvelope: Map<String, dynamic>.from(compacted),
      );
      expect(await h.database.nextDeviceSequence(h.identity.deviceId), '3');

      h.api.snapshotManifest = const [];
      await expectLater(
        h.repository.recoverFromSnapshot(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(h.repository.lastRecoveryCommitted, isTrue);
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'ordinary-cursor');
      expect(
        checkpoint?.serverGeneration,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      expect(checkpoint?.syncStatus, 'retry_wait');
      final queuedAfter = (await h.database.queuedOperations(_vaultId)).single;
      expect(queuedAfter.opId, originalOpId);
      expect(queuedAfter.envelopeJson, originalEnvelopeJson);
      expect(queuedAfter.baseRevisionId, isNull);
      final cache = await h.database.cachedEnvelopes(_vaultId);
      expect(cache, hasLength(1));
      expect(
        cache.single.revisionId,
        (compacted['header'] as Map)['revision_id'],
      );
      expect(cache.single.isDeleted, isFalse);
      expect(await h.database.nextDeviceSequence(h.identity.deviceId), '4');
      expect(
        (await h.database.checkpoint(_otherVaultId))?.cursor,
        'other-vault-cursor',
      );
      expect(await h.database.countPending(_otherVaultId), 1);
      expect(
        (await h.database.cachedEnvelopes(
          _otherVaultId,
        )).map((row) => row.recordId),
        contains(_oldRecordId),
      );
      expect(
        (await h.database.openConflicts(
          _vaultId,
        )).map((conflict) => conflict.conflictId),
        contains(_preservedConflictId),
      );

      await h.dispose();
    },
  );

  test(
    'snapshot recovery follows opaque page cursors before one atomic apply',
    () async {
      final h = _Harness(sodium);
      final first = await h.recordEnvelope(
        recordId: _recordId,
        revisionId: '55555555-5555-4555-8555-555555555555',
        sequence: '1',
        name: 'First paged head',
      );
      final second = await h.recordEnvelope(
        recordId: _oldRecordId,
        revisionId: '66666666-6666-4666-8666-666666666666',
        sequence: '2',
        name: 'Second paged head',
      );
      const expiresAt = '2030-09-27T00:00:00Z';
      h.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'item_count': 2,
          'manifest': [h.head(first)],
          'has_more': true,
          'next_page_cursor': 'opaque/page+2',
        },
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'item_count': 2,
          'manifest': [h.head(second)],
          'has_more': false,
          'next_page_cursor': null,
        },
      ];

      final result = await h.repository.recoverFromSnapshot();

      expect(result.receivedCount, 2);
      expect(h.api.snapshotPageCursorRequests, [null, 'opaque/page+2']);
      expect(
        (await h.database.cachedEnvelopes(
          _vaultId,
        )).map((row) => row.recordId).toSet(),
        {_recordId, _oldRecordId},
      );
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'ordinary-cursor');
      expect(checkpoint?.serverGeneration, h.api.instanceGeneration);
      expect(h.repository.lastRecoveryCommitted, isTrue);
      await h.dispose();
    },
  );

  test(
    'signed graveyard snapshot is verified and persisted without payload',
    () async {
      final h = _Harness(sodium);
      final proof = h.redactionProof();
      h.api.snapshotManifest = [
        {
          'kind': 'graveyard',
          'record_id': _recordId,
          'deleted_revision_id': proof['deleted_revision_id'],
          'deleted_seq': proof['deleted_seq'],
          'redaction': proof,
        },
      ];

      final result = await h.repository.recoverFromSnapshot();

      expect(result.receivedCount, 1);
      expect(await h.database.cachedEnvelopes(_vaultId), isEmpty);
      expect(
        await h.database.redactionProofForRecord(
          instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        proof,
      );
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        'ordinary-cursor',
      );
      await h.dispose();
    },
  );

  test(
    'post-snapshot redaction change quarantines drafts before queued push',
    () async {
      final h = _Harness(sodium);
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Offline'},
        operation: 'create',
      );
      final proof = h.redactionProof();
      h.api.changesEvents = [
        {
          'commit_seq': '10',
          'event_type': 'record_redacted',
          'record_id': _recordId,
          'redaction': proof,
        },
      ];

      await h.repository.recoverFromSnapshot();

      expect(h.api.pushCount, 0);
      expect(await h.database.countPending(_vaultId), 0);
      expect(await h.database.queuedOperations(_vaultId), isEmpty);
      expect(await h.database.cachedEnvelopes(_vaultId), isEmpty);
      final drafts = await h.database.openConflicts(_vaultId);
      expect(drafts, hasLength(1));
      expect(drafts.single.kind, 'record_redacted');
      expect(drafts.single.state, 'redacted_draft');
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        'ordinary-cursor',
      );
      await h.dispose();
    },
  );

  test(
    'invalid graveyard proof leaves the active cache and checkpoint unchanged',
    () async {
      final h = _Harness(sodium);
      final cached = await h.recordEnvelope(
        recordId: _oldRecordId,
        name: 'Must remain cached',
      );
      await h.storeHead(cached);
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'previous-cursor',
        serverGeneration: h.api.instanceGeneration,
      );
      final proof = h.redactionProof();
      proof['signature'] = encodeBase64Url(Uint8List(64));
      h.api.snapshotManifest = [
        {
          'kind': 'graveyard',
          'record_id': _recordId,
          'deleted_revision_id': proof['deleted_revision_id'],
          'deleted_seq': proof['deleted_seq'],
          'redaction': proof,
        },
      ];

      await expectLater(
        h.repository.recoverFromSnapshot(),
        throwsFormatException,
      );

      expect(
        (await h.database.cachedEnvelopes(_vaultId)).single.recordId,
        _oldRecordId,
      );
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        'previous-cursor',
      );
      expect(
        await h.database.redactionProofForRecord(
          instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
          recordId: _recordId,
        ),
        isNull,
      );
      await h.dispose();
    },
  );

  test(
    'restart resumes from the durably committed opaque continuation cursor',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-snapshot-resume-',
      );
      final file = File('${directory.path}/client.sqlite');
      final h = _Harness(sodium, databaseFile: file);
      final first = await h.recordEnvelope(
        recordId: _recordId,
        revisionId: '77777777-7777-4777-8777-777777777777',
        sequence: '1',
        name: 'First durable page',
      );
      final second = await h.recordEnvelope(
        recordId: _oldRecordId,
        revisionId: '88888888-8888-4888-8888-888888888888',
        sequence: '2',
        name: 'Second durable page',
      );
      final firstPage = <String, dynamic>{
        'snapshot_id': _snapshotId,
        'high_watermark': '12',
        'conflict_high_watermark': '0',
        'next_cursor': 'snapshot-cursor',
        'expires_at': '2030-09-27T00:00:00Z',
        'item_count': 2,
        'manifest': [h.head(first)],
        'has_more': true,
        'next_page_cursor': 'opaque/restart+page-2',
      };
      final secondPage = <String, dynamic>{
        'snapshot_id': _snapshotId,
        'high_watermark': '12',
        'conflict_high_watermark': '0',
        'next_cursor': 'snapshot-cursor',
        'expires_at': '2030-09-27T00:00:00Z',
        'item_count': 2,
        'manifest': [h.head(second)],
        'has_more': false,
        'next_page_cursor': null,
      };
      h.api.snapshotPageResponses = [firstPage];
      await expectLater(h.repository.recoverFromSnapshot(), throwsA(anything));
      expect(h.api.snapshotPageCursorRequests, [null, 'opaque/restart+page-2']);
      expect(await h.database.cachedEnvelopes(_vaultId), isEmpty);
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        isNull,
      );
      final scope = SnapshotRecoveryScope(
        serverNamespace: h.api.baseUrl,
        accountId: '55555555-5555-4555-8555-555555555555',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        serverGeneration: h.api.instanceGeneration,
      );
      final paused = await h.database.resumableSnapshotRecoveryStage(
        scope,
        now: DateTime.now(),
      );
      expect(paused?.snapshotId, _snapshotId);
      expect(paused?.verifiedItemCount, 1);
      expect(paused?.nextPageCursor, 'opaque/restart+page-2');

      await h.database.close();
      h.api.close();
      final reopened = ClientDatabase.forTesting(NativeDatabase(file));
      final resumedApi = _SnapshotApi(own: h.identity, database: reopened)
        ..snapshotPageResponses = [secondPage];
      final resumedRepository = SyncRepository(
        api: resumedApi,
        database: reopened,
        crypto: h.crypto,
        identity: h.identity,
        serverSpaceId: _serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        accountId: '55555555-5555-4555-8555-555555555555',
        vaultId: _vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: h.api.instanceGeneration,
        vaultKey: h.vaultKey,
      );
      try {
        final result = await resumedRepository.recoverFromSnapshot();
        expect(result.receivedCount, 2);
        expect(resumedApi.createSnapshotCount, 0);
        expect(resumedApi.snapshotPageCursorRequests, [
          'opaque/restart+page-2',
        ]);
        expect(
          (await reopened.cachedEnvelopes(
            _vaultId,
          )).map((row) => row.recordId).toSet(),
          {_recordId, _oldRecordId},
        );
        expect(
          (await reopened.checkpoint(
            _vaultId,
            instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            serverSpaceId: _serverSpaceId,
          ))?.cursor,
          'ordinary-cursor',
        );
        expect(
          await reopened.resumableSnapshotRecoveryStage(
            scope,
            now: DateTime.now(),
          ),
          isNull,
        );
      } finally {
        await reopened.close();
        resumedApi.close();
        h.identity.dispose();
        h.vaultKey.fillRange(0, h.vaultKey.length, 0);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'legacy full snapshot responses remain readable as one manifest page',
    () async {
      final h = _Harness(sodium);
      final remote = await h.recordEnvelope(name: 'Legacy full manifest');
      h.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': '2030-09-27T00:00:00Z',
          'manifest': [h.head(remote)],
        },
      ];

      final result = await h.repository.recoverFromSnapshot();

      expect(result.receivedCount, 1);
      expect(h.api.snapshotPageCursorRequests, [null]);
      expect(
        (await h.database.cachedEnvelopes(_vaultId)).single.recordId,
        _recordId,
      );
      await h.dispose();
    },
  );

  test(
    'snapshot item_count must stay stable and match the collected heads',
    () async {
      final h = _Harness(sodium);
      final first = await h.recordEnvelope(
        recordId: _recordId,
        name: 'Counted page one',
      );
      final second = await h.recordEnvelope(
        recordId: _oldRecordId,
        name: 'Counted page two',
      );
      h.api.snapshotItemCount = 2;
      const expiresAt = '2030-09-27T00:00:00Z';
      h.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'item_count': 2,
          'manifest': [h.head(first)],
          'has_more': true,
          'next_page_cursor': 'page-2',
        },
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'item_count': 3,
          'manifest': [h.head(second)],
          'has_more': false,
          'next_page_cursor': null,
        },
      ];

      await expectLater(h.repository.recoverFromSnapshot(), throwsA(anything));

      expect(h.repository.lastRecoveryCommitted, isFalse);
      expect(await h.database.cachedEnvelopes(_vaultId), isEmpty);
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        isNull,
      );
      await h.dispose();
    },
  );

  test(
    'snapshot aggregate JSON byte cap accepts its boundary and rejects one byte over',
    () async {
      final h = _Harness(sodium);
      final remote = await h.recordEnvelope(name: 'Byte-budget head');
      final head = h.head(remote)..['padding'] = '';
      final emptyPaddingBytes = utf8.encode(jsonEncode(head)).length;
      const maxManifestBytes = 64 * 1024 * 1024;
      final exactPaddingLength = maxManifestBytes - 2 - emptyPaddingBytes;
      head['padding'] = _repeatX(exactPaddingLength);
      h.api.snapshotManifest = [head];

      final atLimit = await h.repository.recoverFromSnapshot();
      expect(atLimit.receivedCount, 1);
      final durableCache = await h.database.cachedEnvelopes(_vaultId);
      final durableCheckpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );

      head['padding'] = _repeatX(exactPaddingLength + 1);
      await expectLater(
        h.repository.recoverFromSnapshot(),
        throwsA(
          isA<SnapshotBootstrapLimitException>().having(
            (error) => error.toString(),
            'message',
            contains('64 MiB'),
          ),
        ),
      );

      expect(h.repository.lastRecoveryCommitted, isFalse);
      expect(
        (await h.database.cachedEnvelopes(
          _vaultId,
        )).map((row) => row.envelopeJson),
        durableCache.map((row) => row.envelopeJson),
      );
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        durableCheckpoint?.cursor,
      );
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.syncStatus,
        'snapshot_too_large',
      );
      await h.dispose();
    },
  );

  test(
    'a later snapshot page failure preserves cache, checkpoint, and outbox',
    () async {
      final h = _Harness(sodium);
      final old = await h.recordEnvelope(
        recordId: _oldRecordId,
        name: 'Existing durable head',
      );
      await h.storeHead(old);
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'durable-old-cursor',
        serverGeneration: 'old-generation',
      );
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Pending'},
        operation: 'create',
      );
      final cacheBefore = await h.database.cachedEnvelopes(_vaultId);
      final pendingBefore = (await h.database.allPendingOperations(
        _vaultId,
      )).single;
      const expiresAt = '2030-09-27T00:00:00Z';
      final remote = await h.recordEnvelope(
        recordId: _recordId,
        revisionId: '77777777-7777-4777-8777-777777777777',
        name: 'First remote page',
      );
      h.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'manifest': [h.head(remote)],
          'has_more': true,
          'next_page_cursor': 'page-2',
        },
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'manifest': [],
          'has_more': false,
          'next_page_cursor': null,
        },
      ];
      h.api.failSnapshotPage = 2;

      await expectLater(
        h.repository.recoverFromSnapshot(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );

      expect(h.repository.lastRecoveryCommitted, isFalse);
      expect(
        (await h.database.cachedEnvelopes(
          _vaultId,
        )).map((row) => row.envelopeJson),
        cacheBefore.map((row) => row.envelopeJson),
      );
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'durable-old-cursor');
      expect(checkpoint?.serverGeneration, 'old-generation');
      final pendingAfter = (await h.database.allPendingOperations(
        _vaultId,
      )).single;
      expect(pendingAfter.opId, pendingBefore.opId);
      expect(pendingAfter.envelopeJson, pendingBefore.envelopeJson);
      expect(h.api.snapshotPageCursorRequests, [null, 'page-2']);
      await h.dispose();
    },
  );

  test(
    'snapshot pagination rejects empty continuation pages and repeated cursors',
    () async {
      final emptyPageHarness = _Harness(sodium);
      const expiresAt = '2030-09-27T00:00:00Z';
      emptyPageHarness.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'manifest': <dynamic>[],
          'has_more': true,
          'next_page_cursor': 'loop',
        },
      ];
      await expectLater(
        emptyPageHarness.repository.recoverFromSnapshot(),
        throwsA(anything),
      );
      expect(emptyPageHarness.repository.lastRecoveryCommitted, isFalse);
      expect(
        await emptyPageHarness.database.cachedEnvelopes(_vaultId),
        isEmpty,
      );
      expect(
        (await emptyPageHarness.database.checkpoint(
          _vaultId,
          instanceId: emptyPageHarness.repository.instanceId,
          serverSpaceId: emptyPageHarness.repository.serverSpaceId,
        ))?.cursor,
        isNull,
      );
      expect(emptyPageHarness.api.snapshotPageCursorRequests, [null]);
      await emptyPageHarness.dispose();

      final repeatedCursorHarness = _Harness(sodium);
      final first = await repeatedCursorHarness.recordEnvelope(
        recordId: _recordId,
        name: 'Page one',
      );
      final second = await repeatedCursorHarness.recordEnvelope(
        recordId: _oldRecordId,
        name: 'Page two',
      );
      repeatedCursorHarness.api.snapshotPageResponses = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'manifest': [repeatedCursorHarness.head(first)],
          'has_more': true,
          'next_page_cursor': 'loop',
        },
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '12',
          'conflict_high_watermark': '0',
          'next_cursor': 'snapshot-cursor',
          'expires_at': expiresAt,
          'manifest': [repeatedCursorHarness.head(second)],
          'has_more': true,
          'next_page_cursor': 'loop',
        },
      ];
      await expectLater(
        repeatedCursorHarness.repository.recoverFromSnapshot(),
        throwsA(anything),
      );
      expect(repeatedCursorHarness.repository.lastRecoveryCommitted, isFalse);
      expect(
        await repeatedCursorHarness.database.cachedEnvelopes(_vaultId),
        isEmpty,
      );
      expect(
        (await repeatedCursorHarness.database.checkpoint(
          _vaultId,
          instanceId: repeatedCursorHarness.repository.instanceId,
          serverSpaceId: repeatedCursorHarness.repository.serverSpaceId,
        ))?.cursor,
        isNull,
      );
      expect(repeatedCursorHarness.api.snapshotPageCursorRequests, [
        null,
        'loop',
      ]);
      await repeatedCursorHarness.dispose();
    },
  );

  test(
    'snapshot keeps an edit based on the current head as optimistic cache',
    () async {
      final h = _Harness(sodium);
      final remote = await h.recordEnvelope(
        revisionId: '55555555-5555-4555-8555-555555555555',
        name: 'Current head',
      );
      await h.storeHead(remote);
      final local = await h.repository.saveRecord(
        recordId: _recordId,
        baseRevisionId: (remote['header'] as Map)['revision_id'] as String,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'My edit'},
        operation: 'update',
      );
      h.api.snapshotManifest = [h.head(remote)];

      await expectLater(
        h.repository.recoverFromSnapshot(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(h.repository.lastRecoveryCommitted, isTrue);

      final queued = (await h.database.queuedOperations(_vaultId)).single;
      expect(queued.baseRevisionId, (remote['header'] as Map)['revision_id']);
      expect(queued.envelopeJson, jsonEncode(local));
      final cache = await h.database.cachedEnvelopes(_vaultId);
      expect(cache.single.revisionId, (local['header'] as Map)['revision_id']);
      expect(cache.single.commitSeq, isNull);

      await h.dispose();
    },
  );

  test(
    'snapshot confirms only an exact pending op id and revision pair',
    () async {
      final h = _Harness(sodium);
      final local = await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Already committed',
        },
        operation: 'create',
      );
      h.api.snapshotManifest = [h.head(local)];

      final result = await h.repository.recoverFromSnapshot();

      expect(result.status, 'idle');
      expect(await h.database.countPending(_vaultId), 0);
      final cache = await h.database.cachedEnvelopes(_vaultId);
      expect(cache.single.revisionId, (local['header'] as Map)['revision_id']);
      expect(cache.single.commitSeq, '12');
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.serverGeneration,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );

      await h.dispose();
    },
  );

  test(
    'legacy snapshot heads without commit_seq remain explicitly uncommitted',
    () async {
      final h = _Harness(sodium);
      final remote = await h.recordEnvelope(name: 'Legacy snapshot head');
      final legacyHead = h.head(remote)..remove('commit_seq');
      h.api.snapshotManifest = [legacyHead];

      await h.repository.recoverFromSnapshot();

      final cache = await h.database.cachedEnvelopes(_vaultId);
      expect(cache.single.revisionId, (remote['header'] as Map)['revision_id']);
      expect(cache.single.commitSeq, isNull);

      await h.dispose();
    },
  );

  test(
    'same operation and revision IDs with different signed ciphertext become a conflict',
    () async {
      final h = _Harness(sodium);
      final local = await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Local intent',
        },
        operation: 'create',
      );
      final remote = await h.alternateEnvelope(local, const {
        'id': _recordId,
        'type': 'host',
        'name': 'Different signed payload',
      });
      h.api.snapshotManifest = [h.head(remote)];

      await h.repository.recoverFromSnapshot();

      final outbox = (await h.database.allPendingOperations(_vaultId)).single;
      expect(outbox.envelopeJson, jsonEncode(local));
      expect(outbox.status, 'conflict');
      final cache = (await h.database.cachedEnvelopes(_vaultId)).single;
      expect(cache.envelopeJson, jsonEncode(remote));
      final conflict = (await h.database.openConflicts(_vaultId)).single;
      expect(conflict.kind, 'id_reuse');
      expect(conflict.branchEnvelopeJson, jsonEncode(local));
      expect(conflict.remoteEnvelopeJson, jsonEncode(remote));

      await h.dispose();
    },
  );

  test(
    'concurrent snapshot head becomes visible while original local branch is preserved',
    () async {
      final h = _Harness(sodium);
      final formerHead = await h.recordEnvelope(
        revisionId: '66666666-6666-4666-8666-666666666666',
        name: 'Base head',
      );
      final local = await h.repository.saveRecord(
        recordId: _recordId,
        baseRevisionId: (formerHead['header'] as Map)['revision_id'] as String,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Local branch',
        },
        operation: 'update',
      );
      final localBefore = (await h.database.queuedOperations(_vaultId)).single;
      final remoteIdentity = DeviceIdentity.create(sodium);
      h.api.addTrusted(remoteIdentity);
      final remote = await h.recordEnvelope(
        signer: remoteIdentity,
        revisionId: '77777777-7777-4777-8777-777777777777',
        sequence: '4',
        name: 'Remote head',
      );
      h.api.snapshotManifest = [h.head(remote)];
      h.api.checkSnapshotCommitted = true;

      await h.repository.recoverFromSnapshot();

      expect(h.api.conflictUploadCount, 1);
      expect(h.api.snapshotWasCommittedAtConflictUpload, isTrue);
      final cache = await h.database.cachedEnvelopes(_vaultId);
      expect(cache.single.revisionId, (remote['header'] as Map)['revision_id']);
      final outbox = (await h.database.allPendingOperations(_vaultId)).single;
      expect(outbox.opId, localBefore.opId);
      expect(outbox.envelopeJson, localBefore.envelopeJson);
      expect(outbox.baseRevisionId, localBefore.baseRevisionId);
      expect(outbox.status, 'conflict');
      final conflicts = await h.database.openConflicts(_vaultId);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.conflictId, _serverConflictId);
      expect(conflicts.single.branchEnvelopeJson, jsonEncode(local));
      expect(conflicts.single.remoteEnvelopeJson, jsonEncode(remote));

      remoteIdentity.dispose();
      await h.dispose();
    },
  );

  test(
    'snapshot tombstone remains the remote head and is excluded from active records',
    () async {
      final h = _Harness(sodium);
      final tombstone = await h.recordEnvelope(
        operation: 'delete',
        plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
      );
      h.api.snapshotManifest = [h.head(tombstone, deleted: true)];

      await h.repository.recoverFromSnapshot();

      final cached = (await h.database.cachedEnvelopes(_vaultId)).single;
      expect(cached.isDeleted, isTrue);
      expect(cached.revisionId, (tombstone['header'] as Map)['revision_id']);
      expect(await h.repository.loadRecords(), isEmpty);

      await h.dispose();
    },
  );

  test(
    'generation rejection preserves a queued row and snapshot recovery retries once with the new generation',
    () async {
      final h = _Harness(sodium);
      const oldGeneration = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const newGeneration = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      h
        ..repository.serverGeneration = oldGeneration
        ..api.instanceGeneration = oldGeneration
        ..api.rotateGenerationOnNextPush = newGeneration
        ..api.pushFailure = false;
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'old-generation-cursor',
        serverGeneration: oldGeneration,
      );
      final envelope = await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Retain across generation change',
        },
        operation: 'create',
      );
      h.api.snapshotManifest = const [];
      final before = (await h.database.allPendingOperations(_vaultId)).single;

      final syncResult = await h.repository.synchronize();

      expect(syncResult.status, 'resnapshot_required');
      expect(syncResult.pendingCount, 1);
      expect(h.api.pushCount, 1, reason: 'generation rejection must not retry');
      expect(h.api.successfulOperationIds, isEmpty);
      final afterRejection = (await h.database.allPendingOperations(
        _vaultId,
      )).single;
      _expectSamePendingOperation(afterRejection, before);
      expect(afterRejection.status, 'queued');

      final recovered = await h.repository.recoverFromSnapshot();

      expect(recovered.status, 'idle');
      expect(recovered.serverGeneration, newGeneration);
      expect(h.api.pushCount, 2);
      expect(h.api.pushedGenerations, [oldGeneration, newGeneration]);
      expect(h.api.successfulOperationIds, [
        (envelope['header'] as Map<String, dynamic>)['op_id'],
      ]);
      expect(await h.database.countPending(_vaultId), 0);
      expect(h.api.serverCommitCount, 1);

      await h.dispose();
    },
  );

  test(
    'generation rejection after snapshot commit leaves recovery actionable and preserves the outbox',
    () async {
      final h = _Harness(sodium);
      const snapshotGeneration = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const laterGeneration = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      h
        ..repository.serverGeneration = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        ..api.instanceGeneration = snapshotGeneration
        ..api.rotateGenerationOnNextPush = laterGeneration
        ..api.pushFailure = false;
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'pre-recovery-cursor',
        serverGeneration: h.repository.serverGeneration,
      );
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Keep me'},
        operation: 'create',
      );
      h.api.snapshotManifest = const [];
      final before = (await h.database.allPendingOperations(_vaultId)).single;

      final firstRecovery = await h.repository.recoverFromSnapshot();

      expect(firstRecovery.status, 'resnapshot_required');
      expect(h.repository.lastRecoveryCommitted, isTrue);
      expect(h.api.pushCount, 1);
      expect(h.api.pushedGenerations, [snapshotGeneration]);
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'ordinary-cursor');
      expect(checkpoint?.serverGeneration, snapshotGeneration);
      _expectSamePendingOperation(
        (await h.database.allPendingOperations(_vaultId)).single,
        before,
      );
      expect(await h.database.countPending(_vaultId), 1);

      final secondRecovery = await h.repository.recoverFromSnapshot();

      expect(secondRecovery.status, 'idle');
      expect(secondRecovery.serverGeneration, laterGeneration);
      expect(h.api.pushCount, 2);
      expect(h.api.pushedGenerations, [snapshotGeneration, laterGeneration]);
      expect(h.api.successfulOperationIds, [before.opId]);
      expect(h.api.serverCommitCount, 1);
      expect(await h.database.countPending(_vaultId), 0);

      await h.dispose();
    },
  );

  test(
    'snapshot adopts restored server generation for checkpoint and next push',
    () async {
      final h = _Harness(sodium);
      h.repository.serverGeneration = 'old-generation';
      h.api.pushFailure = false;
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'expired-generation-cursor',
        serverGeneration: 'old-generation',
      );
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'After restore',
        },
        operation: 'create',
      );
      h.api.snapshotManifest = const [];

      final result = await h.repository.recoverFromSnapshot();

      expect(result.status, 'idle');
      expect(result.serverGeneration, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(
        h.repository.serverGeneration,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      expect(h.api.pushedGenerations, ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']);
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'ordinary-cursor');
      expect(
        checkpoint?.serverGeneration,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      expect(await h.database.countPending(_vaultId), 0);

      await h.dispose();
    },
  );

  test(
    'failed snapshot activation does not advance the in-memory generation',
    () async {
      final h = _Harness(sodium);
      const oldGeneration = 'old-generation';
      h.repository.serverGeneration = oldGeneration;
      await h.database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _oldRecordId,
        revisionId: 'old-revision',
        envelope: const {'ciphertext': 'preserved'},
        commitSeq: '4',
        deleted: false,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'old-cursor',
        serverGeneration: oldGeneration,
      );
      h.api.snapshotManifest = const [];
      h.api.pushFailure = false;
      await h.database.customStatement(
        "CREATE TRIGGER reject_snapshot_checkpoint BEFORE INSERT ON sync_checkpoints "
        "BEGIN SELECT RAISE(ABORT, 'injected activation failure'); END",
      );

      await expectLater(h.repository.recoverFromSnapshot(), throwsA(anything));

      expect(h.repository.serverGeneration, oldGeneration);
      expect(
        (await h.database.cachedEnvelopes(_vaultId)).map((row) => row.recordId),
        [_oldRecordId],
      );
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'old-cursor');
      expect(checkpoint?.serverGeneration, oldGeneration);
      expect(h.repository.lastRecoveryCommitted, isFalse);

      await h.dispose();
    },
  );

  test(
    'an expired snapshot manifest is discarded and opened once more',
    () async {
      final h = _Harness(sodium);
      h.api.expireFirstSnapshot = true;
      h.api.snapshotManifest = const [];

      await h.repository.recoverFromSnapshot();

      expect(h.api.createSnapshotCount, 2);
      expect(h.api.snapshotCount, 2);
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        'ordinary-cursor',
      );

      await h.dispose();
    },
  );

  test('an already-expired snapshot creation is retried once', () async {
    final h = _Harness(sodium);
    h.api.expireFirstSnapshotCreation = true;
    h.api.snapshotManifest = const [];

    final result = await h.repository.recoverFromSnapshot();

    expect(result.status, 'idle');
    expect(h.api.createSnapshotCount, 2);
    expect(h.api.snapshotCount, 1);
    expect(
      (await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      ))?.cursor,
      'ordinary-cursor',
    );

    await h.dispose();
  });

  test(
    'incomplete, bad-signature and unknown-signer snapshots leave cache, cursor and outbox untouched',
    () async {
      for (final failure in [
        'incomplete',
        'bad_commit_seq',
        'zero_commit_seq',
        'high_commit_seq',
        'numeric_commit_seq',
        'bad_signature',
        'unknown_signer',
        'missing_epoch_key',
      ]) {
        final h = _Harness(sodium);
        final old = await h.recordEnvelope(
          recordId: _oldRecordId,
          revisionId: '88888888-8888-4888-8888-888888888888',
          name: 'Preserved cache',
        );
        await h.storeHead(old);
        await h.database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
          cursor: 'old-cursor',
          serverGeneration: 'old-generation',
        );
        await h.repository.saveRecord(
          recordId: _recordId,
          plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Pending'},
          operation: 'create',
        );
        final oldCache = await h.database.cachedEnvelopes(_vaultId);
        final oldPending = (await h.database.allPendingOperations(
          _vaultId,
        )).single;
        final oldSequence = await h.database.nextDeviceSequence(
          h.identity.deviceId,
        );

        if (failure == 'incomplete') {
          h.api.snapshotManifest = const [
            {'record_id': _recordId, 'revision_id': 'bad', 'envelope': {}},
          ];
        } else if (failure == 'bad_commit_seq' ||
            failure == 'zero_commit_seq' ||
            failure == 'high_commit_seq' ||
            failure == 'numeric_commit_seq') {
          final malformed = h.head(old);
          malformed['commit_seq'] = switch (failure) {
            'bad_commit_seq' => '01',
            'zero_commit_seq' => '0',
            'high_commit_seq' => '13',
            _ => 1,
          };
          h.api.snapshotManifest = [malformed];
        } else if (failure == 'bad_signature') {
          final bad = Map<String, dynamic>.from(old);
          bad['signature'] = encodeBase64Url(List<int>.filled(64, 0));
          h.api.snapshotManifest = [h.head(bad)];
        } else if (failure == 'unknown_signer') {
          final untrusted = DeviceIdentity.create(sodium);
          final unknown = await h.recordEnvelope(
            signer: untrusted,
            recordId: _recordId,
            revisionId: '99999999-9999-4999-8999-999999999999',
            name: 'Untrusted signer',
          );
          h.api.snapshotManifest = [h.head(unknown)];
          untrusted.dispose();
        } else {
          final unavailableEpoch = await h.recordEnvelope(
            recordId: _recordId,
            keyEpoch: '2',
            revisionId: '99999999-9999-4999-8999-999999999999',
            name: 'Unavailable epoch',
          );
          h.api.snapshotManifest = [h.head(unavailableEpoch)];
        }

        await expectLater(
          h.repository.recoverFromSnapshot(),
          throwsA(anything),
          reason: failure,
        );

        final newCache = await h.database.cachedEnvelopes(_vaultId);
        expect(
          newCache.map((row) => row.envelopeJson),
          oldCache.map((row) => row.envelopeJson),
          reason: failure,
        );
        final checkpoint = await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        );
        expect(checkpoint?.cursor, 'old-cursor', reason: failure);
        expect(checkpoint?.serverGeneration, 'old-generation', reason: failure);
        final newPending = (await h.database.allPendingOperations(
          _vaultId,
        )).single;
        expect(newPending.opId, oldPending.opId, reason: failure);
        expect(
          newPending.envelopeJson,
          oldPending.envelopeJson,
          reason: failure,
        );
        expect(
          newPending.baseRevisionId,
          oldPending.baseRevisionId,
          reason: failure,
        );
        expect(
          await h.database.nextDeviceSequence(h.identity.deviceId),
          oldSequence == '1' ? '2' : '3',
        );

        await h.dispose();
      }
    },
  );

  test(
    'Drift rollback keeps the old cache and cursor when snapshot transaction fails',
    () async {
      final h = _Harness(sodium);
      final old = await h.recordEnvelope(
        recordId: _oldRecordId,
        name: 'Before transaction failure',
      );
      await h.storeHead(old);
      await h.database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
        cursor: 'durable-old-cursor',
        serverGeneration: 'old-generation',
      );
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'Retained outbox',
        },
        operation: 'create',
      );
      final outboxBefore = (await h.database.allPendingOperations(
        _vaultId,
      )).single;
      final duplicate = SnapshotHead(
        recordId: _oldRecordId,
        revisionId: (old['header'] as Map)['revision_id'] as String,
        deleted: false,
        envelope: Map<String, dynamic>.from(old),
      );

      await expectLater(
        h.database.applyVaultSnapshot(
          vaultId: _vaultId,
          heads: [duplicate, duplicate],
          cursor: 'new-cursor-must-not-commit',
          serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
        throwsA(anything),
      );

      final cacheAfter = await h.database.cachedEnvelopes(_vaultId);
      expect(cacheAfter, hasLength(2));
      expect(
        cacheAfter.map((row) => row.envelopeJson),
        contains(jsonEncode(old)),
      );
      final checkpoint = await h.database.checkpoint(
        _vaultId,
        instanceId: h.repository.instanceId,
        serverSpaceId: h.repository.serverSpaceId,
      );
      expect(checkpoint?.cursor, 'durable-old-cursor');
      expect(checkpoint?.serverGeneration, 'old-generation');
      final outboxAfter = (await h.database.allPendingOperations(
        _vaultId,
      )).single;
      expect(outboxAfter.opId, outboxBefore.opId);
      expect(outboxAfter.envelopeJson, outboxBefore.envelopeJson);
      expect(outboxAfter.baseRevisionId, outboxBefore.baseRevisionId);

      await h.dispose();
    },
  );

  test(
    'recovery waits behind sync, freezes new edits, then performs snapshot push',
    () async {
      final h = _Harness(sodium);
      await h.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'name': 'Queued'},
        operation: 'create',
      );
      h.api.delayFirstChanges = true;
      final syncFuture = h.repository.synchronize();
      await h.api.changesEntered.future.timeout(const Duration(seconds: 5));
      final recoveryFuture = h.repository.recoverFromSnapshot();
      await expectLater(
        h.repository.saveRecord(
          recordId: _oldRecordId,
          plaintext: const {
            'id': _oldRecordId,
            'type': 'host',
            'name': 'Must wait',
          },
          operation: 'create',
        ),
        throwsStateError,
      );
      expect(h.api.createSnapshotCount, 0);
      h.api.changesRelease.complete(
        const SyncPage(
          events: [],
          nextCursor: 'sync-cursor',
          hasMore: false,
          serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      );

      final syncResult = await syncFuture;
      await expectLater(
        recoveryFuture,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(syncResult.status, 'resnapshot_required');
      expect(h.repository.lastRecoveryCommitted, isTrue);
      expect(h.api.createSnapshotCount, 1);
      expect(h.api.pushCount, 1);
      expect(
        (await h.database.checkpoint(
          _vaultId,
          instanceId: h.repository.instanceId,
          serverSpaceId: h.repository.serverSpaceId,
        ))?.cursor,
        'ordinary-cursor',
      );
      expect(await h.database.countPending(_vaultId), 1);

      await h.dispose();
    },
  );
}

void _expectSamePendingOperation(
  PendingOperation actual,
  PendingOperation expected,
) {
  expect(actual.opId, expected.opId);
  expect(actual.recordId, expected.recordId);
  expect(actual.baseRevisionId, expected.baseRevisionId);
  expect(actual.envelopeJson, expected.envelopeJson);
  expect(actual.status, expected.status);
  expect(actual.attemptCount, expected.attemptCount);
  expect(actual.lastAttemptAt, expected.lastAttemptAt);
  expect(actual.createdAt, expected.createdAt);
}

class _Harness {
  _Harness(this.sodium, {File? databaseFile})
    : identity = DeviceIdentity.create(sodium),
      database = ClientDatabase.forTesting(
        databaseFile == null
            ? NativeDatabase.memory()
            : NativeDatabase(databaseFile),
      ),
      vaultKey = sodium.randombytes.buf(32),
      crypto = VaultCrypto(sodium) {
    api = _SnapshotApi(own: identity, database: database);
    repository = SyncRepository(
      api: api,
      database: database,
      crypto: crypto,
      identity: identity,
      serverSpaceId: _serverSpaceId,
      instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      accountId: '55555555-5555-4555-8555-555555555555',
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      vaultKey: vaultKey,
      trustedInstanceSigningPublicKey: identity.signingPublicKey,
    );
  }

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final ClientDatabase database;
  final Uint8List vaultKey;
  final VaultCrypto crypto;
  late final _SnapshotApi api;
  late final SyncRepository repository;

  Future<Map<String, Object?>> recordEnvelope({
    DeviceIdentity? signer,
    String recordId = _recordId,
    String vaultId = _vaultId,
    String? revisionId,
    String sequence = '1',
    String keyEpoch = '1',
    String operation = 'create',
    Map<String, Object?>? plaintext,
    String? name,
  }) async {
    final actualSigner = signer ?? identity;
    return crypto.encryptRecord(
      vaultKey: vaultKey,
      serverSpaceId: _serverSpaceId,
      vaultId: vaultId,
      recordId: recordId,
      baseRevisionId: null,
      deviceId: actualSigner.deviceId,
      deviceSequence: sequence,
      keyEpoch: keyEpoch,
      membershipVersion: '1',
      operation: operation,
      plaintext:
          plaintext ??
          <String, Object?>{
            'id': recordId,
            'type': 'host',
            'name': name ?? 'Snapshot record',
            if (operation == 'delete') 'deleted': true,
          },
      identity: actualSigner,
    );
  }

  Map<String, Object?> redactionProof({
    String recordId = _recordId,
    String deletedRevisionId = '66666666-6666-4666-8666-666666666666',
    String deletedSeq = '9',
    String redactionSeq = '10',
  }) {
    final unsigned = <String, Object?>{
      'format': 'atermius-record-redaction-proof-v1',
      'redaction_id': '77777777-7777-4777-8777-777777777777',
      'instance_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'server_space_id': _serverSpaceId,
      'vault_id': _vaultId,
      'record_id': recordId,
      'deleted_revision_id': deletedRevisionId,
      'deleted_seq': deletedSeq,
      'redaction_seq': redactionSeq,
      'signing_public_key': identity.signingPublicKey,
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      secretKey: identity.signing.secretKey,
    );
    return {...unsigned, 'signature': encodeBase64Url(signature)};
  }

  Future<Map<String, Object?>> alternateEnvelope(
    Map<String, Object?> original,
    Map<String, Object?> plaintext,
  ) async {
    final header = Map<String, dynamic>.from(original['header'] as Map);
    final salt = decodeBase64Url(header['kdf_salt'] as String);
    final revisionId = header['revision_id'] as String;
    final recordId = header['record_id'] as String;
    final key =
        await cryptography.Hkdf(
          hmac: cryptography.Hmac.sha256(),
          outputLength: 32,
        ).deriveKey(
          secretKey: cryptography.SecretKey(vaultKey),
          nonce: salt,
          info: utf8.encode(
            canonicalJson([
              'atermius',
              'record',
              1,
              _vaultId,
              recordId,
              revisionId,
            ]),
          ),
        );
    final keyBytes = Uint8List.fromList(await key.extractBytes());
    final sodiumKey = sodium.secureCopy(keyBytes);
    final nonce = sodium.randombytes.buf(24);
    final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: Uint8List.fromList(utf8.encode(canonicalJson(plaintext))),
      nonce: nonce,
      key: sodiumKey,
      additionalData: Uint8List.fromList(utf8.encode(canonicalJson(header))),
    );
    sodiumKey.dispose();
    final unsigned = <String, Object?>{
      'header': header,
      'nonce': encodeBase64Url(nonce),
      'ciphertext': encodeBase64Url(ciphertext),
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      secretKey: identity.signing.secretKey,
    );
    keyBytes.fillRange(0, keyBytes.length, 0);
    nonce.fillRange(0, nonce.length, 0);
    return {...unsigned, 'signature': encodeBase64Url(signature)};
  }

  Map<String, dynamic> head(
    Map<String, Object?> envelope, {
    bool deleted = false,
  }) {
    final header = envelope['header'] as Map<String, dynamic>;
    return {
      'record_id': header['record_id'],
      'revision_id': header['revision_id'],
      'commit_seq': '12',
      'deleted': deleted,
      'envelope': envelope,
    };
  }

  Future<void> storeHead(
    Map<String, Object?> envelope, {
    bool deleted = false,
  }) async {
    final header = envelope['header'] as Map<String, dynamic>;
    await database.storeRemoteEnvelope(
      vaultId: _vaultId,
      recordId: header['record_id'] as String,
      revisionId: header['revision_id'] as String,
      envelope: Map<String, dynamic>.from(envelope),
      commitSeq: '1',
      deleted: deleted,
      instanceId: repository.instanceId,
      serverSpaceId: repository.serverSpaceId,
    );
  }

  Future<void> dispose() async {
    await database.close();
    api.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  }
}

class _SnapshotApi extends ApiClient {
  _SnapshotApi({required this.own, required this.database})
    : super(baseUrl: 'https://snapshot-test.example');

  final DeviceIdentity own;
  final ClientDatabase database;
  final Map<String, DeviceIdentity> _trusted = {};
  List<dynamic> snapshotManifest = const [];
  List<Map<String, dynamic>>? snapshotPageResponses;
  final List<String?> snapshotPageCursorRequests = [];
  int? failSnapshotPage;
  int? snapshotItemCount;
  List<Map<String, dynamic>> changesEvents = const [];
  String instanceGeneration = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  String? rotateGenerationOnNextPush;
  bool pushFailure = true;
  bool delayFirstChanges = false;
  final Completer<void> changesEntered = Completer<void>();
  final Completer<SyncPage> changesRelease = Completer<SyncPage>();
  bool _delayed = false;
  int createSnapshotCount = 0;
  int snapshotCount = 0;
  bool expireFirstSnapshot = false;
  bool expireFirstSnapshotCreation = false;
  int conflictUploadCount = 0;
  int pushCount = 0;
  int serverCommitCount = 0;
  final List<String?> pushedGenerations = [];
  final List<String> successfulOperationIds = [];
  bool checkSnapshotCommitted = false;
  bool snapshotWasCommittedAtConflictUpload = false;

  void addTrusted(DeviceIdentity identity) {
    _trusted[identity.deviceId] = identity;
  }

  @override
  Future<InstanceInfo> fetchInstance() async => InstanceInfo(
    instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    serverSpaceId: _serverSpaceId,
    generation: instanceGeneration,
    protocolVersion: 1,
    setupRequired: false,
    capabilities: const ['snapshots'],
  );

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': own.deviceId,
      'signing_public_key': own.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    for (final signer in [own, ..._trusted.values])
      {
        'device_id': signer.deviceId,
        'user_id': '55555555-5555-4555-8555-555555555555',
        'signing_public_key': signer.signingPublicKey,
        'status': 'active',
      },
  ];

  @override
  Future<Map<String, dynamic>> createSnapshot(String vaultId) async {
    createSnapshotCount++;
    return {
      'snapshot_id': _snapshotId,
      'high_watermark': '12',
      'conflict_high_watermark': '0',
      'next_cursor': 'snapshot-cursor',
      'expires_at': expireFirstSnapshotCreation && createSnapshotCount == 1
          ? '2000-09-27T00:00:00Z'
          : '2030-09-27T00:00:00Z',
      if (snapshotItemCount != null) 'item_count': snapshotItemCount,
    };
  }

  @override
  Future<Map<String, dynamic>> snapshot(
    String snapshotId, {
    int? limit,
    String? pageCursor,
  }) async {
    snapshotCount++;
    snapshotPageCursorRequests.add(pageCursor);
    if (expireFirstSnapshot && snapshotCount == 1) {
      throw const ApiException(
        statusCode: 410,
        code: 'SNAPSHOT_EXPIRED',
        message: 'Expired during snapshot read',
      );
    }
    if (failSnapshotPage == snapshotCount) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Snapshot page transport failed',
      );
    }
    final responses = snapshotPageResponses;
    if (responses != null) {
      final index = snapshotCount - 1;
      if (index >= responses.length) {
        throw StateError('Unexpected snapshot page request $index.');
      }
      return responses[index];
    }
    return {
      'snapshot_id': snapshotId,
      'high_watermark': '12',
      'conflict_high_watermark': '0',
      'next_cursor': 'snapshot-cursor',
      'expires_at': '2030-09-27T00:00:00Z',
      'manifest': snapshotManifest,
      if (snapshotItemCount != null) 'item_count': snapshotItemCount,
      'has_more': false,
      'next_page_cursor': null,
    };
  }

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async => ConflictChangesPage(
    vaultId: vaultId,
    afterSeq: afterSeq ?? '0',
    highWatermark: afterSeq ?? '0',
    events: const [],
    nextAfterSeq: afterSeq ?? '0',
    hasMore: false,
    serverGeneration: serverGeneration ?? instanceGeneration,
  );

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    if (delayFirstChanges && !_delayed) {
      _delayed = true;
      changesEntered.complete();
      return changesRelease.future;
    }
    return SyncPage(
      events: changesEvents,
      nextCursor: 'ordinary-cursor',
      hasMore: false,
      serverGeneration: instanceGeneration,
    );
  }

  @override
  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    conflictUploadCount++;
    if (checkSnapshotCommitted) {
      final checkpoint = await database.checkpoint(
        vaultId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        serverSpaceId: _serverSpaceId,
      );
      final cache = await database.cachedEnvelopes(
        vaultId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        serverSpaceId: _serverSpaceId,
      );
      snapshotWasCommittedAtConflictUpload =
          checkpoint?.cursor == 'ordinary-cursor' &&
          cache.any((row) => row.commitSeq != null);
    }
    return const {'conflict_id': _serverConflictId, 'status': 'stored'};
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushCount++;
    pushedGenerations.add(batch['server_generation'] as String?);
    final nextGeneration = rotateGenerationOnNextPush;
    if (nextGeneration != null) {
      rotateGenerationOnNextPush = null;
      instanceGeneration = nextGeneration;
      throw const ApiException(
        statusCode: 410,
        code: 'SERVER_GENERATION_CHANGED',
        message: 'Server generation changed before push acceptance.',
      );
    }
    if (pushFailure) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Offline test push',
      );
    }
    final operations = batch['operations'] as List<dynamic>;
    final results = <Map<String, Object?>>[];
    for (final raw in operations) {
      final envelope = Map<String, dynamic>.from(raw as Map);
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      successfulOperationIds.add(header['op_id'] as String);
      serverCommitCount++;
      results.add({
        'op_id': header['op_id'],
        'revision_id': header['revision_id'],
        'commit_seq': '${12 + serverCommitCount}',
        'already_committed': false,
      });
    }
    return {'batch_id': batch['batch_id'], 'results': results};
  }
}
