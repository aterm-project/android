import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/telnet/telnet_errors.dart';
import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:aterm_client/telnet/telnet_session.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

void main() {
  useAppLocaleFixture('en');

  test('BINARY changes affect later bytes in the same packet', () async {
    final wire = _BoundaryChannel();
    final session = TelnetSession.attach(wire);
    final output = <String>[];
    session.output.listen(output.add);
    addTearDown(session.close);
    wire.output.add(Uint8List.fromList([
      255, 251, TelnetOption.binary, 13, 0,
    ]));
    await pumpEventQueue();
    expect(output.join(), '\r\x00');
    output.clear();
    wire.output.add(Uint8List.fromList([
      255, 252, TelnetOption.binary, 13, 0,
    ]));
    await pumpEventQueue();
    expect(output.join(), '\r');
  });

  test('an oversized paste sends no truncated command', () async {
    final wire = _BoundaryChannel();
    final session = TelnetSession.attach(wire);
    session.output.listen((_) {}, onError: (Object _) {});
    addTearDown(session.close);
    await pumpEventQueue();
    wire.sent.clear();
    expect(() => session.input('x' * (maxTelnetInputBytes + 1)), returnsNormally);
    await pumpEventQueue();
    expect(wire.sent, isEmpty);
  });

  test('a synchronously failing transport does not throw from key handling', () async {
    final wire = _BoundaryChannel();
    final session = TelnetSession.attach(wire);
    final errors = <Object>[];
    session.output.listen((_) {}, onError: errors.add);
    addTearDown(session.close);
    await pumpEventQueue();
    wire.failWrites = true;
    expect(() => session.input('whoami\r'), returnsNormally);
    await pumpEventQueue();
    expect(session.isClosed, isTrue);
    expect(errors, isNotEmpty);
    expect(errors.every((error) => error is TelnetException), isTrue);
  });

  test('endpoint notice cannot inject terminal controls', () {
    final text = telnetPlaintextTerminalNotice('host\x1b]52;c;payload\x07\r\n:23');
    final plain = text
        .replaceAll('\x1b[33m', '')
        .replaceAll('\x1b[0m', '')
        .replaceFirst(RegExp(r'\r\n$'), '');
    expect(RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(plain), isFalse);
    expect(telnetPlaintextTerminalNotice('h' * 100000).length, lessThan(2500));
  });
}

class _BoundaryChannel implements TelnetByteChannel {
  final output = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  bool failWrites = false;
  bool closed = false;
  @override
  Stream<Uint8List> get stream => output.stream;
  @override
  void add(Uint8List bytes) {
    if (failWrites) throw StateError('synthetic transport detail');
    if (!closed) sent.add(Uint8List.fromList(bytes));
  }
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(output.close());
  }
}
