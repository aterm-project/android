import 'support/settings_navigation.dart';

import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _purgeAfter = '2026-10-04T00:00:00Z';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('login recovery stays sessionless and asks for a new sign-in', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _RecoveryApi();
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: _MemorySecureStore(),
          )
          ..api = api
          ..stage = ClientStage.login;
    try {
      await tester.pumpWidget(AtermiusApp(controller: controller));
      expect(find.text('Cancel scheduled account deletion'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), 'user@example.test');
      await tester.enterText(
        find.byType(TextField).at(1),
        'correct horse battery staple',
      );
      final cancelButton = find.text('Cancel scheduled account deletion');
      await tester.ensureVisible(cancelButton);
      await tester.pumpAndSettle();
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();

      expect(api.cancelCalls, 1);
      expect(api.loginCalls, 0);
      expect(controller.session, isNull);
      expect(controller.stage, ClientStage.login);
      expect(api.accessToken, isNull);
      expect(find.textContaining('重新输入密码登录'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
      await database.close();
    }
  });

  testWidgets('Settings exposes the account deletion confirmation action', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: _MemorySecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'security', ifAvailable: true);
      }
      await tester.pump();

      expect(find.text('Account deletion'), findsOneWidget);
      expect(find.text('Schedule account deletion'), findsOneWidget);
      expect(
        find.textContaining('Other members’ shared Vault data is not deleted.'),
        findsOneWidget,
      );
    } finally {
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Settings deletion confirms twice and reports server deadline', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _RecoveryApi();
    final secureStore = _MemorySecureStore();
    final controller = _NamedController(
      sodium: sodium,
      database: database,
      secureStore: secureStore,
    )..api = api;
    controller
      ..stage = ClientStage.workspace
      ..page = WorkspacePage.settings
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
    controller
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
    api.accessToken = 'active-token';

    try {
      await tester.pumpWidget(AtermiusApp(controller: controller));
      final deleteButton = find.text('Schedule account deletion');
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(find.text('Schedule account deletion?'), findsOneWidget);
      await tester.tap(find.text('Continue to final confirmation'));
      await tester.pumpAndSettle();
      expect(find.text('Type DELETE to confirm'), findsOneWidget);
      expect(find.text('Re-enter account master password'), findsOneWidget);

      final confirmationField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Type DELETE to confirm',
      );
      final passwordField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Re-enter account master password',
      );
      await tester.enterText(confirmationField, 'DELETE');
      await tester.enterText(passwordField, 'correct horse battery staple');
      await tester.pump();
      expect(
        tester.widget<TextField>(confirmationField).controller?.text,
        'DELETE',
      );
      expect(
        tester.widget<TextField>(passwordField).controller?.text,
        'correct horse battery staple',
      );
      expect(controller.accountLifecycleBusy, isFalse);
      final submit = find.widgetWithText(FilledButton, 'Schedule deletion');
      expect(submit, findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(find.text('Schedule deletion'));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 1);
      expect(api.logoutCalls, 0);
      expect(secureStore.deletedRefreshTokens, ['user@example.test']);
      expect(controller.stage, ClientStage.login);
      expect(controller.session, isNull);
      expect(controller.account, isNull);
      expect(api.accessToken, isNull);
      expect(controller.openConflicts, isEmpty);
      expect(controller.devices, isEmpty);
      expect(controller.sftpEntries, isEmpty);
      expect(find.textContaining(_purgeAfter), findsNWidgets(2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
      await database.close();
    }
  });

  testWidgets(
    'Settings deletion shows shared-owner rejection and keeps active session',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RecoveryApi()..rejectSharedOwnerDeletion = true;
      final secureStore = _MemorySecureStore();
      final controller = _NamedController(
        sodium: sodium,
        database: database,
        secureStore: secureStore,
      )..api = api;
      controller
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.settings
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
      api.accessToken = 'active-token';
      final originalSession = controller.session;

      try {
        await tester.pumpWidget(AtermiusApp(controller: controller));
        final deleteButton = find.text('Schedule account deletion');
        await tester.ensureVisible(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Continue to final confirmation'));
        await tester.pumpAndSettle();
        final confirmationField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Type DELETE to confirm',
        );
        final passwordField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText ==
                  'Re-enter account master password',
        );
        await tester.enterText(confirmationField, 'DELETE');
        await tester.enterText(passwordField, 'correct horse battery staple');
        await tester.pump();
        await tester.tap(find.text('Schedule deletion'));
        await tester.pumpAndSettle();

        expect(api.deleteCalls, 1);
        final confirmationDialog = find.ancestor(
          of: find.text('Confirm and re-authenticate'),
          matching: find.byType(AlertDialog),
        );
        expect(
          find.descendant(
            of: confirmationDialog,
            matching: find.text(
              "The account is still the Owner of a shared Vault with other members. The server won't transfer ownership or delete other accounts' data automatically; remove the other members, then try again.",
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('Confirm and re-authenticate'), findsOneWidget);
        expect(find.text('Account deletion'), findsOneWidget);
        expect(controller.stage, ClientStage.workspace);
        expect(controller.page, WorkspacePage.settings);
        expect(controller.session, same(originalSession));
        expect(api.accessToken, 'active-token');
        expect(controller.accountLifecycleBusy, isFalse);
        expect(controller.accountDeletionPurgeAfter, isNull);
        expect(find.textContaining(_purgeAfter), findsNothing);
        expect(find.text('Cancel scheduled account deletion'), findsNothing);
        expect(api.logoutCalls, 0);
        expect(secureStore.deletedRefreshTokens, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        api.close();
        await database.close();
      }
    },
  );
}

class _MemorySecureStore extends ClientSecureStore {
  final List<String> deletedRefreshTokens = [];

  @override
  Future<void> deleteRefreshToken(String baseUrl, String username) async {
    deletedRefreshTokens.add(username);
  }
}

class _NamedController extends AppController {
  _NamedController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  @override
  String? get authenticatedUsername => 'user@example.test';
}

class _RecoveryApi extends ApiClient {
  _RecoveryApi()
    : super(
        baseUrl: 'https://account-recovery.test',
        client: MockClient((request) async {
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );

  int cancelCalls = 0;
  int deleteCalls = 0;
  int loginCalls = 0;
  int logoutCalls = 0;
  bool rejectSharedOwnerDeletion = false;

  @override
  Future<Map<String, dynamic>> prelogin(String username) async => {
    'account_id': _accountId,
    'kdf': KdfParameters(salt: Uint8List(16)).toJson(),
  };

  @override
  Future<Map<String, dynamic>> cancelAccountDeletion({
    required String username,
    required Map<String, Object?> body,
  }) async {
    cancelCalls++;
    return const {
      'status': 'active',
      'requested_at': null,
      'purge_after': null,
      'can_cancel': false,
    };
  }

  @override
  Future<Map<String, dynamic>> deleteAccount(Map<String, Object?> body) async {
    deleteCalls++;
    if (rejectSharedOwnerDeletion) {
      throw const ApiException(
        statusCode: 409,
        code: 'ACCOUNT_OWNS_SHARED_VAULT',
        message: 'The account owns a shared Vault.',
      );
    }
    return {
      'status': 'deleting',
      'requested_at': '2026-09-27T00:00:00Z',
      'purge_after': _purgeAfter,
      'can_cancel': true,
    };
  }

  @override
  Future<AuthLoginResult> login({
    required String username,
    required String loginVerifier,
    required String deviceId,
  }) async {
    loginCalls++;
    throw StateError('Recovery must not create a session');
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    accessToken = null;
  }
}
