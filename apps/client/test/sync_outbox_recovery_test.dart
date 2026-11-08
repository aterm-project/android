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
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordA = '33333333-3333-4333-8333-333333333333';
const _recordB = '44444444-4444-4444-8444-444444444444';
const _conflictId = '55555555-5555-4555-8555-555555555555';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'replays the identical encrypted outbox after restart when commit receipt was lost',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-outbox-replay-',
      );
      final file = File('${directory.path}/client.sqlite');
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final api = _ReplayApi(identity, sodium);
      final firstDatabase = ClientDatabase.forTesting(NativeDatabase(file));
      final firstRepository = _repository(
        api: api,
        database: firstDatabase,
        identity: identity,
        key: key,
      );

      final savedEnvelope = await firstRepository.saveRecord(
        recordId: _recordA,
        plaintext: const {
          'id': _recordA,
          'type': 'host',
          'name': 'Durable offline draft',
          'address': '10.8.0.1',
          'username': 'ops',
        },
      );
      api.loseNextPushResponseAfterCommit = true;
      await expectLater(
        firstRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(await firstDatabase.scopedCountPending(_vaultId), 1);
      final savedHeader = savedEnvelope['header'] as Map<String, dynamic>;
      final pendingBeforeRestart = await firstDatabase.queuedOperations(
        _vaultId,
      );
      expect(pendingBeforeRestart.single.status, 'sent');
      expect(pendingBeforeRestart.single.opId, savedHeader['op_id']);
      final envelopeBeforeRestart = pendingBeforeRestart.single.envelopeJson;
      await firstDatabase.close();

      final reopenedDatabase = ClientDatabase.forTesting(NativeDatabase(file));
      final reopenedRepository = _repository(
        api: api,
        database: reopenedDatabase,
        identity: identity,
        key: key,
      );
      final localRows = await reopenedDatabase.scopedCachedEnvelopes(_vaultId);
      expect(localRows, hasLength(1));
      expect(localRows.single.envelopeJson, envelopeBeforeRestart);

      final recovered = await reopenedRepository.synchronize();
      expect(recovered.status, 'idle');
      expect(await reopenedDatabase.scopedCountPending(_vaultId), 0);
      expect(api.serverCommitCount, 1);
      expect(api.pushRequests, hasLength(2));
      final firstRequestEnvelope = _onlyEnvelope(api.pushRequests[0]);
      final retryEnvelope = _onlyEnvelope(api.pushRequests[1]);
      expect(jsonEncode(retryEnvelope), jsonEncode(firstRequestEnvelope));
      expect(jsonEncode(retryEnvelope), envelopeBeforeRestart);
      expect(
        (await reopenedDatabase.scopedCachedEnvelopes(
          _vaultId,
        )).single.commitSeq,
        '1',
      );

      await reopenedDatabase.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'late push receipt is acknowledged after the pulled head advances past its event',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final mergeDevice = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _DelayedPushResponseApi(identity, sodium)..trust(mergeDevice);
      final crypto = VaultCrypto(sodium);
      final sender = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final puller = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      Future<SyncResult>? senderSync;

      try {
        final operationEnvelope = await sender.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(name: 'First commit', tags: const []),
        );
        final operationHeader =
            operationEnvelope['header'] as Map<String, dynamic>;
        final expected = (await database.queuedOperations(_vaultId)).single;

        senderSync = sender.synchronize();
        final delayedResponse = await api.firstCommittedResponse.future;
        final responseResult =
            (delayedResponse['results'] as List<dynamic>).single
                as Map<String, dynamic>;
        final commitSeq = responseResult['commit_seq'] as String;
        final firstRevisionId = operationHeader['revision_id'] as String;

        final descendantEnvelope = await _encryptHost(
          crypto: crypto,
          identity: mergeDevice,
          key: key,
          plaintext: _hostPlaintext(
            name: 'Merged descendant',
            tags: const ['remote-tag'],
          ),
          seq: '1',
          operation: 'update',
          baseRevisionId: firstRevisionId,
        );
        final descendantHeader =
            descendantEnvelope['header'] as Map<String, dynamic>;
        final descendantRevisionId = descendantHeader['revision_id'] as String;
        api
          ..setServerHead(_recordA, descendantRevisionId)
          ..queueEvent({
            'commit_seq': commitSeq,
            'event_type': operationHeader['operation'],
            'record_id': _recordA,
            'revision_id': firstRevisionId,
            'envelope': operationEnvelope,
          })
          ..queueEvent({
            'commit_seq': (int.parse(commitSeq) + 1).toString(),
            'event_type': 'update',
            'record_id': _recordA,
            'revision_id': descendantRevisionId,
            'envelope': descendantEnvelope,
          });

        final pullResult = await puller.synchronize();
        expect(pullResult.status, 'idle');
        expect(pullResult.conflictCount, 0);
        expect(await database.scopedCountPending(_vaultId), 0);
        final cachedAfterPull = await database.cachedEnvelope(
          _vaultId,
          _recordA,
        );
        expect(cachedAfterPull?.revisionId, descendantRevisionId);
        expect(cachedAfterPull?.commitSeq, '2');
        final proofRows = await database
            .select(database.authenticatedPushReceipts)
            .get();
        expect(proofRows, hasLength(1));
        expect(proofRows.single.createdAt, greaterThan(0));
        final modifiedEnvelope =
            jsonDecode(expected.envelopeJson) as Map<String, dynamic>;
        modifiedEnvelope['ciphertext'] = 'different-operation-bytes';
        await expectLater(
          database.acknowledgePushBatch(
            vaultId: _vaultId,
            requested: [
              expected.copyWith(envelopeJson: jsonEncode(modifiedEnvelope)),
            ],
            receipts: {
              expected.opId: PushCommitReceipt(
                opId: expected.opId,
                revisionId: firstRevisionId,
                commitSeq: commitSeq,
              ),
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          await database.select(database.authenticatedPushReceipts).get(),
          hasLength(1),
        );

        // A mismatched delayed receipt must leave the authenticated event proof
        // available for the actual response.
        await expectLater(
          database.acknowledgePushBatch(
            vaultId: _vaultId,
            requested: [expected],
            receipts: {
              expected.opId: PushCommitReceipt(
                opId: expected.opId,
                revisionId: firstRevisionId,
                commitSeq: '999',
              ),
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          await database.select(database.authenticatedPushReceipts).get(),
          hasLength(1),
        );

        api.releaseFirstResponse.complete();
        final pushResult = await senderSync;
        expect(pushResult.status, 'idle');
        expect(pushResult.conflictCount, 0);
        expect(await database.scopedCountPending(_vaultId), 0);
        expect(await database.scopedOpenConflicts(_vaultId), isEmpty);
        expect(
          await database.select(database.authenticatedPushReceipts).get(),
          isEmpty,
        );
        final cachedAfterReceipt = await database.cachedEnvelope(
          _vaultId,
          _recordA,
        );
        expect(cachedAfterReceipt?.revisionId, descendantRevisionId);
        expect(cachedAfterReceipt?.commitSeq, '2');
        final loaded = await sender.loadRecords();
        expect(loaded.single['name'], 'Merged descendant');
        expect(loaded.single['tags'], ['remote-tag']);
      } finally {
        if (!api.releaseFirstResponse.isCompleted) {
          api.releaseFirstResponse.complete();
        }
        if (senderSync != null) {
          try {
            await senderSync;
          } on Object {
            // Preserve the original assertion while waiting for the held
            // request to stop touching the shared test database.
          }
        }
        await database.close();
        api.close();
        identity.dispose();
        mergeDevice.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'a local edit racing a pull is retained and reconciled as a conflict',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final remoteDevice = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(identity, sodium)..trust(remoteDevice);
      final atRemoteStore = Completer<void>();
      final resumeRemoteStore = Completer<void>();
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
        beforeStorePulledEventForTesting: () async {
          if (!atRemoteStore.isCompleted) {
            atRemoteStore.complete();
            await resumeRemoteStore.future;
          }
        },
      );
      final remote = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: remoteDevice,
        key: key,
        recordId: _recordA,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'Remote create',
      );
      final remoteHeader = remote['header'] as Map<String, dynamic>;
      api.queueEvent({
        'commit_seq': '7',
        'event_type': remoteHeader['operation'],
        'record_id': remoteHeader['record_id'],
        'revision_id': remoteHeader['revision_id'],
        'envelope': remote,
      });

      try {
        final sync = repository.synchronize();
        await atRemoteStore.future;
        final local = await repository.saveRecord(
          recordId: _recordA,
          plaintext: const {
            'id': _recordA,
            'type': 'host',
            'name': 'Local create during pull',
          },
        );
        resumeRemoteStore.complete();

        final result = await sync;

        expect(result.status, 'idle');
        expect(api.pushRequests, isEmpty);
        expect(api.conflictUploadRequests, hasLength(1));
        final cached = await database.cachedEnvelope(_vaultId, _recordA);
        expect(cached?.revisionId, remoteHeader['revision_id']);
        expect(cached?.envelopeJson, jsonEncode(remote));
        expect(cached?.commitSeq, '7');
        final outbox = await database.scopedAllPendingOperations(_vaultId);
        expect(outbox, hasLength(1));
        expect(outbox.single.envelopeJson, jsonEncode(local));
        expect(outbox.single.status, 'conflict');
        final conflicts = await database.scopedOpenConflicts(_vaultId);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.branchEnvelopeJson, jsonEncode(local));
        expect(conflicts.single.remoteEnvelopeJson, jsonEncode(remote));
        expect(conflicts.single.state, 'open');
        expect(
          (await database.scopedCheckpoint(_vaultId))?.cursor,
          'event-cursor',
        );
      } finally {
        if (!resumeRemoteStore.isCompleted) resumeRemoteStore.complete();
        await database.close();
        api.close();
        identity.dispose();
        remoteDevice.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'same-base Host edits auto-merge both commit orders and retain sensitive conflicts',
    () async {
      Future<void> verifyAutoMerge({required bool localRenames}) async {
        final localIdentity = DeviceIdentity.create(sodium);
        final remoteIdentity = DeviceIdentity.create(sodium);
        final key = sodium.randombytes.buf(32);
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        final api = _ReplayApi(localIdentity, sodium)..trust(remoteIdentity);
        final repository = _repository(
          api: api,
          database: database,
          identity: localIdentity,
          key: key,
        );
        final crypto = VaultCrypto(sodium);
        final base = _hostPlaintext(name: 'Base host', tags: const []);
        final baseEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: base,
          seq: '1',
          operation: 'create',
          baseRevisionId: null,
        );
        final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
        final baseRevisionId = baseHeader['revision_id'] as String;
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordA,
          revisionId: baseRevisionId,
          envelope: baseEnvelope,
          commitSeq: '1',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );

        final local = _hostPlaintext(
          name: localRenames ? 'Local host name' : 'Base host',
          tags: localRenames ? const [] : const ['local-tag'],
        );
        final firstLocalEnvelope = await repository.saveRecord(
          recordId: _recordA,
          plaintext: local,
          baseRevisionId: baseRevisionId,
          operation: 'update',
        );
        final firstLocalHeader =
            firstLocalEnvelope['header'] as Map<String, dynamic>;
        await (database.update(database.pendingOperations)..where(
              (row) => row.opId.equals(firstLocalHeader['op_id'] as String),
            ))
            .write(const PendingOperationsCompanion(status: Value('sent')));
        final secondLocalEnvelope = await repository.saveRecord(
          recordId: _recordA,
          plaintext: {...local, 'color': 0x123456},
          baseRevisionId: firstLocalHeader['revision_id'] as String,
          operation: 'update',
        );
        final secondLocalHeader =
            secondLocalEnvelope['header'] as Map<String, dynamic>;
        // Equal timestamps make SQL's tie order independent of the edit
        // sequence. The merge path must follow signed revision links.
        for (final opId in [
          firstLocalHeader['op_id'] as String,
          secondLocalHeader['op_id'] as String,
        ]) {
          await (database.update(database.pendingOperations)
                ..where((row) => row.opId.equals(opId)))
              .write(const PendingOperationsCompanion(createdAt: Value(123)));
        }
        final remote = _hostPlaintext(
          name: localRenames ? 'Base host' : 'Remote host name',
          tags: localRenames ? const ['remote-tag'] : const [],
        );
        final remoteEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: remote,
          seq: '2',
          operation: 'update',
          baseRevisionId: baseRevisionId,
        );
        final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
        final remoteRevisionId = remoteHeader['revision_id'] as String;
        api
          ..serverCommitCount = 2
          ..setServerHead(_recordA, remoteRevisionId)
          ..queueEvent({
            'commit_seq': '2',
            'event_type': 'update',
            'record_id': _recordA,
            'revision_id': remoteRevisionId,
            'envelope': remoteEnvelope,
          });

        final result = await repository.synchronize();

        expect(result.status, 'idle');
        expect(result.conflictCount, 0);
        expect(api.conflictUploadRequests, isEmpty);
        expect(api.pushRequests, hasLength(1));
        expect(await database.scopedCountPending(_vaultId), 0);
        final supersededRows = await database.scopedSupersededOperations(
          _vaultId,
        );
        expect(supersededRows, hasLength(2));
        expect(supersededRows.map((row) => row.opId).toSet(), {
          firstLocalHeader['op_id'],
          secondLocalHeader['op_id'],
        });
        expect(await database.scopedAllPendingOperations(_vaultId), isEmpty);
        final committedEnvelope = _onlyEnvelope(api.pushRequests.single);
        final committedHeader =
            committedEnvelope['header'] as Map<String, dynamic>;
        expect(committedHeader['base_revision_id'], remoteRevisionId);
        expect(committedHeader['device_id'], localIdentity.deviceId);
        expect(committedHeader['revision_id'], isNot(remoteRevisionId));
        final cached = await database.cachedEnvelope(_vaultId, _recordA);
        expect(cached?.revisionId, committedHeader['revision_id']);
        expect(cached?.commitSeq, '3');
        final records = await repository.loadRecords();
        final merged = records.single;
        expect(
          merged['name'],
          localRenames ? 'Local host name' : 'Remote host name',
        );
        expect(merged['tags'], localRenames ? ['remote-tag'] : ['local-tag']);
        expect(merged['color'], 0x123456);
        expect(await database.scopedOpenConflicts(_vaultId), isEmpty);

        await database.close();
        api.close();
        localIdentity.dispose();
        remoteIdentity.dispose();
        key.fillRange(0, key.length, 0);
      }

      await verifyAutoMerge(localRenames: true);
      await verifyAutoMerge(localRenames: false);

      final localIdentity = DeviceIdentity.create(sodium);
      final remoteIdentity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(localIdentity, sodium)..trust(remoteIdentity);
      final repository = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
      );
      final crypto = VaultCrypto(sodium);
      final base = _hostPlaintext(name: 'Base host', tags: const []);
      final baseEnvelope = await _encryptHost(
        crypto: crypto,
        identity: remoteIdentity,
        key: key,
        plaintext: base,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
      );
      final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
      final baseRevisionId = baseHeader['revision_id'] as String;
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordA,
        revisionId: baseRevisionId,
        envelope: baseEnvelope,
        commitSeq: '1',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );
      final local = _hostPlaintext(
        name: 'Base host',
        tags: const [],
        address: 'local.example',
      );
      await repository.saveRecord(
        recordId: _recordA,
        plaintext: local,
        baseRevisionId: baseRevisionId,
        operation: 'update',
      );
      final remote = _hostPlaintext(
        name: 'Base host',
        tags: const [],
        address: 'remote.example',
      );
      final remoteEnvelope = await _encryptHost(
        crypto: crypto,
        identity: remoteIdentity,
        key: key,
        plaintext: remote,
        seq: '2',
        operation: 'update',
        baseRevisionId: baseRevisionId,
      );
      final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
      final remoteRevisionId = remoteHeader['revision_id'] as String;
      api
        ..serverCommitCount = 2
        ..setServerHead(_recordA, remoteRevisionId)
        ..queueEvent({
          'commit_seq': '2',
          'event_type': 'update',
          'record_id': _recordA,
          'revision_id': remoteRevisionId,
          'envelope': remoteEnvelope,
        });

      final result = await repository.synchronize();

      expect(result.conflictCount, 1);
      expect(api.conflictUploadRequests, hasLength(1));
      expect(api.pushRequests, isEmpty);
      expect(
        (await database.scopedOpenConflicts(_vaultId)).single.kind,
        'concurrent_edit',
      );
      expect(
        (await database.cachedEnvelope(_vaultId, _recordA))?.revisionId,
        remoteRevisionId,
      );
      expect(
        (await database.scopedAllPendingOperations(
          _vaultId,
        )).singleWhere((operation) => operation.status == 'conflict').status,
        'conflict',
      );

      await database.close();
      api.close();
      localIdentity.dispose();
      remoteIdentity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'single-record atomic revision conflict preserves the local branch after signed refresh',
    () async {
      final localIdentity = DeviceIdentity.create(sodium);
      final remoteIdentity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _AtomicRevisionConflictApi(localIdentity, sodium)
        ..trust(remoteIdentity);
      final crypto = VaultCrypto(sodium);
      late Map<String, dynamic> competingEnvelope;
      var competitionCommitted = false;
      final repository = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
        beforePushMarkAttemptedForTesting: () async {
          if (competitionCommitted) return;
          competitionCommitted = true;
          api.commitCompetingUpdate(
            recordId: _recordA,
            envelope: competingEnvelope,
            commitSeq: '2',
          );
        },
      );

      try {
        final baseEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: _hostPlaintext(name: 'Base host', tags: const []),
          seq: '1',
          operation: 'create',
          baseRevisionId: null,
        );
        final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
        final baseRevisionId = baseHeader['revision_id'] as String;
        api.seedCommittedEnvelope(baseEnvelope, commitSeq: '1');
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordA,
          revisionId: baseRevisionId,
          envelope: baseEnvelope,
          commitSeq: '1',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );

        final localEnvelope = await repository.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(
            name: 'Local concurrent name',
            tags: const [],
          ),
          baseRevisionId: baseRevisionId,
          operation: 'update',
        );
        competingEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: _hostPlaintext(
            name: 'Remote concurrent name',
            tags: const [],
          ),
          seq: '2',
          operation: 'update',
          baseRevisionId: baseRevisionId,
        );

        final result = await repository.synchronize();

        final localHeader = localEnvelope['header'] as Map<String, dynamic>;
        final competingHeader =
            competingEnvelope['header'] as Map<String, dynamic>;
        final competingRevisionId = competingHeader['revision_id'] as String;
        expect(result.status, 'idle');
        expect(result.conflictCount, 1);
        expect(api.pushRequests, hasLength(1));
        expect(api.pushRequests.single['operations'], [localEnvelope]);
        expect(api.changesRequestCursors, [null, null]);
        expect(api.rejectedLedgerSnapshots, hasLength(1));
        expect(api.rejectedLedgerSnapshots.single['serverCommitCount'], 2);
        expect(api.rejectedLedgerSnapshots.single['heads'], {
          _recordA: competingRevisionId,
        });
        expect(api.rejectedLedgerSnapshots.single['operationIds'], {
          baseHeader['op_id'],
          competingHeader['op_id'],
        });
        expect(api.serverCommitCount, 2);
        expect(
          api._committedOperations.containsKey(localHeader['op_id']),
          isFalse,
        );

        expect(api.conflictUploadRequests, hasLength(1));
        expect(api.conflictUploadRequests.single['envelope'], localEnvelope);
        final pending = await database.scopedAllPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.status, 'conflict');
        expect(pending.single.envelopeJson, jsonEncode(localEnvelope));
        final conflicts = await database.scopedOpenConflicts(_vaultId);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.kind, 'concurrent_edit');
        expect(conflicts.single.branchEnvelopeJson, jsonEncode(localEnvelope));
        expect(
          conflicts.single.remoteEnvelopeJson,
          jsonEncode(competingEnvelope),
        );
        final cached = await database.cachedEnvelope(_vaultId, _recordA);
        expect(cached?.revisionId, competingRevisionId);
        expect(cached?.envelopeJson, jsonEncode(competingEnvelope));
        expect(cached?.commitSeq, '2');
        expect(
          (await database.scopedCheckpoint(_vaultId))?.cursor,
          'event-cursor',
        );
        expect(
          (await repository.loadRecords()).single['name'],
          'Remote concurrent name',
        );
      } finally {
        await database.close();
        api.close();
        localIdentity.dispose();
        remoteIdentity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'single-record atomic revision conflict auto-merges disjoint Host edits',
    () async {
      final localIdentity = DeviceIdentity.create(sodium);
      final remoteIdentity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _AtomicRevisionConflictApi(localIdentity, sodium)
        ..trust(remoteIdentity);
      final crypto = VaultCrypto(sodium);
      late Map<String, dynamic> competingEnvelope;
      var competitionCommitted = false;
      final repository = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
        beforePushMarkAttemptedForTesting: () async {
          if (competitionCommitted) return;
          competitionCommitted = true;
          api.commitCompetingUpdate(
            recordId: _recordA,
            envelope: competingEnvelope,
            commitSeq: '2',
          );
        },
      );

      try {
        final baseEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: _hostPlaintext(name: 'Base host', tags: const []),
          seq: '1',
          operation: 'create',
          baseRevisionId: null,
        );
        final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
        final baseRevisionId = baseHeader['revision_id'] as String;
        api.seedCommittedEnvelope(baseEnvelope, commitSeq: '1');
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordA,
          revisionId: baseRevisionId,
          envelope: baseEnvelope,
          commitSeq: '1',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );

        final localEnvelope = await repository.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(
            name: 'Local concurrent name',
            tags: const [],
          ),
          baseRevisionId: baseRevisionId,
          operation: 'update',
        );
        competingEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          plaintext: _hostPlaintext(
            name: 'Base host',
            tags: const ['remote-tag'],
          ),
          seq: '2',
          operation: 'update',
          baseRevisionId: baseRevisionId,
        );

        final result = await repository.synchronize();

        final localHeader = localEnvelope['header'] as Map<String, dynamic>;
        final competingHeader =
            competingEnvelope['header'] as Map<String, dynamic>;
        final competingRevisionId = competingHeader['revision_id'] as String;
        expect(result.status, 'idle');
        expect(result.conflictCount, 0);
        expect(api.pushRequests, hasLength(2));
        expect(
          api.pushRequests.map(
            (request) => (request['operations'] as List<dynamic>).length,
          ),
          [1, 1],
        );
        expect(api.changesRequestCursors, [null, null]);
        expect(api.rejectedLedgerSnapshots, hasLength(1));
        expect(api.serverCommitCount, 3);
        expect(
          api._committedOperations.containsKey(localHeader['op_id']),
          isFalse,
        );

        final rejectedEnvelope = _onlyEnvelope(api.pushRequests.first);
        final mergedEnvelope = _onlyEnvelope(api.pushRequests.last);
        expect(jsonEncode(rejectedEnvelope), jsonEncode(localEnvelope));
        final mergedHeader = mergedEnvelope['header'] as Map<String, dynamic>;
        expect(mergedHeader['op_id'], isNot(localHeader['op_id']));
        expect(mergedHeader['base_revision_id'], competingRevisionId);
        expect(mergedHeader['device_id'], localIdentity.deviceId);
        expect(
          api._committedOperations[mergedHeader['op_id']]?['envelope'],
          mergedEnvelope,
        );
        final cached = await database.cachedEnvelope(_vaultId, _recordA);
        expect(cached?.revisionId, mergedHeader['revision_id']);
        expect(cached?.envelopeJson, jsonEncode(mergedEnvelope));
        expect(cached?.commitSeq, '3');
        expect(await database.scopedAllPendingOperations(_vaultId), isEmpty);
        final superseded = await database.scopedSupersededOperations(_vaultId);
        expect(superseded, hasLength(1));
        expect(superseded.single.opId, localHeader['op_id']);
        expect(superseded.single.envelopeJson, jsonEncode(localEnvelope));
        expect(await database.scopedOpenConflicts(_vaultId), isEmpty);
        final merged = (await repository.loadRecords()).single;
        expect(merged['name'], 'Local concurrent name');
        expect(merged['tags'], ['remote-tag']);
      } finally {
        await database.close();
        api.close();
        localIdentity.dispose();
        remoteIdentity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'repeated atomic revision conflict stops after one signed refresh',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _AtomicRevisionConflictApi(identity, sodium);
      var advancedHead = false;
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
        beforePushMarkAttemptedForTesting: () async {
          if (advancedHead) return;
          advancedHead = true;
          // Simulate a conflict whose signed event is not available in this
          // response window. The client must retain both envelopes and stop
          // after one bounded refresh instead of retrying indefinitely.
          api.setServerHead(_recordA, _conflictId);
        },
      );

      try {
        final localA = await repository.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(name: 'Local A', tags: const []),
        );
        final localB = await repository.saveRecord(
          recordId: _recordB,
          plaintext: _hostPlaintext(
            recordId: _recordB,
            name: 'Local B',
            tags: const [],
          ),
        );

        final result = await repository.synchronize();

        expect(result.status, 'retry_wait');
        expect(api.pushRequests, hasLength(2));
        expect(
          api.pushRequests.map((request) {
            return (request['operations'] as List<dynamic>).length;
          }),
          [2, 2],
        );
        expect(api.changesRequestCursors, [null, null]);
        expect(api.rejectedLedgerSnapshots, hasLength(2));
        expect(api.serverCommitCount, 0);
        expect(api._committedOperations, isEmpty);
        final retriedEnvelopes = (api.pushRequests.last['operations'] as List)
            .cast<Map<String, dynamic>>();
        expect(retriedEnvelopes, containsAll([localA, localB]));
        final pending = await database.scopedAllPendingOperations(_vaultId);
        expect(pending, hasLength(2));
        expect(pending.map((operation) => operation.envelopeJson).toSet(), {
          jsonEncode(localA),
          jsonEncode(localB),
        });
        expect(
          pending.every((operation) => operation.status == 'sent'),
          isTrue,
        );
      } finally {
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'atomic multi-record revision conflict refreshes signed changes and pushes independent work',
    () async {
      final localIdentity = DeviceIdentity.create(sodium);
      final remoteIdentity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _AtomicRevisionConflictApi(localIdentity, sodium)
        ..trust(remoteIdentity);
      final crypto = VaultCrypto(sodium);
      late Map<String, dynamic> competingEnvelope;
      var competitionCommitted = false;
      final repository = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
        beforePushMarkAttemptedForTesting: () async {
          if (competitionCommitted) return;
          competitionCommitted = true;
          api.commitCompetingUpdate(
            recordId: _recordA,
            envelope: competingEnvelope,
            commitSeq: '3',
          );
        },
      );

      try {
        final baseA = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          recordId: _recordA,
          plaintext: _hostPlaintext(name: 'Base A', tags: const []),
          seq: '1',
          operation: 'create',
          baseRevisionId: null,
        );
        final baseB = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          recordId: _recordB,
          plaintext: _hostPlaintext(
            recordId: _recordB,
            name: 'Base B',
            tags: const [],
          ),
          seq: '2',
          operation: 'create',
          baseRevisionId: null,
        );
        final baseAHeader = baseA['header'] as Map<String, dynamic>;
        final baseBHeader = baseB['header'] as Map<String, dynamic>;
        final baseARevisionId = baseAHeader['revision_id'] as String;
        final baseBRevisionId = baseBHeader['revision_id'] as String;
        api
          ..seedCommittedEnvelope(baseA, commitSeq: '1')
          ..seedCommittedEnvelope(baseB, commitSeq: '2');
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordA,
          revisionId: baseARevisionId,
          envelope: baseA,
          commitSeq: '1',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordB,
          revisionId: baseBRevisionId,
          envelope: baseB,
          commitSeq: '2',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );

        final localA = await repository.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(
            name: 'Base A',
            tags: const [],
            address: 'local-a.example',
          ),
          baseRevisionId: baseARevisionId,
          operation: 'update',
        );
        final localB = await repository.saveRecord(
          recordId: _recordB,
          plaintext: _hostPlaintext(
            recordId: _recordB,
            name: 'Base B',
            tags: const [],
            address: 'local-b.example',
          ),
          baseRevisionId: baseBRevisionId,
          operation: 'update',
        );
        competingEnvelope = await _encryptHost(
          crypto: crypto,
          identity: remoteIdentity,
          key: key,
          recordId: _recordA,
          plaintext: _hostPlaintext(
            name: 'Base A',
            tags: const [],
            address: 'remote-a.example',
          ),
          seq: '3',
          operation: 'update',
          baseRevisionId: baseARevisionId,
        );

        final result = await repository.synchronize();

        final localAHeader = localA['header'] as Map<String, dynamic>;
        final localBHeader = localB['header'] as Map<String, dynamic>;
        final competingHeader =
            competingEnvelope['header'] as Map<String, dynamic>;
        expect(result.status, 'idle');
        expect(result.conflictCount, 1);
        expect(api.conflictUploadRequests, hasLength(1));
        expect(api.conflictUploadRequests.single['envelope'], localA);
        expect(
          api.pushRequests.map((request) {
            return (request['operations'] as List<dynamic>).length;
          }),
          [2, 1],
        );
        expect(api.changesRequestCursors, [null, null]);
        expect(api.rejectedLedgerSnapshots, hasLength(1));
        expect(api.rejectedLedgerSnapshots.single['serverCommitCount'], 3);
        expect(api.rejectedLedgerSnapshots.single['heads'], {
          _recordA: competingHeader['revision_id'],
          _recordB: baseBRevisionId,
        });
        expect(api.rejectedLedgerSnapshots.single['operationIds'], {
          baseAHeader['op_id'],
          baseBHeader['op_id'],
          competingHeader['op_id'],
        });
        expect(api.serverCommitCount, 4);
        expect(
          api._committedOperations.containsKey(localAHeader['op_id']),
          isFalse,
        );
        expect(
          api._committedOperations[localBHeader['op_id']]?['envelope'],
          localB,
        );

        final rejectedBatch = (api.pushRequests.first['operations'] as List)
            .cast<Map<String, dynamic>>();
        expect(rejectedBatch, [localA, localB]);
        expect(_onlyEnvelope(api.pushRequests.last), localB);
        final pending = await database.scopedAllPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.opId, localAHeader['op_id']);
        expect(pending.single.status, 'conflict');
        expect(pending.single.envelopeJson, jsonEncode(localA));
        final conflicts = await database.scopedOpenConflicts(_vaultId);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.kind, 'concurrent_edit');
        expect(conflicts.single.branchEnvelopeJson, jsonEncode(localA));
        expect(
          conflicts.single.remoteEnvelopeJson,
          jsonEncode(competingEnvelope),
        );
        expect(
          (await database.cachedEnvelope(_vaultId, _recordA))?.revisionId,
          competingHeader['revision_id'],
        );
        final cachedB = await database.cachedEnvelope(_vaultId, _recordB);
        expect(cachedB?.revisionId, localBHeader['revision_id']);
        expect(cachedB?.envelopeJson, jsonEncode(localB));
        expect(cachedB?.commitSeq, '4');
        expect(
          (await database.scopedCheckpoint(_vaultId))?.cursor,
          'event-cursor',
        );
      } finally {
        await database.close();
        api.close();
        localIdentity.dispose();
        remoteIdentity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'automatic merge rereads the full outbox after a sibling edit wins replacement race',
    () async {
      final localIdentity = DeviceIdentity.create(sodium);
      final remoteIdentity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(localIdentity, sodium)..trust(remoteIdentity);
      final atReplacement = Completer<void>();
      final resumeReplacement = Completer<void>();
      var replacementPauses = 0;
      final repository = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
        beforeReplaceMergedOperationForTesting: () async {
          replacementPauses++;
          if (replacementPauses == 1) {
            atReplacement.complete();
            await resumeReplacement.future;
          }
        },
      );
      final sibling = _repository(
        api: api,
        database: database,
        identity: localIdentity,
        key: key,
      );
      final crypto = VaultCrypto(sodium);
      final base = _hostPlaintext(name: 'Base host', tags: const []);
      final baseEnvelope = await _encryptHost(
        crypto: crypto,
        identity: remoteIdentity,
        key: key,
        plaintext: base,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
      );
      final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
      final baseRevisionId = baseHeader['revision_id'] as String;
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordA,
        revisionId: baseRevisionId,
        envelope: baseEnvelope,
        commitSeq: '1',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

      const localTags = ['local-tag'];
      final firstLocal = await repository.saveRecord(
        recordId: _recordA,
        plaintext: _hostPlaintext(name: 'Base host', tags: localTags),
        baseRevisionId: baseRevisionId,
        operation: 'update',
      );
      final firstLocalHeader = firstLocal['header'] as Map<String, dynamic>;
      final firstLocalRevisionId = firstLocalHeader['revision_id'] as String;
      await (database.update(database.pendingOperations)..where(
            (row) => row.opId.equals(firstLocalHeader['op_id'] as String),
          ))
          .write(const PendingOperationsCompanion(status: Value('sent')));
      final remoteEnvelope = await _encryptHost(
        crypto: crypto,
        identity: remoteIdentity,
        key: key,
        plaintext: _hostPlaintext(name: 'Remote host name', tags: const []),
        seq: '2',
        operation: 'update',
        baseRevisionId: baseRevisionId,
      );
      final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
      final remoteRevisionId = remoteHeader['revision_id'] as String;
      api
        ..serverCommitCount = 2
        ..setServerHead(_recordA, remoteRevisionId)
        ..queueEvent({
          'commit_seq': '2',
          'event_type': 'update',
          'record_id': _recordA,
          'revision_id': remoteRevisionId,
          'envelope': remoteEnvelope,
        });

      try {
        final sync = repository.synchronize();
        await atReplacement.future;
        final siblingEdit = await sibling.saveRecord(
          recordId: _recordA,
          plaintext: _hostPlaintext(
            name: 'Base host',
            tags: localTags,
            color: 0x654321,
          ),
          baseRevisionId: firstLocalRevisionId,
          operation: 'update',
        );
        final siblingHeader = siblingEdit['header'] as Map<String, dynamic>;
        expect(siblingHeader['base_revision_id'], firstLocalRevisionId);
        resumeReplacement.complete();

        final result = await sync;

        expect(result.status, 'idle');
        expect(result.conflictCount, 0);
        expect(replacementPauses, 2);
        expect(api.conflictUploadRequests, isEmpty);
        expect(api.pushRequests, hasLength(1));
        expect(await database.scopedOpenConflicts(_vaultId), isEmpty);
        final committed = _onlyEnvelope(api.pushRequests.single);
        final committedHeader = committed['header'] as Map<String, dynamic>;
        expect(committedHeader['operation'], 'update');
        expect(committedHeader['base_revision_id'], remoteRevisionId);
        expect(committedHeader['device_id'], localIdentity.deviceId);
        final records = await repository.loadRecords();
        expect(records, hasLength(1));
        expect(records.single['name'], 'Remote host name');
        expect(records.single['tags'], localTags);
        expect(records.single['color'], 0x654321);
        final superseded = await database.scopedSupersededOperations(_vaultId);
        expect(superseded.map((item) => item.opId).toSet(), {
          firstLocalHeader['op_id'],
          siblingHeader['op_id'],
        });
      } finally {
        if (!resumeReplacement.isCompleted) resumeReplacement.complete();
        await database.close();
        api.close();
        localIdentity.dispose();
        remoteIdentity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'rejects an incomplete or mismatched batch receipt without acknowledging any operation',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(identity, sodium);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      await repository.saveRecord(
        recordId: _recordA,
        plaintext: const {'id': _recordA, 'type': 'host', 'name': 'A'},
      );
      await repository.saveRecord(
        recordId: _recordB,
        plaintext: const {'id': _recordB, 'type': 'host', 'name': 'B'},
      );

      api.receiptFault = _ReceiptFault.mismatchedRevision;
      await expectLater(
        repository.synchronize(),
        throwsA(isA<FormatException>()),
      );
      expect(await database.scopedCountPending(_vaultId), 2);
      final afterBadReceipt = await database.scopedAllPendingOperations(
        _vaultId,
      );
      expect(afterBadReceipt, hasLength(2));
      expect(
        afterBadReceipt.every((operation) => operation.status == 'sent'),
        isTrue,
      );
      expect(
        (await database.scopedCachedEnvelopes(
          _vaultId,
        )).every((record) => record.commitSeq == null),
        isTrue,
      );

      api.receiptFault = _ReceiptFault.none;
      final retried = await repository.synchronize();
      expect(retried.status, 'idle');
      expect(await database.scopedCountPending(_vaultId), 0);
      expect(api.serverCommitCount, 2);
      expect(api.pushRequests, hasLength(2));

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'serializes dependent operations for one record across push batches',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(identity, sodium);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final first = await repository.saveRecord(
        recordId: _recordA,
        plaintext: const {'id': _recordA, 'type': 'host', 'name': 'first'},
      );
      final firstHeader = first['header'] as Map<String, dynamic>;
      await database.markAttempted([firstHeader['op_id'] as String]);
      final second = await repository.saveRecord(
        recordId: _recordA,
        baseRevisionId: firstHeader['revision_id'] as String,
        operation: 'update',
        plaintext: const {'id': _recordA, 'type': 'host', 'name': 'second'},
      );
      final secondHeader = second['header'] as Map<String, dynamic>;

      final result = await repository.synchronize();

      expect(result.status, 'idle');
      expect(api.pushRequests, hasLength(2));
      for (final request in api.pushRequests) {
        final operations = request['operations'] as List<dynamic>;
        expect(operations, hasLength(1));
        expect(
          operations
              .map((item) => (item as Map)['header']['record_id'])
              .toSet(),
          hasLength(1),
        );
      }
      expect(
        ((api.pushRequests[0]['operations'] as List).single
            as Map)['header']['op_id'],
        firstHeader['op_id'],
      );
      expect(
        ((api.pushRequests[1]['operations'] as List).single
            as Map)['header']['op_id'],
        secondHeader['op_id'],
      );
      expect(
        ((api.pushRequests[1]['operations'] as List).single
            as Map)['header']['base_revision_id'],
        firstHeader['revision_id'],
      );
      expect(api.serverCommitCount, 2);
      expect(await database.scopedCountPending(_vaultId), 0);

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'keeps a pulled conflict branch and cursor when upload fails, then resumes after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-conflict-upload-',
      );
      final file = File('${directory.path}/client.sqlite');
      final identity = DeviceIdentity.create(sodium);
      final remoteDevice = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      final api = _ReplayApi(identity, sodium)..trust(remoteDevice);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final local = await repository.saveRecord(
        recordId: _recordA,
        plaintext: const {
          'id': _recordA,
          'type': 'host',
          'name': 'Offline local branch',
        },
      );
      final remote = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: remoteDevice,
        key: key,
        recordId: _recordA,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'Remote branch',
      );
      api.queueEvent({
        'commit_seq': '7',
        'event_type': (remote['header']! as Map)['operation'],
        'record_id': (remote['header']! as Map)['record_id'],
        'revision_id': (remote['header']! as Map)['revision_id'],
        'envelope': remote,
      });
      api.failNextConflictUpload = true;

      await expectLater(
        repository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(
        (await database.scopedCheckpoint(_vaultId))?.cursor,
        'event-cursor',
      );
      expect(await database.scopedCountPending(_vaultId), 1);
      expect(
        (await database.scopedAllPendingOperations(_vaultId)).single.status,
        'conflict',
      );
      var localConflict = (await database.scopedOpenConflicts(_vaultId)).single;
      expect(localConflict.state, 'upload_pending');
      expect(localConflict.branchEnvelopeJson, jsonEncode(local));
      expect(
        (await database.scopedCachedEnvelopes(_vaultId)).single.envelopeJson,
        jsonEncode(remote),
      );
      await database.close();

      final reopenedDatabase = ClientDatabase.forTesting(NativeDatabase(file));
      final reopenedRepository = _repository(
        api: api,
        database: reopenedDatabase,
        identity: identity,
        key: key,
      );
      final resumed = await reopenedRepository.synchronize();
      expect(resumed.status, 'idle');
      expect(api.conflictUploadRequests, hasLength(2));
      expect(
        jsonEncode(api.conflictUploadRequests.first['envelope']),
        jsonEncode(api.conflictUploadRequests.last['envelope']),
      );
      expect(await reopenedDatabase.scopedCountPending(_vaultId), 1);
      localConflict = (await reopenedDatabase.scopedOpenConflicts(
        _vaultId,
      )).single;
      expect(localConflict.state, 'open');
      expect(localConflict.conflictId, _ReplayApi.serverConflictId);
      expect(localConflict.branchEnvelopeJson, jsonEncode(local));

      await reopenedDatabase.close();
      api.close();
      identity.dispose();
      remoteDevice.dispose();
      key.fillRange(0, key.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'a late page from another repository cannot regress the shared changes checkpoint',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConcurrentCheckpointApi(identity, sodium);
      final firstRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final secondRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final lateSync = firstRepository.synchronize();
        await api.firstRequestStarted.future;
        final earlySync = secondRepository.synchronize();
        await api.secondRequestStarted.future;
        final earlyResult = await earlySync;

        expect(earlyResult.status, 'idle');
        expect(
          (await database.scopedCheckpoint(_vaultId))?.cursor,
          'newer-cursor',
        );

        api.releaseFirstResponse.complete();
        final lateResult = await lateSync;

        expect(lateResult.status, 'retry_wait');
        expect(api.changesRequestCursors, [null, null]);
        expect(
          (await database.scopedCheckpoint(_vaultId))?.cursor,
          'newer-cursor',
        );
      } finally {
        if (!api.releaseFirstResponse.isCompleted) {
          api.releaseFirstResponse.complete();
        }
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'a late older changes page cannot overwrite a newer cached revision',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final crypto = VaultCrypto(sodium);
      final olderEnvelope = await _encrypt(
        crypto: crypto,
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'older page',
      );
      final newerEnvelope = await _encrypt(
        crypto: crypto,
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '2',
        operation: 'update',
        baseRevisionId:
            (olderEnvelope['header'] as Map<String, dynamic>)['revision_id']
                as String,
        name: 'newer page',
      );
      final api = _ConcurrentCheckpointApi(
        identity,
        sodium,
        firstEvents: [
          {
            'commit_seq': '2',
            'event_type': (olderEnvelope['header']! as Map)['operation'],
            'record_id': (olderEnvelope['header']! as Map)['record_id'],
            'revision_id': (olderEnvelope['header']! as Map)['revision_id'],
            'envelope': olderEnvelope,
          },
        ],
        secondEvents: [
          {
            'commit_seq': '3',
            'event_type': (newerEnvelope['header']! as Map)['operation'],
            'record_id': (newerEnvelope['header']! as Map)['record_id'],
            'revision_id': (newerEnvelope['header']! as Map)['revision_id'],
            'envelope': newerEnvelope,
          },
        ],
      );
      final firstRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final secondRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final lateSync = firstRepository.synchronize();
        await api.firstRequestStarted.future;
        final earlySync = secondRepository.synchronize();
        await api.secondRequestStarted.future;
        expect((await earlySync).status, 'idle');
        final newerHead = (await database.scopedCachedEnvelopes(
          _vaultId,
        )).single;
        expect(
          newerHead.revisionId,
          (newerEnvelope['header'] as Map<String, dynamic>)['revision_id'],
        );
        expect(newerHead.commitSeq, '3');

        api.releaseFirstResponse.complete();
        expect((await lateSync).status, 'retry_wait');

        final finalHead = (await database.scopedCachedEnvelopes(
          _vaultId,
        )).single;
        expect(
          finalHead.revisionId,
          (newerEnvelope['header'] as Map<String, dynamic>)['revision_id'],
        );
        expect(finalHead.envelopeJson, jsonEncode(newerEnvelope));
        expect(finalHead.commitSeq, '3');
        await expectLater(
          database.storeRemoteEnvelope(
            vaultId: _vaultId,
            recordId: _recordA,
            revisionId:
                (olderEnvelope['header'] as Map<String, dynamic>)['revision_id']
                    as String,
            envelope: Map<String, dynamic>.from(olderEnvelope),
            commitSeq: '3',
            deleted: false,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          (await database.scopedCachedEnvelopes(_vaultId)).single.revisionId,
          finalHead.revisionId,
        );
      } finally {
        if (!api.releaseFirstResponse.isCompleted) {
          api.releaseFirstResponse.complete();
        }
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'a stale page cannot create a conflict against a newer shared head',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ReplayApi(identity, sodium);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final localEnvelope = Map<String, dynamic>.from(
        await repository.saveRecord(
          recordId: _recordA,
          plaintext: const {'id': _recordA, 'type': 'host', 'name': 'local'},
        ),
      );
      final localHeader = localEnvelope['header'] as Map<String, dynamic>;
      final staleEnvelope = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '10',
        operation: 'create',
        baseRevisionId: null,
        name: 'stale remote page',
      );
      final latestEnvelope = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '11',
        operation: 'update',
        baseRevisionId:
            (staleEnvelope['header'] as Map<String, dynamic>)['revision_id']
                as String,
        name: 'latest remote head',
      );
      final latestHeader = latestEnvelope['header'] as Map<String, dynamic>;
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordA,
        revisionId: latestHeader['revision_id'] as String,
        envelope: latestEnvelope,
        commitSeq: '12',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

      try {
        final recorded = await database.recordPulledConflict(
          conflictedOperationIds: [localHeader['op_id'] as String],
          conflictId: _conflictId,
          vaultId: _vaultId,
          recordId: _recordA,
          kind: 'concurrent_edit',
          branchEnvelope: localEnvelope,
          remoteEnvelope: staleEnvelope,
          remoteRevisionId:
              (staleEnvelope['header'] as Map<String, dynamic>)['revision_id']
                  as String,
          remoteCommitSeq: '9',
          remoteDeleted: false,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );

        expect(recorded, isFalse);
        expect(await database.scopedOpenConflicts(_vaultId), isEmpty);
        expect(await database.scopedCountPending(_vaultId), 1);
        expect(
          (await database.scopedAllPendingOperations(_vaultId)).single.status,
          'queued',
        );
        final cached = (await database.scopedCachedEnvelopes(_vaultId)).single;
        expect(cached.revisionId, latestHeader['revision_id']);
        expect(cached.commitSeq, '12');
      } finally {
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'two repositories accept an already committed identical initial checkpoint',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConcurrentCheckpointApi(
        identity,
        sodium,
        firstCursor: null,
        secondCursor: null,
      );
      final firstRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final secondRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final lateSync = firstRepository.synchronize();
        await api.firstRequestStarted.future;
        final earlySync = secondRepository.synchronize();
        await api.secondRequestStarted.future;
        final earlyResult = await earlySync;

        expect(earlyResult.status, 'idle');
        expect((await database.scopedCheckpoint(_vaultId))?.cursor, isNull);
        expect(
          (await database.scopedCheckpoint(_vaultId))?.serverGeneration,
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        );

        api.releaseFirstResponse.complete();
        final lateResult = await lateSync;

        expect(lateResult.status, 'idle');
        expect(api.changesRequestCursors, [null, null]);
        expect((await database.scopedCheckpoint(_vaultId))?.cursor, isNull);
        expect(
          (await database.scopedCheckpoint(_vaultId))?.serverGeneration,
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        );
      } finally {
        if (!api.releaseFirstResponse.isCompleted) {
          api.releaseFirstResponse.complete();
        }
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'a late page cannot overwrite a checkpoint from a restored server generation',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConcurrentCheckpointApi(identity, sodium);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const restoredGeneration = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

      try {
        final sync = repository.synchronize();
        await api.firstRequestStarted.future;
        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          cursor: 'restored-snapshot-cursor',
          serverGeneration: restoredGeneration,
        );

        api.releaseFirstResponse.complete();
        final result = await sync;

        expect(result.status, 'resnapshot_required');
        expect(api.changesRequestCursors, [null]);
        final checkpoint = await database.scopedCheckpoint(_vaultId);
        expect(checkpoint?.cursor, 'restored-snapshot-cursor');
        expect(checkpoint?.serverGeneration, restoredGeneration);
      } finally {
        if (!api.releaseFirstResponse.isCompleted) {
          api.releaseFirstResponse.complete();
        }
        await database.close();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'replays a persisted conflict event after its page cursor checkpoint fails and the database reopens',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-pull-checkpoint-replay-',
      );
      final file = File('${directory.path}/client.sqlite');
      final identity = DeviceIdentity.create(sodium);
      final remoteDevice = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final api = _ReplayApi(identity, sodium)..trust(remoteDevice);
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const oldCursor = 'before-event-page';
      const pageCursor = 'event-cursor';

      final local = await repository.saveRecord(
        recordId: _recordA,
        plaintext: const {
          'id': _recordA,
          'type': 'host',
          'name': 'Offline local branch',
        },
      );
      final localHeader = local['header'] as Map<String, dynamic>;
      final remote = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: remoteDevice,
        key: key,
        recordId: _recordA,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'Remote branch',
      );
      final remoteHeader = remote['header'] as Map<String, dynamic>;
      final localOutbox = (await database.scopedAllPendingOperations(
        _vaultId,
      )).single;
      expect(localOutbox.opId, localHeader['op_id']);
      expect(localOutbox.envelopeJson, jsonEncode(local));

      await database.saveCheckpoint(
        vaultId: _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
        cursor: oldCursor,
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      expect(api.changesRequestCursors, isEmpty);
      await database.customStatement('''
        CREATE TRIGGER reject_pull_page_checkpoint
        BEFORE UPDATE OF cursor ON sync_checkpoints
        WHEN NEW.cursor = '$pageCursor'
        BEGIN
          SELECT RAISE(ABORT, 'injected pull checkpoint failure');
        END
      ''');
      api.queueEvent({
        'commit_seq': '7',
        'event_type': (remote['header']! as Map)['operation'],
        'record_id': (remote['header']! as Map)['record_id'],
        'revision_id': (remote['header']! as Map)['revision_id'],
        'envelope': remote,
      });

      await expectLater(repository.synchronize(), throwsA(anything));

      expect(api.changesRequestCursors, [oldCursor]);
      expect((await database.scopedCheckpoint(_vaultId))?.cursor, oldCursor);
      final failedPullRows = await database.scopedCachedEnvelopes(_vaultId);
      expect(failedPullRows, hasLength(1));
      expect(failedPullRows.single.revisionId, remoteHeader['revision_id']);
      expect(failedPullRows.single.envelopeJson, jsonEncode(remote));
      expect(failedPullRows.single.commitSeq, '7');
      final failedPullOutbox = (await database.scopedAllPendingOperations(
        _vaultId,
      )).single;
      expect(failedPullOutbox.opId, localOutbox.opId);
      expect(failedPullOutbox.envelopeJson, localOutbox.envelopeJson);
      expect(failedPullOutbox.status, 'conflict');
      final failedPullConflicts = await database.scopedOpenConflicts(_vaultId);
      expect(failedPullConflicts, hasLength(1));
      final persistedConflict = failedPullConflicts.single;
      expect(persistedConflict.state, 'upload_pending');
      expect(persistedConflict.branchEnvelopeJson, jsonEncode(local));
      expect(persistedConflict.remoteEnvelopeJson, jsonEncode(remote));
      expect(api.conflictUploadRequests, isEmpty);
      await database.close();

      final reopenedDatabase = ClientDatabase.forTesting(NativeDatabase(file));
      await reopenedDatabase.customStatement(
        'DROP TRIGGER reject_pull_page_checkpoint',
      );
      expect(
        (await reopenedDatabase.scopedCheckpoint(_vaultId))?.cursor,
        oldCursor,
      );
      expect(api.changesRequestCursors, [oldCursor]);
      api.queueEvent({
        'commit_seq': '7',
        'event_type': (remote['header']! as Map)['operation'],
        'record_id': (remote['header']! as Map)['record_id'],
        'revision_id': (remote['header']! as Map)['revision_id'],
        'envelope': remote,
      });
      final reopenedRepository = _repository(
        api: api,
        database: reopenedDatabase,
        identity: identity,
        key: key,
      );

      final recovered = await reopenedRepository.synchronize();

      expect(recovered.status, 'idle');
      expect(api.changesRequestCursors, [oldCursor, oldCursor]);
      expect(
        (await reopenedDatabase.scopedCheckpoint(_vaultId))?.cursor,
        pageCursor,
      );
      final recoveredRows = await reopenedDatabase.scopedCachedEnvelopes(
        _vaultId,
      );
      expect(recoveredRows, hasLength(1));
      expect(recoveredRows.single.revisionId, remoteHeader['revision_id']);
      expect(recoveredRows.single.envelopeJson, jsonEncode(remote));
      expect(recoveredRows.single.commitSeq, '7');
      final recoveredOutbox =
          (await reopenedDatabase.scopedAllPendingOperations(_vaultId)).single;
      expect(recoveredOutbox.opId, localOutbox.opId);
      expect(recoveredOutbox.envelopeJson, localOutbox.envelopeJson);
      expect(recoveredOutbox.status, 'conflict');
      final recoveredConflicts = await reopenedDatabase.scopedOpenConflicts(
        _vaultId,
      );
      expect(recoveredConflicts, hasLength(1));
      expect(recoveredConflicts.single.conflictId, _ReplayApi.serverConflictId);
      expect(recoveredConflicts.single.state, 'open');
      expect(recoveredConflicts.single.branchEnvelopeJson, jsonEncode(local));
      expect(recoveredConflicts.single.remoteEnvelopeJson, jsonEncode(remote));
      expect(api.conflictUploadRequests, hasLength(1));
      expect(
        jsonEncode(api.conflictUploadRequests.single['envelope']),
        jsonEncode(local),
      );

      await reopenedDatabase.close();
      api.close();
      identity.dispose();
      remoteDevice.dispose();
      key.fillRange(0, key.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'retries a durably associated conflict resolution after restart and lost response',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-conflict-replay-',
      );
      final file = File('${directory.path}/client.sqlite');
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      final remote = await _encrypt(
        crypto: crypto,
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'Remote head',
      );
      final remoteHeader = remote['header'] as Map<String, dynamic>;
      final local = await _encrypt(
        crypto: crypto,
        identity: identity,
        key: key,
        recordId: _recordA,
        seq: '2',
        operation: 'update',
        baseRevisionId: remoteHeader['revision_id'] as String,
        name: 'Local conflict branch',
      );
      final localHeader = local['header'] as Map<String, dynamic>;
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      await _seedConflict(
        database: database,
        localEnvelope: local,
        remoteEnvelope: remote,
        identity: identity,
      );
      final api = _ReplayApi(identity, sodium)
        ..loseNextResolutionResponseAfterCommit = true;
      api.setServerHead(_recordA, remoteHeader['revision_id'] as String);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      await repository.resolveConflictBranch(
        conflictId: _conflictId,
        keepLocal: true,
      );
      var branch = (await database.scopedOpenConflicts(_vaultId)).single;
      expect(branch.state, 'resolution_pending');
      final resolutionOpId = branch.resolutionOpId;
      final resolutionRevisionId = branch.resolutionRevisionId;
      expect(resolutionOpId, isNot(localHeader['op_id']));
      expect(await database.scopedCountPending(_vaultId), 1);

      await expectLater(
        repository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      branch = (await database.scopedOpenConflicts(_vaultId)).single;
      expect(branch.state, 'resolution_ready');
      expect(branch.resolutionOpId, resolutionOpId);
      expect(branch.resolutionRevisionId, resolutionRevisionId);
      expect(branch.branchEnvelopeJson, jsonEncode(local));
      expect(await database.scopedCountPending(_vaultId), 0);
      await database.close();

      final reopenedDatabase = ClientDatabase.forTesting(NativeDatabase(file));
      final reopenedRepository = _repository(
        api: api,
        database: reopenedDatabase,
        identity: identity,
        key: key,
      );
      api.setResolvedRevision(
        _conflictId,
        '99999999-9999-4999-8999-999999999999',
      );
      await expectLater(
        reopenedRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'CONFLICT_ALREADY_RESOLVED',
          ),
        ),
      );
      branch = (await reopenedDatabase.scopedOpenConflicts(_vaultId)).single;
      expect(branch.state, 'resolution_ready');
      expect(branch.resolutionOpId, resolutionOpId);
      expect(branch.resolutionRevisionId, resolutionRevisionId);

      api.setResolvedRevision(_conflictId, resolutionRevisionId!);
      final retried = await reopenedRepository.synchronize();
      expect(retried.status, 'idle');
      expect(api.resolveRequests, hasLength(3));
      expect(api.resolveRequests.first, api.resolveRequests.last);
      expect(api.serverResolutionSeq, 1);
      expect(await reopenedDatabase.scopedCountPending(_vaultId), 0);
      final resolved = (await reopenedDatabase.scopedOpenConflicts(_vaultId));
      expect(resolved, isEmpty);
      final retainedBranch = await (reopenedDatabase.select(
        reopenedDatabase.conflictBranches,
      )..where((row) => row.conflictId.equals(_conflictId))).getSingle();
      expect(retainedBranch.state, 'resolved');
      expect(retainedBranch.branchEnvelopeJson, jsonEncode(local));
      expect(retainedBranch.resolutionOpId, resolutionOpId);
      expect(retainedBranch.resolutionRevisionId, resolutionRevisionId);

      await reopenedDatabase.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'schema v1 upgrade adds resolution fields without losing conflict data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-db-migration-',
      );
      final file = File('${directory.path}/client.sqlite');
      final database = ClientDatabase.forTesting(NativeDatabase(file));
      await database.saveConflict(
        conflictId: _conflictId,
        vaultId: _vaultId,
        recordId: _recordA,
        kind: 'concurrent_edit',
        branchEnvelope: const {'opaque': 'local'},
        remoteEnvelope: const {'opaque': 'remote'},
      );
      await database.customStatement(
        'ALTER TABLE conflict_branches DROP COLUMN resolution_op_id',
      );
      await database.customStatement(
        'ALTER TABLE conflict_branches DROP COLUMN resolution_revision_id',
      );
      await database.customStatement('PRAGMA user_version = 1');
      await database.close();

      final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
      final columns = await upgraded
          .customSelect('PRAGMA table_info("conflict_branches")')
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      expect(names, contains('resolution_op_id'));
      expect(names, contains('resolution_revision_id'));
      final preserved = await (upgraded.select(
        upgraded.conflictBranches,
      )..where((row) => row.conflictId.equals(_conflictId))).getSingle();
      expect(preserved.vaultId, _vaultId);
      expect(preserved.branchEnvelopeJson, '{"opaque":"local"}');
      expect(preserved.remoteEnvelopeJson, '{"opaque":"remote"}');
      expect(preserved.resolutionOpId, isNull);

      await upgraded.close();
      await directory.delete(recursive: true);
    },
  );

  test(
    'schema v8 upgrade adds delayed-receipt storage and preserves cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-push-receipt-migration-',
      );
      final file = File('${directory.path}/client.sqlite');
      final beforeUpgrade = ClientDatabase.forTesting(NativeDatabase(file));
      await beforeUpgrade.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordA,
        revisionId: '77777777-7777-4777-8777-777777777777',
        envelope: const {
          'header': {
            'vault_id': _vaultId,
            'record_id': _recordA,
            'revision_id': '77777777-7777-4777-8777-777777777777',
          },
          'ciphertext': 'opaque-ciphertext',
        },
        commitSeq: '41',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );
      await beforeUpgrade.customStatement(
        'DROP TABLE authenticated_push_receipts',
      );
      await beforeUpgrade.customStatement('PRAGMA user_version = 8');
      await beforeUpgrade.close();

      final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
      final columns = await upgraded
          .customSelect('PRAGMA table_info("authenticated_push_receipts")')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')).toSet(),
        containsAll({
          'op_id',
          'vault_id',
          'record_id',
          'revision_id',
          'envelope_json',
          'commit_seq',
        }),
      );
      final preserved = await upgraded.cachedEnvelope(_vaultId, _recordA);
      expect(preserved?.revisionId, '77777777-7777-4777-8777-777777777777');
      expect(preserved?.commitSeq, '41');
      await upgraded.customStatement('PRAGMA user_version = 8');
      await upgraded.close();

      final retried = ClientDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await retried.close();
        await directory.delete(recursive: true);
      });
      expect(
        await retried
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        14,
      );
      expect(
        (await retried.cachedEnvelope(_vaultId, _recordA))?.commitSeq,
        '41',
      );
    },
  );
}

