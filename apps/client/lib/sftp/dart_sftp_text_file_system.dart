import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/sftp_transfer.dart';
import 'sftp_text_editor_service.dart';
import '../l10n/l10n.dart';

const _sftpTextReadLimit = 10 * 1024 * 1024 + 1;
const _sftpTextRegularFileType = 0x8000;
const _sftpTextOwnerReadWrite = 0x180;
const _sftpTextPermissionMask = 0x1ff;

/// Applies the shared bounded text-editing rules to a dartssh2 SFTP channel.
class DartSftpTextFileSystem implements SftpTextFileSystem {
  DartSftpTextFileSystem(
    this._client, {
    required this.supportsAtomicReplaceExtension,
  });

  final SftpClient _client;
  final bool supportsAtomicReplaceExtension;

  @override
  Future<bool> supportsAtomicReplace() async => supportsAtomicReplaceExtension;

  @override
  Future<SftpTextRemoteSnapshot> readFile(
    String path, {
    required int maxBytes,
  }) async {
    if (maxBytes < 1 || maxBytes > _sftpTextReadLimit) {
      throw RangeError.range(maxBytes, 1, _sftpTextReadLimit, 'maxBytes');
    }
    // SFTP v3 has no portable OPEN no-follow flag. Check the path and handle,
    // then check the path again so a substitution that remains a symlink is
    // rejected. A hostile remote rename can still race these requests.
    final pathAttributes = await _client.stat(path, followLink: false);
    _requireSftpTextRegularFile(pathAttributes, path);
    final file = await _client.open(path);
    try {
      final handleAttributes = await file.stat();
      _requireSftpTextRegularFile(handleAttributes, path);
      final pathAfterOpen = await _client.stat(path, followLink: false);
      _requireSftpTextRegularFile(pathAfterOpen, path);
      final bytes = await file.readBytes(length: maxBytes);
      return SftpTextRemoteSnapshot(
        bytes: bytes,
        isRegularFile: true,
        permissionBits: _sftpTextPermissionBits(handleAttributes),
      );
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeExclusive(
    String path,
    Uint8List bytes, {
    int? permissionBits,
  }) async {
    final file = await _openExclusive(path);
    Object? writeError;
    StackTrace? writeStackTrace;
    try {
      final attributes = await file.stat();
      _requireSftpTextRegularFile(attributes, path);
      await file.setStat(
        SftpFileAttrs(
          mode: const SftpFileMode.value(
            _sftpTextRegularFileType | _sftpTextOwnerReadWrite,
          ),
        ),
      );
      await file.writeBytes(bytes);
      final safePermissions =
          (permissionBits ?? _sftpTextOwnerReadWrite) & _sftpTextPermissionMask;
      await file.setStat(
        SftpFileAttrs(
          mode: SftpFileMode.value(_sftpTextRegularFileType | safePermissions),
        ),
      );
    } catch (error, stackTrace) {
      writeError = error;
      writeStackTrace = stackTrace;
    }

    try {
      await file.close();
    } catch (error, stackTrace) {
      writeError ??= error;
      writeStackTrace ??= stackTrace;
    }

    if (writeError != null) {
      try {
        await _client.remove(path);
      } catch (cleanupError) {
        throw _SftpTextPartialWriteCleanupException(
          path: path,
          writeError: writeError,
          cleanupError: cleanupError,
        );
      }
      Error.throwWithStackTrace(writeError, writeStackTrace!);
    }
  }

  @override
  Future<void> replaceAtomically(String tempPath, String targetPath) async {
    if (!supportsAtomicReplaceExtension) {
      throw StateError(
        'SFTP server did not advertise posix-rename@openssh.com version 1.',
      );
    }
    // dartssh2 falls back to ordinary rename when the extension is absent, so
    // call rename only after checking the exact advertised extension version.
    await _client.rename(tempPath, targetPath);
  }

  @override
  Future<void> setPermissionBits(String path, int permissionBits) async {
    final pathAttributes = await _client.stat(path, followLink: false);
    _requireSftpTextRegularFile(pathAttributes, path);
    final file = await _client.open(
      path,
      mode: SftpFileOpenMode.read | SftpFileOpenMode.write,
    );
    try {
      final handleAttributes = await file.stat();
      _requireSftpTextRegularFile(handleAttributes, path);
      final pathAfterOpen = await _client.stat(path, followLink: false);
      _requireSftpTextRegularFile(pathAfterOpen, path);
      final safePermissions = permissionBits & _sftpTextPermissionMask;
      await file.setStat(
        SftpFileAttrs(
          mode: SftpFileMode.value(_sftpTextRegularFileType | safePermissions),
        ),
      );
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> removeFile(String path) => _client.remove(path);

  Future<SftpFile> _openExclusive(String path) async {
    try {
      return await _client.open(path, mode: sftpExclusiveCreateMode);
    } on SftpStatusError catch (openError, stackTrace) {
      if (openError.code != SftpStatusCode.failure) {
        Error.throwWithStackTrace(openError, stackTrace);
      }
      // SFTP v3 commonly reports exclusive-create collisions as generic
      // failure. A successful lstat confirms a path exists; never touch it.
      try {
        await _client.stat(path, followLink: false);
      } catch (_) {
        Error.throwWithStackTrace(openError, stackTrace);
      }
      throw SftpTextFileAlreadyExistsException(path);
    }
  }
}

void _requireSftpTextRegularFile(SftpFileAttrs attributes, String path) {
  if (attributes.mode?.type != SftpFileType.regularFile) {
    throw FormatException(currentL10n.theRemotePathIsntARegular(path));
  }
}

int? _sftpTextPermissionBits(SftpFileAttrs attributes) {
  final mode = attributes.mode?.value;
  return mode == null ? null : mode & _sftpTextPermissionMask;
}

class _SftpTextPartialWriteCleanupException implements Exception {
  const _SftpTextPartialWriteCleanupException({
    required this.path,
    required this.writeError,
    required this.cleanupError,
  });

  final String path;
  final Object writeError;
  final Object cleanupError;

  @override
  String toString() =>
      'SFTP text write failed for "$path" and its newly created file could '
      'not be removed. Write error: $writeError. Cleanup error: $cleanupError.';
}
