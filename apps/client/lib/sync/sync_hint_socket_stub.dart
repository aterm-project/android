import 'package:web_socket_channel/web_socket_channel.dart';

import 'sync_hint_socket.dart';

Future<SyncHintSocket> connectSyncHintSocket(
  Uri uri, {
  required String origin,
}) async {
  // Browsers set Origin from the page URL and do not let JavaScript override
  // it. The server checks the exact configured public origin.
  return WebSocketChannelSyncHintSocket(WebSocketChannel.connect(uri));
}
