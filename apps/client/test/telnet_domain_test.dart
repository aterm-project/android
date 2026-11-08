import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/telnet/telnet_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HostRecord telnetHost({
  String? credentialId,
  HostLogin? login,
  String? jumpHostId,
  AuthKind authKind = AuthKind.password,
  List<SshPortForwardProfile> forwards = const [],
}) => HostRecord(
  id: 'h1',
  name: 'Switch',
  address: '192.0.2.10',
  protocol: HostProtocol.telnet,
  credentialId: credentialId,
  login: login,
  jumpHostId: jumpHostId,
  authKind: authKind,
  portForwardProfiles: forwards,
);

void main() {
  group('HostProtocol.telnet', () {
    test('defaults to port 23 and is a terminal protocol', () {
      expect(HostProtocol.telnet.defaultPort, 23);
      expect(HostProtocol.telnet.label, 'Telnet');
      expect(HostProtocol.telnet.isTerminal, isTrue);
      expect(HostProtocol.ssh.isTerminal, isTrue);
      expect(HostProtocol.rdp.isTerminal, isFalse);
      expect(HostProtocol.vnc.isTerminal, isFalse);
      expect(telnetHost().port, 23);
      expect(HostProtocol.parse('telnet'), HostProtocol.telnet);
    });

    test('serializes protocol and restores default port when omitted', () {
      final json = telnetHost().toJson();
      expect(json['protocol'], 'telnet');
      expect(json['port'], 23);
      final restored = HostRecord.fromJson({...json}..remove('port'));
      expect(restored.protocol, HostProtocol.telnet);
      expect(restored.port, 23);
      expect(restored.validate(), isNull);
      // Existing protocols keep their serialized shape.
      final ssh = HostRecord(
        id: 's',
        name: 's',
        address: 'a',
        username: 'u',
      ).toJson();
      expect(ssh.containsKey('protocol'), isFalse);
      expect(ssh['port'], 22);
    });

    test('rejects saved sign-in, keychain, jump host and forwarding', () {
      expect(telnetHost().validate(), isNull);
      expect(telnetHost(credentialId: 'c1').validate(), isNotNull);
      expect(
        telnetHost(
          login: const HostLogin(kind: AuthKind.password, password: 'pw'),
        ).validate(),
        isNotNull,
      );
      expect(telnetHost(jumpHostId: 'j1').validate(), isNotNull);
      expect(telnetHost(authKind: AuthKind.privateKey).validate(), isNotNull);
      expect(
        telnetHost(
          forwards: const [
            SshPortForwardProfile(
              id: 'f',
              name: 'f',
              type: SshPortForwardType.dynamic,
              bindAddress: '127.0.0.1',
              bindPort: 1080,
            ),
          ],
        ).validate(),
        isNotNull,
      );
    });

    test('has a distinct icon', () {
      expect(hostProtocolIcon(HostProtocol.telnet), Icons.settings_ethernet);
      expect(hostProtocolIcon(HostProtocol.ssh), Icons.terminal);
    });
  });

  group('quick connect', () {
    QuickConnectRequest parse(String text) => QuickConnectRequest.parse(text)!;

    test('telnet host[:port], -p and IPv6 forms', () {
      final plain = parse('telnet router.test');
      expect(
        (plain.kind, plain.protocol, plain.address, plain.port, plain.username),
        (QuickConnectKind.telnet, HostProtocol.telnet, 'router.test', 23, ''),
      );
      expect(parse('telnet router.test:2323').port, 2323);
      expect(parse('telnet -p 2324 router.test').port, 2324);
      expect(parse('TELNET --port=2325 router.test').port, 2325);
      final v6 = parse('telnet [2001:db8::5]:2300');
      expect((v6.address, v6.port), ('2001:db8::5', 2300));
      final bareV6 = parse('telnet 2001:db8::6');
      expect((bareV6.address, bareV6.port), ('2001:db8::6', 23));
      expect(parse('telnet 192.0.2.1').label, 'TELNET 192.0.2.1:23');
    });

    test('drafts a Telnet host and matches only Telnet hosts', () {
      final request = parse('telnet 192.0.2.10');
      final draft = request.draft('new');
      expect(draft.protocol, HostProtocol.telnet);
      expect(draft.port, 23);
      expect(draft.username, isEmpty);
      expect(draft.validate(), isNull);
      expect(request.matches(telnetHost()), isTrue);
      expect(
        request.matches(
          HostRecord(
            id: 's',
            name: 's',
            address: '192.0.2.10',
            port: 23,
            username: 'u',
          ),
        ),
        isFalse,
      );
    });

    test('rejects user@, bad ports and options', () {
      expect(() => parse('telnet root@host'), throwsFormatException);
      expect(() => parse('telnet host:0'), throwsFormatException);
      expect(() => parse('telnet host:70000'), throwsFormatException);
      expect(() => parse('telnet -l root host'), throwsFormatException);
      expect(() => parse('telnet'), throwsFormatException);
      expect(() => parse('telnet host;rm'), throwsFormatException);
    });
  });

  test('window sets accept telnet panes with a host id', () {
    final pane = CombinationPane(kind: 'telnet', hostId: 'h1');
    expect(CombinationPane.fromJson(pane.toJson()).kind, 'telnet');
    expect(() => CombinationPane(kind: 'telnet'), throwsFormatException);
  });
}
