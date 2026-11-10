import 'package:aterm_client/l10n/l10n.dart';

import 'support/l10n_fixture.dart';

import 'package:aterm_client/domain/window_combination.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/remote_file_workspace.dart';
import 'package:aterm_client/ui/group_session_layout.dart';
import 'package:aterm_client/platform/files_window_launch.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/terminal_tools_sidebar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:aterm_client/ui/transfer_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

const _password = 'correct horse battery staple';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalVaultDatabase seedDatabase;
  late LocalHostRepository seedRepository;
  late LocalProfileRecord profileRecord;
  late String hostId;
  late String credentialId;
  late String groupId;
  late List<LocalVaultDatabase> openedDatabases;
  late _FakeSshHarness sshHarness;
  LocalHostRepository? activeRepository;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-local-terminal-pref-',
    );
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final seedProfile = await profileService.create(password: _password);
    profileRecord = seedProfile.record;
    seedDatabase = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    seedRepository = LocalHostRepository(
      database: seedDatabase,
      profile: seedProfile,
      crypto: crypto,
    );

    credentialId = const Uuid().v4();
    hostId = const Uuid().v4();
    groupId = const Uuid().v4();
    await seedRepository.createCredential(
      CredentialRecord(
        id: credentialId,
        name: 'terminal test credential',
        username: 'local-user',
        kind: AuthKind.password,
        secret: 'test-only-local-password',
      ),
    );
    await seedRepository.createGroup(
      GroupRecord(
        id: groupId,
        name: 'Local terminal credential defaults',
        defaultCredentialId: credentialId,
        manifest: const {'preserved': 'metadata'},
      ),
    );
    final savedHost = await seedRepository.createHost(
      HostRecord(
        id: hostId,
        name: 'Local preference test host',
        address: 'host.example.test',
        port: 2222,
        username: 'local-user',
        groupId: groupId,
        tags: const ['production'],
      ),
    );
    hostId = savedHost.id;
    await seedRepository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalFontSizeKey,
      value: '16',
      platformFamily: 'all',
    );
    await seedRepository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalThemeKey,
      value: VaultTerminalThemeChoice.light.value,
      platformFamily: 'all',
    );
    final shortcuts = TerminalShortcutBindings.fromBindings({
      TerminalShortcutAction.search: 'alt+f',
      TerminalShortcutAction.searchNext: 'alt+n',
      TerminalShortcutAction.searchPrevious: 'alt+p',
      TerminalShortcutAction.disconnect: 'alt+d',
    });
    await seedRepository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalShortcutsKey,
      value: shortcuts.toValue(),
      platformFamily: 'all',
    );
    await seedDatabase.close();
    await seedProfile.lock();
    openedDatabases = [];
    sshHarness = _FakeSshHarness();
  });

  tearDown(() async {
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // LocalProfileFlow may already have closed it while disposing.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('Expected widget did not become visible.');
  }

  Future<void> pumpUntilIdle(WidgetTester tester) async {
    var idleFrames = 0;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      final waiting =
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      idleFrames = waiting ? 0 : idleFrames + 1;
      if (idleFrames >= 4) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('LocalProfileFlow did not finish its pending operation.');
  }

  Future<void> terminalAction(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey(id)));
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
  }

  Future<void> drainClose(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> openFixtureTerminal(
    WidgetTester tester, {
    FilesWindowLaunch? launch,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
        home: LocalProfileFlow(
          catalog: catalog,
          filesLaunch: launch,
          service: profileService,
          crypto: crypto,
          onExit: () {},
          quarantineRegistry: DatabaseQuarantineRegistry(),
          databaseFactory: (profile, {required mode}) async {
            final record = profile.record;
            final database = await LocalVaultDatabase.openForTesting(
              executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
              profileId: record.profileId,
              localDataDomainId: record.localDataDomainId,
              localVaultId: record.localVaultId,
              mode: mode,
            );
            openedDatabases.add(database);
            return database;
          },
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
          sshControllerFactory: (repository) => LocalProfileSshController(
            repository: repository,
            serviceForTesting: sshHarness.createService(
              knownHostDecisionLock: repository.knownHostDecisionLock,
            ),
          ),
        ),
      ),
    );
    await pumpUntilIdle(tester);
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    if (launch == null) {
      await pumpUntilIdle(tester);
      await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
    }
    await pumpUntilVisible(
      tester,
      find.byKey(const ValueKey('local_ssh_host_key_approve')),
    );
    await tester.tap(find.byKey(const ValueKey('local_ssh_host_key_approve')));
    await pumpUntilVisible(
      tester,
      launch == null
          ? find.byKey(const ValueKey('local_ssh_terminal_view'))
          : find.byType(RemoteFileWorkspace),
    );
  }

  Future<void> hostContext(
    WidgetTester tester,
    String id,
    String action,
  ) async {
    await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('local_host_$id')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == action,
      ),
    );
    await tester.pump();
  }

  dynamic transferDialog(WidgetTester tester) => tester.widget(
    find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TransferDialog',
    ),
  );

  testWidgets(
    'file window launch unlocks exact profile and uses trusted SSH for requested path',
    (tester) async {
      await openFixtureTerminal(
        tester,
        launch: FilesWindowLaunch(
          workspace: FilesWindowWorkspace.local,
          scopeId: profileRecord.profileId,
          hostId: hostId,
          protocol: FilesWindowProtocol.scp,
          initialPath: '/work',
        ),
      );
      await pumpUntilVisible(tester, find.text('inside.txt'));
      final workspace = tester.widget<RemoteFileWorkspace>(
        find.byType(RemoteFileWorkspace),
      );
      expect(workspace.controller.path, '/work');
      expect(workspace.controller.protocol, SshTransferProtocol.scp);
      expect(sshHarness.userAuthenticationCount, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
            .tabs
            .where((tab) => tab.isFile),
        hasLength(1),
      );
      expect(sshHarness.userAuthenticationCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
    },
  );

  testWidgets(
    'file window request never bootstraps an unrelated empty catalog',
    (tester) async {
      final emptyCatalog = LocalProfileCatalog.forTesting(
        NativeDatabase.memory(),
      );
      final service = LocalProfileService(
        catalog: emptyCatalog,
        crypto: crypto,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LocalProfileFlow(
            catalog: emptyCatalog,
            service: service,
            crypto: crypto,
            onExit: () {},
            autoCreateOnFirstLaunch: true,
            filesLaunch: FilesWindowLaunch(
              workspace: FilesWindowWorkspace.local,
              scopeId: 'missing-profile',
              hostId: hostId,
              protocol: FilesWindowProtocol.sftp,
            ),
          ),
        ),
      );
      await pumpUntilIdle(tester);
      expect(await tester.runAsync(() => emptyCatalog.list()), isEmpty);
      expect(sshHarness.socketCount, 0);
      expect(
        find.text(
          "The local profile requested by the file window doesn't exist.",
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
      await emptyCatalog.close();
    },
  );

  testWidgets(
    'topbar local split sidebar stays at workspace right and targets focused pane',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await openFixtureTerminal(tester);
      var bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      final firstId = bar.selectedId;
      final firstTerminal = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      bar.onDuplicate!(firstId);
      for (
        var attempt = 0;
        attempt < 100 && sshHarness.userAuthenticationCount < 2;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpUntilIdle(tester);
      bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      final secondId = bar.selectedId;
      final layout = tester
          .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
          .controller;
      layout.activate(firstId);
      layout.split(secondId, firstId, SessionSplitEdge.right);
      bar.onSelect(firstId);
      await tester.pumpAndSettle();
      final terminals = tester
          .widgetList<TerminalView>(find.byType(TerminalView))
          .map((view) => view.terminal)
          .toSet();
      firstTerminal.write('first-marker\r\n');
      final count = sshHarness.userAuthenticationCount;
      final toggle = find.byKey(
        const ValueKey('workspace_terminal_sidebar_button'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(layout.selectedId, firstId);
      expect(tester.getRect(find.byType(TerminalToolsSidebar)).right, 1400);
      final sidebar = tester.widget<TerminalToolsSidebar>(
        find.byType(TerminalToolsSidebar),
      );
      await tester.enterText(
        find.byKey(const ValueKey('terminal-sidebar-query')),
        'first-marker',
      );
      await tester.pump(const Duration(milliseconds: 200));
      // ICU singular: "1 of 1 match" (the old plural literal was stale).
      expect(
        find.text(currentL10n.terminalSearchMatchCount(1, 1)),
        findsOneWidget,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      bar.onSelect(secondId);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(layout.selectedId, secondId);
      expect(
        tester
            .widget<TerminalToolsSidebar>(find.byType(TerminalToolsSidebar))
            .query,
        isNot(same(sidebar.query)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('terminal-sidebar-query')),
        'first-marker',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('0 matches'), findsOneWidget);
      expect(
        tester
            .widgetList<TerminalView>(find.byType(TerminalView))
            .map((view) => view.terminal)
            .toSet(),
        terminals,
      );
      expect(sshHarness.userAuthenticationCount, count);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
    },
  );
  testWidgets(
    'topbar local sidebar preserves terminal and homepage search filters live',
    (tester) async {
      await openFixtureTerminal(tester);
      final before = tester
          .widget<TerminalView>(
            find.byKey(const ValueKey('local_ssh_terminal_view')),
          )
          .terminal;
      final count = sshHarness.userAuthenticationCount;
      final toggle = find.byKey(
        const ValueKey('workspace_terminal_sidebar_button'),
      );
      expect(toggle, findsOneWidget);
      expect(find.byType(TerminalToolsLauncher), findsNothing);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalToolsSidebar), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalToolsSidebar), findsNothing);
      expect(
        tester
            .widget<TerminalView>(
              find.byKey(const ValueKey('local_ssh_terminal_view')),
            )
            .terminal,
        same(before),
      );
      expect(sshHarness.userAuthenticationCount, count);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('local_home_search'));
      await tester.enterText(search, 'no-such-host');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('local_host_$hostId')), findsNothing);
      await tester.enterText(search, 'host.example.test');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('local_host_$hostId')), findsOneWidget);
      await tester.enterText(
        search,
        'ssh local-user@host.example.test -p 2222',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quick_connect_action')),
        findsOneWidget,
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      expect(sshHarness.userAuthenticationCount, count + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
    },
  );
  testWidgets('local host search and compact cards fit a narrow window', (
    tester,
  ) async {
    await openFixtureTerminal(tester);
    await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('workspace_host_search_button')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host_search_filters')), findsOneWidget);
    final search = find.byKey(const ValueKey('local_host_search'));
    for (final query in [
      'Local preference',
      'host.example.test',
      'production',
      'local-user',
      'credential defaults',
    ]) {
      await tester.enterText(search, query);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('host-search-result-$hostId')),
        findsOneWidget,
      );
    }
    await tester.enterText(search, 'no-such-host');
    await tester.pumpAndSettle();
    expect(find.textContaining('No matching hosts'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('host-search-result-$hostId')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(ValueKey('local_host_$hostId'))).height,
      lessThanOrEqualTo(108),
    );
    // Homepage has no second heading/action/filter toolbar. These controls
    // belong exclusively to the existing Host menu and search palette.
    expect(find.text('Host'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('local_host_add')), findsNothing);
    expect(find.byKey(const ValueKey('local_host_add_group')), findsNothing);
    expect(find.byTooltip('主机列表菜单'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
    await tester.pumpAndSettle();
    for (final action in [
      'local_host_add',
      'local_host_add_group',
      'local_host_layout',
      'local_known_hosts_manage',
    ]) {
      expect(find.byKey(ValueKey(action)), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await drainClose(tester);
  });

  testWidgets(
    'group click reuses sessions and saves encrypted pane layout with metadata',
    (tester) async {
      final profile = await profileService.unlock(
        profileId: profileRecord.profileId,
        password: _password,
      );
      final database = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
        profileId: profileRecord.profileId,
        localDataDomainId: profileRecord.localDataDomainId,
        localVaultId: profileRecord.localVaultId,
      );
      final repository = LocalHostRepository(
        database: database,
        profile: profile,
        crypto: crypto,
      );
      final second = await repository.createHost(
        HostRecord(
          id: const Uuid().v4(),
          name: 'Second grouped host',
          address: 'host.example.test',
          port: 2222,
          username: 'local-user',
          groupId: groupId,
        ),
      );
      await database.close();
      await profile.lock();
      await openFixtureTerminal(tester);
      final initialSessionCount = sshHarness.sessions.length;
      await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('local_host_group_$groupId')));
      for (
        var i = 0;
        i < 100 && find.byType(TerminalView).evaluate().length < 2;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(TerminalView), findsNWidgets(2));
      expect(sshHarness.sessions, hasLength(initialSessionCount + 1));
      expect(find.text('Edit local group'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(
          currentL10n.groupActionsName('Local terminal credential defaults'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save current window layout'));
      await pumpUntilIdle(tester);
      final checkProfile = await tester.runAsync(
        () => profileService.unlock(
          profileId: profileRecord.profileId,
          password: _password,
        ),
      );
      final checkDatabase = await tester.runAsync(
        () => LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
          profileId: profileRecord.profileId,
          localDataDomainId: profileRecord.localDataDomainId,
          localVaultId: profileRecord.localVaultId,
        ),
      );
      final checkRepository = LocalHostRepository(
        database: checkDatabase!,
        profile: checkProfile!,
        crypto: crypto,
      );
      final saved = await tester.runAsync(
        () => checkRepository.getGroup(groupId),
      );
      expect(GroupSessionLayout.read(saved!.group)!.hostIds.toSet(), {
        hostId,
        second.id,
      });
      expect(saved.group.manifest!['preserved'], 'metadata');
      await tester.tap(find.byKey(ValueKey('local_host_group_$groupId')));
      for (
        var i = 0;
        i < 100 && find.byType(TerminalView).evaluate().length < 2;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(TerminalView), findsNWidgets(2));
      expect(sshHarness.sessions, hasLength(initialSessionCount + 1));
      await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(
          currentL10n.groupActionsName('Local terminal credential defaults'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset layout'));
      await pumpUntilIdle(tester);
      final reset = await tester.runAsync(
        () => checkRepository.getGroup(groupId),
      );
      expect(GroupSessionLayout.read(reset!.group), isNull);
      expect(reset.group.manifest!['preserved'], 'metadata');
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
      await tester.runAsync(() async {
        await checkProfile.lock();
        await checkDatabase.close();
      });
    },
  );

  testWidgets('Host context SFTP reuses authenticated host transport', (
    tester,
  ) async {
    await openFixtureTerminal(tester);
    final socketCount = sshHarness.socketCount;
    await hostContext(tester, hostId, 'local_host_sftp');
    await pumpUntilVisible(tester, find.byType(RemoteFileWorkspace));
    expect(sshHarness.socketCount, socketCount);
    expect(sshHarness.sftpClients.last.listedPaths, contains('/'));
    final files = tester
        .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
        .tabs
        .last;
    expect(files.isFile, isTrue);
    await tester.tap(find.byTooltip('Close ${files.title}'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await drainClose(tester);
  });

  testWidgets(
    'SCP file tab downloads selected file through clicked SSH owner',
    (tester) async {
      await openFixtureTerminal(tester);
      final owner = sshHarness.clients.last;
      final socketCount = sshHarness.socketCount;
      await hostContext(tester, hostId, 'local_host_scp_upload');
      await pumpUntilVisible(tester, find.text('note.txt'));
      expect(find.text('Upload file'), findsNothing);
      final browser = tester.widget<RemoteFileWorkspace>(
        find.byType(RemoteFileWorkspace),
      );
      expect(browser.controller.connection.client, same(owner));
      expect(browser.controller.protocol, SshTransferProtocol.scp);
      await tester.tap(find.byTooltip(currentL10n.filenameActions('note.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      final dialog = transferDialog(tester);
      expect(dialog.client, same(owner));
      expect(dialog.direction, SshTransferDirection.download);
      expect(dialog.initialProtocol, SshTransferProtocol.scp);
      expect(dialog.remotePath, '/note.txt');
      expect(sshHarness.socketCount, socketCount);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
    },
  );

  testWidgets('Host context refused trust never transfers through other host', (
    tester,
  ) async {
    final profile = await profileService.unlock(
      profileId: profileRecord.profileId,
      password: _password,
    );
    final db = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final repository = LocalHostRepository(
      database: db,
      profile: profile,
      crypto: crypto,
    );
    final other = await repository.createHost(
      HostRecord(
        id: const Uuid().v4(),
        name: 'Untrusted other host',
        address: 'other.example.test',
        port: 2222,
        username: 'local-user',
        credentialId: credentialId,
      ),
    );
    await db.close();
    await profile.lock();
    await openFixtureTerminal(tester);
    await hostContext(tester, other.id, 'local_host_scp_upload');
    await pumpUntilVisible(
      tester,
      find.byKey(const ValueKey('local_ssh_host_key_approve')),
    );
    await tester.tap(find.text('Reject'));
    await pumpUntilIdle(tester);
    expect(find.text('Download file'), findsNothing);
    expect(find.byType(SegmentedButton<SshTransferProtocol>), findsNothing);
    expect(sshHarness.userAuthenticationCount, 1);
    // The click opened the other host's tab at once; the rejected attempt
    // stays there as a failed, never-connected tab (retry/close), as cloud
    // tabs do. It never borrows the first host's session.
    final tabs = tester
        .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
        .tabs;
    expect(tabs, hasLength(3));
    final rejected = tabs.singleWhere((t) => t.title == other.name);
    expect(rejected.isConnected, isFalse);
    expect(rejected.canOpenFiles, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await drainClose(tester);
  });

  Future<void> dragMouse(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();
  }

  for (final axis in [Axis.horizontal, Axis.vertical]) {
    testWidgets(
      'Local SSH actual tab drag ${axis.name} keeps independent panes and streams',
      (tester) async {
        await openFixtureTerminal(tester);
        final firstSession = sshHarness.sessions.last;
        final firstTerminal = tester
            .widget<TerminalView>(
              find.byKey(const ValueKey('local_ssh_terminal_view')),
            )
            .terminal;
        var tabs = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        final firstId = tabs.tabs.last.id;
        await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
        await tester.pumpAndSettle();
        firstSession.emitStdout('FIRST_WHILE_HOME\r\n');
        await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
        await pumpUntilVisible(
          tester,
          find.byKey(const ValueKey('local_ssh_terminal_view')),
        );
        await pumpUntilIdle(tester);
        final secondSession = sshHarness.sessions.last;
        final secondTerminal = tester
            .widget<TerminalView>(
              find.byKey(const ValueKey('local_ssh_terminal_view')),
            )
            .terminal;
        tabs = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        final secondId = tabs.tabs.last.id;
        expect(secondId, isNot(firstId));
        expect(identical(firstTerminal, secondTerminal), isFalse);
        final firstTab = find.byKey(ValueKey('workspace-tab-$firstId'));
        final secondTab = find.byKey(ValueKey('workspace-tab-$secondId'));

        await dragMouse(
          tester,
          tester.getCenter(secondTab),
          tester.getCenter(firstTab),
        );
        tabs = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        expect(tabs.tabs.map((t) => t.id), ['hosts', secondId, firstId]);
        // Right-click properties selects the existing first session, and contains
        // display metadata only even though this Host resolves a stored credential.
        await tester.tap(
          firstTab,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Properties'));
        await tester.pumpAndSettle();
        expect(find.text('Connection properties'), findsOneWidget);
        expect(find.textContaining('test-only-local-password'), findsNothing);
        expect(find.textContaining(_password), findsNothing);
        final visibleProperties = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((t) => t.data ?? '')
            .join();
        expect(visibleProperties, contains('host.example.test'));
        expect(visibleProperties, contains('local-user'));
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();

        final firstPane = find.byKey(ValueKey('session-pane-$firstId'));
        final rect = tester.getRect(firstPane);
        final destination = axis == Axis.horizontal
            ? Offset(rect.right - 20, rect.center.dy)
            : Offset(rect.center.dx, rect.bottom - 20);
        await dragMouse(tester, tester.getCenter(secondTab), destination);
        final layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.root, isA<SessionWorkspaceSplit>());
        expect((layout.root! as SessionWorkspaceSplit).axis, axis);
        expect(layout.sessionIds.toSet(), {firstId, secondId});
        expect(find.byType(TerminalView), findsNWidgets(2));
        final secondPane = find.byKey(ValueKey('session-pane-$secondId'));
        final firstRect = tester.getRect(firstPane),
            secondRect = tester.getRect(secondPane);
        if (axis == Axis.horizontal) {
          expect(firstRect.center.dy, closeTo(secondRect.center.dy, 1));
          expect(
            (firstRect.center.dx - secondRect.center.dx).abs(),
            greaterThan(100),
          );
        } else {
          expect(firstRect.center.dx, closeTo(secondRect.center.dx, 1));
          expect(
            (firstRect.center.dy - secondRect.center.dy).abs(),
            greaterThan(50),
          );
        }
        firstSession.emitStdout('FIRST_PANE_ONLY\r\n');
        secondSession.emitStdout('SECOND_PANE_ONLY\r\n');
        await tester.pump();
        expect(firstTerminal.buffer.getText(), contains('FIRST_WHILE_HOME'));
        expect(firstTerminal.buffer.getText(), contains('FIRST_PANE_ONLY'));
        expect(
          firstTerminal.buffer.getText(),
          isNot(contains('SECOND_PANE_ONLY')),
        );
        expect(secondTerminal.buffer.getText(), contains('SECOND_PANE_ONLY'));
        expect(
          secondTerminal.buffer.getText(),
          isNot(contains('FIRST_PANE_ONLY')),
        );
        firstSession.writes.clear();
        secondSession.writes.clear();
        await tester.tap(
          find.descendant(of: firstPane, matching: find.byType(TerminalView)),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'first-input'),
        );
        await tester.pump();
        expect(
          firstSession.writes.expand((b) => b).toList(),
          utf8.encode('first-input'),
        );
        expect(secondSession.writes, isEmpty);
        await tester.tap(
          find.descendant(of: secondPane, matching: find.byType(TerminalView)),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'second-input'),
        );
        await tester.pump();
        expect(
          secondSession.writes.expand((b) => b).toList(),
          utf8.encode('second-input'),
        );
        expect(
          firstSession.writes.expand((b) => b).toList(),
          utf8.encode('first-input'),
        );

        if (axis == Axis.horizontal) {
          final sessionCountBeforeUnsplit = sshHarness.sessions.length;
          final authenticationCountBeforeUnsplit =
              sshHarness.userAuthenticationCount;
          final unsplitMouse = await tester.createGesture(
            pointer: 88,
            kind: PointerDeviceKind.mouse,
          );
          final bounds = tester.getRect(firstPane);
          await unsplitMouse.addPointer(location: bounds.center);
          await unsplitMouse.moveTo(
            tester.getCenter(find.byKey(ValueKey('pane-handle-$firstId'))),
          );
          await tester.pump();
          await tester.tap(find.byKey(ValueKey('pane-unsplit-$firstId')));
          await tester.pumpAndSettle();
          await unsplitMouse.removePointer();
          expect(layout.sessionIds, [secondId]);
          expect(firstSession.closed, false);
          expect(secondSession.closed, false);
          expect(
            find.byKey(ValueKey('workspace-group-$firstId')),
            findsNothing,
          );
          await tester.tap(firstTab);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
            same(firstTerminal),
          );
          final boundsAfter = tester.getRect(firstPane);
          await dragMouse(
            tester,
            tester.getCenter(secondTab),
            Offset(boundsAfter.right - 20, boundsAfter.center.dy),
          );
          expect(layout.sessionIds.toSet(), {firstId, secondId});
          expect(
            find.byKey(ValueKey('workspace-group-$firstId')),
            findsOneWidget,
          );
          expect(sshHarness.sessions, hasLength(sessionCountBeforeUnsplit));
          expect(
            sshHarness.userAuthenticationCount,
            authenticationCountBeforeUnsplit,
          );
        }
        await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalView), findsNothing);
        expect(firstSession.closed, false);
        expect(secondSession.closed, false);
        firstSession.emitStdout('FIRST_BACKGROUND\r\n');
        secondSession.emitStdout('SECOND_BACKGROUND\r\n');
        await tester.pump();
        await tester.tap(firstTab);
        await tester.pumpAndSettle();
        expect(find.byType(TerminalView), findsNWidgets(2));
        expect(firstTerminal.buffer.getText(), contains('FIRST_BACKGROUND'));
        expect(secondTerminal.buffer.getText(), contains('SECOND_BACKGROUND'));
        expect(
          find.byKey(ValueKey('workspace-group-$firstId')),
          findsOneWidget,
        );
        expect(secondTab, findsNothing);
        final closeMouse = await tester.createGesture(
          pointer: 77,
          kind: PointerDeviceKind.mouse,
        );
        final secondBounds = tester.getRect(secondPane);
        await closeMouse.addPointer(location: secondBounds.center);
        await closeMouse.moveTo(
          tester.getCenter(find.byKey(ValueKey('pane-handle-$secondId'))),
        );
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('pane-close-$secondId')));
        await closeMouse.removePointer();
        await drainClose(tester);
        expect(secondSession.closed, true);
        expect(firstSession.closed, false);
        expect(find.byType(TerminalView), findsOneWidget);
        expect(
          tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
          same(firstTerminal),
        );
        firstSession.emitStdout('FIRST_SURVIVES_CLOSE\r\n');
        await tester.pump();
        expect(
          firstTerminal.buffer.getText(),
          contains('FIRST_SURVIVES_CLOSE'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await drainClose(tester);
      },
    );
  }

  testWidgets(
    'LocalVault font, palette and semantic shortcuts drive native terminal runtime',
    (tester) async {
      LocalHostRepository? activeRepository;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: LocalProfileFlow(
            catalog: catalog,
            service: profileService,
            crypto: crypto,
            onExit: () {},
            quarantineRegistry: DatabaseQuarantineRegistry(),
            databaseFactory: (profile, {required mode}) async {
              final record = profile.record;
              final database = await LocalVaultDatabase.openForTesting(
                executor: NativeDatabase(
                  File('${directory.path}/vault.sqlite'),
                ),
                profileId: record.profileId,
                localDataDomainId: record.localDataDomainId,
                localVaultId: record.localVaultId,
                mode: mode,
              );
              openedDatabases.add(database);
              return database;
            },
            repositoryFactory:
                ({required database, required profile, required crypto}) =>
                    activeRepository = LocalHostRepository(
                      database: database,
                      profile: profile,
                      crypto: crypto,
                    ),
            sshControllerFactory: (repository) => LocalProfileSshController(
              repository: repository,
              serviceForTesting: sshHarness.createService(
                knownHostDecisionLock: repository.knownHostDecisionLock,
              ),
            ),
          ),
        ),
      );
      await pumpUntilIdle(tester);

      await tester.tap(
        find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        _password,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.byKey(ValueKey('local_host_$hostId')), findsOneWidget);
      expect(activeRepository, isNotNull);

      await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_host_key_approve')),
      );
      await tester.tap(
        find.byKey(const ValueKey('local_ssh_host_key_approve')),
      );
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );

      final terminalView = tester.widget<TerminalView>(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      expect(terminalView.textStyle.fontSize, 16);
      expect(
        terminalView.theme.background,
        buildTerminalColorTheme(VaultTerminalThemeChoice.light).background,
      );
      expect(sshHarness.socketCount, 2);
      expect(sshHarness.userAuthenticationCount, 1);

      final firstSession = sshHarness.sessions.last;
      final firstTerminal = terminalView.terminal;
      firstSession.emitStdout('first-session-only\r\n');
      await tester.tap(
        find.descendant(
          of: find.byType(WorkspaceTabBar),
          matching: find.text('Home'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      await pumpUntilIdle(tester);
      final secondView = tester.widget<TerminalView>(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      expect(identical(secondView.terminal, firstTerminal), isFalse);
      final secondSession = sshHarness.sessions.last;
      secondView.terminal.textInput('second');
      await tester.pump();
      expect(
        secondSession.writes.expand((value) => value).toList(),
        utf8.encode('second'),
      );
      expect(firstSession.writes, isEmpty);
      // Disconnect retains this tab; closing it remains a separate action.
      await terminalAction(tester, 'local_ssh_disconnect');
      await drainClose(tester);
      final disconnected = tester.widget<TerminalView>(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      expect(disconnected.terminal, same(secondView.terminal));
      expect(disconnected.readOnly, isTrue);
      final stoppedClient = sshHarness.clients.singleWhere(
        (c) => identical(c.session, secondSession),
      );
      for (var i = 0; i < 150 && !stoppedClient.closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        sshHarness.clients
            .singleWhere((c) => identical(c.session, secondSession))
            .closed,
        isTrue,
      );
      expect(
        sshHarness.clients
            .singleWhere((c) => identical(c.session, firstSession))
            .closed,
        isFalse,
      );
      expect(
        find.byKey(const ValueKey('session_restore_connection')),
        findsOneWidget,
      );
      final retainedTabs = tester.widget<WorkspaceTabBar>(
        find.byType(WorkspaceTabBar),
      );
      expect(retainedTabs.tabs.where((tab) => !tab.isHome), hasLength(2));
      retainedTabs.onClose(retainedTabs.selectedId);
      await drainClose(tester);
      final restored = tester.widget<TerminalView>(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      expect(identical(restored.terminal, firstTerminal), isTrue);
      expect(
        restored.terminal.buffer.getText(),
        contains('first-session-only'),
      );
      firstSession.emitStdout('needle first needle\r\n');
      await tester.pump();
      await pressAlt(tester, LogicalKeyboardKey.keyF);
      final searchField = find.byKey(const ValueKey('terminal-sidebar-query'));
      await pumpUntilVisible(tester, searchField);
      await tester.enterText(searchField, 'needle');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('1 of 2 matches'), findsOneWidget);

      for (var index = 0; index < 6; index++) {
        await pressAlt(tester, LogicalKeyboardKey.keyN);
        expect(find.text('2 of 2 matches'), findsOneWidget);
        await pressAlt(tester, LogicalKeyboardKey.keyP);
        expect(find.text('1 of 2 matches'), findsOneWidget);
      }

      await pressAlt(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TerminalView>(
              find.byKey(const ValueKey('local_ssh_terminal_view')),
            )
            .readOnly,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('session_restore_connection')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'file tabs drag into mixed panes, duplicate independently, and retire with owner',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await openFixtureTerminal(tester);
      WorkspaceTabBar bar() =>
          tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      final owner = bar().tabs.last.id;
      final session = sshHarness.sessions.last;
      bar().onSftp!(owner);
      await pumpUntilVisible(tester, find.byType(RemoteFileWorkspace));
      final sftpId = bar().selectedId;
      final sftp = tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller;
      await sftp.navigate('/work');
      await tester.pumpAndSettle();
      bar().onScp!(owner);
      await tester.pumpAndSettle();
      final scpId = bar().selectedId;
      final scp = tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller;
      var rect = tester.getRect(find.byKey(ValueKey('session-pane-$scpId')));
      await dragMouse(
        tester,
        tester.getCenter(find.byKey(ValueKey('workspace-tab-$sftpId'))),
        Offset(rect.left + 20, rect.center.dy),
      );
      expect(find.byType(RemoteFileWorkspace), findsNWidgets(2));
      final layout = tester
          .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
          .controller;
      expect(layout.sessionIds.toSet(), {sftpId, scpId});
      rect = tester.getRect(find.byKey(ValueKey('session-pane-$scpId')));
      await dragMouse(
        tester,
        tester.getCenter(find.byKey(ValueKey('workspace-tab-$owner'))),
        Offset(rect.center.dx, rect.bottom - 20),
      );
      expect(layout.sessionIds.toSet(), {sftpId, scpId, owner});
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(RemoteFileWorkspace), findsNWidgets(2));
      expect(sftp.path, '/work');
      expect(scp.path, '/');
      expect(find.text('Modified'), findsNWidgets(2));
      final entryRect = tester.getRect(find.text('inside.txt'));
      expect(entryRect.height, lessThan(24));
      // Cancel split restores an independent file tab without closing its channel/owner.
      final fileMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      final fileBounds = tester.getRect(
        find.byKey(ValueKey('session-pane-$sftpId')),
      );
      await fileMouse.addPointer(location: fileBounds.center);
      await fileMouse.moveTo(
        tester.getCenter(find.byKey(ValueKey('pane-handle-$sftpId'))),
      );
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('pane-unsplit-$sftpId')));
      await tester.pumpAndSettle();
      await fileMouse.removePointer();
      expect(layout.sessionIds, isNot(contains(sftpId)));
      expect(sftp.isClosed, false);
      expect(session.closed, false);
      // The right-click affordance must work on file tabs, with the current path.
      await tester.tap(
        find.byKey(ValueKey('workspace-tab-$sftpId')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Split left/right'), findsOneWidget);
      await tester.tap(find.text('Duplicate tab'));
      await tester.pumpAndSettle();
      final copyId = bar().selectedId;
      expect(copyId, isNot(sftpId));
      final copy = tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller;
      expect(copy, isNot(same(sftp)));
      expect(copy.path, '/work');
      await copy.up();
      await tester.pumpAndSettle();
      expect(sftp.path, '/work');
      bar().onClose(copyId);
      await tester.pumpAndSettle();
      expect(copy.isClosed, isTrue);
      expect(sftp.isClosed, isFalse);
      expect(session.closed, isFalse);
      // Closing the owner removes all borrowed channels and their pane IDs.
      bar().onClose(owner);
      await drainClose(tester);
      expect(sftp.isClosed, isTrue);
      expect(scp.isClosed, isTrue);
      expect(layout.sessionIds, isEmpty);
      expect(bar().tabs, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await drainClose(tester);
    },
  );

  for (final outcome in [0, 1, 2]) {
    final failOwner = outcome == 1;
    final revoked = outcome == 2;
    testWidgets(
      revoked
          ? 'saved file restore stops on real UI scope disposal during owner handshake'
          : failOwner
          ? 'saved files do not replace failed exact owner with another same-host connection'
          : 'saved same-host file panes restore exact SSH owners without extra connections',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await openFixtureTerminal(tester);
        WorkspaceTabBar bar() =>
            tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        final first = bar().selectedId;
        bar().onSftp!(first);
        await pumpUntilVisible(tester, find.byType(RemoteFileWorkspace));
        await tester.runAsync(
          () => tester
              .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
              .controller
              .navigate('/work'),
        );
        bar().onSelect(first);
        await tester.pumpAndSettle();
        bar().onDuplicate!(first);
        for (
          var i = 0;
          i < 100 && sshHarness.userAuthenticationCount < 2;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await pumpUntilIdle(tester);
        final second = bar().selectedId;
        expect(second, isNot(first));
        bar().onScp!(second);
        await pumpUntilVisible(tester, find.byType(RemoteFileWorkspace));
        expect(sshHarness.userAuthenticationCount, 2);
        final originalIds = bar().tabs
            .where((t) => !t.isHome)
            .map((t) => t.id)
            .toList();
        await terminalAction(tester, 'local_save_window_combination');
        await pumpUntilVisible(
          tester,
          find.widgetWithText(AlertDialog, currentL10n.saveWindowSet),
        );
        await tester.enterText(
          find.byType(TextField).last,
          'owner association regression',
        );
        await tester.tap(find.widgetWithText(FilledButton, currentL10n.save2));
        await pumpUntilIdle(tester);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        final pref = await tester.runAsync(
          () => activeRepository!.getPreference(
            scope: 'workspace',
            key: VaultPreferenceRecord.windowCombinationsKey,
            platformFamily: 'all',
          ),
        );
        expect(pref, isNotNull);
        final recipe = WindowCombination.decode(pref!.value as String).single;
        expect(recipe.schemaVersion, 4);
        final files = recipe.panes
            .where((p) => {'sftp', 'scp'}.contains(p.kind))
            .toList();
        expect(files, hasLength(2));
        expect(files.map((p) => p.ownerPane).toSet(), hasLength(2));
        expect(files.first.remotePath, '/work');
        for (final id in originalIds) {
          bar().onClose(id);
          await drainClose(tester);
        }
        expect(bar().tabs.where((t) => !t.isHome), isEmpty);
        expect(
          sshHarness.authenticatedClients.every(
            (c) => (c.session as _FakeSession).closed,
          ),
          isTrue,
        );
        final home = bar().tabs.firstWhere((t) => t.isHome).id;
        bar().onSelect(home);
        await pumpUntilVisible(
          tester,
          find.byKey(ValueKey('window-combination-${recipe.id}')),
        );
        if (failOwner) sshHarness.failAuthenticationAttempt = 4;
        final gate = revoked ? Completer<void>() : null;
        if (revoked) sshHarness.authenticationGate = gate;
        await tester.tap(
          find.byKey(ValueKey('window-combination-${recipe.id}')),
        );
        if (revoked) {
          for (
            var attempt = 0;
            attempt < 100 && sshHarness.authenticationAttempts < 3;
            attempt++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(sshHarness.authenticationAttempts, 3);
          await tester.pumpWidget(const SizedBox.shrink());
          gate!.complete();
          await drainClose(tester);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          expect(
            sshHarness.authenticationAttempts,
            3,
            reason: 'no second owner or file fallback after scope revocation',
          );
          // Disposal cancels the pending owner attempt: a client that finished
          // authenticating afterwards is closed before any shell is opened.
          expect(
            sshHarness.authenticatedClients.every(
              (c) =>
                  (c.session as _FakeSession).closed ||
                  (c.closed && !c.shellOpened),
            ),
            isTrue,
          );
          return;
        }
        for (
          var i = 0;
          i < 100 && sshHarness.userAuthenticationCount < (failOwner ? 3 : 4);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await pumpUntilIdle(tester);
        for (
          var attempt = 0;
          attempt < 100 &&
              bar().tabs.where((t) => t.isFile).length < (failOwner ? 1 : 2);
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(
          sshHarness.userAuthenticationCount,
          failOwner ? 3 : 4,
          reason: 'no implicit file-owner authentication',
        );
        expect(sshHarness.authenticationAttempts, 4);
        // A failed owner keeps its (failed, never-connected) tab; files are
        // only restored onto the connected exact owner.
        expect(bar().tabs.where((t) => !t.isHome && !t.isFile), hasLength(2));
        expect(
          bar().tabs.where((t) => !t.isHome && !t.isFile && t.isConnected),
          hasLength(failOwner ? 1 : 2),
        );
        final restoredFiles = bar().tabs.where((t) => t.isFile).toList();
        expect(restoredFiles, hasLength(failOwner ? 1 : 2));
        for (final tab in restoredFiles) {
          bar().onSelect(tab.id);
          await tester.pumpAndSettle();
          final controller = tester
              .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
              .controller;
          final ownerOrdinal = controller.protocol == SshTransferProtocol.sftp
              ? 0
              : 1;
          expect(
            controller.connection.client,
            same(sshHarness.authenticatedClients[2 + ownerOrdinal]),
          );
          expect(controller.path, ownerOrdinal == 0 ? '/work' : '/');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await drainClose(tester);
      },
    );
  }

  testWidgets('duplicate SSH tab creates a separate authenticated connection', (
    tester,
  ) async {
    await openFixtureTerminal(tester);
    final before = sshHarness.sessions.last;
    final sessionCount = sshHarness.sessions.length;
    final authenticationCount = sshHarness.userAuthenticationCount;
    final bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
    bar.onDuplicate!(bar.selectedId);
    for (
      var attempt = 0;
      attempt < 100 &&
          sshHarness.userAuthenticationCount == authenticationCount;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await pumpUntilIdle(tester);

    expect(sshHarness.sessions, hasLength(sessionCount + 1));
    expect(sshHarness.userAuthenticationCount, authenticationCount + 1);
    expect(sshHarness.sessions.last, isNot(same(before)));
    expect(before.closed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await drainClose(tester);
  });

  testWidgets('file tabs persist path and close without closing SSH owner', (
    tester,
  ) async {
    await openFixtureTerminal(tester);
    expect(find.byType(AppBar), findsNothing);
    final terminalTab = tester
        .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
        .tabs
        .last;
    final session = sshHarness.sessions.last;
    await terminalAction(tester, 'local_ssh_open_sftp');
    await pumpUntilVisible(tester, find.text('work'));
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('../unsafe'), findsNothing);
    expect(find.text('line\nbreak'), findsNothing);
    expect(find.text('c1\u0085name'), findsNothing);
    final fileTab = tester
        .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
        .tabs
        .last;
    expect(fileTab.isFile, isTrue);
    final browser = tester.widget<RemoteFileWorkspace>(
      find.byType(RemoteFileWorkspace),
    );
    final fileTransport =
        (browser.controller.connection.client as _FakeClient).sftpClient;
    await tester.tap(find.text('work'));
    await pumpUntilVisible(tester, find.text('inside.txt'));
    expect(browser.controller.path, '/work');
    await tester.tap(find.byKey(ValueKey('workspace-tab-${terminalTab.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(ValueKey('workspace-tab-${fileTab.id}')),
    );
    await tester.tap(find.byKey(ValueKey('workspace-tab-${fileTab.id}')));
    await tester.pumpAndSettle();
    expect(browser.controller.path, '/work');
    expect(find.text('inside.txt'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('workspace-tab-${terminalTab.id}')));
    await tester.pumpAndSettle();
    await terminalAction(tester, 'local_ssh_open_scp');
    await pumpUntilVisible(tester, find.text('note.txt'));
    final scpBrowser = tester.widget<RemoteFileWorkspace>(
      find.byType(RemoteFileWorkspace),
    );
    expect(scpBrowser.controller.path, '/');
    expect(scpBrowser.controller.protocol, SshTransferProtocol.scp);
    expect(browser.controller.path, '/work');
    final scpTab = tester
        .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
        .tabs
        .last;
    await tester.ensureVisible(find.byTooltip('Close ${scpTab.title}'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close ${scpTab.title}'));
    await tester.pumpAndSettle();
    expect(session.closed, false);
    await tester.ensureVisible(
      find.byKey(ValueKey('workspace-tab-${fileTab.id}')),
    );
    await tester.tap(find.byKey(ValueKey('workspace-tab-${fileTab.id}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller,
      same(browser.controller),
    );
    expect(browser.controller.path, '/work');
    await tester.tap(find.byTooltip('File actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    final nameInput = find.byKey(const ValueKey('file_manager_name_input'));
    await pumpUntilVisible(tester, nameInput);
    await tester.enterText(nameInput, 'reports');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fileTransport.createdDirectories, ['/work/reports']);
    await tester.tap(find.byTooltip('Close ${fileTab.title}'));
    await tester.pumpAndSettle();
    expect(browser.controller.isClosed, isTrue);
    expect(session.closed, false);
    expect(fileTransport.closed, 2);
    await tester.tap(find.byKey(ValueKey('workspace-tab-${terminalTab.id}')));
    await tester.pumpAndSettle();
    await terminalAction(tester, 'local_ssh_open_sftp');
    await pumpUntilVisible(tester, find.byType(RemoteFileWorkspace));
    await tester.tap(find.byTooltip('Close ${terminalTab.title}'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar)).tabs,
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await drainClose(tester);
  });
}

class _FakeSshHarness {
  final sessions = <_FakeSession>[];
  final clients = <_FakeClient>[];
  final authenticatedClients = <_FakeClient>[];
  final sftpClients = <_FakeSftpClient>[];
  final services = <SshService>[];
  int socketCount = 0;
  int userAuthenticationCount = 0;
  int authenticationAttempts = 0;
  int? failAuthenticationAttempt;
  Completer<void>? authenticationGate;

  SshService createService({
    required KnownHostDecisionLock knownHostDecisionLock,
  }) {
    final service = SshService(
      api: null,
      deviceId: 'local-terminal-test-device',
      useRelay: false,
      knownHostDecisionLock: knownHostDecisionLock,
      directSocketConnector: (_, _) async {
        socketCount++;
        return _FakeSocket();
      },
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            final session = _FakeSession();
            sessions.add(session);
            final sftp = _FakeSftpClient();
            sftpClients.add(sftp);
            late final _FakeClient client;
            client = _FakeClient(
              session: session,
              sftpClient: sftp,
              authenticate: () async {
                final approved = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode(_fingerprint)),
                );
                if (!approved) throw SSHAuthFailError('untrusted key');
                authenticationAttempts++;
                if (authenticationAttempts == failAuthenticationAttempt)
                  throw SSHAuthFailError('injected owner failure');
                await authenticationGate?.future;
                userAuthenticationCount++;
                authenticatedClients.add(client);
              },
            );
            clients.add(client);
            return client;
          },
    );
    services.add(service);
    return service;
  }
}

class _FakeClient implements SSHClient {
  _FakeClient({
    required this.session,
    required this.sftpClient,
    required Future<void> Function() authenticate,
  }) : _authenticated = authenticate();

  final SSHSession session;
  final _FakeSftpClient sftpClient;
  final Future<void> _authenticated;
  bool closed = false;
  bool shellOpened = false;

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    shellOpened = true;
    return session;
  }

  @override
  Future<SftpClient> sftp() async => sftpClient;

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpClient extends Fake implements SftpClient {
  final listedPaths = <String>[];
  final createdDirectories = <String>[];
  int closed = 0;

  @override
  Future<SftpHandsake> get handshake async =>
      SftpHandsake(3, const <String, String>{'posix-rename@openssh.com': '1'});

  @override
  Future<List<SftpName>> listdir(String path) async {
    listedPaths.add(path);
    if (path == '/') {
      return [
        _sftpEntry('work', directory: true),
        _sftpEntry('note.txt'),
        _sftpEntry('../unsafe'),
        _sftpEntry('line\nbreak'),
        _sftpEntry('c1\u0085name'),
      ];
    }
    return [_sftpEntry('inside.txt')];
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    createdDirectories.add(path);
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      // ignore: prefer_const_constructors
      SftpFileAttrs(mode: SftpFileMode.value(0x81a4), size: 19);

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => _FakeSftpFile();

  @override
  Future<void> close() async {
    closed++;
  }
}

class _FakeSftpFile extends Fake implements SftpFile {
  @override
  Future<SftpFileAttrs> stat() async =>
      // ignore: prefer_const_constructors
      SftpFileAttrs(mode: SftpFileMode.value(0x81a4), size: 19);

  @override
  Future<Uint8List> readBytes({int? offset, int? length}) async =>
      Uint8List.fromList(utf8.encode('fixture file body\n'));

  @override
  Future<void> close() async {}
}

SftpName _sftpEntry(String name, {bool directory = false}) => SftpName(
  filename: name,
  longname: name,
  attr: SftpFileAttrs(
    mode: SftpFileMode.value((directory ? 0x4000 : 0x8000) | 0x1a4),
  ),
);

class _FakeSession implements SSHSession {
  bool get closed => _stdout.isClosed;
  final _stdout = StreamController<Uint8List>(sync: true);
  final _stderr = StreamController<Uint8List>(sync: true);

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  void emitStdout(String text) =>
      _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  void close() {
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  final writes = <List<int>>[];
  @override
  void write(Uint8List data) {
    writes.add(List<int>.of(data));
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements SSHSocket {
  _FakeSocket() {
    _outgoing.stream.listen((_) {});
  }
  final _closed = Completer<void>();
  final _outgoing = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    if (!_outgoing.isClosed) await _outgoing.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}
