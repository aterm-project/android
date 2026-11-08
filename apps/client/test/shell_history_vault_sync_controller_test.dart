// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/terminal/encrypted_shell_history_repository.dart';
import 'package:aterm_client/terminal/shell_integration_protocol.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '33333333-3333-4333-8333-333333333333';
const _hostId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _accountId = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  test(
    'Vault opt-in backfills encrypted records idempotently; local clear is local only',
    () async {
      final fixture = await _fixture(sodium);
      final event = _event('sudo systemctl restart api.service');
      try {
        expect(
          await fixture.localHistory.record(hostId: _hostId, command: event),
          isNotEmpty,
        );
        await fixture.app.loadShellHistorySyncPreference();
        expect(fixture.app.shellHistorySyncEnabled, isFalse);
        expect(await fixture.database.countPending(_vaultId), 0);

        await fixture.app.setShellHistorySyncEnabled(true);
        expect(fixture.app.shellHistorySyncEnabled, isTrue);
        expect(await fixture.database.countPending(_vaultId), 1);
        final firstPending = await fixture.database.allPendingOperations(
          _vaultId,
        );
        expect(firstPending, hasLength(1));
        expect(
          firstPending.single.envelopeJson,
          isNot(contains(event.command)),
        );
        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.vaultKey,
          envelope:
              jsonDecode(firstPending.single.envelopeJson)
                  as Map<String, dynamic>,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        expect(plaintext['type'], 'shellHistory');
        expect(plaintext['command'], event.command);
        expect(plaintext['host_record_id'], _hostId);
        expect(plaintext['source_device_id'], fixture.identity.deviceId);

        await fixture.app.setShellHistorySyncEnabled(true);
        expect(await fixture.database.countPending(_vaultId), 1);

        final staged = (await fixture.database.allPendingOperations(
          _vaultId,
        )).single;
        await fixture.app.setShellHistorySyncEnabled(false);
        expect(fixture.app.shellHistorySyncEnabled, isFalse);
        expect(await fixture.database.countPending(_vaultId), 0);
        expect(
          await fixture.database.cachedEnvelope(_vaultId, staged.recordId),
          isNull,
        );

        await fixture.localHistory.clear(hostId: _hostId);
        expect(await fixture.localHistory.load(hostId: _hostId), isEmpty);
        expect(await fixture.database.countPending(_vaultId), 0);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'turning sync off removes queued history but retains sent and committed rows',
    () async {
      final fixture = await _fixture(sodium);
      try {
        for (final command in [
          'queued-command',
          'sent-command',
          'committed-command',
        ]) {
          await fixture.localHistory.record(
            hostId: _hostId,
            command: _event(command),
          );
        }
        await fixture.app.setShellHistorySyncEnabled(true);
        final staged = await fixture.database.allPendingOperations(_vaultId);
        expect(staged, hasLength(3));
        await fixture.database.markAttempted([staged[0].opId]);
        await fixture.database.markCommitted(
          opId: staged[1].opId,
          commitSeq: '2',
        );

        await fixture.app.setShellHistorySyncEnabled(false);

        final remaining = await fixture.database.allPendingOperations(_vaultId);
        expect(remaining, hasLength(1));
        expect(remaining.single.opId, staged[0].opId);
        expect(remaining.single.status, 'sent');
        expect(
          await fixture.database.cachedEnvelope(_vaultId, staged[2].recordId),
          isNull,
        );
        expect(
          (await fixture.database.cachedEnvelope(
            _vaultId,
            staged[0].recordId,
          ))?.commitSeq,
          isNull,
        );
        expect(
          (await fixture.database.cachedEnvelope(
            _vaultId,
            staged[1].recordId,
          ))?.commitSeq,
          '2',
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'Vault read-only state blocks sync opt-in and leaves local history intact',
    () async {
      final fixture = await _fixture(sodium, canWrite: false);
      try {
        await fixture.localHistory.record(
          hostId: _hostId,
          command: _event('uname -a'),
        );
        await expectLater(
          fixture.app.setShellHistorySyncEnabled(true),
          throwsStateError,
        );
        expect(fixture.app.shellHistorySyncEnabled, isFalse);
        expect(await fixture.database.countPending(_vaultId), 0);
        expect(await fixture.localHistory.load(hostId: _hostId), hasLength(1));
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'another device decrypts the Vault record without the local history key',
    () async {
      final fixture = await _fixture(sodium);
      final otherIdentity = DeviceIdentity.create(sodium);
      final otherLocal = EncryptedShellHistoryRepository(
        database: fixture.database,
        crypto: VaultCrypto(sodium),
        identity: otherIdentity,
        baseUrl: 'https://history-sync.example.test/tenant',
        accountId: _accountId,
      );
      try {
        await fixture.localHistory.record(
          hostId: _hostId,
          command: _event('git status --short'),
        );
        await fixture.app.setShellHistorySyncEnabled(true);
        final pending = (await fixture.database.allPendingOperations(
          _vaultId,
        )).single;
        final decoded = await VaultCrypto(sodium).decryptRecord(
          vaultKey: fixture.vaultKey,
          envelope: jsonDecode(pending.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        expect(decoded['command'], 'git status --short');
        expect(await otherLocal.load(hostId: _hostId), isEmpty);
      } finally {
        otherLocal.close();
        otherIdentity.dispose();
        await fixture.dispose();
      }
    },
  );

  test(
    'clearing local history invalidates a pending tab restoration',
    () async {
      final fixture = await _fixture(sodium);
      try {
        await fixture.localHistory.record(
          hostId: _hostId,
          command: _event('must-not-return-after-clear'),
        );
        fixture.app.selectedHost = fixture.app.hosts.single;
        fixture.app.terminalConnection = _RecordingConnection();
        final tab = fixture.app.terminalTabs.single;
        final restorationAtStart = tab.shellHistoryRestorationGeneration;

        final clearing = fixture.app.clearTerminalShellHistoryFor(tab.id);
        expect(tab.shellHistoryRestorationGeneration, restorationAtStart + 1);
        await clearing;
        await tab.shellHistoryRestoration;

        expect(tab.shellIntegrationHistory, isEmpty);
        expect(await fixture.localHistory.load(hostId: _hostId), isEmpty);
      } finally {
        await fixture.dispose();
      }
    },
  );
}

Future<_ShellHistoryFixture> _fixture(
  SodiumSumo sodium, {
  bool canWrite = true,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final vaultKey = sodium.randombytes.buf(32);
  final api = _TestApi(identity);
  final crypto = VaultCrypto(sodium);
  final repository = SyncRepository(
    api: api,
    database: database,
    crypto: crypto,
    identity: identity,
    serverSpaceId: '11111111-1111-4111-8111-111111111111',
    instanceId: '22222222-2222-4222-8222-222222222222',
    vaultId: _vaultId,
    keyEpoch: '1',
    membershipVersion: '1',
    serverGeneration: '1',
    vaultKey: vaultKey,
    canWrite: canWrite,
  );
  const vault = VaultDescriptor(
    id: _vaultId,
    role: 'owner',
    activeKeyEpoch: '1',
    membershipVersion: '1',
    canWrite: true,
  );
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(const FlutterSecureStorage()),
          repositoryForTesting: repository,
          shellHistoryVaultKeyForTesting: vaultKey,
        )
        ..identity = identity
        ..session = AuthSession(
          accountId: _accountId,
          accessToken: 'access',
          expiresIn: 3600,
          refreshToken: 'refresh',
          deviceId: identity.deviceId,
          vaults: const [vault],
        )
        ..api = api
        ..activeVault = canWrite
            ? vault
            : const VaultDescriptor(
                id: _vaultId,
                role: 'viewer',
                activeKeyEpoch: '1',
                membershipVersion: '1',
                canWrite: false,
              )
        ..hosts.add(
          const HostRecord(
            id: _hostId,
            name: 'Test host',
            address: 'host.example.test',
            username: 'tester',
          ),
        );
  final localHistory = EncryptedShellHistoryRepository(
    database: database,
    crypto: crypto,
    identity: identity,
    baseUrl: api.baseUrl,
    accountId: _accountId,
  );
  return _ShellHistoryFixture(
    app: app,
    database: database,
    repository: repository,
    identity: identity,
    vaultKey: vaultKey,
    localHistory: localHistory,
  );
}

class _ShellHistoryFixture {
  const _ShellHistoryFixture({
    required this.app,
    required this.database,
    required this.repository,
    required this.identity,
    required this.vaultKey,
    required this.localHistory,
  });

  final AppController app;
  final ClientDatabase database;
  final SyncRepository repository;
  final DeviceIdentity identity;
  final Uint8List vaultKey;
  final EncryptedShellHistoryRepository localHistory;

  Future<void> dispose() async {
    app.dispose();
    localHistory.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
    await database.close();
  }
}

class _TestApi extends ApiClient {
  _TestApi(this.identity)
    : super(baseUrl: 'https://history-sync.example.test/tenant');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _accountId,
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

ShellIntegrationCompletedCommand _event(String command) {
  final startedAt = DateTime.utc(2026, 10, 8, 12);
  return ShellIntegrationCompletedCommand(
    commandId: 1,
    command: command,
    exitStatus: 0,
    startedAt: startedAt,
    completedAt: startedAt.add(const Duration(seconds: 1)),
  );
}

class _RecordingConnection implements SshConnection {
  _RecordingConnection() {
    _output = StreamController<String>.broadcast(sync: true);
  }

  late final StreamController<String> _output;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
