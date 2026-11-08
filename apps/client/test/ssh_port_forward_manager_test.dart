import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const localProfile = SshPortForwardProfile(
    id: 'local-1',
    name: 'Database tunnel',
    type: SshPortForwardType.local,
    bindAddress: '127.0.0.1',
    bindPort: 0,
    destinationAddress: 'db.internal',
    destinationPort: 5432,
  );

  test('manager tracks, stops and closes per-connection forwards', () async {
    final platform = _FakePlatform();
    final manager = SshPortForwardManager(_FakeSshClient(), platform: platform);
    final handle = await manager.start(localProfile);

    expect(manager.activeProfileIds, ['local-1']);
    expect(handle.listeningPort, 50123);
    await expectLater(manager.start(localProfile), throwsStateError);
    expect(await manager.stop('local-1'), isTrue);
    expect(handle.isClosed, isTrue);
    expect(await manager.stop('local-1'), isFalse);

    await manager.start(localProfile.copyWithId('local-2'));
    await manager.closeAll();
    expect(manager.activeProfileIds, isEmpty);
    expect(platform.handles.every((item) => item.isClosed), isTrue);
    expect(manager.isOpen, isFalse);
    await expectLater(
      manager.start(localProfile),
      throwsA(isA<SshPortForwardException>()),
    );
  });

  test(
    'manager prevents concurrent profiles from reusing a listener',
    () async {
      final platform = _FakePlatform();
      final manager = SshPortForwardManager(
        _FakeSshClient(),
        platform: platform,
      );
      final first = localProfile.copyWithId('local-1').copyWithPort(15432);
      final duplicate = SshPortForwardProfile(
        id: 'local-2',
        name: 'Same listener',
        type: SshPortForwardType.dynamic,
        bindAddress: 'localhost',
        bindPort: 15432,
      );

      await manager.start(first);
      await expectLater(manager.start(duplicate), throwsStateError);
      expect(platform.handles, hasLength(1));
      await manager.closeAll();
    },
  );

  test(
    'manager refuses to start forwarding on unsupported platforms',
    () async {
      final platform = _FakePlatform(supported: false);
      final manager = SshPortForwardManager(
        _FakeSshClient(),
        platform: platform,
      );

      await expectLater(manager.start(localProfile), throwsUnsupportedError);
      expect(platform.handles, isEmpty);
      await manager.closeAll();
    },
  );

  test(
    'IO local forwarding binds loopback and bridges both directions',
    () async {
      final client = _FakeSshClient();
      final manager = SshPortForwardManager(client);
      final handle = await manager.start(localProfile);
      expect(handle.listeningPort, greaterThan(0));

      final socket = await Socket.connect('127.0.0.1', handle.listeningPort);
      addTearDown(() async {
        await manager.closeAll();
        socket.destroy();
        await client.forwardChannel?.dispose();
      });

      final channel = await client.channelOpened.future.timeout(
        const Duration(seconds: 2),
      );
      final localBytes = Completer<List<int>>();
      channel.sinkController.stream.listen(localBytes.complete);
      socket.add([1, 2, 3]);
      await socket.flush();
      expect(await localBytes.future.timeout(const Duration(seconds: 2)), [
        1,
        2,
        3,
      ]);

      final socketBytes = Completer<List<int>>();
      socket.listen(socketBytes.complete);
      channel.outputController.add(Uint8List.fromList([4, 5, 6]));
      expect(await socketBytes.future.timeout(const Duration(seconds: 2)), [
        4,
        5,
        6,
      ]);

      await manager.closeAll();
      expect(handle.isClosed, isTrue);
      expect(channel.isDestroyed, isTrue);
    },
  );

  test(
    'remote forwarding requests a loopback listener and reports its port',
    () async {
      final client = _FakeSshClient();
      final manager = SshPortForwardManager(client);
      const profile = SshPortForwardProfile(
        id: 'remote-1',
        name: 'Device web service',
        type: SshPortForwardType.remote,
        bindAddress: '127.0.0.1',
        bindPort: 0,
        destinationAddress: 'localhost',
        destinationPort: 3000,
      );

      final handle = await manager.start(profile);
      expect(client.remoteBindHost, '127.0.0.1');
      expect(client.remoteBindPort, 0);
      expect(handle.listeningPort, 62001);
      expect(manager.activeListeningPort(profile.id), 62001);
      await manager.stop(profile.id);
      expect(client.remoteForwardCancelled, isTrue);
    },
  );

  test('failed remote cancellation closes the SSH transport', () async {
    final client = _FakeSshClient()..rejectRemoteCancel = true;
    final manager = SshPortForwardManager(client);
    const profile = SshPortForwardProfile(
      id: 'remote-fail-1',
      name: 'Remote service',
      type: SshPortForwardType.remote,
      bindAddress: '127.0.0.1',
      bindPort: 0,
      destinationAddress: 'localhost',
      destinationPort: 3000,
    );

    await manager.start(profile);
    var notifications = 0;
    manager.addListener(() => notifications++);
    await expectLater(manager.stop(profile.id), throwsStateError);
    expect(client.closeCount, 1);
    expect(manager.activeProfileIds, isEmpty);
    // "stopping" while tearing down, then "stopped".
    expect(notifications, 2);
    expect(manager.statusOf(profile.id).state, SshPortForwardState.stopped);
    await manager.closeAll();
  });

  test(
    'dynamic SOCKS forwarding binds only loopback and closes cleanly',
    () async {
      final client = _FakeSshClient();
      final manager = SshPortForwardManager(client);
      const profile = SshPortForwardProfile(
        id: 'dynamic-1',
        name: 'Private SOCKS',
        type: SshPortForwardType.dynamic,
        bindAddress: '127.0.0.1',
        bindPort: 0,
      );

      final handle = await manager.start(profile);
      expect(handle.listeningPort, greaterThan(0));
      final probe = await Socket.connect('127.0.0.1', handle.listeningPort);
      expect(probe.remoteAddress.isLoopback, isTrue);
      probe.destroy();
      await manager.stop(profile.id);
      expect(handle.isClosed, isTrue);
      await expectLater(
        Socket.connect('127.0.0.1', handle.listeningPort),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('stop during an in-flight start cancels that start', () async {
    final platform = _FakePlatform()..gate = Completer<void>();
    final manager = SshPortForwardManager(_FakeSshClient(), platform: platform);
    final starting = manager.start(localProfile);
    expect(
      manager.statusOf(localProfile.id).state,
      SshPortForwardState.starting,
    );
    expect(await manager.stop(localProfile.id), isTrue);
    platform.gate!.complete();
    await expectLater(starting, throwsStateError);
    expect(platform.handles.single.isClosed, isTrue);
    expect(manager.activeProfileIds, isEmpty);
    expect(
      manager.statusOf(localProfile.id).state,
      SshPortForwardState.stopped,
    );
  });

  test(
    'stop/restart of one profile keeps the newer listener tracked',
    () async {
      final platform = _FakePlatform();
      final manager = SshPortForwardManager(
        _FakeSshClient(),
        platform: platform,
      );
      final fixed = localProfile.copyWithPort(15433);
      await manager.start(fixed);
      final release = Completer<void>();
      platform.handles.single.closeGate = release;
      final stopping = manager.stop(fixed.id);
      expect(manager.statusOf(fixed.id).state, SshPortForwardState.stopping);
      expect(manager.isStopping(fixed.id), isTrue);
      expect(manager.runningCount, 0);
      // A different profile cannot take the still-closing listener...
      await expectLater(
        manager.start(fixed.copyWithId('other')),
        throwsStateError,
      );
      // ...but the same profile may restart, and the late stop leaves it alone.
      final restarted = await manager.start(fixed);
      expect(manager.isStopping(fixed.id), isFalse);
      expect(manager.statusOf(fixed.id).state, SshPortForwardState.running);
      release.complete();
      await stopping;
      expect(manager.activeProfileIds, [fixed.id]);
      expect(identical(platform.handles.last, restarted), isTrue);
      expect(restarted.isClosed, isFalse);
      // Stopping the new handle works and stopping twice is harmless.
      expect(await manager.stop(fixed.id), isTrue);
      expect(restarted.isClosed, isTrue);
      expect(await manager.stop(fixed.id), isFalse);
      await manager.closeAll();
    },
  );

  test('start failures become a per-profile failed status', () async {
    final platform = _FakePlatform()
      ..failWith = const SshPortForwardException('Port busy.');
    final manager = SshPortForwardManager(_FakeSshClient(), platform: platform);
    await expectLater(
      manager.start(localProfile),
      throwsA(isA<SshPortForwardException>()),
    );
    final status = manager.statusOf(localProfile.id);
    expect(status.state, SshPortForwardState.failed);
    expect(status.error, 'Port busy.');
    // Library errors are never shown verbatim.
    expect(
      describeSshPortForwardError(Exception('secret=hunter2')),
      isNot(contains('hunter2')),
    );
    manager.clearError(localProfile.id);
    expect(
      manager.statusOf(localProfile.id).state,
      SshPortForwardState.stopped,
    );
  });

  test('wildcard listeners conflict with specific addresses', () async {
    final manager = SshPortForwardManager(
      _FakeSshClient(),
      platform: _FakePlatform(),
    );
    final exposed = localProfile
        .copyWithId('wild')
        .copyWithPort(18080)
        .copyWith(bindAddress: '0.0.0.0', exposeToNetwork: true);
    await manager.start(exposed);
    await expectLater(
      manager.start(localProfile.copyWithId('loop').copyWithPort(18080)),
      throwsStateError,
    );
    // A remote-side listener on the same port lives on the SSH server.
    await manager.start(
      const SshPortForwardProfile(
        id: 'remote-same-port',
        name: 'Remote',
        type: SshPortForwardType.remote,
        bindAddress: '127.0.0.1',
        bindPort: 18080,
        destinationAddress: '127.0.0.1',
        destinationPort: 80,
      ),
    );
    expect(manager.runningCount, 2);
    await manager.closeAll();
  });

  test('a handle that closes by itself is reported as failed', () async {
    final platform = _FakePlatform();
    final manager = SshPortForwardManager(_FakeSshClient(), platform: platform);
    await manager.start(localProfile);
    final handle = platform.handles.single
      ..isClosed = true
      ..lastConnectionError = 'The device listener stopped unexpectedly.';
    handle.callback!();
    expect(manager.activeProfileIds, isEmpty);
    expect(
      manager.statusOf(localProfile.id).error,
      'The device listener stopped unexpectedly.',
    );
    await manager.closeAll();
  });
}

class _FakePlatform implements SshPortForwardPlatform {
  _FakePlatform({this.supported = true});

  final bool supported;
  final handles = <_FakeHandle>[];

  Completer<void>? gate;
  Object? failWith;

  @override
  bool get isSupported => supported;

  @override
  String? get unsupportedReason => supported ? null : 'Not on this platform.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) async {
    final handle = _FakeHandle(profile.id, handles.length + 50123);
    handles.add(handle);
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    return handle;
  }
}

class _FakeHandle implements SshPortForwardHandle {
  _FakeHandle(this.profileId, this.listeningPort);

  @override
  final String profileId;
  @override
  final int listeningPort;
  @override
  bool isClosed = false;
  @override
  int activeConnections = 0;
  @override
  int totalConnections = 0;
  @override
  String? lastConnectionError;
  void Function()? callback;

  @override
  set onChanged(void Function()? value) => callback = value;

  Completer<void>? closeGate;

  @override
  Future<void> close() async {
    isClosed = true;
    await closeGate?.future;
  }
}

class _FakeSshClient extends Fake implements SSHClient {
  final channelOpened = Completer<_FakeForwardChannel>();
  _FakeForwardChannel? forwardChannel;
  String? remoteBindHost;
  int? remoteBindPort;
  bool remoteForwardCancelled = false;
  bool rejectRemoteCancel = false;
  int closeCount = 0;
  String? dynamicBindHost;
  int? dynamicBindPort;
  _FakeDynamicForward? dynamicForward;

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    final channel = _FakeForwardChannel();
    forwardChannel = channel;
    if (!channelOpened.isCompleted) channelOpened.complete(channel);
    return channel;
  }

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    remoteBindHost = host;
    remoteBindPort = port;
    return SSHRemoteForward(this, host ?? '', 62001, filter);
  }

  @override
  Future<bool> cancelForwardRemote(SSHRemoteForward forward) async {
    remoteForwardCancelled = true;
    return !rejectRemoteCancel;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<SSHDynamicForward> forwardDynamic({
    String bindHost = '127.0.0.1',
    int? bindPort,
    SSHDynamicForwardOptions options = const SSHDynamicForwardOptions(),
    SSHDynamicConnectionFilter? filter,
  }) async {
    dynamicBindHost = bindHost;
    dynamicBindPort = bindPort;
    return dynamicForward = _FakeDynamicForward('127.0.0.1', 62002);
  }
}

