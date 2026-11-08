import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:drift/native.dart';

const _testServerSpaceId = '11111111-1111-4111-8111-111111111111';
const _testInstanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _testVaultId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two repositories sharing a file outbox both accept the same committed push receipt',
    () async {
      final sodium = await SodiumSumoInit.init();
      final directory = await Directory.systemTemp.createTemp(
        'atermius-cross-tab-ack-',
      );
      final file = File('${directory.path}/client.sqlite');
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = sodium.randombytes.buf(32);
      final databaseA = ClientDatabase.forTesting(NativeDatabase(file));
      final apiBarrier = _TwoTabPushBarrier();
      final apiA = _FlakyApiClient(
        identity: identity,
        database: databaseA,
        failFirstPush: false,
        pushBarrier: apiBarrier,
      );
      final repositoryA = _makeSyncRepository(
        sodium: sodium,
        api: apiA,
        database: databaseA,
        identity: identity,
        vaultKey: vaultKey,
      );
      const recordId = '33333333-3333-4333-8333-333333333333';
      final envelope = await repositoryA.saveRecord(
        recordId: recordId,
        plaintext: const {
          'id': recordId,
          'type': 'host',
          'name': 'Shared outbox operation',
        },
      );
      final envelopeJson = jsonEncode(envelope);

      final apiB = _FlakyApiClient(
        identity: identity,
        database: databaseA,
        failFirstPush: false,
        pushBarrier: apiBarrier,
      );
      final repositoryB = _makeSyncRepository(
        sodium: sodium,
        api: apiB,
        database: databaseA,
        identity: identity,
        vaultKey: vaultKey,
      );
      expect(await databaseA.countPending(repositoryA.vaultId), 1);

      final results = await Future.wait([
        repositoryA.synchronize(),
        repositoryB.synchronize(),
      ]);

      expect(apiBarrier.pushCalls, 2);
      expect(apiBarrier.batchIds.toSet(), hasLength(2));
      expect(apiBarrier.logicalReceiptCount, 1);
      expect(apiBarrier.versionCount, 1);
      expect(apiBarrier.eventCount, 1);
      expect(apiBarrier.headCount, 1);
      expect(results.map((result) => result.status), everyElement('idle'));
      expect(await databaseA.countPending(repositoryA.vaultId), 0);
      final committed = await databaseA.cachedEnvelopes(repositoryA.vaultId);
      expect(committed, hasLength(1));
      expect(committed.single.envelopeJson, envelopeJson);
      expect(committed.single.commitSeq, '1');

      await databaseA.close();
      apiA.close();
      apiB.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'duplicate push ACK requires exact committed cache and completed resolution side effects',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(
        identity: identity,
        database: database,
        failFirstPush: false,
      );
      final vaultKey = sodium.randombytes.buf(32);
      final repository = _makeSyncRepository(
        sodium: sodium,
        api: api,
        database: database,
        identity: identity,
        vaultKey: vaultKey,
      );
      const recordId = '33333333-3333-4333-8333-333333333333';
      const conflictId = '44444444-4444-4444-8444-444444444444';
      const feedConflictId = '55555555-5555-4555-8555-555555555555';
      final envelope = await repository.saveRecord(
        recordId: recordId,
        plaintext: const {'id': recordId, 'type': 'host', 'name': 'Resolved'},
      );
      final header = envelope['header'] as Map<String, dynamic>;
      final opId = header['op_id'] as String;
      final revisionId = header['revision_id'] as String;
      await database.markAttempted([opId]);
      final requested = (await database.allPendingOperations(
        repository.vaultId,
      )).single;
      final now = DateTime.now().millisecondsSinceEpoch;
      await database
          .into(database.conflictBranches)
          .insert(
            ConflictBranchesCompanion.insert(
              conflictId: conflictId,
              vaultId: repository.vaultId,
              recordId: recordId,
              instanceId: Value(repository.instanceId),
              serverSpaceId: Value(repository.serverSpaceId),
              kind: 'concurrent_edit',
              branchEnvelopeJson: jsonEncode(envelope),
              remoteEnvelopeJson: '{}',
              state: const Value('resolution_pending'),
              resolutionOpId: Value(opId),
              resolutionRevisionId: Value(revisionId),
              createdAt: now,
            ),
          );
      await database
          .into(database.feedConflictResolutions)
          .insert(
            FeedConflictResolutionsCompanion.insert(
              conflictId: feedConflictId,
              vaultId: repository.vaultId,
              recordId: recordId,
              instanceId: Value(repository.instanceId),
              serverSpaceId: Value(repository.serverSpaceId),
              opId: Value(opId),
              resolutionRevisionId: revisionId,
              state: 'awaiting_commit',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final receipt = PushCommitReceipt(
        opId: opId,
        revisionId: revisionId,
        commitSeq: '1',
      );
      final receipts = {opId: receipt};

      await database.acknowledgePushBatch(
        vaultId: repository.vaultId,
        requested: [requested],
        receipts: receipts,
      );
      await database.acknowledgePushBatch(
        vaultId: repository.vaultId,
        requested: [requested],
        receipts: receipts,
      );
      expect(
        (await (database.select(
              database.conflictBranches,
            )..where((row) => row.conflictId.equals(conflictId))).getSingle())
            .state,
        'resolution_ready',
      );
      expect(
        (await database.feedConflictResolution(feedConflictId))?.state,
        'committed',
      );
      await database.markConflictResolutionCompleted(
        conflictId: conflictId,
        opId: opId,
        revisionId: revisionId,
      );
      await database.markFeedConflictResolved(
        conflictId: feedConflictId,
        resolutionRevisionId: revisionId,
      );
      await database.acknowledgePushBatch(
        vaultId: repository.vaultId,
        requested: [requested],
        receipts: receipts,
      );
      expect(
        (await (database.select(
              database.conflictBranches,
            )..where((row) => row.conflictId.equals(conflictId))).getSingle())
            .state,
        'resolved',
      );
      expect(
        (await database.feedConflictResolution(feedConflictId))?.state,
        'resolved',
      );

      await expectLater(
        database.acknowledgePushBatch(
          vaultId: repository.vaultId,
          requested: [requested],
          receipts: {
            opId: PushCommitReceipt(
              opId: opId,
              revisionId: revisionId,
              commitSeq: '2',
            ),
          },
        ),
        throwsA(isA<StateError>()),
      );
      await (database.update(
        database.feedConflictResolutions,
      )..where((row) => row.conflictId.equals(feedConflictId))).write(
        const FeedConflictResolutionsCompanion(state: Value('needs_review')),
      );
      await expectLater(
        database.acknowledgePushBatch(
          vaultId: repository.vaultId,
          requested: [requested],
          receipts: receipts,
        ),
        throwsA(isA<StateError>()),
      );

      await database.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'local encrypted outbox survives offline failure and retry commits',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(identity: identity, database: db);
      final vaultKey = sodium.randombytes.buf(32);
      final repository = SyncRepository(
        api: api,
        database: db,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: '22222222-2222-4222-8222-222222222222',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultKey: Uint8List.fromList(vaultKey),
      );

      final localEnvelope = await repository.saveRecord(
        recordId: '33333333-3333-4333-8333-333333333333',
        plaintext: const {
          'id': '33333333-3333-4333-8333-333333333333',
          'type': 'host',
          'name': 'Private production host',
          'address': '10.1.2.3',
          'username': 'deployer',
        },
        operation: 'create',
      );
      expect(await db.countPending(repository.vaultId), 1);
      final saved = await db.cachedEnvelopes(repository.vaultId);
      expect(saved, hasLength(1));
      expect(
        saved.single.envelopeJson,
        isNot(contains('Private production host')),
      );
      expect(saved.single.envelopeJson, isNot(contains('10.1.2.3')));

      await expectLater(repository.synchronize(), throwsA(isA<ApiException>()));
      expect(api.pendingCountAtFirstPush, 1);
      expect(await db.countPending(repository.vaultId), 1);
      final queuedAfterFailure = await db.queuedOperations(repository.vaultId);
      expect(queuedAfterFailure, hasLength(1));
      expect(queuedAfterFailure.single.status, 'sent');
      final originalOpId =
          (localEnvelope['header'] as Map<String, dynamic>)['op_id'];

      final retried = await repository.synchronize();
      expect(retried.status, 'idle');
      expect(await db.countPending(repository.vaultId), 0);
      expect(api.pushOperationIds, [originalOpId, originalOpId]);
      final committed = await db.cachedEnvelopes(repository.vaultId);
      expect(committed.single.commitSeq, '1');

      await db.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'seeded lost-ACK sequences preserve outbox identity across retry and reopen',
    () async {
      final sodium = await SodiumSumoInit.init();
      // These two fixed seeds select both valid orderings of the bounded
      // post-failure actions. The sequence always begins with a server commit
      // whose ACK is lost, then retries and reopens in one of the two orders.
      for (final seed in [1, 2]) {
        final directory = await Directory.systemTemp.createTemp(
          'atermius-seeded-sync-sequence-',
        );
        final file = File('${directory.path}/client.sqlite');
        final identity = DeviceIdentity.create(sodium);
        final vaultKey = sodium.randombytes.buf(32);
        final ledger = _LostAckServerLedger();
        late ClientDatabase database;
        late _LostAckRetryApiClient api;
        late SyncRepository repository;

        ClientDatabase openDatabase() =>
            ClientDatabase.forTesting(NativeDatabase(file));

        void openClient() {
          database = openDatabase();
          api = _LostAckRetryApiClient(
            identity: identity,
            database: database,
            ledger: ledger,
          );
          repository = _makeSyncRepository(
            sodium: sodium,
            api: api,
            database: database,
            identity: identity,
            vaultKey: vaultKey,
          );
        }

        try {
          openClient();
          const recordId = '33333333-3333-4333-8333-333333333333';
          final envelope = await repository.saveRecord(
            recordId: recordId,
            plaintext: const {
              'id': recordId,
              'type': 'host',
              'name': 'Seeded retry record',
            },
          );
          final header = Map<String, dynamic>.from(envelope['header'] as Map);
          final expectedOpId = header['op_id'] as String;
          final expectedRevisionId = header['revision_id'] as String;
          final expectedEnvelopeJson = jsonEncode(envelope);
          final beforePush = (await database.queuedOperations(
            repository.vaultId,
          )).single;

          expect(await database.countPending(repository.vaultId), 1);
          _expectStablePendingOperation(
            beforePush,
            opId: expectedOpId,
            revisionId: expectedRevisionId,
            envelopeJson: expectedEnvelopeJson,
            expectedAttemptCount: 0,
          );

          await expectLater(
            repository.synchronize(),
            throwsA(isA<ApiException>()),
          );
          expect(await database.countPending(repository.vaultId), 1);
          final afterLostAck = (await database.queuedOperations(
            repository.vaultId,
          )).single;
          _expectStablePendingOperation(
            afterLostAck,
            opId: expectedOpId,
            revisionId: expectedRevisionId,
            envelopeJson: expectedEnvelopeJson,
            expectedAttemptCount: 1,
          );
          expect(ledger.attempts, hasLength(1));
          expect(ledger.receiptCount, 1);
          expect(ledger.versionCount, 1);
          expect(ledger.eventCount, 1);
          expect(ledger.headCount, 1);

          final postFailureOrder = _seededPostFailureActionOrder(seed);
          expect(
            postFailureOrder,
            seed == 1 ? ['retry', 'reopen'] : ['reopen', 'retry'],
          );
          var retried = false;
          for (final action in postFailureOrder) {
            if (action == 'retry') {
              final result = await repository.synchronize();
              expect(result.status, 'idle');
              retried = true;
              expect(await database.countPending(repository.vaultId), 0);
              expect(
                await database.queuedOperations(repository.vaultId),
                isEmpty,
              );
            } else {
              await database.close();
              api.close();
              openClient();
              final expectedPending = retried ? 0 : 1;
              expect(
                await database.countPending(repository.vaultId),
                expectedPending,
              );
              if (!retried) {
                final afterReopen = (await database.queuedOperations(
                  repository.vaultId,
                )).single;
                _expectStablePendingOperation(
                  afterReopen,
                  opId: expectedOpId,
                  revisionId: expectedRevisionId,
                  envelopeJson: expectedEnvelopeJson,
                  expectedAttemptCount: 1,
                );
              }
            }
            expect(ledger.receiptCount, 1);
            expect(ledger.versionCount, 1);
            expect(ledger.eventCount, 1);
            expect(ledger.headCount, 1);
          }

          // A no-op sync after completion must not replay a committed write.
          expect((await repository.synchronize()).status, 'idle');
          expect(await database.countPending(repository.vaultId), 0);
          expect(await database.queuedOperations(repository.vaultId), isEmpty);
          final committed = await database.cachedEnvelopes(repository.vaultId);
          expect(committed, hasLength(1));
          expect(committed.single.envelopeJson, expectedEnvelopeJson);
          expect(committed.single.commitSeq, '1');
          expect(ledger.attempts, hasLength(2));
          expect(ledger.duplicateAckCount, 1);
          expect(
            ledger.attempts.map((attempt) => attempt.opId),
            everyElement(expectedOpId),
          );
          expect(
            ledger.attempts.map((attempt) => attempt.revisionId),
            everyElement(expectedRevisionId),
          );
          expect(
            ledger.attempts.map((attempt) => attempt.envelopeJson),
            everyElement(expectedEnvelopeJson),
          );
          expect(ledger.attempts[0].batchId, isNot(ledger.attempts[1].batchId));
          expect(ledger.receiptCount, 1);
          expect(ledger.versionCount, 1);
          expect(ledger.eventCount, 1);
          expect(ledger.headCount, 1);
        } finally {
          await database.close();
          api.close();
          identity.dispose();
          vaultKey.fillRange(0, vaultKey.length, 0);
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'push drops a snapshotted operation canceled before it becomes sent',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(
        identity: identity,
        database: database,
        failFirstPush: false,
      );
      final vaultKey = sodium.randombytes.buf(32);
      final batchSnapshotted = Completer<void>();
      final resumePushAdmission = Completer<void>();
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: '22222222-2222-4222-8222-222222222222',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultKey: Uint8List.fromList(vaultKey),
        beforePushMarkAttemptedForTesting: () async {
          if (batchSnapshotted.isCompleted) return;
          batchSnapshotted.complete();
          await resumePushAdmission.future;
        },
      );
      const recordId = '33333333-3333-4333-8333-333333333333';
      await repository.saveRecord(
        recordId: recordId,
        plaintext: const {
          'id': recordId,
          'type': 'shellHistory',
          'host_record_id': '44444444-4444-4444-8444-444444444444',
          'command': 'queued command marker',
          'exit_status': 0,
          'started_at_ms': 1,
          'completed_at_ms': 2,
          'source_device_id': 'test-device',
        },
        operation: 'create',
      );

      final synchronizing = repository.synchronize();
      await batchSnapshotted.future.timeout(const Duration(seconds: 10));
      expect(await database.countPending(repository.vaultId), 1);
      expect(
        await database.discardQueuedCreateOperationIfUncommitted(
          vaultId: repository.vaultId,
          recordId: recordId,
          instanceId: repository.instanceId,
          serverSpaceId: repository.serverSpaceId,
        ),
        isTrue,
      );
      resumePushAdmission.complete();

      final result = await synchronizing;
      expect(result.status, 'idle');
      expect(api.pushCalls, 0);
      expect(await database.countPending(repository.vaultId), 0);
      expect(
        await database.cachedEnvelope(repository.vaultId, recordId),
        isNull,
      );

      await database.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'deletion grace keeps pulling but holds pending outbox until cancellation',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(
        identity: identity,
        database: db,
        deleteOnFirstPush: true,
        failFirstPush: false,
      );
      final vaultKey = sodium.randombytes.buf(32);
      final repository = SyncRepository(
        api: api,
        database: db,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: '22222222-2222-4222-8222-222222222222',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultKey: Uint8List.fromList(vaultKey),
      );

      final envelope = await repository.saveRecord(
        recordId: '33333333-3333-4333-8333-333333333333',
        plaintext: const {
          'id': '33333333-3333-4333-8333-333333333333',
          'type': 'host',
          'name': 'Held during deletion grace',
        },
        operation: 'create',
      );
      final opId = (envelope['header'] as Map<String, dynamic>)['op_id'];

      final raced = await repository.synchronize();
      expect(raced.status, 'deletion_pending');
      expect(api.pushOperationIds, [opId]);
      expect(await db.countPending(repository.vaultId), 1);
      expect(
        (await db.queuedOperations(repository.vaultId)).single.status,
        'sent',
      );

      final readOnly = await repository.synchronize();
      expect(readOnly.status, 'deletion_pending');
      expect(api.pushOperationIds, [opId]);
      expect(await db.countPending(repository.vaultId), 1);

      await repository.updateVaultAccess(
        canWrite: true,
        deletionPending: false,
      );
      final resumed = await repository.synchronize();
      expect(resumed.status, 'idle');
      expect(api.pushOperationIds, [opId, opId]);
      expect(await db.countPending(repository.vaultId), 0);

      await db.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'deletion during conflict-only upload stops sync without retrying writes',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(
        identity: identity,
        database: db,
        deleteOnConflictUpload: true,
      );
      final vaultKey = sodium.randombytes.buf(32);
      final repository = SyncRepository(
        api: api,
        database: db,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: '22222222-2222-4222-8222-222222222222',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultKey: Uint8List.fromList(vaultKey),
      );
      const conflictId = '44444444-4444-4444-8444-444444444444';
      await db
          .into(db.conflictBranches)
          .insert(
            ConflictBranchesCompanion.insert(
              conflictId: conflictId,
              vaultId: repository.vaultId,
              recordId: '33333333-3333-4333-8333-333333333333',
              instanceId: Value(repository.instanceId),
              serverSpaceId: Value(repository.serverSpaceId),
              kind: 'concurrent_edit',
              branchEnvelopeJson: jsonEncode(const {
                'header': {'record_id': '33333333-3333-4333-8333-333333333333'},
              }),
              remoteEnvelopeJson: '{}',
              state: const Value('upload_pending'),
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      expect(await db.countPending(repository.vaultId), 0);
      final result = await repository.synchronize();

      expect(result.status, 'deletion_pending');
      expect(api.conflictUploadCalls, 1);
      expect(api.pushCalls, 0);
      final conflicts = await db.pendingConflictUploads(repository.vaultId);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.conflictId, conflictId);

      await db.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'conflict resolution decrypts and re-encrypts object refs intact',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _FlakyApiClient(identity: identity, database: db);
      final vaultKey = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      final repository = SyncRepository(
        api: api,
        database: db,
        crypto: crypto,
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: '22222222-2222-4222-8222-222222222222',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultKey: Uint8List.fromList(vaultKey),
      );
      const recordId = '33333333-3333-4333-8333-333333333333';
      const conflictId = '44444444-4444-4444-8444-444444444444';
      const refs = [
        '55555555-5555-4555-8555-555555555555',
        '66666666-6666-4666-8666-666666666666',
      ];
      final remote = await crypto.encryptRecord(
        vaultKey: vaultKey,
        serverSpaceId: repository.serverSpaceId,
        vaultId: repository.vaultId,
        recordId: recordId,
        baseRevisionId: null,
        deviceId: identity.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': recordId,
          'type': 'host',
          'name': 'Remote base',
          '_manifest': {'object_refs': refs},
        },
        identity: identity,
      );
      final remoteHeader = remote['header'] as Map<String, dynamic>;
      await db.storeRemoteEnvelope(
        vaultId: repository.vaultId,
        recordId: recordId,
        revisionId: remoteHeader['revision_id'] as String,
        envelope: Map<String, dynamic>.from(remote),
        commitSeq: '1',
        deleted: false,
        instanceId: repository.instanceId,
        serverSpaceId: repository.serverSpaceId,
      );
      expect(await db.nextDeviceSequence(identity.deviceId), '1');

      final local = await repository.saveRecord(
        recordId: recordId,
        baseRevisionId: remoteHeader['revision_id'] as String,
        operation: 'update',
        plaintext: const {
          'id': recordId,
          'type': 'host',
          'name': 'Chosen local branch',
          '_manifest': {'object_refs': refs},
        },
      );
      final localHeader = local['header'] as Map<String, dynamic>;
      await db.markConflicted(localHeader['op_id'] as String);
      await db.saveConflict(
        conflictId: conflictId,
        vaultId: repository.vaultId,
        recordId: recordId,
        instanceId: repository.instanceId,
        serverSpaceId: repository.serverSpaceId,
        kind: 'concurrent_edit',
        branchEnvelope: Map<String, dynamic>.from(local),
        remoteEnvelope: Map<String, dynamic>.from(remote),
      );

      await repository.resolveConflictBranch(
        conflictId: conflictId,
        keepLocal: true,
      );

      final resolvedOperation = (await db.queuedOperations(
        repository.vaultId,
      )).single;
      final resolvedEnvelope =
          jsonDecode(resolvedOperation.envelopeJson) as Map<String, dynamic>;
      expect(
        (resolvedEnvelope['header'] as Map<String, dynamic>)['object_refs'],
        refs,
      );
      final resolvedPlaintext = await crypto.decryptRecord(
        vaultKey: vaultKey,
        envelope: resolvedEnvelope,
        authorPublicKey: identity.signing.publicKey,
      );
      expect(
        (resolvedPlaintext['_manifest'] as Map<String, dynamic>)['object_refs'],
        refs,
      );

      await db.close();
      api.close();
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );
}

void _expectStablePendingOperation(
  PendingOperation operation, {
  required String opId,
  required String revisionId,
  required String envelopeJson,
  required int expectedAttemptCount,
}) {
  final header = Map<String, dynamic>.from(
    (jsonDecode(operation.envelopeJson) as Map)['header'] as Map,
  );
  expect(operation.opId, opId);
  expect(operation.envelopeJson, envelopeJson);
  expect(header['op_id'], opId);
  expect(header['revision_id'], revisionId);
  expect(operation.attemptCount, expectedAttemptCount);
}

List<String> _seededPostFailureActionOrder(int seed) {
  var state = seed & 0xffffffff;
  int nextUint32() {
    state = (1664525 * state + 1013904223) & 0xffffffff;
    return state;
  }

  final actions = ['retry', 'reopen'];
  final swapIndex = nextUint32() % actions.length;
  if (swapIndex != 1) return actions;
  final first = actions[0];
  actions[0] = actions[1];
  actions[1] = first;
  return actions;
}

class _FlakyApiClient extends ApiClient {
  _FlakyApiClient({
    required this.identity,
    required this.database,
    this.deleteOnFirstPush = false,
    this.deleteOnConflictUpload = false,
    this.pushBarrier,
    bool failFirstPush = true,
  }) : _failNextPush = failFirstPush,
       super(baseUrl: 'https://sync-test.example');

  final DeviceIdentity identity;
  final ClientDatabase database;
  bool _failNextPush;
  bool deleteOnFirstPush;
  bool deleteOnConflictUpload;
  final _TwoTabPushBarrier? pushBarrier;
  int conflictUploadCalls = 0;
  int? pendingCountAtFirstPush;
  final List<Object?> pushOperationIds = [];
  int get pushCalls => pushOperationIds.length;

  @override
  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    conflictUploadCalls++;
    if (deleteOnConflictUpload) {
      deleteOnConflictUpload = false;
      throw const ApiException(
        statusCode: 409,
        code: 'VAULT_DELETION_PENDING',
        message: 'Vault is read-only while deletion is pending.',
      );
    }
    return const {
      'conflict_id': '55555555-5555-4555-8555-555555555555',
      'status': 'stored',
    };
  }

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    {
      'device_id': identity.deviceId,
      'user_id': '55555555-5555-4555-8555-555555555555',
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];

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
    serverGeneration:
        serverGeneration ?? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async => const SyncPage(
    events: [],
    nextCursor: null,
    hasMore: false,
    serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pendingCountAtFirstPush ??= await database.countPending(vaultId);
    final operations = batch['operations'] as List<dynamic>;
    final envelope = Map<String, dynamic>.from(operations.single as Map);
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    final opId = header['op_id'];
    pushOperationIds.add(opId);
    if (deleteOnFirstPush) {
      deleteOnFirstPush = false;
      throw const ApiException(
        statusCode: 409,
        code: 'VAULT_DELETION_PENDING',
        message: 'Vault is read-only while deletion is pending.',
      );
    }
    if (_failNextPush) {
      _failNextPush = false;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Temporary offline test failure',
      );
    }
    final barrier = pushBarrier;
    if (barrier != null) return barrier.push(batch);
    return {
      'batch_id': batch['batch_id'],
      'results': [
        {
          'op_id': opId,
          'revision_id': header['revision_id'],
          'commit_seq': '1',
          'already_committed': false,
        },
      ],
    };
  }
}

class _LostAckRetryApiClient extends _FlakyApiClient {
  _LostAckRetryApiClient({
    required super.identity,
    required super.database,
    required this.ledger,
  }) : super(failFirstPush: false);

  final _LostAckServerLedger ledger;

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    final pendingCount = await database.countPending(vaultId);
    final operations = batch['operations'] as List<dynamic>;
    if (operations.length != 1) {
      throw StateError('The seeded test expects a one-operation batch.');
    }
    final envelope = Map<String, dynamic>.from(operations.single as Map);
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    final opId = header['op_id'] as String;
    final revisionId = header['revision_id'] as String;
    final recordId = header['record_id'] as String;
    final envelopeJson = jsonEncode(envelope);
    final batchId = batch['batch_id'] as String;
    ledger.attempts.add(
      _LostAckPushAttempt(
        batchId: batchId,
        opId: opId,
        revisionId: revisionId,
        recordId: recordId,
        envelopeJson: envelopeJson,
        pendingCount: pendingCount,
      ),
    );

    final previous = ledger.committedOperations[opId];
    final alreadyCommitted = previous != null;
    if (previous == null) {
      ledger.committedOperations[opId] = _LostAckCommittedOperation(
        revisionId: revisionId,
        recordId: recordId,
        envelopeJson: envelopeJson,
        commitSeq: '1',
      );
      ledger.receipts.add(opId);
      ledger.versions.add(opId);
      ledger.events.add(opId);
      ledger.heads.add(recordId);
    } else if (previous.revisionId != revisionId ||
        previous.recordId != recordId ||
        previous.envelopeJson != envelopeJson) {
      throw StateError('Retry changed the committed operation identity.');
    }

    if (!ledger.firstAckLost) {
      ledger.firstAckLost = true;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Simulated lost push acknowledgement after commit.',
      );
    }
    if (alreadyCommitted) ledger.duplicateAckCount++;
    final committed = ledger.committedOperations[opId]!;
    return {
      'batch_id': batchId,
      'results': [
        {
          'op_id': opId,
          'revision_id': revisionId,
          'commit_seq': committed.commitSeq,
          'already_committed': alreadyCommitted,
        },
      ],
    };
  }
}

