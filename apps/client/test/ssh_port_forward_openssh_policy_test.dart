import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _enable = 'ATERMIUS_RUN_SSHD_FORWARD_TEST';

/// Real OpenSSH (isolated, loopback-only, temporary keys) acceptance for
/// server policy outcomes: PermitOpen denial, refused targets, PermitListen
/// rejection, authentication failure, half-close, bulk and concurrent data.
void main() {
  final enabled = Platform.isLinux && Platform.environment[_enable] == '1';

  test(
    'OpenSSH policy, failure and data-path behaviour of forwards',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atermius-fwd-policy-',
      );
      Process? sshd;
      ServerSocket? echo;
      SshConnection? connection;
      try {
        final userKey = '${root.path}/user-key';
        final otherKey = '${root.path}/other-key';
        final hostKey = '${root.path}/host-key';
        for (final path in [userKey, otherKey]) {
          await _run('ssh-keygen', [
            '-q',
            '-t',
            'ecdsa',
            '-b',
            '256',
            '-m',
            'PEM',
            '-N',
            '',
            '-f',
            path,
          ]);
        }
        await _run('ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-f',
          hostKey,
        ]);
        final authorized = await _run('ssh-keygen', ['-y', '-f', userKey]);
        await File('${root.path}/authorized_keys')
            .writeAsString('${authorized.stdout}\n');

        // Half-close aware echo: replies, then closes its write side after
        // the client's FIN.
        echo = await ServerSocket.bind('127.0.0.1', 0);
        echo.listen((socket) {
          socket.listen(
            socket.add,
            onDone: () => socket.close(),
            onError: (Object _) => socket.destroy(),
          );
        });
        Future<int> freePort() async {
          final lease = await ServerSocket.bind('127.0.0.1', 0);
          final port = lease.port;
          await lease.close();
          return port;
        }

        final sshPort = await freePort();
        final refusedPort = await freePort(); // permitted, nothing listening
        final deniedPort = await freePort(); // listening, not permitted
        final denied = await ServerSocket.bind('127.0.0.1', deniedPort);
        denied.listen((socket) => socket.destroy());
        final allowedListen = await freePort();
        final forbiddenListen = await freePort();
        final config = '${root.path}/sshd_config';
        await File(config).writeAsString('''
AddressFamily inet
ListenAddress 127.0.0.1
Port $sshPort
HostKey $hostKey
PidFile ${root.path}/sshd.pid
AuthorizedKeysFile ${root.path}/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin yes
AllowUsers root
StrictModes no
UsePAM no
UseDNS no
AllowTcpForwarding yes
PermitOpen 127.0.0.1:${echo.port} 127.0.0.1:$refusedPort
PermitListen 127.0.0.1:$allowedListen
GatewayPorts no
PermitTTY yes
X11Forwarding no
PrintMotd no
LogLevel ERROR
''');
        final sshdPath = _findExecutable('sshd');
        await _run(sshdPath, ['-t', '-f', config]);
        sshd = await Process.start(sshdPath, ['-D', '-e', '-f', config]);
        unawaited(sshd.stdout.drain<void>());
        final sshdOutput = StringBuffer();
        unawaited(
          sshd.stderr.transform(utf8.decoder).forEach(sshdOutput.write),
        );

        // Authentication failure: an unauthorized key never yields a client
        // that forwards could be attached to.
        final rejectedSocket = await _connectWhenReady(
          sshPort,
          sshd,
          sshdOutput,
        );
        final rejected = SSHClient(
          rejectedSocket,
          username: 'root',
          identities: SSHKeyPair.fromPem(await File(otherKey).readAsString()),
          onVerifyHostKey: (_, _) => true,
        );
        await expectLater(
          rejected.authenticated.timeout(const Duration(seconds: 10)),
          throwsA(isA<SSHAuthError>()),
        );
        rejected.close();

        final client = SSHClient(
          await _connectWhenReady(sshPort, sshd, sshdOutput),
          username: 'root',
          identities: SSHKeyPair.fromPem(await File(userKey).readAsString()),
          onVerifyHostKey: (_, _) => true,
        );
        await client.authenticated.timeout(const Duration(seconds: 10));
        connection = SshConnection(
          client: client,
          session: await client.shell(),
        );
        final manager = connection.portForwards;

        SshPortForwardProfile local(String id, int port) =>
            SshPortForwardProfile(
              id: id,
              name: id,
              type: SshPortForwardType.local,
              bindAddress: '127.0.0.1',
              bindPort: 0,
              destinationAddress: '127.0.0.1',
              destinationPort: port,
            );

        // 1. Half-close through sshd: the reply arrives after our FIN.
        final echoForward = await manager.start(local('echo', echo.port));
        expect(
          await _halfCloseRoundTrip(
            echoForward.listeningPort,
            utf8.encode('half-close'),
          ),
          utf8.encode('half-close'),
        );

        // 2. Bulk transfer (window/backpressure) keeps byte integrity.
        final bulk = Uint8List(8 * 1024 * 1024);
        for (var i = 0; i < bulk.length; i++) {
          bulk[i] = (i * 31 + 7) & 0xff;
        }
        final bulkEcho = await _halfCloseRoundTrip(
          echoForward.listeningPort,
          bulk,
        );
        expect(bulkEcho.length, bulk.length);
        expect(bulkEcho, bulk);

        // 3. Concurrent clients.
        final results = await Future.wait([
          for (var i = 0; i < 16; i++)
            _halfCloseRoundTrip(
              echoForward.listeningPort,
              utf8.encode('client-$i-${'z' * (i * 4096)}'),
            ),
        ]);
        for (var i = 0; i < 16; i++) {
          expect(utf8.decode(results[i]), 'client-$i-${'z' * (i * 4096)}');
        }
        await _eventually(() => echoForward.activeConnections == 0);

        // 4. PermitOpen denial is reported, the client socket is closed.
        final deniedForward = await manager.start(local('denied', deniedPort));
        expect(
          await _halfCloseRoundTrip(deniedForward.listeningPort, [1]),
          isEmpty,
        );
        await _eventually(
          () => manager.statusOf('denied').lastConnectionError != null,
        );
        expect(
          manager.statusOf('denied').lastConnectionError,
          contains('denied forwarding to 127.0.0.1:$deniedPort'),
        );

        // 5. SOCKS replies reflect sshd outcomes.
        final socks = await manager.start(
          const SshPortForwardProfile(
            id: 'socks',
            name: 'socks',
            type: SshPortForwardType.dynamic,
            bindAddress: '127.0.0.1',
            bindPort: 0,
          ),
        );
        expect(await _socksReply(socks.listeningPort, echo.port), 0x00);
        expect(await _socksReply(socks.listeningPort, deniedPort), 0x02);
        expect(await _socksReply(socks.listeningPort, refusedPort), 0x05);

        // 6. PermitListen: forbidden remote listener is a start failure.
        await expectLater(
          manager.start(
            SshPortForwardProfile(
              id: 'remote-forbidden',
              name: 'remote-forbidden',
              type: SshPortForwardType.remote,
              bindAddress: '127.0.0.1',
              bindPort: forbiddenListen,
              destinationAddress: '127.0.0.1',
              destinationPort: echo.port,
            ),
          ),
          throwsA(isA<SshPortForwardException>()),
        );
        expect(
          manager.statusOf('remote-forbidden').error,
          contains('rejected a listener on 127.0.0.1:$forbiddenListen'),
        );
        expect(await _canConnect(forbiddenListen), isFalse);

        // 7. Allowed remote listener relays with half-close.
        final remote = await manager.start(
          SshPortForwardProfile(
            id: 'remote-ok',
            name: 'remote-ok',
            type: SshPortForwardType.remote,
            bindAddress: '127.0.0.1',
            bindPort: allowedListen,
            destinationAddress: '127.0.0.1',
            destinationPort: echo.port,
          ),
        );
        expect(remote.listeningPort, allowedListen);
        expect(
          await _halfCloseRoundTrip(allowedListen, utf8.encode('via-remote')),
          utf8.encode('via-remote'),
        );

        // 8. Repeated start/stop on the same port leaves nothing behind.
        for (var i = 0; i < 10; i++) {
          await manager.stop('remote-ok');
          expect(await _canConnect(allowedListen), isFalse);
          await manager.start(
            SshPortForwardProfile(
              id: 'remote-ok',
              name: 'remote-ok',
              type: SshPortForwardType.remote,
              bindAddress: '127.0.0.1',
              bindPort: allowedListen,
              destinationAddress: '127.0.0.1',
              destinationPort: echo.port,
            ),
          );
        }
        expect(manager.runningCount, 4);

        final ports = [
          echoForward.listeningPort,
          deniedForward.listeningPort,
          socks.listeningPort,
          allowedListen,
        ];
        await connection.close();
        connection = null;
        expect(manager.runningCount, 0);
        for (final port in ports) {
          expect(await _canConnect(port), isFalse, reason: 'port $port');
        }
        await denied.close();
      } finally {
        await connection?.close();
        await echo?.close();
        if (sshd != null) {
          sshd.kill(ProcessSignal.sigterm);
          try {
            await sshd.exitCode.timeout(const Duration(seconds: 3));
          } catch (_) {
            sshd.kill(ProcessSignal.sigkill);
          }
        }
        await root.delete(recursive: true);
      }
    },
    skip: enabled ? null : 'Set $_enable=1 on Linux with OpenSSH installed.',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<List<int>> _halfCloseRoundTrip(int port, List<int> payload) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final received = BytesBuilder(copy: false);
  final done = Completer<void>();
  socket.listen(
    received.add,
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
  );
  socket.add(payload);
  await socket.flush();
  await socket.close();
  await done.future.timeout(const Duration(seconds: 30));
  socket.destroy();
  return received.takeBytes();
}

