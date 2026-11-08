import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _firstVaultId = '55555555-5555-4555-8555-555555555555';
const _secondVaultId = '66666666-6666-4666-8666-666666666666';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'heartbeat lifecycle starts, follows selected Vault, and stops on logout',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final paths = <String>[];
      final api = ApiClient(
        baseUrl: 'https://presence.example.test',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/presence')) {
            paths.add(request.url.path);
            return _heartbeatResponse();
          }
          if (request.url.path == '/api/v1/auth/logout') {
            return http.Response('{}', 200);
          }
          return http.Response('{}', 200);
        }),
      )..accessToken = 'test-access-token';
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _PresenceSecureStore(),
              vaultPresenceHeartbeatIntervalForTesting: const Duration(
                milliseconds: 12,
              ),
            )
            ..api = api
            ..session = const AuthSession(
              accountId: '11111111-1111-4111-8111-111111111111',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              vaults: [],
            )
            ..authenticatedUsernameForTesting = 'presence@example.test'
            ..stage = ClientStage.workspace;

      try {
        controller.startVaultPresenceHeartbeatsForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(
          paths,
          isEmpty,
          reason: 'a session without an active Vault has no lease',
        );

        controller.activeVault = const VaultDescriptor(
          id: _firstVaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        controller.startVaultPresenceHeartbeatsForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 28));
        expect(paths, isNotEmpty);
        expect(
          paths.every(
            (path) => path == '/api/v1/vaults/$_firstVaultId/presence',
          ),
          isTrue,
        );

        final afterSelection = paths.length;
        controller.activeVault = const VaultDescriptor(
          id: _secondVaultId,
          role: 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: false,
        );
        controller.startVaultPresenceHeartbeatsForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 28));
        final switchedPaths = paths.sublist(afterSelection);
        expect(switchedPaths, isNotEmpty);
        expect(
          switchedPaths.every(
            (path) => path == '/api/v1/vaults/$_secondVaultId/presence',
          ),
          isTrue,
        );

        controller.activeVault = null;
        controller.startVaultPresenceHeartbeatsForTesting();
        final withoutVault = paths.length;
        await Future<void>.delayed(const Duration(milliseconds: 28));
        expect(
          paths.length,
          withoutVault,
          reason: 'clearing the Vault stops renewal',
        );

        controller.activeVault = const VaultDescriptor(
          id: _firstVaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        controller.startVaultPresenceHeartbeatsForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await controller.logout();
        final afterLogout = paths.length;
        await Future<void>.delayed(const Duration(milliseconds: 28));
        expect(
          paths.length,
          afterLogout,
          reason: 'logout cancels periodic renewal',
        );
      } finally {
        controller.dispose();
        await database.close();
      }
    },
  );

  test(
    'rate-limited heartbeat still reads Presence; panel polling is GET-only',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final calls = <String>[];
      final api = ApiClient(
        baseUrl: 'https://presence.example.test',
        client: MockClient((request) async {
          calls.add(request.method);
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'PRESENCE_HEARTBEAT_RATE_LIMITED',
                  'message': 'presence heartbeat was recently renewed',
                  'request_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                },
              }),
              429,
              headers: {'content-type': 'application/json'},
            );
          }
          return _presenceResponse();
        }),
      )..accessToken = 'test-access-token';
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _PresenceSecureStore(),
            )
            ..api = api
            ..session = const AuthSession(
              accountId: '11111111-1111-4111-8111-111111111111',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              vaults: [],
            )
            ..stage = ClientStage.workspace
            ..activeVault = const VaultDescriptor(
              id: _firstVaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );

      try {
        await controller.refreshVaultPresence();
        expect(calls, ['POST', 'GET']);
        expect(controller.vaultPresenceDevices, hasLength(1));

        calls.clear();
        await Future.wait([
          controller.refreshVaultPresenceList(),
          controller.refreshVaultPresenceList(),
        ]);
        expect(calls, ['GET']);
      } finally {
        controller.dispose();
        await database.close();
      }
    },
  );

  test(
    'a Vault switch does not reuse a stale in-flight presence refresh',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final delayedFirstRead = Completer<http.Response>();
      var presenceReads = 0;
      final api = ApiClient(
        baseUrl: 'https://presence.example.test',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/presence') &&
              request.method == 'POST') {
            return _heartbeatResponse();
          }
          if (request.url.path.endsWith('/presence') &&
              request.method == 'GET') {
            presenceReads++;
            if (presenceReads == 1) return delayedFirstRead.future;
            return _presenceResponse(
              deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            );
          }
          return http.Response('{}', 200);
        }),
      )..accessToken = 'test-access-token';
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _PresenceSecureStore(),
            )
            ..api = api
            ..session = const AuthSession(
              accountId: '11111111-1111-4111-8111-111111111111',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              vaults: [],
            )
            ..stage = ClientStage.workspace
            ..activeVault = const VaultDescriptor(
              id: _firstVaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );

      try {
        final staleRefresh = controller.refreshVaultPresenceList();
        await Future<void>.delayed(Duration.zero);
        expect(presenceReads, 1);

        controller.activeVault = const VaultDescriptor(
          id: _secondVaultId,
          role: 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: false,
        );
        controller.stopVaultPresenceHeartbeatsForTesting();
        controller.activeVault = const VaultDescriptor(
          id: _firstVaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        controller.startVaultPresenceHeartbeatsForTesting();

        await controller.refreshVaultPresenceList();
        expect(presenceReads, 2);
        expect(
          controller.vaultPresenceDevices.single.deviceId,
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        );

        delayedFirstRead.complete(
          _presenceResponse(deviceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
        );
        await staleRefresh;
        expect(
          controller.vaultPresenceDevices.single.deviceId,
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          reason:
              'a response from the prior selection cannot replace fresh state',
        );
      } finally {
        if (!delayedFirstRead.isCompleted) {
          delayedFirstRead.complete(_presenceResponse());
        }
        controller.dispose();
        await database.close();
      }
    },
  );

  test('dispose cancels the periodic presence heartbeat', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final paths = <String>[];
    final api = ApiClient(
      baseUrl: 'https://presence.example.test',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/presence')) {
          paths.add(request.url.path);
          return _heartbeatResponse();
        }
        return http.Response('{}', 200);
      }),
    )..accessToken = 'test-access-token';
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: _PresenceSecureStore(),
            vaultPresenceHeartbeatIntervalForTesting: const Duration(
              milliseconds: 12,
            ),
          )
          ..api = api
          ..session = const AuthSession(
            accountId: '11111111-1111-4111-8111-111111111111',
            accessToken: 'test-access-token',
            expiresIn: 900,
            refreshToken: 'test-refresh-token',
            deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            vaults: [],
          )
          ..stage = ClientStage.workspace
          ..activeVault = const VaultDescriptor(
            id: _firstVaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    controller.startVaultPresenceHeartbeatsForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(paths, isNotEmpty);
    controller.dispose();
    final afterDispose = paths.length;
    await Future<void>.delayed(const Duration(milliseconds: 28));
    expect(paths.length, afterDispose);
    await database.close();
  });
}

http.Response _heartbeatResponse() => http.Response(
  jsonEncode({
    'expires_at': DateTime.now()
        .toUtc()
        .add(const Duration(seconds: 90))
        .toIso8601String(),
    'ttl_seconds': 90,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _presenceResponse({
  String deviceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) => http.Response(
  jsonEncode({
    'devices': [
      {
        'user_id': '11111111-1111-4111-8111-111111111111',
        'device_id': deviceId,
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      },
    ],
    'ttl_seconds': 90,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

class _PresenceSecureStore extends ClientSecureStore {
  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async => true;
}
