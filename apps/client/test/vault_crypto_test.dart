import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;
  late VaultCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
  });

  test(
    'local Vault key package is ciphertext-only and bound to its context',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      const vaultId = '33333333-3333-4333-8333-333333333333';
      final umk = crypto.randomBytes(32);
      final vaultKey = crypto.randomBytes(32);
      Uint8List? opened;
      try {
        final envelope = await crypto.wrapLocalVaultKey(
          umk: umk,
          vaultKey: vaultKey,
          profileId: profileId,
          localDataDomainId: domainId,
          localVaultId: vaultId,
          keyEpoch: 7,
        );
        expect(envelope['format'], 'atermius-local-vault-key-envelope');
        expect(envelope['purpose'], 'local-vault-key-wrap');
        expect(envelope['key_epoch'], 7);
        expect(envelope['suite'], 'xchacha20-poly1305-ietf');
        expect(decodeBase64Url(envelope['nonce']! as String), hasLength(24));
        expect(
          decodeBase64Url(envelope['ciphertext']! as String),
          hasLength(48),
        );
        expect(
          jsonEncode(envelope),
          isNot(contains(encodeBase64Url(vaultKey))),
        );
        expect(envelope.keys.toSet(), {
          'format',
          'envelope_version',
          'key_version',
          'purpose',
          'profile_id',
          'local_data_domain_id',
          'local_vault_id',
          'key_epoch',
          'suite',
          'nonce',
          'ciphertext',
        });

        opened = await crypto.unwrapLocalVaultKey(
          umk: umk,
          envelope: Map<String, dynamic>.from(envelope),
          profileId: profileId,
          localDataDomainId: domainId,
          localVaultId: vaultId,
          keyEpoch: 7,
        );
        expect(opened, vaultKey);

        final wrongUmk = crypto.randomBytes(32);
        try {
          await expectLater(
            crypto.unwrapLocalVaultKey(
              umk: wrongUmk,
              envelope: Map<String, dynamic>.from(envelope),
              profileId: profileId,
              localDataDomainId: domainId,
              localVaultId: vaultId,
              keyEpoch: 7,
            ),
            throwsFormatException,
          );
        } finally {
          wrongUmk.fillRange(0, wrongUmk.length, 0);
        }

        for (final (
              field,
              replacement,
              expectedProfile,
              expectedDomain,
              expectedVault,
              expectedEpoch,
            )
            in <(String, Object, String, String, String, int)>[
              (
                'profile_id',
                '44444444-4444-4444-8444-444444444444',
                '44444444-4444-4444-8444-444444444444',
                domainId,
                vaultId,
                7,
              ),
              (
                'local_data_domain_id',
                '55555555-5555-4555-8555-555555555555',
                profileId,
                '55555555-5555-4555-8555-555555555555',
                vaultId,
                7,
              ),
              (
                'local_vault_id',
                '66666666-6666-4666-8666-666666666666',
                profileId,
                domainId,
                '66666666-6666-4666-8666-666666666666',
                7,
              ),
              ('key_epoch', 8, profileId, domainId, vaultId, 8),
            ]) {
          final rebound = Map<String, dynamic>.from(envelope)
            ..[field] = replacement;
          await expectLater(
            crypto.unwrapLocalVaultKey(
              umk: umk,
              envelope: rebound,
              profileId: expectedProfile,
              localDataDomainId: expectedDomain,
              localVaultId: expectedVault,
              keyEpoch: expectedEpoch,
            ),
            throwsFormatException,
          );
        }

        for (final (field, replacement) in <(String, Object)>[
          ('format', 'other-format'),
          ('envelope_version', 2),
          ('key_version', 2),
          ('purpose', 'local-device-identity-wrap'),
          ('suite', 'other-suite'),
        ]) {
          final tampered = Map<String, dynamic>.from(envelope)
            ..[field] = replacement;
          await expectLater(
            crypto.unwrapLocalVaultKey(
              umk: umk,
              envelope: tampered,
              profileId: profileId,
              localDataDomainId: domainId,
              localVaultId: vaultId,
              keyEpoch: 7,
            ),
            throwsFormatException,
          );
        }
        final missing = Map<String, dynamic>.from(envelope)..remove('purpose');
        final extra = Map<String, dynamic>.from(envelope)
          ..['unexpected'] = true;
        final malformedBytes = Map<String, dynamic>.from(envelope)
          ..['ciphertext'] = '%%%';
        for (final invalid in [missing, extra, malformedBytes]) {
          await expectLater(
            crypto.unwrapLocalVaultKey(
              umk: umk,
              envelope: invalid,
              profileId: profileId,
              localDataDomainId: domainId,
              localVaultId: vaultId,
              keyEpoch: 7,
            ),
            throwsFormatException,
          );
        }
      } finally {
        umk.fillRange(0, umk.length, 0);
        vaultKey.fillRange(0, vaultKey.length, 0);
        opened?.fillRange(0, opened.length, 0);
      }
    },
  );

  test(
    'local DeviceIdentity package seals private keys and validates key pairs',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      final umk = crypto.randomBytes(32);
      final identity = DeviceIdentity.create(sodium);
      DeviceIdentity? opened;
      try {
        final envelope = await crypto.wrapLocalDeviceIdentity(
          umk: umk,
          identity: identity,
          profileId: profileId,
          localDataDomainId: domainId,
          localDeviceId: identity.deviceId,
          keyVersion: 3,
        );
        expect(envelope['format'], 'atermius-local-device-identity-envelope');
        expect(envelope['purpose'], 'local-device-identity-wrap');
        expect(envelope['key_version'], 3);
        expect(decodeBase64Url(envelope['nonce']! as String), hasLength(24));
        expect(
          decodeBase64Url(envelope['ciphertext']! as String),
          hasLength(64 + 32 + 16),
        );
        expect(envelope.containsKey('signing_secret'), isFalse);
        expect(envelope.containsKey('encryption_secret'), isFalse);
        final persistedJson = jsonEncode(envelope);
        final signingSecretBytes = identity.signing.secretKey.extractBytes();
        final encryptionSecretBytes = identity.encryption.secretKey
            .extractBytes();
        try {
          expect(
            persistedJson,
            isNot(contains(encodeBase64Url(signingSecretBytes))),
          );
          expect(
            persistedJson,
            isNot(contains(encodeBase64Url(encryptionSecretBytes))),
          );
        } finally {
          signingSecretBytes.fillRange(0, signingSecretBytes.length, 0);
          encryptionSecretBytes.fillRange(0, encryptionSecretBytes.length, 0);
        }

        opened = await crypto.unwrapLocalDeviceIdentity(
          umk: umk,
          envelope: Map<String, dynamic>.from(envelope),
          profileId: profileId,
          localDataDomainId: domainId,
          localDeviceId: identity.deviceId,
          keyVersion: 3,
        );
        expect(opened.signingPublicKey, identity.signingPublicKey);
        expect(opened.encryptionPublicKey, identity.encryptionPublicKey);

        final proof = opened.registrationProof(
          sodium,
          accountId: '77777777-7777-4777-8777-777777777777',
        );
        final signedPayload = <String, Object?>{
          'account_id': proof['account_id'],
          'device_id': proof['device_id'],
          'signing_public_key': proof['signing_public_key'],
          'encryption_public_key': proof['encryption_public_key'],
        };
        expect(
          sodium.crypto.sign.verifyDetached(
            message: Uint8List.fromList(
              utf8.encode(canonicalJson(signedPayload)),
            ),
            signature: decodeBase64Url(proof['signature']! as String),
            publicKey: opened.signing.publicKey,
          ),
          isTrue,
        );
        final challenge = Uint8List.fromList(
          utf8.encode('local identity challenge'),
        );
        final sealedChallenge = sodium.crypto.box.seal(
          message: challenge,
          publicKey: opened.encryption.publicKey,
        );
        final decryptedChallenge = sodium.crypto.box.sealOpen(
          cipherText: sealedChallenge,
          publicKey: opened.encryption.publicKey,
          secretKey: opened.encryption.secretKey,
        );
        expect(decryptedChallenge, challenge);
        challenge.fillRange(0, challenge.length, 0);
        sealedChallenge.fillRange(0, sealedChallenge.length, 0);
        decryptedChallenge.fillRange(0, decryptedChallenge.length, 0);

        final wrongUmk = crypto.randomBytes(32);
        try {
          await expectLater(
            crypto.unwrapLocalDeviceIdentity(
              umk: wrongUmk,
              envelope: Map<String, dynamic>.from(envelope),
              profileId: profileId,
              localDataDomainId: domainId,
              localDeviceId: identity.deviceId,
              keyVersion: 3,
            ),
            throwsFormatException,
          );
        } finally {
          wrongUmk.fillRange(0, wrongUmk.length, 0);
        }

        for (final (
              field,
              replacement,
              expectedProfile,
              expectedDomain,
              expectedDevice,
              expectedVersion,
            )
            in <(String, Object, String, String, String, int)>[
              (
                'profile_id',
                '44444444-4444-4444-8444-444444444444',
                '44444444-4444-4444-8444-444444444444',
                domainId,
                identity.deviceId,
                3,
              ),
              (
                'local_data_domain_id',
                '55555555-5555-4555-8555-555555555555',
                profileId,
                '55555555-5555-4555-8555-555555555555',
                identity.deviceId,
                3,
              ),
              (
                'local_device_id',
                '66666666-6666-4666-8666-666666666666',
                profileId,
                domainId,
                '66666666-6666-4666-8666-666666666666',
                3,
              ),
              ('key_version', 4, profileId, domainId, identity.deviceId, 4),
            ]) {
          final rebound = Map<String, dynamic>.from(envelope)
            ..[field] = replacement;
          await expectLater(
            crypto.unwrapLocalDeviceIdentity(
              umk: umk,
              envelope: rebound,
              profileId: expectedProfile,
              localDataDomainId: expectedDomain,
              localDeviceId: expectedDevice,
              keyVersion: expectedVersion,
            ),
            throwsFormatException,
          );
        }
        for (final (field, replacement) in <(String, Object)>[
          ('format', 'other-format'),
          ('envelope_version', 2),
          ('purpose', 'local-vault-key-wrap'),
          ('signing_algorithm', 'other-signing'),
          ('encryption_algorithm', 'other-encryption'),
          ('suite', 'other-suite'),
          ('signing_public', encodeBase64Url(crypto.randomBytes(32))),
          ('encryption_public', encodeBase64Url(crypto.randomBytes(32))),
        ]) {
          final tampered = Map<String, dynamic>.from(envelope)
            ..[field] = replacement;
          await expectLater(
            crypto.unwrapLocalDeviceIdentity(
              umk: umk,
              envelope: tampered,
              profileId: profileId,
              localDataDomainId: domainId,
              localDeviceId: identity.deviceId,
              keyVersion: 3,
            ),
            throwsFormatException,
          );
        }
        final missing = Map<String, dynamic>.from(envelope)
          ..remove('local_device_id');
        final extra = Map<String, dynamic>.from(envelope)
          ..['unexpected'] = true;
        for (final invalid in [missing, extra]) {
          await expectLater(
            crypto.unwrapLocalDeviceIdentity(
              umk: umk,
              envelope: invalid,
              profileId: profileId,
              localDataDomainId: domainId,
              localDeviceId: identity.deviceId,
              keyVersion: 3,
            ),
            throwsFormatException,
          );
        }
      } finally {
        umk.fillRange(0, umk.length, 0);
        opened?.dispose();
        identity.dispose();
      }
    },
  );

  test(
    'local UMK envelope is versioned and bound to profile and data domain',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      const otherProfileId = '33333333-3333-4333-8333-333333333333';
      const otherDomainId = '44444444-4444-4444-8444-444444444444';
      const password = 'correct horse battery staple';
      final params = KdfParameters.defaults(sodium);
      final umk = crypto.randomBytes(32);
      Uint8List? opened;
      try {
        final excessiveKdf = KdfParameters(
          salt: sodium.randombytes.buf(16),
          memoryKib: 1048576,
        );
        await expectLater(
          crypto.wrapLocalUmk(
            password: password,
            params: params,
            umk: Uint8List(31),
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );
        await expectLater(
          crypto.wrapLocalUmk(
            password: password,
            params: excessiveKdf,
            umk: umk,
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );
        await expectLater(
          crypto.wrapLocalUmk(
            password: password,
            params: params,
            umk: umk,
            profileId: 'not-a-uuid',
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );

        final envelope = await crypto.wrapLocalUmk(
          password: password,
          params: params,
          umk: umk,
          profileId: profileId,
          localDataDomainId: domainId,
        );

        expect(envelope['format'], 'atermius-local-umk-envelope');
        expect(envelope['envelope_version'], 1);
        expect(envelope['key_version'], 1);
        expect(envelope['purpose'], 'local-umk-wrap');
        expect(envelope['profile_id'], profileId);
        expect(envelope['local_data_domain_id'], domainId);
        expect(decodeBase64Url(envelope['nonce']! as String), hasLength(24));
        expect(
          decodeBase64Url(envelope['ciphertext']! as String),
          hasLength(32 + 16),
        );

        opened = await crypto.unwrapLocalUmk(
          password: password,
          envelope: Map<String, dynamic>.from(envelope),
          profileId: profileId,
          localDataDomainId: domainId,
        );
        expect(opened, umk);

        await expectLater(
          crypto.unwrapLocalUmk(
            password: 'incorrect password',
            envelope: Map<String, dynamic>.from(envelope),
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );

        // Rebind both context IDs in the envelope and caller. Since both
        // replacements are canonical UUIDs, rejection must come from AEAD AAD.
        final rebound = Map<String, dynamic>.from(envelope)
          ..['profile_id'] = otherProfileId
          ..['local_data_domain_id'] = otherDomainId;
        await expectLater(
          crypto.unwrapLocalUmk(
            password: password,
            envelope: rebound,
            profileId: otherProfileId,
            localDataDomainId: otherDomainId,
          ),
          throwsFormatException,
        );

        // A different expected context is rejected before any KDF work.
        await expectLater(
          crypto.unwrapLocalUmk(
            password: password,
            envelope: Map<String, dynamic>.from(envelope),
            profileId: otherProfileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );

        for (final (field, replacement) in <(String, Object)>[
          ('envelope_version', 2),
          ('key_version', 2),
          ('purpose', 'account-key-wrap'),
        ]) {
          final tampered = Map<String, dynamic>.from(envelope)
            ..[field] = replacement;
          await expectLater(
            crypto.unwrapLocalUmk(
              password: password,
              envelope: tampered,
              profileId: profileId,
              localDataDomainId: domainId,
            ),
            throwsFormatException,
          );
        }

        final badNonce = Map<String, dynamic>.from(envelope)..['nonce'] = '';
        await expectLater(
          crypto.unwrapLocalUmk(
            password: password,
            envelope: badNonce,
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );

        final badCiphertext = Map<String, dynamic>.from(envelope)
          ..['ciphertext'] = '';
        await expectLater(
          crypto.unwrapLocalUmk(
            password: password,
            envelope: badCiphertext,
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );

        final excessiveKdfEnvelope = Map<String, dynamic>.from(envelope)
          ..['kdf'] = Map<String, dynamic>.from(envelope['kdf']! as Map)
          ..['mem_kib'] = 1048576;
        await expectLater(
          crypto.unwrapLocalUmk(
            password: password,
            envelope: excessiveKdfEnvelope,
            profileId: profileId,
            localDataDomainId: domainId,
          ),
          throwsFormatException,
        );
      } finally {
        umk.fillRange(0, umk.length, 0);
        opened?.fillRange(0, opened.length, 0);
      }
    },
  );

  test('device approval transfers and opens every epoch key', () async {
    final approver = DeviceIdentity.create(sodium);
    final target = DeviceIdentity.create(sodium);
    const vaultId = '11111111-1111-4111-8111-111111111111';
    final epochs = <({int epoch, int membership, Uint8List key})>[
      (epoch: 1, membership: 1, key: crypto.randomBytes(32)),
      (epoch: 2, membership: 3, key: crypto.randomBytes(32)),
    ];

    for (final source in epochs) {
      final signed = crypto.createDeviceKeyEnvelope(
        vaultId: vaultId,
        vaultKey: source.key,
        keyEpoch: source.epoch,
        membershipVersion: source.membership,
        recipientDeviceId: target.deviceId,
        recipientEncryptionPublicKey: target.encryption.publicKey,
        signer: approver,
      );
      // The API adds signer_device_id as transport metadata. It is deliberately
      // excluded from the signed payload.
      final serverEnvelope = <String, dynamic>{
        'recipient_device_id': signed['recipient_device_id'],
        'key_epoch': signed['key_epoch'],
        'membership_version': signed['membership_version'],
        'envelope': signed['envelope'],
        'signature': signed['signature'],
        'signer_device_id': approver.deviceId,
      };
      final opened = await crypto.openVaultKeyEnvelope(
        vaultId: vaultId,
        deviceId: target.deviceId,
        identity: target,
        keyEnvelope: serverEnvelope,
        signerPublicKey: approver.signing.publicKey,
      );
      expect(opened, source.key);
    }

    final signed = crypto.createDeviceKeyEnvelope(
      vaultId: vaultId,
      vaultKey: epochs.first.key,
      keyEpoch: epochs.first.epoch,
      membershipVersion: epochs.first.membership,
      recipientDeviceId: target.deviceId,
      recipientEncryptionPublicKey: target.encryption.publicKey,
      signer: approver,
    );
    final tampered = <String, dynamic>{
      'recipient_device_id': signed['recipient_device_id'],
      'key_epoch': 2,
      'membership_version': signed['membership_version'],
      'envelope': signed['envelope'],
      'signature': signed['signature'],
    };
    await expectLater(
      crypto.openVaultKeyEnvelope(
        vaultId: vaultId,
        deviceId: target.deviceId,
        identity: target,
        keyEnvelope: tampered,
        signerPublicKey: approver.signing.publicKey,
      ),
      throwsFormatException,
    );
    approver.dispose();
    target.dispose();
  });

  test('Vault share Device Cards self-verify and contain public keys only', () {
    final target = DeviceIdentity.create(sodium);
    const accountId = '22222222-2222-4222-8222-222222222222';
    const instanceId = '33333333-3333-4333-8333-333333333333';
    final request = crypto.createVaultShareRequest(
      accountId: accountId,
      instanceId: instanceId,
      identity: target,
      name: 'Recipient browser',
    );
    final verified = crypto.verifyVaultShareRequest(
      request,
      expectedInstanceId: instanceId,
    );
    expect(verified.accountId, accountId);
    expect(verified.deviceId, target.deviceId);
    expect(verified.name, 'Recipient browser');
    expect(verified.device.containsKey('signing_secret'), isFalse);
    expect(verified.device.containsKey('encryption_secret'), isFalse);

    final tampered = jsonDecode(request) as Map<String, dynamic>;
    final rawDevice = Map<String, dynamic>.from(tampered['device'] as Map);
    rawDevice['encryption_public_key'] = target.signingPublicKey;
    tampered['device'] = rawDevice;
    expect(
      () => crypto.verifyVaultShareRequest(
        jsonEncode(tampered),
        expectedInstanceId: instanceId,
      ),
      throwsFormatException,
    );
    expect(
      () => crypto.verifyVaultShareRequest(
        request,
        expectedInstanceId: '44444444-4444-4444-8444-444444444444',
      ),
      throwsFormatException,
    );
    target.dispose();
  });

  test(
    'instance key rotations require a continuous old-key signature chain',
    () {
      const instanceId = '55555555-5555-4555-8555-555555555555';
      const format = 'atermius-instance-key-transition-v1';
      final first = DeviceIdentity.create(sodium);
      final second = DeviceIdentity.create(sodium);
      final third = DeviceIdentity.create(sodium);

      Map<String, dynamic> transition(
        DeviceIdentity signer,
        String toPublicKey, {
        String? fromPublicKey,
      }) {
        final unsigned = <String, Object?>{
          'format': format,
          'instance_id': instanceId,
          'from_public_key': fromPublicKey ?? signer.signingPublicKey,
          'to_public_key': toPublicKey,
          'issued_at': '2026-09-27T12:00:00Z',
        };
        return {
          ...unsigned,
          'signature': encodeBase64Url(
            sodium.crypto.sign.detached(
              message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
              secretKey: signer.signing.secretKey,
            ),
          ),
        };
      }

      final chain = [
        transition(first, second.signingPublicKey),
        transition(second, third.signingPublicKey),
      ];
      expect(
        crypto.verifyInstanceKeyTransitions(
          instanceId: instanceId,
          pinnedPublicKey: first.signingPublicKey,
          currentPublicKey: third.signingPublicKey,
          transitions: chain,
        ),
        isTrue,
      );
      // A device that already pinned the intermediate key may start at its link.
      expect(
        crypto.verifyInstanceKeyTransitions(
          instanceId: instanceId,
          pinnedPublicKey: second.signingPublicKey,
          currentPublicKey: third.signingPublicKey,
          transitions: chain,
        ),
        isTrue,
      );
      expect(
        crypto.verifyInstanceKeyTransitions(
          instanceId: instanceId,
          pinnedPublicKey: first.signingPublicKey,
          currentPublicKey: third.signingPublicKey,
          transitions: [
            chain.first,
            {...chain.last, 'to_public_key': second.signingPublicKey},
          ],
        ),
        isFalse,
      );
      expect(
        crypto.verifyInstanceKeyTransitions(
          instanceId: instanceId,
          pinnedPublicKey: first.signingPublicKey,
          currentPublicKey: third.signingPublicKey,
          transitions: [
            chain.first,
            {
              ...chain.last,
              'instance_id': '66666666-6666-4666-8666-666666666666',
            },
          ],
        ),
        isFalse,
      );
      expect(
        crypto.verifyInstanceKeyTransitions(
          instanceId: instanceId,
          pinnedPublicKey: first.signingPublicKey,
          currentPublicKey: third.signingPublicKey,
          transitions: [chain.last],
        ),
        isFalse,
      );
      first.dispose();
      second.dispose();
      third.dispose();
    },
  );

  test('membership invite grants carry owner JCS signature', () {
    final owner = DeviceIdentity.create(sodium);
    const vaultId = '11111111-1111-4111-8111-111111111111';
    const targetId = '22222222-2222-4222-8222-222222222222';
    final manifest = <String, Object?>{
      'key_epoch': 1,
      'members': [
        {
          'user_id': targetId,
          'role': 'viewer',
          'state': 'active',
          'encryption_key_fingerprint': 'fingerprint',
        },
      ],
      'signer_device_id': owner.deviceId,
    };
    final membership = crypto.createMembershipGrant(
      vaultId: vaultId,
      membershipVersion: 2,
      previousDigest: 'previous-digest',
      manifest: manifest,
      signer: owner,
    );
    final payload = <String, Object?>{
      'vault_id': vaultId,
      'membership_version': 2,
      'previous_digest': 'previous-digest',
      'manifest': manifest,
    };
    expect(
      sodium.crypto.sign.verifyDetached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
        signature: decodeBase64Url(membership['signature']! as String),
        publicKey: owner.signing.publicKey,
      ),
      isTrue,
    );
    owner.dispose();
  });

  test(
    'display name envelope is part of the signed initial manifest and can rotate',
    () async {
      final owner = DeviceIdentity.create(sodium);
      const accountId = '22222222-2222-4222-8222-222222222222';
      const name = 'Shared operations';
      final initial = await crypto.createInitialVault(
        accountId: accountId,
        name: name,
        identity: owner,
      );
      final topLevelName = Map<String, dynamic>.from(
        initial.payload['name_envelope']! as Map,
      );
      final initialMembership = Map<String, dynamic>.from(
        initial.payload['membership']! as Map,
      );
      final initialManifest = Map<String, dynamic>.from(
        initialMembership['manifest']! as Map,
      );
      final signedName = Map<String, dynamic>.from(
        initialManifest['display_name_envelope']! as Map,
      );
      expect(canonicalJson(signedName), canonicalJson(topLevelName));
      expect(
        await crypto.decryptVaultName(
          vaultId: initial.vaultId,
          vaultKey: initial.vaultKey,
          envelope: signedName,
        ),
        name,
      );

      final nextKey = crypto.randomBytes(32);
      final nextNameEnvelope = await crypto.encryptVaultName(
        vaultId: initial.vaultId,
        vaultKey: nextKey,
        name: name,
      );
      expect(
        await crypto.decryptVaultName(
          vaultId: initial.vaultId,
          vaultKey: nextKey,
          envelope: nextNameEnvelope,
        ),
        name,
      );
      nextKey.fillRange(0, nextKey.length, 0);
      initial.vaultKey.fillRange(0, initial.vaultKey.length, 0);
      owner.dispose();
    },
  );

  test('device approval certificates bind target device and approver', () {
    final approver = DeviceIdentity.create(sodium);
    final target = DeviceIdentity.create(sodium);
    const accountId = '22222222-2222-4222-8222-222222222222';
    final device = target.registrationProof(
      sodium,
      accountId: accountId,
      name: 'Approved browser',
    );
    final payload = <String, Object?>{
      'account_id': accountId,
      'approver_device_id': approver.deviceId,
      'device': device,
    };
    final signature = encodeBase64Url(
      sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
        secretKey: approver.signing.secretKey,
      ),
    );
    expect(
      crypto.verifyDeviceApprovalCertificate(
        accountId: accountId,
        approverDeviceId: approver.deviceId,
        device: device,
        signature: signature,
        approverSigningPublicKey: approver.signing.publicKey,
      ),
      isTrue,
    );
    expect(
      crypto.verifyDeviceApprovalCertificate(
        accountId: accountId,
        approverDeviceId: target.deviceId,
        device: device,
        signature: signature,
        approverSigningPublicKey: approver.signing.publicKey,
      ),
      isFalse,
    );
    final altered = Map<String, dynamic>.from(device)..['name'] = 'Other';
    expect(
      crypto.verifyDeviceApprovalCertificate(
        accountId: accountId,
        approverDeviceId: approver.deviceId,
        device: altered,
        signature: signature,
        approverSigningPublicKey: approver.signing.publicKey,
      ),
      isFalse,
    );
    approver.dispose();
    target.dispose();
  });

  test(
    'membership chain verifies signatures, versions, and digest links',
    () async {
      final owner = DeviceIdentity.create(sodium);
      const accountId = '22222222-2222-4222-8222-222222222222';
      final initial = await crypto.createInitialVault(
        accountId: accountId,
        name: 'Personal vault',
        identity: owner,
      );
      final membership = Map<String, dynamic>.from(
        initial.payload['membership']! as Map,
      );
      final body = Map<String, dynamic>.from(membership['manifest']! as Map);
      final signedPayload = <String, Object?>{
        'vault_id': initial.vaultId,
        'membership_version': membership['membership_version'],
        'previous_digest': membership['previous_digest'],
        'manifest': body,
      };
      final digest = await cryptography.Sha256().hash(
        utf8.encode(canonicalJson(signedPayload)),
      );
      final digestHex = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final storedSignedManifest = <String, Object?>{
        'vault_id': initial.vaultId,
        ...membership,
      };
      final chain = await crypto.verifyMembershipChain(
        vaultId: initial.vaultId,
        entries: [
          {
            'membership_version': 1,
            'previous_digest': null,
            'manifest': storedSignedManifest,
            'signature': membership['signature'],
            'signer_device_id': owner.deviceId,
            'digest': digestHex,
          },
        ],
        signerPublicKeys: {owner.deviceId: owner.signing.publicKey},
        expectedLatestVersion: 1,
      );
      expect(chain.single.version, 1);
      expect(chain.single.digest, digestHex);
      expect(chain.single.manifest['signer_device_id'], owner.deviceId);

      await expectLater(
        crypto.verifyMembershipChain(
          vaultId: initial.vaultId,
          entries: [
            {
              'membership_version': 1,
              'previous_digest': null,
              'manifest': {
                ...storedSignedManifest,
                'manifest': {...body, 'key_epoch': 2},
              },
              'signature': membership['signature'],
              'signer_device_id': owner.deviceId,
              'digest': digestHex,
            },
          ],
          signerPublicKeys: {owner.deviceId: owner.signing.publicKey},
          expectedLatestVersion: 1,
        ),
        throwsFormatException,
      );
      owner.dispose();
      initial.vaultKey.fillRange(0, initial.vaultKey.length, 0);
    },
  );

  test(
    'membership chain keeps key epoch stable or advances it by one',
    () async {
      final owner = DeviceIdentity.create(sodium);
      final initial = await crypto.createInitialVault(
        accountId: '22222222-2222-4222-8222-222222222222',
        name: 'Epoch monotonicity',
        identity: owner,
      );
      try {
        final initialMembership = Map<String, dynamic>.from(
          initial.payload['membership']! as Map,
        );
        final initialManifest = Map<String, Object?>.from(
          initialMembership['manifest']! as Map,
        );
        final initialEntry = <String, dynamic>{
          'membership_version': initialMembership['membership_version'],
          'previous_digest': initialMembership['previous_digest'],
          'manifest': initialManifest,
          'signature': initialMembership['signature'],
          'signer_device_id': owner.deviceId,
        };
        Map<String, dynamic> signedEntry({
          required int version,
          required int epoch,
          required String previousDigest,
        }) {
          final grant = crypto.createMembershipGrant(
            vaultId: initial.vaultId,
            membershipVersion: version,
            previousDigest: previousDigest,
            manifest: {...initialManifest, 'key_epoch': epoch},
            signer: owner,
          );
          return Map<String, dynamic>.from({
            ...grant,
            'signer_device_id': owner.deviceId,
          });
        }

        Future<List<VerifiedMembership>> verify(
          List<Map<String, dynamic>> entries,
        ) => crypto.verifyMembershipChain(
          vaultId: initial.vaultId,
          entries: entries,
          signerPublicKeys: {owner.deviceId: owner.signing.publicKey},
          expectedLatestVersion: entries.length,
        );

        final versionOne = await verify([initialEntry]);
        final sameEpoch = signedEntry(
          version: 2,
          epoch: 1,
          previousDigest: versionOne.last.digest,
        );
        final versionTwo = await verify([initialEntry, sameEpoch]);
        final oneStepRotation = signedEntry(
          version: 3,
          epoch: 2,
          previousDigest: versionTwo.last.digest,
        );
        final versionThree = await verify([
          initialEntry,
          sameEpoch,
          oneStepRotation,
        ]);
        expect(
          versionThree.map((entry) => entry.manifest['key_epoch']).toList(),
          [1, 1, 2],
        );

        final rollback = signedEntry(
          version: 4,
          epoch: 1,
          previousDigest: versionThree.last.digest,
        );
        await expectLater(
          verify([initialEntry, sameEpoch, oneStepRotation, rollback]),
          throwsFormatException,
        );
        final skippedEpoch = signedEntry(
          version: 4,
          epoch: 4,
          previousDigest: versionThree.last.digest,
        );
        await expectLater(
          verify([initialEntry, sameEpoch, oneStepRotation, skippedEpoch]),
          throwsFormatException,
        );
      } finally {
        owner.dispose();
        initial.vaultKey.fillRange(0, initial.vaultKey.length, 0);
      }
    },
  );
}
