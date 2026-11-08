// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/auth/session_startup.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _base = 'https://example.test/tenant';
const _info = InstanceInfo(
  instanceId: 'instance',
  serverSpaceId: 'space',
  generation: '1',
  protocolVersion: 1,
  setupRequired: false,
  capabilities: [],
);

class _Api extends ApiClient {
  _Api() : super(baseUrl: _base);
  int version = 1;
  Map<String, dynamic> envelope = {};
  KdfParameters? params;
  @override
  Future<Map<String, dynamic>> prelogin(String username) async => {
    'kdf': params!.toJson(),
  };
  @override
  Future<AuthSession> refresh(String token) async => const AuthSession(
    accountId: 'account',
    deviceId: 'device',
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresIn: 900,
    vaults: [],
  );
  bool revoked = false;
  Completer<void>? gate;
  @override
  Future<AccountProfile> accountProfile() async {
    await gate?.future;
    if (revoked) throw StateError('revoked');
    return AccountProfile(
      accountId: 'account',
      deviceId: 'device',
      accountKeyEnvelopeVersion: version,
      accountKeyEnvelope: envelope,
    );
  }

  @override
  Future<List<VaultDescriptor>> vaults() async => [];
  @override
  Future<List<Map<String, dynamic>>> devices() async => [];
  @override
  Future<void> logout() async {}
}

class _StoragePlatform extends TestFlutterSecureStoragePlatform {
  _StoragePlatform(super.data);
  bool failDelete = false;
  Completer<void>? deviceGate;
  final deviceRead = Completer<void>();
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (key.endsWith('.device') &&
        !key.contains('.session.') &&
        deviceGate != null) {
      if (!deviceRead.isCompleted) deviceRead.complete();
      await deviceGate!.future;
    }
    return super.read(key: key, options: options);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failDelete) throw StateError('native secure deletion failed');
    await super.delete(key: key, options: options);
  }
}

class _Lock implements SessionRefreshLock {
  @override
  Future<T> run<T>(Future<T> Function() action) => action();
}

