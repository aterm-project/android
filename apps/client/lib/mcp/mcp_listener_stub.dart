import 'mcp_listener_contract.dart';

const supported = false;
Future<McpListener> start({
  required int port,
  required String token,
  required McpRequestHandler handler,
}) => throw UnsupportedError(
  'MCP local listening is unavailable on this platform.',
);
