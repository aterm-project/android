import 'dart:convert';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late VaultCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
  });

  test(
    'Host forwarding profiles sync inside the encrypted Host envelope',
    () async {
      final author = DeviceIdentity.create(sodium);
      final vaultKey = crypto.randomBytes(32);
      const profiles = [
        SshPortForwardProfile(
          id: 'local-forward',
          name: 'Private database',
          type: SshPortForwardType.local,
          bindAddress: '127.0.0.1',
          bindPort: 15432,
          destinationAddress: 'db.internal',
          destinationPort: 5432,
        ),
        SshPortForwardProfile(
          id: 'dynamic-forward',
          name: 'SOCKS proxy',
          type: SshPortForwardType.dynamic,
          bindAddress: 'localhost',
          bindPort: 0,
        ),
      ];
      final host = HostRecord(
        id: '33333333-3333-4333-8333-333333333333',
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
        portForwardProfiles: profiles,
      );
      expect(host.validate(), isNull);

      try {
        final envelope = await crypto.encryptRecord(
          vaultKey: vaultKey,
          serverSpaceId: '11111111-1111-4111-8111-111111111111',
          vaultId: '22222222-2222-4222-8222-222222222222',
          recordId: host.id,
          baseRevisionId: null,
          deviceId: author.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: host.toJson(),
          identity: author,
        );
        final encodedEnvelope = jsonEncode(envelope);
        expect(encodedEnvelope, isNot(contains('db.internal')));
        expect(encodedEnvelope, isNot(contains('Private database')));
        expect(encodedEnvelope, isNot(contains('15432')));

        final opened = await crypto.decryptRecord(
          vaultKey: vaultKey,
          envelope: Map<String, dynamic>.from(envelope),
          authorPublicKey: author.signing.publicKey,
        );
        final syncedHost = HostRecord.fromJson(opened);
        expect(
          syncedHost.portForwardProfiles.map((profile) => profile.toJson()),
          profiles.map((profile) => profile.toJson()),
        );
      } finally {
        author.dispose();
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
    },
  );
}
