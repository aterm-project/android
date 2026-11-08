import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _otherVaultId = '33333333-3333-4333-8333-333333333333';
const _fingerprintA = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _fingerprintB = 'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _feedGeneration = '77777777-7777-4777-8777-777777777777';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    _testSodium = sodium;
  });

  test(
    'same-Vault exact match, endpoint isolation and changed-key rejection',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, acceptPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      final otherVault = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
        vaultId: _otherVaultId,
      );

      try {
        expect(
          await repository.knownHostTrustStatus(
            host: 'SSH.Example.Test.',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.unknown,
        );
        final record = await repository.approveKnownHost(
          host: 'SSH.Example.Test.',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        );
        expect(record.host, 'ssh.example.test');
        expect(record.revisionId, isNotNull);
        expect(
          await repository.knownHostTrustStatus(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.unknown,
          reason: 'a local create remains untrusted until sync acknowledges it',
        );
        await repository.synchronize();
        expect(
          await repository.knownHostTrustStatus(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(
          await repository.knownHostTrustStatus(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-rsa',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.changed,
        );
        expect(
          await repository.knownHostTrustStatus(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintB,
          ),
          KnownHostTrustStatus.changed,
        );
        expect(await otherVault.loadKnownHosts(), isEmpty);
        expect(
          await otherVault.knownHostTrustStatus(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.unknown,
        );
        await expectLater(
          repository.approveKnownHost(
            host: 'ssh.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintB,
          ),
          throwsStateError,
        );
      } finally {
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('push receipt acknowledgement uses the shared Vault lock', () async {
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final key = sodium.randombytes.buf(32);
    final decisionLock = _BlockingKnownHostDecisionLock();
    final api = _KnownHostApi(
      identity: identity,
      acceptPush: true,
      onPush: () async => decisionLock.blockNext(),
    );
    final repository = _repository(
      api: api,
      database: database,
      identity: identity,
      key: key,
      knownHostDecisionLock: decisionLock,
    );

    try {
      final record = await repository.approveKnownHost(
        host: 'receipt-lock.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprintA,
      );

      final synchronizing = repository.synchronize();
      final stage = await Future.any<String>([
        decisionLock.blocked.then((_) => 'receipt acknowledgement locked'),
        synchronizing.then((_) => 'synchronization completed'),
      ]);
      expect(stage, 'receipt acknowledgement locked');
      expect(await database.allPendingOperations(_vaultId), hasLength(1));
      expect(
        (await database.cachedEnvelope(_vaultId, record.id))?.commitSeq,
        isNull,
        reason: 'the KnownHost projection must stay pending while lock is held',
      );

      decisionLock.release();
      await synchronizing;
      expect(await database.allPendingOperations(_vaultId), isEmpty);
      expect(
        (await database.cachedEnvelope(_vaultId, record.id))?.commitSeq,
        isNotNull,
      );
    } finally {
      decisionLock.release();
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test('KnownHost approval and revocation use the shared Vault lock', () async {
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final key = sodium.randombytes.buf(32);
    final api = _KnownHostApi(identity: identity, acceptPush: true);
    final decisionLock = _TrackingKnownHostDecisionLock();
    final repository = _repository(
      api: api,
      database: database,
      identity: identity,
      key: key,
      knownHostDecisionLock: decisionLock,
    );

    try {
      final approved = await repository.approveKnownHost(
        host: 'guarded.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprintA,
      );
      expect(
        decisionLock.scopes.single.lockName,
        const KnownHostDecisionScope(
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
        ).lockName,
      );
      expect(decisionLock.modes.single, KnownHostDecisionLockMode.exclusive);

      await repository.synchronize();
      final beforeRevoke = decisionLock.scopes.length;
      await repository.revokeKnownHost(recordId: approved.id);
      expect(decisionLock.scopes.length, beforeRevoke + 1);
      expect(
        decisionLock.scopes.last.lockName,
        const KnownHostDecisionScope(
          serverSpaceId: _serverSpaceId,
          vaultId: _vaultId,
        ).lockName,
      );
      expect(decisionLock.modes.last, KnownHostDecisionLockMode.exclusive);
    } finally {
      api.close();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'local concurrent approvals serialize and endpoint conflicts fail closed',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, acceptPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final approvals = await Future.wait([
          repository.approveKnownHost(
            host: 'parallel.example.test',
            port: 2200,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          repository.approveKnownHost(
            host: 'parallel.example.test',
            port: 2200,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
        ]);
        expect(approvals[0].id, approvals[1].id);
        expect(await repository.loadKnownHosts(), hasLength(1));
        expect(
          await repository.knownHostTrustStatus(
            host: 'parallel.example.test',
            port: 2200,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.unknown,
        );
        await repository.synchronize();
        expect(
          await repository.knownHostTrustStatus(
            host: 'parallel.example.test',
            port: 2200,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );

        final conflictRecords = <KnownHostRecord>[];
        for (final fingerprint in [_fingerprintA, _fingerprintB]) {
          final competing = KnownHostRecord.approve(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: fingerprint,
            approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
            approvedByDeviceId: identity.deviceId,
            approvedAt: DateTime.utc(2026, 9, 27),
          );
          await repository.saveRecord(
            recordId: competing.id,
            plaintext: competing.toJson(),
            operation: 'create',
          );
          conflictRecords.add(competing);
        }
        expect(
          await repository.knownHostTrustStatus(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.conflict,
        );
        await expectLater(
          repository.approveKnownHost(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          throwsStateError,
        );

        for (final record in conflictRecords) {
          final revoked = await repository.revokeKnownHost(recordId: record.id);
          expect(revoked.state, KnownHostState.revoked);
          expect(revoked.id, record.id);
        }
        for (final fingerprint in [_fingerprintA, _fingerprintB]) {
          expect(
            await repository.knownHostTrustStatus(
              host: 'conflict.example.test',
              port: 22,
              algorithm: 'ssh-ed25519',
              fingerprint: fingerprint,
            ),
            KnownHostTrustStatus.revoked,
          );
        }
        final explicitlyReapproved = await repository.approveKnownHost(
          host: 'conflict.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        );
        expect(
          conflictRecords.map((record) => record.id),
          isNot(contains(explicitlyReapproved.id)),
        );
        expect(
          await repository.knownHostTrustStatus(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.unknown,
        );
        await repository.synchronize();
        expect(
          await repository.knownHostTrustStatus(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(
          await repository.knownHostTrustStatus(
            host: 'conflict.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintB,
          ),
          KnownHostTrustStatus.changed,
        );
      } finally {
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'revocation is a revision and renewed trust has a new record ID',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final approved = await repository.approveKnownHost(
          host: 'rotate.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        );
        final revoked = await repository.revokeKnownHost(recordId: approved.id);
        expect(revoked.id, approved.id);
        expect(revoked.revisionId, isNot(approved.revisionId));
        expect(revoked.state, KnownHostState.revoked);
        expect(
          await repository.knownHostTrustStatus(
            host: 'rotate.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.revoked,
        );

        final renewed = await repository.approveKnownHost(
          host: 'rotate.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        );
        expect(renewed.id, isNot(approved.id));
        expect(renewed.schemaVersion, 2);
        expect(renewed.observedRevocations, [
          KnownHostRevocationReference(
            recordId: revoked.id,
            revisionId: revoked.revisionId!,
          ),
        ]);
        final records = await repository.loadKnownHosts();
        expect(records, hasLength(2));
        expect(
          records.map((record) => record.state),
          containsAll([KnownHostState.revoked, KnownHostState.trusted]),
        );
      } finally {
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'a stale independent approval cannot override a matching revocation',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );

      try {
        final original = await repository.approveKnownHost(
          host: 'stale-reapproval.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        );
        final revoked = await repository.revokeKnownHost(recordId: original.id);
        expect(revoked.state, KnownHostState.revoked);
        expect(revoked.revisionId, isNotNull);
        final staleApproval = KnownHostRecord.approve(
          host: 'stale-reapproval.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
          approvalSource: KnownHostApprovalSource.interactiveConfirmation,
          approvedByDeviceId: identity.deviceId,
          approvedAt: DateTime.utc(2026, 9, 27, 14),
        );
        await repository.saveRecord(
          recordId: staleApproval.id,
          plaintext: staleApproval.toJson(),
          operation: 'create',
        );

        expect(
          await repository.knownHostTrustStatus(
            host: 'stale-reapproval.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.revoked,
        );
        await expectLater(
          repository.approveKnownHost(
            host: 'stale-reapproval.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          throwsStateError,
        );

        final revisionPinRevocation = KnownHostRecord.fromJson({
          ...KnownHostRecord.approve(
                host: 'revision-pin.example.test',
                port: 22,
                algorithm: 'ssh-ed25519',
                fingerprint: _fingerprintA,
                approvalSource: KnownHostApprovalSource.interactiveConfirmation,
                approvedByDeviceId: identity.deviceId,
                approvedAt: DateTime.utc(2026, 9, 27, 13),
              )
              .revoke(
                revokedByDeviceId: identity.deviceId,
                revokedAt: DateTime.utc(2026, 9, 27, 14),
              )
              .toJson(),
          '_revision_id': '99999999-9999-4999-8999-999999999999',
        });
        final staleReferenceApproval = KnownHostRecord.approve(
          host: 'revision-pin.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
          approvalSource: KnownHostApprovalSource.interactiveConfirmation,
          approvedByDeviceId: identity.deviceId,
          approvedAt: DateTime.utc(2026, 9, 27, 14),
          observedRevocations: [
            KnownHostRevocationReference(
              recordId: revisionPinRevocation.id,
              revisionId: '88888888-8888-4888-8888-888888888888',
            ),
          ],
        );
        final staleRevision = KnownHostRecord.fromJson({
          ...staleReferenceApproval.toJson(),
          '_record_id': staleReferenceApproval.id,
          '_revision_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        });
        await repository.saveRecord(
          recordId: revisionPinRevocation.id,
          plaintext: revisionPinRevocation.toJson(),
          operation: 'create',
        );
        await repository.saveRecord(
          recordId: staleRevision.id,
          plaintext: staleRevision.toJson(),
          operation: 'create',
        );
        expect(
          await repository.knownHostTrustStatus(
            host: 'revision-pin.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.revoked,
        );
      } finally {
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('new device pulls a Vault-signed KnownHost record', () async {
    final identity = DeviceIdentity.create(sodium);
    final approver = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final key = sodium.randombytes.buf(32);
    final crypto = VaultCrypto(sodium);
    final knownHost = KnownHostRecord.approve(
      host: 'pulled.example.test',
      port: 2222,
      algorithm: 'ssh-ed25519',
      fingerprint: _fingerprintA,
      approvalSource: KnownHostApprovalSource.interactiveConfirmation,
      approvedByDeviceId: approver.deviceId,
      approvedAt: DateTime.utc(2026, 9, 27),
    );
    final envelope = await crypto.encryptRecord(
      vaultKey: Uint8List.fromList(key),
      serverSpaceId: _serverSpaceId,
      vaultId: _vaultId,
      recordId: knownHost.id,
      baseRevisionId: null,
      deviceId: approver.deviceId,
      deviceSequence: '1',
      keyEpoch: '1',
      membershipVersion: '1',
      operation: 'create',
      plaintext: knownHost.toJson(),
      identity: approver,
    );
    final api = _KnownHostApi(
      identity: identity,
      vaultMemberDevices: [approver],
      firstPageEnvelope: envelope,
    );
    final repository = _repository(
      api: api,
      database: database,
      identity: identity,
      key: key,
    );

    try {
      final result = await repository.synchronize();
      expect(result.receivedCount, 1);
      final pulled = await repository.loadKnownHosts();
      expect(pulled, hasLength(1));
      expect(pulled.single.id, knownHost.id);
      expect(pulled.single.revisionId, isNotNull);
      expect(
        await repository.knownHostTrustStatus(
          host: 'PULLED.EXAMPLE.TEST.',
          port: 2222,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        ),
        KnownHostTrustStatus.trusted,
      );
    } finally {
      api.close();
      identity.dispose();
      approver.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'controller pulls current Vault trust before deciding host-key status',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final approver = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      final knownHost = KnownHostRecord.approve(
        host: 'controller-pull.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprintA,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: approver.deviceId,
        approvedAt: DateTime.utc(2026, 9, 27),
      );
      final envelope = await crypto.encryptRecord(
        vaultKey: Uint8List.fromList(key),
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        recordId: knownHost.id,
        baseRevisionId: null,
        deviceId: approver.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: knownHost.toJson(),
        identity: approver,
      );
      final api = _KnownHostApi(
        identity: identity,
        vaultMemberDevices: [approver],
        firstPageEnvelope: envelope,
      );
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace;

      try {
        expect(
          await controller.knownHostTrustStatus(
            host: 'CONTROLLER-PULL.EXAMPLE.TEST.',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(controller.knownHosts.single.id, knownHost.id);

        // A failed read must never convert cached trust into a fresh
        // connection decision. Existing endpoint history requires an online
        // Vault view, even if the cached key currently matches.
        api.failSyncRead = true;
        await expectLater(
          controller.knownHostTrustStatus(
            host: 'CONTROLLER-PULL.EXAMPLE.TEST.',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          throwsStateError,
        );
        expect(api.pushCalls, 0);
      } finally {
        controller.dispose();
        approver.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'controller does not return a local-only host approval as trusted',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, failPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace;

      try {
        await expectLater(
          controller.approveKnownHost(
            host: 'pending-approval.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          throwsA(isA<ApiException>()),
        );

        final records = await repository.loadKnownHosts();
        expect(records, hasLength(1));
        expect(records.single.state, KnownHostState.trusted);
        expect(controller.knownHosts, isEmpty);
        final pending = await database.allPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, records.single.id);
        expect(api.pushCalls, 1);
      } finally {
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'offline first-seen approval queues encrypted and stops until sync confirms it',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(
        identity: identity,
        failSyncRead: true,
        acceptPush: true,
      );
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const host = HostRecord(
        id: 'offline-approval-host',
        name: 'Offline approval',
        address: 'offline-approval.example.test',
        username: 'fixture-user',
        credentialId: 'offline-approval-credential',
      );
      var connectorCalls = 0;
      var connectionVerified = false;
      final verificationResults = <bool>[];
      var promptWasOfflineQueueOnly = false;
      var approvalPromptCalls = 0;
      final controller =
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
                    connectorCalls++;
                    final accepted = await verifyHostKey(
                      'ssh-ed25519',
                      _fingerprintA,
                    );
                    verificationResults.add(accepted);
                    if (!accepted) {
                      throw StateError(
                        'The SSH host-key decision stopped this attempt.',
                      );
                    }
                    connectionVerified = true;
                    return _KnownHostTestConnection();
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..credentials.add(
              const CredentialRecord(
                id: 'offline-approval-credential',
                name: 'Offline approval fixture',
                username: 'fixture-user',
                secret: 'unused-test-secret',
              ),
            )
            ..askTrustHostApproval = (request) async {
              approvalPromptCalls++;
              promptWasOfflineQueueOnly = request.offlineTransportUnavailable;
              expect(request.host, host.address);
              expect(request.algorithm, 'ssh-ed25519');
              expect(request.fingerprint, _fingerprintA);
              return true;
            };
      AppController? recoveredController;
      SyncRepository? recoveredRepository;
      DeviceIdentity? recoveredIdentity;
      Map<String, dynamic>? restartIdentityStorage;
      Uint8List? restartKey;
      Uint8List? recoveredKey;
      var controllerDisposed = false;

      try {
        await expectLater(
          controller.openTerminalTab(host),
          throwsA(isA<KnownHostApprovalQueuedException>()),
        );
        expect(promptWasOfflineQueueOnly, isTrue);
        expect(connectorCalls, 1);
        expect(verificationResults, [false]);
        expect(connectionVerified, isFalse);
        expect(api.pushCalls, 0);
        await expectLater(controller.openTerminalTab(host), throwsStateError);
        expect(approvalPromptCalls, 1);
        expect(connectorCalls, 2);
        expect(verificationResults, [false, false]);
        expect(await database.allPendingOperations(_vaultId), hasLength(1));
        expect(api.pushCalls, 0);
        final pending = await database.allPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.baseRevisionId, isNull);
        expect(pending.single.envelopeJson, isNot(contains(host.address)));
        expect(pending.single.envelopeJson, isNot(contains(_fingerprintA)));
        expect(
          controller.pendingKnownHostRecordIds,
          contains(pending.single.recordId),
        );
        expect(controller.noticeMessage, contains('当前连接已停止'));

        // Model a process restart: controller disposal retires this repository,
        // disposes the device identity, and wipes its key buffers. Preserve
        // only the serialized identity and test key needed to restore them.
        restartIdentityStorage = Map<String, dynamic>.from(
          identity.toStorageJson(),
        );
        restartKey = Uint8List.fromList(key);
        controller.dispose();
        controllerDisposed = true;

        recoveredIdentity = DeviceIdentity.fromStorage(
          sodium,
          restartIdentityStorage!,
        );
        restartIdentityStorage!.clear();
        restartIdentityStorage = null;
        recoveredKey = Uint8List.fromList(restartKey!);
        restartKey!.fillRange(0, restartKey!.length, 0);
        restartKey = null;
        recoveredRepository = _repository(
          api: api,
          database: database,
          identity: recoveredIdentity!,
          key: recoveredKey!,
        );
        recoveredKey!.fillRange(0, recoveredKey!.length, 0);
        recoveredKey = null;

        api.failSyncRead = false;
        await recoveredRepository!.synchronize();
        expect(api.pushCalls, 1);
        expect(await database.allPendingOperations(_vaultId), isEmpty);

        recoveredController =
            AppController(
                sodium: sodium,
                database: database,
                secureStore: ClientSecureStore(),
                repositoryForTesting: recoveredRepository!,
                sshConnectorForTesting:
                    ({
                      required host,
                      required credential,
                      required verifyHostKey,
                    }) async {
                      connectorCalls++;
                      final accepted = await verifyHostKey(
                        'ssh-ed25519',
                        _fingerprintA,
                      );
                      verificationResults.add(accepted);
                      if (!accepted) {
                        throw StateError(
                          'The synced SSH host key was not trusted.',
                        );
                      }
                      connectionVerified = true;
                      return _KnownHostTestConnection();
                    },
              )
              ..identity = recoveredIdentity
              ..api = api
              ..activeVault = vault
              ..session = AuthSession(
                accountId: '55555555-5555-4555-8555-555555555555',
                accessToken: 'test-access-token',
                expiresIn: 900,
                refreshToken: 'test-refresh-token',
                deviceId: recoveredIdentity!.deviceId,
                vaults: const [vault],
              )
              ..stage = ClientStage.workspace
              ..credentials.add(
                const CredentialRecord(
                  id: 'offline-approval-credential',
                  name: 'Offline approval fixture',
                  username: 'fixture-user',
                  secret: 'unused-test-secret',
                ),
              );
        await recoveredController!.reloadRecords();
        expect(recoveredController!.pendingKnownHostRecordIds, isEmpty);
        recoveredController!.credentials.add(
          const CredentialRecord(
            id: 'offline-approval-credential',
            name: 'Offline approval fixture',
            username: 'fixture-user',
            secret: 'unused-test-secret',
          ),
        );
        await recoveredController!.openTerminalTab(host);
        expect(connectorCalls, 4);
        expect(verificationResults, [false, false, false, true]);
        expect(connectionVerified, isTrue);
      } finally {
        if (!controllerDisposed) controller.dispose();
        recoveredController?.dispose();
        if (recoveredController == null) {
          await recoveredRepository?.retireAndWaitForKeyOperations();
        }
        api.close();
        identity.dispose();
        recoveredIdentity?.dispose();
        key.fillRange(0, key.length, 0);
        restartIdentityStorage?.clear();
        restartKey?.fillRange(0, restartKey!.length, 0);
        recoveredKey?.fillRange(0, recoveredKey!.length, 0);
        await database.close();
      }
    },
  );

  test(
    'online recovery during first-seen confirmation completes verified SSH',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(
        identity: identity,
        failSyncRead: true,
        acceptPush: true,
      );
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const host = HostRecord(
        id: 'online-recovery-host',
        name: 'Online recovery',
        address: 'online-recovery.example.test',
        username: 'fixture-user',
        credentialId: 'online-recovery-credential',
      );
      var connectorCalls = 0;
      var connectionVerified = false;
      var promptWasInitiallyOffline = false;
      final verificationResults = <bool>[];
      final controller =
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
                    connectorCalls++;
                    final accepted = await verifyHostKey(
                      'ssh-ed25519',
                      _fingerprintA,
                    );
                    verificationResults.add(accepted);
                    if (!accepted) {
                      throw StateError(
                        'The SSH host-key decision stopped this attempt.',
                      );
                    }
                    connectionVerified = true;
                    return _KnownHostTestConnection();
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..credentials.add(
              const CredentialRecord(
                id: 'online-recovery-credential',
                name: 'Online recovery fixture',
                username: 'fixture-user',
                secret: 'unused-test-secret',
              ),
            )
            ..askTrustHostApproval = (request) async {
              promptWasInitiallyOffline = request.offlineTransportUnavailable;
              // The user may finish reading the explicit confirmation after
              // the changes feed has recovered.
              api.failSyncRead = false;
              return true;
            };

      try {
        await controller.openTerminalTab(host);
        expect(promptWasInitiallyOffline, isTrue);
        expect(connectorCalls, 2);
        expect(verificationResults, [false, true]);
        expect(connectionVerified, isTrue);
        expect(api.pushCalls, 1);
        expect(await database.allPendingOperations(_vaultId), isEmpty);
        expect(controller.pendingKnownHostRecordIds, isEmpty);
      } finally {
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'offline approval fails closed when the local encrypted cache is unavailable',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(
        identity: identity,
        failSyncRead: true,
        onSyncReadFailure: () async {
          await database.customStatement('DROP TABLE encrypted_records');
        },
      );
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const host = HostRecord(
        id: 'offline-storage-failure-host',
        name: 'Offline storage failure',
        address: 'offline-storage-failure.example.test',
        username: 'fixture-user',
        credentialId: 'offline-storage-failure-credential',
      );
      var connectorCalls = 0;
      var promptCalls = 0;
      final controller =
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
                    connectorCalls++;
                    await verifyHostKey('ssh-ed25519', _fingerprintA);
                    return _KnownHostTestConnection();
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..credentials.add(
              const CredentialRecord(
                id: 'offline-storage-failure-credential',
                name: 'Offline storage failure fixture',
                username: 'fixture-user',
                secret: 'unused-test-secret',
              ),
            )
            ..askTrustHostApproval = (_) async {
              promptCalls++;
              return true;
            };

      try {
        await expectLater(
          controller.openTerminalTab(host),
          throwsA(isNot(isA<SyncReadTransportUnavailableException>())),
        );
        expect(promptCalls, 0);
        expect(connectorCalls, 1);
        expect(api.pushCalls, 0);
        expect(await database.allPendingOperations(_vaultId), isEmpty);
      } finally {
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'host-key approval stops the pending handshake, syncs, then reconnects',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, acceptPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const host = HostRecord(
        id: 'approval-retry-host',
        name: 'Approval retry',
        address: 'approval-retry.example.test',
        username: 'fixture-user',
        credentialId: 'approval-retry-credential',
      );
      var connectorCalls = 0;
      var retryFingerprint = _fingerprintA;
      final verificationResults = <bool>[];
      final connections = <_KnownHostTestConnection>[];
      final controller =
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
                    connectorCalls++;
                    final trusted = await verifyHostKey(
                      'ssh-ed25519',
                      connectorCalls == 1 ? _fingerprintA : retryFingerprint,
                    );
                    verificationResults.add(trusted);
                    if (!trusted) {
                      throw StateError(
                        'The unapproved SSH handshake was stopped.',
                      );
                    }
                    final connection = _KnownHostTestConnection();
                    connections.add(connection);
                    return connection;
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..credentials.add(
              const CredentialRecord(
                id: 'approval-retry-credential',
                name: 'Approval retry fixture',
                username: 'fixture-user',
                secret: 'unused-test-secret',
              ),
            )
            ..askTrustHostApproval = (_) async => true;

      try {
        await controller.openTerminalTab(host);

        expect(connectorCalls, 2);
        expect(verificationResults, [false, true]);
        expect(api.pushCalls, 1);
        expect(
          controller.activeTerminalTab?.connection,
          same(connections.single),
        );
        expect(
          await repository.knownHostTrustStatus(
            host: host.address,
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(await database.allPendingOperations(_vaultId), isEmpty);

        // A second openTerminalTab call gets a fresh proof map and must stop
        // its handshake before the Vault pull. A different fingerprint at
        // this endpoint must not match the route-scoped proof for key A.
        await controller.disconnectAllTerminalTabs();
        controller.credentials.add(
          const CredentialRecord(
            id: 'approval-retry-credential',
            name: 'Approval retry fixture',
            username: 'fixture-user',
            secret: 'unused-test-secret',
          ),
        );
        connectorCalls = 0;
        retryFingerprint = _fingerprintB;
        verificationResults.clear();
        await expectLater(
          controller.openTerminalTab(host),
          throwsA(isA<SshHostKeyVerificationException>()),
        );
        expect(connectorCalls, 2);
        expect(verificationResults, [false, false]);
        expect(
          await repository.knownHostTrustStatus(
            host: host.address,
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(
          await repository.knownHostTrustStatus(
            host: host.address,
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintB,
          ),
          KnownHostTrustStatus.changed,
        );

        await controller.disconnectAllTerminalTabs();
        controller.credentials.add(
          const CredentialRecord(
            id: 'approval-retry-credential',
            name: 'Approval retry fixture',
            username: 'fixture-user',
            secret: 'unused-test-secret',
          ),
        );
        connectorCalls = 0;
        retryFingerprint = _fingerprintA;
        verificationResults.clear();
        await controller.openTerminalTab(host);
        expect(connectorCalls, 2);
        expect(verificationResults, [false, true]);
        expect(
          controller.activeTerminalTab?.connection,
          same(connections.last),
        );
        expect(api.pushCalls, 1);
        expect(await database.allPendingOperations(_vaultId), isEmpty);
      } finally {
        await controller.disconnectAllTerminalTabs();
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'local revocation invalidates a cached route proof before SSH authentication',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, acceptPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const host = HostRecord(
        id: 'revocation-race-host',
        name: 'Revocation race',
        address: 'revocation-race.example.test',
        username: 'fixture-user',
        credentialId: 'revocation-race-credential',
      );
      final retryEntered = Completer<void>();
      final releaseRetry = Completer<void>();
      final verificationResults = <bool>[];
      final approvals = <KnownHostApprovalRequest>[];
      var connectorCalls = 0;
      var authenticationAttempts = 0;
      final controller =
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
                    connectorCalls++;
                    if (connectorCalls == 2) {
                      retryEntered.complete();
                      await releaseRetry.future;
                    }
                    final trusted = await verifyHostKey(
                      'ssh-ed25519',
                      _fingerprintA,
                    );
                    verificationResults.add(trusted);
                    if (!trusted) {
                      throw StateError('The stale proof must stop SSH.');
                    }
                    authenticationAttempts++;
                    return _KnownHostTestConnection();
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..credentials.add(
              const CredentialRecord(
                id: 'revocation-race-credential',
                name: 'Revocation race fixture',
                username: 'fixture-user',
                secret: 'unused-test-secret',
              ),
            )
            ..askTrustHostApproval = (request) async {
              approvals.add(request);
              return !request.previouslyRevoked;
            };
      Future<void>? opening;

      try {
        opening = controller.openTerminalTab(host);
        await retryEntered.future.timeout(const Duration(seconds: 5));
        expect(controller.knownHosts, hasLength(1));
        await controller.revokeKnownHost(controller.knownHosts.single.id);
        expect(controller.knownHosts.single.state, KnownHostState.revoked);

        releaseRetry.complete();
        await expectLater(
          opening,
          throwsA(isA<SshHostKeyVerificationException>()),
        );

        expect(connectorCalls, 2);
        expect(verificationResults, [false, false]);
        expect(authenticationAttempts, 0);
        expect(approvals.map((request) => request.previouslyRevoked), [
          false,
          true,
        ]);
        expect(
          await repository.knownHostTrustStatus(
            host: host.address,
            port: host.port,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.revoked,
        );
      } finally {
        if (!releaseRetry.isCompleted) releaseRetry.complete();
        if (opening != null) {
          try {
            await opening.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        await controller.disconnectAllTerminalTabs();
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'multi-hop host-key proofs are reusable only within one route setup',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final api = _KnownHostApi(identity: identity, acceptPush: true);
      final repository = _repository(
        api: api,
        database: database,
        identity: identity,
        key: key,
      );
      const vault = VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      const bastion = HostRecord(
        id: 'proof-bastion',
        name: 'Proof bastion',
        address: 'proof-bastion.example.test',
        port: 2222,
        username: 'bastion-user',
        credentialId: 'proof-bastion-credential',
      );
      const target = HostRecord(
        id: 'proof-target',
        name: 'Proof target',
        address: 'proof-target.example.test',
        port: 2200,
        username: 'target-user',
        credentialId: 'proof-target-credential',
        jumpHostId: 'proof-bastion',
      );
      var connectorCalls = 0;
      final verificationResults = <String>[];
      final userAuthRoutes = <List<String>>[];
      final changesAtAttemptStart = <int>[];
      final approvalRequests = <KnownHostApprovalRequest>[];
      late final AppController controller;
      controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
              sshConnectorWithRouteForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                    required jumpHops,
                  }) async {
                    connectorCalls++;
                    changesAtAttemptStart.add(api.changesCalls);
                    final userAuthForAttempt = <String>[];
                    for (final hop in jumpHops) {
                      final trusted = await hop.verifyHostKey(
                        'ssh-ed25519',
                        _fingerprintA,
                      );
                      verificationResults.add('${hop.host.id}:$trusted');
                      if (!trusted) {
                        userAuthRoutes.add(userAuthForAttempt);
                        throw StateError(
                          'The reviewed Jump Host handshake must restart.',
                        );
                      }
                      // SshService authenticates each verified Jump Host
                      // before opening the next forwarded SSH transport.
                      userAuthForAttempt.add(hop.host.id);
                    }
                    if (connectorCalls == 2) {
                      // A concurrent same-Vault state refresh can advance
                      // the decision generation after one hop was approved.
                      // The route-local proof must be checked against the
                      // current exact KnownHost projection without restarting
                      // the whole SSH chain a second time.
                      controller.invalidateKnownHostDecisionProofsForTesting();
                    }
                    final targetTrusted = await verifyHostKey(
                      'ssh-ed25519',
                      _fingerprintB,
                    );
                    verificationResults.add('proof-target:$targetTrusted');
                    if (!targetTrusted) {
                      userAuthRoutes.add(userAuthForAttempt);
                      throw StateError(
                        'The reviewed Target handshake must restart.',
                      );
                    }
                    userAuthForAttempt.add(host.id);
                    userAuthRoutes.add(userAuthForAttempt);
                    return _KnownHostTestConnection();
                  },
            )
            ..identity = identity
            ..api = api
            ..activeVault = vault
            ..session = AuthSession(
              accountId: '55555555-5555-4555-8555-555555555555',
              accessToken: 'test-access-token',
              expiresIn: 900,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [vault],
            )
            ..stage = ClientStage.workspace
            ..hosts.add(bastion)
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'proof-bastion-credential',
                name: 'Proof bastion credential',
                username: 'bastion-user',
                secret: 'unused-bastion-secret',
              ),
              CredentialRecord(
                id: 'proof-target-credential',
                name: 'Proof target credential',
                username: 'target-user',
                secret: 'unused-target-secret',
              ),
            ])
            ..askTrustHostApproval = (request) async {
              approvalRequests.add(request);
              return true;
            };

      try {
        await controller.openTerminalTab(target);

        expect(connectorCalls, 3);
        expect(verificationResults, [
          'proof-bastion:false',
          'proof-bastion:true',
          'proof-target:false',
          'proof-bastion:true',
          'proof-target:true',
        ]);
        expect(approvalRequests.map((request) => request.host), [
          bastion.address,
          target.address,
        ]);
        expect(approvalRequests.map((request) => request.fingerprint), [
          _fingerprintA,
          _fingerprintB,
        ]);
        expect(userAuthRoutes, [
          <String>[],
          [bastion.id],
          [bastion.id, target.id],
        ]);
        expect(changesAtAttemptStart, hasLength(3));
        expect(
          changesAtAttemptStart.last,
          api.changesCalls,
          reason:
              'the final route retry must reuse both proofs without another Vault pull',
        );
        expect(controller.activeTerminalTab?.state, 'connected');
        expect(api.pushCalls, 2);
        expect(
          await repository.knownHostTrustStatus(
            host: bastion.address,
            port: bastion.port,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintA,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(
          await repository.knownHostTrustStatus(
            host: target.address,
            port: target.port,
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprintB,
          ),
          KnownHostTrustStatus.trusted,
        );
        expect(await database.allPendingOperations(_vaultId), isEmpty);

        // Proofs are local to one openTerminalTab route setup. A later tab
        // must preflight the already trusted Bastion and Target again before
        // SSH userauth, then may reuse those proofs only for its own retries.
        // This fake API only accepts the KnownHost writes and does not return
        // workspace records, so restore the test's host/credential projection
        // after the approval sync reloads that projection from the repository.
        controller
          ..hosts.addAll([bastion, target])
          ..credentials.addAll(const [
            CredentialRecord(
              id: 'proof-bastion-credential',
              name: 'Proof bastion credential',
              username: 'bastion-user',
              secret: 'unused-bastion-secret',
            ),
            CredentialRecord(
              id: 'proof-target-credential',
              name: 'Proof target credential',
              username: 'target-user',
              secret: 'unused-target-secret',
            ),
          ]);
        await controller.disconnectAllTerminalTabs();
        connectorCalls = 0;
        verificationResults.clear();
        userAuthRoutes.clear();
        changesAtAttemptStart.clear();
        final changesBeforeSecondTab = api.changesCalls;
        await controller.openTerminalTab(target);
        expect(connectorCalls, 3);
        expect(verificationResults, [
          'proof-bastion:false',
          'proof-bastion:true',
          'proof-target:false',
          'proof-bastion:true',
          'proof-target:true',
        ]);
        expect(userAuthRoutes, [
          <String>[],
          [bastion.id],
          [bastion.id, target.id],
        ]);
        expect(api.changesCalls, greaterThan(changesBeforeSecondTab));
        expect(
          api.pushCalls,
          2,
          reason: 'the second tab rechecks trust without repeating approvals',
        );
        expect(approvalRequests, hasLength(2));
      } finally {
        await controller.disconnectAllTerminalTabs();
        controller.dispose();
        api.close();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('signing directory duplicate identity keys fail closed', () async {
    final identity = DeviceIdentity.create(sodium);
    final otherIdentity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final key = sodium.randombytes.buf(32);
    final api = _KnownHostApi(
      identity: identity,
      additionalAccountDevices: [
        {
          'device_id': identity.deviceId,
          'signing_public_key': otherIdentity.signingPublicKey,
          'status': 'active',
        },
      ],
    );
    final repository = _repository(
      api: api,
      database: database,
      identity: identity,
      key: key,
    );

    try {
      await expectLater(
        repository.knownHostTrustStatus(
          host: 'directory.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: _fingerprintA,
        ),
        throwsFormatException,
      );
    } finally {
      api.close();
      identity.dispose();
      otherIdentity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });
}

SyncRepository _repository({
  required ApiClient api,
  required ClientDatabase database,
  required DeviceIdentity identity,
  required List<int> key,
  KnownHostDecisionLock? knownHostDecisionLock,
  String vaultId = _vaultId,
}) => SyncRepository(
  api: api,
  database: database,
  crypto: VaultCrypto(_testSodium),
  identity: identity,
  serverSpaceId: _serverSpaceId,
  instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  vaultId: vaultId,
  keyEpoch: '1',
  membershipVersion: '1',
  serverGeneration: _feedGeneration,
  vaultKey: Uint8List.fromList(key),
  knownHostDecisionLock: knownHostDecisionLock,
);

class _KnownHostTestConnection implements SshConnection {
  @override
  Stream<String> get output => const Stream<String>.empty();

  @override
  Future<void> close() async {}

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

late SodiumSumo _testSodium;

class _TrackingKnownHostDecisionLock implements KnownHostDecisionLock {
  final inner = createKnownHostDecisionLock();
  final scopes = <KnownHostDecisionScope>[];
  final modes = <KnownHostDecisionLockMode>[];

  @override
  Future<T> run<T>(
    KnownHostDecisionScope scope,
    Future<T> Function() action, {
    KnownHostDecisionLockMode mode = KnownHostDecisionLockMode.exclusive,
    Future<void>? cancel,
  }) {
    scopes.add(scope);
    modes.add(mode);
    return inner.run(scope, action, mode: mode, cancel: cancel);
  }
}

class _BlockingKnownHostDecisionLock implements KnownHostDecisionLock {
  final inner = createKnownHostDecisionLock();
  final Completer<void> _entered = Completer<void>();
  Completer<void>? _release;
  bool _blockNext = false;

  Future<void> get blocked => _entered.future;

  void blockNext() {
    _release = Completer<void>();
    _blockNext = true;
  }

  void release() {
    final release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<T> run<T>(
    KnownHostDecisionScope scope,
    Future<T> Function() action, {
    KnownHostDecisionLockMode mode = KnownHostDecisionLockMode.exclusive,
    Future<void>? cancel,
  }) async {
    if (_blockNext) {
      _blockNext = false;
      _entered.complete();
      await _release!.future;
    }
    return inner.run(scope, action, mode: mode, cancel: cancel);
  }
}

class _KnownHostApi extends ApiClient {
  _KnownHostApi({
    required this.identity,
    this.vaultMemberDevices = const [],
    this.additionalAccountDevices = const [],
    this.firstPageEnvelope,
    this.failPush = false,
    this.acceptPush = false,
    this.failSyncRead = false,
    this.onSyncReadFailure,
    this.onPush,
  }) : super(baseUrl: 'https://known-host-sync.test');

  final DeviceIdentity identity;
  final List<DeviceIdentity> vaultMemberDevices;
  final List<Map<String, dynamic>> additionalAccountDevices;
  final Map<String, Object?>? firstPageEnvelope;
  final bool failPush;
  final bool acceptPush;
  final Future<void> Function()? onSyncReadFailure;
  final Future<void> Function()? onPush;
  bool failSyncRead;
  int pushCalls = 0;
  int changesCalls = 0;
  bool _returnedEnvelope = false;

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushCalls++;
    await onPush?.call();
    if (failPush) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Vault sync is unavailable.',
      );
    }
    if (acceptPush) {
      final operations = (batch['operations'] as List).cast<Map>();
      return {
        'batch_id': batch['batch_id'],
        'results': [
          for (final operation in operations)
            {
              'op_id': (operation['header'] as Map)['op_id'],
              'revision_id': (operation['header'] as Map)['revision_id'],
              'commit_seq': '$pushCalls',
              'already_committed': false,
            },
        ],
      };
    }
    return super.push(vaultId, batch);
  }

  Map<String, dynamic> _directoryRow(DeviceIdentity device) => {
    'device_id': device.deviceId,
    'user_id': '55555555-5555-4555-8555-555555555555',
    'signing_public_key': device.signingPublicKey,
    'status': 'active',
  };

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    _directoryRow(identity),
    ...additionalAccountDevices,
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    _directoryRow(identity),
    ...vaultMemberDevices.map(_directoryRow),
  ];

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
    serverGeneration: serverGeneration ?? _feedGeneration,
  );

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    changesCalls++;
    if (failSyncRead) {
      await onSyncReadFailure?.call();
      throw const SyncReadTransportUnavailableException(
        path: '/api/v1/vaults/$_vaultId/changes',
      );
    }
    final envelope = firstPageEnvelope;
    if (envelope != null && !_returnedEnvelope) {
      _returnedEnvelope = true;
      return SyncPage(
        events: [
          {
            'commit_seq': '1',
            'event_type': (envelope['header']! as Map)['operation'],
            'record_id': (envelope['header']! as Map)['record_id'],
            'revision_id': (envelope['header']! as Map)['revision_id'],
            'envelope': envelope,
          },
        ],
        nextCursor: 'cursor-1',
        hasMore: false,
        serverGeneration: _feedGeneration,
      );
    }
    return const SyncPage(
      events: [],
      nextCursor: 'cursor-1',
      hasMore: false,
      serverGeneration: _feedGeneration,
    );
  }
}
