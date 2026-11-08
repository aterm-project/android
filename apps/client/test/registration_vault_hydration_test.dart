import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_hint_client.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _editorAccountId = '22222222-2222-4222-8222-222222222222';
const _pendingAccountId = '33333333-3333-4333-8333-333333333333';
const _migrationTargetRecordId = '44444444-4444-4444-8444-444444444444';
const _migrationTargetConflictId = '55555555-5555-4555-8555-555555555555';
const _membershipRefreshHostA = '66666666-6666-4666-8666-666666666666';
const _membershipRefreshHostB = '77777777-7777-4777-8777-777777777777';
const _membershipRefreshCredentialA = '88888888-8888-4888-8888-888888888888';
const _membershipRefreshCredentialB = '99999999-9999-4999-8999-999999999999';
const _membershipRefreshWorkspace = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _membershipRefreshPaneA = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _membershipRefreshPaneB = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _knownHostReplacementAccountId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _multiVaultPendingHostId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _multiVaultPendingConflictId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const _multiVaultSecondaryHostId = '10101010-1010-4010-8010-101010101010';
const _syncInstanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _syncServerSpaceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('signer directory cache is scoped and rejects retired writers', () {
    final cache = VerifiedSignerDirectoryCache();
    const accountScope = SignerDirectoryCacheScope(
      serverBaseUrl: 'https://signers-one.example.test',
      serverSpaceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      instanceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      accountId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      vaultId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    );
    const otherAccountScope = SignerDirectoryCacheScope(
      serverBaseUrl: 'https://signers-one.example.test',
      serverSpaceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      instanceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      accountId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      vaultId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    );
    final generation = cache.generation;
    final ticket = cache.beginRefresh(accountScope, generation: generation);
    final signingKey = Uint8List.fromList(List<int>.filled(32, 7));
    cache.publishRefresh(
      accountScope,
      generation: generation,
      ticket: ticket,
      signers: {'ffffffff-ffff-4fff-8fff-ffffffffffff': signingKey},
    );

    expect(
      cache.read(accountScope, generation: generation),
      contains('ffffffff-ffff-4fff-8fff-ffffffffffff'),
    );
    expect(cache.read(otherAccountScope, generation: generation), isNull);

    final olderTicket = cache.beginRefresh(
      accountScope,
      generation: generation,
    );
    final newerTicket = cache.beginRefresh(
      accountScope,
      generation: generation,
    );
    cache.publishRefresh(
      accountScope,
      generation: generation,
      ticket: newerTicket,
      signers: {
        'ffffffff-ffff-4fff-8fff-ffffffffffff': Uint8List.fromList(
          List<int>.filled(32, 8),
        ),
      },
    );
    cache.publishRefresh(
      accountScope,
      generation: generation,
      ticket: olderTicket,
      signers: {
        'ffffffff-ffff-4fff-8fff-ffffffffffff': Uint8List.fromList(
          List<int>.filled(32, 9),
        ),
      },
    );
    expect(
      cache
          .read(
            accountScope,
            generation: generation,
          )!['ffffffff-ffff-4fff-8fff-ffffffffffff']!
          .first,
      8,
      reason: 'an older refresh must not overwrite a newer committed roster',
    );

    final hydrationTicket = cache.beginRefresh(
      accountScope,
      generation: generation,
    );
    final laterRefreshTicket = cache.beginRefresh(
      accountScope,
      generation: generation,
    );
    cache.publishRefresh(
      accountScope,
      generation: generation,
      ticket: laterRefreshTicket,
      signers: {
        'ffffffff-ffff-4fff-8fff-ffffffffffff': Uint8List.fromList(
          List<int>.filled(32, 10),
        ),
      },
    );
    cache.publishHydrated(
      accountScope,
      generation: generation,
      ticket: hydrationTicket,
      signers: {
        'ffffffff-ffff-4fff-8fff-ffffffffffff': Uint8List.fromList(
          List<int>.filled(32, 11),
        ),
      },
    );
    expect(
      cache
          .read(
            accountScope,
            generation: generation,
          )!['ffffffff-ffff-4fff-8fff-ffffffffffff']!
          .first,
      10,
      reason:
          'a refresh started after hydration must win if hydration finishes last',
    );

    cache.invalidate();
    cache.publishRefresh(
      accountScope,
      generation: generation,
      ticket: olderTicket,
      signers: {'ffffffff-ffff-4fff-8fff-ffffffffffff': signingKey},
    );
    expect(cache.read(accountScope, generation: cache.generation), isNull);
  });

  test(
    'membership refresh keeps live pane bindings for the same Vault workspace',
    () async {
      late AppController app;
      var refreshDuringFirstHandshake = true;
      var connectorCalls = 0;
      final harness = await _createRegisteredSyncHarness(
        sodium,
        sshConnectorForTesting:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              connectorCalls++;
              if (refreshDuringFirstHandshake) {
                refreshDuringFirstHandshake = false;
                await app.reloadVaultsForTesting();
              }
              final trusted = await verifyHostKey(
                'ssh-ed25519',
                'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              );
              if (!trusted) {
                throw StateError('The SSH test handshake needs a retry.');
              }
              return _MembershipRefreshSshConnection();
            },
        knownHostTrustStatusForTesting:
            ({
              required host,
              required port,
              required algorithm,
              required fingerprint,
            }) async => KnownHostTrustStatus.trusted,
      );
      app = harness.app;

      try {
        for (final credential in const [
          CredentialRecord(
            id: _membershipRefreshCredentialA,
            name: 'Refresh A',
            username: 'workspace-user',
            secret: 'test-password-a',
          ),
          CredentialRecord(
            id: _membershipRefreshCredentialB,
            name: 'Refresh B',
            username: 'workspace-user',
            secret: 'test-password-b',
          ),
        ]) {
          await app.saveCredential(credential);
        }
        await app.saveHost(
          const HostRecord(
            id: _membershipRefreshHostA,
            name: 'Refresh Host A',
            address: 'refresh-a.example.test',
            username: 'workspace-user',
            credentialId: _membershipRefreshCredentialA,
          ),
        );
        await app.saveHost(
          const HostRecord(
            id: _membershipRefreshHostB,
            name: 'Refresh Host B',
            address: 'refresh-b.example.test',
            username: 'workspace-user',
            credentialId: _membershipRefreshCredentialB,
          ),
        );
        await app.saveSplitWorkspace(
          name: 'Refresh must retain pane runtime',
          hostIds: const [_membershipRefreshHostA, _membershipRefreshHostB],
          axis: WorkspaceSplitAxis.horizontal,
          activeIndex: 0,
        );
        final workspace = app.savedWorkspaces.single;
        final firstPane = workspace.panes.first;
        app.stageWorkspace(workspace.id);

        await app.connectWorkspacePane(workspace.id, firstPane.paneId);

        final paneTab = app.workspacePaneTerminalTab(
          workspace.id,
          firstPane.paneId,
        );
        expect(app.activeSavedWorkspaceId, workspace.id);
        expect(paneTab, isNotNull);
        expect(paneTab!.host?.id, _membershipRefreshHostA);
        expect(paneTab.state, 'connected');
        expect(connectorCalls, 2, reason: 'the known-host proof retries SSH');
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'known-host approval revalidates after repository refresh and rejects pending trust',
    () async {
      Future<void> runScenario({required bool writableAfterRefresh}) async {
        var now = DateTime.utc(2026, 10, 1);
        var connectorCalls = 0;
        var authenticationAttempts = 0;
        final changesEntered = Completer<void>();
        final releaseChanges = Completer<void>();
        final harness = await _createRegisteredSyncHarness(
          sodium,
          nowForTesting: () => now,
          sshConnectorForTesting:
              ({
                required host,
                required credential,
                required verifyHostKey,
              }) async {
                connectorCalls++;
                final trusted = await verifyHostKey(
                  'ssh-ed25519',
                  'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                );
                if (!trusted) {
                  throw StateError('The untrusted SSH attempt must stop.');
                }
                authenticationAttempts++;
                return _MembershipRefreshSshConnection();
              },
        );
        final app = harness.app;
        final api = harness.api;
        app.credentials.add(
          const CredentialRecord(
            id: 'approval-refresh-credential',
            name: 'Approval refresh credential',
            username: 'approval-user',
            secret: 'test-password',
          ),
        );
        const host = HostRecord(
          id: 'approval-refresh-host',
          name: 'Approval refresh host',
          address: 'approval-refresh.example.test',
          username: 'approval-user',
          credentialId: 'approval-refresh-credential',
        );
        Future<void>? terminalOpen;
        var pushesBeforeApproval = 0;
        var vaultReadsBeforeRefresh = 0;

        try {
          app.hosts.add(host);

          app.askTrustHostApproval = (request) async {
            expect(request.host, host.address);
            pushesBeforeApproval = api.pushCalls;
            vaultReadsBeforeRefresh = api.vaultListReads;
            // Hold the approval's pre-write pull at +44s. Its completion at
            // +46s must trigger the due account/Vault refresh in the final
            // confirmation pull, after the KnownHost operation is queued.
            now = now.add(const Duration(seconds: 44));
            api
              ..nextChangesEntered = changesEntered
              ..nextChangesRelease = releaseChanges;
            return true;
          };
          terminalOpen = app.openTerminalTab(host);
          await changesEntered.future.timeout(const Duration(seconds: 5));
          now = now.add(const Duration(seconds: 2));
          if (!writableAfterRefresh) api.serverCanWrite = false;
          releaseChanges.complete();
          if (writableAfterRefresh) {
            await terminalOpen.timeout(const Duration(seconds: 15));
          } else {
            await expectLater(terminalOpen, throwsA(isA<StateError>()));
          }

          final pending = await harness.database.allPendingOperations(
            api.vaultId,
          );
          expect(api.vaultListReads, vaultReadsBeforeRefresh + 1);
          if (writableAfterRefresh) {
            expect(app.activeTerminalTab?.state, 'connected');
            expect(connectorCalls, 2);
            expect(authenticationAttempts, 1);
            expect(api.pushCalls, pushesBeforeApproval + 1);
            expect(app.knownHosts, hasLength(1));
            final approvalId = app.knownHosts.single.id;
            expect(app.knownHosts.single.host, host.address);
            final pushedApprovalOperations = api.pushedOperations.where((
              operation,
            ) {
              final header = operation['header'] as Map;
              return header['record_id'] == approvalId;
            });
            expect(pushedApprovalOperations, hasLength(1));
            expect(
              pending.where((operation) => operation.recordId == approvalId),
              isEmpty,
            );
            expect(
              (await harness.database.cachedEnvelope(
                api.vaultId,
                approvalId,
              ))?.commitSeq,
              isNotNull,
              reason:
                  'the exact approved KnownHost has a server commit receipt',
            );
          } else {
            expect(app.activeTerminalTab?.state, 'failed');
            expect(connectorCalls, 1);
            expect(authenticationAttempts, 0);
            expect(api.pushCalls, pushesBeforeApproval);
            expect(app.activeVault?.canWrite, isFalse);
            expect(app.syncStatus, 'read_only');
            expect(pending, hasLength(1));
            expect(
              await app.knownHostTrustStatus(
                host: host.address,
                port: host.port,
                algorithm: 'ssh-ed25519',
                fingerprint:
                    'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              ),
              KnownHostTrustStatus.unknown,
              reason: 'a local pending approval cannot authorize a retry',
            );
          }
        } finally {
          if (!releaseChanges.isCompleted) releaseChanges.complete();
          if (terminalOpen != null) {
            try {
              await terminalOpen.timeout(const Duration(seconds: 5));
            } catch (_) {}
          }
          app.dispose();
          await harness.database.close();
        }
      }

      await runScenario(writableAfterRefresh: true);
      await runScenario(writableAfterRefresh: false);
    },
  );

  test(
    'multi-hop trust revalidates a stale route proof after Vault reload',
    () async {
      Future<void> runScenario({
        required KnownHostTrustStatus refreshedBastionStatus,
        required bool expectConnected,
      }) async {
        late AppController app;
        var bastionStatus = KnownHostTrustStatus.unknown;
        var targetStatus = KnownHostTrustStatus.unknown;
        var refreshDuringTargetApproval = false;
        var connectorCalls = 0;
        final verificationResults = <String>[];
        final userAuthRoutes = <List<String>>[];
        final approvals = <KnownHostApprovalRequest>[];
        const bastion = HostRecord(
          id: 'reload-proof-bastion',
          name: 'Reload proof bastion',
          address: 'reload-proof-bastion.example.test',
          port: 2222,
          username: 'bastion-user',
          credentialId: 'reload-proof-bastion-credential',
        );
        const target = HostRecord(
          id: 'reload-proof-target',
          name: 'Reload proof target',
          address: 'reload-proof-target.example.test',
          port: 2200,
          username: 'target-user',
          credentialId: 'reload-proof-target-credential',
          jumpHostId: 'reload-proof-bastion',
        );
        final harness = await _createRegisteredSyncHarness(
          sodium,
          sshConnectorWithRouteForTesting:
              ({
                required host,
                required credential,
                required verifyHostKey,
                required jumpHops,
              }) async {
                connectorCalls++;
                final userAuthForAttempt = <String>[];
                final jump = jumpHops.single;
                final jumpTrusted = await jump.verifyHostKey(
                  'ssh-ed25519',
                  'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                );
                verificationResults.add('bastion:$jumpTrusted');
                if (!jumpTrusted) {
                  userAuthRoutes.add(userAuthForAttempt);
                  throw StateError('The unverified bastion attempt must stop.');
                }
                userAuthForAttempt.add(jump.host.id);
                final targetTrusted = await verifyHostKey(
                  'ssh-ed25519',
                  'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                );
                verificationResults.add('target:$targetTrusted');
                if (!targetTrusted) {
                  userAuthRoutes.add(userAuthForAttempt);
                  throw StateError('The unverified target attempt must stop.');
                }
                userAuthForAttempt.add(host.id);
                userAuthRoutes.add(userAuthForAttempt);
                return _MembershipRefreshSshConnection();
              },
          knownHostTrustStatusForTesting:
              ({
                required host,
                required port,
                required algorithm,
                required fingerprint,
              }) async {
                if (host == bastion.address) return bastionStatus;
                if (host == target.address) return targetStatus;
                return KnownHostTrustStatus.unknown;
              },
        );
        app = harness.app
          ..askTrustHostApproval = (request) async {
            approvals.add(request);
            if (request.host == bastion.address && request.previouslyRevoked) {
              return false;
            }
            if (request.host == bastion.address) {
              bastionStatus = KnownHostTrustStatus.trusted;
              return true;
            }
            if (request.host == target.address) {
              if (!refreshDuringTargetApproval) {
                refreshDuringTargetApproval = true;
                await app.reloadVaultsForTesting();
                bastionStatus = refreshedBastionStatus;
                targetStatus = KnownHostTrustStatus.trusted;
              }
              return true;
            }
            return false;
          }
          ..credentials.addAll(const [
            CredentialRecord(
              id: 'reload-proof-bastion-credential',
              name: 'Reload proof bastion credential',
              username: 'bastion-user',
              secret: 'test-bastion-password',
            ),
            CredentialRecord(
              id: 'reload-proof-target-credential',
              name: 'Reload proof target credential',
              username: 'target-user',
              secret: 'test-target-password',
            ),
          ])
          ..hosts.add(bastion)
          ..hosts.add(target);

        try {
          if (expectConnected) {
            await app.openTerminalTab(target);
            expect(app.activeTerminalTab?.state, 'connected');
            expect(connectorCalls, 4);
            expect(verificationResults, [
              'bastion:false',
              'bastion:true',
              'target:false',
              'bastion:false',
              'bastion:true',
              'target:true',
            ]);
            expect(userAuthRoutes, [
              <String>[],
              [bastion.id],
              <String>[],
              [bastion.id, target.id],
            ]);
            expect(approvals.map((request) => request.host), [
              bastion.address,
              target.address,
            ]);

            // A later tab must perform a new trust preflight; route proofs
            // from the refreshed setup are not retained on the controller.
            await app.disconnectAllTerminalTabs();
            app
              ..credentials.addAll(const [
                CredentialRecord(
                  id: 'reload-proof-bastion-credential',
                  name: 'Reload proof bastion credential',
                  username: 'bastion-user',
                  secret: 'test-bastion-password',
                ),
                CredentialRecord(
                  id: 'reload-proof-target-credential',
                  name: 'Reload proof target credential',
                  username: 'target-user',
                  secret: 'test-target-password',
                ),
              ])
              ..hosts.addAll([bastion, target]);
            connectorCalls = 0;
            verificationResults.clear();
            await app.openTerminalTab(target);
            expect(app.activeTerminalTab?.state, 'connected');
            expect(verificationResults.take(3), [
              'bastion:false',
              'bastion:true',
              'target:false',
            ]);
          } else {
            await expectLater(
              app.openTerminalTab(target),
              throwsA(isA<SshHostKeyVerificationException>()),
            );
            expect(app.activeTerminalTab?.state, 'failed');
            expect(connectorCalls, 3);
            expect(verificationResults, [
              'bastion:false',
              'bastion:true',
              'target:false',
              'bastion:false',
            ]);
            if (refreshedBastionStatus == KnownHostTrustStatus.revoked) {
              expect(approvals.last.host, bastion.address);
              expect(approvals.last.previouslyRevoked, isTrue);
            } else {
              expect(approvals.map((request) => request.host), [
                bastion.address,
                target.address,
              ]);
            }
          }
          expect(refreshDuringTargetApproval, isTrue);
          expect(
            userAuthRoutes.every(
              (route) => route.isEmpty || route.first == bastion.id,
            ),
            isTrue,
          );
        } finally {
          await app.disconnectAllTerminalTabs();
          app.dispose();
          await harness.database.close();
        }
      }

      await runScenario(
        refreshedBastionStatus: KnownHostTrustStatus.trusted,
        expectConnected: true,
      );
      await runScenario(
        refreshedBastionStatus: KnownHostTrustStatus.changed,
        expectConnected: false,
      );
      await runScenario(
        refreshedBastionStatus: KnownHostTrustStatus.revoked,
        expectConnected: false,
      );
    },
  );

  test(
    'Vault selection keeps records, stale reads, outbox and conflicts scoped',
    () async {
      final recordsByVault = <String, List<Map<String, dynamic>>>{};
      String? vaultA;
      var holdNextARead = false;
      var heldARead = false;
      final aReadEntered = Completer<void>();
      final releaseARead = Completer<void>();
      Map<String, dynamic> hostRow(String id, String name, String address) => {
        ...HostRecord(
          id: id,
          name: name,
          address: address,
          username: 'workspace-user',
        ).toJson(),
        '_record_id': id,
        '_revision_id': 'revision-$id',
      };
      final harness = await _createRegisteredSyncHarness(
        sodium,
        loadRecordsForTesting: (repository) async {
          if (holdNextARead && !heldARead && repository.vaultId == vaultA) {
            heldARead = true;
            aReadEntered.complete();
            await releaseARead.future;
          }
          return (recordsByVault[repository.vaultId] ??
                  const <Map<String, dynamic>>[])
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false);
        },
      );
      final app = harness.app;
      final api = harness.api;
      final database = harness.database;
      vaultA = app.currentVaultId;
      final vaultBExpected = HostRecord(
        id: '12121212-1212-4212-8212-121212121212',
        name: 'Vault B only host',
        address: 'vault-b.example.test',
        username: 'workspace-user',
      );
      recordsByVault[vaultA!] = [
        hostRow(
          '11111111-1111-4111-8111-111111111111',
          'Vault A only host',
          'vault-a.example.test',
        ),
      ];
      try {
        await app.reloadRecords();
        expect(app.hosts.map((host) => host.name), ['Vault A only host']);

        await app.createVault('Second isolated Vault');
        final vaultB = app.currentVaultId;
        expect(vaultB, isNot(vaultA));
        recordsByVault[vaultB] = [
          hostRow(
            vaultBExpected.id,
            vaultBExpected.name,
            vaultBExpected.address,
          ),
        ];
        await app.reloadRecords();
        expect(app.hosts.map((host) => host.name), ['Vault B only host']);

        await app.selectVault(vaultA!);
        expect(app.currentVaultId, vaultA);
        expect(app.hosts.map((host) => host.name), ['Vault A only host']);
        await app.selectVault(vaultB);
        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), ['Vault B only host']);
        await app.selectVault(vaultA!);
        expect(app.hosts.map((host) => host.name), ['Vault A only host']);

        await app.selectVault(vaultB);
        holdNextARead = true;
        final staleASelection = app.selectVault(vaultA!);
        await aReadEntered.future.timeout(const Duration(seconds: 5));
        await app.selectVault(vaultB);
        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), ['Vault B only host']);
        releaseARead.complete();
        await staleASelection;
        expect(app.currentVaultId, vaultB);
        expect(
          app.hosts.map((host) => host.name),
          ['Vault B only host'],
          reason:
              'a delayed read from A must not replace the active B projection',
        );
        holdNextARead = false;

        api.failPushVaultIds.add(vaultA!);
        await app.selectVault(vaultA!);
        await app.saveHost(
          const HostRecord(
            id: _multiVaultPendingHostId,
            name: 'Pending only in A',
            address: 'pending-a.example.test',
            username: 'workspace-user',
          ),
        );
        await _waitForSyncIdle(app);
        await database.saveConflict(
          conflictId: _multiVaultPendingConflictId,
          vaultId: vaultA!,
          recordId: _multiVaultPendingHostId,
          kind: 'concurrent_update',
          branchEnvelope: const {'record_id': _multiVaultPendingHostId},
          remoteEnvelope: const {'record_id': _multiVaultPendingHostId},
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        await app.refreshSyncStatus();
        expect(app.pendingCount, 1);
        expect(app.unresolvedConflictCount, 1);
        expect(
          await database.openConflicts(
            vaultA!,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          hasLength(1),
        );

        await app.selectVault(vaultB);
        expect(app.pendingCount, 0);
        expect(app.unresolvedConflictCount, 0);
        expect(
          await database.openConflicts(
            vaultB,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          isEmpty,
        );
        await app.saveHost(
          const HostRecord(
            id: _multiVaultSecondaryHostId,
            name: 'Created only in B',
            address: 'created-b.example.test',
            username: 'workspace-user',
          ),
        );
        await app.synchronize();
        await _waitForSyncIdle(app);
        final bPushes = api.pushRequestSummaries.where(
          (entry) => entry['routeVaultId'] == vaultB,
        );
        expect(bPushes, isNotEmpty);
        expect(
          bPushes.every(
            (entry) =>
                entry['bodyVaultId'] == vaultB &&
                !(entry['recordIds'] as List).contains(
                  _multiVaultPendingHostId,
                ),
          ),
          isTrue,
          reason: 'A outbox operations must never be sent through B',
        );
        expect(
          await database.openConflicts(
            vaultA!,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          hasLength(1),
        );

        api.failPushVaultIds.remove(vaultA!);
        await app.selectVault(vaultA!);
        await app.synchronize();
        await _waitForSyncIdle(app);
        expect(
          api.pushRequestSummaries.any(
            (entry) =>
                entry['routeVaultId'] == vaultA &&
                entry['bodyVaultId'] == vaultA &&
                (entry['recordIds'] as List).contains(_multiVaultPendingHostId),
          ),
          isTrue,
          reason: 'A pending operation must resume only after selecting A',
        );
        expect(
          await database.openConflicts(
            vaultA!,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          hasLength(1),
        );
      } finally {
        if (!releaseARead.isCompleted) releaseARead.complete();
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'previously visited Vault decrypts its cached records after offline switch',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      final database = harness.database;
      final vaultA = app.currentVaultId;
      const hostA = HostRecord(
        id: '21212121-2121-4121-8121-212121212121',
        name: 'Vault A cached host',
        address: 'vault-a-cached.example.test',
        username: 'workspace-user',
      );
      const hostB = HostRecord(
        id: '23232323-2323-4323-8323-232323232323',
        name: 'Vault B cached host',
        address: 'vault-b-cached.example.test',
        username: 'workspace-user',
      );
      try {
        await app.saveHost(hostA);
        await app.synchronize();
        await _waitForSyncIdle(app);

        await app.createVault('Offline cached Vault B');
        final vaultB = app.currentVaultId;
        expect(vaultB, isNot(vaultA));
        await app.saveHost(hostB);
        await app.synchronize();
        await _waitForSyncIdle(app);
        expect(
          (await database.cachedEnvelopes(
            vaultB,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          )).map((row) => row.recordId),
          contains(hostB.id),
          reason: 'the B fixture must be an actual encrypted local row',
        );
        await app.selectVault(vaultA);
        expect(app.hosts.map((host) => host.name), [hostA.name]);
        api.failSignerDirectoryReads = true;

        await app.selectVault(vaultB).timeout(const Duration(seconds: 5));

        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), [hostB.name]);
        expect(app.credentials, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'Vault switch releases B sync while retired A sync drains without stale UI writes',
    () async {
      final recordsByVault = <String, List<Map<String, dynamic>>>{};
      final harness = await _createRegisteredSyncHarness(
        sodium,
        loadRecordsForTesting: (repository) async =>
            (recordsByVault[repository.vaultId] ??
                    const <Map<String, dynamic>>[])
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false),
      );
      final app = harness.app;
      final api = harness.api;
      final database = harness.database;
      final vaultA = app.currentVaultId;
      Completer<void>? pendingRelease;
      Future<void>? pendingSync;
      try {
        recordsByVault[vaultA] = [
          {
            ...const HostRecord(
              id: '11111111-1111-4111-8111-111111111111',
              name: 'A projection',
              address: 'a.example.test',
              username: 'workspace-user',
            ).toJson(),
            '_record_id': '11111111-1111-4111-8111-111111111111',
            '_revision_id': 'revision-a',
          },
        ];
        await app.reloadRecords();
        await app.createVault('B while A syncs');
        final vaultB = app.currentVaultId;
        recordsByVault[vaultB] = [
          {
            ...const HostRecord(
              id: '22222222-2222-4222-8222-222222222222',
              name: 'B projection',
              address: 'b.example.test',
              username: 'workspace-user',
            ).toJson(),
            '_record_id': '22222222-2222-4222-8222-222222222222',
            '_revision_id': 'revision-b',
          },
        ];
        await app.reloadRecords();
        await app.selectVault(vaultA);
        await _waitForSyncIdle(app);

        final aEntered = Completer<void>();
        final releaseA = Completer<void>();
        pendingRelease = releaseA;
        api
          ..nextChangesVaultId = vaultA
          ..nextChangesEntered = aEntered
          ..nextChangesRelease = releaseA;
        final aSync = app.synchronize(background: true);
        pendingSync = aSync;
        await aEntered.future.timeout(const Duration(seconds: 5));

        await app.selectVault(vaultB).timeout(const Duration(seconds: 5));
        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), ['B projection']);
        await app
            .synchronize(background: true)
            .timeout(const Duration(seconds: 5));
        expect(api.requestedChangeVaultIds, contains(vaultB));

        api.failHeldChangesAfterRelease = const ApiException(
          statusCode: 503,
          code: 'TEMPORARY_FAILURE',
          message: 'synthetic delayed A failure',
        );
        releaseA.complete();
        await aSync.timeout(const Duration(seconds: 5));
        pendingRelease = null;
        pendingSync = null;
        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), ['B projection']);
        expect(app.syncStatus, 'idle');
        expect(app.errorMessage, isNull);
      } finally {
        final release = pendingRelease;
        if (release != null && !release.isCompleted) release.complete();
        try {
          await pendingSync;
        } catch (_) {}
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'same Vault reselection and logout wait for retired repository drains',
    () async {
      final recordsByVault = <String, List<Map<String, dynamic>>>{};
      final harness = await _createRegisteredSyncHarness(
        sodium,
        loadRecordsForTesting: (repository) async =>
            (recordsByVault[repository.vaultId] ??
                    const <Map<String, dynamic>>[])
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false),
      );
      final app = harness.app;
      final api = harness.api;
      final database = harness.database;
      final vaultA = app.currentVaultId;
      Completer<void>? pendingRelease;
      Future<void>? pendingSync;
      Future<void>? pendingSelection;
      Future<void>? pendingCleanup;
      try {
        recordsByVault[vaultA] = [
          {
            ...const HostRecord(
              id: '33333333-3333-4333-8333-333333333333',
              name: 'A projection',
              address: 'a.example.test',
              username: 'workspace-user',
            ).toJson(),
            '_record_id': '33333333-3333-4333-8333-333333333333',
            '_revision_id': 'revision-a',
          },
        ];
        await app.reloadRecords();
        await app.createVault('B for drain fence');
        final vaultB = app.currentVaultId;
        recordsByVault[vaultB] = [
          {
            ...const HostRecord(
              id: '44444444-4444-4444-8444-444444444444',
              name: 'B projection',
              address: 'b.example.test',
              username: 'workspace-user',
            ).toJson(),
            '_record_id': '44444444-4444-4444-8444-444444444444',
            '_revision_id': 'revision-b',
          },
        ];
        await app.reloadRecords();
        await app.selectVault(vaultA);
        await _waitForSyncIdle(app);

        final aEntered = Completer<void>();
        final releaseA = Completer<void>();
        pendingRelease = releaseA;
        api
          ..nextChangesVaultId = vaultA
          ..nextChangesEntered = aEntered
          ..nextChangesRelease = releaseA;
        final oldASync = app.synchronize(background: true);
        pendingSync = oldASync;
        await aEntered.future.timeout(const Duration(seconds: 5));
        await app.selectVault(vaultB).timeout(const Duration(seconds: 5));

        var reselectCompleted = false;
        final reselectA = app.selectVault(vaultA).then((_) {
          reselectCompleted = true;
        });
        pendingSelection = reselectA;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(reselectCompleted, isFalse);
        expect(app.currentVaultId, vaultB);
        expect(app.hosts.map((host) => host.name), ['B projection']);

        releaseA.complete();
        await Future.wait([
          oldASync,
          reselectA,
        ]).timeout(const Duration(seconds: 5));
        pendingRelease = null;
        pendingSync = null;
        pendingSelection = null;
        expect(reselectCompleted, isTrue);
        expect(app.currentVaultId, vaultA);
        expect(app.hosts.map((host) => host.name), ['A projection']);

        final cleanupEntered = Completer<void>();
        final releaseCleanup = Completer<void>();
        pendingRelease = releaseCleanup;
        api
          ..nextChangesVaultId = vaultA
          ..nextChangesEntered = cleanupEntered
          ..nextChangesRelease = releaseCleanup;
        final cleanupSync = app.synchronize(background: true);
        pendingSync = cleanupSync;
        await cleanupEntered.future.timeout(const Duration(seconds: 5));
        await app.selectVault(vaultB).timeout(const Duration(seconds: 5));

        var logoutCompleted = false;
        final logout = app.logout().then((_) {
          logoutCompleted = true;
        });
        pendingCleanup = logout;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(logoutCompleted, isFalse);
        expect(app.identity, isNotNull);

        releaseCleanup.complete();
        await Future.wait([
          cleanupSync,
          logout,
        ]).timeout(const Duration(seconds: 5));
        pendingRelease = null;
        pendingSync = null;
        expect(logoutCompleted, isTrue);
        expect(app.identity, isNull);
      } finally {
        final release = pendingRelease;
        if (release != null && !release.isCompleted) release.complete();
        try {
          await pendingSync;
        } catch (_) {}
        try {
          await pendingSelection;
        } catch (_) {}
        try {
          await pendingCleanup;
        } catch (_) {}
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'membership reload wipes replaced Vault key buffers after repository drain',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final database = harness.database;
      final vaultId = app.currentVaultId;
      final previousKey = app.vaultKeyForTesting(vaultId)!;
      try {
        expect(previousKey.any((byte) => byte != 0), isTrue);

        await app.reloadVaultsForTesting().timeout(const Duration(seconds: 10));

        final currentKey = app.vaultKeyForTesting(vaultId)!;
        expect(identical(previousKey, currentKey), isFalse);
        expect(
          previousKey.any((byte) => byte != 0),
          isFalse,
          reason:
              'the replaced key buffer should be zeroized after its repo drains',
        );
        expect(currentKey.any((byte) => byte != 0), isTrue);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'same-base API replacement drains a committed Vault load before swapping',
    () async {
      final secureStore = _MemorySecureStore();
      final harness = await _createRegisteredSyncHarness(
        sodium,
        secureStoreForTesting: secureStore,
      );
      final app = harness.app;
      final database = harness.database;
      final oldApi = harness.api;
      final vaultId = app.currentVaultId;
      final originalKey = app.vaultKeyForTesting(vaultId)!;
      final preferenceEntered = Completer<void>();
      final releasePreference = Completer<void>();
      secureStore
        ..terminalHistorySyncReadEntered = preferenceEntered
        ..terminalHistorySyncReadRelease = releasePreference;

      Future<void>? reload;
      Future<void>? activation;
      var activationCompleted = false;
      final replacementApi = ApiClient(baseUrl: oldApi.baseUrl);
      const replacementInfo = InstanceInfo(
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        protocolVersion: 1,
        setupRequired: true,
        capabilities: ['ciphertext_sync', 'snapshots'],
      );
      try {
        reload = app.reloadVaultsForTesting();
        await preferenceEntered.future.timeout(const Duration(seconds: 5));
        final committedKey = app.vaultKeyForTesting(vaultId)!;
        expect(identical(originalKey, committedKey), isFalse);
        expect(app.repositoryForTesting?.api, same(oldApi));
        expect(app.activeVault?.id, vaultId);

        activation = app
            .activateConfiguredServerForTesting(replacementApi, replacementInfo)
            .then((_) => activationCompleted = true);
        await Future<void>.delayed(Duration.zero);
        expect(activationCompleted, isFalse);
        expect(app.api, same(oldApi));
        expect(app.activeVault?.id, vaultId);

        releasePreference.complete();
        await Future.wait([
          reload,
          activation,
        ]).timeout(const Duration(seconds: 10));

        expect(app.api, same(replacementApi));
        expect(app.api?.baseUrl, oldApi.baseUrl);
        expect(app.session, isNull);
        expect(app.identity, isNull);
        expect(app.activeVault, isNull);
        expect(app.currentVaultId, isEmpty);
        expect(app.vaults, isEmpty);
        expect(app.repositoryForTesting, isNull);
        expect(app.vaultKeyForTesting(vaultId), isNull);
        expect(originalKey.every((byte) => byte == 0), isTrue);
        expect(committedKey.every((byte) => byte == 0), isTrue);
      } finally {
        if (!releasePreference.isCompleted) releasePreference.complete();
        for (final pending in [reload, activation]) {
          if (pending == null) continue;
          try {
            await pending.timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'failed post-publish recovery restore detaches the candidate API',
    () async {
      final secureStore = _MemorySecureStore()..failPendingRecoveryLoad = true;
      final harness = await _createRegisteredSyncHarness(
        sodium,
        secureStoreForTesting: secureStore,
      );
      final app = harness.app;
      final database = harness.database;
      final candidate = ApiClient(baseUrl: harness.api.baseUrl);
      try {
        await expectLater(
          app.activateConfiguredServerForTesting(
            candidate,
            const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: false,
              capabilities: ['ciphertext_sync', 'snapshots'],
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(app.api, isNull);
        expect(app.instance, isNull);
        expect(app.stage, ClientStage.server);
        expect(app.session, isNull);
        expect(app.identity, isNull);
        expect(app.activeVault, isNull);
        expect(app.repositoryForTesting, isNull);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'stale pending recovery read cannot install state after server replacement',
    () async {
      final secureStore = _MemorySecureStore();
      final harness = await _createRegisteredSyncHarness(
        sodium,
        secureStoreForTesting: secureStore,
      );
      final app = harness.app;
      final database = harness.database;
      final oldApi = harness.api;
      final oldInstance = app.instance!;
      final accountId = app.session!.accountId;
      final recoveryDevice = DeviceIdentity.create(sodium);
      final pendingRecovery = PendingAccountRecoveryStorageData(
        request: {
          'account_id': accountId,
          'instance_id': oldInstance.instanceId,
          'server_space_id': oldInstance.serverSpaceId,
          'recovery_generation': 1,
          'challenge_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          'challenge': encodeBase64Url(Uint8List(32)),
          'recovery_signature': encodeBase64Url(Uint8List(64)),
          'operation_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          'device': recoveryDevice.registrationProof(
            sodium,
            accountId: accountId,
            name: 'Pending recovery device',
          ),
          'next_recovery': {
            'recovery_public_signing_key': 'test-signing-key',
            'recovery_public_encryption_key': 'test-encryption-key',
            'recovery_envelope': <String, dynamic>{},
            'recovery_identity_envelope': <String, dynamic>{},
            'key_envelopes': <dynamic>[],
            'recovery_identity_proof_signature': 'test-signature',
          },
        },
        device: Map<String, dynamic>.from(recoveryDevice.toStorageJson()),
        challengeExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 5),
        ),
        completionAttempted: true,
      );
      recoveryDevice.dispose();

      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      secureStore
        ..pendingRecoveryByBaseUrl[oldApi.baseUrl] = pendingRecovery
        ..blockedPendingRecoveryBaseUrl = oldApi.baseUrl
        ..pendingRecoveryReadEntered = readEntered
        ..pendingRecoveryReadRelease = releaseRead;
      Future<void>? restore;
      Future<void>? activation;
      final replacementApi = ApiClient(baseUrl: 'https://registration-b.test');
      const replacementInfo = InstanceInfo(
        instanceId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        serverSpaceId: '11111111-1111-4111-8111-111111111112',
        generation: '2',
        protocolVersion: 1,
        setupRequired: false,
        capabilities: ['ciphertext_sync', 'snapshots'],
      );
      try {
        await app.logout();
        restore = app.restorePendingFullAccountRecovery();
        await readEntered.future.timeout(const Duration(seconds: 5));
        expect(app.hasPreparedFullAccountRecovery, isFalse);

        activation = app.activateConfiguredServerForTesting(
          replacementApi,
          replacementInfo,
        );
        await activation.timeout(const Duration(seconds: 10));
        expect(app.api, same(replacementApi));
        expect(app.instance, same(replacementInfo));
        expect(app.stage, ClientStage.login);
        expect(app.hasPreparedFullAccountRecovery, isFalse);

        releaseRead.complete();
        await restore.timeout(const Duration(seconds: 10));

        expect(app.api, same(replacementApi));
        expect(app.instance, same(replacementInfo));
        expect(app.stage, ClientStage.login);
        expect(app.session, isNull);
        expect(app.identity, isNull);
        expect(app.hasPreparedFullAccountRecovery, isFalse);
      } finally {
        if (!releaseRead.isCompleted) releaseRead.complete();
        for (final pending in [restore, activation]) {
          if (pending == null) continue;
          try {
            await pending.timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
        secureStore.pendingRecoveryByBaseUrl.clear();
        app.dispose();
        await database.close();
      }
    },
  );

  test('logout fences an in-flight staged Vault key load', () async {
    final harness = await _createRegisteredSyncHarness(sodium);
    final app = harness.app;
    final api = harness.api;
    final database = harness.database;
    final vaultId = app.currentVaultId;
    final previousKey = app.vaultKeyForTesting(vaultId)!;
    final vaultsEntered = Completer<void>();
    final releaseVaults = Completer<void>();
    api
      ..nextVaultsEntered = vaultsEntered
      ..nextVaultsRelease = releaseVaults;
    Future<void>? refresh;
    Future<void>? logout;
    try {
      refresh = app.reloadVaultsForTesting();
      await vaultsEntered.future.timeout(const Duration(seconds: 5));
      logout = app.logout();

      releaseVaults.complete();
      await Future.wait([refresh, logout]).timeout(const Duration(seconds: 10));

      expect(app.identity, isNull);
      expect(app.vaultKeyForTesting(vaultId), isNull);
      expect(previousKey.every((byte) => byte == 0), isTrue);
    } finally {
      if (!releaseVaults.isCompleted) releaseVaults.complete();
      for (final pending in [refresh, logout]) {
        if (pending == null) continue;
        try {
          await pending.timeout(const Duration(seconds: 10));
        } catch (_) {}
      }
      app.dispose();
      await database.close();
    }
  });

  test('dispose fences an in-flight staged Vault key load', () async {
    final harness = await _createRegisteredSyncHarness(sodium);
    final app = harness.app;
    final api = harness.api;
    final database = harness.database;
    final vaultId = app.currentVaultId;
    final previousKey = app.vaultKeyForTesting(vaultId)!;
    final vaultsEntered = Completer<void>();
    final releaseVaults = Completer<void>();
    api
      ..nextVaultsEntered = vaultsEntered
      ..nextVaultsRelease = releaseVaults;
    Future<void>? refresh;
    var disposed = false;
    try {
      refresh = app.reloadVaultsForTesting();
      await vaultsEntered.future.timeout(const Duration(seconds: 5));

      app.dispose();
      disposed = true;
      releaseVaults.complete();
      await refresh.timeout(const Duration(seconds: 10));
      await _waitForCondition(
        () => previousKey.every((byte) => byte == 0),
        reason: 'dispose did not wipe the retired key after the load ended',
      );
    } finally {
      if (!releaseVaults.isCompleted) releaseVaults.complete();
      try {
        await refresh?.timeout(const Duration(seconds: 10));
      } catch (_) {}
      if (!disposed) app.dispose();
      await database.close();
    }
  });

  test(
    'a later malformed envelope cannot publish or retain earlier keys',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      final database = harness.database;
      final vaultId = app.currentVaultId;
      final previousKey = app.vaultKeyForTesting(vaultId)!;
      final validEnvelope = Map<String, dynamic>.from(
        api.deviceEnvelopes[api.currentDeviceId]!.single,
      );
      final malformedEnvelope = Map<String, dynamic>.from(validEnvelope)
        ..['signer_device_id'] = 'unknown-signing-device';
      api.deviceEnvelopes[api.currentDeviceId] = [
        validEnvelope,
        malformedEnvelope,
      ];
      try {
        await expectLater(
          app.reloadVaultsForTesting(),
          throwsA(isA<FormatException>()),
        );

        expect(app.identity, isNull);
        expect(app.vaultKeyForTesting(vaultId), isNull);
        expect(previousKey.every((byte) => byte == 0), isTrue);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'registration hydrates canonical key envelope before approving a device',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _MemorySecureStore();
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );

        expect(api.registeredResponseVaults, hasLength(1));
        expect(api.registeredResponseVaults.single.keyEnvelopes, isEmpty);
        expect(
          api.membershipManifest['display_name_envelope'],
          api.nameEnvelope,
        );
        expect(app.vaults, hasLength(1));
        expect(app.vaults.single.keyEnvelopes, hasLength(1));
        expect(
          app.vaults.single.keyEnvelopes.single['recipient_device_id'],
          app.identity!.deviceId,
        );
        expect(
          app.vaults.single.encryptedDisplayNameEnvelope,
          api.nameEnvelope,
        );

        final enrollment = await app.createDeviceEnrollmentRequest(
          username: 'owner@example.test',
          name: 'Second browser',
        );
        final enrollmentJson = jsonDecode(enrollment) as Map<String, dynamic>;
        final targetDevice = Map<String, dynamic>.from(
          enrollmentJson['device'] as Map,
        );
        final approval = await app.approveDeviceEnrollment(enrollment);
        expect(jsonDecode(approval), isA<Map<String, dynamic>>());
        expect(api.registeredDeviceBody, isNotNull);
        expect(api.registeredDeviceBody!['vault_key_envelopes'], hasLength(1));
        final transferred = Map<String, dynamic>.from(
          (api.registeredDeviceBody!['vault_key_envelopes'] as List).single
              as Map,
        );
        expect(transferred['recipient_device_id'], targetDevice['device_id']);
        expect(transferred['key_epoch'], 1);
        expect(transferred['membership_version'], 1);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'known-host approval follows a same-scope repository replacement during its pre-write pull',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const host = 'same-scope-replacement.example.test';
      const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final changesEntered = Completer<void>();
      final releaseChanges = Completer<void>();
      final vaultsEntered = Completer<void>();
      final releaseVaults = Completer<void>();
      api
        ..nextChangesEntered = changesEntered
        ..nextChangesRelease = releaseChanges
        ..nextVaultsEntered = vaultsEntered
        ..nextVaultsRelease = releaseVaults;
      final initialVaultListReads = api.vaultListReads;
      final initialPushCalls = api.pushCalls;
      Future<KnownHostRecord>? approval;
      Future<void>? replacement;

      try {
        approval = app.approveKnownHost(
          host: host,
          port: 2222,
          algorithm: 'ssh-ed25519',
          fingerprint: fingerprint,
          approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
        );
        await changesEntered.future.timeout(const Duration(seconds: 5));

        // Start a signed roster refresh while the approval's first (pre-write)
        // pull is in flight. It must wait for that pull, then replace the
        // Repository under the same account, device and Vault scope.
        replacement = app.reloadVaultsForTesting();
        await _waitForCondition(
          () => app.membershipRefreshActiveForTesting,
          reason: 'same-scope repository refresh did not publish its guard',
        );
        releaseChanges.complete();
        await vaultsEntered.future.timeout(const Duration(seconds: 5));
        expect(api.vaultListReads, initialVaultListReads + 1);
        expect(app.membershipRefreshActiveForTesting, isTrue);
        releaseVaults.complete();

        await replacement.timeout(const Duration(seconds: 10));
        final approved = await approval.timeout(const Duration(seconds: 15));
        expect(app.currentVaultId, api.vaultId);
        expect(app.session?.accountId, api.accountId);
        expect(app.session?.deviceId, api.deviceId);
        expect(approved.host, host);
        expect(approved.port, 2222);
        expect(approved.algorithm, 'ssh-ed25519');
        expect(approved.fingerprint, fingerprint);
        expect(
          approved.approvalSource,
          KnownHostApprovalSource.outOfBandFingerprint,
        );

        final matchingPushes = api.pushedOperations.where((operation) {
          final header = operation['header'] as Map;
          return header['record_id'] == approved.id;
        }).toList();
        expect(matchingPushes, hasLength(1));
        final pushedEnvelope = matchingPushes.single;
        final pushedHeader = pushedEnvelope['header'] as Map;
        expect(pushedHeader['operation'], 'create');
        expect(pushedHeader['vault_id'], api.vaultId);
        expect(pushedEnvelope['ciphertext'], isA<String>());
        final serializedEnvelope = jsonEncode(pushedEnvelope);
        expect(serializedEnvelope, isNot(contains(host)));
        expect(serializedEnvelope, isNot(contains(fingerprint)));
        expect(api.pushCalls, greaterThan(initialPushCalls));
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).where((operation) => operation.recordId == approved.id),
          isEmpty,
        );
        expect(
          (await harness.database.cachedEnvelope(
            api.vaultId,
            approved.id,
          ))?.commitSeq,
          isNotNull,
          reason: 'the exact encrypted approval must have a server receipt',
        );
        expect(
          await app.knownHostTrustStatus(
            host: host,
            port: 2222,
            algorithm: 'ssh-ed25519',
            fingerprint: fingerprint,
          ),
          KnownHostTrustStatus.trusted,
        );
      } finally {
        if (!releaseChanges.isCompleted) releaseChanges.complete();
        if (!releaseVaults.isCompleted) releaseVaults.complete();
        for (final pending in [replacement, approval]) {
          if (pending == null) continue;
          try {
            await pending.timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'known-host approval fails closed when its pre-write refresh changes account scope',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const host = 'cross-scope-replacement.example.test';
      const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final changesEntered = Completer<void>();
      final releaseChanges = Completer<void>();
      final vaultsEntered = Completer<void>();
      final releaseVaults = Completer<void>();
      api
        ..nextChangesEntered = changesEntered
        ..nextChangesRelease = releaseChanges
        ..nextVaultsEntered = vaultsEntered
        ..nextVaultsRelease = releaseVaults;
      final initialPushCalls = api.pushCalls;
      Future<KnownHostRecord>? approval;
      Future<void>? replacement;

      try {
        approval = app.approveKnownHost(
          host: host,
          port: 2223,
          algorithm: 'ssh-ed25519',
          fingerprint: fingerprint,
          approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
        );
        await changesEntered.future.timeout(const Duration(seconds: 5));

        replacement = app.reloadVaultsForTesting();
        await _waitForCondition(
          () => app.membershipRefreshActiveForTesting,
          reason: 'cross-scope repository refresh did not publish its guard',
        );
        releaseChanges.complete();
        await vaultsEntered.future.timeout(const Duration(seconds: 5));

        // Keep the device and Vault identifiers, but simulate the authenticated
        // account changing while the roster refresh constructs its replacement
        // Repository. The original approval scope must no longer be usable.
        final oldSession = app.session!;
        app.session = AuthSession(
          accountId: _knownHostReplacementAccountId,
          accessToken: oldSession.accessToken,
          expiresIn: oldSession.expiresIn,
          refreshToken: oldSession.refreshToken,
          deviceId: oldSession.deviceId,
          vaults: oldSession.vaults,
        );
        releaseVaults.complete();

        await replacement.timeout(const Duration(seconds: 10));
        await expectLater(
          approval.timeout(const Duration(seconds: 15)),
          throwsA(isA<StateError>()),
        );
        expect(app.session?.accountId, _knownHostReplacementAccountId);
        expect(app.currentVaultId, api.vaultId);
        expect(api.pushCalls, initialPushCalls);
        expect(api.pushedOperations, isEmpty);
        expect(
          await harness.database.allPendingOperations(api.vaultId),
          isEmpty,
          reason: 'a stale-scope approval must never be persisted or pushed',
        );
        expect(app.knownHosts, isEmpty);
      } finally {
        if (!releaseChanges.isCompleted) releaseChanges.complete();
        if (!releaseVaults.isCompleted) releaseVaults.complete();
        for (final pending in [replacement, approval]) {
          if (pending == null) continue;
          try {
            await pending.timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'accepting a Vault invitation waits for an in-flight membership refresh',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _MemorySecureStore(),
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      final acceptEntered = Completer<void>();
      final acceptRelease = Completer<void>();
      final refreshEntered = Completer<void>();
      final refreshRelease = Completer<void>();
      Future<void>? acceptance;
      Future<void>? refresh;
      Future<void>? deferredHint;
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );
        await _waitForSyncIdle(app);

        api.acceptInvitationEntered = acceptEntered;
        api.acceptInvitationRelease = acceptRelease;
        final initialVaultReads = api.vaultListReads;
        acceptance = app.acceptVaultInvitation('synthetic-invitation-token');
        await acceptEntered.future.timeout(const Duration(seconds: 5));

        // Hold a membership-hint reload after it has published the active
        // guard. The invitation can be accepted while that verified refresh
        // is rebuilding the local descriptors and repository.
        api.nextVaultsEntered = refreshEntered;
        api.nextVaultsRelease = refreshRelease;
        refresh = app.reloadVaultsForTesting();
        await refreshEntered.future.timeout(const Duration(seconds: 5));
        expect(app.membershipRefreshActiveForTesting, isTrue);

        final vaultReadsBeforeHint = api.vaultListReads;
        final membershipReadsBeforeHint = api.membershipReads;
        deferredHint = app.handleSyncHintForTesting(
          SyncHint(vaultId: api.vaultId, membershipChanged: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(api.vaultListReads, vaultReadsBeforeHint);
        expect(api.membershipReads, membershipReadsBeforeHint);

        acceptRelease.complete();
        await _waitForCondition(
          () => api.vaultListReads >= initialVaultReads + 2,
          reason: 'invitation reload did not reach its Vault descriptor read',
        );
        expect(app.membershipRefreshActiveForTesting, isTrue);

        final acceptanceOutcome = acceptance.then<bool>(
          (_) => true,
          onError: (Object _) => false,
        );
        final earlyResult = await Future.any<bool?>([
          acceptanceOutcome,
          Future<void>.delayed(
            const Duration(milliseconds: 50),
          ).then((_) => null),
        ]);
        expect(
          earlyResult,
          isNull,
          reason: 'invitation selection should wait for membership refresh',
        );

        refreshRelease.complete();
        await expectLater(refresh, completes);
        await expectLater(acceptance, completes);
        await expectLater(deferredHint, completes);
        await _waitForSyncIdle(app);
        expect(app.currentVaultId, api.vaultId);
        expect(app.activeVault?.id, api.vaultId);
      } finally {
        if (!acceptRelease.isCompleted) acceptRelease.complete();
        if (!refreshRelease.isCompleted) refreshRelease.complete();
        for (final pending in [refresh, acceptance, deferredHint]) {
          if (pending == null) continue;
          try {
            await pending.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'migration target sync is not blocked by unrelated pending work or conflicts',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _MemorySecureStore();
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );
        await _waitForSyncIdle(app);

        final target = await app.prepareMigrationVaultCreation(
          'Migration target',
        );
        await app.createOrResumeMigrationVault(
          vaultId: target.vaultId,
          payloadJson: target.payloadJson,
        );
        final unrelatedEnvelope = await app.encryptMigrationRecord(
          targetVaultId: target.vaultId,
          recordId: _migrationTargetRecordId,
          plaintext: {
            'id': _migrationTargetRecordId,
            'type': 'snippet',
            'body': 'unrelated pending work',
          },
        );
        await database.putExactCreateOperation(
          vaultId: target.vaultId,
          deviceId: app.identity!.deviceId,
          envelope: unrelatedEnvelope,
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        await database.saveConflict(
          conflictId: _migrationTargetConflictId,
          vaultId: target.vaultId,
          recordId: _migrationTargetRecordId,
          kind: 'unrelated',
          branchEnvelope: const {'record_id': _migrationTargetRecordId},
          remoteEnvelope: const {'record_id': _migrationTargetRecordId},
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        api.failNextPush = true;

        await expectLater(
          app.synchronizeMigrationTarget(target.vaultId),
          completes,
        );
        expect(app.pendingCount, 1);
        expect(app.unresolvedConflictCount, 1);

        await app.synchronize();
        expect(app.pendingCount, 0);
        final committed = (await database.cachedEnvelopes(
          target.vaultId,
        )).singleWhere((row) => row.recordId == _migrationTargetRecordId);
        expect(committed.commitSeq, isNotNull);

        // A stale cached receipt cannot finish migration when the next pull
        // requires a snapshot rebuild instead of verifying current server state.
        api.expireNextChanges = true;
        await expectLater(
          app.synchronizeMigrationTarget(target.vaultId),
          throwsA(isA<StateError>()),
        );
        expect(app.syncStatus, 'resnapshot_required');
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'delayed device approval accepts later signed key rotation envelopes',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _MemorySecureStore();
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );
        await _waitForSyncIdle(app);

        final enrollmentJson = await app.createDeviceEnrollmentRequest(
          username: 'owner@example.test',
          name: 'Delayed browser',
        );
        final enrollment = jsonDecode(enrollmentJson) as Map<String, dynamic>;
        final target = Map<String, dynamic>.from(enrollment['device'] as Map);
        final approval = await app.approveDeviceEnrollment(enrollmentJson);
        expect(api.registeredDeviceBody?['vault_key_envelopes'], hasLength(1));

        final nextKey = Uint8List.fromList(
          List<int>.generate(32, (index) => index + 1),
        );
        final nextNameEnvelope = await app.crypto.encryptVaultName(
          vaultId: api.vaultId,
          vaultKey: nextKey,
          name: 'Operations',
        );
        final nextManifest = <String, Object?>{
          ...api.membershipManifest,
          'key_epoch': 2,
          'display_name_envelope': nextNameEnvelope,
        };
        final previousPayload = <String, Object?>{
          'vault_id': api.vaultId,
          'membership_version': 1,
          'previous_digest': null,
          'manifest': api.membershipManifest,
        };
        final digestBytes = await cryptography.Sha256().hash(
          utf8.encode(canonicalJson(previousPayload)),
        );
        final previousDigest = digestBytes.bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        final nextMembership = app.crypto.createMembershipGrant(
          vaultId: api.vaultId,
          membershipVersion: 2,
          previousDigest: previousDigest,
          manifest: nextManifest,
          signer: app.identity!,
        );
        final nextKeyEnvelope = app.crypto.createDeviceKeyEnvelope(
          vaultId: api.vaultId,
          vaultKey: nextKey,
          keyEpoch: 2,
          membershipVersion: 2,
          recipientDeviceId: target['device_id']! as String,
          recipientEncryptionPublicKey: decodeBase64Url(
            target['encryption_public_key']! as String,
          ),
          signer: app.identity!,
        );
        await api.installPostEnrollmentRotation(
          membership: nextMembership,
          manifest: nextManifest,
          nameEnvelope: nextNameEnvelope,
          keyEnvelope: nextKeyEnvelope,
          recipientDeviceId: target['device_id']! as String,
        );

        await app.importDeviceApproval(approval);
        await app.login(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );
        expect(app.activeVault?.activeKeyEpoch, '2');
        expect(app.activeVault?.membershipVersion, '2');
        expect(app.currentVaultName, 'Operations');
        expect(secureStore.savedPendingApproval, isNull);

        api.omitCurrentDeviceEnvelopes = true;
        await expectLater(
          app.login(
            username: 'owner@example.test',
            password: 'correct horse battery staple',
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'read-only sync refreshes signed membership after a missed key-rotation hint',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => now,
      );
      final app = harness.app;
      final api = harness.api;
      const pendingRecordId = '66666666-6666-4666-8666-666666666666';
      const remoteRecordId = '77777777-7777-4777-8777-777777777777';
      try {
        // Keep the local create queued while the active Vault becomes
        // effectively read-only. Its immutable envelope must survive refresh.
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending local edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        expect(pendingBefore, hasLength(1));
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;

        app.setStage(ClientStage.workspace);
        app.showWorkspacePage(WorkspacePage.devices);
        await _waitForCondition(
          () => app.vaultDeviceRowsVaultId == api.vaultId,
          reason: 'Devices page did not load its initial Vault device roster',
        );
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();
        expect(app.activeVault?.canWrite, isFalse);
        final membershipReadsBefore = api.membershipReads;
        final changesStart = api.requestedChangeCursors.length;
        final traceStart = api.controlPlaneCallOrder.length;

        api.pendingChangeEvents.add(
          await _installMissedRotationAndCreateEvent(
            app,
            api,
            sodium,
            recordId: remoteRecordId,
          ),
        );

        await app.synchronize();

        expect(app.activeVault?.activeKeyEpoch, '2');
        expect(app.activeVault?.membershipVersion, '2');
        expect(api.membershipReads, membershipReadsBefore + 1);
        expect(
          app.vaultDeviceRowsVaultId,
          api.vaultId,
          reason:
              'membership refresh left the open Devices page without its Vault roster',
        );
        expect(app.vaultDeviceRows, isNotEmpty);
        expect(api.requestedChangeCursors.skip(changesStart), [
          null,
          null,
        ], reason: 'the failed page must replay from the unchanged cursor');
        final trace = api.controlPlaneCallOrder.skip(traceStart).toList();
        final firstChanges = trace.indexOf('changes');
        final secondChanges = trace.lastIndexOf('changes');
        expect(firstChanges, greaterThanOrEqualTo(0));
        expect(secondChanges, greaterThan(firstChanges));
        expect(
          trace.sublist(firstChanges + 1, secondChanges),
          containsAll(['devices', 'vaults', 'vaultDevices', 'membership']),
          reason: 'verified account/Vault control plane must precede replay',
        );
        expect(app.syncStatus, 'read_only');

        final checkpoint = await harness.database.checkpoint(
          api.vaultId,
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        expect(checkpoint?.cursor, 'rotation-cursor');
        final cached = await harness.database.cachedEnvelopes(
          api.vaultId,
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        final remote = cached.singleWhere(
          (row) => row.recordId == remoteRecordId,
        );
        expect(remote.commitSeq, '1');
        expect(app.hosts.map((host) => host.id), contains(remoteRecordId));
        expect(
          await harness.database.countPending(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          1,
        );
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
        expect(api.pushCalls, 0);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'host-key preflight waits for missed membership refresh before reading trust',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      final knownHost = KnownHostRecord.approve(
        host: 'refresh-race.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
        approvedByDeviceId: app.identity!.deviceId,
        approvedAt: DateTime.utc(2026, 10, 1),
      );
      final changesEntered = Completer<void>();
      final releaseChanges = Completer<void>();
      final vaultsEntered = Completer<void>();
      final releaseVaults = Completer<void>();
      Future<void>? backgroundSync;
      Future<void>? observedDecision;
      var decisionSettledBeforeMembershipRelease = false;
      KnownHostTrustStatus? decisionStatus;
      Object? decisionError;

      try {
        final event = await _installMissedRotationAndCreateEvent(
          app,
          api,
          sodium,
          recordId: knownHost.id,
          plaintext: knownHost.toJson(),
        );
        api.pendingChangeEvents.add(event);
        api.nextChangesEntered = changesEntered;
        api.nextChangesRelease = releaseChanges;
        api.nextVaultsEntered = vaultsEntered;
        api.nextVaultsRelease = releaseVaults;
        final membershipReadsBefore = api.membershipReads;

        backgroundSync = app.synchronize(background: true);
        await changesEntered.future.timeout(const Duration(seconds: 5));

        observedDecision = app
            .knownHostTrustStatus(
              host: knownHost.host,
              port: knownHost.port,
              algorithm: knownHost.algorithm,
              fingerprint: knownHost.fingerprint,
            )
            .then<void>(
              (status) => decisionStatus = status,
              onError: (Object error, StackTrace stackTrace) {
                decisionError = error;
              },
            )
            .whenComplete(() {
              decisionSettledBeforeMembershipRelease = true;
            });

        releaseChanges.complete();
        await vaultsEntered.future.timeout(const Duration(seconds: 5));
        // The host decision is waiting on the active sync. The sync has now
        // discovered the missed epoch and entered the signed membership
        // refresh, which is held at GET /vaults to keep that window open. Its
        // sync wake-up must retry against the state published by this refresh
        // instead of escaping through the transient state check.
        await Future<void>.delayed(Duration.zero);
        final settledWhileRefreshWasBlocked =
            decisionSettledBeforeMembershipRelease;

        releaseVaults.complete();
        await backgroundSync.timeout(const Duration(seconds: 10));
        await observedDecision.timeout(const Duration(seconds: 10));

        expect(
          settledWhileRefreshWasBlocked,
          isFalse,
          reason: 'host-key preflight must wait while membership is refreshing',
        );
        expect(
          decisionError,
          isNull,
          reason: 'a refresh racing the sync wake-up is transient',
        );
        expect(
          decisionStatus,
          KnownHostTrustStatus.trusted,
          reason: 'trust must be read after refreshing the membership keys',
        );
        expect(api.membershipReads, membershipReadsBefore + 1);
        expect(app.activeVault?.activeKeyEpoch, '2');
        expect(app.activeVault?.membershipVersion, '2');
        expect(app.knownHosts.single.id, knownHost.id);
      } finally {
        if (!releaseChanges.isCompleted) releaseChanges.complete();
        if (!releaseVaults.isCompleted) releaseVaults.complete();
        await backgroundSync;
        await observedDecision;
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'well-formed unknown event signer refreshes directory before one replay',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      final remoteDevice = DeviceIdentity.create(sodium);
      const remoteRecordId = 'aaaaaaaa-1111-4111-8111-111111111111';
      Uint8List? currentVaultKey;
      try {
        final identity = app.identity!;
        currentVaultKey = await app.crypto.openVaultKeyEnvelope(
          vaultId: api.vaultId,
          deviceId: identity.deviceId,
          identity: identity,
          keyEnvelope: api.keyEnvelope,
          signerPublicKey: identity.signing.publicKey,
        );
        final envelope = await app.crypto.encryptRecord(
          vaultKey: currentVaultKey,
          serverSpaceId: app.instance!.serverSpaceId,
          vaultId: api.vaultId,
          recordId: remoteRecordId,
          baseRevisionId: null,
          deviceId: remoteDevice.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: {
            'id': remoteRecordId,
            'type': 'host',
            'name': 'Late signer host',
            'address': 'late-signer.example.test',
            'username': 'deploy',
          },
          identity: remoteDevice,
        );
        final header = Map<String, dynamic>.from(envelope['header']! as Map);
        api.pendingChangeEvents.add({
          'commit_seq': '1',
          'event_type': header['operation'],
          'record_id': header['record_id'],
          'revision_id': header['revision_id'],
          'envelope': envelope,
        });
        api.delayedSignerOnFirstChange = {
          ...remoteDevice.registrationProof(
            sodium,
            accountId: api.accountId,
            name: 'Delayed sibling device',
          ),
          'user_id': api.accountId,
          'status': 'active',
        };
        api.exposeDelayedSignerOnNextChanges = true;
        final membershipReadsBefore = api.membershipReads;
        final changesStart = api.requestedChangeCursors.length;

        await app.synchronize();

        expect(api.membershipReads, membershipReadsBefore + 1);
        expect(api.requestedChangeCursors.skip(changesStart), [null, null]);
        expect(
          app.hosts.map((host) => host.id),
          contains(remoteRecordId),
          reason: 'the refreshed signer directory must authenticate replay',
        );
        expect(
          (await harness.database.checkpoint(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ))?.cursor,
          api.pendingChangeCursor,
        );
        expect(app.syncStatus, 'idle');
      } finally {
        app.dispose();
        await harness.database.close();
        remoteDevice.dispose();
        final openedVaultKey = currentVaultKey;
        if (openedVaultKey != null) {
          openedVaultKey.fillRange(0, openedVaultKey.length, 0);
        }
      }
    },
  );

  test(
    'bad signature on missing epoch key does not refresh membership or replay',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const remoteRecordId = 'bbbbbbbb-2222-4222-8222-222222222222';
      const pendingRecordId = 'dddddddd-4444-4444-8444-444444444444';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending encrypted edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();
        final event = await _installMissedRotationAndCreateEvent(
          app,
          api,
          sodium,
          recordId: remoteRecordId,
          eventEpoch: 3,
          eventMembershipVersion: 3,
        );
        final envelope = Map<String, dynamic>.from(event['envelope']! as Map);
        envelope['signature'] = encodeBase64Url(List<int>.filled(64, 0));
        api.pendingChangeEvents.add({...event, 'envelope': envelope});
        final membershipReadsBefore = api.membershipReads;
        final vaultReadsBefore = api.vaultListReads;
        final cursorStart = api.requestedChangeCursors.length;
        final pushesBefore = api.pushCalls;

        await expectLater(
          app.synchronize(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Record signature is invalid'),
            ),
          ),
        );

        expect(api.membershipReads, membershipReadsBefore);
        expect(api.vaultListReads, vaultReadsBefore);
        expect(api.requestedChangeCursors.skip(cursorStart), [null]);
        expect(
          (await harness.database.checkpoint(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ))?.cursor,
          isNull,
        );
        expect(
          (await harness.database.cachedEnvelopes(
            api.vaultId,
          )).where((row) => row.recordId == remoteRecordId),
          isEmpty,
        );
        final pendingAfter = await harness.database.allPendingOperations(
          api.vaultId,
        );
        expect(pendingAfter, hasLength(1));
        expect(pendingAfter.single.envelopeJson, pendingEnvelopeBefore);
        expect(api.pushCalls, pushesBefore);
        expect(app.authenticated, isTrue);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'malformed signer header does not request control-plane refresh',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const remoteRecordId = 'cccccccc-3333-4333-8333-333333333333';
      const pendingRecordId = 'eeeeeeee-5555-4555-8555-555555555555';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending encrypted edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();
        final event = await _installMissedRotationAndCreateEvent(
          app,
          api,
          sodium,
          recordId: remoteRecordId,
          eventEpoch: 3,
          eventMembershipVersion: 3,
        );
        final envelope = Map<String, dynamic>.from(event['envelope']! as Map);
        final header = Map<String, dynamic>.from(envelope['header']! as Map)
          ..['device_id'] = 'not-a-canonical-device-id';
        envelope['header'] = header;
        api.pendingChangeEvents.add({...event, 'envelope': envelope});
        final membershipReadsBefore = api.membershipReads;
        final vaultReadsBefore = api.vaultListReads;
        final cursorStart = api.requestedChangeCursors.length;
        final pushesBefore = api.pushCalls;

        await expectLater(app.synchronize(), throwsFormatException);

        expect(api.membershipReads, membershipReadsBefore);
        expect(api.vaultListReads, vaultReadsBefore);
        expect(api.requestedChangeCursors.skip(cursorStart), [null]);
        expect(
          (await harness.database.checkpoint(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ))?.cursor,
          isNull,
        );
        expect(
          (await harness.database.cachedEnvelopes(
            api.vaultId,
          )).where((row) => row.recordId == remoteRecordId),
          isEmpty,
        );
        final pendingAfter = await harness.database.allPendingOperations(
          api.vaultId,
        );
        expect(pendingAfter, hasLength(1));
        expect(pendingAfter.single.envelopeJson, pendingEnvelopeBefore);
        expect(api.pushCalls, pushesBefore);
        expect(app.authenticated, isTrue);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'one signed control-plane refresh bounds repeated missing-key pages',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => now,
      );
      final app = harness.app;
      final api = harness.api;
      const pendingRecordId = '88888888-8888-4888-8888-888888888888';
      const remoteRecordId = '99999999-9999-4999-8999-999999999999';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending local edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();

        api.pendingChangeEvents.add(
          await _installMissedRotationAndCreateEvent(
            app,
            api,
            sodium,
            recordId: remoteRecordId,
            eventEpoch: 3,
            eventMembershipVersion: 3,
          ),
        );
        final changesStart = api.requestedChangeCursors.length;
        final membershipReadsBefore = api.membershipReads;
        final pushesBefore = api.pushCalls;

        await app.synchronize();

        expect(app.syncStatus, 'epoch_update_required');
        expect(app.authenticated, isTrue);
        expect(api.membershipReads, membershipReadsBefore + 1);
        expect(api.requestedChangeCursors.skip(changesStart), [
          null,
          null,
        ], reason: 'only one retry is permitted and neither page may advance');
        expect(
          (await harness.database.checkpoint(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ))?.cursor,
          isNull,
        );
        final cached = await harness.database.cachedEnvelopes(
          api.vaultId,
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        expect(
          cached.where((row) => row.recordId == remoteRecordId),
          isEmpty,
          reason: 'an event without a verified key must not enter the cache',
        );
        expect(
          await harness.database.countPending(
            api.vaultId,
            instanceId: _syncInstanceId,
            serverSpaceId: _syncServerSpaceId,
          ),
          1,
        );
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
        expect(api.pushCalls, pushesBefore);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'periodic recovery refreshes the account control plane before changes',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => now,
      );
      final app = harness.app;
      final api = harness.api;
      try {
        final traceStart = api.controlPlaneCallOrder.length;
        final vaultReadsBefore = api.vaultListReads;
        final membershipReadsBefore = api.membershipReads;
        now = now.add(const Duration(seconds: 46));

        await app.synchronize();

        final trace = api.controlPlaneCallOrder.skip(traceStart).toList();
        expect(trace.indexOf('vaults'), greaterThanOrEqualTo(0));
        expect(
          trace.indexOf('membership'),
          greaterThan(trace.indexOf('vaults')),
        );
        expect(
          trace.indexOf('changes'),
          greaterThan(trace.indexOf('membership')),
        );
        expect(api.vaultListReads, vaultReadsBefore + 1);
        expect(api.membershipReads, membershipReadsBefore + 1);

        final readsAfterRefresh = api.vaultListReads;
        now = now.subtract(const Duration(minutes: 10));
        await app.synchronize();
        expect(
          api.vaultListReads,
          readsAfterRefresh + 1,
          reason: 'a backwards wall-clock adjustment must not suppress refresh',
        );
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test('sync callers wait through a serialized follow-up pass', () async {
    final harness = await _createRegisteredSyncHarness(sodium);
    final app = harness.app;
    final api = harness.api;
    final firstChangesEntered = Completer<void>();
    final releaseFirstChanges = Completer<void>();
    final followUpChangesEntered = Completer<void>();
    final releaseFollowUpChanges = Completer<void>();
    Future<void>? firstSync;
    Future<void>? concurrentSync;
    var firstSyncSettled = false;
    var concurrentSyncSettled = false;

    try {
      api
        ..nextChangesEntered = firstChangesEntered
        ..nextChangesRelease = releaseFirstChanges;
      firstSync = app.synchronize().whenComplete(() {
        firstSyncSettled = true;
      });
      await firstChangesEntered.future.timeout(const Duration(seconds: 5));

      // A manual request arriving during the active pull is coalesced into
      // a second pass. Hold that pass so neither caller can mistake the
      // first pass's completion for completion of the queued request.
      api
        ..nextChangesEntered = followUpChangesEntered
        ..nextChangesRelease = releaseFollowUpChanges;
      concurrentSync = app.synchronize().whenComplete(() {
        concurrentSyncSettled = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(firstSyncSettled, isFalse);
      expect(concurrentSyncSettled, isFalse);

      releaseFirstChanges.complete();
      await followUpChangesEntered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(app.syncStatus, 'syncing');
      expect(
        firstSyncSettled,
        isFalse,
        reason: 'the initiating caller must await the queued pass',
      );
      expect(
        concurrentSyncSettled,
        isFalse,
        reason: 'the coalesced caller must await the queued pass',
      );

      releaseFollowUpChanges.complete();
      await firstSync.timeout(const Duration(seconds: 10));
      await concurrentSync.timeout(const Duration(seconds: 10));
      expect(firstSyncSettled, isTrue);
      expect(concurrentSyncSettled, isTrue);
      expect(api.changeReads, greaterThanOrEqualTo(2));
      expect(app.syncStatus, 'idle');
    } finally {
      if (!releaseFirstChanges.isCompleted) releaseFirstChanges.complete();
      if (!releaseFollowUpChanges.isCompleted) {
        releaseFollowUpChanges.complete();
      }
      await firstSync;
      await concurrentSync;
      app.dispose();
      await harness.database.close();
    }
  });

  test(
    'sync callers wait through an active membership refresh and coalesce its follow-up',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => now,
      );
      final app = harness.app;
      final api = harness.api;
      final vaultsEntered = Completer<void>();
      final releaseVaults = Completer<void>();
      final changesEntered = Completer<void>();
      final releaseChanges = Completer<void>();
      Future<void>? firstSync;
      Future<void>? concurrentSync;
      var concurrentSyncSettled = false;
      final syncStatusHistory = <String>[];
      void captureSyncStatus() => syncStatusHistory.add(app.syncStatus);
      app.addListener(captureSyncStatus);

      try {
        now = now.add(const Duration(seconds: 46));
        api
          ..nextVaultsEntered = vaultsEntered
          ..nextVaultsRelease = releaseVaults
          ..nextChangesEntered = changesEntered
          ..nextChangesRelease = releaseChanges;

        firstSync = app.synchronize();
        await vaultsEntered.future.timeout(const Duration(seconds: 5));
        expect(
          app.syncStatus,
          'syncing',
          reason: 'the visible status must cover the signed refresh prelude',
        );
        concurrentSync = app.synchronize().whenComplete(() {
          concurrentSyncSettled = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          concurrentSyncSettled,
          isFalse,
          reason: 'a sync wake-up must wait for the signed membership refresh',
        );

        releaseVaults.complete();
        await changesEntered.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        expect(
          concurrentSyncSettled,
          isFalse,
          reason: 'the concurrent caller must wait for the active sync pass',
        );
        expect(
          syncStatusHistory,
          isNot(contains('idle')),
          reason:
              'membership refresh must not publish stale Idle before pull completion',
        );

        releaseChanges.complete();
        await firstSync.timeout(const Duration(seconds: 10));
        await concurrentSync.timeout(const Duration(seconds: 10));
        expect(concurrentSyncSettled, isTrue);
        expect(api.changeReads, greaterThanOrEqualTo(2));
        expect(app.syncStatus, 'idle');
      } finally {
        if (!releaseVaults.isCompleted) releaseVaults.complete();
        if (!releaseChanges.isCompleted) releaseChanges.complete();
        await firstSync;
        await concurrentSync;
        app.removeListener(captureSyncStatus);
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'transient control-plane GET failure retains session and signed Vault state',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => now,
      );
      final app = harness.app;
      final api = harness.api;
      final activeVaultId = app.activeVault!.id;
      const pendingRecordId = '12121212-1212-4121-8121-121212121212';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending local edit',
            address: 'pending-before-integrity-refresh.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);

        api.failNextVaultList = const ApiTransportException(
          method: 'GET',
          path: '/api/v1/vaults',
        );
        now = now.add(const Duration(seconds: 46));

        await expectLater(
          app.synchronize(),
          throwsA(isA<ApiTransportException>()),
        );

        expect(
          api.controlPlaneCallOrder.skip(api.controlPlaneCallOrder.length - 1),
          ['vaults'],
        );
        expect(app.authenticated, isTrue);
        expect(app.stage, ClientStage.workspace);
        expect(app.activeVault?.id, activeVaultId);
        expect(app.vaults.map((vault) => vault.id), [activeVaultId]);

        api.failNextVaultList = const SyncReadTransportUnavailableException(
          path: '/api/v1/vaults',
        );
        await expectLater(
          app.synchronize(),
          throwsA(isA<SyncReadTransportUnavailableException>()),
        );
        expect(app.authenticated, isTrue);
        expect(app.stage, ClientStage.workspace);
        expect(app.activeVault?.id, activeVaultId);

        // The failed refresh did not advance its timer. A subsequent signed
        // membership integrity failure still locks this client fail-closed.
        api.corruptMembershipSignature = true;
        final vaultReadsBefore = api.vaultListReads;
        final membershipReadsBefore = api.membershipReads;
        await app.synchronize();

        expect(app.authenticated, isFalse);
        expect(api.vaultListReads, greaterThan(vaultReadsBefore));
        expect(api.membershipReads, greaterThan(membershipReadsBefore));
        expect(await harness.database.countPending(api.vaultId), 1);
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'revoked Vault on forced refresh preserves its outbox and does not replay',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const pendingRecordId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const remoteRecordId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending local edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();
        api.pendingChangeEvents.add(
          await _installMissedRotationAndCreateEvent(
            app,
            api,
            sodium,
            recordId: remoteRecordId,
          ),
        );
        api.hideAllVaults = true;
        final changesStart = api.requestedChangeCursors.length;

        await app.synchronize();

        expect(app.syncStatus, 'revoked');
        expect(app.authenticated, isTrue);
        expect(app.activeVault, isNull);
        expect(api.requestedChangeCursors.skip(changesStart), [null]);
        expect(await harness.database.countPending(api.vaultId), 1);
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
        expect(api.pushCalls, 0);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    '404 NOT_FOUND sync reloads signed roster and preserves revoked Vault outbox',
    () async {
      final controlPlaneTime = DateTime.utc(2026, 10, 6);
      final harness = await _createRegisteredSyncHarness(
        sodium,
        nowForTesting: () => controlPlaneTime,
      );
      final app = harness.app;
      final api = harness.api;
      const pendingRecordId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending revoked Vault edit',
            address: 'pending-revoked.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        expect(pendingBefore, hasLength(1));
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;

        app.setStage(ClientStage.workspace);
        api
          ..failNextChanges = const ApiException(
            statusCode: 404,
            code: 'NOT_FOUND',
            message: 'synthetic opaque missing Vault',
          )
          ..hideAllVaults = true;
        final traceStart = api.controlPlaneCallOrder.length;
        final changesStart = api.changeReads;
        final vaultReadsStart = api.vaultListReads;

        await app.synchronize();

        expect(api.changeReads, changesStart + 1);
        expect(api.requestedChangeCursors.last, isNull);
        expect(api.vaultListReads, vaultReadsStart + 1);
        final syncTrace = api.controlPlaneCallOrder.skip(traceStart).toList();
        final deniedReadIndex = syncTrace.indexOf('changes');
        expect(deniedReadIndex, greaterThanOrEqualTo(0));
        final rosterVaultsIndex = syncTrace.indexOf(
          'vaults',
          deniedReadIndex + 1,
        );
        expect(rosterVaultsIndex, greaterThan(deniedReadIndex));
        expect(
          syncTrace.elementAt(rosterVaultsIndex + 1),
          'devices',
          reason:
              'the Vault descriptors must be read before signer rosters after a revoked read',
        );
        expect(app.syncStatus, 'revoked');
        expect(app.authenticated, isTrue);
        expect(app.activeVault, isNull);
        expect(await harness.database.countPending(api.vaultId), 1);
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
        expect(api.pushCalls, 0);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test(
    'invalid signed membership during forced refresh logs out without deleting outbox',
    () async {
      final harness = await _createRegisteredSyncHarness(sodium);
      final app = harness.app;
      final api = harness.api;
      const pendingRecordId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      const remoteRecordId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      try {
        app.setStage(ClientStage.server);
        await app.saveHost(
          const HostRecord(
            id: pendingRecordId,
            name: 'Pending local edit',
            address: 'pending.example.test',
            username: 'deploy',
          ),
        );
        final pendingBefore = await harness.database.allPendingOperations(
          api.vaultId,
        );
        final pendingEnvelopeBefore = pendingBefore.single.envelopeJson;
        app.setStage(ClientStage.workspace);
        api.serverCanWrite = false;
        await app.refreshVaultLifecycle();
        api.pendingChangeEvents.add(
          await _installMissedRotationAndCreateEvent(
            app,
            api,
            sodium,
            recordId: remoteRecordId,
          ),
        );
        api.corruptMembershipSignature = true;
        final changesStart = api.requestedChangeCursors.length;
        final vaultReadsBefore = api.vaultListReads;
        final membershipReadsBefore = api.membershipReads;

        await app.synchronize();

        expect(app.authenticated, isFalse);
        expect(api.vaultListReads, greaterThan(vaultReadsBefore));
        expect(api.membershipReads, greaterThan(membershipReadsBefore));
        expect(api.requestedChangeCursors.skip(changesStart), [null]);
        expect(await harness.database.countPending(api.vaultId), 1);
        expect(
          (await harness.database.allPendingOperations(
            api.vaultId,
          )).single.envelopeJson,
          pendingEnvelopeBefore,
        );
        expect(api.pushCalls, 0);
      } finally {
        app.dispose();
        await harness.database.close();
      }
    },
  );

  test('device approval import accepts an empty transfer list', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final secureStore = _MemorySecureStore();
    final api = _RegistrationApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: secureStore,
          )
          ..api = api
          ..instance = const InstanceInfo(
            instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            protocolVersion: 1,
            setupRequired: true,
            capabilities: ['ciphertext_sync', 'snapshots'],
          );
    try {
      await app.register(
        username: 'owner@example.test',
        password: 'correct horse battery staple',
        bootstrapToken: 'bootstrap-once',
      );
      final requestJson = await app.createDeviceEnrollmentRequest(
        username: 'owner@example.test',
        name: 'No Vault device',
      );
      final request = jsonDecode(requestJson) as Map<String, dynamic>;
      final device = Map<String, dynamic>.from(request['device'] as Map);
      final approverId = app.identity!.deviceId;
      final certificatePayload = <String, Object?>{
        'account_id': api.accountId,
        'approver_device_id': approverId,
        'device': device,
      };
      final certificate = sodium.crypto.sign.detached(
        message: Uint8List.fromList(
          utf8.encode(canonicalJson(certificatePayload)),
        ),
        secretKey: app.identity!.signing.secretKey,
      );
      final approval = const JsonEncoder.withIndent('  ').convert({
        'format': 'atermius-device-approval-v1',
        'account_id': api.accountId,
        'device': device,
        'approver_device_id': approverId,
        'certificate_signature': encodeBase64Url(certificate),
        'vault_key_envelopes': const <Object?>[],
      });

      await app.importDeviceApproval(approval);
      expect(app.stage, ClientStage.login);
      expect(secureStore.savedDeviceJson, isNotNull);
      expect(secureStore.savedPendingApproval, approval);
    } finally {
      app.dispose();
      await database.close();
    }
  });

  test(
    'empty Vault workspace supports empty-envelope enrollment and Vault creation',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _MemorySecureStore();
      final api = _RegistrationApi()..hideAllVaults = true;
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );
        expect(app.authenticated, isTrue);
        expect(app.activeVault, isNull);
        expect(app.vaults, isEmpty);

        final enrollment = await app.createDeviceEnrollmentRequest(
          username: 'owner@example.test',
          name: 'Empty workspace device',
        );
        final approval = await app.approveDeviceEnrollment(enrollment);
        expect(api.registeredDeviceBody?['vault_key_envelopes'], isEmpty);

        await app.importDeviceApproval(approval);
        await app.login(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );
        expect(app.authenticated, isTrue);
        expect(app.activeVault, isNull);
        expect(app.vaults, isEmpty);

        await app.createVault('Recovered workspace');
        expect(app.activeVault, isNotNull);
        expect(
          app.activeVault?.id,
          isNot(api.initialVaultPayload?['vault_id']),
        );
        expect(app.currentVaultName, 'Recovered workspace');
        expect(app.activeVault?.canWrite, isTrue);
        await _waitForSyncIdle(app);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'a later accessible-Vault listing restores an empty account workspace after relogin',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _MemorySecureStore();
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
          vaultName: 'Restored vault',
        );
        await _waitForSyncIdle(app);
        expect(app.activeVault, isNotNull);

        api.hideAllVaults = true;
        await app.logout();
        await app.login(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );
        expect(app.authenticated, isTrue);
        expect(app.activeVault, isNull);
        expect(app.vaults, isEmpty);

        api.hideAllVaults = false;
        await app.logout();
        await app.login(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
        );
        expect(app.activeVault?.id, api.vaultId);
        expect(app.currentVaultName, 'Restored vault');
        expect(app.vaults, hasLength(1));
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'owner role rotation defers membership hints until its signed refresh completes',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _MemorySecureStore(),
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      final changesEntered = Completer<void>();
      final releaseChanges = Completer<void>();
      final vaultsEntered = Completer<void>();
      final releaseVaults = Completer<void>();
      Future<void>? rotation;
      Future<void>? hint;
      final editorDeviceOne = DeviceIdentity.create(sodium);
      final editorDeviceTwo = DeviceIdentity.create(sodium);
      final pendingDevice = DeviceIdentity.create(sodium);
      final unhandled = <Future<void>>[];
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
          vaultName: 'Operations',
        );
        await _waitForSyncIdle(app);
        await _installRotationMembershipFixture(
          app,
          api,
          sodium,
          editorDeviceOne: editorDeviceOne,
          editorDeviceTwo: editorDeviceTwo,
          pendingDevice: pendingDevice,
        );

        // Membership manifests can advance without changing the data key.
        // Store a record at the latest membership version, then rotate the
        // data key so hydration must retain the earlier epoch key as an
        // alias for this record's signed version.
        for (final version in [2, 3]) {
          final previousEntry = api.membershipRecords.last;
          final previousPayload = <String, Object?>{
            'vault_id': api.vaultId,
            'membership_version': previousEntry['membership_version'],
            'previous_digest': previousEntry['previous_digest'],
            'manifest': previousEntry['manifest'],
          };
          final digestBytes = await cryptography.Sha256().hash(
            utf8.encode(canonicalJson(previousPayload)),
          );
          final previousDigest = digestBytes.bytes
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join();
          final manifest = Map<String, Object?>.from(api.membershipManifest)
            ..['key_epoch'] = 1
            ..['signer_device_id'] = app.identity!.deviceId;
          final signed = app.crypto.createMembershipGrant(
            vaultId: api.vaultId,
            membershipVersion: version,
            previousDigest: previousDigest,
            manifest: manifest,
            signer: app.identity!,
          );
          api.membershipManifest = Map<String, dynamic>.from(manifest);
          api.membershipSignature = signed['signature']! as String;
          api.activeMembershipVersion = version;
          api.membershipRecords = [
            ...api.membershipRecords,
            {
              'membership_version': version,
              'previous_digest': previousDigest,
              'manifest': api.membershipManifest,
              'signature': api.membershipSignature,
              'signer_device_id': app.identity!.deviceId,
            },
          ];
        }
        await app.reloadVaultsForTesting();
        await app.saveHost(
          const HostRecord(
            id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            name: 'Epoch continuity host',
            address: 'epoch-continuity.example.test',
            username: 'deploy',
          ),
        );
        await _waitForSyncIdle(app);
        final storedRecord = (await database.cachedEnvelopes(api.vaultId))
            .singleWhere(
              (row) => row.recordId == 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            );
        final storedHeader =
            (jsonDecode(storedRecord.envelopeJson)
                    as Map<String, dynamic>)['header']
                as Map<String, dynamic>;
        expect(storedHeader['key_epoch'], '1');
        expect(storedHeader['membership_version'], '3');

        final initialVaultReads = api.vaultListReads;
        final initialMemberReads = api.vaultMembersReads;
        final initialMembershipReads = api.membershipReads;
        api.nextChangesEntered = changesEntered;
        api.nextChangesRelease = releaseChanges;
        api.nextVaultsEntered = vaultsEntered;
        api.nextVaultsRelease = releaseVaults;
        api.snapshotVaultsBeforeNextWait = true;

        rotation = app.changeVaultMemberRole(
          userId: _editorAccountId,
          role: 'viewer',
        );
        await changesEntered.future.timeout(const Duration(seconds: 5));
        expect(app.vaultMembershipBusy, isTrue);

        hint = app.handleSyncHintForTesting(SyncHint(vaultId: api.vaultId));
        await hint;
        hint = app.handleSyncHintForTesting(
          const SyncHint(vaultId: null, membershipChanged: true),
        );
        await hint;
        hint = app.handleSyncHintForTesting(SyncHint(vaultId: api.vaultId));
        await hint;
        expect(api.vaultListReads, initialVaultReads);
        expect(app.membershipRefreshActiveForTesting, isFalse);

        releaseChanges.complete();
        await vaultsEntered.future.timeout(const Duration(seconds: 5));
        await _waitForCondition(
          () => api.activeMembershipVersion == 4,
          reason:
              'the role rotation did not commit while the Vault read was held',
        );
        releaseVaults.complete();

        await expectLater(rotation, completes);
        await expectLater(hint, completes);
        final firstReplay = app.deferredSyncHintReplayForTesting;
        expect(firstReplay, isNotNull);
        await expectLater(firstReplay, completes);
        await _waitForSyncIdle(app);

        expect(app.authenticated, isTrue);
        expect(api.rotationWrites, 1);
        expect(api.activeEpoch, 2);
        expect(api.activeMembershipVersion, 4);
        expect(
          api.vaultMembersReads,
          greaterThanOrEqualTo(initialMemberReads + 2),
        );
        expect(api.membershipReads, greaterThan(initialMembershipReads));
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _editorAccountId,
          )['role'],
          'viewer',
        );
        expect(app.activeVault?.membershipVersion, '4');
        expect(
          app.hosts.map((host) => host.id),
          contains('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
        );
        await app.saveHost(
          const HostRecord(
            id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            name: 'Rotated epoch host',
            address: 'rotated-epoch.example.test',
            username: 'deploy',
          ),
        );
        await _waitForSyncIdle(app);
        final rotatedEpochRecord = (await database.cachedEnvelopes(api.vaultId))
            .singleWhere(
              (row) => row.recordId == 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            );
        final rotatedEpochHeader =
            (jsonDecode(rotatedEpochRecord.envelopeJson)
                    as Map<String, dynamic>)['header']
                as Map<String, dynamic>;
        expect(rotatedEpochHeader['key_epoch'], '2');
        expect(rotatedEpochHeader['membership_version'], '4');

        // Exercise the deferred replay failure path separately from the
        // signed rotation reload. The first Vault list belongs to the direct
        // post-rotation refresh; the replay's next Vault list fails as a
        // safe transport error and must not escape as an unhandled Future.
        api.failVaultListAtRead = api.vaultListReads + 2;
        final promotion = app.changeVaultMemberRole(
          userId: _editorAccountId,
          role: 'editor',
        );
        await _waitForCondition(
          () => app.vaultMembershipBusy,
          reason: 'the second role rotation did not enter its busy window',
        );
        await app.handleSyncHintForTesting(
          const SyncHint(vaultId: null, membershipChanged: true),
        );
        await expectLater(promotion, completes);
        final failedReplay = app.deferredSyncHintReplayForTesting;
        expect(failedReplay, isNotNull);
        await expectLater(failedReplay, completes);
        expect(api.failVaultListAtRead, isNull);
        expect(app.authenticated, isTrue);
        expect(app.activeVault?.membershipVersion, '5');
        expect(app.syncStatus, 'retry_wait');
      } finally {
        if (!releaseChanges.isCompleted) releaseChanges.complete();
        if (!releaseVaults.isCompleted) releaseVaults.complete();
        for (final pending in [hint, rotation]) {
          if (pending == null) continue;
          unhandled.add(pending);
        }
        for (final pending in unhandled) {
          try {
            await pending.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        app.dispose();
        editorDeviceOne.dispose();
        editorDeviceTwo.dispose();
        pendingDevice.dispose();
        await database.close();
      }
    },
  );

  test(
    'owner rotation rekeys retained devices and signed Vault metadata',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _MemorySecureStore(),
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      final editorDeviceOne = DeviceIdentity.create(sodium);
      final editorDeviceTwo = DeviceIdentity.create(sodium);
      final pendingDevice = DeviceIdentity.create(sodium);
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
          vaultName: 'Operations',
        );
        await _waitForSyncIdle(app);
        final originalName = app.currentVaultName;
        await _installRotationMembershipFixture(
          app,
          api,
          sodium,
          editorDeviceOne: editorDeviceOne,
          editorDeviceTwo: editorDeviceTwo,
          pendingDevice: pendingDevice,
        );

        await app.changeVaultMemberRole(
          userId: _editorAccountId,
          role: 'viewer',
        );
        await _waitForSyncIdle(app);
        expect(api.activeEpoch, 2);
        expect(api.activeMembershipVersion, 2);
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _editorAccountId,
          )['role'],
          'viewer',
        );
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _pendingAccountId,
          )['state'],
          'invited',
        );
        expect(
          api.lastRotationEnvelopes.map((item) => item['recipient_device_id']),
          unorderedEquals([
            app.identity!.deviceId,
            editorDeviceOne.deviceId,
            editorDeviceTwo.deviceId,
            pendingDevice.deviceId,
          ]),
        );
        expect(
          api.membershipManifest['display_name_envelope'],
          api.nameEnvelope,
        );
        expect(app.activeVault!.encryptedDisplayNameEnvelope, api.nameEnvelope);
        expect(app.activeVault!.activeKeyEpoch, '2');
        expect(app.activeVault!.membershipVersion, '2');
        expect(app.currentVaultName, originalName);
        expect(app.noticeMessage, contains('旧 token 已失效'));

        api.failRotationBeforeCommit = true;
        await expectLater(
          app.revokeVaultMember(_pendingAccountId),
          throwsA(isA<StateError>()),
        );
        await _waitForSyncIdle(app);
        expect(api.activeEpoch, 2);
        expect(api.activeMembershipVersion, 2);
        expect(app.activeVault!.activeKeyEpoch, '2');
        expect(app.activeVault!.membershipVersion, '2');
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _pendingAccountId,
          )['state'],
          'invited',
        );
        expect(app.currentVaultName, originalName);
        api.failRotationBeforeCommit = false;

        await app.revokeVaultMember(_editorAccountId);
        await _waitForSyncIdle(app);
        expect(api.activeEpoch, 3);
        expect(api.activeMembershipVersion, 3);
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _editorAccountId,
          )['state'],
          'revoked',
        );
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _pendingAccountId,
          )['state'],
          'invited',
        );
        expect(
          api.lastRotationEnvelopes.map((item) => item['recipient_device_id']),
          unorderedEquals([app.identity!.deviceId, pendingDevice.deviceId]),
        );
        expect(app.activeVault!.activeKeyEpoch, '3');
        expect(app.activeVault!.membershipVersion, '3');
        expect(app.activeVault!.encryptedDisplayNameEnvelope, api.nameEnvelope);
        expect(app.currentVaultName, originalName);
        expect(app.noticeMessage, contains('旧 token 已失效'));
      } finally {
        app.dispose();
        editorDeviceOne.dispose();
        editorDeviceTwo.dispose();
        pendingDevice.dispose();
        await database.close();
      }
    },
  );

  test(
    'deleting Host retires queued attachment task and retries only the tombstone',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _MemorySecureStore(),
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      const hostId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      const objectId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      const blobId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        );
        await _waitForSyncIdle(app);
        app.setStage(ClientStage.server);

        final uploadJobId = 'upload:${api.vaultId}:$hostId:$blobId';
        await database.beginBlobJob(
          jobId: uploadJobId,
          vaultId: api.vaultId,
          recordId: hostId,
          blobId: blobId,
          direction: 'upload',
          state: 'uploading',
          instanceId: _syncInstanceId,
          serverSpaceId: _syncServerSpaceId,
        );
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: objectId,
          sha256: List.filled(64, 'a').join(),
          bytes: Uint8List.fromList([1, 2, 3]),
        );

        const host = HostRecord(
          id: hostId,
          name: 'Disposable edge',
          address: 'edge.example.test',
          username: 'deploy',
          manifest: {
            'extension_version': 1,
            'object_refs': [objectId],
          },
        );
        await app.saveHost(host);
        await app.synchronize();
        expect(
          api.pushedOperations,
          isEmpty,
          reason:
              'A Host reference operation cannot push before its blob upload.',
        );
        expect(
          await database.blobJobsForRecord(api.vaultId, hostId),
          hasLength(1),
        );

        await app.deleteHost(host);
        final pendingBeforePush = await database.queuedOperations(api.vaultId);
        expect(pendingBeforePush, hasLength(1));
        expect(
          (jsonDecode(pendingBeforePush.single.envelopeJson)
              as Map)['header']['operation'],
          'delete',
        );
        expect(await database.blobJobsForRecord(api.vaultId, hostId), isEmpty);
        expect(
          (await database.pushableOperations(
            api.vaultId,
          )).map((item) => item.opId),
          [
            (jsonDecode(pendingBeforePush.single.envelopeJson)
                as Map)['header']['op_id'],
          ],
        );
        expect(app.hosts, isEmpty);

        api.loseNextPushResponse = true;
        await expectLater(app.synchronize(), throwsA(isA<StateError>()));
        expect(api.pushedOperations, hasLength(1));
        final attemptedEnvelope = jsonEncode(api.pushedOperations.single);
        final pendingAfterUnknownResult = await database.queuedOperations(
          api.vaultId,
        );
        expect(pendingAfterUnknownResult, hasLength(1));
        expect(pendingAfterUnknownResult.single.status, 'sent');
        expect(
          pendingAfterUnknownResult.single.envelopeJson,
          attemptedEnvelope,
        );
        expect(await database.blobJobsForRecord(api.vaultId, hostId), isEmpty);

        await app.synchronize();
        expect(api.pushedOperations, hasLength(2));
        expect(jsonEncode(api.pushedOperations.last), attemptedEnvelope);
        expect(await database.queuedOperations(api.vaultId), isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'ownership transfer requires an active member and commits a signed new epoch',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _RegistrationApi();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _MemorySecureStore(),
            )
            ..api = api
            ..instance = const InstanceInfo(
              instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              protocolVersion: 1,
              setupRequired: true,
              capabilities: ['ciphertext_sync', 'snapshots'],
            );
      final editorDeviceOne = DeviceIdentity.create(sodium);
      final editorDeviceTwo = DeviceIdentity.create(sodium);
      final pendingDevice = DeviceIdentity.create(sodium);
      try {
        await app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
          vaultName: 'Operations',
        );
        await _waitForSyncIdle(app);
        await _installRotationMembershipFixture(
          app,
          api,
          sodium,
          editorDeviceOne: editorDeviceOne,
          editorDeviceTwo: editorDeviceTwo,
          pendingDevice: pendingDevice,
        );

        await expectLater(
          app.transferVaultOwnership(newOwnerUserId: _pendingAccountId),
          throwsA(isA<StateError>()),
        );
        expect(api.transferCalls, 0);

        final fixtureDevices = api.additionalDevices;
        api.additionalDevices = fixtureDevices
            .where((device) => device['user_id'] != _editorAccountId)
            .toList(growable: false);
        await expectLater(
          app.transferVaultOwnership(newOwnerUserId: _editorAccountId),
          throwsA(isA<StateError>()),
        );
        expect(api.transferCalls, 0);
        api.additionalDevices = fixtureDevices;
        await _waitForSyncIdle(app);

        api.failRotationBeforeCommit = true;
        await expectLater(
          app.transferVaultOwnership(newOwnerUserId: _editorAccountId),
          throwsA(isA<StateError>()),
        );
        expect(api.transferCalls, 1);
        await _waitForSyncIdle(app);
        expect(api.ownerAccountId, api.accountId);
        expect(api.activeEpoch, 1);
        expect(api.activeMembershipVersion, 1);
        expect(app.activeVault?.role, 'owner');
        api.failRotationBeforeCommit = false;

        await app.transferVaultOwnership(newOwnerUserId: _editorAccountId);
        await _waitForSyncIdle(app);
        expect(api.transferCalls, 2);
        expect(api.ownerAccountId, _editorAccountId);
        expect(api.activeEpoch, 2);
        expect(api.activeMembershipVersion, 2);
        expect(app.activeVault?.role, 'editor');
        expect(app.activeVault?.activeKeyEpoch, '2');
        expect(app.activeVault?.membershipVersion, '2');
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == api.accountId,
          )['role'],
          'editor',
        );
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _editorAccountId,
          )['role'],
          'owner',
        );
        expect(
          api.members.singleWhere(
            (item) => item['user_id'] == _pendingAccountId,
          )['state'],
          'invited',
        );
        expect(api.membershipManifest['ownership_transfer'], {
          'from_user_id': api.accountId,
          'to_user_id': _editorAccountId,
        });
        expect(
          api.lastRotationEnvelopes.map((item) => item['recipient_device_id']),
          unorderedEquals([
            app.identity!.deviceId,
            editorDeviceOne.deviceId,
            editorDeviceTwo.deviceId,
            pendingDevice.deviceId,
          ]),
        );
        expect(app.currentVaultName, 'Operations');
        expect(app.noticeMessage, contains('所有权已转移'));
        await expectLater(
          app.changeVaultMemberRole(userId: _pendingAccountId, role: 'viewer'),
          throwsA(isA<StateError>()),
        );
      } finally {
        app.dispose();
        editorDeviceOne.dispose();
        editorDeviceTwo.dispose();
        pendingDevice.dispose();
        await database.close();
      }
    },
  );

  test('registration failure leaves no authenticated local state', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final secureStore = _MemorySecureStore();
    final api = _RegistrationApi()..failRegister = true;
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: secureStore,
          )
          ..api = api
          ..instance = const InstanceInfo(
            instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            protocolVersion: 1,
            setupRequired: true,
            capabilities: ['ciphertext_sync', 'snapshots'],
          );
    try {
      await expectLater(
        app.register(
          username: 'owner@example.test',
          password: 'correct horse battery staple',
          bootstrapToken: 'bootstrap-once',
        ),
        throwsStateError,
      );
      expect(app.session, isNull);
      expect(app.identity, isNull);
      expect(app.stage, ClientStage.server);
      expect(secureStore.savedDeviceJson, isNull);
    } finally {
      app.dispose();
      await database.close();
    }
  });
}

