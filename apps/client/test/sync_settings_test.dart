import 'dart:async';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/sync_preference_store.dart';
import 'package:aterm_client/storage/sync_preference_store_native.dart';
import 'package:aterm_client/sync/sync_hint_client.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/sync_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _userId = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  group('device-local preference store', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('sync-pref-');
    });
    tearDown(() => directory.delete(recursive: true));

    test(
      'missing value is null, values round-trip, corruption throws',
      () async {
        final store = FileSyncPreferenceStore(directory: () async => directory);
        expect(await store.readAutomaticSync(), isNull);
        await store.writeAutomaticSync(false);
        expect(await store.readAutomaticSync(), isFalse);
        await store.writeAutomaticSync(true);
        expect(await store.readAutomaticSync(), isTrue);
        // Only the value file remains; temporary write directories are removed.
        expect(
          directory.listSync().map((entry) => entry.uri.pathSegments.last),
          ['sync-preference-v1'],
        );

        final file = File('${directory.path}/sync-preference-v1');
        await file.writeAsString('garbage');
        expect(
          store.readAutomaticSync(),
          throwsA(isA<SyncPreferenceUnreadableException>()),
        );
        await file.writeAsString('x' * 64);
        expect(
          store.readAutomaticSync(),
          throwsA(isA<SyncPreferenceUnreadableException>()),
        );
      },
    );
  });

  group('AppController automatic sync gate', () {
    test(
      'persisted off: no background callback, outbox intact, Sync now works',
      () async {
        final f = await _Fixture.create(
          sodium,
          store: _ScriptedStore(stored: false),
        );
        try {
          await pumpEventQueue();
          expect(
            f.app.automaticSyncPreference,
            AutomaticSyncPreferenceState.ready,
          );
          expect(f.app.automaticSyncEnabled, isFalse);
          expect(f.app.automaticSyncActive, isFalse);

          await f.app.saveWorkspaceDefaultSection('snippets');
          expect(await f.database.countPending(_vaultId), 1);
          // Edit debounce (700 ms), foreground resume, realtime/push hint.
          await Future<void>.delayed(const Duration(milliseconds: 850));
          await f.app.onForegroundResumed();
          await f.app.handleSyncHintForTesting(
            const SyncHint(vaultId: _vaultId),
          );
          await pumpEventQueue();
          expect(f.automaticCalls, 0);
          expect(f.repository.passes, 0);
          expect(await f.database.countPending(_vaultId), 1);

          final result = await f.app.syncNow();
          expect(f.repository.passes, 1);
          expect(f.automaticCalls, 0);
          // The fake server pass leaves the queued edit; never claim success.
          expect(result.outcome, SyncNowOutcome.completedWithPending);
          expect(await f.database.countPending(_vaultId), 1);
          // Status is re-derived from the real outbox, not the pass result.
          expect(f.app.pendingCount, 1);
          expect(f.app.syncNowRunning, isFalse);
        } finally {
          await f.dispose();
        }
      },
    );

    test('turning automatic sync on resumes triggers and persists', () async {
      final store = _ScriptedStore(stored: false);
      final f = await _Fixture.create(sodium, store: store);
      try {
        await pumpEventQueue();
        await f.app.onForegroundResumed();
        expect(f.automaticCalls, 0);

        expect(await f.app.setAutomaticSyncEnabled(true), isTrue);
        expect(store.stored, isTrue);
        expect(f.app.automaticSyncActive, isTrue);
        expect(f.app.automaticSyncSaveFailed, isFalse);
        await f.app.onForegroundResumed();
        expect(f.automaticCalls, 1);
        await f.app.saveWorkspaceDefaultSection('groups');
        await Future<void>.delayed(const Duration(milliseconds: 850));
        expect(f.automaticCalls, 2);

        expect(await f.app.setAutomaticSyncEnabled(false), isTrue);
        expect(store.stored, isFalse);
        await f.app.onForegroundResumed();
        expect(f.automaticCalls, 2);
      } finally {
        await f.dispose();
      }
    });

    test('no automatic trigger before the stored choice has loaded', () async {
      final read = Completer<bool?>();
      final f = await _Fixture.create(
        sodium,
        store: _ScriptedStore(read: () => read.future),
      );
      try {
        expect(
          f.app.automaticSyncPreference,
          AutomaticSyncPreferenceState.loading,
        );
        await f.app.onForegroundResumed();
        await f.app.handleSyncHintForTesting(const SyncHint(vaultId: _vaultId));
        expect(f.automaticCalls, 0);

        read.complete(null); // No stored choice: default on.
        await pumpEventQueue();
        expect(f.app.automaticSyncActive, isTrue);
        await f.app.onForegroundResumed();
        expect(f.automaticCalls, 1);
      } finally {
        await f.dispose();
      }
    });

    test(
      'unreadable stored choice keeps automatic sync off until retry',
      () async {
        var failRead = true;
        final store = _ScriptedStore(
          read: () async {
            if (failRead) throw const FileSystemException('denied');
            return false;
          },
        );
        final f = await _Fixture.create(sodium, store: store);
        try {
          await pumpEventQueue();
          expect(
            f.app.automaticSyncPreference,
            AutomaticSyncPreferenceState.readFailed,
          );
          expect(f.app.automaticSyncActive, isFalse);
          await f.app.onForegroundResumed();
          expect(f.automaticCalls, 0);
          expect(
            store.writes,
            isEmpty,
            reason: 'never overwrite on read failure',
          );

          // Manual sync is still available.
          expect(
            (await f.app.syncNow()).outcome,
            isNot(SyncNowOutcome.signInRequired),
          );
          expect(f.repository.passes, 1);

          failRead = false;
          await f.app.retryAutomaticSyncPreference();
          expect(
            f.app.automaticSyncPreference,
            AutomaticSyncPreferenceState.ready,
          );
          expect(f.app.automaticSyncEnabled, isFalse);
          expect(f.app.automaticSyncActive, isFalse);
        } finally {
          await f.dispose();
        }
      },
    );

    test(
      'save failure is visible, writes stay ordered, retry stores',
      () async {
        final store = _ScriptedStore(stored: true);
        final f = await _Fixture.create(sodium, store: store);
        try {
          await pumpEventQueue();
          final firstWrite = Completer<void>();
          store.nextWrites.addAll([() => firstWrite.future, () async {}]);
          final first = f.app.setAutomaticSyncEnabled(false);
          // The off choice applies immediately, before it is stored.
          expect(f.app.automaticSyncActive, isFalse);
          final second = f.app.setAutomaticSyncEnabled(true);
          await pumpEventQueue();
          expect(store.writes, [false], reason: 'second write waits for first');
          firstWrite.completeError(const FileSystemException('disk full'));
          await first;
          await second;
          expect(store.writes, [false, true]);
          expect(store.stored, isTrue);
          // The superseded failure is not shown for the latest choice.
          expect(f.app.automaticSyncSaveFailed, isFalse);

          store.nextWrites.add(
            () async => throw const FileSystemException('read-only'),
          );
          expect(await f.app.setAutomaticSyncEnabled(false), isFalse);
          expect(f.app.automaticSyncSaveFailed, isTrue);
          expect(f.app.automaticSyncActive, isFalse);
          expect(store.stored, isTrue);
          await f.app.onForegroundResumed();
          expect(f.automaticCalls, 0);

          await f.app.retryAutomaticSyncPreference();
          expect(f.app.automaticSyncSaveFailed, isFalse);
          expect(store.stored, isFalse);
        } finally {
          await f.dispose();
        }
      },
    );

    // The stale-epoch retry is a NEW pass started after an awaited membership
    // refresh. Without an attached device identity the vault reload resolves
    // as superseded (no signed control plane needed), so the retry path runs.
    test('automatic stale-epoch retry is dropped when sync is turned off '
        'during the membership refresh; explicit retry still runs', () async {
      final f = await _Fixture.create(
        sodium,
        realAutomaticSync: true,
        attachIdentity: false,
      );
      var toggledDuringRefresh = false;
      void toggleOffDuringRefresh() {
        if (toggledDuringRefresh || !f.app.membershipRefreshActiveForTesting) {
          return;
        }
        toggledDuringRefresh = true;
        scheduleMicrotask(() {
          expect(f.app.membershipRefreshActiveForTesting, isTrue);
          unawaited(f.app.setAutomaticSyncEnabled(false));
        });
      }

      f.app.addListener(toggleOffDuringRefresh);
      try {
        expect(f.app.automaticSyncActive, isTrue);
        f.repository.staleEpochOnce = true;
        await f.app.onForegroundResumed();
        await pumpEventQueue();
        expect(toggledDuringRefresh, isTrue);
        expect(f.app.automaticSyncActive, isFalse);
        expect(f.repository.passes, 1, reason: 'no automatic retry pass');
        expect(f.app.syncing, isFalse);
        f.app.removeListener(toggleOffDuringRefresh);

        // Explicit Sync now with automatic sync off keeps its retry.
        f.repository.staleEpochOnce = true;
        final result = await f.app.syncNow();
        expect(f.repository.passes, 3);
        expect(result.outcome, SyncNowOutcome.completed);
      } finally {
        f.app.removeListener(toggleOffDuringRefresh);
        await f.dispose();
      }
    });

    test('Sync now result is dropped when the account scope changes', () async {
      final f = await _Fixture.create(sodium);
      try {
        final gate = Completer<void>();
        f.repository.gate = gate.future;
        final pending = f.app.syncNow();
        await pumpEventQueue();
        expect(f.app.syncNowRunning, isTrue);
        // A repeated tap joins the running action instead of a second pass.
        final repeated = f.app.syncNow();
        f.app.session = _session('other-account', f.identity.deviceId);
        gate.complete();
        expect((await pending).outcome, SyncNowOutcome.superseded);
        expect((await repeated).outcome, SyncNowOutcome.superseded);
        expect(f.repository.passes, 1);
      } finally {
        await f.dispose();
      }
    });

    test('Sync now without an account session requires sign-in', () async {
      final f = await _Fixture.create(sodium);
      try {
        expect((await f.app.syncNow()).outcome, SyncNowOutcome.completed);
        expect(f.repository.passes, 1);
        f.app.session = null;
        final result = await f.app.syncNow();
        expect(result.outcome, SyncNowOutcome.signInRequired);
        expect(f.repository.passes, 1);
      } finally {
        await f.dispose();
      }
    });
  });

  testWidgets('sync card shows state and reports Sync now honestly', (
    tester,
  ) async {
    final automatic = <bool>[];
    var syncCalls = 0;
    Widget build(SyncSettingsSummary summary, SyncNowResult result) =>
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SyncSettingsView(
                summary: summary,
                onSetAutomatic: (value) async => automatic.add(value),
                onRetryPreference: () async {},
                onSyncNow: () async {
                  syncCalls++;
                  return result;
                },
                describeError: (error) => 'friendly',
              ),
            ),
          ),
        );

    await tester.pumpWidget(
      build(
        _summary(automaticEnabled: false, pendingCount: 2),
        const SyncNowResult(SyncNowOutcome.completedWithPending),
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(SyncSettingsView)),
    );
    expect(find.text(l10n.syncSettingsAutomaticOffDescription), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync_settings_queued_while_off')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('sync_settings_automatic')));
    await tester.pump();
    expect(automatic, [true]);

    await tester.tap(find.byKey(const ValueKey('sync_settings_sync_now')));
    await tester.pump();
    expect(syncCalls, 1);
    expect(find.text(l10n.syncSettingsResultPending(2)), findsOneWidget);
    expect(find.text(l10n.syncSettingsResultCompleted), findsNothing);

    // A new account/Vault scope never shows the previous result.
    await tester.pumpWidget(
      build(
        _summary(automaticEnabled: false, pendingCount: 2, scope: 'b'),
        const SyncNowResult(SyncNowOutcome.completed),
      ),
    );
    expect(find.byKey(const ValueKey('sync_settings_result')), findsNothing);

    // Loading: switch disabled; read failure: retry offered.
    await tester.pumpWidget(
      build(
        _summary(preference: AutomaticSyncPreferenceState.loading),
        const SyncNowResult(SyncNowOutcome.completed),
      ),
    );
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('sync_settings_automatic')),
    );
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    await tester.pumpWidget(
      build(
        _summary(preference: AutomaticSyncPreferenceState.readFailed),
        const SyncNowResult(SyncNowOutcome.completed),
      ),
    );
    expect(
      find.byKey(const ValueKey('sync_settings_preference_error')),
      findsOneWidget,
    );
    expect(find.text(l10n.retry), findsOneWidget);
  });
}

