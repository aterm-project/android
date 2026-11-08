import 'support/settings_navigation.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/archive/local_profile_archive.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_profile_resume_store.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultCrypto crypto;
  late Directory directory;

  setUpAll(() async {
    // The browser flow fixture opens independent source and target profiles.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-archive-ui-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpUntilIdle(WidgetTester tester) async {
    var idleFrames = 0;
    for (var attempt = 0; attempt < 160; attempt++) {
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
    fail('Local profile archive flow did not finish its pending operation.');
  }

  Future<void> enterDialogPassword(
    WidgetTester tester, {
    required String password,
    String? confirmation,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey('local_archive_password')),
      password,
    );
    if (confirmation != null) {
      await tester.enterText(
        find.byKey(const ValueKey('local_archive_password_confirm')),
        confirmation,
      );
    }
    await tester.tap(
      find.byKey(const ValueKey('local_archive_password_continue')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'imports and re-exports Host, Credential, Group, Snippet and Preference',
    (tester) async {
      const archivePassword = 'portable-archive-password-2026';
      const localMasterPassword = 'local-profile-master-password';
      const secret = 'archive-widget-secret-sentinel-b8f1';
      const knownHostFingerprint =
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

      final fixture = (await tester.runAsync(() async {
        final sourceCatalog = LocalProfileCatalog.forTesting(
          NativeDatabase(File('${directory.path}/source-catalog.sqlite')),
        );
        final sourceService = LocalProfileService(
          catalog: sourceCatalog,
          crypto: crypto,
        );
        final sourceProfile = await sourceService.create(
          password: localMasterPassword,
        );
        final sourceRecord = sourceProfile.record;
        final sourceDatabase = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(
            File(
              '${directory.path}/source-vault-${sourceRecord.profileId}.sqlite',
            ),
          ),
          profileId: sourceRecord.profileId,
          localDataDomainId: sourceRecord.localDataDomainId,
          localVaultId: sourceRecord.localVaultId,
        );
        final sourceRepository = LocalHostRepository(
          database: sourceDatabase,
          profile: sourceProfile,
          crypto: crypto,
        );
        final credential = await sourceRepository.createCredential(
          const CredentialRecord(
            id: '45a31d23-636c-48f2-af46-e8e9a8dfed1b',
            name: 'Archive widget credential',
            username: 'archive-deploy',
            secret: secret,
          ),
        );
        final group = await sourceRepository.createGroup(
          const GroupRecord(
            id: '9b1ac293-6dc2-43bd-a9b2-a15c4a42f830',
            name: 'Archive widget group',
          ),
        );
        await sourceRepository.createHost(
          HostRecord(
            id: 'draft',
            name: 'Archive widget host',
            address: 'archive-widget.example.test',
            username: 'archive-deploy',
            groupId: group.id,
            credentialId: credential.id,
          ),
        );
        const snippetId = 'c1cddaf4-4cb3-40ec-9d9b-3b585b2ecbc5';
        await sourceRepository.createSnippet(
          const SnippetRecord(
            id: snippetId,
            title: 'Archive widget snippet',
            body: 'printf "archive-widget-snippet-sentinel"',
            tags: ['portable'],
          ),
        );
        await sourceRepository.createPreference(
          scope: 'workspace',
          key: 'defaultSection',
          platformFamily: 'all',
          value: 'snippets',
        );
        final shortcutBindings = TerminalShortcutBindings.fromBindings({
          ...TerminalShortcutBindings.defaultValues,
          TerminalShortcutAction.search: 'alt+shift+x',
        });
        await sourceRepository.createPreference(
          scope: 'workspace',
          key: VaultPreferenceRecord.terminalShortcutsKey,
          platformFamily: 'all',
          value: shortcutBindings.toValue(),
        );
        final archivedKnownHost = await sourceRepository.approveKnownHost(
          host: 'archive-widget.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
          explicitlyConfirmed: true,
        );
        final sourceBefore = await sourceRepository.exportArchiveSnapshot();
        final archiveService = LocalProfileArchiveService(crypto.sodium);
        final sourceArchive = await archiveService.export(
          repository: sourceRepository,
          password: archivePassword,
        );

        final targetCatalog = LocalProfileCatalog.forTesting(
          NativeDatabase(File('${directory.path}/catalog.sqlite')),
        );
        final targetService = LocalProfileService(
          resumeStore: _NoResumeStore(),
          deviceKeyStore: _NoResumeStore(),
          catalog: targetCatalog,
          crypto: crypto,
        );
        return (
          sourceCatalog: sourceCatalog,
          sourceService: sourceService,
          sourceProfile: sourceProfile,
          sourceRecord: sourceRecord,
          sourceDatabase: sourceDatabase,
          sourceRepository: sourceRepository,
          credential: credential,
          archivedKnownHost: archivedKnownHost,
          sourceBefore: sourceBefore,
          archiveService: archiveService,
          sourceArchive: sourceArchive,
          targetCatalog: targetCatalog,
          targetService: targetService,
        );
      }))!;
      final sourceCatalog = fixture.sourceCatalog;
      final sourceProfile = fixture.sourceProfile;
      final sourceDatabase = fixture.sourceDatabase;
      final sourceRepository = fixture.sourceRepository;
      final credential = fixture.credential;
      final archivedKnownHost = fixture.archivedKnownHost;
      final sourceBefore = fixture.sourceBefore;
      final archiveService = fixture.archiveService;
      final sourceArchive = fixture.sourceArchive;
      final targetCatalog = fixture.targetCatalog;
      final targetService = fixture.targetService;
      final targetDatabases = <LocalVaultDatabase>[];
      Uint8List? exportedArchive;
      var exited = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: LocalProfileFlow(
            catalog: targetCatalog,
            service: targetService,
            crypto: crypto,
            onExit: () => exited = true,
            archivePicker: () async => Uint8List.fromList(sourceArchive),
            archiveSaver: (bytes) async {
              exportedArchive = Uint8List.fromList(bytes);
              return true;
            },
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
              targetDatabases.add(database);
              return database;
            },
          ),
        ),
      );
      await pumpUntilIdle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_create_password')),
        localMasterPassword,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_create_button')),
      );
      await pumpUntilIdle(tester);
      expect(find.text('No Hosts yet'), findsOneWidget);

      await _tapWorkspaceAction(tester, 'local_profile_archive_import');
      await tester.pumpAndSettle();
      await enterDialogPassword(tester, password: archivePassword);
      await pumpUntilIdle(tester);
      expect(find.text('Archive widget snippet'), findsOneWidget);
      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();
      await _tapWorkspaceAction(tester, 'local_known_hosts_manage');
      await _pumpUntilVisible(
        tester,
        find.text('archive-widget.example.test:22 · pending review'),
      );
      expect(find.text('archive-widget.example.test:22 · pending review'), findsOneWidget);
      expect(find.textContaining(knownHostFingerprint), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('local-known-host-review-${archivedKnownHost.id}')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Only continue after verifying the fingerprint over a trusted channel. Once confirmed, this device creates a new local trust record for the following endpoint:'), findsOneWidget);
      await tester.tap(
        find.byKey(
          ValueKey('local-known-host-confirm-${archivedKnownHost.id}'),
        ),
      );
      await _pumpUntilVisible(tester, find.textContaining('Trusted'));
      expect(find.text('archive-widget.example.test:22 · pending review'), findsNothing);
      expect(find.textContaining('Trusted'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();
      expect(find.text('Archive widget host'), findsAtLeastNWidgets(1));
      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      final credentials = find.byKey(
        const ValueKey('local_profile_credentials_toggle'),
      );
      await tester.ensureVisible(credentials);
      await tester.tap(credentials);
      await tester.pumpAndSettle();
      expect(find.text('Archive widget credential'), findsOneWidget);
      expect(find.text(secret), findsNothing);
      await _tapWorkspaceAction(tester, 'local_profile_groups_toggle');
      await tester.pumpAndSettle();
      expect(find.text('Archive widget group'), findsOneWidget);
      await _tapWorkspaceAction(tester, 'local_profile_snippets_toggle');
      await tester.pumpAndSettle();
      expect(find.text('Archive widget snippet'), findsOneWidget);
      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      await tester.pumpAndSettle();
      expect(find.text('Default workspace'), findsOneWidget);
      expect(find.text('Snippet'), findsAtLeastNWidgets(1));
      await openSettingsCategory(tester, 'terminal');
      final searchShortcutField = find.byKey(
        const ValueKey('local_terminal_shortcut_search'),
      );
      await openSettingsCategory(tester, 'terminal');
      await tester.ensureVisible(searchShortcutField);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchShortcutField).controller!.text,
        'alt+shift+x',
      );

      await _tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await tester.pumpAndSettle();
      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      await tester.pumpAndSettle();
      await openSettingsCategory(tester, 'terminal');
      await tester.ensureVisible(searchShortcutField);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchShortcutField).controller!.text,
        'alt+shift+x',
      );

      await _tapWorkspaceAction(tester, 'local_profile_lock');
      await pumpUntilIdle(tester);
      final targetProfile = (await targetCatalog.list()).single;
      await tester.tap(
        find.byKey(ValueKey('local_profile_${targetProfile.profileId}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        localMasterPassword,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);
      await _tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      await tester.pumpAndSettle();
      await openSettingsCategory(tester, 'terminal');
      await tester.ensureVisible(searchShortcutField);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchShortcutField).controller!.text,
        'alt+shift+x',
      );

      await _tapWorkspaceAction(tester, 'local_profile_archive_export');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_archive_password')),
        '😀' * 257,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_archive_password_continue')),
      );
      await tester.pumpAndSettle();
      expect(find.text('The local archive passphrase can be at most 1024 UTF-8 bytes.'), findsOneWidget);
      await enterDialogPassword(
        tester,
        password: archivePassword,
        confirmation: archivePassword,
      );
      await _pumpUntilVisible(tester, find.text('Local encrypted archive saved.'));
      expect(exportedArchive, isNotNull);
      expect(String.fromCharCodes(exportedArchive!), isNot(contains(secret)));
      final reexported = (await tester.runAsync(
        () => archiveService.stageImport(
          container: exportedArchive!,
          password: archivePassword,
        ),
      ))!;
      expect(
        reexported.records.map((record) => record.plaintext['type']).toSet(),
        {'host', 'credential', 'group', 'snippet', 'preference'},
      );
      expect(reexported.knownHosts, hasLength(1));
      expect(reexported.knownHosts.single.state.name, 'trusted');
      final exportedCredential = reexported.records.singleWhere(
        (record) => record.plaintext['id'] == credential.id,
      );
      expect(exportedCredential.plaintext['secret'], secret);

      final targetEnvelopes = await targetDatabases.last
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      expect(
        targetEnvelopes.map((row) => row.read<String>('envelope_json')).join(),
        isNot(contains(secret)),
      );
      final sourceAfter = await sourceRepository.exportArchiveSnapshot();
      expect(
        sourceAfter.map((record) => record.toJson()).toList(),
        sourceBefore.map((record) => record.toJson()).toList(),
      );
      expect(await targetCatalog.list(), hasLength(1));
      expect(exited, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await sourceProfile.lock();
        await sourceDatabase.close();
        await sourceCatalog.close();
        for (final database in targetDatabases.reversed) {
          await database.close();
        }
        await targetCatalog.close();
      });
      sourceArchive.fillRange(0, sourceArchive.length, 0);
      final savedArchive = exportedArchive;
      if (savedArchive != null) {
        savedArchive.fillRange(0, savedArchive.length, 0);
      }
    },
  );
}

Future<void> _tapWorkspaceAction(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey(id)));
  await tester.tap(find.byKey(ValueKey(id)));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Expected UI did not appear: $finder');
}

// Password-based archive fixtures do not access the host OS key store.
class _NoResumeStore implements LocalProfileResumeStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> clear() async {}
}