SyncRepository _repository({
  required _ReplayApi api,
  required ClientDatabase database,
  required DeviceIdentity identity,
  required Uint8List key,
  Future<void> Function()? beforeStorePulledEventForTesting,
  Future<void> Function()? beforeReplaceMergedOperationForTesting,
  Future<void> Function()? beforePushMarkAttemptedForTesting,
}) => SyncRepository(
  api: api,
  database: database,
  crypto: VaultCrypto(api.sodium),
  identity: identity,
  serverSpaceId: _spaceId,
  instanceId: _instanceId,
  vaultId: _vaultId,
  keyEpoch: '1',
  membershipVersion: '1',
  serverGeneration: _instanceId,
  vaultKey: Uint8List.fromList(key),
  beforeStorePulledEventForTesting: beforeStorePulledEventForTesting,
  beforeReplaceMergedOperationForTesting:
      beforeReplaceMergedOperationForTesting,
  beforePushMarkAttemptedForTesting: beforePushMarkAttemptedForTesting,
);

Map<String, dynamic> _onlyEnvelope(Map<String, Object?> request) =>
    Map<String, dynamic>.from(
      (request['operations'] as List<dynamic>).single as Map,
    );

Future<Map<String, Object?>> _encrypt({
  required VaultCrypto crypto,
  required DeviceIdentity identity,
  required Uint8List key,
  required String recordId,
  required String seq,
  required String operation,
  required String? baseRevisionId,
  required String name,
}) => crypto.encryptRecord(
  vaultKey: key,
  serverSpaceId: _spaceId,
  vaultId: _vaultId,
  recordId: recordId,
  baseRevisionId: baseRevisionId,
  deviceId: identity.deviceId,
  deviceSequence: seq,
  keyEpoch: '1',
  membershipVersion: '1',
  operation: operation,
  plaintext: {'id': recordId, 'type': 'host', 'name': name},
  identity: identity,
);

