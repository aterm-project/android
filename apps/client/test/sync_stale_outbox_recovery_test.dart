import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _secondRecordId = '44444444-4444-4444-8444-444444444444';
const _generation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _oldEpoch = '1';
const _oldMembership = '1';
const _currentEpoch = '2';
const _currentMembership = '3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    're-signs a definitively rejected sent operation on the unchanged base and retains its immutable attempt',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium)
        ..staleCode = 'KEY_EPOCH_OUTDATED'
        ..holdFreshOperation = true;
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalJson = jsonEncode(original);
      final originalHeader = original['header'] as Map<String, dynamic>;

      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      currentRepository.authorizeStaleOutboxRewrapAfterMembershipRefresh();
      await expectLater(
        currentRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );

      // The first request is the immutable old envelope probe. Re-signing is
      // allowed only after that exact request receives a definitive stale
      // version rejection.
      expect(api.pushRequests, hasLength(2));
      expect(_onlyEnvelope(api.pushRequests.first), original);
      expect(
        api.pushRequests[1]['batch_id'],
        isNot(api.pushRequests[0]['batch_id']),
      );

      final replacement = _onlyEnvelope(api.pushRequests[1]);
      final replacementHeader = replacement['header'] as Map<String, dynamic>;
      expect(replacementHeader['op_id'], isNot(originalHeader['op_id']));
      expect(
        replacementHeader['revision_id'],
        isNot(originalHeader['revision_id']),
      );
      expect(replacementHeader['device_seq'], isNot('1'));
      expect(replacementHeader['base_revision_id'], isNull);
      expect(replacementHeader['key_epoch'], _currentEpoch);
      expect(replacementHeader['membership_version'], _currentMembership);
      await _expectDecryptsTo(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: currentKey,
        envelope: replacement,
        expectedName: 'offline draft',
      );

      final history = await database.supersededOperations(_vaultId);
      final preservedAttempt = history.singleWhere(
        (operation) => operation.opId == originalHeader['op_id'],
      );
      expect(preservedAttempt.status, 'superseded');
      expect(preservedAttempt.envelopeJson, originalJson);
      expect(preservedAttempt.attemptCount, greaterThanOrEqualTo(2));
      final replacementAttempt = (await database.allPendingOperations(_vaultId))
          .singleWhere(
            (operation) => operation.opId == replacementHeader['op_id'],
          );
      expect(replacementAttempt.status, 'sent');
      expect(replacementAttempt.envelopeJson, jsonEncode(replacement));
      expect(replacementAttempt.baseRevisionId, isNull);

      // The membership-refresh permit is scoped to this push pass. A second
      // stale response for the replacement must return to the coordinator and
      // must not replace the same operation repeatedly with stale local state.
      api.staleOperationId = replacementHeader['op_id'] as String;
      await expectLater(
        currentRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'KEY_EPOCH_OUTDATED',
          ),
        ),
      );
      expect(api.pushRequests, hasLength(3));
      expect(_onlyEnvelope(api.pushRequests.last), replacement);
      expect(await database.supersededOperations(_vaultId), hasLength(1));
      final activeAfterSecondStale = (await database.allPendingOperations(
        _vaultId,
      )).single;
      expect(activeAfterSecondStale.opId, replacementHeader['op_id']);
      expect(activeAfterSecondStale.envelopeJson, jsonEncode(replacement));

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'returns a stale rejection to the membership coordinator before re-signing',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium);
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );

      await expectLater(
        repository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'KEY_EPOCH_OUTDATED',
          ),
        ),
      );

      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), original);
      expect(await database.supersededOperations(_vaultId), isEmpty);
      final active = await database.allPendingOperations(_vaultId);
      expect(active, hasLength(1));
      expect(active.single.opId, originalHeader['op_id']);
      expect(active.single.envelopeJson, jsonEncode(original));

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'clears the refreshed membership permit when snapshot recovery fails before push',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium);
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      repository.authorizeStaleOutboxRewrapAfterMembershipRefresh();

      await expectLater(
        repository.recoverFromSnapshot(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVER_UNAVAILABLE',
          ),
        ),
      );
      await expectLater(
        repository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'KEY_EPOCH_OUTDATED',
          ),
        ),
      );

      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), original);
      expect(await database.supersededOperations(_vaultId), isEmpty);
      final active = await database.allPendingOperations(_vaultId);
      expect(active.single.opId, originalHeader['op_id']);
      expect(active.single.envelopeJson, jsonEncode(original));

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    're-signs a two-edit offline chain atomically and keeps one fresh base-linked active root',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium)
        ..staleCode = 'MEMBERSHIP_VERSION_CONFLICT'
        ..holdFreshOperation = true;
      final base = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: oldKey,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'committed base',
        epoch: _oldEpoch,
        membership: _oldMembership,
      );
      final baseHeader = base['header'] as Map<String, dynamic>;
      final baseRevisionId = baseHeader['revision_id'] as String;
      final baseJson = jsonEncode(base);
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: baseRevisionId,
        envelope: base,
        commitSeq: '1',
        deleted: false,
        instanceId: _generation,
        serverSpaceId: _serverSpaceId,
      );
      await database
          .into(database.deviceSequences)
          .insert(
            DeviceSequencesCompanion.insert(
              deviceId: identity.deviceId,
              nextSequence: const Value(2),
            ),
          );

      final oldRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: oldKey,
        oldKey: oldKey,
        keyEpoch: _oldEpoch,
        membershipVersion: _oldMembership,
      );
      final firstOriginal = await oldRepository.saveRecord(
        recordId: _recordId,
        baseRevisionId: baseRevisionId,
        operation: 'update',
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'offline edit one',
        },
      );
      final firstOriginalHeader =
          firstOriginal['header'] as Map<String, dynamic>;
      await database.markAttempted([firstOriginalHeader['op_id'] as String]);
      final secondOriginal = await oldRepository.saveRecord(
        recordId: _recordId,
        baseRevisionId: firstOriginalHeader['revision_id'] as String,
        operation: 'update',
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'offline edit two',
        },
      );
      final secondOriginalHeader =
          secondOriginal['header'] as Map<String, dynamic>;
      await database.markAttempted([secondOriginalHeader['op_id'] as String]);

      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      currentRepository.authorizeStaleOutboxRewrapAfterMembershipRefresh();
      await expectLater(
        currentRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );

      expect(api.pushRequests, hasLength(2));
      expect(_onlyEnvelope(api.pushRequests.first), firstOriginal);
      final superseded = await database.supersededOperations(_vaultId);
      expect(superseded, hasLength(2));
      final supersededById = {for (final row in superseded) row.opId: row};
      expect(
        supersededById.keys,
        containsAll([
          firstOriginalHeader['op_id'],
          secondOriginalHeader['op_id'],
        ]),
      );
      expect(
        supersededById[firstOriginalHeader['op_id']]!.envelopeJson,
        jsonEncode(firstOriginal),
      );
      expect(
        supersededById[secondOriginalHeader['op_id']]!.envelopeJson,
        jsonEncode(secondOriginal),
      );

      final active = await database.allPendingOperations(_vaultId);
      expect(active, hasLength(2));
      expect(active.where((row) => row.status != 'superseded'), hasLength(2));
      expect(await database.countPending(_vaultId), 2);
      final activeByBase = <String?, List<PendingOperation>>{};
      for (final row in active) {
        activeByBase.putIfAbsent(row.baseRevisionId, () => []).add(row);
      }
      expect(activeByBase[baseRevisionId], hasLength(1));
      final replacementRoot = activeByBase[baseRevisionId]!.single;
      final replacementRootHeader =
          (jsonDecode(replacementRoot.envelopeJson) as Map)['header'] as Map;
      expect(replacementRootHeader['key_epoch'], _currentEpoch);
      expect(replacementRootHeader['membership_version'], _currentMembership);
      expect(replacementRoot.baseEnvelopeJson, baseJson);
      expect(replacementRoot.opId, isNot(firstOriginalHeader['op_id']));
      expect(replacementRoot.status, 'sent');
      expect(
        _onlyEnvelope(api.pushRequests[1]),
        jsonDecode(replacementRoot.envelopeJson),
      );
      await _expectDecryptsTo(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: currentKey,
        envelope: Map<String, dynamic>.from(
          jsonDecode(replacementRoot.envelopeJson) as Map,
        ),
        expectedName: 'offline edit one',
      );

      final replacementChild =
          activeByBase[replacementRootHeader['revision_id'] as String]!.single;
      final replacementChildHeader =
          (jsonDecode(replacementChild.envelopeJson) as Map)['header'] as Map;
      expect(replacementChild.baseEnvelopeJson, replacementRoot.envelopeJson);
      expect(replacementChildHeader['key_epoch'], _currentEpoch);
      expect(replacementChildHeader['membership_version'], _currentMembership);
      expect(replacementChild.opId, isNot(secondOriginalHeader['op_id']));
      expect(replacementChild.status, 'queued');
      await _expectDecryptsTo(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: currentKey,
        envelope: Map<String, dynamic>.from(
          jsonDecode(replacementChild.envelopeJson) as Map,
        ),
        expectedName: 'offline edit two',
      );

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'recovers a stale multi-record batch by probing and re-signing each independent Host once',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium)
        ..staleCode = 'KEY_EPOCH_OUTDATED';
      final oldRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: oldKey,
        oldKey: oldKey,
        keyEpoch: _oldEpoch,
        membershipVersion: _oldMembership,
      );

      final originalByRecord = <String, Map<String, Object?>>{};
      for (final record in const [
        (id: _recordId, name: 'offline Host one'),
        (id: _secondRecordId, name: 'offline Host two'),
      ]) {
        originalByRecord[record.id] = await oldRepository.saveRecord(
          recordId: record.id,
          operation: 'create',
          plaintext: {'id': record.id, 'type': 'host', 'name': record.name},
        );
      }
      final originalsByOpId = {
        for (final envelope in originalByRecord.values)
          (envelope['header'] as Map<String, dynamic>)['op_id'] as String:
              envelope,
      };
      await database.markAttempted(originalsByOpId.keys.toList());
      api.staleBatchOperationIds.addAll(originalsByOpId.keys);

      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      currentRepository.authorizeStaleOutboxRewrapAfterMembershipRefresh();
      final result = await currentRepository.synchronize();

      expect(result.status, 'idle');
      expect(api.pushRequests, hasLength(4));
      expect(
        api.pushRequests.map((request) => _requestEnvelopes(request).length),
        [2, 1, 1, 2],
      );
      expect(api.ledgerEntryCountBeforePush, [0, 0, 0, 0]);

      final initialStaleBatch = _requestEnvelopes(api.pushRequests[0]);
      final initialStaleByOpId = {
        for (final envelope in initialStaleBatch)
          (envelope['header'] as Map<String, dynamic>)['op_id'] as String:
              envelope,
      };
      expect(initialStaleByOpId.keys.toSet(), originalsByOpId.keys.toSet());
      for (final entry in originalsByOpId.entries) {
        expect(
          jsonEncode(initialStaleByOpId[entry.key]),
          jsonEncode(entry.value),
        );
        final header = entry.value['header'] as Map<String, dynamic>;
        expect(header['key_epoch'], _oldEpoch);
        expect(header['membership_version'], _oldMembership);
      }

      final individualStaleProbes = api.pushRequests
          .skip(1)
          .take(2)
          .map(_requestEnvelopes)
          .toList(growable: false);
      expect(individualStaleProbes.every((probe) => probe.length == 1), isTrue);
      final individuallyProbedIds = <String>{};
      for (final probe in individualStaleProbes) {
        final envelope = probe.single;
        final header = envelope['header'] as Map<String, dynamic>;
        final opId = header['op_id'] as String;
        expect(individuallyProbedIds.add(opId), isTrue);
        expect(originalsByOpId.containsKey(opId), isTrue);
        expect(jsonEncode(envelope), jsonEncode(originalsByOpId[opId]));
      }
      expect(individuallyProbedIds, originalsByOpId.keys.toSet());
      expect(api.staleRejectedOperationBatches, hasLength(3));
      expect(
        api.staleRejectedOperationBatches.first.toSet(),
        originalsByOpId.keys.toSet(),
      );
      expect(
        api.staleRejectedOperationBatches.skip(1).expand((ids) => ids).toSet(),
        originalsByOpId.keys.toSet(),
      );
      expect(api.acceptedOperations, hasLength(2));

      final replacementByRecord = <String, Map<String, Object?>>{};
      for (final envelope in _requestEnvelopes(api.pushRequests.last)) {
        final header = envelope['header'] as Map<String, dynamic>;
        final recordId = header['record_id'] as String;
        replacementByRecord[recordId] = envelope;
        final replacement = envelope['header'] as Map<String, dynamic>;
        final original = originalByRecord[recordId]!;
        final originalHeader = original['header'] as Map<String, dynamic>;
        expect(replacement['op_id'], isNot(originalHeader['op_id']));
        expect(
          replacement['revision_id'],
          isNot(originalHeader['revision_id']),
        );
        expect(replacement['key_epoch'], _currentEpoch);
        expect(replacement['membership_version'], _currentMembership);
        expect(envelope['ciphertext'], isNot(original['ciphertext']));
      }
      expect(replacementByRecord.keys.toSet(), originalByRecord.keys.toSet());
      expect(
        api.acceptedOperations
            .map((operation) => operation['recordId'])
            .toSet(),
        originalByRecord.keys.toSet(),
      );
      expect(
        api.acceptedOperations.map((operation) => operation['opId']).toSet(),
        replacementByRecord.values
            .map((envelope) => (envelope['header'] as Map)['op_id'])
            .toSet(),
      );
      for (final record in const [
        (id: _recordId, name: 'offline Host one'),
        (id: _secondRecordId, name: 'offline Host two'),
      ]) {
        final acceptedForRecord = api.acceptedOperations
            .where((operation) => operation['recordId'] == record.id)
            .toList(growable: false);
        expect(acceptedForRecord, hasLength(1));
        expect(
          acceptedForRecord.single['revisionId'],
          (replacementByRecord[record.id]!['header'] as Map)['revision_id'],
        );
        await _expectDecryptsTo(
          crypto: VaultCrypto(sodium),
          identity: identity,
          key: currentKey,
          envelope: Map<String, dynamic>.from(replacementByRecord[record.id]!),
          recordId: record.id,
          expectedName: record.name,
        );
      }

      final superseded = await database.supersededOperations(_vaultId);
      expect(superseded, hasLength(2));
      final supersededByOpId = {for (final row in superseded) row.opId: row};
      for (final entry in originalsByOpId.entries) {
        final row = supersededByOpId[entry.key]!;
        expect(row.status, 'superseded');
        expect(row.envelopeJson, jsonEncode(entry.value));
        expect(row.attemptCount, greaterThanOrEqualTo(2));
      }
      expect(await database.allPendingOperations(_vaultId), isEmpty);
      expect(await database.countPending(_vaultId), 0);

      final cachedByRecord = {
        for (final record in await database.cachedEnvelopes(_vaultId))
          record.recordId: record,
      };
      expect(cachedByRecord.keys.toSet(), originalByRecord.keys.toSet());
      for (final record in const [
        (id: _recordId, name: 'offline Host one'),
        (id: _secondRecordId, name: 'offline Host two'),
      ]) {
        final cached = cachedByRecord[record.id]!;
        final accepted = api.acceptedOperations.singleWhere(
          (operation) => operation['recordId'] == record.id,
        );
        expect(cached.commitSeq, accepted['commitSeq']);
        final cachedEnvelope =
            jsonDecode(cached.envelopeJson) as Map<String, dynamic>;
        expect(cached.envelopeJson, jsonEncode(accepted['envelope']));
        expect(
          (cachedEnvelope['header'] as Map<String, dynamic>)['key_epoch'],
          _currentEpoch,
        );
        await _expectDecryptsTo(
          crypto: VaultCrypto(sodium),
          identity: identity,
          key: currentKey,
          envelope: cachedEnvelope,
          recordId: record.id,
          expectedName: record.name,
        );
      }

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'routes a sent outbox branch to the existing conflict flow when the pre-push feed shows its base changed',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium)
        ..changedBaseKey = currentKey;
      final base = await _encrypt(
        crypto: VaultCrypto(sodium),
        identity: identity,
        key: oldKey,
        seq: '1',
        operation: 'create',
        baseRevisionId: null,
        name: 'committed base',
        epoch: _oldEpoch,
        membership: _oldMembership,
      );
      final baseHeader = base['header'] as Map<String, dynamic>;
      api.changedBaseBaseRevisionId = baseHeader['revision_id'] as String;
      await database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: baseHeader['revision_id'] as String,
        envelope: base,
        commitSeq: '1',
        deleted: false,
        instanceId: _generation,
        serverSpaceId: _serverSpaceId,
      );
      await database
          .into(database.deviceSequences)
          .insert(
            DeviceSequencesCompanion.insert(
              deviceId: identity.deviceId,
              nextSequence: const Value(2),
            ),
          );
      final oldRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: oldKey,
        oldKey: oldKey,
        keyEpoch: _oldEpoch,
        membershipVersion: _oldMembership,
      );
      final original = await oldRepository.saveRecord(
        recordId: _recordId,
        baseRevisionId: baseHeader['revision_id'] as String,
        operation: 'update',
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': 'offline edit',
        },
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      await database.markAttempted([originalHeader['op_id'] as String]);
      api.staleOperationId = originalHeader['op_id'] as String;

      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      await api.queueChangedBase();
      final result = await currentRepository.synchronize();

      expect(result.status, 'idle');
      expect(api.pushRequests, isEmpty);
      expect(api.conflictUploadRequests, hasLength(1));
      expect(api.conflictUploadRequests.single['envelope'], original);

      final oldAttempt = (await database.allPendingOperations(
        _vaultId,
      )).singleWhere((operation) => operation.opId == originalHeader['op_id']);
      expect(oldAttempt.status, 'conflict');
      expect(oldAttempt.envelopeJson, jsonEncode(original));
      final conflicts = await database.openConflicts(_vaultId);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.branchEnvelopeJson, jsonEncode(original));
      final remote = jsonDecode(conflicts.single.remoteEnvelopeJson) as Map;
      expect(
        (remote['header'] as Map)['revision_id'],
        api.changedBaseRevisionId,
      );

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'does not re-sign a stale rejected operation if write access is revoked before replacement',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium);
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      late final SyncRepository currentRepository;
      api.onStaleReject = () {
        currentRepository.canWrite = false;
      };
      currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      await expectLater(
        currentRepository.synchronize(),
        throwsA(isA<StateError>()),
      );
      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), original);
      final history = await database.allPendingOperations(_vaultId);
      expect(history, hasLength(1));
      expect(history.single.opId, originalHeader['op_id']);
      expect(history.single.envelopeJson, jsonEncode(original));
      expect(history.single.status, 'sent');

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'fails closed without the old epoch key and leaves the sent envelope untouched',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium);
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
        includeOldKey: false,
      );
      currentRepository.authorizeStaleOutboxRewrapAfterMembershipRefresh();

      await expectLater(
        currentRepository.synchronize(),
        throwsA(isA<StateError>()),
      );

      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), original);
      final active = await database.allPendingOperations(_vaultId);
      expect(active, hasLength(1));
      expect(active.single.opId, originalHeader['op_id']);
      expect(active.single.status, 'sent');
      expect(active.single.envelopeJson, jsonEncode(original));
      expect(await database.supersededOperations(_vaultId), isEmpty);
      expect(await database.countPending(_vaultId), 1);
      expect(
        (await database.cachedEnvelopes(_vaultId)).single.envelopeJson,
        jsonEncode(original),
      );

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'fails closed on an invalid old signature without altering pending or cached bytes',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium);
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      final tamperedSignature = decodeBase64Url(
        original['signature'] as String,
      );
      tamperedSignature[0] ^= 1;
      final tamperedEnvelope = Map<String, Object?>.from(original)
        ..['signature'] = encodeBase64Url(tamperedSignature);
      final tamperedJson = jsonEncode(tamperedEnvelope);
      final opId = originalHeader['op_id'] as String;
      await (database.update(database.pendingOperations)
            ..where((row) => row.opId.equals(opId)))
          .write(PendingOperationsCompanion(envelopeJson: Value(tamperedJson)));
      await (database.update(database.encryptedRecords)..where(
            (row) =>
                row.vaultId.equals(_vaultId) & row.recordId.equals(_recordId),
          ))
          .write(EncryptedRecordsCompanion(envelopeJson: Value(tamperedJson)));

      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );
      currentRepository.authorizeStaleOutboxRewrapAfterMembershipRefresh();
      await expectLater(
        currentRepository.synchronize(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Record signature is invalid'),
          ),
        ),
      );

      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), tamperedEnvelope);
      final active = await database.allPendingOperations(_vaultId);
      expect(active, hasLength(1));
      expect(active.single.opId, opId);
      expect(active.single.status, 'sent');
      expect(active.single.envelopeJson, tamperedJson);
      expect(await database.supersededOperations(_vaultId), isEmpty);
      expect(
        (await database.cachedEnvelopes(_vaultId)).single.envelopeJson,
        tamperedJson,
      );

      await database.close();
      api.close();
      identity.dispose();
      tamperedSignature.fillRange(0, tamperedSignature.length, 0);
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );

  test(
    'does not re-sign when the original push reports revoked device access',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final oldKey = sodium.randombytes.buf(32);
      final currentKey = sodium.randombytes.buf(32);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _StaleOutboxApi(identity, sodium)..revokeOnFirstPush = true;
      final original = await _saveSentCreate(
        database: database,
        api: api,
        identity: identity,
        key: oldKey,
      );
      final originalHeader = original['header'] as Map<String, dynamic>;
      final currentRepository = _repository(
        api: api,
        database: database,
        identity: identity,
        currentKey: currentKey,
        oldKey: oldKey,
      );

      await expectLater(
        currentRepository.synchronize(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'DEVICE_REVOKED',
          ),
        ),
      );

      expect(api.pushRequests, hasLength(1));
      expect(_onlyEnvelope(api.pushRequests.single), original);
      final history = await database.allPendingOperations(_vaultId);
      expect(history, hasLength(1));
      expect(history.single.opId, originalHeader['op_id']);
      expect(history.single.envelopeJson, jsonEncode(original));
      expect(history.single.status, 'sent');

      await database.close();
      api.close();
      identity.dispose();
      oldKey.fillRange(0, oldKey.length, 0);
      currentKey.fillRange(0, currentKey.length, 0);
    },
  );
}

