// Per-machine MCP policy over real AppController tabs (local shell + Telnet).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/app_mcp_workspace.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/fake_local_console.dart';
import 'support/l10n_fixture.dart';

const _telnetHost = HostRecord(
  id: '22222222-2222-4222-8222-222222222222',
  name: 'Policy Telnet',
  address: '127.0.0.1',
  protocol: HostProtocol.telnet,
);

Map<String, dynamic> _call(
  String name, [
  Map<String, dynamic> args = const {},
]) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'tools/call',
  'params': {'name': name, 'arguments': args},
};
Map _content(McpReply reply) =>
    (reply.body!['result'] as Map)['structuredContent'] as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  test(
    'app tabs are authorized by their live host or the local device',
    () async {
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

      final workspace = appMcpWorkspace(app);
      // No authenticated session, server identity or Vault: no scope, so the
      // service can neither start nor load a policy.
      expect(workspace.scope(), isNull);

      final shellId = (await app.openLocalShellTab(
        launch: const LocalShellLaunch(kind: LocalShellKind.bash),
      ))!;
      await app.openTerminalTab(_telnetHost);
      final telnetId = app.activeTerminalTabId!;
      consoles.failWith = const LocalShellException(
        LocalShellIssue.shellNotInstalled,
      );
      final failedId = (await app.openLocalShellTab())!;
      await pumpEventQueue();
      wire.received.clear();

      final byId = {for (final s in workspace.sessions()) s.id: s};
      expect(byId[shellId]!.accessHostId, mcpLocalDeviceHostId);
      // A failed shell keeps a synthetic Host internally; it is still governed
      // by the local-device policy, never by that synthetic ID.
      expect(byId[failedId]!.accessHostId, mcpLocalDeviceHostId);
      expect(byId[telnetId]!.accessHostId, _telnetHost.id);

      var policy = McpAccessPolicy(
        defaultAccess: McpAccessMode.readWrite,
        overrides: {_telnetHost.id: McpAccessMode.denied},
      );
      final protocol = McpProtocol(
        workspace: workspace,
        validateAccess: () {},
        access: (host) => policy.effective(host),
      );
      final ids = await _listed(protocol);
      expect(ids, containsAll([shellId, failedId]));
      expect(ids, isNot(contains(telnetId)));
      final denied = await protocol.handle(
        _call('terminal_write', {'session_id': telnetId, 'text': 'id\r'}),
      );
      expect(_content(denied)['error'], 'session_unavailable');
      await pumpEventQueue();
      expect(wire.received, isEmpty);

      final local = await protocol.handle(
        _call('terminal_write', {'session_id': shellId, 'text': 'local\r'}),
      );
      expect(_content(local)['sent'], isTrue);
      await pumpEventQueue();
      expect(consoles.opened.first.inputs, ['local\r']);

      // Read-only Telnet: visible and readable, never writable or closable.
      policy = policy.withHost(_telnetHost.id, McpAccessMode.readOnly);
      wire.output.add(Uint8List.fromList(utf8.encode('remote-banner')));
      await pumpEventQueue();
      final read = await protocol.handle(
        _call('terminal_read', {'session_id': telnetId}),
      );
      expect(_content(read)['text'], contains('remote-banner'));
      for (final tool in ['terminal_write', 'session_close', 'session_focus']) {
        final reply = await protocol.handle(
          _call(tool, {
            'session_id': telnetId,
            if (tool == 'terminal_write') 'text': 'reboot\r',
          }),
        );
        expect(_content(reply)['error'], 'read_only', reason: tool);
      }
      await pumpEventQueue();
      expect(wire.received, isEmpty);
      expect(wire.closed, isFalse);
      expect(app.terminalTabFor(telnetId), isNotNull);

      // Denying the local device hides every console, including the failed one.
      policy = policy.withHost(mcpLocalDeviceHostId, McpAccessMode.denied);
      expect(await _listed(protocol), [telnetId]);
      expect(
        _content(await protocol.handle(_call('console_open')))['error'],
        'access_denied',
      );
    },
  );
}

Future<List<String>> _listed(McpProtocol protocol) async => [
  for (final row
      in _content(await protocol.handle(_call('sessions_list')))['items']
          as List)
    (row as Map)['id'] as String,
];

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
