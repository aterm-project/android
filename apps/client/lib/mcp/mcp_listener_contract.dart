import 'mcp_protocol.dart';

typedef McpRequestHandler = Future<McpReply> Function(
  Object? body, {
  Map<String, String> headers,
});

abstract interface class McpListener {
  Uri get endpoint;
  Future<void> close();
}

/// Optional listener capability, kept separate so existing [McpListener]
/// implementations (including test fakes) remain source compatible.
///
/// [done] completes exactly once when the listener stops accepting requests,
/// whether through [McpListener.close] or because the platform closed the
/// socket (for example when Android tears the process' sockets down). Owners
/// must treat completion as revocation of the token bound to this listener.
abstract interface class McpObservableListener implements McpListener {
  Future<void> get done;
  bool get closed;
}
