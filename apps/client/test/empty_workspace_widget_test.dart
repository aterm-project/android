import 'support/settings_navigation.dart';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty workspace offers Vault creation and hides Vault tools', (
    tester,
  ) async {
    final harness = await _makeHarness();
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No accessible Vaults'), findsOneWidget);
      expect(find.text('Create encrypted Vault'), findsOneWidget);
      expect(find.text('Accept invitation'), findsOneWidget);
      expect(find.text('No Vault'), findsNothing);
      expect(find.text('Hosts'), findsNothing);
      expect(find.text('SFTP'), findsNothing);
      expect(find.text('Sync & conflicts'), findsNothing);
      expect(find.text('Audit log'), findsNothing);
      expect(find.textContaining('pending 0'), findsNothing);

      await tester.tap(find.text('Create encrypted Vault'));
      await tester.pumpAndSettle();
      expect(find.text('Create Vault'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Personal');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Create encrypted Vault'),
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.app.createdVaultNames, ['Personal']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'empty workspace settings expose account and recovery actions only',
    (tester) async {
      final harness = await _makeHarness(page: WorkspacePage.settings);
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: harness.app),
          ),
        );
        await tester.pumpAndSettle();

        await openSettingsCategory(tester, 'security');
        expect(find.text('Account password'), findsOneWidget);
        await openSettingsCategory(tester, 'vaults');
        expect(
          find.textContaining(
            'No Vault is currently available to this device.',
          ),
          findsOneWidget,
        );
        expect(find.text('Create encrypted Vault'), findsOneWidget);
        expect(find.text('Accept invitation'), findsOneWidget);
        expect(find.text('Vault-synced preferences'), findsNothing);
        expect(find.text('Portable encrypted Vault archive'), findsNothing);
        expect(find.text('SSH host-key trust'), findsNothing);
        expect(find.text('Invite member'), findsNothing);
        expect(find.text('Manage Vault members'), findsNothing);

        await tester.ensureVisible(find.text('Create encrypted Vault'));
        await tester.tap(find.text('Create encrypted Vault'));
        await tester.pumpAndSettle();
        expect(find.text('Create Vault'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(harness.app.createdVaultNames, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        harness.app.dispose();
        await harness.database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('empty workspace invitation action opens the account flow', (
    tester,
  ) async {
    final harness = await _makeHarness();
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Accept invitation'));
      await tester.pumpAndSettle();
      expect(find.text('Accept Vault invitation'), findsOneWidget);
      expect(find.text('Current account'), findsOneWidget);
      expect(find.text('Accept and unlock Vault'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('No accessible Vaults'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'trusted device enrollment remains available without Vault keys',
    (tester) async {
      final harness = await _makeHarness(page: WorkspacePage.devices);
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: harness.app),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Trusted devices'), findsWidgets);
        expect(find.text('Approve enrollment'), findsOneWidget);
        expect(find.text('Refresh devices'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        harness.app.dispose();
        await harness.database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}

Future<_Harness> _makeHarness({
  WorkspacePage page = WorkspacePage.hosts,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _EmptyWorkspaceController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = page;
  return _Harness(app, database);
}

class _Harness {
  const _Harness(this.app, this.database);

  final _EmptyWorkspaceController app;
  final ClientDatabase database;
}

class _EmptyWorkspaceController extends AppController {
  _EmptyWorkspaceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  final List<String> createdVaultNames = [];

  @override
  bool get authenticated => true;

  @override
  Future<void> createVault(String name) async {
    createdVaultNames.add(name);
  }
}
