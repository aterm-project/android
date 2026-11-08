import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('default section dropdown exposes selected-value semantics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: true);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      final dropdown = find.byKey(
        const ValueKey('vault_default_workspace_section'),
      );
      String label() => tester.getSemantics(dropdown).getSemanticsData().label;
      String? value() => tester.getSemantics(dropdown).getSemanticsData().value;

      expect(label(), 'Default workspace section');
      expect(value(), 'Hosts');

      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Credentials').last);
      await tester.pumpAndSettle();

      expect(label(), 'Default workspace section');
      expect(value(), 'Credentials');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('owner saves the default section through the Vault controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: true);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Vault-synced preferences'), findsOneWidget);
      expect(
        find.textContaining('encrypted before syncing to devices'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save synced preference'),
            )
            .onPressed,
        isNull,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.tap(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snippets').last);
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(
        FilledButton,
        'Save synced preference',
      );
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(app.saveCalls, 1);
      expect(app.savedSection, 'snippets');
      expect(app.defaultWorkspaceSection, 'snippets');
      expect(
        find.textContaining(
          'This preference is encrypted in the active Vault and will sync to its authorized devices.',
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('read-only Vault can view but cannot save preferences', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: false);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This Vault is read-only. You can view the preference but cannot change it.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('vault-section-hosts')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save synced preference'),
            )
            .onPressed,
        isNull,
      );
      expect(app.saveCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('save failures are shown without exposing exception details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(
      canWrite: true,
      failSave: true,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.tap(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Credentials').last);
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(
        FilledButton,
        'Save synced preference',
      );
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(app.saveCalls, 1);
      expect(app.defaultWorkspaceSection, 'hosts');
      expect(
        find.text(
          'Could not save this preference. Check Vault write access and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private response body'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('Vault preference data errors are visible and block editing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(
      canWrite: true,
      preferenceError: '此 Vault 中默认工作区偏好存在重复记录，已暂停应用该设置。',
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('此 Vault 中默认工作区偏好存在重复记录，已暂停应用该设置。'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('vault-section-hosts')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save synced preference'),
            )
            .onPressed,
        isNull,
      );
      expect(app.saveCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('duplicate preference repair requires an explicit record ID choice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    const snippetsId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const snippetsRevision = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const credentialsId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const credentialsRevision = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    final candidates = [
      _candidate(snippetsId, 'snippets', snippetsRevision),
      _candidate(credentialsId, 'credentials', credentialsRevision),
    ];
    final (app, database) = await _makeController(
      canWrite: true,
      preferenceError: 'Duplicate default preference records need repair.',
      conflictCandidates: candidates,
    );
    app.updateSectionDuringRepair = true;
    const selectedId = credentialsId;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Choose the default preference record to keep'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('preference-repair-$snippetsId')),
          matching: find.text('Snippets'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('preference-repair-$credentialsId')),
          matching: find.text('Credentials'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Record ID: $selectedId'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('preference-repair-$snippetsId')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label ==
                    'Default section: Snippets; Record ID: $snippetsId; Revision: $snippetsRevision',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('preference-repair-$credentialsId')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label ==
                    'Default section: Credentials; Record ID: $credentialsId; Revision: $credentialsRevision',
          ),
        ),
        findsOneWidget,
      );
      final repairButton = find.byKey(
        const ValueKey('repair_vault_preference_conflict'),
      );
      expect(tester.widget<FilledButton>(repairButton).onPressed, isNull);

      final selectedRadio = find.byKey(
        ValueKey('preference-repair-$selectedId'),
      );
      await tester.ensureVisible(selectedRadio);
      await tester.tap(selectedRadio);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(repairButton).onPressed, isNotNull);
      await tester.ensureVisible(repairButton);
      await tester.tap(repairButton);
      await tester.pumpAndSettle();

      expect(app.repairCalls, 1);
      expect(app.repairedRecordId, selectedId);
      expect(app.hasDefaultSectionPreferenceConflict, isFalse);
      expect(app.defaultWorkspaceSection, 'credentials');
      final status = find.byKey(
        const ValueKey('vault_synced_preference_status'),
      );
      await tester.ensureVisible(status);
      expect(
        find.text(
          'The selected default preference was confirmed after Vault sync.',
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'repair retry is disabled for a read-only Vault and hides failures',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      final candidates = [
        _candidate(
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'snippets',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        _candidate(
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          'credentials',
          'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        ),
      ];
      final (readonlyApp, readonlyDatabase) = await _makeController(
        canWrite: false,
        conflictCandidates: candidates,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: readonlyApp),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('repair_vault_preference_conflict')),
              )
              .onPressed,
          isNull,
        );
        expect(readonlyApp.repairCalls, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        readonlyApp.dispose();
        await readonlyDatabase.close();
      }

      final (app, database) = await _makeController(
        canWrite: true,
        failRepair: true,
        conflictCandidates: candidates,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        const selectedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
        final selectedRadio = find.byKey(
          ValueKey('preference-repair-$selectedId'),
        );
        await tester.ensureVisible(selectedRadio);
        await tester.tap(selectedRadio);
        await tester.pumpAndSettle();
        final repairButton = find.byKey(
          const ValueKey('repair_vault_preference_conflict'),
        );
        await tester.ensureVisible(repairButton);
        await tester.tap(repairButton);
        await tester.pumpAndSettle();

        expect(app.repairCalls, 1);
        expect(app.hasDefaultSectionPreferenceConflict, isTrue);
        expect(
          find.textContaining('Repair is not confirmed yet'),
          findsOneWidget,
        );
        expect(find.textContaining('private response body'), findsNothing);
        expect(
          find.byKey(const ValueKey('repair_vault_preference_conflict')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('repair_vault_preference_conflict')),
              )
              .onPressed,
          isNotNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'repair retry becomes neutral success after verified singleton recovery',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      const snippetsId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const credentialsId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final candidates = [
        _candidate(
          snippetsId,
          'snippets',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        _candidate(
          credentialsId,
          'credentials',
          'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        ),
      ];
      final (app, database) = await _makeController(
        canWrite: true,
        failRepair: true,
        conflictCandidates: candidates,
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        final selectedRadio = find.byKey(
          const ValueKey('preference-repair-$credentialsId'),
        );
        await tester.ensureVisible(selectedRadio);
        await tester.tap(selectedRadio);
        await tester.pumpAndSettle();
        final repairButton = find.byKey(
          const ValueKey('repair_vault_preference_conflict'),
        );
        await tester.ensureVisible(repairButton);
        await tester.tap(repairButton);
        await tester.pumpAndSettle();

        expect(app.hasDefaultSectionPreferenceConflict, isTrue);
        expect(
          find.textContaining('Repair is not confirmed yet'),
          findsOneWidget,
        );
        expect(repairButton, findsOneWidget);

        // A later complete sync can safely resolve the latch to a singleton.
        // This fixture deliberately exposes the other candidate as active so
        // the status must not claim that the original selection won.
        app.confirmSingletonAfterVerifiedSyncForTesting(candidates.first);
        await tester.pumpAndSettle();

        expect(app.hasDefaultSectionPreferenceConflict, isFalse);
        expect(app.preferenceError, isNull);
        expect(
          app.preferences.where((item) => item.isDefaultWorkspaceSection),
          hasLength(1),
        );
        expect(
          find.text('The default preference was confirmed after Vault sync.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Repair is not confirmed yet'),
          findsNothing,
        );
        expect(
          find.text(
            'The selected default preference was confirmed after Vault sync.',
          ),
          findsNothing,
        );
        expect(repairButton, findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'repair failure after singleton recovery keeps neutral confirmed status',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      const snippetsId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const credentialsId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final candidates = [
        _candidate(
          snippetsId,
          'snippets',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        _candidate(
          credentialsId,
          'credentials',
          'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        ),
      ];
      final (app, database) = await _makeController(
        canWrite: true,
        conflictCandidates: candidates,
      );
      final repairCompletion = Completer<void>();
      app.pendingRepairResult = repairCompletion;

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        final selectedRadio = find.byKey(
          const ValueKey('preference-repair-$credentialsId'),
        );
        await tester.ensureVisible(selectedRadio);
        await tester.tap(selectedRadio);
        await tester.pumpAndSettle();
        final repairButton = find.byKey(
          const ValueKey('repair_vault_preference_conflict'),
        );
        await tester.ensureVisible(repairButton);
        await tester.tap(repairButton);
        await tester.pump();
        expect(app.repairCalls, 1);

        // Publish the complete-sync singleton while the UI still awaits the
        // repair result. The active record is deliberately not the selected
        // candidate, so only neutral success wording is valid.
        app.confirmSingletonAfterVerifiedSyncForTesting(candidates.first);
        await tester.pump();
        expect(repairButton, findsNothing);
        expect(
          find.text('The default preference was confirmed after Vault sync.'),
          findsNothing,
        );

        repairCompletion.completeError(StateError('private response body'));
        await tester.pumpAndSettle();

        expect(
          find.text('The default preference was confirmed after Vault sync.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Repair is not confirmed yet'),
          findsNothing,
        );
        expect(
          find.text(
            'The selected default preference was confirmed after Vault sync.',
          ),
          findsNothing,
        );
        expect(find.textContaining('private response body'), findsNothing);
        expect(repairButton, findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('a pending repair marker pins the retained record choice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    const retainedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const otherId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final candidates = [
      _candidate(
        retainedId,
        'snippets',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      ),
      _candidate(
        otherId,
        'credentials',
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      ),
    ];
    final (app, database) = await _makeController(
      canWrite: true,
      conflictCandidates: candidates,
      retainedRecordId: retainedId,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      final retainedTile = tester.widget<RadioListTile<String>>(
        find.byKey(ValueKey('preference-repair-$retainedId')),
      );
      final otherTile = tester.widget<RadioListTile<String>>(
        find.byKey(ValueKey('preference-repair-$otherId')),
      );
      expect(retainedTile.enabled, isTrue);
      expect(otherTile.enabled, isFalse);
      final repairButton = find.byKey(
        const ValueKey('repair_vault_preference_conflict'),
      );
      expect(tester.widget<FilledButton>(repairButton).onPressed, isNotNull);
      await tester.ensureVisible(repairButton);
      await tester.tap(repairButton);
      await tester.pumpAndSettle();

      expect(app.repairCalls, 1);
      expect(app.repairedRecordId, retainedId);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('a Vault switch during save cannot reuse the prior selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: true);
    final saveResult = Completer<WorkspacePreferenceSaveOutcome>();
    app.pendingSaveResult = saveResult;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.tap(
        find.byKey(const ValueKey('vault_default_workspace_section')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snippets').last);
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(
        FilledButton,
        'Save synced preference',
      );
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pump();

      expect(app.saveCalls, 1);
      expect(app.savedSection, 'snippets');

      app
        ..activeVault = const VaultDescriptor(
          id: '22222222-2222-4222-8222-222222222222',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: true,
        )
        ..setDefaultSectionForTesting('credentials')
        ..notifyListeners();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('vault-section-credentials')),
        findsOneWidget,
      );

      saveResult.complete(WorkspacePreferenceSaveOutcome.queuedInOriginalVault);
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved as Snippets'), findsNothing);
      expect(find.textContaining('Vault changed while saving'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('vault-section-credentials')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save synced preference'),
            )
            .onPressed,
        isNull,
      );
    } finally {
      if (!saveResult.isCompleted) {
        saveResult.complete(
          WorkspacePreferenceSaveOutcome.queuedInOriginalVault,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

Future<(_PreferenceController, ClientDatabase)> _makeController({
  required bool canWrite,
  bool failSave = false,
  bool failRepair = false,
  String? preferenceError,
  List<VaultPreferenceRecord> conflictCandidates = const [],
  String? retainedRecordId,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _PreferenceController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..failSave = failSave
        ..failRepair = failRepair
        ..preferenceError = preferenceError
        ..setConflictForTesting(conflictCandidates)
        ..setRetainedRecordIdForTesting(retainedRecordId)
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.settings
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database);
}

class _PreferenceController extends AppController {
  _PreferenceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  String _defaultSection = 'hosts';
  int saveCalls = 0;
  String? savedSection;
  bool failSave = false;
  bool failRepair = false;
  bool updateSectionDuringRepair = false;
  Completer<void>? pendingRepairResult;
  final List<VaultPreferenceRecord> _conflictCandidates = [];
  bool _hasConflict = false;
  String? _retainedRecordId;
  bool _repairBusy = false;
  int repairCalls = 0;
  String? repairedRecordId;
  Completer<WorkspacePreferenceSaveOutcome>? pendingSaveResult;

  @override
  String get defaultWorkspaceSection => _defaultSection;

  @override
  List<VaultPreferenceRecord> get defaultSectionConflictCandidates =>
      List.unmodifiable(_conflictCandidates);

  @override
  bool get hasDefaultSectionPreferenceConflict => _hasConflict;

  @override
  String? get defaultSectionConflictRetainedRecordId => _retainedRecordId;

  @override
  bool get defaultSectionConflictRepairBusy => _repairBusy;

  void setConflictForTesting(List<VaultPreferenceRecord> candidates) {
    _conflictCandidates
      ..clear()
      ..addAll(candidates);
    _hasConflict = candidates.isNotEmpty;
    if (_hasConflict) {
      preferenceError ??= 'Duplicate default preference records need repair.';
    }
  }

  void setRetainedRecordIdForTesting(String? recordId) =>
      _retainedRecordId = recordId;

  void confirmSingletonAfterVerifiedSyncForTesting(
    VaultPreferenceRecord candidate,
  ) {
    _defaultSection = candidate.value;
    preferences
      ..clear()
      ..add(candidate);
    _conflictCandidates.clear();
    _hasConflict = false;
    _retainedRecordId = null;
    preferenceError = null;
    notifyListeners();
  }

  @override
  Future<WorkspacePreferenceSaveOutcome> saveWorkspaceDefaultSection(
    String section,
  ) async {
    saveCalls++;
    if (failSave) throw StateError('private response body');
    savedSection = section;
    if (pendingSaveResult case final pending?) return pending.future;
    _defaultSection = section;
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  @override
  Future<void> repairDefaultWorkspaceSectionConflict({
    required String retainedRecordId,
  }) async {
    repairCalls++;
    repairedRecordId = retainedRecordId;
    _repairBusy = true;
    notifyListeners();
    try {
      if (pendingRepairResult case final pending?) await pending.future;
      if (failRepair) {
        preferenceError = 'Repair still needs confirmation.';
        throw StateError('private response body');
      }
      if (updateSectionDuringRepair) {
        _defaultSection = _conflictCandidates
            .singleWhere((candidate) => candidate.id == retainedRecordId)
            .value;
      }
      _hasConflict = false;
      _retainedRecordId = null;
      _conflictCandidates.clear();
      preferenceError = null;
    } finally {
      _repairBusy = false;
      notifyListeners();
    }
  }

  void setDefaultSectionForTesting(String section) => _defaultSection = section;
}

VaultPreferenceRecord _candidate(String id, String value, String revisionId) =>
    VaultPreferenceRecord.defaultWorkspaceSection(
      value: value,
      id: id,
    ).copyWith(revisionId: revisionId);
