import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('terminal tabs expose accessible switching and independent close', (
    tester,
  ) async {
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
            accountId: 'account-test',
            accessToken: 'access-test',
            expiresIn: 3600,
            refreshToken: 'refresh-test',
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
          ..credentials.addAll([
            const CredentialRecord(
              id: 'credential-alpha',
              name: 'Alpha credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
            const CredentialRecord(
              id: 'credential-beta',
              name: 'Beta credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          ]);
    const alphaHost = HostRecord(
      id: 'host-alpha',
      name: 'Alpha',
      address: 'alpha.example.test',
      username: 'tester',
      credentialId: 'credential-alpha',
    );
    const betaHost = HostRecord(
      id: 'host-beta',
      name: 'Beta',
      address: 'beta.example.test',
      username: 'tester',
      credentialId: 'credential-beta',
    );
    // Forwarding profiles are bound to Hosts saved in the active Vault.
    app.hosts.addAll([alphaHost, betaHost]);
    final semantics = tester.ensureSemantics();
    var shellMounted = false;

    try {
      await app.openTerminalTab(alphaHost);
      final alpha = app.activeTerminalTab!;
      connections['host-alpha']!.emit('\r\nALPHA-OUTPUT\r\n');
      await app.openTerminalTab(betaHost);
      final beta = app.activeTerminalTab!;
      connections['host-beta']!.emit('\r\nBETA-OUTPUT\r\n');

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

      expect(find.byType(TerminalView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('terminal_function_menu')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal-port-forwarding')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Beta terminal tab, connected, active'),
        findsOneWidget,
      );
      expect(find.byTooltip('Close Alpha'), findsOneWidget);
      await tester.tap(
        find.bySemanticsLabel('Alpha terminal tab, connected, inactive'),
      );
      await tester.pump();
      expect(app.activeTerminalTabId, alpha.id);
      expect(
        find.bySemanticsLabel('Alpha terminal tab, connected, active'),
        findsOneWidget,
      );
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(alpha.terminal),
      );
      expect(_bufferText(alpha), contains('ALPHA-OUTPUT'));
      expect(_bufferText(beta), contains('BETA-OUTPUT'));

      await _openTerminalAction(tester, 'terminal-port-forwarding');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-port-forwarding-dialog')),
        findsOneWidget,
      );
      expect(
        find.textContaining('browser cannot open the local TCP listeners'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-forward-profile-save')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-profile-name')),
        'Unsafe bind',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-bind-address')),
        '0.0.0.0',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Forward listeners must bind to loopback unless network exposure is confirmed',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Splitting reuses the two authenticated sessions; it does not reconnect.
      await tester.tap(
        find.byKey(ValueKey('workspace-tab-${alpha.id}')),
        buttons: 2,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Split left/right'));
      await tester.pumpAndSettle();
      expect(find.byType(TerminalView), findsNWidgets(2));
      expect(
        tester
            .widgetList<TerminalView>(find.byType(TerminalView))
            .map((view) => view.terminal)
            .toSet(),
        {alpha.terminal, beta.terminal},
      );
      expect(alpha.connection, same(connections['host-alpha']));
      expect(beta.connection, same(connections['host-beta']));
      connections['host-alpha']!.emit('SPLIT-ALPHA-LIVE');
      connections['host-beta']!.emit('SPLIT-BETA-LIVE');
      await tester.pump();
      expect(alpha.terminal.history.join(), contains('SPLIT-ALPHA-LIVE'));
      expect(beta.terminal.history.join(), contains('SPLIT-BETA-LIVE'));
      expect(
        find.byKey(const ValueKey('workspace_status_bar')),
        findsOneWidget,
      );
      expect(find.text('2 SSH'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('pane-handle-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pane-close-${alpha.id}')));
      await tester.pump();
      expect(app.terminalTabs.map((tab) => tab.id), [beta.id]);
      expect(app.activeTerminalTabId, beta.id);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(
        find.bySemanticsLabel('Alpha terminal tab, connected, active'),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel('Beta terminal tab, connected, active'),
        findsOneWidget,
      );
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(beta.terminal),
      );
      expect(find.byTooltip('Close Alpha'), findsNothing);

      await connections['host-beta']!.close();
      beta.connection = null;
      beta.state = 'failed';
      beta.errorMessage = 'SSH handshake failed. Check the SSH server and relay connection.';
      app.notifyListeners();
      await tester.pump();
      expect(find.text('SSH connection failed'), findsOneWidget);
      expect(find.text(beta.errorMessage!), findsOneWidget);
      expect(
        find.text('Choose Connect on the left to start a new session.'),
        findsOneWidget,
      );
    } finally {
      if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      app.dispose();
      await database.close();
    }
  });
}

String _bufferText(TerminalTabSession tab) {
  final lines = tab.terminal.buffer.lines;
  return List.generate(
    lines.length,
    (index) => lines[index].toString(),
  ).join('\n');
}

class _RecordingConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );
  void emit(String text) => _output.add(text);

  @override
  late final portForwards = SshPortForwardManager(
    _FakeSshClient(),
    platform: const _UnsupportedPortForwardPlatform(),
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

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

class _UnsupportedPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason =>
      'This browser cannot open the local TCP listeners required to run port forwarding.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError('Unsupported in this Web-like test.');
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
