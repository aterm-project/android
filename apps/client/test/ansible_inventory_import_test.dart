import 'package:aterm_client/import/ansible_inventory_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnsibleInventoryImporter', () {
    test('parses INI groups, children, group vars, and host overrides', () {
      final result = AnsibleInventoryImporter.parse('''
[all:vars]
ansible_user=common
[all:children]
production
[production:vars]
ansible_port=2222
[production:children]
web
[web]
api-1 ansible_host=api.example.test ansible_user=deploy
api-2
''');

      expect(result.format, AnsibleInventoryFormat.ini);
      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts, hasLength(2));
      final api = result.hosts.first;
      expect(api.name, 'api-1');
      expect(api.address, 'api.example.test');
      expect(api.username, 'deploy');
      expect(api.port, 2222);
      expect(api.groups, ['production', 'web']);
      expect(api.sourceLine, 10);
      expect(api.canImport, isTrue);
      final inherited = result.hosts.last;
      expect(inherited.address, 'api-2');
      expect(inherited.username, 'common');
      expect(inherited.port, 2222);
      expect(inherited.canImport, isTrue);
    });

    test('parses static YAML and inherits all/group variables', () {
      final result = AnsibleInventoryImporter.parse('''
all:
  vars:
    ansible_user: ops
    ansible_password: SUPER_SECRET_CANARY_71
  children:
    web:
      vars:
        ansible_port: 2201
        deploy_token: TOKEN_CANARY_42
      hosts:
        web-a:
          ansible_host: web-a.example.test
          ansible_user: deploy
        web-b: null
''');

      expect(result.format, AnsibleInventoryFormat.yaml);
      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts, hasLength(2));
      expect(result.hosts.first.name, 'web-a');
      expect(result.hosts.first.address, 'web-a.example.test');
      expect(result.hosts.first.username, 'deploy');
      expect(result.hosts.first.port, 2201);
      expect(result.hosts.first.groups, ['web']);
      expect(result.hosts.first.canImport, isTrue);
      expect(result.hosts.last.address, 'web-b');
      expect(result.hosts.last.username, 'ops');
      expect(result.hosts.last.port, 2201);

      final exposedText = [
        ...result.issues.map((issue) => issue.message),
        for (final host in result.hosts)
          ...host.issues.map((issue) => issue.message),
      ].join('\n');
      expect(exposedText, isNot(contains('SUPER_SECRET_CANARY_71')));
      expect(exposedText, isNot(contains('TOKEN_CANARY_42')));
      expect(exposedText, isNot(contains('ansible_password')));
      expect(exposedText, isNot(contains('deploy_token')));
    });

    test('projects only static connection values and omits sensitive vars', () {
      const secret = 'DONT_RETAIN_THIS_PASSWORD_5D31';
      final result = AnsibleInventoryImporter.parse('''
[servers]
app ansible_host=app.example.test ansible_user=ops ansible_password=$secret ansible_ssh_private_key_file=/tmp/private-key ansible_connection=ssh
local ansible_connection=local ansible_password=$secret
''');

      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts, hasLength(2));
      final app = result.hosts.first;
      expect(app.canImport, isTrue);
      expect(app.address, 'app.example.test');
      expect(app.username, 'ops');
      expect(app.port, 22);
      expect(
        app.issues.map((issue) => issue.code),
        contains('ignored_variable'),
      );
      expect(result.hosts.last.canImport, isFalse);
      expect(
        result.hosts.last.issues.map((issue) => issue.code),
        contains('unsupported_connection'),
      );
      for (final issue in [
        ...result.issues,
        for (final host in result.hosts) ...host.issues,
      ]) {
        expect(issue.message, isNot(contains(secret)));
        expect(issue.message, isNot(contains('/tmp/private-key')));
        expect(issue.message, isNot(contains('ansible_password')));
      }
    });

    test('blocks plugin and dynamic YAML constructs with no host candidates', () {
      for (final source in [
        'plugin: community.aws.aws_ec2\nregions: [us-east-1]\n',
        'all:\n  hosts:\n    app: {}\n  compose:\n    name: "{{ inventory_hostname }}"\n',
        'all:\n  children:\n    web:\n      keyed_groups: []\n',
        '#!/usr/bin/env python3\nprint("not executed")\n',
      ]) {
        final result = AnsibleInventoryImporter.parse(
          source,
          format: AnsibleInventoryFormat.yaml,
        );
        expect(result.blocksWholeFile, isTrue, reason: source);
        expect(result.hosts, isEmpty, reason: source);
        expect(result.issues.single.blocking, isTrue);
        expect(result.issues.single.message, isNot(contains('not executed')));
      }
    });

    test('rejects YAML aliases, merge keys, custom tags, and templates', () {
      for (final source in [
        'defaults: &defaults\n  ansible_user: ops\n',
        'all:\n  vars:\n    ansible_user: *defaults\n',
        'all:\n  vars:\n    <<: *defaults\n',
        'all:\n  vars:\n    ansible_password: !vault encrypted\n',
        'all:\n  hosts:\n    app:\n      ansible_host: "{{ lookup(\'env\', \'HOST\') }}"\n',
      ]) {
        final result = AnsibleInventoryImporter.parse(
          source,
          format: AnsibleInventoryFormat.yaml,
        );
        expect(result.blocksWholeFile, isTrue, reason: source);
        expect(result.hosts, isEmpty, reason: source);
      }
    });

    test('rejects malformed YAML, duplicate keys, and multiple documents', () {
      for (final source in [
        'all:\n  hosts:\n    app: [unterminated\n',
        'all:\n  hosts:\n    app: null\n    app: null\n',
        'all:\n  hosts: {}\n---\nall:\n  hosts: {}\n',
        'all:\n  hosts: {}\n...\n---\nall:\n  hosts: {}\n',
        '- app\n- db\n',
      ]) {
        final result = AnsibleInventoryImporter.parse(
          source,
          format: AnsibleInventoryFormat.yaml,
        );
        expect(result.blocksWholeFile, isTrue, reason: source);
        expect(result.hosts, isEmpty, reason: source);
        expect(
          result.issues.every((issue) => issue.message.length < 120),
          isTrue,
        );
      }
    });

    test('accepts a single YAML document terminator', () {
      final result = AnsibleInventoryImporter.parse(
        'all:\n  hosts:\n    app: null\n...\n',
        format: AnsibleInventoryFormat.yaml,
      );
      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts.single.name, 'app');
    });

    test('blocks duplicate allowlisted INI fields without echoing values', () {
      final result = AnsibleInventoryImporter.parse('''
[servers]
ambiguous ansible_host=first.example.test ansible_host=second.example.test
good ansible_host=good.example.test
''');
      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts, hasLength(2));
      expect(result.hosts.first.canImport, isFalse);
      expect(result.hosts.first.address, 'first.example.test');
      expect(result.hosts.first.issues.single.code, 'duplicate_variable');
      expect(
        result.hosts.first.issues.single.message,
        isNot(contains('first.example.test')),
      );
      expect(
        result.hosts.first.issues.single.message,
        isNot(contains('second.example.test')),
      );
      expect(result.hosts.last.canImport, isTrue);
    });

    test('invalid host fields block that candidate without leaking values', () {
      const dangerous = 'INVALID_VALUE_CANARY_9302';
      final result = AnsibleInventoryImporter.parse('''
[hosts]
bad ansible_host="$dangerous" ansible_user="user with spaces" ansible_port=70000
good ansible_host=good.example.test ansible_connection=ssh
''');

      expect(result.blocksWholeFile, isFalse);
      expect(result.hosts, hasLength(2));
      expect(result.hosts.first.canImport, isFalse);
      expect(result.hosts.last.canImport, isTrue);
      expect(
        result.hosts.first.issues.map((issue) => issue.code),
        contains('invalid_variable'),
      );
      expect(
        result.hosts.first.issues.every(
          (issue) => !issue.message.contains(dangerous),
        ),
        isTrue,
      );
    });

    test('blocks group cycles and malformed sections', () {
      final cycle = AnsibleInventoryImporter.parse('''
[a:children]
b
[b:children]
a
[a]
host
''');
      expect(cycle.blocksWholeFile, isTrue);
      expect(cycle.hosts, isEmpty);
      expect(cycle.issues.single.code, 'group_cycle');

      final malformed = AnsibleInventoryImporter.parse('''
[web:magic]
host
''');
      expect(malformed.blocksWholeFile, isTrue);
      expect(malformed.hosts, isEmpty);
    });

    test('enforces file, line, host, and group bounds', () {
      final oversized = AnsibleInventoryImporter.parse(
        'x' * (maxAnsibleInventoryBytes + 1),
      );
      expect(oversized.blocksWholeFile, isTrue);
      expect(oversized.issues.single.code, 'file_too_large');

      final tooManyLines = AnsibleInventoryImporter.parse(
        List.filled(4097, '').join('\n'),
      );
      expect(tooManyLines.blocksWholeFile, isTrue);
      expect(tooManyLines.issues.single.code, 'too_many_lines');

      final tooLongLine = AnsibleInventoryImporter.parse(
        'x' * 8193,
        format: AnsibleInventoryFormat.ini,
      );
      expect(tooLongLine.blocksWholeFile, isTrue);
      expect(tooLongLine.issues.single.code, 'line_too_long');

      final tooManyHosts = AnsibleInventoryImporter.parse(
        '[servers]\n${List.generate(513, (i) => 'host-$i').join('\n')}',
      );
      expect(tooManyHosts.blocksWholeFile, isTrue);
      expect(tooManyHosts.hosts, isEmpty);

      final groups = List.generate(129, (i) => '[g$i]\nhost-$i').join('\n');
      final tooManyGroups = AnsibleInventoryImporter.parse(groups);
      expect(tooManyGroups.blocksWholeFile, isTrue);
      expect(tooManyGroups.hosts, isEmpty);
    });

    test('rejects controls and dynamic executable inventory shebangs', () {
      for (final source in [
        'app\u0000 ansible_host=app.example.test\n',
        '#!/usr/bin/env python3\nprint("marker")\n',
      ]) {
        final result = AnsibleInventoryImporter.parse(
          source,
          format: AnsibleInventoryFormat.ini,
        );
        expect(result.blocksWholeFile, isTrue);
        expect(result.hosts, isEmpty);
      }
    });
  });
}
