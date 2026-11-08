import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/snippet_invocation.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy confirmation sends once while target stays bound to connected host',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      const connected = HostRecord(
        id: 'connected-a',
        name: 'Connected A',
        address: 'a.example.test',
        username: 'ops',
      );
      const selected = HostRecord(
        id: 'selected-b',
        name: 'Selected B',
        address: 'b.example.test',
        username: 'ops',
      );
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = connected
        ..hosts.add(connected)
        ..selectedHost = selected;
      const snippet = SnippetRecord(
        id: 'legacy-script',
        title: 'Legacy script',
        body: 'echo approved',
      );
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(snippet);

      expect(prepared.hostId, connected.id);
      expect(prepared.hostName, connected.name);
      expect(prepared.endpoint, connected.endpoint);

      await fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
      );
      expect(connection.inputs, ['echo approved\n']);
      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
        ),
        throwsStateError,
      );
      expect(connection.inputs, hasLength(1));
      await fixture.dispose();
    },
  );

  test(
    'connection replacement after preview rejects without sending',
    () async {
      final fixture = await _Fixture.create();
      final oldConnection = _RecordingConnection();
      final newConnection = _RecordingConnection();
      const host = HostRecord(
        id: 'host-a',
        name: 'Host A',
        address: 'a.example.test',
        username: 'ops',
      );
      fixture.app
        ..terminalConnection = oldConnection
        ..connectedHost = host
        ..hosts.add(host);
      final snippet = _parameterizedSnippet();
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(
        snippet,
        values: const {'pattern': 'value'},
      );

      fixture.app
        ..terminalConnection = newConnection
        ..connectedHost = const HostRecord(
          id: 'host-b',
          name: 'Host B',
          address: 'b.example.test',
          username: 'ops',
        );
      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
          values: const {'pattern': 'value'},
        ),
        throwsStateError,
      );
      expect(oldConnection.inputs, isEmpty);
      expect(newConnection.inputs, isEmpty);
      await fixture.dispose();
    },
  );

  test(
    'Credential-secret reference is redacted and sent only over exec stdin',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      const credentialSecret = 'synthetic-secret-value';
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = const HostRecord(
          id: 'host-a',
          name: 'Host A',
          address: 'a.example.test',
          username: 'ops',
        )
        ..hosts.add(
          const HostRecord(
            id: 'host-a',
            name: 'Host A',
            address: 'a.example.test',
            username: 'ops',
          ),
        )
        ..credentials.add(
          const CredentialRecord(
            id: 'stored-credential-id',
            name: 'API token',
            username: 'ops',
            secret: credentialSecret,
          ),
        );
      const snippet = SnippetRecord(
        id: 'secret-snippet',
        title: 'Secret operation',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'tool',
        parameters: [
          SnippetParameter.credential(
            name: 'token',
            credentialId: 'stored-credential-id',
          ),
        ],
        arguments: [SnippetArgument.reference('token')],
      );
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(snippet);
      connection.execStdout = '$credentialSecret|$credentialSecret';
      connection.execStderr = credentialSecret;
      expect(preview.command, contains('Credential secret hidden: token'));
      expect(preview.canExecute, isTrue);
      expect(preview.command, isNot(contains(credentialSecret)));
      // A background sync can rehydrate an unchanged immutable record between
      // review and confirmation. Compare the captured contents, not object
      // identity, while still rejecting any changed Credential field.
      fixture.app.credentials[0] = CredentialRecord.fromJson(
        fixture.app.credentials[0].toJson(),
      );
      final result = await fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
        cancellation: SshExecCancellation(),
      );
      expect(result?.exitCode, 0);
      final maskedSecret = List<String>.filled(
        credentialSecret.length,
        '*',
      ).join();
      expect(result?.stdout, '$maskedSecret|$maskedSecret');
      expect(result?.stderr, maskedSecret);
      expect(result?.stdout, isNot(contains(credentialSecret)));
      expect(result?.stderr, isNot(contains(credentialSecret)));
      expect(connection.inputs, isEmpty);
      expect(connection.execCommands, hasLength(1));
      expect(
        connection.execCommands.single,
        isNot(contains('synthetic-secret-value')),
      );
      expect(connection.execInputData, hasLength(1));
      expect(
        String.fromCharCodes(connection.execInputData.single),
        'synthetic-secret-value\n',
      );
      expect(
        snippet.toJson().toString(),
        isNot(contains('synthetic-secret-value')),
      );
      await fixture.dispose();
    },
  );

  test(
    'Credential change after review blocks the command before exec',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      const host = HostRecord(
        id: 'host-a',
        name: 'Host A',
        address: 'a.example.test',
        username: 'ops',
      );
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = host
        ..hosts.add(host)
        ..credentials.add(
          const CredentialRecord(
            id: 'stored-credential-id',
            name: 'API token',
            username: 'ops',
            secret: 'old-secret',
          ),
        );
      const snippet = SnippetRecord(
        id: 'secret-snippet',
        title: 'Secret operation',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'tool',
        parameters: [
          SnippetParameter.credential(
            name: 'token',
            credentialId: 'stored-credential-id',
          ),
        ],
        arguments: [SnippetArgument.reference('token')],
      );
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(snippet);
      fixture.app.credentials[0] = const CredentialRecord(
        id: 'stored-credential-id',
        name: 'API token',
        username: 'ops',
        secret: 'new-secret',
      );

      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
          cancellation: SshExecCancellation(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(connection.execCommands, isEmpty);
      expect(connection.execInputData, isEmpty);
      await fixture.dispose();
    },
  );

  test(
    'structured Bash command uses one confirmed non-PTY exec and reports exit status',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = const HostRecord(
          id: 'legacy-host',
          name: 'Legacy host',
          address: 'legacy.example.test',
          username: 'ops',
        );
      fixture.app.hosts.add(fixture.app.connectedHost!);
      final snippet = _parameterizedSnippet();
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(
        snippet,
        values: const {'pattern': r'$HOME'},
      );

      expect(preview.command, "'grep' '\$HOME'");
      expect(preview.canExecute, isTrue);
      expect(preview.blockedReason, isNull);
      final result = await fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
        values: const {'pattern': r'$HOME'},
        cancellation: SshExecCancellation(),
      );
      expect(result?.stdout, 'snippet stdout');
      expect(result?.exitCode, 0);
      expect(connection.inputs, isEmpty);
      expect(connection.execCommands, hasLength(1));
      final execRequest = connection.execCommands.single;
      expect(execRequest, contains('if [ -x /bin/bash ]'));
      expect(execRequest, contains('command -v bash 2>/dev/null'));
      expect(execRequest, contains(r'exec "$bash_path" -c '));
      expect(execRequest, contains(r"'$HOME'"));
      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
          values: const {'pattern': r'$HOME'},
          cancellation: SshExecCancellation(),
        ),
        throwsStateError,
      );
      expect(connection.execCommands, hasLength(1));
      await fixture.dispose();
    },
  );

  test(
    'same snippet ID with changed content is rejected after preview',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = const HostRecord(
          id: 'host-a',
          name: 'Host A',
          address: 'a.example.test',
          username: 'ops',
        );
      fixture.app.hosts.add(fixture.app.connectedHost!);
      const original = SnippetRecord(
        id: 'same-id',
        title: 'Reviewed command',
        body: 'echo reviewed',
      );
      fixture.app.snippets.add(original);
      const changed = SnippetRecord(
        id: 'same-id',
        title: 'Changed command',
        body: 'echo changed',
      );
      final prepared = fixture.app.prepareSnippetExecution(original);
      final preview = fixture.app.previewSnippetExecution(original);

      await expectLater(
        fixture.app.executeSnippet(
          changed,
          prepared: prepared,
          confirmedPreview: preview,
        ),
        throwsStateError,
      );
      expect(connection.inputs, isEmpty);
      await fixture.dispose();
    },
  );

  test('unknown legacy shell labels are preview-only', () async {
    final fixture = await _Fixture.create();
    final connection = _RecordingConnection();
    fixture.app
      ..terminalConnection = connection
      ..connectedHost = const HostRecord(
        id: 'host-a',
        name: 'Host A',
        address: 'a.example.test',
        username: 'ops',
      );
    fixture.app.hosts.add(fixture.app.connectedHost!);
    const snippet = SnippetRecord(
      id: 'unknown-shell',
      title: 'Unknown shell',
      body: 'echo not sent',
      shell: 'unknown-shell',
    );
    fixture.app.snippets.add(snippet);
    final prepared = fixture.app.prepareSnippetExecution(snippet);
    final preview = fixture.app.previewSnippetExecution(snippet);

    expect(preview.canExecute, isFalse);
    expect(preview.blockedReason, contains('unknown shell label'));
    await expectLater(
      fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
      ),
      throwsStateError,
    );
    expect(connection.inputs, isEmpty);
    await fixture.dispose();
  });

  test('full Host snapshot change after preview rejects the command', () async {
    final fixture = await _Fixture.create();
    final connection = _RecordingConnection();
    const originalHost = HostRecord(
      id: 'host-a',
      name: 'Host A',
      address: 'a.example.test',
      username: 'ops',
    );
    fixture.app
      ..terminalConnection = connection
      ..connectedHost = originalHost
      ..hosts.add(originalHost);
    final snippet = _parameterizedSnippet();
    fixture.app.snippets.add(snippet);
    final prepared = fixture.app.prepareSnippetExecution(snippet);
    final preview = fixture.app.previewSnippetExecution(
      snippet,
      values: const {'pattern': 'value'},
    );
    final updatedHost = originalHost.copyWith(jumpHostId: 'new-bastion');
    fixture.app
      ..connectedHost = updatedHost
      ..hosts[0] = updatedHost;

    await expectLater(
      fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
        values: const {'pattern': 'value'},
        cancellation: SshExecCancellation(),
      ),
      throwsStateError,
    );
    expect(connection.execCommands, isEmpty);
    await fixture.dispose();
  });

  test(
    'changed parameter value cannot reuse an earlier preview confirmation',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection();
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = const HostRecord(
          id: 'host-a',
          name: 'Host A',
          address: 'a.example.test',
          username: 'ops',
        );
      fixture.app.hosts.add(fixture.app.connectedHost!);
      final snippet = _parameterizedSnippet();
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(
        snippet,
        values: const {'pattern': 'reviewed value'},
      );

      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
          values: const {'pattern': 'different value'},
        ),
        throwsStateError,
      );
      expect(connection.inputs, isEmpty);
      await fixture.dispose();
    },
  );

  test(
    'unresolved exec-open guard preserves the confirmation for later retry',
    () async {
      final fixture = await _Fixture.create();
      final connection = _RecordingConnection()..unresolvedExecOpen = true;
      fixture.app
        ..terminalConnection = connection
        ..connectedHost = const HostRecord(
          id: 'host-a',
          name: 'Host A',
          address: 'a.example.test',
          username: 'ops',
        );
      fixture.app.hosts.add(fixture.app.connectedHost!);
      final snippet = _parameterizedSnippet();
      fixture.app.snippets.add(snippet);
      final prepared = fixture.app.prepareSnippetExecution(snippet);
      final preview = fixture.app.previewSnippetExecution(
        snippet,
        values: const {'pattern': 'value'},
      );

      await expectLater(
        fixture.app.executeSnippet(
          snippet,
          prepared: prepared,
          confirmedPreview: preview,
          values: const {'pattern': 'value'},
          cancellation: SshExecCancellation(),
        ),
        throwsStateError,
      );
      expect(connection.execCommands, isEmpty);

      connection.unresolvedExecOpen = false;
      final result = await fixture.app.executeSnippet(
        snippet,
        prepared: prepared,
        confirmedPreview: preview,
        values: const {'pattern': 'value'},
        cancellation: SshExecCancellation(),
      );
      expect(result?.exitCode, 0);
      expect(connection.execCommands, hasLength(1));
      await fixture.dispose();
    },
  );

  test('batch execution stays bound to reviewed connected Host tabs', () async {
    final fixture = await _BatchFixture.create();
    final snippet = _batchSnippet();
    fixture.fixture.app.snippets.add(snippet);
    expect(fixture.alphaTab.state, 'connected');
    expect(fixture.betaTab.state, 'connected');
    expect(fixture.alphaTab.connection, same(fixture.alpha));
    expect(fixture.betaTab.connection, same(fixture.beta));
    final targets = [
      fixture.fixture.app.prepareSnippetExecution(
        snippet,
        terminalTabId: fixture.alphaTab.id,
      ),
      fixture.fixture.app.prepareSnippetExecution(
        snippet,
        terminalTabId: fixture.betaTab.id,
      ),
    ];
    final preview = fixture.fixture.app.previewSnippetExecution(snippet);
    final started = <String>[];
    // Switching the visible tab after review must not redirect either target.
    fixture.fixture.app.activateTerminalTab(fixture.alphaTab.id);

    final outcomes = await fixture.fixture.app.executeSnippetBatch(
      snippet: snippet,
      targets: targets,
      confirmedPreview: preview,
      cancellation: SshExecCancellation(),
      onTargetStarted: (_, target) => started.add(target.hostId),
    );

    expect(started, ['batch-host-a', 'batch-host-b']);
    expect(fixture.alpha.execCommands, hasLength(1));
    expect(fixture.beta.execCommands, hasLength(1));
    expect(outcomes, hasLength(2));
    expect(outcomes.map((item) => item.result?.exitCode), [0, 0]);
    expect(outcomes.map((item) => item.hostId), [
      'batch-host-a',
      'batch-host-b',
    ]);
    await fixture.dispose();
  });

  test(
    'batch stops at the first nonzero result and marks later Hosts skipped',
    () async {
      final fixture = await _BatchFixture.create();
      fixture.alpha.execExitCode = 23;
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final targets = fixture.prepareTargets(snippet);
      final outcomes = await fixture.fixture.app.executeSnippetBatch(
        snippet: snippet,
        targets: targets,
        confirmedPreview: fixture.fixture.app.previewSnippetExecution(snippet),
        cancellation: SshExecCancellation(),
      );

      expect(fixture.alpha.execCommands, hasLength(1));
      expect(fixture.beta.execCommands, isEmpty);
      expect(outcomes.first.result?.exitCode, 23);
      expect(outcomes.last.skipped, isTrue);
      expect(outcomes.last.error, contains('Not started'));
      await fixture.dispose();
    },
  );

  test(
    'batch preflight validates every target before the first command',
    () async {
      final fixture = await _BatchFixture.create();
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final targets = fixture.prepareTargets(snippet);
      fixture.trustByHost['batch-b.example.test'] =
          KnownHostTrustStatus.changed;

      await expectLater(
        fixture.fixture.app.executeSnippetBatch(
          snippet: snippet,
          targets: targets,
          confirmedPreview: fixture.fixture.app.previewSnippetExecution(
            snippet,
          ),
          cancellation: SshExecCancellation(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fixture.alpha.execCommands, isEmpty);
      expect(fixture.beta.execCommands, isEmpty);
      await fixture.dispose();
    },
  );

  test(
    'batch preflight rejects changed SSH credentials without dispatch',
    () async {
      final fixture = await _BatchFixture.create();
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final targets = fixture.prepareTargets(snippet);
      final credentialIndex = fixture.fixture.app.credentials.indexWhere(
        (item) => item.id == 'batch-credential-b',
      );
      fixture.fixture.app.credentials[credentialIndex] = const CredentialRecord(
        id: 'batch-credential-b',
        name: 'SSH B',
        username: 'ops',
        secret: 'changed-after-connect',
      );

      await expectLater(
        fixture.fixture.app.executeSnippetBatch(
          snippet: snippet,
          targets: targets,
          confirmedPreview: fixture.fixture.app.previewSnippetExecution(
            snippet,
          ),
          cancellation: SshExecCancellation(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fixture.alpha.execCommands, isEmpty);
      expect(fixture.beta.execCommands, isEmpty);
      await fixture.dispose();
    },
  );

  test(
    'batch cancellation marks current completion unknown and skips later Hosts',
    () async {
      final started = Completer<void>();
      final fixture = await _BatchFixture.create(
        onAlphaExecute: (cancellation) async {
          if (!started.isCompleted) started.complete();
          await cancellation.whenCancelled;
          return const SshExecResult(
            stdout: '',
            stderr: '',
            exitCode: null,
            exitSignal: null,
            cancelled: true,
          );
        },
      );
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final cancellation = SshExecCancellation();
      final execution = fixture.fixture.app.executeSnippetBatch(
        snippet: snippet,
        targets: fixture.prepareTargets(snippet),
        confirmedPreview: fixture.fixture.app.previewSnippetExecution(snippet),
        cancellation: cancellation,
      );
      await started.future;
      cancellation.cancel();
      final outcomes = await execution;

      expect(fixture.alpha.execCommands, hasLength(1));
      expect(fixture.beta.execCommands, isEmpty);
      expect(outcomes.first.result?.cancelled, isTrue);
      expect(outcomes.first.result?.exitCode, isNull);
      expect(outcomes.last.skipped, isTrue);
      await fixture.dispose();
    },
  );

  test('batch cancellation during preflight starts no targets', () async {
    final cancellation = SshExecCancellation();
    var trustChecks = 0;
    final fixture = await _BatchFixture.create(
      onTrustStatus: () {
        trustChecks++;
        if (trustChecks == 3) cancellation.cancel();
      },
    );
    final snippet = _batchSnippet();
    fixture.fixture.app.snippets.add(snippet);
    final outcomes = await fixture.fixture.app.executeSnippetBatch(
      snippet: snippet,
      targets: fixture.prepareTargets(snippet),
      confirmedPreview: fixture.fixture.app.previewSnippetExecution(snippet),
      cancellation: cancellation,
    );

    expect(fixture.alpha.execCommands, isEmpty);
    expect(fixture.beta.execCommands, isEmpty);
    expect(outcomes, hasLength(2));
    expect(outcomes.every((item) => item.skipped), isTrue);
    expect(
      outcomes.every((item) => item.error!.contains('during preflight')),
      isTrue,
    );
    await fixture.dispose();
  });

  test(
    'batch rechecks later Host credentials immediately before dispatch',
    () async {
      final fixture = await _BatchFixture.create();
      final credentialIndex = fixture.fixture.app.credentials.indexWhere(
        (item) => item.id == 'batch-credential-b',
      );
      fixture.alpha.onExecute = (_) async {
        fixture.fixture.app.credentials[credentialIndex] =
            const CredentialRecord(
              id: 'batch-credential-b',
              name: 'SSH B',
              username: 'ops',
              secret: 'changed-during-batch',
            );
        return const SshExecResult(
          stdout: '',
          stderr: '',
          exitCode: 0,
          exitSignal: null,
        );
      };
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final outcomes = await fixture.fixture.app.executeSnippetBatch(
        snippet: snippet,
        targets: fixture.prepareTargets(snippet),
        confirmedPreview: fixture.fixture.app.previewSnippetExecution(snippet),
        cancellation: SshExecCancellation(),
      );

      expect(fixture.alpha.execCommands, hasLength(1));
      expect(fixture.beta.execCommands, isEmpty);
      expect(outcomes.first.result?.exitCode, 0);
      expect(outcomes.last.skipped, isFalse);
      expect(outcomes.last.error, contains('changed before dispatch'));
      expect(outcomes.last.completionUnknown, isFalse);
      await fixture.dispose();
    },
  );

  test(
    'batch marks SSH exceptions after exec dispatch as unknown and stops',
    () async {
      final fixture = await _BatchFixture.create();
      fixture.alpha.onExecute = (_) async =>
          throw StateError('transport ended');
      final snippet = _batchSnippet();
      fixture.fixture.app.snippets.add(snippet);
      final outcomes = await fixture.fixture.app.executeSnippetBatch(
        snippet: snippet,
        targets: fixture.prepareTargets(snippet),
        confirmedPreview: fixture.fixture.app.previewSnippetExecution(snippet),
        cancellation: SshExecCancellation(),
      );

      expect(fixture.alpha.execCommands, hasLength(1));
      expect(fixture.beta.execCommands, isEmpty);
      expect(outcomes.first.completionUnknown, isTrue);
      expect(outcomes.first.error, contains('after dispatch'));
      expect(outcomes.last.skipped, isTrue);
      await fixture.dispose();
    },
  );
}

SnippetRecord _parameterizedSnippet() => const SnippetRecord(
  id: 'text-snippet',
  title: 'Search',
  body: '',
  executionMode: SnippetExecutionMode.bashCommand,
  program: 'grep',
  parameters: [SnippetParameter.text(name: 'pattern')],
  arguments: [SnippetArgument.reference('pattern')],
);

class _Fixture {
  _Fixture(this.app, this.database);

  final AppController app;
  final ClientDatabase database;

  static Future<_Fixture> create({
    SshConnectorForTesting? connector,
    KnownHostTrustStatusForTesting? knownHostTrustStatus,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = AppController(
      sodium: await SodiumSumoInit.init(),
      database: database,
      secureStore: ClientSecureStore(),
      sshConnectorForTesting: connector,
      knownHostTrustStatusForTesting: knownHostTrustStatus,
    );
    return _Fixture(app, database);
  }

  Future<void> dispose() async {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    await database.close();
  }
}

class _RecordingConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast();
  final List<String> inputs = [];
  final List<String> execCommands = [];
  final List<List<int>> execInputData = [];
  bool unresolvedExecOpen = false;
  int? execExitCode = 0;
  String execStdout = 'snippet stdout';
  String execStderr = '';
  Future<SshExecResult> Function(SshExecCancellation cancellation)? onExecute;

  @override
  bool get hasUnresolvedExecOpen => unresolvedExecOpen;

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
    if (stdinData != null) execInputData.add(List.of(stdinData));
    final custom = onExecute;
    if (custom != null) return custom(cancellation);
    return SshExecResult(
      stdout: execStdout,
      stderr: execStderr,
      exitCode: execExitCode,
      exitSignal: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SnippetRecord _batchSnippet() => const SnippetRecord(
  id: 'batch-snippet',
  title: 'Batch operation',
  body: '',
  executionMode: SnippetExecutionMode.bashCommand,
  program: 'true',
);

class _BatchFixture {
  _BatchFixture({
    required this.fixture,
    required this.alpha,
    required this.beta,
    required this.alphaTab,
    required this.betaTab,
    required this.trustByHost,
  });

  final _Fixture fixture;
  final _RecordingConnection alpha;
  final _RecordingConnection beta;
  final TerminalTabSession alphaTab;
  final TerminalTabSession betaTab;
  final Map<String, KnownHostTrustStatus> trustByHost;

  static Future<_BatchFixture> create({
    Future<SshExecResult> Function(SshExecCancellation cancellation)?
    onAlphaExecute,
    void Function()? onTrustStatus,
  }) async {
    final alpha = _RecordingConnection()..onExecute = onAlphaExecute;
    final beta = _RecordingConnection();
    final trustByHost = <String, KnownHostTrustStatus>{};
    final fixture = await _Fixture.create(
      connector:
          ({required host, required credential, required verifyHostKey}) async {
            final connection = host.id == 'batch-host-a' ? alpha : beta;
            final approved = await verifyHostKey(
              'ssh-ed25519',
              'SHA256:${host.id}',
            );
            if (!approved) throw StateError('Host key validation failed.');
            return connection;
          },
      knownHostTrustStatus:
          ({
            required host,
            required port,
            required algorithm,
            required fingerprint,
          }) async {
            onTrustStatus?.call();
            return trustByHost[host] ?? KnownHostTrustStatus.trusted;
          },
    );
    final app = fixture.app;
    final identity = DeviceIdentity.create(app.sodium);
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
      ..stage = ClientStage.workspace
      ..credentials.addAll(const [
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
      ])
      ..hosts.addAll(const [
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
      ]);
    await app.openTerminalTab(app.hosts[0]);
    final alphaTab = app.activeTerminalTab!;
    await app.openTerminalTab(app.hosts[1]);
    final betaTab = app.activeTerminalTab!;
    return _BatchFixture(
      fixture: fixture,
      alpha: alpha,
      beta: beta,
      alphaTab: alphaTab,
      betaTab: betaTab,
      trustByHost: trustByHost,
    );
  }

  List<PreparedSnippetExecution> prepareTargets(SnippetRecord snippet) => [
    fixture.app.prepareSnippetExecution(snippet, terminalTabId: alphaTab.id),
    fixture.app.prepareSnippetExecution(snippet, terminalTabId: betaTab.id),
  ];

  Future<void> dispose() => fixture.dispose();
}
