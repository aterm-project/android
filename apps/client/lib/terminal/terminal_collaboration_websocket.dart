import 'package:web_socket_channel/web_socket_channel.dart';

import 'terminal_collaboration_websocket_stub.dart'
    if (dart.library.js_interop) 'terminal_collaboration_websocket_web.dart'
    as platform;

/// Creates a browser-backed channel on Web so its transport buffer is
/// observable. Native builds continue to use the package's default channel.
WebSocketChannel createTerminalCollaborationWebSocketChannel(Uri uri) =>
    platform.createTerminalCollaborationWebSocketChannel(uri);

/// Returns the browser WebSocket's queued outbound byte count, or null when
/// the platform channel does not expose that value.
int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    platform.terminalCollaborationWebSocketBufferedAmount(channel);
