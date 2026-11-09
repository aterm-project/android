import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/terminal/terminal_collaboration_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SSH restore reuses the same tab, scrollback and order without replaying input', () async {
    final connections = <_RecordingConnection>[];
    final fixture = await _Fixture.create(
      connector:
          ({required host, required credential, required verifyHostKey}) async {
            final connection = _RecordingConnection();
            connections.add(connection);
            return connection;
          },
    );
    final app = fixture.app;
    try {
      await app.openTerminalTab(_host('host-a', 'Alpha'));
      final tab = app.activeTerminalTab!;
      connections.single.emit('original scrollback');
      await connections.single.finishOutput();
      await Future<void>.delayed(Duration.zero);
      expect(tab.state, 'disconnected');
      expect(tab.recovery!.interrupted, isTrue);
      await tab.recovery!.retry();
      expect(connections, hasLength(2));
      expect(app.activeTerminalTab, same(tab));
      expect(app.terminalTabs, [tab]);
      expect(tab.state, 'connected');
      expect(tab.terminal.buffer.getText(), contains('original scrollback'));
      expect(connections.last.inputs, isEmpty);
    } finally {
      await app.closeWorkspace();
      await fixture.database.close();
    }
  });


  test('legacy SFTP compatibility caps reads and rejects oversize before a save picker', () async {
    const limit = 16 * 1024 * 1024;
    final file = _CompatibilitySftpFile(Uint8List(limit + 1)..fillRange(0, limit + 1, 7));
    final sftp = _CompatibilitySftpClient(file);
    final fixture = await _Fixture.create(connector: ({required host, required credential, required verifyHostKey}) async => _RecordingConnection(sftpClient: sftp));
    try {
      await fixture.app.openTerminalTab(_host('host-a', 'Alpha'));
      await expectLater(fixture.app.downloadSftpFile('file.bin',
        remotePath: '/explicit/path/file.bin', maximumBytes: limit), throwsFormatException);
      expect(sftp.path, '/explicit/path/file.bin');
      expect(file.requestedLength, limit + 1);
      expect(file.closed, isTrue);
      expect(file.bytes.every((byte) => byte == 0), isTrue);
      await expectLater(fixture.app.downloadSftpFile('file.bin', maximumBytes: limit + 1), throwsFormatException);
    } finally {
      await fixture.app.closeWorkspace();
      await fixture.database.close();
    }
  });

  test('cloud session logs are bound to account/Vault scope', () async {
    final connections = <_RecordingConnection>[];
    final fixture = await _Fixture.create(
      connector: ({required host, required credential, required verifyHostKey}) async {
        final connection = _RecordingConnection();
        connections.add(connection);
        return connection;
      },
    );
    final app = fixture.app;
    try {
      app.activeVault = const VaultDescriptor(
        id: 'vault-logs-a',
        role: 'owner',
        activeKeyEpoch: 'epoch',
        membershipVersion: 'membership',
      );
      final book = app.sessionLogs;
      await book.setRecordTranscripts(true);
      await app.openTerminalTab(_host('host-a', 'Alpha'));
      expect(app.sessionLogs.entries.single.status, SessionLogStatus.connected);
      connections.single.emit('output from vault A');

      // Vault switch: old rows/transcripts are not visible in the new scope.
      app.activeVault = const VaultDescriptor(
        id: 'vault-logs-b',
        role: 'owner',
        activeKeyEpoch: 'epoch',
        membershipVersion: 'membership',
      );
      final next = app.sessionLogs;
      expect(identical(next, book), isFalse);
      expect(next.entries, isEmpty);

      // The old session ends later (delayed callback): it must not
      // repopulate the new scope.
      await connections.single.finishOutput();
      await Future<void>.delayed(Duration.zero);
      expect(app.sessionLogs.entries, isEmpty);

      // Account switch on the same device also starts a fresh journal.
      final row = next.begin(host: _host('host-b', 'Beta'));
      row.markClosed(SessionLogEndReason.user);
      app.session = AuthSession(
        accountId: 'account-other',
        accessToken: 'access-other',
        expiresIn: 3600,
        refreshToken: 'refresh-other',
        deviceId: app.identity!.deviceId,
        vaults: const [],
      );
      expect(app.sessionLogs.entries, isEmpty);
    } finally {
      await app.closeWorkspace();
      await fixture.database.close();
    }
  });

  test(
    'reorder and detached ownership preserve SSH while locked owner rejects input',
    () async {
      final connections = <String, _RecordingConnection>{};
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              final connection = _RecordingConnection();
              connections[host.id] = connection;
              return connection;
            },
      );
      final app = fixture.app;
      try {
        await app.openTerminalTab(_host('host-a', 'Alpha'));
        final alpha = app.activeTerminalTab!;
        await app.openTerminalTab(_host('host-b', 'Beta'));
        final beta = app.activeTerminalTab!;
        app.reorderTerminalTab(beta.id, alpha.id);
        expect(app.terminalTabs.map((tab) => tab.id), [beta.id, alpha.id]);
        app.markTerminalDetached(beta.id, true);
        expect(app.visibleTerminalTabs.map((tab) => tab.id), [alpha.id]);
        expect(app.activeTerminalTabId, alpha.id);
        expect(connections['host-b']!.closeCount, 0);
        connections['host-b']!.emit('background remains live');
        expect(
          beta.terminal.history.join(),
          contains('background remains live'),
        );
        app.activateTerminalTab(beta.id);
        app.showWorkspacePage(WorkspacePage.sftp);
        expect(app.activeTerminalTabId, beta.id);
        app.showWorkspacePage(WorkspacePage.terminal);
        expect(app.activeTerminalTabId, alpha.id);
        app.workspaceLocked = true;
        final resizes = connections['host-b']!.resizes.length;
        app.sendTerminalInputFor(beta.id, 'blocked');
        app.resizeTerminalFor(beta.id, 120, 40);
        expect(connections['host-b']!.inputs, isEmpty);
        expect(connections['host-b']!.resizes.length, resizes);
        app.workspaceLocked = false;
        app.markTerminalDetached(beta.id, false);
        expect(app.visibleTerminalTabs, hasLength(2));
        expect(app.activeTerminalTabId, beta.id);
        await app.closeTerminalTab(alpha.id);
        expect(connections['host-a']!.closeCount, 1);
        expect(connections['host-b']!.closeCount, 0);
        expect(
          beta.terminal.history.join(),
          contains('background remains live'),
        );
      } finally {
        await app.closeWorkspace();
        await fixture.database.close();
      }
    },
  );

  test(
    'join adopts an active grant delivered before observer event subscription',
    () async {
      const expectedSessionId = '11111111-1111-4111-8111-111111111111';
      const leaseId = '22222222-2222-4222-8222-222222222222';
      final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final handle = _PreGrantedObserverHandle(
        controllerGrant: TerminalControllerLease(
          leaseId: leaseId,
          controlEpoch: 7,
          expiresAt: expiresAt,
          controllerUserId: '33333333-3333-4333-8333-333333333333',
          controllerDeviceId: '44444444-4444-4444-8444-444444444444',
        ),
      );
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => _RecordingConnection(),
        terminalShareObserverJoinerForTesting: ({required sessionId}) async {
          expect(sessionId, expectedSessionId);
          return handle;
        },
      );
      final app = fixture.app;
      app.activeVault = const VaultDescriptor(
        id: '55555555-5555-4555-8555-555555555555',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      TerminalObserverTabSession? observer;
      try {
        // The injected joiner returns an already-authenticated handle whose
        // grant event was emitted before AppController subscribes.
        observer = await app.joinTerminalShare(expectedSessionId);
        expect(app.terminalShareObserverFor(expectedSessionId), same(observer));
        expect(observer.grantedLeaseId, leaseId);
        expect(observer.grantedControlEpoch, 7);
        expect(observer.grantedControlExpiresAt, expiresAt);
        expect(observer.controlExpiryTimer?.isActive, isTrue);
      } finally {
        if (observer != null) await app.leaveTerminalShare(expectedSessionId);
        observer?.controlExpiryTimer?.cancel();
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'join rejects and clears a controller that closes before attachment',
    () async {
      const sessionId = '11111111-1111-4111-8111-111111111111';
      final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final grant = TerminalControllerLease(
        leaseId: '22222222-2222-4222-8222-222222222222',
        controlEpoch: 8,
        expiresAt: expiresAt,
        controllerUserId: '33333333-3333-4333-8333-333333333333',
        controllerDeviceId: '44444444-4444-4444-8444-444444444444',
      );
      final controller = _DisconnectedControllerSession(
        leaseId: grant.leaseId,
        controlEpoch: grant.controlEpoch,
        expiresAt: expiresAt,
      );
      final handle = _ObserverWithDisconnectedControllerHandle(
        controllerGrant: grant,
        controller: controller,
      );
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => _RecordingConnection(),
        terminalShareObserverJoinerForTesting: ({required sessionId}) async =>
            handle,
      );
      final app = fixture.app;
      app.activeVault = const VaultDescriptor(
        id: '55555555-5555-4555-8555-555555555555',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      TerminalObserverTabSession? observer;
      try {
        observer = await app.joinTerminalShare(sessionId);
        expect(observer.grantedLeaseId, grant.leaseId);

        await expectLater(
          app.joinTerminalShareController(sessionId),
          throwsStateError,
        );

        expect(controller.closeCount, greaterThan(0));
        expect(observer.controller, isNull);
        expect(observer.grantedLeaseId, isNull);
        expect(observer.grantedControlEpoch, isNull);
        expect(observer.controlErrorMessage, isNotNull);
      } finally {
        if (observer != null) await app.leaveTerminalShare(sessionId);
        observer?.controlExpiryTimer?.cancel();
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'observer rejoin clears old output and requires a fresh host grant',
    () async {
      const sessionId = '11111111-1111-4111-8111-111111111111';
      final oldHandle = _PreGrantedObserverHandle(
        controllerGrant: TerminalControllerLease(
          leaseId: '22222222-2222-4222-8222-222222222222',
          controlEpoch: 3,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
          controllerUserId: '33333333-3333-4333-8333-333333333333',
          controllerDeviceId: '44444444-4444-4444-8444-444444444444',
        ),
      );
      final replacementHandle = _PreGrantedObserverHandle(
        controllerGrant: null,
      );
      final handles = <TerminalShareObserverSession>[
        oldHandle,
        replacementHandle,
      ];
      var joinCount = 0;
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => _RecordingConnection(),
        terminalShareObserverJoinerForTesting: ({required sessionId}) async {
          joinCount++;
          return handles.removeAt(0);
        },
      );
      final app = fixture.app;
      app.activeVault = const VaultDescriptor(
        id: '55555555-5555-4555-8555-555555555555',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      TerminalObserverTabSession? observer;
      try {
        observer = await app.joinTerminalShare(sessionId);
        final disconnectedTerminal = observer.terminal;
        oldHandle.emit(TerminalCollaborationEvent.output('BEFORE_REJOIN'));
        expect(
          disconnectedTerminal.buffer.getText(),
          contains('BEFORE_REJOIN'),
        );
        expect(observer.grantedLeaseId, '22222222-2222-4222-8222-222222222222');

        await oldHandle.close();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(observer.state, 'ended');

        await app.reconnectTerminalShare(sessionId);
        expect(joinCount, 2);
        expect(observer.handle, same(replacementHandle));
        expect(observer.terminal, isNot(same(disconnectedTerminal)));
        expect(
          observer.terminal.buffer.getText(),
          isNot(contains('BEFORE_REJOIN')),
        );
        expect(observer.grantedLeaseId, isNull);
        expect(observer.grantedControlEpoch, isNull);
        expect(observer.controlExpiryTimer, isNull);
        expect(observer.state, anyOf('connecting', 'connected'));

        replacementHandle.emit(
          TerminalCollaborationEvent.output('AFTER_REJOIN'),
        );
        expect(observer.terminal.buffer.getText(), contains('AFTER_REJOIN'));
      } finally {
        if (observer != null) await app.leaveTerminalShare(sessionId);
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test('observer rejoin rejects a changed Vault membership snapshot', () async {
    const sessionId = '11111111-1111-4111-8111-111111111111';
    final oldHandle = _PreGrantedObserverHandle(controllerGrant: null);
    final pendingHandle = _PreGrantedObserverHandle(controllerGrant: null);
    final releaseJoin = Completer<void>();
    var joinCount = 0;
    final fixture = await _Fixture.create(
      connector:
          ({
            required host,
            required credential,
            required verifyHostKey,
          }) async => _RecordingConnection(),
      terminalShareObserverJoinerForTesting: ({required sessionId}) async {
        joinCount++;
        if (joinCount == 1) return oldHandle;
        await releaseJoin.future;
        return pendingHandle;
      },
    );
    final app = fixture.app;
    app.activeVault = const VaultDescriptor(
      id: '55555555-5555-4555-8555-555555555555',
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
    );
    TerminalObserverTabSession? observer;
    try {
      observer = await app.joinTerminalShare(sessionId);
      await oldHandle.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final reconnect = app.reconnectTerminalShare(sessionId);
      await Future<void>.delayed(Duration.zero);
      app.activeVault = const VaultDescriptor(
        id: '55555555-5555-4555-8555-555555555555',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '2',
      );
      releaseJoin.complete();
      await expectLater(reconnect, throwsStateError);

      expect(observer.handle, same(oldHandle));
      expect(observer.reconnecting, isFalse);
      expect(observer.state, 'failed');
      expect(observer.grantedLeaseId, isNull);
      expect(observer.errorMessage, contains('共享可能已结束'));
    } finally {
      if (observer != null) await app.leaveTerminalShare(sessionId);
      await pendingHandle.close();
      app.dispose();
      await fixture.database.close();
    }
  });

  test(
    'terminal tabs isolate connection input, output and lifecycle',
    () async {
      final first = _RecordingConnection();
      final firstSftp = _RecordingSftpClient();
      final secondSftp = _RecordingSftpClient();
      final second = _RecordingConnection(sftpClient: secondSftp);
      first.sftpClient = firstSftp;
      final connections = <String, _RecordingConnection>{};
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              final connection = host.id == 'host-a' ? first : second;
              connections[host.id] = connection;
              return connection;
            },
      );
      final app = fixture.app;
      try {
        await app.openTerminalTab(_host('host-a', 'Alpha'));
        final alpha = app.activeTerminalTab!;
        first.emit('\r\nALPHA-OUTPUT\r\n');

        await app.openTerminalTab(_host('host-b', 'Beta'));
        final beta = app.activeTerminalTab!;
        second.emit('\r\nBETA-OUTPUT\r\n');
        first.emit('\r\nALPHA-LATER\r\n');
        await Future<void>.delayed(Duration.zero);

        expect(app.activeTerminalTabId, beta.id);
        expect(app.terminalTabs.map((tab) => tab.host?.name), [
          'Alpha',
          'Beta',
        ]);
        expect(_bufferText(alpha), contains('ALPHA-OUTPUT'));
        expect(_bufferText(alpha), contains('ALPHA-LATER'));
        expect(_bufferText(alpha), isNot(contains('BETA-OUTPUT')));
        expect(_bufferText(beta), contains('BETA-OUTPUT'));
        expect(_bufferText(beta), isNot(contains('ALPHA-OUTPUT')));

        await app.makeSftpDirectory('created-on-alpha', sessionId: alpha.id);
        expect(firstSftp.mkdirPaths, ['/created-on-alpha']);
        expect(secondSftp.mkdirPaths, isEmpty);
        expect(firstSftp.listdirPaths, ['/']);

        alpha.terminal.onOutput?.call('alpha input');
        alpha.terminal.onResize?.call(101, 37, 0, 0);
        beta.terminal.onOutput?.call('beta input');
        beta.terminal.onResize?.call(132, 42, 0, 0);
        expect(first.inputs, ['alpha input']);
        expect(first.resizes, [(101, 37)]);
        final controllerInputBytes = Uint8List.fromList(
          utf8.encode('controller input\r'),
        );
        await app.deliverVerifiedTerminalInputBytesFor(
          alpha.id,
          controllerInputBytes,
        );
        expect(first.inputs, ['alpha input', 'controller input\r']);
        expect(controllerInputBytes, everyElement(0));
        expect(second.inputs, ['beta input']);
        expect(second.resizes, [(132, 42)]);

        app.activateTerminalTab(alpha.id);
        expect(app.connectedHost?.id, 'host-a');
        expect(app.terminalConnection, same(first));
        await app.closeTerminalTab(alpha.id);
        expect(first.closeCount, 1);
        expect(app.activeTerminalTabId, beta.id);
        expect(app.terminalTabs.map((tab) => tab.host?.id), ['host-b']);

        await app.disconnectAllTerminalTabs();
        expect(second.closeCount, 1);
        expect(app.activeTerminalTab, isNull);
        expect(connections.keys, containsAll(['host-a', 'host-b']));
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'closing a tab cancels in-flight SSH setup and closes Relay resources',
    () async {
      final socket = _PendingRelaySocket();
      final clientCreated = Completer<_PendingSshClient>();
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async =>
                throw StateError('The cancellation connector must be used.'),
        cancellationConnector:
            ({
              required host,
              required credential,
              required verifyHostKey,
              required jumpHops,
              required cancellation,
              required onUserInfoRequest,
            }) {
              return SshService(
                api: _ControllerRelayApi(),
                deviceId: 'test-device',
                useRelay: true,
                relaySocketConnector: (_, _) async => socket,
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
                      final client = _PendingSshClient();
                      clientCreated.complete(client);
                      return client;
                    },
              ).connect(
                host: host,
                credential: credential,
                verifyHostKey: verifyHostKey,
                jumpHops: jumpHops,
                cancellation: cancellation,
                onUserInfoRequest: onUserInfoRequest,
              );
            },
      );
      final app = fixture.app;
      try {
        final opening = app.openTerminalTab(_host('host-a', 'Alpha'));
        final client = await clientCreated.future;
        final tab = app.terminalTabs.single;

        await app.closeTerminalTab(tab.id);
        await opening;

        expect(app.terminalTabs, isEmpty);
        expect(tab.connection, isNull);
        expect(client.closeCount, 1);
        expect(socket.closeCount, 1);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'saved split pane connects bind transient tabs and reuse an existing session',
    () async {
      final connections = <String, _RecordingConnection>{};
      final connectorCalls = <String, int>{};
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              connectorCalls.update(
                host.id,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              final connection = _RecordingConnection();
              connections[host.id] = connection;
              return connection;
            },
      );
      final app = fixture.app;
      const hostA = '77777777-7777-4777-8777-777777777777';
      const hostB = '88888888-8888-4888-8888-888888888888';
      const workspaceId = '66666666-6666-4666-8666-666666666666';
      app
        ..activeVault = const VaultDescriptor(
          id: '11111111-1111-4111-8111-111111111111',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        )
        ..credentials.addAll(const [
          CredentialRecord(
            id: 'split-credential-a',
            name: 'Split A credential',
            username: 'tester',
          ),
          CredentialRecord(
            id: 'split-credential-b',
            name: 'Split B credential',
            username: 'tester',
          ),
        ])
        ..hosts.addAll(const [
          HostRecord(
            id: hostA,
            name: 'Split A',
            address: 'split-a.example.test',
            username: 'tester',
            credentialId: 'split-credential-a',
          ),
          HostRecord(
            id: hostB,
            name: 'Split B',
            address: 'split-b.example.test',
            username: 'tester',
            credentialId: 'split-credential-b',
          ),
        ]);
      final workspace = WorkspaceRecord.fromSplitHostIds(
        id: workspaceId,
        name: 'Two live panes',
        hostIds: const [hostA, hostB],
        axis: WorkspaceSplitAxis.horizontal,
        splitRatioBasisPoints: 6300,
      );
      app.savedWorkspaces.add(workspace);
      final savedLayoutBeforeConnect = workspace.toJson().toString();

      try {
        app.stageWorkspace(workspace.id);
        expect(
          app.workspacePaneTerminalTab(
            workspace.id,
            workspace.panes.first.paneId,
          ),
          isNull,
        );

        await app.connectWorkspacePane(
          workspace.id,
          workspace.panes.first.paneId,
        );
        final firstTab = app.workspacePaneTerminalTab(
          workspace.id,
          workspace.panes.first.paneId,
        );
        expect(firstTab?.host?.id, hostA);
        expect(firstTab?.connection, same(connections[hostA]));
        expect(app.terminalTabs, hasLength(1));

        await app.connectWorkspacePane(
          workspace.id,
          workspace.panes.last.paneId,
        );
        final secondTab = app.workspacePaneTerminalTab(
          workspace.id,
          workspace.panes.last.paneId,
        );
        expect(secondTab?.host?.id, hostB);
        expect(secondTab?.connection, same(connections[hostB]));
        expect(app.terminalTabs, hasLength(2));

        app.activateTerminalTab(secondTab!.id);
        await app.connectWorkspacePane(
          workspace.id,
          workspace.panes.first.paneId,
        );
        expect(app.activeTerminalTabId, firstTab!.id);
        expect(connections.keys, unorderedEquals([hostA, hostB]));
        expect(connectorCalls, {hostA: 1, hostB: 1});
        expect(workspace.toJson().toString(), savedLayoutBeforeConnect);

        await app.closeTerminalTab(firstTab.id);
        expect(connections[hostA]!.closeCount, 1);
        expect(connections[hostB]!.closeCount, 0);
        expect(
          app.workspacePaneTerminalTab(
            workspace.id,
            workspace.panes.first.paneId,
          ),
          isNull,
        );
        expect(
          app
              .workspacePaneTerminalTab(
                workspace.id,
                workspace.panes.last.paneId,
              )
              ?.id,
          secondTab.id,
        );

        await app.disconnectAllTerminalTabs();
        expect(
          app.workspacePaneTerminalTab(
            workspace.id,
            workspace.panes.first.paneId,
          ),
          isNull,
        );
        expect(
          app.workspacePaneTerminalTab(
            workspace.id,
            workspace.panes.last.paneId,
          ),
          isNull,
        );
        expect(connections[hostB]!.closeCount, 1);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'concurrent Connect calls reserve a split pane before tab registration',
    () async {
      final connectorStarted = Completer<void>();
      final pendingConnection = Completer<SshConnection>();
      var connectorCalls = 0;
      final connection = _RecordingConnection();
      final fixture = await _Fixture.create(
        connector:
            ({required host, required credential, required verifyHostKey}) {
              connectorCalls++;
              if (!connectorStarted.isCompleted) connectorStarted.complete();
              return pendingConnection.future;
            },
      );
      final app = fixture.app;
      const hostA = '77777777-7777-4777-8777-777777777777';
      const hostB = '88888888-8888-4888-8888-888888888888';
      const workspaceId = '66666666-6666-4666-8666-666666666666';
      app
        ..activeVault = const VaultDescriptor(
          id: '11111111-1111-4111-8111-111111111111',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        )
        ..credentials.addAll(const [
          CredentialRecord(
            id: 'flight-credential-a',
            name: 'Flight A credential',
            username: 'tester',
          ),
          CredentialRecord(
            id: 'flight-credential-b',
            name: 'Flight B credential',
            username: 'tester',
          ),
        ])
        ..hosts.addAll(const [
          HostRecord(
            id: hostA,
            name: 'Flight A',
            address: 'flight-a.example.test',
            username: 'tester',
            credentialId: 'flight-credential-a',
          ),
          HostRecord(
            id: hostB,
            name: 'Flight B',
            address: 'flight-b.example.test',
            username: 'tester',
            credentialId: 'flight-credential-b',
          ),
        ]);
      final workspace = WorkspaceRecord.fromSplitHostIds(
        id: workspaceId,
        name: 'Single flight',
        hostIds: const [hostA, hostB],
        axis: WorkspaceSplitAxis.horizontal,
      );
      app
        ..savedWorkspaces.add(workspace)
        ..stageWorkspace(workspace.id);

      try {
        final firstConnect = app.connectWorkspacePane(
          workspace.id,
          workspace.panes.first.paneId,
        );
        final duplicateConnect = app.connectWorkspacePane(
          workspace.id,
          workspace.panes.first.paneId,
        );
        expect(identical(firstConnect, duplicateConnect), isTrue);

        await connectorStarted.future;
        expect(connectorCalls, 1);
        expect(app.terminalTabs, hasLength(1));
        pendingConnection.complete(connection);
        await Future.wait([firstConnect, duplicateConnect]);

        final paneTab = app.workspacePaneTerminalTab(
          workspace.id,
          workspace.panes.first.paneId,
        );
        expect(paneTab?.connection, same(connection));
        expect(app.terminalTabs, hasLength(1));
      } finally {
        if (!pendingConnection.isCompleted) {
          pendingConnection.complete(connection);
        }
        await app.disconnectAllTerminalTabs();
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'split pane stream completion and errors clear stale sessions for reconnect',
    () async {
      final connections = <_RecordingConnection>[];
      var connectorCalls = 0;
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              connectorCalls++;
              final connection = _RecordingConnection();
              connections.add(connection);
              return connection;
            },
      );
      final app = fixture.app;
      const hostA = '77777777-7777-4777-8777-777777777777';
      const hostB = '88888888-8888-4888-8888-888888888888';
      const workspaceId = '66666666-6666-4666-8666-666666666666';
      app
        ..activeVault = const VaultDescriptor(
          id: '11111111-1111-4111-8111-111111111111',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        )
        ..credentials.addAll(const [
          CredentialRecord(
            id: 'reconnect-credential-a',
            name: 'Reconnect A credential',
            username: 'tester',
          ),
          CredentialRecord(
            id: 'reconnect-credential-b',
            name: 'Reconnect B credential',
            username: 'tester',
          ),
        ])
        ..hosts.addAll(const [
          HostRecord(
            id: hostA,
            name: 'Reconnect A',
            address: 'reconnect-a.example.test',
            username: 'tester',
            credentialId: 'reconnect-credential-a',
          ),
          HostRecord(
            id: hostB,
            name: 'Reconnect B',
            address: 'reconnect-b.example.test',
            username: 'tester',
            credentialId: 'reconnect-credential-b',
          ),
        ]);
      final workspace = WorkspaceRecord.fromSplitHostIds(
        id: workspaceId,
        name: 'Reconnect split',
        hostIds: const [hostA, hostB],
        axis: WorkspaceSplitAxis.horizontal,
      );
      app
        ..savedWorkspaces.add(workspace)
        ..stageWorkspace(workspace.id);

      try {
        final paneId = workspace.panes.first.paneId;
        await app.connectWorkspacePane(workspace.id, paneId);
        final firstTab = app.workspacePaneTerminalTab(workspace.id, paneId)!;
        expect(firstTab.connection, same(connections[0]));

        await connections[0].finishOutput();
        await Future<void>.delayed(Duration.zero);
        expect(firstTab.connection, isNull);
        expect(firstTab.state, 'disconnected');
        expect(firstTab.errorMessage, isNull);
        expect(connections[0].closeCount, 1);

        await app.connectWorkspacePane(workspace.id, paneId);
        final secondTab = app.workspacePaneTerminalTab(workspace.id, paneId)!;
        expect(secondTab.id, isNot(firstTab.id));
        expect(secondTab.connection, same(connections[1]));

        connections[1].failOutput(StateError('synthetic transport loss'));
        await Future<void>.delayed(Duration.zero);
        expect(secondTab.connection, isNull);
        expect(secondTab.state, 'disconnected');
        expect(secondTab.errorMessage, isNotNull);
        expect(connections[1].closeCount, 1);

        await app.connectWorkspacePane(workspace.id, paneId);
        final thirdTab = app.workspacePaneTerminalTab(workspace.id, paneId)!;
        expect(thirdTab.id, isNot(secondTab.id));
        expect(thirdTab.connection, same(connections[2]));
        expect(connectorCalls, 3);
      } finally {
        await app.disconnectAllTerminalTabs();
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'a connection completing after its tab closes is closed immediately',
    () async {
      final connectStarted = Completer<void>();
      final pendingConnection = Completer<SshConnection>();
      final lateConnection = _RecordingConnection();
      final fixture = await _Fixture.create(
        connector:
            ({required host, required credential, required verifyHostKey}) {
              if (!connectStarted.isCompleted) connectStarted.complete();
              return pendingConnection.future;
            },
      );
      final app = fixture.app;
      try {
        final opening = app.openTerminalTab(_host('host-a', 'Alpha'));
        await connectStarted.future;
        final tab = app.activeTerminalTab!;
        await app.closeTerminalTab(tab.id);
        pendingConnection.complete(lateConnection);
        await opening;

        expect(lateConnection.closeCount, 1);
        expect(app.terminalTabs, isEmpty);
        expect(app.activeTerminalTab, isNull);
      } finally {
        if (!pendingConnection.isCompleted) {
          pendingConnection.complete(_RecordingConnection());
        }
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'SSH connection uses Host override then nearest inherited credential',
    () async {
      final usedCredentialIds = <String>[];
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              usedCredentialIds.add(credential.id);
              return _RecordingConnection();
            },
      );
      final app = fixture.app;
      app
        ..credentials.addAll(const [
          CredentialRecord(
            id: 'group-root-credential',
            name: 'Root default',
            username: 'root-default',
            secret: 'ephemeral-root',
          ),
          CredentialRecord(
            id: 'group-child-credential',
            name: 'Child default',
            username: 'child-default',
            secret: 'ephemeral-child',
          ),
        ])
        ..groups.addAll(const [
          GroupRecord(
            id: 'group-root',
            name: 'Root',
            defaultCredentialId: 'group-root-credential',
          ),
          GroupRecord(
            id: 'group-child',
            name: 'Child',
            parentId: 'group-root',
            defaultCredentialId: 'group-child-credential',
          ),
        ]);
      try {
        await app.openTerminalTab(
          const HostRecord(
            id: 'inherited-host',
            name: 'Inherited host',
            address: 'inherited.example.test',
            username: 'deploy',
            groupId: 'group-child',
          ),
        );
        expect(usedCredentialIds, ['group-child-credential']);
        await app.closeTerminalTab(app.activeTerminalTabId!);

        await app.openTerminalTab(
          const HostRecord(
            id: 'host-a',
            name: 'Override host',
            address: 'host-a.example.test',
            username: 'tester',
            groupId: 'group-child',
            credentialId: 'credential-host-a',
          ),
        );
        expect(usedCredentialIds, [
          'group-child-credential',
          'credential-host-a',
        ]);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'Jump Host SSH uses separately resolved Host credentials and key checks',
    () async {
      HostRecord? connectedTarget;
      HostRecord? usedJumpHost;
      CredentialRecord? targetCredential;
      CredentialRecord? usedJumpCredential;
      Future<bool> Function(String, String)? targetKeyCheck;
      Future<bool> Function(String, String)? jumpKeyCheck;
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => throw StateError(
              'direct-only connector must not handle a Jump Host',
            ),
        jumpConnector:
            ({
              required host,
              required credential,
              required verifyHostKey,
              required jumpHost,
              required jumpCredential,
              required verifyJumpHostKey,
            }) async {
              connectedTarget = host;
              usedJumpHost = jumpHost;
              targetCredential = credential;
              usedJumpCredential = jumpCredential;
              targetKeyCheck = verifyHostKey;
              jumpKeyCheck = verifyJumpHostKey;
              return _RecordingConnection();
            },
      );
      final app = fixture.app;
      app
        ..credentials.addAll(const [
          CredentialRecord(
            id: 'target-default',
            name: 'Target default',
            username: 'target-user',
            secret: 'target-secret',
          ),
          CredentialRecord(
            id: 'jump-default',
            name: 'Jump default',
            username: 'jump-user',
            secret: 'jump-secret',
          ),
        ])
        ..groups.addAll(const [
          GroupRecord(
            id: 'target-group',
            name: 'Target group',
            defaultCredentialId: 'target-default',
          ),
          GroupRecord(
            id: 'jump-group',
            name: 'Jump group',
            defaultCredentialId: 'jump-default',
          ),
        ]);
      const bastion = HostRecord(
        id: 'jump-host',
        name: 'Bastion',
        address: 'bastion.example.test',
        username: 'relay',
        groupId: 'jump-group',
      );
      const target = HostRecord(
        id: 'target-host',
        name: 'Target',
        address: 'target.example.test',
        username: 'deploy',
        groupId: 'target-group',
        jumpHostId: 'jump-host',
      );
      app.hosts.add(bastion);
      try {
        await app.openTerminalTab(target);

        expect(connectedTarget, same(target));
        expect(usedJumpHost, same(bastion));
        expect(targetCredential?.id, 'target-default');
        expect(usedJumpCredential?.id, 'jump-default');
        expect(targetKeyCheck, isNotNull);
        expect(jumpKeyCheck, isNotNull);
        expect(identical(targetKeyCheck, jumpKeyCheck), isFalse);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'invalid Jump Host references fail before opening a terminal tab',
    () async {
      var connectorCalls = 0;
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              connectorCalls++;
              return _RecordingConnection();
            },
        jumpConnector:
            ({
              required host,
              required credential,
              required verifyHostKey,
              required jumpHost,
              required jumpCredential,
              required verifyJumpHostKey,
            }) async {
              connectorCalls++;
              return _RecordingConnection();
            },
      );
      final app = fixture.app;
      app.hosts.addAll(const [
        HostRecord(
          id: 'nested-jump',
          name: 'Nested jump',
          address: 'nested.example.test',
          username: 'relay',
          jumpHostId: 'some-other-hop',
        ),
        HostRecord(
          id: 'jump-without-credential',
          name: 'Credential-less jump',
          address: 'no-credential.example.test',
          username: 'relay',
        ),
      ]);
      for (var hop = 1; hop <= maxJumpHostHops + 1; hop++) {
        app.hosts.add(
          HostRecord(
            id: 'over-limit-hop-$hop',
            name: 'Over limit hop $hop',
            address: 'over-limit-hop-$hop.example.test',
            username: 'relay',
            credentialId: 'credential-host-a',
            jumpHostId: hop == 1 ? null : 'over-limit-hop-${hop - 1}',
          ),
        );
      }
      try {
        await expectLater(
          app.openTerminalTab(
            const HostRecord(
              id: 'self-target',
              name: 'Self target',
              address: 'target.example.test',
              username: 'deploy',
              credentialId: 'credential-host-a',
              jumpHostId: 'self-target',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          app.openTerminalTab(
            const HostRecord(
              id: 'missing-target',
              name: 'Missing target jump',
              address: 'target.example.test',
              username: 'deploy',
              credentialId: 'credential-host-a',
              jumpHostId: 'missing-jump',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          app.openTerminalTab(
            const HostRecord(
              id: 'unresolved-credential-target',
              name: 'Unresolved jump credential',
              address: 'target.example.test',
              username: 'deploy',
              credentialId: 'credential-host-a',
              jumpHostId: 'jump-without-credential',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          app.openTerminalTab(
            const HostRecord(
              id: 'nested-target',
              name: 'Nested target jump',
              address: 'target.example.test',
              username: 'deploy',
              credentialId: 'credential-host-a',
              jumpHostId: 'nested-jump',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          app.openTerminalTab(
            HostRecord(
              id: 'over-limit-target',
              name: 'Over limit target',
              address: 'target.example.test',
              username: 'deploy',
              credentialId: 'credential-host-b',
              jumpHostId: 'over-limit-hop-${maxJumpHostHops + 1}',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'terminal opens each resolved Jump Host from outermost to target',
    () async {
      List<SshJumpHop>? observedHops;
      final fixture = await _Fixture.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async =>
                throw StateError('route connector must handle this chain'),
        routeConnector:
            ({
              required host,
              required credential,
              required verifyHostKey,
              required jumpHops,
            }) async {
              observedHops = jumpHops;
              expect(host.id, 'route-target');
              expect(credential.id, 'route-target-credential');
              return _RecordingConnection();
            },
      );
      final app = fixture.app;
      app.credentials.addAll(const [
        CredentialRecord(
          id: 'route-outer-credential',
          name: 'Outer',
          username: 'outer-user',
          secret: 'outer-secret',
        ),
        CredentialRecord(
          id: 'route-inner-credential',
          name: 'Inner',
          username: 'inner-user',
          secret: 'inner-secret',
        ),
        CredentialRecord(
          id: 'route-target-credential',
          name: 'Target',
          username: 'target-user',
          secret: 'target-secret',
        ),
      ]);
      const outer = HostRecord(
        id: 'route-outer',
        name: 'Outer Bastion',
        address: 'outer.example.test',
        credentialId: 'route-outer-credential',
      );
      const inner = HostRecord(
        id: 'route-inner',
        name: 'Inner Bastion',
        address: 'inner.example.test',
        credentialId: 'route-inner-credential',
        jumpHostId: 'route-outer',
      );
      const target = HostRecord(
        id: 'route-target',
        name: 'Target',
        address: 'target.example.test',
        credentialId: 'route-target-credential',
        jumpHostId: 'route-inner',
      );
      app.hosts.addAll([outer, inner]);
      try {
        await app.openTerminalTab(target);
        expect(observedHops?.map((hop) => hop.host.id), [
          'route-outer',
          'route-inner',
        ]);
        expect(observedHops?.map((hop) => hop.credential.id), [
          'route-outer-credential',
          'route-inner-credential',
        ]);
        expect(observedHops?[0].verifyHostKey, isNotNull);
        expect(observedHops?[1].verifyHostKey, isNotNull);
      } finally {
        app.dispose();
        await fixture.database.close();
      }
    },
  );
}

String _bufferText(TerminalTabSession tab) {
  final lines = tab.terminal.buffer.lines;
  return List.generate(
    lines.length,
    (index) => lines[index].toString(),
  ).join('\n');
}

HostRecord _host(String id, String name) => HostRecord(
  id: id,
  name: name,
  address: '$id.example.test',
  username: 'tester',
  credentialId: 'credential-$id',
);

class _Fixture {
  const _Fixture(this.app, this.database);

  final AppController app;
  final ClientDatabase database;

  static Future<_Fixture> create({
    required SshConnectorForTesting connector,
    TerminalShareObserverJoinerForTesting?
    terminalShareObserverJoinerForTesting,
    SshConnectorWithJumpForTesting? jumpConnector,
    SshConnectorWithRouteForTesting? routeConnector,
    SshConnectorWithCancellationForTesting? cancellationConnector,
  }) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorForTesting: connector,
            terminalShareObserverJoinerForTesting:
                terminalShareObserverJoinerForTesting,
            sshConnectorWithJumpForTesting: jumpConnector,
            sshConnectorWithRouteForTesting: routeConnector,
            sshConnectorWithCancellationForTesting: cancellationConnector,
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
          ..credentials.addAll([
            for (final id in ['host-a', 'host-b'])
              CredentialRecord(
                id: 'credential-$id',
                name: 'Test credential',
                username: 'tester',
                secret: 'ephemeral-test-secret',
              ),
          ]);
    return _Fixture(app, database);
  }
}

class _PreGrantedObserverHandle implements TerminalShareObserverSession {
  _PreGrantedObserverHandle({required this.controllerGrant}) {
    final grant = controllerGrant;
    if (grant != null) {
      _events.add(
        TerminalCollaborationEvent.controllerGranted(
          leaseId: grant.leaseId,
          controlEpoch: grant.controlEpoch,
          expiresAt: grant.expiresAt,
        ),
      );
    }
  }

  @override
  final TerminalControllerLease? controllerGrant;

  final _events = StreamController<TerminalCollaborationEvent>.broadcast(
    sync: true,
  );
  final _done = Completer<void>();

  void emit(TerminalCollaborationEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Stream<TerminalCollaborationEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> get connected => Future<void>.value();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObserverWithDisconnectedControllerHandle
    extends _PreGrantedObserverHandle {
  _ObserverWithDisconnectedControllerHandle({
    required super.controllerGrant,
    required this.controller,
  });

  final _DisconnectedControllerSession controller;

  @override
  Future<TerminalShareControllerSession> joinController() async => controller;
}

class _DisconnectedControllerSession implements TerminalShareControllerSession {
  _DisconnectedControllerSession({
    required this.leaseId,
    required this.controlEpoch,
    required this.expiresAt,
  });

  @override
  final String leaseId;
  @override
  final int controlEpoch;
  @override
  final DateTime expiresAt;
  int closeCount = 0;

  @override
  bool get isConnected => false;

  @override
  Future<void> get connected => Future<void>.value();

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async => closeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingConnection implements SshConnection {
  _RecordingConnection({this.sftpClient});

  _RecordingSftpClient? sftpClient;
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );
  final List<String> inputs = [];
  final List<(int, int)> resizes = [];
  int closeCount = 0;

  void emit(String text) => _output.add(text);

  Future<void> finishOutput() => _output.close();

  void failOutput(Object error) => _output.addError(error);

  @override
  Stream<String> get output => _output.stream;

  @override
  SSHClient get client => _RecordingSshClient(
    sftpClient ?? (throw StateError('No SFTP fixture configured')),
  );

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

class _RecordingSshClient implements SSHClient {
  _RecordingSshClient(this.sftpClient);

  final _RecordingSftpClient sftpClient;

  @override
  Future<SftpClient> sftp() async => sftpClient;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSftpClient implements SftpClient {
  final List<String> mkdirPaths = [];
  final List<String> listdirPaths = [];

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    mkdirPaths.add(path);
  }

  @override
  Future<List<SftpName>> listdir(String path) async {
    listdirPaths.add(path);
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControllerRelayApi extends ApiClient {
  _ControllerRelayApi() : super(baseUrl: 'https://relay.example.test/tenant');

  @override
  Future<RelayTicket> createRelayTicket({
    required String deviceId,
    required String targetHost,
    required int targetPort,
  }) async => RelayTicket(
    value: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 20)),
  );

  @override
  Uri relayUri() =>
      Uri.parse('wss://relay.example.test/tenant/relay/v1/connect');
}

class _PendingSshClient implements SSHClient {
  final _authenticated = Completer<void>();
  int closeCount = 0;

  @override
  Future<void> get authenticated => _authenticated.future;

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PendingRelaySocket implements SSHSocket {
  int closeCount = 0;

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>().sink;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  void destroy() {}

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CompatibilitySftpClient extends _RecordingSftpClient {
  _CompatibilitySftpClient(this.file);
  final _CompatibilitySftpFile file;
  String? path;
  @override
  Future<SftpFile> open(String path, {SftpFileOpenMode mode = SftpFileOpenMode.read}) async {
    this.path = path;
    return file;
  }
}
class _CompatibilitySftpFile implements SftpFile {
  _CompatibilitySftpFile(this.bytes);
  final Uint8List bytes;
  int? requestedLength;
  bool closed = false;
  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    requestedLength = length;
    return bytes;
  }
  @override
  Future<void> close() async { closed = true; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
