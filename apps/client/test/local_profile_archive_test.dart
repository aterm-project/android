import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/archive/local_profile_archive.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

String _customTerminalShortcutsValue() =>
    TerminalShortcutBindings.fromBindings({
      for (final action in TerminalShortcutAction.values)
        action: action == TerminalShortcutAction.search
            ? 'alt+shift+x'
            : TerminalShortcutBindings.defaults.chordFor(action),
    }).toValue();

void main() {
  const knownHostFingerprint =
      'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const changedHostFingerprint =
      'SHA256:QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultCrypto crypto;
  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profiles;
  late LocalProfileArchiveService archive;
  final unlocked = <UnlockedLocalProfile>[];
  final databases = <LocalVaultDatabase>[];

  setUpAll(() async {
    // These cases intentionally keep source and destination LocalVaults open
    // together to exercise cross-profile archive copy and rollback.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-local-archive-',
    );
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profiles = LocalProfileService(catalog: catalog, crypto: crypto);
    archive = LocalProfileArchiveService(crypto.sodium);
    unlocked.clear();
    databases.clear();
  });

  tearDown(() async {
    for (final database in databases.reversed) {
      await database.close();
    }
    for (final profile in unlocked) {
      await profile.lock();
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<UnlockedLocalProfile> createProfile() async {
    final profile = await profiles.create(
      password: 'local-profile-master-password',
    );
    unlocked.add(profile);
    return profile;
  }

  Future<LocalHostRepository> repositoryFor(
    UnlockedLocalProfile profile,
  ) async {
    final record = profile.record;
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(
        File('${directory.path}/vault-${record.profileId}.sqlite'),
      ),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
    databases.add(database);
    return LocalHostRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
  }

  Future<
    ({
      LocalHostRepository repository,
      String host,
      String credential,
      String group,
      String snippet,
      String preference,
      String tombstone,
    })
  >
  populateSource() async {
    final source = await createProfile();
    final repository = await repositoryFor(source);
    final credential = await repository.createCredential(
      const CredentialRecord(
        id: '45a31d23-636c-48f2-af46-e8e9a8dfed1b',
        name: 'Archive deploy credential',
        username: 'archive-deploy',
        secret: 'archive-secret-sentinel-29a4',
      ),
    );
    final group = await repository.createGroup(
      const GroupRecord(
        id: '9b1ac293-6dc2-43bd-a9b2-a15c4a42f830',
        name: 'Archive group',
      ),
    );
    final host = await repository.createHost(
      HostRecord(
        id: 'draft',
        name: 'Archive host',
        address: 'archive.example.test',
        username: 'archive-deploy',
        groupId: group.id,
        credentialId: credential.id,
      ),
    );
    final deletedHost = await repository.createHost(
      const HostRecord(
        id: 'draft',
        name: 'Archived deleted Host',
        address: 'deleted.example.test',
        username: 'archive-deploy',
      ),
    );
    await repository.deleteHost(
      recordId: deletedHost.id,
      baseRevisionId: deletedHost.revisionId!,
    );
    const snippetId = 'c1cddaf4-4cb3-40ec-9d9b-3b585b2ecbc5';
    final snippet = await repository.createSnippet(
      const SnippetRecord(
        id: snippetId,
        title: 'Archive snippet',
        body: 'printf "archive-snippet-sentinel"',
        tags: ['portable'],
      ),
    );
    final preference = await repository.createPreference(
      scope: 'workspace',
      key: 'defaultSection',
      platformFamily: 'all',
      value: 'snippets',
    );
    await repository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalFontSizeKey,
      platformFamily: 'all',
      value: '16',
    );
    await repository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalThemeKey,
      platformFamily: 'all',
      value: VaultTerminalThemeChoice.light.value,
    );
    await repository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.terminalShortcutsKey,
      platformFamily: 'all',
      value: _customTerminalShortcutsValue(),
    );
    return (
      repository: repository,
      host: host.id,
      credential: credential.id,
      group: group.id,
      snippet: snippet.id,
      preference: preference.id,
      tombstone: deletedHost.id,
    );
  }

  test(
    'portable container authenticates, bounds, and rejects unsupported versions',
    () async {
      const password = 'archive-password-for-tests';
      final records = <LocalProfileArchiveRecord>[
        const LocalProfileArchiveRecord(
          recordId: '45a31d23-636c-48f2-af46-e8e9a8dfed1b',
          sourceRevisionId: '64cd4d26-a3db-42ad-9e3c-ab81929bb282',
          baseRevisionId: null,
          updatedAtMs: 1730000000000,
          isDeleted: false,
          plaintext: {
            'id': '45a31d23-636c-48f2-af46-e8e9a8dfed1b',
            'type': 'host',
            'name': 'codec fixture',
          },
        ),
      ];
      final payload = LocalProfileArchiveCodec.encodeSnapshot(records);
      final sealed = await LocalProfileArchiveCodec(
        crypto.sodium,
      ).seal(password: password, payload: payload);
      payload.fillRange(0, payload.length, 0);

      final decoded = await archive.stageImport(
        container: sealed,
        password: password,
      );
      expect(decoded.records.single.toJson(), records.single.toJson());
      expect(
        decoded.knownHosts,
        isEmpty,
        reason: 'legacy v1 has no trust data',
      );

      final tooLongPassword = 'x' * 1025;
      await expectLater(
        LocalProfileArchiveCodec(
          crypto.sodium,
        ).seal(password: tooLongPassword, payload: Uint8List.fromList([1])),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        LocalProfileArchiveCodec(
          crypto.sodium,
        ).seal(password: '😀' * 257, payload: Uint8List.fromList([1])),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        archive.stageImport(container: sealed, password: tooLongPassword),
        throwsA(isA<FormatException>()),
      );

      await expectLater(
        archive.stageImport(
          container: sealed,
          password: 'wrong-password-for-tests',
        ),
        throwsA(isA<FormatException>()),
      );
      final tampered = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      await expectLater(
        archive.stageImport(container: tampered, password: password),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        archive.stageImport(
          container: Uint8List.fromList(sealed.sublist(0, sealed.length - 1)),
          password: password,
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        archive.stageImport(
          container: _replaceHeaderVersion(sealed, 2),
          password: password,
        ),
        throwsA(isA<FormatException>()),
      );

      final unknownPayload = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'format': LocalProfileArchiveCodec.payloadFormat,
            'version': 3,
            'records': <Object?>[],
          }),
        ),
      );
      final unknownPayloadArchive = await LocalProfileArchiveCodec(
        crypto.sodium,
      ).seal(password: password, payload: unknownPayload);
      unknownPayload.fillRange(0, unknownPayload.length, 0);
      await expectLater(
        archive.stageImport(
          container: unknownPayloadArchive,
          password: password,
        ),
        throwsA(isA<FormatException>()),
      );
      sealed.fillRange(0, sealed.length, 0);
      tampered.fillRange(0, tampered.length, 0);
      unknownPayloadArchive.fillRange(0, unknownPayloadArchive.length, 0);
    },
  );

  test(
    'KnownHost archive v2 is strict, bounded, sorted, and round-trips',
    () async {
      final profile = await createProfile();
      final repository = await repositoryFor(profile);
      await repository.approveKnownHost(
        host: 'codec-known-host.example.test',
        port: 2200,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
        explicitlyConfirmed: true,
      );
      final snapshot = await repository.exportPortableArchiveSnapshot();
      final payload = LocalProfileArchiveCodec.encodeArchiveSnapshot(
        records: snapshot.records,
        knownHosts: snapshot.knownHosts,
      );
      final decoded = LocalProfileArchiveCodec.decodeArchiveSnapshot(payload);
      expect(decoded.records, isEmpty);
      expect(
        decoded.knownHosts.single.toJson(),
        snapshot.knownHosts.single.toJson(),
      );
      expect(
        decoded.knownHosts.single.revisionId,
        snapshot.knownHosts.single.revisionId,
      );

      await expectLater(
        () => LocalProfileArchiveCodec.encodeArchiveSnapshot(
          records: snapshot.records,
          knownHosts: [snapshot.knownHosts.single, snapshot.knownHosts.single],
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        () => LocalProfileArchiveCodec.encodeArchiveSnapshot(
          records: snapshot.records,
          knownHosts: List<KnownHostRecord>.filled(
            LocalProfileArchiveCodec.maxKnownHosts + 1,
            snapshot.knownHosts.single,
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      final malformed = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
      );
      final hostEnvelope = Map<String, dynamic>.from(
        (malformed['known_hosts'] as List).single as Map<String, dynamic>,
      );
      final hostRecord = Map<String, dynamic>.from(
        hostEnvelope['record'] as Map<String, dynamic>,
      )..['fingerprint'] = 'not-a-canonical-fingerprint';
      hostEnvelope['record'] = hostRecord;
      malformed['known_hosts'] = [hostEnvelope];
      final malformedBytes = Uint8List.fromList(
        utf8.encode(canonicalJson(malformed)),
      );
      expect(
        () => LocalProfileArchiveCodec.decodeArchiveSnapshot(malformedBytes),
        throwsA(isA<FormatException>()),
      );
      payload.fillRange(0, payload.length, 0);
      malformedBytes.fillRange(0, malformedBytes.length, 0);
    },
  );

  test(
    'round-trips every LocalVault record type with atomic empty-target import',
    () async {
      final source = await populateSource();
      final originalApproval = await source.repository.approveKnownHost(
        host: 'archive.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
        explicitlyConfirmed: true,
      );
      final sourceRevocation = await source.repository.revokeKnownHost(
        recordId: originalApproval.id,
      );
      final intermediateApproval = await source.repository.approveKnownHost(
        host: 'archive.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
        explicitlyConfirmed: true,
      );
      expect(intermediateApproval.observedRevocations, hasLength(1));
      final secondSourceRevocation = await source.repository.revokeKnownHost(
        recordId: intermediateApproval.id,
      );
      final currentApproval = await source.repository.approveKnownHost(
        host: 'archive.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: knownHostFingerprint,
        explicitlyConfirmed: true,
      );
      expect(currentApproval.observedRevocations, hasLength(2));
      final sourceBefore = await source.repository.exportArchiveSnapshot();
      final secretFreeArchive = await archive.export(
        repository: source.repository,
        password: 'archive-password-for-tests',
      );
      expect(
        String.fromCharCodes(secretFreeArchive),
        isNot(contains('archive-secret-sentinel-29a4')),
      );
      expect(
        String.fromCharCodes(secretFreeArchive),
        isNot(contains(knownHostFingerprint)),
      );
      expect(
        String.fromCharCodes(secretFreeArchive),
        isNot(contains('archive.example.test')),
      );

      final records = await archive.stageImport(
        container: secretFreeArchive,
        password: 'archive-password-for-tests',
      );
      expect(
        records.records.map((record) => record.plaintext['type']).toSet(),
        {'host', 'credential', 'group', 'snippet', 'preference'},
      );
      expect(records.knownHosts, hasLength(3));
      expect(records.knownHosts.map((record) => record.state).toSet(), {
        KnownHostState.trusted,
        KnownHostState.revoked,
      });

      final destination = await createProfile();
      var target = await repositoryFor(destination);
      var targetDatabase = databases.last;
      final sourceGroup = records.records.singleWhere(
        (record) => record.plaintext['type'] == 'group',
      );
      const duplicateGroupId = 'faf3da26-83ab-4e25-bccf-e155be88984e';
      final duplicateGroup = LocalProfileArchiveRecord(
        recordId: duplicateGroupId,
        sourceRevisionId: '26c3c17f-58bc-4414-bef1-6b873d65b4c2',
        baseRevisionId: null,
        updatedAtMs: sourceGroup.updatedAtMs,
        isDeleted: false,
        plaintext: {
          ...sourceGroup.plaintext,
          'id': duplicateGroupId,
          'name': ' ARCHIVE GROUP ',
        },
      );
      await expectLater(
        target.importArchiveSnapshot([...records.records, duplicateGroup]),
        throwsA(isA<FormatException>()),
      );
      expect(await target.isEmptyForArchiveImport(), isTrue);

      await targetDatabase.customStatement('''
      CREATE TRIGGER fail_second_archive_insert
      BEFORE INSERT ON local_vault_records
      WHEN EXISTS (
        SELECT 1 FROM local_vault_records
        WHERE local_vault_id = NEW.local_vault_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'fixture import failure');
      END
    ''');
      await expectLater(
        target.importArchiveSnapshot(
          records.records,
          knownHosts: records.knownHosts,
        ),
        throwsA(anything),
      );
      expect(await target.isEmptyForArchiveImport(), isTrue);
      await targetDatabase.customStatement(
        'DROP TRIGGER fail_second_archive_insert',
      );
      await targetDatabase.customStatement('''
      CREATE TRIGGER fail_archive_known_host_candidate
      BEFORE INSERT ON local_vault_known_host_imports
      BEGIN
        SELECT RAISE(ABORT, 'fixture candidate import failure');
      END
    ''');
      await expectLater(
        target.importArchiveSnapshot(
          records.records,
          knownHosts: records.knownHosts,
        ),
        throwsA(anything),
      );
      expect(await target.isEmptyForArchiveImport(), isTrue);
      await targetDatabase.customStatement(
        'DROP TRIGGER fail_archive_known_host_candidate',
      );
      await target.importArchiveSnapshot(
        records.records,
        knownHosts: records.knownHosts,
      );
      await targetDatabase.close();
      databases.remove(targetDatabase);
      target = await repositoryFor(destination);
      targetDatabase = databases.last;
      expect(await target.listImportedKnownHostCandidates(), hasLength(1));

      expect((await target.listHosts()).single.id, source.host);
      final importedHost = await target.getHost(source.host);
      expect(importedHost?.name, 'Archive host');
      expect(importedHost?.credentialId, source.credential);
      expect(importedHost?.groupId, source.group);
      expect((await target.listCredentials()).single.id, source.credential);
      expect(
        (await target.getCredential(source.credential))?.secret,
        'archive-secret-sentinel-29a4',
      );
      expect(
        (await target.getGroup(source.group))?.group.name,
        'Archive group',
      );
      expect(
        (await target.getSnippet(source.snippet))?.snippet.body,
        'printf "archive-snippet-sentinel"',
      );
      final preferences = await target.listPreferences();
      expect(
        {
          for (final preference in preferences)
            preference.key: preference.value,
        },
        {
          'defaultSection': 'snippets',
          'terminalFontSize': '16',
          'terminalTheme': 'light',
          'terminalShortcuts': _customTerminalShortcutsValue(),
        },
      );
      final importedShortcuts = await target.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalShortcutsKey,
        platformFamily: 'all',
      );
      expect(importedShortcuts, isNotNull);
      expect(importedShortcuts!.value, _customTerminalShortcutsValue());
      expect(
        TerminalShortcutBindings.fromValue(
          importedShortcuts.value as String,
        ).chordFor(TerminalShortcutAction.search),
        'alt+shift+x',
      );
      expect(await target.isEmptyForArchiveImport(), isFalse);
      final importedTombstone = await targetDatabase
          .customSelect(
            'SELECT is_deleted FROM local_vault_records WHERE record_id = ?',
            variables: [Variable<String>(source.tombstone)],
          )
          .getSingle();
      expect(importedTombstone.read<int>('is_deleted'), 1);
      final importedRevocations = await target.listKnownHosts();
      expect(importedRevocations, hasLength(2));
      expect(
        importedRevocations.every(
          (record) => record.state == KnownHostState.revoked,
        ),
        isTrue,
      );
      final importedRevocation = importedRevocations.singleWhere(
        (record) => record.id == sourceRevocation.id,
      );
      final importedSecondRevocation = importedRevocations.singleWhere(
        (record) => record.id == secondSourceRevocation.id,
      );
      expect(
        importedRevocation.matchesKey(
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
        ),
        isTrue,
      );
      expect(importedRevocation.revisionId, isNot(sourceRevocation.revisionId));
      expect(
        importedSecondRevocation.revisionId,
        isNot(secondSourceRevocation.revisionId),
      );
      expect(importedSecondRevocation.observedRevocations, [
        KnownHostRevocationReference(
          recordId: importedRevocation.id,
          revisionId: importedRevocation.revisionId!,
        ),
      ]);
      expect(
        await target.knownHostTrustStatus(
          host: 'archive.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
        ),
        LocalKnownHostTrustStatus.revoked,
      );
      expect(
        await target.knownHostTrustStatus(
          host: 'archive.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: changedHostFingerprint,
        ),
        LocalKnownHostTrustStatus.unknown,
      );
      final importedCandidates = await target.listImportedKnownHostCandidates();
      expect(importedCandidates, hasLength(1));
      expect(importedCandidates.single.record.id, currentApproval.id);
      final candidateEnvelope = await targetDatabase
          .customSelect(
            'SELECT envelope_json FROM local_vault_known_host_imports',
          )
          .getSingle();
      expect(
        candidateEnvelope.read<String>('envelope_json'),
        isNot(contains('archive.example.test')),
      );
      expect(
        candidateEnvelope.read<String>('envelope_json'),
        isNot(contains(knownHostFingerprint)),
      );
      await expectLater(
        target.approveImportedKnownHost(
          candidateId: importedCandidates.single.record.id,
          explicitlyConfirmed: false,
        ),
        throwsStateError,
      );
      expect(await target.listImportedKnownHostCandidates(), hasLength(1));
      final concurrentApprovals = await Future.wait([
        () async {
          try {
            return await target.approveImportedKnownHost(
              candidateId: importedCandidates.single.record.id,
              explicitlyConfirmed: true,
              approvedAt: DateTime.utc(2026, 10, 8),
            );
          } on Object {
            return null;
          }
        }(),
        () async {
          try {
            return await target.approveImportedKnownHost(
              candidateId: importedCandidates.single.record.id,
              explicitlyConfirmed: true,
              approvedAt: DateTime.utc(2026, 10, 8),
            );
          } on Object {
            return null;
          }
        }(),
      ]);
      final approvedOnTarget = concurrentApprovals
          .whereType<KnownHostRecord>()
          .single;
      expect(approvedOnTarget.id, isNot(currentApproval.id));
      expect(
        approvedOnTarget.approvalSource,
        KnownHostApprovalSource.knownHostsImport,
      );
      expect(
        approvedOnTarget.approvedByDeviceId,
        destination.record.localDeviceId,
      );
      final expectedObservedRevocations = [
        KnownHostRevocationReference(
          recordId: importedRevocation.id,
          revisionId: importedRevocation.revisionId!,
        ),
        KnownHostRevocationReference(
          recordId: importedSecondRevocation.id,
          revisionId: importedSecondRevocation.revisionId!,
        ),
      ]..sort((left, right) => left.sortKey.compareTo(right.sortKey));
      expect(approvedOnTarget.observedRevocations, expectedObservedRevocations);
      expect(
        (await target.listKnownHosts()).where(
          (record) => record.state == KnownHostState.trusted,
        ),
        hasLength(1),
      );
      expect(await target.listImportedKnownHostCandidates(), isEmpty);
      expect(
        await target.knownHostTrustStatus(
          host: 'archive.example.test',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: knownHostFingerprint,
        ),
        LocalKnownHostTrustStatus.trusted,
      );
      await expectLater(
        target.importArchiveSnapshot(
          records.records,
          knownHosts: records.knownHosts,
        ),
        throwsStateError,
      );

      final trustOnlyProfile = await createProfile();
      final trustOnlyTarget = await repositoryFor(trustOnlyProfile);
      await trustOnlyTarget.approveKnownHost(
        host: 'preexisting-trust.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: changedHostFingerprint,
        explicitlyConfirmed: true,
      );
      expect(await trustOnlyTarget.isEmptyForArchiveImport(), isFalse);
      await expectLater(
        trustOnlyTarget.importArchiveSnapshot(
          records.records,
          knownHosts: records.knownHosts,
        ),
        throwsStateError,
      );
      expect(await trustOnlyTarget.listHosts(), isEmpty);
      expect(await trustOnlyTarget.listImportedKnownHostCandidates(), isEmpty);

      final targetEnvelopes = await targetDatabase
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      expect(
        targetEnvelopes
            .map((row) => row.read<String>('envelope_json'))
            .join('\n'),
        isNot(contains('archive-secret-sentinel-29a4')),
      );
      final sourceAfter = await source.repository.exportArchiveSnapshot();
      expect(
        sourceAfter.map((record) => record.toJson()).toList(),
        sourceBefore.map((record) => record.toJson()).toList(),
      );
      secretFreeArchive.fillRange(0, secretFreeArchive.length, 0);
    },
  );
}

Uint8List _replaceHeaderVersion(Uint8List container, int version) {
  final oldHeaderLength = ByteData.sublistView(container).getUint32(8);
  const oldHeaderStart = 12;
  final oldBodyStart = oldHeaderStart + oldHeaderLength;
  final header = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(container.sublist(oldHeaderStart, oldBodyStart)))
        as Map<String, dynamic>,
  )..['version'] = version;
  final headerBytes = Uint8List.fromList(utf8.encode(canonicalJson(header)));
  final bytes = BytesBuilder(copy: true)
    ..add(utf8.encode(LocalProfileArchiveCodec.containerMagic))
    ..add(_uint32(headerBytes.length))
    ..add(headerBytes)
    ..add(container.sublist(oldBodyStart));
  return bytes.takeBytes();
}

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
  return bytes;
}
