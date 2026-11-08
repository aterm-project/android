import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/crypto/host_attachment_crypto.dart';
import 'package:aterm_client/attachments/attachment_upload_source.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late HostAttachmentCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = HostAttachmentCrypto(randomBytes: sodium.randombytes.buf);
  });

  test('matches the shared host attachment v1 crypto vector', () async {
    const blobId = '00000000-0000-4000-8000-000000000001';
    const objectId = '00000000-0000-4000-8000-000000000002';
    const ciphertextHex =
        '79d7e6271da9038000109dc3183c9e3b196fe7e33eb2b174d3db4d4b4c6eb8b7'
        'c2a1c9aa3f79e33735aa1777c1c0313a5a80';
    final ids = [blobId, objectId];
    final vectorCrypto = HostAttachmentCrypto.withUuidGenerator(
      randomBytes: (count) => Uint8List.fromList(
        List<int>.generate(count, (index) => index + (count == 12 ? 12 : 0)),
      ),
      uuidGenerator: () => ids.removeAt(0),
    );
    final plaintext = Uint8List.fromList(
      'atermius host attachment vector v1'.codeUnits,
    );

    final encrypted = await vectorCrypto.encrypt(
      fileName: 'vector.txt',
      mediaType: 'text/plain',
      bytes: plaintext,
    );

    expect(encrypted.manifestEntry['blob_id'], blobId);
    expect(
      encrypted.manifestEntry['blob_key'],
      'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    );
    expect(
      encrypted.manifestEntry['plaintext_sha256'],
      'b819b679500e2f0bc2a446b9410177052fb4df84b0a08899a79a73e80dd70ebe',
    );
    final chunk = (encrypted.manifestEntry['chunks']! as List).single as Map;
    expect(chunk['object_id'], objectId);
    expect(chunk['nonce'], 'DA0ODxAREhMUFRYX');
    expect(
      chunk['sha256'],
      '2907a97c04c6a981ed561861e19e8b88c8856550a4a3302e8bb0e3bc7c924ea7',
    );
    expect(
      encrypted.objects.single.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      ciphertextHex,
    );

    final streamIds = [blobId, objectId];
    final streamCrypto = HostAttachmentCrypto.withUuidGenerator(
      randomBytes: (count) => Uint8List.fromList(
        List<int>.generate(count, (index) => index + (count == 12 ? 12 : 0)),
      ),
      uuidGenerator: () => streamIds.removeAt(0),
    );
    final streamObjects = <EncryptedAttachmentObject>[];
    final streamManifest = await streamCrypto.encryptSourceForTransfer(
      fileName: 'vector.txt',
      mediaType: 'text/plain',
      source: StreamAttachmentUploadSource(
        size: plaintext.length,
        stream: Stream<List<int>>.fromIterable([
          Uint8List.fromList(Uint8List.sublistView(plaintext, 0, 9)),
          Uint8List.fromList(Uint8List.sublistView(plaintext, 9)),
        ]),
      ),
      onStart: (_) async {},
      onObject: (object) async {
        streamObjects.add(
          EncryptedAttachmentObject(
            objectId: object.objectId,
            bytes: Uint8List.fromList(object.bytes),
            sha256: object.sha256,
          ),
        );
      },
    );
    expect(streamManifest, encrypted.manifestEntry);
    expect(streamObjects, hasLength(1));
    expect(streamObjects.single.bytes, encrypted.objects.single.bytes);
    streamObjects.single.bytes.fillRange(
      0,
      streamObjects.single.bytes.length,
      0,
    );
    encrypted.clearCiphertext();
    plaintext.fillRange(0, plaintext.length, 0);
  });

  test(
    'best-effort clears mutable source lists and tolerates immutable views',
    () {
      final source = StreamAttachmentUploadSource(
        size: 0,
        stream: const Stream<List<int>>.empty(),
      );
      final backing = <dynamic>[17, 34, 51];

      source.releaseReadChunk(backing.cast<int>());

      expect(backing, [0, 0, 0]);
      expect(
        () => source.releaseReadChunk(List<int>.unmodifiable([1, 2, 3])),
        returnsNormally,
      );
    },
  );

  test(
    'v2 directory encrypts, resolves and decrypts without changing v1',
    () async {
      final plaintext = Uint8List.fromList(
        List<int>.generate(
          hostAttachmentLogicalChunkBytes + 37,
          (index) => index & 0xff,
        ),
      );
      final objects = <String, Uint8List>{};
      final manifest = await crypto.encryptSourceForTransferV2(
        fileName: 'v2-roundtrip.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: plaintext.length,
          stream: Stream<List<int>>.fromIterable([
            Uint8List.fromList(
              Uint8List.sublistView(plaintext, 0, 1024 * 1024),
            ),
            Uint8List.fromList(Uint8List.sublistView(plaintext, 1024 * 1024)),
          ]),
        ),
        onStart: (_) async {},
        onObject: (object) async {
          objects[object.objectId] = Uint8List.fromList(object.bytes);
        },
      );
      final referenceV1 = await crypto.encrypt(
        fileName: 'reference.bin',
        mediaType: 'application/octet-stream',
        bytes: plaintext,
      );
      expect(
        manifest['plaintext_sha256'],
        referenceV1.manifestEntry['plaintext_sha256'],
      );
      referenceV1.clearCiphertext();
      final descriptor = HostAttachmentV2ManifestEntry.parse(manifest);
      expect(descriptor.totalSize, plaintext.length);
      expect(descriptor.chunkCount, 2);
      expect(descriptor.objectIds, [
        descriptor.manifestObjectId,
        ...descriptor.chunkObjectIds,
      ]);
      final resolved = await crypto.resolveV2Manifest(
        manifestEntry: manifest,
        manifestCiphertext: objects[descriptor.manifestObjectId]!,
      );
      final restored = BytesBuilder(copy: true);
      try {
        for (var index = 0; index < resolved.chunks.length; index++) {
          final clear = await crypto.decryptV2Chunk(
            attachment: resolved,
            index: index,
            ciphertext: objects[resolved.chunks[index].objectId]!,
          );
          try {
            restored.add(clear);
          } finally {
            clear.fillRange(0, clear.length, 0);
          }
        }
        final restoredBytes = restored.takeBytes();
        expect(restoredBytes, plaintext);
        expect(
          await _sha256ForTest(restoredBytes),
          manifest['plaintext_sha256'],
        );
        restoredBytes.fillRange(0, restoredBytes.length, 0);
      } finally {
        resolved.clearSecrets();
        descriptor.clearSecrets();
        plaintext.fillRange(0, plaintext.length, 0);
        for (final bytes in objects.values) {
          bytes.fillRange(0, bytes.length, 0);
        }
      }

      // The checked v1 vector above and this parse assertion pin v1's writer and
      // parser independently from the new v2 dispatch API.
      final legacy = await crypto.encrypt(
        fileName: 'legacy.txt',
        mediaType: 'text/plain',
        bytes: Uint8List.fromList('v1'.codeUnits),
      );
      expect(legacy.manifestEntry['format'], hostAttachmentFormat);
      expect(legacy.manifestEntry['version'], 1);
      final parsedLegacy = HostAttachmentManifestEntry.parse(
        legacy.manifestEntry,
      );
      expect(parsedLegacy.totalSize, 2);
      parsedLegacy.clearKey();
      for (final chunk in parsedLegacy.chunks) {
        chunk.clearNonce();
      }
      expect(
        () => HostAttachmentManifestEntry.parse(manifest),
        throwsA(isA<FormatException>()),
      );
      legacy.clearCiphertext();
    },
  );

  test(
    'v2 parser rejects unknown, oversized and inconsistent descriptors',
    () async {
      final manifest = await crypto.encryptSourceForTransferV2(
        fileName: 'strict.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: 1,
          stream: Stream<List<int>>.value(Uint8List.fromList([9])),
        ),
        onStart: (_) async {},
        onObject: (_) async {},
      );

      final unknownVersion = Map<String, Object?>.from(manifest)
        ..['version'] = 3;
      final extraField = Map<String, Object?>.from(manifest)
        ..['chunks'] = const [];
      final oversized = Map<String, Object?>.from(manifest)
        ..['total_size'] = hostAttachmentV2MaxBytes + 1;
      final wrongCount = Map<String, Object?>.from(manifest)
        ..['chunk_count'] = 2;
      final nonCanonicalNonce = Map<String, Object?>.from(manifest)
        ..['manifest_nonce'] = '${manifest['manifest_nonce']}=';
      final oversizedDirectory = Map<String, Object?>.from(manifest)
        ..['manifest_ciphertext_size'] = 256 * 1024 + 1;
      final duplicateId = Map<String, Object?>.from(manifest)
        ..['chunk_object_ids'] = [manifest['manifest_object_id']];

      for (final invalid in [
        unknownVersion,
        extraField,
        oversized,
        wrongCount,
        nonCanonicalNonce,
        oversizedDirectory,
        duplicateId,
      ]) {
        expect(
          () => HostAttachmentV2ManifestEntry.parse(invalid),
          throwsA(isA<FormatException>()),
        );
      }
      await expectLater(
        crypto.encryptSourceForTransferV2(
          fileName: 'too-large.bin',
          mediaType: 'application/octet-stream',
          source: StreamAttachmentUploadSource(
            size: hostAttachmentV2MaxBytes + 1,
            stream: const Stream<List<int>>.empty(),
          ),
          onStart: (_) async {},
          onObject: (_) async {},
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'v2 resolution rejects tampered and descriptor-mismatched directories',
    () async {
      final objects = <String, Uint8List>{};
      final manifest = await crypto.encryptSourceForTransferV2(
        fileName: 'tamper.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: 3,
          stream: Stream<List<int>>.value(Uint8List.fromList([1, 2, 3])),
        ),
        onStart: (_) async {},
        onObject: (object) async {
          objects[object.objectId] = Uint8List.fromList(object.bytes);
        },
      );
      final descriptor = HostAttachmentV2ManifestEntry.parse(manifest);
      final directory = objects[descriptor.manifestObjectId]!;
      final tamperedDirectory = Uint8List.fromList(directory)..[0] ^= 0x80;
      final tamperedWithMatchingHash = Map<String, Object?>.from(manifest)
        ..['manifest_ciphertext_sha256'] = await _sha256ForTest(
          tamperedDirectory,
        );
      final wrongChunkIds = Map<String, Object?>.from(manifest)
        ..['chunk_object_ids'] = const <String>[]
        ..['chunk_count'] = 0;

      try {
        await expectLater(
          crypto.resolveV2Manifest(
            manifestEntry: manifest,
            manifestCiphertext: tamperedDirectory,
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          crypto.resolveV2Manifest(
            manifestEntry: tamperedWithMatchingHash,
            manifestCiphertext: tamperedDirectory,
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          crypto.resolveV2Manifest(
            manifestEntry: wrongChunkIds,
            manifestCiphertext: directory,
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        descriptor.clearSecrets();
        tamperedDirectory.fillRange(0, tamperedDirectory.length, 0);
        for (final bytes in objects.values) {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
    },
  );

  test(
    'streams the maximum 1 GiB v2 source without a file-sized allocation',
    () async {
      const totalSize = hostAttachmentV2MaxBytes;
      final digest = cryptography.Sha256().toSync().newHashSink();
      var activeSourceBytes = 0;
      var maxActiveSourceBytes = 0;
      var sourceBytesRead = 0;
      var dataObjectCount = 0;
      var directoryObjectCount = 0;
      var maxObjectBytes = 0;

      Stream<Uint8List> virtualChunks() async* {
        for (var offset = 0; offset < totalSize; offset += 1024 * 1024) {
          const length = 1024 * 1024;
          final part = Uint8List(length);
          for (var index = 0; index < length; index++) {
            part[index] = ((offset + index) * 19 + 23) & 0xff;
          }
          digest.add(part);
          sourceBytesRead += part.length;
          activeSourceBytes += part.length;
          if (activeSourceBytes > maxActiveSourceBytes) {
            maxActiveSourceBytes = activeSourceBytes;
          }
          yield part;
          activeSourceBytes -= part.length;
          part.fillRange(0, part.length, 0);
        }
      }

      final manifest = await crypto.encryptSourceForTransferV2(
        fileName: 'virtual-one-gib.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: totalSize,
          stream: virtualChunks(),
        ),
        onStart: (_) async {},
        onObject: (object) async {
          if (object.bytes.length == hostAttachmentLogicalChunkBytes + 16) {
            dataObjectCount++;
          } else {
            directoryObjectCount++;
          }
          if (object.bytes.length > maxObjectBytes) {
            maxObjectBytes = object.bytes.length;
          }
          expect(
            object.bytes.length,
            lessThanOrEqualTo(hostAttachmentLogicalChunkBytes + 16),
          );
          await Future<void>.delayed(Duration.zero);
        },
      );

      digest.close();
      final expectedDigest = (await digest.hash()).bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final parsed = HostAttachmentV2ManifestEntry.parse(manifest);
      expect(sourceBytesRead, totalSize);
      expect(maxActiveSourceBytes, 1024 * 1024);
      expect(activeSourceBytes, 0);
      expect(dataObjectCount, hostAttachmentV2MaxChunks);
      expect(directoryObjectCount, 1);
      expect(maxObjectBytes, hostAttachmentLogicalChunkBytes + 16);
      expect(manifest['total_size'], totalSize);
      expect(manifest['chunk_count'], hostAttachmentV2MaxChunks);
      expect(
        manifest['chunk_object_ids'],
        hasLength(hostAttachmentV2MaxChunks),
      );
      expect(manifest['plaintext_sha256'], expectedDigest);
      expect(parsed.objectIds, hasLength(hostAttachmentV2MaxChunks + 1));
      parsed.clearSecrets();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'streams the maximum 256 MiB virtual source with one bounded input event',
    () async {
      const totalSize = hostAttachmentMaxBytes;
      final digest = cryptography.Sha256().toSync().newHashSink();
      var activeSourceBytes = 0;
      var maxActiveSourceBytes = 0;
      var sourceBytesRead = 0;
      var objectCount = 0;
      var maxConcurrentObjectCallbacks = 0;
      var activeObjectCallbacks = 0;

      Stream<Uint8List> virtualChunks() async* {
        for (var offset = 0; offset < totalSize; offset += 1024 * 1024) {
          final length = (totalSize - offset) < 1024 * 1024
              ? totalSize - offset
              : 1024 * 1024;
          final part = Uint8List(length);
          for (var index = 0; index < length; index++) {
            part[index] = ((offset + index) * 31 + 17) & 0xff;
          }
          digest.add(part);
          sourceBytesRead += part.length;
          activeSourceBytes += part.length;
          if (activeSourceBytes > maxActiveSourceBytes) {
            maxActiveSourceBytes = activeSourceBytes;
          }
          yield part;
          activeSourceBytes -= part.length;
          part.fillRange(0, part.length, 0);
        }
      }

      final manifest = await crypto.encryptSourceForTransfer(
        fileName: 'virtual-maximum.bin',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: totalSize,
          stream: virtualChunks(),
        ),
        onStart: (_) async {},
        onObject: (object) async {
          activeObjectCallbacks++;
          if (activeObjectCallbacks > maxConcurrentObjectCallbacks) {
            maxConcurrentObjectCallbacks = activeObjectCallbacks;
          }
          expect(object.bytes, hasLength(hostAttachmentLogicalChunkBytes + 16));
          objectCount++;
          await Future<void>.delayed(Duration.zero);
          activeObjectCallbacks--;
        },
      );

      digest.close();
      final expectedDigest = (await digest.hash()).bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(sourceBytesRead, totalSize);
      expect(maxActiveSourceBytes, 1024 * 1024);
      expect(activeSourceBytes, 0);
      expect(maxConcurrentObjectCallbacks, 1);
      expect(objectCount, hostAttachmentMaxChunks);
      expect(manifest['total_size'], totalSize);
      expect(manifest['chunks'], hasLength(hostAttachmentMaxChunks));
      expect(manifest['plaintext_sha256'], expectedDigest);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('encrypts and restores a multi-chunk file', () async {
    final plaintext = Uint8List.fromList(
      List<int>.generate(
        hostAttachmentLogicalChunkBytes + 137,
        (index) => (index * 31 + 17) & 0xff,
      ),
    );
    final encrypted = await crypto.encrypt(
      fileName: 'diagnostic.txt',
      mediaType: 'text/plain',
      bytes: plaintext,
    );
    final manifest = encrypted.manifestEntry;
    final chunks = manifest['chunks']! as List;
    expect(chunks, hasLength(2));
    expect(manifest['file_name'], 'diagnostic.txt');
    expect(manifest['media_type'], 'text/plain');
    expect(
      (chunks.first as Map)['ciphertext_size'],
      hostAttachmentLogicalChunkBytes + 16,
    );

    final objects = {
      for (final object in encrypted.objects) object.objectId: object.bytes,
    };
    final restored = await crypto.decrypt(
      manifestEntry: manifest,
      ciphertextObjects: objects,
    );
    expect(restored, plaintext);
    restored.fillRange(0, restored.length, 0);
    plaintext.fillRange(0, plaintext.length, 0);
    encrypted.clearCiphertext();
  });

  test(
    'stream preserves empty files and rejects inaccurate source lengths',
    () async {
      var objectCount = 0;
      final emptyManifest = await crypto.encryptSourceForTransfer(
        fileName: 'empty.dat',
        mediaType: 'application/octet-stream',
        source: StreamAttachmentUploadSource(
          size: 0,
          stream: const Stream<List<int>>.empty(),
        ),
        onStart: (_) async {},
        onObject: (_) async {
          objectCount++;
        },
      );
      expect(emptyManifest['total_size'], 0);
      expect(
        emptyManifest['plaintext_sha256'],
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(emptyManifest['chunks'], isEmpty);
      expect(objectCount, 0);

      await expectLater(
        crypto.encryptSourceForTransfer(
          fileName: 'truncated.dat',
          mediaType: 'application/octet-stream',
          source: StreamAttachmentUploadSource(
            size: 2,
            stream: Stream<List<int>>.value(Uint8List.fromList([1])),
          ),
          onStart: (_) async {},
          onObject: (_) async {},
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        crypto.encryptSourceForTransfer(
          fileName: 'long.dat',
          mediaType: 'application/octet-stream',
          source: StreamAttachmentUploadSource(
            size: 1,
            stream: Stream<List<int>>.value(Uint8List.fromList([1, 2])),
          ),
          onStart: (_) async {},
          onObject: (_) async {},
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('rejects attachment names with control characters', () async {
    await expectLater(
      crypto.encrypt(
        fileName: 'notes\nhidden.txt',
        mediaType: 'text/plain',
        bytes: const [],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'rejects ciphertext tampering, reordered chunks and truncation',
    () async {
      final plaintext = Uint8List.fromList(
        List<int>.generate(
          hostAttachmentLogicalChunkBytes + 11,
          (index) => (index * 7 + 91) & 0xff,
        ),
      );
      final encrypted = await crypto.encrypt(
        fileName: 'bundle.bin',
        mediaType: 'application/octet-stream',
        bytes: plaintext,
      );
      final manifest = encrypted.manifestEntry;
      final ciphertextObjects = {
        for (final object in encrypted.objects) object.objectId: object.bytes,
      };

      final first = encrypted.objects.first;
      final tamperedBytes = Uint8List.fromList(first.bytes)..[4] ^= 0x80;
      await expectLater(
        crypto.decrypt(
          manifestEntry: manifest,
          ciphertextObjects: {
            ...ciphertextObjects,
            first.objectId: tamperedBytes,
          },
        ),
        throwsA(isA<FormatException>()),
      );

      final reorderedManifest = Map<String, Object?>.from(manifest)
        ..['chunks'] = (manifest['chunks']! as List).reversed.toList();
      await expectLater(
        crypto.decrypt(
          manifestEntry: reorderedManifest,
          ciphertextObjects: ciphertextObjects,
        ),
        throwsA(isA<FormatException>()),
      );

      final truncatedObjects = Map<String, Uint8List>.from(ciphertextObjects)
        ..[first.objectId] = Uint8List.sublistView(
          first.bytes,
          0,
          first.bytes.length - 1,
        );
      await expectLater(
        crypto.decrypt(
          manifestEntry: manifest,
          ciphertextObjects: truncatedObjects,
        ),
        throwsA(isA<FormatException>()),
      );

      final truncatedManifest = Map<String, Object?>.from(manifest)
        ..['chunks'] = (manifest['chunks']! as List).take(1).toList();
      await expectLater(
        crypto.decrypt(
          manifestEntry: truncatedManifest,
          ciphertextObjects: ciphertextObjects,
        ),
        throwsA(isA<FormatException>()),
      );

      tamperedBytes.fillRange(0, tamperedBytes.length, 0);
      plaintext.fillRange(0, plaintext.length, 0);
      encrypted.clearCiphertext();
    },
  );
}

Future<String> _sha256ForTest(List<int> bytes) async =>
    (await cryptography.Sha256().hash(
      bytes,
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
