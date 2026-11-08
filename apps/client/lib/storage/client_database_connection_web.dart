import 'dart:js_interop';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:web/web.dart' as web;

import 'database_quarantine.dart';
import 'web_storage_policy.dart';

final _sqlite3Wasm = Uri.parse('sqlite3.wasm');
final _driftWorker = Uri.parse('drift_worker.js');
final _quarantineChannel = web.BroadcastChannel(
  'atermius.database.quarantine.v1',
);
final Map<String, _WebDatabaseQuarantine> _databaseQuarantines = {};
var _quarantineChannelListening = false;

_WebDatabaseQuarantine _quarantineFor(String databaseName) {
  if (!_quarantineChannelListening) {
    _quarantineChannel.onmessage = (web.MessageEvent event) {
      final data = event.data;
      if (data == null || !data.typeofEquals('string')) return;
      final databaseName = (data as JSString).toDart;
      _databaseQuarantines
          .putIfAbsent(databaseName, () => _WebDatabaseQuarantine(databaseName))
          .quarantine(notifyPeers: false);
    }.toJS;
    _quarantineChannelListening = true;
  }
  return _databaseQuarantines.putIfAbsent(
    databaseName,
    () => _WebDatabaseQuarantine(databaseName),
  );
}

class _WebDatabaseQuarantine extends QueryInterceptor {
  _WebDatabaseQuarantine(this.databaseName);

  final String databaseName;
  var _isQuarantined = false;

  void quarantine({required bool notifyPeers}) {
    if (_isQuarantined) return;
    _isQuarantined = true;
    databaseQuarantineRegistry.quarantine(databaseName);
    if (notifyPeers) {
      _quarantineChannel.postMessage(databaseName.toJS);
    }
  }

  void _checkAvailable() {
    if (_isQuarantined ||
        databaseQuarantineRegistry.isQuarantined(databaseName)) {
      _isQuarantined = true;
      throw const DatabaseRecoveryRequiredException();
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _checkAvailable();
    return runWithDatabaseQuarantine(
      databaseName: databaseName,
      registry: databaseQuarantineRegistry,
      operation: operation,
      onQuarantine: () => quarantine(notifyPeers: true),
    );
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    _checkAvailable();
    return parent.beginTransaction();
  }

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    _checkAvailable();
    return parent.beginExclusive();
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _run(inner.send);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    // Drift automatically rolls a transaction back after a failed COMMIT.
    // Allow that cleanup request to reach the poisoned SharedWorker; it is
    // not an application read or mutation, and the worker's fail-closed path
    // handles both the failed commit and its follow-up rollback.
    return inner.rollback();
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      _run(() => executor.ensureOpen(user));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _run(() => executor.runBatched(statements));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(() => executor.runCustom(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(() => executor.runInsert(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(() => executor.runDelete(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(() => executor.runUpdate(statement, args));

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(() => executor.runSelect(statement, args));
}

Future<DatabaseConnection> openClientDatabaseConnection({
  required String name,
}) async {
  // Probe browser capabilities and existing storage without opening the vault
  // connection. Only after the allowlist passes do we request a DB connection.
  final probe = await WasmDatabase.probe(
    sqlite3Uri: _sqlite3Wasm,
    driftWorkerUri: _driftWorker,
    databaseName: name,
  );

  return openWithSafeDriftStorage(
    databaseName: name,
    availableImplementations: probe.availableStorages.map(
      (value) => value.name,
    ),
    existingDatabases: probe.existingDatabases.map(
      (value) => (value.$1.name, value.$2),
    ),
    open: (implementation) async {
      // This marker contains only the backend selected by Drift. Browser
      // acceptance tests use it to verify storage capability, never vault data.
      // ignore: avoid_print
      print('ATERMIUS_DRIFT_WEB_IMPLEMENTATION=$implementation');
      final connection = await probe.open(
        WasmStorageImplementation.values.byName(implementation),
        name,
      );
      return implementation == 'sharedIndexedDb'
          ? connection.interceptWith(_quarantineFor(name))
          : connection;
    },
  );
}
