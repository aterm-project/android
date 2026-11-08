import 'package:aterm_client/domain/ansible_inventory_metadata.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/ansible_inventory_import.dart';
import 'package:aterm_client/import/ansible_inventory_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';
const _hostId = '22222222-2222-4222-8222-222222222222';
const _credentialId = '33333333-3333-4333-8333-333333333333';
const _jumpHostId = '44444444-4444-4444-8444-444444444444';
const _revisionId = '55555555-5555-4555-8555-555555555555';

void main() {
  group('planAnsibleInventoryRefresh', () {
    test('creates Hosts with encrypted source identity and safe baseline', () {
      const secret = 'ANSIBLE_REFRESH_PASSWORD_CANARY';
      final parsed = AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.11 ansible_user=deploy ansible_password=$secret
''');
      final plan = planAnsibleInventoryRefresh(
        parsed: parsed,
        savedHosts: const [],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
        createHostId: () => _hostId,
      );

      expect(plan.createCount, 1);
      expect(plan.staleMarkingAllowed, isTrue);
      final host = plan.actionableRows.single.plannedHost!;
      expect(host.id, _hostId);
      expect(host.ansibleInventoryImport?.sourceId, _sourceId);
      expect(host.ansibleInventoryImport?.entryKey, 'web-01');
      expect(host.ansibleInventoryImport?.baseline.address, '192.0.2.11');
      expect(host.toJson().toString(), isNot(contains(secret)));
    });

    test('updates source fields and preserves unrelated Host data', () {
      final current = _savedHost(tags: const ['manual', 'web']);
      final parsed = AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy ansible_port=2200
''');
      final plan = planAnsibleInventoryRefresh(
        parsed: parsed,
        savedHosts: [current],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
      );

      expect(plan.updateCount, 1);
      expect(plan.rows.single.hasConflict, isFalse);
      final updated = plan.rows.single.plannedHost!;
      expect(updated.address, '192.0.2.12');
      expect(updated.port, 2200);
      expect(updated.username, 'deploy');
      expect(updated.tags, containsAll(['manual', 'web']));
      expect(updated.credentialId, _credentialId);
      expect(updated.jumpHostId, _jumpHostId);
      expect(updated.groupId, 'existing-group');
      expect(updated.isFavorite, isTrue);
      expect(updated.portForwardProfiles, hasLength(1));
      expect(
        updated.manifest?['object_refs'],
        current.manifest?['object_refs'],
      );
      expect(updated.manifest?['other_namespace'], {'preserve': true});
      expect(updated.ansibleInventoryImport?.baseline.address, '192.0.2.12');
    });

    test(
      'three-way conflict defaults to the manual value and offers a choice',
      () {
        final current = _savedHost(address: '192.0.2.99');
        final parsed = AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
''');
        final row = planAnsibleInventoryRefresh(
          parsed: parsed,
          savedHosts: [current],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        ).rows.single;
        final address = row.fields.singleWhere(
          (field) => field.key == 'address',
        );

        expect(row.hasConflict, isTrue);
        expect(address.conflict, isTrue);
        expect(address.current, '192.0.2.99');
        expect(address.incoming, '192.0.2.12');
        expect(row.plannedHost?.address, '192.0.2.99');

        final useInventory = row.resolveConflicts(
          useInventoryFields: const {'address'},
        );
        expect(useInventory.plannedHost?.address, '192.0.2.12');
        expect(
          useInventory.fields
              .singleWhere((field) => field.key == 'address')
              .proposed,
          '192.0.2.12',
        );
        expect(
          useInventory.plannedHost?.ansibleInventoryImport?.baseline.address,
          '192.0.2.12',
        );
      },
    );

    test('does not repeat an already reviewed manual-value conflict', () {
      final current = _savedHost(address: '192.0.2.99');
      final parsed = AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
''');
      final first = planAnsibleInventoryRefresh(
        parsed: parsed,
        savedHosts: [current],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
      ).rows.single.plannedHost!;
      final second = planAnsibleInventoryRefresh(
        parsed: parsed,
        savedHosts: [
          first.copyWith(revisionId: '66666666-6666-4666-8666-666666666666'),
        ],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
      ).rows.single;

      expect(second.hasConflict, isFalse);
      expect(second.plannedHost?.address, '192.0.2.99');
      expect(second.status, AnsibleInventoryRefreshStatus.unchanged);
    });

    test(
      'marks missing entries stale only after a complete non-empty parse',
      () {
        final web = _savedHost();
        final db = _savedHost(
          id: '66666666-6666-4666-8666-666666666666',
          name: 'db-01',
          entryKey: 'db-01',
          address: '192.0.2.21',
        );
        final complete = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.11 ansible_user=deploy
'''),
          savedHosts: [web, db],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );
        expect(complete.staleMarkingAllowed, isTrue);
        expect(complete.staleCount, 1);
        expect(
          complete.rows
              .singleWhere(
                (row) => row.status == AnsibleInventoryRefreshStatus.missing,
              )
              .plannedHost
              ?.ansibleInventoryImport
              ?.state,
          AnsibleInventoryEntryState.stale,
        );

        final empty = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse(''),
          savedHosts: [web, db],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );
        expect(empty.staleMarkingAllowed, isFalse);
        expect(empty.staleCount, 0);

        final dynamic = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse('plugin: amazon.aws.aws_ec2'),
          savedHosts: [web, db],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );
        expect(dynamic.staleMarkingAllowed, isFalse);
        expect(dynamic.staleCount, 0);
      },
    );

    test(
      'partial input and missing revisions fail closed for stale updates',
      () {
        final web = _savedHost();
        final db = _savedHost(
          id: '66666666-6666-4666-8666-666666666666',
          name: 'db-01',
          entryKey: 'db-01',
          address: '192.0.2.21',
        );
        final partial = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
bad-01 ansible_host=192.0.2.30 ansible_user=deploy ansible_port=0
'''),
          savedHosts: [web, db],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );
        expect(partial.staleMarkingAllowed, isFalse);
        expect(partial.staleCount, 0);

        final noRevision = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.12 ansible_user=deploy
'''),
          savedHosts: [_savedHost(revisionId: null)],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );
        expect(noRevision.blockedCount, 1);
        expect(noRevision.actionableRows, isEmpty);
      },
    );

    test(
      'duplicate saved source identities are blocked and never marked stale',
      () {
        final first = _savedHost();
        final duplicate = _savedHost(
          id: '66666666-6666-4666-8666-666666666666',
        );
        final plan = planAnsibleInventoryRefresh(
          parsed: AnsibleInventoryImporter.parse('''
[web]
web-01 ansible_host=192.0.2.11 ansible_user=deploy
'''),
          savedHosts: [first, duplicate],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );

        expect(plan.staleMarkingAllowed, isTrue);
        expect(plan.blockedCount, 1);
        expect(plan.staleCount, 0);
      },
    );

    test(
      'tag merge over storage limit is blocked without dropping manual tags',
      () {
        final candidate = AnsibleInventoryHost(
          name: 'web-01',
          address: '192.0.2.11',
          username: 'deploy',
          port: 22,
          groups: List.generate(128, (index) => 'group_$index'),
          sourceLine: 1,
          issues: const [],
        );
        final parsed = AnsibleInventoryParseResult(
          format: AnsibleInventoryFormat.ini,
          hosts: [candidate],
          issues: const [],
          blocksWholeFile: false,
        );
        final current = _savedHost(tags: const ['web', 'manual']);
        final plan = planAnsibleInventoryRefresh(
          parsed: parsed,
          savedHosts: [current],
          sourceId: _sourceId,
          sourceLabel: 'Production inventory',
        );

        expect(plan.blockedCount, 1);
        expect(plan.actionableRows, isEmpty);
        expect(plan.rows.single.existing?.tags, ['web', 'manual']);
        expect(plan.rows.single.note, contains('128-tag storage limit'));
      },
    );

    test('manual tag removals stay suppressed across later refreshes', () {
      final first = planAnsibleInventoryRefresh(
        parsed: AnsibleInventoryImporter.parse('''
[web]
web-01
[database]
web-01 ansible_host=192.0.2.11 ansible_user=deploy
'''),
        savedHosts: [
          _savedHost(tags: const ['manual'], baselineTags: const ['web']),
        ],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
      ).rows.single.plannedHost!;
      expect(first.tags, contains('database'));
      expect(first.tags, isNot(contains('web')));

      final second = planAnsibleInventoryRefresh(
        parsed: AnsibleInventoryImporter.parse('''
[web]
web-01
[database]
web-01 ansible_host=192.0.2.11 ansible_user=deploy
'''),
        savedHosts: [
          first.copyWith(revisionId: '77777777-7777-4777-8777-777777777777'),
        ],
        sourceId: _sourceId,
        sourceLabel: 'Production inventory',
      ).rows.single.plannedHost!;
      expect(second.tags, containsAll(['manual', 'database']));
      expect(second.tags, isNot(contains('web')));
    });
  });
}

HostRecord _savedHost({
  String id = _hostId,
  String name = 'web-01',
  String entryKey = 'web-01',
  String address = '192.0.2.11',
  int port = 22,
  String username = 'deploy',
  List<String> tags = const ['web'],
  List<String> baselineTags = const ['web'],
  String? revisionId = _revisionId,
}) {
  final metadata = AnsibleInventoryImportMetadata(
    sourceId: _sourceId,
    sourceLabel: 'Production inventory',
    entryKey: entryKey,
    baseline: AnsibleInventoryImportedValues(
      name: name,
      address: '192.0.2.11',
      port: 22,
      username: 'deploy',
      tags: baselineTags,
    ),
  );
  return HostRecord(
    id: id,
    name: name,
    address: address,
    port: port,
    username: username,
    groupId: 'existing-group',
    credentialId: _credentialId,
    jumpHostId: _jumpHostId,
    authKind: AuthKind.privateKey,
    tags: tags,
    portForwardProfiles: const [
      SshPortForwardProfile(
        id: '77777777-7777-4777-8777-777777777777',
        name: 'Database',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 15432,
        destinationAddress: 'db.internal',
        destinationPort: 5432,
      ),
    ],
    isFavorite: true,
    revisionId: revisionId,
    manifest: const {
      'object_refs': [
        {'object_id': '88888888-8888-4888-8888-888888888888'},
      ],
      'other_namespace': {'preserve': true},
    },
  ).copyWithAnsibleInventoryImport(metadata);
}
