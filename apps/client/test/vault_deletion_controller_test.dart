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
import 'support/l10n_fixture.dart';

const _accountId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _requestedAt = '2026-09-26T12:00:00Z';
const _purgeAfter = '2026-10-03T12:00:00Z';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'scheduling deletion reauthenticates and applies server deadline',
    () async {
      final harness = _Harness(sodium);
      try {
        final updated = await harness.app.scheduleVaultDeletion(
          vaultId: _vaultId,
          username: 'OWNER@example.test',
          password: 'correct horse battery staple',
        );

        expect(harness.api.preloginUsername, 'owner@example.test');
        expect(harness.api.deleteCalls, 1);
        expect(harness.api.cancelCalls, 0);
        expect(harness.api.lastDeleteBody!.keys, {'login_verifier'});
        expect(
          base64Url.decode(
            base64Url.normalize(
              harness.api.lastDeleteBody!['login_verifier'] as String,
            ),
          ),
          hasLength(32),
        );
        expect(
          harness.api.lastDeleteBody!.values.single,
          isNot('correct horse battery staple'),
        );
        expect(updated.status, 'deleting');
        expect(updated.requestedAt, _requestedAt);
        expect(updated.purgeAfter, _purgeAfter);
        expect(updated.canCancel, isTrue);
        expect(updated.canWrite, isFalse);
        expect(harness.app.activeVault?.status, 'deleting');
        expect(harness.app.activeVault?.canWrite, isFalse);
        expect(harness.app.vaults.single.status, 'deleting');
        expect(harness.api.lastDeleteBody!.containsKey('password'), isFalse);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'cancel reauthenticates, restores write access, and retries pending sync',
    () async {
      final harness = _Harness(sodium);
      try {
        await harness.app.scheduleVaultDeletion(
          vaultId: _vaultId,
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );

        final restored = await harness.app.cancelVaultDeletion(
          vaultId: _vaultId,
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );

        expect(harness.api.cancelCalls, 1);
        expect(harness.api.lastCancelBody!.keys, {'login_verifier'});
        expect(restored.status, 'active');
        expect(restored.requestedAt, isNull);
        expect(restored.purgeAfter, isNull);
        expect(restored.canCancel, isFalse);
        expect(restored.canWrite, isTrue);
        expect(harness.app.activeVault?.status, 'active');
        expect(harness.app.activeVault?.canWrite, isTrue);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'wrong proof leaves deletion state unchanged and exposes a concrete error',
    () async {
      final harness = _Harness(sodium)..api.rejectDeleteProof = true;
      try {
        await expectLater(
          harness.app.scheduleVaultDeletion(
            vaultId: _vaultId,
            username: 'owner@example.test',
            password: 'wrong password that is long enough',
          ),
          throwsA(isA<ApiException>()),
        );

        expect(harness.app.activeVault?.status, 'active');
        expect(harness.app.activeVault?.canWrite, isTrue);
        expect(harness.app.errorMessage, contains('主密码验证失败'));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'a prelogin identity mismatch never submits the deletion request',
    () async {
      final harness = _Harness(sodium)..api.returnWrongAccount = true;
      try {
        await expectLater(
          harness.app.scheduleVaultDeletion(
            vaultId: _vaultId,
            username: 'other@example.test',
            password: 'correct horse battery staple',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(harness.api.deleteCalls, 0);
        expect(harness.app.activeVault?.status, 'active');
      } finally {
        await harness.dispose();
      }
    },
  );
}

class _Harness {
  _Harness(SodiumSumo sodium)
    : database = ClientDatabase.forTesting(NativeDatabase.memory()),
      api = _DeletionControllerApi(sodium) {
    app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..account = const AccountProfile(
            accountId: _accountId,
            deviceId: 'device-id',
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: {},
          )
          ..activeVault = _activeOwnerVault;
  }

  final ClientDatabase database;
  final _DeletionControllerApi api;
  late final AppController app;

  Future<void> dispose() async {
    app.dispose();
    api.close();
    await database.close();
  }
}

const VaultDescriptor _activeOwnerVault = VaultDescriptor(
  id: _vaultId,
  role: 'owner',
  activeKeyEpoch: '1',
  membershipVersion: '1',
);

class _DeletionControllerApi extends ApiClient {
  _DeletionControllerApi(this.sodium)
    : super(baseUrl: 'https://deletion-controller.example');

  final SodiumSumo sodium;
  String? preloginUsername;
  int deleteCalls = 0;
  int cancelCalls = 0;
  bool rejectDeleteProof = false;
  bool returnWrongAccount = false;
  Map<String, Object?>? lastDeleteBody;
  Map<String, Object?>? lastCancelBody;

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    preloginUsername = username;
    return {
      'account_id': returnWrongAccount
          ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
          : _accountId,
      'kdf': KdfParameters(salt: Uint8List(16)).toJson(),
    };
  }

  @override
  Future<Map<String, dynamic>> deleteVault(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    deleteCalls++;
    lastDeleteBody = Map<String, Object?>.from(body);
    if (rejectDeleteProof) {
      throw const ApiException(
        statusCode: 401,
        code: 'REAUTH_REQUIRED',
        message: 'Reauthentication is required.',
      );
    }
    return {
      'vault_id': vaultId,
      'status': 'deleting',
      'requested_at': _requestedAt,
      'purge_after': _purgeAfter,
      'can_cancel': true,
      'can_write': false,
    };
  }

  @override
  Future<Map<String, dynamic>> cancelVaultDeletion(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    cancelCalls++;
    lastCancelBody = Map<String, Object?>.from(body);
    return {
      'vault_id': vaultId,
      'status': 'active',
      'requested_at': null,
      'purge_after': null,
      'can_cancel': false,
      'can_write': true,
    };
  }

  @override
  Future<List<VaultDescriptor>> vaults() async => [_activeOwnerVault];
}
