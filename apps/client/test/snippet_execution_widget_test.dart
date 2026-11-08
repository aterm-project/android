import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Snippet card exposes its title as an accessible label', (
    tester,
  ) async {
    final fixture = await _SnippetFixture.create();
    final semantics = tester.ensureSemantics();
    try {
      await _pumpSnippets(tester, fixture);

      final cardLabel = find.bySemanticsLabel('Snippet: Search files');
      expect(cardLabel, findsOneWidget);
      expect(tester.getSemantics(cardLabel).label, 'Snippet: Search files');
    } finally {
      await _clear(tester, fixture);
      semantics.dispose();
    }
  });

  testWidgets(
    'structured Snippet editor stores only a selected Credential reference',
    (tester) async {
      final fixture = await _SnippetFixture.create();
      fixture.app.credentials.add(
        const CredentialRecord(
          id: 'password-credential',
          name: 'API token',
          username: 'ops',
          secret: 'private-test-secret',
        ),
      );
      fixture.app.credentials.add(
        const CredentialRecord(
          id: 'second-password-credential',
          name: 'Deployment token',
          username: 'deploy',
          secret: 'second-private-test-secret',
        ),
      );
      try {
        await _pumpSnippets(tester, fixture);
        await tester.tap(find.text('New snippet'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byType(DropdownButtonFormField<SnippetExecutionMode>),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Structured Bash command').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('snippet-program')),
          'tool',
        );
        final addCredentialParameter = find.byKey(
          const ValueKey('add_credential_secret_parameter'),
        );
        await tester.ensureVisible(addCredentialParameter);
        await tester.tap(addCredentialParameter);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog).last,
            matching: find.text('Add Credential secret parameter'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('snippet-secret-credential-choice')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Deployment token').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add parameter'));
        await tester.pumpAndSettle();

        final definitions = tester
            .widget<TextField>(
              find.byKey(const ValueKey('snippet-parameter-definitions')),
            )
            .controller!
            .text;
        final parsed =
            (jsonDecode(definitions) as List).single as Map<String, dynamic>;
        expect(parsed['name'], 'token');
        expect(parsed['type'], 'credentialSecret');
        expect(parsed['credential_id'], 'second-password-credential');
        expect(definitions, isNot(contains('private-test-secret')));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } finally {
        await _clear(tester, fixture);
      }
    },
  );

  testWidgets('Cancel closes preview and sends zero PTY bytes', (tester) async {
    final fixture = await _SnippetFixture.create();
    try {
      await _pumpSnippets(tester, fixture);
      expect(find.text('Review and run'), findsOneWidget);
      expect(find.text('Run'), findsNothing);
      await _openPreview(tester);
      expect(
        find.text('Target: Connected A · a.example.test:22'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.connection.inputs, isEmpty);
    } finally {
      await _clear(tester, fixture);
    }
  });

  testWidgets(
    'structured Bash preview executes once and shows bounded exec result',
    (tester) async {
      final fixture = await _SnippetFixture.create();
      final semantics = tester.ensureSemantics();
      try {
        await _pumpSnippets(tester, fixture);
        await _openPreview(tester);
        await tester.enterText(
          find.byKey(const ValueKey('snippet-param-pattern')),
          'two words',
        );
        await tester.pump();
        const expectedPreview = "'grep' 'two words'";
        final previewFinder = find.byKey(
          const ValueKey('snippet_execution_preview'),
        );
        expect(find.text(expectedPreview), findsOneWidget);
        expect(previewFinder, findsOneWidget);
        expect(tester.getSemantics(previewFinder).label, expectedPreview);
        expect(
          find.textContaining('Bash non-interactive execution'),
          findsOneWidget,
        );
        expect(fixture.connection.execCommands, isEmpty);
        await tester.tap(find.text('Confirm and run'));
        await tester.pumpAndSettle();
        expect(fixture.connection.execCommands, hasLength(1));
        expect(fixture.connection.inputs, isEmpty);
        expect(find.text('Exit code: 0'), findsOneWidget);
        const expectedOutput = 'stdout:\nstructured output\n';
        expect(find.text(expectedOutput), findsOneWidget);
        final outputFinder = find.byKey(
          const ValueKey('snippet_execution_output'),
        );
        expect(outputFinder, findsOneWidget);
        expect(tester.getSemantics(outputFinder).label, expectedOutput);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(fixture.connection.inputs, isEmpty);
        expect(
          fixture.app.snippets.single.toJson().toString(),
          isNot(contains('two words')),
        );
      } finally {
        await _clear(tester, fixture);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'batch Snippet reviews every connected Host before sequential execution',
    (tester) async {
      final fixture = await _SnippetFixture.create(withBatchTargets: true);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: fixture.app),
          ),
        );
        await _pumpBatchUi(tester);
        final batchButton = find.byKey(
          const ValueKey('snippet-batch-run-search-snippet'),
        );
        expect(batchButton, findsOneWidget);

        await tester.tap(batchButton);
        await _pumpBatchUi(tester);
        expect(find.text('Choose connected Hosts'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('snippet-batch-target-batch-host-a')),
        );
        await _pumpBatchUi(tester);
        await tester.tap(find.text('Review 2 Hosts'));
        await _pumpBatchUi(tester);
        expect(find.text('Review batch command'), findsOneWidget);
        expect(
          find.textContaining('Target 1: Batch B · batch-b.example.test:22'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Target 2: Batch A · batch-a.example.test:22'),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('snippet-batch-param-pattern')),
          'two words',
        );
        await tester.pump();
        const expectedPreview = "'grep' 'two words'";
        expect(find.text(expectedPreview), findsNWidgets(2));
        final firstPreview = find.byKey(
          const ValueKey('snippet-batch-preview-0'),
        );
        final secondPreview = find.byKey(
          const ValueKey('snippet-batch-preview-1'),
        );
        expect(tester.getSemantics(firstPreview).label, expectedPreview);
        expect(tester.getSemantics(secondPreview).label, expectedPreview);
        expect(
          fixture.batchConnections.values.every(
            (item) => item.execCommands.isEmpty,
          ),
          isTrue,
        );
        // No command is sent until the one full-batch confirmation.
        expect(
          fixture.batchConnections.values.every(
            (item) => item.execCommands.isEmpty,
          ),
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('snippet-batch-confirm')));
        await _pumpBatchUi(tester);
        for (
          var attempt = 0;
          attempt < 8 &&
              find
                  .byKey(const ValueKey('snippet-batch-outcome-batch-host-a'))
                  .evaluate()
                  .isEmpty;
          attempt++
        ) {
          await _pumpBatchUi(tester);
        }
        expect(
          fixture.batchConnections['batch-host-a']!.execCommands,
          hasLength(1),
        );
        expect(
          fixture.batchConnections['batch-host-b']!.execCommands,
          hasLength(1),
        );
        expect(
          fixture.batchConnections.values.every((item) => item.inputs.isEmpty),
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('snippet-batch-outcome-batch-host-a')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('snippet-batch-outcome-batch-host-b')),
          findsOneWidget,
        );
        expect(find.text('Exit code: 0'), findsNWidgets(2));
        await tester.tap(find.text('Close'));
        await _pumpBatchUi(tester);

        // A fresh, explicit review after a transport error shows unknown
        // completion and leaves the following target visibly not started.
        fixture.batchConnections['batch-host-b']!.onExecute = (_, _) async =>
            throw StateError('synthetic transport failure');
        await tester.tap(batchButton);
        await _pumpBatchUi(tester);
        await tester.tap(
          find.byKey(const ValueKey('snippet-batch-target-batch-host-a')),
        );
        await _pumpBatchUi(tester);
        await tester.tap(find.text('Review 2 Hosts'));
        await _pumpBatchUi(tester);
        await tester.enterText(
          find.byKey(const ValueKey('snippet-batch-param-pattern')),
          'transport-error',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('snippet-batch-confirm')));
        await _pumpBatchUi(tester);
        for (
          var attempt = 0;
          attempt < 8 &&
              find
                  .text('Remote completion unknown · not retried')
                  .evaluate()
                  .isEmpty;
          attempt++
        ) {
          await _pumpBatchUi(tester);
        }
        expect(
          fixture.batchConnections['batch-host-b']!.execCommands,
          hasLength(2),
        );
        expect(
          fixture.batchConnections['batch-host-a']!.execCommands,
          hasLength(1),
        );
        expect(
          find.text('Remote completion unknown · not retried'),
          findsOneWidget,
        );
        expect(find.text('Not started'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await _pumpBatchUi(tester);

        // Canceling a dispatched target must be counted as unknown completion
        // even though SSH returned an SshExecResult rather than throwing.
        final cancellationStarted = Completer<void>();
        fixture.batchConnections['batch-host-b']!.onExecute =
            (_, cancellation) async {
              if (!cancellationStarted.isCompleted) {
                cancellationStarted.complete();
              }
              await cancellation.whenCancelled;
              return const SshExecResult(
                stdout: '',
                stderr: '',
                exitCode: null,
                exitSignal: null,
                cancelled: true,
              );
            };
        await tester.tap(batchButton);
        await _pumpBatchUi(tester);
        await tester.tap(
          find.byKey(const ValueKey('snippet-batch-target-batch-host-a')),
        );
        await _pumpBatchUi(tester);
        await tester.tap(find.text('Review 2 Hosts'));
        await _pumpBatchUi(tester);
        await tester.enterText(
          find.byKey(const ValueKey('snippet-batch-param-pattern')),
          'cancelled',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('snippet-batch-confirm')));
        await _pumpBatchUi(tester);
        await cancellationStarted.future.timeout(const Duration(seconds: 2));
        expect(find.text('Cancel batch'), findsOneWidget);
        await tester.tap(find.text('Cancel batch'));
        await _pumpBatchUi(tester);
        for (
          var attempt = 0;
          attempt < 8 &&
              find
                  .textContaining('remote completion unknown')
                  .evaluate()
                  .isEmpty;
          attempt++
        ) {
          await _pumpBatchUi(tester);
        }
        expect(
          find.text(
            '0 targets reported a known result; 1 remote completion unknown; 0 stopped before dispatch; 1 not started.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Remote completion unknown · not retried'),
          findsOneWidget,
        );
        await tester.tap(find.text('Close'));
        await _pumpBatchUi(tester);
      } finally {
        await _clear(tester, fixture);
        semantics.dispose();
      }
    },
  );

  testWidgets('connection change while preview is open rejects confirmation', (
    tester,
  ) async {
    final fixture = await _SnippetFixture.create();
    final replacement = _RecordingConnection();
    try {
      _replaceWithLegacySnippet(fixture);
      await _pumpSnippets(tester, fixture);
      await _openPreview(tester, action: 'Review and run');
      fixture.app
        ..terminalConnection = replacement
        ..connectedHost = const HostRecord(
          id: 'connected-b',
          name: 'Connected B',
          address: 'b.example.test',
          username: 'ops',
        );
      fixture.app.notifyListeners();
      await tester.pump();
      await tester.tap(find.text('Confirm and run'));
      await tester.pumpAndSettle();
      expect(fixture.connection.inputs, isEmpty);
      expect(replacement.inputs, isEmpty);
    } finally {
      await _clear(tester, fixture);
    }
  });

  testWidgets('legacy script sends only after explicit preview confirmation', (
    tester,
  ) async {
    final fixture = await _SnippetFixture.create();
    try {
      _replaceWithLegacySnippet(fixture);
      await _pumpSnippets(tester, fixture);
      await _openPreview(tester, action: 'Review and run');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('echo approved'),
        ),
        findsOneWidget,
      );
      expect(fixture.connection.inputs, isEmpty);
      await tester.tap(find.text('Confirm and run'));
      await tester.pumpAndSettle();
      expect(fixture.connection.inputs, ['echo approved\n']);
    } finally {
      await _clear(tester, fixture);
    }
  });

  testWidgets('running structured command can be canceled without retry', (
    tester,
  ) async {
    final fixture = await _SnippetFixture.create();
    fixture.connection.onExecute = (_, cancellation) async {
      await cancellation.whenCancelled;
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
      );
    };
    try {
      await _pumpSnippets(tester, fixture);
      await _openPreview(tester);
      await tester.enterText(
        find.byKey(const ValueKey('snippet-param-pattern')),
        'cancel-test',
      );
      tester.testTextInput.hide();
      await tester.pump();
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm and run'),
          )
          .onPressed!
          .call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('Cancel execution'), findsOneWidget);
      await tester.tap(find.text('Cancel execution'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Canceled. Remote completion status is unknown'),
        findsOneWidget,
      );
      expect(fixture.connection.execCommands, hasLength(1));
      expect(fixture.connection.inputs, isEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    } finally {
      await _clear(tester, fixture);
    }
  });

  testWidgets('unresolved SSH exec open tells the user to reconnect', (
    tester,
  ) async {
    final fixture = await _SnippetFixture.create();
    fixture.connection.onExecute = (_, cancellation) async {
      await cancellation.whenCancelled;
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
        execOpenPending: true,
      );
    };
    try {
      await _pumpSnippets(tester, fixture);
      await _openPreview(tester);
      await tester.enterText(
        find.byKey(const ValueKey('snippet-param-pattern')),
        'pending-open',
      );
      tester.testTextInput.hide();
      await tester.pump();
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm and run'),
          )
          .onPressed!
          .call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.text('Cancel execution'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('disconnect and reconnect before retrying'),
        findsOneWidget,
      );
      expect(fixture.connection.execCommands, hasLength(1));
      expect(fixture.connection.inputs, isEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    } finally {
      await _clear(tester, fixture);
    }
  });
}

