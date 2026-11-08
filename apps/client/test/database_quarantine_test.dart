import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('database quarantine error boundary', () {
    test(
      'ordinary SQLite constraint errors do not quarantine the DB',
      () async {
        final registry = DatabaseQuarantineRegistry();
        var peerNotificationCount = 0;
        final constraintError = StateError('UNIQUE constraint failed');

        await expectLater(
          runWithDatabaseQuarantine<int>(
            databaseName: 'atermius_vault',
            registry: registry,
            operation: () async => throw constraintError,
            onQuarantine: () => peerNotificationCount++,
          ),
          throwsA(same(constraintError)),
        );

        expect(registry.isQuarantined('atermius_vault'), isFalse);
        expect(registry.hasQuarantinedDatabase, isFalse);
        expect(peerNotificationCount, 0);
      },
    );

    test(
      'an IndexedDB flush failure quarantines and blocks later operations',
      () async {
        final registry = DatabaseQuarantineRegistry();
        var peerNotificationCount = 0;
        var operationCount = 0;

        await expectLater(
          runWithDatabaseQuarantine<int>(
            databaseName: 'atermius_vault',
            registry: registry,
            operation: () async {
              operationCount++;
              throw StateError(indexedDbPersistenceFailureMarker);
            },
            onQuarantine: () => peerNotificationCount++,
          ),
          throwsA(isA<DatabaseRecoveryRequiredException>()),
        );

        expect(registry.isQuarantined('atermius_vault'), isTrue);
        expect(peerNotificationCount, 1);
        await expectLater(
          runWithDatabaseQuarantine<int>(
            databaseName: 'atermius_vault',
            registry: registry,
            operation: () async {
              operationCount++;
              return 1;
            },
            onQuarantine: () => peerNotificationCount++,
          ),
          throwsA(isA<DatabaseRecoveryRequiredException>()),
        );
        expect(operationCount, 1);
        expect(peerNotificationCount, 1);
      },
    );
  });
}