Future<_RegisteredSyncHarness> _createRegisteredSyncHarness(
  SodiumSumo sodium, {
  _MemorySecureStore? secureStoreForTesting,
  DateTime Function()? nowForTesting,
  SshConnectorForTesting? sshConnectorForTesting,
  SshConnectorWithRouteForTesting? sshConnectorWithRouteForTesting,
  KnownHostTrustStatusForTesting? knownHostTrustStatusForTesting,
  Future<List<Map<String, dynamic>>> Function(SyncRepository)?
  loadRecordsForTesting,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final api = _RegistrationApi();
  final secureStore = secureStoreForTesting ?? _MemorySecureStore();
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: secureStore,
          nowForTesting: nowForTesting,
          sshConnectorForTesting: sshConnectorForTesting,
          sshConnectorWithRouteForTesting: sshConnectorWithRouteForTesting,
          knownHostTrustStatusForTesting: knownHostTrustStatusForTesting,
          loadRecordsForTesting: loadRecordsForTesting,
        )
        ..api = api
        ..instance = const InstanceInfo(
          instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          serverSpaceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          generation: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          protocolVersion: 1,
          setupRequired: true,
          capabilities: ['ciphertext_sync', 'snapshots'],
        );
  await app.register(
    username: 'owner@example.test',
    password: 'correct horse battery staple',
    bootstrapToken: 'bootstrap-once',
  );
  await _waitForSyncIdle(app);
  return _RegisteredSyncHarness(
    app: app,
    api: api,
    database: database,
    secureStore: secureStore,
  );
}

