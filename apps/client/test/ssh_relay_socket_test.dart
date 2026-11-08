import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/ssh/ssh_relay_socket.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  const ticket = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  final relay = Uri.parse('wss://relay.example.test/tenant/relay/v1/connect');

  test(
    'sends ticket only as first text frame and relays opaque bytes',
    () async {
      final channel = _FakeWebSocketChannel();
      Uri? requestedUri;
      final socket = await connectRelaySocket(
        relay,
        ticket,
        channelFactory: (uri) {
          requestedUri = uri;
          return channel;
        },
      );

      expect(requestedUri, relay);
      expect(channel.sink.sent, [ticket]);
      expect(channel.sink.closeCode, isNull);

      final incoming = socket.stream.first;
      channel.incoming.add(Uint8List.fromList([0, 255, 7]));
      expect(await incoming, Uint8List.fromList([0, 255, 7]));

      socket.sink.add([4, 5, 6]);
      await Future<void>.delayed(Duration.zero);
      expect(channel.sink.sent, [
        ticket,
        Uint8List.fromList([4, 5, 6]),
      ]);

      await socket.close();
      await socket.done;
      expect(channel.sink.closeCode, 1000);
    },
  );

  test(
    'SSHClient sends its identification and parses the server banner through relay',
    () async {
      final channel = _FakeWebSocketChannel();
      final socket = await connectRelaySocket(
        relay,
        ticket,
        channelFactory: (_) => channel,
      );
      final client = SSHClient(
        socket,
        username: 'test-user',
        handshakeTimeout: const Duration(seconds: 1),
      );

      channel.incoming.add(
        Uint8List.fromList(latin1.encode('SSH-2.0-TestServer_1.0\r\n')),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (client.remoteVersion == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(client.remoteVersion, 'SSH-2.0-TestServer_1.0');
      final binaryFrames = channel.sink.sent.whereType<Uint8List>().toList();
      expect(binaryFrames, isNotEmpty);
      expect(
        latin1.decode(binaryFrames.first),
        startsWith('SSH-2.0-DartSSH_2.0\r\n'),
      );

      await client.close();
      await socket.done;
    },
  );

  test('failed websocket handshake times out and closes the channel', () async {
    final channel = _FakeWebSocketChannel(completeReady: false);
    await expectLater(
      connectRelaySocket(
        relay,
        ticket,
        channelFactory: (_) => channel,
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(channel.sink.closeCode, 1000);
    expect(channel.sink.closeReason, contains('setup failed'));
  });

  test(
    'unexpected text frame reports protocol error and closes socket',
    () async {
      final channel = _FakeWebSocketChannel();
      final socket = await connectRelaySocket(
        relay,
        ticket,
        channelFactory: (_) => channel,
      );
      final received = socket.stream.first;

      channel.incoming.add('server text is not SSH data');

      await expectLater(received, throwsA(isA<FormatException>()));
      await socket.done;
      expect(channel.sink.closeCode, 1002);
      expect(channel.sink.closeReason, contains('Invalid SSH relay stream'));
    },
  );

  test(
    'websocket stream errors surface to SSH and release the channel',
    () async {
      final channel = _FakeWebSocketChannel();
      final socket = await connectRelaySocket(
        relay,
        ticket,
        channelFactory: (_) => channel,
      );
      final received = socket.stream.first;
      channel.incoming.addError(StateError('network reset'));

      await expectLater(received, throwsA(isA<StateError>()));
      await socket.done;
      expect(channel.sink.closeCode, 1002);
    },
  );

  test(
    'rejects insecure remote, wrong path, query, and malformed ticket before connect',
    () async {
      var connectAttempts = 0;
      WebSocketChannel factory(Uri _) {
        connectAttempts++;
        return _FakeWebSocketChannel();
      }

      Future<void> rejected(Uri uri, String value) async {
        await expectLater(
          connectRelaySocket(uri, value, channelFactory: factory),
          throwsFormatException,
        );
      }

      await rejected(
        Uri.parse('ws://relay.example.test/tenant/relay/v1/connect'),
        ticket,
      );
      await rejected(
        Uri.parse('wss://relay.example.test/tenant/other'),
        ticket,
      );
      await rejected(
        Uri.parse(
          'wss://relay.example.test/tenant/relay/v1/connect?ticket=$ticket',
        ),
        ticket,
      );
      await rejected(relay, 'not-a-ticket');
      expect(connectAttempts, 0);

      final localChannel = _FakeWebSocketChannel();
      final localSocket = await connectRelaySocket(
        Uri.parse('ws://localhost:8080/tenant/relay/v1/connect'),
        ticket,
        channelFactory: (_) => localChannel,
      );
      await localSocket.close();
    },
  );
}

class _FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeWebSocketChannel({bool completeReady = true}) {
    if (completeReady) readyCompleter.complete();
    sink = _FakeWebSocketSink(
      onClose: () async {
        if (!incoming.isClosed) await incoming.close();
      },
    );
  }

  final incoming = StreamController<dynamic>.broadcast();
  final readyCompleter = Completer<void>();
  @override
  late final _FakeWebSocketSink sink;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => sink.closeCode;

  @override
  String? get closeReason => sink.closeReason;
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink({required this.onClose});

  final Future<void> Function() onClose;
  final sent = <Object?>[];
  final _done = Completer<void>();
  int? closeCode;
  String? closeReason;

  @override
  Future<void> get done => _done.future;

  @override
  void add(data) => sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    throw error;
  }

  @override
  Future<void> addStream(Stream stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    closeReason ??= reason;
    if (!_done.isCompleted) {
      await onClose();
      _done.complete();
    }
  }
}
