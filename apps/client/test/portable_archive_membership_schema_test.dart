import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/archive/archive_codec.dart';
import 'package:aterm_client/archive/portable_vault_archive.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _instanceId = '11111111-1111-4111-8111-111111111111';
const _accountId = '22222222-2222-4222-8222-222222222222';
const _spaceId = '33333333-3333-4333-8333-333333333333';
const _vaultId = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'signed API membership wrapper passes archive shape and signature-chain verification',
    () async {
      final device = DeviceIdentity.create(sodium);
      final fixture = await _fixture(sodium: sodium, device: device);
      final api = _trustApi(fixture);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        final error = await _stageExpectingMissingKeyEnvelope(
          sodium: sodium,
          device: device,
          fixture: fixture,
          api: api,
          database: database,
        );
        // The complete wrapper signature chain has been validated. Staging
        // proceeds to the intentionally empty key-envelope section next.
        expect(error.message, "The archive must be bound to one exporting device's key envelope set.");
        expect(api.readCount, 2);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        device.dispose();
        fixture.container.fillRange(0, fixture.container.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  test(
    'legacy archive inner-body membership remains accepted and signature-verified',
    () async {
      final device = DeviceIdentity.create(sodium);
      final fixture = await _fixture(
        sodium: sodium,
        device: device,
        legacyInnerBody: true,
      );
      final api = _trustApi(fixture);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        final error = await _stageExpectingMissingKeyEnvelope(
          sodium: sodium,
          device: device,
          fixture: fixture,
          api: api,
          database: database,
        );
        expect(error.message, "The archive must be bound to one exporting device's key envelope set.");
        expect(api.readCount, 2);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        device.dispose();
        fixture.container.fillRange(0, fixture.container.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  test(
    'archive accepts a signed v1 display-name envelope in the membership body',
    () async {
      final device = DeviceIdentity.create(sodium);
      final fixture = await _fixture(
        sodium: sodium,
        device: device,
        includeDisplayNameEnvelope: true,
      );
      final api = _trustApi(fixture);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        final error = await _stageExpectingMissingKeyEnvelope(
          sodium: sodium,
          device: device,
          fixture: fixture,
          api: api,
          database: database,
        );
        expect(error.message, "The archive must be bound to one exporting device's key envelope set.");
        expect(api.readCount, 2);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        device.dispose();
        fixture.container.fillRange(0, fixture.container.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  test(
    'archive rejects a malformed signed display-name envelope shape',
    () async {
      final device = DeviceIdentity.create(sodium);
      final fixture = await _fixture(
        sodium: sodium,
        device: device,
        malformedDisplayNameEnvelope: true,
      );
      final api = _trustApi(fixture);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        final error = await _stageExpectingMissingKeyEnvelope(
          sodium: sodium,
          device: device,
          fixture: fixture,
          api: api,
          database: database,
        );
        expect(
          error.message,
          'membership display_name_envelope shape is invalid.',
        );
        expect(api.readCount, 0);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        device.dispose();
        fixture.container.fillRange(0, fixture.container.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  for (final mismatch in const [
    'vault_id',
    'membership_version',
    'previous_digest',
    'signature',
  ]) {
    test(
      'archive rejects membership wrapper $mismatch mismatch before reads or writes',
      () async {
        final device = DeviceIdentity.create(sodium);
        final fixture = await _fixture(
          sodium: sodium,
          device: device,
          changedWrapperField: mismatch,
        );
        final api = _trustApi(fixture);
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        try {
          final error = await _stageExpectingMissingKeyEnvelope(
            sodium: sodium,
            device: device,
            fixture: fixture,
            api: api,
            database: database,
          );
          expect(
            error.message,
            contains('signed membership wrapper context differs'),
          );
          expect(api.readCount, 0);
          expect(await database.checkpoint(_vaultId), isNull);
        } finally {
          device.dispose();
          fixture.container.fillRange(0, fixture.container.length, 0);
          api.close();
          await database.close();
        }
      },
    );
  }
}

Future<FormatException> _stageExpectingMissingKeyEnvelope({
  required SodiumSumo sodium,
  required DeviceIdentity device,
  required _ArchiveFixture fixture,
  required _CountingApi api,
  required ClientDatabase database,
}) async {
  try {
    final stage =
        await PortableVaultArchiveService(
          sodium: sodium,
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
        ).stageImport(
          container: fixture.container,
          exportPassword: 'a long archive password',
          target: VaultArchiveContext(
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            accountId: _accountId,
            device: device,
            vault: VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              // _validateContext requires an unlocked descriptor. Staging fails
              // earlier than envelope decryption by design in this fixture.
              keyEnvelopes: const [{}],
            ),
            epochKeysByVersion: const {},
          ),
        );
    stage.dispose();
    throw TestFailure('Expected archive without a key envelope to fail.');
  } on FormatException catch (error) {
    return error;
  }
}

Future<_ArchiveFixture> _fixture({
  required SodiumSumo sodium,
  required DeviceIdentity device,
  bool legacyInnerBody = false,
  bool includeDisplayNameEnvelope = false,
  bool malformedDisplayNameEnvelope = false,
  String? changedWrapperField,
}) async {
  final crypto = VaultCrypto(sodium);
  final encryptionFingerprint = encodeBase64Url(
    (await cryptography.Sha256().hash(device.encryption.publicKey)).bytes,
  );
  final body = <String, Object?>{
    'key_epoch': 1,
    if (includeDisplayNameEnvelope || malformedDisplayNameEnvelope)
      'display_name_envelope': {
        'version': malformedDisplayNameEnvelope ? 2 : 1,
        'nonce': encodeBase64Url(Uint8List(24)),
        'ciphertext': encodeBase64Url(Uint8List(17)),
      },
    'members': [
      {
        'user_id': _accountId,
        'role': 'owner',
        'state': 'active',
        'encryption_key_fingerprint': encryptionFingerprint,
      },
    ],
    'signer_device_id': device.deviceId,
  };
  final grant = crypto.createMembershipGrant(
    vaultId: _vaultId,
    membershipVersion: 1,
    previousDigest: null,
    manifest: body,
    signer: device,
  );
  final signature = grant['signature']! as String;
  final signedContext = <String, Object?>{
    'vault_id': _vaultId,
    'membership_version': 1,
    'previous_digest': null,
    'manifest': body,
  };
  final digestBytes = await cryptography.Sha256().hash(
    utf8.encode(canonicalJson(signedContext)),
  );
  final digest = digestBytes.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final canonicalWrapper = <String, Object?>{
    ...signedContext,
    'signature': signature,
  };
  final archivedWrapper = Map<String, Object?>.from(canonicalWrapper);
  switch (changedWrapperField) {
    case 'vault_id':
      archivedWrapper['vault_id'] = '55555555-5555-4555-8555-555555555555';
    case 'membership_version':
      archivedWrapper['membership_version'] = 2;
    case 'previous_digest':
      archivedWrapper['previous_digest'] = 'a' * 64;
    case 'signature':
      archivedWrapper['signature'] = '${signature}x';
  }
  final currentRow = <String, Object?>{
    'membership_version': 1,
    'previous_digest': null,
    'manifest': canonicalWrapper,
    'digest': digest,
    'signer_device_id': device.deviceId,
    'signature': signature,
    'created_at': '2026-09-27T00:00:00Z',
  };
  final archivedRow = <String, Object?>{
    ...currentRow,
    'manifest': legacyInnerBody ? body : archivedWrapper,
  };
  final deviceRow = <String, Object?>{
    'device_id': device.deviceId,
    'user_id': _accountId,
    'name': 'Archive test device',
    'signing_public_key': device.signingPublicKey,
    'encryption_public_key': device.encryptionPublicKey,
    'status': 'active',
    'created_at': '2026-09-27T00:00:00Z',
  };
  final manifest = <String, Object?>{
    'format': 'atermius-portable-vault-data',
    'version': 1,
    'created_at': '2026-09-27T00:00:00Z',
    'instance_id': _instanceId,
    'server_space_id': _spaceId,
    'account_id': _accountId,
    'vault_id': _vaultId,
    'vault_role': 'owner',
    'name_envelope': null,
    'snapshot': {
      'snapshot_id': '66666666-6666-4666-8666-666666666666',
      'high_watermark': '0',
      'conflict_high_watermark': '0',
      'next_cursor': 'archive-cursor',
      'server_generation': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    },
    'devices': [deviceRow],
    'membership_chain': [archivedRow],
    'key_envelopes': <Object?>[],
    'epoch_keys': <Object?>[],
    'snapshot_heads': <Object?>[],
    'graveyard': <Object?>[],
    'revisions': <Object?>[],
    'conflicts': <Object?>[],
    'local_pending': {
      'operations': <Object?>[],
      'conflict_branches': <Object?>[],
      'device_sequence_floors': <String, int>{},
    },
    'binary_blocks': <Object?>[],
  };
  final payload = VaultArchiveCodec.packPayload(
    manifest: manifest,
    objectBytes: const [],
  );
  try {
    final container = await VaultArchiveCodec(sodium).seal(
      password: 'a long archive password',
      payload: payload,
      serverSpaceId: _spaceId,
      vaultId: _vaultId,
    );
    return _ArchiveFixture(
      container: container,
      currentRow: currentRow,
      deviceRow: deviceRow,
    );
  } finally {
    payload.fillRange(0, payload.length, 0);
  }
}

_CountingApi _trustApi(_ArchiveFixture fixture) => _CountingApi(
  client: MockClient((request) async {
    if (request.url.path.endsWith('/devices')) {
      return _json({
        'devices': [fixture.deviceRow],
      });
    }
    if (request.url.path.endsWith('/membership')) {
      return _json({
        'manifests': [fixture.currentRow],
      });
    }
    fail('Unexpected archive import request ${request.method} ${request.url}');
  }),
);

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _ArchiveFixture {
  const _ArchiveFixture({
    required this.container,
    required this.currentRow,
    required this.deviceRow,
  });

  final Uint8List container;
  final Map<String, Object?> currentRow;
  final Map<String, Object?> deviceRow;
}

class _CountingApi extends ApiClient {
  _CountingApi({required super.client})
    : super(baseUrl: 'https://archive.test');

  int readCount = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) async {
    readCount++;
    return super.get(path, query: query, authenticated: authenticated);
  }
}
