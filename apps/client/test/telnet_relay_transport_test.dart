import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/telnet/telnet_errors.dart';
import 'package:aterm_client/telnet/telnet_session.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

class _FakeRelaySocket implements SSHSocket {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  final StreamController<List<int>> outgoing = StreamController<List<int>>();
  final List<int> written = [];
  int closeCount = 0;
  bool destroyed = false;

  _FakeRelaySocket() {
    outgoing.stream.listen(written.addAll);
  }

  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  StreamSink<List<int>> get sink => outgoing.sink;
  @override
  Future<void> get done => Future<void>.value();
  @override
  Future<void> close() async {
    closeCount++;
    unawaited(outgoing.close());
    unawaited(incoming.close());
  }

  @override
  void destroy() => destroyed = true;
  @override
  Future<void> flush() async {}
}

void main() {
  useAppLocaleFixture('en');
  final relayUri = Uri.parse('wss://relay.example.test/relay/v1/connect');
  const ticket = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  test('relay socket that arrives after the session deadline is closed',
      () async {
    final lateSocket = Completer<SSHSocket>();
    final socket = _FakeRelaySocket();
    Uri? usedUri;
    String? usedTicket;
    await expectLater(
      TelnetSession.connect(
        host: 'switch.example.test',
        port: 23,
        timeout: const Duration(milliseconds: 20),
        connector: (_, _) => connectTelnetRelayWith(
          issueTicket: () async => ticket,
          relayUri: () => relayUri,
          relaySocketConnector: (uri, value) {
            usedUri = uri;
            usedTicket = value;
            return lateSocket.future;
          },
        ),
      ),
      throwsA(
        isA<TelnetException>().having(
          (e) => e.failure,
          'failure',
          TelnetFailure.timeout,
        ),
      ),
    );
    expect(usedUri, relayUri);
    expect(usedTicket, ticket);
    lateSocket.complete(socket);
    await pumpEventQueue();
    expect(socket.closeCount, 1, reason: 'late Relay socket must be closed');
    expect(socket.written, isEmpty);
  });

  test('relay socket failures are sanitized', () async {
    await expectLater(
      connectTelnetRelayWith(
        issueTicket: () async => ticket,
        relayUri: () => relayUri,
        relaySocketConnector: (_, _) =>
            Future.error(StateError('ws://internal-detail:9999 refused')),
      ),
      throwsA(
        isA<TelnetException>()
            .having((e) => e.failure, 'failure', TelnetFailure.relayUnavailable)
            .having((e) => e.toString(), 'text', isNot(contains('internal'))),
      ),
    );
  });

  test('relay channel carries opaque Telnet bytes and closes once', () async {
    final socket = _FakeRelaySocket();
    final session = TelnetSession.attach(RelayTelnetChannel(socket));
    final output = StringBuffer();
    session.output.listen(output.write);
    socket.incoming.add(Uint8List.fromList('hello'.codeUnits));
    await pumpEventQueue();
    expect(output.toString(), 'hello');
    session.input('id\r');
    await pumpEventQueue();
    expect(String.fromCharCodes(socket.written), contains('id\r\n'));
    await Future.wait([session.close(), session.close()]);
    expect(socket.closeCount, 1);
  });
}
