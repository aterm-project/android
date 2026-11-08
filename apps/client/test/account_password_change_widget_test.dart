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
const _vaultId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Settings validates password confirmation and clears fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _PasswordSettingsController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
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
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'security', ifAvailable: true);
      }

      final currentField = _field('Current master password');
      final newField = _field('New master password');
      final confirmationField = _field('Confirm new master password');
      for (final field in [currentField, newField, confirmationField]) {
        expect(tester.widget<TextField>(field).obscureText, isTrue);
      }

      await tester.enterText(currentField, 'current password fixture');
      await tester.enterText(newField, 'new password fixture');
      await tester.enterText(confirmationField, 'mismatched fixture');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Change master password'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('The new master passwords do not match.'),
        findsOneWidget,
      );
      expect(app.changeCalls, 0);

      await tester.enterText(confirmationField, 'new password fixture');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Change master password'),
      );
      await tester.pumpAndSettle();
      expect(app.changeCalls, 1);
      expect(app.receivedCurrentPassword, 'current password fixture');
      expect(app.receivedNewPassword, 'new password fixture');
      expect(app.receivedConfirmationPassword, 'new password fixture');
      expect(
        find.text('Master password changed. Other sessions were revoked.'),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(currentField).controller?.text, isEmpty);
      expect(tester.widget<TextField>(newField).controller?.text, isEmpty);
      expect(
        tester.widget<TextField>(confirmationField).controller?.text,
        isEmpty,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'password field "$label"',
);

class _PasswordSettingsController extends AppController {
  _PasswordSettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  int changeCalls = 0;
  String? receivedCurrentPassword;
  String? receivedNewPassword;
  String? receivedConfirmationPassword;

  @override
  String? get authenticatedUsername => 'user@example.test';

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmationPassword,
  }) async {
    changeCalls++;
    receivedCurrentPassword = currentPassword;
    receivedNewPassword = newPassword;
    receivedConfirmationPassword = confirmationPassword;
  }
}
