import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
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
  UnlockedLocalProfile? profile;
  LocalVaultDatabase? vault;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-local-vault-fail-closed-',
    );
    catalogFile = File('${directory.path}/catalog.sqlite');
    vaultFile = File('${directory.path}/vault.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    profile = null;
    vault = null;
  });

  tearDown(() async {
    await vault?.close();
    await profile?.lock();
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'deleted Vault fails closed on unlock without changing the profile catalog',
    () async {
      final createdProfile = await service.create(
        password: 'correct horse battery staple',
      );
      profile = createdProfile;
      final profileId = createdProfile.record.profileId;
      final catalogBeforeDeletion = (await catalog.list())
          .map((record) => record.toJson())
          .toList(growable: false);

      final createdVault = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(vaultFile),
        profileId: createdProfile.record.profileId,
        localDataDomainId: createdProfile.record.localDataDomainId,
        localVaultId: createdProfile.record.localVaultId,
        mode: LocalVaultOpenMode.createNew,
      );
      vault = createdVault;
      final repository = LocalHostRepository(
        database: createdVault,
        profile: createdProfile,
        crypto: crypto,
      );
      final savedHost = await repository.createHost(
        const HostRecord(
          id: 'draft-id',
          name: 'Encrypted regression fixture',
          address: 'vault.example.test',
          username: 'deploy',
        ),
        recordId: 'f745800b-4f05-4513-bc60-78f97c54c998',
      );
      expect(
        (await repository.getHost(savedHost.id))?.name,
        'Encrypted regression fixture',
      );

      await createdVault.close();
      vault = null;
      await createdProfile.lock();
      profile = null;
      await catalog.close();

      await vaultFile.delete();
      for (final suffix in const ['-wal', '-shm']) {
        final sidecar = File('${vaultFile.path}$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }

      // Reopen the durable catalog as a fresh app process would before unlock.
      catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
      service = LocalProfileService(catalog: catalog, crypto: crypto);
      final unlockedProfile = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      profile = unlockedProfile;

      Future<void> expectMissingBinding() async {
        await expectLater(
          LocalVaultDatabase.openForTesting(
            executor: NativeDatabase(vaultFile),
            profileId: unlockedProfile.record.profileId,
            localDataDomainId: unlockedProfile.record.localDataDomainId,
            localVaultId: unlockedProfile.record.localVaultId,
            mode: LocalVaultOpenMode.openExisting,
          ),
          throwsA(
            predicate(
              (error) =>
                  error is LocalVaultBindingMissingException &&
                  error.toString() ==
                      'Local profile storage is missing or unavailable.',
            ),
          ),
        );
      }

      await expectMissingBinding();
      expect(await vaultFile.exists(), isTrue);
      // A failed attempt must not bind the newly initialized empty database.
      await expectMissingBinding();
      expect(
        (await catalog.list()).map((record) => record.toJson()).toList(),
        equals(catalogBeforeDeletion),
      );
    },
  );
}
