/// Standard OpenSSH bundle: a ZIP holding `atermius-ssh/config`, opted-in
/// private key files under `atermius-ssh/keys/`, optional `*-cert.pub` user
/// certificates and a README. Extract it into `~/.ssh` and add
/// `Include ~/.ssh/atermius-ssh/config` to use it with OpenSSH; Termius'
/// `~/.ssh` import reads the same files. This is NOT a Termius vault format.
///
/// Import accepts only a selected bundle: bounded size and entry count,
/// stored/deflate entries only, no encryption, ZIP64, symlinks, absolute or
/// `..` paths. IdentityFile/CertificateFile values resolve only to entries of
/// that bundle; nothing on disk is ever opened.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show InputStream, Inflate, OutputMemoryStream, getCrc32;

import 'openssh_config_import.dart';
import 'termius_openssh.dart';
import 'termius_transfer.dart';

const maxTermiusBundleBytes = 4 * 1024 * 1024;
const maxTermiusBundleEntries = 512;
const maxTermiusBundleEntryBytes = 512 * 1024;
const _maxBundleTotalBytes = 8 * 1024 * 1024;
const termiusBundleRoot = 'atermius-ssh';

// ---------------------------------------------------------------------------
// Export

class TermiusOpenSshBundleExporter {
  const TermiusOpenSshBundleExporter._();

