import 'mcp_protocol.dart';

typedef McpRequestHandler = Future<McpReply> Function(
  Object? body, {
  Map<String, String> headers,
});

abstract interface class McpListener {
  Uri get endpoint;
  Future<void> close();
}