Future<Map<String, Object?>> _saveSentCreate({
  required ClientDatabase database,
  required _StaleOutboxApi api,
  required DeviceIdentity identity,
  required Uint8List key,
}) async {
  final repository = _repository(
    api: api,
    database: database,
    identity: identity,
    currentKey: key,
    oldKey: key,
    keyEpoch: _oldEpoch,
    membershipVersion: _oldMembership,
  );
  final envelope = await repository.saveRecord(
    recordId: _recordId,
    plaintext: const {'id': _recordId, 'type': 'host', 'name': 'offline draft'},
    operation: 'create',
  );
  await database.markAttempted([
    (envelope['header'] as Map<String, dynamic>)['op_id'] as String,
  ]);
  return envelope;
}

SyncRepository _repository({
  required _StaleOutboxApi api,
  required ClientDatabase database,
  required DeviceIdentity identity,
  required Uint8List currentKey,
  required Uint8List oldKey,
  String keyEpoch = _currentEpoch,
  String membershipVersion = _currentMembership,
  bool canWrite = true,
  bool includeOldKey = true,
}) => SyncRepository(
  api: api,
  database: database,
  crypto: VaultCrypto(api.sodium),
  identity: identity,
  serverSpaceId: _serverSpaceId,
  instanceId: _generation,
  accountId: '66666666-6666-4666-8666-666666666666',
  vaultId: _vaultId,
  keyEpoch: keyEpoch,
  membershipVersion: membershipVersion,
  serverGeneration: _generation,
  vaultKey: Uint8List.fromList(currentKey),
  vaultKeysByVersion: {if (includeOldKey) '$_oldEpoch:$_oldMembership': oldKey},
  canWrite: canWrite,
);

