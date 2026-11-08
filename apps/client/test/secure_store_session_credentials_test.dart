// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/storage/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> values;
  late ClientSecureStore store;

  setUp(() {
    values = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      values,
    );
    store = ClientSecureStore(const FlutterSecureStorage());
  });

  test(
    'round trips a session snapshot scoped to server, user and device',
    () async {
      final credentials = SessionCredentials(
        accountId: 'account-id',
        deviceId: 'device-id',
        accessToken: 'access-secret',
        refreshToken: 'refresh-secret',
        accessExpiresAt: DateTime.utc(2026, 9, 28, 10),
      );

      await store.saveSessionCredentials(
        'https://sync.example.test/tenant',
        'Alice',
        credentials,
      );

      final restored = await store.readSessionCredentials(
        'https://sync.example.test/tenant',
        'alice',
        'device-id',
      );
      expect(restored?.accountId, 'account-id');
      expect(restored?.deviceId, 'device-id');
      expect(restored?.accessToken, 'access-secret');
      expect(restored?.refreshToken, 'refresh-secret');
      expect(restored?.accessExpiresAt, credentials.accessExpiresAt);
      expect(
        await store.readSessionCredentials(
          'https://sync.example.test/other-tenant',
          'alice',
          'device-id',
        ),
        isNull,
      );
      expect(
        await store.readSessionCredentials(
          'https://sync.example.test/tenant',
          'alice',
          'other-device',
        ),
        isNull,
      );
    },
  );

  test('a stale logout cannot delete a newer session snapshot', () async {
    final credentials = SessionCredentials(
      accountId: 'account-id',
      deviceId: 'device-id',
      accessToken: 'access-new',
      refreshToken: 'refresh-new',
      accessExpiresAt: DateTime.utc(2026, 9, 28, 10),
    );
    await store.saveSessionCredentials(
      'https://sync.example.test',
      'alice',
      credentials,
    );

    expect(
      await store.deleteSessionCredentialsIfCurrent(
        'https://sync.example.test',
        'alice',
        deviceId: 'device-id',
        expectedRefreshToken: 'refresh-old',
      ),
      isFalse,
    );
    expect(
      (await store.readSessionCredentials(
        'https://sync.example.test',
        'alice',
        'device-id',
      ))?.refreshToken,
      'refresh-new',
    );
  });

  test('logout removes only its device snapshot', () async {
    final expiry = DateTime.utc(2026, 9, 28, 10);
    for (final deviceId in ['device-a', 'device-b']) {
      await store.saveSessionCredentials(
        'https://sync.example.test',
        'alice',
        SessionCredentials(
          accountId: 'account-id',
          deviceId: deviceId,
          accessToken: 'access-$deviceId',
          refreshToken: 'refresh-$deviceId',
          accessExpiresAt: expiry,
        ),
      );
    }

    expect(
      await store.deleteSessionCredentialsIfCurrent(
        'https://sync.example.test',
        'alice',
        deviceId: 'device-a',
        expectedRefreshToken: 'refresh-device-a',
      ),
      isTrue,
    );
    expect(
      await store.readSessionCredentials(
        'https://sync.example.test',
        'alice',
        'device-a',
      ),
      isNull,
    );
    expect(
      (await store.readSessionCredentials(
        'https://sync.example.test',
        'alice',
        'device-b',
      ))?.refreshToken,
      'refresh-device-b',
    );
  });

  test(
    'account refresh-token cleanup deletes every local device snapshot',
    () async {
      final expiry = DateTime.utc(2026, 9, 28, 10);
      for (final deviceId in ['device-a', 'device-b']) {
        await store.saveSessionCredentials(
          'https://sync.example.test',
          'alice',
          SessionCredentials(
            accountId: 'account-id',
            deviceId: deviceId,
            accessToken: 'access-$deviceId',
            refreshToken: 'refresh-$deviceId',
            accessExpiresAt: expiry,
          ),
        );
      }

      await store.deleteRefreshToken('https://sync.example.test', 'alice');

      expect(
        await store.readSessionCredentials(
          'https://sync.example.test',
          'alice',
          'device-a',
        ),
        isNull,
      );
      expect(
        await store.readSessionCredentials(
          'https://sync.example.test',
          'alice',
          'device-b',
        ),
        isNull,
      );
    },
  );

  test('reports interrupted and corrupt snapshots as unsafe states', () async {
    final credentials = SessionCredentials(
      accountId: 'account-id',
      deviceId: 'device-id',
      accessToken: 'access-secret',
      refreshToken: 'refresh-secret',
      accessExpiresAt: DateTime.utc(2026, 9, 28, 10),
    );
    const baseUrl = 'https://sync.example.test';
    await store.saveSessionCredentials(baseUrl, 'alice', credentials);
    final scope = SessionScope(
      serverNamespace: secureStorageNamespace(baseUrl),
      accountId: credentials.accountId,
      deviceId: credentials.deviceId,
    );

    await store.markSessionRotationPending(baseUrl, 'alice', scope);
    expect(
      (await store.readSessionSnapshot(baseUrl, 'alice', 'device-id')).status,
      SessionSnapshotStatus.rotationPending,
    );

    final sessionKey = values.keys.singleWhere(
      (key) => key.contains('.session.'),
    );
    values[sessionKey] = '{malformed';
    expect(
      (await store.readSessionSnapshot(baseUrl, 'alice', 'device-id')).status,
      SessionSnapshotStatus.invalid,
    );
  });

  test('legacy refresh key is updated before the ready snapshot', () async {
    final failingPlatform = _FailingSessionSnapshotPlatform(values);
    FlutterSecureStoragePlatform.instance = failingPlatform;
    store = ClientSecureStore(const FlutterSecureStorage());
    final previous = SessionCredentials(
      accountId: 'account-id',
      deviceId: 'device-id',
      accessToken: 'access-old',
      refreshToken: 'refresh-old',
      accessExpiresAt: DateTime.utc(2026, 9, 28, 10),
    );
    final next = SessionCredentials(
      accountId: 'account-id',
      deviceId: 'device-id',
      accessToken: 'access-new',
      refreshToken: 'refresh-new',
      accessExpiresAt: DateTime.utc(2026, 9, 28, 11),
    );
    await store.saveSessionCredentials(
      'https://sync.example.test',
      'alice',
      previous,
    );
    await store.markSessionRotationPending(
      'https://sync.example.test',
      'alice',
      SessionScope(
        serverNamespace: secureStorageNamespace('https://sync.example.test'),
        accountId: 'account-id',
        deviceId: 'device-id',
      ),
    );
    failingPlatform.failSnapshotWrites = true;

    await expectLater(
      store.saveSessionCredentials('https://sync.example.test', 'alice', next),
      throwsStateError,
    );

    expect(
      (await store.readSessionSnapshot(
        'https://sync.example.test',
        'alice',
        'device-id',
      )).status,
      SessionSnapshotStatus.rotationPending,
    );
    expect(
      await store.readRefreshToken('https://sync.example.test', 'alice'),
      'refresh-new',
    );
  });
}

class _FailingSessionSnapshotPlatform extends TestFlutterSecureStoragePlatform {
  _FailingSessionSnapshotPlatform(super.data);

  bool failSnapshotWrites = false;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failSnapshotWrites && key.contains('.session.')) {
      throw StateError('snapshot write failed');
    }
    await super.write(key: key, value: value, options: options);
  }
}
