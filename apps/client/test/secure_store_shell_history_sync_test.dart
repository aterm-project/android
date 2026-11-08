// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aterm_client/storage/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientSecureStore store;
  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    store = ClientSecureStore(const FlutterSecureStorage());
  });

  test(
    'is disabled by default and scoped to server account device and Vault',
    () async {
      const baseUrl = 'https://sync.example.test/tenant';
      expect(
        await store.terminalHistorySyncEnabled(
          baseUrl: baseUrl,
          accountId: 'account-a',
          deviceId: 'device-a',
          vaultId: 'vault-a',
        ),
        isFalse,
      );

      await store.setTerminalHistorySyncEnabled(
        baseUrl: baseUrl,
        accountId: 'account-a',
        deviceId: 'device-a',
        vaultId: 'vault-a',
        enabled: true,
      );

      Future<bool> read({
        String url = baseUrl,
        String account = 'account-a',
        String device = 'device-a',
        String vault = 'vault-a',
      }) => store.terminalHistorySyncEnabled(
        baseUrl: url,
        accountId: account,
        deviceId: device,
        vaultId: vault,
      );

      expect(await read(), isTrue);
      expect(await read(url: 'https://elsewhere.example.test'), isFalse);
      expect(await read(account: 'account-b'), isFalse);
      expect(await read(device: 'device-b'), isFalse);
      expect(await read(vault: 'vault-b'), isFalse);

      await store.setTerminalHistorySyncEnabled(
        baseUrl: baseUrl,
        accountId: 'account-a',
        deviceId: 'device-a',
        vaultId: 'vault-a',
        enabled: false,
      );
      expect(await read(), isFalse);
    },
  );
}
