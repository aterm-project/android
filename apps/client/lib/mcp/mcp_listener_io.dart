import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'mcp_listener_contract.dart';
import 'mcp_protocol.dart';

/// Platforms with a supported local listener. iOS and other targets have no
/// background execution model compatible with a local MCP server.
@visibleForTesting
bool mcpListenerPlatformSupported(String operatingSystem) =>
    const {'windows', 'linux', 'macos', 'android'}.contains(operatingSystem);

bool get supported => mcpListenerPlatformSupported(Platform.operatingSystem);

const _maxRequestBytes = 512 * 1024;
const _maxActiveRequests = 4;

/// Upper bound on simultaneously open HTTP connections, authenticated or not.
/// On Android every installed app may reach 127.0.0.1, so unauthenticated
/// peers must not be able to hold an unbounded number of sockets.
const _maxOpenConnections = 16;
const _minTokenLength = 32;

Future<McpListener> start({
  required int port,
  required String token,
  required McpRequestHandler handler,
}) async {
  if (!supported) throw UnsupportedError('MCP listener is unavailable.');
  return bindMcpLoopbackListener(port: port, token: token, handler: handler);
}

/// Binds the authenticated listener on IPv4 loopback. Exposed for transport
/// tests so the platform gate above stays the only production entry point.
@visibleForTesting
Future<McpListener> bindMcpLoopbackListener({
  required int port,
  required String token,
  required McpRequestHandler handler,
  Duration bodyTimeout = const Duration(seconds: 10),
}) async {
  if (token.length < _minTokenLength ||
      token.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
    throw ArgumentError('MCP token is too short or malformed.');
  }
  if (port < 0 || port > 65535) throw RangeError.range(port, 0, 65535, 'port');
  // Never bind a wildcard or external address: forwarding (ADB/SSH) must
  // terminate on the device's loopback interface.
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    port,
    shared: false,
  );
  server.idleTimeout = const Duration(seconds: 15);
  server.autoCompress = false;
  return _Listener(server, token, handler, bodyTimeout);
}

class _Listener implements McpObservableListener {
  _Listener(this.server, this.token, this.handler, this.bodyTimeout) {
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object _) {},
      // The socket can be closed underneath us (process teardown, network
      // stack reset). Report it so the owner revokes the bound token.
      onDone: _markClosed,
      cancelOnError: false,
    );
  }
  final HttpServer server;
  final String token;
  final McpRequestHandler handler;
  final Duration bodyTimeout;
  final _done = Completer<void>();
  int _active = 0;
  bool _closed = false;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}/mcp');

  @override
  Future<void> get done => _done.future;

  @override
  bool get closed => _closed;

  void _markClosed() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    _closed = true;
    try {
      await server.close(force: true);
    } finally {
      _markClosed();
    }
  }

  bool _authorized(String? header) {
    final expected = 'Bearer $token';
    if (header == null || header.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
    }
    return diff == 0;
  }

  bool _allowedHost(String? host) =>
      host == '127.0.0.1:${server.port}' || host == 'localhost:${server.port}';

  bool _allowedOrigin(String? origin) =>
      origin == null ||
      origin == 'http://127.0.0.1:${server.port}' ||
      origin == 'http://localhost:${server.port}';

  Future<void> _serve(HttpRequest request) async {
    var counted = false;
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      final host = request.headers.value('host');
      final origin = request.headers.value('origin');
      if (_closed || request.uri.path != '/mcp' || request.uri.hasQuery) {
        request.response.statusCode = 404;
      } else if (!_allowedHost(host) || !_allowedOrigin(origin)) {
        // DNS rebinding and browser pages are rejected before credentials
        // are examined.
        request.response.statusCode = 403;
      } else if (server.connectionsInfo().total > _maxOpenConnections) {
        request.response.statusCode = 503;
        request.response.headers.set('Retry-After', '1');
      } else if (!_authorized(request.headers.value('authorization'))) {
        request.response.statusCode = 401;
        request.response.headers.set(
          'WWW-Authenticate',
          'Bearer realm="Atermius MCP"',
        );
      } else if (request.method != 'POST') {
        request.response.statusCode = 405;
        request.response.headers.set('Allow', 'POST');
      } else if (request.headers.contentType?.mimeType != 'application/json') {
        request.response.statusCode = 415;
      } else if (!(request.headers.value('accept') ?? '').contains(
            'application/json',
          ) ||
          !(request.headers.value('accept') ?? '').contains(
            'text/event-stream',
          )) {
        request.response.statusCode = 406;
      } else if (_active >= _maxActiveRequests) {
        request.response.statusCode = 429;
      } else if (request.contentLength > _maxRequestBytes) {
        request.response.statusCode = 413;
      } else {
        _active++;
        counted = true;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in request.timeout(bodyTimeout)) {
          if (bytes.length + chunk.length > _maxRequestBytes) {
            throw const _BodyTooLarge();
          }
          bytes.add(chunk);
        }
        Object? body;
        try {
          body = jsonDecode(utf8.decode(bytes.takeBytes()));
        } on FormatException {
          await _write(
            request,
            const McpReply(400, {
              'jsonrpc': '2.0',
              'id': null,
              'error': {'code': -32700, 'message': 'Invalid JSON.'},
            }),
          );
          return;
        }
        final headers = <String, String>{};
        for (final name in ['mcp-protocol-version', 'mcp-method', 'mcp-name']) {
          final value = request.headers.value(name);
          if (value != null) headers[name] = value;
        }
        final reply = await handler(body, headers: headers);
        if (_closed) {
          // Revoked while the tool ran: the connection was force-closed and
          // the result must not be delivered under a revoked token.
          try {
            request.response.statusCode = 503;
            request.response.persistentConnection = false;
            await request.response.close();
          } catch (_) {}
          return;
        }
        await _write(request, reply);
        return;
      }
      request.response.persistentConnection = false;
      // Consume a bounded rejected body so HTTP clients can receive the status
      // without a TCP reset while their request body is still being written.
      var rejectedBytes = 0;
      try {
        await for (final chunk in request.timeout(const Duration(seconds: 2))) {
          rejectedBytes += chunk.length;
          if (rejectedBytes > _maxRequestBytes) break;
        }
      } catch (_) {}
      await request.response.close();
    } on _BodyTooLarge {
      request.response.statusCode = 413;
      request.response.persistentConnection = false;
      await request.response.close();
    } on TimeoutException {
      request.response.statusCode = 408;
      request.response.persistentConnection = false;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = 400;
        request.response.persistentConnection = false;
        await request.response.close();
      } catch (_) {}
    } finally {
      if (counted) _active--;
    }
  }

  Future<void> _write(HttpRequest request, McpReply reply) async {
    request.response.statusCode = reply.status;
    if (reply.body != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply.body));
    }
    await request.response.close();
  }
}

class _BodyTooLarge {
  const _BodyTooLarge();
}
