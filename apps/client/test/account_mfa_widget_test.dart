import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/account_mfa_panel.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _password = 'correct horse battery staple';
const _secret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';
const _recoveryCodes = <String>[
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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MFA login waits for TOTP and can switch to a recovery code', (
    tester,
  ) async {
    final harness = await _AuthHarness.create();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AuthFlow(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'alice@example.test',
      );
      await tester.enterText(find.byType(TextField).at(1), _password);
      await tester.ensureVisible(find.text('Sign in and unlock'));
      await tester.tap(find.text('Sign in and unlock'));
      await tester.pumpAndSettle();

      expect(find.text('Verify your identity'), findsOneWidget);
      expect(find.text('Authenticator code'), findsOneWidget);
      expect(find.text('Sign in and unlock'), findsNothing);
      expect(harness.app.stage, ClientStage.login);
      expect(harness.app.session, isNull);

      await tester.tap(find.byKey(const ValueKey('mfa_use_recovery_code')));
      await tester.pumpAndSettle();
      expect(find.text('Recovery code'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('mfa_recovery_code')),
        'abcd-efgh-jklm-npqr',
      );
      await tester.tap(find.byKey(const ValueKey('mfa_login_continue')));
      await tester.pumpAndSettle();

      expect(harness.app.completedChallenge, 'challenge-1');
      expect(harness.app.completedCode, 'ABCD-EFGH-JKLM-NPQR');
      expect(harness.app.usedRecoveryCode, isTrue);
      expect(harness.app.completedPassword, _password);
      expect(harness.app.stage, ClientStage.workspace);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('MFA challenge errors describe an invalid or expired factor', (
    tester,
  ) async {
    final harness = await _AuthHarness.create();
    harness.app.mfaLoginError = const ApiException(
      statusCode: 401,
      code: 'AUTH_REQUIRED',
      message: 'Authentication is required.',
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AuthFlow(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'alice@example.test',
      );
      await tester.enterText(find.byType(TextField).at(1), _password);
      await tester.ensureVisible(find.text('Sign in and unlock'));
      await tester.tap(find.text('Sign in and unlock'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '123456',
      );
      await tester.tap(find.byKey(const ValueKey('mfa_login_continue')));
      await tester.pumpAndSettle();

      expect(
        find.text('MFA verification failed: the code is invalid or already used, or the sign-in challenge expired. Sign in again and enter a new code.'),
        findsOneWidget,
      );
      expect(find.text('The sign-in state expired. Sign in again.'), findsNothing);
      expect(harness.app.stage, ClientStage.login);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('Settings enrollment shows recovery codes once and clears them', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: AccountMfaPanel(app: harness.app)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Two-factor sign-in'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mfa_enable')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, _password);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('mfa_totp_setup_secret')),
        findsOneWidget,
      );
      expect(find.text(_secret), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('mfa_totp_setup_secret_semantics')),
            )
            .label,
        contains(_secret),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('mfa_totp_setup_uri_semantics')),
            )
            .label,
        contains('otpauth://totp/Atermius:alice'),
      );
      expect(
        find.textContaining('otpauth://totp/Atermius:alice'),
        findsOneWidget,
      );
      // The setup field must send the contract's six digits even if a paste
      // contains extra digits.
      await tester.enterText(find.byType(TextField).last, '12345678');
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mfa_totp_code')))
            .controller
            ?.text,
        '123456',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Verify and enable'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Verify and enable'));
      await tester.pumpAndSettle();

      expect(find.text(_secret), findsNothing);
      expect(
        find.byKey(const ValueKey('mfa_totp_setup_secret_semantics')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mfa_totp_setup_uri_semantics')),
        findsNothing,
      );
      expect(harness.app.confirmPassword, _password);
      expect(harness.app.confirmTotp, '123456');
      expect(find.text('Save your MFA recovery codes'), findsOneWidget);
      for (final recoveryCode in _recoveryCodes) {
        expect(find.text(recoveryCode), findsNothing);
      }
      expect(
        find.byKey(const ValueKey('mfa_recovery_codes_once')),
        findsOneWidget,
      );
      expect(find.text(_recoveryCodes.join('\n')), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('mfa_recovery_codes_once_semantics')),
            )
            .label,
        contains(_recoveryCodes.join('\n')),
      );

      await tester.tap(find.text('I saved these codes securely'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('mfa_recovery_codes_once_semantics')),
        findsNothing,
      );
      expect(find.text(_recoveryCodes.join('\n')), findsNothing);
      expect(find.text('Enabled'), findsOneWidget);
      expect(find.text('Two-factor sign-in is enabled.'), findsOneWidget);
      expect(harness.setupMaterial?.secret, isNull);
      expect(harness.setupMaterial?.provisioningUri, isNull);
      expect(harness.codesMaterial?.codes, isEmpty);
      expect(harness.app.accountMfaEnabled, isTrue);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('recovery-code rotation and disable accept only six digits', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();
    harness.app.accountMfaEnabled = true;
    harness.app.accountMfaRecoveryCodesRemaining = 10;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: AccountMfaPanel(app: harness.app)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('mfa_rotate_recovery_codes')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mfa_current_password')),
        _password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '12345',
      );
      await tester.pump();
      expect(find.text('Enter exactly six digits.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Rotate codes'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '12345678',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mfa_totp_code')))
            .controller
            ?.text,
        '123456',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Rotate codes'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Rotate codes'));
      await tester.pumpAndSettle();
      expect(harness.app.rotatedTotp, '123456');
      expect(find.text('Save your MFA recovery codes'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('mfa_disable')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mfa_current_password')),
        _password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '1234',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Disable MFA'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '98a7654',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Disable MFA'));
      await tester.pumpAndSettle();

      expect(harness.app.disabledTotp, '987654');
      expect(harness.app.accountMfaEnabled, isFalse);
      expect(find.text('Two-factor sign-in was disabled.'), findsOneWidget);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('MFA settings reauthentication errors describe the factor', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();
    harness.app
      ..accountMfaEnabled = true
      ..accountMfaRecoveryCodesRemaining = 10
      ..rejectRotationProof = true;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: AccountMfaPanel(app: harness.app)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mfa_rotate_recovery_codes')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mfa_current_password')),
        _password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('mfa_totp_code')),
        '123456',
      );
      await tester.pump();
      await tester.tap(find.text('Rotate codes'));
      await tester.pumpAndSettle();

      expect(find.text('The current master password or six-digit authenticator code is invalid or already used. Enter the master password and a new six-digit code again.'), findsOneWidget);
      expect(find.textContaining('删除计划未更改'), findsNothing);
    } finally {
      harness.dispose();
    }
  });
}

