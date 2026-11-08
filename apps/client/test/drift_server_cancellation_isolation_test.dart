import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/src/remote/protocol.dart' show StatementMethod;
import 'package:drift/src/remote/server_impl.dart';
import 'package:drift/src/runtime/cancellation_zone.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test(
    'cancellation request IDs are scoped to their communication channel',
    () async {
      final executor = _BlockingQueryExecutor();
      final server = ServerImplementation(executor, false, false);
      final firstClient = _ServerClient();
      final secondClient = _ServerClient();
      unawaited(server.serve(firstClient.serverChannel));
      unawaited(server.serve(secondClient.serverChannel));

      addTearDown(() async {
        await firstClient.close();
        await secondClient.close();
        await server.shutdown();
      });

      final firstQuery = firstClient.request(41, [
        3,
        StatementMethod.select.index,
        'select first',
        ['first'],
        null,
      ]);
      await executor.started['first']!.future.timeout(
        const Duration(seconds: 2),
      );

      final secondQuery = secondClient.request(41, [
        3,
        StatementMethod.select.index,
        'select second',
        ['second'],
        null,
      ]);
      await executor.started['second']!.future.timeout(
        const Duration(seconds: 2),
      );

      final cancelAck = firstClient.request(42, [12, 41]);
      await cancelAck.timeout(const Duration(seconds: 2));
      executor.release['first']!.complete();
      executor.release['second']!.complete();

      final firstResponse = await firstQuery.timeout(
        const Duration(seconds: 2),
      );
      final secondResponse = await secondQuery.timeout(
        const Duration(seconds: 2),
      );
      expect(firstResponse, isA<List<Object?>>());
      expect(
        (firstResponse as List<Object?>)[0],
        3,
        reason: 'only the first channel was cancelled',
      );
      expect(secondResponse, isA<List<Object?>>());
      expect(
        (secondResponse as List<Object?>)[0],
        1,
        reason: 'same numeric request ID on another channel must survive',
      );
    },
  );

  test(
    'failed IndexedDB commit releases the transaction lock on rollback',
    () async {
      final executor = _QuarantinedCommitExecutor();
      final server = ServerImplementation(executor, false, false);
      final writer = _ServerClient();
      final reader = _ServerClient();
      unawaited(server.serve(writer.serverChannel));
      unawaited(server.serve(reader.serverChannel));

      addTearDown(() async {
        await writer.close();
        await reader.close();
        await server.shutdown();
      });

      final beginResponse = await writer.request(1, [5, 0, null]);
      expect(beginResponse, isA<List<Object?>>());
      final transactionId =
          (beginResponse as List<Object?>)[2] as List<Object?>;
      expect(transactionId[0], 10);
      final executorId = transactionId[1] as int;

      final failedCommit = await writer.request(2, [5, 1, executorId]);
      expect((failedCommit as List<Object?>)[0], 2);
      expect(executor.rollbackCalls, 1);
      expect(executor.transactionLockReleased, isTrue);

      // The client automatically sends rollback after a failed commit. The
      // server must acknowledge it without running rollback a second time.
      final rollbackAck = await writer.request(3, [5, 2, executorId]);
      expect((rollbackAck as List<Object?>)[0], 1);
      expect(executor.rollbackCalls, 1);

      // Repeated rollback for an already completed transaction is also
      // acknowledged without retaining a poison tombstone or waiting forever.
      final repeatedRollbackAck = await writer.request(4, [5, 2, executorId]);
      expect((repeatedRollbackAck as List<Object?>)[0], 1);

      final readResponse = await reader
          .request(7, [
            3,
            StatementMethod.select.index,
            'select after failure',
            [],
            null,
          ])
          .timeout(const Duration(seconds: 2));
      expect((readResponse as List<Object?>)[0], 2);
      expect(
        readResponse[2].toString(),
        contains('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED'),
      );
    },
  );
}

class _ServerClient {
  final StreamChannelController<Object?> _controller =
      StreamChannelController<Object?>();
  final Map<int, Completer<Object?>> _pending = {};

  _ServerClient() {
    _controller.local.stream.listen((message) {
      if (message is List && message.length >= 2 && message[1] is int) {
        _pending.remove(message[1])?.complete(message);
      }
    });
  }

  StreamChannel<Object?> get serverChannel => _controller.foreign;

  Future<Object?> request(int requestId, List<Object?> payload) {
    final response = Completer<Object?>();
    _pending[requestId] = response;
    _controller.local.sink.add([0, requestId, payload]);
    return response.future;
  }

  Future<void> close() => _controller.local.sink.close();
}

class _BlockingQueryExecutor extends QueryExecutor {
  final Map<String, Completer<void>> started = {
    'first': Completer<void>(),
    'second': Completer<void>(),
  };
  final Map<String, Completer<void>> release = {
    'first': Completer<void>(),
    'second': Completer<void>(),
  };

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async {
    final label = args.single as String;
    started[label]!.complete();
    final cancelled = Completer<void>();
    doOnCancellation(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    await Future.any([release[label]!.future, cancelled.future]);
    checkIfCancelled();
    return [
      <String, Object?>{'result': label},
    ];
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => 0;

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {}

  @override
  Future<void> runBatched(BatchedStatements statements) async {}

  @override
  TransactionExecutor beginTransaction() =>
      throw UnsupportedError('Transactions are not used in this regression.');

  @override
  QueryExecutor beginExclusive() => throw UnsupportedError(
    'Exclusive access is not used in this regression.',
  );
}

class _QuarantinedCommitExecutor extends QueryExecutor {
  bool transactionLockReleased = false;
  int rollbackCalls = 0;
  final Completer<void> _transactionReleased = Completer<void>();

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async {
    if (!transactionLockReleased) await _transactionReleased.future;
    throw StateError('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED');
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => 0;

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {}

  @override
  Future<void> runBatched(BatchedStatements statements) async {}

  @override
  TransactionExecutor beginTransaction() => _FailedCommitTransaction(this);

  @override
  QueryExecutor beginExclusive() => throw UnsupportedError(
    'Exclusive access is not used in this regression.',
  );
}

class _FailedCommitTransaction extends TransactionExecutor {
  final _QuarantinedCommitExecutor parent;

  _FailedCommitTransaction(this.parent);

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  bool get supportsNestedTransactions => false;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => true;

  @override
  Future<void> send() async {
    throw StateError('ATERMIUS_INDEXEDDB_PERSISTENCE_FAILURE');
  }

  @override
  Future<void> rollback() async {
    parent.rollbackCalls += 1;
    parent.transactionLockReleased = true;
    parent._transactionReleased.complete();
    throw StateError('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED');
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async => [];

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => 0;

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {}

  @override
  Future<void> runBatched(BatchedStatements statements) async {}

  @override
  TransactionExecutor beginTransaction() =>
      throw UnsupportedError('Nested transactions are not used.');

  @override
  QueryExecutor beginExclusive() =>
      throw UnsupportedError('Exclusive access is not used.');
}