Future<void> _pumpBatchUi(WidgetTester tester) async {
  // Connected terminal tabs keep xterm's cursor ticker alive. Pump bounded
  // frames here instead of waiting for every ticker to settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void _replaceWithLegacySnippet(_SnippetFixture fixture) {
  fixture.app.snippets
    ..clear()
    ..add(
      const SnippetRecord(
        id: 'legacy-snippet',
        title: 'Legacy command',
        body: 'echo approved',
      ),
    );
}

Future<void> _pumpSnippets(WidgetTester tester, _SnippetFixture fixture) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: fixture.app),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPreview(
  WidgetTester tester, {
  String action = 'Review and run',
}) async {
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
  expect(find.text('Review command execution'), findsOneWidget);
}

Future<void> _clear(WidgetTester tester, _SnippetFixture fixture) async {
  if (fixture.batchConnections.isNotEmpty) {
    for (final connection in fixture.batchConnections.values) {
      await connection.close();
    }
  }
  await tester.pumpWidget(const SizedBox.shrink());
  if (fixture.batchConnections.isEmpty) {
    await fixture.app.disconnectAllTerminalTabs();
  }
  await fixture.connection.close();
  fixture.app.dispose();
  await fixture.database.close();
}

class _SnippetFixture {
  _SnippetFixture(
    this.app,
    this.database,
    this.connection, {
    this.batchConnections = const {},
  });