class _MembershipRefreshSshConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  SSHClient get client => throw UnimplementedError();

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

Future<Map<String, dynamic>> _installMissedRotationAndCreateEvent(
  AppController app,
  _RegistrationApi api,
  SodiumSumo sodium, {
  required String recordId,
  int eventEpoch = 2,
  int eventMembershipVersion = 2,
  Map<String, Object?>? plaintext,
}) async {
  final identity = app.identity!;
  final previousEntry = api.membershipRecords.last;
  final previousPayload = <String, Object?>{
    'vault_id': api.vaultId,
    'membership_version': previousEntry['membership_version'],
    'previous_digest': previousEntry['previous_digest'],
    'manifest': previousEntry['manifest'],
  };
  final previousDigestBytes = await cryptography.Sha256().hash(
    utf8.encode(canonicalJson(previousPayload)),
  );
  final previousDigest = previousDigestBytes.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final nextKey = sodium.randombytes.buf(32);
  try {
    final nextNameEnvelope = await app.crypto.encryptVaultName(
      vaultId: api.vaultId,
      vaultKey: nextKey,
      name: 'Operations',
    );
    final nextManifest = <String, Object?>{
      ...api.membershipManifest,
      'key_epoch': 2,
      'display_name_envelope': nextNameEnvelope,
    };
    final nextMembership = app.crypto.createMembershipGrant(
      vaultId: api.vaultId,
      membershipVersion: api.activeMembershipVersion + 1,
      previousDigest: previousDigest,
      manifest: nextManifest,
      signer: identity,
    );
    final nextKeyEnvelope = app.crypto.createDeviceKeyEnvelope(
      vaultId: api.vaultId,
      vaultKey: nextKey,
      keyEpoch: 2,
      membershipVersion: api.activeMembershipVersion + 1,
      recipientDeviceId: identity.deviceId,
      recipientEncryptionPublicKey: identity.encryption.publicKey,
      signer: identity,
    );
    final signedKeyEnvelope = {
      ...Map<String, dynamic>.from(nextKeyEnvelope),
      'signer_device_id': identity.deviceId,
    };
    api.deviceEnvelopes[identity.deviceId] = [
      ...?api.deviceEnvelopes[identity.deviceId],
      signedKeyEnvelope,
    ];
    api.keyEnvelope = signedKeyEnvelope;
    api.nameEnvelope = Map<String, dynamic>.from(nextNameEnvelope);
    api.activeEpoch = 2;
    api.activeMembershipVersion++;
    api.membershipManifest = Map<String, dynamic>.from(nextManifest);
    api.membershipSignature = nextMembership['signature']! as String;
    api.membershipRecords = [
      ...api.membershipRecords,
      {
        'membership_version': api.activeMembershipVersion,
        'previous_digest': previousDigest,
        'manifest': api.membershipManifest,
        'signature': api.membershipSignature,
        'signer_device_id': identity.deviceId,
      },
    ];

    final eventEnvelope = await app.crypto.encryptRecord(
      vaultKey: nextKey,
      serverSpaceId: app.instance!.serverSpaceId,
      vaultId: api.vaultId,
      recordId: recordId,
      baseRevisionId: null,
      deviceId: identity.deviceId,
      deviceSequence: '17',
      keyEpoch: '$eventEpoch',
      membershipVersion: '$eventMembershipVersion',
      operation: 'create',
      plaintext:
          plaintext ??
          {'id': recordId, 'type': 'host', 'name': 'Rotated remote'},
      identity: identity,
    );
    final eventHeader = Map<String, dynamic>.from(
      eventEnvelope['header']! as Map,
    );
    return {
      'commit_seq': '1',
      'event_type': eventHeader['operation'],
      'record_id': eventHeader['record_id'],
      'revision_id': eventHeader['revision_id'],
      'envelope': eventEnvelope,
    };
  } finally {
    nextKey.fillRange(0, nextKey.length, 0);
  }
}

