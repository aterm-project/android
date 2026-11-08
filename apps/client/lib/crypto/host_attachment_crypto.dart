import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import '../attachments/attachment_upload_source.dart';
import 'jcs.dart';

export '../attachments/attachment_upload_source.dart'
    show hostAttachmentLogicalChunkBytes;
import '../l10n/l10n.dart';

const hostAttachmentMaxBytes = 256 * 1024 * 1024;
const hostAttachmentMaxChunks =
    hostAttachmentMaxBytes ~/ hostAttachmentLogicalChunkBytes;
const hostAttachmentFormat = 'atermius-host-attachment-v1';
const hostAttachmentV2MaxBytes = 1024 * 1024 * 1024;
const hostAttachmentV2MaxChunks =
    hostAttachmentV2MaxBytes ~/ hostAttachmentLogicalChunkBytes;
const hostAttachmentV2Format = 'atermius-host-attachment-v2';
const hostAttachmentV2DirectoryFormat = 'atermius-host-attachment-directory-v2';
const _hostAttachmentV2MaxDirectoryCiphertextBytes = 256 * 1024;

const _uuid = Uuid();
final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
final _hkdf = cryptography.Hkdf(
  hmac: cryptography.Hmac.sha256(),
  outputLength: 32,
);
final _aesGcm = cryptography.AesGcm.with256bits();

String _encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decodeBase64Url(String text, {required int length}) {
  try {
    final bytes = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(text)),
    );
    if (bytes.length != length || _encodeBase64Url(bytes) != text) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException('Invalid encoded attachment field.');
    }
    return bytes;
  } on FormatException {
    throw const FormatException('Invalid encoded attachment field.');
  }
}

