import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/credential_conflict_merge.dart';
import 'package:aterm_client/domain/host_security_conflict_merge.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _baseRevisionId = '44444444-4444-4444-8444-444444444444';
const _conflictId = '55555555-5555-4555-8555-555555555555';
const _mainGeneration = '99999999-9999-4999-8999-999999999999';
const _oldGeneration = '77777777-7777-4777-8777-777777777777';
const _jumpHostA = '88888888-8888-4888-8888-888888888888';
const _otherRecordId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sync drains paged inbox with an independent generation cursor',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final signedBranch = await _branchEnvelope(identity, key, sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConflictFeedApi(identity, [
        _page(
          after: '0',
          high: '2',
          next: '1',
          events: [_created('1', envelope: signedBranch)],
          more: true,
        ),
        _page(after: '1', high: '2', next: '2', events: [_resolved('2')]),
      ]);
      final repository = _repository(api, database, identity, key, sodium);
      repository.canWrite = false;

      final result = await repository.synchronize();

      expect(result.status, 'read_only');
      expect(api.conflictAfterSeqs, [null, '1']);
      expect(api.conflictGenerations, [null, _mainGeneration]);
      expect(
        await database.testConflictFeedCursor(
          _vaultId,
          _mainGeneration,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        ),
        '2',
      );
      expect(
        (await database.testListConflictFeedInbox(
          _vaultId,
          _mainGeneration,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        )).map((event) => event.type),
        ['created', 'resolved'],
      );
      final reviewItems = await repository.loadConflictFeedReviewItems();
      expect(reviewItems, hasLength(1));
      expect(reviewItems.single.isVerified, isTrue);
      expect(reviewItems.single.isResolved, isTrue);
      expect(reviewItems.single.branchDeviceId, identity.deviceId);
      expect(
        await database.testCachedEnvelopes(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        ),
        isEmpty,
      );
      expect(
        await database.testOpenConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        ),
        isEmpty,
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test('verifies a live update branch with no deleted field', () async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    final key = Uint8List.fromList(sodium.randombytes.buf(32));
    final signedBranch = await _branchEnvelope(
      identity,
      key,
      sodium,
      operation: 'update',
      baseRevisionId: _baseRevisionId,
      plaintext: {'id': _recordId, 'type': 'host', 'name': 'safe'},
    );
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _ConflictFeedApi(identity, [
      _page(
        after: '0',
        high: '1',
        next: '1',
        events: [
          _created(
            '1',
            envelope: signedBranch,
            baseRevisionId: _baseRevisionId,
          ),
        ],
      ),
    ]);
    final repository = _repository(api, database, identity, key, sodium)
      ..canWrite = false;

    final result = await repository.synchronize();

    expect(result.status, 'read_only');
    expect(
      await database.testConflictFeedCursor(_vaultId, _mainGeneration),
      '1',
    );
    final reviewItems = await repository.loadConflictFeedReviewItems();
    expect(reviewItems, hasLength(1));
    expect(reviewItems.single.isVerified, isTrue);
    expect(reviewItems.single.branchOperation, 'update');
    expect(reviewItems.single.branchDeviceId, identity.deviceId);

    await database.close();
    api.close();
    identity.dispose();
    key.fillRange(0, key.length, 0);
  });

  test('verifies a delete branch only when deleted is true', () async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    final key = Uint8List.fromList(sodium.randombytes.buf(32));
    final signedBranch = await _branchEnvelope(
      identity,
      key,
      sodium,
      operation: 'delete',
      plaintext: {'id': _recordId, 'deleted': true},
    );
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _ConflictFeedApi(identity, [
      _page(
        after: '0',
        high: '1',
        next: '1',
        events: [_created('1', envelope: signedBranch)],
      ),
    ]);
    final repository = _repository(api, database, identity, key, sodium)
      ..canWrite = false;

    final result = await repository.synchronize();

    expect(result.status, 'read_only');
    expect(
      (await repository.loadConflictFeedReviewItems()).single.isVerified,
      isTrue,
    );

    await database.close();
    api.close();
    identity.dispose();
    key.fillRange(0, key.length, 0);
  });

  test(
    'does not persist a conflict branch with a non-boolean deleted field',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final signedBranch = await _branchEnvelope(
        identity,
        key,
        sodium,
        operation: 'update',
        plaintext: {'id': _recordId, 'deleted': 'false', 'name': 'safe'},
      );
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConflictFeedApi(identity, [
        _page(
          after: '0',
          high: '1',
          next: '1',
          events: [_created('1', envelope: signedBranch)],
        ),
      ]);
      final repository = _repository(api, database, identity, key, sodium);

      await expectLater(
        repository.synchronize(),
        throwsA(isA<FormatException>()),
      );

      expect(
        await database.testConflictFeedCursor(_vaultId, _mainGeneration),
        '0',
      );
      expect(await database.testActiveConflictFeedInbox(_vaultId), isEmpty);

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    '410 generation rollover restarts from zero and keeps the old inbox partition',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final signedBranch = await _branchEnvelope(identity, key, sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final oldPage = _page(
        after: '0',
        high: '1',
        next: '1',
        events: [_created('1')],
        generation: _oldGeneration,
      );
      await database.saveTestConflictChangesPage(oldPage);
      const nextGeneration = 'abababab-abab-4bab-8bab-abababababab';
      final api = _ConflictFeedApi(
        identity,
        [
          _page(
            after: '0',
            high: '1',
            next: '1',
            events: [_created('1', envelope: signedBranch)],
            generation: nextGeneration,
          ),
        ],
        continuationErrors: const [
          ApiException(
            statusCode: 410,
            code: 'CONFLICT_FEED_GENERATION_CHANGED',
            message: 'Conflict feed generation changed.',
            details: {
              'server_generation': _oldGeneration,
              'current_generation': nextGeneration,
              'recovery': 'restart_from_zero',
            },
          ),
        ],
      );
      final repository = _repository(api, database, identity, key, sodium);
      repository.canWrite = false;

      final result = await repository.synchronize();

      expect(result.status, 'read_only');
      expect(api.conflictAfterSeqs, ['1', null]);
      expect(api.conflictGenerations, [_oldGeneration, null]);
      expect(
        await database.testActiveConflictFeedGeneration(_vaultId),
        nextGeneration,
      );
      expect(
        await database.testConflictFeedCursor(_vaultId, _oldGeneration),
        '1',
      );
      expect(
        await database.testConflictFeedCursor(_vaultId, nextGeneration),
        '1',
      );
      expect(
        await database.testListConflictFeedInbox(_vaultId, _oldGeneration),
        hasLength(1),
      );
      expect(
        await database.testListConflictFeedInbox(_vaultId, nextGeneration),
        hasLength(1),
      );
      expect(
        (await database.testActiveConflictFeedInbox(_vaultId)).single.type,
        'created',
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    '410 sequence-ahead restarts same generation in a new preserved partition',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await database.saveTestConflictChangesPage(
        _page(after: '0', high: '12', next: '12', events: [_created('12')]),
      );
      final oldPartitionId = await database.testActiveConflictFeedPartitionId(
        _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );
      final api = _ConflictFeedApi(
        identity,
        [
          _page(after: '0', high: '1', next: '1', events: [_resolved('1')]),
        ],
        continuationErrors: [
          const ApiException(
            statusCode: 410,
            code: 'CONFLICT_FEED_SEQUENCE_AHEAD',
            message: 'Conflict feed cursor is ahead.',
            details: {'recovery': 'restart_from_zero'},
          ),
        ],
      );
      final repository = _repository(api, database, identity, key, sodium)
        ..canWrite = false;

      final result = await repository.synchronize();

      final newPartitionId = await database.testActiveConflictFeedPartitionId(
        _vaultId,
      );
      expect(result.status, 'read_only');
      expect(api.conflictAfterSeqs, ['12', null]);
      expect(api.conflictGenerations, [_mainGeneration, null]);
      expect(
        await database.testActiveConflictFeedGeneration(_vaultId),
        _mainGeneration,
      );
      expect(newPartitionId, isNot(oldPartitionId));
      expect(
        await database.testConflictFeedCursor(
          _vaultId,
          _mainGeneration,
          partitionId: oldPartitionId,
        ),
        '12',
      );
      expect(
        await database.testConflictFeedCursor(
          _vaultId,
          _mainGeneration,
          partitionId: newPartitionId,
        ),
        '1',
      );
      expect(
        await database.testListConflictFeedInbox(
          _vaultId,
          _mainGeneration,
          partitionId: oldPartitionId,
        ),
        hasLength(1),
      );
      expect(
        (await database.testActiveConflictFeedInbox(_vaultId)).single.type,
        'resolved',
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    '410 restart accepts only a canonical current-generation UUID',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await database.saveTestConflictChangesPage(
        _page(
          after: '0',
          high: '1',
          next: '1',
          events: [_created('1')],
          generation: _oldGeneration,
        ),
      );
      final api = _ConflictFeedApi(
        identity,
        [
          _page(
            after: '0',
            high: '1',
            next: '1',
            events: [_resolved('1')],
            generation: 'abababab-abab-4bab-8bab-abababababab',
          ),
        ],
        continuationErrors: [
          const ApiException(
            statusCode: 410,
            code: 'CONFLICT_FEED_GENERATION_CHANGED',
            message: 'Conflict feed generation changed.',
            details: {
              'server_generation': _oldGeneration,
              'current_generation': 'not-a-uuid',
              'recovery': 'restart_from_zero',
            },
          ),
        ],
      );
      final repository = _repository(api, database, identity, key, sodium)
        ..canWrite = false;

      await expectLater(repository.synchronize(), throwsA(isA<ApiException>()));

      expect(api.conflictAfterSeqs, ['1']);
      expect(
        await database.testActiveConflictFeedGeneration(_vaultId),
        _oldGeneration,
      );
      expect(
        await database.testConflictFeedCursor(_vaultId, _oldGeneration),
        '1',
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'a sync cycle applies at most one conflict generation transition',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const nextGeneration = 'abababab-abab-4bab-8bab-abababababab';
      const laterGeneration = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd';
      await database.saveTestConflictChangesPage(
        _page(
          after: '0',
          high: '1',
          next: '1',
          events: [_created('1')],
          generation: _oldGeneration,
        ),
      );
      final api = _ConflictFeedApi(
        identity,
        [
          _page(
            after: '0',
            high: '2',
            next: '1',
            events: [_resolved('1')],
            generation: nextGeneration,
            more: true,
          ),
        ],
        continuationErrors: [
          const ApiException(
            statusCode: 410,
            code: 'CONFLICT_FEED_GENERATION_CHANGED',
            message: 'Conflict feed generation changed.',
            details: {
              'server_generation': _oldGeneration,
              'current_generation': nextGeneration,
              'recovery': 'restart_from_zero',
            },
          ),
          const ApiException(
            statusCode: 410,
            code: 'CONFLICT_FEED_GENERATION_CHANGED',
            message: 'Conflict feed generation changed again.',
            details: {
              'server_generation': nextGeneration,
              'current_generation': laterGeneration,
              'recovery': 'restart_from_zero',
            },
          ),
        ],
      );
      final repository = _repository(api, database, identity, key, sodium)
        ..canWrite = false;

      await expectLater(repository.synchronize(), throwsA(isA<ApiException>()));

      expect(api.conflictAfterSeqs, ['1', null, '1']);
      expect(
        await database.testActiveConflictFeedGeneration(_vaultId),
        nextGeneration,
      );
      expect(
        await database.testConflictFeedCursor(_vaultId, nextGeneration),
        '1',
      );
      expect(
        await database.testConflictFeedCursor(_vaultId, laterGeneration),
        '0',
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'rejects an envelope with an undeclared v1 header field before cursor advance',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final valid = await _branchEnvelope(identity, key, sodium);
      final header = Map<String, dynamic>.from(valid['header'] as Map)
        ..['unsigned_extension'] = 'must-not-be-accepted';
      final malformed = <String, Object?>{...valid, 'header': header};
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _ConflictFeedApi(identity, [
        _page(
          after: '0',
          high: '1',
          next: '1',
          events: [_created('1', envelope: malformed)],
        ),
      ]);
      final repository = _repository(api, database, identity, key, sodium);

      await expectLater(
        repository.synchronize(),
        throwsA(isA<FormatException>()),
      );

      expect(
        await database.testConflictFeedCursor(_vaultId, _mainGeneration),
        '0',
      );
      expect(await database.testActiveConflictFeedInbox(_vaultId), isEmpty);

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'adoption is durable and resolution retry reuses the committed target after reopen',
    () async {
      final sodium = await SodiumSumoInit.init();
      final identity = DeviceIdentity.create(sodium);
      final key = Uint8List.fromList(sodium.randombytes.buf(32));
      final branch = await _branchEnvelope(
        identity,
        key,
        sodium,
        plaintext: {'id': _recordId, 'type': 'host', 'name': 'adopt me'},
      );
      final directory = await Directory.systemTemp.createTemp(
        'atermius-feed-adoption-',
      );
      final databaseFile = File('${directory.path}/client.sqlite');
      var database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
      await database.saveTestConflictChangesPage(
        _page(
          after: '0',
          high: '1',
          next: '1',
          events: [_created('1', envelope: branch)],
        ),
      );
      final api = _FeedAdoptionApi(identity, [
        _page(after: '1', high: '1', next: '1', events: []),
      ]);
      final repository = _repository(api, database, identity, key, sodium);

      await repository.adoptRemoteConflict(_conflictId);

      final staged = await database.testAllPendingOperations(_vaultId);
      expect(staged, hasLength(1));
      expect(staged.single.status, 'queued');
      final adoptedEnvelope =
          jsonDecode(staged.single.envelopeJson) as Map<String, dynamic>;
      final adoptedHeader = adoptedEnvelope['header'] as Map<String, dynamic>;
      final sourceHeader = branch['header'] as Map<String, dynamic>;
      expect(adoptedHeader['op_id'], isNot(sourceHeader['op_id']));
      expect(adoptedHeader['revision_id'], isNot(sourceHeader['revision_id']));
      expect(adoptedHeader['device_id'], identity.deviceId);
      final stagedTarget = await database.testFeedConflictResolution(
        _conflictId,
      );
      expect(stagedTarget?.state, 'awaiting_commit');
      expect(stagedTarget?.opId, adoptedHeader['op_id']);

      await expectLater(
        repository.synchronize(),
        throwsA(isA<SocketException>()),
      );
      expect(api.pushCalls, 1);
      expect(api.resolutionRequests, hasLength(1));
      expect(
        (await database.testAllPendingOperations(_vaultId)),
        isEmpty,
        reason:
            'The push receipt is durable even though resolve response was lost.',
      );
      expect(
        (await database.testFeedConflictResolution(_conflictId))?.state,
        'committed',
      );
      final committedRevision =
          api.resolutionRequests.single['resolved_revision_id'];
      await database.close();

      database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
      final reopened = _repository(api, database, identity, key, sodium);
      final retry = await reopened.synchronize();

      expect(retry.status, 'idle');
      expect(
        api.pushCalls,
        1,
        reason: 'A committed operation is not re-created.',
      );
      expect(api.resolutionRequests, hasLength(2));
      expect(
        api.resolutionRequests.map(
          (request) => request['resolved_revision_id'],
        ),
        everyElement(committedRevision),
      );
      expect(
        (await database.testFeedConflictResolution(_conflictId))?.state,
        'resolved',
      );

      await database.close();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await directory.delete(recursive: true);
    },
  );

  test(
    'matching resolved feed event makes delayed resolution completion idempotent',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const resolutionRevisionId = '66666666-6666-4666-8666-666666666666';
      try {
        await database.saveTestConflictChangesPage(
          _page(after: '0', high: '1', next: '1', events: [_created('1')]),
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        await database
            .into(database.feedConflictResolutions)
            .insert(
              FeedConflictResolutionsCompanion.insert(
                conflictId: _conflictId,
                vaultId: _vaultId,
                recordId: _recordId,
                instanceId: const Value(_instanceId),
                serverSpaceId: const Value(_spaceId),
                opId: const Value('88888888-8888-4888-8888-888888888888'),
                resolutionRevisionId: resolutionRevisionId,
                state: 'committed',
                createdAt: now,
                updatedAt: now,
              ),
            );

        await expectLater(
          database.markFeedConflictResolved(
            conflictId: _conflictId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            resolutionRevisionId: '77777777-7777-4777-8777-777777777777',
          ),
          throwsStateError,
        );
        expect(
          (await database.testFeedConflictResolution(_conflictId))?.state,
          'committed',
        );

        await database.saveTestConflictChangesPage(
          _page(
            after: '1',
            high: '2',
            next: '2',
            events: [_resolved('2', resolvedRevisionId: resolutionRevisionId)],
          ),
        );
        expect(
          (await database.testFeedConflictResolution(_conflictId))?.state,
          'resolved',
        );

        // A delayed completion response for the same durable target is an
        // idempotent success after the authoritative feed event wins the race.
        await database.markFeedConflictResolved(
          conflictId: _conflictId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          resolutionRevisionId: resolutionRevisionId,
        );
        await expectLater(
          database.markFeedConflictResolved(
            conflictId: _conflictId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            resolutionRevisionId: '77777777-7777-4777-8777-777777777777',
          ),
          throwsStateError,
        );
        await expectLater(
          database.markFeedConflictResolved(
            conflictId: '55555555-5555-4555-8555-555555555556',
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            resolutionRevisionId: resolutionRevisionId,
          ),
          throwsStateError,
        );

        await (database.update(
          database.feedConflictResolutions,
        )..where((row) => row.conflictId.equals(_conflictId))).write(
          const FeedConflictResolutionsCompanion(state: Value('needs_review')),
        );
        await expectLater(
          database.markFeedConflictResolved(
            conflictId: _conflictId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            resolutionRevisionId: resolutionRevisionId,
          ),
          throwsStateError,
        );
      } finally {
        await database.close();
      }
    },
  );

  test('local and feed conflict resolution targets cannot overlap', () async {
    final fixture = await _passwordMergeFixture();
    try {
      final event =
          await fixture.database.testActiveCreatedConflictEvent(
            vaultId: _vaultId,
            conflictId: _conflictId,
          ) ??
          (throw StateError('Created conflict event is missing.'));
      final current =
          await fixture.database.testEncryptedRecord(_vaultId, _recordId) ??
          (throw StateError('Committed current head is missing.'));
      final now = DateTime.now().millisecondsSinceEpoch;
      await fixture.database
          .into(fixture.database.conflictBranches)
          .insert(
            ConflictBranchesCompanion.insert(
              conflictId: _conflictId,
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_instanceId),
              serverSpaceId: const Value(_spaceId),
              kind: 'concurrent_edit',
              branchEnvelopeJson: jsonEncode(event.envelope),
              remoteEnvelopeJson: current.envelopeJson,
              state: const Value('open'),
              createdAt: now,
            ),
          );
      await fixture.database
          .into(fixture.database.feedConflictResolutions)
          .insert(
            FeedConflictResolutionsCompanion.insert(
              conflictId: _conflictId,
              vaultId: _vaultId,
              recordId: _recordId,
              instanceId: const Value(_instanceId),
              serverSpaceId: const Value(_spaceId),
              opId: const Value('88888888-8888-4888-8888-888888888888'),
              resolutionRevisionId: current.revisionId,
              state: 'awaiting_commit',
              createdAt: now,
              updatedAt: now,
            ),
          );

      final localResolution = await fixture.repository.encryptOperation(
        recordId: _recordId,
        plaintext: _passwordCredential(name: 'Local resolution'),
        baseRevisionId: current.revisionId,
      );
      await expectLater(
        fixture.database.queueConflictResolution(
          conflictId: _conflictId,
          vaultId: _vaultId,
          recordId: _recordId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          baseRevisionId: current.revisionId,
          envelope: localResolution,
          deleted: false,
        ),
        throwsStateError,
      );
      expect(
        await fixture.database.testAllPendingOperations(_vaultId),
        isEmpty,
      );

      await (fixture.database.update(
        fixture.database.conflictBranches,
      )..where((row) => row.conflictId.equals(_conflictId))).write(
        const ConflictBranchesCompanion(state: Value('resolution_ready')),
      );
      final generation = await fixture.database
          .testActiveConflictFeedGeneration(_vaultId);
      final partition = await fixture.database
          .testActiveConflictFeedPartitionId(_vaultId);
      expect(generation, isNotNull);
      expect(partition, isNotNull);
      await expectLater(
        fixture.database.stageFeedConflictRetainCurrent(
          vaultId: _vaultId,
          conflictId: _conflictId,
          serverGeneration: generation!,
          partitionId: partition!,
          recordId: _recordId,
          expectedHeadRevisionId: current.revisionId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        ),
        throwsStateError,
      );
      expect(
        (await fixture.database.testFeedConflictResolution(_conflictId))?.state,
        'awaiting_commit',
      );
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'password merge previews verified values and stages a newly signed composition',
    () async {
      final fixture = await _passwordMergeFixture(
        local: _passwordCredential(name: 'Local account'),
        remote: _passwordCredential(
          name: 'Current account',
          username: 'remote-user',
          secret: 'remote-secret',
        ),
      );
      try {
        expect(
          await fixture.repository.isPasswordCredentialMergeEligible(
            conflictId: _conflictId,
          ),
          isTrue,
        );
        final preview = await fixture.repository
            .loadCredentialConflictMergePreview(conflictId: _conflictId);
        expect(preview, isNotNull);
        expect(preview!.name.sameOnBothBranches, isFalse);
        expect(preview.username.sameOnBothBranches, isFalse);
        expect(preview.secret.sameOnBothBranches, isFalse);
        expect(preview.username.localValue, 'local-user');
        expect(preview.username.remoteValue, 'remote-user');
        expect(preview.secret.localValue, 'local-secret');
        expect(preview.secret.remoteValue, 'remote-secret');

        await expectLater(
          fixture.repository.mergePasswordCredentialConflict(
            conflictId: _conflictId,
            expectedHeadRevisionId: preview.currentHeadRevisionId,
            choices: const {
              CredentialConflictMergeField.username:
                  CredentialConflictMergeBranch.local,
            },
          ),
          throwsArgumentError,
        );
        expect(
          await fixture.database.testAllPendingOperations(_vaultId),
          isEmpty,
        );

        final outcome = await fixture.repository
            .mergePasswordCredentialConflict(
              conflictId: _conflictId,
              expectedHeadRevisionId: preview.currentHeadRevisionId,
              choices: const {
                CredentialConflictMergeField.name:
                    CredentialConflictMergeBranch.local,
                CredentialConflictMergeField.username:
                    CredentialConflictMergeBranch.local,
                CredentialConflictMergeField.secret:
                    CredentialConflictMergeBranch.remote,
              },
            );
        expect(outcome.status, CredentialConflictMergeStatus.staged);
        expect(outcome.resolutionRevisionId, isNotNull);

        final pending = await fixture.database.testAllPendingOperations(
          _vaultId,
        );
        expect(pending, hasLength(1));
        final staged =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        final header = staged['header'] as Map<String, dynamic>;
        expect(header['operation'], 'update');
        expect(header['record_id'], _recordId);
        expect(header['base_revision_id'], preview.currentHeadRevisionId);
        expect(header['revision_id'], outcome.resolutionRevisionId);
        expect(header['revision_id'], isNot(preview.branchRevisionId));
        expect(header['revision_id'], isNot(preview.currentHeadRevisionId));
        expect(header['device_id'], fixture.identity.deviceId);

        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.key,
          envelope: staged,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        expect(plaintext['name'], 'Local account');
        expect(plaintext['username'], 'local-user');
        expect(plaintext['secret'], 'remote-secret');
        expect(plaintext['kind'], 'password');

        final resolution = await fixture.database.testFeedConflictResolution(
          _conflictId,
        );
        expect(resolution?.state, 'awaiting_commit');
        expect(resolution?.resolutionRevisionId, outcome.resolutionRevisionId);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'Host security merge verifies the base and stages one selected tuple with current-head CAS',
    () async {
      final fixture = await _hostSecurityMergeFixture();
      try {
        final preview = await fixture.repository
            .loadHostSecurityConflictMergePreview(conflictId: _conflictId);
        expect(preview, isNotNull);
        expect(
          preview!.baseRevisionId,
          fixture.api.revisionDetails.keys.single,
        );
        expect(
          preview.fields.firstWhere((field) => field.label == 'Address').base,
          'prod.example.test',
        );
        expect(
          preview.fields
              .firstWhere((field) => field.label == 'Proxy settings')
              .conflict,
          '••••••••',
        );
        expect(preview.toString(), isNot(contains('local-proxy-password')));
        expect(preview.toString(), isNot(contains('conflict-host-key')));

        final outcome = await fixture.repository.mergeHostSecurityConflict(
          conflictId: _conflictId,
          expectedHeadRevisionId: preview.currentHeadRevisionId,
          choice: HostSecurityMergeBranch.conflict,
          validateReferences: (_) => null,
        );
        expect(outcome.status, HostSecurityMergeStatus.staged);

        final pending = await fixture.database.testAllPendingOperations(
          _vaultId,
        );
        expect(pending, hasLength(1));
        final envelope =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        final header = envelope['header'] as Map<String, dynamic>;
        expect(header['operation'], 'update');
        expect(header['base_revision_id'], preview.currentHeadRevisionId);
        expect(header['device_id'], fixture.identity.deviceId);
        expect(header['revision_id'], isNot(preview.branchRevisionId));

        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.key,
          envelope: envelope,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        expect(plaintext['address'], 'staging.example.test');
        expect(plaintext['port'], 22);
        expect(plaintext['proxy'], 'local-proxy-password');
        expect(plaintext['jump_host_id'], _jumpHostA);
        expect(plaintext['host_key'], 'conflict-host-key');
        expect(plaintext['tags'], ['current-tag']);
        expect(
          (await fixture.database.testFeedConflictResolution(
            _conflictId,
          ))?.state,
          'awaiting_commit',
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'rebased Host feed resolution pushes past its preserved conflicted branch',
    () async {
      final fixture = await _hostSecurityMergeFixture();
      try {
        final oldConflict = await _insertConflictedFeedBranch(fixture);
        final oldConflictHeader = oldConflict['header'] as Map<String, dynamic>;
        final preview = await fixture.repository
            .loadHostSecurityConflictMergePreview(conflictId: _conflictId);
        expect(preview, isNotNull);
        final outcome = await fixture.repository.mergeHostSecurityConflict(
          conflictId: _conflictId,
          expectedHeadRevisionId: preview!.currentHeadRevisionId,
          choice: HostSecurityMergeBranch.conflict,
          validateReferences: (_) => null,
        );
        expect(outcome.status, HostSecurityMergeStatus.staged);
        final target = await fixture.database.testFeedConflictResolution(
          _conflictId,
        );
        expect(target?.state, 'awaiting_commit');
        expect(target?.opId, isNot(oldConflictHeader['op_id']));

        final queued = await fixture.database.queuedOperations(_vaultId);
        expect(queued, hasLength(1));
        expect(queued.single.opId, target?.opId);
        expect(
          (await fixture.database.testAllPendingOperations(_vaultId))
              .singleWhere((item) => item.opId == oldConflictHeader['op_id'])
              .status,
          'conflict',
        );

        fixture.api.pushCommitSeq = '3';
        final result = await fixture.repository.synchronize();

        expect(result.status, 'idle');
        expect(fixture.api.pushCalls, 1);
        expect(fixture.api.pushedOperationHeaders, hasLength(1));
        expect(
          fixture.api.pushedOperationHeaders.single['op_id'],
          target?.opId,
        );
        expect(
          fixture.api.pushedOperationHeaders.single['base_revision_id'],
          preview.currentHeadRevisionId,
        );
        expect(fixture.api.resolutionRequests, hasLength(1));
        expect(
          fixture.api.resolutionRequests.single['resolved_revision_id'],
          target?.resolutionRevisionId,
        );
        expect(
          (await fixture.database.testFeedConflictResolution(
            _conflictId,
          ))?.state,
          'resolved',
        );
        final remaining = await fixture.database.testAllPendingOperations(
          _vaultId,
        );
        expect(remaining, hasLength(1));
        expect(remaining.single.opId, oldConflictHeader['op_id']);
        expect(remaining.single.status, 'conflict');
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'queued child of a conflicted revision stays blocked while another record pushes',
    () async {
      final fixture = await _hostSecurityMergeFixture();
      try {
        final oldConflict = await _insertConflictedFeedBranch(fixture);
        final oldConflictHeader = oldConflict['header'] as Map<String, dynamic>;
        final conflictRevisionId = oldConflictHeader['revision_id'] as String;
        final now = DateTime.now().millisecondsSinceEpoch;
        final child = await fixture.repository.encryptOperation(
          recordId: _recordId,
          plaintext: _hostForSecurityMerge(
            address: 'child.example.test',
            port: 2222,
          ),
          baseRevisionId: conflictRevisionId,
        );
        final childHeader = child['header'] as Map<String, dynamic>;
        await fixture.database
            .into(fixture.database.pendingOperations)
            .insert(
              PendingOperationsCompanion.insert(
                opId: childHeader['op_id'] as String,
                vaultId: _vaultId,
                recordId: _recordId,
                instanceId: const Value(_instanceId),
                serverSpaceId: const Value(_spaceId),
                baseRevisionId: Value(conflictRevisionId),
                baseEnvelopeJson: Value(jsonEncode(oldConflict)),
                envelopeJson: jsonEncode(child),
                status: const Value('queued'),
                createdAt: now + 1,
              ),
            );
        final unrelated = await fixture.repository.encryptOperation(
          recordId: _otherRecordId,
          plaintext: {
            'id': _otherRecordId,
            'type': 'host',
            'name': 'Independent host',
            'address': 'independent.example.test',
            'port': 22,
          },
          baseRevisionId: null,
          operation: 'create',
        );
        final unrelatedHeader = unrelated['header'] as Map<String, dynamic>;
        await fixture.database
            .into(fixture.database.pendingOperations)
            .insert(
              PendingOperationsCompanion.insert(
                opId: unrelatedHeader['op_id'] as String,
                vaultId: _vaultId,
                recordId: _otherRecordId,
                instanceId: const Value(_instanceId),
                serverSpaceId: const Value(_spaceId),
                baseRevisionId: const Value(null),
                envelopeJson: jsonEncode(unrelated),
                status: const Value('queued'),
                createdAt: now + 2,
              ),
            );

        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<StateError>()),
        );

        expect(fixture.api.pushCalls, 1);
        expect(fixture.api.pushedOperationHeaders, hasLength(1));
        expect(
          fixture.api.pushedOperationHeaders.single['record_id'],
          _otherRecordId,
        );
        final remaining = await fixture.database.testAllPendingOperations(
          _vaultId,
        );
        final queuedChild = remaining.singleWhere(
          (item) => item.opId == childHeader['op_id'],
        );
        expect(queuedChild.status, 'queued');
        expect(queuedChild.attemptCount, 0);
        expect(
          remaining.any((item) => item.opId == unrelatedHeader['op_id']),
          isFalse,
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('Host security merge refuses to stage after the head changes', () async {
    final fixture = await _hostSecurityMergeFixture();
    try {
      final preview = await fixture.repository
          .loadHostSecurityConflictMergePreview(conflictId: _conflictId);
      expect(preview, isNotNull);
      final newer = await _branchEnvelope(
        fixture.identity,
        fixture.key,
        fixture.sodium,
        operation: 'update',
        baseRevisionId: preview!.currentHeadRevisionId,
        deviceSequence: '3',
        plaintext: _hostForSecurityMerge(
          address: 'newer.example.test',
          port: 2203,
        ),
      );
      final newerRevision =
          (newer['header'] as Map<String, dynamic>)['revision_id'] as String;
      await fixture.database.storeRemoteEnvelope(
        vaultId: _vaultId,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
        recordId: _recordId,
        revisionId: newerRevision,
        envelope: newer,
        commitSeq: '3',
        deleted: false,
      );

      final outcome = await fixture.repository.mergeHostSecurityConflict(
        conflictId: _conflictId,
        expectedHeadRevisionId: preview.currentHeadRevisionId,
        choice: HostSecurityMergeBranch.conflict,
        validateReferences: (_) => null,
      );
      expect(outcome.status, HostSecurityMergeStatus.reviewRequired);
      expect(
        await fixture.database.testAllPendingOperations(_vaultId),
        isEmpty,
      );
      expect(
        await fixture.database.testFeedConflictResolution(_conflictId),
        isNull,
      );
      expect(
        (await fixture.database.testEncryptedRecord(
          _vaultId,
          _recordId,
        ))?.revisionId,
        newerRevision,
      );
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'password merge rejects missing secrets and incompatible auth material',
    () async {
      final invalidPairs =
          <({Map<String, Object?> local, Map<String, Object?> remote})>[
            (
              local: _passwordCredential(secret: null),
              remote: _passwordCredential(),
            ),
            (
              local: _passwordCredential(),
              remote: {
                ..._passwordCredential(),
                'private_key': 'unsupported-auth-material',
              },
            ),
            (
              local: _passwordCredential(),
              remote: {..._passwordCredential(), 'passphrase': 'unsupported'},
            ),
            (
              local: _passwordCredential(),
              remote: {..._passwordCredential(), 'fingerprint': 'unsupported'},
            ),
            (
              local: _passwordCredential(),
              remote: {
                ..._passwordCredential(),
                'credential_id': 'unsupported',
              },
            ),
            (
              local: _passwordCredential(),
              remote: {..._passwordCredential(), 'auth_kind': 'unsupported'},
            ),
            (
              local: _passwordCredential(),
              remote: {..._passwordCredential(), 'type': 'host'},
            ),
            (
              local: {..._passwordCredential(), 'kind': 'private_key'},
              remote: {..._passwordCredential(), 'kind': 'private_key'},
            ),
          ];
      for (final pair in invalidPairs) {
        final fixture = await _passwordMergeFixture(
          local: pair.local,
          remote: pair.remote,
        );
        try {
          expect(
            await fixture.repository.isPasswordCredentialMergeEligible(
              conflictId: _conflictId,
            ),
            isFalse,
          );
          expect(
            await fixture.repository.loadCredentialConflictMergePreview(
              conflictId: _conflictId,
            ),
            isNull,
          );
          expect(
            await fixture.database.testAllPendingOperations(_vaultId),
            isEmpty,
          );
        } finally {
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'password merge returns review-required and DB CAS rejects a moved head',
    () async {
      final fixture = await _passwordMergeFixture();
      try {
        final preview = await fixture.repository
            .loadCredentialConflictMergePreview(conflictId: _conflictId);
        expect(preview, isNotNull);

        final newerEnvelope = await _branchEnvelope(
          fixture.identity,
          fixture.key,
          fixture.sodium,
          operation: 'update',
          baseRevisionId: preview!.currentHeadRevisionId,
          deviceSequence: '3',
          plaintext: _passwordCredential(username: 'newer-head-user'),
        );
        final newerRevision =
            (newerEnvelope['header'] as Map<String, dynamic>)['revision_id']
                as String;
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          recordId: _recordId,
          revisionId: newerRevision,
          envelope: newerEnvelope,
          commitSeq: '2',
          deleted: false,
        );

        final outcome = await fixture.repository
            .mergePasswordCredentialConflict(
              conflictId: _conflictId,
              expectedHeadRevisionId: preview.currentHeadRevisionId,
              choices: const {
                CredentialConflictMergeField.username:
                    CredentialConflictMergeBranch.local,
                CredentialConflictMergeField.secret:
                    CredentialConflictMergeBranch.local,
              },
            );
        expect(outcome.status, CredentialConflictMergeStatus.reviewRequired);
        expect(
          await fixture.database.testAllPendingOperations(_vaultId),
          isEmpty,
        );
        expect(
          await fixture.database.testFeedConflictResolution(_conflictId),
          isNull,
        );
        expect(
          (await fixture.database.testEncryptedRecord(
            _vaultId,
            _recordId,
          ))?.revisionId,
          newerRevision,
        );

        final staleResolution = await fixture.repository.encryptOperation(
          recordId: _recordId,
          plaintext: _passwordCredential(username: 'stale-review-user'),
          baseRevisionId: preview.currentHeadRevisionId,
        );
        final generation = await fixture.database
            .testActiveConflictFeedGeneration(_vaultId);
        final partition = await fixture.database
            .testActiveConflictFeedPartitionId(_vaultId);
        expect(generation, isNotNull);
        expect(partition, isNotNull);
        await expectLater(
          fixture.database.stageFeedConflictAdoption(
            vaultId: _vaultId,
            conflictId: _conflictId,
            serverGeneration: generation!,
            partitionId: partition!,
            recordId: _recordId,
            expectedHeadRevisionId: preview.currentHeadRevisionId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            envelope: staleResolution,
            deleted: false,
          ),
          throwsStateError,
        );
        expect(
          await fixture.database.testAllPendingOperations(_vaultId),
          isEmpty,
        );
        expect(
          await fixture.database.testFeedConflictResolution(_conflictId),
          isNull,
        );
        expect(
          (await fixture.database.testEncryptedRecord(
            _vaultId,
            _recordId,
          ))?.revisionId,
          newerRevision,
        );
      } finally {
        await fixture.dispose();
      }
    },
  );
}

SyncRepository _repository(
  _ConflictFeedApi api,
  ClientDatabase database,
  DeviceIdentity identity,
  Uint8List key,
  SodiumSumo sodium,
) => SyncRepository(
  api: api,
  database: database,
  crypto: VaultCrypto(sodium),
  identity: identity,
  serverSpaceId: _spaceId,
  instanceId: _instanceId,
  vaultId: _vaultId,
  keyEpoch: '1',
  membershipVersion: '1',
  serverGeneration: _mainGeneration,
  vaultKey: key,
);

extension _ScopedConflictFeedTestDatabase on ClientDatabase {
  Future<void> saveTestConflictChangesPage(ConflictChangesPage page) =>
      saveConflictChangesPage(
        page,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );

  Future<String> testConflictFeedCursor(
    String vaultId,
    String generation, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
  }) => conflictFeedCursor(
    vaultId,
    generation,
    partitionId: partitionId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<String?> testActiveConflictFeedGeneration(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => activeConflictFeedGeneration(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<String?> testActiveConflictFeedPartitionId(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => activeConflictFeedPartitionId(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<List<ConflictChangeEvent>> testActiveConflictFeedInbox(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => activeConflictFeedInbox(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<List<ConflictChangeEvent>> testListConflictFeedInbox(
    String vaultId,
    String generation, {
    String? partitionId,
    String? instanceId,
    String? serverSpaceId,
  }) => listConflictFeedInbox(
    vaultId,
    generation,
    partitionId: partitionId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<FeedConflictResolution?> testFeedConflictResolution(
    String conflictId, {
    String? instanceId,
    String? serverSpaceId,
  }) => feedConflictResolution(
    conflictId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<ConflictChangeEvent?> testActiveCreatedConflictEvent({
    required String vaultId,
    required String conflictId,
    String? instanceId,
    String? serverSpaceId,
  }) => activeCreatedConflictEvent(
    vaultId: vaultId,
    conflictId: conflictId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<List<EncryptedRecord>> testCachedEnvelopes(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => cachedEnvelopes(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<List<ConflictBranche>> testOpenConflicts(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => openConflicts(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<EncryptedRecord?> testEncryptedRecord(
    String vaultId,
    String recordId, {
    String? instanceId,
    String? serverSpaceId,
  }) => encryptedRecord(
    vaultId,
    recordId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );

  Future<List<PendingOperation>> testAllPendingOperations(
    String vaultId, {
    String? instanceId,
    String? serverSpaceId,
  }) => allPendingOperations(
    vaultId,
    instanceId: instanceId ?? _instanceId,
    serverSpaceId: serverSpaceId ?? _spaceId,
  );
}

Map<String, Object?> _passwordCredential({
  String name = 'Shared account',
  String username = 'local-user',
  String? secret = 'local-secret',
}) => {
  'id': _recordId,
  'type': 'credential',
  'kind': 'password',
  'name': name,
  'username': username,
  if (secret != null) 'secret': secret,
};

Map<String, Object?> _hostForSecurityMerge({
  required String address,
  required int port,
  String name = 'Production Host',
  List<String> tags = const [],
  String? proxy,
  String? jumpHostId,
  String? hostKey,
}) => {
  'id': _recordId,
  'type': 'host',
  'name': name,
  'address': address,
  'port': port,
  'username': 'deploy',
  'credential_id': null,
  'jump_host_id': jumpHostId,
  'proxy': proxy,
  'host_key': hostKey,
  'tags': tags,
};

Future<_PasswordMergeFixture> _passwordMergeFixture({
  Map<String, Object?>? local,
  Map<String, Object?>? remote,
}) async {
  final sodium = await SodiumSumoInit.init();
  final identity = DeviceIdentity.create(sodium);
  final key = Uint8List.fromList(sodium.randombytes.buf(32));
  final branch = await _branchEnvelope(
    identity,
    key,
    sodium,
    operation: 'update',
    baseRevisionId: _baseRevisionId,
    deviceSequence: '1',
    plaintext: local ?? _passwordCredential(),
  );
  final current = await _branchEnvelope(
    identity,
    key,
    sodium,
    operation: 'update',
    baseRevisionId: _baseRevisionId,
    deviceSequence: '2',
    plaintext:
        remote ??
        _passwordCredential(
          name: 'Current account',
          username: 'remote-user',
          secret: 'remote-secret',
        ),
  );
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  await database.saveTestConflictChangesPage(
    _page(
      after: '0',
      high: '1',
      next: '1',
      events: [
        _created('1', envelope: branch, baseRevisionId: _baseRevisionId),
      ],
    ),
  );
  final currentHeader = current['header'] as Map<String, dynamic>;
  await database.storeRemoteEnvelope(
    vaultId: _vaultId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
    recordId: _recordId,
    revisionId: currentHeader['revision_id'] as String,
    envelope: current,
    commitSeq: '1',
    deleted: false,
  );
  final api = _FeedAdoptionApi(identity, const []);
  api.loseFirstResolutionResponse = false;
  return _PasswordMergeFixture(
    sodium: sodium,
    identity: identity,
    key: key,
    database: database,
    api: api,
    repository: _repository(api, database, identity, key, sodium),
  );
}

Future<_PasswordMergeFixture> _hostSecurityMergeFixture() async {
  final sodium = await SodiumSumoInit.init();
  final identity = DeviceIdentity.create(sodium);
  final key = Uint8List.fromList(sodium.randombytes.buf(32));
  final base = await _branchEnvelope(
    identity,
    key,
    sodium,
    operation: 'create',
    deviceSequence: '0',
    plaintext: _hostForSecurityMerge(
      address: 'prod.example.test',
      port: 22,
      hostKey: 'base-host-key',
    ),
  );
  final baseRevisionId =
      (base['header'] as Map<String, dynamic>)['revision_id'] as String;
  final conflict = await _branchEnvelope(
    identity,
    key,
    sodium,
    operation: 'update',
    baseRevisionId: baseRevisionId,
    deviceSequence: '1',
    plaintext: _hostForSecurityMerge(
      address: 'staging.example.test',
      port: 22,
      name: 'Staging branch',
      proxy: 'local-proxy-password',
      jumpHostId: _jumpHostA,
      hostKey: 'conflict-host-key',
    ),
  );
  final current = await _branchEnvelope(
    identity,
    key,
    sodium,
    operation: 'update',
    baseRevisionId: baseRevisionId,
    deviceSequence: '2',
    plaintext: _hostForSecurityMerge(
      address: 'prod.example.test',
      port: 2202,
      proxy: 'current-proxy-password',
      jumpHostId: '99999999-9999-4999-8999-999999999999',
      hostKey: 'current-host-key',
      tags: const ['current-tag'],
    ),
  );
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  await database.saveTestConflictChangesPage(
    _page(
      after: '0',
      high: '1',
      next: '1',
      events: [
        _created('1', envelope: conflict, baseRevisionId: baseRevisionId),
      ],
    ),
  );
  final currentHeader = current['header'] as Map<String, dynamic>;
  await database.storeRemoteEnvelope(
    vaultId: _vaultId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
    recordId: _recordId,
    revisionId: currentHeader['revision_id'] as String,
    envelope: current,
    commitSeq: '2',
    deleted: false,
  );
  final api = _FeedAdoptionApi(identity, const [])
    ..loseFirstResolutionResponse = false
    ..revisionDetails[baseRevisionId] = {
      'record_id': _recordId,
      'envelope': base,
      'digest': 'test-digest',
      'commit_seq': '1',
    };
  return _PasswordMergeFixture(
    sodium: sodium,
    identity: identity,
    key: key,
    database: database,
    api: api,
    repository: _repository(api, database, identity, key, sodium),
  );
}

Future<Map<String, dynamic>> _insertConflictedFeedBranch(
  _PasswordMergeFixture fixture,
) async {
  final event =
      await fixture.database.testActiveCreatedConflictEvent(
        vaultId: _vaultId,
        conflictId: _conflictId,
      ) ??
      (throw StateError('Created conflict event is missing.'));
  final envelope = Map<String, dynamic>.from(
    event.envelope ??
        (throw StateError('Conflict branch envelope is missing.')),
  );
  final header = Map<String, dynamic>.from(envelope['header'] as Map);
  await fixture.database
      .into(fixture.database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: header['op_id'] as String,
          vaultId: _vaultId,
          recordId: _recordId,
          instanceId: const Value(_instanceId),
          serverSpaceId: const Value(_spaceId),
          baseRevisionId: Value(header['base_revision_id'] as String?),
          envelopeJson: jsonEncode(envelope),
          status: const Value('conflict'),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
  return envelope;
}

class _PasswordMergeFixture {
  _PasswordMergeFixture({
    required this.sodium,
    required this.identity,
    required this.key,
    required this.database,
    required this.api,
    required this.repository,
  });

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final Uint8List key;
  final ClientDatabase database;
  final _FeedAdoptionApi api;
  final SyncRepository repository;

  Future<void> dispose() async {
    await database.close();
    api.close();
    identity.dispose();
    key.fillRange(0, key.length, 0);
  }
}

ConflictChangesPage _page({
  required String after,
  required String high,
  required String next,
  required List<Map<String, Object?>> events,
  String generation = _mainGeneration,
  bool more = false,
}) => ConflictChangesPage.fromJson(
  {
    'vault_id': _vaultId,
    'after_seq': after,
    'high_watermark': high,
    'events': events,
    'next_after_seq': next,
    'has_more': more,
    'server_generation': generation,
  },
  expectedVaultId: _vaultId,
  expectedAfterSeq: after,
  limit: 100,
);

Map<String, Object?> _created(
  String seq, {
  Map<String, Object?>? envelope,
  String? baseRevisionId,
}) => {
  'seq': seq,
  'type': 'created',
  'conflict_id': _conflictId,
  'record_id': _recordId,
  'base_revision_id': baseRevisionId,
  'resolved_revision_id': null,
  'created_at': '2026-09-27T12:30:00Z',
  'envelope': envelope ?? {'ciphertext': 'opaque'},
};

Future<Map<String, Object?>> _branchEnvelope(
  DeviceIdentity identity,
  Uint8List key,
  SodiumSumo sodium, {
  String operation = 'create',
  String? baseRevisionId,
  String deviceSequence = '1',
  Map<String, Object?>? plaintext,
}) => VaultCrypto(sodium).encryptRecord(
  vaultKey: key,
  serverSpaceId: _spaceId,
  vaultId: _vaultId,
  recordId: _recordId,
  baseRevisionId: baseRevisionId,
  deviceId: identity.deviceId,
  deviceSequence: deviceSequence,
  keyEpoch: '1',
  membershipVersion: '1',
  operation: operation,
  plaintext:
      plaintext ??
      {'id': _recordId, 'type': 'host', 'deleted': false, 'name': 'safe'},
  identity: identity,
);

Map<String, Object?> _resolved(
  String seq, {
  String resolvedRevisionId = '66666666-6666-4666-8666-666666666666',
}) => {
  'seq': seq,
  'type': 'resolved',
  'conflict_id': _conflictId,
  'record_id': _recordId,
  'base_revision_id': null,
  'resolved_revision_id': resolvedRevisionId,
  'created_at': '2026-09-27T12:31:00Z',
};

class _ConflictFeedApi extends ApiClient {
  _ConflictFeedApi(
    this.identity,
    this.pages, {
    List<ApiException> continuationErrors = const [],
  }) : continuationErrors = List<ApiException>.of(continuationErrors),
       super(baseUrl: 'https://conflict-feed.test');

  final DeviceIdentity identity;
  final List<ConflictChangesPage> pages;
  final List<ApiException> continuationErrors;
  final conflictAfterSeqs = <String?>[];
  final conflictGenerations = <String?>[];
  var _nextPage = 0;

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) => devices();

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async => const SyncPage(
    events: [],
    nextCursor: null,
    hasMore: false,
    serverGeneration: _mainGeneration,
  );

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async {
    conflictAfterSeqs.add(afterSeq);
    conflictGenerations.add(serverGeneration);
    if (afterSeq != null && continuationErrors.isNotEmpty) {
      throw continuationErrors.removeAt(0);
    }
    return pages[_nextPage++];
  }
}

class _FeedAdoptionApi extends _ConflictFeedApi {
  _FeedAdoptionApi(super.identity, super.pages);

  int pushCalls = 0;
  String pushCommitSeq = '1';
  final pushedOperationHeaders = <Map<String, dynamic>>[];
  final resolutionRequests = <Map<String, dynamic>>[];
  final revisionDetails = <String, Map<String, dynamic>>{};
  String? serverResolvedRevision;
  var loseFirstResolutionResponse = true;

  @override
  Future<Map<String, dynamic>> revision(
    String vaultId,
    String revisionId,
  ) async {
    final detail = revisionDetails[revisionId];
    if (detail == null) {
      throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'missing test revision',
      );
    }
    return detail;
  }

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async {
    conflictAfterSeqs.add(afterSeq);
    conflictGenerations.add(serverGeneration);
    final after = afterSeq ?? '0';
    return _page(after: after, high: '1', next: after, events: const []);
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushCalls++;
    final operations = batch['operations'] as List;
    final results = operations
        .map((raw) {
          final envelope = Map<String, dynamic>.from(raw as Map);
          final header = Map<String, dynamic>.from(envelope['header'] as Map);
          pushedOperationHeaders.add(header);
          return {
            'op_id': header['op_id'],
            'revision_id': header['revision_id'],
            'commit_seq': pushCommitSeq,
            'already_committed': false,
          };
        })
        .toList(growable: false);
    return {'batch_id': batch['batch_id'], 'results': results};
  }

  @override
  Future<Map<String, dynamic>> resolveConflict(
    String vaultId,
    String conflictId,
    Map<String, Object?> body,
  ) async {
    final request = Map<String, dynamic>.from(body);
    resolutionRequests.add(request);
    final revision = request['resolved_revision_id'];
    if (serverResolvedRevision == null) {
      serverResolvedRevision = revision as String;
      if (loseFirstResolutionResponse) {
        loseFirstResolutionResponse = false;
        throw const SocketException('simulated response loss after commit');
      }
    }
    if (serverResolvedRevision != revision) {
      throw StateError('Retry changed the durable resolution revision.');
    }
    return {
      'status': 'resolved',
      'resolved_revision_id': revision,
      'resolution_seq': '2',
      'already_resolved': resolutionRequests.length > 1,
    };
  }
}
