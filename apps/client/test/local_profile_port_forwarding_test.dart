import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

const _password = 'correct horse battery staple';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// Standalone LOCAL mode (Windows/Android without a server): forwarding
/// profiles are managed from the connected SSH tab overflow and the Host
/// context menu, persisted in the encrypted local Host record, and run on the
/// tab's own SSH connection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late String hostId;
  late List<LocalVaultDatabase> openedDatabases;
  late _FakeSshHarness sshHarness;
  LocalHostRepository? activeRepository;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-local-fwd-');
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final seedProfile = await profileService.create(password: _password);
    profileRecord = seedProfile.record;
    final seedDatabase = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final seedRepository = LocalHostRepository(
      database: seedDatabase,
      profile: seedProfile,
      crypto: crypto,
    );
    final credentialId = const Uuid().v4();
    await seedRepository.createCredential(
      CredentialRecord(
        id: credentialId,
        name: 'forwarding test credential',
        username: 'local-user',
        kind: AuthKind.password,
        secret: 'test-only-local-password',
      ),
    );
    final saved = await seedRepository.createHost(
      HostRecord(
        id: const Uuid().v4(),
        name: 'Local forwarding host',
        address: 'host.example.test',
        port: 2222,
        username: 'local-user',
        credentialId: credentialId,
      ),
    );
    hostId = saved.id;
    await seedDatabase.close();
    await seedProfile.lock();
    openedDatabases = [];
    sshHarness = _FakeSshHarness();
    activeRepository = null;
  });

  tearDown(() async {
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // LocalProfileFlow may already have closed it while disposing.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> settleAsync(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('Expected widget did not become visible: $finder');
  }

  Future<void> pumpUntilIdle(WidgetTester tester) async {
    var idleFrames = 0;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      final waiting =
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      idleFrames = waiting ? 0 : idleFrames + 1;
      if (idleFrames >= 4) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('LocalProfileFlow did not finish its pending operation.');
  }

  Future<void> openTerminal(WidgetTester tester, {bool connect = true}) async {
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
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
          sshControllerFactory: (repository) => LocalProfileSshController(
            repository: repository,
            serviceForTesting: sshHarness.createService(
              knownHostDecisionLock: repository.knownHostDecisionLock,
            ),
          ),
        ),
      ),
    );
    await pumpUntilIdle(tester);
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    await pumpUntilIdle(tester);
    if (!connect) return;
    await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
    await pumpUntilVisible(
      tester,
      find.byKey(const ValueKey('local_ssh_host_key_approve')),
    );
    await tester.tap(find.byKey(const ValueKey('local_ssh_host_key_approve')));
    await pumpUntilVisible(
      tester,
      find.byKey(const ValueKey('local_ssh_terminal_view')),
    );
  }

  Future<void> terminalAction(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey(id)));
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pumpAndSettle();
  }

  Future<List<SshPortForwardProfile>> storedProfiles(
    WidgetTester tester,
  ) async {
    final hosts = await tester.runAsync(() => activeRepository!.listHosts());
    return hosts!.singleWhere((host) => host.id == hostId).portForwardProfiles;
  }

  int listeningPortFromCard(WidgetTester tester, String profileId) {
    final card = find.byKey(ValueKey('ssh-forward-profile-$profileId'));
    final texts = tester
        .widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )
        .map((text) => text.data ?? '')
        .join('\n');
    final match = RegExp(r'127\.0\.0\.1:(\d+) →').firstMatch(texts);
    expect(match, isNotNull, reason: texts);
    return int.parse(match!.group(1)!);
  }

  testWidgets('Home sidebar opens all integrated tools without starting SSH', (tester) async {
    await openTerminal(tester, connect: false);
    for (final (destination, page) in [
      ('forwarding', 'ssh-forwarding-page'),
      ('logs', 'session_logs_page'),
      ('keychain', 'keychain_page'),
    ]) {
      await tester.tap(find.byKey(ValueKey('home_nav_$destination')));
      await pumpUntilVisible(tester, find.byKey(ValueKey(page)));
      await pumpUntilIdle(tester);
      expect(tester.takeException(), isNull);
    }
    expect(sshHarness.clients, isEmpty);
    await tester.tap(find.byKey(const ValueKey('home_nav_import_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home_nav_action_local_termius_transfer')));
    // The profile operation is held while the dialog is open; its background
    // activity indicator intentionally keeps animating. Wait for the dialog
    // and real repository IO rather than demanding all animations stop.
    await pumpUntilVisible(tester, find.byKey(const ValueKey('termius_transfer_dialog')));
    await settleAsync(tester);
    expect(find.byKey(const ValueKey('termius_transfer_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('termius_transfer_close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home_nav_hosts')));
    await pumpUntilIdle(tester);
    expect(find.byKey(ValueKey('local_host_$hostId')), findsOneWidget);
    expect(sshHarness.clients, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleAsync(tester);
  });

  testWidgets(
    'local mode configures, persists, starts and cleans up SSH forwards',
    (tester) async {
      await openTerminal(tester);

      // Entry lives in the existing topbar overflow for the active SSH tab.
      await terminalAction(tester, 'local_ssh_port_forwarding');
      expect(
        find.byKey(const ValueKey('ssh-port-forwarding-dialog')),
        findsOneWidget,
      );
      expect(
        find.textContaining('local profile on this device'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Running forwards stay on this device'),
        findsOneWidget,
      );

      // Add a standard -L profile.
      await tester.tap(find.byKey(const ValueKey('ssh-forward-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-profile-name')),
        'Local database',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-destination-address')),
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-destination-port')),
        '5432',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
      await tester.pumpAndSettle();
      await pumpUntilIdle(tester);
      await pumpUntilVisible(tester, find.text('Local database'));

      final stored = await storedProfiles(tester);
      expect(stored, hasLength(1));
      final profile = stored.single;
      expect(profile.type, SshPortForwardType.local);
      expect(profile.bindAddress, '127.0.0.1');
      expect(profile.exposeToNetwork, isFalse);

      // Start it on this tab's SSH connection.
      await tester.tap(
        find.byKey(ValueKey('ssh-forward-toggle-${profile.id}')),
      );
      await settleAsync(tester);
      await pumpUntilVisible(
        tester,
        find.textContaining('Running · 0 active · 0 total'),
      );
      final port = listeningPortFromCard(tester, profile.id);

      // A client connection is accepted; the fake SSH server cannot open the
      // channel, so the failure is reported on the row without crashing.
      final probe = await tester.runAsync(
        () => Socket.connect('127.0.0.1', port),
      );
      await tester.runAsync(
        () => probe!.drain<void>().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        ),
      );
      probe!.destroy();
      await settleAsync(tester);
      expect(
        find.byKey(ValueKey('ssh-forward-connection-error-${profile.id}')),
        findsOneWidget,
      );
      expect(find.textContaining('1 total'), findsOneWidget);

      // Running profiles cannot be edited.
      expect(
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('ssh-forward-edit-${profile.id}')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // The overflow label reflects the running count.
      await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
      await tester.pumpAndSettle();
      expect(find.text('SSH port forwarding (1)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Disconnecting the tab closes the listener; nothing keeps running.
      await terminalAction(tester, 'local_ssh_disconnect');
      await settleAsync(tester);
      final refused = await tester.runAsync(() async {
        try {
          final socket = await Socket.connect('127.0.0.1', port);
          socket.destroy();
          return false;
        } on SocketException {
          return true;
        }
      });
      expect(refused, isTrue);

      // Host context menu: configure while disconnected; start is disabled.
      await tester.tap(find.byKey(const ValueKey('workspace-tab-hosts')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('local_host_$hostId')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is PopupMenuItem<String> &&
              w.value == 'local_host_port_forwarding',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Not started from a single connected SSH tab'),
        findsOneWidget,
      );
      expect(find.text('Stopped'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('ssh-forward-toggle-${profile.id}')),
            )
            .onPressed,
        isNull,
      );

      // Network exposure needs the advanced switch and an explicit confirm.
      await tester.tap(find.byKey(const ValueKey('ssh-forward-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-profile-name')),
        'LAN SOCKS',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dynamic SOCKS (-D)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-bind-address')),
        '0.0.0.0',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-forward-bind-port')),
        '1080',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Forward listeners must bind to loopback unless network exposure is confirmed',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-advanced')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('ssh-forward-expose')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ssh-forward-expose')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('ssh-forward-expose')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-forward-exposure-confirm')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('ssh-forward-exposure-cancel')),
      );
      await tester.pumpAndSettle();
      expect(await storedProfiles(tester), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ssh-forward-exposure-accept')),
      );
      await tester.pumpAndSettle();
      await pumpUntilIdle(tester);
      await pumpUntilVisible(tester, find.text('LAN SOCKS'));
      final afterExpose = await storedProfiles(tester);
      expect(afterExpose, hasLength(2));
      final socks = afterExpose.singleWhere((item) => item.name == 'LAN SOCKS');
      expect(socks.type, SshPortForwardType.dynamic);
      expect(socks.bindAddress, '0.0.0.0');
      expect(socks.exposeToNetwork, isTrue);

      // Delete through the same encrypted Host update path.
      await tester.tap(
        find.byKey(ValueKey('ssh-forward-delete-${profile.id}')),
      );
      await tester.pumpAndSettle();
      await pumpUntilIdle(tester);
      expect((await storedProfiles(tester)).map((item) => item.name), [
        'LAN SOCKS',
      ]);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await settleAsync(tester, 3);
    },
  );
}

class _FakeSshHarness {
  final sessions = <_FakeSession>[];
  final clients = <_FakeClient>[];
  final services = <SshService>[];
  int socketCount = 0;
  int userAuthenticationCount = 0;

  SshService createService({
    required KnownHostDecisionLock knownHostDecisionLock,
  }) {
    final service = SshService(
      api: null,
      deviceId: 'local-terminal-test-device',
      useRelay: false,
      knownHostDecisionLock: knownHostDecisionLock,
      directSocketConnector: (_, _) async {
        socketCount++;
        return _FakeSocket();
      },
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            final session = _FakeSession();
            sessions.add(session);
            final client = _FakeClient(
              session: session,
              authenticate: () async {
                final approved = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode(_fingerprint)),
                );
                if (!approved) throw SSHAuthFailError('untrusted key');
                userAuthenticationCount++;
              },
            );
            clients.add(client);
            return client;
          },
    );
    services.add(service);
    return service;
  }
}

class _FakeClient implements SSHClient {
  _FakeClient({
    required this.session,
    required Future<void> Function() authenticate,
  }) : _authenticated = authenticate();

  final SSHSession session;
  final Future<void> _authenticated;

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => session;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements SSHSession {
  bool get closed => _stdout.isClosed;
  final _stdout = StreamController<Uint8List>(sync: true);
  final _stderr = StreamController<Uint8List>(sync: true);

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  void emitStdout(String text) =>
      _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  void close() {
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  final writes = <List<int>>[];
  @override
  void write(Uint8List data) {
    writes.add(List<int>.of(data));
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements SSHSocket {
  _FakeSocket() {
    _outgoing.stream.listen((_) {});
  }
  final _closed = Completer<void>();
  final _outgoing = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    if (!_outgoing.isClosed) await _outgoing.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}
