import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ssh/tmux_service.dart';
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
const _paneId = '55555555-5555-4555-8555-555555555555';
const _workspaceId = '66666666-6666-4666-8666-666666666666';
const _credentialId = '77777777-7777-4777-8777-777777777777';
const _serverGeneration = '88888888-8888-4888-8888-888888888888';
const _otherVaultId = '99999999-9999-4999-8999-999999999999';
const _tmuxSessionName = 'atermius_0123456789abcdef0123456789abcdef';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit Start saves an encrypted reference and routes terminal I/O to tmux',
    () async {
      final fixture = await _TmuxControllerFixture.create();
      try {
        await fixture.connect();
        expect(
          fixture.tmux.calls,
          isEmpty,
          reason: 'Connect must not probe or attach tmux',
        );

        final tab = fixture.app.workspacePaneTerminalTab(
          fixture.workspace.id,
          _paneId,
        )!;
        await fixture.app.startWorkspacePaneTmux(fixture.workspace.id, _paneId);

        final saved = fixture.app.savedWorkspaces.single;
        final descriptor = saved.sessionDescriptors.single;
        expect(saved.schemaVersion, workspaceLayoutSchemaVersion);
        expect(descriptor.paneId, _paneId);
        expect(descriptor.hostId, _hostId);
        expect(descriptor.tmuxSessionName, startsWith('atermius_'));
        expect(fixture.tmux.createdSessionNames, [descriptor.tmuxSessionName]);
        expect(fixture.tmux.attachedSessionNames, [descriptor.tmuxSessionName]);
        expect(fixture.connection.inputs, isEmpty);

        fixture.app.sendTerminalInputFor(tab.id, 'echo resumed');
        fixture.app.resizeTerminalFor(tab.id, 120, 42);
        expect(fixture.tmux.lastHandle!.inputs, ['echo resumed']);
        expect(fixture.tmux.lastHandle!.resizes, [(120, 42)]);
        expect(fixture.connection.inputs, isEmpty);

        final stored = await fixture.database.encryptedRecord(
          _vaultId,
          _workspaceId,
        );
        expect(stored, isNotNull);
        expect(
          stored!.envelopeJson,
          isNot(contains(descriptor.tmuxSessionName)),
        );
        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(
            fixture.identity.signing.publicKey,
          ),
        );
        final decoded = WorkspaceRecord.fromJson(plaintext);
        expect(decoded.schemaVersion, workspaceLayoutSchemaVersion);
        expect(
          decoded.sessionDescriptors.single.tmuxSessionName,
          descriptor.tmuxSessionName,
        );
        expect(plaintext.keys, isNot(contains('terminal_output')));
        expect(plaintext.keys, isNot(contains('credential')));

        await fixture.app.closeTerminalTab(tab.id);
        expect(fixture.tmux.lastHandle!.closed, isTrue);
        expect(fixture.connection.closeCount, 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'Resume never creates a missing session or attaches a fallback',
    () async {
      final descriptor = WorkspaceSessionDescriptor(
        paneId: _paneId,
        hostId: _hostId,
        tmuxSessionName: _tmuxSessionName,
      );
      final fixture = await _TmuxControllerFixture.create(
        sessionDescriptors: [descriptor],
      );
      try {
        await fixture.connect();
        expect(
          fixture.tmux.calls,
          isEmpty,
          reason: 'Connect must not auto-resume',
        );

        await expectLater(
          fixture.app.resumeWorkspacePaneTmux(fixture.workspace.id, _paneId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('不会自动创建'),
            ),
          ),
        );
        expect(fixture.tmux.createdSessionNames, isEmpty);
        expect(fixture.tmux.attachedSessionNames, isEmpty);
        expect(fixture.tmux.sessions, isEmpty);
        expect(
          fixture.app.workspacePaneSessionDescriptor(
            fixture.workspace.id,
            _paneId,
          ),
          descriptor,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'successful Resume attaches only the saved session on the current SSH connection',
    () async {
      final descriptor = WorkspaceSessionDescriptor(
        paneId: _paneId,
        hostId: _hostId,
        tmuxSessionName: _tmuxSessionName,
      );
      final fixture = await _TmuxControllerFixture.create(
        sessionDescriptors: [descriptor],
      );
      try {
        await fixture.connect();
        fixture.tmux.sessions.add(_tmuxSessionName);

        await fixture.app.resumeWorkspacePaneTmux(
          fixture.workspace.id,
          _paneId,
        );

        expect(fixture.tmux.createdSessionNames, isEmpty);
        expect(fixture.tmux.attachedSessionNames, [_tmuxSessionName]);
        expect(
          fixture.app.workspacePaneSessionDescriptor(
            fixture.workspace.id,
            _paneId,
          ),
          descriptor,
        );
        expect(fixture.connection.closeCount, 0);
        expect(fixture.tmux.lastHandle, isNotNull);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'uncertain create acknowledgement removes an unreferenced remote session',
    () async {
      final fixture = await _TmuxControllerFixture.create(
        failCreateAfterApplying: true,
      );
      try {
        await fixture.connect();

        await expectLater(
          fixture.app.startWorkspacePaneTmux(fixture.workspace.id, _paneId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('tmux 操作超时'),
            ),
          ),
        );

        expect(fixture.tmux.createdSessionNames, hasLength(1));
        expect(
          fixture.tmux.killedSessionNames,
          fixture.tmux.createdSessionNames,
        );
        expect(fixture.tmux.sessions, isEmpty);
        expect(fixture.tmux.attachedSessionNames, isEmpty);
        expect(fixture.app.savedWorkspaces.single.sessionDescriptors, isEmpty);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'Vault switch after encrypted descriptor commit never kills its tmux session',
    () async {
      final fixture = await _TmuxControllerFixture.create(
        switchVaultAfterWorkspaceSave: true,
      );
      try {
        await fixture.connect();

        await expectLater(
          fixture.app.startWorkspacePaneTmux(fixture.workspace.id, _paneId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Vault 或 SSH 连接已变化'),
            ),
          ),
        );

        expect(fixture.tmux.createdSessionNames, hasLength(1));
        expect(fixture.tmux.killedSessionNames, isEmpty);
        expect(fixture.tmux.sessions, fixture.tmux.createdSessionNames.toSet());
        final stored = await fixture.database.encryptedRecord(
          _vaultId,
          _workspaceId,
        );
        expect(stored, isNotNull);
        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.key,
          envelope: jsonDecode(stored!.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(
            fixture.identity.signing.publicKey,
          ),
        );
        expect(
          WorkspaceRecord.fromJson(
            plaintext,
          ).sessionDescriptors.single.tmuxSessionName,
          fixture.tmux.createdSessionNames.single,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'PTY attach failure after descriptor commit keeps the session resumable',
    () async {
      final fixture = await _TmuxControllerFixture.create(failAttachCount: 1);
      try {
        await fixture.connect();

        await expectLater(
          fixture.app.startWorkspacePaneTmux(fixture.workspace.id, _paneId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('无法完成 tmux 会话操作'),
            ),
          ),
        );

        final committedDescriptor = fixture.app.workspacePaneSessionDescriptor(
          fixture.workspace.id,
          _paneId,
        );
        expect(committedDescriptor, isNotNull);
        expect(
          committedDescriptor!.tmuxSessionName,
          fixture.tmux.createdSessionNames.single,
        );
        expect(fixture.tmux.sessions, {committedDescriptor.tmuxSessionName});
        expect(fixture.tmux.killedSessionNames, isEmpty);
        expect(fixture.tmux.attachedSessionNames, isEmpty);
        expect(
          fixture.app.workspacePaneTmuxBusy(fixture.workspace.id, _paneId),
          isFalse,
        );
        expect(
          fixture.app.workspacePaneTmuxAttached(fixture.workspace.id, _paneId),
          isFalse,
        );

        final stored = await fixture.database.encryptedRecord(
          _vaultId,
          _workspaceId,
        );
        expect(stored, isNotNull);
        expect(
          stored!.envelopeJson,
          isNot(contains(committedDescriptor.tmuxSessionName)),
        );
        final plaintext = await fixture.repository.crypto.decryptRecord(
          vaultKey: fixture.key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(
            fixture.identity.signing.publicKey,
          ),
        );
        expect(
          WorkspaceRecord.fromJson(
            plaintext,
          ).sessionDescriptors.single.tmuxSessionName,
          committedDescriptor.tmuxSessionName,
        );

        // A successful retry proves both the pane busy key and its operation
        // cancellation handle were removed after the failed attach.
        await fixture.app.resumeWorkspacePaneTmux(
          fixture.workspace.id,
          _paneId,
        );
        expect(fixture.tmux.createdSessionNames, [
          committedDescriptor.tmuxSessionName,
        ]);
        expect(fixture.tmux.killedSessionNames, isEmpty);
        expect(fixture.tmux.sessions, {committedDescriptor.tmuxSessionName});
        expect(fixture.tmux.attachedSessionNames, [
          committedDescriptor.tmuxSessionName,
        ]);
        expect(
          fixture.app.workspacePaneTmuxBusy(fixture.workspace.id, _paneId),
          isFalse,
        );
        expect(
          fixture.app.workspacePaneTmuxAttached(fixture.workspace.id, _paneId),
          isTrue,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'missing tmux and missing Host fail before descriptor or attach changes',
    () async {
      final noTmux = await _TmuxControllerFixture.create(tmuxAvailable: false);
      try {
        await noTmux.connect();
        await expectLater(
          noTmux.app.startWorkspacePaneTmux(noTmux.workspace.id, _paneId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('没有可用的 tmux'),
            ),
          ),
        );
        expect(noTmux.tmux.createdSessionNames, isEmpty);
        expect(noTmux.tmux.attachedSessionNames, isEmpty);
        expect(noTmux.app.savedWorkspaces.single.sessionDescriptors, isEmpty);
      } finally {
        await noTmux.close();
      }

      final missingHost = await _TmuxControllerFixture.create(
        sessionDescriptors: [
          WorkspaceSessionDescriptor(
            paneId: _paneId,
            hostId: _hostId,
            tmuxSessionName: _tmuxSessionName,
          ),
        ],
      );
      try {
        await missingHost.connect();
        missingHost.app.hosts.clear();
        await expectLater(
          missingHost.app.resumeWorkspacePaneTmux(
            missingHost.workspace.id,
            _paneId,
          ),
          throwsA(isA<StateError>()),
        );
        expect(missingHost.tmux.calls, isEmpty);
        expect(missingHost.connection.closeCount, 0);
      } finally {
        await missingHost.close();
      }
    },
  );
}

class _TmuxControllerFixture {
  _TmuxControllerFixture({
    required this.sodium,
    required this.database,
    required this.identity,
    required this.key,
    required this.repository,
    required this.app,
    required this.workspace,
    required this.connection,
    required this.tmux,
  });

  final SodiumSumo sodium;
  final ClientDatabase database;
  final DeviceIdentity identity;
  final Uint8List key;
  final SyncRepository repository;
  final AppController app;
  final WorkspaceRecord workspace;
  final _WorkspaceSshConnection connection;
  final _RecordingTmuxService tmux;

  static Future<_TmuxControllerFixture> create({
    bool tmuxAvailable = true,
    bool failCreateAfterApplying = false,
    int failAttachCount = 0,
    bool switchVaultAfterWorkspaceSave = false,
    List<WorkspaceSessionDescriptor> sessionDescriptors = const [],
  }) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final key = sodium.randombytes.buf(32);
    late AppController app;
    final repository = _WorkspaceCommitSwitchRepository(
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
      onWorkspaceSaved: () {
        if (switchVaultAfterWorkspaceSave) {
          app.activeVault = const VaultDescriptor(
            id: _otherVaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
        }
      },
    );
    final connection = _WorkspaceSshConnection();
    final tmux = _RecordingTmuxService(
      available: tmuxAvailable,
      failCreateAfterApplying: failCreateAfterApplying,
      failAttachCount: failAttachCount,
    );
    app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            repositoryForTesting: repository,
            tmuxServiceForTesting: tmux,
            sshConnectorForTesting:
                ({
                  required host,
                  required credential,
                  required verifyHostKey,
                }) async => connection,
          )
          ..session = AuthSession(
            accountId: 'account-test',
            accessToken: 'access-test',
            expiresIn: 3600,
            refreshToken: 'refresh-test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
    const host = HostRecord(
      id: _hostId,
      name: 'Tmux Host',
      address: 'tmux.example.test',
      username: 'tester',
      credentialId: _credentialId,
    );
    const credential = CredentialRecord(
      id: _credentialId,
      name: 'Tmux credential',
      username: 'tester',
      secret: 'test-secret-only',
    );
    final workspace = WorkspaceRecord.fromHostIds(
      id: _workspaceId,
      name: 'tmux test',
      hostIds: const [_hostId],
      paneIds: const [_paneId],
      sessionDescriptors: sessionDescriptors,
    );
    app
      ..hosts.add(host)
      ..credentials.add(credential)
      ..savedWorkspaces.add(workspace);
    app.stageWorkspace(workspace.id);
    return _TmuxControllerFixture(
      sodium: sodium,
      database: database,
      identity: identity,
      key: key,
      repository: repository,
      app: app,
      workspace: workspace,
      connection: connection,
      tmux: tmux,
    );
  }

  Future<void> connect() => app.connectWorkspacePane(workspace.id, _paneId);

  Future<void> close() async {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    identity.dispose();
    key.fillRange(0, key.length, 0);
    await database.close();
  }
}

class _WorkspaceCommitSwitchRepository extends SyncRepository {
  _WorkspaceCommitSwitchRepository({
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
    required this.onWorkspaceSaved,
  });

  final void Function() onWorkspaceSaved;

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
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain,
      operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    );
    if (recordId == _workspaceId && operation == 'update') {
      onWorkspaceSaved();
    }
    return envelope;
  }
}

class _WorkspaceApi extends ApiClient {
  _WorkspaceApi(this.identity) : super(baseUrl: 'https://workspace.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': 'user-test',
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

class _WorkspaceSshConnection implements SshConnection {
  final _output = StreamController<String>.broadcast(sync: true);
  final List<String> inputs = [];
  final List<(int, int)> resizes = [];
  int closeCount = 0;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));

  @override
  Future<void> close() async {
    closeCount++;
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingTmuxService implements TmuxService {
  _RecordingTmuxService({
    required this.available,
    this.failCreateAfterApplying = false,
    this.failAttachCount = 0,
  });

  final bool available;
  final bool failCreateAfterApplying;
  int failAttachCount;
  final Set<String> sessions = {};
  final List<String> createdSessionNames = [];
  final List<String> attachedSessionNames = [];
  final List<String> killedSessionNames = [];
  final List<String> calls = [];
  _RecordingTmuxHandle? lastHandle;

  @override
  Future<TmuxProbeStatus> probe(
    SshConnection connection, {
    SshExecCancellation? cancellation,
  }) async {
    calls.add('probe');
    return available ? TmuxProbeStatus.available : TmuxProbeStatus.unavailable;
  }

  @override
  Future<TmuxSessionStatus> hasSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    calls.add('has:$sessionName');
    if (!available) return TmuxSessionStatus.unavailable;
    return sessions.contains(sessionName)
        ? TmuxSessionStatus.exists
        : TmuxSessionStatus.absent;
  }

  @override
  Future<void> createSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    calls.add('create:$sessionName');
    sessions.add(sessionName);
    createdSessionNames.add(sessionName);
    if (failCreateAfterApplying) {
      throw const TmuxServiceException(TmuxServiceFailureReason.timeout);
    }
  }

  @override
  Future<void> killSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    calls.add('kill:$sessionName');
    sessions.remove(sessionName);
    killedSessionNames.add(sessionName);
  }

  @override
  Future<TmuxAttachHandle> openAttach(
    SshConnection connection,
    String sessionName, {
    required int columns,
    required int rows,
    SshExecCancellation? cancellation,
  }) async {
    calls.add('attach:$sessionName');
    if (!sessions.contains(sessionName)) {
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
    if (failAttachCount > 0) {
      failAttachCount--;
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
    attachedSessionNames.add(sessionName);
    lastHandle = _RecordingTmuxHandle();
    return lastHandle!;
  }
}

class _RecordingTmuxHandle implements TmuxAttachHandle {
  final _stdout = StreamController<Uint8List>.broadcast(sync: true);
  final List<String> inputs = [];
  final List<(int, int)> resizes = [];
  bool closed = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _stdout.done;

  @override
  Future<void> input(Uint8List bytes) async => inputs.add(utf8.decode(bytes));

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));

  @override
  void close() {
    closed = true;
    if (!_stdout.isClosed) unawaited(_stdout.close());
  }
}
