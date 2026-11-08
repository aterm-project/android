import 'support/settings_navigation.dart';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
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

  testWidgets('Settings exposes explicit encrypted archive export and import', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'data', ifAvailable: true);
      }
      await tester.pump();

      expect(find.text('Portable encrypted Vault archive'), findsOneWidget);
      expect(find.text('Export archive'), findsOneWidget);
      expect(find.text('Import archive'), findsOneWidget);
      expect(
        find.textContaining('same server space and Vault'),
        findsOneWidget,
      );
    } finally {
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('archive export reports a canceled file save accurately', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _ArchiveOutcomeController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            saved: false,
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'data', ifAvailable: true);
      }
      await tester.ensureVisible(find.text('Export archive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export archive'));
      await tester.pumpAndSettle();
      final passwordDialog = find.byType(AlertDialog);
      final passwordFields = find.descendant(
        of: passwordDialog,
        matching: find.byType(TextField),
      );
      await tester.enterText(passwordFields.at(0), 'archive secret 123');
      await tester.enterText(passwordFields.at(1), 'archive secret 123');
      expect(
        tester
            .widgetList<TextField>(passwordFields)
            .map((field) => field.controller?.text)
            .toList(),
        ['archive secret 123', 'archive secret 123'],
      );
      final continueButton = find.descendant(
        of: passwordDialog,
        matching: find.text('Continue'),
      );
      expect(continueButton, findsOneWidget);
      await tester.tap(continueButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Confirm archive password'), findsNothing);
      expect(controller.exportCalls, 1);
      expect(find.text('Archive save was canceled.'), findsOneWidget);
      expect(find.text('Encrypted Vault archive saved.'), findsNothing);
    } finally {
      controller.dispose();
      await database.close();
    }
  });
}

class _ArchiveOutcomeController extends AppController {
  _ArchiveOutcomeController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required this.saved,
  });

  final bool saved;
  int exportCalls = 0;

  @override
  Future<bool> exportPortableVaultArchive(String exportPassword) async {
    exportCalls++;
    return saved;
  }
}
