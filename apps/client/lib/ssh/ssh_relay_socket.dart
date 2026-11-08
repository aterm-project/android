import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<SSHSocket> connectRelaySocket(
  Uri relayUri,
  String singleUseTicket, {
  @visibleForTesting WebSocketChannel Function(Uri)? channelFactory,
  @visibleForTesting Duration timeout = const Duration(seconds: 15),
}) async {
  _validateRelayUri(relayUri);
  _validateTicket(singleUseTicket);

  final channel = (channelFactory ?? WebSocketChannel.connect)(relayUri);
  try {
    await channel.ready.timeout(timeout);
    // The ticket is sent in the first frame, never in the URL or a
    // subprotocol, so proxies and browser history cannot retain it. Following
    // frames carry opaque SSH bytes.
    channel.sink.add(singleUseTicket);
    return _WebSocketSshSocket(channel);
  } catch (_) {
    await _closeChannel(channel, code: 1000, reason: 'SSH relay setup failed');
    rethrow;
  }
}

void _validateRelayUri(Uri uri) {
  final path = uri.pathSegments;
  final isRelayPath =
      path.length >= 3 &&
      path.sublist(path.length - 3).join('/') == 'relay/v1/connect';
  final isSecure = uri.scheme == 'wss';
  final isLocalDevelopment =
      uri.scheme == 'ws' &&
      const {
        'localhost',
        '127.0.0.1',
        '::1',
        '[::1]',
      }.contains(uri.host.toLowerCase());
  if (uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !isRelayPath ||
      (!isSecure && !isLocalDevelopment)) {
    throw const FormatException('Invalid or insecure SSH relay endpoint.');
  }
}

void _validateTicket(String ticket) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(ticket)) {
    throw const FormatException('Invalid SSH relay ticket.');
  }
  Uint8List? bytes;
  try {
    bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(ticket)));
    if (bytes.length != 32 ||
        base64Url.encode(bytes).replaceAll('=', '') != ticket) {
      throw const FormatException('Invalid SSH relay ticket.');
    }
  } on FormatException {
    throw const FormatException('Invalid SSH relay ticket.');
  } finally {
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }
}

Future<void> _closeChannel(
  WebSocketChannel channel, {
  required int code,
  required String reason,
}) async {
  try {
    await channel.sink.close(code, reason).timeout(const Duration(seconds: 2));
  } catch (_) {
    // The socket may already be disconnected. Cleanup is best effort and must
    // not replace the handshake/protocol error that caused it.
  }
}

class _WebSocketSshSocket implements SSHSocket {
  _WebSocketSshSocket(this._channel) {
    _incomingSubscription = _channel.stream.listen(
      (event) {
        if (event is List<int>) {
          _incoming.add(Uint8List.fromList(event));
        } else {
          _fail(const FormatException('Unexpected text frame from SSH relay'));
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _fail(error, stackTrace),
      onDone: () {
        unawaited(_finishFromRemote());
      },
      cancelOnError: false,
    );
    _outgoingSubscription = _outgoing.stream.listen(
      (bytes) {
        if (_closed) return;
        try {
          _channel.sink.add(Uint8List.fromList(bytes));
        } catch (error, stackTrace) {
          _fail(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _fail(error, stackTrace),
      onDone: () {
        if (!_closed) {
          unawaited(_closeChannel(_channel, code: 1000, reason: 'SSH closed'));
        }
      },
    );
  }

  final WebSocketChannel _channel;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<dynamic> _incomingSubscription;
  late final StreamSubscription<List<int>> _outgoingSubscription;
  bool _closed = false;

  @override
  Future<void> get done => _done.future;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  Future<void> close() async {
    await _shutdown(code: 1000, reason: 'SSH client closed');
  }

  @override
  void destroy() {
    unawaited(_shutdown(code: 1000, reason: 'SSH transport destroyed'));
  }

  @override
  Future<void> flush() async => _channel.ready;

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    if (!_incoming.isClosed) {
      _incoming.addError(error, stackTrace ?? StackTrace.current);
    }
    unawaited(_shutdown(code: 1002, reason: 'Invalid SSH relay stream'));
  }

  Future<void> _finishFromRemote() async {
    if (_closed) return;
    _closed = true;
    await _outgoingSubscription.cancel();
    if (!_outgoing.isClosed) unawaited(_outgoing.close());
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> _shutdown({required int code, required String reason}) async {
    if (_closed) return;
    _closed = true;
    await _incomingSubscription.cancel();
    await _outgoingSubscription.cancel();
    // A StreamController.close future waits for its listener to consume a done
    // event. SSH may close before either side subscribes, so don't make socket
    // cleanup depend on those controller futures.
    if (!_outgoing.isClosed) unawaited(_outgoing.close());
    if (!_incoming.isClosed) unawaited(_incoming.close());
    await _closeChannel(_channel, code: code, reason: reason);
    if (!_done.isCompleted) _done.complete();
  }
}
