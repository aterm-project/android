/// Pure-Dart read-only Chromium IndexedDB (LevelDB + Snappy + Blink/V8
/// ValueDeserializer) reader for offline Termius Desktop data directories.
///
/// Works directly on an in-memory map of LevelDB snapshot files so Termius does
/// not need to be running, no lock files are touched, and tests can synthesize
/// complete LevelDB + IndexedDB fixtures in memory.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Databases inside Termius's IndexedDB relevant to workspace migration.
const Set<String> wantedTermiusDatabases = {
  'hosts',
  'keys',
  'ssh_identities',
  'ssh_configs',
  'proxies',
  'groups',
  'tags',
  'tag_hosts',
  'pf_rules',
  'known_hosts',
};

const int _maxSnappyOutputBytes = 64 * 1024 * 1024;

/// Upper bound on bytes produced by all Snappy blocks of one read (SST data
/// blocks plus Blink-compressed values), so crafted copy chains cannot expand
/// a bounded on-disk snapshot into unbounded memory.
const int maxTermiusIndexedDbDecompressedBytes = 256 * 1024 * 1024;

/// Upper bound on LevelDB entries (all keys, all generations) in one read.
const int maxTermiusIndexedDbEntries = 500000;

/// Upper bound on live rows decoded from one wanted Termius database.
const int maxTermiusIndexedDbRowsPerTable = 50000;

const int _maxV8Depth = 64;
const int _levelDbSstFooterBytes = 48;
const int _levelDbLogBlockBytes = 32768;
const List<int> _levelDbTableMagic = [
  0x57,
  0xfb,
  0x80,
  0x8b,
  0x24,
  0x75,
  0x47,
  0xdb,
];

/// A safety bound of the read-only reader was exceeded; nothing is returned.
class TermiusIndexedDbLimitException implements Exception {
  const TermiusIndexedDbLimitException(this.limit);

  final String limit;

  @override
  String toString() => 'TermiusIndexedDbLimitException($limit)';
}

class TermiusRawTables {
  const TermiusRawTables({
    required this.tables,
    required this.countsBeforeDedup,
    this.malformedRecords = const {},
  });

  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, int> countsBeforeDedup;

  /// Live primary records per wanted database whose value could not be
  /// decoded into an object. Callers that must not silently lose data fail
  /// closed when a table they use has any.
  final Map<String, int> malformedRecords;

  List<Map<String, Object?>> operator [](String name) =>
      tables[name] ?? const [];
}

class _ReadBudget {
  int decompressedBytes = 0;

  void consumeDecompressed(int bytes) {
    decompressedBytes += bytes;
    if (decompressedBytes > maxTermiusIndexedDbDecompressedBytes) {
      throw const TermiusIndexedDbLimitException('decompressedBytes');
    }
  }
}

/// Decompresses a raw (unframed) Snappy block as stored in LevelDB SSTables
/// and Blink `kCompressedWithSnappy` IndexedDB values.
Uint8List snappyUncompress(Uint8List input) =>
    _snappyUncompress(input, null);

Uint8List _snappyUncompress(Uint8List input, _ReadBudget? budget) {
  final header = _readVarint(input, 0);
  if (header == null) {
    throw const FormatException('Truncated Snappy length header');
  }
  final targetLen = header.value;
  if (targetLen < 0 || targetLen > _maxSnappyOutputBytes) {
    throw const FormatException('Snappy uncompressed length out of bounds');
  }
  budget?.consumeDecompressed(targetLen);
  final out = Uint8List(targetLen);
  var inPos = header.next;
  var outPos = 0;

  while (inPos < input.length) {
    final tag = input[inPos++];
    final elementType = tag & 0x03;
    if (elementType == 0) {
      // Literal.
      var lenMinusOne = tag >> 2;
      if (lenMinusOne >= 60) {
        final extraBytes = lenMinusOne - 59;
        if (inPos + extraBytes > input.length) {
          throw const FormatException('Truncated Snappy literal length');
        }
        lenMinusOne = 0;
        for (var i = 0; i < extraBytes; i++) {
          lenMinusOne |= input[inPos + i] << (8 * i);
        }
        inPos += extraBytes;
      }
      final literalLen = lenMinusOne + 1;
      if (inPos + literalLen > input.length || outPos + literalLen > targetLen) {
        throw const FormatException('Snappy literal exceeds buffer');
      }
      out.setRange(outPos, outPos + literalLen, input, inPos);
      inPos += literalLen;
      outPos += literalLen;
    } else {
      // Copy with 1-, 2-, or 4-byte little-endian offset.
      int copyLen;
      int copyOffset;
      if (elementType == 1) {
        if (inPos >= input.length) {
          throw const FormatException('Truncated Snappy copy-1');
        }
        copyLen = ((tag >> 2) & 0x07) + 4;
        copyOffset = ((tag & 0xe0) << 3) | input[inPos++];
      } else if (elementType == 2) {
        if (inPos + 2 > input.length) {
          throw const FormatException('Truncated Snappy copy-2');
        }
        copyLen = (tag >> 2) + 1;
        copyOffset = input[inPos] | (input[inPos + 1] << 8);
        inPos += 2;
      } else {
        if (inPos + 4 > input.length) {
          throw const FormatException('Truncated Snappy copy-4');
        }
        copyLen = (tag >> 2) + 1;
        copyOffset =
            input[inPos] |
            (input[inPos + 1] << 8) |
            (input[inPos + 2] << 16) |
            (input[inPos + 3] << 24);
        inPos += 4;
      }
      if (copyOffset <= 0 ||
          copyOffset > outPos ||
          outPos + copyLen > targetLen) {
        throw const FormatException('Invalid Snappy back-reference');
      }
      var src = outPos - copyOffset;
      for (var i = 0; i < copyLen; i++) {
        out[outPos++] = out[src++];
      }
    }
  }

  if (outPos != targetLen) {
    throw const FormatException('Snappy output length mismatch');
  }
  return out;
}

