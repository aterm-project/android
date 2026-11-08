import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_file_saver.dart';
import '../domain/sftp_entries.dart';
import '../domain/sftp_transfer.dart';
import '../sftp/dart_sftp_text_file_system.dart';
import '../sftp/sftp_text_editor_service.dart';
import 'ssh_service.dart';
import '../l10n/l10n.dart';

const localProfileSftpMaxDownloadBytes = 256 * 1024 * 1024;

/// Narrow transport surface for API-free LocalVault SFTP and its tests.
abstract interface class LocalProfileSftpTransport {
  Future<List<SftpName>> listDirectory(String path);

  Future<void> createDirectory(String path);

  Future<void> uploadExclusive(String path, Uint8List bytes);

  Future<Uint8List> downloadRegularFile(String path, {required int maxBytes});

  Future<int> downloadRegularFileTo(
    String path, {
    required int maxBytes,
    required Future<void> Function(Uint8List chunk) onChunk,
  });

  Future<void> removeFile(String path);

  Future<void> removeDirectory(String path);

  Future<SftpTextEditorService> textEditor({required String sessionId});

  Future<void> close();
}

typedef LocalProfileSftpTransportFactory =
    Future<LocalProfileSftpTransport> Function(SshConnection connection);

/// SFTP operations bound to one direct LocalVault SSH connection.
///
/// It has no account API, sync repository, or Relay dependency. Disposing the
/// controller closes its SFTP channel and prevents later operations.
final class LocalProfileSftpController {
  LocalProfileSftpController({
    required this.connection,
    LocalProfileSftpTransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? _openDartSftp;

  final SshConnection connection;
  final LocalProfileSftpTransportFactory _transportFactory;
  final String sessionId = const Uuid().v4();

  Future<LocalProfileSftpTransport>? _transportOpening;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<List<SftpName>> listDirectory(String path) async {
    final safePath = _validateRemotePath(path);
    final transport = await _requireTransport();
    final entries = await transport.listDirectory(safePath);
    _ensureOpen();
    return visibleSftpEntries(entries);
  }

  Future<void> createDirectory(String parent, String name) async {
    final safeName = name.trim();
    if (!isSafeSftpBasename(safeName)) {
      throw FormatException(currentL10n.invalidFolderNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), safeName);
    final transport = await _requireTransport();
    await transport.createDirectory(path);
    _ensureOpen();
  }

  Future<void> uploadFile({
    required String parent,
    required String name,
    required Uint8List bytes,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.theLocalFileNameIsntA);
    }
    if (bytes.length > attachmentSmallSaveLimitBytes) {
      throw FormatException(currentL10n.theFileExceedsThisPlatformsSftp);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    await transport.uploadExclusive(path, bytes);
    _ensureOpen();
  }

  Future<Uint8List> downloadFile({
    required String parent,
    required String name,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    final bytes = await transport.downloadRegularFile(
      path,
      maxBytes: localProfileSftpMaxDownloadBytes,
    );
    try {
      _ensureOpen();
      return bytes;
    } catch (_) {
      bytes.fillRange(0, bytes.length, 0);
      rethrow;
    }
  }

  Future<int> downloadFileTo({
    required String parent,
    required String name,
    required AttachmentStreamingSaveWriter destination,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    try {
      final transport = await _requireTransport();
      final byteCount = await transport.downloadRegularFileTo(
        path,
        maxBytes: attachmentStreamingSaveLimitBytes,
        onChunk: (chunk) async {
          _ensureOpen();
          await destination.write(chunk);
        },
      );
      _ensureOpen();
      await destination.commit();
      return byteCount;
    } catch (_) {
      await destination.abort();
      rethrow;
    }
  }

  Future<void> deleteEntry({
    required String parent,
    required SftpName item,
  }) async {
    if (!isSafeSftpBasename(item.filename)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), item.filename);
    final transport = await _requireTransport();
    if (item.attr.isDirectory == true) {
      await transport.removeDirectory(path);
    } else {
      await transport.removeFile(path);
    }
    _ensureOpen();
  }

  Future<SftpTextDocument> openTextFile({
    required String parent,
    required String name,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    final editor = await transport.textEditor(sessionId: sessionId);
    final document = await editor.open(path);
    try {
      _ensureOpen();
      return document;
    } catch (_) {
      document.dispose();
      rethrow;
    }
  }

  Future<SftpTextSaveResult> saveTextFile(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
    String? saveAsName,
  }) async {
    if (document.sessionId != sessionId) {
      throw StateError(currentL10n.theSftpDocumentBelongsToA);
    }
    if (saveAsName != null && !isSafeSftpBasename(saveAsName.trim())) {
      throw FormatException(currentL10n.invalidFileNameFormat);
    }
    final transport = await _requireTransport();
    final editor = await transport.textEditor(sessionId: sessionId);
    final result = saveAsName == null
        ? await editor.save(
            document,
            text,
            expectedRemoteBytes: expectedRemoteBytes,
          )
        : await editor.saveAs(
            sftpChildPath(_parentPath(document.path), saveAsName.trim()),
            text,
            permissionBits: document.permissionBits,
          );
    _ensureOpen();
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final opening = _transportOpening;
    if (opening == null) return;
    try {
      await (await opening).close();
    } catch (_) {
      // The parent SSH transport may already have closed the SFTP channel.
    }
  }

  Future<LocalProfileSftpTransport> _requireTransport() async {
    _ensureOpen();
    final opening = _transportOpening ??= _transportFactory(connection);
    try {
      final transport = await opening;
      _ensureOpen();
      return transport;
    } catch (_) {
      if (identical(_transportOpening, opening)) _transportOpening = null;
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError(currentL10n.theSshSftpSessionIsClosed);
  }

  static String _validateRemotePath(String path) {
    if (path.isEmpty ||
        path.length > 4096 ||
        containsSftpControlCharacters(path)) {
      throw FormatException(currentL10n.invalidRemoteFolderPath);
    }
    return path;
  }

  static String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    if (separator <= 0) return '/';
    return path.substring(0, separator);
  }

  static Future<LocalProfileSftpTransport> _openDartSftp(
    SshConnection connection,
  ) async {
    final client = await connection.client.sftp();
    try {
      final handshake = await client.handshake;
      return _DartLocalProfileSftpTransport(client, handshake);
    } catch (_) {
      await client.close();
      rethrow;
    }
  }
}

final class _DartLocalProfileSftpTransport
    implements LocalProfileSftpTransport {
  _DartLocalProfileSftpTransport(this._client, this._handshake);

  final SftpClient _client;
  final SftpHandsake _handshake;

  @override
  Future<List<SftpName>> listDirectory(String path) => _client.listdir(path);

  @override
  Future<void> createDirectory(String path) => _client.mkdir(path);

  @override
  Future<void> uploadExclusive(String path, Uint8List bytes) async {
    if (!supportsSftpExclusiveCreate(_handshake.version)) {
      throw UnsupportedError(currentL10n.theSftpServerVersionDoesntSupport);
    }
    await writeSftpFileWithoutOverwrite(
      remotePath: path,
      bytes: bytes,
      createExclusive: () async {
        try {
          return DartSftpUploadHandle(
            await _client.open(path, mode: sftpExclusiveCreateMode),
          );
        } on SftpStatusError catch (error) {
          throw StateError(currentL10n.couldntSafelyCreateTheRemoteFile(error));
        }
      },
      removePartial: () => _client.remove(path),
    );
  }

  @override
  Future<Uint8List> downloadRegularFile(
    String path, {
    required int maxBytes,
  }) async {
    if (maxBytes < 1) throw RangeError.value(maxBytes, 'maxBytes');
    final attributes = await _client.stat(path, followLink: false);
    if (attributes.mode?.type != SftpFileType.regularFile) {
      throw FormatException(currentL10n.onlyRegularFilesCanBeDownloaded);
    }
    if ((attributes.size ?? 0) > maxBytes) {
      throw FormatException(currentL10n.theRemoteFileExceedsTheLocal);
    }
    final file = await _client.open(path);
    try {
      final handleAttributes = await file.stat();
      if (handleAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsntARegular2);
      }
      final latestAttributes = await _client.stat(path, followLink: false);
      if (latestAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsNoLonger);
      }
      final bytes = await file.readBytes(length: maxBytes + 1);
      if (bytes.length > maxBytes) {
        bytes.fillRange(0, bytes.length, 0);
        throw FormatException(currentL10n.theRemoteFileExceedsTheLocal);
      }
      return bytes;
    } finally {
      await file.close();
    }
  }

  @override
  Future<int> downloadRegularFileTo(
    String path, {
    required int maxBytes,
    required Future<void> Function(Uint8List chunk) onChunk,
  }) async {
    if (maxBytes < 1) throw RangeError.value(maxBytes, 'maxBytes');
    final pathAttributes = await _client.stat(path, followLink: false);
    if (pathAttributes.mode?.type != SftpFileType.regularFile ||
        (pathAttributes.size ?? 0) > maxBytes) {
      throw FormatException(currentL10n.onlySizeBoundedRegularFilesCan);
    }
    final file = await _client.open(path);
    try {
      final handleAttributes = await file.stat();
      if (handleAttributes.mode?.type != SftpFileType.regularFile ||
          (handleAttributes.size ?? 0) > maxBytes) {
        throw FormatException(currentL10n.theRemotePathIsntASize);
      }
      final latestAttributes = await _client.stat(path, followLink: false);
      if (latestAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsNoLonger);
      }
      var total = 0;
      await for (final chunk in file.read()) {
        total += chunk.length;
        try {
          if (total > maxBytes) {
            throw FormatException(currentL10n.theRemoteFileExceedsTheStreaming);
          }
          await onChunk(chunk);
        } finally {
          chunk.fillRange(0, chunk.length, 0);
        }
      }
      return total;
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> removeFile(String path) => _client.remove(path);

  @override
  Future<void> removeDirectory(String path) => _client.rmdir(path);

  @override
  Future<SftpTextEditorService> textEditor({required String sessionId}) async {
    if (!supportsSftpExclusiveCreate(_handshake.version)) {
      throw UnsupportedError(currentL10n.theSftpServerVersionIsBelow);
    }
    return SftpTextEditorService(
      filesystem: DartSftpTextFileSystem(
        _client,
        supportsAtomicReplaceExtension:
            _handshake.extensions['posix-rename@openssh.com'] == '1',
      ),
      sessionId: sessionId,
    );
  }

  @override
  Future<void> close() => _client.close();
}
