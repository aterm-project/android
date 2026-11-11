import 'mcp_listener_stub.dart'
    if (dart.library.io) 'mcp_listener_io.dart'
    as platform;
import 'mcp_listener_contract.dart';
export 'mcp_listener_contract.dart';

/// Desktop and Android listen on IPv4 loopback only. Android additionally
/// requires the MCP foreground lifecycle (see `platform/mcp_foreground.dart`)
/// so a backgrounded process never keeps a frozen, still-valid token.
bool get mcpListenerSupported => platform.supported;
Future<McpListener> startMcpListener({
  required int port,
  required String token,
  required McpRequestHandler handler,
}) => platform.start(port: port, token: token, handler: handler);
