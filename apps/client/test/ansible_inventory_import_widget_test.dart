import 'package:aterm_client/l10n/l10n.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/ansible_inventory_metadata.dart';
import 'package:aterm_client/import/ansible_inventory_import.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/ansible_inventory_import_dialog.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _existingId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ansible_inventory live preview switches locale without replacing state or saving',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final language = AppLanguageController(
        systemLocales: () => [const Locale('en')],
      );
      final (app, database) = await _makeController();
      const source = '[web]\nnode ansible_user=deploy ansible_connection=winrm';
      var parseCalls = 0;
      try {
        await tester.pumpWidget(
          AppLanguageHost(
            controller: language,
            builder: (_, locale) => MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizationSetup.delegates,
              supportedLocales: AppLocalizationSetup.locales,
              theme: buildAppTheme(),
              home: Scaffold(
                body: AnsibleInventoryImportDialog(
                  app: app,
                  parseForTesting: (source) {
                    parseCalls++;
                    return AnsibleInventoryImporter.parse(source);
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(AnsibleInventoryImportDialog));
        for (final choice in [
          AppLanguage.chinese,
          AppLanguage.japanese,
          AppLanguage.russian,
        ]) {
          await language.setPreference(choice);
          await tester.pumpAndSettle();
          final l10n = appLocalizationsFor(choice.locale!);
          expect(find.textContaining(l10n.inventoryBlockedEntry), findsWidgets);
          expect(find.textContaining(l10n.importStatusBlocked), findsWidgets);
          expect(parseCalls, 1);
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const ValueKey('ansible_inventory_source')),
                )
                .controller!
                .text,
            isEmpty,
          );
          expect(
            tester.state(find.byType(AnsibleInventoryImportDialog)),
            same(state),
          );
          expect(app.savedHosts, isEmpty);
          expect(tester.takeException(), isNull);
        }
        // File-level findings have a distinct rendered panel.
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          '{{ unsafe_template }}',
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();
        for (final choice in [
          AppLanguage.english,
          AppLanguage.chinese,
          AppLanguage.japanese,
          AppLanguage.russian,
        ]) {
          await language.setPreference(choice);
          await tester.pumpAndSettle();
          expect(
            find.textContaining(
              appLocalizationsFor(choice.locale!).inventoryUnsupportedConstruct,
            ),
            findsWidgets,
          );
          expect(parseCalls, 2);
          expect(
            tester.state(find.byType(AnsibleInventoryImportDialog)),
            same(state),
          );
          expect(app.savedHosts, isEmpty);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        language.dispose();
        debugCurrentL10n = appLocalizationsFor(const Locale('en'));
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'static inventory is reviewed, secret variables are omitted, and save waits for confirmation',
    (tester) async {
      _setDesktopSize(tester);
      final (app, database) = await _makeController();
      const secret = 'DO_NOT_IMPORT_ANSIBLE_PASSWORD_9465';
      const source =
          '''
[web]
web-01 ansible_host=198.51.100.11 ansible_user=deploy ansible_password=$secret
''';
      try {
        await _pumpDialog(tester, app);
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ansible_inventory_preview')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ansible_inventory_host_web-01')),
          findsOneWidget,
        );
        expect(find.textContaining('deploy@198.51.100.11:22'), findsOneWidget);
        expect(find.textContaining('Host tags to save: web'), findsOneWidget);
        expect(find.textContaining(secret), findsNothing);
        expect(find.textContaining('Ansible inventory'), findsWidgets);
        expect(app.savedHosts, isEmpty);

        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_import')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ansible_inventory_confirm_dialog')),
          findsOneWidget,
        );
        expect(app.savedHosts, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_confirm_cancel')),
        );
        await tester.pumpAndSettle();
        expect(app.savedHosts, isEmpty);

        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_import')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
        );
        await tester.pumpAndSettle();

        expect(app.savedHosts, hasLength(1));
        expect(app.savedHosts.single.name, 'web-01');
        expect(app.savedHosts.single.address, '198.51.100.11');
        expect(app.savedHosts.single.username, 'deploy');
        expect(app.savedHosts.single.tags, ['web']);
        expect(app.savedHosts.single.ansibleInventoryImport, isNotNull);
        expect(
          app.savedHosts.single.ansibleInventoryImport!.sourceLabel,
          'Pasted inventory',
        );
        expect(
          app.savedHosts.single.ansibleInventoryImport!.entryKey,
          'web-01',
        );
        expect(app.savedHosts.single.credentialId, isNull);
        expect(app.terminalTabs, isEmpty);
        expect(
          find.byKey(const ValueKey('ansible_inventory_confirm_dialog')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'same-name Host conflict shows endpoint diff and is not overwritten',
    (tester) async {
      _setDesktopSize(tester);
      final (app, database) = await _makeController(
        initialHosts: const [
          HostRecord(
            id: _existingId,
            name: 'web-01',
            address: 'old.example.test',
            port: 2200,
            username: 'old-user',
          ),
        ],
      );
      const source = '''
[web]
web-01 ansible_host=198.51.100.11 ansible_user=deploy
web-02 ansible_host=198.51.100.12 ansible_user=deploy
''';
      try {
        await _pumpDialog(tester, app);
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Saved: old-user@old.example.test:2200'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Already saved. The existing Host will be kept unchanged.',
          ),
          findsOneWidget,
        );
        expect(find.text('Import 1 Host'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_import')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
        );
        await tester.pumpAndSettle();

        expect(app.savedHosts, hasLength(1));
        expect(app.savedHosts.single.name, 'web-02');
        expect(
          app.hosts.singleWhere((host) => host.id == _existingId).address,
          'old.example.test',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'dynamic inventory is blocked and its source text is not echoed',
    (tester) async {
      _setDesktopSize(tester);
      final (app, database) = await _makeController();
      const secretMarker = 'SOURCE_VALUE_MUST_NOT_APPEAR_12345';
      const source =
          '''
plugin: community.general.aws_ec2
regions:
  - $secretMarker
''';
      final parseResult = AnsibleInventoryImporter.parse(source);
      expect(parseResult.blocksWholeFile, isTrue);
      expect(
        parseResult.issues.any((issue) => issue.code == 'dynamic_inventory'),
        isTrue,
      );
      try {
        await _pumpDialog(tester, app);
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Review blocked: this inventory cannot be imported.'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Dynamic inventory and plugin configuration are not supported.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining(secretMarker), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('ansible_inventory_import')),
              )
              .onPressed,
          isNull,
        );
        expect(app.savedHosts, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('static YAML group membership is saved as a Host tag', (
    tester,
  ) async {
    _setDesktopSize(tester);
    final (app, database) = await _makeController();
    const source = '''
all:
  children:
    web:
      hosts:
        web-01:
          ansible_host: 198.51.100.11
          ansible_user: deploy
''';
    try {
      await _pumpDialog(tester, app);
      await tester.enterText(
        find.byKey(const ValueKey('ansible_inventory_source')),
        source,
      );
      await tester.tap(find.byKey(const ValueKey('ansible_inventory_review')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Host tags to save: web'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ansible_inventory_import')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
      );
      await tester.pumpAndSettle();
      expect(app.savedHosts.single.name, 'web-01');
      expect(app.savedHosts.single.tags, ['web']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('selected inventory bytes are cleared after local parsing', (
    tester,
  ) async {
    _setDesktopSize(tester);
    final (app, database) = await _makeController();
    final bytes = Uint8List.fromList(
      utf8.encode(
        '[db]\ndb-01 ansible_host=198.51.100.30 ansible_user=operator\n',
      ),
    );
    try {
      await _pumpDialog(tester, app, pickedBytes: () async => bytes);
      await tester.tap(
        find.byKey(const ValueKey('ansible_inventory_pick_file')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ansible_inventory_host_db-01')),
        findsOneWidget,
      );
      expect(bytes.every((byte) => byte == 0), isTrue);
      expect(app.savedHosts, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('preview is bound to the Vault active when it was parsed', (
    tester,
  ) async {
    _setDesktopSize(tester);
    final (app, database) = await _makeController();
    const source =
        '[web]\nweb-01 ansible_host=198.51.100.11 ansible_user=deploy\n';
    try {
      await _pumpDialog(tester, app);
      await tester.enterText(
        find.byKey(const ValueKey('ansible_inventory_source')),
        source,
      );
      await tester.tap(find.byKey(const ValueKey('ansible_inventory_review')));
      await tester.pumpAndSettle();
      app.activeVault = const VaultDescriptor(
        id: '33333333-3333-4333-8333-333333333333',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        canWrite: true,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ansible_inventory_source_label')),
        'Renamed preview source',
      );

      await tester.tap(find.byKey(const ValueKey('ansible_inventory_import')));
      await tester.pumpAndSettle();
      expect(find.textContaining('The active Vault changed'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ansible_inventory_confirm_dialog')),
        findsNothing,
      );
      expect(app.savedHosts, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('Vault change during a write stops the remaining Hosts', (
    tester,
  ) async {
    _setDesktopSize(tester);
    final (app, database) = await _makeController();
    app.switchVaultAfterNextSave = const VaultDescriptor(
      id: '33333333-3333-4333-8333-333333333333',
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
      canWrite: true,
    );
    const source = '''
[web]
web-01 ansible_host=198.51.100.11 ansible_user=deploy
web-02 ansible_host=198.51.100.12 ansible_user=deploy
''';
    try {
      await _pumpDialog(tester, app);
      await tester.enterText(
        find.byKey(const ValueKey('ansible_inventory_source')),
        source,
      );
      await tester.tap(find.byKey(const ValueKey('ansible_inventory_review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ansible_inventory_import')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
      );
      await tester.pumpAndSettle();

      expect(app.savedHosts, hasLength(1));
      expect(app.savedHosts.single.name, 'web-01');
      expect(
        find.textContaining('1 Host(s) were saved before an error'),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets(
    'refresh lets the user choose a conflict value and saves at revision',
    (tester) async {
      _setDesktopSize(tester);
      const revisionId = '55555555-5555-4555-8555-555555555555';
      final baseline = AnsibleInventoryImportedValues(
        name: 'web-01',
        address: '192.0.2.11',
        port: 22,
        username: 'deploy',
        tags: const ['web'],
      );
      final existing = HostRecord(
        id: _existingId,
        name: 'web-01',
        address: '192.0.2.99',
        port: 22,
        username: 'deploy',
        tags: const ['web'],
        revisionId: revisionId,
        manifest: {
          'ansible_inventory_v1': AnsibleInventoryImportMetadata(
            sourceId: '44444444-4444-4444-8444-444444444444',
            sourceLabel: 'Production inventory',
            entryKey: 'web-01',
            baseline: baseline,
          ).toJson(),
        },
      );
      final (app, database) = await _makeController(initialHosts: [existing]);
      const source = '''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
''';
      try {
        await _pumpDialog(tester, app);
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_source_selector')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Production inventory ·').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const ValueKey('ansible_refresh_conflict_${_existingId}_address'),
          ),
          findsOneWidget,
        );
        final choice = find.byKey(
          const ValueKey('ansible_refresh_field_choice_${_existingId}_address'),
        );
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use inventory').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_import')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
        );
        await tester.pumpAndSettle();

        final stored = app.hosts.single;
        expect(stored.address, '192.0.2.12');
        expect(stored.ansibleInventoryImport?.baseline.address, '192.0.2.12');
        expect(app.revisionGuardedSaveCount, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'missing inventory Hosts are stale only when explicitly selected',
    (tester) async {
      _setDesktopSize(tester);
      const sourceId = '44444444-4444-4444-8444-444444444444';
      const revA = '55555555-5555-4555-8555-555555555555';
      const revB = '66666666-6666-4666-8666-666666666666';
      HostRecord imported(String id, String name, String address, String rev) {
        final baseline = AnsibleInventoryImportedValues(
          name: name,
          address: address,
          port: 22,
          username: 'deploy',
          tags: const [],
        );
        return HostRecord(
          id: id,
          name: name,
          address: address,
          username: 'deploy',
          revisionId: rev,
          manifest: {
            'ansible_inventory_v1': AnsibleInventoryImportMetadata(
              sourceId: sourceId,
              sourceLabel: 'Production inventory',
              entryKey: name,
              baseline: baseline,
            ).toJson(),
          },
        );
      }

      final web = imported(_existingId, 'web-01', '192.0.2.11', revA);
      final db = imported(
        '33333333-3333-4333-8333-333333333333',
        'db-01',
        '192.0.2.21',
        revB,
      );
      final (app, database) = await _makeController(initialHosts: [web, db]);
      const source = '''
[web]
web-01 ansible_host=192.0.2.11 ansible_user=deploy
''';
      try {
        await _pumpDialog(tester, app);
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_source_selector')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Production inventory ·').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ansible_inventory_source')),
          source,
        );
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_review')),
        );
        await tester.pumpAndSettle();
        expect(app.revisionGuardedSaveCount, 0);
        expect(
          find.byKey(
            const ValueKey(
              'ansible_inventory_mark_stale_33333333-3333-4333-8333-333333333333',
            ),
          ),
          findsOneWidget,
        );
        final staleCheckbox = find.byKey(
          const ValueKey(
            'ansible_inventory_mark_stale_33333333-3333-4333-8333-333333333333',
          ),
        );
        await tester.ensureVisible(staleCheckbox);
        await tester.tap(staleCheckbox);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_import')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
        );
        await tester.pumpAndSettle();

        expect(
          app.hosts
              .singleWhere((host) => host.id == db.id)
              .ansibleInventoryImport
              ?.state,
          AnsibleInventoryEntryState.stale,
        );
        expect(app.hosts, hasLength(2));
        expect(app.revisionGuardedSaveCount, 2);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('refresh preview is rejected when the Host revision changes', (
    tester,
  ) async {
    _setDesktopSize(tester);
    final baseline = AnsibleInventoryImportedValues(
      name: 'web-01',
      address: '192.0.2.11',
      port: 22,
      username: 'deploy',
      tags: const [],
    );
    final existing = HostRecord(
      id: _existingId,
      name: 'web-01',
      address: '192.0.2.11',
      username: 'deploy',
      revisionId: '55555555-5555-4555-8555-555555555555',
      manifest: {
        'ansible_inventory_v1': AnsibleInventoryImportMetadata(
          sourceId: '44444444-4444-4444-8444-444444444444',
          sourceLabel: 'Production inventory',
          entryKey: 'web-01',
          baseline: baseline,
        ).toJson(),
      },
    );
    final (app, database) = await _makeController(initialHosts: [existing]);
    const source = '''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
''';
    try {
      await _pumpDialog(tester, app);
      await tester.tap(
        find.byKey(const ValueKey('ansible_inventory_source_selector')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Production inventory ·').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ansible_inventory_source')),
        source,
      );
      await tester.tap(find.byKey(const ValueKey('ansible_inventory_review')));
      await tester.pumpAndSettle();
      app.hosts[0] = app.hosts[0].copyWith(
        revisionId: '77777777-7777-4777-8777-777777777777',
      );

      await tester.tap(find.byKey(const ValueKey('ansible_inventory_import')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ansible_inventory_confirm_accept')),
      );
      await tester.pumpAndSettle();

      expect(app.revisionGuardedSaveCount, 0);
      expect(
        find.textContaining('A Host changed after the preview'),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });
}

void _setDesktopSize(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpDialog(
  WidgetTester tester,
  _ImporterController app, {
  Future<Uint8List> Function()? pickedBytes,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<int>(
              context: context,
              builder: (_) => AnsibleInventoryImportDialog(
                app: app,
                pickBytesForTesting: pickedBytes,
              ),
            ),
            child: const Text('Open importer'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open importer'));
  await tester.pumpAndSettle();
}

Future<(_ImporterController, ClientDatabase)> _makeController({
  List<HostRecord> initialHosts = const [],
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _ImporterController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: true,
        )
        ..hosts.addAll(initialHosts);
  return (app, database);
}

class _ImporterController extends AppController {
  _ImporterController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  final List<HostRecord> savedHosts = [];
  var revisionGuardedSaveCount = 0;
  var _revisionCounter = 0;
  VaultDescriptor? switchVaultAfterNextSave;

  @override
  Future<void> saveHost(HostRecord host) async {
    final validation = host.validate() ?? validateHostReferences(host);
    if (validation != null) throw FormatException(validation);
    _revisionCounter++;
    final stored = host.copyWith(
      revisionId: 'local-revision-$_revisionCounter',
    );
    savedHosts.add(stored);
    final existingIndex = hosts.indexWhere((item) => item.id == host.id);
    if (existingIndex < 0) {
      hosts.add(stored);
    } else {
      hosts[existingIndex] = stored;
    }
    final nextVault = switchVaultAfterNextSave;
    if (nextVault != null) {
      switchVaultAfterNextSave = null;
      activeVault = nextVault;
    }
    notifyListeners();
  }

  @override
  Future<void> saveHostAtRevision(
    HostRecord host, {
    required String expectedRevisionId,
    bool Function()? isCurrentContext,
  }) async {
    final current = hosts.where((item) => item.id == host.id).firstOrNull;
    if (current?.revisionId != expectedRevisionId) {
      throw const FormatException('stale revision');
    }
    revisionGuardedSaveCount++;
    await saveHost(host);
  }
}
