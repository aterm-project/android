import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'AppShell challenge responses flow through AppController to the connector',
    (tester) async {
      final host = _host();
      final request =
          SSHUserInfoRequest('PAM verification', 'Enter both responses.', [
            SSHUserInfoPrompt('Visible code', true),
            SSHUserInfoPrompt('One-time code', false),
          ]);
      final connection = _TestSshConnection();
      final receivedResponses = Completer<List<String>?>();
      final fixture = await _Harness.create(
        connector:
            ({
              required host,
              required credential,
              required verifyHostKey,
              required jumpHops,
              required onUserInfoRequest,
            }) async {
              final responses = await onUserInfoRequest(host, request);
              receivedResponses.complete(responses);
              return connection;
            },
      );
      final app = fixture.app;
      Future<void>? opening;

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.askSshUserInfo, isNotNull);

        opening = app.openTerminalTab(host);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.byKey(const ValueKey('ssh-user-info-dialog')),
          findsOneWidget,
        );
        expect(
          find.text('Lifecycle target · host-lifecycle.example.test:22'),
          findsOneWidget,
        );
        expect(find.text('PAM verification'), findsOneWidget);
        expect(find.text('Enter both responses.'), findsOneWidget);
        expect(find.text('Visible code'), findsOneWidget);
        final visibleField = tester.widget<TextField>(
          find.byKey(const ValueKey('ssh-user-info-response-0')),
        );
        final hiddenField = tester.widget<TextField>(
          find.byKey(const ValueKey('ssh-user-info-response-1')),
        );
        expect(visibleField.obscureText, isFalse);
        expect(hiddenField.obscureText, isTrue);

        await tester.enterText(
          find.byKey(const ValueKey('ssh-user-info-response-0')),
          'visible-answer',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ssh-user-info-response-1')),
          'hidden-answer',
        );
        await tester.tap(find.byKey(const ValueKey('ssh-user-info-submit')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await opening;
        final responses = await receivedResponses.future;
        expect(responses, ['visible-answer', 'hidden-answer']);
        expect(app.activeTerminalTab?.connection, same(connection));
        expect(
          find.byKey(const ValueKey('ssh-user-info-dialog')),
          findsNothing,
        );
        expect(find.text('hidden-answer'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (app.terminalTabs.isNotEmpty) {
          await tester.runAsync(app.disconnectAllTerminalTabs);
        }
        app.dispose();
        await fixture.database.close();
      }
    },
  );

  test(
    'closing a challenged tab cancels its pending answer fail-closed',
    () async {
      await _expectChallengeCancellation(disconnectAllTabs: false);
    },
  );

  test(
    'disconnecting all tabs cancels the challenged tab fail-closed',
    () async {
      await _expectChallengeCancellation(disconnectAllTabs: true);
    },
  );
}

Future<void> _expectChallengeCancellation({
  required bool disconnectAllTabs,
}) async {
  final request = SSHUserInfoRequest(
    'Second factor',
    'Enter the current one-time code.',
    [SSHUserInfoPrompt('Code', false)],
  );
  final callbackStarted = Completer<void>();
  final capturedChallenge = Completer<Future<List<String>?>>();
  final fixture = await _Harness.create(
    connector:
        ({
          required host,
          required credential,
          required verifyHostKey,
          required jumpHops,
          required onUserInfoRequest,
        }) async {
          final challenge = onUserInfoRequest(host, request);
          capturedChallenge.complete(challenge);
          callbackStarted.complete();
          await challenge;
          throw StateError('The cancelled challenge unexpectedly returned.');
        },
  );
  final app = fixture.app;
  Future<void>? cancellationSignal;
  app.askSshUserInfo = (_, __, cancelled) {
    cancellationSignal = cancelled;
    return Completer<List<String>?>().future;
  };

  try {
    final opening = app.openTerminalTab(_host());
    await callbackStarted.future;
    final tab = app.activeTerminalTab!;
    final challenge = await capturedChallenge.future;

    if (disconnectAllTabs) {
      await app.disconnectAllTerminalTabs();
    } else {
      await app.closeTerminalTab(tab.id);
    }

    await expectLater(
      challenge,
      throwsA(isA<SshKeyboardInteractiveCancelled>()),
    );
    await expectLater(cancellationSignal, completes);
    await opening;

    expect(tab.closed, isTrue);
    expect(tab.state, 'closed');
    expect(app.terminalTabs, isEmpty);
  } finally {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    await fixture.database.close();
  }
}

HostRecord _host() => const HostRecord(
  id: 'host-lifecycle',
  name: 'Lifecycle target',
  address: 'host-lifecycle.example.test',
  username: 'tester',
  credentialId: 'credential-lifecycle',
);

class _Harness {
  const _Harness(this.app, this.database);

  final AppController app;
  final ClientDatabase database;

  static Future<_Harness> create({
    required SshConnectorWithUserInfoForTesting connector,
  }) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorWithUserInfoForTesting: connector,
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
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-lifecycle',
              name: 'Test credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          );
    return _Harness(app, database);
  }
}

class _TestSshConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
