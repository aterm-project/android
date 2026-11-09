import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../domain/sftp_entries.dart';

/// The maximum amount of remote content the in-memory text editor will read
/// or write (10 MiB).
const int sftpTextFileMaxBytes = 10 * 1024 * 1024;

/// Small filesystem surface needed by the remote text editor.
///
/// Implementations must bound the bytes actually read by [readFile], not just
/// truncate its returned value. The snapshot byte buffer is transferred to the
/// caller, which clears it after use. [readFile] must report
/// `isRegularFile == false` for symbolic links and other non-regular entries.
/// [writeExclusive] must use an exclusive create operation, establish the
/// requested restrictive permissions before writing bytes, and remove any
/// partial file it created if writing or closing fails. It must throw
/// [SftpTextFileAlreadyExistsException] when exclusive creation finds an
/// existing path. [replaceAtomically] must have same-filesystem atomic replace
/// semantics; callers must not emulate it with an ordinary rename. Requested
/// target permissions are restored only after the private staging file has
/// atomically replaced its target.
abstract interface class SftpTextFileSystem {
  Future<SftpTextRemoteSnapshot> readFile(String path, {required int maxBytes});

  Future<bool> supportsAtomicReplace();

  Future<void> writeExclusive(
    String path,
    Uint8List bytes, {
    int? permissionBits,
  });

  Future<void> replaceAtomically(String tempPath, String targetPath);

  Future<void> setPermissionBits(String path, int permissionBits);

  Future<void> removeFile(String path);
}

/// Result of a bounded remote file read.
class SftpTextRemoteSnapshot {
  const SftpTextRemoteSnapshot({
    required this.bytes,
    required this.isRegularFile,
    required this.permissionBits,
  });

  final Uint8List bytes;
  final bool isRegularFile;

  /// SFTP mode/permission bits supplied by the adapter, if available.
  final int? permissionBits;

  /// Clears the plaintext buffer owned by this snapshot.
  void dispose() => bytes.fillRange(0, bytes.length, 0);
}

/// A decoded remote text file and the exact bytes it was opened from.
///
/// The private baseline is mutable so [dispose] can clear it when the caller
/// closes or replaces the document. [originalBytes] always returns a copy.
class SftpTextDocument {
  SftpTextDocument._({
    required this.path,
    required this.name,
    required this.text,
    required this._originalBytes,
    required this.permissionBits,
    this.sessionId,
  });

  final String path;
  final String name;
  final String text;
  final int? permissionBits;
  final String? sessionId;
  final Uint8List _originalBytes;
  bool _disposed = false;

  Uint8List get originalBytes {
    if (_disposed) {
      throw StateError('SFTP text document has been disposed.');
    }
    return Uint8List.fromList(_originalBytes);
  }

  /// Clears the document's mutable baseline bytes.
  void dispose() {
    if (_disposed) return;
    _originalBytes.fillRange(0, _originalBytes.length, 0);
    _disposed = true;
  }

  Uint8List _copyOriginalBytes() => originalBytes;
}

sealed class SftpTextSaveResult {
  const SftpTextSaveResult();
}

/// The save completed and [document] represents the new remote baseline.
final class SftpTextSaveSuccess extends SftpTextSaveResult {
  const SftpTextSaveSuccess(
    this.document, {
    this.permissionRestoreFailed = false,
  });

  final SftpTextDocument document;

  /// The contents were published, but restoring the previous file mode could
  /// not be confirmed. The caller should report the uncertain mode separately
  /// from the successful content save.
  final bool permissionRestoreFailed;
}

/// The remote bytes changed. Resolve the conflict using [latestDocument].
final class SftpTextRemoteChanged extends SftpTextSaveResult {
  const SftpTextRemoteChanged(this.latestDocument);

  final SftpTextDocument latestDocument;
}

/// Indicates that an exclusive create did not succeed because the path exists.
class SftpTextFileAlreadyExistsException implements Exception {
  const SftpTextFileAlreadyExistsException([this.path]);

  final String? path;

  @override
  String toString() => path == null
      ? 'SFTP file already exists.'
      : 'SFTP file already exists: $path';
}

/// A staged file could not be removed after an operation failed.
class SftpTextTempCleanupException implements Exception {
  const SftpTextTempCleanupException({
    required this.tempPath,
    required this.operationError,
    required this.cleanupError,
  });

  final String tempPath;
  final Object operationError;
  final Object cleanupError;

  @override
  String toString() =>
      'Could not remove staged SFTP text file "$tempPath" after '
      '$operationError: $cleanupError';
}

/// Reads and safely saves small UTF-8 text files over SFTP.
class SftpTextEditorService {
  SftpTextEditorService({
    required SftpTextFileSystem filesystem,
    Random? random,
    String? sessionId,
  }) : this._(filesystem, random ?? Random.secure(), sessionId);

