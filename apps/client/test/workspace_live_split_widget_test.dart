import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

const _workspaceId = '66666666-6666-4666-8666-666666666666';
const _hostA = '77777777-7777-4777-8777-777777777777';
const _hostB = '88888888-8888-4888-8888-888888888888';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit split connects render independent live panes at saved geometry',
    (tester) async {
      final connections = <String, _RecordingConnection>{};
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
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
                    final connection = _RecordingConnection();
                    connections[host.id] = connection;
                    return connection;
                  },
            )
            ..session = AuthSession(
              accountId: 'account-test',
              accessToken: 'access-test',
              expiresIn: 3600,
              refreshToken: 'refresh-test',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'credential-split-a',
                name: 'A credential',
                username: 'tester',
              ),
              CredentialRecord(
                id: 'credential-split-b',
                name: 'B credential',
                username: 'tester',
              ),
            ])
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Split A',
                address: 'split-a.example.test',
                username: 'tester',
                credentialId: 'credential-split-a',
              ),
              HostRecord(
                id: _hostB,
                name: 'Split B',
                address: 'split-b.example.test',
                username: 'tester',
                credentialId: 'credential-split-b',
              ),
            ]);
      final workspace = WorkspaceRecord.fromSplitHostIds(
        id: _workspaceId,
        name: 'Build and logs',
        hostIds: const [_hostA, _hostB],
        axis: WorkspaceSplitAxis.horizontal,
        splitRatioBasisPoints: 6300,
      );
      app.savedWorkspaces.add(workspace);
      final encodedLayout = workspace.toJson().toString();
      var shellMounted = false;

      try {
        app.stageWorkspace(workspace.id);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        shellMounted = true;
        await tester.pump();
        expect(
          find.byKey(const ValueKey('workspace-live-split-flex-horizontal')),
          findsNothing,
        );
        expect(find.byType(TerminalView), findsNothing);

        // A saved layout never auto-connects: each user Connect action is a
        // separate SSH session. The saved tree remains visible as soon as one
        // pane is live, with a reconnect control in the other leaf.
        await app.connectWorkspacePane(
          workspace.id,
          workspace.panes.first.paneId,
        );
        await tester.pump();
        expect(find.byType(TerminalView), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('terminal_function_menu')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-workspace-tmux-session')),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        await _openTerminalAction(tester, 'terminal-workspace-tmux-session');
        await tester.pumpAndSettle();
        expect(find.text('Start resumable tmux session?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workspace-live-split-flex-horizontal')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            ValueKey(
              'workspace-live-split-connect-${workspace.id}-${workspace.panes.last.paneId}',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('Browse files on Split A'), findsOneWidget);
        expect(find.byTooltip('Browse files on Split B'), findsNothing);
        final firstFilesActionSemantics = tester
            .getSemantics(
              find.byKey(
                ValueKey(
                  'workspace-live-split-sftp-${workspace.id}-${workspace.panes.first.paneId}',
                ),
              ),
            )
            .getSemanticsData();
        expect(
          firstFilesActionSemantics.hasAction(SemanticsAction.tap),
          isTrue,
        );

        await app.connectWorkspacePane(
          workspace.id,
          workspace.panes.last.paneId,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('workspace-live-split-flex-horizontal')),
          findsOneWidget,
        );
        expect(find.byType(TerminalView), findsNWidgets(2));
        expect(find.textContaining('Pane 1 · Split A'), findsOneWidget);
        expect(find.textContaining('Pane 2 · Split B'), findsOneWidget);
        final layout = tester.widget<Flex>(
          find.byKey(const ValueKey('workspace-live-split-flex-horizontal')),
        );
        expect(layout.children.whereType<Expanded>().map((pane) => pane.flex), [
          6300,
          3700,
        ]);

        final firstTab = app.workspacePaneTerminalTab(
          workspace.id,
          workspace.panes.first.paneId,
        )!;
        final secondTab = app.workspacePaneTerminalTab(
          workspace.id,
          workspace.panes.last.paneId,
        )!;
        firstTab.sftpPath = '/build/a';
        secondTab.sftpPath = '/logs/b';
        expect(
          tester
              .widgetList<TerminalView>(find.byType(TerminalView))
              .map((view) => view.terminal),
          containsAll([firstTab.terminal, secondTab.terminal]),
        );

        // Each live pane opens SFTP on that pane's exact SSH tab and resumes
        // its own last remote path when the SFTP page is reopened.
        await tester.tap(
          find.byKey(
            ValueKey(
              'workspace-live-split-sftp-${workspace.id}-${workspace.panes.first.paneId}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.page, WorkspacePage.sftp);
        expect(app.activeTerminalTabId, firstTab.id);
        expect(app.sftpPath, '/build/a');
        expect(
          find.text('Remote files · split-a.example.test:22'),
          findsOneWidget,
        );
        expect(connections[_hostA]!.sftpPaths, ['/build/a']);
        expect(connections[_hostB]!.sftpPaths, isEmpty);

        app.showWorkspacePage(WorkspacePage.terminal);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(
              'workspace-live-split-sftp-${workspace.id}-${workspace.panes.last.paneId}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.activeTerminalTabId, secondTab.id);
        expect(app.sftpPath, '/logs/b');
        expect(
          find.text('Remote files · split-b.example.test:22'),
          findsOneWidget,
        );
        expect(connections[_hostA]!.sftpPaths, ['/build/a']);
        expect(connections[_hostB]!.sftpPaths, ['/logs/b']);
        app.showWorkspacePage(WorkspacePage.terminal);
        await tester.pumpAndSettle();

        connections[_hostA]!.emit('\r\nONLY-A-OUTPUT\r\n');
        connections[_hostB]!.emit('\r\nONLY-B-OUTPUT\r\n');
        await tester.pump();
        expect(_bufferText(firstTab), contains('ONLY-A-OUTPUT'));
        expect(_bufferText(firstTab), isNot(contains('ONLY-B-OUTPUT')));
        expect(_bufferText(secondTab), contains('ONLY-B-OUTPUT'));
        expect(_bufferText(secondTab), isNot(contains('ONLY-A-OUTPUT')));
        firstTab.terminal.onOutput?.call('input-to-A');
        secondTab.terminal.onOutput?.call('input-to-B');
        expect(connections[_hostA]!.inputs, ['input-to-A']);
        expect(connections[_hostB]!.inputs, ['input-to-B']);

        await tester.tap(find.byTooltip('Search Split A scrollback'));
        await tester.pump();
        expect(app.activeTerminalTabId, firstTab.id);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.hintText ==
                    'Search this terminal scrollback…',
          ),
          findsOneWidget,
        );

        final disconnectedDescriptor = WorkspaceSessionDescriptor(
          paneId: workspace.panes.first.paneId,
          hostId: _hostA,
          tmuxSessionName: 'atermius_0123456789abcdef0123456789abcdef',
        );
        final workspaceIndex = app.savedWorkspaces.indexWhere(
          (item) => item.id == workspace.id,
        );
        app.savedWorkspaces[workspaceIndex] = workspace.withSessionDescriptor(
          disconnectedDescriptor,
        );
        await connections[_hostA]!.close();
        await tester.pumpAndSettle();
        expect(find.text('SSH · disconnected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('terminal_function_menu')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-workspace-tmux-session')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('terminal-workspace-tmux-clear-reference')),
          findsOneWidget,
          reason: 'stale encrypted references must remain removable offline',
        );
        await tester.tap(
          find.byKey(const ValueKey('terminal-workspace-tmux-clear-reference')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Remove tmux session reference?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // Runtime bindings do not leak into the encrypted layout.
        expect(workspace.toJson().toString(), encodedLayout);
        expect(encodedLayout, isNot(contains(firstTab.id)));
        expect(encodedLayout, isNot(contains(secondTab.id)));
      } finally {
        if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );
}

String _bufferText(TerminalTabSession tab) => List.generate(
  tab.terminal.buffer.lines.length,
  (index) => tab.terminal.buffer.lines[index].toString(),
).join().replaceAll(RegExp(r'\s+'), '');

class _RecordingConnection implements SshConnection {
  _RecordingConnection() {
    _sshClient = _FakeSshClient(sftpPaths);
  }

  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );
  final List<String> inputs = [];
  final List<String> sftpPaths = [];
  late final SSHClient _sshClient;

  void emit(String text) => _output.add(text);

  @override
  late final portForwards = SshPortForwardManager(
    _FakeSshClient(),
    platform: const _UnsupportedPortForwardPlatform(),
  );

  @override
  SSHClient get client => _sshClient;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    await portForwards.closeAll();
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient extends Fake implements SSHClient {
  _FakeSshClient([List<String>? sftpPaths])
    : sftpPaths = sftpPaths ?? <String>[];

  final List<String> sftpPaths;

  @override
  Future<SftpClient> sftp() async => _FakeSftpClient(sftpPaths);
}

class _FakeSftpClient extends Fake implements SftpClient {
  _FakeSftpClient(this.sftpPaths);

  final List<String> sftpPaths;

  @override
  Future<List<SftpName>> listdir(String path) async {
    sftpPaths.add(path);
    return [
      SftpName(
        filename: 'fixture-entry',
        longname: 'fixture-entry',
        attr: SftpFileAttrs(),
      ),
    ];
  }
}

class _UnsupportedPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => 'Unsupported in this test.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError('Port forwarding is not used by this test.');
}

Future<void> _openTerminalAction(WidgetTester tester, String id) async {
  final menu = find.byKey(const ValueKey('terminal_function_menu'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  final action = find.byKey(ValueKey(id));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}
