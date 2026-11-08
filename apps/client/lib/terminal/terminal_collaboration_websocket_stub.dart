import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel createTerminalCollaborationWebSocketChannel(Uri uri) =>
    WebSocketChannel.connect(uri);

int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    null;
