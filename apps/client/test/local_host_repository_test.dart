import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/domain/window_combination.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/ansible_inventory_metadata.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';

void main() {
  const knownHostFingerprint =
      'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const changedHostFingerprint =
      'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  late Directory directory;
  late File catalogFile;
  late LocalProfileCatalog catalog;
  late LocalProfileService service;
  late VaultCrypto crypto;
  final profiles = <UnlockedLocalProfile>[];
  final databases = <LocalVaultDatabase>[];

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-local-host-');
    catalogFile = File('${directory.path}/catalog.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    profiles.clear();
    databases.clear();
  });

  tearDown(() async {
    for (final database in databases.reversed) {
      await database.close();
    }
    for (final profile in profiles) {
      await profile.lock();
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<UnlockedLocalProfile> createProfile() async {
    final profile = await service.create(
      password: 'correct horse battery staple',
    );
    profiles.add(profile);
    return profile;
  }

  Future<LocalVaultDatabase> openDatabase(
    UnlockedLocalProfile profile, {
    String file = 'vault.sqlite',
  }) async {
    final record = profile.record;
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/$file')),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
    databases.add(database);
    return database;
  }

  LocalHostRepository makeRepository(
    UnlockedLocalProfile profile,
    LocalVaultDatabase database,
  ) =>
      LocalHostRepository(database: database, profile: profile, crypto: crypto);

  HostRecord draft(String name) => HostRecord(
    id: 'draft-id-is-replaced',
    name: name,
    address: 'host.example.test',
    port: 2222,
    username: 'deploy',
    tags: const ['production', 'ssh'],
    isFavorite: true,
  );

  GroupRecord group(
    String id,
    String name, {
    String? parentId,
    String? defaultCredentialId,
    int color = 0,
    Map<String, Object?>? manifest,
  }) => GroupRecord(
    id: id,
    name: name,
    parentId: parentId,
    defaultCredentialId: defaultCredentialId,
    color: color,
    manifest: manifest,
  );

  SnippetRecord scriptSnippet({
    required String id,
    required String title,
    required String body,
    List<String> tags = const [],
    Map<String, Object?>? manifest,
  }) => SnippetRecord(
    id: id,
    title: title,
    body: body,
    tags: tags,
    manifest: manifest,
  );

  SnippetRecord commandSnippet({
    required String id,
    required String title,
    String program = 'printf',
    String shell = 'bash',
    List<SnippetArgument> arguments = const [],
    List<SnippetParameter> parameters = const [],
    List<String> tags = const [],
    Map<String, Object?>? manifest,
  }) => SnippetRecord(
    id: id,
    title: title,
    body: '',
    shell: shell,
    executionMode: SnippetExecutionMode.bashCommand,
    program: program,
    arguments: arguments,
    parameters: parameters,
    tags: tags,
    manifest: manifest,
  );

  CredentialRecord passwordCredential({
    required String id,
    String name = 'deploy password',
    String secret = 'credential-secret-sentinel-7b921',
  }) => CredentialRecord(
    id: id,
    name: name,
    username: 'deploy',
    kind: AuthKind.password,
    secret: secret,
  );

  CredentialRecord privateKeyCredential({required String id}) =>
      CredentialRecord(
        id: id,
        name: 'deploy key',
        username: 'deploy',
        kind: AuthKind.privateKey,
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nkey-material-sentinel\n-----END OPENSSH PRIVATE KEY-----\n',
        passphrase: 'private-key-passphrase-sentinel',
      );

  test(
    'stores only encrypted Host payloads in a minimal local schema',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final hosts = makeRepository(profile, database);
      const sentinel = 'plaintext-host-name-secret-sentinel-51a4c8';

      final created = await hosts.createHost(draft(sentinel));
      expect(created.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(created.revisionId, isNotNull);
      expect(created.baseRevisionId, isNull);
      expect((await hosts.getHost(created.id))?.name, sentinel);
      expect((await hosts.listHosts()).single.id, created.id);

      expect(await database.tableNames(), {
        'local_vault_binding',
        'local_vault_records',
        'local_vault_migrations',
        'local_vault_migration_items',
        'local_vault_migration_create_payloads',
        'local_vault_known_hosts',
        'local_vault_known_host_imports',
      });
      final records = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .getSingle();
      final envelopeText = records.read<String>('envelope_json');
      expect(envelopeText, contains('atermius-local-record-v1'));
      expect(envelopeText, isNot(contains(sentinel)));

      await database.close();
      databases.remove(database);
      final files = await directory
          .list()
          .where((entry) => entry is File)
          .toList();
      for (final file in files.cast<File>()) {
        final bytes = await file.readAsBytes();
        expect(String.fromCharCodes(bytes), isNot(contains(sentinel)));
      }
    },
  );

  test(
    'Desktop protocol, credentials and certificate survive encrypted storage',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      final fingerprint = List.filled(32, 'ab').join();
      for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
        final created = await repository.createHost(
          HostRecord(
            id: 'draft',
            name: 'Desktop',
            address: '192.0.2.10',
            protocol: protocol,
            rdpCertificateSha256: protocol == HostProtocol.rdp
                ? fingerprint
                : null,
            login: const HostLogin(
              kind: AuthKind.password,
              password: 'desktop-password-storage-canary',
            ),
          ),
        );
        final restored = (await repository.getHost(created.id))!;
        expect(restored.protocol, protocol);
        expect(restored.port, protocol.defaultPort);
        expect(restored.login?.password, 'desktop-password-storage-canary');
        expect(restored.rdpCertificateSha256, created.rdpCertificateSha256);
      }
      final records = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      for (final row in records) {
        final envelope = row.read<String>('envelope_json');
        expect(envelope, isNot(contains('desktop-password-storage-canary')));
        expect(envelope, isNot(contains(fingerprint)));
      }
    },
  );

  test(
    'Ansible source metadata and forward profiles survive LocalVault archives',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(
        profile,
        file: 'ansible-source.sqlite',
      );
      final repository = makeRepository(profile, database);
      final baseline = AnsibleInventoryImportedValues(
        name: 'inventory-web-01',
        address: 'web.example.test',
        port: 2222,
        username: 'deploy',
        tags: const ['production', 'web'],
      );
      final metadata = AnsibleInventoryImportMetadata(
        sourceId: '11111111-1111-4111-8111-111111111111',
        sourceLabel: 'INVENTORY_LABEL_CANARY',
        entryKey: 'inventory-web-01',
        baseline: baseline,
      );
      final forwardProfile = SshPortForwardProfile(
        id: '22222222-2222-4222-8222-222222222222',
        name: 'PostgreSQL',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 15432,
        destinationAddress: 'db.internal',
        destinationPort: 5432,
      );
      final created = await repository.createHost(
        draft('Inventory linked')
            .copyWith(portForwardProfiles: [forwardProfile])
            .copyWithAnsibleInventoryImport(metadata),
      );
      final stored = (await repository.getHost(created.id))!;
      expect(stored.ansibleInventoryImport?.toJson(), metadata.toJson());
      expect(stored.portForwardProfiles.map((item) => item.toJson()).toList(), [
        forwardProfile.toJson(),
      ]);

      final archive = await repository.exportPortableArchiveSnapshot();
      final archivedHost = archive.records.singleWhere(
        (record) => record.recordId == created.id,
      );
      final archivedManifest = archivedHost.plaintext['_manifest'];
      expect(archivedManifest, isA<Map>());
      final manifestJson = Map<String, Object?>.from(archivedManifest as Map);
      expect(manifestJson[ansibleInventoryManifestKey], metadata.toJson());
      final envelope = await database
          .customSelect(
            'SELECT envelope_json FROM local_vault_records WHERE record_id = ?',
            variables: [Variable<String>(created.id)],
          )
          .getSingle();
      expect(
        envelope.read<String>('envelope_json'),
        isNot(contains('INVENTORY_LABEL_CANARY')),
      );

      final destinationProfile = await createProfile();
      final destinationDatabase = await openDatabase(
        destinationProfile,
        file: 'ansible-source-destination.sqlite',
      );
      final destination = makeRepository(
        destinationProfile,
        destinationDatabase,
      );
      await destination.importArchiveSnapshot(
        archive.records,
        knownHosts: archive.knownHosts,
      );
      final restored = (await destination.getHost(created.id))!;
      expect(restored.ansibleInventoryImport?.toJson(), metadata.toJson());
      expect(
        restored.portForwardProfiles.map((item) => item.toJson()).toList(),
        [forwardProfile.toJson()],
      );
    },
  );

  test(
    'LocalVault KnownHost approval is encrypted and never enters sync rows',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);

      expect(
        await repository.knownHostTrustStatus(
          host: 'host.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
        ),
        LocalKnownHostTrustStatus.unknown,
      );
      await expectLater(
        repository.approveKnownHost(
          host: 'host.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
          explicitlyConfirmed: false,
        ),
        throwsStateError,
      );
      expect(
        await repository.listKnownHosts(),
        isEmpty,
        reason: 'an unconfirmed first-seen key must not be persisted',
      );

      final approved = await repository.approveKnownHost(
        host: 'host.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
        explicitlyConfirmed: true,
        approvedAt: DateTime.utc(2026, 10, 7),
      );
      expect(approved.state, KnownHostState.trusted);
      expect(approved.revisionId, isNotNull);
      expect(
        await repository.knownHostTrustStatus(
          host: 'host.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
        ),
        LocalKnownHostTrustStatus.trusted,
      );

      final stored = await database
          .customSelect(
            'SELECT * FROM local_vault_known_hosts WHERE local_vault_id = ?',
            variables: [Variable<String>(repository.localVaultId)],
          )
          .getSingle();
      expect(stored.data.keys.toSet(), {
        'local_vault_id',
        'record_id',
        'revision_id',
        'envelope_json',
        'updated_at_ms',
      });
      final serialized = stored.read<String>('envelope_json');
      expect(serialized, contains('atermius-local-record-v1'));
      expect(serialized, isNot(contains('host.example.test')));
      expect(serialized, isNot(contains(knownHostFingerprint)));
      expect(serialized, isNot(contains('ssh-ed25519')));
      final syncRows = await database
          .customSelect('SELECT COUNT(*) AS count FROM local_vault_records')
          .getSingle();
      expect(syncRows.read<int>('count'), 0);
      expect(await repository.exportArchiveSnapshot(), isEmpty);

      await database.close();
      databases.remove(database);
      final reopened = await openDatabase(profile);
      final reopenedRepository = makeRepository(profile, reopened);
      expect(
        (await reopenedRepository.listKnownHosts()).single.id,
        approved.id,
      );
    },
  );

  test('changed and revoked LocalVault host keys fail closed', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    final approved = await repository.approveKnownHost(
      host: 'host.example.test',
      port: 2200,
      algorithm: 'ssh-ed25519',
      fingerprint: knownHostFingerprint,
      explicitlyConfirmed: true,
    );

    expect(
      await repository.knownHostTrustStatus(
        host: 'host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: changedHostFingerprint,
      ),
      LocalKnownHostTrustStatus.changed,
    );
    await expectLater(
      repository.approveKnownHost(
        host: 'host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: changedHostFingerprint,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );

    final revoked = await repository.revokeKnownHost(recordId: approved.id);
    expect(revoked.state, KnownHostState.revoked);
    expect(revoked.revisionId, isNot(approved.revisionId));
    expect(
      await repository.knownHostTrustStatus(
        host: 'host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
      ),
      LocalKnownHostTrustStatus.revoked,
    );
    expect(
      await repository.knownHostTrustStatus(
        host: 'host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: changedHostFingerprint,
      ),
      LocalKnownHostTrustStatus.unknown,
    );

    final reapproved = await repository.approveKnownHost(
      host: 'host.example.test',
      port: 2200,
      algorithm: 'ssh-ed25519',
      fingerprint: knownHostFingerprint,
      explicitlyConfirmed: true,
    );
    expect(reapproved.id, isNot(approved.id));
    expect(reapproved.observedRevocations, hasLength(1));
    expect(
      await repository.knownHostTrustStatus(
        host: 'host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
      ),
      LocalKnownHostTrustStatus.trusted,
    );
  });

  test('Local Hosts preserve bounded acyclic Jump Host chains', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const bastionId = '11111111-1111-4111-8111-111111111111';
    const targetId = '22222222-2222-4222-8222-222222222222';
    const alternateId = '33333333-3333-4333-8333-333333333333';
    const invalidId = '44444444-4444-4444-8444-444444444444';
    const nestedId = '66666666-6666-4666-8666-666666666666';

    final bastion = await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Bastion',
        address: 'bastion.example.test',
        username: 'relay',
      ),
      recordId: bastionId,
    );
    await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Alternate bastion',
        address: 'alternate.example.test',
        username: 'relay',
      ),
      recordId: alternateId,
    );
    final target = await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Target',
        address: 'target.example.test',
        username: 'deploy',
        jumpHostId: bastionId,
      ),
      recordId: targetId,
    );
    expect((await repository.getHost(targetId))?.jumpHostId, bastionId);
    expect(
      (await repository.listHosts())
          .singleWhere((host) => host.id == targetId)
          .jumpHostId,
      bastionId,
    );

    await expectLater(
      repository.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Self reference',
          address: 'self.example.test',
          username: 'deploy',
          jumpHostId: invalidId,
        ),
        recordId: invalidId,
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Missing reference',
          address: 'missing.example.test',
          username: 'deploy',
          jumpHostId: '55555555-5555-4555-8555-555555555555',
        ),
        recordId: invalidId,
      ),
      throwsA(isA<FormatException>()),
    );
    final nested = await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Nested reference',
        address: 'nested.example.test',
        username: 'deploy',
        jumpHostId: targetId,
      ),
      recordId: nestedId,
    );
    expect(nested.jumpHostId, targetId);
    final nestedBastion = await repository.updateHost(
      host: bastion.copyWith(jumpHostId: alternateId),
      baseRevisionId: bastion.revisionId!,
    );
    expect(nestedBastion.jumpHostId, alternateId);
    await expectLater(
      repository.deleteHost(
        recordId: bastionId,
        baseRevisionId: nestedBastion.revisionId!,
      ),
      throwsA(isA<LocalJumpHostInUseException>()),
    );

    final directTarget = await repository.updateHost(
      host: target.copyWith(clearJumpHost: true),
      baseRevisionId: target.revisionId!,
    );
    expect(directTarget.jumpHostId, isNull);
    await repository.deleteHost(
      recordId: bastionId,
      baseRevisionId: nestedBastion.revisionId!,
    );
    expect(await repository.getHost(bastionId), isNull);
    expect((await repository.getHost(targetId))?.jumpHostId, isNull);
  });

  test(
    'Local Hosts allow eight Jump Host hops and reject cycles or a ninth',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);

      String hostId(int index) =>
          '70000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';

      HostRecord hostDraft(String name, {String? jumpHostId}) => HostRecord(
        id: 'draft',
        name: name,
        address: '$name.example.test',
        username: 'deploy',
        jumpHostId: jumpHostId,
      );

      HostRecord? previous;
      for (var index = 0; index < 8; index++) {
        previous = await repository.createHost(
          hostDraft('Hop $index', jumpHostId: previous?.id),
          recordId: hostId(index),
        );
      }
      final eightHopHost = await repository.createHost(
        hostDraft('Eight hop route', jumpHostId: previous!.id),
        recordId: hostId(8),
      );
      expect(eightHopHost.jumpHostId, previous.id);

      await expectLater(
        repository.createHost(
          hostDraft('Nine hop route', jumpHostId: eightHopHost.id),
          recordId: hostId(9),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('8-hop limit'),
          ),
        ),
      );

      final cycleA = await repository.createHost(
        hostDraft('Cycle A'),
        recordId: hostId(10),
      );
      await repository.createHost(
        hostDraft('Cycle B', jumpHostId: cycleA.id),
        recordId: hostId(11),
      );
      await expectLater(
        repository.updateHost(
          host: cycleA.copyWith(jumpHostId: hostId(11)),
          baseRevisionId: cycleA.revisionId!,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('cycle'),
          ),
        ),
      );
    },
  );

  test(
    'v1 LocalVault file migrates and retains its bound records schema',
    () async {
      final profile = await createProfile();
      final record = profile.record;
      final file = File('${directory.path}/v1-vault.sqlite');
      const legacyHostId = '1b6a28dd-f659-4206-94d0-2608f786599d';
      final vaultKey = profile.copyVaultKey();
      late Map<String, Object?> legacyEnvelope;
      try {
        legacyEnvelope = await profile.withDeviceIdentity((identity) async {
          return crypto.encryptLocalRecord(
            vaultKey: vaultKey,
            profileId: record.profileId,
            localDataDomainId: record.localDataDomainId,
            localVaultId: record.localVaultId,
            recordId: legacyHostId,
            baseRevisionId: null,
            operation: 'create',
            plaintext: (const HostRecord(
              id: legacyHostId,
              name: 'Legacy v1 Host',
              address: 'legacy.example.test',
              username: 'deploy',
            ).toJson()..remove('jump_host_id')),
            identity: identity,
          );
        });
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
      final legacyRevisionId =
          (legacyEnvelope['header']! as Map)['revision_id']! as String;
      final executor = NativeDatabase(
        file,
        setup: (sqlite) {
          final currentVersion =
              sqlite.select('PRAGMA user_version').single['user_version']
                  as int;
          if (currentVersion == 0) {
            sqlite.execute('''
            CREATE TABLE local_vault_binding (
              singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
              profile_id TEXT NOT NULL,
              local_data_domain_id TEXT NOT NULL,
              local_vault_id TEXT NOT NULL,
              schema_version INTEGER NOT NULL CHECK (schema_version = 1)
            )
          ''');
            sqlite.execute('''
            CREATE TABLE local_vault_records (
              local_vault_id TEXT NOT NULL,
              record_id TEXT NOT NULL,
              revision_id TEXT NOT NULL,
              envelope_json TEXT NOT NULL,
              is_deleted INTEGER NOT NULL CHECK (is_deleted IN (0, 1)),
              updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms > 0),
              PRIMARY KEY (local_vault_id, record_id)
            )
          ''');
            sqlite.execute(
              '''
            INSERT INTO local_vault_binding (
              singleton_id, profile_id, local_data_domain_id, local_vault_id,
              schema_version
            ) VALUES (1, ?, ?, ?, 1)
            ''',
              [record.profileId, record.localDataDomainId, record.localVaultId],
            );
            sqlite.execute(
              '''
            INSERT INTO local_vault_records (
              local_vault_id, record_id, revision_id, envelope_json,
              is_deleted, updated_at_ms
            ) VALUES (?, ?, ?, ?, 0, ?)
            ''',
              [
                record.localVaultId,
                legacyHostId,
                legacyRevisionId,
                jsonEncode(legacyEnvelope),
                DateTime.now().toUtc().millisecondsSinceEpoch,
              ],
            );
            sqlite.execute('PRAGMA user_version = 1');
          }
        },
      );
      final database = await LocalVaultDatabase.openForTesting(
        executor: executor,
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
      );
      databases.add(database);

      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 5);
      expect(await database.tableNames(), {
        'local_vault_binding',
        'local_vault_records',
        'local_vault_migrations',
        'local_vault_migration_items',
        'local_vault_migration_create_payloads',
        'local_vault_known_hosts',
        'local_vault_known_host_imports',
      });
      final indexes = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'local_vault_records_list_idx'",
          )
          .get();
      expect(indexes, hasLength(1));
      final binding = await database
          .customSelect('SELECT schema_version FROM local_vault_binding')
          .getSingle();
      expect(binding.read<int>('schema_version'), 1);
      final restored = await makeRepository(
        profile,
        database,
      ).getHost(legacyHostId);
      expect(restored?.name, 'Legacy v1 Host');
      expect(restored?.jumpHostId, isNull);
      expect(restored?.revisionId, legacyRevisionId);

      final migratedRepository = makeRepository(profile, database);
      const groupId = '476d92ce-6d2d-4b9f-97d7-40c6cc1b512d';
      final migratedGroup = await migratedRepository.createGroup(
        group(groupId, 'Created after v1 migration'),
      );
      expect(
        (await migratedRepository.getGroup(groupId))?.revisionId,
        migratedGroup.revisionId,
      );
      expect(
        (await migratedRepository.getHost(legacyHostId))?.revisionId,
        legacyRevisionId,
      );
      const snippetId = '6a71e593-0785-40dc-91ca-e84e27518d34';
      final migratedSnippet = await migratedRepository.createSnippet(
        scriptSnippet(
          id: snippetId,
          title: 'Snippet after v1 migration',
          body: 'printf migrated',
        ),
      );
      expect(
        (await migratedRepository.getSnippet(snippetId))?.revisionId,
        migratedSnippet.revisionId,
      );
      final migratedPreference = await migratedRepository.createPreference(
        scope: 'terminal',
        key: 'font-size',
        value: 14,
        platformFamily: 'linux',
      );
      expect(
        (await migratedRepository.getPreference(
          scope: 'terminal',
          key: 'font-size',
          platformFamily: 'linux',
        ))?.revisionId,
        migratedPreference.revisionId,
      );
      expect(
        (await migratedRepository.getHost(legacyHostId))?.name,
        'Legacy v1 Host',
      );
    },
  );

  test(
    'Credentials are encrypted, reopenable, and isolated from Host lists',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      const passwordSentinel = 'credential-secret-sentinel-7b921';
      const keySentinel = 'key-material-sentinel';
      const phraseSentinel = 'private-key-passphrase-sentinel';
      final password = await repository.createCredential(
        passwordCredential(
          id: '82d3659a-09e3-46a0-a022-67e9c410629a',
          secret: passwordSentinel,
        ),
      );
      final privateKey = await repository.createCredential(
        privateKeyCredential(id: 'd9e747af-66ce-42fb-9c00-4b8f676fe3bc'),
      );
      final host = await repository.createHost(draft('Host in same vault'));

      expect((await repository.listCredentials()).map((item) => item.id), {
        password.id,
        privateKey.id,
      });
      expect((await repository.listHosts()).map((item) => item.id), {host.id});
      expect(
        (await repository.getCredential(password.id))?.secret,
        passwordSentinel,
      );
      expect(
        (await repository.getCredential(privateKey.id))?.privateKey,
        contains(keySentinel),
      );

      final summaries = await repository.listCredentialSummaries();
      expect(summaries, hasLength(2));
      final summaryJson = jsonEncode(
        summaries.map((item) => item.toJson()).toList(),
      );
      expect(summaryJson, contains(password.name));
      expect(summaryJson, isNot(contains(passwordSentinel)));
      expect(summaryJson, isNot(contains(keySentinel)));
      expect(summaryJson, isNot(contains(phraseSentinel)));
      expect(summaryJson, isNot(contains('private_key')));
      expect(summaryJson, isNot(contains('passphrase')));

      final columns = await database
          .customSelect('PRAGMA table_info(local_vault_records)')
          .get();
      expect(columns.map((row) => row.read<String>('name')).toSet(), {
        'local_vault_id',
        'record_id',
        'revision_id',
        'envelope_json',
        'is_deleted',
        'updated_at_ms',
      });
      final stored = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      for (final row in stored) {
        final envelope = row.read<String>('envelope_json');
        expect(envelope, isNot(contains(passwordSentinel)));
        expect(envelope, isNot(contains(keySentinel)));
        expect(envelope, isNot(contains(phraseSentinel)));
      }

      final profileId = profile.record.profileId;
      await database.close();
      databases.remove(database);
      final persistedFiles = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      for (final persistedFile in persistedFiles) {
        final bytes = await persistedFile.readAsBytes();
        final rawText = String.fromCharCodes(bytes);
        expect(rawText, isNot(contains(passwordSentinel)));
        expect(rawText, isNot(contains(keySentinel)));
        expect(rawText, isNot(contains(phraseSentinel)));
      }
      await profile.lock();
      profiles.remove(profile);
      await catalog.close();
      catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
      service = LocalProfileService(catalog: catalog, crypto: crypto);
      final reopenedProfile = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      profiles.add(reopenedProfile);
      final reopenedDatabase = await openDatabase(reopenedProfile);
      final reopenedRepository = makeRepository(
        reopenedProfile,
        reopenedDatabase,
      );
      expect(
        (await reopenedRepository.getCredential(password.id))?.secret,
        passwordSentinel,
      );
      expect(
        (await reopenedRepository.getCredential(privateKey.id))?.privateKey,
        contains(keySentinel),
      );
      expect(
        (await reopenedRepository.listHosts()).single.name,
        'Host in same vault',
      );
    },
  );

  test(
    'Credential CAS, tombstones, kind separation, and strict validation',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      final first = await repository.createCredential(
        passwordCredential(id: 'cc10a4ed-0674-4541-b095-ea602250d397'),
      );
      final base = first.revisionId!;
      final attempts = await Future.wait<Object>([
        repository
            .updateCredential(
              credential: CredentialRecord(
                id: first.id,
                name: 'Concurrent A',
                username: first.username,
                secret: 'password-a',
              ),
              baseRevisionId: base,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
        repository
            .updateCredential(
              credential: CredentialRecord(
                id: first.id,
                name: 'Concurrent B',
                username: first.username,
                secret: 'password-b',
              ),
              baseRevisionId: base,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(attempts.whereType<CredentialRecord>(), hasLength(1));
      expect(
        attempts.whereType<LocalCredentialConflictException>(),
        hasLength(1),
      );

      final current = (await repository.getCredential(first.id))!;
      await expectLater(
        repository.updateCredential(credential: first, baseRevisionId: base),
        throwsA(isA<LocalCredentialConflictException>()),
      );
      await repository.deleteCredential(
        recordId: current.id,
        baseRevisionId: current.revisionId!,
      );
      expect(await repository.getCredential(current.id), isNull);
      expect(await repository.listCredentials(), isEmpty);
      final tombstone = await database
          .customSelect(
            'SELECT envelope_json, is_deleted FROM local_vault_records '
            'WHERE record_id = ?',
            variables: [Variable<String>(current.id)],
          )
          .getSingle();
      expect(tombstone.read<int>('is_deleted'), 1);
      final tombstoneEnvelope = jsonDecode(
        tombstone.read<String>('envelope_json'),
      ) as Map<String, dynamic>;
      expect(tombstoneEnvelope['header']['operation'], 'delete');
      expect(tombstoneEnvelope['ciphertext'], isNotEmpty);

      final host = await repository.createHost(draft('Never a Credential'));
      await expectLater(
        repository.deleteCredential(
          recordId: host.id,
          baseRevisionId: host.revisionId!,
        ),
        throwsA(isA<LocalCredentialConflictException>()),
      );
      expect((await repository.getHost(host.id))?.name, 'Never a Credential');
      await expectLater(
        repository.createCredential(
          passwordCredential(
            id: '95f82586-0a40-4e24-8ee4-c6061177c902',
            secret: 'bad\u0000secret',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.createCredential(
          const CredentialRecord(
            id: '8d599aae-8593-4ea0-a562-ade9c7e1eea9',
            name: 'Conflicting auth fields',
            username: 'deploy',
            kind: AuthKind.password,
            secret: 'password',
            privateKey: 'unexpected key material',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await repository.listHosts(), hasLength(1));
    },
  );

  test(
    'Groups use encrypted storage, survive v2 reopen, and remain kind-isolated',
    () async {
      final profile = await createProfile();
      final profileId = profile.record.profileId;
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      const parentId = 'c95620af-8c6c-49e6-b5aa-e745782419ca';
      const childId = 'ab936564-79b5-4aaf-a488-3febfa79d2f6';
      const hostId = '9714f2c0-4dfb-4ab4-b857-1737542f9dd7';
      const credentialId = 'e7e07f72-852c-49e7-a682-88f143c4ca7d';
      const parentName = 'group-name-encrypted-sentinel-c48f';
      const childName = 'child-group-encrypted-sentinel-0de7';
      final parent = await repository.createGroup(
        group(parentId, parentName, color: 0x336699),
      );
      final child = await repository.createGroup(
        group(childId, childName, parentId: parentId, color: 0x112233),
      );
      expect(parent.id, parentId);
      expect(child.id, childId);
      await repository.createHost(
        const HostRecord(
          id: 'draft-id-is-replaced',
          name: 'Grouped host',
          address: 'grouped.example.test',
          username: 'deploy',
          groupId: parentId,
        ),
        recordId: hostId,
      );
      await repository.createCredential(passwordCredential(id: credentialId));

      expect((await repository.getGroup(childId))?.parentId, parentId);
      expect((await repository.listGroups()).map((item) => item.id).toSet(), {
        parentId,
        childId,
      });
      expect(await repository.getHost(parentId), isNull);
      expect(await repository.getCredential(parentId), isNull);
      expect((await repository.listHosts()).single.groupId, parentId);
      expect((await repository.listCredentials()).single.id, credentialId);

      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 5);
      final columns = await database
          .customSelect('PRAGMA table_info(local_vault_records)')
          .get();
      expect(columns.map((row) => row.read<String>('name')).toSet(), {
        'local_vault_id',
        'record_id',
        'revision_id',
        'envelope_json',
        'is_deleted',
        'updated_at_ms',
      });
      final stored = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      for (final row in stored) {
        final envelope = row.read<String>('envelope_json');
        expect(envelope, isNot(contains(parentName)));
        expect(envelope, isNot(contains(childName)));
      }

      await database.close();
      databases.remove(database);
      final persistedFiles = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      for (final persistedFile in persistedFiles) {
        final raw = String.fromCharCodes(await persistedFile.readAsBytes());
        expect(raw, isNot(contains(parentName)));
        expect(raw, isNot(contains(childName)));
      }
      await profile.lock();
      profiles.remove(profile);
      await catalog.close();

      catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
      service = LocalProfileService(catalog: catalog, crypto: crypto);
      final reopenedProfile = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      profiles.add(reopenedProfile);
      final reopenedDatabase = await openDatabase(reopenedProfile);
      final reopened = makeRepository(reopenedProfile, reopenedDatabase);
      expect((await reopened.getGroup(parentId))?.name, parentName);
      expect((await reopened.getGroup(childId))?.parentId, parentId);
      expect((await reopened.getHost(hostId))?.groupId, parentId);
      expect((await reopened.getCredential(credentialId))?.id, credentialId);
    },
  );

  test('Local Group default Credentials resolve by nearest ancestry and survive archive import', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const parentCredentialId = 'a562c60f-f4d9-4541-9e64-59718bf3e14f';
    const innerCredentialId = '5e4d1dc1-dd73-4cd5-8ed6-bbbd02ac3426';
    const explicitCredentialId = 'c91e25b8-7545-4c8b-a785-7c8f17df1fc9';
    const parentId = '43e7dacf-29b0-4945-92d2-d5e54a0e5944';
    const childId = '890db500-0162-4ca7-8519-8706ed919db5';
    const innerId = '3bc0440d-5c0a-4159-a3cf-57a0f118bd75';
    final parentCredential = await repository.createCredential(
      passwordCredential(id: parentCredentialId, name: 'Parent credential'),
    );
    final innerCredential = await repository.createCredential(
      passwordCredential(id: innerCredentialId, name: 'Inner credential'),
    );
    final explicitCredential = await repository.createCredential(
      passwordCredential(
        id: explicitCredentialId,
        name: 'Explicit Host credential',
      ),
    );
    final parent = await repository.createGroup(
      group(
        parentId,
        'Parent with default',
        defaultCredentialId: parentCredential.id,
      ),
    );
    final child = await repository.createGroup(
      group(childId, 'Child inherits', parentId: parent.id),
    );
    final inner = await repository.createGroup(
      group(
        innerId,
        'Inner overrides parent',
        parentId: child.id,
        defaultCredentialId: innerCredential.id,
      ),
    );
    final inheritedHost = await repository.createHost(
      HostRecord(
        id: 'draft-parent-default',
        name: 'Parent default target',
        address: 'parent-default.example.test',
        username: 'deploy',
        groupId: child.id,
      ),
    );
    final nearestHost = await repository.createHost(
      HostRecord(
        id: 'draft-nearest-default',
        name: 'Nearest default target',
        address: 'nearest-default.example.test',
        username: 'deploy',
        groupId: inner.id,
      ),
    );
    final explicitHost = await repository.createHost(
      HostRecord(
        id: 'draft-explicit-override',
        name: 'Explicit override target',
        address: 'explicit-override.example.test',
        username: 'deploy',
        groupId: inner.id,
        credentialId: explicitCredential.id,
      ),
    );

    expect(
      (await repository.resolveCredentialForHost(inheritedHost))?.id,
      parentCredential.id,
    );
    expect(
      (await repository.resolveCredentialForHost(nearestHost))?.id,
      innerCredential.id,
    );
    expect(
      (await repository.resolveCredentialForHost(explicitHost))?.id,
      explicitCredential.id,
    );
    await expectLater(
      repository.createGroup(
        group(
          '2543f9e7-6cea-4f91-a9d0-5cf426d9069f',
          'Missing default',
          defaultCredentialId: 'd5b42065-6daf-4160-8c64-579b70a4f95f',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.deleteCredential(
        recordId: innerCredential.id,
        baseRevisionId: innerCredential.revisionId!,
      ),
      throwsA(
        isA<LocalCredentialInUseException>().having(
          (error) => error.groupId,
          'groupId',
          inner.id,
        ),
      ),
    );

    final archive = await repository.exportArchiveSnapshot();
    final copiedProfile = await createProfile();
    final copiedDatabase = await openDatabase(
      copiedProfile,
      file: 'vault-group-default-copy.sqlite',
    );
    final copiedRepository = makeRepository(copiedProfile, copiedDatabase);
    await copiedRepository.importArchiveSnapshot(archive);
    expect(
      (await copiedRepository.getGroup(inner.id))?.defaultCredentialId,
      innerCredential.id,
    );
    expect(
      (await copiedRepository.resolveCredentialForHost(nearestHost))?.id,
      innerCredential.id,
    );

    final envelope = await database
        .customSelect(
          'SELECT envelope_json FROM local_vault_records WHERE record_id = ?',
          variables: [Variable<String>(inner.id)],
        )
        .getSingle();
    expect(
      envelope.read<String>('envelope_json'),
      isNot(contains(innerCredential.id)),
    );
    final missingCredentialHost = explicitHost.copyWith(
      credentialId: 'd5b42065-6daf-4160-8c64-579b70a4f95f',
    );
    await expectLater(
      repository.resolveCredentialForHost(missingCredentialHost),
      throwsA(isA<FormatException>()),
    );
  });

  test('Group parent and Host references are atomic, cycles fail, and CAS tombstones persist', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const parentId = 'fdb9fb6d-e29a-47d2-9406-efba7c6c0bc6';
    const childId = '256553d0-1ebf-49d8-9af6-9e89c169fcc5';
    const hostId = 'ea80e12c-5b0b-43c2-a655-46aa5a6325d3';
    final parent = await repository.createGroup(group(parentId, 'Parent'));
    final child = await repository.createGroup(
      group(childId, 'Child', parentId: parentId),
    );
    await expectLater(
      repository.createGroup(
        group(
          '01f8df68-340d-4ad1-bcb6-87fd13eaab34',
          ' child ',
          parentId: parentId,
        ),
      ),
      throwsA(isA<LocalGroupDuplicateException>()),
    );
    await expectLater(
      repository.createGroup(
        group(
          '01f8df68-340d-4ad1-bcb6-87fd13eaab34',
          'Missing parent',
          parentId: '6410e0a6-ae35-4f7f-ab6f-1a08787c1412',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.updateGroup(
        group: group(
          childId,
          'Child',
          parentId: '6410e0a6-ae35-4f7f-ab6f-1a08787c1412',
        ),
        baseRevisionId: child.revisionId,
      ),
      throwsA(isA<FormatException>()),
    );
    expect((await repository.getGroup(childId))?.parentId, parentId);

    await expectLater(
      repository.deleteGroup(
        recordId: parentId,
        baseRevisionId: parent.revisionId,
      ),
      throwsA(
        isA<LocalGroupInUseException>().having(
          (error) => error.referenceKind,
          'referenceKind',
          LocalGroupReferenceKind.childGroup,
        ),
      ),
    );
    const inUse = LocalGroupInUseException(
      recordId: childId,
      referenceKind: LocalGroupReferenceKind.childGroup,
    );
    expect(inUse.toString(), isNot(contains(childId)));

    await expectLater(
      repository.createHost(
        const HostRecord(
          id: 'draft',
          name: 'Missing group',
          address: 'host.example.test',
          username: 'deploy',
          groupId: '6410e0a6-ae35-4f7f-ab6f-1a08787c1412',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    final host = await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Parent reference',
        address: 'host.example.test',
        username: 'deploy',
        groupId: parentId,
      ),
      recordId: hostId,
    );
    await expectLater(
      repository.updateHost(
        host: host.copyWith(groupId: '6410e0a6-ae35-4f7f-ab6f-1a08787c1412'),
        baseRevisionId: host.revisionId!,
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.deleteGroup(
        recordId: parentId,
        baseRevisionId: parent.revisionId,
      ),
      throwsA(
        isA<LocalGroupInUseException>().having(
          (error) => error.referenceKind,
          'referenceKind',
          LocalGroupReferenceKind.childGroup,
        ),
      ),
    );

    const otherId = '3f231ab1-3ebf-4b4c-a6a3-639076d02280';
    final other = await repository.createGroup(group(otherId, 'Other root'));
    await expectLater(
      repository.updateGroup(
        group: group(otherId, 'parent'),
        baseRevisionId: other.revisionId,
      ),
      throwsA(isA<LocalGroupDuplicateException>()),
    );
    final concurrentMoves = await Future.wait<Object>([
      repository
          .updateGroup(
            group: group(parentId, 'Parent', parentId: otherId),
            baseRevisionId: parent.revisionId,
          )
          .then<Object>((value) => value, onError: (Object error) => error),
      repository
          .updateGroup(
            group: group(otherId, 'Other root', parentId: parentId),
            baseRevisionId: other.revisionId,
          )
          .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(concurrentMoves.whereType<LocalGroupRecord>(), hasLength(1));
    expect(concurrentMoves.whereType<FormatException>(), hasLength(1));
    final currentParent = (await repository.getGroup(parentId))!;
    final currentOther = (await repository.getGroup(otherId))!;
    expect(
      currentParent.parentId == otherId || currentOther.parentId == parentId,
      isTrue,
    );
    expect(
      currentParent.parentId == otherId && currentOther.parentId == parentId,
      isFalse,
    );

    final changedChild = await repository.updateGroup(
      group: group(childId, 'Child'),
      baseRevisionId: child.revisionId,
    );
    final parentBeforeHostCheck = (await repository.getGroup(parentId))!;
    await expectLater(
      repository.deleteGroup(
        recordId: parentId,
        baseRevisionId: parentBeforeHostCheck.revisionId,
      ),
      throwsA(
        isA<LocalGroupInUseException>().having(
          (error) => error.referenceKind,
          'referenceKind',
          LocalGroupReferenceKind.host,
        ),
      ),
    );
    await expectLater(
      repository.updateGroup(
        group: group(childId, 'Stale child edit'),
        baseRevisionId: child.revisionId,
      ),
      throwsA(isA<LocalGroupConflictException>()),
    );
    final hostWithoutParent = await repository.updateHost(
      host: HostRecord(
        id: host.id,
        name: host.name,
        address: host.address,
        port: host.port,
        username: host.username,
      ),
      baseRevisionId: host.revisionId!,
    );
    expect(hostWithoutParent.groupId, isNull);

    final currentParentForDelete = (await repository.getGroup(parentId))!;
    final currentOtherForDelete = (await repository.getGroup(otherId))!;
    if (currentParentForDelete.parentId == otherId) {
      await repository.updateGroup(
        group: group(parentId, 'Parent'),
        baseRevisionId: currentParentForDelete.revisionId,
      );
    } else if (currentOtherForDelete.parentId == parentId) {
      await repository.updateGroup(
        group: group(otherId, 'Other root'),
        baseRevisionId: currentOtherForDelete.revisionId,
      );
    }
    await repository.deleteGroup(
      recordId: childId,
      baseRevisionId: changedChild.revisionId,
    );
    final latestParent = (await repository.getGroup(parentId))!;
    await repository.deleteGroup(
      recordId: parentId,
      baseRevisionId: latestParent.revisionId,
    );
    expect(await repository.getGroup(parentId), isNull);
    expect(await repository.getGroup(childId), isNull);
    expect(await repository.getHost(hostId), isNotNull);

    final tombstone = await database
        .customSelect(
          'SELECT envelope_json, is_deleted FROM local_vault_records '
          'WHERE record_id = ?',
          variables: [const Variable<String>(parentId)],
        )
        .getSingle();
    expect(tombstone.read<int>('is_deleted'), 1);
    final envelope = jsonDecode(
      tombstone.read<String>('envelope_json'),
    ) as Map<String, dynamic>;
    expect(envelope['header']['operation'], 'delete');
    expect(envelope['ciphertext'], isNotEmpty);
    await expectLater(
      repository.createGroup(group(parentId, 'Cannot revive tombstone')),
      throwsA(isA<LocalGroupConflictException>()),
    );
  });

  test(
    'Group payload validation is exact and field bounds are enforced',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      const id = '1217ba12-6971-47d6-a1dc-33fcfc46ca2d';
      for (final invalid in [
        group(id, '  '),
        group(id, List<String>.filled(257, 'x').join()),
        group(id, 'Invalid color', color: -1),
        group(id, 'Invalid color', color: 0x80000000),
        group(id, 'Invalid parent', parentId: 'not-a-uuid'),
        group(id, 'Invalid control\nname'),
        group(
          id,
          'Manifest too large',
          manifest: {'x': List<String>.filled(33000, 'm').join()},
        ),
      ]) {
        await expectLater(
          repository.createGroup(invalid),
          throwsA(isA<FormatException>()),
        );
      }
      await expectLater(
        repository.createGroup(group('not-a-uuid', 'Invalid id')),
        throwsA(isA<FormatException>()),
      );

      const malformedId = '307db4de-30d9-4c1d-8173-7108bbccfe32';
      final vaultKey = profile.copyVaultKey();
      late Map<String, Object?> malformedEnvelope;
      try {
        malformedEnvelope = await profile.withDeviceIdentity((identity) async {
          return crypto.encryptLocalRecord(
            vaultKey: vaultKey,
            profileId: profile.record.profileId,
            localDataDomainId: profile.record.localDataDomainId,
            localVaultId: profile.record.localVaultId,
            recordId: malformedId,
            baseRevisionId: null,
            operation: 'create',
            plaintext: {
              'id': malformedId,
              'type': 'group',
              'name': 'Signed malformed Group',
              'color': 0,
              'parent_id': null,
              'unexpected': true,
            },
            identity: identity,
          );
        });
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
      final malformedRevision =
          (malformedEnvelope['header']! as Map)['revision_id']! as String;
      await database.customStatement(
        '''
      INSERT INTO local_vault_records (
        local_vault_id, record_id, revision_id, envelope_json,
        is_deleted, updated_at_ms
      ) VALUES (?, ?, ?, ?, 0, ?)
      ''',
        [
          profile.record.localVaultId,
          malformedId,
          malformedRevision,
          jsonEncode(malformedEnvelope),
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      await expectLater(
        repository.getGroup(malformedId),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.listGroups(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'Snippets encrypt script and command definitions and survive unlock/reopen',
    () async {
      final profile = await createProfile();
      final profileId = profile.record.profileId;
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      const scriptId = 'd7143db6-0ba8-4c1d-874e-c5c4134fd60e';
      const commandId = '770c917f-6073-4563-9108-7f70cc07fd1a';
      const titleSentinel = 'snippet-title-encrypted-marker-75f3';
      const bodySentinel = 'snippet-body-encrypted-marker-6f91';
      const programSentinel = 'snippet-program-encrypted-marker-e81a';
      const argumentSentinel = 'snippet-argument-encrypted-marker-347c';
      const defaultSentinel = 'snippet-default-encrypted-marker-5abc';
      const secretCredentialId = 'f807f7bb-dbb8-4a04-b421-84f97a24a1a0';
      await repository.createCredential(
        passwordCredential(id: secretCredentialId),
      );
      final script = await repository.createSnippet(
        scriptSnippet(
          id: scriptId,
          title: titleSentinel,
          body: 'printf "$bodySentinel"\n',
          tags: const ['local', 'ops'],
        ),
      );
      final command = await repository.createSnippet(
        commandSnippet(
          id: commandId,
          title: 'Structured command',
          program: programSentinel,
          arguments: const [
            SnippetArgument.literal(argumentSentinel),
            SnippetArgument.reference('ENVIRONMENT'),
          ],
          parameters: const [
            SnippetParameter.text(
              name: 'ENVIRONMENT',
              defaultValue: defaultSentinel,
            ),
            SnippetParameter.credential(
              name: 'PASSWORD',
              credentialId: secretCredentialId,
            ),
          ],
          tags: const ['structured'],
        ),
      );

      expect(script.revisionId, isNotEmpty);
      expect(command.revisionId, isNotEmpty);
      expect(
        (await repository.getSnippet(scriptId))?.snippet.body,
        'printf "$bodySentinel"\n',
      );
      final restoredCommand = (await repository.getSnippet(commandId))!.snippet;
      expect(restoredCommand.executionMode, SnippetExecutionMode.bashCommand);
      expect(restoredCommand.program, programSentinel);
      expect(restoredCommand.arguments.first.value, argumentSentinel);
      expect(restoredCommand.parameters.first.defaultValue, defaultSentinel);
      expect(restoredCommand.parameters.last.credentialId, secretCredentialId);
      expect((await repository.listSnippets()).map((item) => item.id).toSet(), {
        scriptId,
        commandId,
      });
      expect(await repository.getHost(scriptId), isNull);
      expect(await repository.getCredential(scriptId), isNull);
      expect(await repository.getGroup(scriptId), isNull);
      expect(await repository.listHosts(), isEmpty);
      expect((await repository.listCredentials()).map((item) => item.id), {
        secretCredentialId,
      });
      expect(await repository.listGroups(), isEmpty);

      final columns = await database
          .customSelect('PRAGMA table_info(local_vault_records)')
          .get();
      expect(columns.map((row) => row.read<String>('name')).toSet(), {
        'local_vault_id',
        'record_id',
        'revision_id',
        'envelope_json',
        'is_deleted',
        'updated_at_ms',
      });
      final stored = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      for (final row in stored) {
        final envelope = row.read<String>('envelope_json');
        for (final marker in [
          titleSentinel,
          bodySentinel,
          programSentinel,
          argumentSentinel,
          defaultSentinel,
        ]) {
          expect(envelope, isNot(contains(marker)));
        }
      }

      await database.close();
      databases.remove(database);
      for (final entry
          in await directory.list().where((entry) => entry is File).toList()) {
        final raw = String.fromCharCodes(await (entry as File).readAsBytes());
        for (final marker in [
          titleSentinel,
          bodySentinel,
          programSentinel,
          argumentSentinel,
          defaultSentinel,
        ]) {
          expect(raw, isNot(contains(marker)));
        }
      }
      await profile.lock();
      profiles.remove(profile);
      await catalog.close();
      catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
      service = LocalProfileService(catalog: catalog, crypto: crypto);
      final reopenedProfile = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      profiles.add(reopenedProfile);
      final reopenedDatabase = await openDatabase(reopenedProfile);
      final reopened = makeRepository(reopenedProfile, reopenedDatabase);
      expect(
        (await reopened.getSnippet(scriptId))?.revisionId,
        script.revisionId,
      );
      expect(
        (await reopened.getSnippet(commandId))?.revisionId,
        command.revisionId,
      );
      expect(
        (await reopened.getSnippet(commandId))?.snippet.program,
        programSentinel,
      );
      expect(await reopened.getCredential(secretCredentialId), isNotNull);
    },
  );

  test('Host and Snippet Credential references are active, transactional, and block deletion', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const credentialId = '2f5e5d77-b31e-4b87-9720-156852b87c31';
    const snippetCredentialId = 'ee5c7f6a-42a7-423a-b4b9-b62a80712d01';
    const missingCredentialId = '7f389159-e6b0-4ff0-997b-e97b171230ad';
    const hostId = '80dc786a-0b1e-449f-9cdb-cbf5a9a62093';
    const snippetId = 'ebcddf10-af4b-4e1c-a5dc-608ee6f29132';
    final credential = await repository.createCredential(
      passwordCredential(id: credentialId),
    );
    final snippetCredential = await repository.createCredential(
      passwordCredential(id: snippetCredentialId),
    );

    await expectLater(
      repository.createHost(
        draft('Missing Credential create')
            .copyWith(credentialId: missingCredentialId),
        recordId: hostId,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await repository.getHost(hostId), isNull);

    final host = await repository.createHost(
      draft('Host with Credential').copyWith(credentialId: credential.id),
      recordId: hostId,
    );
    await expectLater(
      repository.updateHost(
        host: host.copyWith(credentialId: missingCredentialId),
        baseRevisionId: host.revisionId!,
      ),
      throwsA(isA<FormatException>()),
    );
    final unchangedHost = (await repository.getHost(host.id))!;
    expect(unchangedHost.revisionId, host.revisionId);
    expect(unchangedHost.credentialId, credential.id);
    await expectLater(
      repository.deleteCredential(
        recordId: credential.id,
        baseRevisionId: credential.revisionId!,
      ),
      throwsA(
        isA<LocalCredentialInUseException>().having(
          (error) => error.hostId,
          'hostId',
          host.id,
        ),
      ),
    );
    expect(await repository.getCredential(credential.id), isNotNull);

    await expectLater(
      repository.createSnippet(
        commandSnippet(
          id: snippetId,
          title: 'Missing Credential create',
          arguments: const [SnippetArgument.reference('TOKEN')],
          parameters: const [
            SnippetParameter.credential(
              name: 'TOKEN',
              credentialId: missingCredentialId,
            ),
          ],
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await repository.getSnippet(snippetId), isNull);

    final snippet = await repository.createSnippet(
      commandSnippet(
        id: snippetId,
        title: 'Credential-backed snippet',
        arguments: const [SnippetArgument.reference('TOKEN')],
        parameters: [
          SnippetParameter.credential(
            name: 'TOKEN',
            credentialId: snippetCredential.id,
          ),
        ],
      ),
    );
    await expectLater(
      repository.deleteCredential(
        recordId: snippetCredential.id,
        baseRevisionId: snippetCredential.revisionId!,
      ),
      throwsA(
        isA<LocalCredentialInUseException>().having(
          (error) => error.snippetId,
          'snippetId',
          snippetId,
        ),
      ),
    );
    expect(await repository.getCredential(snippetCredential.id), isNotNull);

    final revisionBeforeInvalidUpdate = snippet.revisionId;
    await expectLater(
      repository.updateSnippet(
        commandSnippet(
          id: snippetId,
          title: 'Missing Credential update',
          arguments: const [SnippetArgument.reference('TOKEN')],
          parameters: const [
            SnippetParameter.credential(
              name: 'TOKEN',
              credentialId: missingCredentialId,
            ),
          ],
        ),
        expectedRevisionId: revisionBeforeInvalidUpdate,
      ),
      throwsA(isA<FormatException>()),
    );
    final unchangedSnippet = (await repository.getSnippet(snippetId))!;
    expect(unchangedSnippet.revisionId, revisionBeforeInvalidUpdate);
    expect(
      unchangedSnippet.snippet.parameters.single.credentialId,
      snippetCredential.id,
    );

    final withoutSecretReference = await repository.updateSnippet(
      commandSnippet(id: snippetId, title: 'Reference removed'),
      expectedRevisionId: unchangedSnippet.revisionId,
    );
    await repository.deleteCredential(
      recordId: snippetCredential.id,
      baseRevisionId: snippetCredential.revisionId!,
    );
    expect(await repository.getCredential(snippetCredential.id), isNull);
    expect(await repository.getCredential(credential.id), isNotNull);
    expect((await repository.getHost(host.id))?.credentialId, credential.id);
    expect(
      (await repository.getSnippet(snippetId))?.revisionId,
      withoutSecretReference.revisionId,
    );
    await expectLater(
      repository.createSnippet(
        commandSnippet(
          id: '950e956a-51ec-4d99-829a-3806e1fe77bc',
          title: 'Deleted Credential reference',
          arguments: const [SnippetArgument.reference('TOKEN')],
          parameters: [
            SnippetParameter.credential(
              name: 'TOKEN',
              credentialId: snippetCredential.id,
            ),
          ],
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'concurrent Host and Snippet references cannot race Credential deletion',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      const hostCredentialId = '29e01777-a572-490a-b327-3f9cde440f22';
      const snippetCredentialId = 'f6cb0df1-6c53-4fb9-9583-54e66f065ca1';
      const hostId = 'c83b4375-c770-4ed7-9957-8ff51fc86fa4';
      const snippetId = 'fd21246e-e4b7-4427-bdaa-0c96916f2e71';

      Future<void> verifyHostRace() async {
        final credential = await repository.createCredential(
          passwordCredential(id: hostCredentialId),
        );
        final outcomes = await Future.wait<Object>([
          repository
              .createHost(
                draft('Concurrent Host reference')
                    .copyWith(credentialId: credential.id),
                recordId: hostId,
              )
              .then<Object>((value) => value, onError: (Object error) => error),
          repository
              .deleteCredential(
                recordId: credential.id,
                baseRevisionId: credential.revisionId!,
              )
              .then<Object>((_) => 'deleted', onError: (Object error) => error),
        ]);
        final host = await repository.getHost(hostId);
        final activeCredential = await repository.getCredential(credential.id);
        if (outcomes.whereType<HostRecord>().isNotEmpty) {
          expect(host?.credentialId, credential.id);
          expect(activeCredential, isNotNull);
          expect(
            outcomes.whereType<LocalCredentialInUseException>().single.hostId,
            hostId,
          );
        } else {
          expect(outcomes.whereType<FormatException>(), hasLength(1));
          expect(outcomes.whereType<String>(), ['deleted']);
          expect(host, isNull);
          expect(activeCredential, isNull);
        }
      }

      Future<void> verifySnippetRace() async {
        final credential = await repository.createCredential(
          passwordCredential(id: snippetCredentialId),
        );
        final outcomes = await Future.wait<Object>([
          repository
              .createSnippet(
                commandSnippet(
                  id: snippetId,
                  title: 'Concurrent Snippet reference',
                  arguments: const [SnippetArgument.reference('TOKEN')],
                  parameters: [
                    SnippetParameter.credential(
                      name: 'TOKEN',
                      credentialId: credential.id,
                    ),
                  ],
                ),
              )
              .then<Object>((value) => value, onError: (Object error) => error),
          repository
              .deleteCredential(
                recordId: credential.id,
                baseRevisionId: credential.revisionId!,
              )
              .then<Object>((_) => 'deleted', onError: (Object error) => error),
        ]);
        final snippet = await repository.getSnippet(snippetId);
        final activeCredential = await repository.getCredential(credential.id);
        if (outcomes.whereType<LocalSnippetRecord>().isNotEmpty) {
          expect(
            snippet?.snippet.parameters.single.credentialId,
            credential.id,
          );
          expect(activeCredential, isNotNull);
          expect(
            outcomes
                .whereType<LocalCredentialInUseException>()
                .single
                .snippetId,
            snippetId,
          );
        } else {
          expect(outcomes.whereType<FormatException>(), hasLength(1));
          expect(outcomes.whereType<String>(), ['deleted']);
          expect(snippet, isNull);
          expect(activeCredential, isNull);
        }
      }

      await verifyHostRace();
      await verifySnippetRace();
    },
  );

  test('Snippet CAS/tombstones, kind isolation, and strict nested payload validation', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const id = 'bd5616e1-4d03-4b41-ae3c-f09596c0f76c';
    final created = await repository.createSnippet(
      scriptSnippet(id: id, title: 'Before update', body: 'echo before'),
    );
    final base = created.revisionId;
    final attempts = await Future.wait<Object>([
      repository
          .updateSnippet(
            scriptSnippet(id: id, title: 'Concurrent A', body: 'echo a'),
            expectedRevisionId: base,
          )
          .then<Object>((value) => value, onError: (Object error) => error),
      repository
          .updateSnippet(
            scriptSnippet(id: id, title: 'Concurrent B', body: 'echo b'),
            expectedRevisionId: base,
          )
          .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(attempts.whereType<LocalSnippetRecord>(), hasLength(1));
    expect(attempts.whereType<LocalSnippetConflictException>(), hasLength(1));
    await expectLater(
      repository.updateSnippet(created.snippet, expectedRevisionId: base),
      throwsA(isA<LocalSnippetConflictException>()),
    );

    final current = (await repository.getSnippet(id))!;
    final host = await repository.createHost(draft('Snippet type collision'));
    expect(await repository.getSnippet(host.id), isNull);
    await expectLater(
      repository.deleteSnippet(host.id, expectedRevisionId: host.revisionId!),
      throwsA(isA<LocalSnippetConflictException>()),
    );
    await repository.deleteSnippet(id, expectedRevisionId: current.revisionId);
    expect(await repository.getSnippet(id), isNull);
    expect(await repository.listSnippets(), isEmpty);
    final tombstone = await database
        .customSelect(
          'SELECT envelope_json, is_deleted FROM local_vault_records '
          'WHERE record_id = ?',
          variables: [const Variable<String>(id)],
        )
        .getSingle();
    expect(tombstone.read<int>('is_deleted'), 1);
    final tombstoneEnvelope = jsonDecode(
      tombstone.read<String>('envelope_json'),
    ) as Map<String, dynamic>;
    expect(tombstoneEnvelope['header']['operation'], 'delete');
    expect(tombstoneEnvelope['ciphertext'], isNotEmpty);
    await expectLater(
      repository.createSnippet(
        scriptSnippet(id: id, title: 'Cannot revive', body: 'echo no'),
      ),
      throwsA(isA<LocalSnippetConflictException>()),
    );

    const badId = '0ce25632-3c90-4d64-b521-7638eb51e55a';
    for (final invalid in [
      scriptSnippet(id: badId, title: '  ', body: 'echo blank title'),
      scriptSnippet(
        id: badId,
        title: List<String>.filled(257, 'x').join(),
        body: 'echo long title',
      ),
      scriptSnippet(
        id: badId,
        title: 'Duplicate tags',
        body: 'echo duplicate',
        tags: const ['ops', 'OPS'],
      ),
      scriptSnippet(id: badId, title: 'Bad control', body: 'echo\u0000bad'),
      commandSnippet(
        id: badId,
        title: 'Undefined reference',
        arguments: const [SnippetArgument.reference('MISSING')],
      ),
      commandSnippet(
        id: badId,
        title: 'Bad credential ID',
        parameters: const [
          SnippetParameter.credential(
            name: 'PASSWORD',
            credentialId: 'not-a-uuid',
          ),
        ],
      ),
      commandSnippet(id: badId, title: 'Wrong shell', shell: 'sh'),
    ]) {
      await expectLater(
        repository.createSnippet(invalid),
        throwsA(isA<FormatException>()),
      );
    }
    await expectLater(
      repository.createSnippet(
        scriptSnippet(
          id: 'not-a-uuid',
          title: 'Invalid ID',
          body: 'echo invalid',
        ),
      ),
      throwsA(isA<FormatException>()),
    );

    const malformedId = '3d04130e-9c44-430e-b401-e740192085af';
    final vaultKey = profile.copyVaultKey();
    late Map<String, Object?> malformedEnvelope;
    try {
      malformedEnvelope = await profile.withDeviceIdentity((identity) async {
        return crypto.encryptLocalRecord(
          vaultKey: vaultKey,
          profileId: profile.record.profileId,
          localDataDomainId: profile.record.localDataDomainId,
          localVaultId: profile.record.localVaultId,
          recordId: malformedId,
          baseRevisionId: null,
          operation: 'create',
          plaintext: {
            'id': malformedId,
            'type': 'snippet',
            'title': 'Signed malformed Snippet',
            'body': '',
            'shell_kind': 'bash',
            'execution_mode': 'bashCommand',
            'program': 'printf',
            'arguments': [
              {'kind': 'literal', 'value': 'safe', 'unexpected': true},
            ],
            'parameters': [],
            'tags': [],
          },
          identity: identity,
        );
      });
    } finally {
      vaultKey.fillRange(0, vaultKey.length, 0);
    }
    final malformedRevision =
        (malformedEnvelope['header']! as Map)['revision_id']! as String;
    await database.customStatement(
      '''
        INSERT INTO local_vault_records (
          local_vault_id, record_id, revision_id, envelope_json,
          is_deleted, updated_at_ms
        ) VALUES (?, ?, ?, ?, 0, ?)
        ''',
      [
        profile.record.localVaultId,
        malformedId,
        malformedRevision,
        jsonEncode(malformedEnvelope),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
    await expectLater(
      repository.getSnippet(malformedId),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.listSnippets(),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'window combination survives encrypted local profile lock and reopen',
    () async {
      final profile = await createProfile();
      final profileId = profile.record.profileId;
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      final value = WindowCombination.encode([
        WindowCombination(
          id: 'combo',
          name: 'private-combination-marker',
          mainPlacement: SavedWindowPlacement(
            x: 50,
            y: 60,
            width: 1000,
            height: 700,
            maximized: true,
          ),
          panes: [
            CombinationPane(kind: 'rdp', hostId: 'host-ref'),
            CombinationPane(kind: 'ssh', hostId: 'host-second'),
            CombinationPane(
              kind: 'sftp',
              hostId: 'host-file',
              remotePath: '/latest-directory',
            ),
          ],
          tree: {
            'axis': 'horizontal',
            'ratio': .42,
            'first': {'pane': 0},
            'second': {'pane': 1},
          },
          activePane: 1,
          groups: [
            CombinationGroup(
              tree: {
                'axis': 'horizontal',
                'ratio': .42,
                'first': {'pane': 0},
                'second': {'pane': 1},
              },
              activePane: 1,
            ),
          ],
          windows: [
            CombinationWindow(
              pane: 2,
              independentFile: true,
              placement: SavedWindowPlacement(
                x: 10,
                y: 20,
                width: 900,
                height: 600,
              ),
            ),
          ],
        ),
      ]);
      await repository.createPreference(
        scope: 'workspace',
        key: 'windowCombinations',
        value: value,
        platformFamily: 'all',
      );
      final rows = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      expect(
        rows.single.read<String>('envelope_json'),
        isNot(contains('private-combination-marker')),
      );
      await expectLater(
        repository.createPreference(
          scope: 'workspace',
          key: 'windowCombinations',
          value: '[{"password":"bad"}]',
          platformFamily: 'windows',
        ),
        throwsFormatException,
      );
      await database.close();
      databases.remove(database);
      await profile.lock();
      profiles.remove(profile);
      final unlocked = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      profiles.add(unlocked);
      final reopened = makeRepository(unlocked, await openDatabase(unlocked));
      final saved = await reopened.getPreference(
        scope: 'workspace',
        key: 'windowCombinations',
        platformFamily: 'all',
      );
      expect(
        WindowCombination.decode(saved!.value as String).single.name,
        'private-combination-marker',
      );
      final reopenedRecipe = WindowCombination.decode(saved.value as String)
          .single;
      expect(reopenedRecipe.schemaVersion, 3);
      expect(reopenedRecipe.groups.single.activePane, 1);
      expect(reopenedRecipe.windows.single.independentFile, true);
      expect(
        WindowCombination.decode(saved.value as String)
            .single
            .mainPlacement!
            .maximized,
        true,
      );
    },
  );

  test('Preferences encrypt JSON CRUD, enforce CAS/unique keys, and survive reopen', () async {
    final profile = await createProfile();
    final profileId = profile.record.profileId;
    final database = await openDatabase(profile);
    final repository = makeRepository(profile, database);
    const valueSentinel = 'preference-json-secret-marker-e813';
    const scope = 'terminal';
    const key = 'font-size';
    const linux = 'linux';
    final host = await repository.createHost(draft('Preference neighbor'));
    final credential = await repository.createCredential(
      passwordCredential(id: '0d48fa39-a385-4f46-86cd-26a4eb227414'),
    );
    final groupRecord = await repository.createGroup(
      group(
        '475ca5d2-9569-46ec-9cd4-a75361fc52a5',
        'Preference neighbor group',
      ),
    );
    final snippet = await repository.createSnippet(
      scriptSnippet(
        id: '924fa29b-8ee8-489e-95f0-d6c2cc33bdbd',
        title: 'Preference neighbor snippet',
        body: 'echo safe',
      ),
    );
    final created = await repository.createPreference(
      scope: scope,
      key: key,
      platformFamily: linux,
      value: {
        'font': {'family': 'monospace', 'size': 14},
        'secret_marker': valueSentinel,
        'enabled': true,
        'recent': ['one', 'two'],
        'nullable': null,
      },
    );
    final windows = await repository.createPreference(
      scope: scope,
      key: key,
      platformFamily: 'windows',
      value: 15,
    );

    expect(created.id, isNotEmpty);
    expect(created.value, {
      'font': {'family': 'monospace', 'size': 14},
      'secret_marker': valueSentinel,
      'enabled': true,
      'recent': ['one', 'two'],
      'nullable': null,
    });
    final fetched = await repository.getPreference(
      scope: scope,
      key: key,
      platformFamily: linux,
    );
    expect(fetched?.id, created.id);
    expect(fetched?.revisionId, created.revisionId);
    expect(fetched?.value, created.value);
    expect(
      await repository.getPreference(
        scope: scope,
        key: key,
        platformFamily: 'macos',
      ),
      isNull,
    );
    expect(
      (await repository.listPreferences()).map((item) => item.id).toSet(),
      {created.id, windows.id},
    );
    expect(await repository.getHost(host.id), isNotNull);
    expect(await repository.getCredential(credential.id), isNotNull);
    expect(await repository.getGroup(groupRecord.id), isNotNull);
    expect(await repository.getSnippet(snippet.id), isNotNull);
    for (final nonPreference in [host, credential, groupRecord, snippet]) {
      final recordId = switch (nonPreference) {
        HostRecord value => value.id,
        CredentialRecord value => value.id,
        LocalGroupRecord value => value.id,
        LocalSnippetRecord value => value.snippet.id,
        _ => throw StateError('Unexpected record type'),
      };
      final revisionId = switch (nonPreference) {
        HostRecord value => value.revisionId!,
        CredentialRecord value => value.revisionId!,
        LocalGroupRecord value => value.revisionId,
        LocalSnippetRecord value => value.revisionId,
        _ => throw StateError('Unexpected record type'),
      };
      await expectLater(
        repository.deletePreference(
          recordId: recordId,
          baseRevisionId: revisionId,
        ),
        throwsA(isA<LocalPreferenceConflictException>()),
      );
    }
    expect(
      () => (created.value! as Map)['font']['size'] = 18,
      throwsUnsupportedError,
    );

    await expectLater(
      repository.createPreference(
        scope: scope,
        key: key,
        platformFamily: linux,
        value: 'duplicate',
      ),
      throwsA(isA<LocalPreferenceDuplicateException>()),
    );
    final concurrentCreates = await Future.wait<Object>([
      for (var index = 0; index < 2; index++)
        repository
            .createPreference(
              scope: 'workspace',
              key: 'editor-font',
              platformFamily: linux,
              value: index,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(concurrentCreates.whereType<LocalPreferenceRecord>(), hasLength(1));
    expect(
      concurrentCreates.whereType<LocalPreferenceDuplicateException>(),
      hasLength(1),
    );

    final revised = await repository.updatePreference(
      preference: LocalPreferenceRecord(
        id: created.id,
        scope: scope,
        key: key,
        platformFamily: linux,
        revisionId: created.revisionId,
        value: {
          'font': {'family': 'monospace', 'size': 16},
          'secret_marker': valueSentinel,
        },
      ),
      baseRevisionId: created.revisionId,
    );
    expect(revised.revisionId, isNot(created.revisionId));
    await expectLater(
      repository.updatePreference(
        preference: created,
        baseRevisionId: created.revisionId,
      ),
      throwsA(isA<LocalPreferenceConflictException>()),
    );
    await expectLater(
      repository.updatePreference(
        preference: LocalPreferenceRecord(
          id: revised.id,
          scope: scope,
          key: key,
          platformFamily: 'windows',
          value: 20,
          revisionId: revised.revisionId,
        ),
        baseRevisionId: revised.revisionId,
      ),
      throwsA(isA<LocalPreferenceDuplicateException>()),
    );

    final updateAttempts = await Future.wait<Object>([
      for (final value in [18, 19])
        repository
            .updatePreference(
              preference: LocalPreferenceRecord(
                id: revised.id,
                scope: scope,
                key: key,
                platformFamily: linux,
                value: value,
                revisionId: revised.revisionId,
              ),
              baseRevisionId: revised.revisionId,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(updateAttempts.whereType<LocalPreferenceRecord>(), hasLength(1));
    expect(
      updateAttempts.whereType<LocalPreferenceConflictException>(),
      hasLength(1),
    );
    final current = (await repository.getPreference(
      scope: scope,
      key: key,
      platformFamily: linux,
    ))!;
    await repository.deletePreference(
      recordId: current.id,
      baseRevisionId: current.revisionId,
    );
    expect(
      await repository.getPreference(
        scope: scope,
        key: key,
        platformFamily: linux,
      ),
      isNull,
    );
    await expectLater(
      repository.updatePreference(
        preference: current,
        baseRevisionId: current.revisionId,
      ),
      throwsA(isA<LocalPreferenceConflictException>()),
    );
    final tombstone = await database
        .customSelect(
          'SELECT envelope_json, is_deleted FROM local_vault_records '
          'WHERE record_id = ?',
          variables: [Variable<String>(current.id)],
        )
        .getSingle();
    expect(tombstone.read<int>('is_deleted'), 1);
    final tombstoneEnvelope = jsonDecode(
      tombstone.read<String>('envelope_json'),
    ) as Map<String, dynamic>;
    expect(tombstoneEnvelope['header']['operation'], 'delete');
    expect(tombstoneEnvelope['ciphertext'], isNotEmpty);

    final columns = await database
        .customSelect('PRAGMA table_info(local_vault_records)')
        .get();
    expect(columns.map((row) => row.read<String>('name')).toSet(), {
      'local_vault_id',
      'record_id',
      'revision_id',
      'envelope_json',
      'is_deleted',
      'updated_at_ms',
    });
    final envelopes = await database
        .customSelect('SELECT envelope_json FROM local_vault_records')
        .get();
    for (final row in envelopes) {
      expect(row.read<String>('envelope_json'), isNot(contains(valueSentinel)));
    }
    await database.close();
    databases.remove(database);
    final persistedFiles = await directory
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    for (final file in persistedFiles) {
      expect(
        String.fromCharCodes(await file.readAsBytes()),
        isNot(contains(valueSentinel)),
      );
    }

    await profile.lock();
    profiles.remove(profile);
    await catalog.close();
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    final reopenedProfile = await service.unlock(
      profileId: profileId,
      password: 'correct horse battery staple',
    );
    profiles.add(reopenedProfile);
    final reopenedDatabase = await openDatabase(reopenedProfile);
    final reopened = makeRepository(reopenedProfile, reopenedDatabase);
    expect(
      (await reopened.getPreference(
        scope: scope,
        key: key,
        platformFamily: 'windows',
      ))?.value,
      15,
    );
    expect(
      await reopened.getPreference(
        scope: scope,
        key: key,
        platformFamily: linux,
      ),
      isNull,
    );
    expect(await reopened.listPreferences(), hasLength(2));
  });

  test(
    'Preference validation rejects unsafe and malformed local JSON',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final repository = makeRepository(profile, database);
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      Object? oversizedTree = 0;
      for (var depth = 0; depth < 8; depth++) {
        oversizedTree = List<Object?>.filled(16, oversizedTree);
      }
      final invalidValues = <Object?>[
        Object(),
        double.nan,
        cyclic,
        oversizedTree,
        <Object?>[...List<Object?>.filled(513, 0)],
        ''.padRight(32769, 'x'),
        {'bad\u0000key': true},
        {1: 'non-string key'},
      ];
      for (final value in invalidValues) {
        await expectLater(
          repository.createPreference(
            scope: 'terminal',
            key: 'invalid-value',
            platformFamily: 'linux',
            value: value,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      for (final tuple in [
        ('', 'key', 'linux'),
        ('bad scope', 'key', 'linux'),
        ('s'.padRight(65, 's'), 'key', 'linux'),
        ('terminal', '', 'linux'),
        ('terminal', 'k'.padRight(129, 'k'), 'linux'),
        ('terminal', 'key', 'linux family'),
        ('terminal', 'key', 'p'.padRight(33, 'p')),
      ]) {
        await expectLater(
          repository.createPreference(
            scope: tuple.$1,
            key: tuple.$2,
            platformFamily: tuple.$3,
            value: null,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      expect(await repository.listPreferences(), isEmpty);

      const malformedId = '727babfd-452b-48ea-81fc-dfe69f84c5c5';
      final vaultKey = profile.copyVaultKey();
      late Map<String, Object?> malformedEnvelope;
      try {
        malformedEnvelope = await profile.withDeviceIdentity((identity) async {
          return crypto.encryptLocalRecord(
            vaultKey: vaultKey,
            profileId: profile.record.profileId,
            localDataDomainId: profile.record.localDataDomainId,
            localVaultId: profile.record.localVaultId,
            recordId: malformedId,
            baseRevisionId: null,
            operation: 'create',
            plaintext: const {
              'id': malformedId,
              'type': 'preference',
              'scope': 'terminal',
              'key': 'theme',
              'value': 'looks innocuous',
              'platform_family': 'linux',
              'unexpected': true,
            },
            identity: identity,
          );
        });
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
      final malformedRevision =
          (malformedEnvelope['header']! as Map)['revision_id']! as String;
      await database.customStatement(
        '''
      INSERT INTO local_vault_records (
        local_vault_id, record_id, revision_id, envelope_json,
        is_deleted, updated_at_ms
      ) VALUES (?, ?, ?, ?, 0, ?)
      ''',
        [
          profile.record.localVaultId,
          malformedId,
          malformedRevision,
          jsonEncode(malformedEnvelope),
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      await expectLater(
        repository.getPreference(
          scope: 'terminal',
          key: 'theme',
          platformFamily: 'linux',
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.listPreferences(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('file reopen plus profile unlock restores encrypted Hosts', () async {
    final profile = await createProfile();
    final profileId = profile.record.profileId;
    final database = await openDatabase(profile);
    final hosts = makeRepository(profile, database);
    final created = await hosts.createHost(draft('Reopen fixture'));
    await database.close();
    databases.remove(database);
    await profile.lock();
    profiles.remove(profile);
    await catalog.close();

    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    final reopenedProfile = await service.unlock(
      profileId: profileId,
      password: 'correct horse battery staple',
    );
    profiles.add(reopenedProfile);
    final reopenedDatabase = await openDatabase(reopenedProfile);
    final restored = await makeRepository(
      reopenedProfile,
      reopenedDatabase,
    ).getHost(created.id);

    expect(restored?.name, 'Reopen fixture');
    expect(restored?.revisionId, created.revisionId);
    expect(restored?.address, 'host.example.test');
  });

  test(
    'same record IDs stay isolated and database binding cannot be reused',
    () async {
      final firstProfile = await createProfile();
      final secondProfile = await createProfile();
      final firstDatabase = await openDatabase(
        firstProfile,
        file: 'first.sqlite',
      );
      final secondDatabase = await openDatabase(
        secondProfile,
        file: 'second.sqlite',
      );
      const sharedRecordId = '1ac2fda2-6da5-49e2-8e6d-f520e40a8571';
      final firstHosts = makeRepository(firstProfile, firstDatabase);
      final secondHosts = makeRepository(secondProfile, secondDatabase);
      await firstHosts.createHost(
        draft('Profile one'),
        recordId: sharedRecordId,
      );
      await secondHosts.createHost(
        draft('Profile two'),
        recordId: sharedRecordId,
      );

      expect((await firstHosts.getHost(sharedRecordId))?.name, 'Profile one');
      expect((await secondHosts.getHost(sharedRecordId))?.name, 'Profile two');

      await firstDatabase.close();
      databases.remove(firstDatabase);
      await expectLater(
        LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File('${directory.path}/first.sqlite')),
          profileId: secondProfile.record.profileId,
          localDataDomainId: secondProfile.record.localDataDomainId,
          localVaultId: secondProfile.record.localVaultId,
        ),
        throwsA(isA<FormatException>()),
      );

      final names = await secondDatabase.tableNames();
      expect(names, isNot(contains('pending_operations')));
      expect(names, isNot(contains('sync_checkpoints')));
      expect(names, isNot(contains('device_sequences')));
    },
  );

  test(
    'CAS admits one concurrent edit and delete persists an encrypted tombstone',
    () async {
      final profile = await createProfile();
      final database = await openDatabase(profile);
      final hosts = makeRepository(profile, database);
      final created = await hosts.createHost(draft('Before update'));
      final baseRevision = created.revisionId!;

      final attempts = await Future.wait<Object>([
        hosts
            .updateHost(
              host: created.copyWith(name: 'Concurrent A'),
              baseRevisionId: baseRevision,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
        hosts
            .updateHost(
              host: created.copyWith(name: 'Concurrent B'),
              baseRevisionId: baseRevision,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(attempts.whereType<HostRecord>(), hasLength(1));
      expect(attempts.whereType<LocalHostConflictException>(), hasLength(1));

      final current = (await hosts.getHost(created.id))!;
      expect({'Concurrent A', 'Concurrent B'}, contains(current.name));
      await hosts.deleteHost(
        recordId: created.id,
        baseRevisionId: current.revisionId!,
      );
      expect(await hosts.getHost(created.id), isNull);
      expect(await hosts.listHosts(), isEmpty);

      final tombstoneRow = await database
          .customSelect(
            'SELECT envelope_json, is_deleted FROM local_vault_records '
            'WHERE record_id = ?',
            variables: [Variable<String>(created.id)],
          )
          .getSingle();
      expect(tombstoneRow.read<int>('is_deleted'), 1);
      final envelope = jsonDecode(
        tombstoneRow.read<String>('envelope_json'),
      ) as Map<String, dynamic>;
      expect(envelope['header']['operation'], 'delete');
      expect(envelope['ciphertext'], isNotEmpty);
      expect(envelope['header'], isNot(contains('deleted')));
    },
  );

  test(
    'rejects invalid local Host identifiers and unlocked-profile mismatch',
    () async {
      final profile = await createProfile();
      final secondProfile = await createProfile();
      final database = await openDatabase(profile);
      final wrongRepository = makeRepository(secondProfile, database);
      await expectLater(
        wrongRepository.listHosts(),
        throwsA(isA<FormatException>()),
      );

      final hosts = makeRepository(profile, database);
      await expectLater(
        hosts.createHost(
          const HostRecord(
            id: 'draft',
            name: 'Invalid reference',
            address: 'host.example.test',
            username: 'deploy',
            groupId: 'not-a-uuid',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        hosts.createHost(draft('Invalid stable identifier'), recordId: '123'),
        throwsA(isA<FormatException>()),
      );
      expect(await hosts.listHosts(), isEmpty);
    },
  );

  test('profile lock waits for a complete repository write', () async {
    final profile = await createProfile();
    final database = await openDatabase(profile);
    final gatedCrypto = _GatedVaultCrypto(crypto.sodium);
    final hosts = LocalHostRepository(
      database: database,
      profile: profile,
      crypto: gatedCrypto,
    );
    final create = hosts.createHost(draft('Lock race fixture'));
    await gatedCrypto.encryptionStarted.future;

    var lockFinished = false;
    final lock = profile.lock().then((_) => lockFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(profile.isLocked, isTrue);
    expect(lockFinished, isFalse);

    gatedCrypto.allowEncryption.complete();
    final created = await create;
    await lock;
    expect(lockFinished, isTrue);
    expect(
      await database
          .customSelect(
            'SELECT record_id FROM local_vault_records WHERE record_id = ?',
            variables: [Variable<String>(created.id)],
          )
          .get(),
      hasLength(1),
    );
  });
}

class _GatedVaultCrypto extends VaultCrypto {
  _GatedVaultCrypto(super.sodium);

  final encryptionStarted = Completer<void>();
  final allowEncryption = Completer<void>();

  @override
  Future<Map<String, Object?>> encryptLocalRecord({
    required Uint8List vaultKey,
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required String recordId,
    required String? baseRevisionId,
    required String operation,
    required Map<String, Object?> plaintext,
    required DeviceIdentity identity,
  }) async {
    encryptionStarted.complete();
    await allowEncryption.future;
    return super.encryptLocalRecord(
      vaultKey: vaultKey,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: operation,
      plaintext: plaintext,
      identity: identity,
    );
  }
}
