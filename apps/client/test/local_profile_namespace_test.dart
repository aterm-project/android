import 'package:aterm_client/storage/local_profile_namespace.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/web_storage_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'profile UUIDs derive stable isolated database and secure-store names',
    () {
      const profileA = '11111111-1111-4111-8111-111111111111';
      const profileB = '22222222-2222-4222-8222-222222222222';

      expect(isCanonicalLocalProfileId(profileA), isTrue);
      expect(localProfileDatabaseName(profileA), 'atermius_local_$profileA');
      expect(localProfileSecureStorageNamespace(profileA), 'local:$profileA');
      expect(
        localProfileDatabaseName(profileA),
        isNot(localProfileDatabaseName(profileB)),
      );
      expect(
        localProfileSecureStorageNamespace(profileA),
        isNot(localProfileSecureStorageNamespace(profileB)),
      );
      expect(serverClientDatabaseName, 'atermius_vault');
    },
  );

  test(
    'invalid or noncanonical profile IDs cannot influence storage names',
    () {
      for (final invalid in [
        '',
        '../atermius_vault',
        '11111111-1111-4111-8111-11111111111A',
        '11111111-1111-0111-8111-111111111111',
        '11111111-1111-4111-7111-111111111111',
        '11111111-1111-4111-8111-111111111111/',
      ]) {
        expect(isCanonicalLocalProfileId(invalid), isFalse, reason: invalid);
        expect(
          () => localProfileDatabaseName(invalid),
          throwsFormatException,
          reason: invalid,
        );
        expect(
          () => localProfileSecureStorageNamespace(invalid),
          throwsFormatException,
          reason: invalid,
        );
        expect(
          () => ClientDatabase.openLocalProfile(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    },
  );

  test('Web storage preflight pins each profile database independently', () {
    const profileA = '11111111-1111-4111-8111-111111111111';
    const profileB = '22222222-2222-4222-8222-222222222222';
    final dbA = localProfileDatabaseName(profileA);
    final dbB = localProfileDatabaseName(profileB);
    const implementations = [
      'opfsShared',
      'sharedIndexedDb',
      'unsafeIndexedDb',
    ];

    expect(
      selectSafeDriftStorage(
        databaseName: dbA,
        availableImplementations: implementations,
        existingDatabases: [('indexedDb', dbA), ('opfs', 'unrelated')],
      ),
      'sharedIndexedDb',
    );
    expect(
      selectSafeDriftStorage(
        databaseName: dbB,
        availableImplementations: implementations,
        existingDatabases: [('opfs', dbB), ('indexedDb', dbA)],
      ),
      'opfsShared',
    );
  });
}
