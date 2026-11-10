import 'dart:async';
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
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'support/l10n_fixture.dart';

const _password = 'correct horse battery staple';

final _pane = find.byKey(const ValueKey('connect_progress_pane'));
final _stop = find.byKey(const ValueKey('connect_progress_stop'));
final _retry = find.byKey(const ValueKey('connect_progress_retry'));
final _close = find.byKey(const ValueKey('connect_progress_close'));

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

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-connect-progress-',
    );
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
        name: 'progress credential',
        username: 'local-user',
        kind: AuthKind.password,
        secret: 'test-only-local-password',
      ),
    );
    final saved = await seedRepository.createHost(
      HostRecord(
        id: const Uuid().v4(),
        name: 'Progress local host',
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

  Future<void> pumpFor(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 120 && !done(); attempt++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (done()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(done(), isTrue);
    await tester.pump();
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

  Future<_DelayedSsh> openProfile(WidgetTester tester) async {
    final ssh = _DelayedSsh();
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
                  _GatedRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                    gate: ssh,
                  ),
          sshControllerFactory: (repository) => LocalProfileSshController(
            repository: repository,
            serviceForTesting: ssh.service(repository),
          ),
        ),
      ),
    );
    await pumpUntilIdle(tester);
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    await pumpUntilIdle(tester);
    return ssh;
  }

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    final label = '${size.width.toInt()}px';

    testWidgets('$label local profile: the SSH tab shows loading before the '
        'credential lookup; stop, retry, failure, retry and close', (
      tester,
    ) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ssh = await openProfile(tester);

      ssh.credentialGate = Completer<void>();
      await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
      await tester.pump();
      // The tab is open and selected while the encrypted credential lookup
      // is still pending, so the SSH transport has not started.
      expect(ssh.sockets, isEmpty);
      expect(_pane, findsOneWidget);
      expect(find.text('Connecting to Progress local host'), findsOneWidget);
      expect(
        find.text('Checking host settings and sign-in details'),
        findsOneWidget,
      );

      final gate = ssh.credentialGate!;
      ssh.credentialGate = null;
      gate.complete();
      await pumpFor(tester, () => ssh.sockets.length == 1);
      expect(find.text('Opening the connection'), findsOneWidget);

      // Stop loading: the pending socket attempt is abandoned and a socket
      // that still arrives later is closed, never attached.
      await tester.tap(_stop);
      await tester.pump();
      expect(find.text('Loading stopped'), findsOneWidget);
      final late = _Socket();
      ssh.sockets[0].complete(late);
      await pumpFor(tester, () => late.closed);
      expect(find.text('Loading stopped'), findsOneWidget);

      // Retry: the same tab, exactly one new socket attempt.
      await tester.tap(_retry);
      await pumpFor(tester, () => ssh.sockets.length == 2);
      expect(find.text('Connecting to Progress local host'), findsOneWidget);

      // Failure is reported in the tab.
      ssh.sockets[1].completeError(const SocketException('refused'));
      await pumpFor(
        tester,
        () => find
            .text("Couldn't connect to Progress local host")
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('connect_progress_error')),
        findsOneWidget,
      );

      // Retry again, then close while loading: the tab and attempt end.
      await tester.tap(_retry);
      await pumpFor(tester, () => ssh.sockets.length == 3);
      await tester.tap(_close);
      await pumpFor(tester, () => _pane.evaluate().isEmpty);
      final afterClose = _Socket();
      ssh.sockets[2].complete(afterClose);
      await pumpFor(tester, () => afterClose.closed);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(ssh.sockets, hasLength(3));
      expect(
        find.byKey(const ValueKey('local_ssh_terminal_view')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    });
  }
}

class _DelayedSsh {
  final sockets = <Completer<SSHSocket>>[];

  /// While set, credential lookups wait for it (the user already clicked).
  Completer<void>? credentialGate;

  SshService service(LocalHostRepository repository) => SshService(
    api: null,
    deviceId: 'connect-progress-test-device',
    useRelay: false,
    knownHostDecisionLock: repository.knownHostDecisionLock,
    directSocketConnector: (_, _) {
      final socket = Completer<SSHSocket>();
      sockets.add(socket);
      return socket.future;
    },
  );
}

class _Socket implements SSHSocket {
  bool closed = false;
  final _done = Completer<void>();

  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedRepository extends LocalHostRepository {
  _GatedRepository({
    required super.database,
    required super.profile,
    required super.crypto,
    required this.gate,
  });
  final _DelayedSsh gate;

  @override
  Future<CredentialRecord?> resolveCredentialForHost(HostRecord host) async {
    final pending = gate.credentialGate;
    if (pending != null) await pending.future;
    return super.resolveCredentialForHost(host);
  }
}
