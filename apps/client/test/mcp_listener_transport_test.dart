@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/mcp/mcp_listener_contract.dart';
import 'package:aterm_client/mcp/mcp_listener_io.dart' as io;
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'tok_0123456789abcdefghijklmnopqrstuvwxyzABCDEF';
const _rpc = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';

/// Minimal raw HTTP/1.1 exchange so header handling (Host, Origin,
/// Authorization, framing) is exercised exactly as an external client or a
/// hostile local app would send it, without HttpClient normalisation.
Future<({int status, Map<String, String> headers, String body})> _raw(
  int port,
  String head, {
  String body = '',
  bool contentLength = true,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final bytes = utf8.encode(body);
  socket.write(head);
  if (contentLength) socket.write('Content-Length: ${bytes.length}\r\n');
  socket.write('Connection: close\r\n\r\n');
  socket.add(bytes);
  await socket.flush();
  final response = await utf8.decoder
      .bind(socket)
      .join()
      .timeout(timeout)
      .whenComplete(socket.destroy);
  return _parse(response);
}

({int status, Map<String, String> headers, String body}) _parse(String text) {
  final split = text.indexOf('\r\n\r\n');
  final head = split < 0 ? text : text.substring(0, split);
  final lines = head.split('\r\n');
  final status = lines.first.isEmpty ? 0 : int.parse(lines.first.split(' ')[1]);
  final headers = <String, String>{
    for (final line in lines.skip(1))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).toLowerCase(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  };
  var body = split < 0 ? '' : text.substring(split + 4);
  if (headers['transfer-encoding'] == 'chunked') {
    final out = StringBuffer();
    var rest = body;
    while (true) {
      final eol = rest.indexOf('\r\n');
      if (eol < 0) break;
      final size = int.parse(rest.substring(0, eol), radix: 16);
      if (size == 0) break;
      out.write(rest.substring(eol + 2, eol + 2 + size));
      rest = rest.substring(eol + 2 + size + 2);
    }
    body = out.toString();
  }
  return (status: status, headers: headers, body: body);
}

String _post(
  int port, {
  String? host,
  String? authorization = 'Bearer $_token',
  String? origin,
  String path = '/mcp',
  String method = 'POST',
  String contentType = 'application/json',
  String accept = 'application/json, text/event-stream',
  Map<String, String> extra = const {},
}) {
  final b = StringBuffer('$method $path HTTP/1.1\r\n');
  if (host != '') b.write('Host: ${host ?? '127.0.0.1:$port'}\r\n');
  if (authorization != null) b.write('Authorization: $authorization\r\n');
  if (origin != null) b.write('Origin: $origin\r\n');
  b.write('Content-Type: $contentType\r\nAccept: $accept\r\n');
  extra.forEach((k, v) => b.write('$k: $v\r\n'));
  return b.toString();
}

void main() {
  late McpListener listener;
  late int port;
  late List<Object?> bodies;
  late List<Map<String, String>> headerLog;
  late Future<McpReply> Function(Object?) reply;

  Future<void> bind({
    Duration bodyTimeout = const Duration(seconds: 10),
  }) async {
    listener = await io.bindMcpLoopbackListener(
      port: 0,
      token: _token,
      bodyTimeout: bodyTimeout,
      handler: (body, {headers = const {}}) {
        bodies.add(body);
        headerLog.add(headers);
        return reply(body);
      },
    );
    port = listener.endpoint.port;
  }

  setUp(() async {
    bodies = [];
    headerLog = [];
    reply = (_) async => const McpReply(200, {'jsonrpc': '2.0', 'id': 1});
    await bind();
  });
  tearDown(() => listener.close());

  test('Android is a listener platform; iOS and others are not', () {
    for (final os in ['android', 'windows', 'linux', 'macos']) {
      expect(io.mcpListenerPlatformSupported(os), isTrue, reason: os);
    }
    for (final os in ['ios', 'fuchsia', '']) {
      expect(io.mcpListenerPlatformSupported(os), isFalse, reason: os);
    }
  });

  test('rejects short or non-printable tokens before binding', () async {
    Future<void> attempt(String token) => io.bindMcpLoopbackListener(
      port: 0,
      token: token,
      handler: (_, {headers = const {}}) async => const McpReply(200),
    );
    await expectLater(attempt('short'), throwsArgumentError);
    await expectLater(attempt('${'a' * 40} b'), throwsArgumentError);
    await expectLater(attempt('${'a' * 40}\n'), throwsArgumentError);
  });

  test('binds IPv4 loopback only, never a wildcard or LAN address', () async {
    expect(listener.endpoint.host, '127.0.0.1');
    expect(listener.endpoint.path, '/mcp');
    final external = <InternetAddress>[
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        ...i.addresses.where((a) => !a.isLoopback),
    ];
    for (final address in external) {
      await expectLater(
        Socket.connect(address, port, timeout: const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
        reason: '$address must not reach the MCP listener',
      );
    }
  });

  test(
    'authenticated request reaches the handler with allowlisted headers',
    () async {
      final r = await _raw(
        port,
        _post(
          port,
          extra: {
            'MCP-Protocol-Version': '2025-11-25',
            'Mcp-Method': 'tools/list',
            'X-Forwarded-For': '203.0.113.9',
            'Cookie': 'session=leak',
          },
        ),
        body: _rpc,
      );
      expect(r.status, 200);
      expect(r.headers['cache-control'], 'no-store');
      expect(r.headers['x-content-type-options'], 'nosniff');
      expect(jsonDecode(r.body), {'jsonrpc': '2.0', 'id': 1});
      expect(bodies.single, jsonDecode(_rpc));
      expect(headerLog.single, {
        'mcp-protocol-version': '2025-11-25',
        'mcp-method': 'tools/list',
      });
    },
  );

  test('localhost Host and same-port Origin are accepted', () async {
    final r = await _raw(
      port,
      _post(port, host: 'localhost:$port', origin: 'http://localhost:$port'),
      body: _rpc,
    );
    expect(r.status, 200);
  });

  test(
    'missing or wrong credentials get 401 and never reach the handler',
    () async {
      final wrong = 'Bearer ${_token.substring(1)}X';
      for (final auth in <String?>[
        null,
        '',
        wrong,
        'bearer $_token',
        'Basic $_token',
        _token,
      ]) {
        final r = await _raw(
          port,
          _post(port, authorization: auth),
          body: _rpc,
        );
        expect(r.status, 401, reason: '$auth');
        expect(r.headers['www-authenticate'], 'Bearer realm="Atermius MCP"');
        expect(r.body, isNot(contains(_token)));
      }
      expect(bodies, isEmpty);
    },
  );

  test(
    'DNS-rebinding Host and browser Origins are refused even with the token',
    () async {
      final cases = <({String? host, String? origin})>[
        (host: '', origin: null), // no Host header at all
        (host: 'evil.example:$port', origin: null),
        (host: '127.0.0.1', origin: null), // portless
        // ADB/SSH forwarding with a different local port keeps the client's
        // port in Host; that must be refused, not silently trusted.
        (host: '127.0.0.1:${port == 65535 ? 1 : port + 1}', origin: null),
        (host: '0.0.0.0:$port', origin: null),
        (host: '[::1]:$port', origin: null),
        (host: null, origin: 'https://evil.example'),
        (host: null, origin: 'null'),
        (
          host: null,
          origin: 'http://127.0.0.1:${port == 65535 ? 1 : port + 1}',
        ),
        (host: null, origin: 'https://127.0.0.1:$port'),
      ];
      for (final c in cases) {
        final r = await _raw(
          port,
          _post(port, host: c.host, origin: c.origin),
          body: _rpc,
        );
        expect(r.status, 403, reason: '$c');
      }
      expect(bodies, isEmpty);
    },
  );

  test('path, query, method, media type and Accept are enforced', () async {
    expect((await _raw(port, _post(port, path: '/'), body: _rpc)).status, 404);
    expect(
      (await _raw(port, _post(port, path: '/mcp/'), body: _rpc)).status,
      404,
    );
    expect(
      (await _raw(
        port,
        _post(port, path: '/mcp?token=$_token'),
        body: _rpc,
      )).status,
      404,
    );
    final get = await _raw(port, _post(port, method: 'GET'));
    expect(get.status, 405);
    expect(get.headers['allow'], 'POST');
    expect((await _raw(port, _post(port, method: 'DELETE'))).status, 405);
    expect(
      (await _raw(
        port,
        _post(port, contentType: 'text/plain'),
        body: _rpc,
      )).status,
      415,
    );
    expect(
      (await _raw(
        port,
        _post(port, accept: 'application/json'),
        body: _rpc,
      )).status,
      406,
    );
    expect(bodies, isEmpty);
  });

  test('malformed JSON returns a JSON-RPC parse error', () async {
    final r = await _raw(port, _post(port), body: '{"jsonrpc":');
    expect(r.status, 400);
    expect((jsonDecode(r.body) as Map)['error']['code'], -32700);
    expect(bodies, isEmpty);
  });

  // Dart's HttpServer drops the socket once a rejected request body is
  // abandoned, so a client may see 413/408 or a closed connection. Either is a
  // rejection; what matters is that the handler never runs and no in-flight
  // slot leaks (more than four leaked slots would turn the probe into 429).
  Future<void> expectSlotsFree() async {
    final probe = await _raw(port, _post(port), body: _rpc);
    expect(probe.status, 200);
    bodies.clear();
    headerLog.clear();
  }

  test('declared and streamed oversize bodies are rejected', () async {
    for (var i = 0; i < 5; i++) {
      final declared = await _raw(
        port,
        '${_post(port)}Content-Length: ${600 * 1024}\r\n',
        contentLength: false,
      ).catchError((_) => (status: 0, headers: <String, String>{}, body: ''));
      expect(declared.status, anyOf(413, 0));
      expect(bodies, isEmpty);
    }

    for (var i = 0; i < 5; i++) {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final response = utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 5))
          .catchError((_) => '');
      try {
        socket.write(
          '${_post(port)}Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
        );
        final chunk = 'x' * 65536;
        for (var c = 0; c < 10; c++) {
          socket.write('${chunk.length.toRadixString(16)}\r\n$chunk\r\n');
        }
        socket.write('0\r\n\r\n');
        await socket.flush();
      } on SocketException {
        // The server may close as soon as the limit is crossed.
      }
      final streamed = _parse(await response);
      socket.destroy();
      expect(streamed.status, anyOf(413, 0));
      expect(bodies, isEmpty);
    }
    await expectSlotsFree();
  });

  test('stalled bodies time out instead of holding slots', () async {
    await listener.close();
    await bind(bodyTimeout: const Duration(milliseconds: 300));
    final stalled = <Future<String>>[];
    final sockets = <Socket>[];
    // Fill every in-flight slot with a body that never completes.
    for (var i = 0; i < 4; i++) {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      sockets.add(socket);
      stalled.add(
        utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 5))
            .catchError((_) => ''),
      );
      socket.write('${_post(port)}Content-Length: 100\r\n\r\n{"jsonrpc"');
      await socket.flush();
    }
    for (final r in await Future.wait(stalled)) {
      expect(_parse(r).status, anyOf(408, 0));
    }
    for (final s in sockets) {
      s.destroy();
    }
    expect(bodies, isEmpty);
    await expectSlotsFree();
  });

  test('more than four in-flight requests are refused with 429', () async {
    final gate = Completer<void>();
    reply = (_) async {
      await gate.future;
      return const McpReply(200, {'jsonrpc': '2.0', 'id': 1});
    };
    final pending = [
      for (var i = 0; i < 4; i++) _raw(port, _post(port), body: _rpc),
    ];
    while (bodies.length < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await _raw(port, _post(port), body: _rpc)).status, 429);
    gate.complete();
    for (final r in await Future.wait(pending)) {
      expect(r.status, 200);
    }
  });

  test('unauthenticated socket floods cannot exhaust the listener', () async {
    final idle = <Socket>[];
    try {
      for (var i = 0; i < 16; i++) {
        idle.add(await Socket.connect(InternetAddress.loopbackIPv4, port));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final r = await _raw(port, _post(port), body: _rpc);
      expect(r.status, 503);
      expect(r.headers['retry-after'], '1');
      expect(bodies, isEmpty);
    } finally {
      for (final s in idle) {
        s.destroy();
      }
    }
    // Capacity returns once peers disconnect.
    var status = 0;
    for (var i = 0; i < 50 && status != 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      status = (await _raw(port, _post(port), body: _rpc)).status;
    }
    expect(status, 200);
  });

  test(
    'close revokes in flight: no result is delivered and the port closes',
    () async {
      final observable = listener as McpObservableListener;
      final gate = Completer<void>();
      reply = (_) async {
        await gate.future;
        return const McpReply(200, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': 'late',
        });
      };
      final pending = _raw(port, _post(port), body: _rpc).then(
        (r) => r,
        onError: (_) => (status: 0, headers: <String, String>{}, body: ''),
      );
      while (bodies.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(observable.closed, isFalse);
      var doneFired = false;
      unawaited(observable.done.then((_) => doneFired = true));
      await listener.close();
      gate.complete();
      final r = await pending;
      expect(r.status, isNot(200));
      expect(r.body, isNot(contains('late')));
      await observable.done.timeout(const Duration(seconds: 2));
      expect(doneFired, isTrue);
      expect(observable.closed, isTrue);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
      // A second close is harmless.
      await listener.close();
    },
  );

  test(
    'a new listener on the same port does not accept the old token',
    () async {
      await listener.close();
      final next = await io.bindMcpLoopbackListener(
        port: port,
        token: 'new_${'z' * 40}',
        handler: (_, {headers = const {}}) async => const McpReply(200),
      );
      try {
        final r = await _raw(port, _post(port), body: _rpc);
        expect(r.status, 401);
      } finally {
        await next.close();
      }
    },
  );
}
