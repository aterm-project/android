import 'package:aterm_client/crypto/vault_crypto.dart' show DeviceIdentity;
import 'package:aterm_client/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pending full recovery is server-scoped and restores its retry state',
    () async {
      final sodium = await SodiumSumoInit.init();
      final platformStorage = _MemoryFlutterSecureStorage();
      final secureStore = ClientSecureStore(platformStorage);
      final device = DeviceIdentity.create(sodium);
      final expiresAt = DateTime.utc(2026, 9, 30, 12);
      try {
        final request = <String, Object?>{
          'operation_id': '11111111-1111-4111-8111-111111111111',
          'recovery_signature': 'signature',
          'device': {
            'device_id': device.deviceId,
            'signing_public_key': device.signingPublicKey,
            'encryption_public_key': device.encryptionPublicKey,
          },
        };
        await secureStore.savePendingFullAccountRecovery(
          baseUrl: 'https://example.test/tenant-a',
          request: request,
          device: device,
          challengeExpiresAt: expiresAt,
          completionAttempted: false,
        );
        await secureStore.savePendingFullAccountRecovery(
          baseUrl: 'https://example.test/tenant-b',
          request: {
            ...request,
            'operation_id': '22222222-2222-4222-8222-222222222222',
          },
          device: device,
          challengeExpiresAt: expiresAt,
          completionAttempted: true,
        );

        final tenantA = await secureStore.loadPendingFullAccountRecovery(
          'https://example.test/tenant-a',
        );
        final tenantB = await secureStore.loadPendingFullAccountRecovery(
          'https://example.test/tenant-b',
        );
        expect(tenantA?.request['operation_id'], request['operation_id']);
        expect(tenantA?.completionAttempted, isFalse);
        expect(tenantB?.completionAttempted, isTrue);
        expect(tenantA?.challengeExpiresAt, expiresAt);
        expect(tenantA?.device['device_id'], device.deviceId);
        expect(
          tenantA?.device['signing_secret'],
          device.toStorageJson()['signing_secret'],
        );

        await secureStore.clearPendingFullAccountRecovery(
          'https://example.test/tenant-a',
        );
        expect(
          await secureStore.loadPendingFullAccountRecovery(
            'https://example.test/tenant-a',
          ),
          isNull,
        );
        expect(
          await secureStore.loadPendingFullAccountRecovery(
            'https://example.test/tenant-b',
          ),
          isNotNull,
        );
      } finally {
        device.dispose();
      }
    },
  );
}

class _MemoryFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}
