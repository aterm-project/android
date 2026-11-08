import 'package:aterm_client/storage/web_storage_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('openWithSafeDriftStorage', () {
    for (final rejected in ['unsafeIndexedDb', 'inMemory']) {
      test(
        '$rejected is rejected before opening the Vault connection',
        () async {
          var openCalls = 0;

          await expectLater(
            openWithSafeDriftStorage<void>(
              databaseName: 'atermius_vault',
              availableImplementations: [rejected],
              existingDatabases: const [],
              open: (_) async {
                openCalls++;
              },
            ),
            throwsA(isA<UnsupportedWebStorageException>()),
          );

          expect(openCalls, 0);
        },
      );
    }

    test('sharedIndexedDb opens only after the allowlist passes', () async {
      final opened = <String>[];

      final result = await openWithSafeDriftStorage<String>(
        databaseName: 'atermius_vault',
        availableImplementations: ['unsafeIndexedDb', 'sharedIndexedDb'],
        existingDatabases: const [],
        open: (implementation) async {
          opened.add(implementation);
          return 'opened';
        },
      );

      expect(result, 'opened');
      expect(opened, ['sharedIndexedDb']);
    });

    test('reliable OPFS implementations are accepted', () {
      expect(
        selectSafeDriftStorage(
          databaseName: 'atermius_vault',
          availableImplementations: ['inMemory', 'opfsLocks', 'opfsShared'],
          existingDatabases: const [],
        ),
        'opfsShared',
      );
    });

    test('existing database storage is preserved before opening', () async {
      final opened = <String>[];
      final selected = await openWithSafeDriftStorage<String>(
        databaseName: 'atermius_vault',
        availableImplementations: [
          'opfsShared',
          'unsafeIndexedDb',
          'sharedIndexedDb',
        ],
        existingDatabases: const [
          ('indexedDb', 'atermius_vault'),
          ('opfs', 'another_database'),
        ],
        open: (implementation) async {
          opened.add(implementation);
          return implementation;
        },
      );

      expect(selected, 'sharedIndexedDb');
      expect(opened, ['sharedIndexedDb']);
    });

    test(
      'does not silently replace an existing Vault with an empty backend',
      () {
        expect(
          () => selectSafeDriftStorage(
            databaseName: 'atermius_vault',
            availableImplementations: ['opfsShared', 'unsafeIndexedDb'],
            existingDatabases: const [('indexedDb', 'atermius_vault')],
          ),
          throwsA(isA<UnsupportedWebStorageException>()),
        );
      },
    );
  });
}
