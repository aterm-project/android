import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'fixtures/legacy_known_host_v1_client.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _revokedRecordId = '33333333-3333-4333-8333-333333333333';
const _revokedRevisionId = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'legacy v1 client decrypts and accepts the v1 KnownHost payload',
    () async {
      final author = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      final legacy = LegacyKnownHostV1Client();
      final record = KnownHostRecord.approve(
        host: 'ssh.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: author.deviceId,
        approvedAt: DateTime.utc(2026, 10, 3),
      );

      try {
        final plaintext = await _encryptThenDecrypt(
          crypto: crypto,
          author: author,
          vaultKey: key,
          record: record,
        );

        expect(legacy.decode(plaintext)['id'], record.id);
        expect(legacy.decode(plaintext)['state'], 'trusted');
      } finally {
        author.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'legacy v1 client fails closed on an actual signed and encrypted v2 reapproval',
    () async {
      final author = DeviceIdentity.create(sodium);
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      final legacy = LegacyKnownHostV1Client();
      final record = KnownHostRecord.approve(
        host: 'ssh.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: author.deviceId,
        approvedAt: DateTime.utc(2026, 10, 3),
        observedRevocations: const [
          KnownHostRevocationReference(
            recordId: _revokedRecordId,
            revisionId: _revokedRevisionId,
          ),
        ],
      );

      try {
        final plaintext = await _encryptThenDecrypt(
          crypto: crypto,
          author: author,
          vaultKey: key,
          record: record,
        );

        expect(record.schemaVersion, 2);
        expect(plaintext['observed_revocations'], [
          {'record_id': _revokedRecordId, 'revision_id': _revokedRevisionId},
        ]);
        expect(
          () => legacy.decode(plaintext),
          throwsA(isA<FormatException>()),
          reason:
              'a v1 reader must reject the v2 approval instead of silently '
              'dropping the exact revocation heads it has to acknowledge',
        );

        // The current reader accepts the exact same authenticated plaintext;
        // no fallback or lossy v1 rewrite is performed for old clients.
        final current = KnownHostRecord.fromJson(plaintext);
        expect(current.observedRevocations.single.recordId, _revokedRecordId);
        expect(
          current.observedRevocations.single.revisionId,
          _revokedRevisionId,
        );
      } finally {
        author.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );
}

Future<Map<String, dynamic>> _encryptThenDecrypt({
  required VaultCrypto crypto,
  required DeviceIdentity author,
  required Uint8List vaultKey,
  required KnownHostRecord record,
}) async {
  final envelope = await crypto.encryptRecord(
    vaultKey: vaultKey,
    serverSpaceId: _serverSpaceId,
    vaultId: _vaultId,
    recordId: record.id,
    baseRevisionId: null,
    deviceId: author.deviceId,
    deviceSequence: '1',
    keyEpoch: '1',
    membershipVersion: '1',
    operation: 'create',
    plaintext: record.toJson(),
    identity: author,
  );
  return crypto.decryptRecord(
    vaultKey: vaultKey,
    envelope: envelope,
    authorPublicKey: Uint8List.fromList(author.signing.publicKey),
  );
}
