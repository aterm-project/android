/// Web support for drift.
///
/// For more information about the components of this library and how to use
/// them, see https://drift.simonbinder.eu/web/.
/// Be aware that additional setup is necessary to use drift on the web, this
/// is explained in the documentation.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart'
    show DedicatedWorkerGlobalScope, SharedWorkerGlobalScope;

import 'backends.dart';
import 'src/sqlite3/database.dart';
import 'src/web/wasm_setup.dart';
import 'src/web/wasm_setup/dedicated_worker.dart';
import 'src/web/wasm_setup/shared_worker.dart';
import 'src/web/wasm_setup/types.dart';

export 'src/web/wasm_setup/types.dart';

/// An experimental, WebAssembly based implementation of a drift sqlite3
/// database.
///
/// Using this database requires adding a WebAssembly file for sqlite3 to your
/// app.
/// The [documentation](https://drift.simonbinder.eu/web/#drift-wasm) describes
/// how to obtain this file. A [working example](https://github.com/simolus3/drift/blob/04539882330d80519128fec1ceb120fb1623a831/examples/app/lib/database/connection/web.dart#L27-L36)
/// is also available in the drift repository.
class WasmDatabase extends DelegatedDatabase {
  WasmDatabase._(super.delegate, bool logStatements)
    : super(isSequential: true, logStatements: logStatements);

  /// Creates a wasm database at [path] in the virtual file system of the
  /// [sqlite3] module.
  /// If [fileSystem] provided, the data is guaranteed to be
  /// stored in the IndexedDB when the request is complete. Attention!
  /// Insert/update queries may be slower when this option enabled. If you want
  /// to insert more than one rows, be sure you run in a transaction if
  /// possible.
  factory WasmDatabase({
    required CommonSqlite3 sqlite3,
    required String path,
    WasmDatabaseSetup? setup,
    IndexedDbFileSystem? fileSystem,
    bool logStatements = false,
    bool enableMigrations = true,
    bool cachePreparedStatements = true,
  }) {
    return WasmDatabase._(
      _WasmDelegate(
        sqlite3,
        path,
        setup,
        fileSystem,
        cachePreparedStatements: cachePreparedStatements,
        enableMigrations: enableMigrations,
      ),
      logStatements,
    );
  }

  /// Creates an in-memory database in the loaded [sqlite3] database.
  ///
  /// If an in-memory database is all you need, it can be created more easily
  /// than going through the path with [open]. In particular, you probably don't
  /// need a web worker hosting the database.
  ///
  /// To create an in-memory database without workers, one can use:
  ///
  /// ```dart
  /// final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('/sqlite3.wasm'));
  /// sqlite3.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
  ///
  /// WasmDatabase.inMemory(sqlite3);
  /// ```
  factory WasmDatabase.inMemory(
    CommonSqlite3 sqlite3, {
    WasmDatabaseSetup? setup,
    bool logStatements = false,
    bool cachePreparedStatements = true,
  }) {
    return WasmDatabase._(
      _WasmDelegate(
        sqlite3,
        null,
        setup,
        null,
        cachePreparedStatements: cachePreparedStatements,
      ),
      logStatements,
    );
  }

  /// Creates a drift executor for an opened [database] from the `sqlite3`
  /// package.
  ///
  /// When the [closeUnderlyingOnClose] argument is set (which is the default),
  /// calling [QueryExecutor.close] on the returned [WasmDatabase] will also
  /// [CommonDatabase.close] the [database] passed to this constructor.
  ///
  /// Using [WasmDatabase.opened] may be useful when you want to use the same
  /// underlying [CommonDatabase] in multiple drift connections. Drift uses this
  /// internally when running [integration tests for migrations](https://drift.simonbinder.eu/docs/advanced-features/migrations/#verifying-migrations).
  factory WasmDatabase.opened(
    CommonDatabase database, {
    bool logStatements = false,
    WasmDatabaseSetup? setup,
    bool closeUnderlyingOnClose = true,
    bool enableMigrations = true,
    bool cachePreparedStatements = true,
  }) {
    return WasmDatabase._(
      _WasmDelegate.opened(
        database,
        setup,
        closeUnderlyingOnClose,
        cachePreparedStatements,
        enableMigrations,
      ),
      logStatements,
    );
  }