Future<Map<String, Object?>> _encrypt({
  required VaultCrypto crypto,
  required DeviceIdentity identity,
  required Uint8List key,
  required String seq,
  String recordId = _recordId,
  required String operation,
  required String? baseRevisionId,
  required String name,
  required String epoch,
  required String membership,
}) => crypto.encryptRecord(
  vaultKey: key,
  serverSpaceId: _serverSpaceId,
  vaultId: _vaultId,
  recordId: recordId,
  baseRevisionId: baseRevisionId,
  deviceId: identity.deviceId,
  deviceSequence: seq,
  keyEpoch: epoch,
  membershipVersion: membership,
  operation: operation,
  plaintext: {'id': recordId, 'type': 'host', 'name': name},
  identity: identity,
);

Future<void> _expectDecryptsTo({
  required VaultCrypto crypto,
  required DeviceIdentity identity,
  required Uint8List key,
  required Map<String, dynamic> envelope,
  String recordId = _recordId,
  required String expectedName,
}) async {
  final plaintext = await crypto.decryptRecord(
    vaultKey: key,
    envelope: envelope,
    authorPublicKey: identity.signing.publicKey,
  );
  expect(plaintext['id'], recordId);
  expect(plaintext['type'], 'host');
  expect(plaintext['name'], expectedName);
}

