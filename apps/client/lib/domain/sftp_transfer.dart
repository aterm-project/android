import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// SFTP v3 defines SSH_FXF_EXCL for atomically refusing an existing file.
bool supportsSftpExclusiveCreate(int version) => version >= 3;

/// Opens a new file for writing and refuses to open an existing destination.
SftpFileOpenMode get sftpExclusiveCreateMode =>
    SftpFileOpenMode.write |
    SftpFileOpenMode.create |
    SftpFileOpenMode.exclusive;

/// An opened remote file used by [writeSftpFileWithoutOverwrite].
abstract interface class SftpUploadHandle {
  Future<void> writeBytes(Uint8List bytes);

  Future<void> close();
}

/// Creates a complete new remote file without overwriting a file already at
/// [remotePath].
///
/// [createExclusive] must use SFTP's create + exclusive flags. The server
/// checks that flag as part of opening the file, so a pre-existing destination
/// is never truncated even if it appears after a separate UI/list operation.
/// On write/close failure removal is attempted by remote path. SFTP v3 has no
/// unlink-by-handle or conditional-unlink operation, so a concurrent remote
/// actor replacing that pathname can make cleanup ambiguous. Callers should
/// treat the destination path as reserved to this operation until completion.
Future<void> writeSftpFileWithoutOverwrite({
  required String remotePath,
  required Uint8List bytes,
  required Future<SftpUploadHandle> Function() createExclusive,
  required Future<void> Function() removePartial,
}) async {
  final file = await createExclusive();
  try {
    await file.writeBytes(bytes);
  } catch (error, stackTrace) {
    try {
      await file.close();
    } catch (_) {
      // Still try to remove the partial file after a failed close.
    }
    await _removePartialAndRethrow(
      remotePath: remotePath,
      removePartial: removePartial,
      uploadError: error,
      stackTrace: stackTrace,
    );
  }

  try {
    await file.close();
  } catch (error, stackTrace) {
    await _removePartialAndRethrow(
      remotePath: remotePath,
      removePartial: removePartial,
      uploadError: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _removePartialAndRethrow({
  required String remotePath,
  required Future<void> Function() removePartial,
  required Object uploadError,
  required StackTrace stackTrace,
}) async {
  try {
    // SFTP v3 can unlink only by path; it cannot prove that a concurrent
    // replacement still names the partial file created by this operation.
    await removePartial();
  } catch (cleanupError) {
    throw SftpPartialUploadCleanupException(
      remotePath: remotePath,
      uploadError: uploadError,
      cleanupError: cleanupError,
    );
  }
  Error.throwWithStackTrace(uploadError, stackTrace);
}

/// Indicates that an incomplete newly-created file might remain remotely.
class SftpPartialUploadCleanupException implements Exception {
  const SftpPartialUploadCleanupException({
    required this.remotePath,
    required this.uploadError,
    required this.cleanupError,
  });

  final String remotePath;
  final Object uploadError;
  final Object cleanupError;

  @override
  String toString() =>
      'SFTP upload of "$remotePath" failed, and its incomplete file could '
      'not be removed. Inspect and remove it before retrying. '
      'Upload error: $uploadError. Cleanup error: $cleanupError.';
}

/// Adapts dartssh2's [SftpFile] to the upload operation's narrow interface.
class DartSftpUploadHandle implements SftpUploadHandle {
  const DartSftpUploadHandle(this.file);

  final SftpFile file;

  @override
  Future<void> writeBytes(Uint8List bytes) => file.writeBytes(bytes);

  @override
  Future<void> close() => file.close();
}
