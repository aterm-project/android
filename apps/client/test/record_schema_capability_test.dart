import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
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
    'record schema 2 is selected for v2 manifests and decrypts safely',
    () async {
      const vaultId = '11111111-1111-4111-8111-111111111111';
      const recordId = '22222222-2222-4222-8222-222222222222';
      const serverSpaceId = '33333333-3333-4333-8333-333333333333';
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = crypto.randomBytes(32);
      try {
        final legacy = await crypto.encryptRecord(
          vaultKey: vaultKey,
          serverSpaceId: serverSpaceId,
          vaultId: vaultId,
          recordId: recordId,
          baseRevisionId: null,
          deviceId: identity.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: {'id': recordId, 'type': 'host', '_manifest': {}},
          identity: identity,
        );
        expect((legacy['header'] as Map)['record_schema'], 1);

        final v2Plaintext = <String, Object?>{
          'id': recordId,
          'type': 'host',
          '_manifest': {
            'attachments': [
              {'format': 'atermius-host-attachment-v2'},
            ],
            'object_refs': <String>[],
          },
        };
        final v2 = await crypto.encryptRecord(
          vaultKey: vaultKey,
          serverSpaceId: serverSpaceId,
          vaultId: vaultId,
          recordId: recordId,
          baseRevisionId: null,
          deviceId: identity.deviceId,
          deviceSequence: '2',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: v2Plaintext,
          identity: identity,
        );
        expect((v2['header'] as Map)['record_schema'], 2);
        expect(
          await crypto.decryptRecord(
            vaultKey: vaultKey,
            envelope: Map<String, dynamic>.from(v2),
            authorPublicKey: identity.signing.publicKey,
          ),
          v2Plaintext,
        );

        final unknown = Map<String, dynamic>.from(v2);
        unknown['header'] = {
          ...Map<String, dynamic>.from(v2['header'] as Map),
          'record_schema': 3,
        };
        expect(
          () => crypto.validateRecordEnvelope(unknown),
          throwsFormatException,
        );
      } finally {
        identity.dispose();
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
    },
  );

  test('device capability reports require an exact signed payload', () {
    const accountId = '44444444-4444-4444-8444-444444444444';
    final identity = DeviceIdentity.create(sodium);
    try {
      final unsigned = <String, Object?>{
        'account_id': accountId,
        'device_id': identity.deviceId,
        'revision': 1,
        'max_record_schema': 2,
        'host_attachment_manifest_versions': [1, 2],
        'max_attachment_bytes': 1024 * 1024 * 1024,
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: identity.signing.secretKey,
      );
      final report = <String, dynamic>{
        ...unsigned,
        'signature': encodeBase64Url(signature),
      };
      final parsed = crypto.verifyDeviceCapabilityReport(
        report: report,
        expectedAccountId: accountId,
        expectedDeviceId: identity.deviceId,
        signingPublicKey: identity.signing.publicKey,
      );
      expect(parsed.maxRecordSchema, 2);
      expect(parsed.hostAttachmentManifestVersions, [1, 2]);
      expect(parsed.maxAttachmentBytes, 1024 * 1024 * 1024);

      expect(
        () => crypto.verifyDeviceCapabilityReport(
          report: {...report, 'max_attachment_bytes': 256 * 1024 * 1024},
          expectedAccountId: accountId,
          expectedDeviceId: identity.deviceId,
          signingPublicKey: identity.signing.publicKey,
        ),
        throwsFormatException,
      );
      expect(
        () => crypto.verifyDeviceCapabilityReport(
          report: {...report, 'unexpected': true},
          expectedAccountId: accountId,
          expectedDeviceId: identity.deviceId,
          signingPublicKey: identity.signing.publicKey,
        ),
        throwsFormatException,
      );
    } finally {
      identity.dispose();
    }
  });
}