class _Controller extends AppController {
  _Controller(SodiumSumo sodium, ClientSecureStore store, this.client)
    : super(
        sodium: sodium,
        secureStore: store,
        database: ClientDatabase.forTesting(NativeDatabase.memory()),
        sessionRefreshLockForTesting: _Lock(),
      );
  final _Api client;
  InstanceInfo info = _info;
  @override
  Future<void> configureServer(String value, {bool showBusy = true}) async {
    api = client;
    instance = info;
    stage = ClientStage.login;
  }
}

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Map<String, String> values;
  late ClientSecureStore store;
  late _StoragePlatform platform;
  late SodiumSumo sodium;
  late _Api api;
  late _Controller controller;
  late Map<String, Object> binding;
  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cloud-resume-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    values = {};
    platform = _StoragePlatform(values);
    FlutterSecureStoragePlatform.instance = platform;
    store = ClientSecureStore();
    api = _Api();
    controller = _Controller(sodium, store, api);
    binding = {
      'instance_id': 'instance',
      'server_space_id': 'space',
      'account_id': 'account',
      'device_id': 'device',
      'envelope_version': 1,
      'envelope_sha256': base64Encode(
        (await crypto.Sha256().hash(utf8.encode('{}'))).bytes,
      ),
    };
    await store.saveLastServer(_base);
    await store.saveSessionResumeHint(
      _base,
      const SessionResumeHint(
        username: 'alice',
        accountId: 'account',
        deviceId: 'device',
      ),
    );
    await store.saveSessionCredentials(
      _base,
      'alice',
      SessionCredentials(
        accountId: 'account',
        deviceId: 'device',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 10),
        ),
      ),
    );
    final identity = DeviceIdentity(
      deviceId: 'device',
      signing: sodium.crypto.sign.keyPair(),
      encryption: sodium.crypto.box.keyPair(),
    );
    await store.saveDevice(_base, identity);
    identity.dispose();
    await store.saveRememberedAccountKey(
      _base,
      binding: binding,
      accountKey: Uint8List.fromList(List.filled(32, 42)),
    );
  });
  tearDown(() async {
    await controller.closeWorkspace();
    await temp.delete(recursive: true);
  });
  test('native remembered key restores authenticated workspace without password and survives normal close', () async {
    await controller.restoreLastServer();
    expect(controller.workspaceLocked, false);
    expect(controller.stage, ClientStage.workspace);
    expect(controller.identity?.deviceId, 'device');
    expect(controller.restoringStoredSession, false);
    await controller.closeWorkspace();
    expect(
      await store.rememberedAccountKey(_base, binding: binding),
      isNotNull,
    );
  });
  test(
    'successful manual unlock remembers the account key automatically',
    () async {
      await store.clearRememberedAccountKey(
        _base,
        accountId: 'account',
        deviceId: 'device',
      );
      api.params = KdfParameters.defaults(sodium);
      api.envelope = Map<String, dynamic>.from(
        await VaultCrypto(sodium).wrapAccountKey(
          password: 'test password for native unlock',
          params: api.params!,
          accountKey: Uint8List.fromList(List.filled(32, 42)),
        ),
      );
      binding['envelope_sha256'] = base64Encode(
        (await crypto.Sha256().hash(utf8.encode(canonicalJson(api.envelope))))
            .bytes,
      );
      await controller.restoreLastServer();
      expect(controller.workspaceLocked, true);
      await controller.unlockLockedWorkspace(
        password: 'test password for native unlock',
      );
      expect(controller.workspaceLocked, false);
      expect(
        await store.rememberedAccountKey(_base, binding: binding),
        List.filled(32, 42),
      );
    },
  );
  test(
    'explicit lock revokes remembered key and retires in-memory identity',
    () async {
      await controller.restoreLastServer();
      await controller.lock();
      expect(controller.workspaceLocked, true);
      expect(controller.identity, isNull);
      expect(await store.rememberedAccountKey(_base, binding: binding), isNull);
    },
  );
  test('explicit logout removes remembered key', () async {
    await controller.restoreLastServer();
    await controller.logout();
    expect(controller.session, isNull);
    expect(await store.rememberedAccountKey(_base, binding: binding), isNull);
  });
  test(
    'native delete failure still durably vetoes restart auto-unlock',
    () async {
      await controller.restoreLastServer();
      platform.failDelete = true;
      await controller.lock();
      expect(controller.workspaceLocked, true);
      expect(controller.identity, isNull);
      expect(
        values.keys.any((key) => key.endsWith('.remembered-account-key.v1')),
        true,
      );
      expect(await store.rememberedAccountKey(_base, binding: binding), isNull);
    },
  );
  for (final deleteFails in [false, true]) {
    test(
      'marker failure with secure delete failure=$deleteFails retires RAM and reports only double failure',
      () async {
        await controller.restoreLastServer();
        final blocker = File('${temp.path}/blocked-support');
        await blocker.writeAsString('not a directory');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => blocker.path,
            );
        platform.failDelete = deleteFails;
        await controller.lock();
        expect(controller.workspaceLocked, true);
        expect(controller.identity, isNull);
        expect(
          controller.errorMessage,
          deleteFails ? contains('无法清除本机自动解锁记录') : isNull,
        );
        expect(
          values.keys.any((key) => key.endsWith('.remembered-account-key.v1')),
          deleteFails,
        );
      },
    );
  }
  test('oversized native remembered record fails closed', () async {
    final key = values.keys.singleWhere(
      (key) => key.endsWith('.remembered-account-key.v1'),
    );
    values[key] = 'x' * 8193;
    expect(await store.rememberedAccountKey(_base, binding: binding), isNull);
    await controller.restoreLastServer();
    expect(controller.workspaceLocked, true);
    expect(controller.identity, isNull);
  });
  test('credentials changed during keychain I/O cannot publish keys or erase newer login', () async {
    platform.deviceGate = Completer<void>();
    final restoring = controller.restoreLastServer();
    await platform.deviceRead.future;
    await store.saveSessionCredentials(
      _base,
      'alice',
      SessionCredentials(
        accountId: 'account',
        deviceId: 'device',
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        accessExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 10),
        ),
      ),
    );
    platform.deviceGate!.complete();
    await restoring;
    expect(controller.workspaceLocked, true);
    expect(controller.identity, isNull);
    expect(
      (await store.readSessionCredentials(
        _base,
        'alice',
        'device',
      ))?.refreshToken,
      'new-refresh',
    );
    expect(
      await store.rememberedAccountKey(_base, binding: binding),
      isNotNull,
    );
  });
  test(
    'changed password envelope version fails closed to manual unlock',
    () async {
      api.version = 2;
      await controller.restoreLastServer();
      expect(controller.workspaceLocked, true);
      expect(controller.identity, isNull);
    },
  );
  test('changed instance fails closed to manual unlock', () async {
    controller.info = const InstanceInfo(
      instanceId: 'replacement',
      serverSpaceId: 'space',
      generation: '1',
      protocolVersion: 1,
      setupRequired: false,
      capabilities: [],
    );
    await controller.restoreLastServer();
    expect(controller.workspaceLocked, true);
    expect(controller.identity, isNull);
  });
  test('revoked authenticated session cannot load remembered key', () async {
    api.revoked = true;
    await controller.restoreLastServer();
    expect(controller.session, isNull);
    expect(controller.identity, isNull);
  });
  test(
    'binding rejects another tenant, account, device, envelope or space',
    () async {
      expect(
        await store.rememberedAccountKey(
          'https://example.test/other',
          binding: binding,
        ),
        isNull,
      );
      for (final entry in binding.entries) {
        final changed = {
          ...binding,
          entry.key: entry.value is int ? 2 : 'other',
        };
        expect(
          await store.rememberedAccountKey(_base, binding: changed),
          isNull,
          reason: entry.key,
        );
      }
    },
  );
}
