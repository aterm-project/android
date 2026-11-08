import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _workspaceId = '33333333-3333-4333-8333-333333333333';
const _hostA = '44444444-4444-4444-8444-444444444444';
const _hostB = '55555555-5555-4555-8555-555555555555';
const _paneA = '66666666-6666-4666-8666-666666666666';
const _paneB = '77777777-7777-4777-8777-777777777777';
const _paneC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _localConflictId = '88888888-8888-4888-8888-888888888888';
const _remoteConflictId = '99999999-9999-4999-8999-999999999999';
const _malformedConflictId = 'aaaaaaaa-bbbb-4aaa-8aaa-aaaaaaaaaaaa';
const _unknownSignerConflictId = 'bbbbbbbb-cccc-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('divergent Workspace layouts are never field-wise merged', () async {
    final fixture = await _WorkspaceConflictFixture.create();
    try {
      final base = await fixture.encryptWorkspace(
        WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Base layout',
          hostIds: const [_hostA],
        ).toJson(),
        deviceSequence: '910',
      );
      final local = await fixture.encryptWorkspace(
        WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Local layout',
          hostIds: const [_hostA, _hostB],
          activeIndex: 1,
        ).toJson(),
        deviceSequence: '911',
      );
      final remote = await fixture.encryptWorkspace(
        WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Remote layout',
          hostIds: const [_hostB],
        ).toJson(),
        deviceSequence: '912',
      );
      await fixture.repository.refreshSignerDirectory();

      final merged = await fixture.repository.mergeCandidate(
        baseEnvelopeJson: jsonEncode(base),
        localEnvelopeJson: jsonEncode(local),
        remoteEnvelopeJson: jsonEncode(remote),
      );

      expect(merged, isNull);
    } finally {
      await fixture.close();
    }
  });

  test(
    'saves an encrypted named copy from the local Workspace branch and leaves its conflict open',
    () async {
      final fixture = await _WorkspaceConflictFixture.create();
      try {
        final localWorkspace = WorkspaceRecord.fromSplitTree(
          id: _workspaceId,
          name: 'Local layout branch',
          activePaneId: _paneB,
          layoutTree: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.horizontal,
            splitRatioBasisPoints: 6250,
            first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostB),
            second: WorkspaceSplitNode(
              axis: WorkspaceSplitAxis.vertical,
              splitRatioBasisPoints: 4000,
              first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostA),
              second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostA),
            ),
          ),
          manifest: const {
            'extension': {'version': 1},
          },
        );
        final localEnvelope = await fixture.repository.saveRecord(
          recordId: _workspaceId,
          operation: 'update',
          baseRevisionId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          plaintext: localWorkspace.toJson(),
        );
        final localHeader = localEnvelope['header'] as Map<String, dynamic>;
        await fixture.database.markConflicted(localHeader['op_id'] as String);
        final remoteEnvelope = await fixture.encryptWorkspace(
          WorkspaceRecord.fromHostIds(
            id: _workspaceId,
            name: 'Remote layout branch',
            hostIds: const [_hostA],
          ).toJson(),
          deviceSequence: '900',
        );
        await fixture.database.saveConflict(
          conflictId: _localConflictId,
          vaultId: _vaultId,
          recordId: _workspaceId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          kind: 'concurrent_edit',
          branchEnvelope: Map<String, dynamic>.from(localEnvelope),
          remoteEnvelope: remoteEnvelope,
        );
        final originalConflict = (await fixture.database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).single;

        final copyId = await fixture.repository
            .saveWorkspaceConflictBranchAsNamedCopy(
              conflictId: _localConflictId,
              copyName: '  Saved local layout  ',
            );

        expect(copyId, isNot(_workspaceId));
        final queued = await fixture.database.queuedOperations(_vaultId);
        expect(queued, hasLength(1));
        expect(queued.single.recordId, copyId);
        final copiedEnvelope =
            jsonDecode(queued.single.envelopeJson) as Map<String, dynamic>;
        final copiedHeader = copiedEnvelope['header'] as Map<String, dynamic>;
        expect(copiedHeader['operation'], 'create');
        expect(copiedHeader['base_revision_id'], isNull);
        expect(
          queued.single.envelopeJson,
          isNot(contains('Saved local layout')),
        );
        expect(queued.single.envelopeJson, isNot(contains(_hostA)));
        expect(queued.single.envelopeJson, isNot(contains(_hostB)));

        final copiedPlaintext = await fixture.crypto.decryptRecord(
          vaultKey: Uint8List.fromList(fixture.vaultKey),
          envelope: copiedEnvelope,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        final copy = WorkspaceRecord.fromJson(copiedPlaintext);
        expect(copy.id, copyId);
        expect(copy.name, 'Saved local layout');
        expect(copy.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
        expect(copy.hostIds, const [_hostB, _hostA, _hostA]);
        expect(copy.hostRefs, const [_hostA, _hostB]);
        expect(copy.activeIndex, 1);
        expect(copy.activePaneId, isNot(_paneA));
        expect(copy.activePaneId, isNot(_paneB));
        expect(copy.activePaneId, isNot(_paneC));
        expect(
          copy.panes.map((pane) => pane.paneId).toSet().intersection({
            _paneA,
            _paneB,
            _paneC,
          }),
          isEmpty,
        );
        expect(
          _workspaceLayoutWithoutPaneIdentity(copy.toJson()['layout_tree']),
          _workspaceLayoutWithoutPaneIdentity(
            localWorkspace.toJson()['layout_tree'],
          ),
        );
        expect(copy.manifest, localWorkspace.manifest);

        final stillOpen = await fixture.database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(stillOpen, hasLength(1));
        expect(stillOpen.single.conflictId, _localConflictId);
        expect(stillOpen.single.state, 'open');
        expect(
          stillOpen.single.branchEnvelopeJson,
          originalConflict.branchEnvelopeJson,
        );
        expect(
          stillOpen.single.remoteEnvelopeJson,
          originalConflict.remoteEnvelopeJson,
        );
        expect(
          await fixture.database.conflictedOperation(_vaultId, _workspaceId),
          isNotNull,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'rejects non-Workspace, malformed, and unknown-signer local branches',
    () async {
      final fixture = await _WorkspaceConflictFixture.create();
      final foreignIdentity = DeviceIdentity.create(fixture.sodium);
      try {
        final nonWorkspace = await fixture.encryptWorkspace(const {
          'id': _workspaceId,
          'type': 'host',
          'name': 'Not a layout',
        }, deviceSequence: '901');
        final malformedWorkspace = await fixture.encryptWorkspace(const {
          'id': _workspaceId,
          'type': 'workspace',
          'name': 'Broken',
        }, deviceSequence: '902');
        final unknownSigner = await fixture.encryptWorkspace(
          WorkspaceRecord.fromHostIds(
            id: _workspaceId,
            name: 'Unknown signer layout',
            hostIds: const [_hostA],
          ).toJson(),
          deviceSequence: '1',
          author: foreignIdentity,
        );

        await _saveConflict(
          fixture,
          conflictId: _remoteConflictId,
          branchEnvelope: nonWorkspace,
        );
        await _saveConflict(
          fixture,
          conflictId: _malformedConflictId,
          branchEnvelope: malformedWorkspace,
        );
        await _saveConflict(
          fixture,
          conflictId: _unknownSignerConflictId,
          branchEnvelope: unknownSigner,
        );
        await _saveConflict(
          fixture,
          conflictId: _localConflictId,
          branchEnvelope: {'header': 'malformed'},
        );

        for (final conflictId in [
          _remoteConflictId,
          _malformedConflictId,
          _unknownSignerConflictId,
          _localConflictId,
        ]) {
          await expectLater(
            fixture.repository.saveWorkspaceConflictBranchAsNamedCopy(
              conflictId: conflictId,
              copyName: 'Should not persist',
            ),
            throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
          );
        }

        expect(await fixture.database.queuedOperations(_vaultId), isEmpty);
        final conflicts = await fixture.database.openConflicts(_vaultId);
        expect(conflicts, hasLength(4));
        expect(conflicts.map((item) => item.state), everyElement('open'));
      } finally {
        foreignIdentity.dispose();
        await fixture.close();
      }
    },
  );
}

Future<void> _saveConflict(
  _WorkspaceConflictFixture fixture, {
  required String conflictId,
  required Map<String, dynamic> branchEnvelope,
}) async {
  await fixture.database.saveConflict(
    conflictId: conflictId,
    vaultId: _vaultId,
    recordId: _workspaceId,
    instanceId: _instanceId,
    serverSpaceId: _serverSpaceId,
    kind: 'concurrent_edit',
    branchEnvelope: branchEnvelope,
    remoteEnvelope: const {'malformed_remote': true},
  );
}

Map<String, Object?> _workspaceLayoutWithoutPaneIdentity(Object? raw) {
  final value = Map<String, Object?>.from(raw! as Map);
  value.remove('active_pane_id');
  if (value['kind'] == 'terminal') {
    value.remove('pane_id');
  } else {
    value['panes'] = (value['panes']! as List)
        .map(_workspaceLayoutWithoutPaneIdentity)
        .toList(growable: false);
  }
  return value;
}

class _WorkspaceConflictFixture {
  _WorkspaceConflictFixture({
    required this.sodium,
    required this.identity,
    required this.database,
    required this.api,
    required this.crypto,
    required this.vaultKey,
    required this.repository,
  });

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final ClientDatabase database;
  final _DirectoryApiClient api;
  final VaultCrypto crypto;
  final List<int> vaultKey;
  final SyncRepository repository;

  static Future<_WorkspaceConflictFixture> create() async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _DirectoryApiClient(identity);
    final crypto = VaultCrypto(sodium);
    final vaultKey = sodium.randombytes.buf(32);
    final repository = SyncRepository(
      api: api,
      database: database,
      crypto: crypto,
      identity: identity,
      serverSpaceId: _serverSpaceId,
      instanceId: _instanceId,
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: _instanceId,
      vaultKey: Uint8List.fromList(vaultKey),
    );
    return _WorkspaceConflictFixture(
      sodium: sodium,
      identity: identity,
      database: database,
      api: api,
      crypto: crypto,
      vaultKey: vaultKey,
      repository: repository,
    );
  }

  Future<Map<String, dynamic>> encryptWorkspace(
    Map<String, Object?> plaintext, {
    required String deviceSequence,
    DeviceIdentity? author,
  }) async {
    final signer = author ?? identity;
    final envelope = await crypto.encryptRecord(
      vaultKey: Uint8List.fromList(vaultKey),
      serverSpaceId: _serverSpaceId,
      vaultId: _vaultId,
      recordId: _workspaceId,
      baseRevisionId: null,
      deviceId: signer.deviceId,
      deviceSequence: deviceSequence,
      keyEpoch: '1',
      membershipVersion: '1',
      operation: 'create',
      plaintext: plaintext,
      identity: signer,
    );
    return Map<String, dynamic>.from(envelope);
  }

  Future<void> close() async {
    await database.close();
    api.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  }
}

class _DirectoryApiClient extends ApiClient {
  _DirectoryApiClient(this.identity)
    : super(baseUrl: 'https://workspace-conflict-test.example');

  final DeviceIdentity identity;

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    {
      'device_id': identity.deviceId,
      'user_id': _workspaceId,
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];
}
