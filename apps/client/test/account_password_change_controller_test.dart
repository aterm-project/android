import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _username = 'user@example.test';
const _currentPassword = 'correct horse battery staple';
const _newPassword = 'new secure master password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'validates password inputs and rejects a wrong current password',
    () async {
      final harness = await _Harness.create(sodium);
      try {
        await expectLater(
          harness.app.changeAccountPassword(
            currentPassword: _currentPassword,
            newPassword: _newPassword,
            confirmationPassword: 'different secure master password',
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          harness.app.changeAccountPassword(
            currentPassword: _currentPassword,
            newPassword: 'short',
            confirmationPassword: 'short',
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          harness.app.changeAccountPassword(
            currentPassword: 'wrong current master password',
            newPassword: _newPassword,
            confirmationPassword: _newPassword,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(harness.api.changeCalls, 0);
        expect(harness.app.accountPasswordChangePending, isFalse);
        expect(harness.app.account, same(harness.initialProfile));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'retains one exact request after response loss and refreshes on retry',
    () async {
      final harness = await _Harness.create(sodium)
        ..api.dropFirstResponse = true;
      try {
        await expectLater(
          harness.app.changeAccountPassword(
            currentPassword: _currentPassword,
            newPassword: _newPassword,
            confirmationPassword: _newPassword,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(harness.api.changeCalls, 1);
        expect(harness.app.accountPasswordChangePending, isTrue);
        expect(harness.app.account, same(harness.initialProfile));
        expect(harness.api.profileReads, 0);

        final firstRequest = harness.api.requests.single;
        final firstJson = harness.api.requestJson.single;
        expect(firstRequest.keys, {
          'operation_id',
          'current_login_verifier',
          'new_kdf',
          'new_login_verifier',
          'account_key_envelope',
        });
        expect(firstJson, isNot(contains(_currentPassword)));
        expect(firstJson, isNot(contains(_newPassword)));
        expect(firstJson, isNot(contains('confirmationPassword')));
        expect(
          firstRequest['operation_id'],
          matches(RegExp(r'^[0-9a-f-]{36}$')),
        );
        expect(
          base64Url.decode(
            base64Url.normalize(
              firstRequest['current_login_verifier'] as String,
            ),
          ),
          hasLength(32),
        );
        expect(
          base64Url.decode(
            base64Url.normalize(firstRequest['new_login_verifier'] as String),
          ),
          hasLength(32),
        );

        final newParams = KdfParameters.fromJson(
          Map<String, dynamic>.from(firstRequest['new_kdf'] as Map),
        );
        final wrappedAccountKey = Map<String, dynamic>.from(
          firstRequest['account_key_envelope'] as Map,
        );
        final recoveredAccountKey = await harness.app.crypto.unwrapAccountKey(
          password: _newPassword,
          params: newParams,
          envelope: wrappedAccountKey,
        );
        try {
          expect(recoveredAccountKey, harness.accountKey);
        } finally {
          recoveredAccountKey.fillRange(0, recoveredAccountKey.length, 0);
          newParams.salt.fillRange(0, newParams.salt.length, 0);
        }

        await harness.app.retryAccountPasswordChange();
        expect(harness.api.changeCalls, 2);
        expect(harness.api.requests[1], same(firstRequest));
        expect(harness.api.requestJson[1], firstJson);
        expect(
          harness.api.requests[1]['operation_id'],
          firstRequest['operation_id'],
        );
        expect(harness.api.profileReads, 1);
        expect(harness.app.accountPasswordChangePending, isFalse);
        expect(harness.app.account?.accountKeyEnvelopeVersion, 2);
        expect(
          harness.app.account?.accountKeyEnvelope,
          firstRequest['account_key_envelope'],
        );
        expect(harness.api.lastReceipt?.alreadyApplied, isTrue);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('logout clears an unconfirmed retry request', () async {
    final harness = await _Harness.create(sodium)
      ..api.dropFirstResponse = true;
    try {
      await expectLater(
        harness.app.changeAccountPassword(
          currentPassword: _currentPassword,
          newPassword: _newPassword,
          confirmationPassword: _newPassword,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(harness.app.accountPasswordChangePending, isTrue);
      await harness.app.logout();
      expect(harness.api.logoutCalls, 1);
      expect(harness.app.accountPasswordChangePending, isFalse);
      expect(harness.app.session, isNull);
    } finally {
      await harness.dispose();
    }
  });
}

class _Harness {
  _Harness({
    required this.database,
    required this.api,
    required this.app,
    required this.initialProfile,
    required this.accountKey,
  });

  final ClientDatabase database;
  final _PasswordChangeApi api;
  final _PasswordChangeController app;
  final AccountProfile initialProfile;
  final Uint8List accountKey;

  static Future<_Harness> create(SodiumSumo sodium) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _PasswordChangeApi();
    final app = _PasswordChangeController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    )..api = api;
    final oldParams = KdfParameters(
      salt: Uint8List.fromList(List.filled(16, 7)),
    );
    final accountKey = Uint8List.fromList(List.generate(32, (index) => index));
    final envelope = await app.crypto.wrapAccountKey(
      password: _currentPassword,
      params: oldParams,
      accountKey: accountKey,
    );
    oldParams.salt.fillRange(0, oldParams.salt.length, 0);
    final profile = AccountProfile(
      accountId: _accountId,
      deviceId: _deviceId,
      accountKeyEnvelopeVersion: 1,
      accountKeyEnvelope: Map<String, dynamic>.from(envelope),
    );
    app
      ..testUsername = _username
      ..stage = ClientStage.workspace
      ..session = const AuthSession(
        accountId: _accountId,
        accessToken: 'active-token',
        expiresIn: 900,
        refreshToken: 'refresh-token',
        deviceId: _deviceId,
        vaults: [],
      )
      ..account = profile;
    api
      ..kdf = KdfParameters(salt: Uint8List.fromList(List.filled(16, 7)))
      ..profile = profile;
    api.accessToken = 'active-token';
    return _Harness(
      database: database,
      api: api,
      app: app,
      initialProfile: profile,
      accountKey: accountKey,
    );
  }

  Future<void> dispose() async {
    accountKey.fillRange(0, accountKey.length, 0);
    app.dispose();
    api.close();
    await database.close();
  }
}

class _PasswordChangeController extends AppController {
  _PasswordChangeController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  String? testUsername;

  @override
  String? get authenticatedUsername => testUsername;
}

class _PasswordChangeApi extends ApiClient {
  _PasswordChangeApi()
    : super(baseUrl: 'https://password-change-controller.test');

  late KdfParameters kdf;
  late AccountProfile profile;
  int changeCalls = 0;
  int profileReads = 0;
  int logoutCalls = 0;
  bool dropFirstResponse = false;
  String? preloginUsername;
  PasswordChangeReceipt? lastReceipt;
  final List<Map<String, Object?>> requests = [];
  final List<String> requestJson = [];

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    preloginUsername = username;
    return {'account_id': _accountId, 'kdf': kdf.toJson()};
  }

  @override
  Future<PasswordChangeReceipt> changePassword(
    Map<String, Object?> body,
  ) async {
    changeCalls++;
    requests.add(body);
    requestJson.add(jsonEncode(body));
    if (changeCalls == 1 && dropFirstResponse) {
      final envelope = Map<String, dynamic>.from(
        body['account_key_envelope'] as Map,
      );
      profile = AccountProfile(
        accountId: _accountId,
        deviceId: _deviceId,
        accountKeyEnvelopeVersion: 2,
        accountKeyEnvelope: envelope,
      );
      throw TimeoutException('simulated response loss');
    }
    final operationId = body['operation_id'] as String;
    profile = AccountProfile(
      accountId: _accountId,
      deviceId: _deviceId,
      accountKeyEnvelopeVersion: 2,
      accountKeyEnvelope: Map<String, dynamic>.from(
        body['account_key_envelope'] as Map,
      ),
    );
    lastReceipt = PasswordChangeReceipt(
      operationId: operationId,
      credentialVersion: 2,
      alreadyApplied: changeCalls > 1,
    );
    return lastReceipt!;
  }

  @override
  Future<AccountProfile> accountProfile() async {
    profileReads++;
    return profile;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    accessToken = null;
  }
}
