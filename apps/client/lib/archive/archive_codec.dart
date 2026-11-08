import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../l10n/l10n.dart';

/// Bounded, independently password-protected binary archive container.
///
/// Layout: magic, canonical JCS header length/header, then independently
/// authenticated chunks (plaintext length, random nonce, ciphertext+tag).
/// Every chunk AAD binds the complete immutable header and its position.
class VaultArchiveCodec {
  VaultArchiveCodec(this.sodium);

  static const containerMagic = 'ATVLTAR1';
  static const payloadMagic = 'ATVLTPL1';
  static const formatName = 'atermius-vault-archive';
  static const formatVersion = 1;
  static const chunkSize = 1024 * 1024;
  static const maxPayloadBytes = 128 * 1024 * 1024;
  static const maxContainerBytes = 136 * 1024 * 1024;
  static const maxHeaderBytes = 64 * 1024;
  static const _kdfMemoryKib = 65536;
  static const _kdfIterations = 3;
  static const _kdfParallelism = 1;
  static const _tagLength = 16;

  final SodiumSumo sodium;

  Future<Uint8List> seal({
    required String password,
    required Uint8List payload,
    required String serverSpaceId,
    required String vaultId,
  }) async {
    if (payload.isEmpty || payload.length > maxPayloadBytes) {
      throw FormatException(currentL10n.theArchiveContentExceedsTheSize);
    }
    _requireCanonicalUuid(serverSpaceId, 'server_space_id');
    _requireCanonicalUuid(vaultId, 'vault_id');
    _requirePassword(password);
    final salt = sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
    final chunkCount = (payload.length + chunkSize - 1) ~/ chunkSize;
    final header = <String, Object?>{
      'format': formatName,
      'version': formatVersion,
      'cipher_suite': 'xchacha20-poly1305-ietf',
      'kdf': {
        'algorithm': 'argon2id13',
        'salt': encodeBase64Url(salt),
        'memory_kib': _kdfMemoryKib,
        'iterations': _kdfIterations,
        'parallelism': _kdfParallelism,
      },
      'server_space_id': serverSpaceId,
      'vault_id': vaultId,
      'payload_length': payload.length,
      'chunk_size': chunkSize,
      'chunk_count': chunkCount,
    };
    final headerBytes = Uint8List.fromList(utf8.encode(canonicalJson(header)));
    if (headerBytes.length > maxHeaderBytes) {
      salt.fillRange(0, salt.length, 0);
      throw FormatException(currentL10n.theArchiveHeaderExceedsTheSize);
    }
    final prefix = Uint8List.fromList(utf8.encode(containerMagic));
    final kdfBytes = Int8List.fromList(utf8.encode(password));
    SecureKey? key;
    try {
      key = sodium.crypto.pwhash.callRaw(
        outLen: 32,
        password: kdfBytes,
        salt: salt,
        opsLimit: _kdfIterations,
        memLimit: _kdfMemoryKib * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      // Each sealed buffer is wiped immediately after add(). With copy:false
      // BytesBuilder may retain the caller's buffer, so that would erase the
      // ciphertext already assembled into the container. The archive has a
      // strict 128 MiB plaintext cap, making this bounded defensive copy safe.
      final out = BytesBuilder(copy: true)
        ..add(prefix)
        ..add(_u32(headerBytes.length))
        ..add(headerBytes);
      var offset = 0;
      for (var index = 0; index < chunkCount; index++) {
        final length = min(chunkSize, payload.length - offset);
        final nonce = sodium.randombytes.buf(24);
        final aad = _chunkAad(headerBytes, index, length, nonce);
        final clearChunk = Uint8List.sublistView(
          payload,
          offset,
          offset + length,
        );
        final sealed = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
          message: clearChunk,
          nonce: nonce,
          key: key,
          additionalData: aad,
        );
        out
          ..add(_u32(length))
          ..add(nonce)
          ..add(sealed);
        nonce.fillRange(0, nonce.length, 0);
        aad.fillRange(0, aad.length, 0);
        sealed.fillRange(0, sealed.length, 0);
        offset += length;
      }
      final result = out.takeBytes();
      if (result.length > maxContainerBytes) {
        result.fillRange(0, result.length, 0);
        throw FormatException(currentL10n.theEncryptedArchiveExceedsTheFile);
      }
      return result;
    } finally {
      key?.dispose();
      salt.fillRange(0, salt.length, 0);
      kdfBytes.fillRange(0, kdfBytes.length, 0);
      headerBytes.fillRange(0, headerBytes.length, 0);
      prefix.fillRange(0, prefix.length, 0);
    }
  }

