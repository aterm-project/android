import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'attachment_file_saver_model.dart';

const _streamChunkLimit = 4 * 1024 * 1024;
const _uuid = Uuid();
const _privateStagingDirectoryName = 'atermius-attachment-staging';
final _activeStagingPaths = <String>{};

bool get mobileSaveHandledWithoutPath => Platform.isAndroid || Platform.isIOS;

bool get supportsStreamingAttachmentSave =>
    Platform.isLinux || Platform.isWindows;

Future<AttachmentStreamingSaveWriter?> openStreamingSave({
  required String fileName,
  required String mediaType,
}) async {
  if (!supportsStreamingAttachmentSave) {
    throw UnsupportedError('Streaming attachment saves are unavailable.');
  }
  final path = await FilePicker.platform.saveFile(fileName: fileName);
  if (path == null) return null;
  final support = await getApplicationSupportDirectory();
  final stagingDirectory = Directory(
    '${support.path}${Platform.pathSeparator}$_privateStagingDirectoryName',
  );
  await stagingDirectory.create(recursive: true);
  await _restrictPath(stagingDirectory.path, directory: true);
  await _removeStaleStagingFiles(stagingDirectory);
  final temporary = File(
    '${stagingDirectory.path}${Platform.pathSeparator}${_uuid.v4()}.partial',
  );
  final lockFile = File('${temporary.path}.lock');
  _activeStagingPaths.add(temporary.path);
  RandomAccessFile? handle;
  RandomAccessFile? lockHandle;
  try {
    lockHandle = await lockFile.open(mode: FileMode.writeOnly);
    await _restrictPath(lockFile.path, directory: false);
    await lockHandle.lock(FileLock.exclusive);
    handle = await temporary.open(mode: FileMode.writeOnly);
    await _restrictPath(temporary.path, directory: false);
  } catch (_) {
    if (handle != null) await handle.close();
    if (lockHandle != null) {
      try {
        await lockHandle.unlock();
      } on Object {
        // A failed lock acquisition needs no unlock.
      }
      await lockHandle.close();
    }
    if (await temporary.exists()) await temporary.delete();
    if (await lockFile.exists()) await lockFile.delete();
    _activeStagingPaths.remove(temporary.path);
    rethrow;
  }
  return _IoAttachmentSaveWriter(
    destination: File(path),
    temporary: temporary,
    lockFile: lockFile,
    handle: handle,
    lockHandle: lockHandle,
    onFinished: () => _activeStagingPaths.remove(temporary.path),
  );
}

Future<void> _removeStaleStagingFiles(Directory directory) async {
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.endsWith('.partial') ||
          _activeStagingPaths.contains(entity.path)) {
        continue;
      }
      final lockFile = File('${entity.path}.lock');
      RandomAccessFile? lockHandle;
      try {
        if (await lockFile.exists()) {
          lockHandle = await lockFile.open(mode: FileMode.append);
          await lockHandle.lock(FileLock.exclusive);
        }
        await entity.delete();
      } on FileSystemException {
        // Cleanup is best-effort; the directory remains private to this user.
        continue;
      } finally {
        if (lockHandle != null) {
          try {
            await lockHandle.unlock();
          } on Object {
            // The nonblocking lock may have failed because another writer owns it.
          }
          await lockHandle.close();
        }
      }
      if (await lockFile.exists()) await lockFile.delete();
    }
  } on FileSystemException {
    // A cleanup failure must not strand the user's new save operation.
  }
}

/// file_picker's desktop helper skips empty byte arrays. Create the chosen
/// zero-length file ourselves after the native save dialog returns its path.
Future<void> finishSave({
  required String? path,
  required Uint8List bytes,
}) async {
  if (path == null ||
      bytes.isNotEmpty ||
      Platform.isAndroid ||
      Platform.isIOS) {
    return;
  }
  await File(path).writeAsBytes(bytes, flush: true);
}

