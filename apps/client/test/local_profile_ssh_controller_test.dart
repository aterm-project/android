import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _changedFingerprint =
    'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late UnlockedLocalProfile profile;
  late LocalVaultDatabase database;
  late LocalHostRepository repository;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-local-ssh-');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    profile = await profileService.create(
      password: 'correct horse battery staple',
    );
    database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profile.record.profileId,
      localDataDomainId: profile.record.localDataDomainId,
      localVaultId: profile.record.localVaultId,
    );
    repository = LocalHostRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
  });

  tearDown(() async {
    await database.close();
    await profile.lock();
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const host = HostRecord(
    id: '1f36e3d1-153a-4f62-aab0-97518e0b3234',
    name: 'Local production host',
    address: 'host.example.test',
    port: 2222,
    username: 'deploy',
  );
  const credential = CredentialRecord(
    id: 'eb3c5844-4170-4fc8-9b69-d6b20a4348dc',
    name: 'local deploy password',
    username: 'deploy',
    kind: AuthKind.password,
    secret: 'local-secret',
  );

  _TestService createService({
    String fingerprint = _fingerprint,
    Map<String, String> fingerprintsByHost = const {},
  }) {
    final service = _TestService(
      fingerprint: fingerprint,
      fingerprintsByHost: fingerprintsByHost,
      decisionLock: repository.knownHostDecisionLock,
    );
    return service;
  }

  test(
    'first-seen key is rejected before auth, approved, then re-handshaken',
    () async {
      final service = createService();
      expect(service.service.api, isNull);
      final controller = LocalProfileSshController(
        repository: repository,
        serviceForTesting: service.service,
      );
      final approvals = <LocalKnownHostApprovalRequest>[];

      final connection = await controller.connect(
        host: host,
        credential: credential,
        askApproval: (request) async {
          approvals.add(request);
          return true;
        },
      );
      addTearDown(connection.close);

      expect(approvals, hasLength(1));
      expect(approvals.single.host, host.address);
      expect(approvals.single.port, host.port);
      expect(approvals.single.fingerprint, _fingerprint);
      expect(approvals.single.previouslyRevoked, isFalse);
      expect(service.socketCount, 2);
      expect(service.handshakeCount, 2);
      expect(service.userAuthenticationCount, 1);
      expect(
        await repository.knownHostTrustStatus(
          host: host.address,
          port: host.port,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprint,
        ),
        LocalKnownHostTrustStatus.trusted,
      );
    },
  );

  test(
    'host-key read under SSH shared lock does not queue behind a writer',
    () async {
      final lock = repository.knownHostDecisionLock;
      final scope = repository.knownHostDecisionScope;
      final trust = LocalKnownHostTrustController(
        repository,
        decisionLockAlreadyHeld: true,
      );
      var writerEntered = false;
      late Future<void> queuedWriter;

      await lock.run(scope, () async {
        // This writer is queued while the SSH handshake owns its shared
        // decision lock. A nested reader would sit behind this writer and
        // wait for the outer reader to finish: a lock-order deadlock.
        queuedWriter = lock.run(scope, () async {
          writerEntered = true;
        }, mode: KnownHostDecisionLockMode.exclusive);
        await Future<void>.delayed(Duration.zero);
        expect(writerEntered, isFalse);

        expect(
          await trust
              .verifyHostKey(
                host: host.address,
                port: host.port,
                algorithm: 'ssh-ed25519',
                fingerprint: _fingerprint,
              )
              .timeout(const Duration(seconds: 1)),
          isFalse,
        );
        expect(trust.pendingStatus, LocalKnownHostTrustStatus.unknown);
      }, mode: KnownHostDecisionLockMode.shared);

      await queuedWriter;
      expect(writerEntered, isTrue);
    },
  );

  test(
    'declining an unknown key never authenticates or stores trust',
    () async {
      final service = createService();
      final controller = LocalProfileSshController(
        repository: repository,
        serviceForTesting: service.service,
      );

      await expectLater(
        controller.connect(
          host: host,
          credential: credential,
          askApproval: (_) async => false,
        ),
        throwsA(
          isA<SshHostKeyVerificationException>().having(
            (error) => error.failure,
            'failure',
            SshHostKeyFailure.rejected,
          ),
        ),
      );
      expect(service.socketCount, 1);
      expect(service.handshakeCount, 1);
      expect(service.userAuthenticationCount, 0);
      expect(
        await repository.knownHostTrustStatus(
          host: host.address,
          port: host.port,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprint,
        ),
        LocalKnownHostTrustStatus.unknown,
      );
    },
  );

  test(
    'changed key fails closed without prompting or user authentication',
    () async {
      await repository.approveKnownHost(
        host: host.address,
        port: host.port,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        explicitlyConfirmed: true,
      );
      final service = createService(fingerprint: _changedFingerprint);
      final controller = LocalProfileSshController(
        repository: repository,
        serviceForTesting: service.service,
      );
      var promptCount = 0;

      await expectLater(
        controller.connect(
          host: host,
          credential: credential,
          askApproval: (_) async {
            promptCount++;
            return true;
          },
        ),
        throwsA(
          isA<SshHostKeyVerificationException>().having(
            (error) => error.failure,
            'failure',
            SshHostKeyFailure.changed,
          ),
        ),
      );
      expect(promptCount, 0);
      expect(service.socketCount, 1);
      expect(service.handshakeCount, 1);
      expect(service.userAuthenticationCount, 0);
    },
  );

  test('revoked key requires a second explicit approval decision', () async {
    final approved = await repository.approveKnownHost(
      host: host.address,
      port: host.port,
      algorithm: 'ssh-ed25519',
      fingerprint: _fingerprint,
      explicitlyConfirmed: true,
    );
    await repository.revokeKnownHost(recordId: approved.id);
    final service = createService();
    final controller = LocalProfileSshController(
      repository: repository,
      serviceForTesting: service.service,
    );

    await expectLater(
      controller.connect(
        host: host,
        credential: credential,
        askApproval: (request) async {
          expect(request.previouslyRevoked, isTrue);
          return false;
        },
      ),
      throwsA(isA<SshHostKeyVerificationException>()),
    );
    expect(service.socketCount, 1);
    expect(service.userAuthenticationCount, 0);
    expect(
      await repository.knownHostTrustStatus(
        host: host.address,
        port: host.port,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
      ),
      LocalKnownHostTrustStatus.revoked,
    );
  });

  test(
    'LocalVault resolves Jump Host credentials and reviews each hop before auth',
    () async {
      const bastionId = '11111111-1111-4111-8111-111111111111';
      const middleId = '22222222-2222-4222-8222-222222222222';
      final bastionCredential = await repository.createCredential(
        const CredentialRecord(
          id: '44444444-4444-4444-8444-444444444444',
          name: 'bastion credential',
          username: 'bastion-user',
          kind: AuthKind.password,
          secret: 'bastion-secret',
        ),
      );
      final middleCredential = await repository.createCredential(
        const CredentialRecord(
          id: '55555555-5555-4555-8555-555555555555',
          name: 'middle group default',
          username: 'middle-default-user',
          kind: AuthKind.password,
          secret: 'middle-secret',
        ),
      );
      await repository.createHost(
        HostRecord(
          id: bastionId,
          name: 'First bastion',
          address: 'bastion.local.test',
          port: 2201,
          username: 'fallback-bastion-user',
          credentialId: bastionCredential.id,
        ),
        recordId: bastionId,
      );
      await repository.createHost(
        HostRecord(
          id: middleId,
          name: 'Second bastion',
          address: 'middle.local.test',
          port: 2202,
          username: 'fallback-middle-user',
          credentialId: middleCredential.id,
          jumpHostId: bastionId,
        ),
        recordId: middleId,
      );

      final service = createService(
        fingerprintsByHost: {
          'bastion.local.test': _fingerprint,
          'middle.local.test': _changedFingerprint,
          host.address: _fingerprint,
        },
      );
      final controller = LocalProfileSshController(
        repository: repository,
        serviceForTesting: service.service,
      );
      final approvals = <LocalKnownHostApprovalRequest>[];
      final connection = await controller.connect(
        host: host.copyWith(jumpHostId: middleId),
        credential: credential,
        askApproval: (request) async {
          approvals.add(request);
          expect(
            service.authenticatedHosts,
            isNot(contains(request.host)),
            reason: 'the endpoint awaiting trust must not authenticate',
          );
          return true;
        },
      );
      addTearDown(connection.close);

      expect(approvals.map((request) => '${request.host}:${request.port}'), [
        'bastion.local.test:2201',
        'middle.local.test:2202',
        '${host.address}:${host.port}',
      ]);
      expect(service.authenticatedUsernames, [
        'bastion-user',
        'bastion-user',
        'middle-default-user',
        'bastion-user',
        'middle-default-user',
        'deploy',
      ]);
      expect(service.socketCount, 4);
      expect(service.forwardedTargets, [
        ('middle.local.test', 2202),
        ('middle.local.test', 2202),
        (host.address, host.port),
        ('middle.local.test', 2202),
        (host.address, host.port),
      ]);
      expect(await repository.listKnownHosts(), hasLength(3));
    },
  );

  test(
    'changed Jump Host key is rejected before user authentication',
    () async {
      const bastionId = '11111111-1111-4111-8111-111111111111';
      final jumpCredential = await repository.createCredential(
        const CredentialRecord(
          id: '44444444-4444-4444-8444-444444444444',
          name: 'bastion credential',
          username: 'bastion-user',
          kind: AuthKind.password,
          secret: 'bastion-secret',
        ),
      );
      await repository.createHost(
        HostRecord(
          id: bastionId,
          name: 'First bastion',
          address: 'bastion.local.test',
          port: 2201,
          username: 'fallback-bastion-user',
          credentialId: jumpCredential.id,
        ),
        recordId: bastionId,
      );
      await repository.approveKnownHost(
        host: 'bastion.local.test',
        port: 2201,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        explicitlyConfirmed: true,
      );

      final service = createService(
        fingerprintsByHost: {'bastion.local.test': _changedFingerprint},
      );
      final controller = LocalProfileSshController(
        repository: repository,
        serviceForTesting: service.service,
      );
      var approvalCount = 0;
      await expectLater(
        controller.connect(
          host: host.copyWith(jumpHostId: bastionId),
          credential: credential,
          askApproval: (_) async {
            approvalCount++;
            return true;
          },
        ),
        throwsA(
          isA<SshHostKeyVerificationException>().having(
            (error) => error.failure,
            'failure',
            SshHostKeyFailure.changed,
          ),
        ),
      );
      expect(approvalCount, 0);
      expect(service.userAuthenticationCount, 0);
      expect(service.socketCount, 1);
    },
  );

  test('missing Jump Host reference fails before opening a socket', () async {
    final service = createService();
    final controller = LocalProfileSshController(
      repository: repository,
      serviceForTesting: service.service,
    );

    await expectLater(
      controller.connect(
        host: host.copyWith(jumpHostId: '11111111-1111-4111-8111-111111111111'),
        credential: credential,
        askApproval: (_) async => true,
      ),
      throwsStateError,
    );
    expect(service.socketCount, 0);
  });

  test('LocalVault Jump Host uses its Group default Credential', () async {
    const groupId = '4b229e31-562e-40e4-b86a-52a69d0e8765';
    const bastionId = '11111111-1111-4111-8111-111111111111';
    const jumpCredentialId = 'cb83d190-3a88-47bf-97e8-6342cd788017';
    final jumpCredential = await repository.createCredential(
      const CredentialRecord(
        id: jumpCredentialId,
        name: 'group default bastion key',
        username: 'group-default-bastion',
        kind: AuthKind.password,
        secret: 'group-default-bastion-secret',
      ),
    );
    await repository.createGroup(
      GroupRecord(
        id: groupId,
        name: 'Jump credentials',
        defaultCredentialId: jumpCredential.id,
      ),
    );
    await repository.createHost(
      const HostRecord(
        id: bastionId,
        name: 'Inherited credential bastion',
        address: 'bastion.local.test',
        port: 2201,
        username: 'fallback-bastion-user',
        groupId: groupId,
      ),
      recordId: bastionId,
    );

    final service = createService(
      fingerprintsByHost: {
        'bastion.local.test': _fingerprint,
        host.address: _changedFingerprint,
      },
    );
    final controller = LocalProfileSshController(
      repository: repository,
      serviceForTesting: service.service,
    );
    final approvals = <LocalKnownHostApprovalRequest>[];
    final connection = await controller.connect(
      host: host.copyWith(jumpHostId: bastionId),
      credential: credential,
      askApproval: (request) async {
        approvals.add(request);
        return true;
      },
    );
    addTearDown(connection.close);

    expect(approvals.map((request) => request.port), [2201, host.port]);
    expect(service.authenticatedUsernames, [
      'group-default-bastion',
      'group-default-bastion',
      'deploy',
    ]);
    expect(service.socketCount, 3);
    expect(service.forwardedTargets, [
      (host.address, host.port),
      (host.address, host.port),
    ]);
  });
}

class _TestService {
  _TestService({
    required this.fingerprint,
    this.fingerprintsByHost = const {},
    required this.decisionLock,
  }) {
    service = SshService(
      api: null,
      deviceId: 'local-test-device',
      useRelay: false,
      knownHostDecisionLock: decisionLock,
      directSocketConnector: (host, _) async {
        socketCount++;
        return _FakeSocket(host);
      },
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            handshakeCount++;
            final session = _FakeSession();
            final endpointHost = (socket as _FakeSocket).host;
            final endpointFingerprint =
                fingerprintsByHost[endpointHost] ?? fingerprint;
            return _FakeClient(
              session: session,
              forward: (host, port) async {
                forwardedTargets.add((host, port));
                return _FakeSocket(host);
              },
              authenticate: () async {
                final accepted = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode(endpointFingerprint)),
                );
                if (!accepted) throw SSHAuthFailError('host key not accepted');
                userAuthenticationCount++;
                authenticatedUsernames.add(username);
                authenticatedHosts.add(endpointHost);
              },
            );
          },
    );
  }

  final String fingerprint;
  final Map<String, String> fingerprintsByHost;
  final KnownHostDecisionLock decisionLock;
  late final SshService service;
  int socketCount = 0;
  int handshakeCount = 0;
  int userAuthenticationCount = 0;
  final authenticatedUsernames = <String>[];
  final authenticatedHosts = <String>[];
  final forwardedTargets = <(String, int)>[];
}

class _FakeClient implements SSHClient {
  _FakeClient({
    required this.session,
    required this.forward,
    required Future<void> Function() authenticate,
  }) : _authenticated = authenticate();

  final SSHSession session;
  final Future<SSHForwardChannel> Function(String host, int port) forward;
  final Future<void> _authenticated;

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) => forward(remoteHost, remotePort);

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => session;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements SSHSession {
  @override
  Stream<Uint8List> get stdout => const Stream<Uint8List>.empty();

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void close() {}

  @override
  void write(Uint8List data) {}

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements SSHSocket, SSHForwardChannel {
  _FakeSocket(this.host);

  final String host;
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>().sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}