class _RegisteredSyncHarness {
  const _RegisteredSyncHarness({
    required this.app,
    required this.api,
    required this.database,
    required this.secureStore,
  });

  final AppController app;
  final _RegistrationApi api;
  final ClientDatabase database;
  final _MemorySecureStore secureStore;
}

Future<void> _installRotationMembershipFixture(
  AppController app,
  _RegistrationApi api,
  SodiumSumo sodium, {
  required DeviceIdentity editorDeviceOne,
  required DeviceIdentity editorDeviceTwo,
  required DeviceIdentity pendingDevice,
}) async {
  final ownerIdentity = app.identity!;

  Future<String> fingerprint(DeviceIdentity identity) async => encodeBase64Url(
    (await cryptography.Sha256().hash(identity.encryption.publicKey)).bytes,
  );

  Map<String, dynamic> directoryEntry(
    DeviceIdentity identity,
    String accountId,
    String name,
  ) => {
    ...identity.registrationProof(sodium, accountId: accountId, name: name),
    'user_id': accountId,
    'status': 'active',
    'created_at': '2026-09-27T00:00:00Z',
  };

  final ownerMember = Map<String, Object?>.from(
    (api.membershipManifest['members']! as List).single as Map,
  );
  final editor = <String, Object?>{
    'user_id': _editorAccountId,
    'role': 'editor',
    'state': 'active',
    'encryption_key_fingerprint': await fingerprint(editorDeviceOne),
  };
  final pending = <String, Object?>{
    'user_id': _pendingAccountId,
    'role': 'editor',
    // The signed grant is active as the server models a pending invitation;
    // the ACL remains invited until its token is redeemed.
    'state': 'active',
    'encryption_key_fingerprint': await fingerprint(pendingDevice),
  };
  final manifest = Map<String, Object?>.from(api.membershipManifest)
    ..['members'] = [ownerMember, editor, pending]
    ..['signer_device_id'] = ownerIdentity.deviceId;
  final signed = app.crypto.createMembershipGrant(
    vaultId: api.vaultId,
    membershipVersion: 1,
    previousDigest: null,
    manifest: manifest,
    signer: ownerIdentity,
  );

  api.membershipManifest = manifest.cast<String, dynamic>();
  api.membershipSignature = signed['signature']! as String;
  api.membershipRecords = [
    {
      'membership_version': 1,
      'previous_digest': null,
      'manifest': api.membershipManifest,
      'signature': api.membershipSignature,
      'signer_device_id': ownerIdentity.deviceId,
    },
  ];
  api.members = [
    {
      'user_id': api.accountId,
      'username': api.userName,
      'role': 'owner',
      'state': 'active',
    },
    {
      'user_id': _editorAccountId,
      'username': 'editor@example.test',
      'role': 'editor',
      'state': 'active',
    },
    {
      'user_id': _pendingAccountId,
      'username': 'pending@example.test',
      'role': 'editor',
      'state': 'invited',
    },
  ];
  api.additionalMembers = api.members.skip(1).toList(growable: false);
  api.additionalDevices = [
    directoryEntry(editorDeviceOne, _editorAccountId, 'Editor browser'),
    directoryEntry(editorDeviceTwo, _editorAccountId, 'Editor desktop'),
    directoryEntry(pendingDevice, _pendingAccountId, 'Pending browser'),
  ];
  api.activeEpoch = 1;
  api.activeMembershipVersion = 1;
}