Map<String, Object?> _hostPlaintext({
  String recordId = _recordA,
  required String name,
  required List<String> tags,
  String address = 'host.example',
  int color = 0,
}) => {
  'id': recordId,
  'type': 'host',
  'name': name,
  'address': address,
  'port': 22,
  'username': 'ops',
  'group_id': null,
  'credential_id': null,
  'jump_host_id': null,
  'auth_kind': 'password',
  'color': color,
  'tags': tags,
  'is_favorite': false,
};

Future<Map<String, dynamic>> _encryptHost({
  required VaultCrypto crypto,
  required DeviceIdentity identity,
  required Uint8List key,
  String recordId = _recordA,
  required Map<String, Object?> plaintext,
  required String seq,
  required String operation,
  required String? baseRevisionId,
}) async => Map<String, dynamic>.from(
  await crypto.encryptRecord(
    vaultKey: key,
    serverSpaceId: _spaceId,
    vaultId: _vaultId,
    recordId: recordId,
    baseRevisionId: baseRevisionId,
    deviceId: identity.deviceId,
    deviceSequence: seq,
    keyEpoch: '1',
    membershipVersion: '1',
    operation: operation,
    plaintext: plaintext,
    identity: identity,
  ),
);

Future<void> _seedConflict({
  required ClientDatabase database,
  required Map<String, Object?> localEnvelope,
  required Map<String, Object?> remoteEnvelope,
  required DeviceIdentity identity,
}) async {
  final localHeader = localEnvelope['header'] as Map<String, dynamic>;
  final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
  await database.storeRemoteEnvelope(
    vaultId: _vaultId,
    recordId: _recordA,
    revisionId: remoteHeader['revision_id'] as String,
    envelope: Map<String, dynamic>.from(remoteEnvelope),
    commitSeq: '1',
    deleted: false,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
  );
  await database
      .into(database.conflictBranches)
      .insert(
        ConflictBranchesCompanion.insert(
          conflictId: _conflictId,
          vaultId: _vaultId,
          recordId: _recordA,
          instanceId: const Value(_instanceId),
          serverSpaceId: const Value(_spaceId),
          kind: 'concurrent_edit',
          branchEnvelopeJson: jsonEncode(localEnvelope),
          remoteEnvelopeJson: jsonEncode(remoteEnvelope),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
  await database
      .into(database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: localHeader['op_id'] as String,
          vaultId: _vaultId,
          recordId: _recordA,
          instanceId: const Value(_instanceId),
          serverSpaceId: const Value(_spaceId),
          baseRevisionId: Value(remoteHeader['revision_id'] as String),
          envelopeJson: jsonEncode(localEnvelope),
          status: const Value('conflict'),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
  await database
      .into(database.deviceSequences)
      .insert(
        DeviceSequencesCompanion.insert(
          deviceId: identity.deviceId,
          nextSequence: const Value(3),
        ),
      );
}

extension _ScopedOutboxRecoveryQueries on ClientDatabase {
  Future<int> scopedCountPending(String vaultId) =>
      countPending(vaultId, instanceId: _instanceId, serverSpaceId: _spaceId);

  Future<SyncCheckpoint?> scopedCheckpoint(String vaultId) =>
      checkpoint(vaultId, instanceId: _instanceId, serverSpaceId: _spaceId);

  Future<List<EncryptedRecord>> scopedCachedEnvelopes(String vaultId) =>
      cachedEnvelopes(
        vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

  Future<List<PendingOperation>> scopedAllPendingOperations(String vaultId) =>
      allPendingOperations(
        vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

  Future<List<PendingOperation>> scopedSupersededOperations(String vaultId) =>
      supersededOperations(
        vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

  Future<List<ConflictBranche>> scopedOpenConflicts(String vaultId) =>
      openConflicts(vaultId, instanceId: _instanceId, serverSpaceId: _spaceId);
}

enum _ReceiptFault { none, mismatchedRevision }

class _ConcurrentCheckpointApi extends _ReplayApi {
  _ConcurrentCheckpointApi(
    super.identity,
    super.sodium, {
    this.firstCursor = 'older-cursor',
    this.secondCursor = 'newer-cursor',
    this.firstEvents = const [],
    this.secondEvents = const [],
  });

  final String? firstCursor;
  final String? secondCursor;
  final List<Map<String, dynamic>> firstEvents;
  final List<Map<String, dynamic>> secondEvents;

  final Completer<void> firstRequestStarted = Completer<void>();
  final Completer<void> secondRequestStarted = Completer<void>();
  final Completer<void> releaseFirstResponse = Completer<void>();
  int _requestCount = 0;

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    changesRequestCursors.add(cursor);
    final requestNumber = ++_requestCount;
    if (requestNumber == 1) {
      firstRequestStarted.complete();
      await releaseFirstResponse.future;
    } else if (requestNumber == 2) {
      secondRequestStarted.complete();
    } else {
      throw StateError('Unexpected extra changes request in checkpoint race.');
    }
    return SyncPage(
      events: requestNumber == 1 ? firstEvents : secondEvents,
      nextCursor: requestNumber == 1 ? firstCursor : secondCursor,
      hasMore: false,
      serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );
  }
}

class _DelayedPushResponseApi extends _ReplayApi {
  _DelayedPushResponseApi(super.identity, super.sodium);

  final Completer<Map<String, dynamic>> firstCommittedResponse = Completer();
  final Completer<void> releaseFirstResponse = Completer<void>();

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    final response = await super.push(vaultId, batch);
    if (!firstCommittedResponse.isCompleted) {
      firstCommittedResponse.complete(response);
      await releaseFirstResponse.future;
    }
    return response;
  }
}

class _ReplayApi extends ApiClient {
  _ReplayApi(this.identity, this.sodium)
    : super(baseUrl: 'https://outbox-test.example');

  final DeviceIdentity identity;
  final SodiumSumo sodium;

  bool loseNextPushResponseAfterCommit = false;
  bool loseNextResolutionResponseAfterCommit = false;
  bool failNextConflictUpload = false;
  _ReceiptFault receiptFault = _ReceiptFault.none;
  final List<Map<String, Object?>> pushRequests = [];
  final List<Map<String, Object?>> conflictUploadRequests = [];
  final List<String?> changesRequestCursors = [];
  final List<Map<String, dynamic>> _trustedDevices = [];
  final List<Map<String, dynamic>> _queuedEvents = [];
  final Map<String, Map<String, dynamic>> _committedOperations = {};
  final Map<String, String> _serverHeads = {};
  final Map<String, String> _resolvedConflicts = {};
  final List<Map<String, Object?>> resolveRequests = [];
  int serverCommitCount = 0;
  int serverResolutionSeq = 0;

  static const serverConflictId = '66666666-6666-4666-8666-666666666666';

  void trust(DeviceIdentity device) {
    _trustedDevices.add({
      'device_id': device.deviceId,
      'signing_public_key': device.signingPublicKey,
    });
  }

  void queueEvent(Map<String, dynamic> event) {
    _queuedEvents.add(event);
  }

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
    },
    ..._trustedDevices,
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      devices();

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
  }) async {
    changesRequestCursors.add(cursor);
    final events = List<Map<String, dynamic>>.from(_queuedEvents);
    _queuedEvents.clear();
    return SyncPage(
      events: events,
      nextCursor: events.isEmpty ? cursor : 'event-cursor',
      hasMore: false,
      serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );
  }

  @override
  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    conflictUploadRequests.add({'vault_id': vaultId, ...body});
    if (failNextConflictUpload) {
      failNextConflictUpload = false;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'The server did not store the conflict branch.',
      );
    }
    return {'conflict_id': serverConflictId, 'status': 'stored'};
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushRequests.add(Map<String, Object?>.from(batch));
    final operations = (batch['operations'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final records = operations
        .map((envelope) => (envelope['header'] as Map)['record_id'])
        .toList();
    if (records.toSet().length != records.length) {
      throw StateError('A push batch must not contain a record twice.');
    }
    final results = <Map<String, Object?>>[];
    for (final envelope in operations) {
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final opId = header['op_id'] as String;
      final recordId = header['record_id'] as String;
      final existing = _committedOperations[opId];
      if (existing != null) {
        if (jsonEncode(existing['envelope']) != jsonEncode(envelope)) {
          throw const ApiException(
            statusCode: 409,
            code: 'IDEMPOTENCY_KEY_REUSED',
            message: 'Operation bytes changed on retry.',
          );
        }
        results.add({
          'op_id': opId,
          'revision_id': existing['revision_id'],
          'commit_seq': existing['commit_seq'],
          'already_committed': true,
        });
        continue;
      }
      final head = _serverHeads[recordId];
      if (header['base_revision_id'] != head) {
        throw const ApiException(
          statusCode: 409,
          code: 'REVISION_CONFLICT',
          message: 'The test server head changed.',
        );
      }
      final revisionId = header['revision_id'] as String;
      final commitSeq = (++serverCommitCount).toString();
      _serverHeads[recordId] = revisionId;
      _committedOperations[opId] = {
        'envelope': envelope,
        'revision_id': revisionId,
        'commit_seq': commitSeq,
      };
      results.add({
        'op_id': opId,
        'revision_id': revisionId,
        'commit_seq': commitSeq,
        'already_committed': false,
      });
    }
    if (loseNextPushResponseAfterCommit) {
      loseNextPushResponseAfterCommit = false;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'The server committed but the response was lost.',
      );
    }
    switch (receiptFault) {
      case _ReceiptFault.none:
        break;
      case _ReceiptFault.mismatchedRevision:
        if (results.isNotEmpty) {
          results[0] = {
            ...results[0],
            'revision_id': '99999999-9999-4999-8999-999999999999',
          };
        }
        receiptFault = _ReceiptFault.none;
    }
    return {'batch_id': batch['batch_id'], 'results': results};
  }

  @override
  Future<Map<String, dynamic>> resolveConflict(
    String vaultId,
    String conflictId,
    Map<String, Object?> body,
  ) async {
    resolveRequests.add({
      'vault_id': vaultId,
      'conflict_id': conflictId,
      ...body,
    });
    final opId = body['op_id'] as String;
    final revisionId = body['resolved_revision_id'] as String;
    final existing = _resolvedConflicts[conflictId];
    if (existing != null && existing != revisionId) {
      throw const ApiException(
        statusCode: 409,
        code: 'CONFLICT_ALREADY_RESOLVED',
        message: 'A different main revision resolved this conflict.',
      );
    }
    if (existing == null) {
      _resolvedConflicts[conflictId] = revisionId;
      serverResolutionSeq++;
    }
    if (loseNextResolutionResponseAfterCommit) {
      loseNextResolutionResponseAfterCommit = false;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Conflict resolution was committed but the response was lost.',
      );
    }
    return {
      'status': 'resolved',
      'conflict_id': conflictId,
      'op_id': opId,
      'resolved_revision_id': revisionId,
    };
  }

  void setResolvedRevision(String conflictId, String revisionId) {
    _resolvedConflicts[conflictId] = revisionId;
  }

  void setServerHead(String recordId, String revisionId) {
    _serverHeads[recordId] = revisionId;
  }
}

