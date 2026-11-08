import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/files_window_launch.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/remote_file_workspace.dart';
import 'package:aterm_client/ui/group_session_layout.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/host_system_icon.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/terminal_tools_sidebar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vault = '11111111-1111-4111-8111-111111111111';
const _a = HostRecord(
  id: 'host-a',
  name: 'Alpha',
  address: 'a.test',
  username: 'u',
  credentialId: 'credential',
);
const _b = HostRecord(
  id: 'host-b',
  name: 'Beta',
  address: 'b.test',
  username: 'u',
  credentialId: 'credential',
);

void main() {
  testWidgets(
    'topbar sidebar follows focused cloud split without replacing terminals',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        await tester.runAsync(() => fixture.app.openTerminalTab(_a));
        await tester.runAsync(() => fixture.app.openTerminalTab(_b));
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        final layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        final ids = fixture.app.terminalTabs.map((tab) => tab.id).toList();
        layout.split(ids.first, ids.last, SessionSplitEdge.right);
        tester
            .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
            .onSelect(ids.last);
        await tester.pumpAndSettle();
        final terminals = {
          for (final tab in fixture.app.terminalTabs) tab.id: tab.terminal,
        };
        expect(find.byType(TerminalToolsLauncher), findsNothing);
        final toggle = find.byKey(
          const ValueKey('workspace_terminal_sidebar_button'),
        );
        expect(toggle, findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('terminal-tools-${ids.last}')),
          findsOneWidget,
        );
        expect(layout.selectedId, ids.last);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(TerminalToolsSidebar), findsNothing);
        tester
            .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
            .onSelect(ids.first);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('terminal-tools-${ids.first}')),
          findsOneWidget,
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(fixture.calls, [_a.id, _b.id]);
        for (final tab in fixture.app.terminalTabs) {
          expect(tab.terminal, same(terminals[tab.id]));
        }
        expect(find.byType(TerminalView), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'cloud functions stay in top tabs without duplicate page header',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        expect(find.text('Hosts'), findsOneWidget); // Top Host menu only.
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(FilterChip), findsNothing);
        expect(find.byKey(const ValueKey('cloud_home_search')), findsOneWidget);
        expect(find.text('Your server fleet'), findsNothing);
        expect(find.text('Add host'), findsNothing);
        expect(find.byKey(const ValueKey('cloud_add_group')), findsNothing);
        final menu = find.byKey(const ValueKey('workspace_host_menu'));
        expect(
          find.ancestor(of: menu, matching: find.byType(WorkspaceTabBar)),
          findsOneWidget,
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        for (final key in [
          'cloud_new_ssh',
          'cloud_add_group',
          'host_import_openssh_config',
          'host_import_ansible_inventory',
          'cloud-page-hosts',
          'cloud-page-settings',
          'cloud-sync-now',
          'cloud-vault-$_vault',
          'cloud-lock',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget);
        }
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'cloud file drag, split menus, duplication and Windows footer work together',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        await tester.runAsync(() => fixture.app.openTerminalTab(_a));
        final owner = fixture.app.activeTerminalTab!.id;
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workspace_status_bar')),
          findsNothing,
        );
        WorkspaceTabBar bar() =>
            tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        bar().onSftp!(owner);
        await tester.pumpAndSettle();
        final fileId = bar().selectedId;
        final model = tester
            .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
            .controller;
        await model.navigate('/srv/source');
        bar().onSelect(owner);
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(ValueKey('session-pane-$owner')),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('workspace-tab-$fileId'))),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(12, 0));
        await tester.pump();
        await gesture.moveTo(Offset(rect.right - 20, rect.center.dy));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        var layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.sessionIds.toSet(), {owner, fileId});
        expect(find.byType(RemoteFileWorkspace), findsOneWidget);
        expect(model.path, '/srv/source');
        // Selecting an empty file pane must retire the terminal's keyboard focus.
        await tester.tap(find.byType(TerminalView));
        await tester.pumpAndSettle();
        final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
        expect(terminal.focusNode!.hasFocus, isTrue);
        await tester.tap(find.text('This folder is empty'));
        await tester.pumpAndSettle();
        expect(terminal.focusNode!.hasFocus, isFalse);
        expect(bar().groups, contains(containsAll([owner, fileId])));
        expect(find.byKey(ValueKey('workspace-group-$owner')), findsOneWidget);
        final pointer = gesture;
        await pointer.moveTo(
          tester.getCenter(find.byKey(ValueKey('pane-handle-$fileId'))),
        );
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('pane-unsplit-$fileId')));
        await tester.pumpAndSettle();
        expect(layout.sessionIds, [owner]);
        expect(model.isClosed, isFalse);
        expect(fixture.connections.single.closed, isFalse);
        expect(find.byKey(ValueKey('workspace-tab-$fileId')), findsOneWidget);
        // Restore the group, then an independent tab must not erase it.
        layout.split(fileId, owner, SessionSplitEdge.right);
        bar().onSelect(fileId);
        await tester.pumpAndSettle();
        await pointer.removePointer();
        final inputCount = fixture.connections.single.inputs.length;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
        expect(fixture.connections.single.inputs.length, inputCount);
        bar().onDuplicate!(fileId);
        await tester.pumpAndSettle();
        final copyId = bar().selectedId;
        final copy = tester
            .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
            .controller;
        expect(copy.path, '/srv/source');
        expect(copy, isNot(same(model)));
        bar().onSplit!(copyId, Axis.vertical);
        await tester.pumpAndSettle();
        layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.root, isA<SessionWorkspaceSplit>());
        expect(find.byType(RemoteFileWorkspace), findsNWidgets(2));
        await copy.navigate('/srv/other');
        expect(model.path, '/srv/source');
        bar().onClose(copyId);
        await tester.pumpAndSettle();
        expect(copy.isClosed, isTrue);
        expect(model.isClosed, isFalse);
        expect(fixture.connections.single.closed, isFalse);
        bar().onDuplicate!(owner);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(fixture.calls, [_a.id, _a.id]);
        expect(fixture.connections, hasLength(2));
        bar().onClose(owner);
        await tester.pumpAndSettle();
        expect(model.isClosed, isTrue);
        expect(layout.sessionIds, isNot(contains(fileId)));
        expect(tester.takeException(), isNull);
      } finally {
        await _cleanup(tester, fixture);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('cloud SFTP and SCP tabs preserve separate paths and SSH owner', (
    tester,
  ) async {
    final fixture = await _fixture();
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.runAsync(() => fixture.app.openTerminalTab(_a));
      final source = fixture.app.activeTerminalTab!;
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pumpAndSettle();
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar)).onSftp!(
        source.id,
      );
      await tester.pumpAndSettle();
      final sftp = tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller;
      await sftp.navigate('/srv/sftp');
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar)).onScp!(
        source.id,
      );
      await tester.pumpAndSettle();
      final scp = tester
          .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
          .controller;
      await scp.navigate('/srv/scp');
      expect(scp.protocol, SshTransferProtocol.scp);
      expect(identical(sftp, scp), isFalse);
      expect(sftp.path, '/srv/sftp');
      expect(scp.path, '/srv/scp');
      var bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      expect(bar.tabs.where((tab) => tab.isFile), hasLength(2));
      final sftpId = bar.tabs
          .firstWhere((tab) => tab.title == 'SFTP · Alpha')
          .id;
      bar.onSelect(sftpId);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
            .controller
            .path,
        '/srv/sftp',
      );
      bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      bar.onClose(sftpId);
      await tester.pumpAndSettle();
      expect(sftp.isClosed, isTrue);
      expect(scp.isClosed, isFalse);
      expect(fixture.connections.single.closed, isFalse);
      tester
          .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
          .onClose(source.id);
      await tester.pumpAndSettle();
      expect(scp.isClosed, isTrue);
      await tester.runAsync(() => fixture.connections.single.whenClosed);
      expect(fixture.connections.single.closed, isTrue);
      expect(
        tester
            .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
            .tabs
            .where((tab) => tab.isFile),
        isEmpty,
      );
    } finally {
      await _cleanup(tester, fixture);
    }
  });

  testWidgets(
    'failed requested host launch never borrows unrelated active SSH',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.runAsync(() => fixture.app.openTerminalTab(_b));
        fixture.app.failedHost = _a.id;
        await tester.pumpWidget(
          _shell(
            fixture.app,
            launch: FilesWindowLaunch(
              workspace: FilesWindowWorkspace.cloud,
              scopeId: _vault,
              hostId: _a.id,
              protocol: FilesWindowProtocol.scp,
              serverNamespace: 'https://server.test',
              accountId: 'account-test',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RemoteFileWorkspace), findsNothing);
        expect(fixture.app.attempts, [_b.id, _a.id]);
        expect(fixture.calls, [_b.id]);
        expect(
          tester
              .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
              .tabs
              .where((tab) => tab.isFile),
          isEmpty,
        );
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'exact cloud launch opens requested protocol and path; lock retires files',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.runAsync(() => fixture.app.openTerminalTab(_a));
        await tester.pumpWidget(
          _shell(
            fixture.app,
            launch: FilesWindowLaunch(
              workspace: FilesWindowWorkspace.cloud,
              scopeId: _vault,
              hostId: _a.id,
              protocol: FilesWindowProtocol.scp,
              serverNamespace: 'https://server.test',
              accountId: 'account-test',
              initialPath: '/srv/launch',
            ),
          ),
        );
        await tester.pumpAndSettle();
        final model = tester
            .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
            .controller;
        expect(model.protocol, SshTransferProtocol.scp);
        expect(model.path, '/srv/launch');
        expect(fixture.calls, [_a.id]);
        fixture.app.workspaceLocked = true;
        fixture.app.signal();
        await tester.pumpAndSettle();
        expect(model.isClosed, isTrue);
        expect(find.byType(RemoteFileWorkspace), findsNothing);
        expect(fixture.connections.single.closed, isFalse);
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'cloud hosts are compact, searchable and retain group layout actions',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('host_connect_host-a'));
        expect(tester.getSize(card).height, lessThanOrEqualTo(108));
        expect(tester.getSize(card).width, lessThanOrEqualTo(300));
        expect(find.byType(HostSystemIcon), findsNWidgets(2));
        expect(find.byKey(const ValueKey('cloud_add_group')), findsNothing);
        expect(find.byKey(const ValueKey('cloud_host_search')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        await tester.pumpAndSettle();
        final filters = find.byKey(const ValueKey('host_search_filters'));
        expect(filters, findsOneWidget);
        await tester.tap(
          find.descendant(of: filters, matching: find.text('RDP')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('host-search-result-host-a')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('host-search-result-host-b')),
          findsNothing,
        );
        await tester.tap(
          find.descendant(of: filters, matching: find.text('SSH')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('host-search-result-host-a')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('host-search-result-host-b')),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(FilterChip, 'Favorites'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('host-search-result-host-a')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('host-search-result-host-b')),
          findsNothing,
        );
        await tester.tap(find.widgetWithText(FilterChip, 'Favorites'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('host-search-result-host-a')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('host-search-result-host-b')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('cloud_host_search')),
          'Alpha',
        );
        await tester.pumpAndSettle();
        final palette = find.byKey(const ValueKey('host_search_palette'));
        expect(
          find.descendant(
            of: palette,
            matching: find.byKey(const ValueKey('host-search-result-host-a')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: palette,
            matching: find.byKey(const ValueKey('host-search-result-host-b')),
          ),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpAndSettle();
        expect(
          tester
              .getSize(find.byKey(const ValueKey('host_connect_host-a')))
              .height,
          lessThanOrEqualTo(72),
        );
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'group connects reuse exact hosts and restore, save and reset split geometry',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        fixture.app.hosts
          ..clear()
          ..addAll([
            _a.copyWith(groupId: 'group'),
            _b.copyWith(groupId: 'group'),
          ]);
        final group =
            GroupSessionLayout.capture(
              root: SessionWorkspaceSplit(
                axis: Axis.vertical,
                ratio: .3,
                first: const SessionWorkspacePane('pane-b'),
                second: const SessionWorkspacePane('pane-a'),
              ),
              hostIdsBySession: {'pane-a': _a.id, 'pane-b': _b.id},
              selectedSessionId: 'pane-b',
            ).writeTo(
              const GroupRecord(
                id: 'group',
                name: 'Production',
                manifest: {'keep': 'metadata'},
              ),
            );
        fixture.app.groups.add(group);
        await tester.runAsync(
          () => fixture.app.openTerminalTab(fixture.app.hosts[0]),
        );
        final a = fixture.app.activeTerminalTab!;
        await tester.runAsync(
          () => fixture.app.openTerminalTab(fixture.app.hosts[1]),
        );
        final b = fixture.app.activeTerminalTab!;
        fixture.app.showWorkspacePage(WorkspacePage.hosts);
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cloud_group_connect_group')),
        );
        await tester.pumpAndSettle();
        expect(fixture.calls, [_a.id, _b.id]);
        final workspace = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(workspace.sessionIds, [b.id, a.id]);
        final split = workspace.root! as SessionWorkspaceSplit;
        expect(split.axis, Axis.vertical);
        expect(split.ratio, .3);
        tester
            .widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar))
            .onSelect('hosts');
        await tester.pumpAndSettle();
        // Pick the menu beside the group button rather than host card menus.
        final strip = find.byKey(const ValueKey('cloud_group_tile_group'));
        await tester.tap(
          find.descendant(
            of: strip,
            matching: find.byType(WorkspaceOverflowMenu),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cloud-group-save-layout-group')),
        );
        await tester.pumpAndSettle();
        expect(fixture.app.savedGroups, 1);
        expect(fixture.app.groups.single.manifest?['keep'], 'metadata');
        expect(
          GroupSessionLayout.read(fixture.app.groups.single)!.panes
              .map((p) => p.hostId),
          [_b.id, _a.id],
        );
        await tester.tap(
          find.descendant(
            of: strip,
            matching: find.byType(WorkspaceOverflowMenu),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cloud-group-reset-layout-group')),
        );
        await tester.pumpAndSettle();
        expect(GroupSessionLayout.read(fixture.app.groups.single), isNull);
        expect(fixture.app.groups.single.manifest?['keep'], 'metadata');
        expect(
          fixture.connections.every((connection) => !connection.closed),
          isTrue,
        );
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'cancelled first group handshake stops before another host prompt',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        fixture.app.hosts
          ..clear()
          ..addAll([
            _a.copyWith(groupId: 'group'),
            _b.copyWith(groupId: 'group'),
          ]);
        fixture.app.groups.add(
          const GroupRecord(id: 'group', name: 'Production'),
        );
        fixture.app.failedHost = _a.id;
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cloud_group_connect_group')),
        );
        await tester.pumpAndSettle();
        expect(fixture.app.attempts, [_a.id]);
        expect(fixture.calls, isEmpty);
        expect(fixture.app.terminalTabs, isEmpty);
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'cloud launch with another account remains pending without connecting',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          _shell(
            fixture.app,
            launch: FilesWindowLaunch(
              workspace: FilesWindowWorkspace.cloud,
              scopeId: _vault,
              hostId: _a.id,
              protocol: FilesWindowProtocol.sftp,
              serverNamespace: 'https://server.test',
              accountId: 'other-account',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(fixture.calls, isEmpty);
        expect(find.byType(RemoteFileWorkspace), findsNothing);
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );
}

Widget _shell(AppController app, {FilesWindowLaunch? launch}) => MaterialApp(
  theme: buildAppTheme(),
  home: AppShell(controller: app, filesLaunch: launch),
);

class _Fixture {
  _Fixture(this.app, this.database, this.connections, this.calls);
  final _TestApp app;
  final ClientDatabase database;
  final List<_Connection> connections;
  final List<String> calls;
}

class _TestApp extends AppController {
  _TestApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
    super.sshConnectorForTesting,
  });
  void signal() => notifyListeners();
  String? failedHost;
  final attempts = <String>[];
  int savedGroups = 0;
  @override
  Future<void> saveGroup(
    GroupRecord group, {
    bool Function()? isCurrentContext,
  }) async {
    if (isCurrentContext != null && !isCurrentContext())
      throw StateError('Scope changed');
    savedGroups++;
    final index = groups.indexWhere((value) => value.id == group.id);
    if (index >= 0) groups[index] = group;
    notifyListeners();
  }

  @override
  Future<void> openTerminalTab(
    HostRecord host, {
    void Function(String tabId)? onTabOpened,
  }) {
    attempts.add(host.id);
    if (host.id == failedHost)
      return Future.error(StateError('Connection denied'));
    return super.openTerminalTab(host, onTabOpened: onTabOpened);
  }
}

Future<_Fixture> _fixture() async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final connections = <_Connection>[];
  final calls = <String>[];
  late _Fixture fixture;
  final app =
      _TestApp(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          sshConnectorForTesting:
              ({
                required host,
                required credential,
                required verifyHostKey,
              }) async {
                calls.add(host.id);
                final connection = _Connection();
                connections.add(connection);
                return connection;
              },
        )
        ..api = ApiClient(baseUrl: 'https://server.test')
        ..session = AuthSession(
          accountId: 'account-test',
          accessToken: 'test',
          expiresIn: 3600,
          refreshToken: 'test',
          deviceId: identity.deviceId,
          vaults: const [],
        )
        ..identity = identity
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts
        ..activeVault = const VaultDescriptor(
          id: _vault,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        )
        ..vaults.add(
          const VaultDescriptor(
            id: _vault,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          ),
        )
        ..credentials.add(
          const CredentialRecord(
            id: 'credential',
            name: 'Credential',
            username: 'u',
          ),
        )
        ..hosts.addAll([_a, _b]);
  fixture = _Fixture(app, database, connections, calls);
  return fixture;
}

Future<void> _cleanup(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => fixture.app.disconnectAllTerminalTabs());
  fixture.app.dispose();
  await tester.runAsync(() => fixture.database.close());
  await tester.binding.setSurfaceSize(null);
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast();
  final _Client _client = _Client();
  bool closed = false;
  final _closed = Completer<void>();
  Future<void> get whenClosed => _closed.future;
  @override
  SSHClient get client => _client;
  @override
  Stream<String> get output => _output.stream;
  @override
  late final portForwards = SshPortForwardManager(_client);
  final inputs = <String>[];
  @override
  void input(String text) => inputs.add(text);
  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> close() async {
    closed = true;
    if (!_closed.isCompleted) _closed.complete();
    await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Fake implements SSHClient {
  @override
  Future<SftpClient> sftp() async => _Sftp();
}

class _Sftp extends Fake implements SftpClient {
  @override
  Future<SftpHandsake> get handshake async => SftpHandsake(3, const {});
  @override
  Future<List<SftpName>> listdir(String path) async => [];
  @override
  Future<void> close() async {}
}