class _LostAckServerLedger {
  final Map<String, _LostAckCommittedOperation> committedOperations = {};
  final List<_LostAckPushAttempt> attempts = [];
  final Set<String> receipts = {};
  final Set<String> versions = {};
  final Set<String> events = {};
  final Set<String> heads = {};
  bool firstAckLost = false;
  int duplicateAckCount = 0;

  int get receiptCount => receipts.length;
  int get versionCount => versions.length;
  int get eventCount => events.length;
  int get headCount => heads.length;
}

class _LostAckCommittedOperation {
  const _LostAckCommittedOperation({
    required this.revisionId,
    required this.recordId,
    required this.envelopeJson,
    required this.commitSeq,
  });

  final String revisionId;
  final String recordId;
  final String envelopeJson;
  final String commitSeq;
}

class _LostAckPushAttempt {
  const _LostAckPushAttempt({
    required this.batchId,
    required this.opId,
    required this.revisionId,
    required this.recordId,
    required this.envelopeJson,
    required this.pendingCount,
  });

  final String batchId;
  final String opId;
  final String revisionId;
  final String recordId;
  final String envelopeJson;
  final int pendingCount;
}

SyncRepository _makeSyncRepository({
  required SodiumSumo sodium,
  required ApiClient api,
  required ClientDatabase database,
  required DeviceIdentity identity,
  required List<int> vaultKey,
}) => SyncRepository(
  api: api,
  database: database,
  crypto: VaultCrypto(sodium),
  identity: identity,
  serverSpaceId: _testServerSpaceId,
  instanceId: _testInstanceId,
  vaultId: _testVaultId,
  keyEpoch: '1',
  membershipVersion: '1',
  serverGeneration: _testInstanceId,
  vaultKey: Uint8List.fromList(vaultKey),
);

