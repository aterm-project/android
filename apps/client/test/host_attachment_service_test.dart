import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/attachments/attachment_upload_source.dart';
import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:aterm_client/attachments/host_attachment_service.dart';
import 'package:aterm_client/crypto/host_attachment_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:drift/native.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _hostId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _legacyObjectId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('commits encrypted refs before upload and round-trips safely', () async {
    final server = _ObjectServer();
    final api = _api(server);
    final database = _database();
    final service = _service(api, sodium, database);
    final plaintext = Uint8List.fromList(
      utf8.encode('local-only attachment payload with recognizable content'),
    );
    final original = _host(
      manifest: {
        'extension_version': 1,
        'object_refs': [_legacyObjectId],
      },
    );
    HostRecord? committed;
    try {
      final updated = await service.add(
        vaultId: _vaultId,
        host: original,
        fileName: 'deploy-notes.txt',
        mediaType: 'text/plain',
        plaintext: plaintext,
        commit: (candidate) async {
          expect(server.objects, isEmpty);
          final candidateManifest = candidate.manifest!;
          final attachments = candidateManifest['attachments']! as List;
          final entry = Map<String, Object?>.from(attachments.single as Map);
          final chunks = entry['chunks']! as List;
          final expectedRefs = <String>[
            _legacyObjectId,
            ...chunks.map((chunk) => (chunk as Map)['object_id'] as String),
          ]..sort();
          expect(candidateManifest['object_refs'], expectedRefs);
          committed = candidate;
        },
      );
      expect(server.objects.length, 1);
      expect(committed, same(updated));
      expect(original.manifest!['object_refs'], [_legacyObjectId]);
      expect(original.manifest!.containsKey('attachments'), isFalse);

      final entry = Map<String, Object?>.from(
        (updated.manifest!['attachments']! as List).single as Map,
      );
      expect(entry['file_name'], 'deploy-notes.txt');
      expect(entry['media_type'], 'text/plain');
      expect(entry['plaintext_sha256'], await _sha256(plaintext));
      expect(entry['blob_key'], isA<String>());

      final initRequests = server.requests
          .where(
            (request) =>
                request.method == 'POST' &&
                request.url.path.endsWith('/uploads/init'),
          )
          .toList();
      expect(initRequests, hasLength(1));
      final initBody =
          jsonDecode(initRequests.single.body) as Map<String, dynamic>;
      expect(initBody.keys.toSet(), {'object_id', 'size', 'sha256'});
      final uploadedObject = server.objects.values.single;
      expect(_containsSequence(uploadedObject, plaintext), isFalse);
      final ciphertextHash = initBody['sha256'] as String;
      expect(ciphertextHash, await _sha256(uploadedObject));
      expect(ciphertextHash, isNot(await _sha256(plaintext)));
      final putRequests = server.requests.where(
        (request) => request.method == 'PUT',
      );
      expect(putRequests, isNotEmpty);
      for (final request in putRequests) {
        expect(
          request.headers['x-content-sha256'],
          await _sha256(request.bodyBytes),
        );
        expect(_containsSequence(request.bodyBytes, plaintext), isFalse);
      }
      for (final request in server.requests) {
        expect(request.url.toString(), isNot(contains('deploy-notes.txt')));
        expect(request.url.toString(), isNot(contains('text/plain')));
        if (request.method != 'PUT') {
          expect(request.body, isNot(contains(entry['blob_key'] as String)));
          expect(request.body, isNot(contains('deploy-notes.txt')));
          expect(request.body, isNot(contains('text/plain')));
        }
      }

      final summaries = service.list(updated);
      expect(summaries.single.fileName, 'deploy-notes.txt');
      expect(summaries.single.totalSize, plaintext.length);
      final restored = await service.download(
        vaultId: _vaultId,
        host: updated,
        blobId: summaries.single.blobId,
      );
      expect(restored, plaintext);
      restored.fillRange(0, restored.length, 0);

      HostRecord? removed;
      await service.remove(
        vaultId: _vaultId,
        host: updated,
        blobId: summaries.single.blobId,
        commit: (candidate) async => removed = candidate,
      );
      expect(removed, isNotNull);
      expect(removed!.manifest!['attachments'], isEmpty);
      expect(removed!.manifest!['object_refs'], [_legacyObjectId]);
      // Removing a current ref leaves immutable historical objects to normal GC.
      expect(server.objects, hasLength(1));
      expect(service.list(removed!), isEmpty);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      api.close();
      await database.close();
    }
  });

  test(
    'reads, downloads, and removes a v2 sidecar directory attachment',
    () async {
      final server = _ObjectServer(chunkSize: 1024 * 1024);
      final api = _api(server);
      final database = _database();
      final crypto = HostAttachmentCrypto(randomBytes: sodium.randombytes.buf);
      final service = HostAttachmentService(
        api: api,
        crypto: crypto,
        database: database,
      );
      final plaintext = Uint8List.fromList(
        utf8.encode('v2 attachment payload'),
      );
      final descriptor = await crypto.encryptSourceForTransferV2(
        fileName: 'v2-notes.txt',
        mediaType: 'text/plain',
        source: MemoryAttachmentUploadSource(plaintext),
        onStart: (_) async {},
        onObject: (object) async {
          server.objects[object.objectId] = Uint8List.fromList(object.bytes);
        },
      );
      final parsed = HostAttachmentV2ManifestEntry.parse(descriptor);
      final refs = parsed.objectIds.toList()..sort();
      parsed.clearSecrets();
      final host = _host(
        manifest: {
          'attachments': [descriptor],
          'object_refs': refs,
        },
      );
      try {
        final summary = service.list(host).single;
        expect(summary.fileName, 'v2-notes.txt');
        expect(summary.formatVersion, 2);
        expect(summary.totalSize, plaintext.length);
        expect(summary.canDownload, isTrue);

        final restored = await service.download(
          vaultId: _vaultId,
          host: host,
          blobId: descriptor['blob_id']! as String,
        );
        expect(restored, plaintext);
        restored.fillRange(0, restored.length, 0);

        HostRecord? removed;
        await service.remove(
          vaultId: _vaultId,
          host: host,
          blobId: descriptor['blob_id']! as String,
          commit: (candidate) async => removed = candidate,
        );
        expect(removed!.manifest!['attachments'], isEmpty);
        expect(removed!.manifest!['object_refs'], isEmpty);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  test(
    'resumes staged v2 chunk and directory objects by authenticated IDs',
    () async {
      final server = _ObjectServer(chunkSize: 1024 * 1024);
      final api = _api(server);
      final database = _database();
      final crypto = HostAttachmentCrypto(randomBytes: sodium.randombytes.buf);
      final service = HostAttachmentService(
        api: api,
        crypto: crypto,
        database: database,
      );
      final plaintext = Uint8List.fromList(
        List<int>.generate(89 * 1024, (index) => (index * 19) & 0xff),
      );
      String? jobId;
      try {
        final descriptor = await crypto.encryptSourceForTransferV2(
          fileName: 'staged-v2.bin',
          mediaType: 'application/octet-stream',
          source: MemoryAttachmentUploadSource(plaintext),
          onStart: (blobId) async {
            jobId = 'upload:$_vaultId:$_hostId:$blobId';
            await database.beginBlobJob(
              jobId: jobId!,
              vaultId: _vaultId,
              recordId: _hostId,
              blobId: blobId,
              direction: 'upload',
              state: 'encrypting',
            );
          },
          onObject: (object) async {
            await database.stageBlobUploadObject(
              jobId: jobId!,
              objectId: object.objectId,
              sha256: object.sha256,
              bytes: object.bytes,
            );
          },
        );
        final parsed = HostAttachmentV2ManifestEntry.parse(descriptor);
        final refs = parsed.objectIds.toList()..sort();
        parsed.clearSecrets();
        await database.updateBlobJobObjectCount(jobId!, refs.length);
        final host = _host(
          manifest: {
            'attachments': [descriptor],
            'object_refs': refs,
          },
        );

        await service.resumeUpload(
          vaultId: _vaultId,
          host: host,
          blobId: descriptor['blob_id']! as String,
        );
        expect(server.objects, hasLength(refs.length));
        expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
        api.close();
        await database.close();
      }
    },
  );

  test(
    'v2 capability preflight fails closed before staging any object',
    () async {
      final server = _ObjectServer()
        ..advertiseDeviceCapabilityReports = true
        ..vaultDeviceRows = [
          _capabilityDevice(
            deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            status: 'active',
            supportsV2: false,
          ),
          _capabilityDevice(
            deviceId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
            status: 'archived',
            supportsV2: false,
          ),
        ];
      final api = _api(server);
      final database = _database();
      var reportCalls = 0;
      final service = HostAttachmentService(
        api: api,
        crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
        database: database,
        ensureDeviceCapabilityReported: () async => reportCalls++,
        verifyV2ReaderCapability: _verifyTestCapabilityReport,
      );
      final source = StreamAttachmentUploadSource(
        size: hostAttachmentMaxBytes + 1,
        stream: const Stream<List<int>>.empty(),
      );
      try {
        await expectLater(
          service.addFromSource(
            vaultId: _vaultId,
            host: _host(),
            fileName: 'large.bin',
            mediaType: 'application/octet-stream',
            source: source,
            commit: (_) async => fail('A blocked v2 write must not commit.'),
          ),
          throwsA(
            isA<HostAttachmentV2UnavailableException>().having(
              (error) => error.message,
              'message',
              contains('no valid signed report'),
            ),
          ),
        );
        expect(reportCalls, 1);
        expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
        expect(server.objects, isEmpty);
        expect(
          server.requests.where(
            (request) =>
                request.method == 'POST' &&
                request.url.path.endsWith('/uploads/init'),
          ),
          isEmpty,
        );
      } finally {
        api.close();
        await database.close();
      }
    },
  );

  test(
    'revision-1 v2 reports pass for active members with schema-2 fields',
    () async {
      final server = _ObjectServer()
        ..advertiseDeviceCapabilityReports = true
        ..vaultDeviceRows = [
          _capabilityDevice(
            deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            status: 'active',
            supportsV2: true,
          ),
          _capabilityDevice(
            deviceId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
            status: 'active',
            supportsV2: true,
          ),
          _capabilityDevice(
            deviceId: '99999999-9999-4999-8999-999999999999',
            status: 'active',
            membershipStatus: 'invited',
            supportsV2: false,
          ),
        ];
      final api = _api(server);
      final database = _database();
      try {
        final result =
            await HostAttachmentService(
              api: api,
              crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
              database: database,
              ensureDeviceCapabilityReported: () async {},
              verifyV2ReaderCapability: _verifyTestCapabilityReport,
            ).preflightV2Upload(
              vaultId: _vaultId,
              totalSize: hostAttachmentMaxBytes + 1,
            );
        expect(result.supportedActiveDevices, 2);
        expect(result.canUpload, isTrue);
        expect(result.reason, isNull);
        expect(server.objects, isEmpty);
      } finally {
        api.close();
        await database.close();
      }
    },
  );

  test(
    'unsupported platform blocks a large upload before source reads',
    () async {
      final server = _ObjectServer();
      final api = _api(server);
      final database = _database();
      var sourceOpened = false;
      var reportCalls = 0;
      final service = HostAttachmentService(
        api: api,
        crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
        database: database,
        ensureDeviceCapabilityReported: () async => reportCalls++,
        platformAttachmentLimitOverride: hostAttachmentMaxBytes,
      );
      final source = StreamAttachmentUploadSource(
        size: hostAttachmentMaxBytes + 1,
        stream: Stream<List<int>>.multi((controller) {
          sourceOpened = true;
          controller.close();
        }),
      );
      try {
        await expectLater(
          service.addFromSource(
            vaultId: _vaultId,
            host: _host(),
            fileName: 'too-large.bin',
            mediaType: 'application/octet-stream',
            source: source,
            commit: (_) async => fail('Unsupported platform must not commit.'),
          ),
          throwsA(
            isA<HostAttachmentV2UnavailableException>().having(
              (error) => error.message,
              'message',
              contains('platform cannot safely save'),
            ),
          ),
        );
        expect(sourceOpened, isFalse);
        expect(reportCalls, 0);
        expect(server.requests, isEmpty);
        expect(server.objects, isEmpty);
        expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
      } finally {
        api.close();
        await database.close();
      }
    },
  );

  test('large memory source is rejected before opening or staging', () async {
    final server = _ObjectServer();
    final api = _api(server);
    final database = _database();
    final source = _TrackingMemoryUploadSource(hostAttachmentMaxBytes + 1);
    final service = HostAttachmentService(
      api: api,
      crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
      database: database,
    );
    try {
      await expectLater(
        service.addFromSource(
          vaultId: _vaultId,
          host: _host(),
          fileName: 'memory-backed.bin',
          mediaType: 'application/octet-stream',
          source: source,
          commit: (_) async => fail('An unbounded source must not commit.'),
        ),
        throwsA(
          isA<HostAttachmentV2UnavailableException>().having(
            (error) => error.message,
            'message',
            contains('bounded streaming source'),
          ),
        ),
      );
      expect(source.opened, isFalse);
      expect(server.requests, isEmpty);
      expect(server.objects, isEmpty);
      expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
    } finally {
      api.close();
      await database.close();
    }
  });

  test(
    'v2 preflight rejects unknown member and device status values',
    () async {
      for (final invalid in [
        _capabilityDevice(
          deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          status: 'active',
          membershipStatus: 'unknown',
          supportsV2: true,
        ),
        _capabilityDevice(
          deviceId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
          status: 'unknown',
          supportsV2: true,
        ),
      ]) {
        final server = _ObjectServer()
          ..advertiseDeviceCapabilityReports = true
          ..vaultDeviceRows = [invalid];
        final api = _api(server);
        final database = _database();
        try {
          final result =
              await HostAttachmentService(
                api: api,
                crypto: HostAttachmentCrypto(
                  randomBytes: sodium.randombytes.buf,
                ),
                database: database,
                ensureDeviceCapabilityReported: () async {},
                verifyV2ReaderCapability: _verifyTestCapabilityReport,
              ).preflightV2Upload(
                vaultId: _vaultId,
                totalSize: hostAttachmentMaxBytes + 1,
              );
          expect(result.canUpload, isFalse);
          expect(result.reason, contains('invalid Vault device inventory'));
        } finally {
          api.close();
          await database.close();
        }
      }
    },
  );

  test('300 MiB writes require every active report to permit 1 GiB', () async {
    final server = _ObjectServer()
      ..advertiseDeviceCapabilityReports = true
      ..vaultDeviceRows = [
        _capabilityDevice(
          deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          status: 'active',
          supportsV2: true,
          maxAttachmentBytes: 300 * 1024 * 1024,
        ),
      ];
    final api = _api(server);
    final database = _database();
    try {
      final result = await HostAttachmentService(
        api: api,
        crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
        database: database,
        ensureDeviceCapabilityReported: () async {},
        verifyV2ReaderCapability: _verifyTestCapabilityReport,
      ).preflightV2Upload(vaultId: _vaultId, totalSize: 300 * 1024 * 1024);
      expect(result.canUpload, isFalse);
      expect(result.reason, contains('no valid signed report'));
    } finally {
      api.close();
      await database.close();
    }
  });

  test('large v2 download verifies fully before bounded sink writes', () async {
    const totalSize = 6 * 1024 * 1024 + 19;
    Uint8List makePart(int offset, int length) => Uint8List.fromList(
      List<int>.generate(length, (index) => ((offset + index) * 13 + 5) & 0xff),
    );

    final expectedDigest = cryptography.Sha256().toSync().newHashSink();
    for (var offset = 0; offset < totalSize; offset += 1024 * 1024) {
      final end = offset + 1024 * 1024 < totalSize
          ? offset + 1024 * 1024
          : totalSize;
      final part = makePart(offset, end - offset);
      expectedDigest.add(part);
      part.fillRange(0, part.length, 0);
    }
    expectedDigest.close();
    final expectedSha = (await expectedDigest.hash()).bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    final server = _ObjectServer();
    final api = _api(server);
    final database = _database();
    final crypto = HostAttachmentCrypto(randomBytes: sodium.randombytes.buf);
    Stream<Uint8List> virtualPlaintext() async* {
      for (var offset = 0; offset < totalSize; offset += 1024 * 1024) {
        final end = offset + 1024 * 1024 < totalSize
            ? offset + 1024 * 1024
            : totalSize;
        yield makePart(offset, end - offset);
      }
    }

    try {
      final descriptor = await crypto.encryptSourceForTransferV2(
        fileName: 'virtual.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: totalSize,
          stream: virtualPlaintext(),
        ),
        onStart: (_) async {},
        onObject: (object) async {
          server.objects[object.objectId] = Uint8List.fromList(object.bytes);
        },
      );
      expect(descriptor['plaintext_sha256'], expectedSha);
      final objectIds = <String>[
        descriptor['manifest_object_id']! as String,
        ...(descriptor['chunk_object_ids']! as List).cast<String>(),
      ]..sort();
      final host = _host(
        manifest: {
          'attachments': [descriptor],
          'object_refs': objectIds,
        },
      );
      final service = HostAttachmentService(
        api: api,
        crypto: crypto,
        database: database,
        streamingDownloadMinimumBytes: 0,
      );
      final outputDigest = cryptography.Sha256().toSync().newHashSink();
      var outputLength = 0;
      var callbackCount = 0;
      var maximumCallbackBytes = 0;
      await service.downloadToSink(
        vaultId: _vaultId,
        host: host,
        blobId: descriptor['blob_id']! as String,
        onPlaintextChunk: (chunk) async {
          callbackCount++;
          outputLength += chunk.length;
          if (chunk.length > maximumCallbackBytes) {
            maximumCallbackBytes = chunk.length;
          }
          outputDigest.add(chunk);
          await Future<void>.delayed(Duration.zero);
        },
      );
      outputDigest.close();
      final outputSha = (await outputDigest.hash()).bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(outputLength, totalSize);
      expect(outputSha, expectedSha);
      expect(callbackCount, 2);
      expect(maximumCallbackBytes, hostAttachmentLogicalChunkBytes);
      expect(
        (await database.blobJobsForRecord(_vaultId, _hostId)).single.state,
        'ready_to_save',
      );

      await service.completeDownload(
        vaultId: _vaultId,
        recordId: _hostId,
        blobId: descriptor['blob_id']! as String,
      );
      final badDescriptor = Map<String, Object?>.from(descriptor)
        ..['plaintext_sha256'] = List.filled(64, '0').join();
      final badHost = _host(
        manifest: {
          'attachments': [badDescriptor],
          'object_refs': objectIds,
        },
      );
      var badCallbacks = 0;
      await expectLater(
        service.downloadToSink(
          vaultId: _vaultId,
          host: badHost,
          blobId: descriptor['blob_id']! as String,
          onPlaintextChunk: (_) async => badCallbacks++,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(badCallbacks, 0);
      expect(
        (await database.blobJobsForRecord(_vaultId, _hostId)).single.state,
        'failed',
      );
    } finally {
      api.close();
      await database.close();
      for (final bytes in server.objects.values) {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
  });

  test(
    'oversize v2 reads fail before download or full-file allocation',
    () async {
      final server = _ObjectServer();
      final api = _api(server);
      final database = _database();
      const chunkCount =
          (hostAttachmentMaxBytes + 1 + hostAttachmentLogicalChunkBytes - 1) ~/
          hostAttachmentLogicalChunkBytes;
      final chunkIds = List<String>.generate(
        chunkCount,
        (index) =>
            '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
      );
      const directoryId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
      final descriptor = <String, Object?>{
        'format': hostAttachmentV2Format,
        'version': 2,
        'blob_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        'file_name': 'over-limit.bin',
        'media_type': 'application/octet-stream',
        'total_size': hostAttachmentMaxBytes + 1,
        'plaintext_sha256': List.filled(64, '0').join(),
        'compression': 'none',
        'blob_key': base64Url.encode(List.filled(32, 7)).replaceAll('=', ''),
        'manifest_object_id': directoryId,
        'manifest_nonce': base64Url
            .encode(List.filled(12, 8))
            .replaceAll('=', ''),
        'manifest_ciphertext_size': 16,
        'manifest_ciphertext_sha256': List.filled(64, '1').join(),
        'chunk_object_ids': chunkIds,
        'chunk_count': chunkCount,
      };
      final host = _host(
        manifest: {
          'attachments': [descriptor],
          'object_refs': [...chunkIds, directoryId]..sort(),
        },
      );
      final service = HostAttachmentService(
        api: api,
        crypto: HostAttachmentCrypto(randomBytes: (_) => Uint8List(0)),
        database: database,
      );
      try {
        final summary = service.list(host).single;
        expect(summary.formatVersion, 2);
        expect(
          summary.canDownload,
          hostAttachmentMaxBytes + 1 <= maxAttachmentBytesForPlatform,
        );
        await expectLater(
          service.download(
            vaultId: _vaultId,
            host: host,
            blobId: descriptor['blob_id']! as String,
          ),
          throwsA(isA<HostAttachmentV2UnavailableException>()),
        );
        expect(server.requests, isEmpty);
        expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
      } finally {
        api.close();
        await database.close();
      }
    },
  );

  test('failed uploads persist and resume after a database restart', () async {
    final plaintext = Uint8List.fromList(utf8.encode('never commit this file'));
    final original = _host(
      manifest: {
        'extension_version': 4,
        'object_refs': [_legacyObjectId],
      },
    );

    final directory = await Directory.systemTemp.createTemp(
      'atermius-blob-upload-',
    );
    final databaseFile = File('${directory.path}/client.sqlite');
    var database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
    final uploadServer = _ObjectServer(failAtPutIndex: 1);
    final uploadApi = _api(uploadServer);
    var uploadCommitCalls = 0;
    HostRecord? committedHost;
    try {
      await expectLater(
        _service(uploadApi, sodium, database).addFromSource(
          vaultId: _vaultId,
          host: original,
          fileName: 'private.txt',
          mediaType: 'text/plain',
          source: StreamAttachmentUploadSource(
            size: plaintext.length,
            stream: Stream<List<int>>.fromIterable([
              Uint8List.fromList(Uint8List.sublistView(plaintext, 0, 7)),
              Uint8List.fromList(Uint8List.sublistView(plaintext, 7)),
            ]),
          ),
          commit: (candidate) async {
            uploadCommitCalls++;
            committedHost = candidate;
          },
        ),
        throwsA(isA<ApiException>()),
      );
      expect(uploadCommitCalls, 1);
      expect(committedHost, isNotNull);
      expect(original.manifest!['object_refs'], [_legacyObjectId]);
      expect(original.manifest!.containsKey('attachments'), isFalse);
      expect(uploadServer.objects, isEmpty);
      final pending = await database.blobJobsForRecord(_vaultId, _hostId);
      expect(pending, hasLength(1));
      expect(pending.single.state, 'failed');
      final staged = await database.blobJobObjectRows(pending.single.jobId);
      expect(staged.single.bytes, isNotNull);
      expect(staged.single.nextChunkIndex, 1);
      expect(uploadServer.openUploads, hasLength(1));
      await database.close();

      database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
      uploadServer.failAtPutIndex = null;
      final retryApi = _api(uploadServer);
      final requestsBeforeRetry = uploadServer.requests.length;
      try {
        await _service(retryApi, sodium, database).resumeUpload(
          vaultId: _vaultId,
          host: committedHost!,
          blobId:
              (committedHost!.manifest!['attachments']! as List)
                      .single['blob_id']
                  as String,
        );
        expect(uploadServer.objects, hasLength(1));
        final retriedIndexes = uploadServer.requests
            .skip(requestsBeforeRetry)
            .where((request) => request.method == 'PUT')
            .map((request) => int.parse(request.url.path.split('/').last))
            .toList();
        expect(retriedIndexes, isNot(contains(0)));
        expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
      } finally {
        retryApi.close();
      }
    } finally {
      uploadApi.close();
      await database.close();
      await directory.delete(recursive: true);
    }

    final saveServer = _ObjectServer();
    final saveApi = _api(saveServer);
    final saveDatabase = _database();
    try {
      await expectLater(
        _service(saveApi, sodium, saveDatabase).add(
          vaultId: _vaultId,
          host: original,
          fileName: 'private.txt',
          mediaType: 'text/plain',
          plaintext: plaintext,
          commit: (candidate) async {
            expect(saveServer.objects, isEmpty);
            final pending = await saveDatabase.blobJobsForRecord(
              _vaultId,
              _hostId,
            );
            final staged = await saveDatabase.blobJobObjectRows(
              pending.single.jobId,
            );
            expect(
              candidate.manifest!['object_refs'],
              contains(staged.single.objectId),
            );
            expect(staged.single.bytes, isNotNull);
            throw StateError('simulated local record save failure');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(original.manifest!['object_refs'], [_legacyObjectId]);
      expect(original.manifest!.containsKey('attachments'), isFalse);
      expect(saveServer.objects, isEmpty);
      // The callback can fail after committing to Drift; preserve the staged
      // job and let the UI explicitly discard it if the Host does not refer.
      final pending = await saveDatabase.blobJobsForRecord(_vaultId, _hostId);
      expect(pending, hasLength(1));
      final orphanBlob = pending.single.blobId;
      await _service(saveApi, sodium, saveDatabase).discardOrphanUpload(
        vaultId: _vaultId,
        host: original,
        blobId: orphanBlob,
      );
      expect(await saveDatabase.blobJobsForRecord(_vaultId, _hostId), isEmpty);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      saveApi.close();
      await saveDatabase.close();
    }
  });

  test(
    'validates 206 Range metadata and rejects a changed byte interval',
    () async {
      final server = _ObjectServer()
        ..objects[_legacyObjectId] = Uint8List.fromList([3, 5, 7, 9]);
      final api = _api(server);
      final digest = await _sha256(server.objects[_legacyObjectId]!);
      try {
        final first = await api.downloadObjectRange(
          vaultId: _vaultId,
          objectId: _legacyObjectId,
          start: 0,
          end: 1,
          expectedSize: 4,
          expectedSha256: digest,
        );
        expect(first, [3, 5]);
        server.badRangeMetadata = true;
        await expectLater(
          api.downloadObjectRange(
            vaultId: _vaultId,
            objectId: _legacyObjectId,
            start: 2,
            end: 3,
            expectedSize: 4,
            expectedSha256: digest,
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        api.close();
      }
    },
  );

  test(
    'resumes download from the last verified HTTP range after restart',
    () async {
      final plaintext = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 37, (index) => (index * 13) & 0xff),
      );
      final directory = await Directory.systemTemp.createTemp(
        'atermius-blob-download-',
      );
      final databaseFile = File('${directory.path}/client.sqlite');
      var database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
      final server = _ObjectServer(
        chunkSize: 1024 * 1024,
        failAtRangeStart: 1024 * 1024,
      );
      final firstApi = _api(server);
      HostRecord? committed;
      try {
        final host = await _service(firstApi, sodium, database).add(
          vaultId: _vaultId,
          host: _host(),
          fileName: 'large.bin',
          mediaType: 'application/octet-stream',
          plaintext: plaintext,
          commit: (candidate) async => committed = candidate,
        );
        committed = host;
        final blobId =
            ((host.manifest!['attachments']! as List).single as Map)['blob_id']
                as String;

        await expectLater(
          _service(
            firstApi,
            sodium,
            database,
          ).download(vaultId: _vaultId, host: host, blobId: blobId),
          throwsA(isA<ApiException>()),
        );
        expect(server.rangeStarts, [0, 1024 * 1024]);
        final jobs = await database.blobJobsForRecord(_vaultId, _hostId);
        expect(jobs.single.direction, 'download');
        final rows = await database.blobJobObjectRows(jobs.single.jobId);
        expect(rows.single.bytes, hasLength(1024 * 1024));
        firstApi.close();
        await database.close();

        database = ClientDatabase.forTesting(NativeDatabase(databaseFile));
        server.failAtRangeStart = null;
        final retryApi = _api(server);
        final requestOffset = server.rangeStarts.length;
        try {
          final restored = await _service(
            retryApi,
            sodium,
            database,
          ).download(vaultId: _vaultId, host: committed!, blobId: blobId);
          expect(restored, plaintext);
          restored.fillRange(0, restored.length, 0);
          expect(server.rangeStarts.skip(requestOffset), [1024 * 1024]);
          final readyJobs = await database.blobJobsForRecord(_vaultId, _hostId);
          expect(readyJobs.single.state, 'ready_to_save');
          await _service(retryApi, sodium, database).completeDownload(
            vaultId: _vaultId,
            recordId: _hostId,
            blobId: blobId,
          );
          expect(await database.blobJobsForRecord(_vaultId, _hostId), isEmpty);
        } finally {
          retryApi.close();
        }
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
        firstApi.close();
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'rejects disagreement between attachment manifest and object_refs',
    () async {
      final server = _ObjectServer();
      final api = _api(server);
      final database = _database();
      final service = _service(api, sodium, database);
      final valid = await service.add(
        vaultId: _vaultId,
        host: _host(),
        fileName: 'notes.txt',
        mediaType: 'text/plain',
        plaintext: Uint8List.fromList(utf8.encode('x')),
        commit: (_) async {},
      );
      final malformedManifest = Map<String, Object?>.from(valid.manifest!)
        ..['object_refs'] = const <String>[];
      final malformed = valid.copyWith(manifest: malformedManifest);
      final explicitNullRefs = _host(manifest: const {'object_refs': null});
      try {
        expect(() => service.list(malformed), throwsA(isA<FormatException>()));
        expect(
          () => service.list(explicitNullRefs),
          throwsA(isA<FormatException>()),
        );
      } finally {
        api.close();
        await database.close();
      }
    },
  );
}

ClientDatabase _database() =>
    ClientDatabase.forTesting(NativeDatabase.memory());

HostAttachmentService _service(
  ApiClient api,
  SodiumSumo sodium,
  ClientDatabase database,
) => HostAttachmentService(
  api: api,
  crypto: HostAttachmentCrypto(randomBytes: sodium.randombytes.buf),
  database: database,
);

Map<String, Object?> _capabilityDevice({
  required String deviceId,
  required String status,
  String membershipStatus = 'active',
  required bool supportsV2,
  int maxAttachmentBytes = hostAttachmentV2MaxBytes,
}) => {
  'device_id': deviceId,
  'name': 'test device',
  'signing_public_key': 'test-key',
  'status': status,
  'membership_status': membershipStatus,
  'capability_report': supportsV2
      ? {
          'account_id': '11111111-1111-4111-8111-111111111111',
          'device_id': deviceId,
          'revision': 1,
          'max_record_schema': 2,
          'host_attachment_manifest_versions': [1, 2],
          'max_attachment_bytes': maxAttachmentBytes,
          'signature': 'signed-report',
        }
      : null,
};

bool _verifyTestCapabilityReport(Map<String, dynamic> device) {
  final report = device['capability_report'];
  return device['signing_public_key'] == 'test-key' &&
      report is Map &&
      report['device_id'] == device['device_id'] &&
      report['signature'] == 'signed-report';
}

ApiClient _api(_ObjectServer server) => ApiClient(
  baseUrl: 'https://attachment.test',
  client: MockClient(server.handle),
);

HostRecord _host({Map<String, Object?>? manifest}) => HostRecord(
  id: _hostId,
  name: 'Production',
  address: 'host.example.test',
  username: 'deploy',
  manifest: manifest,
);

Future<String> _sha256(List<int> bytes) async =>
    (await cryptography.Sha256().hash(
      bytes,
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _containsSequence(List<int> bytes, List<int> sequence) {
  if (sequence.isEmpty || sequence.length > bytes.length) return false;
  for (var offset = 0; offset <= bytes.length - sequence.length; offset++) {
    var matches = true;
    for (var index = 0; index < sequence.length; index++) {
      if (bytes[offset + index] != sequence[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

class _VirtualByteList extends ListBase<int> {
  _VirtualByteList(this._length);

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('fixed virtual length');

  final int _length;

  @override
  int operator [](int index) => throw StateError('virtual byte list was read');

  @override
  void operator []=(int index, int value) =>
      throw StateError('virtual byte list was written');
}

class _TrackingMemoryUploadSource extends MemoryAttachmentUploadSource {
  _TrackingMemoryUploadSource(int size) : super(_VirtualByteList(size));

  var opened = false;

  @override
  Stream<List<int>> openRead() {
    opened = true;
    return super.openRead();
  }
}

class _UploadReservation {
  _UploadReservation({
    required this.objectId,
    required this.expectedSize,
    required this.expectedHash,
  });

  final String objectId;
  final int expectedSize;
  final String expectedHash;
  final Map<int, Uint8List> chunks = {};
}

class _ObjectServer {
  _ObjectServer({
    this.failAtPutIndex,
    this.failAtRangeStart,
    this.chunkSize = 17,
  });

  int? failAtPutIndex;
  int? failAtRangeStart;
  bool badRangeMetadata = false;
  bool advertiseDeviceCapabilityReports = false;
  List<Map<String, Object?>> vaultDeviceRows = const [];
  final int chunkSize;
  final requests = <http.Request>[];
  final rangeStarts = <int>[];
  final reservations = <String, _UploadReservation>{};
  final objects = <String, Uint8List>{};
  int _uploadSequence = 0;

  Iterable<_UploadReservation> get openUploads => reservations.values.where(
    (reservation) => !objects.containsKey(reservation.objectId),
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'GET' && request.url.path == '/api/v1/instance') {
      return _json({
        'instance_id': '11111111-1111-4111-8111-111111111111',
        'server_space_id': '22222222-2222-4222-8222-222222222222',
        'generation': '1',
        'protocol_version': 1,
        'setup_required': false,
        'capabilities': advertiseDeviceCapabilityReports
            ? ['device_capability_reports']
            : const [],
      });
    }
    if (request.method == 'GET' &&
        request.url.path == '/api/v1/vaults/$_vaultId/devices') {
      return _json({'devices': vaultDeviceRows});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/uploads/init')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final sequence = (++_uploadSequence).toString().padLeft(12, '0');
      final uploadId = 'aaaaaaaa-aaaa-4aaa-8aaa-$sequence';
      reservations[uploadId] = _UploadReservation(
        objectId: body['object_id'] as String,
        expectedSize: body['size'] as int,
        expectedHash: body['sha256'] as String,
      );
      return _json({
        'upload_id': uploadId,
        'chunk_size': chunkSize,
        'expires_at': '2099-01-01T00:00:00Z',
      });
    }
    final chunkMatch = RegExp(
      r'/uploads/([^/]+)/chunks/(\d+)$',
    ).firstMatch(request.url.path);
    if (request.method == 'PUT' && chunkMatch != null) {
      final uploadId = chunkMatch.group(1)!;
      final index = int.parse(chunkMatch.group(2)!);
      if (index == failAtPutIndex) return _apiError(503, 'SERVER_UNAVAILABLE');
      final reservation = reservations[uploadId]!;
      final digest = await _sha256(request.bodyBytes);
      if (request.headers['x-content-sha256'] != digest) {
        return _apiError(400, 'BAD_CHUNK_HASH');
      }
      reservation.chunks[index] = Uint8List.fromList(request.bodyBytes);
      return _json({'upload_id': uploadId, 'index': index, 'sha256': digest});
    }
    final completeMatch = RegExp(
      r'/uploads/([^/]+)/complete$',
    ).firstMatch(request.url.path);
    if (request.method == 'POST' && completeMatch != null) {
      final uploadId = completeMatch.group(1)!;
      final reservation = reservations[uploadId]!;
      final builder = BytesBuilder(copy: false);
      for (var index = 0; index < reservation.chunks.length; index++) {
        builder.add(reservation.chunks[index]!);
      }
      final bytes = builder.takeBytes();
      final digest = await _sha256(bytes);
      if (bytes.length != reservation.expectedSize ||
          digest != reservation.expectedHash) {
        return _apiError(409, 'OBJECT_HASH_MISMATCH');
      }
      objects[reservation.objectId] = bytes;
      return _json({
        'object_id': reservation.objectId,
        'size': bytes.length,
        'sha256': digest,
      });
    }
    final objectMatch = RegExp(
      r'/vaults/[^/]+/objects/([^/]+)$',
    ).firstMatch(request.url.path);
    if (request.method == 'GET' && objectMatch != null) {
      final bytes = objects[objectMatch.group(1)];
      if (bytes == null) return _apiError(404, 'NOT_FOUND');
      final digest = await _sha256(bytes);
      final rangeHeader = request.headers['range'];
      if (rangeHeader != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader);
        if (match == null) return _apiError(400, 'INVALID_RANGE');
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        rangeStarts.add(start);
        if (start == failAtRangeStart) {
          return _apiError(503, 'SERVER_UNAVAILABLE');
        }
        if (end >= bytes.length || start > end) {
          return http.Response(
            '',
            416,
            headers: {
              'content-range': 'bytes */${bytes.length}',
              'etag': '"sha256-$digest"',
            },
          );
        }
        final part = Uint8List.sublistView(bytes, start, end + 1);
        return http.Response.bytes(
          part,
          206,
          headers: {
            'content-range': badRangeMetadata
                ? 'bytes ${start + 1}-$end/${bytes.length}'
                : 'bytes $start-$end/${bytes.length}',
            'content-length': '${part.length}',
            'etag': '"sha256-$digest"',
          },
        );
      }
      return http.Response.bytes(
        bytes,
        200,
        headers: {'etag': '"sha256-$digest"'},
      );
    }
    return _apiError(404, 'NOT_FOUND');
  }
}

http.Response _json(Map<String, Object?> value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _apiError(int status, String code) => http.Response(
  jsonEncode({
    'error': {'code': code, 'message': 'request failed'},
  }),
  status,
  headers: {'content-type': 'application/json'},
);
