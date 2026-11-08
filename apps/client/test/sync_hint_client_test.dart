import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/sync/sync_hint_client.dart';
import 'package:aterm_client/sync/sync_hint_socket.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
final _scope = SyncHintScope(
  serverSpaceId: 'space-a',
  accountId: 'account-a',
  deviceId: 'device-a',
  vaultId: _vaultA,
  websocketUri: Uri(
    scheme: 'wss',
    host: 'example.test',
    path: '/api/v1/notifications',
  ),
  origin: 'https://example.test',
);

void main() {
  test(
    'authenticates in the first frame and only dispatches valid active-vault hints',
    () async {
      final socket = _FakeSyncHintSocket();
      final connected = Completer<void>();
      final hints = <SyncHint>[];
      final client = SyncHintClient(
        fetchTicket: () async => 'A' * 43,
        onHint: (hint) async => hints.add(hint),
        refreshSession: () async => true,
        connect: (uri, {required origin}) async {
          expect(uri, _scope.websocketUri);
          expect(origin, _scope.origin);
          connected.complete();
          return socket;
        },
        retryDelay: (_) => const Duration(hours: 1),
      );

      client.start(_scope);
      await connected.future;
      await _flushMicrotasks();
      expect(socket.sent, hasLength(1));
      expect(jsonDecode(socket.sent.single), {
        'type': 'authenticate',
        'ticket': 'A' * 43,
      });

      socket.push(
        jsonEncode({
          'type': 'ready',
          'server_generation': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'sync_required': true,
          'heartbeat_seconds': 30,
          'poll_interval_seconds': 2,
        }),
      );
      socket.push(
        '{"type":"ready","server_generation":"broken","sync_required":true}',
      );
      socket.push('not-json');
      socket.push('{"type":"sync_required","vault_id":7,"commit_seq":"4"}');
      socket.push(
        jsonEncode({
          'type': 'sync_required',
          'vault_id': _vaultB,
          'commit_seq': '4',
        }),
      );
      socket.push(
        jsonEncode({
          'type': 'sync_required',
          'vault_id': _vaultA,
          'commit_seq': '19',
        }),
      );
      socket.push(
        jsonEncode({
          'type': 'sync_required',
          'vault_id': _vaultA,
          'conflict_seq': '900719925474099312345',
        }),
      );
      socket.push(
        jsonEncode({
          'type': 'sync_required',
          'vault_id': _vaultA,
          'commit_seq': '20',
          'conflict_seq': '21',
        }),
      );
      socket.push(
        jsonEncode({
          'type': 'sync_required',
          'vault_id': _vaultA,
          'conflict_seq': 22,
        }),
      );
      await _flushMicrotasks();

      expect(hints, hasLength(3));
      expect(
        hints.first.vaultId,
        _vaultA,
      ); // ready always pulls the active vault
      expect(hints.last.vaultId, _vaultA);
      expect(hints.any((hint) => hint.membershipChanged), isFalse);
      client.stop();
    },
  );

  test(
    'membership-set hint dispatches a vault refresh and sync hint',
    () async {
      final socket = _FakeSyncHintSocket();
      final connected = Completer<void>();
      final hints = <SyncHint>[];
      final client = SyncHintClient(
        fetchTicket: () async => 'B' * 43,
        onHint: (hint) async => hints.add(hint),
        refreshSession: () async => true,
        connect: (_, {required origin}) async {
          connected.complete();
          return socket;
        },
        retryDelay: (_) => const Duration(hours: 1),
      );
      client.start(_scope);
      await connected.future;
      await _flushMicrotasks();
      socket.push('{"type":"sync_required","vault_id":null,"commit_seq":null}');
      await _flushMicrotasks();
      expect(hints, hasLength(1));
      expect(hints.single.membershipChanged, isTrue);
      expect(hints.single.vaultId, isNull);
      client.stop();
    },
  );

  test(
    'retries transient close with a fresh ticket and stop cancels reconnect',
    () async {
      final first = _FakeSyncHintSocket();
      final second = _FakeSyncHintSocket();
      final secondConnected = Completer<void>();
      var ticketCount = 0;
      var connectCount = 0;
      final client = SyncHintClient(
        fetchTicket: () async => String.fromCharCode(65 + ticketCount++) * 43,
        onHint: (_) async {},
        refreshSession: () async => true,
        connect: (_, {required origin}) async {
          connectCount++;
          if (connectCount == 1) return first;
          secondConnected.complete();
          return second;
        },
        retryDelay: (_) => Duration.zero,
      );

      client.start(_scope);
      await _waitUntil(() => first.sent.isNotEmpty);
      first.serverClose(1011);
      await secondConnected.future.timeout(const Duration(seconds: 2));
      await _waitUntil(() => second.sent.isNotEmpty);
      expect(ticketCount, 2);
      expect(jsonDecode(first.sent.single)['ticket'], 'A' * 43);
      expect(jsonDecode(second.sent.single)['ticket'], 'B' * 43);

      client.stop();
      await _flushMicrotasks();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connectCount, 2);
      expect(ticketCount, 2);
    },
  );

  test('4001 refreshes the session before obtaining a fresh ticket', () async {
    final first = _FakeSyncHintSocket();
    final second = _FakeSyncHintSocket();
    final secondConnected = Completer<void>();
    var refreshes = 0;
    var tickets = 0;
    var connections = 0;
    final client = SyncHintClient(
      fetchTicket: () async => String.fromCharCode(65 + tickets++) * 43,
      onHint: (_) async {},
      refreshSession: () async {
        refreshes++;
        return true;
      },
      connect: (_, {required origin}) async {
        if (++connections == 1) return first;
        secondConnected.complete();
        return second;
      },
      retryDelay: (_) => Duration.zero,
    );
    client.start(_scope);
    await _waitUntil(() => first.sent.isNotEmpty);
    first.serverClose(4001);
    await secondConnected.future.timeout(const Duration(seconds: 2));
    await _waitUntil(() => second.sent.isNotEmpty);
    expect(refreshes, 1);
    expect(tickets, 2);
    client.stop();
  });

  test('1008 policy close stops without retry', () async {
    final socket = _FakeSyncHintSocket();
    var tickets = 0;
    var connections = 0;
    final client = SyncHintClient(
      fetchTicket: () async {
        tickets++;
        return 'C' * 43;
      },
      onHint: (_) async {},
      refreshSession: () async => true,
      connect: (_, {required origin}) async {
        connections++;
        return socket;
      },
      retryDelay: (_) => Duration.zero,
    );
    client.start(_scope);
    await _waitUntil(() => socket.sent.isNotEmpty);
    socket.serverClose(1008);
    await _waitUntil(() => !client.isRunning);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connections, 1);
    expect(tickets, 1);
  });

  test(
    '4008 cap close waits with backoff and retries a fresh ticket',
    () async {
      final first = _FakeSyncHintSocket();
      final second = _FakeSyncHintSocket();
      final secondConnected = Completer<void>();
      var tickets = 0;
      var connections = 0;
      final client = SyncHintClient(
        fetchTicket: () async => String.fromCharCode(68 + tickets++) * 43,
        onHint: (_) async {},
        refreshSession: () async => true,
        connect: (_, {required origin}) async {
          if (++connections == 1) return first;
          secondConnected.complete();
          return second;
        },
        retryDelay: (_) => Duration.zero,
      );
      client.start(_scope);
      await _waitUntil(() => first.sent.isNotEmpty);
      first.serverClose(4008);
      await secondConnected.future.timeout(const Duration(seconds: 2));
      await _waitUntil(() => second.sent.isNotEmpty);
      expect(connections, 2);
      expect(tickets, 2);
      client.stop();
    },
  );

  test('1000 normal close stops without reconnect', () async {
    final socket = _FakeSyncHintSocket();
    var connections = 0;
    final client = SyncHintClient(
      fetchTicket: () async => 'E' * 43,
      onHint: (_) async {},
      refreshSession: () async => true,
      connect: (_, {required origin}) async {
        connections++;
        return socket;
      },
      retryDelay: (_) => Duration.zero,
    );
    client.start(_scope);
    await _waitUntil(() => socket.sent.isNotEmpty);
    socket.serverClose(1000);
    await _waitUntil(() => !client.isRunning);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connections, 1);
  });

  test('NOTIFICATIONS_BUSY handshake retries; ORIGIN_DENIED stops', () async {
    final socket = _FakeSyncHintSocket();
    var busyConnects = 0;
    final busyClient = SyncHintClient(
      fetchTicket: () async => 'F' * 43,
      onHint: (_) async {},
      refreshSession: () async => true,
      connect: (_, {required origin}) async {
        if (++busyConnects == 1) {
          throw const SyncHintHandshakeException(503, 'NOTIFICATIONS_BUSY');
        }
        return socket;
      },
      retryDelay: (_) => Duration.zero,
    );
    busyClient.start(_scope);
    await _waitUntil(() => socket.sent.isNotEmpty);
    expect(busyConnects, 2);
    busyClient.stop();

    var deniedConnects = 0;
    final deniedClient = SyncHintClient(
      fetchTicket: () async => 'G' * 43,
      onHint: (_) async {},
      refreshSession: () async => true,
      connect: (_, {required origin}) async {
        deniedConnects++;
        throw const SyncHintHandshakeException(403, 'ORIGIN_DENIED');
      },
      retryDelay: (_) => Duration.zero,
    );
    deniedClient.start(_scope);
    await _waitUntil(() => !deniedClient.isRunning);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(deniedConnects, 1);
  });

  test('changing the active-vault scope closes the old connection', () async {
    final first = _FakeSyncHintSocket();
    final second = _FakeSyncHintSocket();
    final secondConnected = Completer<void>();
    var connections = 0;
    final hints = <SyncHint>[];
    final client = SyncHintClient(
      fetchTicket: () async => 'H' * 43,
      onHint: (hint) async => hints.add(hint),
      refreshSession: () async => true,
      connect: (_, {required origin}) async {
        if (++connections == 1) return first;
        secondConnected.complete();
        return second;
      },
      retryDelay: (_) => const Duration(hours: 1),
    );
    client.start(_scope);
    await _waitUntil(() => first.sent.isNotEmpty);
    final nextScope = SyncHintScope(
      serverSpaceId: _scope.serverSpaceId,
      accountId: _scope.accountId,
      deviceId: _scope.deviceId,
      vaultId: _vaultB,
      websocketUri: _scope.websocketUri,
      origin: _scope.origin,
    );
    client.start(nextScope);
    await secondConnected.future;
    await _waitUntil(() => second.sent.isNotEmpty);
    expect(first.closeCode, 1000);
    expect(client.scope?.vaultId, _vaultB);
    second.push(
      jsonEncode({
        'type': 'sync_required',
        'vault_id': _vaultA,
        'commit_seq': '1',
      }),
    );
    second.push(
      jsonEncode({
        'type': 'sync_required',
        'vault_id': _vaultB,
        'commit_seq': '2',
      }),
    );
    await _flushMicrotasks();
    expect(hints, hasLength(1));
    expect(hints.single.vaultId, _vaultB);
    client.stop();
  });
}

class _FakeSyncHintSocket implements SyncHintSocket {
  final StreamController<Object?> _controller =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = [];
  int? _closeCode;

  @override
  Future<void> get ready async {}

  @override
  Stream<Object?> get stream => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String text) => sent.add(text);

  void push(Object? value) => _controller.add(value);

  void serverClose(int code) {
    _closeCode = code;
    unawaited(_controller.close());
  }

  @override
  Future<void> close() async {
    _closeCode ??= 1000;
    if (!_controller.isClosed) await _controller.close();
  }
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue, reason: 'Condition did not become true');
}