class _TwoTabPushBarrier {
  final Completer<void> _bothPushed = Completer<void>();
  final List<String> batchIds = [];
  final Map<String, String> _envelopesByOpId = {};
  final Set<String> _committedOpIds = {};

  int get pushCalls => batchIds.length;
  int get logicalReceiptCount => _committedOpIds.length;
  int get versionCount => _committedOpIds.length;
  int get eventCount => _committedOpIds.length;
  int get headCount => _committedOpIds.length;

  Future<Map<String, dynamic>> push(Map<String, Object?> batch) async {
    batchIds.add(batch['batch_id'] as String);
    final rawOperations = batch['operations'] as List<dynamic>;
    final envelope = Map<String, dynamic>.from(rawOperations.single as Map);
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    final opId = header['op_id'] as String;
    final encoded = jsonEncode(envelope);
    final previousEnvelope = _envelopesByOpId[opId];
    if (previousEnvelope != null && previousEnvelope != encoded) {
      throw StateError('Concurrent push changed the operation envelope.');
    }
    _envelopesByOpId[opId] = encoded;
    if (batchIds.length == 2 && !_bothPushed.isCompleted) {
      _bothPushed.complete();
    }
    await _bothPushed.future.timeout(const Duration(seconds: 10));
    final alreadyCommitted = !_committedOpIds.add(opId);
    return {
      'batch_id': batch['batch_id'],
      'results': [
        {
          'op_id': opId,
          'revision_id': header['revision_id'],
          'commit_seq': '1',
          'already_committed': alreadyCommitted,
        },
      ],
    };
  }
}