SyncSettingsSummary _summary({
  AutomaticSyncPreferenceState preference = AutomaticSyncPreferenceState.ready,
  bool automaticEnabled = true,
  int pendingCount = 0,
  String scope = 'a',
}) => SyncSettingsSummary(
  scopeKey: scope,
  preference: preference,
  automaticEnabled: automaticEnabled,
  saving: false,
  saveFailed: false,
  syncing: false,
  syncNowRunning: false,
  status: 'idle',
  pendingCount: pendingCount,
  lastSuccessfulSyncAt: null,
);

AuthSession _session(String accountId, String deviceId) => AuthSession(
  accountId: accountId,
  accessToken: 'access',
  expiresIn: 900,
  refreshToken: 'refresh',
  deviceId: deviceId,
  vaults: const [],
);

class _ScriptedStore implements SyncPreferenceStore {
  _ScriptedStore({this.stored, this.read});

  bool? stored;
  final Future<bool?> Function()? read;
  final List<bool> writes = [];
  final List<Future<void> Function()> nextWrites = [];

  @override
  Future<bool?> readAutomaticSync() => read?.call() ?? Future.value(stored);

  @override
  Future<void> writeAutomaticSync(bool enabled) async {
    writes.add(enabled);
    if (nextWrites.isNotEmpty) await nextWrites.removeAt(0)();
    stored = enabled;
  }
}