Future<void> _waitForSyncIdle(AppController app) async {
  for (var attempt = 0; app.syncing && attempt < 200; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    app.syncing,
    isFalse,
    reason:
        'registration starts automatic sync; wait until it is idle before rotation',
  );
}

Future<void> _waitForCondition(
  bool Function() condition, {
  required String reason,
}) async {
  for (var attempt = 0; !condition() && attempt < 200; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

class _MemorySecureStore extends ClientSecureStore {
  String? savedLastServer;
  String? savedDeviceJson;
  String? savedPendingJson;
  String? savedPendingAccountId;
  String? savedPendingApproval;
  SessionCredentials? savedSessionCredentials;
  Completer<void>? terminalHistorySyncReadEntered;
  Completer<void>? terminalHistorySyncReadRelease;
  bool failPendingRecoveryLoad = false;
  final Map<String, PendingAccountRecoveryStorageData>
  pendingRecoveryByBaseUrl = {};
  String? blockedPendingRecoveryBaseUrl;
  Completer<void>? pendingRecoveryReadEntered;
  Completer<void>? pendingRecoveryReadRelease;

  @override
  Future<void> saveLastServer(String baseUrl) async {
    savedLastServer = baseUrl;
  }

  @override
  Future<PendingAccountRecoveryStorageData?> loadPendingFullAccountRecovery(
    String baseUrl,
  ) async {
    if (failPendingRecoveryLoad) {
      throw StateError('synthetic pending recovery storage failure');
    }
    if (blockedPendingRecoveryBaseUrl == baseUrl) {
      blockedPendingRecoveryBaseUrl = null;
      final entered = pendingRecoveryReadEntered;
      final release = pendingRecoveryReadRelease;
      pendingRecoveryReadEntered = null;
      pendingRecoveryReadRelease = null;
      if (entered != null && !entered.isCompleted) entered.complete();
      if (release != null) await release.future;
    }
    return pendingRecoveryByBaseUrl[baseUrl];
  }

  @override
  Future<bool> terminalHistorySyncEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required String vaultId,
  }) async {
    final entered = terminalHistorySyncReadEntered;
    final release = terminalHistorySyncReadRelease;
    terminalHistorySyncReadEntered = null;
    terminalHistorySyncReadRelease = null;
    if (entered != null && release != null) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return false;
  }

  @override
  Future<void> saveDevice(String baseUrl, DeviceIdentity identity) async {
    savedDeviceJson = jsonEncode(identity.toStorageJson());
  }

  @override
  Future<DeviceIdentity?> loadDevice(String baseUrl, VaultCrypto crypto) async {
    final stored = savedDeviceJson;
    if (stored == null) return null;
    return DeviceIdentity.fromStorage(
      crypto.sodium,
      Map<String, dynamic>.from(jsonDecode(stored) as Map),
    );
  }

  @override
  Future<DeviceIdentity?> loadPendingDevice(
    String baseUrl,
    VaultCrypto crypto,
  ) async {
    final stored = savedPendingJson;
    if (stored == null) return null;
    return DeviceIdentity.fromStorage(
      crypto.sodium,
      Map<String, dynamic>.from(jsonDecode(stored) as Map),
    );
  }

  @override
  Future<String?> pendingAccountId(String baseUrl) async =>
      savedPendingAccountId;

  @override
  Future<void> savePendingDeviceApproval(
    String baseUrl,
    String approvalJson,
  ) async {
    savedPendingApproval = approvalJson;
  }

  @override
  Future<String?> pendingDeviceApproval(String baseUrl) async =>
      savedPendingApproval;

  @override
  Future<void> clearPendingDeviceApproval(String baseUrl) async {
    savedPendingApproval = null;
  }

  @override
  Future<void> clearPendingDevice(String baseUrl) async {
    savedPendingJson = null;
    savedPendingAccountId = null;
  }

  @override
  Future<void> saveRefreshToken(
    String baseUrl,
    String username,
    String token,
  ) async {}

  @override
  Future<void> saveSessionSnapshot(
    String baseUrl,
    String username,
    SessionCredentials credentials,
  ) async {
    savedSessionCredentials = credentials;
  }

  @override
  Future<SessionSnapshotRead> readSessionSnapshot(
    String baseUrl,
    String username,
    String deviceId,
  ) async {
    final credentials = savedSessionCredentials;
    if (credentials == null || credentials.deviceId != deviceId) {
      return const SessionSnapshotRead.missing();
    }
    return SessionSnapshotRead.ready(credentials);
  }

  @override
  Future<void> savePendingDevice(
    String baseUrl,
    DeviceIdentity identity, {
    required String accountId,
  }) async {
    savedPendingJson = jsonEncode(identity.toStorageJson());
    savedPendingAccountId = accountId;
  }
}

