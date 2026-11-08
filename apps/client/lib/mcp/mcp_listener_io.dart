import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mcp_listener_contract.dart';
import 'mcp_protocol.dart';

bool get supported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
const _maxRequestBytes = 512 * 1024;

Future<McpListener> start({
  required int port,
  required String token,
  required McpRequestHandler handler,
}) async {
  if (!supported) throw UnsupportedError('Desktop MCP listener required.');
  if (token.length < 32) throw ArgumentError('MCP token is too short.');
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    port,
    shared: false,
  );
  server.idleTimeout = const Duration(seconds: 15);
  return _Listener(server, token, handler);
}

class _Listener implements McpListener {
  _Listener(this.server, this.token, this.handler) {
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object _) {},
    );
  }
  final HttpServer server;
  final String token;
  final McpRequestHandler handler;
  int _active = 0;
  bool _closed = false;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}/mcp');
  @override
  Future<void> close() async {
    _closed = true;
    await server.close(force: true);
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

  Future<void> _serve(HttpRequest request) async {
    var counted = false;
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      final host = request.headers.value('host');
      final origin = request.headers.value('origin');
      if (_closed || request.uri.path != '/mcp' || request.uri.hasQuery) {
        request.response.statusCode = 404;
      } else if (host != '127.0.0.1:${server.port}' &&
              host != 'localhost:${server.port}' ||
          origin != null &&
              origin != 'http://127.0.0.1:${server.port}' &&
              origin != 'http://localhost:${server.port}') {
        request.response.statusCode = 403;
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
      } else if (_active >= 4) {
        request.response.statusCode = 429;
      } else if (request.contentLength > _maxRequestBytes) {
        request.response.statusCode = 413;
      } else {
        _active++;
        counted = true;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in request.timeout(
          const Duration(seconds: 10),
        )) {
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
        await _write(request, await handler(body, headers: headers));
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