Future<String> _digestHex(List<int> bytes) async =>
    (await cryptography.Sha256().hash(
      bytes,
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void _wipeIfMutable(List<int> bytes) {
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Some cryptography implementations may return immutable byte views.
  }
}

class EncryptedAttachmentObject {
  const EncryptedAttachmentObject({
    required this.objectId,
    required this.bytes,
    required this.sha256,
  });

  final String objectId;
  final Uint8List bytes;
  final String sha256;
}

class EncryptedHostAttachment {
  const EncryptedHostAttachment({
    required this.manifestEntry,
    required this.objects,
  });

  final Map<String, Object?> manifestEntry;
  final List<EncryptedAttachmentObject> objects;

  void clearCiphertext() {
    for (final object in objects) {
      object.bytes.fillRange(0, object.bytes.length, 0);
    }
  }
}

/// Strict parsed attachment metadata stored inside the encrypted HostRecord.
/// No field from this value is sent to the server except referenced object IDs.
class HostAttachmentManifestEntry {
  const HostAttachmentManifestEntry({
    required this.blobId,
    required this.fileName,
    required this.mediaType,
    required this.totalSize,
    required this.plaintextSha256,
    required this.blobKey,
    required this.chunks,
    required this.raw,
  });

  final String blobId;
  final String fileName;
  final String mediaType;
  final int totalSize;
  final String plaintextSha256;
  final Uint8List blobKey;
  final List<HostAttachmentChunk> chunks;
  final Map<String, Object?> raw;

  List<String> get objectIds =>
      chunks.map((chunk) => chunk.objectId).toList(growable: false);

  void clearKey() => blobKey.fillRange(0, blobKey.length, 0);

  factory HostAttachmentManifestEntry.parse(Object? value) {
    if (value is! Map) {
      throw FormatException(currentL10n.invalidAttachmentManifestEntryFormat);
    }
    final raw = Map<String, Object?>.from(value);
    const fields = {
      'format',
      'version',
      'blob_id',
      'file_name',
      'media_type',
      'total_size',
      'plaintext_sha256',
      'compression',
      'blob_key',
      'chunks',
    };
    if (raw.keys.toSet().difference(fields).isNotEmpty ||
        !raw.keys.toSet().containsAll(fields) ||
        raw['format'] != hostAttachmentFormat ||
        raw['version'] != 1 ||
        raw['compression'] != 'none') {
      throw FormatException(currentL10n.unsupportedAttachmentManifestFormat);
    }
    final blobId = raw['blob_id'];
    final fileName = raw['file_name'];
    final mediaType = raw['media_type'];
    final totalSize = raw['total_size'];
    final plaintextSha256 = raw['plaintext_sha256'];
    final encodedKey = raw['blob_key'];
    final rawChunks = raw['chunks'];
    if (blobId is! String || !_canonicalUuid.hasMatch(blobId)) {
      throw FormatException(currentL10n.invalidAttachmentBlobIdFormat);
    }
    if (fileName is! String || !_validFileName(fileName)) {
      throw FormatException(currentL10n.invalidAttachmentFileNameFormat);
    }
    if (mediaType is! String || !_validMediaType(mediaType)) {
      throw FormatException(currentL10n.invalidAttachmentMimeTypeFormat);
    }
    if (totalSize is! int ||
        totalSize < 0 ||
        totalSize > hostAttachmentMaxBytes) {
      throw FormatException(currentL10n.theAttachmentSizeIsOutsideThe);
    }
    if (plaintextSha256 is! String || !_sha256Hex.hasMatch(plaintextSha256)) {
      throw FormatException(currentL10n.invalidAttachmentPlaintextDigestFormat);
    }
    if (encodedKey is! String) {
      throw FormatException(currentL10n.invalidAttachmentKeyFormat);
    }
    final blobKey = _decodeBase64Url(encodedKey, length: 32);
    if (rawChunks is! List) {
      blobKey.fillRange(0, blobKey.length, 0);
      throw FormatException(currentL10n.invalidAttachmentBlockManifestFormat);
    }
    final expectedChunkCount =
        (totalSize + hostAttachmentLogicalChunkBytes - 1) ~/
        hostAttachmentLogicalChunkBytes;
    if (rawChunks.length != expectedChunkCount ||
        rawChunks.length > hostAttachmentMaxChunks) {
      blobKey.fillRange(0, blobKey.length, 0);
      throw FormatException(currentL10n.theAttachmentBlockCountDoesntMatch);
    }
    final chunks = <HostAttachmentChunk>[];
    final seenIds = <String>{};
    final seenNonces = <String>{};
    try {
      for (var index = 0; index < rawChunks.length; index++) {
        final chunk = HostAttachmentChunk.parse(rawChunks[index]);
        final expectedPlainSize = totalSize == 0
            ? 0
            : index == rawChunks.length - 1
            ? totalSize - index * hostAttachmentLogicalChunkBytes
            : hostAttachmentLogicalChunkBytes;
        if (chunk.index != index ||
            chunk.plaintextSize != expectedPlainSize ||
            chunk.ciphertextSize != expectedPlainSize + 16 ||
            !seenIds.add(chunk.objectId) ||
            !seenNonces.add(chunk.nonceText)) {
          chunk.clearNonce();
          throw FormatException(currentL10n.attachmentBlockOrderLengthOrUniqueness);
        }
        chunks.add(chunk);
      }
      return HostAttachmentManifestEntry(
        blobId: blobId,
        fileName: fileName,
        mediaType: mediaType,
        totalSize: totalSize,
        plaintextSha256: plaintextSha256,
        blobKey: blobKey,
        chunks: List.unmodifiable(chunks),
        raw: raw,
      );
    } catch (_) {
      for (final chunk in chunks) {
        chunk.clearNonce();
      }
      blobKey.fillRange(0, blobKey.length, 0);
      rethrow;
    }
  }
}

class HostAttachmentChunk {
  const HostAttachmentChunk({
    required this.objectId,
    required this.index,
    required this.plaintextSize,
    required this.ciphertextSize,
    required this.sha256,
    required this.nonceText,
    required this.nonce,
  });

  final String objectId;
  final int index;
  final int plaintextSize;
  final int ciphertextSize;
  final String sha256;
  final String nonceText;
  final Uint8List nonce;

  void clearNonce() => nonce.fillRange(0, nonce.length, 0);

  factory HostAttachmentChunk.parse(Object? value) {
    if (value is! Map) {
      throw FormatException(currentL10n.invalidAttachmentBlockEntryFormat);
    }
    final raw = Map<String, Object?>.from(value);
    const fields = {
      'object_id',
      'index',
      'plaintext_size',
      'ciphertext_size',
      'sha256',
      'nonce',
    };
    final objectId = raw['object_id'];
    final index = raw['index'];
    final plaintextSize = raw['plaintext_size'];
    final ciphertextSize = raw['ciphertext_size'];
    final sha256 = raw['sha256'];
    final nonceText = raw['nonce'];
    if (raw.keys.toSet().difference(fields).isNotEmpty ||
        !raw.keys.toSet().containsAll(fields) ||
        objectId is! String ||
        !_canonicalUuid.hasMatch(objectId) ||
        index is! int ||
        index < 0 ||
        plaintextSize is! int ||
        plaintextSize < 0 ||
        ciphertextSize is! int ||
        sha256 is! String ||
        !_sha256Hex.hasMatch(sha256) ||
        nonceText is! String) {
      throw FormatException(currentL10n.invalidAttachmentBlockFieldFormat);
    }
    final nonce = _decodeBase64Url(nonceText, length: 12);
    return HostAttachmentChunk(
      objectId: objectId,
      index: index,
      plaintextSize: plaintextSize,
      ciphertextSize: ciphertextSize,
      sha256: sha256,
      nonceText: nonceText,
      nonce: nonce,
    );
  }
}

/// Strict compact v2 descriptor stored inside the encrypted HostRecord.
/// Chunk metadata lives in the encrypted directory object; this descriptor
/// retains the IDs needed for the record's authenticated object reference set.
class HostAttachmentV2ManifestEntry {
  const HostAttachmentV2ManifestEntry({
    required this.blobId,
    required this.fileName,
    required this.mediaType,
    required this.totalSize,
    required this.plaintextSha256,
    required this.blobKey,
    required this.manifestObjectId,
    required this.manifestNonceText,
    required this.manifestNonce,
    required this.manifestCiphertextSize,
    required this.manifestCiphertextSha256,
    required this.chunkObjectIds,
    required this.raw,
  });

  final String blobId;
  final String fileName;
  final String mediaType;
  final int totalSize;
  final String plaintextSha256;
  final Uint8List blobKey;
  final String manifestObjectId;
  final String manifestNonceText;
  final Uint8List manifestNonce;
  final int manifestCiphertextSize;
  final String manifestCiphertextSha256;
  final List<String> chunkObjectIds;
  final Map<String, Object?> raw;

  int get chunkCount => chunkObjectIds.length;

  /// Directory object first, followed by the ordered encrypted data objects.
  List<String> get objectIds =>
      List.unmodifiable([manifestObjectId, ...chunkObjectIds]);

  void clearSecrets() {
    blobKey.fillRange(0, blobKey.length, 0);
    manifestNonce.fillRange(0, manifestNonce.length, 0);
  }

  factory HostAttachmentV2ManifestEntry.parse(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException(currentL10n.invalidAttachmentManifestEntryFormat);
    }
    final raw = Map<String, Object?>.from(value);
    const fields = {
      'format',
      'version',
      'blob_id',
      'file_name',
      'media_type',
      'total_size',
      'plaintext_sha256',
      'compression',
      'blob_key',
      'manifest_object_id',
      'manifest_nonce',
      'manifest_ciphertext_size',
      'manifest_ciphertext_sha256',
      'chunk_object_ids',
      'chunk_count',
    };
    if (raw.keys.toSet().difference(fields).isNotEmpty ||
        !raw.keys.toSet().containsAll(fields) ||
        raw['format'] != hostAttachmentV2Format ||
        raw['version'] != 2 ||
        raw['compression'] != 'none') {
      throw FormatException(currentL10n.unsupportedAttachmentManifestFormat);
    }

    final blobId = raw['blob_id'];
    final fileName = raw['file_name'];
    final mediaType = raw['media_type'];
    final totalSize = raw['total_size'];
    final plaintextSha256 = raw['plaintext_sha256'];
    final encodedKey = raw['blob_key'];
    final manifestObjectId = raw['manifest_object_id'];
    final manifestNonceText = raw['manifest_nonce'];
    final manifestCiphertextSize = raw['manifest_ciphertext_size'];
    final manifestCiphertextSha256 = raw['manifest_ciphertext_sha256'];
    final rawChunkObjectIds = raw['chunk_object_ids'];
    final chunkCount = raw['chunk_count'];
    if (blobId is! String || !_canonicalUuid.hasMatch(blobId)) {
      throw FormatException(currentL10n.invalidAttachmentBlobIdFormat);
    }
    if (fileName is! String || !_validFileName(fileName)) {
      throw FormatException(currentL10n.invalidAttachmentFileNameFormat);
    }
    if (mediaType is! String || !_validMediaType(mediaType)) {
      throw FormatException(currentL10n.invalidAttachmentMimeTypeFormat);
    }
    if (totalSize is! int ||
        totalSize < 0 ||
        totalSize > hostAttachmentV2MaxBytes) {
      throw FormatException(currentL10n.theAttachmentSizeIsOutsideThe);
    }
    if (plaintextSha256 is! String || !_sha256Hex.hasMatch(plaintextSha256)) {
      throw FormatException(currentL10n.invalidAttachmentPlaintextDigestFormat);
    }
    if (encodedKey is! String || encodedKey.length != 43) {
      throw FormatException(currentL10n.invalidAttachmentKeyFormat);
    }
    if (manifestObjectId is! String ||
        !_canonicalUuid.hasMatch(manifestObjectId)) {
      throw FormatException(currentL10n.invalidAttachmentDirectoryObjectIdFormat);
    }
    if (manifestNonceText is! String || manifestNonceText.length != 16) {
      throw FormatException(currentL10n.invalidAttachmentDirectoryNonceFormat);
    }
    if (manifestCiphertextSize is! int ||
        manifestCiphertextSize < 16 ||
        manifestCiphertextSize > _hostAttachmentV2MaxDirectoryCiphertextBytes) {
      throw FormatException(currentL10n.invalidAttachmentDirectoryCiphertextSize);
    }
    if (manifestCiphertextSha256 is! String ||
        !_sha256Hex.hasMatch(manifestCiphertextSha256)) {
      throw FormatException(currentL10n.invalidAttachmentDirectoryDigestFormat);
    }
    if (rawChunkObjectIds is! List ||
        chunkCount is! int ||
        chunkCount < 0 ||
        chunkCount > hostAttachmentV2MaxChunks ||
        rawChunkObjectIds.length != chunkCount) {
      throw FormatException(currentL10n.invalidAttachmentBlockCount);
    }

    final expectedChunkCount =
        (totalSize + hostAttachmentLogicalChunkBytes - 1) ~/
        hostAttachmentLogicalChunkBytes;
    if (chunkCount != expectedChunkCount ||
        chunkCount > hostAttachmentV2MaxChunks) {
      throw FormatException(currentL10n.theAttachmentBlockCountDoesntMatch);
    }

    final blobKey = _decodeBase64Url(encodedKey, length: 32);
    Uint8List? manifestNonce;
    try {
      manifestNonce = _decodeBase64Url(manifestNonceText, length: 12);
      final chunkObjectIds = <String>[];
      final seenIds = <String>{manifestObjectId};
      for (final rawId in rawChunkObjectIds) {
        if (rawId is! String ||
            !_canonicalUuid.hasMatch(rawId) ||
            !seenIds.add(rawId)) {
          throw FormatException(currentL10n.theAttachmentObjectIdIsInvalid);
        }
        chunkObjectIds.add(rawId);
      }
      return HostAttachmentV2ManifestEntry(
        blobId: blobId,
        fileName: fileName,
        mediaType: mediaType,
        totalSize: totalSize,
        plaintextSha256: plaintextSha256,
        blobKey: blobKey,
        manifestObjectId: manifestObjectId,
        manifestNonceText: manifestNonceText,
        manifestNonce: manifestNonce,
        manifestCiphertextSize: manifestCiphertextSize,
        manifestCiphertextSha256: manifestCiphertextSha256,
        chunkObjectIds: List.unmodifiable(chunkObjectIds),
        raw: raw,
      );
    } catch (_) {
      blobKey.fillRange(0, blobKey.length, 0);
      manifestNonce?.fillRange(0, manifestNonce.length, 0);
      rethrow;
    }
  }
}