/// Encodes [plain] as a valid single-literal raw Snappy block (used by tests).
Uint8List snappyCompressLiteral(Uint8List plain) {
  final out = BytesBuilder(copy: false);
  _writeVarint(out, plain.length);
  if (plain.isNotEmpty) {
    final lenMinusOne = plain.length - 1;
    if (lenMinusOne < 60) {
      out.addByte(lenMinusOne << 2);
    } else if (lenMinusOne <= 0xff) {
      out.addByte(60 << 2);
      out.addByte(lenMinusOne);
    } else if (lenMinusOne <= 0xffff) {
      out.addByte(61 << 2);
      out.addByte(lenMinusOne & 0xff);
      out.addByte((lenMinusOne >> 8) & 0xff);
    } else {
      out.addByte(63 << 2);
      out.addByte(lenMinusOne & 0xff);
      out.addByte((lenMinusOne >> 8) & 0xff);
      out.addByte((lenMinusOne >> 16) & 0xff);
      out.addByte((lenMinusOne >> 24) & 0xff);
    }
    out.add(plain);
  }
  return out.takeBytes();
}

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v & 0x7f);
}

({int value, int next})? _readVarint(
  Uint8List buf,
  int offset, {
  int maxBytes = 10,
}) {
  var result = 0;
  var shift = 0;
  final end = offset + maxBytes < buf.length ? offset + maxBytes : buf.length;
  for (var i = offset; i < end; i++) {
    final byte = buf[i];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      return (value: result, next: i + 1);
    }
    shift += 7;
  }
  return null;
}

({Uint8List slice, int next})? _readLengthPrefixedSlice(
  Uint8List buf,
  int offset,
) {
  final len = _readVarint(buf, offset);
  if (len == null || len.value < 0) return null;
  final end = len.next + len.value;
  if (end > buf.length) return null;
  return (slice: Uint8List.sublistView(buf, len.next, end), next: end);
}

({int offset, int size, int next})? _readBlockHandle(
  Uint8List buf,
  int offset,
) {
  final blockOffset = _readVarint(buf, offset);
  if (blockOffset == null) return null;
  final blockSize = _readVarint(buf, blockOffset.next);
  if (blockSize == null) return null;
  return (
    offset: blockOffset.value,
    size: blockSize.value,
    next: blockSize.next,
  );
}

class _LevelDbEntry {
  const _LevelDbEntry({
    required this.userKey,
    required this.sequence,
    required this.valueType,
    required this.value,
  });

  final Uint8List userKey;
  final int sequence;
  final int valueType;
  final Uint8List? value;
}