  Future<Uint8List> open({
    required String password,
    required Uint8List container,
    required String expectedServerSpaceId,
    required String expectedVaultId,
  }) async {
    if (container.length < 12 || container.length > maxContainerBytes) {
      throw FormatException(currentL10n.theArchiveFileSizeIsInvalid);
    }
    _requireCanonicalUuid(expectedServerSpaceId, 'server_space_id');
    _requireCanonicalUuid(expectedVaultId, 'vault_id');
    _requirePassword(password);
    final magicBytes = Uint8List.sublistView(container, 0, 8);
    if (utf8.decode(magicBytes, allowMalformed: true) != containerMagic) {
      throw FormatException(currentL10n.notASupportedAtermiusEncryptedArchive);
    }
    final headerLength = _readU32(container, 8);
    if (headerLength < 2 || headerLength > maxHeaderBytes) {
      throw FormatException(currentL10n.invalidArchiveHeaderLength);
    }
    var offset = 12;
    final endHeader = offset + headerLength;
    if (endHeader > container.length) {
      throw FormatException(currentL10n.theArchiveFileIsTruncated);
    }
    final headerBytes = Uint8List.fromList(
      container.sublist(offset, endHeader),
    );
    final decodedHeader = jsonDecode(utf8.decode(headerBytes));
    if (decodedHeader is! Map<String, dynamic> ||
        canonicalJson(decodedHeader) != utf8.decode(headerBytes)) {
      throw FormatException(currentL10n.theArchiveHeaderIsntCanonicalJson);
    }
    final header = decodedHeader;
    const allowedHeaderKeys = {
      'format',
      'version',
      'cipher_suite',
      'kdf',
      'server_space_id',
      'vault_id',
      'payload_length',
      'chunk_size',
      'chunk_count',
    };
    if (header.keys.toSet().difference(allowedHeaderKeys).isNotEmpty ||
        !header.keys.toSet().containsAll(allowedHeaderKeys)) {
      throw FormatException(currentL10n.theArchiveHeaderHasUnknownOr);
    }
    if (header['format'] != formatName ||
        header['version'] != formatVersion ||
        header['cipher_suite'] != 'xchacha20-poly1305-ietf' ||
        header['server_space_id'] != expectedServerSpaceId ||
        header['vault_id'] != expectedVaultId) {
      throw FormatException(currentL10n.theArchiveVersionServerSpaceOr);
    }
    final rawLength = header['payload_length'];
    final rawChunkSize = header['chunk_size'];
    final rawChunkCount = header['chunk_count'];
    if (rawLength is! int ||
        rawLength < 1 ||
        rawLength > maxPayloadBytes ||
        rawChunkSize != chunkSize ||
        rawChunkCount is! int ||
        rawChunkCount < 1 ||
        rawChunkCount != (rawLength + chunkSize - 1) ~/ chunkSize) {
      throw FormatException(currentL10n.theArchiveLengthOrChunkParameters);
    }
    final rawKdf = header['kdf'];
    if (rawKdf is! Map<String, dynamic> ||
        rawKdf.keys.toSet().difference(const {
          'algorithm',
          'salt',
          'memory_kib',
          'iterations',
          'parallelism',
        }).isNotEmpty ||
        rawKdf.length != 5 ||
        rawKdf['algorithm'] != 'argon2id13' ||
        rawKdf['memory_kib'] != _kdfMemoryKib ||
        rawKdf['iterations'] != _kdfIterations ||
        rawKdf['parallelism'] != _kdfParallelism ||
        rawKdf['salt'] is! String) {
      throw FormatException(currentL10n.unsupportedArgon2idParameters);
    }
    final salt = decodeBase64Url(rawKdf['salt'] as String);
    if (salt.length != sodium.crypto.pwhash.saltBytes) {
      salt.fillRange(0, salt.length, 0);
      throw FormatException(currentL10n.invalidArchiveArgon2idSaltLength);
    }
    final kdfBytes = Int8List.fromList(utf8.encode(password));
    SecureKey? key;
    final payload = Uint8List(rawLength);
    var complete = false;
    var plainBytes = 0;
    try {
      key = sodium.crypto.pwhash.callRaw(
        outLen: 32,
        password: kdfBytes,
        salt: salt,
        opsLimit: _kdfIterations,
        memLimit: _kdfMemoryKib * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      offset = endHeader;
      for (var index = 0; index < rawChunkCount; index++) {
        if (offset + 4 + 24 > container.length) {
          throw FormatException(currentL10n.anEncryptedArchiveChunkIsTruncated);
        }
        final length = _readU32(container, offset);
        offset += 4;
        final expectedLength = min(chunkSize, rawLength - plainBytes);
        if (length != expectedLength || length <= 0) {
          throw FormatException(currentL10n.theArchiveChunkLengthDoesntMatch);
        }
        final nonce = Uint8List.fromList(
          container.sublist(offset, offset + 24),
        );
        offset += 24;
        final cipherLength = length + _tagLength;
        if (offset + cipherLength > container.length) {
          throw FormatException(currentL10n.anEncryptedArchiveChunkIsTruncated);
        }
        final ciphertext = Uint8List.fromList(
          container.sublist(offset, offset + cipherLength),
        );
        offset += cipherLength;
        final aad = _chunkAad(headerBytes, index, length, nonce);
        late Uint8List clear;
        try {
          clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
            cipherText: ciphertext,
            nonce: nonce,
            key: key,
            additionalData: aad,
          );
        } on SodiumException {
          throw FormatException(currentL10n.wrongArchivePasswordOrTheArchive);
        } finally {
          ciphertext.fillRange(0, ciphertext.length, 0);
          nonce.fillRange(0, nonce.length, 0);
          aad.fillRange(0, aad.length, 0);
        }
        try {
          if (clear.length != length) {
            throw FormatException(
              currentL10n.invalidDecryptedArchiveChunkLength,
            );
          }
          payload.setRange(plainBytes, plainBytes + length, clear);
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
        plainBytes += length;
      }
      if (offset != container.length || plainBytes != rawLength) {
        throw FormatException(currentL10n.theArchiveHasTrailingDataOr);
      }
      complete = true;
      return payload;
    } finally {
      key?.dispose();
      salt.fillRange(0, salt.length, 0);
      kdfBytes.fillRange(0, kdfBytes.length, 0);
      headerBytes.fillRange(0, headerBytes.length, 0);
      if (!complete) payload.fillRange(0, payload.length, 0);
    }
  }

  static Uint8List packPayload({
    required Map<String, Object?> manifest,
    required List<Uint8List> objectBytes,
  }) {
    if (objectBytes.length > 10000) {
      throw FormatException(currentL10n.theNumberOfArchiveObjectsExceeds);
    }
    var totalObjectBytes = 0;
    for (final bytes in objectBytes) {
      if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
        throw FormatException(currentL10n.anArchiveObjectIsEmptyOr);
      }
      totalObjectBytes += bytes.length;
      if (totalObjectBytes > maxPayloadBytes) {
        throw FormatException(currentL10n.theTotalArchiveObjectDataExceeds);
      }
    }
    final manifestBytes = Uint8List.fromList(
      utf8.encode(canonicalJson(manifest)),
    );
    if (manifestBytes.length > 16 * 1024 * 1024) {
      manifestBytes.fillRange(0, manifestBytes.length, 0);
      throw FormatException(currentL10n.theArchiveManifestExceedsThe16);
    }
    final out = BytesBuilder(copy: true)
      ..add(utf8.encode(payloadMagic))
      ..add(_u32(manifestBytes.length))
      ..add(manifestBytes);
    for (final bytes in objectBytes) {
      out.add(bytes);
    }
    manifestBytes.fillRange(0, manifestBytes.length, 0);
    final payload = out.takeBytes();
    if (payload.length > maxPayloadBytes) {
      payload.fillRange(0, payload.length, 0);
      throw FormatException(currentL10n.theArchivePlaintextExceedsTheFile);
    }
    return payload;
  }