class _AuthHarness {
  _AuthHarness(this.app, this.database);

  final _AuthController app;
  final ClientDatabase database;

  static Future<_AuthHarness> create() async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _AuthController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.login;
    return _AuthHarness(app, database);
  }

  void dispose() {
    app.dispose();
    unawaited(database.close());
  }
}

class _AuthController extends AppController {
  _AuthController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  String? completedChallenge;
  String? completedCode;
  String? completedPassword;
  bool usedRecoveryCode = false;
  ApiException? mfaLoginError;

  @override
  Future<MfaLoginChallenge?> login({
    required String username,
    required String password,
  }) async => MfaLoginChallenge(
    challengeId: 'challenge-1',
    expiresAt: DateTime.utc(2026, 10, 2, 15),
    methods: {'totp', 'recovery_code'},
  );

  @override
  Future<void> completeMfaLogin({
    required String username,
    required String password,
    required MfaLoginChallenge challenge,
    required String code,
    required bool useRecoveryCode,
  }) async {
    final failure = mfaLoginError;
    if (failure != null) {
      errorMessage = friendlyMfaLoginError(failure);
      notifyListeners();
      throw failure;
    }
    completedChallenge = challenge.challengeId;
    completedCode = code;
    completedPassword = password;
    usedRecoveryCode = useRecoveryCode;
    stage = ClientStage.workspace;
    notifyListeners();
  }
}

class _SettingsHarness {
  _SettingsHarness(this.app, this.database);

  final _SettingsController app;
  final ClientDatabase database;

  MfaTotpSetup? get setupMaterial => app.setupMaterial;
  MfaRecoveryCodes? get codesMaterial => app.codesMaterial;

  static Future<_SettingsHarness> create() async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _SettingsController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    );
    return _SettingsHarness(app, database);
  }

  void dispose() {
    app.dispose();
    unawaited(database.close());
  }
}

class _SettingsController extends AppController {
  _SettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  MfaTotpSetup? setupMaterial;
  MfaRecoveryCodes? codesMaterial;
  String? confirmPassword;
  String? confirmTotp;
  String? rotatedTotp;
  String? disabledTotp;
  bool rejectRotationProof = false;

  @override
  Future<AccountMfaStatus> refreshAccountMfaStatus() async {
    accountMfaEnabled ??= false;
    accountMfaRecoveryCodesRemaining ??= 0;
    notifyListeners();
    return AccountMfaStatus(
      enabled: accountMfaEnabled!,
      recoveryCodesRemaining: accountMfaRecoveryCodesRemaining!,
    );
  }

  @override
  Future<MfaTotpSetup> beginMfaTotpSetup({
    required String currentPassword,
  }) async {
    expect(currentPassword, _password);
    setupMaterial = MfaTotpSetup(
      secret: _secret,
      provisioningUri:
          'otpauth://totp/Atermius:alice?secret=$_secret&issuer=Atermius',
      expiresAt: DateTime.utc(2026, 10, 2, 15),
    );
    return setupMaterial!;
  }

  @override
  Future<MfaRecoveryCodes> confirmMfaTotp({
    required String currentPassword,
    required String totpCode,
  }) async {
    confirmPassword = currentPassword;
    confirmTotp = totpCode;
    accountMfaEnabled = true;
    accountMfaRecoveryCodesRemaining = 10;
    codesMaterial = MfaRecoveryCodes(_recoveryCodes);
    notifyListeners();
    return codesMaterial!;
  }

  @override
  Future<MfaRecoveryCodes> rotateMfaRecoveryCodes({
    required String currentPassword,
    required String totpCode,
  }) async {
    if (rejectRotationProof) {
      throw const ApiException(
        statusCode: 401,
        code: 'REAUTH_REQUIRED',
        message: 'Reauthentication is required.',
      );
    }
    rotatedTotp = totpCode;
    accountMfaEnabled = true;
    accountMfaRecoveryCodesRemaining = 10;
    codesMaterial = MfaRecoveryCodes(_recoveryCodes);
    notifyListeners();
    return codesMaterial!;
  }

  @override
  Future<void> disableMfaTotp({
    required String currentPassword,
    required String totpCode,
  }) async {
    disabledTotp = totpCode;
    accountMfaEnabled = false;
    accountMfaRecoveryCodesRemaining = 0;
    notifyListeners();
  }
}
