import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _otherVaultId = '33333333-3333-4333-8333-333333333333';
const _recordId = '44444444-4444-4444-8444-444444444444';
const _otherRecordId = '55555555-5555-4555-8555-555555555555';
const _plaintextSentinel = 'MIGRATION-PLAINTEXT-MUST-STAY-ENCRYPTED';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late VaultCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
  });

  test(
    'persists exact create atomically, replays idempotently, and advances the sequence floor',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final envelope = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '7',
        );

        expect(
          await database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: envelope,
          ),
          ExactCreateOperationResult.created,
        );
        expect(
          await database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: envelope,
          ),
          ExactCreateOperationResult.pending,
        );

        final header = envelope['header']! as Map<String, Object?>;
        final operations = await database.allPendingOperations(_vaultId);
        final cached = await database.cachedEnvelopes(_vaultId);
        expect(operations, hasLength(1));
        expect(operations.single.opId, header['op_id']);
        expect(operations.single.baseRevisionId, isNull);
        expect(operations.single.baseEnvelopeJson, isNull);
        expect(operations.single.envelopeJson, canonicalJson(envelope));
        expect(cached, hasLength(1));
        expect(cached.single.revisionId, header['revision_id']);
        expect(cached.single.commitSeq, isNull);
        expect(cached.single.envelopeJson, canonicalJson(envelope));
        expect(await database.deviceSequenceFloors(), {identity.deviceId: 8});
        expect(await database.nextDeviceSequence(identity.deviceId), '8');
        expect(
          jsonEncode([
            ...operations.map((row) => row.envelopeJson),
            ...cached.map((row) => row.envelopeJson),
          ]),
          isNot(contains(_plaintextSentinel)),
        );
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'does not compact or replace an existing queued local operation',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final queued = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '1',
        );
        final exact = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '2',
        );
        final queuedHeader = queued['header']! as Map<String, Object?>;
        await database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: null,
          envelope: queued,
          deleted: false,
        );

        await expectLater(
          database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: exact,
          ),
          throwsStateError,
        );

        final rows = await database.allPendingOperations(_vaultId);
        expect(rows, hasLength(1));
        expect(rows.single.opId, queuedHeader['op_id']);
        expect(rows.single.envelopeJson, jsonEncode(queued));
        expect(
          (await database.cachedEnvelopes(_vaultId)).single.envelopeJson,
          jsonEncode(queued),
        );
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test('does not move an already higher sequence floor backward', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final key = sodium.randombytes.buf(32);
    try {
      for (var index = 0; index < 12; index++) {
        await database.nextDeviceSequence(identity.deviceId);
      }
      final envelope = await _createEnvelope(
        crypto: crypto,
        key: key,
        identity: identity,
        sequence: '3',
        recordId: _otherRecordId,
      );
      expect(
        await database.putExactCreateOperation(
          vaultId: _vaultId,
          deviceId: identity.deviceId,
          envelope: envelope,
        ),
        ExactCreateOperationResult.created,
      );
      expect(await database.deviceSequenceFloors(), {identity.deviceId: 13});
      expect(await database.nextDeviceSequence(identity.deviceId), '13');
    } finally {
      await database.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
    }
  });

  test(
    'rejects changed ciphertext, changed header, and a competing record head',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final envelope = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '4',
        );
        await database.putExactCreateOperation(
          vaultId: _vaultId,
          deviceId: identity.deviceId,
          envelope: envelope,
        );

        final changedCiphertext = _copyEnvelope(envelope);
        final ciphertext = changedCiphertext['ciphertext']! as String;
        changedCiphertext['ciphertext'] =
            '${ciphertext.startsWith('A') ? 'B' : 'A'}${ciphertext.substring(1)}';
        await expectLater(
          database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: changedCiphertext,
          ),
          throwsStateError,
        );

        final changedHeader = _copyEnvelope(envelope);
        (changedHeader['header']! as Map<String, Object?>)['key_epoch'] = '2';
        await expectLater(
          database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: changedHeader,
          ),
          throwsStateError,
        );

        final competing = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '5',
        );
        await expectLater(
          database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: competing,
          ),
          throwsStateError,
        );
        expect(await database.countPending(_vaultId), 1);
        expect(
          (await database.cachedEnvelopes(_vaultId)).single.envelopeJson,
          canonicalJson(envelope),
        );
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'committed exact replay is idempotent and remains a confirmed cache head',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final envelope = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '11',
        );
        final header = envelope['header']! as Map<String, Object?>;
        await database.putExactCreateOperation(
          vaultId: _vaultId,
          deviceId: identity.deviceId,
          envelope: envelope,
        );
        await database.markCommitted(
          opId: header['op_id']! as String,
          commitSeq: '23',
        );

        expect(
          await database.putExactCreateOperation(
            vaultId: _vaultId,
            deviceId: identity.deviceId,
            envelope: envelope,
          ),
          ExactCreateOperationResult.committed,
        );
        expect(await database.countPending(_vaultId), 0);
        expect(
          (await database.cachedEnvelopes(_vaultId)).single.commitSeq,
          '23',
        );
        expect(await database.deviceSequenceFloors(), {identity.deviceId: 12});
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'validates exact envelope fields, create semantics, IDs, and sequence',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final valid = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '1',
        );
        final badCases = <Map<String, Object?>>[];

        final extraEnvelopeField = _copyEnvelope(valid)..['unexpected'] = 'x';
        badCases.add(extraEnvelopeField);
        final missingCiphertext = _copyEnvelope(valid)..remove('ciphertext');
        badCases.add(missingCiphertext);
        final extraHeaderField = _copyEnvelope(valid);
        (extraHeaderField['header']! as Map<String, Object?>)['unexpected'] =
            'x';
        badCases.add(extraHeaderField);
        final wrongOperation = _copyEnvelope(valid);
        (wrongOperation['header']! as Map<String, Object?>)['operation'] =
            'update';
        badCases.add(wrongOperation);
        final wrongBase = _copyEnvelope(valid);
        (wrongBase['header']! as Map<String, Object?>)['base_revision_id'] =
            _otherRecordId;
        badCases.add(wrongBase);
        final badRecordId = _copyEnvelope(valid);
        (badRecordId['header']! as Map<String, Object?>)['record_id'] = 'bad';
        badCases.add(badRecordId);
        final badRevisionId = _copyEnvelope(valid);
        (badRevisionId['header']! as Map<String, Object?>)['revision_id'] =
            'bad';
        badCases.add(badRevisionId);
        final badOperationId = _copyEnvelope(valid);
        (badOperationId['header']! as Map<String, Object?>)['op_id'] = 'bad';
        badCases.add(badOperationId);
        final nonCanonicalSequence = _copyEnvelope(valid);
        (nonCanonicalSequence['header']!
                as Map<String, Object?>)['device_seq'] =
            '01';
        badCases.add(nonCanonicalSequence);
        final outOfRangeSequence = _copyEnvelope(valid);
        (outOfRangeSequence['header']! as Map<String, Object?>)['device_seq'] =
            '9007199254739999';
        badCases.add(outOfRangeSequence);
        final wrongVault = _copyEnvelope(valid);
        (wrongVault['header']! as Map<String, Object?>)['vault_id'] =
            _otherVaultId;
        badCases.add(wrongVault);

        for (final candidate in badCases) {
          await expectLater(
            database.putExactCreateOperation(
              vaultId: _vaultId,
              deviceId: identity.deviceId,
              envelope: candidate,
            ),
            throwsFormatException,
          );
        }
        expect(await database.countPending(_vaultId), 0);
        expect(await database.cachedEnvelopes(_vaultId), isEmpty);
        expect(await database.deviceSequenceFloors(), isEmpty);
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'outbox fingerprint detects a same-count queued operation replacement',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      try {
        final first = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '21',
        );
        await database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: null,
          envelope: first,
          deleted: false,
        );
        final beforeReplacement = await database.pendingOutboxFingerprint(
          _vaultId,
        );
        final otherVaultFingerprint = await database.pendingOutboxFingerprint(
          _otherVaultId,
        );

        final replacement = await _createEnvelope(
          crypto: crypto,
          key: key,
          identity: identity,
          sequence: '22',
        );
        await database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: null,
          envelope: replacement,
          deleted: false,
        );

        expect(await database.countPending(_vaultId), 1);
        expect(
          await database.pendingOutboxFingerprint(_vaultId),
          isNot(beforeReplacement),
        );
        expect(
          await database.pendingOutboxFingerprint(_otherVaultId),
          otherVaultFingerprint,
        );
      } finally {
        await database.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );
}

Future<Map<String, Object?>> _createEnvelope({
  required VaultCrypto crypto,
  required Uint8List key,
  required DeviceIdentity identity,
  required String sequence,
  String recordId = _recordId,
}) => crypto.encryptRecord(
  vaultKey: key,
  serverSpaceId: _spaceId,
  vaultId: _vaultId,
  recordId: recordId,
  baseRevisionId: null,
  deviceId: identity.deviceId,
  deviceSequence: sequence,
  keyEpoch: '1',
  membershipVersion: '1',
  operation: 'create',
  plaintext: {
    'id': recordId,
    'type': 'host',
    'name': _plaintextSentinel,
    'address': '192.0.2.40',
  },
  identity: identity,
);

Map<String, Object?> _copyEnvelope(Map<String, Object?> source) => {
  ...source,
  'header': Map<String, Object?>.from(source['header']! as Map),
};
