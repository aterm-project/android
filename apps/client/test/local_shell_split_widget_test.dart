import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_local_console.dart';
import 'support/l10n_fixture.dart';

const _vault = '11111111-1111-4111-8111-111111111111';
const _ssh = HostRecord(
  id: 'host-a',
  name: 'Alpha',
  address: 'a.test',
  username: 'u',
  credentialId: 'credential',
);

void main() {
  useAppLocaleFixture('en');

  testWidgets(
    'account workspace: lone shell split makes an independent PTY with own focus; close keeps sibling',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        fixture.consoles.nextCwd = '/srv/live';
        await tester.runAsync(
          () => fixture.app.openLocalShellTab(
            launch: const LocalShellLaunch(
              kind: LocalShellKind.zsh,
              workingDirectory: '/srv',
            ),
          ),
        );
        final shellId = fixture.app.activeTerminalTabId!;
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        WorkspaceTabBar bar() =>
            tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        expect(
          bar().tabs.firstWhere((t) => t.id == shellId).canDetach,
          isA<bool>(),
        );

        bar().onSplit!(shellId, Axis.horizontal);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(fixture.consoles.opened, hasLength(2));
        final original = fixture.consoles.opened.first;
        final copy = fixture.consoles.opened.last;
        expect(copy, isNot(same(original)));
        expect(copy.shell?.kind, LocalShellKind.zsh);
        expect(copy.shell?.workingDirectory, '/srv/live');
        final copyId = fixture.app.terminalTabs
            .firstWhere((t) => t.id != shellId)
            .id;
        final layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.root, isA<SessionWorkspaceSplit>());
        expect(layout.sessionIds.toSet(), {shellId, copyId});
        expect(find.byType(TerminalView), findsNWidgets(2));
        // Both PTYs were sized by their own panes.
        expect(original.resizes, isNotEmpty);
        expect(copy.resizes, isNotEmpty);

        // Per-pane keyboard focus: keys reach only the focused pane's PTY.
        await _typeInto(tester, shellId, 'first-pane');
        await _typeInto(tester, copyId, 'second-pane');
        expect(original.inputs.join(), 'first-pane');
        expect(copy.inputs.join(), 'second-pane');

        // Closing one pane closes only its process.
        bar().onClose(copyId);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(copy.closed, isTrue);
        expect(original.closed, isFalse);
        expect(fixture.app.terminalTabFor(shellId)?.state, 'connected');
        expect(find.byType(TerminalView), findsOneWidget);
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets(
    'account workspace: shells mix with SSH panes; serial duplicate stays serial; plus menu starts shell',
    (tester) async {
      final fixture = await _fixture();
      try {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        await tester.runAsync(() => fixture.app.openTerminalTab(_ssh));
        final sshId = fixture.app.activeTerminalTabId!;
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        WorkspaceTabBar bar() =>
            tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        final menu = bar().homeMenuActions.firstWhere(
          (a) => a.id == 'cloud_new_console',
        );
        await tester.runAsync(() async => menu.run());
        await tester.pumpAndSettle();
        expect(
          fixture.consoles.opened.single.shell,
          LocalShellLaunch.systemDefault,
        );
        final shellId = fixture.app.activeTerminalTabId!;
        expect(shellId, isNot(sshId));
        expect(
          bar().homeMenuActions.any((a) => a.id == 'cloud_shell_options'),
          isTrue,
        );

        // Splitting a shell next to an existing SSH tab mixes the two panes and
        // does not spawn another process.
        bar().onSplit!(shellId, Axis.vertical);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        final layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.sessionIds.toSet(), {sshId, shellId});
        expect(fixture.consoles.opened, hasLength(1));
        await _typeInto(tester, shellId, 'shell-only');
        expect(fixture.consoles.opened.single.inputs.join(), 'shell-only');
        expect(fixture.connections.single.inputs, isEmpty);
        await _typeInto(tester, sshId, 'ssh-only');
        expect(fixture.connections.single.inputs.join(), 'ssh-only');
        expect(fixture.consoles.opened.single.inputs.join(), 'shell-only');

        // Serial duplicate keeps COM port + baud, never becomes a shell.
        await tester.runAsync(
          () => fixture.app.openConsoleTab(serialPort: 'COM4', baudRate: 57600),
        );
        await tester.pumpAndSettle();
        final serialId = fixture.app.activeTerminalTabId!;
        bar().onDuplicate!(serialId);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        final serials = fixture.consoles.opened
            .where((c) => c.serialPort != null)
            .toList();
        expect(serials, hasLength(2));
        expect(serials.map((c) => (c.serialPort, c.baudRate, c.shell)), [
          ('COM4', 57600, null),
          ('COM4', 57600, null),
        ]);
        expect(
          fixture.consoles.opened.where((c) => c.shell != null),
          hasLength(1),
        );
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );
  testWidgets(
    'account workspace splits Shell with an existing Telnet peer and routes focus',
    (tester) async {
      final fixture = await _fixture();
      final wire = _MixedTelnetChannel();
      fixture.app.telnetConnectorForTesting = (_, _) async => wire;
      try {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        await tester.runAsync(() => fixture.app.openLocalShellTab());
        final shellId = fixture.app.activeTerminalTabId!;
        await tester.runAsync(
          () => fixture.app.openTerminalTab(
            const HostRecord(
              id: 'telnet-peer',
              name: 'Telnet peer',
              address: '127.0.0.1',
              protocol: HostProtocol.telnet,
            ),
          ),
        );
        final telnetId = fixture.app.activeTerminalTabId!;
        fixture.app.activateTerminalTab(shellId);
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pumpAndSettle();
        WorkspaceTabBar bar() =>
            tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
        bar().onSplit!(shellId, Axis.horizontal);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(
          fixture.consoles.opened,
          hasLength(1),
          reason:
              'Use the existing Telnet peer instead of creating another Shell',
        );
        final layout = tester
            .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
            .controller;
        expect(layout.sessionIds.toSet(), {shellId, telnetId});
        expect(find.byType(TerminalView), findsNWidgets(2));
        wire.received.clear();
        await _typeInto(tester, telnetId, 'remote-only');
        expect(utf8.decode(wire.received), 'remote-only');
        expect(fixture.consoles.opened.single.inputs, isEmpty);
        await _typeInto(tester, shellId, 'local-only');
        expect(fixture.consoles.opened.single.inputs.join(), 'local-only');
        expect(utf8.decode(wire.received), 'remote-only');
        bar().onClose(telnetId);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(wire.closed, isTrue);
        expect(fixture.consoles.opened.single.closed, isFalse);
        // Let xterm's double-tap gesture window expire before disposal.
        await tester.pump(const Duration(milliseconds: 350));
      } finally {
        await _cleanup(tester, fixture);
      }
    },
  );

  testWidgets('pane handle Split opens a fresh session even beside other tabs; '
      'open tabs are offered as partners; a lone SSH tab reconnects anew', (
    tester,
  ) async {
    final fixture = await _fixture();
    try {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      await tester.runAsync(() => fixture.app.openTerminalTab(_ssh));
      final sshId = fixture.app.activeTerminalTabId!;
      await tester.runAsync(
        () => fixture.app.openLocalShellTab(
          launch: const LocalShellLaunch(kind: LocalShellKind.zsh),
        ),
      );
      final shellId = fixture.app.activeTerminalTabId!;
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pumpAndSettle();
      SessionWorkspaceView view() => tester.widget<SessionWorkspaceView>(
        find.byType(SessionWorkspaceView),
      );
      expect(view().splitTargets!(), containsAll([sshId, shellId]));

      // Real handle controls: white handle -> Split -> Top/bottom.
      await tester.tap(find.byKey(ValueKey('pane-handle-$shellId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pane-split-$shellId')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('pane-split-with-$sshId')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('pane-split-vertical-$shellId')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      // A new independent Shell, not the already-open SSH tab.
      expect(fixture.consoles.opened, hasLength(2));
      expect(fixture.connections, hasLength(1));
      final copyId = fixture.app.terminalTabs
          .firstWhere((t) => t.id != shellId && t.id != sshId)
          .id;
      final layout = view().controller;
      expect(layout.sessionIds.toSet(), {shellId, copyId});
      expect((layout.root! as SessionWorkspaceSplit).axis, Axis.vertical);

      // Explicit partner from the same menu: the open SSH tab joins.
      await tester.tap(find.byKey(ValueKey('pane-handle-$shellId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pane-split-$shellId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pane-split-with-$sshId')));
      await tester.pumpAndSettle();
      expect(layout.sessionIds.toSet(), {shellId, copyId, sshId});
      expect(fixture.connections, hasLength(1));

      // A lone SSH tab: Split opens a fresh connection of the same host.
      await tester.runAsync(() => fixture.app.closeTerminalTab(shellId));
      await tester.runAsync(() => fixture.app.closeTerminalTab(copyId));
      await tester.pumpAndSettle();
      expect(fixture.app.visibleTerminalTabs.map((t) => t.id), [sshId]);
      view().onSplit!(sshId, Axis.horizontal);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(fixture.connections, hasLength(2));
      final fresh = fixture.app.visibleTerminalTabs.firstWhere(
        (t) => t.id != sshId,
      );
      expect(fresh.host?.id, _ssh.id);
      expect(view().controller.sessionIds.toSet(), {sshId, fresh.id});
      await tester.pump(const Duration(milliseconds: 350));
    } finally {
      await _cleanup(tester, fixture);
    }
  });
}

Future<void> _typeInto(WidgetTester tester, String paneId, String text) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('session-pane-$paneId')),
      matching: find.byType(TerminalView),
    ),
  );
  await tester.pump();
  tester.testTextInput.updateEditingValue(TextEditingValue(text: text));
  await tester.pump();
}

