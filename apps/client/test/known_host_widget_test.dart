import 'support/settings_navigation.dart';

import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _deviceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _otherFingerprint = 'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Vault host-key panel explains sync and revokes with confirmation',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final record = KnownHostRecord.approve(
        host: 'SSH.Example.Test.',
        port: 2222,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: _deviceId,
        approvedAt: DateTime.utc(2026, 9, 27),
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..knownHosts.add(record);
      final semantics = tester.ensureSemantics();

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('cloud_settings'))
            .evaluate()
            .isNotEmpty) {
          await openSettingsCategory(tester, 'trust', ifAvailable: true);
        }
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel(RegExp(r'ssh-ed25519.*TRUSTED')),
          findsOneWidget,
        );
        expect(find.text('SSH host-key trust'), findsOneWidget);
        expect(find.text('ssh.example.test:2222'), findsOneWidget);
        expect(find.text(_fingerprint), findsOneWidget);
        expect(
          find.textContaining('encrypted in this Vault and sync'),
          findsOneWidget,
        );
        final revokeButton = _revokeKnownHostActions();
        expect(revokeButton, findsOneWidget);
        expect(tester.widget<IconButton>(revokeButton).onPressed, isNotNull);

        await tester.ensureVisible(revokeButton);
        await tester.tap(revokeButton);
        await tester.pumpAndSettle();
        expect(find.text('Revoke SSH host-key trust?'), findsOneWidget);
        expect(
          find.textContaining('will be blocked on devices'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('ssh.example.test:2222'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('confirming sequential conflict-row revokes writes revisions', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final key = sodium.randombytes.buf(32);
    final repositoryKey = Uint8List.fromList(key);
    final api = _KnownHostWidgetApi(identity);
    final repository = SyncRepository(
      api: api,
      database: database,
      crypto: VaultCrypto(sodium),
      identity: identity,
      serverSpaceId: '33333333-3333-4333-8333-333333333333',
      instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: '77777777-7777-4777-8777-777777777777',
      vaultKey: repositoryKey,
    );
    final initialRecords = [
      KnownHostRecord.approve(
        host: 'revoke.example.test',
        port: 2222,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: identity.deviceId,
        approvedAt: DateTime.utc(2026, 9, 27),
      ),
      KnownHostRecord.approve(
        host: 'revoke.example.test',
        port: 2222,
        algorithm: 'ssh-ed25519',
        fingerprint: _otherFingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: identity.deviceId,
        approvedAt: DateTime.utc(2026, 9, 27),
      ),
    ];
    final displayedRecords = <KnownHostRecord>[];
    for (final record in initialRecords) {
      final envelope = await repository.saveRecord(
        recordId: record.id,
        plaintext: record.toJson(),
        operation: 'create',
      );
      displayedRecords.add(
        KnownHostRecord.fromJson({
          ...record.toJson(),
          '_record_id': record.id,
          '_revision_id':
              (envelope['header'] as Map<String, dynamic>)['revision_id'],
        }),
      );
    }
    displayedRecords.sort((a, b) => a.id.compareTo(b.id));
    const vault = VaultDescriptor(
      id: _vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
    );
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            repositoryForTesting: repository,
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..identity = identity
          ..api = api
          ..activeVault = vault
          ..session = AuthSession(
            accountId: '55555555-5555-4555-8555-555555555555',
            accessToken: 'test-access-token',
            expiresIn: 900,
            refreshToken: 'test-refresh-token',
            deviceId: identity.deviceId,
            vaults: [vault],
          )
          ..knownHosts.addAll(displayedRecords);
    final semantics = tester.ensureSemantics();

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'trust', ifAvailable: true);
      }
      await tester.pumpAndSettle();
      expect(
        find.text('ssh-ed25519 · CONFLICT — CONNECTIONS BLOCKED'),
        findsNWidgets(2),
      );
      expect(
        find.bySemanticsLabel('ssh-ed25519 · CONFLICT — CONNECTIONS BLOCKED'),
        findsNWidgets(2),
      );
      final originalRevisions = {
        for (final record in displayedRecords) record.id: record.revisionId,
      };
      final revokeActions = _revokeKnownHostActions();
      expect(revokeActions, findsNWidgets(2));
      await tester.ensureVisible(revokeActions.first);
      await tester.tap(revokeActions.first);
      await tester.pumpAndSettle();
      expect(find.text('Revoke SSH host-key trust?'), findsOneWidget);
      await tester.tap(find.text('Revoke trust'));
      await tester.pumpAndSettle();

      final saved = await repository.loadKnownHosts();
      expect(
        saved.where((record) => record.state == KnownHostState.revoked),
        hasLength(1),
      );
      expect(
        saved.where((record) => record.state == KnownHostState.trusted),
        hasLength(1),
      );
      final revoked = saved.singleWhere(
        (record) => record.state == KnownHostState.revoked,
      );
      expect(revoked.revisionId, isNot(originalRevisions[revoked.id]));
      expect(find.bySemanticsLabel('ssh-ed25519 · REVOKED'), findsOneWidget);
      expect(find.text('SSH host key trust was revoked and saved encrypted to the current Vault.'), findsOneWidget);
      expect(
        [
          app.activeVault?.canWrite,
          app.vaultMembershipBusy,
          app.vaultLifecycleBusy,
        ],
        [true, false, false],
        reason: 'the Vault must stay writable after one KnownHost revocation',
      );

      final remainingRevokeActions = _revokeKnownHostActions()
          .evaluate()
          .where((element) => (element.widget as IconButton).onPressed != null)
          .toList();
      expect(remainingRevokeActions, hasLength(1));
      final remainingRevokeAction = find.byWidget(
        remainingRevokeActions.single.widget,
      );
      await tester.ensureVisible(remainingRevokeAction);
      await tester.tap(remainingRevokeAction);
      await tester.pumpAndSettle();
      expect(find.text('Revoke SSH host-key trust?'), findsOneWidget);
      await tester.tap(find.text('Revoke trust'));
      await tester.pumpAndSettle();

      final fullyRevoked = await repository.loadKnownHosts();
      expect(
        fullyRevoked.where((record) => record.state == KnownHostState.revoked),
        hasLength(2),
      );
      expect(
        fullyRevoked.every(
          (record) => record.revisionId != originalRevisions[record.id],
        ),
        isTrue,
      );
      expect(
        fullyRevoked.where((record) => record.state == KnownHostState.trusted),
        isEmpty,
      );
      expect(find.bySemanticsLabel('ssh-ed25519 · REVOKED'), findsNWidgets(2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      app.dispose();
      key.fillRange(0, key.length, 0);
      repositoryKey.fillRange(0, repositoryKey.length, 0);
      await database.close();
    }
  });

  testWidgets('read-only Vault shows trust history without revoke action', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final record = KnownHostRecord.approve(
      host: 'viewer.example.test',
      port: 22,
      algorithm: 'ssh-ed25519',
      fingerprint: _fingerprint,
      approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
      approvedByDeviceId: _deviceId,
      approvedAt: DateTime.utc(2026, 9, 27),
    );
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'viewer',
            activeKeyEpoch: '1',
            membershipVersion: '1',
            canWrite: false,
          )
          ..knownHosts.add(record);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'trust', ifAvailable: true);
      }
      await tester.pumpAndSettle();
      final revoke = _revokeKnownHostActions();
      expect(revoke, findsOneWidget);
      expect(tester.widget<IconButton>(revoke).onPressed, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets(
    'conflicting synced approvals are clearly marked and fail closed',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final approvedAt = DateTime.utc(2026, 9, 27);
      final first = KnownHostRecord.approve(
        host: 'conflict.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: _deviceId,
        approvedAt: approvedAt,
      );
      final second = KnownHostRecord.approve(
        host: 'CONFLICT.EXAMPLE.TEST.',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: _otherFingerprint,
        approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
        approvedByDeviceId: _deviceId,
        approvedAt: approvedAt,
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..knownHosts.addAll([first, second]);
      final semantics = tester.ensureSemantics();

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('cloud_settings'))
            .evaluate()
            .isNotEmpty) {
          await openSettingsCategory(tester, 'trust', ifAvailable: true);
        }
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Revoke every key you do not intend to trust; if neither fingerprint is verified, revoke both',
          ),
          findsOneWidget,
        );
        expect(
          find.text('ssh-ed25519 · CONFLICT — CONNECTIONS BLOCKED'),
          findsNWidgets(2),
        );
        expect(
          find.bySemanticsLabel('ssh-ed25519 · CONFLICT — CONNECTIONS BLOCKED'),
          findsNWidgets(2),
        );
        expect(find.text(_fingerprint), findsOneWidget);
        expect(find.text(_otherFingerprint), findsOneWidget);
        final revokeActions = _revokeKnownHostActions();
        expect(revokeActions, findsNWidgets(2));
        for (var index = 0; index < 2; index++) {
          final revokeButton = revokeActions.at(index);
          expect(tester.widget<IconButton>(revokeButton).onPressed, isNotNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        await database.close();
      }
    },
  );
}

