import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

const indexedDbPersistenceFailureMarker =
    'ATERMIUS_INDEXEDDB_PERSISTENCE_FAILURE';
const indexedDbQuarantinedMarker = 'ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED';

bool isIndexedDbQuarantineError(Object error) {
  final message = error.toString();
  return message.contains(indexedDbPersistenceFailureMarker) ||
      message.contains(indexedDbQuarantinedMarker);
}

Future<T> runWithDatabaseQuarantine<T>({
  required String databaseName,
  required DatabaseQuarantineRegistry registry,
  required Future<T> Function() operation,
  void Function()? onQuarantine,
}) async {
  if (registry.isQuarantined(databaseName)) {
    throw const DatabaseRecoveryRequiredException();
  }
  try {
    return await operation();
  } on DatabaseRecoveryRequiredException {
    rethrow;
  } on Object catch (error) {
    if (!isIndexedDbQuarantineError(error)) rethrow;
    registry.quarantine(databaseName);
    onQuarantine?.call();
    throw const DatabaseRecoveryRequiredException();
  }
}

/// A local database whose Web IndexedDB transaction aborted is unsafe to use
/// until its SharedWorker has stopped and reopened the last durable snapshot.
class DatabaseRecoveryRequiredException implements Exception {
  const DatabaseRecoveryRequiredException();

  @override
  String toString() => currentL10n.localStorageNeedsRecoveryReadingEditing2;
}

/// In-page notifications used by the app shell to keep a recovery banner
/// visible after a database error has been caught by a button callback.
class DatabaseQuarantineRegistry extends ChangeNotifier {
  final Set<String> _databaseNames = <String>{};

  bool get hasQuarantinedDatabase => _databaseNames.isNotEmpty;

  Set<String> get quarantinedDatabaseNames => Set.unmodifiable(_databaseNames);

  bool isQuarantined(String databaseName) =>
      _databaseNames.contains(databaseName);

  void quarantine(String databaseName) {
    if (_databaseNames.add(databaseName)) notifyListeners();
  }
}

final databaseQuarantineRegistry = DatabaseQuarantineRegistry();
