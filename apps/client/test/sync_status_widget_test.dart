import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('top bar reflects non-idle sync states when nothing is pending', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sftp
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    const expectedLabels = {
      'idle': 'Idle',
      'pending': 'Pending',
      'syncing': 'Syncing',
      'retry_wait': 'Retry queued',
      'offline': 'Offline',
      'error': 'Sync error',
      'read_only': 'Read-only',
      'deletion_pending': 'Vault deletion pending · read-only',
      'revoked': 'Device revoked',
      'auth_required': 'Sign in needed',
      'resnapshot_required': 'Snapshot needed',
      'snapshot_recovering': 'Rebuilding snapshot',
      'epoch_update_required': 'Key update needed',
    };

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );

      for (final entry in expectedLabels.entries) {
        app
          ..syncStatus = entry.key
          ..pendingCount = 0
          ..notifyListeners();
        await tester.pump();

        expect(
          find.byTooltip('${entry.value} · pending 0 · conflicts 0'),
          findsOneWidget,
          reason: entry.key,
        );
        expect(find.text('Synced'), findsNothing, reason: entry.key);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('pending count is shown only for healthy queued work', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sftp
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );

      app
        ..syncStatus = 'idle'
        ..pendingCount = 3
        ..notifyListeners();
      await tester.pump();
      expect(find.byTooltip('Idle · pending 3 · conflicts 0'), findsOneWidget);

      app
        ..syncStatus = 'retry_wait'
        ..pendingCount = 3
        ..notifyListeners();
      await tester.pump();
      expect(
        find.byTooltip('Retry queued · pending 3 · conflicts 0'),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'sync health shows checkpoint time and generation with safe error labels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = sodium.randombytes.buf(32);
      final api = ApiClient(baseUrl: 'https://sync-status-widget.test');
      const vaultId = '11111111-1111-4111-8111-111111111111';
      const checkpointGeneration = 'generation-checkpoint-123456789';
      const currentGeneration = 'generation-current-987654321';
      const unknownErrorCode = 'UNTRUSTED_ERROR_DETAIL_SENTINEL';
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: 'space-1',
        instanceId: 'instance-1',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: currentGeneration,
        vaultKey: vaultKey,
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
              id: vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..instance = const InstanceInfo(
              instanceId: 'instance-1',
              serverSpaceId: 'space-1',
              generation: currentGeneration,
              protocolVersion: 1,
              setupRequired: false,
              capabilities: [],
            )
            ..syncStatus = 'auth_required';

      try {
        await database.saveCheckpoint(
          vaultId: vaultId,
          instanceId: 'instance-1',
          serverSpaceId: 'space-1',
          cursor: 'PRIVATE_CURSOR_SENTINEL',
          serverGeneration: checkpointGeneration,
        );
        await app.refreshSyncStatus(keepStatus: true);
        expect(app.lastSuccessfulSyncAt, isNotNull);
        expect(app.syncCheckpointServerGeneration, checkpointGeneration);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Last successful sync'), findsOneWidget);
        expect(find.text('Never'), findsNothing);
        expect(find.text('Generation mismatch'), findsOneWidget);
        expect(find.text('Sign-in required'), findsOneWidget);

        app
          ..syncStatus = unknownErrorCode
          ..notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Other sync issue'), findsOneWidget);
        expect(find.text('Sync error'), findsNWidgets(2));
        expect(find.textContaining(unknownErrorCode), findsNothing);
        expect(find.textContaining('PRIVATE_CURSOR_SENTINEL'), findsNothing);

        app.instance = const InstanceInfo(
          instanceId: 'instance-1',
          serverSpaceId: 'space-1',
          generation: checkpointGeneration,
          protocolVersion: 1,
          setupRequired: false,
          capabilities: [],
        );
        app.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Generation matches'), findsOneWidget);

        app.activeVault = const VaultDescriptor(
          id: '22222222-2222-4222-8222-222222222222',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        await app.refreshSyncStatus();
        await tester.pumpAndSettle();
        expect(app.lastSuccessfulSyncAt, isNull);
        expect(app.syncCheckpointServerGeneration, isNull);
        expect(find.text('Never'), findsOneWidget);
        expect(find.text('Generation matches'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        api.close();
        identity.dispose();
        vaultKey.fillRange(0, vaultKey.length, 0);
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'resnapshot-required status exposes an actionable rebuild button',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _SnapshotRecoveryController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.sync
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..syncStatus = 'resnapshot_required'
            ..pendingCount = 1;

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );

        final rebuild = find.widgetWithText(OutlinedButton, 'Rebuild snapshot');
        expect(rebuild, findsOneWidget);
        expect(tester.widget<OutlinedButton>(rebuild).onPressed, isNotNull);
        await tester.tap(rebuild);
        await tester.pump();

        expect(app.recoveryRequested, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('manual sync contains revoked-session errors after reporting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _RevokedSyncController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sftp
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byTooltip('Sign in needed · pending 1 · conflicts 0'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('The sign-in state expired. Sign in again.'), findsOneWidget);
      expect(app.syncStatus, 'auth_required');
      expect(app.pendingCount, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

class _SnapshotRecoveryController extends AppController {
  _SnapshotRecoveryController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  bool recoveryRequested = false;

  @override
  Future<void> recoverFromSnapshot() async {
    recoveryRequested = true;
  }
}

class _RevokedSyncController extends AppController {
  _RevokedSyncController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  }) {
    syncStatus = 'auth_required';
    pendingCount = 1;
  }

  @override
  Future<void> synchronize({
    bool background = false,
    bool suppressSuccessNotice = false,
  }) async {
    syncStatus = 'auth_required';
    pendingCount = 1;
    errorMessage = 'The sign-in state expired. Sign in again.';
    notifyListeners();
    throw const ApiException(
      statusCode: 401,
      code: 'AUTH_REQUIRED',
      message: 'Authentication required.',
    );
  }
}
