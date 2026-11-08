import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/ssh_forwarding_cloud_source.dart';
import 'package:aterm_client/ui/ssh_forwarding_page.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/ssh_port_forward_fakes.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _userId = '44444444-4444-4444-8444-444444444444';
const _hostId = '88888888-8888-4888-8888-888888888888';

const _vault = VaultDescriptor(
  id: _vaultId,
  role: 'owner',
  activeKeyEpoch: '1',
  membershipVersion: '1',
  canWrite: true,
);

const _host = HostRecord(
  id: _hostId,
  name: 'Development host',
  address: 'ssh.example.test',
  username: 'developer',
);

const _rule = SshPortForwardProfile(
  id: 'local-db',
  name: 'Private database',
  type: SshPortForwardType.local,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  destinationAddress: 'db.internal',
  destinationPort: 5432,
);

class _Api extends ApiClient {
  _Api(this.identity) : super(baseUrl: 'https://forwarding.test');

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

class _Connection implements SshConnection {
  _Connection(this.fake);

  final FakeForwardingSshClient fake;
  final _output = StreamController<String>.broadcast();
  bool closed = false;

  @override
  SSHClient get client => fake;
  @override
  Stream<String> get output => _output.stream;
  @override
  late final portForwards = SshPortForwardManager(fake);
  @override
  void input(String text) {}
  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await portForwards.closeAll();
    fake.endTransport();
    await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedRepository extends SyncRepository {
  _GatedRepository({
    required super.api, required super.database, required super.crypto,
    required super.identity, required super.serverSpaceId, required super.instanceId,
    required super.vaultId, required super.keyEpoch, required super.membershipVersion,
    required super.serverGeneration, required super.vaultKey, super.canWrite,
  });
  Completer<void>? snapshotGate;
  Completer<void>? snapshotEntered;

  Completer<void>? writeGate;
  Completer<void>? writeEntered;

  @override
  Future<Map<String, Object?>> saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) async {
    final envelope = await super.saveRecord(
      recordId: recordId, plaintext: plaintext, baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain, operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    );
    final gate = writeGate;
    if (gate != null) {
      writeGate = null;
      writeEntered?.complete();
      await gate.future;
    }
    return envelope;
  }

  @override
  Future<({List<Map<String, dynamic>> records, Map<String, String> headRevisionIds})>
  loadRecordsWithHeadRevisionSnapshot({bool includeDeleted = false}) async {
    final snapshot = await super.loadRecordsWithHeadRevisionSnapshot(includeDeleted: includeDeleted);
    final gate = snapshotGate;
    if (gate != null) {
      snapshotGate = null;
      snapshotEntered?.complete();
      await gate.future;
    }
    return snapshot;
  }
}

class _Fixture {
  _Fixture(this.app, this.database, this.repository, this.identity, this.key);

  final AppController app;
  final ClientDatabase database;
  final SyncRepository repository;
  final DeviceIdentity identity;
  final Uint8List key;
  final connections = <_Connection>[];
  Completer<void>? editorGate;
  Object? connectFailure;

  SyncRepository newRepository() => SyncRepository(
    api: repository.api,
    database: database,
    crypto: repository.crypto,
    identity: identity,
    serverSpaceId: _serverSpaceId,
    instanceId: _instanceId,
    vaultId: _vaultId,
    keyEpoch: '1',
    membershipVersion: '1',
    serverGeneration: '1',
    vaultKey: key,
    canWrite: true,
  );

  Future<Map<String, dynamic>> storedHost() async {
    final stored = await database.encryptedRecord(_vaultId, _hostId);
    return repository.crypto.decryptRecord(
      vaultKey: key,
      envelope: jsonDecode(stored!.envelopeJson) as Map<String, dynamic>,
      authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
    );
  }

