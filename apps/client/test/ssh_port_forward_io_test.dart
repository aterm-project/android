import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/port_forward_runtime_io.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_port_forward_fakes.dart';

const _local = SshPortForwardProfile(
  id: 'local-io',
  name: 'Local IO',
  type: SshPortForwardType.local,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  destinationAddress: 'db.internal',
  destinationPort: 5432,
);

const _dynamic = SshPortForwardProfile(
  id: 'dynamic-io',
  name: 'SOCKS IO',
  type: SshPortForwardType.dynamic,
  bindAddress: '127.0.0.1',
  bindPort: 0,
);

const _remote = SshPortForwardProfile(
  id: 'remote-io',
  name: 'Remote IO',
  type: SshPortForwardType.remote,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  destinationAddress: '127.0.0.1',
  destinationPort: 1, // replaced per test
);

/// Reads a socket into a buffer and exposes completion of the read side.
class _Reader {
  _Reader(Socket socket) {
    subscription = socket.listen(
      (data) {
        bytes.add(data);
        _changed();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
        _changed();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
  }

  final BytesBuilder bytes = BytesBuilder(copy: false);
  final Completer<void> done = Completer<void>();
  late final StreamSubscription<Uint8List> subscription;
  final List<Completer<void>> _waiters = [];

  void _changed() {
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> take(int count) async {
    while (bytes.length < count) {
      if (done.isCompleted) break;
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 5));
    }
    final all = bytes.takeBytes();
    if (all.length > count) bytes.add(Uint8List.sublistView(all, count));
    return Uint8List.sublistView(
      all,
      0,
      count < all.length ? count : all.length,
    );
  }
}

Future<void> _eventually(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met in time${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  group('local forward tunnel', () {
    test('client half-close still delivers the server response', () async {
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);

      final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
      final channel = await client.nextChannel();
      expect(client.dials, [('db.internal', 5432)]);
      final reader = _Reader(socket);

      socket.add(utf8.encode('REQUEST'));
      await socket.close(); // TCP FIN: write side only
      // Server receives the request followed by SSH EOF.
      expect(utf8.decode(await _collect(channel.received)), 'REQUEST');
      expect(channel.isDestroyed, isFalse);

      channel.serverSend(utf8.encode('RESPONSE'));
      channel.serverClose();
      await reader.done.future.timeout(const Duration(seconds: 2));
      expect(utf8.decode(reader.bytes.takeBytes()), 'RESPONSE');
      await _eventually(() => handle.activeConnections == 0);
      expect(handle.totalConnections, 1);
      socket.destroy();
    });

    test('server EOF half-closes the client while upload continues', () async {
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);

      final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
      final channel = await client.nextChannel();
      final reader = _Reader(socket);
      final upload = _collect(channel.received);

      channel.serverSend(utf8.encode('BANNER'));
      channel.serverEof();
      await reader.done.future.timeout(const Duration(seconds: 2));
      expect(utf8.decode(reader.bytes.takeBytes()), 'BANNER');

      // The device side may still send after the server's EOF.
      socket.add(utf8.encode('LATE-UPLOAD'));
      await socket.close();
      expect(
        utf8.decode(await upload.timeout(const Duration(seconds: 2))),
        'LATE-UPLOAD',
      );
      channel.serverClose();
      await _eventually(() => handle.activeConnections == 0);
      socket.destroy();
    });

    test('upload backpressure pauses the device socket', () async {
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);
      final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
      final channel = await client.nextChannel();

      var received = 0;
      final drained = Completer<void>();
      // The server side does not read yet: no SSH window.
      final serverRead = channel.received.listen((chunk) {
        received += chunk.length;
      }, onDone: drained.complete);
      serverRead.pause();

      const total = 48 * 1024 * 1024;
      final payload = Uint8List(1024 * 1024);
      var flushed = false;
      unawaited(() async {
        for (var i = 0; i < total ~/ payload.length; i++) {
          socket.add(payload);
          await socket.flush();
        }
        flushed = true;
        await socket.close();
      }());
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // Without backpressure the tunnel would buffer all 48 MiB in memory and
      // the writer would finish immediately.
      expect(flushed, isFalse);
      expect(received, 0);

      serverRead.resume();
      await drained.future.timeout(const Duration(seconds: 20));
      expect(received, total);
      expect(flushed, isTrue);
      channel.serverClose();
      await _eventually(() => handle.activeConnections == 0);
      socket.destroy();
    });

    test(
      'download backpressure withholds SSH window from the server',
      () async {
        final client = FakeForwardingSshClient();
        final manager = SshPortForwardManager(client);
        addTearDown(manager.closeAll);
        final handle = await manager.start(_local);
        final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
        final channel = await client.nextChannel();
        var clientReceived = 0;
        final clientRead = socket.listen(
          (data) => clientReceived += data.length,
        );
        clientRead.pause(); // device application is slow / not reading

        await _eventually(() => channel.serverOutHasListener);
        var sent = 0;
        final chunk = List<int>.filled(256 * 1024, 7);
        // Produce only while the tunnel is willing to accept (window open).
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline) && sent < 256 * 1024 * 1024) {
          if (channel.serverOutPaused) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          channel.serverSend(chunk);
          sent += chunk.length;
          await Future<void>.delayed(Duration.zero);
        }
        expect(channel.serverOutPaused, isTrue);
        // Kernel socket buffers hold a few MiB at most.
        expect(sent, lessThan(64 * 1024 * 1024));

        clientRead.resume();
        await _eventually(() => clientReceived >= sent);
        expect(clientReceived, sent);
        channel.serverClose();
        await _eventually(() => handle.activeConnections == 0);
        socket.destroy();
      },
    );

    test('denied channel closes the client and records the reason', () async {
      final client = FakeForwardingSshClient(
        onDial: (host, port) async =>
            throw SSHChannelOpenError(1, 'administratively prohibited'),
      );
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);
      var notifications = 0;
      manager.addListener(() => notifications++);

      final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
      final reader = _Reader(socket);
      await reader.done.future.timeout(const Duration(seconds: 2));
      expect(reader.bytes.length, 0);
      await _eventually(() => handle.activeConnections == 0);
      expect(handle.totalConnections, 1);
      final status = manager.statusOf(_local.id);
      expect(status.state, SshPortForwardState.running);
      expect(status.lastConnectionError, contains('denied'));
      expect(status.lastConnectionError, contains('db.internal:5432'));
      expect(notifications, greaterThan(0));
      socket.destroy();
    });

    test('concurrent clients are bridged independently', () async {
      final client = FakeForwardingSshClient();
      client.opened.listen(echoOnFakeChannel);
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);

      Future<String> roundTrip(int index) async {
        final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
        final reader = _Reader(socket);
        socket.add(utf8.encode('client-$index-${'x' * (index * 997)}'));
        await socket.close();
        await reader.done.future.timeout(const Duration(seconds: 5));
        socket.destroy();
        return utf8.decode(reader.bytes.takeBytes());
      }

      final results = await Future.wait([
        for (var i = 0; i < 24; i++) roundTrip(i),
      ]);
      for (var i = 0; i < 24; i++) {
        expect(results[i], 'client-$i-${'x' * (i * 997)}');
      }
      await _eventually(() => handle.activeConnections == 0);
      expect(handle.totalConnections, 24);
    });

    test('stop closes the listener and every active tunnel', () async {
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_local);
      final port = handle.listeningPort;
      final socket = await Socket.connect('127.0.0.1', port);
      final channel = await client.nextChannel();
      final reader = _Reader(socket);
      await _eventually(() => handle.activeConnections == 1);

      expect(await manager.stop(_local.id), isTrue);
      expect(channel.isDestroyed, isTrue);
      await reader.done.future.timeout(const Duration(seconds: 2));
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
      expect(manager.statusOf(_local.id).state, SshPortForwardState.stopped);
      socket.destroy();
    });

    test('listener port in use reports a sanitized start error', () async {
      final blocker = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(blocker.close);
      final manager = SshPortForwardManager(FakeForwardingSshClient());
      addTearDown(manager.closeAll);
      final profile = _local.copyWith(bindPort: blocker.port);
      await expectLater(
        manager.start(profile),
        throwsA(isA<SshPortForwardException>()),
      );
      final status = manager.statusOf(profile.id);
      expect(status.state, SshPortForwardState.failed);
      expect(status.error, contains('already in use'));
      expect(manager.activeProfileIds, isEmpty);
    });
  });

  group('remote forward', () {
    test('incoming channels reach the device target with half-close', () async {
      final echo = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(echo.close);
      echo.listen((socket) {
        socket.listen(socket.add, onDone: () => socket.close());
      });
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final profile = _remote.copyWith(destinationPort: echo.port);
      final handle = await manager.start(profile);
      expect(client.remoteBindHost, '127.0.0.1');
      expect(client.remoteBindPort, 0);
      expect(handle.listeningPort, 62001);

      final channel = FakeSshForwardChannel();
      final received = _collect(channel.received);
      client.remoteForward!.incoming.add(channel);
      await _eventually(() => channel.serverOutHasListener);
      channel.serverSend(utf8.encode('from-server'));
      channel.serverEof(); // server-side client half-closed
      expect(
        utf8.decode(await received.timeout(const Duration(seconds: 3))),
        'from-server',
      );
      channel.serverClose();
      await _eventually(() => handle.activeConnections == 0);
      expect(handle.totalConnections, 1);

      await manager.stop(profile.id);
      expect(client.remoteCancelCount, 1);
      expect(client.remoteForward!.closed, isTrue);
    });

    test('unreachable device target destroys the channel', () async {
      final lease = await ServerSocket.bind('127.0.0.1', 0);
      final closedPort = lease.port;
      await lease.close();
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final profile = _remote.copyWith(destinationPort: closedPort);
      final handle = await manager.start(profile);
      final channel = FakeSshForwardChannel();
      client.remoteForward!.incoming.add(channel);
      await _eventually(() => channel.isDestroyed);
      await _eventually(() => handle.activeConnections == 0);
      expect(
        manager.statusOf(profile.id).lastConnectionError,
        contains('could not connect to 127.0.0.1:$closedPort'),
      );
    });

    test(
      'server rejection of the remote listener is a start failure',
      () async {
        final client = FakeForwardingSshClient()..rejectRemoteForward = true;
        final manager = SshPortForwardManager(client);
        addTearDown(manager.closeAll);
        final profile = _remote.copyWith(bindPort: 8080, destinationPort: 80);
        await expectLater(
          manager.start(profile),
          throwsA(isA<SshPortForwardException>()),
        );
        final status = manager.statusOf(profile.id);
        expect(status.state, SshPortForwardState.failed);
        expect(status.error, contains('rejected a listener on 127.0.0.1:8080'));
      },
    );
  });

  group('remote start timeout', () {
    const timeoutPlatform = IoSshPortForwardPlatform(
      remoteRequestTimeout: Duration(milliseconds: 50),
      lateRemoteReplyGrace: Duration(milliseconds: 300),
    );
    final profile = _remote.copyWith(bindPort: 9443, destinationPort: 443);

    Future<FakeForwardingSshClient> timedOutStart() async {
      final client = FakeForwardingSshClient()
        ..remoteReplyGate = Completer<void>();
      final manager = SshPortForwardManager(client, platform: timeoutPlatform);
      addTearDown(manager.closeAll);
      await expectLater(
        manager.start(profile),
        throwsA(isA<SshPortForwardException>()),
      );
      final status = manager.statusOf(profile.id);
      expect(status.state, SshPortForwardState.failed);
      expect(status.error, contains('did not answer'));
      expect(manager.activeProfileIds, isEmpty);
      return client;
    }

    test('a late successful listener is cancelled, not leaked', () async {
      final client = await timedOutStart();
      client.remoteReplyGate!.complete(); // server opens the listener late
      await _eventually(() => client.remoteCancelCount == 1);
      await _eventually(() => client.remoteForward?.closed == true);
      expect(client.closeCount, 0, reason: 'cancellation was confirmed');
    });

    test('unconfirmed cancellation of a late listener closes SSH', () async {
      final client = await timedOutStart();
      client.rejectRemoteCancel = true;
      client.remoteReplyGate!.complete();
      await _eventually(() => client.closeCount == 1);
      expect(client.remoteCancelCount, 1);
    });

    test('a server that never answers gets its transport closed', () async {
      final client = await timedOutStart();
      await _eventually(() => client.closeCount == 1);
      expect(client.remoteCancelCount, 0);
    });

    test('a late rejection needs no cleanup', () async {
      final client = await timedOutStart();
      client.rejectRemoteForward = true;
      client.remoteReplyGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(client.remoteCancelCount, 0);
      expect(client.closeCount, 0);
    });
  });

  group('dynamic SOCKS forward', () {
    Future<(SshPortForwardManager, FakeForwardingSshClient, int)> startSocks({
      FakeDialHandler? onDial,
      bool echo = true,
    }) async {
      final client = FakeForwardingSshClient(onDial: onDial);
      if (echo) client.opened.listen(echoOnFakeChannel);
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);
      final handle = await manager.start(_dynamic);
      return (manager, client, handle.listeningPort);
    }

    test('SOCKS5 domain CONNECT returns success and streams data', () async {
      final (_, client, port) = await startSocks();
      final socket = await Socket.connect('127.0.0.1', port);
      final reader = _Reader(socket);
      socket.add([0x05, 0x01, 0x00]);
      expect(await reader.take(2), [0x05, 0x00]);
      final host = utf8.encode('internal.example');
      // Request and first payload bytes in the same write (pipelining).
      socket.add([
        0x05, 0x01, 0x00, 0x03, host.length, ...host, 0x1f, 0x90, //
        ...utf8.encode('PING'),
      ]);
      expect(await reader.take(10), [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      expect(utf8.decode(await reader.take(4)), 'PING');
      expect(client.dials, [('internal.example', 8080)]);
      socket.add(utf8.encode('PONG'));
      expect(utf8.decode(await reader.take(4)), 'PONG');
      await socket.close();
      await reader.done.future.timeout(const Duration(seconds: 2));
      socket.destroy();
    });

    test('SOCKS5 IPv4 and IPv6 targets are passed to the SSH server', () async {
      final (_, client, port) = await startSocks();
      for (final request in [
        [0x05, 0x01, 0x00, 0x01, 10, 0, 0, 7, 0x00, 0x16],
        [
          0x05, 0x01, 0x00, 0x04, //
          0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0xbb,
        ],
      ]) {
        final socket = await Socket.connect('127.0.0.1', port);
        final reader = _Reader(socket);
        socket.add([0x05, 0x01, 0x00, ...request]);
        expect(await reader.take(2), [0x05, 0x00]);
        expect((await reader.take(10))[1], 0x00);
        socket.destroy();
      }
      expect(client.dials, [('10.0.0.7', 22), ('fd00::1', 443)]);
    });

    test('server-side failures map to SOCKS5 reply codes', () async {
      final cases = <Object, int>{
        SSHChannelOpenError(1, 'administratively prohibited'): 0x02,
        SSHChannelOpenError(2, 'connect failed'): 0x05,
        SSHChannelOpenError(4, 'resource shortage'): 0x01,
        StateError('transport closed'): 0x01,
      };
      for (final entry in cases.entries) {
        final (manager, _, port) = await startSocks(
          onDial: (host, port) async => throw entry.key,
          echo: false,
        );
        final socket = await Socket.connect('127.0.0.1', port);
        final reader = _Reader(socket);
        socket.add([0x05, 0x01, 0x00]);
        socket.add([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]);
        await reader.done.future.timeout(const Duration(seconds: 2));
        final bytes = reader.bytes.takeBytes();
        expect(bytes.sublist(0, 2), [0x05, 0x00]);
        expect(bytes.sublist(2), [0x05, entry.value, 0, 1, 0, 0, 0, 0, 0, 0]);
        socket.destroy();
        await _eventually(
          () => manager.statusOf(_dynamic.id).activeConnections == 0,
        );
        await manager.closeAll();
      }
    });

    test('unsupported commands, address types and auth are rejected', () async {
      final (manager, client, port) = await startSocks();

      Future<List<int>> exchange(List<List<int>> writes) async {
        final socket = await Socket.connect('127.0.0.1', port);
        final reader = _Reader(socket);
        for (final write in writes) {
          socket.add(write);
          await socket.flush();
        }
        await reader.done.future.timeout(const Duration(seconds: 2));
        socket.destroy();
        return reader.bytes.takeBytes();
      }

      // Only username/password offered → NO ACCEPTABLE METHODS.
      expect(
        await exchange([
          [0x05, 0x01, 0x02],
        ]),
        [0x05, 0xff],
      );
      // BIND → command not supported.
      expect(
        await exchange([
          [0x05, 0x01, 0x00],
          [0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80],
        ]),
        [0x05, 0x00, 0x05, 0x07, 0, 1, 0, 0, 0, 0, 0, 0],
      );
      // UDP ASSOCIATE → command not supported.
      expect(
        (await exchange([
          [0x05, 0x01, 0x00],
          [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0],
        ]))[3],
        0x07,
      );
      // Unknown address type → address type not supported.
      expect(
        (await exchange([
          [0x05, 0x01, 0x00],
          [0x05, 0x01, 0x00, 0x09, 1, 2, 3],
        ]))[3],
        0x08,
      );
      // Empty domain name → general failure.
      expect(
        (await exchange([
          [0x05, 0x01, 0x00],
          [0x05, 0x01, 0x00, 0x03, 0x00, 0x00, 0x50],
        ]))[3],
        0x01,
      );
      // Unknown protocol version → closed without a reply.
      expect(
        await exchange([
          [0x47, 0x45, 0x54, 0x20],
        ]),
        isEmpty,
      );
      expect(client.dials, isEmpty);
      await _eventually(
        () => manager.statusOf(_dynamic.id).activeConnections == 0,
      );
      expect(
        manager.statusOf(_dynamic.id).lastConnectionError,
        contains('malformed'),
      );
    });

    test('SOCKS4 and SOCKS4a CONNECT', () async {
      var deny = false;
      final dials = <(String, int)>[];
      final (_, _, port) = await startSocks(
        echo: false,
        onDial: (host, port) async {
          dials.add((host, port));
          if (deny) throw SSHChannelOpenError(1, 'prohibited');
          final channel = FakeSshForwardChannel();
          echoOnFakeChannel(channel);
          return channel;
        },
      );
      Future<List<int>> connect(List<int> request) async {
        final socket = await Socket.connect('127.0.0.1', port);
        final reader = _Reader(socket);
        socket.add(request);
        final reply = await reader.take(8);
        socket.destroy();
        return reply;
      }

      expect(
        await connect([
          0x04,
          0x01,
          0x00,
          0x50,
          192,
          168,
          7,
          9,
          ...ascii.encode('me'),
          0,
        ]),
        [0x00, 0x5a, 0, 0, 0, 0, 0, 0],
      );
      expect(
        await connect([
          0x04, 0x01, 0x01, 0xbb, 0, 0, 0, 1, 0, //
          ...ascii.encode('svc.internal'), 0,
        ]),
        [0x00, 0x5a, 0, 0, 0, 0, 0, 0],
      );
      deny = true;
      expect(await connect([0x04, 0x01, 0x00, 0x50, 10, 0, 0, 1, 0]), [
        0x00,
        0x5b,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(dials, [
        ('192.168.7.9', 80),
        ('svc.internal', 443),
        ('10.0.0.1', 80),
      ]);
    });

    test(
      'hundreds of completed SOCKS sessions do not exhaust the proxy',
      () async {
        // dartssh2 4.1.0 forwardDynamic never released sessions that ended by
        // EOF in both directions, so after 128 of them it refused clients.
        final (manager, client, port) = await startSocks();
        for (var i = 0; i < 300; i++) {
          final socket = await Socket.connect('127.0.0.1', port);
          final reader = _Reader(socket);
          socket.add([
            0x05,
            0x01,
            0x00,
            0x05,
            0x01,
            0x00,
            0x01,
            127,
            0,
            0,
            1,
            0,
            80,
          ]);
          final reply = await reader.take(12);
          expect(reply[3], 0x00, reason: 'session $i');
          socket.add([i & 0xff]);
          await socket.close();
          await reader.done.future.timeout(const Duration(seconds: 2));
          expect(reader.bytes.takeBytes(), [i & 0xff]);
          socket.destroy();
        }
        await _eventually(
          () => manager.statusOf(_dynamic.id).activeConnections == 0,
        );
        expect(manager.statusOf(_dynamic.id).totalConnections, 300);
        expect(client.dials, hasLength(300));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('concurrent SOCKS clients and shutdown cleanup', () async {
      final (manager, _, port) = await startSocks();
      final sockets = <Socket>[];
      final readers = <_Reader>[];
      for (var i = 0; i < 32; i++) {
        final socket = await Socket.connect('127.0.0.1', port);
        sockets.add(socket);
        final reader = _Reader(socket);
        readers.add(reader);
        socket.add([
          0x05,
          0x01,
          0x00,
          0x05,
          0x01,
          0x00,
          0x01,
          127,
          0,
          0,
          1,
          0,
          80,
        ]);
      }
      for (var i = 0; i < 32; i++) {
        expect((await readers[i].take(12))[3], 0x00);
        sockets[i].add(utf8.encode('c$i'));
      }
      for (var i = 0; i < 32; i++) {
        expect(utf8.decode(await readers[i].take('c$i'.length)), 'c$i');
      }
      expect(manager.statusOf(_dynamic.id).activeConnections, 32);
      await manager.stop(_dynamic.id);
      for (final reader in readers) {
        await reader.done.future.timeout(const Duration(seconds: 2));
      }
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
      for (final socket in sockets) {
        socket.destroy();
      }
    });
  });

  group('lifecycle', () {
    test('SSH transport end closes every listener and clears status', () async {
      final client = FakeForwardingSshClient();
      final manager = SshPortForwardManager(client);
      final local = await manager.start(_local);
      final socks = await manager.start(_dynamic);
      final ports = [local.listeningPort, socks.listeningPort];
      expect(manager.runningCount, 2);

      client.endTransport();
      await _eventually(() => !manager.isOpen && manager.runningCount == 0);
      expect(local.isClosed, isTrue);
      expect(socks.isClosed, isTrue);
      for (final port in ports) {
        await expectLater(
          Socket.connect('127.0.0.1', port),
          throwsA(isA<SocketException>()),
        );
      }
      expect(manager.statusOf(_local.id).state, SshPortForwardState.stopped);
      await expectLater(
        manager.start(_local),
        throwsA(isA<SshPortForwardException>()),
      );
    });

    test('repeated start/stop cycles do not leak file descriptors', () async {
      final fdDir = Directory('/proc/self/fd');
      if (!fdDir.existsSync()) {
        markTestSkipped('Needs /proc/self/fd (Linux).');
        return;
      }
      int openFds() => fdDir.listSync().length;
      final client = FakeForwardingSshClient();
      client.opened.listen(echoOnFakeChannel);
      final manager = SshPortForwardManager(client);
      addTearDown(manager.closeAll);

      Future<void> cycle() async {
        for (final profile in [_local, _dynamic]) {
          final handle = await manager.start(profile);
          final socket = await Socket.connect(
            '127.0.0.1',
            handle.listeningPort,
          );
          final reader = _Reader(socket);
          if (profile.type == SshPortForwardType.dynamic) {
            socket.add([
              0x05,
              0x01,
              0x00,
              0x05,
              0x01,
              0x00,
              0x01,
              127,
              0,
              0,
              1,
              0,
              80,
            ]);
            await reader.take(12);
          }
          socket.add([1, 2, 3]);
          await reader.take(3);
          await manager.stop(profile.id);
          await reader.done.future.timeout(const Duration(seconds: 2));
          socket.destroy();
        }
      }

      await cycle(); // warm up lazily created runtime resources
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = openFds();
      for (var i = 0; i < 40; i++) {
        await cycle();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(openFds(), lessThanOrEqualTo(before + 2));
      expect(manager.runningCount, 0);
    });
  });
}
