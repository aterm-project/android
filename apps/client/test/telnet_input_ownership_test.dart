import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:aterm_client/telnet/telnet_session.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

/// Retains every buffer passed to add() WITHOUT copying, like an IOSink that
/// consumes asynchronously. Any mutation after add() would be visible here.
class _RetainingChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  final List<Uint8List> retained = [];
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  void add(Uint8List bytes) => retained.add(bytes);
  @override
  Future<void> close() async {
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

void main() {
  useAppLocaleFixture('en');

  test('input buffers are never mutated after add()', () async {
    final channel = _RetainingChannel();
    final session = TelnetSession.attach(channel);
    session.output.listen((_) {});
    addTearDown(session.close);
    await pumpEventQueue();
    channel.retained.clear();
    expect(session.input('secret-cmd\r'), TelnetInputResult.sent);
    session.input('ÿ\n'); // U+00FF, two UTF-8 bytes
    await pumpEventQueue();
    expect(channel.retained, hasLength(2));
    expect(channel.retained[0], [...'secret-cmd'.codeUnits, 13, 10]);
    expect(channel.retained[1], [0xc3, 0xbf, 13, 10]);
  });

  test('huge paste is rejected before encoding and nothing is sent', () async {
    final channel = _RetainingChannel();
    final session = TelnetSession.attach(channel);
    session.output.listen((_) {});
    addTearDown(session.close);
    await pumpEventQueue();
    channel.retained.clear();
    expect(
      session.input('z' * (maxTelnetInputBytes + 1)),
      TelnetInputResult.tooLarge,
    );
    // Within the code-unit cap but over the encoded cap (2-byte UTF-8).
    expect(
      session.input('é' * (maxTelnetInputBytes ~/ 2 + 1)),
      TelnetInputResult.tooLarge,
    );
    expect(channel.retained, isEmpty);
    expect(session.input('ok\r'), TelnetInputResult.sent);
    expect(channel.retained.single, [...'ok'.codeUnits, 13, 10]);
  });
}