  static TermiusExportResult export(
    TermiusCatalog catalog, {
    TermiusExportOptions options = const TermiusExportOptions(),
    TermiusCertificateBridge? certificates,
    DateTime? now,
  }) {
    final issues = <TermiusIssue>[];
    final blocks = TermiusExporter.sshBlocks(
      catalog,
      options,
      issues,
      certificates: certificates,
    );
    final files = <({String path, Uint8List bytes, bool secret})>[];
    final identityFiles = <String, ({String identity, String? certificate})>{};
    final keyNameByText = <String, String>{};
    final usedNames = <String>{};
    var keyFiles = 0;
    var keysOmitted = 0;
    var passphrases = 0;
    var passwords = 0;
    var certificatesOmitted = 0;
    for (final block in blocks) {
      final login = block.login;
      if (login == null) continue;
      if (login.password != null) passwords++;
      final key = login.privateKey;
      if (key == null) continue;
      if (!options.includePrivateKeys) {
        keysOmitted++;
        if (login.certificate != null) certificatesOmitted++;
        continue;
      }
      if (login.passphrase != null && login.passphrase!.isNotEmpty) {
        passphrases++;
      }
      // Hosts sharing one key text share one file.
      final shareKey = '$key\u0000${login.certificate ?? ''}';
      var name = keyNameByText[shareKey];
      if (name == null) {
        final base = _fileName(
          login.source == TermiusLoginSource.hostLogin
              ? block.alias
              : (catalog.credentialById(login.credentialId ?? '')?.name ??
                    block.alias),
        );
        // Reserve the whole output namespace (key AND its -cert.pub) so a
        // key named like another key's certificate can never collide.
        name = base;
        var suffix = 2;
        bool free(String candidate) =>
            !usedNames.contains(candidate.toLowerCase()) &&
            !usedNames.contains('$candidate-cert.pub'.toLowerCase());
        while (!free(name!)) {
          name = '$base-${suffix++}';
        }
        usedNames
          ..add(name.toLowerCase())
          ..add('$name-cert.pub'.toLowerCase());
        keyNameByText[shareKey] = name;
        files.add((
          path: '$termiusBundleRoot/keys/$name',
          bytes: Uint8List.fromList(utf8.encode(_withTrailingNewline(key))),
          secret: true,
        ));
        keyFiles++;
        if (login.certificate != null) {
          files.add((
            path: '$termiusBundleRoot/keys/$name-cert.pub',
            bytes: Uint8List.fromList(
              utf8.encode(_withTrailingNewline(login.certificate!.trim())),
            ),
            secret: false,
          ));
        }
      }
      identityFiles[block.host.id] = (
        identity: '~/.ssh/$termiusBundleRoot/keys/$name',
        certificate: login.certificate == null
            ? null
            : '~/.ssh/$termiusBundleRoot/keys/$name-cert.pub',
      );
    }
    final config = TermiusExporter.writeSshConfig(
      blocks,
      issues,
      catalog: catalog,
      header:
          '# OpenSSH bundle exported by Atermius ${TermiusExporter.stamp(now)}\n'
          '# Extract into ~/.ssh and add to ~/.ssh/config:\n'
          '#   Include ~/.ssh/$termiusBundleRoot/config\n',
      identityFiles: identityFiles,
    );
    files.insert(0, (
      path: '$termiusBundleRoot/config',
      bytes: Uint8List.fromList(utf8.encode(config)),
      secret: false,
    ));
    files.add((
      path: '$termiusBundleRoot/README.txt',
      bytes: Uint8List.fromList(utf8.encode(_readme)),
      secret: false,
    ));
    void addCount(TermiusIssueCode code, int count) {
      if (count > 0) issues.add(TermiusIssue(code, count: count));
    }

    addCount(TermiusIssueCode.exportKeysOmitted, keysOmitted);
    addCount(TermiusIssueCode.exportCertificatesOmitted, certificatesOmitted);
    addCount(TermiusIssueCode.exportPassphraseNotExported, passphrases);
    addCount(TermiusIssueCode.exportPasswordsNotRepresented, passwords);
    // Never produce an artifact our own importer would refuse.
    final total = files.fold<int>(0, (sum, file) => sum + file.bytes.length);
    final blocked =
        files.length > maxTermiusBundleEntries ||
        files.any((file) => file.bytes.length > maxTermiusBundleEntryBytes) ||
        total + files.length * 200 > maxTermiusBundleBytes ||
        !TermiusExporter.sshConfigWithinImportLimits(config, blocks.length);
    if (blocked) {
      issues.add(
        const TermiusIssue(
          TermiusIssueCode.exportTooLarge,
          severity: TermiusIssueSeverity.blocking,
          detail: 'bundle',
        ),
      );
    }
    final zip = blocked
        ? null
        : TermiusZip.encode([
            for (final file in files)
              TermiusZipEntry(file.path, file.bytes, private: file.secret),
          ]);
    for (final file in files) {
      if (file.secret) file.bytes.fillRange(0, file.bytes.length, 0);
    }
    if (zip != null && zip.length > maxTermiusBundleBytes) {
      throw StateError('Bundle size estimate was exceeded.');
    }
    return TermiusExportResult(
      text: blocked ? '' : config,
      blocked: blocked,
      binary: zip,
      exportedHosts: blocks.length,
      keyFiles: keyFiles,
      issues: List.unmodifiable(issues),
      containsSecrets: keyFiles > 0 && !blocked,
      suggestedFileName:
          'atermius-openssh-bundle-${TermiusExporter.stamp(now)}.zip',
    );
  }

  static String _fileName(String value) {
    var name = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'^[._-]+'), '');
    if (name.isEmpty) name = 'key';
    if (name.length > 64) name = name.substring(0, 64);
    return 'id_$name';
  }

  static String _withTrailingNewline(String value) =>
      value.endsWith('\n') ? value : '$value\n';

  static const _readme = '''
Atermius OpenSSH bundle (standard OpenSSH files, not a Termius vault).

1. Extract this archive into your ~/.ssh directory so that the files are at
   ~/.ssh/atermius-ssh/config and ~/.ssh/atermius-ssh/keys/.
2. Add this line near the top of ~/.ssh/config:
       Include ~/.ssh/atermius-ssh/config
3. Keep key files private (chmod 600 on Linux/macOS).

Passwords are never written. Encrypted keys still need their passphrase.
Delete this archive after extracting if it contains private keys.
''';
}

// ---------------------------------------------------------------------------
// Import

class TermiusOpenSshBundleImporter {
  const TermiusOpenSshBundleImporter._();

