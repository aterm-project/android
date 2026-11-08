import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
const _conflictId = '88888888-8888-4888-8888-888888888888';
const _badConflictId = '99999999-9999-4999-8999-999999999999';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'conflict card opens the name dialog and AppController saves an encrypted named copy',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1300);
      tester.view.devicePixelRatio = 1;
      final fixture = await _ControllerFixture.create();
      try {
        final source = await fixture.createWorkspaceConflict();
        await fixture.app.reloadRecords();
        await fixture.app.refreshSyncStatus();
        final originalConflict = (await fixture.database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).single;
        expect(fixture.app.savedWorkspaces, hasLength(1));
        expect(fixture.app.openConflicts, hasLength(1));

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: fixture.app),
          ),
        );
        await tester.pumpAndSettle();

        final copyAction = find.byKey(
          const ValueKey('workspace-conflict-copy-$_conflictId'),
        );
        await tester.ensureVisible(copyAction);
        await tester.pump();
        expect(copyAction, findsOneWidget);
        await tester.tap(copyAction);
        await tester.pumpAndSettle();
        expect(
          find.text('Save conflict branch as workspace copy'),
          findsOneWidget,
        );
        expect(find.text('Workspace name'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('workspace-name-input')),
          '  Saved layout branch  ',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('workspace-name-save')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const ValueKey('workspace-name-save')));
        await tester.pumpAndSettle();
        expect(
          find.text('Save conflict branch as workspace copy'),
          findsNothing,
        );

        expect(fixture.app.savedWorkspaces, hasLength(2));
        final copy = fixture.app.savedWorkspaces.singleWhere(
          (workspace) => workspace.name == 'Saved layout branch',
        );
        expect(copy.id, isNot(source.id));
        expect(copy.hostIds, source.hostIds);
        expect(copy.activeIndex, source.activeIndex);
        expect(
          copy.panes.map((pane) => pane.paneId).toSet(),
          isNot(contains(source.panes.first.paneId)),
        );
        expect(
          copy.panes.map((pane) => pane.paneId).toSet(),
          isNot(contains(source.panes.last.paneId)),
        );

        final queued = await fixture.database.queuedOperations(_vaultId);
        expect(queued, hasLength(1));
        expect(queued.single.recordId, copy.id);
        final envelopeJson = queued.single.envelopeJson;
        expect(envelopeJson, isNot(contains('Saved layout branch')));
        expect(envelopeJson, isNot(contains(_hostA)));
        expect(envelopeJson, isNot(contains(_hostB)));
        final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
        final header = envelope['header'] as Map<String, dynamic>;
        expect(header['record_id'], copy.id);
        expect(header['operation'], 'create');
        expect(header['base_revision_id'], isNull);
        final clear = await fixture.repository.crypto.decryptRecord(
          vaultKey: Uint8List.fromList(fixture.vaultKey),
          envelope: envelope,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        final saved = WorkspaceRecord.fromJson(clear);
        expect(saved.id, copy.id);
        expect(saved.name, 'Saved layout branch');
        expect(saved.hostIds, source.hostIds);
        expect(saved.activeIndex, source.activeIndex);
        expect(
          saved.panes
              .map((pane) => pane.paneId)
              .toSet()
              .intersection(source.panes.map((pane) => pane.paneId).toSet()),
          isEmpty,
        );

        final conflictsAfter = await fixture.database.openConflicts(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(conflictsAfter, hasLength(1));
        expect(conflictsAfter.single.conflictId, _conflictId);
        expect(conflictsAfter.single.state, 'open');
        expect(
          conflictsAfter.single.branchEnvelopeJson,
          originalConflict.branchEnvelopeJson,
        );
        expect(
          conflictsAfter.single.remoteEnvelopeJson,
          originalConflict.remoteEnvelopeJson,
        );
        expect(
          await fixture.database.conflictedOperation(_vaultId, source.id),
          isNotNull,
        );
        expect(fixture.app.openConflicts, hasLength(1));
        expect(fixture.app.pendingCount, 2);
        expect(fixture.app.syncStatus, 'pending');
        expect(fixture.app.unresolvedConflictCount, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  test(
    'AppController rejects a stale conflict and a signed non-Workspace branch without queuing a copy',
    () async {
      final fixture = await _ControllerFixture.create();
      try {
        final local = await fixture.encrypt(const {
          'id': _workspaceId,
          'type': 'host',
          'name': 'Not a Workspace',
        });
        final remote = await fixture.encrypt(
          WorkspaceRecord.fromHostIds(
            id: _workspaceId,
            name: 'Remote layout',
            hostIds: const [_hostA],
          ).toJson(),
        );
        await fixture.database.saveConflict(
          conflictId: _badConflictId,
          vaultId: _vaultId,
          recordId: _workspaceId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          kind: 'concurrent_edit',
          branchEnvelope: local,
          remoteEnvelope: remote,
        );

        await expectLater(
          fixture.app.saveWorkspaceConflictBranchAsNamedCopy(
            conflictId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            copyName: 'Stale branch',
          ),
          throwsStateError,
        );
        await expectLater(
          fixture.app.saveWorkspaceConflictBranchAsNamedCopy(
            conflictId: _badConflictId,
            copyName: 'Wrong record type',
          ),
          throwsFormatException,
        );

        expect(await fixture.database.queuedOperations(_vaultId), isEmpty);
        final conflicts = await fixture.database.openConflicts(_vaultId);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.state, 'open');
        expect(conflicts.single.branchEnvelopeJson, jsonEncode(local));
      } finally {
        await fixture.close();
      }
    },
  );
}

class _ControllerFixture {
  _ControllerFixture({
    required this.sodium,
    required this.identity,
    required this.database,
    required this.api,
    required this.crypto,
    required this.vaultKey,
    required this.repository,
    required this.app,
  });

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final ClientDatabase database;
  final _WorkspaceApi api;
  final VaultCrypto crypto;
  final List<int> vaultKey;
  final SyncRepository repository;
  final AppController app;

  static Future<_ControllerFixture> create() async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WorkspaceApi(identity);
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
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            repositoryForTesting: repository,
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sync
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
    return _ControllerFixture(
      sodium: sodium,
      identity: identity,
      database: database,
      api: api,
      crypto: crypto,
      vaultKey: vaultKey,
      repository: repository,
      app: app,
    );
  }

  Future<WorkspaceRecord> createWorkspaceConflict() async {
    final workspace = WorkspaceRecord.fromHostIds(
      id: _workspaceId,
      name: 'Local layout',
      hostIds: const [_hostB, _hostA],
      activeIndex: 1,
      paneIds: const [_paneA, _paneB],
    );
    final localEnvelope = await repository.saveRecord(
      recordId: workspace.id,
      operation: 'update',
      baseRevisionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      plaintext: workspace.toJson(),
    );
    final localHeader = localEnvelope['header'] as Map<String, dynamic>;
    await database.markConflicted(localHeader['op_id'] as String);
    final remoteEnvelope = await encrypt(
      WorkspaceRecord.fromHostIds(
        id: workspace.id,
        name: 'Remote layout',
        hostIds: const [_hostA],
      ).toJson(),
      deviceSequence: '900',
    );
    await database.saveConflict(
      conflictId: _conflictId,
      vaultId: _vaultId,
      recordId: workspace.id,
      instanceId: _instanceId,
      serverSpaceId: _serverSpaceId,
      kind: 'concurrent_edit',
      branchEnvelope: Map<String, dynamic>.from(localEnvelope),
      remoteEnvelope: remoteEnvelope,
    );
    return workspace;
  }

  Future<Map<String, dynamic>> encrypt(
    Map<String, Object?> plaintext, {
    String deviceSequence = '901',
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
    app.dispose();
    api.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
    await database.close();
  }
}

class _WorkspaceApi extends ApiClient {
  _WorkspaceApi(this.identity)
    : super(baseUrl: 'https://workspace-conflict-widget.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _workspaceId,
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
