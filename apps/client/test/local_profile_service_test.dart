import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_namespace.dart';
import 'package:aterm_client/storage/local_profile_service.dart';

void main() {
  late Directory directory;
  late File databaseFile;
  late LocalProfileCatalog catalog;
  late LocalProfileService service;
  late VaultCrypto crypto;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-profile-lifecycle-',
    );
    databaseFile = File('${directory.path}/catalog.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(databaseFile));
    service = LocalProfileService(catalog: catalog, crypto: crypto);
  });

  tearDown(() async {
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'creates only encrypted key envelopes and clears owned keys on lock',
    () async {
      final unlocked = await service.create(
        password: 'correct horse battery staple',
      );
      Uint8List? umk;
      Uint8List? vaultKey;
      Uint8List? signingSecret;
      Uint8List? encryptionSecret;
      try {
        expect(unlocked.isLocked, isFalse);
        expect(isCanonicalLocalProfileId(unlocked.record.profileId), isTrue);
        expect(
          isCanonicalLocalProfileId(unlocked.record.localDataDomainId),
          isTrue,
        );
        expect(isCanonicalLocalProfileId(unlocked.record.localVaultId), isTrue);
        expect(
          isCanonicalLocalProfileId(unlocked.record.localDeviceId),
          isTrue,
        );
        expect((await catalog.list()).length, 1);

        umk = unlocked.copyUmk();
        vaultKey = unlocked.copyVaultKey();
        await unlocked.withDeviceIdentity((identity) {
          signingSecret = identity.signing.secretKey.extractBytes();
          encryptionSecret = identity.encryption.secretKey.extractBytes();
        });

        expect(umk, hasLength(32));
        expect(vaultKey, hasLength(32));
        expect(signingSecret, hasLength(64));
        expect(encryptionSecret, hasLength(32));
        expect(unlocked.record.umkEnvelope, contains('ciphertext'));
        expect(unlocked.record.vaultKeyEnvelope, contains('ciphertext'));
        expect(unlocked.record.deviceIdentityEnvelope, contains('ciphertext'));
        expect(
          unlocked.record.deviceIdentityEnvelope,
          isNot(contains('signing_secret')),
        );
        expect(
          unlocked.record.deviceIdentityEnvelope,
          isNot(contains('encryption_secret')),
        );

        final rawDatabase = String.fromCharCodes(
          await databaseFile.readAsBytes(),
        );
        for (final secret in [umk, vaultKey, signingSecret, encryptionSecret]) {
          expect(
            rawDatabase,
            isNot(contains(base64Url.encode(secret!).replaceAll('=', ''))),
          );
        }
      } finally {
        await unlocked.lock();
        umk?.fillRange(0, umk.length, 0);
        vaultKey?.fillRange(0, vaultKey.length, 0);
        signingSecret?.fillRange(0, signingSecret?.length ?? 0, 0);
        encryptionSecret?.fillRange(0, encryptionSecret?.length ?? 0, 0);
      }

      expect(unlocked.isLocked, isTrue);
      expect(unlocked.copyUmk, throwsStateError);
      expect(unlocked.copyVaultKey, throwsStateError);
      await expectLater(
        unlocked.withDeviceIdentity((identity) => identity.deviceId),
        throwsStateError,
      );
    },
  );

  test(
    'wrong password fails and correct password unlocks after catalog reopen',
    () async {
      final created = await service.create(
        password: 'correct horse battery staple',
      );
      final profileId = created.record.profileId;
      final expectedUmk = created.copyUmk();
      final expectedVaultKey = created.copyVaultKey();
      final expectedDevicePublic = await created.withDeviceIdentity(
        (identity) => (identity.signingPublicKey, identity.encryptionPublicKey),
      );
      await created.lock();
      await created.lock();

      await expectLater(
        service.unlock(
          profileId: profileId,
          password: 'wrong password that is still long enough',
        ),
        throwsA(isA<FormatException>()),
      );

      await catalog.close();
      catalog = LocalProfileCatalog.forTesting(NativeDatabase(databaseFile));
      service = LocalProfileService(catalog: catalog, crypto: crypto);
      final reopened = await service.unlock(
        profileId: profileId,
        password: 'correct horse battery staple',
      );
      final actualUmk = reopened.copyUmk();
      final actualVaultKey = reopened.copyVaultKey();
      try {
        expect(reopened.record.profileId, profileId);
        expect(actualUmk, expectedUmk);
        expect(actualVaultKey, expectedVaultKey);
        expect(
          await reopened.withDeviceIdentity(
            (identity) =>
                (identity.signingPublicKey, identity.encryptionPublicKey),
          ),
          expectedDevicePublic,
        );
      } finally {
        await reopened.lock();
        expectedUmk.fillRange(0, expectedUmk.length, 0);
        expectedVaultKey.fillRange(0, expectedVaultKey.length, 0);
        actualUmk.fillRange(0, actualUmk.length, 0);
        actualVaultKey.fillRange(0, actualVaultKey.length, 0);
      }
    },
  );

  test(
    'create rejects a short password before writing a catalog row',
    () async {
      await expectLater(
        service.create(password: 'too short'),
        throwsA(isA<FormatException>()),
      );
      expect(await catalog.list(), isEmpty);
    },
  );

  test('lock waits for borrowed identity and blocks new uses', () async {
    final unlocked = await service.create(
      password: 'correct horse battery staple',
    );
    final callbackEntered = Completer<void>();
    final finishCallback = Completer<void>();
    final identityUse = unlocked.withDeviceIdentity((identity) async {
      callbackEntered.complete();
      await finishCallback.future;
      return identity.deviceId;
    });
    await callbackEntered.future;

    var firstLockFinished = false;
    var secondLockFinished = false;
    final firstLock = unlocked.lock().then((_) => firstLockFinished = true);
    final secondLock = unlocked.lock().then((_) => secondLockFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(unlocked.isLocked, isTrue);
    expect(firstLockFinished, isFalse);
    expect(secondLockFinished, isFalse);
    await expectLater(
      unlocked.withDeviceIdentity((identity) => identity.deviceId),
      throwsStateError,
    );

    finishCallback.complete();
    expect(await identityUse, unlocked.record.localDeviceId);
    await Future.wait([firstLock, secondLock]);
    expect(firstLockFinished, isTrue);
    expect(secondLockFinished, isTrue);
  });
}
