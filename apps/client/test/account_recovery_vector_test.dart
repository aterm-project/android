import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/crypto/account_recovery_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'opens the shared Rust/Python/Dart account-recovery v1 vector',
    () async {
      final fixture =
          jsonDecode(
                File(
                  '../../protocol/test-vectors/account-recovery-v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final sodium = await SodiumSumoInit.init();
      final recoveryCrypto = AccountRecoveryCrypto(sodium);
      final accountId = fixture['account_id'] as String;
      final instanceId = fixture['instance_id'] as String;
      final serverSpaceId = fixture['server_space_id'] as String;
      final generation = fixture['recovery_generation'] as int;
      final recoveryCode = fixture['recovery_code_base64url'] as String;
      final accountKey = decodeBase64Url(
        fixture['account_key_base64url'] as String,
      );
      RecoveryIdentity? fromCode;
      RecoveryIdentity? fromAccountKey;
      Uint8List? codeSeed;
      Uint8List? accountSeed;
      Uint8List? identityProof;
      Uint8List? openedVaultKey;
      try {
        fromCode = await recoveryCrypto.openIdentityWithRecoveryCode(
          envelope: Map<String, dynamic>.from(
            fixture['recovery_envelope'] as Map,
          ),
          recoveryCode: recoveryCode,
          accountId: accountId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          generation: generation,
        );
        fromAccountKey = await recoveryCrypto.openIdentityWithAccountKey(
          envelope: Map<String, dynamic>.from(
            fixture['account_key_envelope'] as Map,
          ),
          accountKey: accountKey,
          accountId: accountId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          generation: generation,
        );

        expect(
          fromCode.signingPublicKey,
          fixture['signing_public_key_base64url'],
        );
        expect(
          fromCode.encryptionPublicKey,
          fixture['encryption_public_key_base64url'],
        );
        expect(fromAccountKey.signingPublicKey, fromCode.signingPublicKey);
        expect(
          fromAccountKey.encryptionPublicKey,
          fromCode.encryptionPublicKey,
        );
        expect(
          await recoveryCrypto.recoveryDescriptorHash(
            accountId: accountId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
            generation: generation,
            signingPublicKey: fromCode.signingPublicKey,
            encryptionPublicKey: fromCode.encryptionPublicKey,
          ),
          fixture['descriptor_sha256'],
        );

        codeSeed = fromCode.signingSeed.extractBytes();
        accountSeed = fromAccountKey.encryptionSeed.extractBytes();
        expect(encodeBase64Url(codeSeed), fixture['signing_seed_base64url']);
        expect(
          encodeBase64Url(accountSeed),
          fixture['encryption_seed_base64url'],
        );

        final identityProofPayload = Map<String, Object?>.from(
          jsonDecode(
                fixture['recovery_identity_proof_payload_jcs_utf8'] as String,
              )
              as Map,
        );
        identityProof = decodeBase64Url(
          fixture['recovery_identity_proof_signature_base64url'] as String,
        );
        expect(
          recoveryCrypto.verifyDetached(
            signature: identityProof,
            publicKey: fromCode.signing.publicKey,
            payload: identityProofPayload,
          ),
          isTrue,
        );

        openedVaultKey = await recoveryCrypto.openKeyEnvelope(
          identity: fromCode,
          vaultId: fixture['vault_id'] as String,
          keyEpoch: fixture['key_epoch'] as int,
          envelope: Map<String, dynamic>.from(
            fixture['keybox_envelope'] as Map,
          ),
          uploaderDeviceId: fixture['uploader_device_id'] as String,
          recoverySignature:
              fixture['keybox_recovery_signature_base64url'] as String,
          expectedEnvelopeSha256: fixture['keybox_ciphertext_sha256'] as String,
        );
        expect(encodeBase64Url(openedVaultKey), fixture['vault_key_base64url']);
      } finally {
        accountKey.fillRange(0, accountKey.length, 0);
        codeSeed?.fillRange(0, codeSeed.length, 0);
        accountSeed?.fillRange(0, accountSeed.length, 0);
        identityProof?.fillRange(0, identityProof.length, 0);
        openedVaultKey?.fillRange(0, openedVaultKey.length, 0);
        fromCode?.dispose();
        fromAccountKey?.dispose();
      }
    },
  );
}
