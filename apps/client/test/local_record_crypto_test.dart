import 'dart:convert';

import 'package:aterm_client/crypto/vault_crypto.dart';
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
    'local record envelope round-trips and stays outside server wire format',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      const vaultId = '33333333-3333-4333-8333-333333333333';
      const recordId = '44444444-4444-4444-8444-444444444444';
      final vaultKey = crypto.randomBytes(32);
      final identity = DeviceIdentity.create(sodium);
      const plaintext = <String, Object?>{
        'id': recordId,
        'name': 'local database host',
        'address': '192.0.2.15',
        'port': 22,
        'username': 'operator',
      };

      try {
        final envelope = await crypto.encryptLocalRecord(
          vaultKey: vaultKey,
          profileId: profileId,
          localDataDomainId: domainId,
          localVaultId: vaultId,
          recordId: recordId,
          baseRevisionId: null,
          operation: 'create',
          plaintext: plaintext,
          identity: identity,
        );
        expect(envelope['format'], 'atermius-local-record-v1');
        expect(envelope.keys.toSet(), {
          'format',
          'header',
          'nonce',
          'ciphertext',
          'signature',
        });
        final header = Map<String, dynamic>.from(envelope['header']! as Map);
        expect(header.keys.toSet(), {
          'format',
          'schema_version',
          'profile_id',
          'local_data_domain_id',
          'local_vault_id',
          'record_id',
          'revision_id',
          'base_revision_id',
          'operation',
          'crypto_suite',
          'kdf_salt',
        });
        expect(header['format'], 'atermius-local-record-v1');
        expect(header['schema_version'], 1);
        expect(header['profile_id'], profileId);
        expect(header['local_data_domain_id'], domainId);
        expect(header['local_vault_id'], vaultId);
        expect(header['record_id'], recordId);
        expect(header['base_revision_id'], isNull);
        expect(header['operation'], 'create');
        expect(
          header['crypto_suite'],
          'xchacha20-poly1305-ietf+hkdf-sha256+ed25519',
        );
        expect(decodeBase64Url(header['kdf_salt']! as String), hasLength(32));
        expect(decodeBase64Url(envelope['nonce']! as String), hasLength(24));
        expect(
          decodeBase64Url(envelope['signature']! as String),
          hasLength(64),
        );
        expect(
          header.keys.toSet().intersection({
            'server_space_id',
            'device_seq',
            'membership_version',
            'op_id',
          }),
          isEmpty,
        );
        expect(jsonEncode(envelope), isNot(contains('local database host')));

        final opened = await crypto.decryptLocalRecord(
          vaultKey: vaultKey,
          envelope: Map<String, dynamic>.from(envelope),
          expectedProfileId: profileId,
          expectedLocalDataDomainId: domainId,
          expectedLocalVaultId: vaultId,
          authorPublicKey: identity.signing.publicKey,
        );
        expect(opened, plaintext);
        expect(header['revision_id'], isA<String>());

        await expectLater(
          crypto.decryptRecord(
            vaultKey: vaultKey,
            envelope: Map<String, dynamic>.from(envelope),
            authorPublicKey: identity.signing.publicKey,
          ),
          throwsFormatException,
        );
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
        identity.signing.secretKey.dispose();
        identity.encryption.secretKey.dispose();
      }
    },
  );

  test(
    'local record rejects changed context, header, signature, and ciphertext',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      const vaultId = '33333333-3333-4333-8333-333333333333';
      const recordId = '44444444-4444-4444-8444-444444444444';
      final vaultKey = crypto.randomBytes(32);
      final identity = DeviceIdentity.create(sodium);
      try {
        final envelope = await crypto.encryptLocalRecord(
          vaultKey: vaultKey,
          profileId: profileId,
          localDataDomainId: domainId,
          localVaultId: vaultId,
          recordId: recordId,
          baseRevisionId: null,
          operation: 'create',
          plaintext: const {'id': recordId, 'name': 'original'},
          identity: identity,
        );

        Future<void> reject(
          Map<String, dynamic> candidate, {
          String expectedProfileId = profileId,
          String expectedDomainId = domainId,
          String expectedVaultId = vaultId,
        }) async {
          await expectLater(
            crypto.decryptLocalRecord(
              vaultKey: vaultKey,
              envelope: candidate,
              expectedProfileId: expectedProfileId,
              expectedLocalDataDomainId: expectedDomainId,
              expectedLocalVaultId: expectedVaultId,
              authorPublicKey: identity.signing.publicKey,
            ),
            throwsFormatException,
          );
        }

        await reject(
          Map<String, dynamic>.from(envelope),
          expectedProfileId: '55555555-5555-4555-8555-555555555555',
        );
        await reject(
          Map<String, dynamic>.from(envelope),
          expectedDomainId: '55555555-5555-4555-8555-555555555555',
        );
        await reject(
          Map<String, dynamic>.from(envelope),
          expectedVaultId: '55555555-5555-4555-8555-555555555555',
        );

        final changedHeader = _copyEnvelope(envelope);
        (changedHeader['header'] as Map<String, dynamic>)['record_id'] =
            '66666666-6666-4666-8666-666666666666';
        await reject(changedHeader);

        final changedSignature = _copyEnvelope(envelope);
        changedSignature['signature'] = _mutateBase64(
          changedSignature['signature']! as String,
        );
        await reject(changedSignature);

        final changedCiphertext = _copyEnvelope(envelope);
        changedCiphertext['ciphertext'] = _mutateBase64(
          changedCiphertext['ciphertext']! as String,
        );
        await reject(changedCiphertext);

        final extraServerField = _copyEnvelope(envelope);
        (extraServerField['header']
                as Map<String, dynamic>)['server_space_id'] =
            '77777777-7777-4777-8777-777777777777';
        await reject(extraServerField);

        final invalidRecordId = _copyEnvelope(envelope);
        (invalidRecordId['header'] as Map<String, dynamic>)['record_id'] =
            'not-a-uuid';
        await reject(invalidRecordId);

        final extraWireField = _copyEnvelope(envelope)..['op_id'] = 'server-op';
        await reject(extraWireField);

        final inexactSchemaVersion = _copyEnvelope(envelope);
        (inexactSchemaVersion['header']
                as Map<String, dynamic>)['schema_version'] =
            1.0;
        await reject(inexactSchemaVersion);

        final oversizedByShape = _copyEnvelope(envelope);
        oversizedByShape['nonce'] = 'A';
        await reject(oversizedByShape);
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
        identity.signing.secretKey.dispose();
        identity.encryption.secretKey.dispose();
      }
    },
  );

  test(
    'local record operations and revision relationships are validated',
    () async {
      const profileId = '11111111-1111-4111-8111-111111111111';
      const domainId = '22222222-2222-4222-8222-222222222222';
      const vaultId = '33333333-3333-4333-8333-333333333333';
      const recordId = '44444444-4444-4444-8444-444444444444';
      final vaultKey = crypto.randomBytes(32);
      final identity = DeviceIdentity.create(sodium);
      try {
        for (final (operation, baseRevisionId) in <(String, String?)>[
          ('create', recordId),
          ('update', null),
          ('delete', 'not-a-uuid'),
          ('restore', null),
        ]) {
          await expectLater(
            crypto.encryptLocalRecord(
              vaultKey: vaultKey,
              profileId: profileId,
              localDataDomainId: domainId,
              localVaultId: vaultId,
              recordId: recordId,
              baseRevisionId: baseRevisionId,
              operation: operation,
              plaintext: const {'id': recordId},
              identity: identity,
            ),
            throwsFormatException,
          );
        }
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
        identity.signing.secretKey.dispose();
        identity.encryption.secretKey.dispose();
      }
    },
  );
}

Map<String, dynamic> _copyEnvelope(Map<String, Object?> envelope) => {
  ...envelope,
  'header': Map<String, dynamic>.from(envelope['header']! as Map),
};

String _mutateBase64(String encoded) {
  final bytes = decodeBase64Url(encoded);
  bytes[bytes.length - 1] ^= 1;
  return encodeBase64Url(bytes);
}
