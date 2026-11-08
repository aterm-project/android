@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/telnet/telnet_errors.dart';
import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:aterm_client/telnet/telnet_session.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const iac = TelnetCommand.iac;
const sb = TelnetCommand.sb;
const se = TelnetCommand.se;
const will = TelnetCommand.will;
const wont = TelnetCommand.wont;
const doo = TelnetCommand.doOption;
const dont = TelnetCommand.dont;

/// A loopback Telnet "server" fixture that records every received byte and
/// lets a test script what it sends. No third-party targets are contacted.
class TelnetFixture {
  TelnetFixture._(this.server);

  static Future<TelnetFixture> start() async => TelnetFixture._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  final ServerSocket server;
  final List<int> received = [];
  Socket? client;
  final Completer<Socket> _accepted = Completer<Socket>();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool clientClosed = false;

  int get port => server.port;

  void listen() {
    server.listen((socket) {
      client = socket;
      socket.listen(
        (data) {
          received.addAll(data);
          _changes.add(null);
        },
        onDone: () {
          clientClosed = true;
          _changes.add(null);
        },
        onError: (_) {},
      );
      if (!_accepted.isCompleted) _accepted.complete(socket);
    });
  }

  Future<Socket> get accepted => _accepted.future;

  /// Sends [bytes] one byte per write with a flush in between, so the client
  /// sees every possible split point across TCP segments.
  Future<void> sendSplit(List<int> bytes) async {
    final socket = await accepted;
    for (final byte in bytes) {
      socket.add([byte]);
      await socket.flush();
    }
  }