/// A v2 descriptor paired with its authenticated, decrypted chunk directory.
class ResolvedHostAttachmentV2 {
  ResolvedHostAttachmentV2._({required this.descriptor, required this.chunks});

  final HostAttachmentV2ManifestEntry descriptor;
  final List<HostAttachmentChunk> chunks;

  void clearSecrets() {
    descriptor.clearSecrets();
    for (final chunk in chunks) {
      chunk.clearNonce();
    }
  }
}

class HostAttachmentCrypto {
  HostAttachmentCrypto({required this.randomBytes}) : _uuidGenerator = _uuid.v4;

  @visibleForTesting
  HostAttachmentCrypto.withUuidGenerator({
    required this.randomBytes,
    required String Function() uuidGenerator,
  }) : _uuidGenerator = uuidGenerator;

  final Uint8List Function(int count) randomBytes;
  final String Function() _uuidGenerator;

  Future<EncryptedHostAttachment> encrypt({
    required String fileName,
    required String mediaType,
    required List<int> bytes,
  }) => _encryptSource(
    fileName: fileName,
    mediaType: mediaType,
    source: MemoryAttachmentUploadSource(bytes),
  );

  /// Encrypts with the v1 format while yielding each opaque object immediately
  /// to durable local staging. This avoids retaining the entire ciphertext
  /// bundle in memory during large transfers.
  Future<Map<String, Object?>> encryptForTransfer({
    required String fileName,
    required String mediaType,
    required List<int> bytes,
    required Future<void> Function(String blobId) onStart,
    required Future<void> Function(EncryptedAttachmentObject object) onObject,
  }) => encryptSourceForTransfer(
    fileName: fileName,
    mediaType: mediaType,
    source: MemoryAttachmentUploadSource(bytes),
    onStart: onStart,
    onObject: onObject,
  );

  /// Encrypts a file stream one v1 logical chunk at a time. The stream is
  /// consumed with back-pressure; no full plaintext or ciphertext bundle is
  /// retained. Source events must themselves be bounded to a logical chunk.
  Future<Map<String, Object?>> encryptSourceForTransfer({
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
    required Future<void> Function(String blobId) onStart,
    required Future<void> Function(EncryptedAttachmentObject object) onObject,
  }) async {
    final encrypted = await _encryptSource(
      fileName: fileName,
      mediaType: mediaType,
      source: source,
      onStart: onStart,
      onObject: onObject,
    );
    return encrypted.manifestEntry;
  }

  /// Encrypts a v2 attachment as one bounded data object per 4 MiB plaintext
  /// chunk, plus a compact encrypted directory object. This API is deliberately
  /// separate from the v1 writer; callers must capability-gate its use.
  Future<Map<String, Object?>> encryptSourceForTransferV2({
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
    required Future<void> Function(String blobId) onStart,
    required Future<void> Function(EncryptedAttachmentObject object) onObject,
  }) => _encryptV2Source(
    fileName: fileName,
    mediaType: mediaType,
    source: source,
    onStart: onStart,
    onObject: onObject,
  );

