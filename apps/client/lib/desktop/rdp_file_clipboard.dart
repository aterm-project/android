import 'dart:typed_data';

/// MS-RDPECLIP CLIPRDR_FILELIST / FILEDESCRIPTORW (2.2.5.2.3.1) codec plus
/// path safety rules shared by upload (local → remote) and download.
const fileDescriptorSize = 592;
const maxClipboardFiles = 4096;
const maxClipboardDepth = 32;
const _fdAttributes = 0x00000004;
const _fdFileSize = 0x00000040;
const _fdWriteTime = 0x00000020;
const _fdShowProgress = 0x00004000;
const _fileAttributeDirectory = 0x10;
const _fileAttributeArchive = 0x20;
// Windows FILETIME epoch (1601-01-01) to Unix epoch, in 100 ns units.
const _fileTimeOffset = 116444736000000000;

class ClipboardFileEntry {
  ClipboardFileEntry({
    required this.relativePath,
    required this.isDirectory,
    required this.size,
    this.modified,
    this.sizeKnown = true,
  }) {
    if (!isSafeRelativeClipboardPath(relativePath) || size < 0) {
      throw FormatException('Unsafe clipboard file name: $relativePath');
    }
  }

  /// Backslash-separated path relative to the copied root.
  final String relativePath;
  final bool isDirectory;
  final int size;
  final DateTime? modified;

  /// False when the remote descriptor omitted FD_FILESIZE; the size is then
  /// learned from FILECONTENTS_SIZE under a stricter cap.
  final bool sizeKnown;

  List<String> get segments => relativePath.split('\\');
}

const _reservedNames = {
  'con', 'prn', 'aux', 'nul', 'clock\$', //
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Remote names are untrusted. Each segment must be a plain file name: no
/// separators, drive letters, `.`/`..`, control or Windows-reserved
/// characters, reserved device names, or trailing dots/spaces.
bool isSafeClipboardSegment(String segment) {
  if (segment.isEmpty || segment.length > 255) return false;
  if (segment == '.' || segment == '..') return false;
  if (segment.endsWith('.') || segment.endsWith(' ')) return false;
  if (segment.runes.any((r) => r < 32 || r == 0x7f)) return false;
  if (RegExp(r'[<>:"/\\|?*]').hasMatch(segment)) return false;
  final stem = segment.split('.').first.toLowerCase().trimRight();
  return !_reservedNames.contains(stem);
}

bool isSafeRelativeClipboardPath(String path) {
  if (path.isEmpty || path.length > 259) return false;
  final parts = path.split('\\');
  return parts.length <= maxClipboardDepth && parts.every(isSafeClipboardSegment);
}

Uint8List encodeFileList(List<ClipboardFileEntry> entries) {
  if (entries.isEmpty || entries.length > maxClipboardFiles) {
    throw const FormatException('Clipboard file count out of range');
  }
  final out = ByteData(4 + entries.length * fileDescriptorSize);
  out.setUint32(0, entries.length, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final base = 4 + i * fileDescriptorSize;
    var flags = _fdAttributes | _fdFileSize | _fdShowProgress;
    if (e.modified != null) flags |= _fdWriteTime;
    out.setUint32(base, flags, Endian.little);
    // clsid(16) sizel(8) pointl(8) remain zero.
    out.setUint32(
      base + 36,
      e.isDirectory ? _fileAttributeDirectory : _fileAttributeArchive,
      Endian.little,
    );
    if (e.modified != null) {
      final ft =
          e.modified!.toUtc().microsecondsSinceEpoch * 10 + _fileTimeOffset;
      out.setUint32(base + 56, ft & 0xffffffff, Endian.little);
      out.setUint32(base + 60, (ft >> 32) & 0xffffffff, Endian.little);
    }
    final size = e.isDirectory ? 0 : e.size;
    out.setUint32(base + 64, (size >> 32) & 0xffffffff, Endian.little);
    out.setUint32(base + 68, size & 0xffffffff, Endian.little);
    final units = e.relativePath.codeUnits;
    if (units.length > 259) throw const FormatException('File name too long');
    for (var j = 0; j < units.length; j++) {
      out.setUint16(base + 72 + j * 2, units[j], Endian.little);
    }
  }
  return out.buffer.asUint8List();
}

/// Parse a remote list. Throws [FormatException] on structural errors or any
/// unsafe name, so a hostile list is rejected as a whole.
List<ClipboardFileEntry> decodeFileList(Uint8List bytes) {
  if (bytes.length < 4) throw const FormatException('Short file list');
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(0, Endian.little);
  if (count == 0 ||
      count > maxClipboardFiles ||
      bytes.length != 4 + count * fileDescriptorSize) {
    throw const FormatException('Invalid file list length');
  }
  final entries = <ClipboardFileEntry>[];
  final seen = <String>{};
  for (var i = 0; i < count; i++) {
    final base = 4 + i * fileDescriptorSize;
    final flags = data.getUint32(base, Endian.little);
    final attributes = flags & _fdAttributes != 0
        ? data.getUint32(base + 36, Endian.little)
        : 0;
    final units = <int>[];
    for (var j = 0; j < 260; j++) {
      final unit = data.getUint16(base + 72 + j * 2, Endian.little);
      if (unit == 0) break;
      units.add(unit);
    }
    if (units.length == 260) throw const FormatException('Unterminated name');
    final name = String.fromCharCodes(units);
    final high = data.getUint32(base + 64, Endian.little);
    final low = data.getUint32(base + 68, Endian.little);
    final size = flags & _fdFileSize != 0 ? high * 0x100000000 + low : -1;
    DateTime? modified;
    if (flags & _fdWriteTime != 0) {
      final ft =
          data.getUint32(base + 60, Endian.little) * 0x100000000 +
          data.getUint32(base + 56, Endian.little);
      final micros = (ft - _fileTimeOffset) ~/ 10;
      if (micros > 0 && micros < 8640000000000000) {
        modified = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      }
    }
    final isDirectory = attributes & _fileAttributeDirectory != 0;
    if (!seen.add(name.toLowerCase())) {
      throw const FormatException('Duplicate clipboard file name');
    }
    entries.add(
      ClipboardFileEntry(
        relativePath: name,
        isDirectory: isDirectory,
        // Size may be absent; downloads then query FILECONTENTS_SIZE.
        size: isDirectory ? 0 : (size < 0 ? 0 : size),
        modified: modified,
        sizeKnown: isDirectory || size >= 0,
      ),
    );
  }
  return entries;
}

/// Picks `name`, `name (2)`, ... that does not collide with [exists].
String uniqueName(String name, bool Function(String candidate) exists) {
  if (!exists(name)) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; i < 10000; i++) {
    final candidate = '$stem ($i)$ext';
    if (!exists(candidate)) return candidate;
  }
  throw const FormatException('Too many files with the same name');
}

/// Summary for UI: top-level names only.
List<String> topLevelNames(List<ClipboardFileEntry> entries) => [
  for (final e in entries)
    if (!e.relativePath.contains('\\')) e.relativePath,
];
