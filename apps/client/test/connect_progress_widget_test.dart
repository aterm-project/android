import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/connect_progress_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';

const _vault = '11111111-1111-4111-8111-111111111111';
const _host = HostRecord(
  id: 'host-progress',
  name: 'Progress host',
  address: 'progress.example.test',
  username: 'tester',
  credentialId: 'credential-progress',
);

final _stop = find.byKey(const ValueKey('connect_progress_stop'));
final _retry = find.byKey(const ValueKey('connect_progress_retry'));
final _close = find.byKey(const ValueKey('connect_progress_close'));
final _pane = find.byKey(const ValueKey('connect_progress_pane'));

bool _enabled(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  return switch (widget) {
    ButtonStyleButton(:final onPressed) => onPressed != null,
    IconButton(:final onPressed) => onPressed != null,
    _ => throw StateError('Unexpected control ${widget.runtimeType}'),
  };
}

void main() {
  useAppLocaleFixture('en');

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    final label = '${size.width.toInt()}px';

    testWidgets('$label: Home connect opens a selected loading tab at once; '
        'stop, retry, failure, retry and success through the pane', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      final fixture = await _Fixture.create();
      try {
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('host_connect_host-progress')),
        );
        await tester.pump();

        // Visible and selected before the (still pending) SSH request ends.
        final tab = fixture.app.activeTerminalTab!;
        expect(fixture.app.terminalTabs, [tab]);
        expect(fixture.app.page, WorkspacePage.terminal);
        expect(_pane, findsOneWidget);
        expect(find.text('Connecting to Progress host'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Progress host terminal tab')),
          findsWidgets,
        );
        await fixture.pumpUntilAttempts(tester, 1);
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('connect_progress_stage')),
              )
              .data,
          'Opening the connection',
        );
        expect(_enabled(tester, _stop), isTrue);
        expect(_enabled(tester, _retry), isFalse);
        expect(_enabled(tester, _close), isTrue);
        _expectNoOverflow(tester);

        // Stop loading.
        await tester.tap(_stop);
        await tester.pump();
        expect(fixture.attempts.single.cancellation.isCancelled, isTrue);
        expect(find.text('Loading stopped'), findsOneWidget);
        expect(_enabled(tester, _stop), isFalse);
        expect(_enabled(tester, _retry), isTrue);

        // Retry: same tab, exactly one new request, loading again.
        await tester.tap(_retry);
        await tester.pump();
        await fixture.pumpUntilAttempts(tester, 2);
        expect(fixture.app.terminalTabs, [tab]);
        expect(find.text('Connecting to Progress host'), findsOneWidget);

        // Failure is shown in the tab with the sanitized reason.
        fixture.attempts[1].result.completeError(
          StateError('The SSH server refused the connection.'),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text("Couldn't connect to Progress host"), findsOneWidget);
        expect(
          find.text('The SSH server refused the connection.'),
          findsWidgets,
        );
        expect(_enabled(tester, _retry), isTrue);
        _expectNoOverflow(tester);

        // Retry again, then the attempt succeeds: the terminal replaces it.
        await tester.tap(_retry);
        await tester.pump();
        await fixture.pumpUntilAttempts(tester, 3);
        fixture.attempts[2].result.complete(_Connection());
        await tester.pump();
        await tester.pump();
        expect(tab.state, 'connected');
        expect(tab.connectProgress.phase, ConnectPhase.idle);
        expect(_pane, findsNothing);
        expect(find.byType(TerminalView), findsOneWidget);
        expect(fixture.attempts, hasLength(3));
        expect(fixture.app.terminalTabs, [tab]);
      } finally {
        await fixture.cleanup(tester);
      }
    });

    testWidgets('$label: Close in the loading pane cancels the request and '
        'removes the tab for good', (tester) async {
      await tester.binding.setSurfaceSize(size);
      final fixture = await _Fixture.create();
      try {
        await tester.pumpWidget(_shell(fixture.app));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('host_connect_host-progress')),
        );
        await tester.pump();
        final tab = fixture.app.activeTerminalTab!;
        await fixture.pumpUntilAttempts(tester, 1);
        await tester.tap(_close);
        await tester.pump();
        await tester.pump();
        expect(fixture.attempts.single.cancellation.isCancelled, isTrue);
        expect(fixture.app.terminalTabs, isEmpty);
        final late = _Connection();
        fixture.attempts.single.result.complete(late);
        await tester.pump();
        await tester.pump();
        expect(late.closeCount, greaterThan(0));
        expect(tab.connection, isNull);
        expect(fixture.app.terminalTabs, isEmpty);
        expect(_pane, findsNothing);
      } finally {
        await fixture.cleanup(tester);
      }
    });
  }

  testWidgets('a narrow split pane keeps all three controls tappable', (
    tester,
  ) async {
    final progress = ConnectProgress()..begin();
    var stops = 0, retries = 0, closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Center(
          child: SizedBox(
            width: 120,
            height: 320,
            child: ConnectProgressView(
              progress: progress,
              title: 'A host with a long display name',
              detail: 'SSH · tester@progress.example.test:22',
              onStop: () {
                stops++;
                progress.cancel();
              },
              onRetry: () {
                retries++;
                progress.fail(progress.begin(), 'Refused');
              },
              onClose: () => closes++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    _expectNoOverflow(tester);
    await tester.tap(_stop);
    await tester.pump();
    await tester.tap(_retry);
    await tester.pump();
    expect(find.text('Refused'), findsOneWidget);
    await tester.tap(_close);
    await tester.pump();
    expect((stops, retries, closes), (1, 1, 1));
    _expectNoOverflow(tester);
  });
}

void _expectNoOverflow(WidgetTester tester) {
  final error = tester.takeException();
  expect(error, isNull);
}

Widget _shell(AppController app) => MaterialApp(
  theme: buildAppTheme(),
  home: AppShell(controller: app),
);

class _Attempt {
  _Attempt(this.cancellation);
  final SshConnectCancellation cancellation;
  final result = Completer<SshConnection>();
}

class _Fixture {
  _Fixture(this.app, this.database, this.attempts);
  final AppController app;
  final ClientDatabase database;
  final List<_Attempt> attempts;

  Future<void> pumpUntilAttempts(WidgetTester tester, int count) async {
    for (var i = 0; i < 100 && attempts.length < count; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (attempts.length < count) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }
    expect(attempts, hasLength(count));
    await tester.pump();
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
                  final attempt = _Attempt(cancellation);
                  attempts.add(attempt);
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-progress',
            accessToken: 'test',
            expiresIn: 3600,
            refreshToken: 'test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: _vault,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..vaults.add(
            const VaultDescriptor(
              id: _vault,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            ),
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-progress',
              name: 'Credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          )
          ..hosts.add(_host);
    return _Fixture(app, database, attempts);
  }

  Future<void> cleanup(WidgetTester tester) async {
    for (final attempt in attempts) {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const SshConnectCancelledException());
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => app.disconnectAllTerminalTabs());
    app.dispose();
    await tester.runAsync(() => database.close());
    await tester.binding.setSurfaceSize(null);
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
