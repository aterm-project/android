import 'support/settings_navigation.dart';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _recoveryCode = 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'account recovery code is semantic only while the one-time dialog is open',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _RecoverySettingsController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..account = const AccountProfile(
              accountId: _accountId,
              deviceId: _deviceId,
              accountKeyEnvelopeVersion: 1,
              accountKeyEnvelope: {},
            )
            ..session = const AuthSession(
              accountId: _accountId,
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: _deviceId,
              vaults: [],
            );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('cloud_settings'))
            .evaluate()
            .isNotEmpty) {
          await openSettingsCategory(tester, 'security', ifAvailable: true);
        }
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const ValueKey('account_recovery_configure')),
        );
        await tester.tap(
          find.byKey(const ValueKey('account_recovery_configure')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'current password');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Store your recovery code'), findsOneWidget);
        expect(find.text(_recoveryCode), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('account_recovery_code_semantics')),
              )
              .label,
          contains(_recoveryCode),
        );

        await tester.tap(find.text('I stored this code securely'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Finish'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('account_recovery_code_semantics')),
          findsNothing,
        );
        expect(find.text(_recoveryCode), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}

class _RecoverySettingsController extends AppController {
  _RecoverySettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  @override
  String? get authenticatedUsername => 'alice@example.test';

  @override
  Future<AccountMfaStatus> refreshAccountMfaStatus() async {
    accountMfaEnabled = false;
    accountMfaRecoveryCodesRemaining = 0;
    return const AccountMfaStatus(enabled: false, recoveryCodesRemaining: 0);
  }

  @override
  Future<AccountRecoverySetupResult> configureAccountRecovery({
    required String currentPassword,
  }) async {
    expect(currentPassword, 'current password');
    accountRecoveryStatus = 'current';
    notifyListeners();
    return const AccountRecoverySetupResult(
      recoveryCode: _recoveryCode,
      status: 'current',
      coveredContexts: 1,
      requiredContexts: 1,
    );
  }
}
