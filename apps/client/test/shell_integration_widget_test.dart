import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Bash history requires an explicit copy action and stores encrypted device-local events',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final connections = <_RecordingConnection>[];
      final identity = DeviceIdentity.create(sodium);
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    final connection = _RecordingConnection();
                    connections.add(connection);
                    return connection;
                  },
            )
            ..session = AuthSession(
              accountId: 'account-shell-history',
              accessToken: 'access-test',
              expiresIn: 3600,
              refreshToken: 'refresh-test',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..serverUrl = 'https://history.example.test'
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..credentials.add(
              const CredentialRecord(
                id: 'credential-shell-history',
                name: 'History test credential',
                username: 'tester',
                secret: 'test-only-secret',
              ),
            );
      const host = HostRecord(
        id: 'host-shell-history',
        name: 'History test host',
        address: 'history.example.test',
        username: 'tester',
        credentialId: 'credential-shell-history',
      );
      final previousTargetPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') return null;
        return null;
      });

      var shellMounted = false;
      try {
        await app.openTerminalTab(host);
        final connection = connections.first;
        final tab = app.activeTerminalTab!;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        shellMounted = true;
        await tester.pump();

        await tester.tap(find.byTooltip('Enable Bash command history'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.textContaining('It does not edit shell startup files'),
          findsOneWidget,
        );
        expect(app.shellIntegrationActiveFor(tab.id), isFalse);
        expect(connection.inputs, isEmpty);

        await tester.tap(find.text('Enable and copy'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.shellIntegrationActiveFor(tab.id), isTrue);
        expect(
          find.textContaining('Copied. Paste this command'),
          findsOneWidget,
        );
        expect(connection.inputs, isEmpty);

        const command = r"printf 'recorded from the remote hook'";
        final payload = base64Url
            .encode(utf8.encode(command))
            .replaceAll('=', '');
        final nonce = tab.shellIntegration!.sessionNonce;
        connection.emit(
          '\u001b]777;atermius;v1;$nonce;${tab.id};1;start;$payload\u0007'
          '\u001b]777;atermius;v1;$nonce;${tab.id};1;end;0\u0007',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(command), findsOneWidget);
        expect(tab.shellIntegrationHistory.single.command, command);
        expect(connection.inputs, isEmpty);
        await tester.runAsync(() => tab.shellHistoryPersistenceQueue);
        final storedRows = await tester.runAsync(
          () => database.terminalHistoryCiphertextEntries(
            serverNamespace: 'https://history.example.test',
            accountId: 'account-shell-history',
            deviceId: identity.deviceId,
          ),
        );
        expect(storedRows, hasLength(1));
        expect(
          utf8.decode(storedRows!.single.ciphertext, allowMalformed: true),
          isNot(contains(command)),
        );

        await tester.tap(find.text('Stop local capture'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.shellIntegrationActiveFor(tab.id), isFalse);
        expect(tab.shellIntegrationHistory, hasLength(1));

        connection.emit(
          '\u001b]777;atermius;v1;$nonce;${tab.id};2;start;$payload\u0007'
          '\u001b]777;atermius;v1;$nonce;${tab.id};2;end;0\u0007',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tab.shellIntegrationHistory, hasLength(1));

        await tester.tap(find.text('Close'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => app.closeTerminalTab(tab.id));
        expect(app.shellIntegrationHistoryFor(tab.id), isEmpty);
        final persistedAfterClose = await tester.runAsync(
          () => database.terminalHistoryCiphertextEntries(
            serverNamespace: 'https://history.example.test',
            accountId: 'account-shell-history',
            deviceId: identity.deviceId,
          ),
        );
        expect(persistedAfterClose, hasLength(1));
        await tester.runAsync(
          () => connection.closedFuture.timeout(const Duration(seconds: 2)),
        );

        await app.openTerminalTab(host);
        final restoredTab = app.activeTerminalTab!;
        await tester.runAsync(() => restoredTab.shellHistoryRestoration);
        expect(restoredTab.shellIntegrationHistory, hasLength(1));
        expect(restoredTab.shellIntegrationHistory.single.command, command);
        await tester.runAsync(() => app.closeTerminalTab(restoredTab.id));
        await tester.runAsync(
          () =>
              connections.last.closedFuture.timeout(const Duration(seconds: 2)),
        );
      } finally {
        if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = previousTargetPlatform;
        app.dispose();
        await database.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _RecordingConnection implements SshConnection {
  _RecordingConnection() {
    _output = StreamController<String>.broadcast(sync: true);
  }

  late final StreamController<String> _output;
  final _closedCompleter = Completer<void>();
  final inputs = <String>[];
  bool closed = false;

  Future<void> get closedFuture => _closedCompleter.future;

  void emit(String text) => _output.add(text);

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() {
    if (closed) return Future<void>.value();
    closed = true;
    if (!_output.isClosed) unawaited(_output.close());
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