class _RegistrationApi extends ApiClient {
  _RegistrationApi() : super(baseUrl: 'https://registration.test');

  bool failRegister = false;
  bool hideAllVaults = false;
  Map<String, Object?>? initialVaultPayload;
  Map<String, Object?>? registrationDevice;
  Map<String, Object?>? accountKeyEnvelope;
  Map<String, dynamic>? registeredDeviceBody;
  Map<String, dynamic>? enrolledDevice;
  Map<String, dynamic>? delayedSignerOnFirstChange;
  bool exposeDelayedSignerOnNextChanges = false;
  String accountId = '';
  String ownerAccountId = '';
  String vaultId = '';
  String deviceId = '';
  String currentDeviceId = '';
  Map<String, Object?>? registrationKdf;
  int transferCalls = 0;
  String? userName;
  String? membershipSignature;
  Map<String, dynamic> membershipManifest = const {};
  Map<String, dynamic> nameEnvelope = const {};
  Map<String, dynamic> keyEnvelope = const {};
  List<Map<String, dynamic>> membershipRecords = [];
  final Map<String, List<Map<String, dynamic>>> membershipRecordsByVault = {};
  List<Map<String, dynamic>> members = [];
  List<Map<String, dynamic>> additionalMembers = [];
  List<Map<String, dynamic>> additionalDevices = [];
  List<Map<String, dynamic>> lastRotationEnvelopes = [];
  final Map<String, List<Map<String, dynamic>>> deviceEnvelopes = {};
  bool failRotationBeforeCommit = false;
  bool omitCurrentDeviceEnvelopes = false;
  bool failSignerDirectoryReads = false;
  bool loseNextPushResponse = false;
  bool failNextPush = false;
  final Set<String> knownVaultIds = {};
  final Set<String> failPushVaultIds = {};
  final List<Map<String, dynamic>> pushRequestSummaries = [];
  ApiException? failNextChanges;
  bool expireNextChanges = false;
  bool serverCanWrite = true;
  bool corruptMembershipSignature = false;
  final List<Map<String, dynamic>> pushedOperations = [];
  final List<Map<String, dynamic>> pendingChangeEvents = [];
  final List<String?> requestedChangeCursors = [];
  final List<String> controlPlaneCallOrder = [];
  Completer<void>? nextChangesEntered;
  Completer<void>? nextChangesRelease;
  String? nextChangesVaultId;
  ApiException? failHeldChangesAfterRelease;
  Completer<void>? nextVaultsEntered;
  Completer<void>? nextVaultsRelease;
  bool snapshotVaultsBeforeNextWait = false;
  Completer<void>? acceptInvitationEntered;
  Completer<void>? acceptInvitationRelease;
  int deviceDirectoryReads = 0;
  int vaultListReads = 0;
  int vaultDeviceDirectoryReads = 0;
  int membershipReads = 0;
  int vaultMembersReads = 0;
  int rotationWrites = 0;
  Exception? failNextVaultList;
  int? failVaultListAtRead;
  int pushCalls = 0;
  int changeReads = 0;
  final List<String> requestedChangeVaultIds = [];
  String pendingChangeCursor = 'rotation-cursor';
  var _nextCommitSequence = 0;
  int activeEpoch = 1;
  int activeMembershipVersion = 1;
  late final List<VaultDescriptor> registeredResponseVaults = [
    VaultDescriptor(
      id: vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
    ),
  ];