Finder _revokeKnownHostActions() => find.byWidgetPredicate(
  (widget) =>
      widget is IconButton &&
      (widget.tooltip?.startsWith('Revoke SSH host-key trust for ') ?? false),
);

class _KnownHostWidgetApi extends ApiClient {
  _KnownHostWidgetApi(this.identity)
    : super(baseUrl: 'https://known-host-widget.test');

  final DeviceIdentity identity;
  static const _serverGeneration = '77777777-7777-4777-8777-777777777777';
  static const _userId = '55555555-5555-4555-8555-555555555555';

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

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async => const SyncPage(
    events: [],
    nextCursor: 'cursor-1',
    hasMore: false,
    serverGeneration: _serverGeneration,
  );

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async => ConflictChangesPage(
    vaultId: vaultId,
    afterSeq: afterSeq ?? '0',
    highWatermark: afterSeq ?? '0',
    events: const [],
    nextAfterSeq: afterSeq ?? '0',
    hasMore: false,
    serverGeneration: serverGeneration ?? _serverGeneration,
  );

  var _commitSequence = 0;

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    final operations = batch['operations'] as List<dynamic>;
    return {
      'batch_id': batch['batch_id'],
      'results': [
        for (final rawOperation in operations)
          if (rawOperation is Map)
            {
              'op_id':
                  (rawOperation['header'] as Map<String, dynamic>)['op_id'],
              'revision_id':
                  (rawOperation['header']
                      as Map<String, dynamic>)['revision_id'],
              'commit_seq': (++_commitSequence).toString(),
              'already_committed': false,
            },
      ],
    };
  }
}