Widget _shell(AppController app) => MaterialApp(
  theme: buildAppTheme(),
  home: AppShell(controller: app),
);

class _Fixture {
  _Fixture(this.app, this.database, this.connections, this.consoles);
  final AppController app;
  final ClientDatabase database;
  final List<_Connection> connections;
  final FakeConsoleFactory consoles;
}

Future<_Fixture> _fixture() async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final connections = <_Connection>[];
  final consoles = FakeConsoleFactory();
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          sshConnectorForTesting:
              ({
                required host,
                required credential,
                required verifyHostKey,
              }) async {
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
        ..hosts.add(_ssh);
  app.localConsoleOpenerForTesting = consoles.call;
  return _Fixture(app, database, connections, consoles);
}

Future<void> _cleanup(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => fixture.app.disconnectAllTerminalTabs());
  for (final console in fixture.consoles.opened) {
    expect(console.closed, isTrue, reason: 'no PTY may outlive its tab');
  }
  fixture.app.dispose();
  await tester.runAsync(() => fixture.database.close());
  await tester.binding.setSurfaceSize(null);
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast();
  final _Client _client = _Client();
  bool closed = false;
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
    await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Fake implements SSHClient {}

class _MixedTelnetChannel implements TelnetByteChannel {
  final output = StreamController<Uint8List>();
  final received = <int>[];
  bool closed = false;
  @override
  Stream<Uint8List> get stream => output.stream;
  @override
  void add(Uint8List bytes) {
    if (!closed) received.addAll(bytes);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(output.close());
  }
}
