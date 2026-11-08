import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/archive/local_profile_archive.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/host_security_conflict_merge.dart';
import 'package:aterm_client/domain/merge.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _marker = 'host-inline-secret-sentinel-51b24af2';
const _host = HostRecord(
  id: '11111111-1111-4111-8111-111111111111',
  name: 'Inline Host',
  address: 'example.test',
  username: 'deploy',
  login: HostLogin(kind: AuthKind.password, password: _marker),
);

void main() {
  test(
    'inline Host round trips copy and JSON and is a sensitive merge field',
    () {
      final clone = HostRecord.fromJson(
        jsonDecode(jsonEncode(_host.toJson())) as Map<String, dynamic>,
      );
      expect(clone.login, _host.login);
      expect(clone.copyWith(name: 'Renamed', tags: ['api']).login, _host.login);
      expect(clone.copyWith(clearLogin: true).login, isNull);
      expect(conflictKindFor('login'), ConflictKind.credential);
      final base = _host.toJson();
      final conflict = _host
          .copyWith(
            login: const HostLogin(
              kind: AuthKind.password,
              password: 'conflict-secret-sentinel',
            ),
          )
          .toJson();
      final current = _host
          .copyWith(
            login: const HostLogin(
              kind: AuthKind.password,
              password: 'current-secret-sentinel',
            ),
          )
          .toJson();
      final preview = previewHostSecurityConflict(
        conflictId: 'conflict',
        recordId: _host.id,
        baseRevisionId: 'base',
        branchRevisionId: 'branch',
        currentHeadRevisionId: 'head',
        base: base,
        conflict: conflict,
        current: current,
      );
      expect(preview, isNotNull);
      final shown = preview!.fields
          .expand((f) => [f.base, f.conflict, f.current])
          .join(' ');
      expect(shown, isNot(contains(_marker)));
      expect(shown, isNot(contains('conflict-secret-sentinel')));
      expect(shown, isNot(contains('current-secret-sentinel')));
      expect(preview.fields.any((f) => f.label == 'Host login'), isTrue);
      final selected = mergeHostSecurityConflictRecord(
        recordId: _host.id,
        base: base,
        conflict: conflict,
        current: current,
        choice: HostSecurityMergeBranch.conflict,
      );
      expect(selected, isNotNull);
      expect(
        HostRecord.fromJson(
          Map<String, dynamic>.from(selected!),
        ).login?.password,
        'conflict-secret-sentinel',
      );
      expect(
        () => HostLogin.fromJson({
          'kind': 'password',
          'password': _marker,
          'untrusted': true,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'cloud inline resolution rejects locked, replaced and detached Host snapshots',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final controller = AppController(
        sodium: await SodiumSumoInit.init(),
        database: database,
        secureStore: ClientSecureStore(),
      );
      try {
        controller.stage = ClientStage.workspace;
        controller.activeVault = const VaultDescriptor(
          id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
        controller.hosts.add(_host);
        expect(
          controller
              .resolveHostCredential(
                host: _host,
                groupId: null,
                hostCredentialId: null,
              )
              .credential
              ?.secret,
          _marker,
        );
        controller.hosts.clear();
        expect(
          () => controller.resolveHostCredential(
            host: _host,
            groupId: null,
            hostCredentialId: null,
          ),
          throwsStateError,
        );
        controller.hosts.add(
          _host.copyWith(
            login: const HostLogin(
              kind: AuthKind.password,
              password: 'replacement-secret',
            ),
          ),
        );
        expect(
          () => controller.resolveHostCredential(
            host: _host,
            groupId: null,
            hostCredentialId: null,
          ),
          throwsStateError,
        );
        controller.hosts
          ..clear()
          ..add(_host);
        controller.workspaceLocked = true;
        expect(
          () => controller.resolveHostCredential(
            host: _host,
            groupId: null,
            hostCredentialId: null,
          ),
          throwsStateError,
        );
      } finally {
        controller.dispose();
        await database.close();
      }
    },
  );

  test(
    'inline login persists encrypted, crosses archive, rejects resolve after lock and supports legacy credentials',
    () async {
      final sodium = await SodiumSumoInit.init();
      final crypto = VaultCrypto(sodium);
      final directory = await Directory.systemTemp.createTemp(
        'atermius-inline-login-',
      );
      coordinationDirectory = () async => directory;
      final catalog = LocalProfileCatalog.forTesting(
        NativeDatabase(File('${directory.path}/catalog.sqlite')),
      );
      final service = LocalProfileService(catalog: catalog, crypto: crypto);
      final profiles = <UnlockedLocalProfile>[];
      final databases = <LocalVaultDatabase>[];
      Future<LocalHostRepository> open(
        UnlockedLocalProfile profile,
        String name,
      ) async {
        final database = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File('${directory.path}/$name.sqlite')),
          profileId: profile.record.profileId,
          localDataDomainId: profile.record.localDataDomainId,
          localVaultId: profile.record.localVaultId,
        );
        databases.add(database);
        return LocalHostRepository(
          database: database,
          profile: profile,
          crypto: crypto,
        );
      }

      try {
        final profile = await service.create(
          password: 'profile password for inline login',
        );
        profiles.add(profile);
        final repository = await open(profile, 'source');
        final saved = await repository.createHost(_host);
        expect(
          (await repository.resolveCredentialForHost(saved))?.secret,
          _marker,
        );
        final archiveService = LocalProfileArchiveService(sodium);
        final archive = await archiveService.export(
          repository: repository,
          password: 'archive password for inline login',
        );
        expect(latin1.decode(archive), isNot(contains(_marker)));
        final snapshot = await archiveService.stageImport(
          container: archive,
          password: 'archive password for inline login',
        );
        final destinationProfile = await service.create(
          password: 'destination profile password',
        );
        profiles.add(destinationProfile);
        final destination = await open(destinationProfile, 'destination');
        await archiveService.importIntoEmptyProfile(
          repository: destination,
          snapshot: snapshot,
        );
        final imported = await destination.getHost(saved.id);
        expect(imported?.login, saved.login);
        expect(
          (await destination.resolveCredentialForHost(imported!))?.secret,
          _marker,
        );
        await profile.lock();
        await expectLater(
          repository.resolveCredentialForHost(saved),
          throwsStateError,
        );
        await databases.first.close();
        databases.removeAt(0);
        final reopenedProfile = await service.unlock(
          profileId: profile.record.profileId,
          password: 'profile password for inline login',
        );
        profiles.add(reopenedProfile);
        final reopened = await open(reopenedProfile, 'source');
        final restored = await reopened.getHost(saved.id);
        expect(restored?.login?.password, _marker);
        expect(
          (await reopened.resolveCredentialForHost(restored!))?.secret,
          _marker,
        );
        const credential = CredentialRecord(
          id: '22222222-2222-4222-8222-222222222222',
          name: 'Legacy',
          username: 'deploy',
          secret: 'legacy-secret',
        );
        await reopened.createCredential(credential);
        final legacy = await reopened.createHost(
          _host.copyWith(clearLogin: true, credentialId: credential.id),
        );
        expect(
          (await reopened.resolveCredentialForHost(legacy))?.secret,
          'legacy-secret',
        );
        for (final database in databases) {
          await database.close();
        }
        databases.clear();
        for (final file
            in directory.listSync(recursive: true).whereType<File>()) {
          final raw = latin1.decode(await file.readAsBytes());
          expect(
            raw,
            isNot(contains(_marker)),
            reason: 'Host secret must not appear in ${file.path}',
          );
        }
      } finally {
        for (final database in databases.reversed) {
          await database.close();
        }
        for (final profile in profiles) {
          await profile.lock();
        }
        await catalog.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