Future<int> _socksReply(int proxyPort, int targetPort) async {
  final socket = await Socket.connect('127.0.0.1', proxyPort);
  final bytes = <int>[];
  final enough = Completer<void>();
  socket.listen(
    (data) {
      bytes.addAll(data);
      if (bytes.length >= 12 && !enough.isCompleted) enough.complete();
    },
    onDone: () {
      if (!enough.isCompleted) enough.complete();
    },
  );
  socket.add([
    0x05, 0x01, 0x00, //
    0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, targetPort >> 8, targetPort & 0xff,
  ]);
  await enough.future.timeout(const Duration(seconds: 10));
  socket.destroy();
  expect(bytes.sublist(0, 2), [0x05, 0x00]);
  return bytes[3];
}

Future<bool> _canConnect(int port) async {
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 250),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('$executable failed with exit ${result.exitCode}');
  }
  return result;
}

String _findExecutable(String name) {
  final path = Platform.environment['PATH'];
  if (path == null) throw StateError('PATH is unavailable');
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    final candidate = File('$directory/$name');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  throw StateError('Required executable is not installed: $name');
}

Future<SSHSocket> _connectWhenReady(
  int port,
  Process process,
  StringBuffer processOutput,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final socketResult = SSHSocket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 250),
    );
    final result = await Future.any<Object?>([
      socketResult.then<Object?>((socket) => socket, onError: (_) => null),
      process.exitCode.then<Object?>((code) => code),
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    if (result is SSHSocket) return result;
    if (result is int) {
      throw StateError(
        'Temporary sshd exited with code $result: ${processOutput.toString().trim()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Temporary sshd did not listen on loopback');
}
