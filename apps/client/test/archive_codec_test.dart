import 'dart:typed_data';

import 'package:aterm_client/archive/archive_codec.dart';
import 'package:aterm_client/archive/portable_vault_archive.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'archive authenticates each chunk and enforces password minimum',
    () async {
      final codec = VaultArchiveCodec(sodium);
      final object = Uint8List.fromList(
        List.generate(
          VaultArchiveCodec.chunkSize * 2 + 173,
          (index) => index % 251,
        ),
      );
      final payload = VaultArchiveCodec.packPayload(
        manifest: const {'format': 'test-v1'},
        objectBytes: [object],
      );
      final password = 'independent archive secret';
      final container = await codec.seal(
        password: password,
        payload: payload,
        serverSpaceId: _spaceId,
        vaultId: _vaultId,
      );
      try {
        final opened = await codec.open(
          password: password,
          container: container,
          expectedServerSpaceId: _spaceId,
          expectedVaultId: _vaultId,
        );
        expect(opened, payload);
        opened.fillRange(0, opened.length, 0);

        await expectLater(
          codec.open(
            password: 'tiny',
            container: container,
            expectedServerSpaceId: _spaceId,
            expectedVaultId: _vaultId,
          ),
          throwsFormatException,
        );
        await expectLater(
          codec.open(
            password: 'a different sufficiently long password',
            container: container,
            expectedServerSpaceId: _spaceId,
            expectedVaultId: _vaultId,
          ),
          throwsFormatException,
        );

        final tampered = Uint8List.fromList(container);
        final headerLength = ByteData.sublistView(tampered, 8, 12).getUint32(0);
        final firstCipherByte = 12 + headerLength + 4 + 24;
        tampered[firstCipherByte + 23] ^= 0x40;
        await expectLater(
          codec.open(
            password: password,
            container: tampered,
            expectedServerSpaceId: _spaceId,
            expectedVaultId: _vaultId,
          ),
          throwsFormatException,
        );
        tampered.fillRange(0, tampered.length, 0);

        final tamperedSecondChunk = Uint8List.fromList(container);
        final secondChunkPrefix =
            12 + headerLength + 4 + 24 + VaultArchiveCodec.chunkSize + 16;
        final secondCipherByte = secondChunkPrefix + 4 + 24 + 23;
        tamperedSecondChunk[secondCipherByte] ^= 0x20;
        await expectLater(
          codec.open(
            password: password,
            container: tamperedSecondChunk,
            expectedServerSpaceId: _spaceId,
            expectedVaultId: _vaultId,
          ),
          throwsFormatException,
        );
        tamperedSecondChunk.fillRange(0, tamperedSecondChunk.length, 0);
      } finally {
        payload.fillRange(0, payload.length, 0);
        object.fillRange(0, object.length, 0);
        container.fillRange(0, container.length, 0);
      }
    },
  );

  test(
    'imported historical epoch key is merged in memory and decrypts history',
    () async {
      final crypto = VaultCrypto(sodium);
      final identity = DeviceIdentity.create(sodium);
      const recordId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      final historicalKey = sodium.randombytes.buf(32);
      final activeKey = sodium.randombytes.buf(32);
      final current = <String, Uint8List>{'2:2': activeKey};
      final imported = <String, Uint8List>{'1:1': historicalKey};
      try {
        mergeArchiveEpochKeys(current: current, imported: imported);
        expect(current.keys, containsAll(['1:1', '2:2']));
        expect(current['1:1'], orderedEquals(historicalKey));

        final envelope = await crypto.encryptRecord(
          vaultKey: historicalKey,
          serverSpaceId: _spaceId,
          vaultId: _vaultId,
          recordId: recordId,
          baseRevisionId: null,
          deviceId: identity.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: const {
            'id': recordId,
            'type': 'host',
            'name': 'historical record',
          },
          identity: identity,
        );
        final clear = await crypto.decryptRecord(
          vaultKey: current['1:1']!,
          envelope: Map<String, dynamic>.from(envelope),
          authorPublicKey: identity.signing.publicKey,
        );
        expect(clear['name'], 'historical record');
      } finally {
        identity.dispose();
        historicalKey.fillRange(0, historicalKey.length, 0);
        activeKey.fillRange(0, activeKey.length, 0);
        for (final key in current.values) {
          key.fillRange(0, key.length, 0);
        }
        imported.clear();
      }
    },
  );

  test('same epoch key cannot be silently replaced during merge', () {
    final current = {
      '1:1': Uint8List.fromList([1, 2, 3]),
    };
    final imported = {
      '1:1': Uint8List.fromList([1, 2, 4]),
    };
    expect(
      () => mergeArchiveEpochKeys(current: current, imported: imported),
      throwsFormatException,
    );
    expect(current['1:1'], [1, 2, 3]);
  });
}