  /// Opens a database on the web.
  ///
  /// Drift will detect features supported by the current browser and picks an
  /// appropriate implementation to store data based on those results.
  ///
  /// Using this API requires two additional file that you need to copy into the
  /// `web/` folder of your Flutter or Dart application: A `sqlite3.wasm` file,
  /// which you can [get here](https://github.com/simolus3/drift/releases),
  /// and a drift worker, which you can [get here](https://drift.simonbinder.eu/web/#worker).
  ///
  /// [localSetup] will be called to initialize the database only if the
  /// database will be opened directly in this JavaScript context. It is likely
  /// that the database will actually be opened in a web worker, with drift
  /// using communication mechanisms to access the database. As there is no way
  /// to send the database over to the main context, [localSetup] would not be
  /// called in that case. Instead, you'd have to compile a custom drift worker
  /// with a setup function - see [workerMainForOpen] for additional information.
  ///
  /// When [enableMigrations] is set to `false`, drift will not check the
  /// `user_version` pragma when opening the database or run migrations.
  ///
  /// If [moveExistingIndexedDbToOpfs] is enabled (it is currently disabled by
  /// default), drift will attempt to move existing databases from IndexedDB to
  /// OPFS. This may be useful if previous versions of browsers or your app
  /// didn't support OPFS.
  ///
  /// For more detailed information, see https://drift.simonbinder.eu/web.
  static Future<WasmDatabaseResult> open({
    required String databaseName,
    required Uri sqlite3Uri,
    required Uri driftWorkerUri,
    FutureOr<Uint8List?> Function()? initializeDatabase,
    WasmDatabaseSetup? localSetup,
    bool moveExistingIndexedDbToOpfs = false,
    bool enableMigrations = true,
  }) async {
    final probed = await probe(
      sqlite3Uri: sqlite3Uri,
      driftWorkerUri: driftWorkerUri,
      databaseName: databaseName,
    );

    // If we have an existing database in storage, we want to keep using that
    // format to avoid data loss (e.g. after a browser update that enables a
    // otherwise preferred storage implementation).
    final availableImplementations = probed.availableStorages.toList();
    // Enum values are ordered by preferrability, so just pick the best option.
    availableImplementations.sortBy<num>((e) => e.index);
    var selectedImplementation =
        availableImplementations.firstOrNull ??
        WasmStorageImplementation.inMemory;

    // Check if there is an existing DB and restrict implementations to its storage.
    final currentDb = _selectExistingDatabase(
      databaseName,
      availableImplementations,
      probed.existingDatabases,
    );

    // If we have an existing database, we need to use its storage API instead
    // of starting from scratch.
    if (currentDb != null && currentDb != selectedImplementation.storageApi) {
      // ... except if we want to move from IndexedDB to OPFS
      var didMove = false;
      if (moveExistingIndexedDbToOpfs &&
          currentDb == WebStorageApi.indexedDb &&
          selectedImplementation.storageApi == WebStorageApi.opfs) {
        try {
          await probed.moveFromIndexedDBToOpfs(databaseName);
          didMove = true;
        } catch (e) {
          // Ok, we'll keep using the old database then.
        }
      }

      if (!didMove) {
        selectedImplementation = availableImplementations.firstWhere(
          (e) => e.storageApi == currentDb,
        );
      }
    }

    final connection = await probed.open(
      selectedImplementation,
      databaseName,
      localSetup: localSetup,
      initializeDatabase: initializeDatabase,
      enableMigrations: enableMigrations,
    );

    return WasmDatabaseResult(
      connection,
      selectedImplementation,
      probed.missingFeatures,
    );
  }

