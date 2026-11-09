import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';

const _password = 'correct horse battery staple';
const _secret = 'test-only-local-password';

class _MemoryChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  final List<int> sent = [];
  bool closed = false;

  void emit(List<int> bytes) => incoming.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  void add(Uint8List bytes) => sent.addAll(bytes);

  @override
  Future<void> close() async {
    closed = true;
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late String hostId;
  late List<LocalVaultDatabase> openedDatabases;
  late List<_MemoryChannel> channels;
  late List<(String, int)> dialed;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-telnet-local-');
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final profile = await profileService.create(password: _password);
    profileRecord = profile.record;
    final seedDatabase = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final repository = LocalHostRepository(
      database: seedDatabase,
      profile: profile,
      crypto: crypto,
    );
    final credentialId = const Uuid().v4();
    final groupId = const Uuid().v4();
    // A group default SSH credential exists; Telnet must never send it.
    await repository.createCredential(
      CredentialRecord(
        id: credentialId,
        name: 'ssh default',
        username: 'local-admin',
        kind: AuthKind.password,
        secret: _secret,
      ),
    );
    await repository.createGroup(
      GroupRecord(id: groupId, name: 'Lab', defaultCredentialId: credentialId),
    );
    final saved = await repository.createHost(
      HostRecord(
        id: const Uuid().v4(),
        name: 'Telnet lab switch',
        address: '192.0.2.30',
        port: 2323,
        protocol: HostProtocol.telnet,
        groupId: groupId,
      ),
    );
    hostId = saved.id;
    await seedDatabase.close();
    await profile.lock();
    openedDatabases = [];
    channels = [];
    dialed = [];
    telnetConnectorOverrideForTesting = (host, port) async {
      dialed.add((host, port));
      final channel = _MemoryChannel();
      channels.add(channel);
      return channel;
    };
  });

  tearDown(() async {
    telnetConnectorOverrideForTesting = null;
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // Already closed by the flow.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (condition()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    fail('condition not met');
  }

  Finder telnetView() => find.byWidgetPredicate(
    (widget) =>
        widget is TerminalView &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'local_telnet_view_',
        ),
  );

  String screen(WidgetTester tester) {
    final terminal = tester.widget<TerminalView>(telnetView()).terminal;
    return [
      for (var i = 0; i < terminal.buffer.lines.length; i++)
        terminal.buffer.lines[i].getText(),
    ].join('\n');
  }

  testWidgets('LocalVault Telnet host opens a plaintext terminal session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
        home: LocalProfileFlow(
          catalog: catalog,
          service: profileService,
          crypto: crypto,
          onExit: () {},
          quarantineRegistry: DatabaseQuarantineRegistry(),
          databaseFactory: (profile, {required mode}) async {
            final record = profile.record;
            final database = await LocalVaultDatabase.openForTesting(
              executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
              profileId: record.profileId,
              localDataDomainId: record.localDataDomainId,
              localVaultId: record.localVaultId,
              mode: mode,
            );
            openedDatabases.add(database);
            return database;
          },
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('local_profile_${profileRecord.profileId}'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    await pumpUntil(
      tester,
      () => find.byKey(ValueKey('local_host_$hostId')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
    await pumpUntil(tester, () => telnetView().evaluate().isNotEmpty);
    await pumpUntil(tester, () => channels.isNotEmpty);

    expect(dialed.single, ('192.0.2.30', 2323));
    expect(screen(tester), contains('unencrypted'));
    final channel = channels.single;
    channel.emit([
      TelnetCommand.iac,
      TelnetCommand.will,
      TelnetOption.echo,
      ...'Password: '.codeUnits,
    ]);
    await pumpUntil(tester, () => screen(tester).contains('Password:'));
    final wire = String.fromCharCodes(channel.sent);
    expect(wire, isNot(contains(_secret)));
    expect(wire, isNot(contains('local-admin')));
    // Proactive NAWS offer and DO SGA/ECHO only; nothing else.
    expect(
      channel.sent.where((b) => b != TelnetCommand.iac).length,
      lessThan(16),
    );

    final originalTerminal = tester.widget<TerminalView>(telnetView()).terminal;
    await channel.incoming.close();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('session_restore_connection')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 4999));
    expect(channels, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await pumpUntil(tester, () => channels.length == 2);
    expect(
      tester.widget<TerminalView>(telnetView()).terminal,
      same(originalTerminal),
    );
    expect(screen(tester), contains('Password:'));
    expect(
      find.byKey(const ValueKey('session_restore_connection')),
      findsNothing,
    );

    // Closing the session through the workspace closes the transport.
    final tabBar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
    final sessionTab = tabBar.tabs.where((tab) => !tab.isHome).single;
    expect(sessionTab.canOpenFiles, isFalse, reason: 'no SFTP for Telnet');
    tabBar.onClose(sessionTab.id);
    await pumpUntil(tester, () => channel.closed);
    await pumpUntil(tester, () => channels.last.closed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  });
}
