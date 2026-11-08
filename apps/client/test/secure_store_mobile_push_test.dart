// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

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
    'cleanup-pending marker is account, device, and server scoped',
    () async {
      const baseUrl = 'https://sync.example.test/tenant';
      await store.setMobilePushCleanupPending(
        baseUrl: baseUrl,
        accountId: 'account-a',
        deviceId: 'device-a',
        pending: true,
      );

      Future<bool> read({
        String url = baseUrl,
        String account = 'account-a',
        String device = 'device-a',
      }) => store.mobilePushCleanupPending(
        baseUrl: url,
        accountId: account,
        deviceId: device,
      );

      expect(await read(), isTrue);
      expect(await read(url: 'https://elsewhere.example.test'), isFalse);
      expect(await read(account: 'account-b'), isFalse);
      expect(await read(device: 'device-b'), isFalse);

      await store.setMobilePushCleanupPending(
        baseUrl: baseUrl,
        accountId: 'account-a',
        deviceId: 'device-a',
        pending: false,
      );
      expect(await read(), isFalse);
    },
  );

  test(
    'opt-in preference stays scoped to account, device, and server',
    () async {
      const baseUrl = 'https://sync.example.test/tenant';
      await store.setMobilePushEnabled(
        baseUrl: baseUrl,
        accountId: 'account-a',
        deviceId: 'device-a',
        enabled: true,
      );

      Future<bool> read({
        String url = baseUrl,
        String account = 'account-a',
        String device = 'device-a',
      }) => store.mobilePushEnabled(
        baseUrl: url,
        accountId: account,
        deviceId: device,
      );

      expect(await read(), isTrue);
      expect(await read(url: 'https://elsewhere.example.test'), isFalse);
      expect(await read(account: 'account-b'), isFalse);
      expect(await read(device: 'device-b'), isFalse);
    },
  );

  test(
    'opt-in and cleanup marker store no provider token or credential',
    () async {
      const token = 'provider-token-value-that-must-not-be-stored';
      await store.setMobilePushEnabled(
        baseUrl: 'https://sync.example.test/tenant',
        accountId: 'account-a',
        deviceId: 'device-a',
        enabled: false,
      );
      await store.setMobilePushCleanupPending(
        baseUrl: 'https://sync.example.test/tenant',
        accountId: 'account-a',
        deviceId: 'device-a',
        pending: true,
      );

      expect(values.values, everyElement(anyOf('true', 'false')));
      expect(values.toString(), isNot(contains(token)));
      expect(values.keys.join(' '), isNot(contains('apns')));
      expect(values.keys.join(' '), isNot(contains('fcm_v1')));
    },
  );
}