class _Fixture {
  _Fixture(this.app, this.database, this.repository, this.identity);

  final AppController app;
  final ClientDatabase database;
  final _CountingRepository repository;
  final DeviceIdentity identity;
  int automaticCalls = 0;

  static Future<_Fixture> create(
    SodiumSumo sodium, {
    SyncPreferenceStore? store,
    bool realAutomaticSync = false,
    bool attachIdentity = true,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final api = _Api(identity);
    final repository = _CountingRepository(
      api: api,
      database: database,
      crypto: VaultCrypto(sodium),
      identity: identity,
      serverSpaceId: _serverSpaceId,
      instanceId: _instanceId,
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: '1',
      vaultKey: sodium.randombytes.buf(32),
      canWrite: true,
    );
    late final _Fixture fixture;
    final app = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
      repositoryForTesting: repository,
      mobilePushAutoSyncForTesting: realAutomaticSync
          ? null
          : () async => fixture.automaticCalls++,
      syncPreferenceStore: store,
    );
    app
      ..api = api
      ..identity = attachIdentity ? identity : null
      ..session = _session(_userId, identity.deviceId)
      ..stage = ClientStage.workspace
      ..activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        canWrite: true,
      );
    fixture = _Fixture(app, database, repository, identity);
    return fixture;
  }

  Future<void> dispose() async {
    app.dispose();
    await database.close();
  }
}

class _CountingRepository extends SyncRepository {
  _CountingRepository({
    required super.api,
    required super.database,
    required super.crypto,
    required super.identity,
    required super.serverSpaceId,
    required super.instanceId,
    required super.vaultId,
    required super.keyEpoch,
    required super.membershipVersion,
    required super.serverGeneration,
    required super.vaultKey,
    required super.canWrite,
  });

  int passes = 0;
  Future<void>? gate;
  // First pass is rejected as stale so the controller refreshes signed
  // membership and then retries with a new pass.
  bool staleEpochOnce = false;

  @override
  Future<SyncResult> synchronize() async {
    passes++;
    if (staleEpochOnce) {
      staleEpochOnce = false;
      throw const ApiException(
        statusCode: 409,
        code: 'KEY_EPOCH_OUTDATED',
        message: 'stale',
      );
    }
    final wait = gate;
    gate = null;
    if (wait != null) await wait;
    return SyncResult(
      pendingCount: await database.countPending(vaultId),
      receivedCount: 0,
      conflictCount: 0,
      status: 'idle',
    );
  }
}

class _Api extends ApiClient {
  _Api(this.identity) : super(baseUrl: 'https://sync-settings.test');

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
