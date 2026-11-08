import 'package:aterm_client/l10n/l10n.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/openssh_config_import_dialog.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _existingId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'openssh_config live preview switches locale without replacing state or saving',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final language = AppLanguageController(
        systemLocales: () => [const Locale('en')],
      );
      final (app, database) = await _makeController();
      const source = 'Include ignored.conf\nHost target\nUser deploy';
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
                body: OpenSshConfigImportDialog(
                  app: app,
                  pickBytesForTesting: () async =>
                      Uint8List.fromList(utf8.encode(source)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('openssh_config_pick_file')),
        );
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(OpenSshConfigImportDialog));
        for (final choice in [
          AppLanguage.chinese,
          AppLanguage.japanese,
          AppLanguage.russian,
        ]) {
          await language.setPreference(choice);
          await tester.pumpAndSettle();
          final l10n = appLocalizationsFor(choice.locale!);
          expect(find.textContaining(l10n.sshImportInclude), findsWidgets);
          expect(find.textContaining(l10n.sshImportBlockedFile), findsWidgets);
          expect(
            tester.state(find.byType(OpenSshConfigImportDialog)),
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

  testWidgets('Host page exposes the import action for a writable Vault', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      // The import action lives in the top Host menu (no secondary toolbar).
      await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(const ValueKey('host_import_openssh_config')),
      );
      expect(item.enabled, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('host_import_openssh_config')),
          matching: find.text('Import SSH config'),
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets(
    'preview requires confirmation and saves ProxyJump Hosts safely',
    (tester) async {
      final (app, database) = await _makeController();
      const keyPath = '/home/secret-user/.ssh/DO_NOT_READ_PRIVATE_KEY';
      const source =
          '''
Host target
  HostName target.example.test
  User deploy
  Port 2222
  ProxyJump bastion
  IdentityFile $keyPath
Host bastion
  HostName bastion.example.test
  User gateway
''';
      try {
        await _pumpDialog(tester, app, source);
        await tester.tap(
          find.byKey(const ValueKey('openssh_config_pick_file')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('openssh_config_preview')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('openssh_config_host_target')),
          findsOneWidget,
        );
        expect(
          find.textContaining('ProxyJump bastion · line 5'),
          findsOneWidget,
        );
        expect(
          find.textContaining('IdentityFile is not read or imported'),
          findsWidgets,
        );
        expect(find.textContaining(keyPath), findsNothing);
        expect(app.savedHosts, isEmpty);

        await tester.tap(find.byKey(const ValueKey('openssh_config_import')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('openssh_config_confirm_dialog')),
          findsOneWidget,
        );
        expect(app.savedHosts, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('openssh_config_confirm_cancel')),
        );
        await tester.pumpAndSettle();
        expect(app.savedHosts, isEmpty);

        await tester.tap(find.byKey(const ValueKey('openssh_config_import')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('openssh_config_confirm_accept')),
        );
        await tester.pumpAndSettle();

        expect(app.savedHosts.map((host) => host.name), ['bastion', 'target']);
        final bastion = app.savedHosts.first;
        final target = app.savedHosts.last;
        expect(target.address, 'target.example.test');
        expect(target.username, 'deploy');
        expect(target.port, 2222);
        expect(target.jumpHostId, bastion.id);
        expect(app.terminalTabs, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('existing Host conflicts are explicit and never overwritten', (
    tester,
  ) async {
    final (app, database) = await _makeController(
      initialHosts: const [
        HostRecord(
          id: _existingId,
          name: 'Existing',
          address: 'old.example.test',
          username: 'old-user',
        ),
      ],
    );
    const source = '''
Host Existing
  HostName new.example.test
  User new-user
Host imported
  HostName imported.example.test
  User importer
''';
    try {
      await _pumpDialog(tester, app, source);
      await tester.tap(find.byKey(const ValueKey('openssh_config_pick_file')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Already saved as “Existing”; it will not be overwritten.',
        ),
        findsOneWidget,
      );
      expect(find.text('Import 1 Host'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('openssh_config_import')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('openssh_config_confirm_accept')),
      );
      await tester.pumpAndSettle();

      expect(app.savedHosts, hasLength(1));
      expect(app.savedHosts.single.name, 'imported');
      final existing = app.hosts.singleWhere((host) => host.id == _existingId);
      expect(existing.address, 'old.example.test');
      expect(existing.username, 'old-user');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('unsafe file structure and unresolved jumps fail closed', (
    tester,
  ) async {
    final (app, database) = await _makeController();
    try {
      await _pumpDialog(
        tester,
        app,
        'Host *\nUser bob\nHost app\nUser alice\n',
      );
      await tester.tap(find.byKey(const ValueKey('openssh_config_pick_file')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no records can be imported from this file'),
        findsOneWidget,
      );
      expect(find.textContaining('Line 1'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('openssh_config_import')),
            )
            .onPressed,
        isNull,
      );
      expect(app.savedHosts, isEmpty);

      await tester.tap(find.byKey(const ValueKey('openssh_config_close')));
      await tester.pumpAndSettle();
      await _pumpDialog(
        tester,
        app,
        'Host app\nUser alice\nProxyJump missing-bastion\n',
      );
      await tester.tap(find.byKey(const ValueKey('openssh_config_pick_file')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('does not resolve to one imported or saved Host'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('openssh_config_import')),
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
  });
}

Future<void> _pumpDialog(
  WidgetTester tester,
  _ImporterController app,
  String source,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<int>(
              context: context,
              builder: (_) => OpenSshConfigImportDialog(
                app: app,
                pickBytesForTesting: () async =>
                    Uint8List.fromList(utf8.encode(source)),
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

  @override
  Future<void> saveHost(HostRecord host) async {
    final validation = host.validate() ?? validateHostReferences(host);
    if (validation != null) throw FormatException(validation);
    savedHosts.add(host);
    hosts.add(host);
    notifyListeners();
  }
}