  static WebStorageApi? _selectExistingDatabase(
    String databaseName,
    List<WasmStorageImplementation> available,
    List<ExistingDatabase> existingDatabases,
  ) {
    for (final (location, name) in existingDatabases) {
      if (name != databaseName) continue;

      final implementationsForStorage = switch (location) {
        WebStorageApi.indexedDb => const [
          WasmStorageImplementation.sharedIndexedDb,
          WasmStorageImplementation.unsafeIndexedDb,
        ],
        WebStorageApi.opfs => const [
          WasmStorageImplementation.opfsShared,
          WasmStorageImplementation.opfsLocks,
        ],
      };

      if (implementationsForStorage.any(available.contains)) {
        return location;
      }
    }

    return null;
  }

  /// Probes for:
  ///
  /// - available storage implementations based on supported web APIs.
  /// - APIs not currently supported by the browser.
  /// - existing drift databases in the current browsing context.
  ///
  /// This information can be used to control whether to open a drift database,
  /// or whether the current browser is unsuitable for the persistence
  /// requirements of your app.
  /// For most apps, using [open] directly is easier. It calls [probe]
  /// internally and uses the best storage implementation available.
  ///
  /// The [databaseName] option is not strictly required. But drift can't list
  /// databases stored in IndexedDb, they are not part of
  /// [WasmProbeResult.existingDatabases] by default. This is because drift
  /// databases can't be distinguished from other IndexedDb databases without
  /// opening them, which might disturb the running operation of them. When a
  /// [databaseName] is passed, drift will explicitly probe whether a database
  /// with that name exists in IndexedDb and whether it is a drift database.
  /// Drift is always able to list databases stored in OPFS, regardless of
  /// whether [databaseName] is passed or not.
  ///
  /// Note that this method is only fully supported when using the drift worker
  /// shipped with the drift 2.11 release. Older workers are only supported when
  /// [databaseName] is non-null.
  static Future<WasmProbeResult> probe({
    required Uri sqlite3Uri,
    required Uri driftWorkerUri,
    String? databaseName,
  }) async {
    return await WasmDatabaseOpener(
      sqlite3Uri,
      driftWorkerUri,
      databaseName,
    ).probe();
  }

  /// The entrypoint for a web worker suitable for use with [open].
  ///
  /// Generally, you can grab a pre-compiled worker file from a
  /// [drift release](https://github.com/simolus3/drift/releases) and don't need
  /// to call this method in your app.
  ///
  /// If you prefer to compile the worker yourself, write a simple Dart program
  /// that calls this method in its `main()` function and compile that with
  /// `dart2js`.
  /// This is particularly useful when using [setupAllDatabases], a callback
  /// that will be invoked on every new [CommonDatabase] created by the web
  /// worker. This is a suitable place to register custom functions.
  static void workerMainForOpen({WasmDatabaseSetup? setupAllDatabases}) {
    final self = globalContext;

    if (self.instanceOfString('DedicatedWorkerGlobalScope')) {
      DedicatedDriftWorker(
        self as DedicatedWorkerGlobalScope,
        setupAllDatabases,
      ).start();
    } else if (self.instanceOfString('SharedWorkerGlobalScope')) {
      SharedDriftWorker(
        self as SharedWorkerGlobalScope,
        setupAllDatabases,
      ).start();
    }
  }
}

class _WasmDelegate extends Sqlite3Delegate<CommonDatabase> {
  final CommonSqlite3? _sqlite3;
  final String? _path;
  final IndexedDbFileSystem? _fileSystem;
  Future<void> _indexedDbRequestTail = Future<void>.value();
  var _indexedDbStorageFailed = false;

  _WasmDelegate(
    this._sqlite3,
    this._path,
    super.setup,
    this._fileSystem, {
    super.enableMigrations = true,
    required super.cachePreparedStatements,
  });