  Future<void> send(List<int> bytes) async {
    final socket = await accepted;
    socket.add(bytes);
    await socket.flush();
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('fixture condition not met; got $received');
      }
      await _changes.stream.first.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () {},
      );
    }
  }

  bool receivedContains(List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= received.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (received[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  Future<void> close() async {
    await client?.close();
    client?.destroy();
    await server.close();
    await _changes.close();
  }
}

Future<(TelnetFixture, TelnetSession, StringBuffer, Completer<Object?>)>
connectToFixture({int columns = 80, int rows = 24}) async {
  final fixture = await TelnetFixture.start();
  fixture.listen();
  final session = await TelnetSession.connect(
    host: '127.0.0.1',
    port: fixture.port,
    connector: connectTelnetDirect,
    columns: columns,
    rows: rows,
  );
  final output = StringBuffer();
  final ended = Completer<Object?>();
  session.output.listen(
    output.write,
    onError: (Object error) {
      if (!ended.isCompleted) ended.complete(error);
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete(null);
    },
  );
  await fixture.accepted;
  return (fixture, session, output, ended);
}

void main() {
  test('negotiation, IAC data, CR NUL and UTF-8 survive byte-split packets',
      () async {
    final (fixture, session, output, _) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);

    // Client proactively offers NAWS and asks for SGA + ECHO.
    await fixture.waitFor(
      () =>
          fixture.receivedContains([iac, will, TelnetOption.naws]) &&
          fixture.receivedContains([iac, doo, TelnetOption.suppressGoAhead]) &&
          fixture.receivedContains([iac, doo, TelnetOption.echo]),
    );

    final utf8Text = utf8.encode('héllo ✓');
    await fixture.sendSplit([
      iac, will, TelnetOption.echo, // agree to the client's DO ECHO
      iac, will, TelnetOption.suppressGoAhead,
      iac, doo, TelnetOption.naws, // agree to the client's WILL NAWS
      ...'login: '.codeUnits,
      iac, iac, // literal 0xFF in data (invalid UTF-8 -> U+FFFD)
      13, 0, // CR NUL -> bare CR
      ...utf8Text,
      13, 10,
    ]);

    // NAWS 80x24 follows the agreement; no extra WILL reply (loop-free).
    await fixture.waitFor(
      () => fixture.receivedContains([iac, sb, TelnetOption.naws, 0, 80, 0, 24, iac, se]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(output.toString(), 'login: �\rhéllo ✓\r\n');
    expect(session.options.remoteEcho, isTrue);
    expect(session.options.suppressGoAhead, isTrue);
    expect(session.options.naws, isTrue);
    final willNaws = [iac, will, TelnetOption.naws];
    var count = 0;
    for (var i = 0; i + 3 <= fixture.received.length; i++) {
      if (fixture.received[i] == willNaws[0] &&
          fixture.received[i + 1] == willNaws[1] &&
          fixture.received[i + 2] == willNaws[2]) {
        count++;
      }
    }
    expect(count, 1, reason: 'WILL NAWS must not be repeated');
  });

  test('resize sends NAWS (with IAC escaping) only after it was enabled',
      () async {
    final (fixture, session, _, _) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);
    await fixture.waitFor(
      () => fixture.receivedContains([iac, will, TelnetOption.naws]),
    );
    // Not yet enabled by the server: resize must not send SB NAWS.
    session.resize(100, 40);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fixture.receivedContains([iac, sb, TelnetOption.naws]), isFalse);

    await fixture.send([iac, doo, TelnetOption.naws]);
    await fixture.waitFor(
      () => fixture.receivedContains([iac, sb, TelnetOption.naws, 0, 100, 0, 40, iac, se]),
    );
    session.resize(255, 50);
    await fixture.waitFor(
      () => fixture.receivedContains(
        [iac, sb, TelnetOption.naws, 0, 255, 255, 0, 50, iac, se],
      ),
    );
    // Same size again does not resend.
    final before = fixture.received.length;
    session.resize(255, 50);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fixture.received.length, before);
  });

  test('TERMINAL-TYPE cycles per RFC 1091 and unknown options are refused',
      () async {
    final (fixture, session, _, _) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);
    await fixture.accepted;
    await fixture.sendSplit([
      iac, doo, TelnetOption.terminalType,
      iac, sb, TelnetOption.terminalType, 1, iac, se,
      iac, sb, TelnetOption.terminalType, 1, iac, se,
      iac, sb, TelnetOption.terminalType, 1, iac, se,
      iac, sb, TelnetOption.terminalType, 1, iac, se,
      iac, doo, 39, // NEW-ENVIRON: refused, never sends USER
      iac, will, 37, // AUTHENTICATION from server side: refused
      iac, doo, TelnetOption.echo, // we never echo for the server
    ]);
    List<int> isType(String name) =>
        [iac, sb, TelnetOption.terminalType, 0, ...name.codeUnits, iac, se];
    await fixture.waitFor(
      () =>
          fixture.receivedContains([iac, wont, 39]) &&
          fixture.receivedContains([iac, dont, 37]) &&
          fixture.receivedContains([iac, wont, TelnetOption.echo]),
    );
    expect(fixture.receivedContains([iac, will, TelnetOption.terminalType]), isTrue);
    expect(fixture.receivedContains(isType('XTERM-256COLOR')), isTrue);
    expect(fixture.receivedContains(isType('XTERM')), isTrue);
    // VT100 is sent, then repeated to mark the end of the list.
    final vt100 = isType('VT100');
    var count = 0;
    for (var i = 0; i + vt100.length <= fixture.received.length; i++) {
      var match = true;
      for (var j = 0; j < vt100.length; j++) {
        if (fixture.received[i + j] != vt100[j]) {
          match = false;
          break;
        }
      }
      if (match) count++;
    }
    expect(count, 2);
  });

  test('input is NVT-encoded: CR LF line endings and doubled IAC', () async {
    final (fixture, session, _, _) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);
    await fixture.waitFor(
      () => fixture.receivedContains([iac, doo, TelnetOption.echo]),
    );
    fixture.received.clear();
    session.input('ls -l\r');
    session.input('ÿ\n');
    await fixture.waitFor(() => fixture.received.length >= 11);
    expect(fixture.received, [
      ...'ls -l'.codeUnits, 13, 10,
      0xc3, 0xbf, // UTF-8 for U+00FF (no raw 0xFF to double here)
      13, 10,
    ]);
  });

  test('oversized subnegotiation is ignored and the stream continues',
      () async {
    final (fixture, session, output, _) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);
    await fixture.send([
      iac, doo, TelnetOption.terminalType,
      iac, sb, TelnetOption.terminalType,
      for (var i = 0; i < 64 * 1024; i++) 1,
      iac, se,
      ...'still here'.codeUnits,
    ]);
    await fixture.waitFor(() => output.toString().contains('still here'));
    // The oversized "SEND" payload did not trigger a TTYPE reply.
    expect(fixture.receivedContains([iac, sb, TelnetOption.terminalType, 0]), isFalse);
    expect(session.isClosed, isFalse);
  });

  test('negotiation flood without data closes with a protocol error',
      () async {
    final (fixture, session, _, ended) = await connectToFixture();
    addTearDown(fixture.close);
    addTearDown(session.close);
    final flood = <int>[];
    for (var i = 0; i <= maxTelnetNegotiationRepliesWithoutData; i++) {
      flood.addAll([iac, will, TelnetOption.echo, iac, wont, TelnetOption.echo]);
    }
    await fixture.send(flood);
    final error = await ended.future.timeout(const Duration(seconds: 5));
    expect(error, isA<TelnetException>());
    expect((error! as TelnetException).failure, TelnetFailure.protocol);
    await session.done;
    expect(session.isClosed, isTrue);
    await fixture.waitFor(() => fixture.clientClosed);
  });

  test('remote close ends output and done; close stays idempotent', () async {
    final (fixture, session, output, ended) = await connectToFixture();
    addTearDown(fixture.close);
    await fixture.send('bye\r\n'.codeUnits);
    await fixture.waitFor(() => output.toString().contains('bye'));
    await (await fixture.accepted).close();
    expect(await ended.future.timeout(const Duration(seconds: 5)), isNull);
    await session.done;
    await Future.wait([session.close(), session.close()]);
    session.input('ignored after close');
    session.resize(10, 10);
  });

  test('local close is idempotent and closes the TCP connection', () async {
    final (fixture, session, _, ended) = await connectToFixture();
    addTearDown(fixture.close);
    final first = session.close();
    final second = session.close();
    expect(identical(first, second), isTrue);
    await first;
    await fixture.waitFor(() => fixture.clientClosed);
    expect(await ended.future.timeout(const Duration(seconds: 5)), isNull);
  });

  test('connection refused maps to a sanitized failure', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await expectLater(
      TelnetSession.connect(
        host: '127.0.0.1',
        port: port,
        connector: connectTelnetDirect,
      ),
      throwsA(
        isA<TelnetException>().having(
          (e) => e.failure,
          'failure',
          TelnetFailure.refused,
        ),
      ),
    );
  });

  test('cancel during connect closes a late channel and never returns it',
      () async {
    final lateChannel = Completer<TelnetByteChannel>();
    final channel = _RecordingChannel();
    final cancellation = TelnetConnectCancellation();
    final pending = TelnetSession.connect(
      host: 'example.invalid',
      port: 23,
      connector: (_, _) => lateChannel.future,
      cancellation: cancellation,
    );
    cancellation.cancel();
    cancellation.cancel(); // idempotent
    await expectLater(
      pending,
      throwsA(
        isA<TelnetException>().having(
          (e) => e.failure,
          'failure',
          TelnetFailure.cancelled,
        ),
      ),
    );
    lateChannel.complete(channel);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(channel.closed, isTrue);
    expect(channel.sent, isEmpty);
  });

  test('connect timeout closes a late channel', () async {
    final lateChannel = Completer<TelnetByteChannel>();
    final channel = _RecordingChannel();
    await expectLater(
      TelnetSession.connect(
        host: 'example.invalid',
        port: 23,
        connector: (_, _) => lateChannel.future,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<TelnetException>().having(
          (e) => e.failure,
          'failure',
          TelnetFailure.timeout,
        ),
      ),
    );
    lateChannel.complete(channel);
    await Future<void>.delayed(Duration.zero);
    expect(channel.closed, isTrue);
  });

  test('raw connector errors are sanitized', () async {
    await expectLater(
      TelnetSession.connect(
        host: 'h',
        port: 23,
        connector: (_, _) =>
            Future.error(const SocketException('secret resolver detail')),
      ),
      throwsA(
        isA<TelnetException>().having(
          (e) => e.toString(),
          'message',
          isNot(contains('secret')),
        ),
      ),
    );
  });
}

class _RecordingChannel implements TelnetByteChannel {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<Uint8List> sent = [];
  bool closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  void add(Uint8List bytes) => sent.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}
