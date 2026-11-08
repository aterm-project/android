import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'lock wipes workspace keys but keeps session; sign out still logs out',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = Uint8List.fromList(List<int>.filled(32, 0x5a));
      final api = _LogoutCountingApi();
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: '11111111-1111-4111-8111-111111111111',
        instanceId: '22222222-2222-4222-8222-222222222222',
        vaultId: '33333333-3333-4333-8333-333333333333',
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: '1',
        vaultKey: vaultKey,
      );
      final session = AuthSession(
        accountId: 'account-1',
        accessToken: 'access-token',
        expiresIn: 3600,
        refreshToken: 'refresh-token',
        deviceId: identity.deviceId,
        vaults: const [],
      );
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _NoopSecureStore(),
              repositoryForTesting: repository,
              shellHistoryVaultKeyForTesting: vaultKey,
            )
            ..api = api
            ..session = session
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace
            ..hosts.add(
              const HostRecord(
                id: '44444444-4444-4444-8444-444444444444',
                name: 'must be hidden while locked',
                address: 'host.example.test',
                username: 'tester',
              ),
            );

      try {
        await controller.lock();

        expect(controller.workspaceLocked, isTrue);
        expect(controller.session, same(session));
        expect(controller.authenticated, isTrue);
        expect(controller.stage, ClientStage.workspace);
        expect(controller.identity, isNull);
        expect(controller.repositoryForTesting, isNull);
        expect(controller.hosts, isEmpty);
        expect(vaultKey, everyElement(0));
        expect(api.logoutCalls, 0);
        await expectLater(
          controller.createVault('must-stay-locked'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('工作区锁定'),
            ),
          ),
        );

        await controller.logout();

        expect(api.logoutCalls, 1);
        expect(controller.workspaceLocked, isFalse);
        expect(controller.session, isNull);
        expect(controller.stage, ClientStage.login);
      } finally {
        controller.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test(
    'sign out drains an in-flight locked receive before clearing session',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final api = _BlockingLockedReceiveApi();
      final session = AuthSession(
        accountId: 'account-1',
        accessToken: 'access-token',
        expiresIn: 3600,
        refreshToken: 'refresh-token',
        deviceId: identity.deviceId,
        vaults: const [],
      );
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _NoopSecureStore(),
              mobilePushAutoSyncForTesting: () async {},
            )
            ..api = api
            ..session = session
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace
            ..workspaceLocked = true
            ..instance = const InstanceInfo(
              instanceId: '11111111-1111-4111-8111-111111111111',
              serverSpaceId: '22222222-2222-4222-8222-222222222222',
              generation: '1',
              protocolVersion: 1,
              setupRequired: false,
              capabilities: [],
            )
            ..activeVault = const VaultDescriptor(
              id: '33333333-3333-4333-8333-333333333333',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );

      try {
        final receive = controller.receiveWhileLockedForTesting();
        await api.changesStarted.future;

        var logoutCompleted = false;
        final logout = controller.logout().whenComplete(() {
          logoutCompleted = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(api.logoutCalls, 1);
        expect(logoutCompleted, isFalse);
        expect(controller.session, same(session));
        expect(controller.workspaceLocked, isTrue);

        api.pendingChanges.complete(
          const SyncPage(
            events: [],
            nextCursor: 'locked-cursor-after-drain',
            hasMore: false,
            serverGeneration: '1',
          ),
        );
        await receive;
        await logout;

        expect(logoutCompleted, isTrue);
        expect(controller.session, isNull);
        expect(controller.workspaceLocked, isFalse);
        expect(controller.lockedSyncReceiverForTesting, isNull);
      } finally {
        controller.dispose();
        identity.dispose();
        api.close();
        await database.close();
      }
    },
  );
}

class _LogoutCountingApi extends ApiClient {
  _LogoutCountingApi() : super(baseUrl: 'https://locked-workspace.test');

  int logoutCalls = 0;

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

class _NoopSecureStore extends ClientSecureStore {
  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async => true;
}

class _BlockingLockedReceiveApi extends _LogoutCountingApi {
  final changesStarted = Completer<void>();
  final pendingChanges = Completer<SyncPage>();

  @override
  Future<List<Map<String, dynamic>>> devices() async => const [];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      const [];

  @override
  Future<SyncPage> changes(String vaultId, {String? cursor, int limit = 500}) {
    if (!changesStarted.isCompleted) changesStarted.complete();
    return pendingChanges.future;
  }
}
