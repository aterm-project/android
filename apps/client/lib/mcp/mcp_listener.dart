import 'mcp_listener_stub.dart'
    if (dart.library.io) 'mcp_listener_io.dart'
    as platform;
import 'mcp_listener_contract.dart';
export 'mcp_listener_contract.dart';

bool get mcpListenerSupported => platform.supported;
Future<McpListener> startMcpListener({
  required int port,
  required String token,
  required McpRequestHandler handler,
}) => platform.start(port: port, token: token, handler: handler);
