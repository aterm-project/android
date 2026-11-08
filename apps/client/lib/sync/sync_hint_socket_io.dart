import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'sync_hint_socket.dart';

Future<SyncHintSocket> connectSyncHintSocket(
  Uri uri, {
  required String origin,
}) async => _IoSyncHintSocket(
  IOWebSocketChannel.connect(uri, headers: {'Origin': origin}),
);

class _IoSyncHintSocket implements SyncHintSocket {
  _IoSyncHintSocket(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Future<void> get ready async {
    try {
      await _channel.ready;
    } on WebSocketChannelException catch (error) {
      final cause = error.inner;
      if (cause is WebSocketException && cause.httpStatusCode != null) {
        final statusCode = cause.httpStatusCode!;
        if (statusCode == 403) {
          throw SyncHintHandshakeException(statusCode, 'ORIGIN_DENIED');
        }
        if (statusCode == 503) {
          throw SyncHintHandshakeException(statusCode, 'NOTIFICATIONS_BUSY');
        }
      }
      rethrow;
    }
  }

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void sendText(String text) => _channel.sink.add(text);

  @override
  Future<void> close() => _channel.sink.close(1000, 'client stopped');
}
