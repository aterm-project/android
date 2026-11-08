import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _requestedAt = '2026-09-27T00:00:00Z';
const _purgeAfter = '2026-10-04T00:00:00Z';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'successful deletion clears only local session and shows exact deadline',
    () async {
      final harness = _Harness(sodium);
      try {
        final response = await harness.app.scheduleAccountDeletion(
          username: 'User@Example.Test',
          password: 'correct horse battery staple',
        );
        expect(harness.api.preloginUsername, 'user@example.test');
        expect(harness.api.deleteBody?.keys, {'login_verifier'});
        expect(harness.api.deleteBody?['login_verifier'], isA<String>());
        expect(response.purgeAfter, _purgeAfter);
        expect(harness.app.accountDeletionPurgeAfter, _purgeAfter);
        expect(harness.app.noticeMessage, contains(_purgeAfter));
        expect(harness.app.session, isNull);
        expect(harness.app.account, isNull);
        expect(harness.app.identity, isNull);
        expect(harness.app.stage, ClientStage.login);
        expect(harness.api.accessToken, isNull);
        expect(harness.api.logoutCalls, 0);
        expect(harness.secureStore.deletedRefreshTokens, ['user@example.test']);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'account deletion clears immutable conflict, device, and SFTP snapshots',
    () async {
      final harness = _Harness(sodium);
      harness.app
        ..openConflicts = List.unmodifiable([
          {'conflict_id': 'conflict-1'},
        ])
        ..devices = List.unmodifiable([
          {'device_id': 'device-1'},
        ])
        ..sftpEntries = List.unmodifiable([
          SftpName(
            filename: 'file.txt',
            longname: '-rw-r--r-- file.txt',
            attr: SftpFileAttrs(),
          ),
        ]);
      try {
        await harness.app.scheduleAccountDeletion(
          username: 'user@example.test',
          password: 'correct horse battery staple',
        );

        expect(harness.app.openConflicts, isEmpty);
        expect(harness.app.devices, isEmpty);
        expect(harness.app.sftpEntries, isEmpty);
        expect(harness.app.stage, ClientStage.login);
        expect(harness.api.accessToken, isNull);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'shared Vault Owner rejection keeps the active session unchanged',
    () async {
      final harness = _Harness(sodium)..api.rejectSharedOwnerDeletion = true;
      final originalSession = harness.app.session;
      final originalIdentity = harness.app.identity;
      try {
        await expectLater(
          harness.app.scheduleAccountDeletion(
            username: 'user@example.test',
            password: 'correct horse battery staple',
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'ACCOUNT_OWNS_SHARED_VAULT',
            ),
          ),
        );
        expect(harness.app.session, same(originalSession));
        expect(harness.app.identity, same(originalIdentity));
        expect(harness.app.stage, ClientStage.workspace);
        expect(harness.api.accessToken, 'active-token');
        expect(harness.api.logoutCalls, 0);
        expect(harness.secureStore.deletedRefreshTokens, isEmpty);
        expect(harness.app.errorMessage, contains('共享 Vault Owner'));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'sessionless cancellation restores no session and requires sign-in',
    () async {
      final harness = _Harness(sodium, authenticated: false)
        ..api.accessToken = 'stale-revoked-token';
      try {
        final response = await harness.app.cancelAccountDeletion(
          username: 'User@Example.Test',
          password: 'correct horse battery staple',
        );
        expect(response.status, 'active');
        expect(harness.api.cancelUsername, 'user@example.test');
        expect(harness.api.cancelTokenAtRequest, isNull);
        expect(harness.api.loginCalls, 0);
        expect(harness.app.session, isNull);
        expect(harness.app.account, isNull);
        expect(harness.app.identity, isNull);
        expect(harness.app.stage, ClientStage.login);
        expect(harness.api.accessToken, isNull);
        expect(harness.app.noticeMessage, contains('重新输入密码登录'));
        expect(harness.secureStore.deletedRefreshTokens, ['user@example.test']);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'refresh-token cleanup failure does not reverse server cancellation',
    () async {
      final harness = _Harness(sodium, authenticated: false)
        ..secureStore.failRefreshTokenDeletion = true;
      try {
        final response = await harness.app.cancelAccountDeletion(
          username: 'user@example.test',
          password: 'correct horse battery staple',
        );
        expect(response.status, 'active');
        expect(harness.app.session, isNull);
        expect(harness.app.stage, ClientStage.login);
        expect(harness.api.cancelUsername, 'user@example.test');
        expect(harness.app.noticeMessage, contains('账户删除计划已撤销'));
        expect(harness.app.noticeMessage, contains('该 token 已在服务端撤销'));
        expect(harness.app.errorMessage, isNull);
      } finally {
        await harness.dispose();
      }
    },
  );
}

class _Harness {
  _Harness(this.sodium, {bool authenticated = true})
    : database = ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore = _MemorySecureStore(),
      api = _AccountDeletionApi() {
    app = AppController(
      sodium: sodium,
      database: database,
      secureStore: secureStore,
    )..api = api;
    api.accessToken = authenticated ? 'active-token' : null;
    if (authenticated) {
      app
        ..stage = ClientStage.workspace
        ..session = const AuthSession(
          accountId: _accountId,
          accessToken: 'active-token',
          expiresIn: 900,
          refreshToken: 'refresh-token',
          deviceId: 'device-id',
          vaults: [],
        )
        ..account = const AccountProfile(
          accountId: _accountId,
          deviceId: 'device-id',
          accountKeyEnvelopeVersion: 1,
          accountKeyEnvelope: {},
        )
        ..identity = DeviceIdentity.create(sodium);
    } else {
      app.stage = ClientStage.login;
    }
  }

  final SodiumSumo sodium;
  final ClientDatabase database;
  final _MemorySecureStore secureStore;
  final _AccountDeletionApi api;
  late final AppController app;

  Future<void> dispose() async {
    app.dispose();
    api.close();
    await database.close();
  }
}

class _MemorySecureStore extends ClientSecureStore {
  final List<String> deletedRefreshTokens = [];
  bool failRefreshTokenDeletion = false;

  @override
  Future<void> deleteRefreshToken(String baseUrl, String username) async {
    if (failRefreshTokenDeletion) {
      throw StateError('Secure storage unavailable');
    }
    deletedRefreshTokens.add(username);
  }
}

class _AccountDeletionApi extends ApiClient {
  _AccountDeletionApi()
    : super(
        baseUrl: 'https://account-delete.test',
        client: MockClient((request) async {
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );

  String? preloginUsername;
  String? cancelUsername;
  String? cancelTokenAtRequest;
  Map<String, Object?>? deleteBody;
  int logoutCalls = 0;
  int loginCalls = 0;
  bool rejectSharedOwnerDeletion = false;

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    preloginUsername = username;
    return {
      'account_id': _accountId,
      'kdf': KdfParameters(salt: Uint8List(16)).toJson(),
    };
  }

  @override
  Future<Map<String, dynamic>> deleteAccount(Map<String, Object?> body) async {
    deleteBody = Map<String, Object?>.from(body);
    if (rejectSharedOwnerDeletion) {
      throw const ApiException(
        statusCode: 409,
        code: 'ACCOUNT_OWNS_SHARED_VAULT',
        message: 'The account owns a shared Vault.',
      );
    }
    return {
      'status': 'deleting',
      'requested_at': _requestedAt,
      'purge_after': _purgeAfter,
      'can_cancel': true,
    };
  }

  @override
  Future<Map<String, dynamic>> cancelAccountDeletion({
    required String username,
    required Map<String, Object?> body,
  }) async {
    cancelUsername = username;
    cancelTokenAtRequest = accessToken;
    return const {
      'status': 'active',
      'requested_at': null,
      'purge_after': null,
      'can_cancel': false,
    };
  }

  @override
  Future<AuthLoginResult> login({
    required String username,
    required String loginVerifier,
    required String deviceId,
  }) async {
    loginCalls++;
    throw StateError('login must require a separate explicit action');
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    accessToken = null;
  }
}