Map<String, dynamic> _onlyEnvelope(Map<String, Object?> request) =>
    _requestEnvelopes(request).single;

List<Map<String, dynamic>> _requestEnvelopes(Map<String, Object?> request) =>
    (request['operations'] as List<dynamic>)
        .map((envelope) => Map<String, dynamic>.from(envelope as Map))
        .toList(growable: false);

class _StaleOutboxApi extends ApiClient {
  _StaleOutboxApi(this.identity, this.sodium)
    : super(baseUrl: 'https://stale-outbox-test.example');

  final DeviceIdentity identity;
  final SodiumSumo sodium;
  final List<Map<String, Object?>> pushRequests = [];
  final List<int> ledgerEntryCountBeforePush = [];
  final List<List<String>> staleRejectedOperationBatches = [];
  final List<Map<String, Object?>> acceptedOperations = [];
  final List<Map<String, Object?>> conflictUploadRequests = [];
  final List<Map<String, dynamic>> _queuedChanges = [];
  final Set<String> staleBatchOperationIds = {};
  String staleCode = 'KEY_EPOCH_OUTDATED';
  String? staleOperationId;
  bool holdFreshOperation = false;
  bool revokeOnFirstPush = false;
  void Function()? onStaleReject;
  Uint8List? changedBaseKey;
  String? changedBaseRevisionId;
  String? changedBaseBaseRevisionId;
  bool _revoked = false;
  int _staleAttempts = 0;
  int _commitSeq = 1;

