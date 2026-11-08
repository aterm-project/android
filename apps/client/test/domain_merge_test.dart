import 'package:aterm_client/domain/ansible_inventory_metadata.dart';
import 'package:aterm_client/domain/merge.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host tags trim labels and drop empty or duplicate entries', () {
    expect(parseHostTags(' production, api ,, production, API '), [
      'production',
      'api',
    ]);
  });

  test('HostRecord round-trips tags through the encrypted record DTO', () {
    final host = HostRecord.fromJson({
      'id': 'host-1',
      'name': 'Edge',
      'address': 'edge.example.test',
      'username': 'ops',
      'tags': ['production', 'api'],
    });

    expect(host.tags, ['production', 'api']);
    expect(host.toJson()['tags'], ['production', 'api']);
  });

  test('Ansible import metadata round-trips inside the Host manifest', () {
    const sourceId = '11111111-1111-4111-8111-111111111111';
    final metadata = AnsibleInventoryImportMetadata(
      sourceId: sourceId,
      sourceLabel: 'Production inventory',
      entryKey: 'web-01',
      baseline: AnsibleInventoryImportedValues(
        name: 'web-01',
        address: '192.0.2.11',
        port: 22,
        username: 'deploy',
        tags: const ['web'],
      ),
    );
    final host = HostRecord(
      id: '22222222-2222-4222-8222-222222222222',
      name: 'web-01',
      address: '192.0.2.11',
      username: 'deploy',
      manifest: const {
        'object_refs': [
          {'object_id': '33333333-3333-4333-8333-333333333333'},
        ],
        'future_extension': {'retained': true},
      },
    ).copyWithAnsibleInventoryImport(metadata);

    final decoded = HostRecord.fromJson(host.toJson());
    expect(decoded.ansibleInventoryImport?.toJson(), metadata.toJson());
    expect(
      decoded
          .copyWith(name: 'Manually renamed')
          .ansibleInventoryImport
          ?.toJson(),
      metadata.toJson(),
    );
    expect(decoded.manifest?['object_refs'], host.manifest?['object_refs']);
    expect(
      decoded.manifest?['future_extension'],
      host.manifest?['future_extension'],
    );

    final detached = decoded.copyWithAnsibleInventoryImport(null);
    expect(detached.ansibleInventoryImport, isNull);
    expect(detached.manifest?.containsKey('object_refs'), isTrue);
    expect(detached.manifest?.containsKey('future_extension'), isTrue);
  });

  test('Ansible import metadata rejects unknown schema and secret fields', () {
    const sourceId = '11111111-1111-4111-8111-111111111111';
    final metadata = AnsibleInventoryImportMetadata(
      sourceId: sourceId,
      sourceLabel: 'Prod',
      entryKey: 'web-01',
      baseline: AnsibleInventoryImportedValues(
        name: 'web-01',
        address: '192.0.2.11',
        port: 22,
        username: 'deploy',
        tags: const [],
      ),
    );
    final futureSchema = metadata.toJson()..['schema_version'] = 2;
    expect(
      () => AnsibleInventoryImportMetadata.fromJson(futureSchema),
      throwsFormatException,
    );
    final secretField = metadata.toJson()..['ansible_password'] = 'secret';
    expect(
      () => AnsibleInventoryImportMetadata.fromJson(secretField),
      throwsFormatException,
    );
  });

  test('Ansible metadata constructor rejects invalid tag provenance', () {
    expect(
      () => AnsibleInventoryImportMetadata(
        sourceId: '11111111-1111-4111-8111-111111111111',
        sourceLabel: 'Production inventory',
        entryKey: 'web-01',
        baseline: AnsibleInventoryImportedValues(
          name: 'web-01',
          address: '192.0.2.11',
          port: 22,
          username: 'deploy',
          tags: const [],
        ),
        retainedTags: const ['invalid\nvalue'],
      ),
      throwsFormatException,
    );
  });

  test(
    'HostRecord reads a sync revision without putting it in plaintext JSON',
    () {
      final host = HostRecord.fromJson({
        'id': '22222222-2222-4222-8222-222222222222',
        'name': 'web-01',
        'address': '192.0.2.11',
        'username': 'deploy',
        'revision_id': '44444444-4444-4444-8444-444444444444',
      });
      expect(host.revisionId, '44444444-4444-4444-8444-444444444444');
      expect(host.toJson().containsKey('revision_id'), isFalse);
    },
  );

  test('HostRecord jump Host is backward compatible and round-trips', () {
    final oldRecord = HostRecord.fromJson({
      'id': 'legacy-host',
      'name': 'Legacy',
      'address': 'legacy.example.test',
      'username': 'ops',
    });
    expect(oldRecord.jumpHostId, isNull);

    final host = oldRecord.copyWith(jumpHostId: 'bastion-id');
    expect(host.toJson()['jump_host_id'], 'bastion-id');
    expect(HostRecord.fromJson(host.toJson()).jumpHostId, 'bastion-id');
    expect(host.copyWith(clearJumpHost: true).jumpHostId, isNull);
  });

  test(
    'HostRecord saves encrypted forwarding profiles and accepts old rows',
    () {
      final oldRecord = HostRecord.fromJson({
        'id': 'legacy-host',
        'name': 'Legacy',
        'address': 'legacy.example.test',
        'username': 'ops',
      });
      expect(oldRecord.portForwardProfiles, isEmpty);
      expect(oldRecord.toJson().containsKey('port_forward_profiles'), isFalse);

      const local = SshPortForwardProfile(
        id: 'forward-1',
        name: 'Database tunnel',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 15432,
        destinationAddress: 'db.internal',
        destinationPort: 5432,
      );
      final updated = oldRecord.copyWith(portForwardProfiles: const [local]);
      expect(updated.validate(), isNull);
      expect(updated.toJson()['port_forward_profiles'], [local.toJson()]);
      expect(
        HostRecord.fromJson(
          updated.toJson(),
        ).portForwardProfiles.single.toJson(),
        local.toJson(),
      );
      expect(conflictKindFor('port_forward_profiles'), ConflictKind.security);
    },
  );

  test(
    'forward profiles reject public listeners and malformed destinations',
    () {
      const exposed = SshPortForwardProfile(
        id: 'forward-1',
        name: 'Exposed tunnel',
        type: SshPortForwardType.remote,
        bindAddress: '0.0.0.0',
        bindPort: 15432,
        destinationAddress: '127.0.0.1',
        destinationPort: 5432,
      );
      expect(
        exposed.validate(),
        'Forward listeners must bind to loopback unless network exposure is confirmed',
      );
      // Explicit acknowledgement allows standard -R/-L wildcard binds and
      // round-trips through the encrypted Host JSON.
      final acknowledged = exposed.copyWith(exposeToNetwork: true);
      expect(acknowledged.validate(), isNull);
      expect(acknowledged.exposesBeyondLoopback, isTrue);
      expect(acknowledged.toJson()['expose_to_network'], isTrue);
      expect(
        SshPortForwardProfile.fromJson(acknowledged.toJson()),
        acknowledged,
      );
      // Loopback-only profiles keep their exact previous JSON shape.
      expect(
        exposed
            .copyWith(bindAddress: '127.0.0.1')
            .toJson()
            .containsKey('expose_to_network'),
        isFalse,
      );
      expect(
        () => SshPortForwardProfile.fromJson({
          ...acknowledged.toJson(),
          'expose_to_network': 'yes',
        }),
        throwsFormatException,
      );
      // Host names are not accepted as listener addresses (no DNS at bind).
      expect(
        exposed.copyWith(bindAddress: 'evil.example', exposeToNetwork: true)
            .validate(),
        'Forward listener address must be localhost or an IP address',
      );
      expect(isLoopbackForwardAddress('127.0.0.2'), isTrue);
      expect(isLoopbackForwardAddress('::ffff:127.0.0.1'), isTrue);
      expect(isLoopbackForwardAddress('0.0.0.0'), isFalse);
      expect(isLoopbackForwardAddress('::'), isFalse);

      const malformed = SshPortForwardProfile(
        id: 'forward-2',
        name: 'Bad destination',
        type: SshPortForwardType.local,
        bindAddress: 'localhost',
        bindPort: 15432,
        destinationAddress: 'db.internal\n127.0.0.1',
        destinationPort: 5432,
      );
      expect(malformed.validate(), 'Forward destination host is invalid');

      const remoteToLan = SshPortForwardProfile(
        id: 'forward-3',
        name: 'LAN proxy',
        type: SshPortForwardType.remote,
        bindAddress: '127.0.0.1',
        bindPort: 9000,
        destinationAddress: '192.168.1.9',
        destinationPort: 9001,
      );
      expect(
        remoteToLan.validate(),
        'Remote forwarding targets must use this device loopback unless network exposure is confirmed',
      );
      expect(remoteToLan.copyWith(exposeToNetwork: true).validate(), isNull);

      const local = SshPortForwardProfile(
        id: 'forward-local',
        name: 'Local database',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 5432,
        destinationAddress: 'db.internal',
        destinationPort: 5432,
      );
      const dynamic = SshPortForwardProfile(
        id: 'forward-dynamic',
        name: 'SOCKS proxy',
        type: SshPortForwardType.dynamic,
        bindAddress: 'localhost',
        bindPort: 5432,
      );
      expect(
        const HostRecord(
          id: 'host-1',
          name: 'Edge',
          address: 'edge.example.test',
          username: 'ops',
          portForwardProfiles: [local, dynamic],
        ).validate(),
        'Forward listener address and port must be unique',
      );
      expect(
        () => HostRecord.fromJson({
          'id': 'host-1',
          'name': 'Edge',
          'address': 'edge.example.test',
          'username': 'ops',
          'port_forward_profiles': [local.toJson(), dynamic.toJson()],
        }),
        throwsFormatException,
      );
    },
  );

  group('HostRecord validation', () {
    test('requires identity fields and validates the TCP port range', () {
      expect(
        const HostRecord(
          id: 'host-1',
          name: '  ',
          address: 'ssh.example.test',
          username: 'admin',
        ).validate(),
        'Host name is required',
      );
      expect(
        const HostRecord(
          id: 'host-1',
          name: 'Build host',
          address: 'ssh.example.test',
          port: 65536,
          username: 'admin',
        ).validate(),
        'Port must be between 1 and 65535',
      );
      expect(
        const HostRecord(
          id: 'host-1',
          name: 'Build host',
          address: 'ssh.example.test',
          username: 'admin',
        ).validate(),
        isNull,
      );
    });
  });

  test('record DTOs preserve reserved manifests when serialized for edits', () {
    const manifest = <String, Object?>{
      'object_refs': ['40000000-0000-4000-8000-000000000001'],
      'extension_version': 1,
    };

    final host = HostRecord.fromJson({
      'id': 'host-1',
      'name': 'Host',
      'address': 'host.example.test',
      'username': 'ops',
      '_manifest': manifest,
    });
    expect(host.copyWith(name: 'Edited host').toJson()['_manifest'], manifest);

    final credential = CredentialRecord.fromJson({
      'id': 'credential-1',
      'name': 'Credential',
      'username': 'ops',
      'kind': 'password',
      'secret': 'test-only',
      '_manifest': manifest,
    });
    expect(credential.toJson()['_manifest'], manifest);

    final group = GroupRecord.fromJson({
      'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'type': 'group',
      'name': 'Group',
      'color': 0,
      'parent_id': null,
      '_manifest': manifest,
    });
    expect(group.toJson()['_manifest'], manifest);

    final snippet = SnippetRecord.fromJson({
      'id': 'snippet-1',
      'title': 'Snippet',
      'body': 'true',
      '_manifest': manifest,
    });
    expect(snippet.toJson()['_manifest'], manifest);
  });

  group('three-way sync merge', () {
    void expectCleanChangeToRequireReview({
      required Map<String, Object?> base,
      required String field,
      required Object? value,
    }) {
      final remote = Map<String, Object?>.of(base)..[field] = value;
      final merged = mergeRecord(base: base, local: base, remote: remote);

      expect(merged.clean, isTrue, reason: '$field should merge cleanly');
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: base,
          remote: remote,
          result: merged,
        ),
        isFalse,
        reason: '$field must require explicit review',
      );
    }

    test('merges independent edits and retains both conflicting branches', () {
      final merged = mergeRecord(
        base: const {'name': 'Build', 'address': 'old.example', 'port': 22},
        local: const {
          'name': 'Build staging',
          'address': 'local.example',
          'port': 22,
        },
        remote: const {
          'name': 'Build',
          'address': 'remote.example',
          'port': 2202,
        },
      );

      expect(merged.clean, isFalse);
      expect(merged.value['name'], 'Build staging');
      expect(merged.value['port'], 2202);
      expect(merged.conflicts.keys, contains('address'));
      expect(merged.conflicts['address']?.local, 'local.example');
      expect(merged.conflicts['address']?.remote, 'remote.example');
      expect(conflictKindFor('address'), ConflictKind.security);
    });

    test('never silently resolves credential conflicts', () {
      final merged = mergeRecord(
        base: const {'credential_id': 'old'},
        local: const {'credential_id': 'local'},
        remote: const {'credential_id': 'remote'},
      );

      expect(merged.clean, isFalse);
      expect(merged.conflicts['credential_id']?.base, 'old');
      expect(merged.conflicts['credential_id']?.local, 'local');
      expect(merged.conflicts['credential_id']?.remote, 'remote');
      expect(conflictKindFor('credential_id'), ConflictKind.credential);
    });

    test('Jump Host route changes are security conflicts', () {
      final merged = mergeRecord(
        base: const {'jump_host_id': 'jump-before'},
        local: const {'jump_host_id': 'jump-local'},
        remote: const {'jump_host_id': 'jump-remote'},
      );

      expect(merged.clean, isFalse);
      expect(merged.conflicts['jump_host_id']?.local, 'jump-local');
      expect(merged.conflicts['jump_host_id']?.remote, 'jump-remote');
      expect(conflictKindFor('jump_host_id'), ConflictKind.security);
    });

    test('automatic merge allows only distinct low-risk fields', () {
      const base = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Base',
        'address': 'old.example',
        'username': 'ops',
        'tags': <String>[],
      };
      const local = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Local name',
        'address': 'old.example',
        'username': 'ops',
        'tags': <String>[],
      };
      const remote = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Base',
        'address': 'old.example',
        'username': 'ops',
        'tags': <String>['production'],
      };
      final merged = mergeRecord(base: base, local: local, remote: remote);

      expect(
        isAutomaticMergeSafe(
          base: base,
          local: local,
          remote: remote,
          result: merged,
        ),
        isTrue,
      );
      expect(merged.value['name'], 'Local name');
      expect(merged.value['tags'], ['production']);
    });

    test('automatic merge refuses security and unknown field changes', () {
      const base = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Base',
        'address': 'old.example',
      };
      const local = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Local name',
        'address': 'old.example',
      };
      const remoteSecurityChange = {
        'id': 'host-1',
        'type': 'host',
        'name': 'Base',
        'address': 'new.example',
      };
      final securityMerge = mergeRecord(
        base: base,
        local: local,
        remote: remoteSecurityChange,
      );
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: local,
          remote: remoteSecurityChange,
          result: securityMerge,
        ),
        isFalse,
      );

      final unknownChange = <String, Object?>{
        ...remoteSecurityChange,
        'vendor_extension': 'opaque',
      };
      final unknownMerge = mergeRecord(
        base: base,
        local: base,
        remote: unknownChange,
      );
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: base,
          remote: unknownChange,
          result: unknownMerge,
        ),
        isFalse,
      );

      final usernameChange = <String, Object?>{...base, 'username': 'deploy'};
      final usernameMerge = mergeRecord(
        base: base,
        local: base,
        remote: usernameChange,
      );
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: base,
          remote: usernameChange,
          result: usernameMerge,
        ),
        isFalse,
      );
    });

    test('Group automatically merges independent name and color edits', () {
      const base = <String, Object?>{
        'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'type': 'group',
        'name': 'Production',
        'color': 0x112233,
        'parent_id': null,
        'default_credential_id': null,
      };
      final local = <String, Object?>{...base, 'name': 'Production west'};
      final remote = <String, Object?>{...base, 'color': 0x334455};
      final merged = mergeRecord(base: base, local: local, remote: remote);

      expect(merged.clean, isTrue);
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: local,
          remote: remote,
          result: merged,
        ),
        isTrue,
      );
      expect(merged.value['name'], 'Production west');
      expect(merged.value['color'], 0x334455);
    });

    test('Group reference and unknown edits require explicit review', () {
      const base = <String, Object?>{
        'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'type': 'group',
        'name': 'Production',
        'color': 0x112233,
        'parent_id': null,
        'default_credential_id': null,
      };

      expectCleanChangeToRequireReview(
        base: base,
        field: 'parent_id',
        value: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      );
      expectCleanChangeToRequireReview(
        base: base,
        field: 'default_credential_id',
        value: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      expectCleanChangeToRequireReview(
        base: base,
        field: 'vendor_extension',
        value: 'opaque',
      );
    });

    test(
      'Credential name edits are automatic while other fields are reviewed',
      () {
        const base = <String, Object?>{
          'id': 'credential-1',
          'type': 'credential',
          'name': 'Deploy key',
          'username': 'deploy',
          'kind': 'privateKey',
          'secret': 'old secret fixture',
          'private_key': 'old private key fixture',
          'passphrase': 'old passphrase fixture',
          'fingerprint': 'SHA256:old-fixture',
        };
        final local = <String, Object?>{
          ...base,
          'name': 'Production deploy key',
        };
        final merged = mergeRecord(base: base, local: local, remote: base);

        expect(merged.clean, isTrue);
        expect(
          isAutomaticMergeSafe(
            base: base,
            local: local,
            remote: base,
            result: merged,
          ),
          isTrue,
        );
        expect(merged.value['name'], 'Production deploy key');

        for (final change in <String, Object?>{
          'username': 'operator',
          'kind': 'password',
          'secret': 'new secret fixture',
          'private_key': 'new private key fixture',
          'passphrase': 'new passphrase fixture',
          'fingerprint': 'SHA256:new-fixture',
          'vendor_extension': 'opaque',
        }.entries) {
          expectCleanChangeToRequireReview(
            base: base,
            field: change.key,
            value: change.value,
          );
        }
      },
    );

    test('Snippet automatically merges independent title and tag edits', () {
      const base = <String, Object?>{
        'id': 'snippet-1',
        'type': 'snippet',
        'title': 'Health check',
        'body': 'echo healthy',
        'shell_kind': 'bash',
        'execution_mode': 'script',
        'program': '',
        'arguments': <Object?>[],
        'parameters': <Object?>[],
        'tags': <String>[],
      };
      final local = <String, Object?>{...base, 'title': 'Service health check'};
      final remote = <String, Object?>{
        ...base,
        'tags': ['operations'],
      };
      final merged = mergeRecord(base: base, local: local, remote: remote);

      expect(merged.clean, isTrue);
      expect(
        isAutomaticMergeSafe(
          base: base,
          local: local,
          remote: remote,
          result: merged,
        ),
        isTrue,
      );
      expect(merged.value['title'], 'Service health check');
      expect(merged.value['tags'], ['operations']);
    });

    test('Snippet executable structure and unknown edits require review', () {
      const base = <String, Object?>{
        'id': 'snippet-1',
        'type': 'snippet',
        'title': 'Health check',
        'body': 'echo healthy',
        'shell_kind': 'bash',
        'execution_mode': 'script',
        'program': '',
        'arguments': <Object?>[],
        'parameters': <Object?>[],
        'tags': <String>[],
      };

      for (final change in <String, Object?>{
        'body': 'curl https://example.test',
        'shell_kind': 'zsh',
        'execution_mode': 'bashCommand',
        'program': 'curl',
        'arguments': const [
          {'kind': 'literal', 'value': 'https://example.test'},
        ],
        'parameters': const [
          {'name': 'target', 'type': 'text'},
        ],
        'vendor_extension': 'opaque',
      }.entries) {
        expectCleanChangeToRequireReview(
          base: base,
          field: change.key,
          value: change.value,
        );
      }
    });

    test(
      'preference conflict keeps local candidate and exposes remote branch',
      () {
        final merged = mergeRecord(
          base: const {
            'type': 'preference',
            'scope': 'workspace',
            'key': 'defaultSection',
            'platform_family': 'all',
            'value': 'hosts',
          },
          local: const {
            'type': 'preference',
            'scope': 'workspace',
            'key': 'defaultSection',
            'platform_family': 'all',
            'value': 'snippets',
          },
          remote: const {
            'type': 'preference',
            'scope': 'workspace',
            'key': 'defaultSection',
            'platform_family': 'all',
            'value': 'credentials',
          },
        );

        expect(merged.clean, isFalse);
        expect(merged.value['value'], 'snippets');
        expect(merged.conflicts['value']?.local, 'snippets');
        expect(merged.conflicts['value']?.remote, 'credentials');
      },
    );
  });
}
