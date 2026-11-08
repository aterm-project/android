import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _hostId = '44444444-4444-4444-8444-444444444444';
const _replacementHostId = '77777777-7777-4777-8777-777777777777';
const _staleReplacementHostId = '88888888-8888-4888-8888-888888888888';
const _userId = '55555555-5555-4555-8555-555555555555';
const _serverGeneration = '66666666-6666-4666-8666-666666666666';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'workspace save, rename and duplicate stay encrypted in the outbox',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final api = _WorkspaceApi(identity);
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: _serverSpaceId,
        instanceId: _instanceId,
        vaultId: _vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: key,
        canWrite: true,
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    fail('Workspace preview must not call the SSH connector');
                  },
            )
            ..stage = ClientStage.workspace
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );
      const host = HostRecord(
        id: _hostId,
        name: 'Sensitive Host Label',
        address: 'sensitive-host.example.test',
        username: 'private-user',
      );
      const replacementHost = HostRecord(
        id: _replacementHostId,
        name: 'Replacement Host Label',
        address: 'replacement-host.example.test',
        username: 'replacement-user',
      );
      app
        ..hosts.add(host)
        ..hosts.add(replacementHost)
        ..selectedHost = host
        ..connectedHost = host;

      try {
        await app.saveCurrentWorkspace('  Daily operations  ');
        final original = app.savedWorkspaces.single;
        expect(original.name, 'Daily operations');
        expect(original.hostIds, [_hostId]);
        expect(await database.countPending(_vaultId), 1);

        var stored = await database.encryptedRecord(_vaultId, original.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('Daily operations')));
        expect(stored.envelopeJson, isNot(contains('Sensitive Host Label')));
        expect(
          stored.envelopeJson,
          isNot(contains('sensitive-host.example.test')),
        );
        expect(stored.envelopeJson, isNot(contains('private-user')));
        var clear = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(clear['type'], 'workspace');
        expect(clear['name'], 'Daily operations');
        expect(clear['host_refs'], [_hostId]);
        expect(clear['layout_tree'], isA<Map>());
        expect(clear.keys, isNot(contains('scrollback')));
        expect(clear.keys, isNot(contains('credential')));

        final firstRevision = original.revisionId;
        await app.renameWorkspace(original.id, 'Production shell');
        expect(app.savedWorkspaces.single.name, 'Production shell');
        expect(app.savedWorkspaces.single.revisionId, isNot(firstRevision));
        expect(await database.countPending(_vaultId), 1);

        await app.duplicateWorkspace(original.id, 'Production shell copy');
        expect(app.savedWorkspaces, hasLength(2));
        expect(
          app.savedWorkspaces.map((item) => item.name),
          containsAll(['Production shell', 'Production shell copy']),
        );
        expect(
          app.savedWorkspaces.map((item) => item.id).toSet(),
          hasLength(2),
        );
        expect(await database.countPending(_vaultId), 2);

        final duplicate = app.savedWorkspaces.singleWhere(
          (item) => item.name == 'Production shell copy',
        );
        stored = await database.encryptedRecord(_vaultId, duplicate.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('Production shell copy')));
        clear = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(clear['id'], duplicate.id);
        expect(clear['host_refs'], [_hostId]);

        final duplicateRevision = duplicate.revisionId;
        final duplicatePaneId = duplicate.panes.single.paneId;
        final pendingBeforeFailedRepair = await database.countPending(_vaultId);
        // Model the missing Host and a replacement selected in a dialog that
        // became stale before its choice was submitted.
        app.hosts.removeWhere((item) => item.id == _hostId);
        await expectLater(
          app.replaceWorkspaceHost(
            duplicate.id,
            duplicatePaneId,
            _staleReplacementHostId,
          ),
          throwsStateError,
        );
        expect(
          app.savedWorkspaces
              .singleWhere((item) => item.id == duplicate.id)
              .hostIds,
          [_hostId],
        );
        expect(
          app.savedWorkspaces
              .singleWhere((item) => item.id == duplicate.id)
              .revisionId,
          duplicateRevision,
        );
        expect(
          await database.countPending(_vaultId),
          pendingBeforeFailedRepair,
        );

        await app.replaceWorkspaceHost(
          duplicate.id,
          duplicatePaneId,
          _replacementHostId,
        );
        final repaired = app.savedWorkspaces.singleWhere(
          (item) => item.id == duplicate.id,
        );
        expect(repaired.panes.map((pane) => pane.paneId), [duplicatePaneId]);
        expect(repaired.hostIds, [_replacementHostId]);
        expect(repaired.revisionId, isNot(duplicateRevision));
        expect(
          await database.countPending(_vaultId),
          pendingBeforeFailedRepair,
        );
        stored = await database.encryptedRecord(_vaultId, duplicate.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('Replacement Host Label')));
        expect(
          stored.envelopeJson,
          isNot(contains('replacement-host.example.test')),
        );
        clear = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(clear['host_refs'], [_replacementHostId]);

        app.savedWorkspaces.clear();
        await app.reloadRecords();
        expect(app.savedWorkspaces, hasLength(2));
        expect(app.unavailableRecordCount, 0);
        expect(
          app.savedWorkspaces.map((item) => item.name),
          containsAll(['Production shell', 'Production shell copy']),
        );

        app.hosts.clear();
        await expectLater(
          app.connectWorkspacePane(duplicate.id, duplicate.panes.single.paneId),
          throwsStateError,
        );
        expect(app.terminalTabs, hasLength(1));
        expect(await database.countPending(_vaultId), 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'split workspace saves encrypted layout intent without connecting',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final repository = SyncRepository(
        api: _WorkspaceApi(identity),
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: _serverSpaceId,
        instanceId: _instanceId,
        vaultId: _vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: key,
        canWrite: true,
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    fail(
                      'Creating or previewing a split Workspace must not connect',
                    );
                  },
            )
            ..stage = ClientStage.workspace
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostId,
                name: 'Primary Sensitive Host',
                address: 'primary-private.example.test',
                username: 'primary-user',
                credentialId: 'workspace-race-credential',
              ),
              HostRecord(
                id: _replacementHostId,
                name: 'Secondary Sensitive Host',
                address: 'secondary-private.example.test',
                username: 'secondary-user',
                credentialId: 'workspace-race-credential',
              ),
            ])
            ..credentials.add(
              const CredentialRecord(
                id: 'workspace-race-credential',
                name: 'Workspace race credential',
                username: 'workspace-race-user',
                secret: 'workspace-race-secret',
              ),
            );

      try {
        await app.saveSplitWorkspace(
          name: '  Review split  ',
          hostIds: const [_hostId, _replacementHostId],
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 6250,
        );

        final saved = app.savedWorkspaces.single;
        expect(saved.name, 'Review split');
        expect(saved.isSplit, isTrue);
        expect(saved.splitAxis, WorkspaceSplitAxis.horizontal);
        expect(saved.splitRatioBasisPoints, 6250);
        expect(saved.hostIds, const [_hostId, _replacementHostId]);
        expect(await database.countPending(_vaultId), 1);

        final encrypted = await database.encryptedRecord(_vaultId, saved.id);
        expect(encrypted, isNotNull);
        final envelopeJson = encrypted!.envelopeJson;
        for (final marker in [
          'Review split',
          'Primary Sensitive Host',
          'Secondary Sensitive Host',
          'primary-private.example.test',
          'secondary-private.example.test',
          'primary-user',
          'secondary-user',
        ]) {
          expect(envelopeJson, isNot(contains(marker)));
        }
        final clear = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(clear['schema_version'], 2);
        expect(clear['layout_tree'], {
          'kind': 'split',
          'axis': 'horizontal',
          'split_ratio_basis_points': 6250,
          'active_pane_id': saved.activePaneId,
          'panes': [
            {
              'kind': 'terminal',
              'pane_id': saved.panes[0].paneId,
              'host_id': _hostId,
            },
            {
              'kind': 'terminal',
              'pane_id': saved.panes[1].paneId,
              'host_id': _replacementHostId,
            },
          ],
        });
        expect(clear['host_refs'], [_hostId, _replacementHostId]);

        await app.duplicateWorkspace(saved.id, 'Review split copy');
        final duplicate = app.savedWorkspaces.singleWhere(
          (workspace) => workspace.name == 'Review split copy',
        );
        expect(duplicate.isSplit, isTrue);
        expect(duplicate.splitAxis, WorkspaceSplitAxis.horizontal);
        expect(duplicate.splitRatioBasisPoints, 6250);
        expect(duplicate.hostIds, const [_hostId, _replacementHostId]);
        expect(await database.countPending(_vaultId), 2);

        app.stageWorkspace(saved.id);
        expect(app.activeSavedWorkspaceId, saved.id);
        expect(app.terminalTabs, isEmpty);

        app.savedWorkspaces.clear();
        await app.reloadRecords();
        final restored = app.savedWorkspaces.singleWhere(
          (workspace) => workspace.name == 'Review split',
        );
        expect(restored.isSplit, isTrue);
        expect(restored.splitAxis, WorkspaceSplitAxis.horizontal);
        expect(restored.splitRatioBasisPoints, 6250);
        expect(restored.hostIds, const [_hostId, _replacementHostId]);
        app.hosts.addAll(const [
          HostRecord(
            id: _hostId,
            name: 'Primary Sensitive Host',
            address: 'primary-private.example.test',
            username: 'primary-user',
            credentialId: 'workspace-race-credential',
          ),
          HostRecord(
            id: _replacementHostId,
            name: 'Secondary Sensitive Host',
            address: 'secondary-private.example.test',
            username: 'secondary-user',
            credentialId: 'workspace-race-credential',
          ),
        ]);
        app.credentials.add(
          const CredentialRecord(
            id: 'workspace-race-credential',
            name: 'Workspace race credential',
            username: 'workspace-race-user',
            secret: 'workspace-race-secret',
          ),
        );

        final connectingDuringVaultSwitch = app.connectWorkspacePane(
          restored.id,
          restored.panes.first.paneId,
        );
        app.activeVault = const VaultDescriptor(
          id: _replacementHostId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        await expectLater(
          connectingDuringVaultSwitch,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Vault 在工作区连接准备期间已切换'),
            ),
          ),
        );

        app.activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        final connectingBeforeHostRemoval = app.connectWorkspacePane(
          restored.id,
          restored.panes.first.paneId,
        );
        app.hosts.clear();
        await expectLater(
          connectingBeforeHostRemoval,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('工作区主机在连接准备期间已从当前 Vault 移除'),
            ),
          ),
        );
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'nested Workspace saves, reloads, and duplicates encrypted geometry',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final repository = SyncRepository(
        api: _WorkspaceApi(identity),
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: _serverSpaceId,
        instanceId: _instanceId,
        vaultId: _vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: key,
        canWrite: true,
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    fail(
                      'Saving or previewing a nested layout must not connect',
                    );
                  },
            )
            ..stage = ClientStage.workspace
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostId,
                name: 'Nested Host One',
                address: 'nested-one.example.test',
                username: 'private-user-one',
              ),
              HostRecord(
                id: _replacementHostId,
                name: 'Nested Host Two',
                address: 'nested-two.example.test',
                username: 'private-user-two',
              ),
            ]);

      try {
        final tree = WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 6250,
          first: WorkspaceTerminalNode(
            paneId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            hostId: _hostId,
          ),
          second: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.vertical,
            splitRatioBasisPoints: 4000,
            first: WorkspaceTerminalNode(
              paneId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              hostId: _replacementHostId,
            ),
            second: WorkspaceTerminalNode(
              paneId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              hostId: _hostId,
            ),
          ),
        );
        await app.saveWorkspaceLayout(
          name: 'Nested operations',
          layoutTree: tree,
          activePaneId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        );
        final saved = app.savedWorkspaces.single;
        expect(saved.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
        expect(saved.panes, hasLength(3));
        expect(saved.activePaneId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
        expect(saved.hostRefs, [_hostId, _replacementHostId]);
        expect(await database.countPending(_vaultId), 1);

        final encrypted = await database.encryptedRecord(_vaultId, saved.id);
        expect(encrypted, isNotNull);
        for (final marker in [
          'Nested operations',
          'Nested Host One',
          'nested-one.example.test',
          'private-user-one',
        ]) {
          expect(encrypted!.envelopeJson, isNot(contains(marker)));
        }
        final clear = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(encrypted!.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        final decoded = WorkspaceRecord.fromJson(clear);
        expect(decoded.toJson(), saved.toJson());
        expect(
          clear['schema_version'],
          workspaceNestedSplitLayoutSchemaVersion,
        );
        expect(clear.keys, isNot(contains('terminal_output')));
        expect(clear.keys, isNot(contains('credential')));

        await app.duplicateWorkspace(saved.id, 'Nested operations copy');
        final duplicate = app.savedWorkspaces.singleWhere(
          (workspace) => workspace.name == 'Nested operations copy',
        );
        expect(
          duplicate.schemaVersion,
          workspaceNestedSplitLayoutSchemaVersion,
        );
        expect(
          _workspaceLayoutWithoutPaneIdentity(
            duplicate.toJson()['layout_tree'],
          ),
          _workspaceLayoutWithoutPaneIdentity(saved.toJson()['layout_tree']),
        );
        expect(duplicate.hostIds, saved.hostIds);
        expect(duplicate.activeIndex, saved.activeIndex);
        expect(
          duplicate.panes
              .map((pane) => pane.paneId)
              .toSet()
              .intersection(saved.panes.map((pane) => pane.paneId).toSet()),
          isEmpty,
        );

        app.savedWorkspaces.clear();
        await app.reloadRecords();
        final restored = app.savedWorkspaces.singleWhere(
          (workspace) => workspace.name == 'Nested operations',
        );
        expect(
          restored.panes.map((pane) => pane.paneId),
          saved.panes.map((pane) => pane.paneId),
        );
        expect(restored.activePaneId, saved.activePaneId);
        expect(restored.toJson()['layout_tree'], saved.toJson()['layout_tree']);

        await app.removeWorkspacePane(
          restored.id,
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        );
        final paneRemoved = app.savedWorkspaces.singleWhere(
          (workspace) => workspace.id == restored.id,
        );
        expect(
          paneRemoved.schemaVersion,
          workspaceNestedSplitLayoutSchemaVersion,
        );
        expect(paneRemoved.panes.map((pane) => pane.paneId), [
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        ]);
        expect(
          paneRemoved.activePaneId,
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        );
        expect(paneRemoved.layoutTree!.second, isA<WorkspaceTerminalNode>());
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('workspace save invalidates an earlier stale record reload', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final key = sodium.randombytes.buf(32);
    final repository = SyncRepository(
      api: _WorkspaceApi(identity),
      database: database,
      crypto: VaultCrypto(sodium),
      identity: identity,
      serverSpaceId: _serverSpaceId,
      instanceId: _instanceId,
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: _serverGeneration,
      vaultKey: key,
      canWrite: true,
    );
    final staleRows = Completer<List<Map<String, dynamic>>>();
    final loadStarted = Completer<void>();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            repositoryForTesting: repository,
            loadRecordsForTesting: (_) {
              loadStarted.complete();
              return staleRows.future;
            },
          )
          ..stage = ClientStage.workspace
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
    const host = HostRecord(
      id: _hostId,
      name: 'Host',
      address: 'host.example.test',
      username: 'user',
    );
    app
      ..hosts.add(host)
      ..selectedHost = host
      ..connectedHost = host;

    try {
      final oldReload = app.reloadRecords();
      await loadStarted.future;
      await app.saveCurrentWorkspace('Fresh workspace');

      // This reload captured an empty pre-save snapshot. Completing it after
      // the save must not clear the Workspace from the controller projection.
      staleRows.complete(const []);
      await oldReload;

      expect(app.savedWorkspaces, hasLength(1));
      expect(app.savedWorkspaces.single.name, 'Fresh workspace');
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });
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

class _WorkspaceApi extends ApiClient {
  _WorkspaceApi(this.identity) : super(baseUrl: 'https://workspace.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _userId,
    'signing_public_key': identity.signingPublicKey,
    'status': 'active',
  };

  @override
  Future<List<Map<String, dynamic>>> devices() async => [_device];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    _device,
  ];
}