  static TermiusImportDocument parseZip(List<int> bytes) {
    final TermiusZipArchive archive;
    try {
      archive = TermiusZip.decode(bytes);
    } on TermiusZipException catch (error) {
      return _failure(
        error.tooLarge
            ? TermiusIssueCode.bundleTooLarge
            : TermiusIssueCode.bundleInvalid,
        detail: error.detail,
      );
    }
    final rejected = [
      for (final path in archive.rejectedPaths)
        TermiusIssue(TermiusIssueCode.bundleEntryRejected, detail: _short(path)),
    ];
    var configs = archive.files.keys
        .where((path) => path == 'config' || path.endsWith('/config'))
        .toList();
    if (configs.isEmpty) {
      configs = archive.files.keys
          .where((path) => path == 'ssh_config' || path.endsWith('/ssh_config'))
          .toList();
    }
    configs.sort(
      (a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length),
    );
    if (configs.isEmpty) {
      return _failure(TermiusIssueCode.bundleConfigMissing, extra: rejected);
    }
    final shallowest = '/'.allMatches(configs.first).length;
    final top = configs.where((c) => '/'.allMatches(c).length == shallowest);
    if (top.length > 1) {
      return _failure(TermiusIssueCode.bundleConfigAmbiguous, extra: rejected);
    }
    final configPath = configs.first;
    final configBytes = archive.files[configPath]!;
    if (configBytes.length > maxOpenSshConfigBytes) {
      return _failure(TermiusIssueCode.fileTooLarge, extra: rejected);
    }
    final String source;
    try {
      source = utf8.decode(configBytes, allowMalformed: false);
    } on FormatException {
      return _failure(TermiusIssueCode.fileNotUtf8, extra: rejected);
    }
    final configDir = configPath.contains('/')
        ? configPath.substring(0, configPath.lastIndexOf('/'))
        : '';
    final document = TermiusOpenSshImporter.parse(
      source,
      bundle: _BundleFiles(archive.files, configDir),
    );
    return TermiusImportDocument(
      format: TermiusSourceFormat.openSsh,
      headers: const [],
      rows: document.rows,
      fileIssues: List.unmodifiable([...rejected, ...document.fileIssues]),
    );
  }

  static TermiusImportDocument _failure(
    TermiusIssueCode code, {
    String? detail,
    List<TermiusIssue> extra = const [],
  }) => TermiusImportDocument(
    format: TermiusSourceFormat.openSsh,
    headers: const [],
    rows: const [],
    fileIssues: [
      ...extra,
      TermiusIssue(code, severity: TermiusIssueSeverity.blocking, detail: detail),
    ],
  );

  static String _short(String value) =>
      value.length > 80 ? '${value.substring(0, 80)}…' : value;
}

class _BundleFiles implements TermiusBundleFiles {
  _BundleFiles(this.files, this.configDir);

  final Map<String, Uint8List> files;
  final String configDir;

