import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _opId = '44444444-4444-4444-8444-444444444444';
const _revisionId = '55555555-5555-4555-8555-555555555555';

void main() {
  test(
    'a returned local edit restores its encrypted row and outbox after reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-local-edit-durability-',
      );
      final file = File('${directory.path}/client.sqlite');
      var database = ClientDatabase.forTesting(NativeDatabase(file));
      const envelope = {
        'header': {
          'op_id': _opId,
          'revision_id': _revisionId,
          'record_id': _recordId,
        },
        'nonce': 'opaque-test-value',
        'ciphertext': 'opaque-test-value',
        'signature': 'opaque-test-value',
      };
      final envelopeJson = jsonEncode(envelope);

      try {
        await database.ensureReady();
        await database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: null,
          envelope: envelope,
          deleted: false,
        );

        // Saving has returned before closing the file-backed connection. The
        // rows must therefore be recoverable without relying on process memory.
        expect(await database.countPending(_vaultId), 1);
        await database.close();
        database = ClientDatabase.forTesting(NativeDatabase(file));
        await database.ensureReady();

        final cached = await database.cachedEnvelope(_vaultId, _recordId);
        expect(cached?.envelopeJson, envelopeJson);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.opId, _opId);
        expect(pending.single.envelopeJson, envelopeJson);
        expect(pending.single.status, 'queued');
        expect(pending.single.attemptCount, 0);
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'flushes the encrypted record and outbox transaction before returning',
    () async {
      final interceptor = _PersistenceBarrierInterceptor();
      final database = ClientDatabase.forTesting(
        NativeDatabase.memory().interceptWith(interceptor),
      );
      addTearDown(database.close);

      await database.ensureReady();
      var operationCompleted = false;
      final operation = database
          .putLocalOperation(
            vaultId: _vaultId,
            recordId: _recordId,
            baseRevisionId: null,
            envelope: const {
              'header': {
                'op_id': _opId,
                'revision_id': _revisionId,
                'record_id': _recordId,
              },
              'nonce': 'opaque-test-value',
              'ciphertext': 'opaque-test-value',
              'signature': 'opaque-test-value',
            },
            deleted: false,
          )
          .then((_) => operationCompleted = true);

      await interceptor.barrierEntered.future.timeout(
        const Duration(seconds: 5),
      );
      expect(operationCompleted, isFalse);
      interceptor.releaseBarrier.complete();
      await operation;

      expect(interceptor.persistenceBarrierCount, 1);
      expect(await database.countPending(_vaultId), 1);
      final recordCount = await database
          .customSelect(
            'SELECT COUNT(*) AS count FROM encrypted_records WHERE vault_id = ?',
            variables: [Variable.withString(_vaultId)],
          )
          .getSingle();
      expect(recordCount.read<int>('count'), 1);
    },
  );

  test(
    'propagates an error from the post-transaction persistence barrier',
    () async {
      final interceptor = _PersistenceBarrierInterceptor()..failBarrier = true;
      final database = ClientDatabase.forTesting(
        NativeDatabase.memory().interceptWith(interceptor),
      );
      addTearDown(database.close);

      await database.ensureReady();
      final operation = database.putLocalOperation(
        vaultId: _vaultId,
        recordId: _recordId,
        baseRevisionId: null,
        envelope: const {
          'header': {
            'op_id': _opId,
            'revision_id': _revisionId,
            'record_id': _recordId,
          },
          'nonce': 'opaque-test-value',
          'ciphertext': 'opaque-test-value',
          'signature': 'opaque-test-value',
        },
        deleted: false,
      );

      await interceptor.barrierEntered.future.timeout(
        const Duration(seconds: 5),
      );
      interceptor.releaseBarrier.complete();

      await expectLater(
        operation,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected persistence barrier failure',
          ),
        ),
      );
      expect(interceptor.persistenceBarrierCount, 1);
    },
  );
}

class _PersistenceBarrierInterceptor extends QueryInterceptor {
  final barrierEntered = Completer<void>();
  final releaseBarrier = Completer<void>();
  var persistenceBarrierCount = 0;
  var failBarrier = false;

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.trim().toUpperCase() == 'PRAGMA DATA_VERSION') {
      persistenceBarrierCount += 1;
      barrierEntered.complete();
      await releaseBarrier.future;
      if (failBarrier) throw StateError('injected persistence barrier failure');
    }
    await super.runCustom(executor, statement, args);
  }
}
