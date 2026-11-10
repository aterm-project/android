import 'dart:async';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

const _vaultA = VaultDescriptor(
  id: 'vault-progress-a',
  role: 'owner',
  activeKeyEpoch: 'epoch',
  membershipVersion: 'membership',
);
const _host = HostRecord(
  id: 'host-progress',
  name: 'Progress host',
  address: 'progress.example.test',
  username: 'tester',
  credentialId: 'credential-progress',
);

void main() {
  useAppLocaleFixture('en');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a pending SSH request shows a selected tab before the handshake '
      'and reports real stages', () async {
    final fixture = await _Fixture.create();
    final app = fixture.app;
    try {
      final opening = app.openTerminalTab(_host);
      // Synchronously after the click: the tab exists, is selected and is
      // loading, before credential fingerprinting or any connector call.
      expect(fixture.attempts, isEmpty);
      final tab = app.activeTerminalTab!;
      expect(app.terminalTabs, [tab]);
      expect(app.page, WorkspacePage.terminal);
      expect(tab.state, 'connecting');
      expect(tab.connectProgress.phase, ConnectPhase.loading);
      expect(tab.connectProgress.stage, ConnectStage.preparing);

      final first = await fixture.nextAttempt();
      // Credential preparation finished; the transport attempt is running.
      expect(tab.connectProgress.stage, ConnectStage.connecting);
      expect(app.terminalTabs, [tab]);
      expect(fixture.attempts, hasLength(1));

      final connection = _Connection();
      first.result.complete(connection);
      await opening.catchError((Object _) {});
      expect(tab.state, 'connected');
      expect(tab.connection, same(connection));
      expect(tab.connectProgress.phase, ConnectPhase.idle);
    } finally {
      await fixture.dispose();
    }
  });

  test('stop loading cancels the socket attempt; a late success is closed '
      'and never attached', () async {
    final fixture = await _Fixture.create();
    final app = fixture.app;
    try {
      final opening = app.openTerminalTab(_host);
      final tab = app.activeTerminalTab!;
      final first = await fixture.nextAttempt();

      await app.cancelTerminalConnect(tab.id);
      expect(first.cancellation.isCancelled, isTrue);
      expect(tab.connectProgress.phase, ConnectPhase.cancelled);
      expect(tab.state, 'disconnected');
      expect(app.activeTerminalTab, same(tab));

      final late = _Connection();
      first.result.complete(late);
      await opening.catchError((Object _) {});
      await _settle();
      expect(late.closeCount, greaterThan(0));
      expect(tab.connection, isNull);
      expect(tab.connectProgress.phase, ConnectPhase.cancelled);
      expect(tab.state, 'disconnected');
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'retry reuses the original tab with exactly one new connection per '
    'attempt; late success and failure of stopped attempts change nothing',
    () async {
      final fixture = await _Fixture.create();
      final app = fixture.app;
      try {
        final opening = app.openTerminalTab(_host);
        final tab = app.activeTerminalTab!;
        final first = await fixture.nextAttempt();
        await app.cancelTerminalConnect(tab.id);
        expect(app.canRetryTerminalConnect(tab.id), isTrue);

        final secondRetry = app.retryTerminalConnect(tab.id);
        // A second click while loading is a no-op: one new connection only.
        await app.retryTerminalConnect(tab.id);
        final second = await fixture.nextAttempt();
        expect(fixture.attempts, hasLength(2));
        expect(app.terminalTabs, [tab]);
        expect(app.activeTerminalTab, same(tab));
        expect(tab.connectProgress.phase, ConnectPhase.loading);

        await app.cancelTerminalConnect(tab.id);
        final thirdRetry = app.retryTerminalConnect(tab.id);
        final third = await fixture.nextAttempt();
        expect(fixture.attempts, hasLength(3));
        expect(second.cancellation.isCancelled, isTrue);
        expect(third.cancellation.isCancelled, isFalse);

        // Late success from the first stopped attempt.
        final lateSuccess = _Connection();
        first.result.complete(lateSuccess);
        // Late failure from the second stopped attempt.
        second.result.completeError(StateError('late failure must not show'));
        await opening.catchError((Object _) {});
        await secondRetry;
        await _settle();
        expect(lateSuccess.closeCount, greaterThan(0));
        expect(tab.connection, isNull);
        expect(tab.state, 'connecting');
        expect(tab.errorMessage, isNull);
        expect(tab.connectProgress.phase, ConnectPhase.loading);
        expect(tab.connectProgress.error, isNull);

        final live = _Connection();
        third.result.complete(live);
        await thirdRetry;
        expect(tab.state, 'connected');
        expect(tab.connection, same(live));
        expect(live.closeCount, 0);
        expect(tab.connectProgress.phase, ConnectPhase.idle);
        expect(app.terminalTabs, [tab]);
        expect(fixture.attempts, hasLength(3));
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('a failed attempt shows its error and retry uses the current Host '
      'and credential in the same tab', () async {
    final fixture = await _Fixture.create();
    final app = fixture.app;
    try {
      final opening = app.openTerminalTab(_host);
      final tab = app.activeTerminalTab!;
      final first = await fixture.nextAttempt();
      first.result.completeError(StateError('connection refused'));
      await expectLater(opening, throwsStateError);
      expect(tab.state, 'failed');
      expect(tab.connectProgress.phase, ConnectPhase.failed);
      expect(tab.connectProgress.error, contains('connection refused'));
      expect(tab.connectProgress.error, isNot(startsWith('Bad state')));

      // The Vault now holds a corrected Host and a rotated credential.
      app.hosts
        ..clear()
        ..add(_host.copyWith(address: 'fixed.example.test'));
      app.credentials
        ..clear()
        ..add(
          const CredentialRecord(
            id: 'credential-progress',
            name: 'Rotated',
            username: 'tester',
            secret: 'rotated-ephemeral-secret',
          ),
        );
      final retry = app.retryTerminalConnect(tab.id);
      final second = await fixture.nextAttempt();
      expect(fixture.attempts, hasLength(2));
      expect(second.host.address, 'fixed.example.test');
      expect(second.credential.secret, 'rotated-ephemeral-secret');
      second.result.complete(_Connection());
      await retry;
      expect(tab.state, 'connected');
      expect(app.terminalTabs, [tab]);
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'closing a loading tab cancels the request and it never restores',
    () async {
      final fixture = await _Fixture.create();
      final app = fixture.app;
      try {
        final opening = app.openTerminalTab(_host);
        final tab = app.activeTerminalTab!;
        final first = await fixture.nextAttempt();
        await app.closeTerminalTab(tab.id);
        expect(first.cancellation.isCancelled, isTrue);
        expect(app.terminalTabs, isEmpty);
        expect(tab.connectProgress.retired, isTrue);
        expect(tab.connectProgress.isVisible, isFalse);

        final late = _Connection();
        first.result.complete(late);
        await opening.catchError((Object _) {});
        await _settle();
        expect(late.closeCount, greaterThan(0));
        expect(tab.connection, isNull);
        expect(tab.recovery, isNull);
        expect(app.canRetryTerminalConnect(tab.id), isFalse);
        await app.retryTerminalConnect(tab.id);
        await app.reconnectTerminalTab(tab.id);
        expect(fixture.attempts, hasLength(1));
        expect(app.terminalTabs, isEmpty);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('a Vault switch while loading never attaches the late connection '
      'and the stale tab cannot retry with the new authority', () async {
    final fixture = await _Fixture.create();
    final app = fixture.app;
    try {
      final opening = app.openTerminalTab(_host);
      final tab = app.activeTerminalTab!;
      final first = await fixture.nextAttempt();
      app.activeVault = const VaultDescriptor(
        id: 'vault-progress-b',
        role: 'owner',
        activeKeyEpoch: 'epoch',
        membershipVersion: 'membership',
      );
      final late = _Connection();
      first.result.complete(late);
      await opening.catchError((Object _) {});
      await _settle();
      expect(late.closeCount, greaterThan(0));
      expect(tab.connection, isNull);
      expect(tab.state, 'failed');
      expect(tab.connectProgress.phase, ConnectPhase.failed);
      expect(app.canRetryTerminalConnect(tab.id), isFalse);
      await app.retryTerminalConnect(tab.id);
      expect(fixture.attempts, hasLength(1));
    } finally {
      await fixture.dispose();
    }
  });

  test('an account change or lock while loading never connects', () async {
    for (final revoke in <void Function(AppController)>[
      (app) => app.session = AuthSession(
        accountId: 'account-other',
        accessToken: 'access-other',
        expiresIn: 3600,
        refreshToken: 'refresh-other',
        deviceId: app.identity!.deviceId,
        vaults: const [],
      ),
      (app) => app.workspaceLocked = true,
    ]) {
      final fixture = await _Fixture.create();
      final app = fixture.app;
      try {
        final opening = app.openTerminalTab(_host);
        final tab = app.activeTerminalTab!;
        final first = await fixture.nextAttempt();
        revoke(app);
        final late = _Connection();
        first.result.complete(late);
        await opening.catchError((Object _) {});
        await _settle();
        expect(late.closeCount, greaterThan(0));
        expect(tab.connection, isNull);
        expect(tab.state, isNot('connected'));
        expect(app.canRetryTerminalConnect(tab.id), isFalse);
        await app.retryTerminalConnect(tab.id);
        expect(fixture.attempts, hasLength(1));
      } finally {
        app.workspaceLocked = false;
        await fixture.dispose();
      }
    }
  });

  test(
    'a console that cannot start keeps a failed tab and retries in it',
    () async {
      final fixture = await _Fixture.create();
      final app = fixture.app;
      var opens = 0;
      final console = _Console();
      app.localConsoleOpenerForTesting =
          ({LocalShellLaunch? shell, String? serialPort, int baudRate = 0}) {
            opens++;
            if (opens == 1) {
              throw const LocalShellException(
                LocalShellIssue.shellNotInstalled,
              );
            }
            return console;
          };
      try {
        final id = await app.openLocalShellTab();
        final tab = app.terminalTabFor(id)!;
        expect(tab.connectProgress.phase, ConnectPhase.failed);
        expect(tab.connectProgress.error, isNotEmpty);
        expect(app.canRetryTerminalConnect(tab.id), isTrue);
        await app.retryTerminalConnect(tab.id);
        expect(opens, 2);
        expect(app.terminalTabs, [tab]);
        expect(tab.console, same(console));
        expect(tab.state, 'connected');
        expect(tab.connectProgress.phase, ConnectPhase.idle);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('a VNC tab opens immediately; stop closes its socket and retry opens '
      'exactly one new socket in the same tab', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    final clientClosed = <Completer<void>>[];
    server.listen((socket) {
      accepted.add(socket);
      final closed = Completer<void>();
      clientClosed.add(closed);
      // Never answer the RFB handshake: the attempt stays loading.
      socket.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final fixture = await _Fixture.create();
    final app = fixture.app;
    final vnc = HostRecord(
      id: 'host-progress-vnc',
      name: 'Progress VNC',
      address: '127.0.0.1',
      port: server.port,
      protocol: HostProtocol.vnc,
    );
    app.hosts.add(vnc);
    try {
      final opening = app.openTerminalTab(vnc);
      final tab = app.activeTerminalTab!;
      expect(tab.desktop, isNotNull);
      expect(tab.connectProgress.phase, ConnectPhase.loading);
      await opening;
      await _until(() => accepted.length == 1);

      await app.cancelTerminalConnect(tab.id);
      expect(tab.connectProgress.phase, ConnectPhase.cancelled);
      await clientClosed.single.future.timeout(const Duration(seconds: 5));

      final firstDesktop = tab.desktop;
      await app.retryTerminalConnect(tab.id);
      expect(tab.desktop, isNot(same(firstDesktop)));
      expect(tab.connectProgress.phase, ConnectPhase.loading);
      await _until(() => accepted.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, hasLength(2));
      expect(app.terminalTabs, [tab]);

      await app.closeTerminalTab(tab.id);
      await clientClosed.last.future.timeout(const Duration(seconds: 5));
    } finally {
      for (final socket in accepted) {
        socket.destroy();
      }
      await server.close();
      await fixture.dispose();
    }
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _Attempt {
  _Attempt(this.host, this.credential, this.cancellation, this.verifyHostKey);
  final HostRecord host;
  final CredentialRecord credential;
  final SshConnectCancellation cancellation;
  final Future<bool> Function(String type, String fingerprint) verifyHostKey;
  final result = Completer<SshConnection>();
}

class _Fixture {
  _Fixture(this.app, this.database, this.attempts);

  final AppController app;
  final ClientDatabase database;
  final List<_Attempt> attempts;
  int _consumed = 0;

  Future<_Attempt> nextAttempt() async {
    final index = _consumed++;
    for (var i = 0; i < 500 && attempts.length <= index; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(attempts.length, greaterThan(index));
    return attempts[index];
  }

  static Future<_Fixture> create() async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final attempts = <_Attempt>[];
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorWithCancellationForTesting:
                ({
                  required host,
                  required credential,
                  required verifyHostKey,
                  required jumpHops,
                  required cancellation,
                  required onUserInfoRequest,
                }) {
                  final attempt = _Attempt(
                    host,
                    credential,
                    cancellation,
                    verifyHostKey,
                  );
                  attempts.add(attempt);
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-progress',
            accessToken: 'access-progress',
            expiresIn: 3600,
            refreshToken: 'refresh-progress',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..activeVault = _vaultA
          ..hosts.add(_host)
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-progress',
              name: 'Progress credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          );
    return _Fixture(app, database, attempts);
  }

  Future<void> dispose() async {
    for (final attempt in attempts) {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const SshConnectCancelledException());
      }
    }
    await app.disconnectAllTerminalTabs();
    app.dispose();
    await database.close();
  }
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast(sync: true);
  int closeCount = 0;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    closeCount++;
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Console implements LocalConsole {
  final _output = StreamController<String>.broadcast();
  final _exit = Completer<int>();

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
    if (!_exit.isCompleted) _exit.complete(0);
  }
}