class _AtomicRevisionConflictApi extends _ReplayApi {
  _AtomicRevisionConflictApi(super.identity, super.sodium);

  final List<Map<String, Object?>> rejectedLedgerSnapshots = [];

  Map<String, Object?> _ledgerSnapshot() => {
    'serverCommitCount': serverCommitCount,
    'heads': Map<String, String>.from(_serverHeads),
    'operationIds': _committedOperations.keys.toSet(),
  };

  void seedCommittedEnvelope(
    Map<String, dynamic> envelope, {
    required String commitSeq,
  }) {
    final header = envelope['header'] as Map<String, dynamic>;
    final opId = header['op_id'] as String;
    final recordId = header['record_id'] as String;
    final revisionId = header['revision_id'] as String;
    serverCommitCount = int.parse(commitSeq);
    _serverHeads[recordId] = revisionId;
    _committedOperations[opId] = {
      'envelope': envelope,
      'revision_id': revisionId,
      'commit_seq': commitSeq,
    };
  }

  void commitCompetingUpdate({
    required String recordId,
    required Map<String, dynamic> envelope,
    required String commitSeq,
  }) {
    seedCommittedEnvelope(envelope, commitSeq: commitSeq);
    final header = envelope['header'] as Map<String, dynamic>;
    queueEvent({
      'commit_seq': commitSeq,
      'event_type': header['operation'],
      'record_id': recordId,
      'revision_id': header['revision_id'],
      'envelope': envelope,
    });
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushRequests.add(Map<String, Object?>.from(batch));
    final operations = (batch['operations'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final records = operations
        .map((envelope) => (envelope['header'] as Map)['record_id'])
        .toList();
    if (records.toSet().length != records.length) {
      throw StateError('A push batch must not contain a record twice.');
    }

    // Validate the complete batch before changing any fake server state. This
    // models the production transaction's all-or-nothing CAS behavior.
    for (final envelope in operations) {
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final opId = header['op_id'] as String;
      final recordId = header['record_id'] as String;
      final existing = _committedOperations[opId];
      if (existing != null &&
          jsonEncode(existing['envelope']) != jsonEncode(envelope)) {
        throw const ApiException(
          statusCode: 409,
          code: 'IDEMPOTENCY_KEY_REUSED',
          message: 'Operation bytes changed on retry.',
        );
      }
      if (existing == null &&
          header['base_revision_id'] != _serverHeads[recordId]) {
        rejectedLedgerSnapshots.add(_ledgerSnapshot());
        throw const ApiException(
          statusCode: 409,
          code: 'REVISION_CONFLICT',
          message: 'The atomic test batch has a stale base revision.',
        );
      }
    }

    final results = <Map<String, Object?>>[];
    for (final envelope in operations) {
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final opId = header['op_id'] as String;
      final recordId = header['record_id'] as String;
      final existing = _committedOperations[opId];
      if (existing != null) {
        results.add({
          'op_id': opId,
          'revision_id': existing['revision_id'],
          'commit_seq': existing['commit_seq'],
          'already_committed': true,
        });
        continue;
      }
      final revisionId = header['revision_id'] as String;
      final commitSeq = (++serverCommitCount).toString();
      _serverHeads[recordId] = revisionId;
      _committedOperations[opId] = {
        'envelope': envelope,
        'revision_id': revisionId,
        'commit_seq': commitSeq,
      };
      results.add({
        'op_id': opId,
        'revision_id': revisionId,
        'commit_seq': commitSeq,
        'already_committed': false,
      });
    }
    return {'batch_id': batch['batch_id'], 'results': results};
  }
}