  @override
  Future<AuthSession> register({
    required String accountId,
    required String username,
    String? bootstrapToken,
    String? instanceInvitationToken,
    required Map<String, Object?> kdf,
    required String loginVerifier,
    required Map<String, Object?> accountKeyEnvelope,
    required Map<String, Object?> device,
    required Map<String, Object?> initialVault,
  }) async {
    if (failRegister) throw StateError('synthetic register failure');
    this.accountId = accountId;
    ownerAccountId = accountId;
    userName = username;
    this.accountKeyEnvelope = accountKeyEnvelope;
    registrationKdf = Map<String, Object?>.from(kdf);
    registrationDevice = device;
    initialVaultPayload = initialVault;
    vaultId = initialVault['vault_id']! as String;
    knownVaultIds.add(vaultId);
    deviceId = device['device_id']! as String;
    currentDeviceId = deviceId;
    nameEnvelope = Map<String, dynamic>.from(
      initialVault['name_envelope']! as Map,
    );
    final rawKey = Map<String, dynamic>.from(
      initialVault['key_envelope']! as Map,
    );
    keyEnvelope = {...rawKey, 'signer_device_id': deviceId};
    deviceEnvelopes[deviceId] = [Map<String, dynamic>.from(keyEnvelope)];
    final membership = Map<String, dynamic>.from(
      initialVault['membership']! as Map,
    );
    membershipSignature = membership['signature']! as String;
    membershipManifest = Map<String, dynamic>.from(
      membership['manifest']! as Map,
    );
    activeEpoch = 1;
    activeMembershipVersion = 1;
    members = [
      {
        'user_id': accountId,
        'username': username,
        'role': 'owner',
        'state': 'active',
      },
      ...additionalMembers,
    ];
    membershipRecords = [
      {
        'vault_id': vaultId,
        'membership_version': 1,
        'previous_digest': null,
        'manifest': membershipManifest,
        'signature': membershipSignature,
        'signer_device_id': deviceId,
      },
    ];
    membershipRecordsByVault[vaultId] = membershipRecords
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
    accessToken = 'access-token';
    return AuthSession(
      accountId: accountId,
      accessToken: accessToken!,
      expiresIn: 900,
      refreshToken: 'refresh-token',
      deviceId: deviceId,
      vaults: registeredResponseVaults,
    );
  }