  /// Accepts `~/.ssh/<rel>`, a path relative to the config directory, or a
  /// bundle-relative path. Never resolves outside the bundle.
  @override
  String? read(String configValue) {
    var value = configValue.replaceAll('\\', '/');
    final candidates = <String>[];
    if (value.startsWith('~/.ssh/')) {
      value = value.substring('~/.ssh/'.length);
      candidates.add(value);
    } else if (value.startsWith('/') ||
        value.startsWith('~') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value) ||
        value.contains('%') ||
        value.contains(r'$')) {
      return null;
    } else {
      if (configDir.isNotEmpty) candidates.add('$configDir/$value');
      candidates.add(value);
    }
    for (final candidate in candidates) {
      final normalized = TermiusZip.normalizeEntryPath(candidate);
      if (normalized == null) continue;
      final bytes = files[normalized];
      if (bytes == null) continue;
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Minimal bounded ZIP (stored writer; stored/deflate reader)

class TermiusZipEntry {
  TermiusZipEntry(this.path, this.bytes, {this.private = false});

  final String path;
  final Uint8List bytes;

  /// Unix mode 0600 instead of 0644.
  final bool private;
}

class TermiusZipException implements Exception {
  const TermiusZipException(this.detail, {this.tooLarge = false});

  final String detail;
  final bool tooLarge;

  @override
  String toString() => 'TermiusZipException($detail)';
}

class TermiusZipArchive {
  const TermiusZipArchive(this.files, this.rejectedPaths);

  /// Accepted regular files by normalized path.
  final Map<String, Uint8List> files;

  /// Entries that were refused (links, traversal, unsupported methods).
  final List<String> rejectedPaths;
}

class TermiusZip {
  const TermiusZip._();

  /// Returns a safe relative path, or null for absolute, drive, traversal,
  /// empty, control-character or backslash paths.
  static String? normalizeEntryPath(String path) {
    if (path.isEmpty ||
        path.length > 512 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path) ||
        RegExp(r'[\u0000-\u001F\u007F]').hasMatch(path)) {
      return null;
    }
    final parts = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') return null;
      parts.add(part);
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  static bool _isMacosArchiveMetadata(String normalizedPath) {
    if (normalizedPath.startsWith('__MACOSX/')) return true;
    final slash = normalizedPath.lastIndexOf('/');
    final base = slash >= 0
        ? normalizedPath.substring(slash + 1)
        : normalizedPath;
    return base == '.DS_Store' || base.startsWith('._');
  }

  static Uint8List encode(List<TermiusZipEntry> entries) {
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    // Fixed DOS timestamp (1980-01-01) keeps output deterministic.
    const dosTime = 0;
    const dosDate = (0 << 9) | (1 << 5) | 1;
    for (final entry in entries) {
      final name = utf8.encode(entry.path);
      final crc = getCrc32(entry.bytes);
      final offset = out.length;
      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 0x0800, Endian.little) // UTF-8 names
        ..setUint16(8, 0, Endian.little) // stored
        ..setUint16(10, dosTime, Endian.little)
        ..setUint16(12, dosDate, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, entry.bytes.length, Endian.little)
        ..setUint32(22, entry.bytes.length, Endian.little)
        ..setUint16(26, name.length, Endian.little)
        ..setUint16(28, 0, Endian.little);
      out
        ..add(local.buffer.asUint8List())
        ..add(name)
        ..add(entry.bytes);
      final mode = 0x8000 | (entry.private ? 0x180 : 0x1A4);
      final header = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 0x0314, Endian.little) // made by Unix, v2.0
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, dosTime, Endian.little)
        ..setUint16(14, dosDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, entry.bytes.length, Endian.little)
        ..setUint32(24, entry.bytes.length, Endian.little)
        ..setUint16(28, name.length, Endian.little)
        ..setUint16(30, 0, Endian.little)
        ..setUint16(32, 0, Endian.little)
        ..setUint16(34, 0, Endian.little)
        ..setUint16(36, 0, Endian.little)
        ..setUint32(38, mode << 16, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(header.buffer.asUint8List())
        ..add(name);
    }
    final centralOffset = out.length;
    final centralBytes = central.takeBytes();
    out.add(centralBytes);
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, entries.length, Endian.little)
      ..setUint16(10, entries.length, Endian.little)
      ..setUint32(12, centralBytes.length, Endian.little)
      ..setUint32(16, centralOffset, Endian.little);
    out.add(end.buffer.asUint8List());
    return out.takeBytes();
  }

  static TermiusZipArchive decode(List<int> input) {
    if (input.length > maxTermiusBundleBytes) {
      throw const TermiusZipException('size', tooLarge: true);
    }
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final data = ByteData.sublistView(bytes);
    int u16(int at) {
      if (at < 0 || at + 2 > bytes.length) throw const TermiusZipException('bounds');
      return data.getUint16(at, Endian.little);
    }

    int u32(int at) {
      if (at < 0 || at + 4 > bytes.length) throw const TermiusZipException('bounds');
      return data.getUint32(at, Endian.little);
    }

    var eocd = -1;
    final searchFrom = bytes.length - 22;
    final searchTo = (bytes.length - 22 - 65535).clamp(0, bytes.length);
    for (var at = searchFrom; at >= searchTo; at--) {
      if (at >= 0 && u32(at) == 0x06054b50) {
        eocd = at;
        break;
      }
    }
    if (eocd < 0) throw const TermiusZipException('eocd');
    final count = u16(eocd + 10);
    final centralSize = u32(eocd + 12);
    final centralOffset = u32(eocd + 16);
    if (count == 0xFFFF || centralOffset == 0xFFFFFFFF) {
      throw const TermiusZipException('zip64');
    }
    if (count > maxTermiusBundleEntries) {
      throw const TermiusZipException('entries', tooLarge: true);
    }
    if (centralOffset + centralSize > eocd) {
      throw const TermiusZipException('central');
    }
    final files = <String, Uint8List>{};
    final rejected = <String>[];
    var total = 0;
    var at = centralOffset;
    for (var index = 0; index < count; index++) {
      if (u32(at) != 0x02014b50) throw const TermiusZipException('header');
      final madeBy = u16(at + 4) >> 8;
      final flags = u16(at + 8);
      final method = u16(at + 10);
      final crc = u32(at + 16);
      final compressedSize = u32(at + 20);
      final size = u32(at + 24);
      final nameLength = u16(at + 28);
      final extraLength = u16(at + 30);
      final commentLength = u16(at + 32);
      final external = u32(at + 38);
      final localOffset = u32(at + 42);
      if (at + 46 + nameLength > bytes.length) {
        throw const TermiusZipException('name');
      }
      final rawName = bytes.sublist(at + 46, at + 46 + nameLength);
      at += 46 + nameLength + extraLength + commentLength;
      final String name;
      try {
        name = (flags & 0x0800) != 0
            ? utf8.decode(rawName, allowMalformed: false)
            : latin1.decode(rawName);
      } on FormatException {
        rejected.add('#${index + 1}');
        continue;
      }
      if (name.endsWith('/')) continue; // directory
      final unixType = madeBy == 3 ? (external >> 16) & 0xF000 : 0x8000;
      final path = normalizeEntryPath(name);
      // Silently skip benign macOS Finder archive metadata (__MACOSX, .DS_Store,
      // and AppleDouble `._*` resource-fork sidecars).
      if (path != null && _isMacosArchiveMetadata(path)) {
        continue;
      }
      if (path == null ||
          (flags & 0x1) != 0 ||
          (method != 0 && method != 8) ||
          // Type 0 = permissions only (e.g. Python zipfile.writestr).
          (unixType != 0x8000 && unixType != 0) ||
          compressedSize == 0xFFFFFFFF ||
          size == 0xFFFFFFFF) {
        rejected.add(name);
        continue;
      }
      if (size > maxTermiusBundleEntryBytes ||
          compressedSize > maxTermiusBundleBytes ||
          (total += size) > _maxBundleTotalBytes) {
        throw const TermiusZipException('entry', tooLarge: true);
      }
      if (files.containsKey(path)) {
        throw const TermiusZipException('duplicate');
      }
      if (u32(localOffset) != 0x04034b50) {
        throw const TermiusZipException('local');
      }
      final dataStart =
          localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28);
      if (dataStart + compressedSize > bytes.length) {
        throw const TermiusZipException('data');
      }
      final raw = Uint8List.sublistView(
        bytes,
        dataStart,
        dataStart + compressedSize,
      );
      final Uint8List content;
      if (method == 0) {
        if (compressedSize != size) throw const TermiusZipException('size');
        content = Uint8List.fromList(raw);
      } else {
        final output = _BoundedOutput(size);
        try {
          Inflate(raw, output: output);
        } on TermiusZipException {
          rethrow;
        } on Object {
          throw const TermiusZipException('inflate');
        }
        content = output.getBytes();
        if (content.length != size) throw const TermiusZipException('size');
      }
      if (getCrc32(content) != crc) throw const TermiusZipException('crc');
      files[path] = content;
    }
    return TermiusZipArchive(Map.unmodifiable(files), List.unmodifiable(rejected));
  }
}

/// Inflate output that refuses to grow past the declared entry size, so a
/// decompression bomb fails fast instead of exhausting memory.
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit) : super(size: limit == 0 ? 1 : limit);

  final int limit;

  void _check(int adding) {
    if (length + adding > limit) {
      throw const TermiusZipException('ratio', tooLarge: true);
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
