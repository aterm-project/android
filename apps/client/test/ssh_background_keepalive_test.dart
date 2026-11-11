import 'dart:async';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/ssh_background_keepalive.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('atermius/ssh_keepalive_test');
const _grace = Duration(milliseconds: 40);

Future<void> _settle([Duration extra = Duration.zero]) =>
    Future<void>.delayed(_grace * 2 + extra);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) native;
  late SshBackgroundKeepalive keepalive;
  var revision = 0;

  Map<String, Object?> state({
    bool active = true,
    bool notifications = true,
    String? reason,
    int? at,
  }) => {
    'revision': at ?? ++revision,
    'active': active,
    'starting': false,
    'notifications': notifications,
    'reason': reason,
  };

  Future<void> fromNative(String method, [Object? arguments]) async {
    final completer = Completer<void>();
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => completer.complete(),
    );
    await completer.future;
  }

  List<int> sessions() =>
      calls.map((c) => (c.arguments as Map)['sessions'] as int).toList();

  setUp(() {
    calls = [];
    revision = 0;
    native = (call) async =>
        state(active: (call.arguments as Map)['sessions'] as int > 0);
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return native(call);
    });
    keepalive = SshBackgroundKeepalive(
      channel: _channel,
      enabled: true,
      handoffGrace: _grace,
    );
  });

  tearDown(() {
    keepalive.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  group('registry and channel', () {
    test('counts sessions, shows only counts and stops after the last '
        'release', () async {
      final first = keepalive.hold(SshKeepaliveKind.connecting);
      await _settle();
      expect(calls.single.method, 'sync');
      final arguments = Map<String, Object?>.from(
        calls.single.arguments as Map,
      );
      expect(arguments.keys.toSet(), {
        'sessions',
        'channelName',
        'title',
        'body',
        'disconnectLabel',
      });
      expect(arguments['sessions'], 1);
      expect(arguments['body'], 'Connecting SSH…');
      expect(keepalive.status.value.active, isTrue);

      first.update(SshKeepaliveKind.connected);
      final second = keepalive.hold(SshKeepaliveKind.connected);
      final third = keepalive.hold(SshKeepaliveKind.connecting);
      await _settle();
      expect(sessions(), [1, 3]);
      expect(
        (calls.last.arguments as Map)['body'],
        '2 SSH connections open · connecting…',
      );

      third.release();
      second.release();
      await _settle();
      expect((calls.last.arguments as Map)['body'], '1 SSH connection open');

      first.release();
      first.release(); // idempotent
      await Future<void>.delayed(_grace ~/ 4);
      expect(sessions().last, 1, reason: 'stop waits for the hand-off window');
      await _settle();
      expect(sessions().last, 0);
      expect(keepalive.status.value.active, isFalse);
      expect(keepalive.holdCount, 0);
    });

    test('a hold taken within the hand-off window keeps the service', () async {
      final transport = keepalive.hold(SshKeepaliveKind.connected);
      await _settle();
      transport.release();
      final recovery = keepalive.hold(SshKeepaliveKind.reconnecting);
      await _settle();
      expect(sessions(), [1, 1]);
      expect((calls.last.arguments as Map)['body'], 'Connecting SSH…');
      expect(sessions(), isNot(contains(0)));
      recovery.release();
      await _settle();
      expect(sessions().last, 0);
    });

    test('a released hold cannot be revived by a stale owner', () async {
      final hold = keepalive.hold(SshKeepaliveKind.connecting);
      hold.release();
      hold.update(SshKeepaliveKind.connected);
      expect(hold.released, isTrue);
      expect(keepalive.holdCount, 0);
      await _settle();
      // Count changes inside one turn coalesce: nothing was ever held long
      // enough to start the service.
      expect(sessions(), isEmpty);
    });

    test('OS denial and waiting-for-visible are reported, never claimed '
        'as active', () async {
      native = (_) async => state(active: false, reason: 'waiting_visible');
      keepalive.hold(SshKeepaliveKind.reconnecting);
      await _settle();
      expect(keepalive.status.value.active, isFalse);
      expect(keepalive.status.value.reason, 'waiting_visible');

      await fromNative('state', state(active: false, reason: 'denied'));
      expect(keepalive.status.value.reason, 'denied');

      // An out-of-order (older) state is ignored.
      await fromNative('state', state(active: true, at: 1));
      expect(keepalive.status.value.active, isFalse);

      // Unknown reasons are not trusted verbatim.
      await fromNative('state', state(active: false, reason: 'host=x'));
      expect(keepalive.status.value.reason, isNull);
    });

    test('notification refusal keeps the service but reports it', () async {
      native = (_) async => state(notifications: false);
      keepalive.hold(SshKeepaliveKind.connected);
      await _settle();
      expect(keepalive.status.value.active, isTrue);
      expect(keepalive.status.value.notifications, isFalse);
      await fromNative('state', state(notifications: true));
      expect(keepalive.status.value.notifications, isTrue);
    });

    test(
      'channel failure is contained and retried on the next change',
      () async {
        native = (_) async => throw PlatformException(code: 'boom');
        final hold = keepalive.hold(SshKeepaliveKind.connecting);
        await _settle();
        expect(keepalive.status.value.active, isFalse);
        expect(keepalive.status.value.reason, 'unavailable');
        native = (call) async => state();
        hold.update(SshKeepaliveKind.connected);
        await _settle();
        expect(sessions(), [1, 1]);
        expect(keepalive.status.value.active, isTrue);
      },
    );

    test('other platforms never touch the channel', () async {
      final disabled = SshBackgroundKeepalive(
        channel: _channel,
        enabled: false,
        handoffGrace: _grace,
      );
      addTearDown(disabled.dispose);
      final hold = disabled.hold(SshKeepaliveKind.connected);
      await _settle();
      expect(disabled.holdCount, 1);
      hold.release();
      await _settle();
      expect(calls, isEmpty);
    });

    test('Disconnect all stops recoveries before closing transports', () async {
      final order = <String>[];
      final remove = keepalive.addUserDisconnectListener(
        () => order.add('recovery'),
      );
      keepalive.hold(
        SshKeepaliveKind.connected,
        onUserDisconnect: () => order.add('transport-a'),
      );
      final released = keepalive.hold(
        SshKeepaliveKind.connected,
        onUserDisconnect: () => order.add('released'),
      );
      keepalive.hold(
        SshKeepaliveKind.connecting,
        onUserDisconnect: () => throw StateError('one owner failing'),
      );
      keepalive.hold(
        SshKeepaliveKind.connected,
        onUserDisconnect: () => order.add('transport-b'),
      );
      released.release();
      await _settle();
      await fromNative('disconnectAll');
      expect(order, ['recovery', 'transport-a', 'transport-b']);
      remove();
      remove();
      order.clear();
      await fromNative('disconnectAll');
      expect(order, ['transport-a', 'transport-b']);
    });
  });

  group('SessionRecovery', () {
    test(
      'SSH recovery holds only while an automatic retry is pending',
      () async {
        final flight = Completer<void>();
        var attempts = 0;
        final recovery = SessionRecovery(
          automatic: true,
          keepSshAlive: true,
          sshKeepalive: keepalive,
          isCurrent: () => true,
          reconnect: () {
            attempts++;
            return flight.future;
          },
        );
        addTearDown(recovery.dispose);
        recovery.update(connected: true);
        expect(keepalive.holdCount, 0, reason: 'connected: transport holds');
        recovery.update(connected: false);
        expect(keepalive.holdCount, 1);
        expect(recovery.interrupted, isTrue);
        recovery.update(connected: true);
        expect(keepalive.holdCount, 0);
        expect(attempts, 0);
        recovery.update(connected: false);
        expect(keepalive.holdCount, 1);
        final retry = recovery.retry();
        await Future<void>.delayed(Duration.zero);
        expect(attempts, 1);
        expect(keepalive.holdCount, 1, reason: 'busy retry keeps the hold');
        flight.complete();
        await retry;
        recovery.update(connected: true);
        expect(keepalive.holdCount, 0);
      },
    );

    test(
      'Disconnect all blocks automatic retry and releases the hold',
      () async {
        var attempts = 0;
        final recovery = SessionRecovery(
          automatic: true,
          keepSshAlive: true,
          sshKeepalive: keepalive,
          isCurrent: () => true,
          reconnect: () async => attempts++,
        );
        addTearDown(recovery.dispose);
        recovery.update(connected: true);
        recovery.update(connected: false);
        expect(keepalive.holdCount, 1);
        await _settle();
        await fromNative('disconnectAll');
        expect(recovery.automaticEnabled, isFalse);
        expect(keepalive.holdCount, 0);
        // The transport closed by Disconnect all reports a drop afterwards.
        recovery.update(connected: false);
        expect(keepalive.holdCount, 0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(attempts, 0);
      },
    );

    test(
      'closing/locking (dispose) and stale scope release the hold',
      () async {
        var current = true;
        final recovery = SessionRecovery(
          automatic: true,
          keepSshAlive: true,
          sshKeepalive: keepalive,
          isCurrent: () => current,
          reconnect: () async {},
        );
        recovery.update(connected: true);
        recovery.update(connected: false);
        expect(keepalive.holdCount, 1);
        current = false;
        recovery.blockAutomatic();
        expect(keepalive.holdCount, 0);
        current = true;
        recovery.dispose();
        expect(keepalive.holdCount, 0);
        await _settle();
        await fromNative('disconnectAll'); // listener removed: no throw
      },
    );

    test('non-SSH recovery never holds the SSH keepalive', () async {
      final recovery = SessionRecovery(
        automatic: true,
        sshKeepalive: keepalive,
        isCurrent: () => true,
        reconnect: () async {},
      );
      addTearDown(recovery.dispose);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(keepalive.holdCount, 0);
    });

    testWidgets('the hold is bounded per interruption while retries continue', (
      tester,
    ) async {
      var attempts = 0;
      final local = SshBackgroundKeepalive(
        channel: _channel,
        enabled: true,
        handoffGrace: _grace,
      );
      final recovery = SessionRecovery(
        automatic: true,
        keepSshAlive: true,
        sshKeepalive: local,
        keepaliveLimit: const Duration(seconds: 12),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(local.holdCount, 1);
      await tester.pump(const Duration(seconds: 6));
      expect(attempts, 1);
      expect(local.holdCount, 1);
      await tester.pump(const Duration(seconds: 7));
      expect(local.holdCount, 0);
      await tester.pump(const Duration(seconds: 6));
      expect(attempts, greaterThan(1));
      expect(local.holdCount, 0);
      // A successful reconnect re-arms the bound for the next drop.
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(local.holdCount, 1);
      recovery.dispose();
      expect(local.holdCount, 0);
      await tester.pump(_grace * 2);
      local.dispose();
    });

    test('off Android a recovery takes no hold and starts no timers', () {
      final disabled = SshBackgroundKeepalive(
        channel: _channel,
        enabled: false,
      );
      addTearDown(disabled.dispose);
      final recovery = SessionRecovery(
        automatic: true,
        keepSshAlive: true,
        sshKeepalive: disabled,
        isCurrent: () => true,
        reconnect: () async {},
      );
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(disabled.holdCount, 0);
      recovery.dispose();
    });
  });

  group('SshService connection ownership', () {
    const host = HostRecord(
      id: 'host',
      name: 'Host',
      address: '192.0.2.20',
      username: 'user',
    );
    const credential = CredentialRecord(
      id: 'credential',
      name: 'Password',
      username: 'user',
      secret: 'secret',
    );

    SshService service(
      List<_FakeClient> clients, {
      Future<void> Function()? authenticate,
    }) => SshService(
      api: null,
      deviceId: 'device',
      useRelay: false,
      backgroundKeepalive: keepalive,
      directSocketConnector: (_, _) async => _FakeSocket(),
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            final client = _FakeClient(
              authenticate?.call() ?? Future<void>.value(),
            );
            clients.add(client);
            return client;
          },
    );

    test(
      'holds while connecting, becomes connected, releases on close',
      () async {
        final clients = <_FakeClient>[];
        final gate = Completer<void>();
        final pending = service(clients, authenticate: () => gate.future)
            .connect(
              host: host,
              credential: credential,
              verifyHostKey: (_, _) async => true,
            );
        await Future<void>.delayed(Duration.zero);
        expect(keepalive.holdCount, 1);
        await _settle();
        expect((calls.last.arguments as Map)['body'], 'Connecting SSH…');
        gate.complete();
        final connection = await pending;
        await _settle();
        expect(keepalive.holdCount, 1);
        expect((calls.last.arguments as Map)['body'], '1 SSH connection open');
        for (final call in calls) {
          expect('${call.arguments}', isNot(contains('192.0.2.20')));
          expect('${call.arguments}', isNot(contains('secret')));
          expect('${call.arguments}', isNot(contains('user')));
        }
        await connection.close();
        expect(keepalive.holdCount, 0);
        await _settle();
        expect(sessions().last, 0);
      },
    );

    test('a failed open releases its hold', () async {
      final clients = <_FakeClient>[];
      await expectLater(
        service(
          clients,
          authenticate: () async => throw SSHAuthFailError('denied'),
        ).connect(
          host: host,
          credential: credential,
          verifyHostKey: (_, _) async => true,
        ),
        throwsA(isA<SSHAuthFailError>()),
      );
      expect(keepalive.holdCount, 0);
      await _settle();
      // The attempt was visible long enough to sync; failure stops it.
      expect(sessions(), [1, 0]);
    });

    test('multiple connections are counted; a remote drop releases only '
        'its own hold', () async {
      final clients = <_FakeClient>[];
      final ssh = service(clients);
      final a = await ssh.connect(
        host: host,
        credential: credential,
        verifyHostKey: (_, _) async => true,
      );
      final b = await ssh.connect(
        host: host,
        credential: credential,
        verifyHostKey: (_, _) async => true,
      );
      await _settle();
      expect(keepalive.holdCount, 2);
      expect((calls.last.arguments as Map)['body'], '2 SSH connections open');
      clients.first.drop();
      await Future<void>.delayed(Duration.zero);
      expect(keepalive.holdCount, 1);
      await a.close(); // owner cleanup after the drop stays idempotent
      expect(keepalive.holdCount, 1);
      await b.close();
      expect(keepalive.holdCount, 0);
    });

    test('Disconnect all is atomic with a recovery flight that has not '
        'reached SSH yet', () async {
      final clients = <_FakeClient>[];
      final ssh = service(clients);
      final gate = Completer<void>();
      Object? flightError;
      final recovery = SessionRecovery(
        automatic: true,
        keepSshAlive: true,
        sshKeepalive: keepalive,
        isCurrent: () => true,
        reconnect: () async {
          // e.g. waiting for a busy profile or a credential lookup.
          await gate.future;
          try {
            await ssh.connect(
              host: host,
              credential: credential,
              verifyHostKey: (_, _) async => true,
            );
          } catch (error) {
            flightError = error;
            rethrow;
          }
        },
      );
      addTearDown(recovery.dispose);
      recovery.update(connected: true);
      recovery.update(connected: false);
      final flight = recovery.retry();
      await _settle();
      expect(keepalive.holdCount, 1);
      await fromNative('disconnectAll');
      gate.complete();
      await flight;
      expect(flightError, isA<SshConnectCancelledException>());
      expect(clients, isEmpty, reason: 'no socket or SSH client was opened');
      expect(keepalive.holdCount, 0);
      expect(recovery.automaticEnabled, isFalse);

      // A later user-initiated open (outside that flight) still works.
      final later = await ssh.connect(
        host: host,
        credential: credential,
        verifyHostKey: (_, _) async => true,
      );
      expect(keepalive.holdCount, 1);
      await later.close();
      // And so does a manual retry started after Disconnect all.
      var manualOpened = false;
      final manual = SessionRecovery(
        automatic: true,
        keepSshAlive: true,
        sshKeepalive: keepalive,
        isCurrent: () => true,
        reconnect: () async {
          final connection = await ssh.connect(
            host: host,
            credential: credential,
            verifyHostKey: (_, _) async => true,
          );
          manualOpened = true;
          await connection.close();
        },
      );
      addTearDown(manual.dispose);
      manual.update(connected: true);
      manual.update(connected: false);
      await manual.retry();
      expect(manualOpened, isTrue);
    });

    test(
      'Disconnect all closes open transports and cancels pending opens',
      () async {
        final clients = <_FakeClient>[];
        final open = await service(clients).connect(
          host: host,
          credential: credential,
          verifyHostKey: (_, _) async => true,
        );
        final gate = Completer<void>();
        final pending = service(clients, authenticate: () => gate.future)
            .connect(
              host: host,
              credential: credential,
              verifyHostKey: (_, _) async => true,
            );
        final pendingResult = expectLater(
          pending,
          throwsA(isA<SshConnectCancelledException>()),
        );
        await _settle();
        expect(keepalive.holdCount, 2);
        await fromNative('disconnectAll');
        await pendingResult;
        expect(clients.first.closed, isTrue);
        expect(keepalive.holdCount, 0);
        await open.close();
        expect(keepalive.holdCount, 0);
      },
    );
  });
}

class _FakeClient implements SSHClient {
  _FakeClient(this._authenticated);

  final Future<void> _authenticated;
  final _done = Completer<void>();
  bool closed = false;

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<void> get done => _done.future;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => _FakeSession();

  @override
  Future<void> close() async {
    closed = true;
    drop();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements SSHSession {
  @override
  Stream<Uint8List> get stdout => const Stream<Uint8List>.empty();

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements SSHSocket {
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get stream => const Stream.empty();

  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>().sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}