  @override
  Future<AccountProfile> accountProfile() async => AccountProfile(
    accountId: accountId,
    deviceId: currentDeviceId,
    accountKeyEnvelopeVersion: 1,
    accountKeyEnvelope: Map<String, dynamic>.from(accountKeyEnvelope!),
  );

  Map<String, dynamic> get _deviceDto => {
    'device_id': deviceId,
    'user_id': accountId,
    'name': 'Registration device',
    'signing_public_key': registrationDevice!['signing_public_key'],
    'encryption_public_key': registrationDevice!['encryption_public_key'],
    'signature': registrationDevice!['signature'],
    'status': 'active',
    'created_at': '2026-09-27T00:00:00Z',
  };

  Map<String, dynamic>? get _enrolledDeviceDto {
    final device = enrolledDevice;
    if (device == null) return null;
    return {
      'device_id': device['device_id'],
      'user_id': accountId,
      'name': device['name'],
      'signing_public_key': device['signing_public_key'],
      'encryption_public_key': device['encryption_public_key'],
      'signature': device['signature'],
      'status': 'active',
      'created_at': '2026-09-27T00:00:01Z',
    };
  }

  @override
  Future<List<Map<String, dynamic>>> devices() async {
    deviceDirectoryReads++;
    controlPlaneCallOrder.add('devices');
    if (failSignerDirectoryReads) {
      throw const ApiTransportException(method: 'GET', path: '/api/v1/devices');
    }
    return [_deviceDto, if (_enrolledDeviceDto case final enrolled?) enrolled];
  }

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String id) async {
    vaultDeviceDirectoryReads++;
    controlPlaneCallOrder.add('vaultDevices');
    if (failSignerDirectoryReads) {
      throw ApiTransportException(
        method: 'GET',
        path: '/api/v1/vaults/$id/devices',
      );
    }
    expect(knownVaultIds, contains(id));
    return [
      _deviceDto,
      if (_enrolledDeviceDto case final enrolled?) enrolled,
      ...additionalDevices,
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> vaultMembers(String id) async {
    expect(knownVaultIds, contains(id));
    vaultMembersReads++;
    return members.map((member) => Map<String, dynamic>.from(member)).toList();
  }

  @override
  Future<List<VaultDescriptor>> vaults() async {
    vaultListReads++;
    controlPlaneCallOrder.add('vaults');
    if (failVaultListAtRead == vaultListReads) {
      failVaultListAtRead = null;
      throw const ApiTransportException(method: 'GET', path: '/api/v1/vaults');
    }
    final failure = failNextVaultList;
    if (failure != null) {
      failNextVaultList = null;
      throw failure;
    }
    final entered = nextVaultsEntered;
    final release = nextVaultsRelease;
    if (entered != null && release != null) {
      nextVaultsEntered = null;
      nextVaultsRelease = null;
      final snapshot = snapshotVaultsBeforeNextWait
          ? _currentVaultsSnapshot()
          : null;
      snapshotVaultsBeforeNextWait = false;
      entered.complete();
      await release.future;
      return snapshot ?? _currentVaultsSnapshot();
    }
    return _currentVaultsSnapshot();
  }

  List<VaultDescriptor> _currentVaultsSnapshot() => [
    if (!hideAllVaults)
      VaultDescriptor(
        id: vaultId,
        role: ownerAccountId == accountId ? 'owner' : 'editor',
        activeKeyEpoch: '$activeEpoch',
        membershipVersion: '$activeMembershipVersion',
        encryptedDisplayNameEnvelope: nameEnvelope,
        keyEnvelopes: omitCurrentDeviceEnvelopes
            ? const []
            : deviceEnvelopes[currentDeviceId] ??
                  (currentDeviceId == deviceId ? [keyEnvelope] : const []),
        canWrite: serverCanWrite,
      ),
  ];

  @override
  Future<Map<String, dynamic>> createVault(Map<String, Object?> body) async {
    hideAllVaults = false;
    vaultId = body['vault_id']! as String;
    knownVaultIds.add(vaultId);
    ownerAccountId = accountId;
    nameEnvelope = Map<String, dynamic>.from(body['name_envelope']! as Map);
    final membership = Map<String, dynamic>.from(body['membership']! as Map);
    membershipManifest = Map<String, dynamic>.from(
      membership['manifest']! as Map,
    );
    membershipSignature = membership['signature']! as String;
    activeEpoch = 1;
    activeMembershipVersion = 1;
    final rawKey = Map<String, dynamic>.from(body['key_envelope']! as Map);
    keyEnvelope = {...rawKey, 'signer_device_id': currentDeviceId};
    deviceEnvelopes[currentDeviceId] = [Map<String, dynamic>.from(keyEnvelope)];
    membershipRecords = [
      {
        'vault_id': vaultId,
        'membership_version': 1,
        'previous_digest': null,
        'manifest': membershipManifest,
        'signature': membershipSignature,
        'signer_device_id': currentDeviceId,
      },
    ];
    membershipRecordsByVault[vaultId] = membershipRecords
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
    members = [
      {
        'user_id': accountId,
        'username': userName,
        'role': 'owner',
        'state': 'active',
      },
    ];
    return {
      'vault_id': vaultId,
      'role': 'owner',
      'active_key_epoch': 1,
      'membership_version': 1,
    };
  }

  @override
  Future<void> logout() async {
    accessToken = null;
  }

  @override
  Future<Map<String, dynamic>> acceptInvitation(
    String token,
    Map<String, Object?> body,
  ) async {
    final entered = acceptInvitationEntered;
    final release = acceptInvitationRelease;
    if (entered != null && release != null) {
      acceptInvitationEntered = null;
      acceptInvitationRelease = null;
      entered.complete();
      await release.future;
    }
    return {
      'invitation_id': 'synthetic-invitation',
      'vault_id': vaultId,
      'status': 'accepted',
    };
  }

  @override
  Future<Map<String, dynamic>> membership(String id, {int from = 0}) async {
    membershipReads++;
    controlPlaneCallOrder.add('membership');
    expect(knownVaultIds, contains(id));
    final records = id == vaultId
        ? membershipRecords
        : membershipRecordsByVault[id] ?? const <Map<String, dynamic>>[];
    return {
      'manifests': records
          .map((entry) {
            final body = entry['manifest']! as Map<String, dynamic>;
            return {
              ...entry,
              'manifest': {
                'vault_id': id,
                'membership_version': entry['membership_version'],
                'previous_digest': entry['previous_digest'],
                'manifest': body,
                'signature': corruptMembershipSignature
                    ? 'invalid-signature'
                    : entry['signature'],
              },
            };
          })
          .toList(growable: false),
    };
  }

  @override
  Future<Map<String, dynamic>> rotateVaultKey(
    String id,
    Map<String, Object?> body,
  ) async {
    expect(id, vaultId);
    rotationWrites++;
    if (failRotationBeforeCommit) {
      throw StateError('synthetic server rejected rotation before commit');
    }
    final membership = Map<String, dynamic>.from(body['membership']! as Map);
    final manifest = Map<String, dynamic>.from(membership['manifest']! as Map);
    final nextEpoch = body['new_epoch']! as int;
    final nextVersion = membership['membership_version']! as int;
    final envelopes = (body['key_envelopes']! as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    lastRotationEnvelopes = envelopes;
    for (final envelope in envelopes) {
      final recipientId = envelope['recipient_device_id']! as String;
      deviceEnvelopes[recipientId] = [
        ...?deviceEnvelopes[recipientId],
        {...envelope, 'signer_device_id': deviceId},
      ];
    }
    keyEnvelope = envelopes.singleWhere(
      (item) => item['recipient_device_id'] == deviceId,
    );
    nameEnvelope = Map<String, dynamic>.from(
      manifest['display_name_envelope']! as Map,
    );
    activeEpoch = nextEpoch;
    activeMembershipVersion = nextVersion;
    membershipManifest = manifest;
    membershipSignature = membership['signature']! as String;
    membershipRecords = [
      ...membershipRecords,
      {
        'membership_version': nextVersion,
        'previous_digest': membership['previous_digest'],
        'manifest': manifest,
        'signature': membershipSignature,
        'signer_device_id': deviceId,
      },
    ];
    membershipRecordsByVault[vaultId] = membershipRecords
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
    final signedMembers = (manifest['members']! as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    members = members
        .map((member) {
          final signed = signedMembers.singleWhere(
            (item) => item['user_id'] == member['user_id'],
          );
          final signedState = signed['state'] as String;
          return {
            ...member,
            'role': signed['role'],
            'state': member['state'] == 'invited' && signedState == 'active'
                ? 'invited'
                : signedState,
          };
        })
        .toList(growable: false);
    return {
      'vault_id': vaultId,
      'active_key_epoch': activeEpoch,
      'membership_version': activeMembershipVersion,
      'owner_user_id': ownerAccountId,
      'status': 'active',
    };
  }

  @override
  Future<Map<String, dynamic>> transferVaultOwnership(
    String id,
    Map<String, Object?> body,
  ) async {
    expect(id, vaultId);
    transferCalls++;
    if (failRotationBeforeCommit) {
      throw StateError('synthetic server rejected transfer before commit');
    }
    final newOwner = body['new_owner_user_id']! as String;
    final result = await rotateVaultKey(id, body);
    ownerAccountId = newOwner;
    return {...result, 'owner_user_id': ownerAccountId};
  }

  @override
  Future<Map<String, dynamic>> prelogin(String username) async => {
    'account_id': accountId,
    'kdf': registrationKdf ?? KdfParameters(salt: Uint8List(16)).toJson(),
  };

  @override
  Future<Map<String, dynamic>> registerDevice(Map<String, Object?> body) async {
    registeredDeviceBody = Map<String, dynamic>.from(body);
    enrolledDevice = Map<String, dynamic>.from(body['device']! as Map);
    final targetId = enrolledDevice!['device_id']! as String;
    deviceEnvelopes[targetId] = (body['vault_key_envelopes']! as List)
        .map(
          (item) => {
            ...Map<String, dynamic>.from(item as Map),
            'signer_device_id': body['approver_device_id'],
          },
        )
        .toList(growable: false);
    return {
      'device_id': targetId,
      'status': 'active',
      'vault_key_envelope_count': deviceEnvelopes[targetId]!.length,
    };
  }

  @override
  Future<AuthLoginResult> login({
    required String username,
    required String loginVerifier,
    required String deviceId,
  }) async {
    currentDeviceId = deviceId;
    accessToken = 'access-token-$deviceId';
    return AuthenticatedLogin(
      AuthSession(
        accountId: accountId,
        accessToken: accessToken!,
        expiresIn: 900,
        refreshToken: 'refresh-token-$deviceId',
        deviceId: deviceId,
        vaults: const [],
      ),
    );
  }

  Future<void> installPostEnrollmentRotation({
    required Map<String, Object?> membership,
    required Map<String, Object?> manifest,
    required Map<String, Object?> nameEnvelope,
    required Map<String, Object?> keyEnvelope,
    required String recipientDeviceId,
  }) async {
    final version = membership['membership_version']! as int;
    final signature = membership['signature']! as String;
    membershipManifest = Map<String, dynamic>.from(manifest);
    membershipSignature = signature;
    activeEpoch = manifest['key_epoch']! as int;
    activeMembershipVersion = version;
    this.nameEnvelope = Map<String, dynamic>.from(nameEnvelope);
    membershipRecords = [
      ...membershipRecords,
      {
        'membership_version': version,
        'previous_digest': membership['previous_digest'],
        'manifest': manifest,
        'signature': signature,
        'signer_device_id': deviceId,
      },
    ];
    deviceEnvelopes[recipientDeviceId] = [
      ...deviceEnvelopes[recipientDeviceId]!,
      {...keyEnvelope, 'signer_device_id': deviceId},
    ];
  }

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
    serverGeneration:
        serverGeneration ?? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );

  @override
  Future<SyncPage> changes(String id, {String? cursor, int limit = 500}) async {
    expect(knownVaultIds, contains(id));
    controlPlaneCallOrder.add('changes');
    requestedChangeCursors.add(cursor);
    requestedChangeVaultIds.add(id);
    changeReads++;
    final failure = failNextChanges;
    if (failure != null) {
      failNextChanges = null;
      throw failure;
    }
    final entered = nextChangesEntered;
    final release = nextChangesRelease;
    if (entered != null &&
        release != null &&
        (nextChangesVaultId == null || nextChangesVaultId == id)) {
      nextChangesEntered = null;
      nextChangesRelease = null;
      nextChangesVaultId = null;
      entered.complete();
      await release.future;
      final heldFailure = failHeldChangesAfterRelease;
      failHeldChangesAfterRelease = null;
      if (heldFailure != null) throw heldFailure;
    }
    final delayedSigner = delayedSignerOnFirstChange;
    if (exposeDelayedSignerOnNextChanges && delayedSigner != null) {
      additionalDevices.add(delayedSigner);
      delayedSignerOnFirstChange = null;
      exposeDelayedSignerOnNextChanges = false;
    }
    if (expireNextChanges) {
      expireNextChanges = false;
      throw const ApiException(
        statusCode: 410,
        code: 'CURSOR_EXPIRED',
        message: 'synthetic expired cursor',
      );
    }
    if (pendingChangeEvents.isNotEmpty && cursor != pendingChangeCursor) {
      return SyncPage(
        events: pendingChangeEvents
            .map((event) {
              final envelope = Map<String, dynamic>.from(
                event['envelope']! as Map,
              );
              final header = Map<String, dynamic>.from(
                envelope['header']! as Map,
              );
              return {
                'commit_seq': event['commit_seq'],
                'event_type': event['event_type'] ?? header['operation'],
                'record_id': event['record_id'] ?? header['record_id'],
                'revision_id': event['revision_id'] ?? header['revision_id'],
                'envelope': envelope,
              };
            })
            .toList(growable: false),
        nextCursor: pendingChangeCursor,
        hasMore: false,
        serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
    }
    return SyncPage(
      events: const [],
      nextCursor: cursor,
      hasMore: false,
      serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );
  }

  @override
  Future<Map<String, dynamic>> push(
    String id,
    Map<String, Object?> batch,
  ) async {
    pushCalls++;
    controlPlaneCallOrder.add('push');
    expect(knownVaultIds, contains(id));
    final operations = (batch['operations']! as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    pushRequestSummaries.add({
      'routeVaultId': id,
      'bodyVaultId': batch['vault_id'],
      'recordIds': operations
          .map((item) => (item['header']! as Map)['record_id'])
          .toList(growable: false),
    });
    if (failNextPush || failPushVaultIds.contains(id)) {
      failNextPush = false;
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'synthetic unrelated operation outage',
      );
    }
    pushedOperations.addAll(operations);
    if (loseNextPushResponse) {
      loseNextPushResponse = false;
      throw StateError(
        'synthetic response lost after the server accepted the batch',
      );
    }
    return {
      'batch_id': batch['batch_id'],
      'results': operations
          .map((operation) {
            final header = operation['header'] as Map;
            return {
              'op_id': header['op_id'],
              'revision_id': header['revision_id'],
              'commit_seq': '${++_nextCommitSequence}',
              'already_committed': false,
            };
          })
          .toList(growable: false),
    };
  }
}