  _WasmDelegate.opened(
    super.db,
    super.setup,
    super.closeUnderlyingWhenClosed,
    bool cachePreparedStatements,
    bool enableMigrations,
  ) : _sqlite3 = null,
      _path = null,
      _fileSystem = null,
      super.opened(
        cachePreparedStatements: cachePreparedStatements,
        enableMigrations: enableMigrations,
      );

  @override
  CommonDatabase openDatabase() {
    final path = _path;
    if (path == null) {
      return _sqlite3!.openInMemory();
    } else {
      return _sqlite3!.open(path);
    }
  }

  Future<void> _flush() async {
    await _fileSystem?.flush();
  }

  Future<T> _normalizeIndexedDbFailure<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on Object {
      if (_fileSystem?.isPoisoned == true) {
        _indexedDbStorageFailed = true;
        throw StateError('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED');
      }
      rethrow;
    }
  }

  Future<T> _serializeIndexedDbRequest<T>(Future<T> Function() operation) {
    if (_fileSystem == null) return operation();

    final previous = _indexedDbRequestTail;
    final released = Completer<void>();
    _indexedDbRequestTail = released.future;

    return () async {
      try {
        await previous;
        if (_indexedDbStorageFailed) {
          throw StateError('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED');
        }
        return await operation();
      } finally {
        released.complete();
      }
    }();
  }

  Future<void> _flushOrPoison() async {
    try {
      await _flush();
    } on Object {
      if (_fileSystem != null) {
        _indexedDbStorageFailed = true;
        throw StateError('ATERMIUS_INDEXEDDB_PERSISTENCE_FAILURE');
      }
      rethrow;
    }
  }

  void _checkIndexedDbUsable() {
    if (_fileSystem?.isPoisoned == true) {
      _indexedDbStorageFailed = true;
    }
    if (_fileSystem != null && _indexedDbStorageFailed) {
      throw StateError('ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED');
    }
  }

  @override
  Future<void> open(QueryExecutorUser db) =>
      _normalizeIndexedDbFailure(() async {
        _checkIndexedDbUsable();
        await super.open(db);
      });

  bool _isCommitStatement(String statement) {
    final normalized = statement.trim().toUpperCase();
    return normalized == 'COMMIT' ||
        normalized == 'COMMIT TRANSACTION' ||
        normalized == 'END' ||
        normalized == 'END TRANSACTION';
  }

  Future<void> _runWithArgs(String statement, List<Object?> args) {
    return _serializeIndexedDbRequest(
      () => _normalizeIndexedDbFailure(() async {
        _checkIndexedDbUsable();
        runWithArgsSync(statement, args);

        // Drift's server keeps its transaction backlog lock until send() returns.
        // Persist before returning from the outer COMMIT so another SharedWorker
        // port cannot read the post-commit page cache while the blocks write is
        // still pending.
        if (!isInTransaction || _isCommitStatement(statement)) {
          await _flushOrPoison();
        }
      }),
    );
  }

  @override
  Future<void> runCustom(String statement, List<Object?> args) async {
    await _runWithArgs(statement, args);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async {
    await _runWithArgs(statement, args);
    return database.lastInsertRowId;
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async {
    await _runWithArgs(statement, args);
    return database.updatedRows;
  }

  @override
  Future<QueryResult> runSelect(String statement, List<Object?> args) =>
      _serializeIndexedDbRequest(
        () => _normalizeIndexedDbFailure(() async {
          _checkIndexedDbUsable();
          final result = await super.runSelect(statement, args);
          if (!isInTransaction) {
            await _flushOrPoison();
          }
          return result;
        }),
      );

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _serializeIndexedDbRequest(
        () => _normalizeIndexedDbFailure(() async {
          _checkIndexedDbUsable();
          runBatchSync(statements);

          if (!isInTransaction) {
            await _flushOrPoison();
          }
        }),
      );

  @override
  Future<void> close() async {
    await super.close();

    if (closeUnderlyingWhenClosed) {
      database.close();
      if (!_indexedDbStorageFailed) await _flush();
    }
  }
}