  static ({Map<String, dynamic> manifest, Uint8List objectRegion})
  unpackPayload(Uint8List payload) {
    if (payload.length < 12 || payload.length > maxPayloadBytes) {
      throw FormatException(currentL10n.invalidArchivePlaintextSize);
    }
    if (utf8.decode(payload.sublist(0, 8), allowMalformed: true) !=
        payloadMagic) {
      throw FormatException(currentL10n.invalidArchivePlaintextType);
    }
    final manifestLength = _readU32(payload, 8);
    final manifestEnd = 12 + manifestLength;
    if (manifestLength < 2 ||
        manifestLength > 16 * 1024 * 1024 ||
        manifestEnd > payload.length) {
      throw FormatException(currentL10n.invalidArchiveManifestLength);
    }
    final manifestBytes = payload.sublist(12, manifestEnd);
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map<String, dynamic> ||
        canonicalJson(decoded) != utf8.decode(manifestBytes)) {
      throw FormatException(currentL10n.theArchiveManifestIsntCanonicalJson);
    }
    return (
      manifest: decoded,
      objectRegion: Uint8List.sublistView(payload, manifestEnd),
    );
  }

  static void _requireCanonicalUuid(String value, String field) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      throw FormatException('$field must be a lowercase canonical UUID.');
    }
  }

  static void _requirePassword(String password, {int minLength = 12}) {
    if (utf8.encode(password).length < minLength) {
      throw FormatException(currentL10n.theSeparateArchivePasswordMustBe);
    }
  }

  static Uint8List _chunkAad(
    Uint8List header,
    int index,
    int length,
    Uint8List nonce,
  ) {
    return Uint8List.fromList([
      ...utf8.encode('$containerMagic\u0000chunk-v1\u0000'),
      ...header,
      ..._u32(index),
      ..._u32(length),
      ...nonce,
    ]);
  }

  static Uint8List _u32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
    return bytes;
  }

  static int _readU32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.big);

  static int min(int left, int right) => left < right ? left : right;
}