  Future<Map<String, Object?>> _encryptV2Source({
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
    required Future<void> Function(String blobId) onStart,
    required Future<void> Function(EncryptedAttachmentObject object) onObject,
  }) async {
    if (!_validFileName(fileName) || !_validMediaType(mediaType)) {
      throw FormatException(currentL10n.invalidAttachmentFileNameOrMime);
    }
    final totalSize = source.size;
    if (totalSize < 0 || totalSize > hostAttachmentV2MaxBytes) {
      throw FormatException(currentL10n.theAttachmentExceedsThe1Gib);
    }
    final expectedChunks =
        (totalSize + hostAttachmentLogicalChunkBytes - 1) ~/
        hostAttachmentLogicalChunkBytes;
    if (expectedChunks > hostAttachmentV2MaxChunks) {
      throw FormatException(currentL10n.theNumberOfAttachmentBlocksExceeds);
    }

    final blobId = _uuidGenerator();
    final blobKey = randomBytes(32);
    if (blobKey.length != 32) {
      blobKey.fillRange(0, blobKey.length, 0);
      throw StateError('Secure random source returned an invalid key.');
    }
    final chunks = <Map<String, Object?>>[];
    final chunkObjectIds = <String>[];
    final seenObjectIds = <String>{};
    final seenNonces = <String>{};
    StreamIterator<List<int>>? sourceIterator;
    final plaintextDigest = cryptography.Sha256().toSync().newHashSink();
    List<int>? sourcePart;
    var sourceOffset = 0;
    var emptyParts = 0;

    void releaseSourcePart() {
      final part = sourcePart;
      if (part == null) return;
      source.releaseReadChunk(part);
      sourcePart = null;
      sourceOffset = 0;
    }

    try {
      final activeIterator = StreamIterator<List<int>>(source.openRead());
      sourceIterator = activeIterator;
      await onStart(blobId);
      for (var index = 0; index < expectedChunks; index++) {
        final clearSize =
            totalSize - index * hostAttachmentLogicalChunkBytes <
                hostAttachmentLogicalChunkBytes
            ? totalSize - index * hostAttachmentLogicalChunkBytes
            : hostAttachmentLogicalChunkBytes;
        final clearChunk = Uint8List(clearSize);
        var clearOffset = 0;
        try {
          while (clearOffset < clearSize) {
            var currentPart = sourcePart;
            if (currentPart == null || sourceOffset == currentPart.length) {
              releaseSourcePart();
              if (!await activeIterator.moveNext()) {
                throw FormatException(currentL10n.theAttachmentSourceEndedEarlyIts);
              }
              final nextPart = activeIterator.current;
              if (nextPart.isEmpty) {
                source.releaseReadChunk(nextPart);
                if (++emptyParts > 128) {
                  throw FormatException(currentL10n.theAttachmentSourceReturnsOnlyEmpty);
                }
                continue;
              }
              if (nextPart.length > hostAttachmentLogicalChunkBytes) {
                source.releaseReadChunk(nextPart);
                throw FormatException(currentL10n.anAttachmentSourceBlockExceedsThe);
              }
              emptyParts = 0;
              sourcePart = nextPart;
              currentPart = nextPart;
            }
            final inputPart = currentPart;
            final remaining = clearSize - clearOffset;
            final available = inputPart.length - sourceOffset;
            final count = remaining < available ? remaining : available;
            clearChunk.setRange(
              clearOffset,
              clearOffset + count,
              inputPart,
              sourceOffset,
            );
            plaintextDigest.addSlice(
              inputPart,
              sourceOffset,
              sourceOffset + count,
              false,
            );
            clearOffset += count;
            sourceOffset += count;
            if (sourceOffset == inputPart.length) releaseSourcePart();
          }

          final nonce = randomBytes(12);
          if (nonce.length != 12) {
            nonce.fillRange(0, nonce.length, 0);
            throw StateError('Secure random source returned an invalid nonce.');
          }
          final nonceText = _encodeBase64Url(nonce);
          if (!seenNonces.add(nonceText)) {
            nonce.fillRange(0, nonce.length, 0);
            throw StateError(
              'Secure random source repeated an attachment nonce.',
            );
          }
          final chunkObjectId = _uuidGenerator();
          if (!_canonicalUuid.hasMatch(chunkObjectId) ||
              !seenObjectIds.add(chunkObjectId)) {
            nonce.fillRange(0, nonce.length, 0);
            throw StateError('Secure UUID source repeated an attachment ID.');
          }
          final info = utf8.encode(
            canonicalJson([
              'atermius',
              'host-attachment-chunk',
              2,
              blobId,
              index,
            ]),
          );
          final derived = await _hkdf.deriveKey(
            secretKey: cryptography.SecretKey(blobKey),
            nonce: Uint8List(32),
            info: info,
          );
          final chunkKey = Uint8List.fromList(await derived.extractBytes());
          final aad = utf8.encode(
            canonicalJson({
              'format': hostAttachmentV2Format,
              'version': 2,
              'blob_id': blobId,
              'chunk_index': index,
              'plaintext_size': clearChunk.length,
            }),
          );
          try {
            final sealed = await _aesGcm.encrypt(
              clearChunk,
              secretKey: cryptography.SecretKey(chunkKey),
              nonce: nonce,
              aad: aad,
            );
            final cipherBytes =
                Uint8List(sealed.cipherText.length + sealed.mac.bytes.length)
                  ..setRange(0, sealed.cipherText.length, sealed.cipherText)
                  ..setRange(
                    sealed.cipherText.length,
                    sealed.cipherText.length + sealed.mac.bytes.length,
                    sealed.mac.bytes,
                  );
            try {
              final digest = await _digestHex(cipherBytes);
              await onObject(
                EncryptedAttachmentObject(
                  objectId: chunkObjectId,
                  bytes: cipherBytes,
                  sha256: digest,
                ),
              );
              chunkObjectIds.add(chunkObjectId);
              chunks.add({
                'object_id': chunkObjectId,
                'index': index,
                'plaintext_size': clearChunk.length,
                'ciphertext_size': cipherBytes.length,
                'sha256': digest,
                'nonce': nonceText,
              });
            } finally {
              cipherBytes.fillRange(0, cipherBytes.length, 0);
            }
          } finally {
            chunkKey.fillRange(0, chunkKey.length, 0);
            nonce.fillRange(0, nonce.length, 0);
          }
        } finally {
          clearChunk.fillRange(0, clearChunk.length, 0);
        }
      }

      final finalSourcePart = sourcePart;
      if (finalSourcePart != null && sourceOffset < finalSourcePart.length) {
        throw FormatException(currentL10n.theAttachmentSourceLengthExceedsThe);
      }
      while (await activeIterator.moveNext()) {
        final trailingPart = activeIterator.current;
        if (trailingPart.isNotEmpty) {
          source.releaseReadChunk(trailingPart);
          throw FormatException(currentL10n.theAttachmentSourceLengthExceedsThe);
        }
        source.releaseReadChunk(trailingPart);
        if (++emptyParts > 128) {
          throw FormatException(currentL10n.theAttachmentSourceKeepsReturningEmpty);
        }
      }
      plaintextDigest.close();
      final plaintextSha256 = _hex((await plaintextDigest.hash()).bytes);

      final manifestNonce = randomBytes(12);
      if (manifestNonce.length != 12) {
        manifestNonce.fillRange(0, manifestNonce.length, 0);
        throw StateError('Secure random source returned an invalid nonce.');
      }
      final manifestNonceText = _encodeBase64Url(manifestNonce);
      if (!seenNonces.add(manifestNonceText)) {
        manifestNonce.fillRange(0, manifestNonce.length, 0);
        throw StateError('Secure random source repeated an attachment nonce.');
      }
      final directoryPlaintext = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'format': hostAttachmentV2DirectoryFormat,
            'version': 2,
            'blob_id': blobId,
            'chunks': chunks,
          }),
        ),
      );
      late final Uint8List directoryCiphertext;
      try {
        if (directoryPlaintext.length + 16 >
            _hostAttachmentV2MaxDirectoryCiphertextBytes) {
          throw FormatException(currentL10n.theAttachmentEncryptionDirectoryExceedsThe);
        }
        final directoryKeyData = await _hkdf.deriveKey(
          secretKey: cryptography.SecretKey(blobKey),
          nonce: Uint8List(32),
          info: utf8.encode(
            canonicalJson(['atermius', 'host-attachment-directory', 2, blobId]),
          ),
        );
        final directoryKey = Uint8List.fromList(
          await directoryKeyData.extractBytes(),
        );
        try {
          final sealed = await _aesGcm.encrypt(
            directoryPlaintext,
            secretKey: cryptography.SecretKey(directoryKey),
            nonce: manifestNonce,
            aad: utf8.encode(
              canonicalJson({
                'format': hostAttachmentV2DirectoryFormat,
                'version': 2,
                'blob_id': blobId,
              }),
            ),
          );
          directoryCiphertext =
              Uint8List(sealed.cipherText.length + sealed.mac.bytes.length)
                ..setRange(0, sealed.cipherText.length, sealed.cipherText)
                ..setRange(
                  sealed.cipherText.length,
                  sealed.cipherText.length + sealed.mac.bytes.length,
                  sealed.mac.bytes,
                );
        } finally {
          directoryKey.fillRange(0, directoryKey.length, 0);
        }
      } finally {
        directoryPlaintext.fillRange(0, directoryPlaintext.length, 0);
        manifestNonce.fillRange(0, manifestNonce.length, 0);
      }

      final directoryBytes = directoryCiphertext;
      try {
        final directoryObjectId = _uuidGenerator();
        if (!_canonicalUuid.hasMatch(directoryObjectId) ||
            !seenObjectIds.add(directoryObjectId)) {
          throw StateError('Secure UUID source repeated an attachment ID.');
        }
        final manifest = <String, Object?>{
          'format': hostAttachmentV2Format,
          'version': 2,
          'blob_id': blobId,
          'file_name': fileName,
          'media_type': mediaType,
          'total_size': totalSize,
          'plaintext_sha256': plaintextSha256,
          'compression': 'none',
          'blob_key': _encodeBase64Url(blobKey),
          'manifest_object_id': directoryObjectId,
          'manifest_nonce': manifestNonceText,
          'manifest_ciphertext_size': directoryBytes.length,
          'manifest_ciphertext_sha256': await _digestHex(directoryBytes),
          'chunk_object_ids': chunkObjectIds,
          'chunk_count': chunks.length,
        };
        final parsed = HostAttachmentV2ManifestEntry.parse(manifest);
        parsed.clearSecrets();
        await onObject(
          EncryptedAttachmentObject(
            objectId: directoryObjectId,
            bytes: directoryBytes,
            sha256: manifest['manifest_ciphertext_sha256']! as String,
          ),
        );
        return manifest;
      } finally {
        directoryBytes.fillRange(0, directoryBytes.length, 0);
      }
    } finally {
      await sourceIterator?.cancel();
      releaseSourcePart();
      blobKey.fillRange(0, blobKey.length, 0);
    }
  }

  /// Authenticates and resolves a v2 directory object before any data chunk is
  /// consumed. The returned descriptor owns its decoded key and nonce buffers;
  /// callers must call [ResolvedHostAttachmentV2.clearSecrets] when finished.
  Future<ResolvedHostAttachmentV2> resolveV2Manifest({
    required Object? manifestEntry,
    required Uint8List manifestCiphertext,
  }) async {
    final descriptor = HostAttachmentV2ManifestEntry.parse(manifestEntry);
    final chunks = <HostAttachmentChunk>[];
    Uint8List? directoryKey;
    Uint8List? directoryPlaintext;
    try {
      if (manifestCiphertext.length != descriptor.manifestCiphertextSize ||
          manifestCiphertext.length >
              _hostAttachmentV2MaxDirectoryCiphertextBytes ||
          await _digestHex(manifestCiphertext) !=
              descriptor.manifestCiphertextSha256) {
        throw FormatException(currentL10n.attachmentDirectoryCiphertextDigestOrLength);
      }
      final cipherEnd = manifestCiphertext.length - 16;
      if (cipherEnd < 0) {
        throw FormatException(currentL10n.invalidAttachmentDirectoryCiphertextLength);
      }
      final keyData = await _hkdf.deriveKey(
        secretKey: cryptography.SecretKey(descriptor.blobKey),
        nonce: Uint8List(32),
        info: utf8.encode(
          canonicalJson([
            'atermius',
            'host-attachment-directory',
            2,
            descriptor.blobId,
          ]),
        ),
      );
      directoryKey = Uint8List.fromList(await keyData.extractBytes());
      final decrypted = await _aesGcm.decrypt(
        cryptography.SecretBox(
          manifestCiphertext.sublist(0, cipherEnd),
          nonce: descriptor.manifestNonce,
          mac: cryptography.Mac(manifestCiphertext.sublist(cipherEnd)),
        ),
        secretKey: cryptography.SecretKey(directoryKey),
        aad: utf8.encode(
          canonicalJson({
            'format': hostAttachmentV2DirectoryFormat,
            'version': 2,
            'blob_id': descriptor.blobId,
          }),
        ),
      );
      try {
        directoryPlaintext = Uint8List.fromList(decrypted);
      } finally {
        _wipeIfMutable(decrypted);
      }
      final directoryText = utf8.decode(directoryPlaintext);
      final decoded = jsonDecode(directoryText);
      if (decoded is! Map<String, dynamic> ||
          canonicalJson(decoded) != directoryText ||
          decoded.keys.toSet().difference(const {
            'format',
            'version',
            'blob_id',
            'chunks',
          }).isNotEmpty ||
          !decoded.keys.toSet().containsAll(const {
            'format',
            'version',
            'blob_id',
            'chunks',
          }) ||
          decoded['format'] != hostAttachmentV2DirectoryFormat ||
          decoded['version'] != 2 ||
          decoded['blob_id'] != descriptor.blobId ||
          decoded['chunks'] is! List) {
        throw FormatException(currentL10n.invalidAttachmentEncryptionDirectoryFormat);
      }
      final rawChunks = decoded['chunks']! as List;
      if (rawChunks.length != descriptor.chunkCount) {
        throw FormatException(currentL10n.theAttachmentDirectoryBlockCountDoesnt);
      }
      final seenNonces = <String>{descriptor.manifestNonceText};
      for (var index = 0; index < rawChunks.length; index++) {
        final chunk = HostAttachmentChunk.parse(rawChunks[index]);
        final totalSize = descriptor.totalSize;
        final expectedPlainSize = totalSize == 0
            ? 0
            : index == rawChunks.length - 1
            ? totalSize - index * hostAttachmentLogicalChunkBytes
            : hostAttachmentLogicalChunkBytes;
        if (chunk.index != index ||
            chunk.objectId != descriptor.chunkObjectIds[index] ||
            chunk.plaintextSize != expectedPlainSize ||
            chunk.ciphertextSize != expectedPlainSize + 16 ||
            chunk.ciphertextSize > hostAttachmentLogicalChunkBytes + 16 ||
            !seenNonces.add(chunk.nonceText)) {
          chunk.clearNonce();
          throw FormatException(currentL10n.attachmentDirectoryBlockOrderLengthOr);
        }
        chunks.add(chunk);
      }
      return ResolvedHostAttachmentV2._(
        descriptor: descriptor,
        chunks: List.unmodifiable(chunks),
      );
    } on FormatException {
      descriptor.clearSecrets();
      for (final chunk in chunks) {
        chunk.clearNonce();
      }
      rethrow;
    } catch (_) {
      descriptor.clearSecrets();
      for (final chunk in chunks) {
        chunk.clearNonce();
      }
      throw FormatException(currentL10n.attachmentEncryptionDirectoryAuthenticationOrParsing);
    } finally {
      if (directoryKey != null) {
        directoryKey.fillRange(0, directoryKey.length, 0);
      }
      if (directoryPlaintext != null) {
        directoryPlaintext.fillRange(0, directoryPlaintext.length, 0);
      }
    }
  }

  /// Decrypts and authenticates one v2 data chunk. The caller owns the returned
  /// plaintext and should wipe it after writing it to its bounded sink.
  Future<Uint8List> decryptV2Chunk({
    required ResolvedHostAttachmentV2 attachment,
    required int index,
    required Uint8List ciphertext,
  }) async {
    if (index < 0 || index >= attachment.chunks.length) {
      throw RangeError.index(index, attachment.chunks, 'index');
    }
    final descriptor = attachment.descriptor;
    final chunk = attachment.chunks[index];
    final expectedChunkCount =
        (descriptor.totalSize + hostAttachmentLogicalChunkBytes - 1) ~/
        hostAttachmentLogicalChunkBytes;
    final expectedPlainSize = descriptor.totalSize == 0
        ? 0
        : index == attachment.chunks.length - 1
        ? descriptor.totalSize - index * hostAttachmentLogicalChunkBytes
        : hostAttachmentLogicalChunkBytes;
    if (descriptor.totalSize < 0 ||
        descriptor.totalSize > hostAttachmentV2MaxBytes ||
        attachment.chunks.length > hostAttachmentV2MaxChunks ||
        attachment.chunks.length != expectedChunkCount ||
        chunk.index != index ||
        chunk.plaintextSize != expectedPlainSize ||
        chunk.ciphertextSize != expectedPlainSize + 16 ||
        chunk.ciphertextSize > hostAttachmentLogicalChunkBytes + 16 ||
        descriptor.chunkObjectIds[index] != chunk.objectId ||
        ciphertext.length != chunk.ciphertextSize ||
        await _digestHex(ciphertext) != chunk.sha256) {
      throw FormatException(currentL10n.attachmentCiphertextDigestOrLengthVerification);
    }
    final cipherEnd = ciphertext.length - 16;
    if (cipherEnd < 0) {
      throw FormatException(currentL10n.invalidAttachmentCiphertextLength);
    }
    final keyData = await _hkdf.deriveKey(
      secretKey: cryptography.SecretKey(descriptor.blobKey),
      nonce: Uint8List(32),
      info: utf8.encode(
        canonicalJson([
          'atermius',
          'host-attachment-chunk',
          2,
          descriptor.blobId,
          index,
        ]),
      ),
    );
    final chunkKey = Uint8List.fromList(await keyData.extractBytes());
    Uint8List? clear;
    try {
      final decrypted = await _aesGcm.decrypt(
        cryptography.SecretBox(
          ciphertext.sublist(0, cipherEnd),
          nonce: chunk.nonce,
          mac: cryptography.Mac(ciphertext.sublist(cipherEnd)),
        ),
        secretKey: cryptography.SecretKey(chunkKey),
        aad: utf8.encode(
          canonicalJson({
            'format': hostAttachmentV2Format,
            'version': 2,
            'blob_id': descriptor.blobId,
            'chunk_index': index,
            'plaintext_size': chunk.plaintextSize,
          }),
        ),
      );
      try {
        clear = Uint8List.fromList(decrypted);
      } finally {
        _wipeIfMutable(decrypted);
      }
      if (clear.length != chunk.plaintextSize) {
        throw FormatException(currentL10n.attachmentPlaintextBlockLengthVerificationFailed);
      }
      final result = clear;
      clear = null;
      return result;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException(currentL10n.attachmentBlockAuthenticationFailedTheFile);
    } finally {
      chunkKey.fillRange(0, chunkKey.length, 0);
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<EncryptedHostAttachment> _encryptSource({
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
    Future<void> Function(String blobId)? onStart,
    Future<void> Function(EncryptedAttachmentObject object)? onObject,
  }) async {
    if (!_validFileName(fileName) || !_validMediaType(mediaType)) {
      throw FormatException(currentL10n.invalidAttachmentFileNameOrMime);
    }
    final totalSize = source.size;
    if (totalSize < 0 || totalSize > hostAttachmentMaxBytes) {
      throw FormatException(currentL10n.theAttachmentExceedsThe256Mib);
    }
    final expectedChunks =
        (totalSize + hostAttachmentLogicalChunkBytes - 1) ~/
        hostAttachmentLogicalChunkBytes;
    if (expectedChunks > hostAttachmentMaxChunks) {
      throw FormatException(currentL10n.theNumberOfAttachmentBlocksExceeds2);
    }
    final blobId = _uuidGenerator();
    final blobKey = randomBytes(32);
    if (blobKey.length != 32) {
      blobKey.fillRange(0, blobKey.length, 0);
      throw StateError('Secure random source returned an invalid key.');
    }
    final objectBytes = <EncryptedAttachmentObject>[];
    final chunks = <Map<String, Object?>>[];
    final seenNonces = <String>{};
    StreamIterator<List<int>>? sourceIterator;
    // Sha256.newHashSink() on the browser implementation falls back to a
    // buffering generic sink. Use the package's incremental Dart sink so
    // plaintext hashing remains bounded on every platform.
    final plaintextDigest = cryptography.Sha256().toSync().newHashSink();
    List<int>? sourcePart;
    var sourceOffset = 0;
    var emptyParts = 0;

    void releaseSourcePart() {
      final part = sourcePart;
      if (part == null) return;
      source.releaseReadChunk(part);
      sourcePart = null;
      sourceOffset = 0;
    }

    try {
      final activeIterator = StreamIterator<List<int>>(source.openRead());
      sourceIterator = activeIterator;
      await onStart?.call(blobId);
      for (var index = 0; index < expectedChunks; index++) {
        final clearSize =
            totalSize - index * hostAttachmentLogicalChunkBytes <
                hostAttachmentLogicalChunkBytes
            ? totalSize - index * hostAttachmentLogicalChunkBytes
            : hostAttachmentLogicalChunkBytes;
        final clearChunk = Uint8List(clearSize);
        var clearOffset = 0;
        try {
          while (clearOffset < clearSize) {
            var currentPart = sourcePart;
            if (currentPart == null || sourceOffset == currentPart.length) {
              releaseSourcePart();
              if (!await activeIterator.moveNext()) {
                throw FormatException(currentL10n.theAttachmentSourceEndedEarlyIts);
              }
              final nextPart = activeIterator.current;
              if (nextPart.isEmpty) {
                source.releaseReadChunk(nextPart);
                if (++emptyParts > 128) {
                  throw FormatException(currentL10n.theAttachmentSourceReturnsOnlyEmpty);
                }
                continue;
              }
              if (nextPart.length > hostAttachmentLogicalChunkBytes) {
                source.releaseReadChunk(nextPart);
                throw FormatException(currentL10n.anAttachmentSourceBlockExceedsThe);
              }
              emptyParts = 0;
              sourcePart = nextPart;
              currentPart = nextPart;
            }
            final inputPart = currentPart;
            final remaining = clearSize - clearOffset;
            final available = inputPart.length - sourceOffset;
            final count = remaining < available ? remaining : available;
            clearChunk.setRange(
              clearOffset,
              clearOffset + count,
              inputPart,
              sourceOffset,
            );
            plaintextDigest.addSlice(
              inputPart,
              sourceOffset,
              sourceOffset + count,
              false,
            );
            clearOffset += count;
            sourceOffset += count;
            if (sourceOffset == inputPart.length) releaseSourcePart();
          }

          final nonce = randomBytes(12);
          if (nonce.length != 12) {
            nonce.fillRange(0, nonce.length, 0);
            throw StateError('Secure random source returned an invalid nonce.');
          }
          final nonceText = _encodeBase64Url(nonce);
          if (!seenNonces.add(nonceText)) {
            nonce.fillRange(0, nonce.length, 0);
            throw StateError(
              'Secure random source repeated an attachment nonce.',
            );
          }
          final info = utf8.encode(
            canonicalJson([
              'atermius',
              'host-attachment-chunk',
              1,
              blobId,
              index,
            ]),
          );
          final derived = await _hkdf.deriveKey(
            secretKey: cryptography.SecretKey(blobKey),
            nonce: Uint8List(32),
            info: info,
          );
          final chunkKey = Uint8List.fromList(await derived.extractBytes());
          final aad = utf8.encode(
            canonicalJson({
              'format': hostAttachmentFormat,
              'version': 1,
              'blob_id': blobId,
              'chunk_index': index,
              'plaintext_size': clearChunk.length,
            }),
          );
          try {
            final sealed = await _aesGcm.encrypt(
              clearChunk,
              secretKey: cryptography.SecretKey(chunkKey),
              nonce: nonce,
              aad: aad,
            );
            final mac = sealed.mac.bytes;
            final cipherBytes = Uint8List(sealed.cipherText.length + mac.length)
              ..setRange(0, sealed.cipherText.length, sealed.cipherText)
              ..setRange(
                sealed.cipherText.length,
                sealed.cipherText.length + mac.length,
                mac,
              );
            final digest = await _digestHex(cipherBytes);
            final objectId = _uuidGenerator();
            final encryptedObject = EncryptedAttachmentObject(
              objectId: objectId,
              bytes: cipherBytes,
              sha256: digest,
            );
            if (onObject == null) {
              objectBytes.add(encryptedObject);
            } else {
              try {
                await onObject(encryptedObject);
              } finally {
                cipherBytes.fillRange(0, cipherBytes.length, 0);
              }
            }
            chunks.add({
              'object_id': objectId,
              'index': index,
              'plaintext_size': clearChunk.length,
              'ciphertext_size': cipherBytes.length,
              'sha256': digest,
              'nonce': nonceText,
            });
          } finally {
            chunkKey.fillRange(0, chunkKey.length, 0);
            nonce.fillRange(0, nonce.length, 0);
          }
        } finally {
          clearChunk.fillRange(0, clearChunk.length, 0);
        }
      }
      final finalSourcePart = sourcePart;
      if (finalSourcePart != null && sourceOffset < finalSourcePart.length) {
        throw FormatException(currentL10n.theAttachmentSourceLengthExceedsThe);
      }
      // Consume through EOF so a source with an inaccurate reported length
      // cannot silently append or truncate data after the final v1 chunk.
      while (await activeIterator.moveNext()) {
        final trailingPart = activeIterator.current;
        if (trailingPart.isNotEmpty) {
          source.releaseReadChunk(trailingPart);
          throw FormatException(currentL10n.theAttachmentSourceLengthExceedsThe);
        }
        source.releaseReadChunk(trailingPart);
        if (++emptyParts > 128) {
          throw FormatException(currentL10n.theAttachmentSourceKeepsReturningEmpty);
        }
      }
      plaintextDigest.close();
      final manifest = <String, Object?>{
        'format': hostAttachmentFormat,
        'version': 1,
        'blob_id': blobId,
        'file_name': fileName,
        'media_type': mediaType,
        'total_size': totalSize,
        'plaintext_sha256': _hex((await plaintextDigest.hash()).bytes),
        'compression': 'none',
        'blob_key': _encodeBase64Url(blobKey),
        'chunks': chunks,
      };
      // Validate the generated descriptor with the same strict parser used on
      // every later download before returning any uploadable objects.
      final parsed = HostAttachmentManifestEntry.parse(manifest);
      parsed.clearKey();
      for (final chunk in parsed.chunks) {
        chunk.clearNonce();
      }
      return EncryptedHostAttachment(
        manifestEntry: manifest,
        objects: List.unmodifiable(objectBytes),
      );
    } catch (_) {
      for (final object in objectBytes) {
        object.bytes.fillRange(0, object.bytes.length, 0);
      }
      rethrow;
    } finally {
      await sourceIterator?.cancel();
      releaseSourcePart();
      blobKey.fillRange(0, blobKey.length, 0);
    }
  }

  Future<Uint8List> decrypt({
    required Map<String, Object?> manifestEntry,
    required Map<String, Uint8List> ciphertextObjects,
  }) => decryptWithLoader(
    manifestEntry: manifestEntry,
    loadCiphertext: (chunk) {
      final ciphertext = ciphertextObjects[chunk.objectId];
      if (ciphertext == null) {
        throw FormatException(currentL10n.theAttachmentCiphertextObjectIsMissing);
      }
      return Future.value(Uint8List.fromList(ciphertext));
    },
  );

  /// Decrypts and authenticates one existing v1 object at a time. The caller
  /// can fetch each object as bounded HTTP ranges and keep ciphertext storage
  /// outside the live plaintext buffer; the manifest and crypto wire format
  /// are unchanged.
  Future<Uint8List> decryptWithLoader({
    required Map<String, Object?> manifestEntry,
    required Future<Uint8List> Function(HostAttachmentChunk chunk)
    loadCiphertext,
  }) async {
    final attachment = HostAttachmentManifestEntry.parse(manifestEntry);
    try {
      final output = Uint8List(attachment.totalSize);
      var validated = false;
      try {
        var outputOffset = 0;
        for (final chunk in attachment.chunks) {
          final ciphertext = await loadCiphertext(chunk);
          try {
            if (ciphertext.length != chunk.ciphertextSize ||
                await _digestHex(ciphertext) != chunk.sha256) {
              throw FormatException(currentL10n.attachmentCiphertextDigestOrLengthVerification);
            }
            final cipherEnd = ciphertext.length - 16;
            if (cipherEnd < 0) {
              throw FormatException(currentL10n.invalidAttachmentCiphertextLength);
            }
            final info = utf8.encode(
              canonicalJson([
                'atermius',
                'host-attachment-chunk',
                1,
                attachment.blobId,
                chunk.index,
              ]),
            );
            final derived = await _hkdf.deriveKey(
              secretKey: cryptography.SecretKey(attachment.blobKey),
              nonce: Uint8List(32),
              info: info,
            );
            final chunkKey = Uint8List.fromList(await derived.extractBytes());
            final aad = utf8.encode(
              canonicalJson({
                'format': hostAttachmentFormat,
                'version': 1,
                'blob_id': attachment.blobId,
                'chunk_index': chunk.index,
                'plaintext_size': chunk.plaintextSize,
              }),
            );
            try {
              final clear = Uint8List.fromList(
                await _aesGcm.decrypt(
                  cryptography.SecretBox(
                    ciphertext.sublist(0, cipherEnd),
                    nonce: chunk.nonce,
                    mac: cryptography.Mac(ciphertext.sublist(cipherEnd)),
                  ),
                  secretKey: cryptography.SecretKey(chunkKey),
                  aad: aad,
                ),
              );
              try {
                if (clear.length != chunk.plaintextSize ||
                    outputOffset + clear.length > output.length) {
                  throw FormatException(currentL10n.attachmentPlaintextBlockLengthVerificationFailed);
                }
                output.setRange(
                  outputOffset,
                  outputOffset + clear.length,
                  clear,
                );
                outputOffset += clear.length;
              } finally {
                clear.fillRange(0, clear.length, 0);
              }
            } on FormatException {
              rethrow;
            } catch (_) {
              throw FormatException(currentL10n.attachmentBlockAuthenticationFailedTheFile);
            } finally {
              chunkKey.fillRange(0, chunkKey.length, 0);
            }
          } finally {
            ciphertext.fillRange(0, ciphertext.length, 0);
          }
        }
        if (outputOffset != attachment.totalSize ||
            await _digestHex(output) != attachment.plaintextSha256) {
          throw FormatException(currentL10n.attachmentIntegrityOrFinalLengthVerification);
        }
        validated = true;
        return output;
      } finally {
        if (!validated) output.fillRange(0, output.length, 0);
      }
    } finally {
      attachment.clearKey();
      for (final chunk in attachment.chunks) {
        chunk.clearNonce();
      }
    }
  }
}

bool _validFileName(String value) =>
    value.trim().isNotEmpty &&
    value == value.trim() &&
    utf8.encode(value).length <= 255 &&
    !value.contains('/') &&
    !value.contains('\\') &&
    !value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) &&
    value != '.' &&
    value != '..';

bool _validMediaType(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    RegExp(r'^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$').hasMatch(value);
