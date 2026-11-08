import 'package:aterm_client/import/openssh_config_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenSshConfigImporter', () {
    test(
      'parses literal aliases, safe fields, and a resolvable jump alias',
      () {
        final result = OpenSshConfigImporter.parse('''
Host web-prod
  HostName web.example.test
  User deploy
  Port 2222
  ProxyJump bastion

Host bastion
  HostName 192.0.2.15
  User gateway
''');

        expect(result.blocksWholeFile, isFalse);
        expect(result.hosts, hasLength(2));
        final target = result.hosts.first;
        expect(target.alias, 'web-prod');
        expect(target.address, 'web.example.test');
        expect(target.username, 'deploy');
        expect(target.port, 2222);
        expect(target.proxyJumpAlias, 'bastion');
        expect(target.fieldLines, {
          'Host': 1,
          'HostName': 2,
          'User': 3,
          'Port': 4,
          'ProxyJump': 5,
        });
        expect(target.canImport, isTrue);
        expect(result.hosts.last.address, '192.0.2.15');
        expect(result.hosts.last.canImport, isTrue);
      },
    );

    test('applies safe global defaults and first obtained values', () {
      final result = OpenSshConfigImporter.parse('''
User default-user
Port 2200
Host prod-a prod-b
  HostName "prod.example.test"
  User override
  User ignored-later-value
''');

      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts.map((host) => host.alias), ['prod-a', 'prod-b']);
      expect(result.hosts.map((host) => host.username), [
        'default-user',
        'default-user',
      ]);
      expect(result.hosts.map((host) => host.port), [2200, 2200]);
      expect(result.hosts.every((host) => host.canImport), isTrue);
    });

    test('uses alias as HostName when no HostName is present', () {
      final result = OpenSshConfigImporter.parse('Host short-name\nUser bob\n');

      expect(result.hosts.single.address, 'short-name');
      expect(result.hosts.single.port, 22);
      expect(result.hosts.single.canImport, isTrue);
    });

    test(
      'blocks Include, Match, and wildcard Host patterns for the whole file',
      () {
        for (final source in [
          'Host *\nUser bob\n',
          'Host app\nUser bob\nInclude other.conf\n',
          'Host app\nUser bob\nMatch host *.example.test\n',
        ]) {
          final result = OpenSshConfigImporter.parse(source);
          expect(result.blocksWholeFile, isTrue, reason: source);
          expect(result.canImportAny, isFalse, reason: source);
          expect(result.issues.any((issue) => issue.blocking), isTrue);
        }
      },
    );

    test(
      'blocks command directives without retaining or running their values',
      () {
        for (final directive in ['ProxyCommand', 'LocalCommand']) {
          const commandMarker = 'OPENSSH_COMMAND_CANARY_91A7';
          final result = OpenSshConfigImporter.parse('''
Host app
  HostName app.example.test
  User bob
  $directive echo $commandMarker
''');
          final host = result.hosts.single;
          expect(result.blocksWholeFile, isFalse);
          expect(host.canImport, isFalse);
          expect(host.issues.single.blocking, isTrue);
          expect(host.issues.single.line, 4);
          expect(host.issues.single.message, isNot(contains(commandMarker)));
        }
      },
    );

    test('reports IdentityFile but discards its path', () {
      const privatePath = '/home/test-user/.ssh/private-key-canary';
      final result = OpenSshConfigImporter.parse('''
Host app
  User bob
  IdentityFile $privatePath
''');

      expect(result.hosts.single.canImport, isTrue);
      expect(result.hosts.single.issues, hasLength(1));
      expect(result.hosts.single.issues.single.blocking, isFalse);
      expect(
        result.hosts.single.issues.single.message,
        isNot(contains(privatePath)),
      );
      expect(result.issues.single.message, isNot(contains(privatePath)));
      expect(result.hosts.single.address, 'app');
    });

    test(
      'blocks unresolved syntax and invalid values at their source line',
      () {
        final invalidUser = OpenSshConfigImporter.parse('''
Host app
  User "bad user"
''');
        expect(invalidUser.hosts.single.canImport, isFalse);
        expect(invalidUser.hosts.single.issues, hasLength(2));
        expect(invalidUser.hosts.single.issues.first.line, 2);

        final invalidPort = OpenSshConfigImporter.parse('''
Host app
  User bob
  Port 70000
''');
        expect(invalidPort.hosts.single.canImport, isFalse);
        expect(invalidPort.hosts.single.issues.single.line, 3);

        final unsupported = OpenSshConfigImporter.parse('''
Host app
  User bob
  RemoteCommand echo unsafe
''');
        expect(unsupported.hosts.single.canImport, isFalse);
        expect(unsupported.hosts.single.issues.single.line, 3);
        expect(
          unsupported.hosts.single.issues.single.message,
          isNot(contains('unsafe')),
        );
      },
    );

    test('rejects malformed quotes and bounded input', () {
      final malformed = OpenSshConfigImporter.parse('Host app\nUser "bob\n');
      expect(malformed.blocksWholeFile, isTrue);
      expect(malformed.issues.single.line, 2);

      final oversized = OpenSshConfigImporter.parse(
        'x' * (maxOpenSshConfigBytes + 1),
      );
      expect(oversized.blocksWholeFile, isTrue);
      expect(oversized.hosts, isEmpty);
    });
  });
}