  SftpTextEditorService._(this._filesystem, this._random, this.sessionId);

  static const int _maxTempNameAttempts = 4;
  static const int _ordinaryPermissionMask = 0x1ff; // 0777
  static const int _newFilePermissionBits = 0x180; // 0600

  final SftpTextFileSystem _filesystem;
  final Random _random;
  final String? sessionId;

  /// The bounded byte-level filesystem (regular-file reads, exclusive
  /// staging, atomic replace) for byte-exact external editing.
  SftpTextFileSystem get filesystem => _filesystem;

  Future<SftpTextDocument> open(String path) async {
    final safePath = _validateFilePath(path);
    final snapshot = await _readSnapshot(safePath);
    return _documentFromSnapshot(safePath, snapshot);
  }

  /// Saves [text] over the path represented by [document].
  ///
  /// By default, the bytes captured when the document was opened are the
  /// expected baseline. A caller may pass [expectedRemoteBytes] only after an
  /// explicit overwrite choice; those exact bytes are checked both before
  /// staging and again immediately before atomic replacement. SFTP does not
  /// provide compare-and-swap, so a remote write can still race after the
  /// final read and before the server performs the atomic replacement.
  Future<SftpTextSaveResult> save(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
  }) async {
    final targetPath = _validateFilePath(document.path);
    final newBytes = _encodeText(text);
    Uint8List? baseline;
    try {
      baseline = expectedRemoteBytes == null
          ? document._copyOriginalBytes()
          : Uint8List.fromList(expectedRemoteBytes);
      _validateBytesAndDecode(baseline);

      final current = await _readSnapshot(targetPath);
      final matchesBaseline = _bytesEqual(current.bytes, baseline);
      if (!matchesBaseline) {
        return SftpTextRemoteChanged(
          _documentFromSnapshot(targetPath, current),
        );
      }
      current.dispose();

      if (!await _filesystem.supportsAtomicReplace()) {
        throw UnsupportedError(
          'This SFTP server does not support safe atomic replacement.',
        );
      }

      final permissions =
          _safePermissionBits(document.permissionBits) ??
          _newFilePermissionBits;
      // Do not expose uncommitted contents through the target's broader mode.
      final tempPath = await _stageTempFile(
        targetPath,
        newBytes,
        _newFilePermissionBits,
      );
      var staged = true;
      try {
        final latest = await _readSnapshot(targetPath);
        if (!_bytesEqual(latest.bytes, baseline)) {
          final latestDocument = _documentFromSnapshot(targetPath, latest);
          staged = false;
          await _removeStagedFile(
            tempPath,
            operationError: StateError(
              'The remote file changed while the replacement was staged.',
            ),
          );
          return SftpTextRemoteChanged(latestDocument);
        }
        latest.dispose();

        await _filesystem.replaceAtomically(tempPath, targetPath);
        staged = false;
        var publishedPermissions = _newFilePermissionBits;
        var permissionRestoreFailed = false;
        if (permissions != _newFilePermissionBits) {
          try {
            // The broader mode is applied only after atomic publication.
            await _filesystem.setPermissionBits(targetPath, permissions);
            publishedPermissions = permissions;
          } catch (_) {
            // Replacement succeeded; keep its secure default mode and report
            // this as a warning rather than claiming the save was lost.
            permissionRestoreFailed = true;
          }
        }
        return SftpTextSaveSuccess(
          _newDocument(targetPath, newBytes, text, publishedPermissions),
          permissionRestoreFailed: permissionRestoreFailed,
        );
      } catch (error, stackTrace) {
        if (staged) {
          staged = false;
          try {
            await _filesystem.removeFile(tempPath);
          } catch (cleanupError) {
            throw SftpTextTempCleanupException(
              tempPath: tempPath,
              operationError: error,
              cleanupError: cleanupError,
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      baseline?.fillRange(0, baseline.length, 0);
      newBytes.fillRange(0, newBytes.length, 0);
    }
  }

  /// Creates [path] without replacing an existing remote file.
  ///
  /// `writeExclusive` must clean up its own partially-created final target if
  /// a write or close fails. The default mode is 0600; special permission bits
  /// are always stripped.
  Future<SftpTextSaveSuccess> saveAs(
    String path,
    String text, {
    int? permissionBits,
  }) async {
    final targetPath = _validateFilePath(path);
    final bytes = _encodeText(text);
    final permissions = _safePermissionBits(
      permissionBits ?? _newFilePermissionBits,
    );
    try {
      await _filesystem.writeExclusive(
        targetPath,
        bytes,
        permissionBits: permissions,
      );
      return SftpTextSaveSuccess(
        _newDocument(targetPath, bytes, text, permissions),
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<SftpTextRemoteSnapshot> _readSnapshot(String path) async {
    final snapshot = await _filesystem.readFile(
      path,
      // One extra byte distinguishes an exactly-at-limit file from an
      // oversized file while still bounding the adapter's actual read.
      maxBytes: sftpTextFileMaxBytes + 1,
    );
    if (snapshot.bytes.length > sftpTextFileMaxBytes) {
      snapshot.dispose();
      throw const FormatException('Remote text file exceeds the 10 MiB limit.');
    }
    if (!snapshot.isRegularFile) {
      snapshot.dispose();
      throw const FormatException(
        'Only regular remote files can be opened as text.',
      );
    }
    // Copy adapter-owned memory before decoding or retaining a baseline, then
    // clear the adapter buffer and the copy if decoding fails.
    final bytes = Uint8List.fromList(snapshot.bytes);
    snapshot.dispose();
    try {
      _decodeUtf8(bytes);
    } catch (_) {
      bytes.fillRange(0, bytes.length, 0);
      rethrow;
    }
    return SftpTextRemoteSnapshot(
      bytes: bytes,
      isRegularFile: true,
      permissionBits: _safePermissionBits(snapshot.permissionBits),
    );
  }

  SftpTextDocument _documentFromSnapshot(
    String path,
    SftpTextRemoteSnapshot snapshot,
  ) {
    try {
      return _newDocument(
        path,
        snapshot.bytes,
        _decodeUtf8(snapshot.bytes),
        _safePermissionBits(snapshot.permissionBits),
      );
    } finally {
      snapshot.dispose();
    }
  }

  SftpTextDocument _newDocument(
    String path,
    Uint8List bytes,
    String text,
    int? permissionBits,
  ) => SftpTextDocument._(
    path: path,
    name: _basename(path),
    text: text,
    originalBytes: Uint8List.fromList(bytes),
    permissionBits: _safePermissionBits(permissionBits),
    sessionId: sessionId,
  );

  Future<String> _stageTempFile(
    String targetPath,
    Uint8List bytes,
    int? permissionBits,
  ) async {
    for (var attempt = 0; attempt < _maxTempNameAttempts; attempt++) {
      final tempPath = _makeTempPath(targetPath);
      try {
        await _filesystem.writeExclusive(
          tempPath,
          bytes,
          permissionBits: permissionBits,
        );
        return tempPath;
      } on SftpTextFileAlreadyExistsException {
        // Exclusive create proves the colliding file belongs to someone else;
        // leave it untouched and retry with a fresh random component.
      }
    }
    throw StateError(
      'Could not allocate a unique same-directory SFTP staging file.',
    );
  }

  String _makeTempPath(String targetPath) {
    final slash = targetPath.lastIndexOf('/');
    final directory = slash < 0 ? '' : targetPath.substring(0, slash + 1);
    final name = targetPath.substring(slash + 1);
    final randomHex = List<String>.generate(
      4,
      // Use a literal bound: `1 << 32` becomes zero in dart2js because JS
      // bitwise shifts use 32-bit operands.
      (_) => _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '$directory.$name.atermius-$randomHex.tmp';
  }

  Future<void> _removeStagedFile(
    String tempPath, {
    required Object operationError,
  }) async {
    try {
      await _filesystem.removeFile(tempPath);
    } catch (cleanupError) {
      throw SftpTextTempCleanupException(
        tempPath: tempPath,
        operationError: operationError,
        cleanupError: cleanupError,
      );
    }
  }

  static Uint8List _encodeText(String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > sftpTextFileMaxBytes) {
      throw const FormatException('Text exceeds the 10 MiB limit.');
    }
    return bytes;
  }

  static String _validateBytesAndDecode(Uint8List bytes) {
    if (bytes.length > sftpTextFileMaxBytes) {
      throw const FormatException('Remote text file exceeds the 10 MiB limit.');
    }
    return _decodeUtf8(bytes);
  }

  static String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const FormatException('Remote file is not valid UTF-8 text.');
    }
  }

  static String _validateFilePath(String path) {
    if (path.isEmpty || path.contains('\u0000') || path.contains('\\')) {
      throw const FormatException('Remote file path is unsafe.');
    }
    if (path.endsWith('/')) {
      throw const FormatException('A remote file path must name a file.');
    }
    final components = path.split('/');
    for (var index = 0; index < components.length; index++) {
      final component = components[index];
      if (component.isEmpty && index == 0 && path.startsWith('/')) continue;
      if (!isSafeSftpBasename(component)) {
        throw const FormatException(
          'Remote file path contains an unsafe component.',
        );
      }
    }
    return path;
  }

  static String _basename(String path) =>
      path.substring(path.lastIndexOf('/') + 1);

  static int? _safePermissionBits(int? bits) =>
      bits == null ? null : bits & _ordinaryPermissionMask;

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