  Future<void> dispose() async {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    identity.dispose();
    key.fillRange(0, key.length, 0);
    await database.close();
  }
}

Future<_Fixture> _fixture(SodiumSumo sodium) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final key = sodium.randombytes.buf(32);
  final api = _Api(identity);
  final repository = _GatedRepository(
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
    vaultKey: key,
    canWrite: true,
  );
  late final _Fixture fixture;
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          repositoryForTesting: repository,
          beforeHostEditorSaveForTesting: () async {
            await fixture.editorGate?.future;
          },
          sshConnectorForTesting:
              ({required host, required credential, required verifyHostKey}) async {
                final failure = fixture.connectFailure;
                if (failure != null) throw failure;
                final connection = _Connection(FakeForwardingSshClient());
                fixture.connections.add(connection);
                return connection;
              },
        )
        ..activeVault = _vault
        ..session = AuthSession(
          accountId: 'account-test',
          accessToken: 'test',
          expiresIn: 3600,
          refreshToken: 'test',
          deviceId: identity.deviceId,
          vaults: const [],
        )
        ..identity = identity
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts;
  fixture = _Fixture(app, database, repository, identity, key);
  return fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('scoped rule save writes the encrypted Host in the captured scope', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      await app.saveHost(_host);
      final source = CloudSshForwardingSource(app);
      expect(source.scopeKey, same(fixture.repository));
      await source.saveRule(
        _hostId,
        replacement: _rule,
        scope: source.scopeKey,
      );
      expect(app.hosts.single.portForwardProfiles, const [_rule]);
      expect((await fixture.storedHost())['port_forward_profiles'], [
        _rule.toJson(),
      ]);
    } finally {
      await fixture.dispose();
    }
  });

  for (final afterCommit in [false, true]) {
  test('scope switch during forwarding ${afterCommit ? "commit" : "validation"} cannot refresh new-scope tabs', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      await app.saveHost(_host);
      final repository = fixture.repository as _GatedRepository;
      final entered = Completer<void>();
      final gate = Completer<void>();
      if (afterCommit) {
        repository.writeEntered = entered;
        repository.writeGate = gate;
      } else {
        repository.snapshotEntered = entered;
        repository.snapshotGate = gate;
      }
      final save = app.updateHostPortForwardRuleInScope(
        hostId: _hostId, replacement: _rule, scope: repository,
      );
      Object? error;
      final done = save.catchError((Object value) { error = value; });
      await entered.future;
      app.replaceRecordScopeForTesting(repository: fixture.newRepository(), vault: _vault);
      app.hosts
        ..clear()
        ..add(_host.copyWith(name: 'New scope record'));
      var notifications = 0;
      app.addListener(() => notifications++);
      gate.complete();
      await done;
      expect(error, isA<StateError>());
      expect(notifications, 0);
      expect(app.hosts.single.name, 'New scope record');
      expect(app.hosts.single.portForwardProfiles, isEmpty);
    } finally {
      await fixture.dispose();
    }
  });
  }

  test('a rule save queued behind another write never lands after a '
      'Vault switch (A -> B -> A)', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      await app.saveHost(_host);
      final scope = app.recordWriteScope!;
      // Hold the mutation queue with an in-flight Host editor save.
      fixture.editorGate = Completer<void>();
      final editor = app.saveHostFromEditor(
        original: _host,
        edited: _host.copyWith(name: 'Renamed'),
      );
      final queued = app.updateHostPortForwardRuleInScope(
        hostId: _hostId,
        replacement: _rule,
        scope: scope,
      );
      Object? queuedError;
      final queuedDone = queued.catchError((Object error) {
        queuedError = error;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Switch away and back: same account and Vault id, new repository.
      app.replaceRecordScopeForTesting(
        repository: fixture.newRepository(),
        vault: const VaultDescriptor(
          id: '99999999-9999-4999-8999-999999999999',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: true,
        ),
      );
      final again = fixture.newRepository();
      app.replaceRecordScopeForTesting(repository: again, vault: _vault);
      expect(app.recordWriteScope, isNot(same(scope)));
      fixture.editorGate!.complete();
      await editor.catchError((Object _) {});
      await queuedDone;
      expect(queuedError, isA<StateError>());
      expect(
        (await fixture.storedHost())['port_forward_profiles'] ?? const [],
        isEmpty,
      );
      // The page-facing adapter refuses a stale scope before queueing too.
      final source = CloudSshForwardingSource(app);
      await expectLater(
        source.saveRule(_hostId, replacement: _rule, scope: scope),
        throwsA(isA<StateError>()),
      );
    } finally {
      await fixture.dispose();
    }
  });

  test('queued rule saves apply to the Host as it is in the queue: no '
      'lost rule, no lost Host edit, stale edits refused', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      await app.saveHost(_host);
      final scope = app.recordWriteScope!;
      final other = _rule.copyWith(name: 'Second').copyWithId('second');
      fixture.editorGate = Completer<void>();
      final editor = app.saveHostFromEditor(
        original: _host,
        edited: _host.copyWith(name: 'Renamed'),
      );
      // Both were computed while neither rule existed yet.
      final first = app.updateHostPortForwardRuleInScope(
        hostId: _hostId,
        replacement: _rule,
        scope: scope,
      );
      final second = app.updateHostPortForwardRuleInScope(
        hostId: _hostId,
        replacement: other,
        scope: scope,
      );
      fixture.editorGate!.complete();
      await editor;
      await first;
      await second;
      final stored = await fixture.storedHost();
      expect(stored['name'], 'Renamed');
      expect(stored['port_forward_profiles'], [
        _rule.toJson(),
        other.toJson(),
      ]);

      // Two edits of the same rule from the same snapshot: the later one is
      // refused instead of silently reverting the earlier one.
      final edited = _rule.copyWith(destinationPort: 6543);
      final stale = _rule.copyWith(name: 'Stale');
      fixture.editorGate = Completer<void>();
      final hold = app.saveHostFromEditor(
        original: app.hosts.single,
        edited: app.hosts.single.copyWith(port: 2222),
      );
      final winner = app.updateHostPortForwardRuleInScope(
        hostId: _hostId,
        expected: _rule,
        replacement: edited,
        scope: scope,
      );
      final loser = app.updateHostPortForwardRuleInScope(
        hostId: _hostId,
        expected: _rule,
        replacement: stale,
        scope: scope,
      );
      Object? loserError;
      final loserDone = loser.catchError((Object error) {
        loserError = error;
      });
      fixture.editorGate!.complete();
      await hold;
      await winner;
      await loserDone;
      expect(loserError, isA<SshPortForwardRuleConflict>());
      final after = await fixture.storedHost();
      expect(after['port'], 2222);
      expect(after['port_forward_profiles'], [
        edited.toJson(),
        other.toJson(),
      ]);
      // A delete of a rule that changed meanwhile is refused too.
      await expectLater(
        app.updateHostPortForwardRuleInScope(
          hostId: _hostId,
          expected: _rule,
          scope: scope,
        ),
        throwsA(isA<SshPortForwardRuleConflict>()),
      );
    } finally {
      await fixture.dispose();
    }
  });

  test('connect and start uses the normal terminal tab connect and starts '
      'on exactly that tab, also when no page is shown', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      app.credentials.add(
        const CredentialRecord(id: 'credential', name: 'Key', username: 'u'),
      );
      final host = _host.copyWith(
        credentialId: 'credential',
        portForwardProfiles: const [_rule],
      );
      app.hosts.add(host);
      final source = CloudSshForwardingSource(app);
      final controller = SshForwardingController(
        runtimeSupported: true,
        source: source,
      );
      // A second tab of the same host already exists and must stay untouched.
      await app.openTerminalTab(host);
      final existing = fixture.connections.single;
      expect(source.sessions.single.phase, SshForwardingSessionPhase.connected);
      // Two authenticated tabs and no choice: never guesses.
      await app.openTerminalTab(host);
      await controller.start(source, _hostId, _rule.id);
      expect(controller.noteOf(_hostId, _rule.id), isNotNull);
      for (final connection in fixture.connections) {
        expect(connection.portForwards.runningCount, 0);
      }
      // Close both; now Start connects a fresh tab through openTerminalTab.
      await app.disconnectAllTerminalTabs();
      for (final tab in app.terminalTabs.toList()) {
        await app.closeTerminalTab(tab.id);
      }
      await controller.start(source, _hostId, _rule.id);
      final fresh = fixture.connections.last;
      expect(fresh, isNot(same(existing)));
      expect(fresh.portForwards.activeProfileIds, [_rule.id]);
      final tab = app.terminalTabs.singleWhere((tab) => !tab.closed);
      expect(controller.selectedSessionId(_hostId), tab.id);
      expect(source.sessions.single.manager, same(fresh.portForwards));

      // Failed authentication / rejected host key: nothing starts.
      await fresh.portForwards.stop(_rule.id);
      await app.closeTerminalTab(tab.id);
      fixture.connectFailure = StateError('host key was not approved');
      await controller.start(source, _hostId, _rule.id);
      expect(
        controller.noteOf(_hostId, _rule.id),
        currentL10n.r7ForwardNotConnected,
      );
      expect(
        fixture.connections.where((c) => c.portForwards.runningCount > 0),
        isEmpty,
      );
      controller.dispose();
    } finally {
      await fixture.dispose();
    }
  });

  test('a Vault switch while connecting drops the pending start even when '
      'the page is not shown', () async {
    final fixture = await _fixture(sodium);
    try {
      final app = fixture.app;
      app.credentials.add(
        const CredentialRecord(id: 'credential', name: 'Key', username: 'u'),
      );
      final host = _host.copyWith(
        credentialId: 'credential',
        portForwardProfiles: const [_rule],
      );
      app.hosts.add(host);
      final source = CloudSshForwardingSource(app);
      final controller = SshForwardingController(
        runtimeSupported: true,
        source: source,
      );
      final gate = Completer<String?>();
      final gated = _GatedSource(source, gate.future);
      final start = controller.start(gated, _hostId, _rule.id);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isConnecting(_hostId, _rule.id), isTrue);
      // A -> B -> A while the connection is pending.
      app.replaceRecordScopeForTesting(
        repository: fixture.newRepository(),
        vault: _vault,
      );
      // ignore: invalid_use_of_protected_member
      app.notifyListeners();
      expect(controller.isConnecting(_hostId, _rule.id), isFalse);
      await app.openTerminalTab(host);
      gate.complete(app.terminalTabs.single.id);
      await start;
      expect(fixture.connections.single.portForwards.runningCount, 0);
      controller.dispose();
    } finally {
      await fixture.dispose();
    }
  });
}