String _hexKey(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Reads all live user-key -> latest-value entries from a LevelDB directory
/// represented as `fileName -> bytes`.
Map<String, _LevelDbEntry> _readLiveLevelDbEntries(
  Map<String, Uint8List> files,
  _ReadBudget budget,
) {
  final records = <String, _LevelDbEntry>{};
  var seenEntries = 0;

  void recordEntry(
    Uint8List userKey,
    int sequence,
    int valueType,
    Uint8List? value,
  ) {
    if (++seenEntries > maxTermiusIndexedDbEntries) {
      throw const TermiusIndexedDbLimitException('entries');
    }
    final keyHex = _hexKey(userKey);
    final existing = records[keyHex];
    if (existing != null && existing.sequence > sequence) return;
    records[keyHex] = _LevelDbEntry(
      userKey: Uint8List.fromList(userKey),
      sequence: sequence,
      valueType: valueType,
      value: valueType == 1 && value != null ? Uint8List.fromList(value) : null,
    );
  }

  int? fileNumber(String name) {
    final dot = name.lastIndexOf('.');
    return int.tryParse(dot > 0 ? name.substring(0, dot) : name);
  }

  final manifest = _readManifestState(files);
  final presentTables = {
    for (final name in files.keys)
      if (name.endsWith('.ldb') || name.endsWith('.sst')) ?fileNumber(name),
  };
  // Only trust the manifest when every table it lists is in this snapshot.
  // A compaction racing the read can publish a new MANIFEST naming tables
  // that were not captured; filtering by it would then silently drop live
  // records. Falling back to all captured tables stays correct because the
  // newest sequence number per key always wins.
  final liveTables =
      manifest != null &&
          manifest.liveTables.isNotEmpty &&
          manifest.liveTables.every(presentTables.contains)
      ? manifest.liveTables
      : null;
  final tableNames = files.keys
      .where((name) => name.endsWith('.ldb') || name.endsWith('.sst'))
      .where((name) {
        if (liveTables == null) return true;
        final num = fileNumber(name);
        return num == null || liveTables.contains(num);
      })
      .toList()
    ..sort();

  for (final name in tableNames) {
    final bytes = files[name];
    if (bytes != null) {
      _readTableEntries(bytes, recordEntry, budget);
    }
  }

  // Logs older than the manifest's log number were already flushed into
  // tables; replaying them could resurrect records whose tombstones were
  // dropped by a later compaction.
  final minLog = liveTables == null ? null : manifest?.minLiveLogNumber;
  final logNames = files.keys
      .where((name) => name.endsWith('.log'))
      .where((name) {
        if (minLog == null) return true;
        final num = fileNumber(name);
        return num == null || num >= minLog;
      })
      .toList()
    ..sort();
  for (final name in logNames) {
    final bytes = files[name];
    if (bytes != null) {
      _readLogEntries(bytes, recordEntry);
    }
  }

  return records;
}

class _ManifestState {
  final live = <String, int>{};
  int? logNumber;
  int? prevLogNumber;

  Set<int> get liveTables => live.values.toSet();

  /// Lowest log file number that may still hold unflushed writes.
  int? get minLiveLogNumber {
    final log = logNumber;
    if (log == null) return null;
    final prev = prevLogNumber;
    return prev != null && prev > 0 && prev < log ? prev : log;
  }
}

_ManifestState? _readManifestState(Map<String, Uint8List> files) {
  final currentBytes = files['CURRENT'];
  if (currentBytes == null) return null;
  final manifestName = utf8
      .decode(currentBytes, allowMalformed: true)
      .trim();
  if (manifestName.isEmpty ||
      manifestName.contains('/') ||
      manifestName.contains(r'\')) {
    return null;
  }
  final manifestBytes = files[manifestName];
  if (manifestBytes == null) return null;

  final state = _ManifestState();
  for (final edit in _readLogPhysicalRecords(manifestBytes)) {
    _applyVersionEdit(edit, state);
  }
  return state;
}

void _applyVersionEdit(Uint8List edit, _ManifestState state) {
  final live = state.live;
  var pos = 0;
  while (pos < edit.length) {
    final tag = _readVarint(edit, pos);
    if (tag == null) return;
    pos = tag.next;
    switch (tag.value) {
      case 1:
        final comp = _readLengthPrefixedSlice(edit, pos);
        if (comp == null) return;
        pos = comp.next;
      case 2 || 3 || 4 || 9:
        final val = _readVarint(edit, pos);
        if (val == null) return;
        pos = val.next;
        if (tag.value == 2) state.logNumber = val.value;
        if (tag.value == 9) state.prevLogNumber = val.value;
      case 5:
        final level = _readVarint(edit, pos);
        if (level == null) return;
        final key = _readLengthPrefixedSlice(edit, level.next);
        if (key == null) return;
        pos = key.next;
      case 6:
        final level = _readVarint(edit, pos);
        if (level == null) return;
        final file = _readVarint(edit, level.next);
        if (file == null) return;
        live.remove('${level.value}:${file.value}');
        pos = file.next;
      case 7:
        final level = _readVarint(edit, pos);
        if (level == null) return;
        final file = _readVarint(edit, level.next);
        if (file == null) return;
        final size = _readVarint(edit, file.next);
        if (size == null) return;
        final smallest = _readLengthPrefixedSlice(edit, size.next);
        if (smallest == null) return;
        final largest = _readLengthPrefixedSlice(edit, smallest.next);
        if (largest == null) return;
        live['${level.value}:${file.value}'] = file.value;
        pos = largest.next;
      default:
        return;
    }
  }
}

Uint8List? _readSstBlock(
  Uint8List fileBuffer,
  ({int offset, int size, int next}) handle,
  _ReadBudget budget,
) {
  final blockEnd = handle.offset + handle.size;
  if (handle.offset < 0 ||
      handle.size < 0 ||
      blockEnd + 5 > fileBuffer.length) {
    return null;
  }
  final raw = Uint8List.sublistView(fileBuffer, handle.offset, blockEnd);
  final compressionType = fileBuffer[blockEnd];
  if (compressionType == 0) return raw;
  if (compressionType == 1) {
    try {
      return _snappyUncompress(raw, budget);
    } on FormatException {
      return null;
    }
  }
  return null;
}

List<({Uint8List key, Uint8List value})> _parseBlockEntries(Uint8List? block) {
  if (block == null || block.length < 4) return const [];
  final bd = ByteData.sublistView(block);
  final restartCount = bd.getUint32(block.length - 4, Endian.little);
  final entriesEnd = block.length - 4 - restartCount * 4;
  if (entriesEnd < 0 || entriesEnd > block.length) return const [];

  final entries = <({Uint8List key, Uint8List value})>[];
  var pos = 0;
  var prevKey = Uint8List(0);

  while (pos < entriesEnd) {
    final shared = _readVarint(block, pos, maxBytes: 5);
    if (shared == null) break;
    pos = shared.next;
    final nonShared = _readVarint(block, pos, maxBytes: 5);
    if (nonShared == null) break;
    pos = nonShared.next;
    final valueLen = _readVarint(block, pos, maxBytes: 5);
    if (valueLen == null) break;
    pos = valueLen.next;

    if (shared.value < 0 ||
        nonShared.value < 0 ||
        valueLen.value < 0 ||
        shared.value > prevKey.length ||
        pos + nonShared.value + valueLen.value > entriesEnd) {
      break;
    }

    final key = Uint8List(shared.value + nonShared.value);
    if (shared.value > 0) {
      key.setRange(0, shared.value, prevKey, 0);
    }
    if (nonShared.value > 0) {
      key.setRange(shared.value, key.length, block, pos);
    }
    pos += nonShared.value;

    final value = Uint8List.sublistView(block, pos, pos + valueLen.value);
    pos += valueLen.value;

    prevKey = key;
    entries.add((key: key, value: value));
  }
  return entries;
}

void _readTableEntries(
  Uint8List fileBuffer,
  void Function(Uint8List userKey, int sequence, int valueType, Uint8List? value)
  onEntry,
  _ReadBudget budget,
) {
  if (fileBuffer.length < _levelDbSstFooterBytes) return;
  final footer = Uint8List.sublistView(
    fileBuffer,
    fileBuffer.length - _levelDbSstFooterBytes,
  );
  for (var i = 0; i < 8; i++) {
    if (footer[40 + i] != _levelDbTableMagic[i]) return;
  }
  final metaIndex = _readBlockHandle(footer, 0);
  if (metaIndex == null) return;
  final index = _readBlockHandle(footer, metaIndex.next);
  if (index == null) return;

  final indexBlock = _readSstBlock(fileBuffer, index, budget);
  for (final indexEntry in _parseBlockEntries(indexBlock)) {
    final dataHandle = _readBlockHandle(indexEntry.value, 0);
    if (dataHandle == null) continue;
    final dataBlock = _readSstBlock(fileBuffer, dataHandle, budget);
    for (final entry in _parseBlockEntries(dataBlock)) {
      if (entry.key.length < 8) continue;
      final userKeyLen = entry.key.length - 8;
      final userKey = Uint8List.sublistView(entry.key, 0, userKeyLen);
      final bd = ByteData.sublistView(entry.key, userKeyLen, entry.key.length);
      final lo = bd.getUint32(0, Endian.little);
      final hi = bd.getUint32(4, Endian.little);
      final valueType = lo & 0xff;
      final sequence = (hi * 0x1000000) + (lo >> 8);
      onEntry(userKey, sequence, valueType, entry.value);
    }
  }
}

List<Uint8List> _readLogPhysicalRecords(Uint8List buffer) {
  final records = <Uint8List>[];
  var blockStart = 0;
  BytesBuilder? fragment;

  while (blockStart < buffer.length) {
    final blockEnd = blockStart + _levelDbLogBlockBytes < buffer.length
        ? blockStart + _levelDbLogBlockBytes
        : buffer.length;
    var pos = blockStart;

    while (pos + 7 <= blockEnd) {
      final bd = ByteData.sublistView(buffer, pos, pos + 7);
      final length = bd.getUint16(4, Endian.little);
      final type = buffer[pos + 6];
      pos += 7;

      if (length == 0 && type == 0) break;
      if (pos + length > blockEnd) break;

      final payload = Uint8List.sublistView(buffer, pos, pos + length);
      pos += length;

      if (type == 1) {
        records.add(payload);
        fragment = null;
      } else if (type == 2) {
        fragment = BytesBuilder(copy: false)..add(payload);
      } else if (type == 3 && fragment != null) {
        fragment.add(payload);
      } else if (type == 4 && fragment != null) {
        fragment.add(payload);
        records.add(fragment.takeBytes());
        fragment = null;
      }
    }
    blockStart += _levelDbLogBlockBytes;
  }
  return records;
}

void _readLogEntries(
  Uint8List buffer,
  void Function(Uint8List userKey, int sequence, int valueType, Uint8List? value)
  onEntry,
) {
  for (final batch in _readLogPhysicalRecords(buffer)) {
    if (batch.length < 12) continue;
    final bd = ByteData.sublistView(batch, 0, 12);
    final seqLo = bd.getUint32(0, Endian.little);
    final seqHi = bd.getUint32(4, Endian.little);
    final startSeq = (seqHi * 0x100000000) + seqLo;
    final count = bd.getUint32(8, Endian.little);
    var pos = 12;

    for (var i = 0; i < count && pos < batch.length; i++) {
      final valueType = batch[pos++];
      final key = _readLengthPrefixedSlice(batch, pos);
      if (key == null) break;
      pos = key.next;

      Uint8List? value;
      if (valueType == 1) {
        final parsed = _readLengthPrefixedSlice(batch, pos);
        if (parsed == null) break;
        value = parsed.slice;
        pos = parsed.next;
      } else if (valueType != 0) {
        break;
      }
      onEntry(key.slice, startSeq + i, valueType, value);
    }
  }
}

int _decodeTruncatedInt(Uint8List bytes) {
  var result = 0;
  for (var i = 0; i < bytes.length; i++) {
    result |= bytes[i] << (i * 8);
  }
  return result;
}

String _decodeUtf16Be(Uint8List bytes) {
  final units = Uint16List(bytes.length ~/ 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < units.length; i++) {
    units[i] = bd.getUint16(i * 2, Endian.big);
  }
  return String.fromCharCodes(units);
}

String _decodeUtf16Le(Uint8List bytes) {
  final units = Uint16List(bytes.length ~/ 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < units.length; i++) {
    units[i] = bd.getUint16(i * 2, Endian.little);
  }
  return String.fromCharCodes(units);
}

Uint8List _makeIdbPrefix(
  int dbId,
  int objStoreId,
  int indexId, [
  List<int> suffix = const [],
]) {
  int countBytes(int val) {
    if (val <= 0) return 1;
    var count = 0;
    var v = val;
    while (v > 0) {
      count++;
      v >>= 8;
    }
    return count;
  }

  void writeLe(BytesBuilder out, int val, int len) {
    var v = val;
    for (var i = 0; i < len; i++) {
      out.addByte(v & 0xff);
      v >>= 8;
    }
  }

  final dbSize = countBytes(dbId);
  final storeSize = countBytes(objStoreId);
  final idxSize = countBytes(indexId);
  final first = ((dbSize - 1) << 5) | ((storeSize - 1) << 2) | (idxSize - 1);
  final out = BytesBuilder(copy: false)..addByte(first);
  writeLe(out, dbId, dbSize);
  writeLe(out, objStoreId, storeSize);
  writeLe(out, indexId, idxSize);
  if (suffix.isNotEmpty) out.add(suffix);
  return out.takeBytes();
}

({int dbId, int objStoreId, int indexId, int length})? _readIdbPrefix(
  Uint8List key,
) {
  if (key.isEmpty) return null;
  final lengths = key[0];
  final dbSize = ((lengths >> 5) & 0x07) + 1;
  final storeSize = ((lengths >> 2) & 0x07) + 1;
  final idxSize = (lengths & 0x03) + 1;
  final total = 1 + dbSize + storeSize + idxSize;
  if (key.length < total) return null;

  int readLe(int start, int count) {
    var res = 0;
    for (var i = 0; i < count; i++) {
      res |= key[start + i] << (i * 8);
    }
    return res;
  }

  return (
    dbId: readLe(1, dbSize),
    objStoreId: readLe(1 + dbSize, storeSize),
    indexId: readLe(1 + dbSize + storeSize, idxSize),
    length: total,
  );
}

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// Deduplicates rows by business key `id` (falling back to `local_id`), keeping
/// the row with the greatest `updated_at` timestamp string.
List<Map<String, Object?>> dedupTermiusTableRows(
  List<Map<String, Object?>> rows,
) {
  final latest = <String, Map<String, Object?>>{};
  final keyless = <Map<String, Object?>>[];

  for (final row in rows) {
    final id = row['id'];
    final localId = row['local_id'];
    String? key;
    if (id != null && id.toString().isNotEmpty) {
      key = 'id:$id';
    } else if (localId != null && localId.toString().isNotEmpty) {
      key = 'local:$localId';
    }
    if (key == null) {
      keyless.add(row);
      continue;
    }
    final prev = latest[key];
    final currUpdated = (row['updated_at'] ?? '').toString();
    final prevUpdated = (prev?['updated_at'] ?? '').toString();
    if (prev == null || currUpdated.compareTo(prevUpdated) >= 0) {
      latest[key] = row;
    }
  }

  bool isSoftDeleted(Map<String, Object?> row) =>
      row['is_deleted'] == true ||
      row['deleted'] == true ||
      (row['deleted_at'] is String &&
          (row['deleted_at'] as String).trim().isNotEmpty);

  return [
    for (final row in latest.values)
      if (!isSoftDeleted(row)) row,
    for (final row in keyless)
      if (!isSoftDeleted(row)) row,
  ];
}

/// Reads Termius IndexedDB tables from an in-memory LevelDB snapshot.
TermiusRawTables readTermiusIndexedDbTables(
  Map<String, Uint8List> levelDbFiles, {
  Set<String> wantedDatabases = wantedTermiusDatabases,
  bool keepAllVersions = false,
}) {
  final budget = _ReadBudget();
  final entries = _readLiveLevelDbEntries(levelDbFiles, budget);

  // 1. Resolve dbId -> database name from global metadata (`00 00 00 00 C9`).
  final dbNamesById = <int, String>{};
  for (final entry in entries.values) {
    if (entry.valueType != 1 || entry.value == null) continue;
    if (!_startsWith(entry.userKey, const [0x00, 0x00, 0x00, 0x00, 0xc9])) {
      continue;
    }
    var pos = 5;
    final originLen = _readVarint(entry.userKey, pos);
    if (originLen == null) continue;
    pos = originLen.next + originLen.value * 2;
    if (pos > entry.userKey.length) continue;
    final nameLen = _readVarint(entry.userKey, pos);
    if (nameLen == null) continue;
    pos = nameLen.next;
    final nameBytesEnd = pos + nameLen.value * 2;
    if (nameBytesEnd > entry.userKey.length) continue;
    final dbName = _decodeUtf16Be(
      Uint8List.sublistView(entry.userKey, pos, nameBytesEnd),
    );
    final dbId = _decodeTruncatedInt(entry.value!);
    dbNamesById[dbId] = dbName;
  }

  // 2. Discover first objectStoreId per wanted dbId from ObjectStoreMetadata
  // (`makePrefix(dbId, 0, 0, [50])`), with automatic fallback to lowest storeId
  // observed in object data records (`indexId == 1`).
  final wantedDbIds = <int, String>{
    for (final entry in dbNamesById.entries)
      if (wantedDatabases.contains(entry.value)) entry.key: entry.value,
  };

  final firstStoreByDb = <int, int>{};
  for (final dbId in wantedDbIds.keys) {
    final metaPrefix = _makeIdbPrefix(dbId, 0, 0, const [50]);
    for (final entry in entries.values) {
      if (entry.valueType != 1 || entry.value == null) continue;
      if (!_startsWith(entry.userKey, metaPrefix)) continue;
      final storeIdVar = _readVarint(entry.userKey, metaPrefix.length);
      if (storeIdVar == null || storeIdVar.next >= entry.userKey.length) {
        continue;
      }
      final metaType = entry.userKey[storeIdVar.next];
      if (metaType == 0) {
        final storeId = storeIdVar.value;
        final prev = firstStoreByDb[dbId];
        if (prev == null || storeId < prev) {
          firstStoreByDb[dbId] = storeId;
        }
      }
    }
  }

  // 3. Collect and deserialize primary object records (`indexId == 1`).
  final rawRowsByDbStore = <int, Map<int, List<Map<String, Object?>>>>{};
  final malformedByDbStore = <int, Map<int, int>>{};
  final rowsByDb = <int, int>{};
  final sortedEntries = entries.values.toList()
    ..sort((a, b) => a.sequence.compareTo(b.sequence));

  for (final entry in sortedEntries) {
    if (entry.valueType != 1 || entry.value == null || entry.value!.isEmpty) {
      continue;
    }
    final prefix = _readIdbPrefix(entry.userKey);
    if (prefix == null ||
        prefix.dbId <= 0 ||
        prefix.objStoreId <= 0 ||
        prefix.indexId != 1) {
      continue;
    }
    if (!wantedDbIds.containsKey(prefix.dbId)) continue;

    if ((rowsByDb[prefix.dbId] = (rowsByDb[prefix.dbId] ?? 0) + 1) >
        maxTermiusIndexedDbRowsPerTable) {
      throw const TermiusIndexedDbLimitException('rowsPerTable');
    }
    final decoded = _decodeIndexedDbRecordValue(entry.value!, budget);
    if (decoded is Map<String, Object?>) {
      rawRowsByDbStore
          .putIfAbsent(prefix.dbId, () => {})
          .putIfAbsent(prefix.objStoreId, () => [])
          .add(decoded);
    } else {
      final perStore = malformedByDbStore.putIfAbsent(prefix.dbId, () => {});
      perStore[prefix.objStoreId] = (perStore[prefix.objStoreId] ?? 0) + 1;
    }
  }

  final tables = <String, List<Map<String, Object?>>>{};
  final before = <String, int>{};
  final malformed = <String, int>{};

  for (final dbEntry in wantedDbIds.entries) {
    final dbId = dbEntry.key;
    final dbName = dbEntry.value;
    final stores = rawRowsByDbStore[dbId] ?? const {};
    final badStores = malformedByDbStore[dbId] ?? const {};
    if (stores.isEmpty && badStores.isEmpty) continue;
    final storeIds = {...stores.keys, ...badStores.keys}.toList()..sort();
    final storeId = firstStoreByDb[dbId] ?? storeIds.first;
    final bad = badStores[storeId] ?? 0;
    if (bad > 0) malformed[dbName] = bad;
    final rows = stores[storeId] ?? const <Map<String, Object?>>[];
    if (rows.isEmpty) continue;
    before[dbName] = rows.length;
    tables[dbName] = keepAllVersions ? rows : dedupTermiusTableRows(rows);
  }

  return TermiusRawTables(
    tables: tables,
    countsBeforeDedup: before,
    malformedRecords: malformed,
  );
}

/// Unwraps the IndexedDB value version + Blink SSV header and runs the V8
/// structured-clone deserializer.
Object? decodeIndexedDbRecordValue(Uint8List rawValue) =>
    _decodeIndexedDbRecordValue(rawValue, _ReadBudget());

Object? _decodeIndexedDbRecordValue(Uint8List rawValue, _ReadBudget budget) {
  final valueVer = _readVarint(rawValue, 0);
  if (valueVer == null || valueVer.next >= rawValue.length) return null;
  final blinkSlice = Uint8List.sublistView(rawValue, valueVer.next);
  return _unwrapBlinkAndDeserializeV8(blinkSlice, budget, 0);
}

Object? _unwrapBlinkAndDeserializeV8(
  Uint8List buffer,
  _ReadBudget budget,
  int wrapDepth,
) {
  if (wrapDepth > 1) return null;
  if (buffer.isEmpty || buffer[0] != 0xff) return null;
  final blinkVer = _readVarint(buffer, 1);
  if (blinkVer == null) return null;
  var pos = blinkVer.next;

  if (blinkVer.value == 0x11) {
    if (pos >= buffer.length) return null;
    final wrappingMode = buffer[pos++];
    if (wrappingMode == 0x02) {
      // kCompressedWithSnappy
      try {
        final decompressed = _snappyUncompress(
          Uint8List.sublistView(buffer, pos),
          budget,
        );
        return _unwrapBlinkAndDeserializeV8(
          decompressed,
          budget,
          wrapDepth + 1,
        );
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  // Blink wire format >= 21 prepends a 13-byte trailer header starting at 0xFE.
  if (blinkVer.value >= 21 && pos < buffer.length && buffer[pos] == 0xfe) {
    if (pos + 13 > buffer.length) return null;
    pos += 13;
  }

  try {
    final reader = _V8ValueDeserializer(Uint8List.sublistView(buffer, pos));
    return reader.read();
  } on TermiusIndexedDbLimitException {
    rethrow;
  } on Object {
    return null;
  }
}

class _UndefinedSentinel {
  const _UndefinedSentinel();
}

const _undefined = _UndefinedSentinel();

class _V8ValueDeserializer {
  _V8ValueDeserializer(this._buf) {
    final first = _readTag();
    if (first != 0xff) {
      throw const FormatException('Missing V8 serialization version tag');
    }
    version = _readVarintChecked();
  }

  final Uint8List _buf;
  int _pos = 0;
  int _depth = 0;
  late final int version;
  final List<Object?> _objects = [];

  /// Rejects element counts that cannot fit in the remaining input (each
  /// element needs at least one byte) before allocating for them.
  int _checkedCount(int count) {
    if (count < 0 || count > _buf.length - _pos) {
      throw const FormatException('V8 element count exceeds input');
    }
    return count;
  }

  int _readTag() {
    while (_pos < _buf.length) {
      final b = _buf[_pos++];
      if (b != 0x00 && b != 0x3f) {
        if (b == 0x3f) continue;
        return b;
      }
      if (b == 0x3f) {
        // '?' token_kVerifyObjectCount followed by varint count.
        _readVarintChecked();
      }
    }
    throw const FormatException('Unexpected EOF reading V8 tag');
  }

  int? _peekTag() {
    final saved = _pos;
    while (_pos < _buf.length) {
      final b = _buf[_pos++];
      if (b == 0x00) continue;
      if (b == 0x3f) {
        _readVarintChecked();
        continue;
      }
      _pos = saved;
      return b;
    }
    _pos = saved;
    return null;
  }

  void _consumeExpectedTag(int expected) {
    final actual = _readTag();
    if (actual != expected) {
      throw FormatException('Expected V8 tag $expected, got $actual');
    }
  }

  int _readVarintChecked() {
    final parsed = _readVarint(_buf, _pos);
    if (parsed == null) {
      throw const FormatException('Truncated V8 varint');
    }
    _pos = parsed.next;
    return parsed.value;
  }

  Uint8List _readRaw(int len) {
    if (len < 0 || _pos + len > _buf.length) {
      throw const FormatException('Truncated V8 slice');
    }
    final view = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return view;
  }

  double _readDouble() {
    final raw = _readRaw(8);
    return ByteData.sublistView(raw).getFloat64(0, Endian.little);
  }

  int _readZigZag() {
    final u = _readVarintChecked();
    return (u & 1) != 0 ? -((u >> 1) + 1) : (u >> 1);
  }

  int _readBigInt() {
    final bitfield = _readVarintChecked();
    final isNeg = (bitfield & 0x01) != 0;
    final byteLen = bitfield >> 1;
    // V8 encodes byte length in bits [1..30] on modern builds (`bitfield >> 1`),
    // or word count in older builds; guard bounds safely.
    final safeLen = byteLen <= _buf.length - _pos
        ? byteLen
        : ((bitfield >> 4) * 8);
    final raw = _readRaw(safeLen);
    var val = 0;
    for (var i = 0; i < raw.length && i < 8; i++) {
      val |= raw[i] << (8 * i);
    }
    return isNeg ? -val : val;
  }

  Object? read() => _readObject();

  Object? _readObject() {
    final value = _readObjectInternal();
    if (_peekTag() == 0x56 /* 'V' ArrayBufferView */ ) {
      _consumeExpectedTag(0x56);
      _readVarintChecked(); // subtag
      final offset = _readVarintChecked();
      final length = _readVarintChecked();
      if (version >= 14) {
        _readVarintChecked(); // flags
      }
      if (value is Uint8List && offset + length <= value.length) {
        return Uint8List.sublistView(value, offset, offset + length);
      }
    }
    return value == _undefined ? null : value;
  }

  Object? _readObjectInternal() {
    if (++_depth > _maxV8Depth) {
      throw const FormatException('V8 value nesting too deep');
    }
    try {
      return _readObjectInternalTag(_readTag());
    } finally {
      _depth--;
    }
  }

  Object? _readObjectInternalTag(int tag) {
    switch (tag) {
      case 0x5f /* '_' undefined */ || 0x2d /* '-' hole */ :
        return _undefined;
      case 0x30 /* '0' null */ :
        return null;
      case 0x54 /* 'T' true */ :
        return true;
      case 0x46 /* 'F' false */ :
        return false;
      case 0x49 /* 'I' Int32 ZigZag */ :
        return _readZigZag();
      case 0x55 /* 'U' Uint32 */ :
        return _readVarintChecked();
      case 0x4e /* 'N' Double */ :
        return _readDouble();
      case 0x5a /* 'Z' BigInt */ :
        return _readBigInt();
      case 0x53 /* 'S' Utf8String */ :
        final len = _readVarintChecked();
        return utf8.decode(_readRaw(len), allowMalformed: true);
      case 0x22 /* '"' OneByteString (Latin-1) */ :
        final len = _readVarintChecked();
        return latin1.decode(_readRaw(len));
      case 0x63 /* 'c' TwoByteString (UTF-16LE) */ :
        final len = _readVarintChecked();
        return _decodeUtf16Le(_readRaw(len));
      case 0x5e /* '^' ObjectReference */ :
        final id = _readVarintChecked();
        if (id < 0 || id >= _objects.length) {
          throw const FormatException('Invalid V8 object reference');
        }
        return _objects[id];
      case 0x44 /* 'D' Date */ :
        final ms = _readDouble();
        final iso = DateTime.fromMillisecondsSinceEpoch(
          ms.round(),
          isUtc: true,
        ).toIso8601String();
        _objects.add(iso);
        return iso;
      case 0x79 /* 'y' TrueObject */ :
        _objects.add(true);
        return true;
      case 0x78 /* 'x' FalseObject */ :
        _objects.add(false);
        return false;
      case 0x6e /* 'n' NumberObject */ :
        final n = _readDouble();
        _objects.add(n);
        return n;
      case 0x7a /* 'z' BigIntObject */ :
        final b = _readBigInt();
        _objects.add(b);
        return b;
      case 0x73 /* 's' StringObject */ :
        final s = version < 12
            ? utf8.decode(_readRaw(_readVarintChecked()), allowMalformed: true)
            : (_readObject()?.toString() ?? '');
        _objects.add(s);
        return s;
      case 0x52 /* 'R' RegExp */ :
        final pattern = version < 12
            ? utf8.decode(_readRaw(_readVarintChecked()), allowMalformed: true)
            : (_readObject()?.toString() ?? '');
        _readVarintChecked(); // flags
        _objects.add(pattern);
        return pattern;
      case 0x6f /* 'o' BeginJSObject */ :
        final map = <String, Object?>{};
        _objects.add(map);
        var count = 0;
        while (_peekTag() != 0x7b /* '{' EndJSObject */ ) {
          final k = _readObjectInternal();
          final v = _readObjectInternal();
          count++;
          if (k != _undefined && v != _undefined) {
            map[k.toString()] = v;
          } else if (k != _undefined && v == _undefined) {
            // Undefined property still counts toward V8's property count.
          }
        }
        _consumeExpectedTag(0x7b);
        final expected = _readVarintChecked();
        if (count != expected) {
          throw const FormatException('V8 JSObject property count mismatch');
        }
        return map;
      case 0x41 /* 'A' BeginDenseJSArray */ :
        final length = _checkedCount(_readVarintChecked());
        final list = List<Object?>.filled(length, null, growable: true);
        _objects.add(list);
        for (var i = 0; i < length; i++) {
          final elem = _readObjectInternal();
          list[i] = elem == _undefined ? null : elem;
        }
        var propCount = 0;
        while (_peekTag() != 0x24 /* '$' EndDenseJSArray */ ) {
          final k = _readObjectInternal();
          final v = _readObjectInternal();
          propCount++;
          final idx = int.tryParse(k.toString());
          if (idx != null && idx >= 0 && idx < list.length && v != _undefined) {
            list[idx] = v;
          }
        }
        _consumeExpectedTag(0x24);
        final expectedProps = _readVarintChecked();
        _readVarintChecked(); // expectedLength
        if (propCount != expectedProps) {
          throw const FormatException('V8 DenseArray property count mismatch');
        }
        return list;
      case 0x61 /* 'a' BeginSparseJSArray */ :
        final length = _readVarintChecked();
        final safeCap = length > 65536 ? 65536 : length;
        final list = List<Object?>.filled(safeCap, null, growable: true);
        _objects.add(list);
        var propCount = 0;
        while (_peekTag() != 0x40 /* '@' EndSparseJSArray */ ) {
          final k = _readObjectInternal();
          final v = _readObjectInternal();
          propCount++;
          final idx = int.tryParse(k.toString());
          if (idx != null && idx >= 0 && idx < list.length && v != _undefined) {
            list[idx] = v;
          }
        }
        _consumeExpectedTag(0x40);
        final expectedProps = _readVarintChecked();
        _readVarintChecked(); // expectedLength
        if (propCount != expectedProps) {
          throw const FormatException('V8 SparseArray property count mismatch');
        }
        return list;
      case 0x3b /* ';' BeginJSMap */ :
        final map = <String, Object?>{};
        _objects.add(map);
        var entries = 0;
        while (_peekTag() != 0x3a /* ':' EndJSMap */ ) {
          final k = _readObjectInternal();
          final v = _readObjectInternal();
          entries += 2;
          if (k != _undefined && v != _undefined) {
            map[k.toString()] = v;
          }
        }
        _consumeExpectedTag(0x3a);
        final expectedEntries = _readVarintChecked();
        if (entries != expectedEntries) {
          throw const FormatException('V8 Map entry count mismatch');
        }
        return map;
      case 0x27 /* ''' BeginJSSet */ :
        final items = <Object?>[];
        _objects.add(items);
        while (_peekTag() != 0x2c /* ',' EndJSSet */ ) {
          final v = _readObjectInternal();
          items.add(v == _undefined ? null : v);
        }
        _consumeExpectedTag(0x2c);
        final expectedLen = _readVarintChecked();
        if (items.length != expectedLen) {
          throw const FormatException('V8 Set length mismatch');
        }
        return items;
      case 0x42 /* 'B' ArrayBuffer */ :
        final len = _readVarintChecked();
        final bytes = Uint8List.fromList(_readRaw(len));
        _objects.add(bytes);
        return bytes;
      default:
        throw FormatException('Unsupported V8 tag: 0x${tag.toRadixString(16)}');
    }
  }
}
