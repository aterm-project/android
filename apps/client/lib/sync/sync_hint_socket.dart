import 'package:web_socket_channel/web_socket_channel.dart';

/// Small adapter seam for the sync-hint protocol. Keeping the channel behind
/// this interface makes reconnect, close-code, and malformed-frame behavior
/// testable without an HTTP or WebSocket server.
abstract interface class SyncHintSocket {
  Future<void> get ready;
  Stream<Object?> get stream;
  int? get closeCode;
  void sendText(String text);
  Future<void> close();
}

typedef SyncHintSocketFactory =
    Future<SyncHintSocket> Function(Uri uri, {required String origin});

/// Optional transport error detail for platforms which expose the HTTP
/// WebSocket handshake response. Browser WebSocket APIs intentionally hide
/// that response, so browser clients can only classify application frames,
/// close codes, and network errors.
class SyncHintHandshakeException implements Exception {
  const SyncHintHandshakeException(this.statusCode, this.code);

  final int statusCode;
  final String code;
}

class WebSocketChannelSyncHintSocket implements SyncHintSocket {
  WebSocketChannelSyncHintSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void sendText(String text) => _channel.sink.add(text);

  @override
  Future<void> close() => _channel.sink.close(1000, 'client stopped');
}
