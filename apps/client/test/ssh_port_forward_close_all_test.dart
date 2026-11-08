import 'dart:async';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_port_forward_fakes.dart';

/// Lifecycle regression (gated, independent of any device result): tearing
/// down every forward of a connection must begin closing all of them without
/// waiting for an earlier close that is blocked (e.g. a remote cancellation a
/// dead transport never answers), one failing close must not stop the others,
/// and closeAll() must own every teardown still in flight.
void main() {
  SshPortForwardProfile profile(String id, SshPortForwardType type) =>
      SshPortForwardProfile(
        id: id,
        name: id,
        type: type,
        bindAddress: '127.0.0.1',
        bindPort: 0,
        destinationAddress: type == SshPortForwardType.dynamic
            ? null
            : '127.0.0.1',
        destinationPort: type == SshPortForwardType.dynamic ? null : 9,
      );

  group('closeAll with gated handles', () {
    for (final viaTransport in [false, true]) {
      test('every handle starts closing while the first close is blocked '
          '(${viaTransport ? 'transport ended' : 'closeAll'})', () async {
        final platform = _GatedPlatform();
        final client = FakeForwardingSshClient();
        final manager = SshPortForwardManager(client, platform: platform);
        await manager.start(profile('R', SshPortForwardType.remote));
        await manager.start(profile('L', SshPortForwardType.local));
        await manager.start(profile('D', SshPortForwardType.dynamic));
        final blocked = platform.handles['R']!..gate = Completer<void>();
        platform.handles['L']!.failClose = true; // failure isolation

        var closeAllDone = false;
        if (viaTransport) {
          client.endTransport();
          await _eventually(() => !manager.isOpen);
        } else {
          unawaited(manager.closeAll().then((_) => closeAllDone = true));
        }
        await _eventually(
          () => platform.handles.values.every((h) => h.closeStarted),
          reason: 'later handles must not wait for the blocked one',
        );
        expect(platform.handles['D']!.closeFinished, isTrue);
        expect(blocked.closeFinished, isFalse);
        expect(manager.activeProfileIds, isEmpty);
        if (!viaTransport) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(closeAllDone, isFalse, reason: 'completes after teardown');
        }
        blocked.gate!.complete();
        await manager.closeAll(); // idempotent
        if (!viaTransport) {
          await _eventually(() => closeAllDone);
        }
        expect(blocked.closeFinished, isTrue);
      });
    }
  });

  group('closeAll owns every teardown in flight', () {
    test('joins an earlier stop without closing that handle twice', () async {
      final platform = _GatedPlatform();
      final manager = SshPortForwardManager(
        FakeForwardingSshClient(),
        platform: platform,
      );
      await manager.start(profile('D', SshPortForwardType.dynamic));
      final handle = platform.handles['D']!..gate = Completer<void>();
      final stopping = manager.stop('D');
      var done = false;
      final closing = manager.closeAll().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse);
      handle.gate!.complete();
      await stopping;
      await closing;
      expect(done, isTrue);
      expect(handle.closeCalls, 1);
    });

    test('waits for a pending start only up to the bound, late handle '
        'is still closed', () async {
      final platform = _GatedPlatform()..startGate = Completer<void>();
      final manager = SshPortForwardManager(
        FakeForwardingSshClient(),
        platform: platform,
        pendingStartCloseBound: const Duration(milliseconds: 100),
      );
      final starting = manager
          .start(profile('L', SshPortForwardType.local))
          .then<Object?>((_) => null, onError: (Object e) => e);
      final stopwatch = Stopwatch()..start();
      await manager.closeAll();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      platform.startGate!.complete(); // the platform answers much later
      expect(await starting, isA<StateError>());
      final late = platform.handles['L']!;
      expect(late.closeCalls, 1);
      expect(late.closeFinished, isTrue);
      expect(manager.activeProfileIds, isEmpty);
    });

    test('SshConnection.close ordering cannot deadlock on a pending remote '
        'start', () async {
      // closeAll() runs before client.close(); the remote request only fails
      // once the transport closes (as dartssh2 terminates pending requests).
      final client = _TransportBoundRemoteClient();
      final manager = SshPortForwardManager(
        client,
        pendingStartCloseBound: const Duration(milliseconds: 200),
      );
      final starting = manager
          .start(profile('R', SshPortForwardType.remote))
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stopwatch = Stopwatch()..start();
      await manager.closeAll();
      await client.close();
      expect(await starting, isA<SshPortForwardException>());
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(manager.activeProfileIds, isEmpty);
    });
  });

  test(
    'device listeners are released at once although remote cancellation hangs',
    () async {
      final client = FakeForwardingSshClient()
        ..remoteCancelGate = Completer<void>();
      final manager = SshPortForwardManager(client);
      // L, R, D: device listeners must not wait for the remote handle.
      final local = await manager.start(
        profile('close-L', SshPortForwardType.local),
      );
      await manager.start(
        profile(
          'close-R',
          SshPortForwardType.remote,
        ).copyWith(destinationPort: 9),
      );
      final socks = await manager.start(
        profile('close-D', SshPortForwardType.dynamic),
      );

      client.endTransport();
      final stopwatch = Stopwatch()..start();
      await _eventually(() => !manager.isOpen);
      expect(manager.activeProfileIds, isEmpty);
      for (final port in [local.listeningPort, socks.listeningPort]) {
        await _eventually(
          () => false,
          reason: 'device port $port still accepts connections',
          timeout: const Duration(milliseconds: 1500),
          asyncCheck: () async => !(await _canConnect(port)),
        );
      }
      // Well before the 3 s remote cancellation timeout.
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(client.remoteCancelCount, 1);
      client.remoteCancelGate!.complete();
      await manager.closeAll();
    },
  );
}

Future<bool> _canConnect(int port) async {
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 200),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> _eventually(
  bool Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 5),
  Future<bool> Function()? asyncCheck,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final ok = asyncCheck != null ? await asyncCheck() : condition();
    if (ok) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met in $timeout${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _GatedHandle implements SshPortForwardHandle {
  _GatedHandle(this.profileId);

  @override
  final String profileId;
  Completer<void>? gate;
  bool failClose = false;
  bool closeStarted = false;
  bool closeFinished = false;
  @override
  bool isClosed = false;
  @override
  int get listeningPort => 40000;
  @override
  int get activeConnections => 0;
  @override
  int get totalConnections => 0;
  @override
  String? get lastConnectionError => null;
  @override
  set onChanged(void Function()? callback) {}

  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
    closeStarted = true;
    isClosed = true;
    try {
      await gate?.future;
      if (failClose) throw StateError('close failed');
    } finally {
      closeFinished = true;
    }
  }
}

class _GatedPlatform implements SshPortForwardPlatform {
  final handles = <String, _GatedHandle>{};
  Completer<void>? startGate;

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    return handles[profile.id] = _GatedHandle(profile.id);
  }
}

/// `tcpip-forward` is answered only by the transport closing (error), like a
/// dead or stalled server with dartssh2 terminating pending requests.
class _TransportBoundRemoteClient extends FakeForwardingSshClient {
  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    await done;
    throw StateError('SSH client closed');
  }
}
