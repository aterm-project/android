import 'package:aterm_client/domain/host_security_conflict_merge.dart';
import 'package:flutter_test/flutter_test.dart';

const _recordId = '11111111-1111-4111-8111-111111111111';
const _jumpA = '22222222-2222-4222-8222-222222222222';
const _jumpB = '33333333-3333-4333-8333-333333333333';

void main() {
  test(
    'review preview shows base and both branches but masks proxy and trust',
    () {
      final base = _host(
        address: 'prod.example.test',
        port: 22,
        proxy: null,
        jumpHostId: null,
        hostKey: null,
      );
      final conflict = _host(
        address: 'staging.example.test',
        port: 22,
        proxy: 'proxy-user:proxy-secret@proxy.example.test',
        jumpHostId: _jumpA,
        hostKey: 'conflict-host-private-trust-material',
        credentialId: 'conflict-credential-id',
      );
      final current = _host(
        address: 'prod.example.test',
        port: 2202,
        proxy: null,
        jumpHostId: _jumpB,
        hostKey: 'current-host-private-trust-material',
      );

      final preview = previewHostSecurityConflict(
        conflictId: _recordId,
        recordId: _recordId,
        baseRevisionId: _jumpA,
        branchRevisionId: _jumpB,
        currentHeadRevisionId: _recordId,
        base: base,
        conflict: conflict,
        current: current,
      );

      expect(preview, isNotNull);
      final fields = {for (final field in preview!.fields) field.label: field};
      expect(fields['Address']?.base, 'prod.example.test');
      expect(fields['Address']?.conflict, 'staging.example.test');
      expect(fields['Port']?.current, '2202');
      expect(fields['SSH username']?.base, 'deploy');
      expect(fields['Authentication']?.base, 'password');
      expect(
        fields['SSH credential override']?.conflict,
        '•••••••• (selected)',
      );
      expect(fields['Proxy settings']?.conflict, '••••••••');
      expect(fields['Jump Host route']?.conflict, startsWith('Host '));
      expect(fields['Host trust']?.conflict, '•••••••• (configured)');
      expect(preview.toString(), isNot(contains('proxy-secret')));
      expect(preview.toString(), isNot(contains('private-trust-material')));
    },
  );

  test(
    'selected branch supplies whole security tuple while independent fields merge',
    () {
      final base = _host(
        address: 'prod.example.test',
        port: 22,
        name: 'Prod',
        tags: const ['base'],
      );
      final conflict = _host(
        address: 'staging.example.test',
        port: 22,
        name: 'Staging name',
        tags: const ['base'],
        username: 'staging-user',
        authKind: 'privateKey',
        credentialId: 'conflict-credential-id',
      );
      final current = _host(
        address: 'prod.example.test',
        port: 2202,
        name: 'Prod',
        tags: const ['remote'],
        username: 'prod-user',
        authKind: 'password',
        credentialId: 'current-credential-id',
      );

      final merged = mergeHostSecurityConflictRecord(
        recordId: _recordId,
        base: base,
        conflict: conflict,
        current: current,
        choice: HostSecurityMergeBranch.conflict,
      );

      expect(merged, isNotNull);
      expect(merged!['address'], 'staging.example.test');
      // Address and port never form a tuple assembled from opposite branches.
      expect(merged['port'], 22);
      expect(merged['username'], 'staging-user');
      expect(merged['auth_kind'], 'privateKey');
      expect(merged['credential_id'], 'conflict-credential-id');
      expect(merged['name'], 'Staging name');
      expect(merged['tags'], ['remote']);
    },
  );

  test('current tuple choice retains all current connection fields', () {
    final base = _host(address: 'prod.example.test', port: 22);
    final conflict = _host(
      address: 'staging.example.test',
      port: 22,
      proxy: 'secret-proxy-config',
      jumpHostId: _jumpA,
    );
    final current = _host(
      address: 'prod.example.test',
      port: 2202,
      proxy: 'current-proxy-config',
      jumpHostId: _jumpB,
      hostKey: 'current-trust-key',
    );

    final merged = mergeHostSecurityConflictRecord(
      recordId: _recordId,
      base: base,
      conflict: conflict,
      current: current,
      choice: HostSecurityMergeBranch.current,
    );

    expect(merged, isNotNull);
    expect(merged!['address'], 'prod.example.test');
    expect(merged['port'], 2202);
    expect(merged['proxy'], 'current-proxy-config');
    expect(merged['jump_host_id'], _jumpB);
    expect(merged['host_key'], 'current-trust-key');
  });

  test(
    'fails closed for unsupported fields, unrelated conflicts, and one-sided changes',
    () {
      final base = _host(address: 'prod.example.test', port: 22);
      final conflict = _host(address: 'staging.example.test', port: 22);
      final current = _host(address: 'prod.example.test', port: 2202);

      expect(
        mergeHostSecurityConflictRecord(
          recordId: _recordId,
          base: base,
          conflict: {
            ...conflict,
            'future_auth_extension': {'key': 'value'},
          },
          current: current,
          choice: HostSecurityMergeBranch.conflict,
        ),
        isNull,
      );
      expect(
        mergeHostSecurityConflictRecord(
          recordId: _recordId,
          base: base,
          conflict: {...conflict, 'name': 'Conflict name'},
          current: {...current, 'name': 'Current name'},
          choice: HostSecurityMergeBranch.conflict,
        ),
        isNull,
      );
      expect(
        previewHostSecurityConflict(
          conflictId: _recordId,
          recordId: _recordId,
          baseRevisionId: _jumpA,
          branchRevisionId: _jumpB,
          currentHeadRevisionId: _recordId,
          base: base,
          conflict: conflict,
          current: base,
        ),
        isNull,
      );
      expect(
        previewHostSecurityConflict(
          conflictId: _recordId,
          recordId: _recordId,
          baseRevisionId: _jumpA,
          branchRevisionId: _jumpB,
          currentHeadRevisionId: _recordId,
          base: base,
          conflict: {...conflict, 'auth_kind': 'future-auth'},
          current: current,
        ),
        isNull,
      );
    },
  );
}

Map<String, Object?> _host({
  required String address,
  required int port,
  String name = 'Production Host',
  List<String> tags = const [],
  String username = 'deploy',
  String authKind = 'password',
  String? credentialId,
  String? proxy,
  String? jumpHostId,
  String? hostKey,
}) => {
  'id': _recordId,
  'type': 'host',
  'name': name,
  'address': address,
  'port': port,
  'username': username,
  'auth_kind': authKind,
  'credential_id': credentialId,
  'jump_host_id': jumpHostId,
  'proxy': proxy,
  'host_key': hostKey,
  'tags': tags,
};
