import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';

void main() {
  late Directory directory;
  late File catalogFile;
  late File vaultFile;
  late LocalProfileCatalog catalog;
  late LocalProfileService service;
  late VaultCrypto crypto;
  late UnlockedLocalProfile profile;
  final openDatabases = <LocalVaultDatabase>[];

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-local-migration-source-',
    );
    catalogFile = File('${directory.path}/catalog.sqlite');
    vaultFile = File('${directory.path}/vault.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    profile = await service.create(password: 'migration test password');
    openDatabases.clear();
  });

  tearDown(() async {
    for (final database in openDatabases.reversed) {
      await database.close();
    }
    await profile.lock();
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<LocalVaultDatabase> openVault({File? file}) async {
    final record = profile.record;
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(file ?? vaultFile),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
      mode: LocalVaultOpenMode.createNew,
    );
    openDatabases.add(database);
    return database;
  }

  LocalHostRepository repository(LocalVaultDatabase database) =>
      LocalHostRepository(database: database, profile: profile, crypto: crypto);

  Future<InitialVaultMaterial> targetMaterial() => profile.withDeviceIdentity(
    (identity) => crypto.createInitialVault(
      accountId: '90000000-0000-4000-8000-000000000009',
      name: 'Migration target',
      identity: identity,
    ),
  );

  Future<String> targetEnvelopeJson({
    required InitialVaultMaterial target,
    required LocalMigrationSourceItem item,
  }) async {
    final vaultKey = target.vaultKey.sublist(0);
    try {
      final envelope = await profile.withDeviceIdentity(
        (identity) => crypto.encryptRecord(
          vaultKey: vaultKey,
          serverSpaceId: '80000000-0000-4000-8000-000000000008',
          vaultId: target.vaultId,
          recordId: item.recordId,
          baseRevisionId: null,
          deviceId: identity.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: item.plaintext,
          identity: identity,
        ),
      );
      return canonicalJson(envelope);
    } finally {
      vaultKey.fillRange(0, vaultKey.length, 0);
    }
  }

  test(
    'freezes an authenticated full snapshot and resumes exact ciphertext staging after reopen',
    () async {
      final database = await openVault();
      final repo = repository(database);
      const groupId = '10000000-0000-4000-8000-000000000001';
      const credentialId = '20000000-0000-4000-8000-000000000002';
      const hostId = '30000000-0000-4000-8000-000000000003';
      const snippetId = '40000000-0000-4000-8000-000000000004';
      const secret = 'migration-secret-must-never-be-staged-in-cleartext';

      await repo.createGroup(
        const GroupRecord(id: groupId, name: 'Engineering'),
      );
      await repo.createCredential(
        const CredentialRecord(
          id: credentialId,
          name: 'deploy password',
          username: 'deploy',
          kind: AuthKind.password,
          secret: secret,
        ),
      );
      await repo.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Build server',
          address: 'build.example.test',
          username: 'deploy',
          credentialId: credentialId,
          groupId: groupId,
        ),
        recordId: hostId,
      );
      await repo.createSnippet(
        const SnippetRecord(
          id: snippetId,
          title: 'Health check',
          body: 'printf ready',
        ),
      );
      await repo.createPreference(
        scope: 'workspace',
        key: 'defaultSection',
        value: 'snippets',
        platformFamily: 'all',
      );
      await repo.createPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalFontSizeKey,
        value: '16',
        platformFamily: 'all',
      );
      await repo.createPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalThemeKey,
        value: VaultTerminalThemeChoice.light.value,
        platformFamily: 'all',
      );
      await repo.createPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalShortcutsKey,
        value: TerminalShortcutBindings.defaults.toValue(),
        platformFamily: 'all',
      );

      final target = await targetMaterial();
      final rawTargetKey = encodeBase64Url(target.vaultKey);
      const migrationId = '50000000-0000-4000-8000-000000000005';
      final snapshot = await repo.prepareMigrationSnapshot(
        migrationId: migrationId,
        targetInstanceId: '60000000-0000-4000-8000-000000000006',
        targetVaultId: target.vaultId,
      );
      expect(snapshot.items, hasLength(8));
      expect(
        snapshot.items.map((item) => item.recordId).toList(),
        [...snapshot.items.map((item) => item.recordId)]..sort(),
      );
      expect(snapshot.items.map((item) => item.recordType).toSet(), {
        'host',
        'credential',
        'group',
        'snippet',
        'preference',
      });
      final preferenceItems = snapshot.items
          .where((item) => item.recordType == 'preference')
          .toList(growable: false);
      expect(preferenceItems, hasLength(4));
      final validatedPreferences = [
        for (final item in preferenceItems)
          VaultPreferenceRecord.fromJson(item.recordJson),
      ];
      expect(
        validatedPreferences
            .map(
              (preference) => [
                preference.scope,
                preference.key,
                preference.platformFamily,
              ],
            )
            .map(canonicalJson)
            .toSet(),
        {
          canonicalJson(['workspace', 'defaultSection', 'all']),
          canonicalJson(['workspace', 'terminalFontSize', 'all']),
          canonicalJson(['workspace', 'terminalTheme', 'all']),
          canonicalJson(['workspace', 'terminalShortcuts', 'all']),
        },
      );
      expect(
        validatedPreferences
            .map((preference) => canonicalJson(preference.toJson()))
            .toSet(),
        preferenceItems.map((item) => canonicalJson(item.recordJson)).toSet(),
      );
      final preferences = {
        for (final preference in validatedPreferences)
          preference.key: preference.value,
      };
      expect(preferences['defaultSection'], 'snippets');
      expect(preferences['terminalFontSize'], '16');
      expect(preferences['terminalTheme'], 'light');
      expect(
        TerminalShortcutBindings.fromValue(
          preferences['terminalShortcuts']! as String,
        ),
        TerminalShortcutBindings.defaults,
      );
      final snippet = snapshot.items.singleWhere(
        (item) => item.recordType == 'snippet',
      );
      expect(snippet.plaintext['type'], 'snippet');
      expect(snippet.plaintext['title'], 'Health check');
      final targetSnippetEnvelope =
          jsonDecode(await targetEnvelopeJson(target: target, item: snippet))
              as Map<String, dynamic>;
      final targetSnippet = await profile.withDeviceIdentity(
        (identity) => crypto.decryptRecord(
          vaultKey: target.vaultKey,
          envelope: targetSnippetEnvelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        ),
      );
      expect(targetSnippet['type'], 'snippet');
      expect(targetSnippet['id'], snippet.recordId);
      expect(targetSnippet['title'], 'Health check');
      final credential = snapshot.items.singleWhere(
        (item) => item.recordType == 'credential',
      );
      expect(credential.plaintext['secret'], secret);
      expect(credential.plaintext, isNot(contains('revision_id')));
      expect(await repo.listMigrationJournals(), hasLength(1));

      await expectLater(
        repo.createHost(
          const HostRecord(
            id: 'draft',
            name: 'blocked',
            address: 'blocked.example.test',
            username: 'deploy',
          ),
        ),
        throwsA(anything),
      );

      // A second database handle bypassing the repository hits the same
      // SQLite trigger while the persistent migration gate is active.
      final secondHandle = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(vaultFile),
        profileId: profile.record.profileId,
        localDataDomainId: profile.record.localDataDomainId,
        localVaultId: profile.record.localVaultId,
        mode: LocalVaultOpenMode.openExisting,
      );
      openDatabases.add(secondHandle);
      await expectLater(
        secondHandle.customStatement(
          'UPDATE local_vault_records SET updated_at_ms = updated_at_ms + 1',
        ),
        throwsA(anything),
      );
      await secondHandle.close();
      openDatabases.remove(secondHandle);

      // Simulate a process restart and confirm the same target and source
      // fingerprint are recovered from durable metadata.
      await database.close();
      openDatabases.remove(database);
      final reopened = await openVault();
      final reopenedRepository = repository(reopened);
      final journal = (await reopenedRepository.listMigrationJournals()).single;
      expect(journal.migrationId, migrationId);
      expect(journal.targetVaultId, target.vaultId);
      expect(journal.targetInstanceId, snapshot.targetInstanceId);
      expect(journal.state, 'frozen');
      final restored = await reopenedRepository.readMigrationSnapshot(
        migrationId,
      );
      expect(restored.sourceFingerprint, snapshot.sourceFingerprint);
      expect(
        restored.items
            .singleWhere((item) => item.recordId == credentialId)
            .plaintext['secret'],
        secret,
      );

      final createPayload = canonicalJson(target.payload);
      final createDigest = await reopenedRepository.stageMigrationCreatePayload(
        migrationId: migrationId,
        payloadJson: createPayload,
      );
      expect(
        await reopenedRepository.stageMigrationCreatePayload(
          migrationId: migrationId,
          payloadJson: createPayload,
        ),
        createDigest,
      );
      expect(
        await reopenedRepository.readMigrationCreatePayload(migrationId),
        createPayload,
      );
      await expectLater(
        reopenedRepository.cancelMigration(migrationId),
        throwsA(isA<StateError>()),
      );
      for (var i = 0; i < restored.items.length; i++) {
        final item = restored.items[i];
        final envelopeJson = await targetEnvelopeJson(
          target: target,
          item: item,
        );
        final stagedItem = await reopenedRepository.stageMigrationItem(
          migrationId: migrationId,
          recordId: item.recordId,
          sourceRevisionId: item.sourceRevisionId,
          recordType: item.recordType,
          targetEnvelopeJson: envelopeJson,
        );
        if (i == 0) {
          final repeated = await reopenedRepository.stageMigrationItem(
            migrationId: migrationId,
            recordId: item.recordId,
            sourceRevisionId: item.sourceRevisionId,
            recordType: item.recordType,
            targetEnvelopeJson: envelopeJson,
          );
          expect(repeated.targetEnvelopeJson, stagedItem.targetEnvelopeJson);
          expect(
            repeated.targetEnvelopeSha256,
            stagedItem.targetEnvelopeSha256,
          );
        }
      }
      final staged = await reopenedRepository.listStagedMigrationItems(
        migrationId,
      );
      expect(staged, hasLength(8));
      expect(
        staged.map((item) => item.recordId).toSet(),
        restored.items.map((item) => item.recordId).toSet(),
      );
      expect(
        staged.any((item) => item.targetEnvelopeJson.contains(secret)),
        isFalse,
      );

      final files = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      for (final file in files) {
        final persisted = String.fromCharCodes(await file.readAsBytes());
        expect(persisted, isNot(contains(secret)));
        expect(persisted, isNot(contains(rawTargetKey)));
      }

      await reopenedRepository.finishMigration(migrationId);
      expect(
        (await reopenedRepository.listMigrationJournals()).single.state,
        'completed',
      );
      expect(
        (await reopenedRepository.getCredential(credentialId))?.secret,
        secret,
      );
      await reopenedRepository.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Writes resumed',
          address: 'resumed.example.test',
          username: 'deploy',
        ),
      );
      final completionHandle = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(vaultFile),
        profileId: profile.record.profileId,
        localDataDomainId: profile.record.localDataDomainId,
        localVaultId: profile.record.localVaultId,
        mode: LocalVaultOpenMode.openExisting,
      );
      openDatabases.add(completionHandle);
      await repository(completionHandle).createHost(
        const HostRecord(
          id: 'draft',
          name: 'Second handle sees thawed source',
          address: 'second-handle.example.test',
          username: 'deploy',
        ),
      );
      await completionHandle.close();
      openDatabases.remove(completionHandle);
      target.vaultKey.fillRange(0, target.vaultKey.length, 0);
    },
  );

  test(
    'object references, unsupported Preferences, and tombstones fail before freeze; cancellation unfreezes',
    () async {
      final database = await openVault();
      final repo = repository(database);
      await repo.createCredential(
        const CredentialRecord(
          id: '71000000-0000-4000-8000-000000000007',
          name: 'Migration credential',
          username: 'deploy',
          secret: 'migration-source-secret',
        ),
      );
      final host = await repo.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Host with attachment',
          address: 'attachment.example.test',
          username: 'deploy',
          credentialId: '71000000-0000-4000-8000-000000000007',
          manifest: {
            'object_refs': ['70000000-0000-4000-8000-000000000007'],
          },
        ),
      );
      const targetInstanceId = '60000000-0000-4000-8000-000000000006';
      const targetVaultId = '70000000-0000-4000-8000-000000000007';

      Future<void> expectPreflightFailure(String migrationId) async {
        await expectLater(
          repo.prepareMigrationSnapshot(
            migrationId: migrationId,
            targetInstanceId: targetInstanceId,
            targetVaultId: targetVaultId,
          ),
          throwsA(isA<FormatException>()),
        );
      }

      await expectPreflightFailure('50000000-0000-4000-8000-000000000005');
      expect(await repo.listMigrationJournals(), isEmpty);
      final cleanHost = await repo.updateHost(
        host: HostRecord(
          id: host.id,
          name: host.name,
          address: host.address,
          port: host.port,
          username: host.username,
          groupId: host.groupId,
          credentialId: host.credentialId,
          jumpHostId: host.jumpHostId,
          authKind: host.authKind,
          color: host.color,
          tags: host.tags,
          isFavorite: host.isFavorite,
        ),
        baseRevisionId: host.revisionId!,
      );
      // The normal local repository rejects deleting a referenced Credential.
      // Remove its row directly here to simulate a legacy/corrupted source and
      // prove migration preflight rejects the resulting dangling reference.
      await database.customStatement(
        'DELETE FROM local_vault_records '
        'WHERE local_vault_id = ? AND record_id = ?',
        [profile.record.localVaultId, '71000000-0000-4000-8000-000000000007'],
      );
      await expectPreflightFailure('50500000-0000-4000-8000-000000000005');
      expect(await repo.listMigrationJournals(), isEmpty);
      final closedHost = await repo.updateHost(
        host: HostRecord(
          id: cleanHost.id,
          name: cleanHost.name,
          address: cleanHost.address,
          port: cleanHost.port,
          username: cleanHost.username,
          groupId: cleanHost.groupId,
          jumpHostId: cleanHost.jumpHostId,
          authKind: cleanHost.authKind,
          color: cleanHost.color,
          tags: cleanHost.tags,
          isFavorite: cleanHost.isFavorite,
        ),
        baseRevisionId: cleanHost.revisionId!,
      );
      final unsupported = await repo.createPreference(
        scope: 'ui',
        key: 'theme',
        value: 'dark',
        platformFamily: 'all',
      );
      await expectPreflightFailure('51000000-0000-4000-8000-000000000005');
      expect(await repo.listMigrationJournals(), isEmpty);
      final supported = await repo.updatePreference(
        preference: LocalPreferenceRecord(
          id: unsupported.id,
          scope: 'workspace',
          key: 'defaultSection',
          value: 'hosts',
          platformFamily: 'all',
          revisionId: unsupported.revisionId,
        ),
        baseRevisionId: unsupported.revisionId,
      );
      final invalidTerminalPreference = await repo.createPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalFontSizeKey,
        value: '15',
        platformFamily: 'all',
      );
      await expectPreflightFailure('51500000-0000-4000-8000-000000000005');
      await repo.updatePreference(
        preference: LocalPreferenceRecord(
          id: invalidTerminalPreference.id,
          scope: 'workspace',
          key: VaultPreferenceRecord.terminalFontSizeKey,
          value: '16',
          platformFamily: 'all',
          revisionId: invalidTerminalPreference.revisionId,
        ),
        baseRevisionId: invalidTerminalPreference.revisionId,
      );
      final snapshot = await repo.prepareMigrationSnapshot(
        migrationId: '52000000-0000-4000-8000-000000000005',
        targetInstanceId: targetInstanceId,
        targetVaultId: targetVaultId,
      );
      expect(
        snapshot.items.map((item) => item.recordId),
        contains(closedHost.id),
      );
      expect(
        snapshot.items.map((item) => item.recordId),
        contains(supported.id),
      );
      await repo.cancelMigration(snapshot.migrationId);
      expect((await repo.listMigrationJournals()).single.state, 'cancelled');

      final deleted = await repo.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Deleted host',
          address: 'deleted.example.test',
          username: 'deploy',
        ),
      );
      await repo.deleteHost(
        recordId: deleted.id,
        baseRevisionId: deleted.revisionId!,
      );
      await expectPreflightFailure('53000000-0000-4000-8000-000000000005');
      expect(await repo.listMigrationJournals(), hasLength(1));
      await repo.createGroup(
        const GroupRecord(
          id: '90000000-0000-4000-8000-000000000009',
          name: 'Still writable',
        ),
      );
    },
  );

  test(
    'malformed or unsupported values for each supported preference fail before journaling',
    () async {
      final database = await openVault();
      final repo = repository(database);
      const targetInstanceId = '60000000-0000-4000-8000-000000000006';
      const targetVaultId = '70000000-0000-4000-8000-000000000007';
      const invalidValues = <({String key, Object? invalid, String valid})>[
        (key: 'defaultSection', invalid: 'settings', valid: 'hosts'),
        (key: 'terminalFontSize', invalid: '015', valid: '16'),
        (key: 'terminalTheme', invalid: 'solarized', valid: 'light'),
        (
          key: 'terminalShortcuts',
          invalid: '{"version":1,"bindings":{}}',
          valid:
              '{"version":1,"bindings":{"terminal.search":"mod+alt+shift+f","terminal.searchNext":"mod+alt+g","terminal.searchPrevious":"mod+alt+shift+g","terminal.disconnect":"mod+alt+shift+d"}}',
        ),
      ];

      for (var index = 0; index < invalidValues.length; index++) {
        final testCase = invalidValues[index];
        final preference = await repo.createPreference(
          scope: 'workspace',
          key: testCase.key,
          value: testCase.invalid,
          platformFamily: 'all',
        );
        final migrationId =
            '51000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}';
        await expectLater(
          repo.prepareMigrationSnapshot(
            migrationId: migrationId,
            targetInstanceId: targetInstanceId,
            targetVaultId: targetVaultId,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await repo.listMigrationJournals(), isEmpty);

        await repo.updatePreference(
          preference: LocalPreferenceRecord(
            id: preference.id,
            scope: preference.scope,
            key: preference.key,
            value: testCase.valid,
            platformFamily: preference.platformFamily,
            revisionId: preference.revisionId,
          ),
          baseRevisionId: preference.revisionId,
        );
        expect(await repo.listMigrationJournals(), isEmpty);
      }

      final snapshot = await repo.prepareMigrationSnapshot(
        migrationId: '52000000-0000-4000-8000-000000000005',
        targetInstanceId: targetInstanceId,
        targetVaultId: targetVaultId,
      );
      expect(snapshot.items, hasLength(4));
      expect(
        snapshot.items.map((item) => item.recordId).toSet(),
        (await repo.listPreferences()).map((item) => item.id).toSet(),
      );
      await repo.cancelMigration(snapshot.migrationId);
    },
  );

  test(
    'migration preflight diagnoses invalid persisted Jump Host routes',
    () async {
      final database = await openVault();
      final repo = repository(database);
      String hostId(int index) =>
          '72000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
      HostRecord hostDraft(String name, {String? jumpHostId}) => HostRecord(
        id: 'draft',
        name: name,
        address: '$name.example.test',
        username: 'deploy',
        jumpHostId: jumpHostId,
      );

      final chain = <HostRecord>[];
      for (var index = 0; index < 8; index++) {
        chain.add(
          await repo.createHost(
            hostDraft(
              'Hop $index',
              jumpHostId: chain.isEmpty ? null : chain.last.id,
            ),
            recordId: hostId(index),
          ),
        );
      }
      await repo.createHost(
        hostDraft('Eight-hop route', jumpHostId: chain.last.id),
        recordId: hostId(8),
      );
      final spare = await repo.createHost(
        hostDraft('Spare route'),
        recordId: hostId(9),
      );
      const targetInstanceId = '60000000-0000-4000-8000-000000000006';
      const targetVaultId = '70000000-0000-4000-8000-000000000007';
      var migrationIndex = 1;

      Future<void> expectMigrationError(String message) async {
        final migrationId =
            '50000000-0000-4000-8000-${migrationIndex.toString().padLeft(12, '0')}';
        migrationIndex++;
        await expectLater(
          repo.prepareMigrationSnapshot(
            migrationId: migrationId,
            targetInstanceId: targetInstanceId,
            targetVaultId: targetVaultId,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains(message),
            ),
          ),
        );
      }

      Future<void> replaceJumpHost(HostRecord host, String? jumpHostId) async {
        final rows = await database
            .customSelect(
              'SELECT revision_id FROM local_vault_records WHERE record_id = ?',
              variables: [Variable<String>(host.id)],
            )
            .get();
        final baseRevisionId = rows.single.read<String>('revision_id');
        final vaultKey = profile.copyVaultKey();
        late Map<String, Object?> envelope;
        try {
          envelope = await profile.withDeviceIdentity((identity) async {
            final plaintext = Map<String, Object?>.from(host.toJson())
              ..['jump_host_id'] = jumpHostId;
            return crypto.encryptLocalRecord(
              vaultKey: vaultKey,
              profileId: profile.record.profileId,
              localDataDomainId: profile.record.localDataDomainId,
              localVaultId: profile.record.localVaultId,
              recordId: host.id,
              baseRevisionId: baseRevisionId,
              operation: 'update',
              plaintext: plaintext,
              identity: identity,
            );
          });
        } finally {
          vaultKey.fillRange(0, vaultKey.length, 0);
        }
        final revisionId =
            (envelope['header']! as Map)['revision_id']! as String;
        await database.customStatement(
          '''
        UPDATE local_vault_records
        SET revision_id = ?, envelope_json = ?
        WHERE local_vault_id = ? AND record_id = ?
        ''',
          [
            revisionId,
            canonicalJson(envelope),
            profile.record.localVaultId,
            host.id,
          ],
        );
      }

      final valid = await repo.prepareMigrationSnapshot(
        migrationId: '50000000-0000-4000-8000-000000000100',
        targetInstanceId: targetInstanceId,
        targetVaultId: targetVaultId,
      );
      expect(valid.items, hasLength(10));
      await repo.cancelMigration(valid.migrationId);

      await replaceJumpHost(chain.first, spare.id);
      await expectMigrationError('8-hop limit');
      await replaceJumpHost(chain.first, hostId(1));
      await expectMigrationError('cycle');
      await replaceJumpHost(chain.first, null);
      await replaceJumpHost(
        chain.first,
        '73000000-0000-4000-8000-000000000001',
      );
      await expectMigrationError('reference is missing');
      await replaceJumpHost(chain.first, null);
      await replaceJumpHost(chain.first, chain.first.id);
      await expectMigrationError('cycle');
    },
  );

  test(
    'explicit abandon restores writes after target ciphertext is staged',
    () async {
      final database = await openVault();
      final repo = repository(database);
      final host = await repo.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Keep local source',
          address: 'keep-local.example.test',
          username: 'deploy',
        ),
      );
      final target = await targetMaterial();
      final snapshot = await repo.prepareMigrationSnapshot(
        migrationId: '54000000-0000-4000-8000-000000000005',
        targetInstanceId: '60000000-0000-4000-8000-000000000006',
        targetVaultId: target.vaultId,
      );
      final createPayload = canonicalJson(target.payload);
      await repo.stageMigrationCreatePayload(
        migrationId: snapshot.migrationId,
        payloadJson: createPayload,
      );
      final source = snapshot.items.single;
      final stagedEnvelope = await targetEnvelopeJson(
        target: target,
        item: source,
      );
      await repo.stageMigrationItem(
        migrationId: snapshot.migrationId,
        recordId: source.recordId,
        sourceRevisionId: source.sourceRevisionId,
        recordType: source.recordType,
        targetEnvelopeJson: stagedEnvelope,
      );
      await expectLater(
        repo.createHost(
          const HostRecord(
            id: 'draft',
            name: 'Blocked while frozen',
            address: 'blocked.example.test',
            username: 'deploy',
          ),
        ),
        throwsA(anything),
      );

      await repo.abandonMigration(snapshot.migrationId);

      final journal = (await repo.listMigrationJournals()).single;
      expect(journal.state, 'cancelled');
      expect(journal.stagedItemCount, 1);
      expect(
        await repo.readMigrationCreatePayload(snapshot.migrationId),
        createPayload,
      );
      expect(
        (await repo.listStagedMigrationItems(
          snapshot.migrationId,
        )).single.targetEnvelopeJson,
        stagedEnvelope,
      );
      expect((await repo.getHost(host.id))?.name, 'Keep local source');
      await repo.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Source writable after abandon',
          address: 'resumed-local.example.test',
          username: 'deploy',
        ),
      );
      final secondHandle = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(vaultFile),
        profileId: profile.record.profileId,
        localDataDomainId: profile.record.localDataDomainId,
        localVaultId: profile.record.localVaultId,
        mode: LocalVaultOpenMode.openExisting,
      );
      openDatabases.add(secondHandle);
      await repository(secondHandle).createHost(
        const HostRecord(
          id: 'draft',
          name: 'Second handle sees thawed source',
          address: 'second-handle.example.test',
          username: 'deploy',
        ),
      );
      await secondHandle.close();
      openDatabases.remove(secondHandle);
      target.vaultKey.fillRange(0, target.vaultKey.length, 0);
    },
  );
}