  final AppController app;
  final ClientDatabase database;
  final _RecordingConnection connection;
  final Map<String, _RecordingConnection> batchConnections;

  static Future<_SnippetFixture> create({bool withBatchTargets = false}) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final connection = _RecordingConnection();
    final batchConnections = <String, _RecordingConnection>{};
    final app =
        AppController(
            sodium: await SodiumSumoInit.init(),
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorForTesting: withBatchTargets
                ? ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    final targetConnection = batchConnections.putIfAbsent(
                      host.id,
                      _RecordingConnection.new,
                    );
                    final approved = await verifyHostKey(
                      'ssh-ed25519',
                      'SHA256:${host.id}',
                    );
                    if (!approved) {
                      throw StateError('Host key validation failed.');
                    }
                    return targetConnection;
                  }
                : null,
            knownHostTrustStatusForTesting: withBatchTargets
                ? ({
                    required host,
                    required port,
                    required algorithm,
                    required fingerprint,
                  }) async => KnownHostTrustStatus.trusted
                : null,
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.snippets
          ..activeVault = const VaultDescriptor(
            id: 'vault-test',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..terminalConnection = connection
          ..connectedHost = const HostRecord(
            id: 'connected-a',
            name: 'Connected A',
            address: 'a.example.test',
            username: 'ops',
          )
          ..hosts.add(
            const HostRecord(
              id: 'connected-a',
              name: 'Connected A',
              address: 'a.example.test',
              username: 'ops',
            ),
          )
          ..snippets.add(
            const SnippetRecord(
              id: 'search-snippet',
              title: 'Search files',
              body: '',
              executionMode: SnippetExecutionMode.bashCommand,
              program: 'grep',
              parameters: [SnippetParameter.text(name: 'pattern')],
              arguments: [SnippetArgument.reference('pattern')],
            ),
          );
    if (withBatchTargets) {
      final identity = DeviceIdentity.create(app.sodium);
      const hosts = [
        HostRecord(
          id: 'batch-host-a',
          name: 'Batch A',
          address: 'batch-a.example.test',
          username: 'ops',
          credentialId: 'batch-credential-a',
        ),
        HostRecord(
          id: 'batch-host-b',
          name: 'Batch B',
          address: 'batch-b.example.test',
          username: 'ops',
          credentialId: 'batch-credential-b',
        ),
      ];
      app
        ..session = AuthSession(
          accountId: 'account-test',
          accessToken: 'access-test',
          expiresIn: 3600,
          refreshToken: 'refresh-test',
          deviceId: identity.deviceId,
          vaults: const [],
        )
        ..identity = identity
        ..terminalConnection = null
        ..connectedHost = null;
      app.hosts
        ..clear()
        ..addAll(hosts);
      app.credentials.addAll(const [
        CredentialRecord(
          id: 'batch-credential-a',
          name: 'SSH A',
          username: 'ops',
          secret: 'ssh-secret-a',
        ),
        CredentialRecord(
          id: 'batch-credential-b',
          name: 'SSH B',
          username: 'ops',
          secret: 'ssh-secret-b',
        ),
      ]);
      await app.openTerminalTab(hosts[0]);
      await app.openTerminalTab(hosts[1]);
      app
        ..session = null
        ..identity = null
        ..page = WorkspacePage.snippets;
    }
    return _SnippetFixture(
      app,
      database,
      connection,
      batchConnections: batchConnections,
    );
  }
}

class _RecordingConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast();
  final List<String> inputs = [];
  final List<String> execCommands = [];
  Future<SshExecResult> Function(String, SshExecCancellation)? onExecute;

  @override
  bool hasUnresolvedExecOpen = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 64 * 1024,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    execCommands.add(command);
    final custom = onExecute;
    if (custom != null) return custom(command, cancellation);
    return const SshExecResult(
      stdout: 'structured output\n',
      stderr: '',
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
