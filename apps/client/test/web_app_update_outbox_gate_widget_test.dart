import 'support/settings_navigation.dart';

import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/web_update/web_app_update_monitor.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _recordId = '22222222-2222-4222-8222-222222222222';
const _operationId = '33333333-3333-4333-8333-333333333333';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _serverSpaceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _vault = VaultDescriptor(
  id: _vaultId,
  role: 'owner',
  activeKeyEpoch: '1',
  membershipVersion: '1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  testWidgets(
    'same-count outbox replacement during export does not unlock update',
    (tester) async {
      var reloadCount = 0;
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await _insertPendingOperation(database, 'synthetic-ciphertext-before');
      final monitor = await _newerBundleMonitor(() async => reloadCount++);
      final app =
          _UpdateGateController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              onExport: () async {
                await _replacePendingEnvelope(
                  database,
                  'synthetic-ciphertext-during-export',
                );
                return true;
              },
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = _vault
            ..pendingCount = 1;

      try {
        await _pumpSettings(tester, app, monitor);
        _expectReviewDisabled(tester);
        await _exportArchive(tester);

        expect(await database.countPending(_vaultId), 1);
        expect(app.pendingCount, 1);
        _expectReviewDisabled(tester);
        expect(
          find.textContaining(
            '1 encrypted outbox operation(s) need to sync or be included',
          ),
          findsOneWidget,
        );
        expect(reloadCount, 0);
      } finally {
        monitor.dispose();
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'unchanged archive coverage survives page navigation and cancel',
    (tester) async {
      var reloadCount = 0;
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await _insertPendingOperation(database, 'synthetic-ciphertext-stable');
      final monitor = await _newerBundleMonitor(() async => reloadCount++);
      final app =
          _UpdateGateController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = _vault
            ..pendingCount = 1;

      try {
        await _pumpSettings(tester, app, monitor);
        _expectReviewDisabled(tester);
        await _exportArchive(tester);
        await tester.pumpAndSettle();
        expect(
          tester.widget<FilledButton>(_reviewButton()).onPressed,
          isNotNull,
        );

        app.showWorkspacePage(WorkspacePage.hosts);
        await tester.pumpAndSettle();
        app.showWorkspacePage(WorkspacePage.settings);
        await tester.pumpAndSettle();
        expect(
          tester.widget<FilledButton>(_reviewButton()).onPressed,
          isNotNull,
        );

        await tester.tap(_reviewButton());
        await tester.pumpAndSettle();
        expect(
          find.text(
            'An encrypted Vault archive covering 1 pending operation was exported recently. The outbox remains stored locally and will sync after reload.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('web_app_update_cancel')));
        await tester.pumpAndSettle();

        expect(reloadCount, 0);
        expect(await database.countPending(_vaultId), 1);
        expect(
          tester.widget<FilledButton>(_reviewButton()).onPressed,
          isNotNull,
        );
      } finally {
        monitor.dispose();
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'same-count outbox replacement after export invalidates confirmation',
    (tester) async {
      var reloadCount = 0;
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await _insertPendingOperation(database, 'synthetic-ciphertext-archived');
      final monitor = await _newerBundleMonitor(() async => reloadCount++);
      final app =
          _UpdateGateController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = _vault
            ..pendingCount = 1;

      try {
        await _pumpSettings(tester, app, monitor);
        await _exportArchive(tester);
        expect(
          tester.widget<FilledButton>(_reviewButton()).onPressed,
          isNotNull,
        );

        await _replacePendingEnvelope(
          database,
          'synthetic-ciphertext-replaced-after-export',
        );
        app.notifyListeners();
        await tester.pumpAndSettle();

        expect(await database.countPending(_vaultId), 1);
        expect(app.pendingCount, 1);
        _expectReviewDisabled(tester);
        expect(
          find.textContaining(
            '1 encrypted outbox operation(s) need to sync or be included',
          ),
          findsOneWidget,
        );
        expect(reloadCount, 0);
      } finally {
        monitor.dispose();
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'database outbox blocks review when the in-memory count is stale at zero',
    (tester) async {
      var reloadCount = 0;
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      await _insertPendingOperation(
        database,
        'synthetic-ciphertext-in-other-tab',
      );
      final monitor = await _newerBundleMonitor(() async => reloadCount++);
      final app =
          _UpdateGateController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = _vault
            ..pendingCount = 0;

      try {
        await _pumpSettings(tester, app, monitor);
        expect(await database.countPending(_vaultId), 1);
        expect(
          tester.widget<FilledButton>(_reviewButton()).onPressed,
          isNotNull,
        );

        await tester.tap(_reviewButton());
        await tester.pumpAndSettle();

        expect(app.pendingCount, 1);
        expect(await database.countPending(_vaultId), 1);
        expect(
          find.byKey(const ValueKey('web_app_update_confirmation')),
          findsNothing,
        );
        _expectReviewDisabled(tester);
        expect(
          find.textContaining(
            '1 encrypted outbox operation(s) need to sync or be included',
          ),
          findsOneWidget,
        );
        expect(reloadCount, 0);
      } finally {
        monitor.dispose();
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('outbox written after review blocks the final reload check', (
    tester,
  ) async {
    var reloadCount = 0;
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final monitor = await _newerBundleMonitor(() async => reloadCount++);
    final app =
        _UpdateGateController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = _vault
          ..pendingCount = 0;

    try {
      await _pumpSettings(tester, app, monitor);
      await tester.tap(_reviewButton());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('web_app_update_confirmation')),
        findsOneWidget,
      );

      await _insertPendingOperation(
        database,
        'synthetic-ciphertext-inserted-after-review',
      );
      await tester.tap(find.byKey(const ValueKey('web_app_update_confirm')));
      await tester.pumpAndSettle();

      expect(app.pendingCount, 1);
      expect(await database.countPending(_vaultId), 1);
      expect(reloadCount, 0);
      _expectReviewDisabled(tester);
      expect(
        find.textContaining(
          '1 encrypted outbox operation(s) need to sync or be included',
        ),
        findsOneWidget,
      );
    } finally {
      monitor.dispose();
      app.dispose();
      await database.close();
    }
  });
}

Finder _reviewButton() => find.byKey(const ValueKey('web_app_update_review'));

void _expectReviewDisabled(WidgetTester tester) {
  expect(tester.widget<FilledButton>(_reviewButton()).onPressed, isNull);
}

Future<WebAppUpdateMonitor> _newerBundleMonitor(
  Future<void> Function() reload,
) async {
  final monitor = WebAppUpdateMonitor(
    currentBuildId: 'synthetic-build-a',
    probeBuildId: () async => 'synthetic-build-b',
    reload: reload,
    checkInterval: const Duration(days: 1),
  );
  await monitor.checkNow();
  return monitor;
}

Future<void> _pumpSettings(
  WidgetTester tester,
  AppController app,
  WebAppUpdateMonitor monitor,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app, webAppUpdateMonitor: monitor),
    ),
  );
  await tester.pump();
  if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
    await openSettingsCategory(tester, 'notifications', ifAvailable: true);
  }
  await tester.pumpAndSettle();
  expect(_reviewButton(), findsOneWidget);
}

Future<void> _exportArchive(WidgetTester tester) async {
  await openSettingsCategory(tester, 'data');
  await tester.ensureVisible(find.text('Export archive'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Export archive'));
  await tester.pumpAndSettle();
  final passwordDialog = find.byType(AlertDialog);
  final passwordFields = find.descendant(
    of: passwordDialog,
    matching: find.byType(TextField),
  );
  await tester.enterText(passwordFields.at(0), 'synthetic archive password');
  await tester.enterText(passwordFields.at(1), 'synthetic archive password');
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  expect(find.text('Encrypted Vault archive saved.'), findsOneWidget);
  await openSettingsCategory(tester, 'notifications');
}

Future<void> _insertPendingOperation(
  ClientDatabase database,
  String envelopeJson,
) async {
  await database
      .into(database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: _operationId,
          vaultId: _vaultId,
          recordId: _recordId,
          instanceId: const Value(_instanceId),
          serverSpaceId: const Value(_serverSpaceId),
          envelopeJson: envelopeJson,
          createdAt: 1,
        ),
      );
}

Future<void> _replacePendingEnvelope(
  ClientDatabase database,
  String envelopeJson,
) async {
  await (database.update(database.pendingOperations)
        ..where((row) => row.opId.equals(_operationId)))
      .write(PendingOperationsCompanion(envelopeJson: Value(envelopeJson)));
}

class _UpdateGateController extends AppController {
  factory _UpdateGateController({
    required SodiumSumo sodium,
    required ClientDatabase database,
    required ClientSecureStore secureStore,
    Future<bool> Function()? onExport,
  }) {
    final sync = _UpdateGateSyncContext.create(sodium, database);
    return _UpdateGateController._(
      sodium: sodium,
      database: database,
      secureStore: secureStore,
      sync: sync,
      onExport: onExport,
    );
  }

  _UpdateGateController._({
    required SodiumSumo sodium,
    required ClientDatabase database,
    required ClientSecureStore secureStore,
    required _UpdateGateSyncContext sync,
    this.onExport,
  }) : _sync = sync,
       super(
         sodium: sodium,
         database: database,
         secureStore: secureStore,
         repositoryForTesting: sync.repository,
       );

  final Future<bool> Function()? onExport;
  final _UpdateGateSyncContext _sync;

  @override
  void dispose() {
    super.dispose();
    _sync.dispose();
  }

  @override
  Future<bool> exportPortableVaultArchive(String exportPassword) async =>
      await onExport?.call() ?? true;
}

class _UpdateGateSyncContext {
  _UpdateGateSyncContext({
    required this.api,
    required this.identity,
    required this.repository,
    required this.vaultKey,
  });

  final ApiClient api;
  final DeviceIdentity identity;
  final SyncRepository repository;
  final Uint8List vaultKey;

  factory _UpdateGateSyncContext.create(
    SodiumSumo sodium,
    ClientDatabase database,
  ) {
    final api = ApiClient(baseUrl: 'https://web-update-outbox-gate.test');
    final identity = DeviceIdentity.create(sodium);
    final vaultKey = sodium.randombytes.buf(32);
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
      serverGeneration: _instanceId,
      vaultKey: Uint8List.fromList(vaultKey),
    );
    return _UpdateGateSyncContext(
      api: api,
      identity: identity,
      repository: repository,
      vaultKey: vaultKey,
    );
  }

  void dispose() {
    api.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  }
}