class _FakeDynamicForward implements SSHDynamicForward {
  _FakeDynamicForward(this.host, this.port);

  @override
  final String host;
  @override
  final int port;
  @override
  bool isClosed = false;

  @override
  Future<void> close() async => isClosed = true;
}

class _FakeForwardChannel implements SSHForwardChannel {
  final outputController = StreamController<Uint8List>();
  final sinkController = StreamController<List<int>>();
  bool isDestroyed = false;

  @override
  Stream<Uint8List> get stream => outputController.stream;
  @override
  StreamSink<List<int>> get sink => sinkController.sink;
  @override
  Future<void> get done => Future<void>.value();
  @override
  Future<void> close() async => destroy();
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    if (isDestroyed) return;
    isDestroyed = true;
    unawaited(outputController.close());
    unawaited(sinkController.close());
  }

  Future<void> dispose() async {
    if (!isDestroyed) destroy();
  }
}

extension on SshPortForwardProfile {
  SshPortForwardProfile copyWithId(String id) => SshPortForwardProfile(
    id: id,
    name: name,
    type: type,
    bindAddress: bindAddress,
    bindPort: bindPort,
    destinationAddress: destinationAddress,
    destinationPort: destinationPort,
  );

  SshPortForwardProfile copyWithPort(int port) => SshPortForwardProfile(
    id: id,
    name: name,
    type: type,
    bindAddress: bindAddress,
    bindPort: port,
    destinationAddress: destinationAddress,
    destinationPort: destinationPort,
  );
}