Future<void> _restrictPath(String path, {required bool directory}) async {
  if (Platform.isLinux || Platform.isMacOS) {
    final result = await Process.run('chmod', [
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restrict attachment staging permissions.',
        path,
      );
    }
  } else if (Platform.isWindows) {
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) {
      throw StateError('Could not identify the current Windows user.');
    }
    final rights = directory ? '(OI)(CI)F' : 'F';
    final result = await Process.run('icacls', [
      path,
      '/inheritance:r',
      '/grant:r',
      '$user:$rights',
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restrict attachment staging permissions.',
        path,
      );
    }
  }
}

class _IoAttachmentSaveWriter implements AttachmentStreamingSaveWriter {
  _IoAttachmentSaveWriter({
    required this.destination,
    required this.temporary,
    required this.lockFile,
    required this.handle,
    required this.lockHandle,
    required this.onFinished,
  });

  final File destination;
  final File temporary;
  final File lockFile;
  final RandomAccessFile handle;
  final RandomAccessFile lockHandle;
  final void Function() onFinished;
  File? _destinationPartial;
  var _closed = false;
  var _finished = false;

  @override
  Future<void> write(Uint8List plaintextChunk) async {
    if (_closed || _finished) {
      throw StateError('Attachment save writer is no longer open.');
    }
    if (plaintextChunk.length > _streamChunkLimit) {
      throw ArgumentError.value(
        plaintextChunk.length,
        'plaintextChunk.length',
        'must not exceed 4 MiB',
      );
    }
    await handle.writeFrom(plaintextChunk);
  }

  @override
  Future<void> commit() async {
    if (_finished) return;
    if (_closed) throw StateError('Attachment save writer was aborted.');
    await handle.flush();
    await handle.close();
    _closed = true;
    final partial = File('${destination.path}.atermius-${_uuid.v4()}.partial');
    _destinationPartial = partial;
    final partialHandle = await partial.open(mode: FileMode.writeOnly);
    try {
      await _restrictPath(partial.path, directory: false);
      await for (final chunk in temporary.openRead()) {
        try {
          await partialHandle.writeFrom(chunk);
        } finally {
          chunk.fillRange(0, chunk.length, 0);
        }
      }
      await partialHandle.flush();
    } catch (_) {
      await partialHandle.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    await partialHandle.close();
    final backup = File('${destination.path}.atermius-${_uuid.v4()}.backup');
    var movedExisting = false;
    try {
      if (await destination.exists()) {
        await destination.rename(backup.path);
        movedExisting = true;
      }
      await partial.rename(destination.path);
    } catch (_) {
      if (movedExisting &&
          !await destination.exists() &&
          await backup.exists()) {
        await backup.rename(destination.path);
      }
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    _finished = true;
    _destinationPartial = null;
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } on FileSystemException {
        // The verified destination is committed; a private stale file is safe.
      }
    }
    await _releaseStagingLock();
    if (movedExisting) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The committed file is valid; a stale backup is safer than reporting
        // a save failure after replacing the selected destination.
      }
    }
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    try {
      if (!_closed) {
        await handle.close();
        _closed = true;
      }
      final partial = _destinationPartial;
      if (partial != null && await partial.exists()) await partial.delete();
      if (await temporary.exists()) await temporary.delete();
    } finally {
      _finished = true;
      await _releaseStagingLock();
    }
  }

  Future<void> _releaseStagingLock() async {
    try {
      await lockHandle.unlock();
    } on Object {
      // Closing the descriptor also releases a held advisory lock.
    }
    try {
      await lockHandle.close();
    } on Object {
      // Best-effort cleanup after the destination is committed or aborted.
    }
    if (await lockFile.exists()) {
      try {
        await lockFile.delete();
      } on FileSystemException {
        // The lock file contains no plaintext; a later stale sweep removes it.
      }
    }
    onFinished();
  }
}
