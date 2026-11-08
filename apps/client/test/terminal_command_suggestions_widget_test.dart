import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/shell_history_record.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/shell_integration_protocol.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Web suggestions are bounded, Host-scoped, dismissible, and only type text',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final connections = <String, _RecordingConnection>{};
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
                    connections[host.id] = connection;
                    return connection;
                  },
            )
            ..session = AuthSession(
              accountId: 'account-command-suggestions',
              accessToken: 'test-access-token',
              expiresIn: 3600,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'credential-alpha',
                name: 'Alpha credential',
                username: 'tester',
                secret: 'test-only-secret',
              ),
              CredentialRecord(
                id: 'credential-beta',
                name: 'Beta credential',
                username: 'tester',
                secret: 'test-only-secret',
              ),
            ]);
      const alphaHost = HostRecord(
        id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        name: 'Alpha',
        address: 'alpha.example.test',
        username: 'tester',
        credentialId: 'credential-alpha',
      );
      const betaHost = HostRecord(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        name: 'Beta',
        address: 'beta.example.test',
        username: 'tester',
        credentialId: 'credential-beta',
      );
      var shellMounted = false;
      final semantics = tester.ensureSemantics();
      try {
        await app.openTerminalTab(alphaHost);
        final alphaTab = app.activeTerminalTab!;
        alphaTab.appendShellIntegrationHistory([
          ShellIntegrationCompletedCommand(
            commandId: 1,
            command: 'echo ALPHA_LOCAL_ONLY',
            exitStatus: 0,
            startedAt: DateTime.utc(2026, 10, 7),
            completedAt: DateTime.utc(2026, 10, 7, 12),
          ),
        ]);
        app.shellHistoryRecords.add(
          ShellHistoryRecord(
            id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            hostRecordId: alphaHost.id,
            command: 'echo ALPHA_SYNCED_ONLY',
            exitStatus: 0,
            startedAtMs: DateTime.utc(2026, 10, 8).millisecondsSinceEpoch,
            completedAtMs: DateTime.utc(2026, 10, 8, 12).millisecondsSinceEpoch,
            sourceDeviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          ),
        );
        await app.openTerminalTab(betaHost);
        final betaTab = app.activeTerminalTab!;
        betaTab.appendShellIntegrationHistory(
          List.generate(
            12,
            (index) => ShellIntegrationCompletedCommand(
              commandId: index + 1,
              command: 'echo BETA_ONLY_$index',
              exitStatus: 0,
              startedAt: DateTime.utc(
                2026,
                10,
                8,
              ).add(Duration(seconds: index)),
              completedAt: DateTime.utc(
                2026,
                10,
                8,
                13,
              ).add(Duration(seconds: index)),
            ),
          ),
        );
        app.snippets.add(
          const SnippetRecord(
            id: 'snippet-one-line',
            title: 'One line',
            body: 'echo SNIPPET_ONLY',
            shell: 'bash',
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(
                controller: app,
                enableWebCommandSuggestionsForTesting: true,
              ),
            ),
          ),
        );
        shellMounted = true;
        await tester.pump();

        final betaConnection = connections[betaHost.id]!;
        final alphaConnection = connections[alphaHost.id]!;
        expect(betaConnection.inputs, isEmpty);
        expect(alphaConnection.inputs, isEmpty);
        await _openTerminalAction(tester, 'terminal-command-suggestions');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-command-suggestions-dialog')),
          findsOneWidget,
        );
        final queryField = find.byKey(
          const ValueKey('terminal-command-suggestion-query'),
        );
        await tester.enterText(queryField, 'BETA_ONLY');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-command-suggestion-0')),
          findsOneWidget,
        );
        expect(find.text('10 suggestions'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('terminal-command-suggestion-10')),
          findsNothing,
        );
        expect(find.text('echo BETA_ONLY_11'), findsOneWidget);
        expect(find.text('echo BETA_ONLY_1'), findsNothing);
        expect(find.text('echo ALPHA_SYNCED_ONLY'), findsNothing);
        expect(betaConnection.inputs, isEmpty);

        await tester.tap(
          find.byKey(const ValueKey('terminal-command-suggestion-0')),
        );
        await tester.pumpAndSettle();
        expect(betaConnection.inputs, ['echo BETA_ONLY_11']);
        expect(betaConnection.inputs.single, isNot(contains('\n')));
        expect(betaConnection.inputs.single, isNot(contains('\r')));
        expect(alphaConnection.inputs, isEmpty);

        final betaInputsBeforeDictionarySelection =
            betaConnection.inputs.length;
        await _openTerminalAction(tester, 'terminal-command-suggestions');
        await tester.pumpAndSettle();
        await tester.enterText(queryField, 'unam');
        await tester.pumpAndSettle();
        expect(find.text('uname'), findsOneWidget);
        expect(
          betaConnection.inputs,
          hasLength(betaInputsBeforeDictionarySelection),
        );
        await tester.tap(find.text('uname'));
        await tester.pumpAndSettle();
        expect(
          betaConnection.inputs,
          hasLength(betaInputsBeforeDictionarySelection + 1),
        );
        expect(betaConnection.inputs.last, 'uname');
        expect(betaConnection.inputs.last, isNot(contains('\n')));
        expect(betaConnection.inputs.last, isNot(contains('\r')));
        expect(alphaConnection.inputs, isEmpty);

        await _openTerminalAction(tester, 'terminal-command-suggestions');
        await tester.pumpAndSettle();
        await tester.enterText(queryField, 'SNIPPET_ONLY');
        await tester.pumpAndSettle();
        expect(find.text('echo SNIPPET_ONLY'), findsOneWidget);
        expect(betaConnection.inputs, ['echo BETA_ONLY_11', 'uname']);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-command-suggestions-dialog')),
          findsNothing,
        );
        expect(betaConnection.inputs, ['echo BETA_ONLY_11', 'uname']);

        await _openTerminalAction(tester, 'terminal-command-suggestions');
        await tester.pumpAndSettle();
        await tester.enterText(queryField, 'SNIPPET_ONLY');
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('terminal-command-suggestion-0')),
        );
        await tester.pumpAndSettle();
        expect(betaConnection.inputs, [
          'echo BETA_ONLY_11',
          'uname',
          'echo SNIPPET_ONLY',
        ]);
        expect(betaConnection.inputs.last, isNot(contains('\n')));
        expect(betaConnection.inputs.last, isNot(contains('\r')));
        expect(alphaConnection.inputs, isEmpty);

        await tester.tap(
          find.bySemanticsLabel('Alpha terminal tab, connected, inactive'),
        );
        await tester.pumpAndSettle();
        await _openTerminalAction(tester, 'terminal-command-suggestions');
        await tester.pumpAndSettle();
        await tester.enterText(queryField, 'BETA_ONLY');
        await tester.pumpAndSettle();
        expect(find.text('No matching single-line commands.'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('terminal-command-suggestion-0')),
          findsNothing,
        );
        expect(find.text('echo BETA_ONLY_11'), findsNothing);
        await tester.enterText(queryField, 'ALPHA_SYNCED_ONLY');
        await tester.pumpAndSettle();
        expect(find.text('echo ALPHA_SYNCED_ONLY'), findsOneWidget);
        expect(find.text('echo ALPHA_LOCAL_ONLY'), findsNothing);
        await tester.tap(find.text('Close').last);
        await tester.pumpAndSettle();
        expect(alphaConnection.inputs, isEmpty);
        expect(betaConnection.inputs, [
          'echo BETA_ONLY_11',
          'uname',
          'echo SNIPPET_ONLY',
        ]);
      } finally {
        if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        await database.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _RecordingConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );
  final inputs = <String>[];

  @override
  late final portForwards = SshPortForwardManager(
    _FakeSshClient(),
    platform: _UnsupportedPortForwardPlatform(),
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    await portForwards.closeAll();
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient extends Fake implements SSHClient {}

class _UnsupportedPortForwardPlatform extends Fake
    implements SshPortForwardPlatform {
  @override
  bool get isSupported => false;
}

Future<void> _openTerminalAction(WidgetTester tester, String id) async {
  final menu = find.byKey(const ValueKey('terminal_function_menu'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  final action = find.byKey(ValueKey(id));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}
