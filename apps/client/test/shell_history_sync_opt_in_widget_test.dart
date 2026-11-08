// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Vault history sync requires explicit confirmation and is off by default',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final connections = <_HistorySyncConnection>[];
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final identity = DeviceIdentity.create(sodium);
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(const FlutterSecureStorage()),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    final connection = _HistorySyncConnection();
                    connections.add(connection);
                    return connection;
                  },
            )
            ..session = AuthSession(
              accountId: 'account-shell-history-sync-ui',
              accessToken: 'test-access-token',
              expiresIn: 3600,
              refreshToken: 'test-refresh-token',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..serverUrl = 'https://history-sync.example.test'
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..credentials.add(
              const CredentialRecord(
                id: 'history-sync-ui-credential',
                name: 'History sync UI credential',
                username: 'tester',
                secret: 'not-used',
              ),
            );
      const host = HostRecord(
        id: 'history-sync-ui-host',
        name: 'History sync UI host',
        address: 'history-sync.example.test',
        username: 'tester',
        credentialId: 'history-sync-ui-credential',
      );
      final previousTargetPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var shellMounted = false;
      try {
        await app.openTerminalTab(host);
        await app.loadShellHistorySyncPreference();
        expect(app.shellHistorySyncEnabled, isFalse);

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
          find.byKey(const ValueKey('shell-history-vault-sync')),
          findsOneWidget,
        );
        expect(
          find.textContaining('uploads up to 500 existing local commands'),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('shell-history-vault-sync')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text('Sync command history to this Vault?'),
          findsOneWidget,
        );
        expect(
          find.textContaining('any Vault member with access can read them'),
          findsOneWidget,
        );
        expect(app.shellHistorySyncEnabled, isFalse);

        await tester.tap(find.text('Cancel'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Sync command history to this Vault?'), findsNothing);
        expect(app.shellHistorySyncEnabled, isFalse);
        expect(connections.single.inputs, isEmpty);
      } finally {
        if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
        if (app.terminalTabs.isNotEmpty) {
          await tester.runAsync(
            () => app.closeTerminalTab(app.terminalTabs.first.id),
          );
        }
        for (final connection in connections) {
          await tester.runAsync(
            () => connection.closedFuture.timeout(const Duration(seconds: 2)),
          );
        }
        debugDefaultTargetPlatformOverride = previousTargetPlatform;
        app.dispose();
        await database.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _HistorySyncConnection implements SshConnection {
  _HistorySyncConnection() {
    _output = StreamController<String>.broadcast(sync: true);
  }

  late final StreamController<String> _output;
  final _closedCompleter = Completer<void>();
  final inputs = <String>[];
  bool closed = false;

  Future<void> get closedFuture => _closedCompleter.future;

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
