import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _nextRecoveryCode = 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'rotated recovery code is accessible only in its confirmation modal',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _RecoveryAuthController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
      )..stage = ClientStage.login;

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AuthFlow(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const ValueKey('account_recovery_open')),
        );
        await tester.tap(find.byKey(const ValueKey('account_recovery_open')));
        await tester.pumpAndSettle();

        await tester.enterText(_field('Account name'), 'alice@example.test');
        await tester.enterText(
          _field('Recovery code'),
          'previous-recovery-code',
        );
        await tester.enterText(
          _field('New master password · 12+ characters'),
          'new secure master password',
        );
        await tester.enterText(
          _field('Confirm new master password'),
          'new secure master password',
        );
        await tester.enterText(_field('New device name'), 'Recovery browser');
        await tester.tap(find.text('Verify recovery code'));
        await tester.pumpAndSettle();

        expect(find.text('Store the new recovery code'), findsOneWidget);
        expect(find.text(_nextRecoveryCode), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('full_recovery_new_code_semantics')),
              )
              .label,
          contains(_nextRecoveryCode),
        );

        await tester.tap(find.text('I stored this code securely'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Commit recovery'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('full_recovery_new_code_semantics')),
          findsNothing,
        );
        expect(find.text(_nextRecoveryCode), findsNothing);
        expect(app.completedRecovery, isTrue);
        expect(app.preparedUsername, 'alice@example.test');
        expect(app.preparedDeviceName, 'Recovery browser');
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

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'text field "$label"',
);

class _RecoveryAuthController extends AppController {
  _RecoveryAuthController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  String? preparedUsername;
  String? preparedDeviceName;
  bool completedRecovery = false;

  @override
  Future<AccountRecoveryPreparation> prepareFullAccountRecovery({
    required String username,
    required String recoveryCode,
    required String newPassword,
    required String confirmationPassword,
    required String deviceName,
  }) async {
    expect(recoveryCode, 'previous-recovery-code');
    expect(newPassword, 'new secure master password');
    expect(confirmationPassword, newPassword);
    preparedUsername = username;
    preparedDeviceName = deviceName;
    return const AccountRecoveryPreparation(
      recoveryCode: _nextRecoveryCode,
      recoveredContexts: 1,
    );
  }

  @override
  Future<void> completePreparedAccountRecovery() async {
    completedRecovery = true;
  }

  @override
  Future<void> cancelPreparedAccountRecovery({
    bool force = false,
    bool clearStoredPending = true,
  }) async {}
}
