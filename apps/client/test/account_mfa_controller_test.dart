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
import 'support/l10n_fixture.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _username = 'alice@example.test';
const _password = 'correct horse battery staple';
const _secret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';
const _codes = <String>[
  'ABCD-EFGH-JKLM-NPQR',
  'BCDE-FGHJ-KLMN-PQRS',
  'CDEF-GHJK-LMNP-QRST',
  'DEFG-HJKM-NPQR-STUV',
  'EFGH-JKMN-PQRS-TUVW',
  'FGHJ-KMNP-QRST-UVWX',
  'GHJK-MNPQ-RSTU-VWXY',
  'HJKM-NPQR-STUV-WXYZ',
  'JKLM-PQRS-TUVW-XYZ2',
  'KLMN-QRST-UVWX-YZ23',
];

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'MFA controller derives only the verifier and retains status only',
    () async {
      final harness = await _Harness.create(sodium);
      Uint8List? expectedVerifier;
      try {
        expectedVerifier = await harness.app.crypto.deriveLoginVerifier(
          _password,
          harness.api.kdf,
        );

        final status = await harness.app.refreshAccountMfaStatus();
        expect(status.enabled, isFalse);
        expect(status.recoveryCodesRemaining, 0);
        expect(harness.app.accountMfaEnabled, isFalse);
        expect(harness.app.accountMfaRecoveryCodesRemaining, 0);

        final setup = await harness.app.beginMfaTotpSetup(
          currentPassword: _password,
        );
        expect(setup.secret, _secret);
        expect(harness.api.setupVerifier, isNot(contains(_password)));
        _expectVerifier(harness.api.setupVerifier!, expectedVerifier);

        final confirmed = await harness.app.confirmMfaTotp(
          currentPassword: _password,
          totpCode: '123456',
        );
        expect(confirmed.codes, _codes);
        expect(harness.api.confirmTotp, '123456');
        _expectVerifier(harness.api.confirmVerifier!, expectedVerifier);
        expect(harness.app.accountMfaEnabled, isTrue);
        expect(harness.app.accountMfaRecoveryCodesRemaining, 10);

        final rotated = await harness.app.rotateMfaRecoveryCodes(
          currentPassword: _password,
          totpCode: '654321',
        );
        expect(rotated.codes, _codes);
        expect(harness.api.rotateTotp, '654321');
        _expectVerifier(harness.api.rotateVerifier!, expectedVerifier);

        await harness.app.disableMfaTotp(
          currentPassword: _password,
          totpCode: '111111',
        );
        expect(harness.api.disableTotp, '111111');
        _expectVerifier(harness.api.disableVerifier!, expectedVerifier);
        expect(harness.app.accountMfaEnabled, isFalse);
        expect(harness.app.accountMfaRecoveryCodesRemaining, 0);

        // The caller owns the mutable one-time responses; the controller has
        // no fields for the TOTP seed or plaintext recovery-code set.
        setup.clear();
        confirmed.clear();
        rotated.clear();
        expect(setup.secret, isNull);
        expect(confirmed.codes, isEmpty);
        expect(rotated.codes, isEmpty);
        expect(harness.app.accountMfaBusy, isFalse);
      } finally {
        expectedVerifier?.fillRange(0, expectedVerifier.length, 0);
        await harness.dispose();
      }
    },
  );

  test('MFA controller error messages describe factor failures', () async {
    final harness = await _Harness.create(sodium);
    try {
      final settingsMessage = harness.app.friendlyMfaSettingsError(
        const ApiException(
          statusCode: 401,
          code: 'REAUTH_REQUIRED',
          message: 'Reauthentication is required.',
        ),
      );
      expect(settingsMessage, contains('六位验证器代码'));
      expect(settingsMessage, contains('已使用'));
      expect(settingsMessage, isNot(contains('删除计划')));

      final loginMessage = harness.app.friendlyMfaLoginError(
        const ApiException(
          statusCode: 401,
          code: 'AUTH_REQUIRED',
          message: 'Authentication is required.',
        ),
      );
      expect(loginMessage, contains('MFA 验证失败'));
      expect(loginMessage, contains('登录挑战已过期'));
      expect(loginMessage, isNot(contains('登录状态已过期')));
    } finally {
      await harness.dispose();
    }
  });
}

void _expectVerifier(String actual, Uint8List expected) {
  final bytes = base64Url.decode(base64Url.normalize(actual));
  try {
    expect(bytes, expected);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

class _Harness {
  _Harness(this.app, this.api, this.database);

  final _MfaController app;
  final _MfaApi api;
  final ClientDatabase database;

  static Future<_Harness> create(SodiumSumo sodium) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _MfaApi();
    final app = _MfaController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    )..api = api;
    app
      ..authenticatedUsernameForTesting = _username
      ..stage = ClientStage.workspace
      ..session = const AuthSession(
        accountId: _accountId,
        accessToken: 'active-token',
        expiresIn: 900,
        refreshToken: 'refresh-token',
        deviceId: _deviceId,
        vaults: [],
      )
      ..account = AccountProfile(
        accountId: _accountId,
        deviceId: _deviceId,
        accountKeyEnvelopeVersion: 1,
        accountKeyEnvelope: const {},
      );
    api.accessToken = 'active-token';
    return _Harness(app, api, database);
  }

  Future<void> dispose() async {
    app.dispose();
    api.close();
    await database.close();
  }
}

class _MfaController extends AppController {
  _MfaController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
}

class _MfaApi extends ApiClient {
  _MfaApi() : super(baseUrl: 'https://mfa-controller.test');

  final kdf = KdfParameters(salt: Uint8List.fromList(List.filled(16, 7)));
  String? setupVerifier;
  String? confirmVerifier;
  String? confirmTotp;
  String? rotateVerifier;
  String? rotateTotp;
  String? disableVerifier;
  String? disableTotp;

  @override
  Future<Map<String, dynamic>> prelogin(String username) async => {
    'account_id': _accountId,
    'kdf': kdf.toJson(),
  };

  @override
  Future<AccountMfaStatus> accountMfaStatus() async =>
      const AccountMfaStatus(enabled: false, recoveryCodesRemaining: 0);

  @override
  Future<MfaTotpSetup> setupMfaTotp(String currentLoginVerifier) async {
    setupVerifier = currentLoginVerifier;
    return MfaTotpSetup(
      secret: _secret,
      provisioningUri:
          'otpauth://totp/Atermius:alice?secret=$_secret&issuer=Atermius',
      expiresAt: DateTime.utc(2026, 10, 2, 15),
    );
  }

  @override
  Future<MfaRecoveryCodes> confirmMfaTotp({
    required String currentLoginVerifier,
    required String totpCode,
  }) async {
    confirmVerifier = currentLoginVerifier;
    confirmTotp = totpCode;
    return MfaRecoveryCodes(_codes);
  }

  @override
  Future<MfaRecoveryCodes> rotateMfaRecoveryCodes({
    required String currentLoginVerifier,
    required String totpCode,
  }) async {
    rotateVerifier = currentLoginVerifier;
    rotateTotp = totpCode;
    return MfaRecoveryCodes(_codes);
  }

  @override
  Future<AccountMfaStatus> disableMfaTotp({
    required String currentLoginVerifier,
    required String totpCode,
  }) async {
    disableVerifier = currentLoginVerifier;
    disableTotp = totpCode;
    return const AccountMfaStatus(enabled: false, recoveryCodesRemaining: 0);
  }
}
