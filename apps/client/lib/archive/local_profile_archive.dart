import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../domain/known_host.dart';
import '../storage/local_host_repository.dart';
import '../l10n/l10n.dart';

class LocalProfileArchiveSnapshot {
  const LocalProfileArchiveSnapshot({
    required this.records,
    required this.knownHosts,
  });

  final List<LocalProfileArchiveRecord> records;
  final List<KnownHostRecord> knownHosts;
}

/// Coordinates the standalone Local-only archive format with an already
/// unlocked source or empty destination profile.
class LocalProfileArchiveService {
  LocalProfileArchiveService(SodiumSumo sodium)
    : _codec = LocalProfileArchiveCodec(sodium);

  final LocalProfileArchiveCodec _codec;

  Future<Uint8List> export({
    required LocalHostRepository repository,
    required String password,
  }) async {
    final snapshot = await repository.exportPortableArchiveSnapshot();
    final payload = LocalProfileArchiveCodec.encodeArchiveSnapshot(
      records: snapshot.records,
      knownHosts: snapshot.knownHosts,
    );
    try {
      return await _codec.seal(password: password, payload: payload);
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  Future<LocalProfileArchiveSnapshot> stageImport({
    required Uint8List container,
    required String password,
  }) async {
    final payload = await _codec.open(password: password, container: container);
    try {
      return LocalProfileArchiveCodec.decodeArchiveSnapshot(payload);
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  Future<void> importIntoEmptyProfile({
    required LocalHostRepository repository,
    required LocalProfileArchiveSnapshot snapshot,
  }) => repository.importArchiveSnapshot(
    snapshot.records,
    knownHosts: snapshot.knownHosts,
  );
}

/// Independent portable container for Local-only profile data.
///
/// This format is intentionally separate from server-Vault archives: it has
/// no server-space/Vault binding, server history, outbox, or object store.
class LocalProfileArchiveCodec {
  LocalProfileArchiveCodec(this.sodium);

  static const containerMagic = 'ATLOCAL1';
  static const formatName = 'atermius-local-profile-archive';
  static const formatVersion = 1;
  static const payloadFormat = 'atermius-local-profile-data';
  static const payloadVersion = 2;
  static const legacyPayloadVersion = 1;
  static const chunkSize = 1024 * 1024;
  static const maxPayloadBytes = 128 * 1024 * 1024;
  static const maxContainerBytes = 136 * 1024 * 1024;
  static const maxHeaderBytes = 64 * 1024;
  static const maxRecords = 50000;
  static const maxKnownHosts = 4096;
  static const minPasswordUtf8Bytes = 12;
  static const maxPasswordUtf8Bytes = 1024;
  static const kdfMemoryKib = 65536;
  static const kdfIterations = 3;
  static const kdfParallelism = 1;
  static const _tagLength = 16;

  final SodiumSumo sodium;

  Future<Uint8List> seal({
    required String password,
    required Uint8List payload,
  }) async {
    if (payload.isEmpty || payload.length > maxPayloadBytes) {
      throw FormatException(currentL10n.theLocalArchiveContentIsEmpty);
    }
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
        'memory_kib': kdfMemoryKib,
        'iterations': kdfIterations,
        'parallelism': kdfParallelism,
      },
      'payload_length': payload.length,
      'chunk_size': chunkSize,
      'chunk_count': chunkCount,
    };
    final headerBytes = Uint8List.fromList(utf8.encode(canonicalJson(header)));
    final prefix = Uint8List.fromList(utf8.encode(containerMagic));
    final passwordBytes = Int8List.fromList(utf8.encode(password));
    SecureKey? key;
    try {
      if (headerBytes.length > maxHeaderBytes) {
        throw FormatException(currentL10n.theLocalArchiveHeaderExceedsThe);
      }
      key = sodium.crypto.pwhash.callRaw(
        outLen: 32,
        password: passwordBytes,
        salt: salt,
        opsLimit: kdfIterations,
        memLimit: kdfMemoryKib * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      final out = BytesBuilder(copy: true)
        ..add(prefix)
        ..add(_u32(headerBytes.length))
        ..add(headerBytes);
      var offset = 0;
      for (var index = 0; index < chunkCount; index++) {
        final length = _min(chunkSize, payload.length - offset);
        final nonce = sodium.randombytes.buf(24);
        final aad = _chunkAad(headerBytes, index, length, nonce);
        final clear = Uint8List.sublistView(payload, offset, offset + length);
        final sealed = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
          message: clear,
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
      final container = out.takeBytes();
      if (container.length > maxContainerBytes) {
        container.fillRange(0, container.length, 0);
        throw FormatException(currentL10n.theLocalEncryptedArchiveExceedsThe);
      }
      return container;
    } finally {
      key?.dispose();
      salt.fillRange(0, salt.length, 0);
      passwordBytes.fillRange(0, passwordBytes.length, 0);
      headerBytes.fillRange(0, headerBytes.length, 0);
      prefix.fillRange(0, prefix.length, 0);
    }
  }

  Future<Uint8List> open({
    required String password,
    required Uint8List container,
  }) async {
    if (container.length < 12 || container.length > maxContainerBytes) {
      throw FormatException(currentL10n.theLocalArchiveSizeIsInvalid);
    }
    _requirePassword(password);
    if (utf8.decode(container.sublist(0, 8), allowMalformed: true) !=
        containerMagic) {
      throw FormatException(currentL10n.notASupportedLocalEncryptedArchive);
    }
    final headerLength = _readU32(container, 8);
    if (headerLength < 2 || headerLength > maxHeaderBytes) {
      throw FormatException(currentL10n.invalidLocalArchiveHeaderLength);
    }
    final headerEnd = 12 + headerLength;
    if (headerEnd > container.length) {
      throw FormatException(currentL10n.theLocalArchiveFileIsTruncated);
    }
    final headerBytes = Uint8List.fromList(container.sublist(12, headerEnd));
    final headerText = utf8.decode(headerBytes);
    final decodedHeader = jsonDecode(headerText);
    if (decodedHeader is! Map<String, dynamic> ||
        canonicalJson(decodedHeader) != headerText) {
      throw FormatException(currentL10n.theLocalArchiveHeaderIsntCanonical);
    }
    const allowedHeaderKeys = {
      'format',
      'version',
      'cipher_suite',
      'kdf',
      'payload_length',
      'chunk_size',
      'chunk_count',
    };
    if (decodedHeader.keys.toSet().difference(allowedHeaderKeys).isNotEmpty ||
        decodedHeader.keys.toSet().length != allowedHeaderKeys.length ||
        !decodedHeader.keys.toSet().containsAll(allowedHeaderKeys)) {
      headerBytes.fillRange(0, headerBytes.length, 0);
      throw FormatException(currentL10n.theLocalArchiveHeaderHasUnknown);
    }
    if (decodedHeader['format'] != formatName ||
        decodedHeader['version'] != formatVersion ||
        decodedHeader['cipher_suite'] != 'xchacha20-poly1305-ietf') {
      headerBytes.fillRange(0, headerBytes.length, 0);
      throw FormatException(currentL10n.unsupportedLocalArchiveFormatOrVersion);
    }
    final rawLength = decodedHeader['payload_length'];
    final rawChunkCount = decodedHeader['chunk_count'];
    if (rawLength is! int ||
        rawLength < 1 ||
        rawLength > maxPayloadBytes ||
        decodedHeader['chunk_size'] != chunkSize ||
        rawChunkCount is! int ||
        rawChunkCount < 1 ||
        rawChunkCount != (rawLength + chunkSize - 1) ~/ chunkSize) {
      headerBytes.fillRange(0, headerBytes.length, 0);
      throw FormatException(currentL10n.theLocalArchiveLengthOrChunk);
    }
    final rawKdf = decodedHeader['kdf'];
    const kdfKeys = {
      'algorithm',
      'salt',
      'memory_kib',
      'iterations',
      'parallelism',
    };
    if (rawKdf is! Map<String, dynamic> ||
        rawKdf.keys.toSet().difference(kdfKeys).isNotEmpty ||
        rawKdf.keys.toSet().length != kdfKeys.length ||
        !rawKdf.keys.toSet().containsAll(kdfKeys) ||
        rawKdf['algorithm'] != 'argon2id13' ||
        rawKdf['memory_kib'] != kdfMemoryKib ||
        rawKdf['iterations'] != kdfIterations ||
        rawKdf['parallelism'] != kdfParallelism ||
        rawKdf['salt'] is! String) {
      headerBytes.fillRange(0, headerBytes.length, 0);
      throw FormatException(
        currentL10n.unsupportedLocalArchiveArgon2idParameters,
      );
    }
    final salt = _decodeCanonicalBase64(rawKdf['salt'] as String);
    if (salt.length != sodium.crypto.pwhash.saltBytes) {
      salt.fillRange(0, salt.length, 0);
      headerBytes.fillRange(0, headerBytes.length, 0);
      throw FormatException(currentL10n.invalidLocalArchiveSaltLength);
    }
    final passwordBytes = Int8List.fromList(utf8.encode(password));
    final payload = Uint8List(rawLength);
    SecureKey? key;
    var payloadComplete = false;
    var written = 0;
    try {
      key = sodium.crypto.pwhash.callRaw(
        outLen: 32,
        password: passwordBytes,
        salt: salt,
        opsLimit: kdfIterations,
        memLimit: kdfMemoryKib * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      var offset = headerEnd;
      for (var index = 0; index < rawChunkCount; index++) {
        if (offset + 28 > container.length) {
          throw FormatException(currentL10n.aLocalEncryptedArchiveChunkIs);
        }
        final length = _readU32(container, offset);
        offset += 4;
        final expectedLength = _min(chunkSize, rawLength - written);
        if (length != expectedLength || length < 1) {
          throw FormatException(currentL10n.theLocalArchiveChunkLengthDoesnt);
        }
        final nonce = Uint8List.fromList(
          container.sublist(offset, offset + 24),
        );
        offset += 24;
        final cipherLength = length + _tagLength;
        if (offset + cipherLength > container.length) {
          nonce.fillRange(0, nonce.length, 0);
          throw FormatException(currentL10n.aLocalEncryptedArchiveChunkIs);
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
          throw FormatException(currentL10n.wrongLocalArchivePasswordOrThe);
        } finally {
          ciphertext.fillRange(0, ciphertext.length, 0);
          nonce.fillRange(0, nonce.length, 0);
          aad.fillRange(0, aad.length, 0);
        }
        try {
          if (clear.length != length) {
            throw FormatException(currentL10n.invalidDecryptedChunkLengthInThe);
          }
          payload.setRange(written, written + length, clear);
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
        written += length;
      }
      if (offset != container.length || written != rawLength) {
        throw FormatException(currentL10n.theLocalArchiveHasTrailingData);
      }
      payloadComplete = true;
      return payload;
    } finally {
      key?.dispose();
      salt.fillRange(0, salt.length, 0);
      passwordBytes.fillRange(0, passwordBytes.length, 0);
      headerBytes.fillRange(0, headerBytes.length, 0);
      if (!payloadComplete) payload.fillRange(0, payload.length, 0);
    }
  }

  static Uint8List encodeSnapshot(List<LocalProfileArchiveRecord> records) {
    if (records.length > maxRecords) {
      throw FormatException(currentL10n.theNumberOfRecordsInThe);
    }
    final ordered = [...records]
      ..sort((a, b) => a.recordId.compareTo(b.recordId));
    for (var index = 1; index < ordered.length; index++) {
      if (ordered[index - 1].recordId == ordered[index].recordId) {
        throw FormatException(
          currentL10n.theLocalArchiveContainsDuplicateRecord,
        );
      }
    }
    final snapshot = <String, Object?>{
      'format': payloadFormat,
      'version': legacyPayloadVersion,
      'records': ordered.map((record) => record.toJson()).toList(),
    };
    final bytes = Uint8List.fromList(utf8.encode(canonicalJson(snapshot)));
    if (bytes.isEmpty || bytes.length > maxPayloadBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.theLocalArchivePlaintextExceedsThe);
    }
    return bytes;
  }

  static List<LocalProfileArchiveRecord> decodeSnapshot(Uint8List payload) {
    if (payload.isEmpty || payload.length > maxPayloadBytes) {
      throw FormatException(currentL10n.theLocalArchivePlaintextIsEmpty);
    }
    final text = utf8.decode(payload);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || canonicalJson(decoded) != text) {
      throw FormatException(currentL10n.theLocalArchiveContentIsntCanonical);
    }
    if (decoded.keys.toSet().length != 3 ||
        !decoded.keys.toSet().containsAll(const {
          'format',
          'version',
          'records',
        }) ||
        decoded['format'] != payloadFormat ||
        decoded['version'] != legacyPayloadVersion) {
      throw FormatException(currentL10n.unsupportedLocalArchiveContentFormatOr);
    }
    final rawRecords = decoded['records'];
    if (rawRecords is! List || rawRecords.length > maxRecords) {
      throw FormatException(currentL10n.theLocalArchiveRecordListExceeds);
    }
    final records = <LocalProfileArchiveRecord>[];
    String? previousId;
    for (final rawRecord in rawRecords) {
      if (rawRecord is! Map || rawRecord.keys.any((key) => key is! String)) {
        throw FormatException(currentL10n.invalidLocalArchiveRecord);
      }
      final record = LocalProfileArchiveRecord.fromJson(
        Map<String, dynamic>.from(rawRecord),
      );
      if (previousId != null && previousId.compareTo(record.recordId) >= 0) {
        throw FormatException(currentL10n.invalidRecordOrderOrUniquenessIn);
      }
      previousId = record.recordId;
      records.add(record);
    }
    return List.unmodifiable(records);
  }

  /// Encodes payload v2 with ordinary LocalVault records and local KnownHost
  /// history in one encrypted container. Active approvals remain candidates
  /// for destination-device review; only revoked rows will be restored as
  /// effective trust state.
  static Uint8List encodeArchiveSnapshot({
    required List<LocalProfileArchiveRecord> records,
    required List<KnownHostRecord> knownHosts,
  }) {
    if (records.length > maxRecords || knownHosts.length > maxKnownHosts) {
      throw FormatException(currentL10n.theNumberOfRecordsInThe);
    }
    final orderedKnownHosts = [...knownHosts]
      ..sort((a, b) => a.id.compareTo(b.id));
    final seenKnownHostIds = <String>{};
    final knownHostJson = <Map<String, Object?>>[];
    for (final record in orderedKnownHosts) {
      final revisionId = record.revisionId;
      if (revisionId == null || !seenKnownHostIds.add(record.id)) {
        throw FormatException(currentL10n.invalidSshTrustRecordMetadataIn);
      }
      knownHostJson.add({
        'source_revision_id': revisionId,
        'record': {
          ...record.toJson(),
          '_record_id': record.id,
          '_revision_id': revisionId,
        },
      });
    }
    final orderedRecords = [...records]
      ..sort((a, b) => a.recordId.compareTo(b.recordId));
    for (var index = 1; index < orderedRecords.length; index++) {
      if (orderedRecords[index - 1].recordId ==
          orderedRecords[index].recordId) {
        throw FormatException(
          currentL10n.theLocalArchiveContainsDuplicateRecord,
        );
      }
    }
    final snapshot = <String, Object?>{
      'format': payloadFormat,
      'version': payloadVersion,
      'records': orderedRecords.map((record) => record.toJson()).toList(),
      'known_hosts': knownHostJson,
    };
    final bytes = Uint8List.fromList(utf8.encode(canonicalJson(snapshot)));
    if (bytes.isEmpty || bytes.length > maxPayloadBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.theLocalArchivePlaintextExceedsThe);
    }
    return bytes;
  }

  /// Accepts v1 records-only archives and strict v2 archives with KnownHost
  /// history. Candidate approvals are never treated as active trust during
  /// decode or repository import.
  static LocalProfileArchiveSnapshot decodeArchiveSnapshot(Uint8List payload) {
    if (payload.isEmpty || payload.length > maxPayloadBytes) {
      throw FormatException(currentL10n.theLocalArchivePlaintextIsEmpty);
    }
    final text = utf8.decode(payload);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || canonicalJson(decoded) != text) {
      throw FormatException(currentL10n.theLocalArchiveContentIsntCanonical);
    }
    if (decoded['format'] != payloadFormat) {
      throw FormatException(currentL10n.unsupportedLocalArchiveContentFormatOr);
    }
    if (decoded['version'] == legacyPayloadVersion) {
      final records = decodeSnapshot(payload);
      return LocalProfileArchiveSnapshot(
        records: records,
        knownHosts: const [],
      );
    }
    const fields = {'format', 'version', 'records', 'known_hosts'};
    if (decoded.keys.toSet().length != fields.length ||
        !decoded.keys.toSet().containsAll(fields) ||
        decoded['version'] != payloadVersion) {
      throw FormatException(currentL10n.unsupportedLocalArchiveContentFormatOr);
    }
    final records = _decodeRecords(decoded['records']);
    final rawKnownHosts = decoded['known_hosts'];
    if (rawKnownHosts is! List || rawKnownHosts.length > maxKnownHosts) {
      throw FormatException(currentL10n.theNumberOfSshTrustRecords);
    }
    final knownHosts = <KnownHostRecord>[];
    final seenIds = <String>{};
    String? previousId;
    for (final raw in rawKnownHosts) {
      if (raw is! Map ||
          raw.keys.any((key) => key is! String) ||
          raw.keys.toSet().length != 2 ||
          !raw.keys.toSet().containsAll(const {
            'source_revision_id',
            'record',
          })) {
        throw FormatException(currentL10n.invalidSshTrustRecordInThe);
      }
      final sourceRevisionId = raw['source_revision_id'];
      final rawRecord = raw['record'];
      if (sourceRevisionId is! String ||
          rawRecord is! Map ||
          rawRecord.keys.any((key) => key is! String)) {
        throw FormatException(currentL10n.invalidSshTrustRecordMetadataIn);
      }
      final record = KnownHostRecord.fromJson({
        ...Map<String, dynamic>.from(rawRecord),
        '_revision_id': sourceRevisionId,
      });
      if (previousId != null && previousId.compareTo(record.id) >= 0 ||
          !seenIds.add(record.id)) {
        throw FormatException(currentL10n.invalidOrderOrUniquenessOfSsh);
      }
      previousId = record.id;
      knownHosts.add(record);
    }
    return LocalProfileArchiveSnapshot(
      records: records,
      knownHosts: List.unmodifiable(knownHosts),
    );
  }

  static List<LocalProfileArchiveRecord> _decodeRecords(Object? rawRecords) {
    if (rawRecords is! List || rawRecords.length > maxRecords) {
      throw FormatException(currentL10n.theLocalArchiveRecordListExceeds);
    }
    final records = <LocalProfileArchiveRecord>[];
    String? previousId;
    for (final rawRecord in rawRecords) {
      if (rawRecord is! Map || rawRecord.keys.any((key) => key is! String)) {
        throw FormatException(currentL10n.invalidLocalArchiveRecord);
      }
      final record = LocalProfileArchiveRecord.fromJson(
        Map<String, dynamic>.from(rawRecord),
      );
      if (previousId != null && previousId.compareTo(record.recordId) >= 0) {
        throw FormatException(currentL10n.invalidRecordOrderOrUniquenessIn);
      }
      previousId = record.recordId;
      records.add(record);
    }
    return List.unmodifiable(records);
  }

  static void _requirePassword(String password) {
    if (password.length > maxPasswordUtf8Bytes) {
      throw FormatException(currentL10n.theLocalArchivePassphraseMustBe);
    }
    final encoded = utf8.encode(password);
    final length = encoded.length;
    encoded.fillRange(0, encoded.length, 0);
    if (length < minPasswordUtf8Bytes || length > maxPasswordUtf8Bytes) {
      throw FormatException(currentL10n.theLocalArchivePassphraseMustBe);
    }
  }

  static Uint8List _decodeCanonicalBase64(String value) {
    final decoded = decodeBase64Url(value);
    if (encodeBase64Url(decoded) != value) {
      decoded.fillRange(0, decoded.length, 0);
      throw FormatException(currentL10n.invalidBase64urlEncodingInTheLocal);
    }
    return decoded;
  }

  static Uint8List _chunkAad(
    Uint8List header,
    int index,
    int length,
    Uint8List nonce,
  ) => Uint8List.fromList([
    ...utf8.encode('$containerMagic\u0000chunk-v1\u0000'),
    ...header,
    ..._u32(index),
    ..._u32(length),
    ...nonce,
  ]);

  static Uint8List _u32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
    return bytes;
  }

  static int _readU32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.big);

  static int _min(int left, int right) => left < right ? left : right;
}
