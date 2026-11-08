// Integration regression to be installed after both isolated workers merge.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/app_mcp_workspace.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_local_console.dart';
import 'support/l10n_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  test('mixed Shell and Telnet panes keep independent input, MCP identity and closure', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = AppController(
      sodium: await SodiumSumoInit.init(),
      database: database,
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.workspace;
    final consoles = FakeConsoleFactory();
    final wire = _Channel();
    app.localConsoleOpenerForTesting = consoles.call;
    app.telnetConnectorForTesting = (_, _) async => wire;
    addTearDown(() async {
      await app.disconnectAllTerminalTabs();
      app.dispose();
      await database.close();
    });

    final shellId = (await app.openLocalShellTab(
      launch: const LocalShellLaunch(kind: LocalShellKind.bash),
    ))!;
    await app.openTerminalTab(
      const HostRecord(
        id: '11111111-1111-4111-8111-111111111111',
        name: 'Loopback Telnet',
        address: '127.0.0.1',
        protocol: HostProtocol.telnet,
      ),
    );
    final telnetId = app.activeTerminalTabId!;
    final shell = app.terminalTabFor(shellId)!;
    final telnet = app.terminalTabFor(telnetId)!;
    expect(shell.liveTerminalTransport, same(shell.console));
    expect(telnet.liveTerminalTransport, same(telnet.telnet));
    expect(telnet.connection, isNull);
    expect(telnet.desktop, isNull);

    final workspace = SessionWorkspaceController()..activate(shellId);
    addTearDown(workspace.dispose);
    workspace.split(telnetId, shellId, SessionSplitEdge.right);
    final duplicateId = (await app.duplicateConsoleTab(shellId))!;
    workspace.split(duplicateId, shellId, SessionSplitEdge.bottom);
    expect(workspace.groupFor(shellId)?.toSet(), {
      shellId,
      telnetId,
      duplicateId,
    });

    wire.received.clear(); // Exclude initial option negotiation.
    final sessions = appMcpWorkspace(app).sessions();
    final remoteMcp = sessions.singleWhere((s) => s.id == telnetId);
    final shellMcp = sessions.singleWhere((s) => s.id == shellId);
    expect(remoteMcp.kind, 'telnet');
    expect(shellMcp.kind, 'console');
    expect(remoteMcp.connection, isNull);
    shellMcp.input('local-only\r');
    remoteMcp.input('remote-only\r');
    await pumpEventQueue();
    expect(consoles.opened.first.inputs, ['local-only\r']);
    expect(consoles.opened.last.inputs, isEmpty);
    expect(
      utf8.decode(wire.received.expand((bytes) => bytes).toList()),
      'remote-only\r\n',
    );

    wire.output.add(Uint8List.fromList(utf8.encode('remote-output')));
    await pumpEventQueue();
    expect(_contents(remoteMcp.terminal!), contains('remote-output'));
    expect(_contents(shell.terminal), isNot(contains('remote-output')));

    await app.closeTerminalTab(telnetId);
    workspace.remove(telnetId);
    expect(wire.closed, isTrue);
    expect(consoles.opened.every((console) => !console.closed), isTrue);
    expect(workspace.groupFor(shellId)?.toSet(), {shellId, duplicateId});
    app.sendTerminalInputFor(duplicateId, 'still-local\r');
    expect(consoles.opened.last.inputs, ['still-local\r']);

    consoles.failWith = const LocalShellException(
      LocalShellIssue.shellNotInstalled,
    );
    final failedId = await app.openLocalShellTab();
    final failedMcp = appMcpWorkspace(app)
        .sessions()
        .singleWhere((session) => session.id == failedId);
    expect(failedMcp.kind, 'console');
    expect(failedMcp.hostId, isNull);
    expect(failedMcp.connection, isNull);
  });
}

String _contents(Terminal terminal) => [
  for (var index = 0; index < terminal.buffer.lines.length; index++)
    terminal.buffer.lines[index].toString(),
].join('\n');

class _Channel implements TelnetByteChannel {
  final output = StreamController<Uint8List>();
  final received = <Uint8List>[];
  bool closed = false;
  @override
  Stream<Uint8List> get stream => output.stream;
  @override
  void add(Uint8List bytes) {
    if (!closed) received.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(output.close());
  }
}
