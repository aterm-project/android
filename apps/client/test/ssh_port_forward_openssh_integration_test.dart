import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _enableSshdForwardAcceptance = 'ATERMIUS_RUN_SSHD_FORWARD_TEST';

void main() {
  final enabled =
      Platform.isLinux &&
      Platform.environment[_enableSshdForwardAcceptance] == '1';

  test(
    'real OpenSSH accepts local, remote and dynamic forwards and cleans up',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atermius-ssh-forward-',
      );
      Process? sshd;
      ServerSocket? echoServer;
      SshConnection? connection;
      final echoSockets = <Socket>{};

      try {
        final userKeyPath = '${root.path}/user-key';
        final hostKeyPath = '${root.path}/host-key';
        final authorizedKeysPath = '${root.path}/authorized_keys';
        final configPath = '${root.path}/sshd_config';
        final sshdPath = _findExecutable('sshd');
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
          userKeyPath,
        ]);
        await _run('ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-f',
          hostKeyPath,
        ]);
        final authorizedKey = await _run('ssh-keygen', [
          '-y',
          '-f',
          userKeyPath,
        ]);
        await File(
          authorizedKeysPath,
        ).writeAsString('${authorizedKey.stdout}\n');
        final fingerprintResult = await _run('ssh-keygen', [
          '-lf',
          '$hostKeyPath.pub',
          '-E',
          'sha256',
        ]);
        final expectedHostFingerprint = fingerprintResult.stdout.trim().split(
          RegExp(r'\s+'),
        )[1];

        final portLease = await ServerSocket.bind('127.0.0.1', 0);
        final sshPort = portLease.port;
        await portLease.close();
        await File(configPath).writeAsString('''
AddressFamily inet
ListenAddress 127.0.0.1
Port $sshPort
HostKey $hostKeyPath
PidFile ${root.path}/sshd.pid
AuthorizedKeysFile $authorizedKeysPath
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin yes
AllowUsers root
StrictModes no
UsePAM no
UseDNS no
AllowTcpForwarding yes
GatewayPorts no
PermitTTY yes
AllowAgentForwarding no
X11Forwarding no
PrintMotd no
LogLevel ERROR
''');
        await _run(sshdPath, ['-t', '-f', configPath]);

        echoServer = await ServerSocket.bind('127.0.0.1', 0);
        echoServer.listen((socket) {
          echoSockets.add(socket);
          socket.listen(
            socket.add,
            onDone: () {
              echoSockets.remove(socket);
              socket.destroy();
            },
            onError: (Object _) {
              echoSockets.remove(socket);
              socket.destroy();
            },
            cancelOnError: true,
          );
        });

        sshd = await Process.start(sshdPath, ['-D', '-e', '-f', configPath]);
        // Drain daemon output so the process cannot block on a full pipe.
        unawaited(sshd.stdout.drain<void>());
        final sshdOutput = StringBuffer();
        unawaited(
          sshd.stderr.transform(utf8.decoder).forEach(sshdOutput.write),
        );
        final sshSocket = await _connectWhenReady(sshPort, sshd, sshdOutput);
        final userKey = await File(userKeyPath).readAsString();
        var hostKeyVerified = false;
        final client = SSHClient(
          sshSocket,
          username: 'root',
          identities: SSHKeyPair.fromPem(userKey),
          keepAliveInterval: const Duration(seconds: 5),
          onVerifyHostKey: (type, fingerprint) {
            hostKeyVerified =
                type == 'ssh-ed25519' &&
                utf8.decode(fingerprint) == expectedHostFingerprint;
            return hostKeyVerified;
          },
        );
        await client.authenticated.timeout(const Duration(seconds: 10));
        expect(hostKeyVerified, isTrue);
        final session = await client.shell();
        connection = SshConnection(client: client, session: session);
        final manager = connection.portForwards;
        final echoPort = echoServer.port;

        final local = await manager.start(
          SshPortForwardProfile(
            id: 'local-live',
            name: 'Local loopback test',
            type: SshPortForwardType.local,
            bindAddress: '127.0.0.1',
            bindPort: 0,
            destinationAddress: '127.0.0.1',
            destinationPort: echoPort,
          ),
        );
        expect(local.listeningPort, greaterThan(0));
        await _assertEcho(local.listeningPort, 'local-through-sshd');
        expect(await manager.stop(local.profileId), isTrue);
        expect(await _canConnect(local.listeningPort), isFalse);

        final remote = await manager.start(
          SshPortForwardProfile(
            id: 'remote-live',
            name: 'Remote loopback test',
            type: SshPortForwardType.remote,
            bindAddress: '127.0.0.1',
            bindPort: 0,
            destinationAddress: '127.0.0.1',
            destinationPort: echoPort,
          ),
        );
        expect(remote.listeningPort, greaterThan(0));
        await _assertEcho(remote.listeningPort, 'remote-through-sshd');
        expect(await manager.stop(remote.profileId), isTrue);
        expect(await _canConnect(remote.listeningPort), isFalse);

        final dynamic = await manager.start(
          const SshPortForwardProfile(
            id: 'dynamic-live',
            name: 'Dynamic loopback test',
            type: SshPortForwardType.dynamic,
            bindAddress: '127.0.0.1',
            bindPort: 0,
          ),
        );
        expect(dynamic.listeningPort, greaterThan(0));
        await _assertSocksEcho(dynamic.listeningPort, echoPort);
        expect(await manager.stop(dynamic.profileId), isTrue);
        expect(await _canConnect(dynamic.listeningPort), isFalse);

        final disconnectLocal = await manager.start(
          SshPortForwardProfile(
            id: 'local-disconnect',
            name: 'Local disconnect cleanup',
            type: SshPortForwardType.local,
            bindAddress: '127.0.0.1',
            bindPort: 0,
            destinationAddress: '127.0.0.1',
            destinationPort: echoPort,
          ),
        );
        final disconnectRemote = await manager.start(
          SshPortForwardProfile(
            id: 'remote-disconnect',
            name: 'Remote disconnect cleanup',
            type: SshPortForwardType.remote,
            bindAddress: '127.0.0.1',
            bindPort: 0,
            destinationAddress: '127.0.0.1',
            destinationPort: echoPort,
          ),
        );
        final disconnectDynamic = await manager.start(
          const SshPortForwardProfile(
            id: 'dynamic-disconnect',
            name: 'Dynamic disconnect cleanup',
            type: SshPortForwardType.dynamic,
            bindAddress: '127.0.0.1',
            bindPort: 0,
          ),
        );
        final localPort = disconnectLocal.listeningPort;
        final remotePort = disconnectRemote.listeningPort;
        final dynamicPort = disconnectDynamic.listeningPort;
        await connection.close();
        expect(manager.activeProfileIds, isEmpty);
        expect(await _canConnect(localPort), isFalse);
        expect(await _canConnect(dynamicPort), isFalse);
        expect(await _canConnect(remotePort), isFalse);
        connection = null;
      } finally {
        if (connection != null) await connection.close();
        await echoServer?.close();
        for (final socket in echoSockets.toList()) {
          socket.destroy();
        }
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
    skip: enabled
        ? null
        : 'Set $_enableSshdForwardAcceptance=1 on Linux with OpenSSH installed.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
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

Future<void> _assertEcho(int port, String message) async {
  final socket = await Socket.connect(
    '127.0.0.1',
    port,
    timeout: const Duration(seconds: 2),
  );
  final reader = _SocketReader(socket);
  try {
    final expected = utf8.encode(message);
    final responseFuture = reader.readExactly(expected.length);
    socket.add(expected);
    await socket.flush();
    expect(await responseFuture.timeout(const Duration(seconds: 3)), expected);
  } finally {
    await reader.close();
    socket.destroy();
  }
}

Future<void> _assertSocksEcho(int proxyPort, int echoPort) async {
  final socket = await Socket.connect(
    '127.0.0.1',
    proxyPort,
    timeout: const Duration(seconds: 2),
  );
  final reader = _SocketReader(socket);
  try {
    var responseFuture = reader.readExactly(2);
    socket.add([0x05, 0x01, 0x00]);
    await socket.flush();
    expect(await responseFuture.timeout(const Duration(seconds: 3)), [
      0x05,
      0x00,
    ]);

    responseFuture = reader.readExactly(4);
    socket.add([
      0x05,
      0x01,
      0x00,
      0x01,
      127,
      0,
      0,
      1,
      echoPort >> 8,
      echoPort & 0xff,
    ]);
    await socket.flush();
    final connectReply = await responseFuture.timeout(
      const Duration(seconds: 3),
    );
    expect(connectReply.sublist(0, 3), [0x05, 0x00, 0x00]);
    final boundAddressLength = switch (connectReply[3]) {
      0x01 => 4,
      0x04 => 16,
      0x03 => (await reader.readExactly(1)).single,
      _ => throw StateError('Unsupported SOCKS5 bound address type'),
    };
    await reader.readExactly(boundAddressLength + 2);

    final expected = utf8.encode('dynamic-socks-through-sshd');
    responseFuture = reader.readExactly(expected.length);
    socket.add(expected);
    await socket.flush();
    expect(await responseFuture.timeout(const Duration(seconds: 3)), expected);
  } finally {
    await reader.close();
    socket.destroy();
  }
}

Future<bool> _canConnect(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 250),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

class _SocketReader {
  _SocketReader(Socket socket) {
    _subscription = socket.listen(
      (bytes) {
        _buffer.addAll(bytes);
        _wake?.complete();
        _wake = null;
      },
      onError: (Object error) {
        _error = error;
        _wake?.complete();
        _wake = null;
      },
      onDone: () {
        _done = true;
        _wake?.complete();
        _wake = null;
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  Completer<void>? _wake;
  Object? _error;
  bool _done = false;

  Future<List<int>> readExactly(int length) async {
    while (_buffer.length < length) {
      if (_error != null) throw StateError('Socket read failed: $_error');
      if (_done) throw StateError('Socket closed before enough bytes arrived');
      _wake = Completer<void>();
      await _wake!.future;
    }
    final bytes = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return bytes;
  }

  Future<void> close() => _subscription.cancel();
}
