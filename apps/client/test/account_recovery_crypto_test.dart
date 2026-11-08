import 'dart:typed_data';

import 'package:aterm_client/crypto/account_recovery_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;
  late AccountRecoveryCrypto recoveryCrypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    recoveryCrypto = AccountRecoveryCrypto(sodium);
  });

  test(
    'recovery identity has independent code and account-key wrappers',
    () async {
      const accountId = '11111111-1111-4111-8111-111111111111';
      const instanceId = '22222222-2222-4222-8222-222222222222';
      const serverSpaceId = '33333333-3333-4333-8333-333333333333';
      final identity = recoveryCrypto.createIdentity(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: 1,
      );
      final recoveryCode = recoveryCrypto.createRecoveryCode();
      final accountKey = recoveryCrypto.randomBytes(32);
      RecoveryIdentity? fromCode;
      RecoveryIdentity? fromAccountKey;
      try {
        expect(recoveryCode, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        final codeEnvelope = await recoveryCrypto.sealIdentityWithRecoveryCode(
          identity: identity,
          recoveryCode: recoveryCode,
        );
        final accountEnvelope = await recoveryCrypto.sealIdentityWithAccountKey(
          identity: identity,
          accountKey: accountKey,
        );
        expect(codeEnvelope['suite'], 'xchacha20-poly1305-ietf');
        expect(accountEnvelope['suite'], 'xchacha20-poly1305-ietf');
        expect(
          decodeBase64Url(codeEnvelope['ciphertext']! as String),
          hasLength(528),
        );
        expect(
          codeEnvelope['ciphertext'],
          isNot(accountEnvelope['ciphertext']),
        );
        expect(codeEnvelope.keys.toSet(), {
          'version',
          'suite',
          'nonce',
          'ciphertext',
        });

        final codeCiphertext = decodeBase64Url(
          codeEnvelope['ciphertext']! as String,
        );
        final truncatedCodeCiphertext = Uint8List.fromList(
          codeCiphertext.sublist(0, codeCiphertext.length - 1),
        );
        codeCiphertext.fillRange(0, codeCiphertext.length, 0);
        final truncatedCodeEnvelope = Map<String, dynamic>.from(codeEnvelope)
          ..['ciphertext'] = encodeBase64Url(truncatedCodeCiphertext);
        truncatedCodeCiphertext.fillRange(0, truncatedCodeCiphertext.length, 0);
        await expectLater(
          recoveryCrypto.openIdentityWithRecoveryCode(
            envelope: truncatedCodeEnvelope,
            recoveryCode: recoveryCode,
            accountId: accountId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
            generation: 1,
          ),
          throwsA(anything),
        );

        fromCode = await recoveryCrypto.openIdentityWithRecoveryCode(
          envelope: Map<String, dynamic>.from(codeEnvelope),
          recoveryCode: recoveryCode,
          accountId: accountId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          generation: 1,
        );
        fromAccountKey = await recoveryCrypto.openIdentityWithAccountKey(
          envelope: Map<String, dynamic>.from(accountEnvelope),
          accountKey: accountKey,
          accountId: accountId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          generation: 1,
        );
        expect(fromCode.signingPublicKey, identity.signingPublicKey);
        expect(fromCode.encryptionPublicKey, identity.encryptionPublicKey);
        expect(fromAccountKey.signingPublicKey, identity.signingPublicKey);
        expect(
          fromAccountKey.encryptionPublicKey,
          identity.encryptionPublicKey,
        );
        await expectLater(
          recoveryCrypto.openIdentityWithRecoveryCode(
            envelope: Map<String, dynamic>.from(codeEnvelope),
            recoveryCode: recoveryCrypto.createRecoveryCode(),
            accountId: accountId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
            generation: 1,
          ),
          throwsA(anything),
        );
      } finally {
        fromCode?.dispose();
        fromAccountKey?.dispose();
        identity.dispose();
        accountKey.fillRange(0, accountKey.length, 0);
      }
    },
  );

  test(
    'recovery keybox is context-bound and signed by the Recovery identity',
    () async {
      const accountId = '11111111-1111-4111-8111-111111111111';
      const instanceId = '22222222-2222-4222-8222-222222222222';
      const serverSpaceId = '33333333-3333-4333-8333-333333333333';
      const vaultId = '44444444-4444-4444-8444-444444444444';
      const deviceId = '55555555-5555-4555-8555-555555555555';
      final identity = recoveryCrypto.createIdentity(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: 4,
      );
      final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
      try {
        final box = await recoveryCrypto.buildKeyEnvelope(
          identity: identity,
          uploaderDeviceId: deviceId,
          vaultId: vaultId,
          keyEpoch: 3,
          vaultKey: key,
        );
        expect(box['vault_id'], vaultId);
        expect(box['key_epoch'], 3);
        expect(box['uploader_device_id'], deviceId);
        expect(box['envelope_sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        final opened = await recoveryCrypto.openKeyEnvelope(
          identity: identity,
          vaultId: vaultId,
          keyEpoch: 3,
          envelope: Map<String, dynamic>.from(box['envelope']! as Map),
          uploaderDeviceId: deviceId,
          recoverySignature: box['recovery_signature']! as String,
          expectedEnvelopeSha256: box['envelope_sha256']! as String,
        );
        expect(opened, key);
        opened.fillRange(0, opened.length, 0);
        await expectLater(
          recoveryCrypto.openKeyEnvelope(
            identity: identity,
            vaultId: vaultId,
            keyEpoch: 3,
            envelope: Map<String, dynamic>.from(box['envelope']! as Map),
            uploaderDeviceId: 'substituted-device',
            recoverySignature: box['recovery_signature']! as String,
            expectedEnvelopeSha256: box['envelope_sha256']! as String,
          ),
          throwsA(anything),
        );
        await expectLater(
          recoveryCrypto.openKeyEnvelope(
            identity: identity,
            vaultId: vaultId,
            keyEpoch: 4,
            envelope: Map<String, dynamic>.from(box['envelope']! as Map),
            uploaderDeviceId: deviceId,
            recoverySignature: box['recovery_signature']! as String,
            expectedEnvelopeSha256: box['envelope_sha256']! as String,
          ),
          throwsA(anything),
        );
      } finally {
        identity.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );
}
