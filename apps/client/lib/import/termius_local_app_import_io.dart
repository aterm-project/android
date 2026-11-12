import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:sodium/sodium_sumo.dart';

import 'termius_indexeddb_reader.dart';
import 'termius_local_normalizer.dart';
import 'termius_local_vault_cipher.dart';
import 'termius_transfer.dart';

enum TermiusLocalImportFailure {
  notInstalled,
  keyNotFound,
  keyRejected,
  unsupportedCipher,
  emptyDatabase,
  readFailed,
}

class TermiusLocalImportException implements Exception {
  const TermiusLocalImportException(this.failure, [this.detail]);

  final TermiusLocalImportFailure failure;
  final String? detail;

  @override
  String toString() => 'TermiusLocalImportException(${failure.name}, $detail)';
}

const int _maxLevelDbSnapshotTotalBytes = 192 * 1024 * 1024;
const String _keyringAccount = 'localKey';

String? _userHomeDir() {
  final home = Platform.environment['HOME']?.trim();
  if (home != null && home.isNotEmpty) return home;
  final profile = Platform.environment['USERPROFILE']?.trim();
  if (profile != null && profile.isNotEmpty) return profile;
  return null;
}

/// Resolves a user-supplied or candidate Termius path to its `file__0.indexeddb.leveldb`
/// directory if `CURRENT` exists inside it.
Directory? resolveTermiusLevelDbDir(String rawPath) {
  final base = rawPath.trim();
  if (base.isEmpty) return null;
  final candidates = <String>[
    base,
    p.join(base, 'file__0.indexeddb.leveldb'),
    p.join(base, 'IndexedDB', 'file__0.indexeddb.leveldb'),
    p.join(base, '.config', 'Termius', 'IndexedDB', 'file__0.indexeddb.leveldb'),
  ];
  for (final candidate in candidates) {
    final currentFile = File(p.join(candidate, 'CURRENT'));
    try {
      if (currentFile.existsSync()) {
        return Directory(candidate);
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// Lists candidate Termius Desktop directories in priority order for this OS.
List<Directory> discoverLocalTermiusLevelDbDirs() {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    return const [];
  }
  final home = _userHomeDir();
  final rawRoots = <String>[];

  if (Platform.isMacOS && home != null) {
    // 1. Direct DMG / Homebrew Cask install.
    rawRoots.add(p.join(home, 'Library', 'Application Support', 'Termius'));
    // 2. Mac App Store sandboxed container(s).
    final containersDir = Directory(p.join(home, 'Library', 'Containers'));
    try {
      if (containersDir.existsSync()) {
        final matches = containersDir
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where(
              (dir) => p.basename(dir.path).toLowerCase().contains('termius'),
            )
            .map((dir) => dir.path)
            .toList()
          ..sort();
        for (final container in matches) {
          rawRoots.add(
            p.join(
              container,
              'Data',
              'Library',
              'Application Support',
              'Termius',
            ),
          );
        }
      }
    } on FileSystemException {
      // Sandboxed container enumeration may be restricted; ignore safely.
    }
  } else if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA']?.trim();
    if (appData != null && appData.isNotEmpty) {
      rawRoots.add(p.join(appData, 'Termius'));
    } else if (home != null) {
      rawRoots.add(p.join(home, 'AppData', 'Roaming', 'Termius'));
    }
  } else if (Platform.isLinux && home != null) {
    rawRoots.add(
      p.join(home, 'snap', 'termius-app', 'current', '.config', 'Termius'),
    );
    rawRoots.add(p.join(home, '.config', 'Termius'));
  }

  final found = <Directory>[];
  final seen = <String>{};
  for (final root in rawRoots) {
    final resolved = resolveTermiusLevelDbDir(root);
    if (resolved != null && seen.add(resolved.path)) {
      found.add(resolved);
    }
  }
  return found;
}

/// True when a local Termius Desktop IndexedDB directory exists on this device.
bool hasLocalTermiusInstallation() => discoverLocalTermiusLevelDbDirs().isNotEmpty;

List<String> _candidateKeyringServicesForPath(String levelDbPath) {
  final lower = levelDbPath.toLowerCase();
  if (Platform.isMacOS) {
    final isMasContainer = lower.contains('/library/containers/');
    return isMasContainer
        ? const [
            'Termius (MAS)',
            'Termius',
            'com.termius.mac',
            'termius',
          ]
        : const [
            'Termius',
            'Termius (MAS)',
            'com.termius-dmg.mac',
            'termius',
          ];
  }
  if (Platform.isLinux) {
    final isSnap = lower.contains('/snap/termius-app/');
    return isSnap
        ? const ['termius-app', 'Termius', 'termius']
        : const ['Termius', 'termius-app', 'termius'];
  }
  return const ['Termius', 'termius-app', 'termius'];
}

Uint8List? _decodeKeyBase64(String? rawText) {
  final trimmed = rawText?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  try {
    final bytes = Uint8List.fromList(base64.decode(trimmed));
    if (bytes.length == termiusVaultKeyBytes) {
      return bytes;
    }
    bytes.fillRange(0, bytes.length, 0);
    return null;
  } on FormatException {
    return null;
  }
}

Future<String?> _readFromMacOsKeychain(String service) async {
  try {
    final result = await Process.run(
      '/usr/bin/security',
      ['find-generic-password', '-s', service, '-a', _keyringAccount, '-w'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 45));
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on Object {
    return null;
  }
}

Future<String?> _readFromLinuxSecretTool(String service) async {
  try {
    final result = await Process.run(
      'secret-tool',
      ['lookup', 'service', service, 'account', _keyringAccount],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on Object {
    return null;
  }
}

// Windows `CREDENTIALW` structure for `CredReadW` (`advapi32.dll`).
final class _WinFileTime extends ffi.Struct {
  @ffi.Uint32()
  external int dwLowDateTime;

  @ffi.Uint32()
  external int dwHighDateTime;
}

final class _WinCredential extends ffi.Struct {
  @ffi.Uint32()
  external int flags;

  @ffi.Uint32()
  external int type;

  external ffi.Pointer<Utf16> targetName;
  external ffi.Pointer<Utf16> comment;
  external _WinFileTime lastWritten;

  @ffi.Uint32()
  external int credentialBlobSize;

  external ffi.Pointer<ffi.Uint8> credentialBlob;

  @ffi.Uint32()
  external int persist;

  @ffi.Uint32()
  external int attributeCount;

  external ffi.Pointer<ffi.Void> attributes;
  external ffi.Pointer<Utf16> targetAlias;
  external ffi.Pointer<Utf16> userName;
}

typedef _CredReadWNative = ffi.Int32 Function(
  ffi.Pointer<Utf16> targetName,
  ffi.Uint32 type,
  ffi.Uint32 flags,
  ffi.Pointer<ffi.Pointer<_WinCredential>> credential,
);
typedef _CredReadWDart = int Function(
  ffi.Pointer<Utf16> targetName,
  int type,
  int flags,
  ffi.Pointer<ffi.Pointer<_WinCredential>> credential,
);

typedef _CredFreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> buffer);
typedef _CredFreeDart = void Function(ffi.Pointer<ffi.Void> buffer);

String? _readFromWindowsCredentialManager(String service) {
  if (!Platform.isWindows) return null;
  try {
    final advapi32 = ffi.DynamicLibrary.open('advapi32.dll');
    final credReadW = advapi32
        .lookupFunction<_CredReadWNative, _CredReadWDart>('CredReadW');
    final credFree = advapi32
        .lookupFunction<_CredFreeNative, _CredFreeDart>('CredFree');

    return using((arena) {
      final target = '$service/$_keyringAccount'.toNativeUtf16(allocator: arena);
      final outPtr = arena<ffi.Pointer<_WinCredential>>();
      // CRED_TYPE_GENERIC = 1
      final ok = credReadW(target, 1, 0, outPtr);
      if (ok == 0 || outPtr.value == ffi.nullptr) return null;
      try {
        final cred = outPtr.value.ref;
        final size = cred.credentialBlobSize;
        if (size <= 0 || cred.credentialBlob == ffi.nullptr) return null;
        final raw = Uint8List.fromList(cred.credentialBlob.asTypedList(size));
        try {
          final utf8Text = utf8.decode(raw, allowMalformed: true).trim();
          final check = _decodeKeyBase64(utf8Text);
          if (check != null) {
            check.fillRange(0, check.length, 0);
            return utf8Text;
          }
          if (size.isEven) {
            final units = Uint16List(size ~/ 2);
            final bd = ByteData.sublistView(raw);
            for (var i = 0; i < units.length; i++) {
              units[i] = bd.getUint16(i * 2, Endian.little);
            }
            return String.fromCharCodes(units).trim();
          }
          return utf8Text;
        } finally {
          raw.fillRange(0, raw.length, 0);
        }
      } finally {
        credFree(outPtr.value.cast());
      }
    });
  } on Object {
    return null;
  }
}

Future<Uint8List> _loadValidatedLocalKey({
  required SodiumSumo sodium,
  required String levelDbPath,
  required String? sampleCiphertext,
}) async {
  final services = _candidateKeyringServicesForPath(levelDbPath);
  var foundAnyKey = false;

  for (final service in services) {
    String? encoded;
    if (Platform.isMacOS) {
      encoded = await _readFromMacOsKeychain(service);
    } else if (Platform.isLinux) {
      encoded = await _readFromLinuxSecretTool(service);
    } else if (Platform.isWindows) {
      encoded = _readFromWindowsCredentialManager(service);
    }
    final keyBytes = _decodeKeyBase64(encoded);
    if (keyBytes == null) continue;
    foundAnyKey = true;

    if (sampleCiphertext == null) {
      return keyBytes;
    }

    final verifier = TermiusVaultDecryptor(sodium, keyBytes);
    try {
      if (verifier.canDecryptEnvelope(sampleCiphertext)) {
        return keyBytes;
      }
    } finally {
      verifier.dispose();
    }
    keyBytes.fillRange(0, keyBytes.length, 0);
  }

  throw TermiusLocalImportException(
    foundAnyKey
        ? TermiusLocalImportFailure.keyRejected
        : TermiusLocalImportFailure.keyNotFound,
  );
}

Future<Map<String, Uint8List>> _readLevelDbSnapshotFiles(Directory dir) async {
  final files = <String, Uint8List>{};
  var totalBytes = 0;

  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    final relevant =
        name == 'CURRENT' ||
        name.startsWith('MANIFEST-') ||
        name.endsWith('.ldb') ||
        name.endsWith('.sst') ||
        name.endsWith('.log');
    if (!relevant) continue;

    final stat = await entity.stat();
    if (stat.size <= 0) continue;
    if (totalBytes + stat.size > _maxLevelDbSnapshotTotalBytes) {
      throw const TermiusLocalImportException(
        TermiusLocalImportFailure.readFailed,
        'snapshotTooLarge',
      );
    }
    final bytes = await entity.readAsBytes();
    totalBytes += bytes.length;
    files[name] = bytes;
  }

  if (!files.containsKey('CURRENT')) {
    throw const TermiusLocalImportException(
      TermiusLocalImportFailure.notInstalled,
    );
  }
  return files;
}

/// Reads, authenticates via OS keyring (`localKey`), and decrypts the local
/// Termius Desktop database in memory into a [TermiusImportDocument].
Future<({TermiusImportDocument document, String sourceLabel})>
loadLocalTermiusAppDocument({String? customDataDir}) async {
  final Directory? levelDbDir = customDataDir != null
      ? resolveTermiusLevelDbDir(customDataDir)
      : discoverLocalTermiusLevelDbDirs().firstOrNull;

  if (levelDbDir == null) {
    throw const TermiusLocalImportException(
      TermiusLocalImportFailure.notInstalled,
    );
  }

  Map<String, Uint8List>? snapshotFiles;
  Uint8List? keyBytes;
  TermiusVaultDecryptor? decryptor;

  try {
    snapshotFiles = await _readLevelDbSnapshotFiles(levelDbDir);
    final rawTables = readTermiusIndexedDbTables(snapshotFiles);
    if ((rawTables.tables['hosts'] ?? const []).isEmpty) {
      throw const TermiusLocalImportException(
        TermiusLocalImportFailure.emptyDatabase,
      );
    }

    final sampleCiphertext = firstTermiusCiphertext(rawTables.tables);
    final sodium = await SodiumSumoInit.init();
    keyBytes = await _loadValidatedLocalKey(
      sodium: sodium,
      levelDbPath: levelDbDir.path,
      sampleCiphertext: sampleCiphertext,
    );
    decryptor = TermiusVaultDecryptor(sodium, keyBytes);

    final document = buildTermiusDocumentFromLocalTables(rawTables, decryptor);
    if (document.rows.isEmpty) {
      throw const TermiusLocalImportException(
        TermiusLocalImportFailure.emptyDatabase,
      );
    }
    final isMas = levelDbDir.path.toLowerCase().contains('/library/containers/');
    final sourceLabel = isMas ? 'Termius Desktop (App Store)' : 'Termius Desktop';
    return (document: document, sourceLabel: sourceLabel);
  } on TermiusLocalImportException {
    rethrow;
  } on TermiusUnknownCipherVersionException catch (error) {
    throw TermiusLocalImportException(
      TermiusLocalImportFailure.unsupportedCipher,
      error.headerHex,
    );
  } on TermiusVaultDecryptionException {
    throw const TermiusLocalImportException(
      TermiusLocalImportFailure.keyRejected,
    );
  } on Object {
    throw const TermiusLocalImportException(
      TermiusLocalImportFailure.readFailed,
    );
  } finally {
    decryptor?.dispose();
    keyBytes?.fillRange(0, keyBytes.length, 0);
    if (snapshotFiles != null) {
      for (final buf in snapshotFiles.values) {
        buf.fillRange(0, buf.length, 0);
      }
    }
  }
}
