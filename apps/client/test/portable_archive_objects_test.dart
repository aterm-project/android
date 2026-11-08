import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/archive/portable_vault_archive.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _spaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _instanceId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _snapshotId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _objectId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'apply uploads a missing encrypted object and persists its verified bytes',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final objectBytes = Uint8List.fromList(
        List.generate(257, (i) => i % 256),
      );
      final digest = _hex(
        (await cryptography.Sha256().hash(objectBytes)).bytes,
      );
      var exists = false;
      var initCalls = 0;
      var chunkCalls = 0;
      var completeCalls = 0;
      var downloadedBody = <int>[];
      final api = ApiClient(
        baseUrl: 'https://archive-object.test',
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/$_objectId')) {
            if (!exists) return _apiError(404, 'NOT_FOUND');
            downloadedBody = List<int>.from(objectBytes);
            return http.Response.bytes(
              objectBytes,
              200,
              headers: {'etag': '"sha256-$digest"'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/uploads/init')) {
            initCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body, {
              'object_id': _objectId,
              'size': objectBytes.length,
              'sha256': digest,
            });
            return _json({'upload_id': 'upload-1', 'chunk_size': 1024 * 1024});
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/chunks/0')) {
            chunkCalls++;
            expect(request.bodyBytes, objectBytes);
            expect(request.headers['x-content-sha256'], digest);
            return _json({'uploaded': true});
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/uploads/upload-1/complete')) {
            completeCalls++;
            exists = true;
            return _json({'object_id': _objectId, 'sha256': digest});
          }
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );
      final stage = _stage(
        ArchiveObjectBytes(
          objectId: _objectId,
          bytes: objectBytes,
          sha256: digest,
        ),
      );
      try {
        await PortableVaultArchiveService(
          sodium: sodium,
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
        ).applyStage(stage, instanceId: _instanceId);

        expect(initCalls, 1);
        expect(chunkCalls, 1);
        expect(completeCalls, 1);
        expect(downloadedBody, objectBytes);
        final persisted = await database.archiveObject(_vaultId, _objectId);
        expect(persisted?.sha256, digest);
        expect(persisted?.bytes, objectBytes);
      } finally {
        stage.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test(
    'bad staged object digest fails before network or database mutation',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var requestCount = 0;
      final api = ApiClient(
        baseUrl: 'https://archive-object.test',
        client: MockClient((request) async {
          requestCount++;
          return _apiError(404, 'NOT_FOUND');
        }),
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final stage = _stage(
        ArchiveObjectBytes(objectId: _objectId, bytes: bytes, sha256: '0' * 64),
      );
      try {
        await expectLater(
          PortableVaultArchiveService(
            sodium: sodium,
            api: api,
            database: database,
            crypto: VaultCrypto(sodium),
          ).applyStage(stage, instanceId: _instanceId),
          throwsFormatException,
        );
        expect(requestCount, 0);
        expect(await database.archiveObject(_vaultId, _objectId), isNull);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        stage.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test(
    'an exact object created after GET wins the upload race safely',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final objectBytes = Uint8List.fromList([9, 8, 7, 6]);
      final digest = _hex(
        (await cryptography.Sha256().hash(objectBytes)).bytes,
      );
      var exists = false;
      var initCalls = 0;
      final api = ApiClient(
        baseUrl: 'https://archive-race.test',
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/$_objectId')) {
            if (!exists) return _apiError(404, 'NOT_FOUND');
            return http.Response.bytes(
              objectBytes,
              200,
              headers: {'etag': '"sha256-$digest"'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/uploads/init')) {
            initCalls++;
            exists = true;
            return _apiError(409, 'OBJECT_EXISTS');
          }
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );
      final stage = _stage(
        ArchiveObjectBytes(
          objectId: _objectId,
          bytes: objectBytes,
          sha256: digest,
        ),
      );
      try {
        await PortableVaultArchiveService(
          sodium: sodium,
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
        ).applyStage(stage, instanceId: _instanceId);
        expect(initCalls, 1);
        expect(await database.archiveObject(_vaultId, _objectId), isNotNull);
      } finally {
        stage.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test(
    'a different immutable object created during import fails closed',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final objectBytes = Uint8List.fromList([9, 8, 7, 6]);
      final conflictingBytes = Uint8List.fromList([1, 2, 3, 4]);
      final digest = _hex(
        (await cryptography.Sha256().hash(objectBytes)).bytes,
      );
      final conflictingDigest = _hex(
        (await cryptography.Sha256().hash(conflictingBytes)).bytes,
      );
      var exists = false;
      final api = ApiClient(
        baseUrl: 'https://archive-race.test',
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/$_objectId')) {
            if (!exists) return _apiError(404, 'NOT_FOUND');
            return http.Response.bytes(
              conflictingBytes,
              200,
              headers: {'etag': '"sha256-$conflictingDigest"'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/uploads/init')) {
            exists = true;
            return _apiError(409, 'OBJECT_EXISTS');
          }
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );
      final stage = _stage(
        ArchiveObjectBytes(
          objectId: _objectId,
          bytes: objectBytes,
          sha256: digest,
        ),
      );
      try {
        await expectLater(
          PortableVaultArchiveService(
            sodium: sodium,
            api: api,
            database: database,
            crypto: VaultCrypto(sodium),
          ).applyStage(stage, instanceId: _instanceId),
          throwsStateError,
        );
        expect(await database.archiveObject(_vaultId, _objectId), isNull);
        expect(await database.checkpoint(_vaultId), isNull);
      } finally {
        stage.dispose();
        api.close();
        await database.close();
        conflictingBytes.fillRange(0, conflictingBytes.length, 0);
      }
    },
  );
}

StagedVaultArchive _stage(ArchiveObjectBytes object) => StagedVaultArchive(
  sourceInstanceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  serverSpaceId: _spaceId,
  vaultId: _vaultId,
  snapshotId: _snapshotId,
  highWatermark: '0',
  conflictHighWatermark: '0',
  cursor: 'fixed-cursor',
  serverGeneration: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  heads: const [],
  operations: const [],
  conflicts: const [],
  objects: [object],
  sequenceFloors: const {},
  epochKeysByVersion: {},
  recordCount: 0,
  conflictCount: 0,
);

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

http.Response _json(Map<String, Object?> value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _apiError(int status, String code) => http.Response(
  jsonEncode({
    'error': {'code': code, 'message': code, 'request_id': _snapshotId},
  }),
  status,
  headers: {'content-type': 'application/json'},
);
