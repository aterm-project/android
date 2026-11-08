import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel createTerminalCollaborationWebSocketChannel(Uri uri) =>
    HtmlWebSocketChannel.connect(uri);

int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    channel is HtmlWebSocketChannel ? channel.bufferedAmount : null;
