import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_listener_lifecycle.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/platform/mcp_foreground.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Target extends ChangeNotifier implements McpLifecycleTarget {
  bool _running = false;
  int port = 8765;
  int stops = 0;

  @override
  bool get running => _running;
  @override
  Uri? get endpoint =>
      _running ? Uri.parse('http://127.0.0.1:$port/mcp') : null;

  void startListening([int? next]) {
    if (next != null) port = next;
    _running = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    _running = false;
    notifyListeners();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methodChannel = MethodChannel('atermius/mcp_foreground_test');
  final messenger = binding.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) native;
  late _Target target;
  late McpForegroundChannel channel;
  late McpListenerLifecycle lifecycle;
  var leaseCounter = 0;

  String nextLease() => 'lease-${(++leaseCounter).toString().padLeft(12, '0')}';

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Native -> Dart call, as MainActivity sends it.
  Future<void> fromNative(String method, Map<String, Object?> args) async {
    await messenger.handlePlatformMessage(
      methodChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await settle();
  }

  void lifecycleState(AppLifecycleState state) {
    binding.handleAppLifecycleStateChanged(state);
  }

  setUp(() {
    calls = [];
    native = (call) async =>
        call.method == 'start' ? {'active': true, 'notifications': true} : null;
    messenger.setMockMethodCallHandler(methodChannel, (call) {
      calls.add(call);
      return native(call);
    });
    lifecycleState(AppLifecycleState.resumed);
    target = _Target();
    channel = McpForegroundChannel(channel: methodChannel, enabled: true);
    lifecycle = McpListenerLifecycle(
      target: target,
      channel: channel,
      binding: binding,
      newLeaseId: nextLease,
      text: () => const McpForegroundText(
        channelName: 'Externe KI',
        title: 'MCP aktiv',
        body: 'Auf {endpoint}\nStopp widerruft',
        stopLabel: 'Stopp',
      ),
    );
  });

  tearDown(() {
    lifecycle.dispose();
    channel.dispose();
    messenger.setMockMethodCallHandler(methodChannel, null);
    lifecycleState(AppLifecycleState.resumed);
  });

  test(
    'listening starts a visible lease without any secret on the channel',
    () async {
      expect(lifecycle.mode, McpBackgroundMode.inactive);
      target.startListening();
      expect(lifecycle.mode, McpBackgroundMode.starting);
      await settle();
      expect(lifecycle.mode, McpBackgroundMode.protected);
      expect(lifecycle.notificationsVisible, isTrue);
      final start = calls.single;
      expect(start.method, 'start');
      final args = Map<String, Object?>.from(start.arguments as Map);
      expect(args.keys.toSet(), {
        'leaseId',
        'port',
        'channelName',
        'title',
        'body',
        'stopLabel',
      });
      expect(args['port'], 8765);
      expect(args['body'], 'Auf 127.0.0.1:8765 Stopp widerruft');
      expect(args['title'], 'MCP aktiv');
      expect(jsonEncode(args), isNot(contains('Bearer')));

      await target.stop();
      await settle();
      expect(lifecycle.mode, McpBackgroundMode.inactive);
      expect(calls.last.method, 'stop');
      expect(calls.last.arguments['leaseId'], args['leaseId']);
    },
  );

  test(
    'notification Stop revokes the running service; stale leases are ignored',
    () async {
      target.startListening();
      await settle();
      final lease = calls.single.arguments['leaseId'] as String;

      await fromNative('revoked', {
        'leaseId': 'lease-stale-000000000',
        'reason': 'user_stop',
      });
      expect(target.running, isTrue);
      expect(target.stops, 0);

      await fromNative('revoked', {'leaseId': lease, 'reason': 'user_stop'});
      expect(target.running, isFalse);
      expect(target.stops, 1);
      expect(lifecycle.mode, McpBackgroundMode.inactive);
      expect(lifecycle.lastRevocation, 'user_stop');
      // Native already ended the lease; no redundant stop round-trip needed.
      expect(calls.map((c) => c.method), ['start']);
    },
  );

  test('task removal and unknown native reasons revoke as well', () async {
    target.startListening();
    await settle();
    await fromNative('revoked', {
      'leaseId': calls.last.arguments['leaseId'],
      'reason': 'task_removed',
    });
    expect(target.running, isFalse);
    expect(lifecycle.lastRevocation, 'task_removed');

    target.startListening();
    await settle();
    expect(lifecycle.lastRevocation, isNull);
    await fromNative('revoked', {
      'leaseId': calls.last.arguments['leaseId'],
      'reason': '<script>',
    });
    expect(target.running, isFalse);
    expect(lifecycle.lastRevocation, 'unknown');
  });

  test(
    'protected service survives backgrounding; engine detach revokes',
    () async {
      target.startListening();
      await settle();
      lifecycleState(AppLifecycleState.inactive);
      lifecycleState(AppLifecycleState.hidden);
      lifecycleState(AppLifecycleState.paused);
      await settle();
      expect(target.running, isTrue);
      expect(lifecycle.mode, McpBackgroundMode.protected);

      lifecycleState(AppLifecycleState.detached);
      await settle();
      expect(target.running, isFalse);
      expect(lifecycle.lastRevocation, 'detached');
      expect(calls.last.method, 'stop');
    },
  );

  test(
    'without a foreground service the token is revoked when hidden',
    () async {
      native = (call) async {
        if (call.method == 'start') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      };
      target.startListening();
      await settle();
      expect(lifecycle.mode, McpBackgroundMode.foregroundOnly);
      expect(target.running, isTrue);
      // Transient overlays (permission dialog, shade) are not backgrounding.
      lifecycleState(AppLifecycleState.inactive);
      await settle();
      expect(target.running, isTrue);

      lifecycleState(AppLifecycleState.hidden);
      await settle();
      expect(target.running, isFalse);
      expect(lifecycle.lastRevocation, 'background_unprotected');
    },
  );

  test('inactive grant (service refused) is foreground-only too', () async {
    native = (call) async => call.method == 'start'
        ? {'active': false, 'notifications': false}
        : null;
    target.startListening();
    await settle();
    expect(lifecycle.mode, McpBackgroundMode.foregroundOnly);
    // A refused or late native start is explicitly released.
    expect(calls.map((c) => c.method), ['start', 'stop']);
    lifecycleState(AppLifecycleState.paused);
    await settle();
    expect(target.running, isFalse);
  });

  test('backgrounded while starting and then refused revokes', () async {
    final ack = Completer<Object?>();
    native = (call) async => call.method == 'start' ? ack.future : null;
    target.startListening();
    await settle();
    lifecycleState(AppLifecycleState.hidden);
    await settle();
    expect(target.running, isTrue, reason: 'decision waits for native answer');
    ack.complete({'active': false, 'notifications': false});
    await settle();
    expect(target.running, isFalse);
    expect(lifecycle.lastRevocation, 'background_unprotected');
  });

  test('stopping before the native ACK tears down the late service', () async {
    final ack = Completer<Object?>();
    native = (call) async => call.method == 'start' ? ack.future : null;
    target.startListening();
    await settle();
    final lease = calls.single.arguments['leaseId'];
    await target.stop();
    await settle();
    ack.complete({'active': true, 'notifications': true});
    await settle();
    expect(lifecycle.mode, McpBackgroundMode.inactive);
    final stops = calls.where((c) => c.method == 'stop').toList();
    expect(stops, isNotEmpty);
    expect(stops.every((c) => c.arguments['leaseId'] == lease), isTrue);
  });

  test('restart on another port replaces the lease', () async {
    target.startListening(8765);
    await settle();
    final first = calls.first.arguments['leaseId'];
    await target.stop();
    target.startListening(9876);
    await settle();
    expect(calls.map((c) => c.method), ['start', 'stop', 'start']);
    expect(calls[1].arguments['leaseId'], first);
    expect(calls[2].arguments['leaseId'], isNot(first));
    expect(calls[2].arguments['port'], 9876);
    expect(lifecycle.mode, McpBackgroundMode.protected);
  });

  test(
    'notification permission answer updates visibility for current lease',
    () async {
      native = (call) async => call.method == 'start'
          ? {'active': true, 'notifications': false}
          : null;
      target.startListening();
      await settle();
      expect(lifecycle.notificationsVisible, isFalse);
      await fromNative('notifications', {
        'leaseId': calls.single.arguments['leaseId'],
        'visible': true,
      });
      expect(lifecycle.notificationsVisible, isTrue);
    },
  );

  test(
    'disabled platform channel never claims background protection',
    () async {
      final off = McpForegroundChannel(channel: methodChannel, enabled: false);
      final t = _Target();
      final l = McpListenerLifecycle(
        target: t,
        channel: off,
        binding: binding,
        newLeaseId: nextLease,
      );
      addTearDown(l.dispose);
      t.startListening();
      await settle();
      expect(l.mode, McpBackgroundMode.foregroundOnly);
      expect(calls, isEmpty);
      lifecycleState(AppLifecycleState.paused);
      await settle();
      expect(t.running, isFalse);
    },
  );

  test(
    'channel validates lease IDs and ports before reaching native',
    () async {
      await expectLater(
        channel.start(leaseId: 'short', port: 8765),
        throwsArgumentError,
      );
      await expectLater(
        channel.start(leaseId: 'lease-000000000000x', port: 0),
        throwsRangeError,
      );
      expect(calls, isEmpty);
      final long = McpForegroundText(title: 'T' * 400).toArguments(1);
      expect(long['title']!.length, McpForegroundText.maxLength);
    },
  );

  test(
    'real McpService: native revoke closes the listener and its token',
    () async {
      final service = McpService()
        ..attach(
          McpWorkspace(
            scope: () => 'fixture:lifecycle',
            describe: () => {'mode': 'fixture'},
            hosts: () => const <HostRecord>[],
            sessions: () => const <McpSession>[],
            connect: (_) async {},
            openConsole: () async {},
          ),
        );
      final l = McpListenerLifecycle(
        target: McpServiceLifecycleTarget(service),
        channel: channel,
        binding: binding,
        newLeaseId: nextLease,
      );
      try {
        await service.start(port: 0);
        await settle();
        expect(l.mode, McpBackgroundMode.protected);
        final endpoint = service.endpoint!;
        final auth =
            (jsonDecode(
                  service.connectionConfiguration(),
                ) as Map)['mcpServers']['atermius']['headers']['Authorization']
                as String;
        // Raw socket: TestWidgetsFlutterBinding mocks HttpClient (always 400).
        Future<int> post() async {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            endpoint.port,
          );
          const body =
              '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}';
          socket.write(
            'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:${endpoint.port}\r\n'
            'Authorization: $auth\r\nContent-Type: application/json\r\n'
            'Accept: application/json, text/event-stream\r\n'
            'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n$body',
          );
          await socket.flush();
          final text = await utf8.decoder.bind(socket).join();
          socket.destroy();
          return int.parse(text.split(' ')[1]);
        }

        expect(await post(), 200);
        final lease = calls.firstWhere((c) => c.method == 'start');
        expect(lease.arguments['port'], endpoint.port);
        await fromNative('revoked', {
          'leaseId': lease.arguments['leaseId'],
          'reason': 'user_stop',
        });
        expect(service.running, isFalse);
        expect(l.lastRevocation, 'user_stop');
        await expectLater(post(), throwsA(isA<SocketException>()));
      } finally {
        l.dispose();
        await service.stop();
        service.dispose();
      }
    },
  );
}
