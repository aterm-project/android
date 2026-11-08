import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses SSH, RDP, VNC, IPv6 and domain usernames', () {
    final ssh = QuickConnectRequest.parse('ssh root@host.test -p 22122')!;
    expect(
      (ssh.kind, ssh.username, ssh.address, ssh.port),
      (QuickConnectKind.ssh, 'root', 'host.test', 22122),
    );
    final rdp = QuickConnectRequest.parse(r'rdp DOMAIN\admin@192.0.2.1')!;
    expect((rdp.username, rdp.port), (r'DOMAIN\admin', 3389));
    final upn = QuickConnectRequest.parse('rdp user@domain@host.test:3390')!;
    expect(upn.username, 'user@domain');
    expect(upn.port, 3390);
    final ipv6 = QuickConnectRequest.parse('vnc [2001:db8::1]:5901')!;
    expect((ipv6.address, ipv6.port), ('2001:db8::1', 5901));
    expect(QuickConnectRequest.parse('ssh -p2222 user@host.test')!.port, 2222);
  });
  test('plain search stays a search and console grammar is bounded', () {
    expect(QuickConnectRequest.parse('production edge'), isNull);
    expect(
      QuickConnectRequest.parse('console')!.kind,
      QuickConnectKind.console,
    );
    final serial = QuickConnectRequest.parse('console tty @com12 -b 9600')!;
    expect(
      (serial.kind, serial.address, serial.baudRate),
      (QuickConnectKind.serial, 'COM12', 9600),
    );
    expect(QuickConnectRequest.parse('tty @COM3')!.baudRate, 115200);
    for (final text in [
      'ssh user@host -p',
      'ssh user@host -p 0',
      'rdp host:3390 -p 3389',
      'ssh host;id',
      'ssh user@host -oProxyCommand=bad',
      'console tty @COM0',
      'console tty @COM3 -b 99999999',
      'console cmd.exe',
    ]) {
      expect(
        () => QuickConnectRequest.parse(text),
        throwsFormatException,
        reason: text,
      );
    }
  });
  test(
    'saved credentials only match requested endpoint protocol and username',
    () {
      const host = HostRecord(
        id: 'a',
        name: 'Production',
        address: 'example.test',
        username: 'root',
        port: 22122,
      );
      expect(
        QuickConnectRequest.parse('ssh root@example.test -p 22122')!
            .matches(host),
        isTrue,
      );
      expect(
        QuickConnectRequest.parse('rdp root@example.test -p 22122')!
            .matches(host),
        isFalse,
      );
      expect(
        QuickConnectRequest.parse('ssh deploy@example.test -p 22122')!
            .matches(host),
        isFalse,
      );
      expect(
        QuickConnectRequest.parse('ssh root@example.test')!.matches(host),
        isFalse,
      );
    },
  );
}
