/// Thrown when the browser cannot provide storage with durable, safe
/// cross-tab semantics for the local encrypted vault.
///
/// The message is deliberately stable and contains no browser, server, or
/// account details so it can be safely classified by startup UI.
class UnsupportedWebStorageException implements Exception {
  const UnsupportedWebStorageException();

  @override
  String toString() => 'Unsupported secure browser storage.';
}

const _preferredImplementations = <String>[
  'opfsShared',
  'opfsLocks',
  'sharedIndexedDb',
  'unsafeIndexedDb',
  'inMemory',
];

const _storageByImplementation = <String, String?>{
  'opfsShared': 'opfs',
  'opfsLocks': 'opfs',
  'sharedIndexedDb': 'indexedDb',
  'unsafeIndexedDb': 'indexedDb',
  'inMemory': null,
};

const _safeImplementations = <String>{
  'opfsShared',
  'opfsLocks',
  'sharedIndexedDb',
};

/// Selects the same preferred storage family Drift would use, while refusing
/// storage modes that can lose data or race across browser tabs.
///
/// If Drift found an existing database with [databaseName], selection remains
/// pinned to that storage API. This preserves an existing IndexedDB or OPFS
/// vault instead of silently opening an empty database on a different backend.
String selectSafeDriftStorage({
  required String databaseName,
  required Iterable<String> availableImplementations,
  required Iterable<(String storageName, String name)> existingDatabases,
}) {
  final available = availableImplementations.toSet();
  final existing = existingDatabases
      .where((entry) => entry.$2 == databaseName)
      .firstOrNull;

  final candidates = _preferredImplementations.where(available.contains);
  final storagePinnedCandidates = existing == null
      ? candidates
      : candidates.where(
          (implementation) =>
              _storageByImplementation[implementation] == existing.$1,
        );

  for (final candidate in storagePinnedCandidates) {
    if (_safeImplementations.contains(candidate)) return candidate;
  }

  throw const UnsupportedWebStorageException();
}

/// Runs [open] only after a supported storage backend has been selected.
/// Keeping this boundary separate makes the no-open behavior testable without
/// browser globals or a real IndexedDB/OPFS implementation.
Future<T> openWithSafeDriftStorage<T>({
  required String databaseName,
  required Iterable<String> availableImplementations,
  required Iterable<(String storageName, String name)> existingDatabases,
  required Future<T> Function(String implementation) open,
}) async {
  final implementation = selectSafeDriftStorage(
    databaseName: databaseName,
    availableImplementations: availableImplementations,
    existingDatabases: existingDatabases,
  );
  return open(implementation);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
