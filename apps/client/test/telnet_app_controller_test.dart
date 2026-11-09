@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/app_mcp_workspace.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

const _secret = 'ephemeral-test-secret';

class _Server {
  _Server(this.socket);
  final ServerSocket socket;
  final List<int> received = [];
  final List<Socket> clients = [];
  bool clientClosed = false;

  static Future<_Server> start() async {
    final server = _Server(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.socket.listen((client) {
      server.clients.add(client);
      client.listen(
        server.received.addAll,
        onDone: () => server.clientClosed = true,
        onError: (_) {},
      );
    });
    return server;
  }

  Future<void> send(List<int> bytes) async {
    clients.single.add(bytes);
    await clients.single.flush();
  }

  bool contains(List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= received.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (received[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  Future<void> close() async {
    for (final client in clients) {
      client.destroy();
    }
    await socket.close();
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _PendingChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  final List<Uint8List> sent = [];
  bool closed = false;
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  void add(Uint8List bytes) => sent.add(bytes);
  @override
  Future<void> close() async {
    closed = true;
    // No listener may exist; don't wait for the done event to be delivered.
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

Future<(AppController, ClientDatabase, List<String>)> _controller() async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final sshCalls = <String>[];
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          sshConnectorForTesting:
              ({required host, required credential, required verifyHostKey}) {
                sshCalls.add(host.id);
                throw StateError('SSH must never be used for Telnet');
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
        ..activeVault = const VaultDescriptor(
          id: 'vault-telnet',
          role: 'owner',
          activeKeyEpoch: 'epoch',
          membershipVersion: 'membership',
        );
  // A group default credential exists: Telnet must never resolve or send it.
  app.credentials.add(
    CredentialRecord(
      id: 'cred-1',
      name: 'Default',
      username: 'admin',
      secret: _secret,
    ),
  );
  app.groups.add(
    const GroupRecord(id: 'g1', name: 'Lab', defaultCredentialId: 'cred-1'),
  );
  return (app, database, sshCalls);
}

HostRecord _telnetHost(int port) => HostRecord(
  id: 'telnet-host',
  name: 'Lab switch',
  address: '127.0.0.1',
  port: port,
  protocol: HostProtocol.telnet,
  groupId: 'g1',
);

void main() {
  useAppLocaleFixture('en');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manual Telnet disconnect retains the tab and restore creates a fresh transport', () async {
    final (app, database, _) = await _controller();
    final channels = <_PendingChannel>[];
    app.telnetConnectorForTesting = (_, _) async { final c = _PendingChannel(); channels.add(c); return c; };
    try {
      await app.openTerminalTab(_telnetHost(2323));
      final tab = app.activeTerminalTab!;
      await app.disconnectTerminalTab(tab.id);
      expect(channels.single.closed, isTrue);
      expect(app.activeTerminalTab, same(tab));
      expect(tab.state, 'disconnected');
      expect(tab.recovery!.automaticEnabled, isFalse);
      await tab.recovery!.retry();
      expect(channels, hasLength(2));
      expect(tab.state, 'connected');
      expect(app.activeTerminalTab, same(tab));
    } finally { await app.closeWorkspace(); await database.close(); }
  });

  test('Telnet manual restore keeps tab identity and old screen', () async {
    final (app, database, _) = await _controller();
    final channels = <_PendingChannel>[];
    app.telnetConnectorForTesting = (_, _) async {
      final channel = _PendingChannel();
      channels.add(channel);
      return channel;
    };
    try {
      await app.openTerminalTab(_telnetHost(2323));
      final tab = app.activeTerminalTab!;
      channels.single.incoming.add(
        Uint8List.fromList('existing output'.codeUnits),
      );
      await Future<void>.delayed(Duration.zero);
      await channels.single.incoming.close();
      await _until(() => tab.state == 'disconnected');
      await tab.recovery!.retry();
      expect(channels, hasLength(2));
      expect(app.activeTerminalTab, same(tab));
      expect(tab.state, 'connected');
      expect(tab.terminal.buffer.getText(), contains('existing output'));
    } finally {
      await app.closeWorkspace();
      await database.close();
    }
  });


  test('opens a real Telnet tab, routes I/O and never sends credentials',
      () async {
    final server = await _Server.start();
    final (app, database, sshCalls) = await _controller();
    app.telnetConnectorForTesting = connectTelnetDirect;
    try {
      await app.openTerminalTab(_telnetHost(server.socket.port));
      final tab = app.activeTerminalTab!;
      expect(tab.state, 'connected');
      expect(tab.telnet, isNotNull);
      expect(tab.connection, isNull, reason: 'no SSH connection/SFTP/exec');
      expect(tab.console, isNull);
      expect(tab.liveTerminalTransport, same(tab.telnet));
      expect(sshCalls, isEmpty);
      // Plaintext notice is visible in the terminal itself.
      String screen() => [
        for (var i = 0; i < tab.terminal.buffer.lines.length; i++)
          tab.terminal.buffer.lines[i].getText(),
      ].join('\n');
      expect(screen(), contains('unencrypted'));

      await _until(() => server.clients.isNotEmpty);
      await server.send([
        TelnetCommand.iac, TelnetCommand.will, TelnetOption.echo,
        TelnetCommand.iac, TelnetCommand.doOption, TelnetOption.naws,
        ...'Username: '.codeUnits,
      ]);
      await _until(() => screen().contains('Username:'));

      // MCP identifies the session as Telnet without SSH-only capabilities.
      final mcp = appMcpWorkspace(app).sessions().single;
      expect(mcp.kind, 'telnet');
      expect(mcp.toJson()['ssh_exec_available'], isFalse);
      expect(mcp.toJson()['sftp_available'], isFalse);
      expect(mcp.toJson()['terminal_available'], isTrue);
      expect(mcp.state, 'connected');
      mcp.input('operator\r');
      app.resizeTerminalFor(tab.id, 132, 43);
      await _until(
        () =>
            server.contains([...'operator'.codeUnits, 13, 10]) &&
            server.contains([
              TelnetCommand.iac, TelnetCommand.sb, TelnetOption.naws,
              0, 132, 0, 43, TelnetCommand.iac, TelnetCommand.se,
            ]),
      );
      final wire = String.fromCharCodes(server.received);
      expect(wire, isNot(contains(_secret)));
      expect(wire, isNot(contains('admin')));
      expect(sshCalls, isEmpty);

      // Remote close is reflected on the tab.
      await server.clients.single.close();
      await _until(() => tab.state == 'disconnected');
      expect(tab.telnet, isNull);
      await app.closeTerminalTab(tab.id);
      await app.closeTerminalTab(tab.id); // idempotent
    } finally {
      await app.closeWorkspace();
      await database.close();
      await server.close();
    }
  });

  test('output after a scope change and oversized pastes are not published',
      () async {
    final server = await _Server.start();
    final (app, database, _) = await _controller();
    app.telnetConnectorForTesting = connectTelnetDirect;
    try {
      await app.openTerminalTab(_telnetHost(server.socket.port));
      final tab = app.activeTerminalTab!;
      String screen() => [
        for (var i = 0; i < tab.terminal.buffer.lines.length; i++)
          tab.terminal.buffer.lines[i].getText(),
      ].join('\n');
      await _until(() => server.clients.isNotEmpty);
      await _until(() => server.received.isNotEmpty);
      final before = server.received.length;

      // A 2 MiB paste is rejected whole with a localized error.
      app.sendTerminalInputFor(tab.id, 'y' * (2 * 1024 * 1024));
      expect(app.errorMessage, contains('too large'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.received.length, before, reason: 'nothing partial sent');

      await server.send('BEFORE-SCOPE\r\n'.codeUnits);
      await _until(() => screen().contains('BEFORE-SCOPE'));
      app.activeVault = const VaultDescriptor(
        id: 'vault-switched',
        role: 'owner',
        activeKeyEpoch: 'epoch',
        membershipVersion: 'membership',
      );
      await server.send('AFTER-SCOPE\r\n'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(screen(), isNot(contains('AFTER-SCOPE')));
    } finally {
      await app.closeWorkspace();
      await database.close();
      await server.close();
    }
  });

  test('closing the tab closes the TCP connection', () async {
    final server = await _Server.start();
    final (app, database, _) = await _controller();
    app.telnetConnectorForTesting = connectTelnetDirect;
    try {
      await app.openTerminalTab(_telnetHost(server.socket.port));
      final tab = app.activeTerminalTab!;
      await _until(() => server.clients.isNotEmpty);
      await app.closeTerminalTab(tab.id);
      expect(tab.closed, isTrue);
      await _until(() => server.clientClosed);
    } finally {
      await app.closeWorkspace();
      await database.close();
      await server.close();
    }
  });

  test('late connect completion after tab close is closed, not attached',
      () async {
    final (app, database, _) = await _controller();
    final pending = Completer<TelnetByteChannel>();
    app.telnetConnectorForTesting = (_, _) => pending.future;
    try {
      final opening = app.openTerminalTab(_telnetHost(2323));
      await Future<void>.delayed(Duration.zero);
      final tab = app.activeTerminalTab!;
      expect(tab.state, 'connecting');
      await app.closeTerminalTab(tab.id);
      final channel = _PendingChannel();
      pending.complete(channel);
      await opening;
      await _until(() => channel.closed);
      expect(tab.telnet, isNull);
      expect(channel.sent, isEmpty);
    } finally {
      await app.closeWorkspace();
      await database.close();
    }
  });

  test('scope change while connecting fails the tab and closes the channel',
      () async {
    final (app, database, _) = await _controller();
    final pending = Completer<TelnetByteChannel>();
    app.telnetConnectorForTesting = (_, _) => pending.future;
    try {
      final opening = app.openTerminalTab(_telnetHost(2323));
      await Future<void>.delayed(Duration.zero);
      final tab = app.activeTerminalTab!;
      app.activeVault = const VaultDescriptor(
        id: 'vault-other',
        role: 'owner',
        activeKeyEpoch: 'epoch',
        membershipVersion: 'membership',
      );
      final channel = _PendingChannel();
      pending.complete(channel);
      await opening;
      expect(channel.closed, isTrue);
      expect(tab.telnet, isNull);
      expect(tab.state, 'failed');
    } finally {
      await app.closeWorkspace();
      await database.close();
    }
  });

  test('Telnet host with saved sign-in is rejected before connecting',
      () async {
    final (app, database, sshCalls) = await _controller();
    var connects = 0;
    app.telnetConnectorForTesting = (_, _) {
      connects++;
      return Completer<TelnetByteChannel>().future;
    };
    try {
      final invalid = HostRecord(
        id: 'bad',
        name: 'bad',
        address: '127.0.0.1',
        protocol: HostProtocol.telnet,
        login: const HostLogin(kind: AuthKind.password, password: _secret),
      );
      await expectLater(app.openTerminalTab(invalid), throwsStateError);
      expect(connects, 0);
      expect(app.terminalTabs, isEmpty);
      expect(sshCalls, isEmpty);
    } finally {
      await app.closeWorkspace();
      await database.close();
    }
  });

  test('connection failure is sanitized on the tab', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final (app, database, _) = await _controller();
    app.telnetConnectorForTesting = connectTelnetDirect;
    try {
      await expectLater(
        app.openTerminalTab(_telnetHost(port)),
        throwsA(anything),
      );
      final tab = app.terminalTabs.single;
      expect(tab.state, 'failed');
      expect(tab.errorMessage, 'The Telnet server refused the connection.');
    } finally {
      await app.closeWorkspace();
      await database.close();
    }
  });
}