/// Delegates to the real cloud source but lets the test decide when the
/// connection "authenticates".
class _GatedSource implements SshForwardingSource {
  _GatedSource(this.inner, this.result);

  final CloudSshForwardingSource inner;
  final Future<String?> result;

  @override
  Future<String?> connect(HostRecord host) => result;
  @override
  Object? get scopeKey => inner.scopeKey;
  @override
  List<HostRecord> get hosts => inner.hosts;
  @override
  List<SshForwardingSessionInfo> get sessions => inner.sessions;
  @override
  bool get canEdit => inner.canEdit;
  @override
  String? get readOnlyReason => inner.readOnlyReason;
  @override
  String get storageDescription => inner.storageDescription;
  @override
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) => inner.saveRule(
    hostId,
    expected: expected,
    replacement: replacement,
    scope: scope,
  );
  @override
  String describeSaveError(Object error) => inner.describeSaveError(error);
  @override
  void showSession(String sessionId) => inner.showSession(sessionId);
  @override
  void addListener(void Function() listener) => inner.addListener(listener);
  @override
  void removeListener(void Function() listener) =>
      inner.removeListener(listener);
}

extension on SshPortForwardProfile {
  SshPortForwardProfile copyWithId(String id) => SshPortForwardProfile(
    id: id,
    name: name,
    type: type,
    bindAddress: bindAddress,
    bindPort: bindPort,
    destinationAddress: destinationAddress,
    destinationPort: destinationPort,
    exposeToNetwork: exposeToNetwork,
  );
}