  @override
  Future<InstanceInfo> fetchInstance() async => throw const ApiException(
    statusCode: 503,
    code: 'SERVER_UNAVAILABLE',
    message: 'Snapshot recovery fixture is unavailable.',
  );

  Future<void> queueChangedBase() async {
    _queuedChanges.add(await _changedBaseEvent());
  }

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      devices();

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    final events = List<Map<String, dynamic>>.from(_queuedChanges);
    _queuedChanges.clear();
    return SyncPage(
      events: events,
      nextCursor: events.isEmpty ? cursor : 'stale-recovery-cursor',
      hasMore: false,
      serverGeneration: _generation,
    );
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
    serverGeneration: serverGeneration ?? _generation,
  );

  @override
  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    conflictUploadRequests.add({'vault_id': vaultId, ...body});
    return {
      'conflict_id': '55555555-5555-4555-8555-555555555555',
      'status': 'stored',
    };
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    final request = Map<String, Object?>.from(batch);
    pushRequests.add(request);
    ledgerEntryCountBeforePush.add(acceptedOperations.length);
    final envelopes = _requestEnvelopes(request);
    final headers = envelopes
        .map((envelope) => Map<String, dynamic>.from(envelope['header'] as Map))
        .toList(growable: false);
    final opIds = headers.map((header) => header['op_id'] as String).toList();
    final header = headers.first;
    final opId = header['op_id'] as String;
    staleOperationId ??= opId;

    if (revokeOnFirstPush && !_revoked) {
      _revoked = true;
      throw const ApiException(
        statusCode: 403,
        code: 'DEVICE_REVOKED',
        message: 'The device was revoked.',
      );
    }

    if (!_revoked && opIds.any(staleBatchOperationIds.contains)) {
      staleRejectedOperationBatches.add(List<String>.from(opIds));
      throw ApiException(
        statusCode: 409,
        code: staleCode,
        message: 'The encrypted operation batch uses a stale Vault version.',
      );
    }

    if (!_revoked && opId == staleOperationId && _staleAttempts < 2) {
      _staleAttempts++;
      onStaleReject?.call();
      throw ApiException(
        statusCode: 409,
        code: staleCode,
        message: 'The encrypted operation uses a stale Vault version.',
      );
    }
    if (_revoked) {
      throw const ApiException(
        statusCode: 403,
        code: 'DEVICE_REVOKED',
        message: 'The device was revoked.',
      );
    }
    if (holdFreshOperation) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Hold the fresh operation in the outbox for assertions.',
      );
    }

    final results = <Map<String, Object?>>[];
    for (var index = 0; index < envelopes.length; index++) {
      final acceptedHeader = headers[index];
      final acceptedOpId = acceptedHeader['op_id'] as String;
      final revisionId = acceptedHeader['revision_id'] as String;
      final commitSeq = (++_commitSeq).toString();
      acceptedOperations.add({
        'opId': acceptedOpId,
        'recordId': acceptedHeader['record_id'],
        'revisionId': revisionId,
        'commitSeq': commitSeq,
        'keyEpoch': acceptedHeader['key_epoch'],
        'membershipVersion': acceptedHeader['membership_version'],
        'envelope': envelopes[index],
      });
      results.add({
        'op_id': acceptedOpId,
        'revision_id': revisionId,
        'commit_seq': commitSeq,
        'already_committed': false,
      });
    }
    return {'batch_id': batch['batch_id'], 'results': results};
  }

  Future<Map<String, dynamic>> _changedBaseEvent() async {
    // The event uses a valid current-version signature so the regular pull and
    // conflict path can authenticate it before acting on the stale outbox.
    final remote = await _encrypt(
      crypto: VaultCrypto(sodium),
      identity: identity,
      key: changedBaseKey!,
      seq: '50',
      operation: 'update',
      baseRevisionId: changedBaseBaseRevisionId,
      name: 'concurrent server head',
      epoch: _currentEpoch,
      membership: _currentMembership,
    );
    final header = remote['header'] as Map<String, dynamic>;
    changedBaseRevisionId = header['revision_id'] as String;
    return {
      'commit_seq': '2',
      'event_type': header['operation'],
      'record_id': header['record_id'],
      'revision_id': header['revision_id'],
      'envelope': remote,
    };
  }
}
