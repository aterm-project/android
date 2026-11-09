import 'package:aterm_client/domain/window_combination.dart';

import 'support/settings_navigation.dart';

import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_namespace.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/ssh_forwarding_page.dart';
import 'package:aterm_client/ui/terminal_palette_picker.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';
import 'package:aterm_client/l10n/l10n.dart';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File catalogFile;
  late LocalProfileCatalog catalog;
  late VaultCrypto crypto;
  late List<LocalVaultDatabase> openedDatabases;
  late List<UnlockedLocalProfile> profileFixtures;
  late List<UnlockedLocalProfile> profileQueue;
  late LocalProfileRecord profileTemplate;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
    final fixtureCatalog = LocalProfileCatalog.forTesting(
      NativeDatabase.memory(),
    );
    final fixtureService = LocalProfileService(
      catalog: fixtureCatalog,
      crypto: crypto,
    );
    final first = await fixtureService.create(
      password: 'correct horse battery staple',
    );
    final second = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final third = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final fourth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final fifth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final sixth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final seventh = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final eighth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final ninth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final tenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final eleventh = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final twelfth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final thirteenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final fourteenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final fifteenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    // The encrypted-combination homepage test also creates a profile. Every
    // fake create/unlock consumes one real unlocked fixture from this pool.
    final sixteenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    final seventeenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    // The Home Add/sharing row test creates one more profile.
    final eighteenth = await fixtureService.unlock(
      profileId: first.record.profileId,
      password: 'correct horse battery staple',
    );
    profileTemplate = first.record;
    profileFixtures = [
      first,
      second,
      third,
      fourth,
      fifth,
      sixth,
      seventh,
      eighth,
      ninth,
      tenth,
      eleventh,
      twelfth,
      thirteenth,
      fourteenth,
      fifteenth,
      sixteenth,
      seventeenth,
      eighteenth,
    ];
    profileQueue = [...profileFixtures];
    await fixtureCatalog.close();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-local-flow-');
    catalogFile = File('${directory.path}/catalog.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    openedDatabases = [];
  });

  tearDown(() async {
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // The flow may already have closed it during lock or exit.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  tearDownAll(() async {
    for (final profile in profileFixtures) {
      await profile.lock();
    }
  });

  LocalProfileFlow flow({
    required VoidCallback onExit,
    LocalProfileCatalog? catalogOverride,
    LocalHostRepositoryFactory? repositoryFactory,
    DatabaseQuarantineRegistry? quarantineRegistry,
    Object? profileCreateFailure,
  }) => LocalProfileFlow(
    catalog: catalogOverride ?? catalog,
    service: _FlowProfileService(
      catalog: catalog,
      template: profileTemplate,
      unlockedProfiles: profileQueue,
      createFailure: profileCreateFailure,
    ),
    crypto: crypto,
    onExit: onExit,
    repositoryFactory: repositoryFactory,
    quarantineRegistry: quarantineRegistry ?? DatabaseQuarantineRegistry(),
    databaseFactory: (profile, {required mode}) async {
      final record = profile.record;
      final database = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(
          File('${directory.path}/vault-${record.profileId}.sqlite'),
        ),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
        mode: mode,
      );
      openedDatabases.add(database);
      return database;
    },
  );

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
    fail('Local profile flow did not finish its pending operation.');
  }

  Future<void> pumpFlow(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(), home: child));
    await pumpUntilIdle(tester);
  }

  Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('Expected widget did not become visible.');
  }

  testWidgets(
    'local forwarding keeps its source across runtime locale changes',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final language = AppLanguageController.instance;
      await language.setPreference(AppLanguage.japanese);
      final localFlow = flow(onExit: () {});
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: language,
          builder: (_, _) => MaterialApp(
            locale: language.locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(),
            home: localFlow,
          ),
        ),
      );
      await pumpUntilIdle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      await tester.tap(find.byKey(const ValueKey('home_nav_forwarding')));
      await tester.pumpAndSettle();
      final page = tester.widget<SshForwardingPage>(
        find.byType(SshForwardingPage),
      );
      for (final preference in [
        AppLanguage.japanese,
        AppLanguage.english,
        AppLanguage.russian,
        AppLanguage.chinese,
        AppLanguage.system,
      ]) {
        await language.setPreference(preference);
        await tester.pumpAndSettle();
        final updated = tester.widget<SshForwardingPage>(
          find.byType(SshForwardingPage),
        );
        expect(updated.source, same(page.source));
        expect(updated.controller, same(page.controller));
        final l10n = appLocalizationsFor(language.locale);
        expect(
          page.source.storageDescription,
          l10n.profilesAreEncryptedInsideThisHost2,
        );
        expect(
          find.textContaining(l10n.profilesAreEncryptedInsideThisHost2),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'local topbar palette filters live and opens the quick credential editor',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpFlow(tester, flow(onExit: () {}));
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final search = find.byKey(const ValueKey('local_host_search'));
      expect(search, findsNothing);
      // A landscape keyboard can leave the empty inventory shorter than its
      // illustration. The page behind the editor must stay scrollable.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.viewInsets = const FakeViewPadding(bottom: 465);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tapWorkspaceAction(tester, 'local_host_add');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        'Local production',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_address')),
        'production.example.test',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_username')),
        'root',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_password')),
        'test-password',
      );
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local_host_save')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('workspace_host_search_button')),
      );
      await tester.pumpAndSettle();
      final palette = find.byKey(const ValueKey('host_search_palette'));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('host_search_filters'))).dy,
        greaterThan(tester.getBottomLeft(search).dy),
      );
      await tester.enterText(search, 'no-match');
      await tester.pump();
      expect(
        find.descendant(of: palette, matching: find.text('Local production')),
        findsNothing,
      );
      await tester.enterText(search, 'production');
      await tester.pump();
      expect(
        find.descendant(of: palette, matching: find.text('Local production')),
        findsOneWidget,
      );
      await tester.enterText(search, 'rdp admin@desktop.example.test -p 3390');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('local_host_address')))
            .controller!
            .text,
        'desktop.example.test',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('local_host_port')))
            .controller!
            .text,
        '3390',
      );
      expect(find.text(currentL10n.saveAndConnect), findsOneWidget);
      await tester.tap(find.text(currentL10n.cancel));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local Home Add row sits below search, routes RDP to the editor and is Local only',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpFlow(tester, flow(onExit: () {}));
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      expect(tester.takeException(), isNull);
      final search = find.byKey(const ValueKey('local_home_search'));
      final add = find.byKey(const ValueKey('local_home_add'));
      expect(add, findsOneWidget);
      expect(tester.getTopLeft(add).dy, greaterThan(tester.getBottomLeft(search).dy));
      expect(tester.getRect(add).right, lessThanOrEqualTo(390));
      // No Vault in a local Profile: never other users or a shared state.
      expect(find.text(currentL10n.homeSharingLocalOnly), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'local_home_sharing_avatar_',
              ),
        ),
        findsNothing,
      );
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local_home_add_console')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local_home_add_rdp')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<HostProtocol>>(
              find.byKey(const ValueKey('local_host_protocol')),
            )
            .initialValue,
        HostProtocol.rdp,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('local_host_port')))
            .controller!
            .text,
        '3389',
      );
      await tester.tap(find.text(currentL10n.cancel));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_home_sharing')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home_local_sharing_dialog')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local homepage shows encrypted combinations and rejects missing host before connecting',
    (tester) async {
      LocalHostRepository? repository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  repository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      await tester.runAsync(
        () => repository!.createPreference(
          scope: 'workspace',
          key: 'windowCombinations',
          platformFamily: 'all',
          value: WindowCombination.encode([
            WindowCombination(
              id: 'missing-layout',
              name: 'Saved mixed layout',
              panes: [CombinationPane(kind: 'rdp', hostId: 'missing-host')],
              tree: {'pane': 0},
              activePane: 0,
            ),
          ]),
        ),
      );
      await tester.tap(find.byTooltip(currentL10n.hostMenuClickToOpen));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.host).last);
      await pumpUntilIdle(tester);
      await pumpUntilVisible(tester, find.text('Saved mixed layout · 1'));
      expect(find.textContaining('主机不存在'), findsNothing);
      await tester.tap(find.text('Saved mixed layout · 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('主机不存在或协议已更改'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('navigation and status stay inside system insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    const insets = FakeViewPadding(top: 32, bottom: 24, left: 20, right: 12);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.reset);
    await pumpFlow(tester, flow(onExit: () {}));
    final menu = find.byTooltip(currentL10n.hostMenuClickToOpen);
    final menuRect = tester.getRect(menu);
    expect(menuRect.top, greaterThanOrEqualTo(32));
    expect(menuRect.right, lessThanOrEqualTo(788));
    final status = tester.getRect(
      find.byKey(const ValueKey('workspace_status_bar')),
    );
    expect(status.left, greaterThanOrEqualTo(20));
    expect(status.bottom, lessThanOrEqualTo(576));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.settings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows has no workspace footer row', (tester) async {
    await pumpFlow(tester, flow(onExit: () {}));
    expect(find.byKey(const ValueKey('workspace_status_bar')), findsNothing);
    expect(find.byType(WorkspaceStatusBar), findsOneWidget);
    expect(find.byTooltip(currentL10n.hostMenuClickToOpen), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'creates local profile, rejects a bad password, persists encrypted Host CRUD, locks and exits',
    (tester) async {
      var didExit = false;
      LocalHostRepository? activeRepository;
      await pumpFlow(
        tester,
        flow(
          onExit: () => didExit = true,
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );

      expect(find.byKey(const ValueKey('workspace-tab-hosts')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('local_profile_create_password')),
        findsOneWidget,
      );
      expect(find.text(currentL10n.noLocalProfilesYet), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('local_profile_create_password')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'short',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('至少需要 12 个字符'), findsOneWidget);
      expect(await catalog.list(), isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.noHostsYet), findsOneWidget);
      await tester.tap(find.byTooltip(currentL10n.hostMenuClickToOpen));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local_profile_lock')), findsOneWidget);
      await tester.tapAt(const Offset(10, 200));
      await tester.pumpAndSettle();
      final profileId = (await catalog.list()).single.profileId;

      const hostNameSecret = 'private-host-name-sentinel-8fb2';
      await _tapWorkspaceAction(tester, 'local_host_add');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        hostNameSecret,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_address')),
        'private.example.test',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_username')),
        'deploy',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_tags')),
        'production, edge',
      );
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      expect(find.text(hostNameSecret), findsAtLeastNWidgets(1));
      expect(find.text('deploy@private.example.test:22'), findsOneWidget);

      final vaultFile = File('${directory.path}/vault-$profileId.sqlite');
      final vaultFileData = await tester.runAsync(() async {
        final exists = await vaultFile.exists();
        final contents = String.fromCharCodes(await vaultFile.readAsBytes());
        return (exists, contents);
      });
      expect(vaultFileData?.$1, isTrue);
      expect(vaultFileData?.$2, isNot(contains(hostNameSecret)));

      const credentialSecret = 'private-password-sentinel-9c27';
      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.noCredentialsYet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local_credential_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_name')),
        'Local deploy credential',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_username')),
        'deploy',
      );
      final secretField = tester.widget<TextField>(
        find.byKey(const ValueKey('local_credential_secret')),
      );
      expect(secretField.obscureText, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_secret')),
        credentialSecret,
      );
      await tester.tap(find.byKey(const ValueKey('local_credential_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Local deploy credential'), findsOneWidget);
      expect(find.text(credentialSecret), findsNothing);
      var credentials = await activeRepository!.listCredentials();
      expect(credentials.single.secret, credentialSecret);

      final credentialVaultFile = File(
        '${directory.path}/vault-$profileId.sqlite',
      );
      final credentialVaultText = await tester.runAsync(() async {
        return String.fromCharCodes(await credentialVaultFile.readAsBytes());
      });
      expect(credentialVaultText, isNot(contains(credentialSecret)));

      await tester.tap(find.text('Local deploy credential'));
      await pumpUntilVisible(tester, find.text(currentL10n.editLocalCredential));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('local_credential_secret')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_name')),
        'Updated local credential',
      );
      await tester.tap(find.byKey(const ValueKey('local_credential_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Updated local credential'), findsOneWidget);
      expect(find.text(credentialSecret), findsNothing);
      credentials = await activeRepository!.listCredentials();
      expect(credentials.single.name, 'Updated local credential');
      expect(credentials.single.secret, credentialSecret);

      const privateKeyMaterial = 'private-key-material-sentinel-a418';
      const privateKeyPassphrase = 'private-key-passphrase-sentinel-52d0';
      await tester.tap(find.byKey(const ValueKey('local_credential_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_name')),
        'Local key credential',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_username')),
        'deploy',
      );
      await tester.tap(find.byKey(const ValueKey('local_credential_kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.sshPrivateKey).last);
      await tester.pumpAndSettle();
      final privateKeyField = tester.widget<TextField>(
        find.byKey(const ValueKey('local_credential_private_key')),
      );
      expect(privateKeyField.obscureText, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_private_key')),
        privateKeyMaterial,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_passphrase')),
        privateKeyPassphrase,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('local_credential_passphrase')),
            )
            .obscureText,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('local_credential_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Local key credential'), findsOneWidget);
      expect(find.text(privateKeyMaterial), findsNothing);
      expect(find.text(privateKeyPassphrase), findsNothing);
      credentials = await activeRepository!.listCredentials();
      final keyCredential = credentials.singleWhere(
        (credential) => credential.name == 'Local key credential',
      );
      expect(keyCredential.privateKey, privateKeyMaterial);
      expect(keyCredential.passphrase, privateKeyPassphrase);
      final keyVaultText = await tester.runAsync(() async {
        return String.fromCharCodes(await credentialVaultFile.readAsBytes());
      });
      expect(keyVaultText, isNot(contains(privateKeyMaterial)));
      expect(keyVaultText, isNot(contains(privateKeyPassphrase)));

      // Exercise update and ensure a fresh unlock reads the persisted value.
      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();
      await _editHostCard(tester, hostNameSecret);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        'Updated local host',
      );
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      expect(find.text('Updated local host'), findsAtLeastNWidgets(1));

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);
      expect(find.textContaining(profileId.substring(0, 8)), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'incorrect password',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.wrongPasswordOrTheLocalProfile), findsOneWidget);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text('Updated local host'), findsAtLeastNWidgets(1));

      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();
      expect(find.text('Updated local credential'), findsOneWidget);
      expect(find.text('Local key credential'), findsOneWidget);
      expect(find.text(credentialSecret), findsNothing);
      credentials = await activeRepository!.listCredentials();
      expect(
        credentials
            .singleWhere((item) => item.name == 'Updated local credential')
            .secret,
        credentialSecret,
      );
      expect(
        credentials
            .singleWhere((item) => item.name == 'Local key credential')
            .privateKey,
        privateKeyMaterial,
      );
      expect(
        credentials
            .singleWhere((item) => item.name == 'Local key credential')
            .passphrase,
        privateKeyPassphrase,
      );

      final keyCredentialTile = find.ancestor(
        of: find.text('Local key credential'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: keyCredentialTile,
          matching: find.byTooltip(currentL10n.credentialActions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteCredential));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_credential_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(find.text('Updated local credential'), findsOneWidget);
      expect(find.text('Local key credential'), findsNothing);
      expect(await activeRepository!.listCredentials(), hasLength(1));

      await tester.tap(find.byTooltip(currentL10n.credentialActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteCredential));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_credential_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.noCredentialsYet), findsOneWidget);
      expect(await activeRepository!.listCredentials(), isEmpty);

      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(currentL10n.hostActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.delete2).last);
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.deleteHost), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local_host_delete_confirm')));
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.noHostsYet), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('local_profile_exit')));
      await pumpUntilIdle(tester);
      expect(didExit, isTrue);
      expect(find.text(currentL10n.noHostsYet), findsNothing);
    },
  );

  testWidgets('catalog read failure stays visible until retry succeeds', (
    tester,
  ) async {
    final flakyCatalog = _FailFirstListCatalog(catalog);
    await pumpFlow(tester, flow(onExit: () {}, catalogOverride: flakyCatalog));

    expect(
      find.byKey(const ValueKey('local_profile_catalog_error')),
      findsOneWidget,
    );
    expect(find.text(currentL10n.couldntReadTheLocalProfileList2), findsOneWidget);
    expect(find.text(currentL10n.noLocalProfilesYet), findsNothing);
    expect(
      find.byKey(const ValueKey('local_profile_create_button')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 10));
    expect(
      find.byKey(const ValueKey('local_profile_catalog_error')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('local_profile_retry_catalog')));
    await pumpUntilIdle(tester);
    expect(
      find.byKey(const ValueKey('local_profile_catalog_error')),
      findsNothing,
    );
    expect(find.text(currentL10n.noLocalProfilesYet), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local_profile_create_button')),
      findsOneWidget,
    );
  });

  testWidgets(
    'quarantined catalog blocks empty-state and profile creation with reload recovery',
    (tester) async {
      final registry = DatabaseQuarantineRegistry();
      await pumpFlow(tester, flow(onExit: () {}, quarantineRegistry: registry));
      expect(find.text(currentL10n.noLocalProfilesYet), findsOneWidget);

      registry.quarantine(localProfileCatalogDatabaseName);
      await tester.pumpAndSettle();

      expect(find.text(currentL10n.noLocalProfilesYet), findsNothing);
      expect(
        find.byKey(const ValueKey('local_storage_recovery_message')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_profile_reload')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_profile_create_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('local_profile_unlock_button')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('local_profile_exit')), findsNothing);
    },
  );

  testWidgets(
    'quarantined active LocalVault locks local UI but server database quarantine does not',
    (tester) async {
      final registry = DatabaseQuarantineRegistry();
      await pumpFlow(tester, flow(onExit: () {}, quarantineRegistry: registry));
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.noHostsYet), findsOneWidget);

      registry.quarantine(serverClientDatabaseName);
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.noHostsYet), findsOneWidget);

      registry.quarantine(localVaultDatabaseName(profileTemplate.profileId));
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.noHostsYet), findsNothing);
      expect(
        find.byKey(const ValueKey('local_storage_recovery_message')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_profile_reload')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('local_host_add')), findsNothing);
      expect(find.byKey(const ValueKey('local_profile_lock')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quarantined catalog profile creation does not invite blind retry',
    (tester) async {
      final catalogBefore = await catalog.list();
      expect(catalogBefore, isEmpty);
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          profileCreateFailure: const DatabaseRecoveryRequiredException(),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);

      expect(await catalog.list(), isEmpty);
      expect(find.text(currentL10n.noLocalProfilesYet), findsNothing);
      expect(
        find.byKey(const ValueKey('local_storage_recovery_message')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_profile_create_button')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'local Groups support hierarchy, Host assignment, protected deletion, encrypted recovery, and cleanup',
    (tester) async {
      LocalHostRepository? activeRepository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final profileId = (await catalog.list()).single.profileId;
      final vaultFile = File('${directory.path}/vault-$profileId.sqlite');

      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_credential_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_name')),
        'Local group default credential',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_username')),
        'deploy',
      );
      const credentialSecret = 'local-group-default-secret-7b5b';
      await tester.enterText(
        find.byKey(const ValueKey('local_credential_secret')),
        credentialSecret,
      );
      await tester.tap(find.byKey(const ValueKey('local_credential_save')));
      await pumpUntilIdle(tester);
      final defaultCredential =
          (await activeRepository!.listCredentialSummaries()).single;

      await _tapWorkspaceAction(tester, 'local_profile_groups_toggle');
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.noGroupsYet), findsOneWidget);

      const rootName = 'Engineering sentinel group';
      await tester.tap(find.byKey(const ValueKey('local_group_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_group_name')),
        rootName,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_group_default_credential')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Local group default credential · deploy · 密码').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_group_color')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#4FC3F7').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_group_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      var groups = await activeRepository!.listGroups();
      expect(groups, hasLength(1));
      expect(groups.single.group.name, rootName);
      expect(groups.single.group.color, 0x4FC3F7);
      final root = groups.single;
      expect(root.defaultCredentialId, defaultCredential.id);

      const childName = 'Production sentinel group';
      await tester.tap(find.byKey(const ValueKey('local_group_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_group_name')),
        childName,
      );
      await tester.tap(find.byKey(const ValueKey('local_group_parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(rootName).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_group_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      groups = await activeRepository!.listGroups();
      expect(groups, hasLength(2));
      final child = groups.singleWhere((group) => group.name == childName);
      expect(child.parentId, root.id);

      await tester.tap(find.byKey(const ValueKey('local_group_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_group_name')),
        ' ${childName.toLowerCase()} ',
      );
      await tester.tap(find.byKey(const ValueKey('local_group_parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(rootName).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_group_save')));
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.aGroupWithThisNameAlready), findsOneWidget);
      expect(await activeRepository!.listGroups(), hasLength(2));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('分组操作：$childName'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.editGroup2));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_group_name')),
        'Renamed production group',
      );
      await tester.tap(find.byKey(const ValueKey('local_group_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      groups = await activeRepository!.listGroups();
      final renamedChild = groups.singleWhere((group) => group.id == child.id);
      expect(renamedChild.name, 'Renamed production group');
      expect(renamedChild.parentId, root.id);

      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();
      await _tapWorkspaceAction(tester, 'local_host_add');
      await tester.pumpAndSettle();
      const hostName = 'Group linked host sentinel';
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        hostName,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_address')),
        'group-linked.example.test',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_username')),
        'deploy',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('local_host_group')),
      );
      await tester.tap(find.byKey(const ValueKey('local_host_group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Renamed production group').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      var hosts = await activeRepository!.listHosts();
      expect(hosts.single.name, hostName);
      expect(hosts.single.groupId, child.id);
      expect(hosts.single.credentialId, isNull);
      expect(
        (await activeRepository!.resolveCredentialForHost(hosts.single))?.id,
        defaultCredential.id,
      );

      await _tapWorkspaceAction(tester, 'local_profile_groups_toggle');
      await tester.pumpAndSettle();
      final childTile = find.byKey(ValueKey('local_group_${child.id}'));
      await tester.tap(
        find.descendant(
          of: childTile,
          matching: find.byTooltip('分组操作：Renamed production group'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteGroup3));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_group_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.theGroupIsStillUsedBy), findsOneWidget);
      expect(await activeRepository!.listGroups(), hasLength(2));

      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();
      final defaultCredentialTile = find.byKey(
        ValueKey('local_credential_${defaultCredential.id}'),
      );
      await tester.tap(
        find.descendant(
          of: defaultCredentialTile,
          matching: find.byTooltip(currentL10n.credentialActions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteCredential));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_credential_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(
        await activeRepository!.getCredential(defaultCredential.id),
        isNotNull,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('此凭据仍被分组“$rootName”引用。请先更改或移除该引用，再删除。'), findsOneWidget);
      expect(find.text(credentialSecret), findsNothing);
      expect(
        await activeRepository!.getCredential(defaultCredential.id),
        isNotNull,
      );

      final storedBytes = await tester.runAsync(() async {
        return String.fromCharCodes(await vaultFile.readAsBytes());
      });
      expect(storedBytes, isNot(contains(rootName)));
      expect(storedBytes, isNot(contains(childName)));
      expect(storedBytes, isNot(contains(hostName)));

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(hostName), findsAtLeastNWidgets(1));
      hosts = await activeRepository!.listHosts();
      expect(hosts.single.groupId, child.id);

      // Unassign the Host before deleting its Group. Both the storage
      // reference check and the picker path are exercised here.
      await _editHostCard(tester, hostName);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('local_host_group')),
      );
      await tester.tap(find.byKey(const ValueKey('local_host_group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.noGroup).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      hosts = await activeRepository!.listHosts();
      expect(hosts.single.groupId, isNull);

      await _tapWorkspaceAction(tester, 'local_profile_groups_toggle');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分组操作：$rootName'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.editGroup2));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_group_default_credential')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.noDefaultCredential2).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_group_save')));
      await pumpUntilIdle(tester);
      expect(
        (await activeRepository!.getGroup(root.id))?.defaultCredentialId,
        isNull,
      );
      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('local_credential_${defaultCredential.id}')),
          matching: find.byTooltip(currentL10n.credentialActions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteCredential));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_credential_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(
        await activeRepository!.getCredential(defaultCredential.id),
        isNull,
      );
      await _tapWorkspaceAction(tester, 'local_profile_groups_toggle');
      await tester.pumpAndSettle();
      for (final group in [renamedChild, root]) {
        final tile = find.byKey(ValueKey('local_group_${group.id}'));
        await tester.tap(
          find.descendant(
            of: tile,
            matching: find.byTooltip('分组操作：${group.name}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(currentL10n.deleteGroup3));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('local_group_delete_confirm')),
        );
        await pumpUntilIdle(tester);
      }
      expect(await activeRepository!.listGroups(), isEmpty);
      expect(find.text(currentL10n.noGroupsYet), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Credential deletion notices identify Host and Snippet references without secrets',
    (tester) async {
      LocalHostRepository? activeRepository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final profileId = (await catalog.list()).single.profileId;
      const hostCredentialId = '2c02f1d6-ded4-4b5b-82c3-a92a6a99ac11';
      const snippetCredentialId = '938c5aeb-cdd7-444e-ae7a-444a52b8a012';
      const hostId = '2b426cd0-c1a1-460b-8b57-4db7de741113';
      const snippetId = '16c9ecf0-b6a8-42e4-8caf-2456f112a014';
      const hostSecret = 'host-reference-secret-sentinel';
      const snippetSecret = 'snippet-reference-secret-sentinel';
      await activeRepository!.createCredential(
        const CredentialRecord(
          id: hostCredentialId,
          name: 'Host-only credential',
          username: 'deploy',
          secret: hostSecret,
        ),
      );
      await activeRepository!.createCredential(
        const CredentialRecord(
          id: snippetCredentialId,
          name: 'Snippet-only credential',
          username: 'deploy',
          secret: snippetSecret,
        ),
      );
      await activeRepository!.createHost(
        const HostRecord(
          id: hostId,
          name: 'Reference host identity',
          address: 'reference.example.test',
          username: 'deploy',
          credentialId: hostCredentialId,
        ),
      );
      await activeRepository!.createSnippet(
        const SnippetRecord(
          id: snippetId,
          title: 'Reference snippet identity',
          body: '',
          executionMode: SnippetExecutionMode.bashCommand,
          program: 'printf',
          arguments: [SnippetArgument.reference('TOKEN')],
          parameters: [
            SnippetParameter.credential(
              name: 'TOKEN',
              credentialId: snippetCredentialId,
            ),
          ],
        ),
      );

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      await _openLegacyCredentials(tester);
      await tester.pumpAndSettle();

      Future<void> attemptDelete(
        String credentialId,
        String expectedNotice,
      ) async {
        final tile = find.byKey(ValueKey('local_credential_$credentialId'));
        await tester.tap(
          find.descendant(of: tile, matching: find.byTooltip(currentL10n.credentialActions)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(currentL10n.deleteCredential));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('local_credential_delete_confirm')),
        );
        await pumpUntilIdle(tester);
        await tester.pumpAndSettle();
        expect(find.text(expectedNotice), findsOneWidget);
      }

      await attemptDelete(
        hostCredentialId,
        '此凭据仍被Host“Reference host identity”引用。请先更改或移除该引用，再删除。',
      );
      expect(find.text(hostSecret), findsNothing);
      expect(
        await activeRepository!.getCredential(hostCredentialId),
        isNotNull,
      );

      await attemptDelete(
        snippetCredentialId,
        '此凭据仍被片段“Reference snippet identity”引用。请先更改或移除该引用，再删除。',
      );
      expect(find.text(snippetSecret), findsNothing);
      expect(
        await activeRepository!.getCredential(snippetCredentialId),
        isNotNull,
      );
    },
  );

  testWidgets(
    'Local Snippets support encrypted CRUD, metadata-only listing, and unlock recovery',
    (tester) async {
      LocalHostRepository? activeRepository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = LocalHostRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final profileId = (await catalog.list()).single.profileId;
      final vaultFile = File('${directory.path}/vault-$profileId.sqlite');

      await _tapWorkspaceAction(tester, 'local_profile_snippets_toggle');
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.localModeOnlyManagesEncryptedSnippets), findsOneWidget);
      expect(find.text(currentL10n.noSnippetsYet2), findsOneWidget);

      const scriptSentinel = 'snippet-script-plaintext-sentinel-71d2';
      const firstTitle = 'Local deployment script';
      await tester.tap(find.byKey(const ValueKey('local_snippet_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_title')),
        firstTitle,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_body')),
        'printf "$scriptSentinel"',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_tags')),
        'release, local',
      );
      await tester.tap(find.byKey(const ValueKey('local_snippet_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text(firstTitle), findsOneWidget);
      expect(find.text(scriptSentinel), findsNothing);
      var snippets = await activeRepository!.listSnippets();
      expect(snippets, hasLength(1));
      expect(snippets.single.snippet.body, 'printf "$scriptSentinel"');
      expect(snippets.single.snippet.tags, ['release', 'local']);

      const updatedTitle = 'Updated local deployment script';
      const updatedSentinel = 'updated-snippet-plaintext-sentinel-42ae';
      await tester.tap(
        find.byKey(ValueKey('local_snippet_${snippets.single.id}')),
      );
      await pumpUntilVisible(tester, find.text(currentL10n.editLocalSnippet));
      expect(find.text(currentL10n.editLocalSnippet), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_title')),
        updatedTitle,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_body')),
        'echo "$updatedSentinel"',
      );
      await tester.tap(find.byKey(const ValueKey('local_snippet_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text(updatedTitle), findsOneWidget);
      expect(find.text(updatedSentinel), findsNothing);
      snippets = await activeRepository!.listSnippets();
      expect(snippets.single.snippet.title, updatedTitle);
      expect(snippets.single.snippet.body, 'echo "$updatedSentinel"');

      final rawVaultText = await tester.runAsync(() async {
        return String.fromCharCodes(await vaultFile.readAsBytes());
      });
      expect(rawVaultText, isNot(contains(firstTitle)));
      expect(rawVaultText, isNot(contains(updatedTitle)));
      expect(rawVaultText, isNot(contains(scriptSentinel)));
      expect(rawVaultText, isNot(contains(updatedSentinel)));

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);
      expect(find.text(updatedTitle), findsNothing);
      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      await _tapWorkspaceAction(tester, 'local_profile_snippets_toggle');
      await tester.pumpAndSettle();
      expect(find.text(updatedTitle), findsOneWidget);
      snippets = await activeRepository!.listSnippets();
      expect(snippets.single.snippet.body, 'echo "$updatedSentinel"');

      const structuredTitle = 'Local structured command';
      const structuredDefault = 'structured-default-plaintext-sentinel-afe9';
      await tester.tap(find.byKey(const ValueKey('local_snippet_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_title')),
        structuredTitle,
      );
      await tester.tap(find.byKey(const ValueKey('local_snippet_mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.structuredBashCommand2).last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_program')),
        'grep',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_parameters')),
        '[{"name":"pattern","type":"text","default":"$structuredDefault"}]',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_snippet_arguments')),
        '[{"kind":"literal","value":"-e"},{"kind":"parameter","name":"pattern"}]',
      );
      await tester.tap(find.byKey(const ValueKey('local_snippet_save')));
      await pumpUntilIdle(tester);
      await tester.pumpAndSettle();
      expect(find.text(structuredTitle), findsOneWidget);
      snippets = await activeRepository!.listSnippets();
      final structuredSnippet = snippets.singleWhere(
        (record) => record.snippet.title == structuredTitle,
      );
      expect(
        structuredSnippet.snippet.executionMode,
        SnippetExecutionMode.bashCommand,
      );
      expect(structuredSnippet.snippet.program, 'grep');
      expect(
        structuredSnippet.snippet.parameters.single.defaultValue,
        structuredDefault,
      );
      expect(structuredSnippet.snippet.arguments, hasLength(2));

      final structuredVaultText = await tester.runAsync(() async {
        return String.fromCharCodes(await vaultFile.readAsBytes());
      });
      expect(structuredVaultText, isNot(contains(structuredTitle)));
      expect(structuredVaultText, isNot(contains(structuredDefault)));

      await tester.tap(find.byTooltip('片段操作：$updatedTitle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteSnippet));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_snippet_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      await tester.tap(find.byTooltip('片段操作：$structuredTitle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.deleteSnippet));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_snippet_delete_confirm')),
      );
      await pumpUntilIdle(tester);
      expect(await activeRepository!.listSnippets(), isEmpty);
      expect(find.text(currentL10n.noSnippetsYet2), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local default workspace preference persists, reapplies after unlock, and reloads after a CAS conflict',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      _ConflictOnPreferenceUpdateRepository? activeRepository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  activeRepository = _ConflictOnPreferenceUpdateRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final profileId = (await catalog.list()).single.profileId;
      final vaultFile = File('${directory.path}/vault-$profileId.sqlite');

      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local_profile_preferences')),
        findsOneWidget,
      );

      await openSettingsCategory(tester, 'appearance');
      final fontSizeDropdown = find.byKey(
        const ValueKey('local_terminal_font_size_dropdown'),
      );
      await tester.ensureVisible(fontSizeDropdown);
      await tester.tap(fontSizeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('16 px').last);
      await tester.pumpAndSettle();
      final fontSizeSave = find.byKey(
        const ValueKey('local_terminal_font_size_save'),
      );
      await tester.ensureVisible(fontSizeSave);
      await tester.tap(fontSizeSave);
      await pumpUntilIdle(tester);

      final themeDropdown = find.byKey(
        const ValueKey('local_terminal_theme_dropdown'),
      );
      await tester.ensureVisible(themeDropdown);
      final lightOption = find.descendant(
        of: themeDropdown,
        matching: find.byKey(const ValueKey('terminal-theme-option-light')),
      );
      await tester.ensureVisible(lightOption);
      await tester.tap(lightOption);
      await tester.pumpAndSettle();
      final themeSave = find.byKey(const ValueKey('local_terminal_theme_save'));
      await tester.ensureVisible(themeSave);
      await tester.tap(themeSave);
      await pumpUntilIdle(tester);

      await openSettingsCategory(tester, 'shortcuts');
      final searchShortcut = find.byKey(
        const ValueKey('local_terminal_shortcut_search'),
      );
      await tester.ensureVisible(searchShortcut);
      await tester.enterText(searchShortcut, 'alt+shift+f');
      FocusManager.instance.primaryFocus?.unfocus();
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchShortcut).controller!.text,
        'alt+shift+f',
      );
      final shortcutsSave = find.byKey(
        const ValueKey('local_terminal_shortcuts_save'),
      );
      await tester.scrollUntilVisible(
        shortcutsSave,
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.widget<FilledButton>(shortcutsSave).onPressed, isNotNull);
      await tester.ensureVisible(shortcutsSave);
      await tester.pumpAndSettle();
      await tester.tap(shortcutsSave);
      await pumpUntilIdle(tester);

      await openSettingsCategory(tester, 'workspace');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local_default_section_dropdown')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_default_section_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.snippet2).last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('local_preference_save')),
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('local_preference_save')));
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.commandSnippets), findsOneWidget);
      expect(find.byKey(const ValueKey('local_snippet_add')), findsOneWidget);

      var preference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: 'defaultSection',
        platformFamily: 'all',
      );
      expect(preference, isNotNull);
      expect(preference!.value, 'snippets');
      expect(preference.scope, 'workspace');
      expect(preference.key, 'defaultSection');
      expect(preference.platformFamily, 'all');
      final fontPreference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalFontSizeKey,
        platformFamily: 'all',
      );
      expect(fontPreference!.value, '16');
      final themePreference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalThemeKey,
        platformFamily: 'all',
      );
      expect(themePreference!.value, 'light');
      final shortcutsPreference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalShortcutsKey,
        platformFamily: 'all',
      );
      final savedShortcuts = TerminalShortcutBindings.fromValue(
        shortcutsPreference!.value as String,
      );
      expect(
        savedShortcuts.chordFor(TerminalShortcutAction.search),
        'alt+shift+f',
      );
      final vaultText = await tester.runAsync(() async {
        return String.fromCharCodes(await vaultFile.readAsBytes());
      });
      expect(vaultText, isNot(contains('defaultSection')));
      expect(vaultText, isNot(contains('workspace')));
      expect(vaultText, isNot(contains('terminalFontSize')));
      expect(vaultText, isNot(contains('terminalTheme')));
      expect(vaultText, isNot(contains('terminalShortcuts')));

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.commandSnippets), findsOneWidget);
      expect(find.byKey(const ValueKey('local_snippet_add')), findsOneWidget);
      expect(find.byKey(const ValueKey('local_host_add')), findsNothing);

      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      await tester.pumpAndSettle();
      await openSettingsCategory(tester, 'appearance');
      final restoredFontSize = find.byKey(
        const ValueKey('local_terminal_font_size_dropdown'),
      );
      await tester.scrollUntilVisible(
        restoredFontSize,
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(restoredFontSize)
            .initialValue,
        16,
      );
      final restoredTheme = find.byKey(
        const ValueKey('local_terminal_theme_dropdown'),
      );
      await tester.scrollUntilVisible(
        restoredTheme,
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester
            .widget<TerminalSyncedThemeSelector>(restoredTheme)
            .selected,
        VaultTerminalThemeChoice.light,
      );
      await openSettingsCategory(tester, 'shortcuts');
      final restoredShortcut = find.byKey(
        const ValueKey('local_terminal_shortcut_search'),
      );
      await tester.scrollUntilVisible(
        restoredShortcut,
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester.widget<TextField>(restoredShortcut).controller!.text,
        'alt+shift+f',
      );
      await openSettingsCategory(tester, 'workspace');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('local_default_section_dropdown')),
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_default_section_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.credential).last);
      await tester.pumpAndSettle();
      activeRepository!.injectConflictOnNextPreferenceUpdate = true;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('local_preference_save')),
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('local_preference_save')));
      await pumpUntilIdle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(currentL10n.preferencesWereChangedByAnotherOperation), findsOneWidget);
      preference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: 'defaultSection',
        platformFamily: 'all',
      );
      expect(preference!.value, 'groups');
      expect(
        find.byKey(const ValueKey('local_profile_preferences')),
        findsOneWidget,
      );
      await openSettingsCategory(tester, 'workspace');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('local_default_section_dropdown')),
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // The Home sidebar also shows a "Groups" destination (R7); assert the
      // dropdown's own selected value.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('local_default_section_dropdown')),
          matching: find.text(currentL10n.groups),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('local_default_section_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.snippet2).last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('local_preference_save')),
        240,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('local_preference_save')));
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.commandSnippets), findsOneWidget);
      preference = await activeRepository!.getPreference(
        scope: 'workspace',
        key: 'defaultSection',
        platformFamily: 'all',
      );
      expect(preference!.value, 'snippets');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing LocalVault fails closed in the unlock UI instead of opening an empty profile',
    (tester) async {
      await pumpFlow(tester, flow(onExit: () {}));
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      final profileId = (await catalog.list()).single.profileId;
      final vaultPath = '${directory.path}/vault-$profileId.sqlite';

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);

      await tester.runAsync(() async {
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('$vaultPath$suffix');
          if (await file.exists()) await file.delete();
        }
      });

      await tester.tap(find.byKey(ValueKey('local_profile_$profileId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);

      expect(find.text(currentL10n.chooseAProfileToUnlock), findsOneWidget);
      expect(find.byKey(ValueKey('local_profile_$profileId')), findsOneWidget);
      expect(
        find.text(currentL10n.localProfileDataIsMissingOr),
        findsOneWidget,
      );
      expect(find.text(currentL10n.noHostsYet), findsNothing);
      expect(await catalog.list(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed Host write is not reported as a failed save when list refresh fails',
    (tester) async {
      _FailPostActivationListRepository? repository;
      await pumpFlow(
        tester,
        flow(
          onExit: () {},
          repositoryFactory:
              ({required database, required profile, required crypto}) =>
                  repository = _FailPostActivationListRepository(
                    database: database,
                    profile: profile,
                    crypto: crypto,
                  ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        'correct horse battery staple',
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);

      await _tapWorkspaceAction(tester, 'local_host_add');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        'Committed host',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_address')),
        'committed.example.test',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local_host_username')),
        'deploy',
      );
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);

      expect(repository, isNotNull);
      expect(
        (await repository!.readWithoutInjectedFailure()).single.name,
        'Committed host',
      );
      expect(
        find.byKey(const ValueKey('local_host_list_error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_host_list_retry')),
        findsOneWidget,
      );
      expect(find.text(currentL10n.theHostWasSavedButThe), findsOneWidget);
      expect(find.text(currentL10n.theHostSaveResultCouldntBe), findsNothing);

      await tester.tap(find.byKey(const ValueKey('local_host_list_retry')));
      await pumpUntilIdle(tester);
      expect(find.text('Committed host'), findsAtLeastNWidgets(1));
      expect(find.byKey(const ValueKey('local_host_list_error')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Avoid running Argon2 inside the widget-test fake clock while preserving the
/// real service/database/crypto contracts exercised in their focused suites.
class _FlowProfileService implements LocalProfileService {
  @override
  Future<bool> isDeviceManaged(String profileId) async => false;
  @override
  Future<UnlockedLocalProfile?> tryResume() async => null;
  @override
  Future<void> remember(UnlockedLocalProfile profile) async {}
  @override
  Future<void> forgetResume() async {}

  _FlowProfileService({
    required this.catalog,
    required this.template,
    required this.unlockedProfiles,
    this.createFailure,
  });

  final LocalProfileCatalog catalog;
  final LocalProfileRecord template;
  final List<UnlockedLocalProfile> unlockedProfiles;
  final Object? createFailure;

  @override
  Future<UnlockedLocalProfile> create({required String password}) async {
    if (createFailure != null) throw createFailure!;
    if (password.length < LocalProfileService.minimumPasswordLength) {
      throw const FormatException('Local master password is too short.');
    }
    await catalog.create(
      profileId: template.profileId,
      localDataDomainId: template.localDataDomainId,
      localVaultId: template.localVaultId,
      localDeviceId: template.localDeviceId,
      createdAt: template.createdAt,
      kdfMetadata: template.kdfMetadata,
      umkEnvelope: template.umkEnvelope,
      vaultKeyEnvelope: template.vaultKeyEnvelope,
      deviceIdentityEnvelope: template.deviceIdentityEnvelope,
    );
    return unlockedProfiles.removeAt(0);
  }

  @override
  Future<UnlockedLocalProfile> unlock({
    required String profileId,
    required String password,
  }) async {
    if (profileId != template.profileId ||
        password != 'correct horse battery staple') {
      throw const FormatException('Local profile cannot be unlocked.');
    }
    return unlockedProfiles.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailFirstListCatalog implements LocalProfileCatalog {
  _FailFirstListCatalog(this.delegate);

  final LocalProfileCatalog delegate;
  bool _shouldFail = true;

  @override
  Future<List<LocalProfileRecord>> list() async {
    if (_shouldFail) {
      _shouldFail = false;
      throw StateError('test-only catalog read failure');
    }
    return delegate.list();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailPostActivationListRepository extends LocalHostRepository {
  _FailPostActivationListRepository({
    required super.database,
    required super.profile,
    required super.crypto,
  });

  var _listCalls = 0;

  @override
  Future<List<HostRecord>> listHosts() async {
    _listCalls++;
    if (_listCalls == 2) {
      throw StateError('injected post-write refresh failure');
    }
    return super.listHosts();
  }

  Future<List<HostRecord>> readWithoutInjectedFailure() => super.listHosts();
}

class _ConflictOnPreferenceUpdateRepository extends LocalHostRepository {
  _ConflictOnPreferenceUpdateRepository({
    required super.database,
    required super.profile,
    required super.crypto,
  });

  bool injectConflictOnNextPreferenceUpdate = false;

  @override
  Future<LocalPreferenceRecord> updatePreference({
    required LocalPreferenceRecord preference,
    required String baseRevisionId,
  }) async {
    if (injectConflictOnNextPreferenceUpdate) {
      injectConflictOnNextPreferenceUpdate = false;
      await super.updatePreference(
        preference: LocalPreferenceRecord(
          id: preference.id,
          scope: preference.scope,
          key: preference.key,
          value: 'groups',
          platformFamily: preference.platformFamily,
          revisionId: preference.revisionId,
        ),
        baseRevisionId: baseRevisionId,
      );
    }
    return super.updatePreference(
      preference: preference,
      baseRevisionId: baseRevisionId,
    );
  }
}

Future<void> _openLegacyCredentials(WidgetTester tester) async {
  await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
  await tester.pumpAndSettle();
  final tile = find.byKey(const ValueKey('local_profile_credentials_toggle'));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Future<void> _editHostCard(WidgetTester tester, String name) async {
  final card = find
      .ancestor(of: find.text(name).last, matching: find.byType(Card))
      .first;
  final menu = find.descendant(
    of: card,
    matching: find.byType(PopupMenuButton<String>),
  );
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(currentL10n.edit2).last);
  await tester.pumpAndSettle();
}

Future<void> _tapWorkspaceAction(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey(id)));
  await tester.tap(find.byKey(ValueKey(id)));
  await tester.pumpAndSettle();
}
