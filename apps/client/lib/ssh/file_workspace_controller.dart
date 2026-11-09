import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import '../domain/sftp_entries.dart';
import '../sftp/external_edit_manager.dart';
import '../sftp/external_edit_platform.dart';
import '../sftp/remote_file_operations.dart';
import 'local_profile_sftp_controller.dart';
import 'scp_transfer_activity.dart';
import 'scp_transfer_service.dart';
import 'ssh_service.dart';
import '../l10n/l10n.dart';

export '../sftp/remote_file_operations.dart'
    show
        RemoteFileOperationException,
        RemoteFileOperationError,
        RemoteTreePlan,
        RemoteTreeEntryKind;

/// Maximum number of local files accepted from one drop.
const fileManagerMaxDroppedFiles = 64;

enum RemoteFileClipboardMode { copy, cut }

/// A copied or cut entry. It lives only inside the [FileWorkspaceController]
/// that created it (one SFTP session on one exact SSH connection object) and
/// is cleared when that controller closes, so it can never be pasted into a
/// different connection, account or host.
@immutable
class RemoteFileClipboard {
  const RemoteFileClipboard._({
    required this.sessionId,
    required this.path,
    required this.name,
    required this.directory,
    required this.mode,
  });

  final String sessionId;
  final String path;
  final String name;
  final bool directory;
  final RemoteFileClipboardMode mode;
  String get parent => paths.posix.dirname(path);
}

enum RemoteFileActivityKind { copy, move, delete, upload }

/// One running file-manager job, shown in the file tab's bottom bar.
class RemoteFileActivity extends ChangeNotifier {
  RemoteFileActivity._(this.kind, this.name, {this.count = 1});

  final RemoteFileActivityKind kind;

  /// Untrusted remote/local basename, for display only.
  String name;
  final int count;
  int index = 0;
  int done = 0;
  int total = 0;
  final _cancellation = RemoteFileCancellation();
  SshTransferCancellation? _transfer;
  bool get isCancelled => _cancellation.isCancelled;
  bool get canCancel =>
      !_cancellation.isCancelled && (_transfer?.canCancel ?? true);
  double? get fraction => total <= 0 ? null : (done / total).clamp(0, 1);

  void cancel() {
    if (!canCancel) return;
    _cancellation.cancel();
    _transfer?.cancel();
    notifyListeners();
  }

  void _progress(int done, int total) {
    this.done = done;
    this.total = total;
    notifyListeners();
  }
}

/// A local file chosen by OS/browser drop. [open] streams it lazily; nothing
/// is read into memory up front.
class LocalUploadSource {
  const LocalUploadSource({
    required this.name,
    required this.length,
    required this.open,
  });

  final String name;
  final int length;
  final Stream<Uint8List> Function() open;
}

enum UploadConflictChoice { keepBoth, skip, cancel }

class UploadSummary {
  const UploadSummary(this.uploaded, this.skipped, this.failed);
  final int uploaded, skipped, failed;
}

/// Streams one local file to an exclusive-created remote path.
typedef RemoteFileUploader = Future<void> Function({
  required String remotePath,
  required Stream<Uint8List> source,
  required int size,
  required SshTransferCancellation cancellation,
  required void Function(SshTransferProgress progress) onProgress,
});

/// A file tab owns its browsing state and SFTP channel, never its SSH owner.
final class FileWorkspaceController extends ChangeNotifier {
  FileWorkspaceController({
    required this.connection,
    required this.protocol,
    String initialPath = '/',
    LocalProfileSftpTransportFactory? transportFactory,
    this.uploader,
    ExternalEditPlatform? externalEditPlatform,
    this._externalEditFileSystem,
  }) : _path = _absolutePath('/', initialPath),
       _externalEditPlatform =
           externalEditPlatform ?? createDefaultExternalEditPlatform(),
       sftp = LocalProfileSftpController(
         connection: connection,
         transportFactory: transportFactory,
       );

  final SshConnection connection;
  final SshTransferProtocol protocol;
  final LocalProfileSftpController sftp;

  /// Test seam; defaults to the exclusive-create SFTP streaming upload on
  /// this controller's own SSH connection.
  final RemoteFileUploader? uploader;
  String _path;
  String get path => _path;
  List<SftpName> entries = const [];
  SftpName? selected;
  bool loading = false;
  String? error;
  bool _closed = false;
  Future<void>? _closing;
  int _generation = 0;
  bool get isClosed => _closed;

  RemoteFileClipboard? _clipboard;
  RemoteFileClipboard? get clipboard => _clipboard;

  RemoteFileActivity? _activity;
  RemoteFileActivity? get activity => _activity;
  bool get busy => _activity != null;

  final ExternalEditPlatform? _externalEditPlatform;
  final ExternalEditRemoteFileSystem? _externalEditFileSystem;
  ExternalEditManager? _externalEdits;

  /// External-application edits bound to this tab's own SFTP session; closed
  /// (watchers stopped, owned copies deleted, nothing uploaded) with the tab.
  ExternalEditManager get externalEdits =>
      _externalEdits ??= ExternalEditManager(
        sessionId: sftp.sessionId,
        remote: _externalEditFileSystem ?? sftp.externalEditFileSystem,
        platform: _externalEditPlatform,
        isOpen: () => !_closed && !sftp.isClosed,
        currentSessionId: () => sftp.sessionId,
      );

  Future<void> navigate(String path, {String? selectName}) async {
    if (_closed) return;
    final generation = ++_generation;
    loading = true;
    error = null;
    selected = null;
    notifyListeners();
    try {
      final target = _absolutePath(_path, path);
      final result = await sftp.listDirectory(target);
      if (_closed || generation != _generation) return;
      _path = target;
      entries = result;
      if (selectName != null) {
        selected = result.where((e) => e.filename == selectName).firstOrNull;
      }
    } catch (failure) {
      if (_closed || generation != _generation) return;
      error = protocol == SshTransferProtocol.scp
          ? currentL10n.scpFileListingRequiresTheSftp
          : fileWorkspaceErrorText(failure);
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh({String? selectName}) =>
      navigate(_path, selectName: selectName);

  Future<void> enter(SftpName entry) {
    if (entry.attr.isDirectory != true) return Future.value();
    return navigate(sftpChildPath(_path, entry.filename));
  }

  Future<void> up() => navigate(paths.posix.dirname(_path));

  static String _absolutePath(String parent, String path) {
    if (path.isEmpty ||
        path.length > 4096 ||
        containsSftpControlCharacters(path)) {
      throw FormatException(currentL10n.invalidRemoteFolderPath);
    }
    return paths.posix.normalize(paths.posix.join(parent, path));
  }

  void select(SftpName? entry) {
    if (_closed) return;
    selected = entry;
    notifyListeners();
  }

  /// Full remote path of a listed entry in the current folder.
  String entryPath(SftpName entry) => sftpChildPath(_path, entry.filename);

  // ---------------------------------------------------------------- clipboard

  void copyToClipboard(SftpName entry) =>
      _setClipboard(entry, RemoteFileClipboardMode.copy);

  void cutToClipboard(SftpName entry) =>
      _setClipboard(entry, RemoteFileClipboardMode.cut);

  void _setClipboard(SftpName entry, RemoteFileClipboardMode mode) {
    if (_closed) return;
    _clipboard = RemoteFileClipboard._(
      sessionId: sftp.sessionId,
      path: entryPath(entry),
      name: entry.filename,
      directory: entry.attr.isDirectory == true,
      mode: mode,
    );
    notifyListeners();
  }

  void clearClipboard() {
    if (_clipboard == null) return;
    _clipboard = null;
    if (!_closed) notifyListeners();
  }

  /// Whether the clipboard can be pasted into [directory] of this tab.
  bool canPasteInto(String directory) {
    final clip = _clipboard;
    if (clip == null || _closed || busy) return false;
    if (clip.sessionId != sftp.sessionId) return false;
    if (clip.directory && isSameOrDescendantPath(directory, clip.path)) {
      return false;
    }
    // Cutting into the folder it already lives in is a no-op.
    return !(clip.mode == RemoteFileClipboardMode.cut &&
        clip.parent == directory);
  }

  /// Pastes the clipboard into [directory] (captured by the caller before any
  /// awaited UI). On a name collision [keepBoth] decides whether to use a free
  /// "(copy)" name; nothing is ever replaced. Cut clears the clipboard only
  /// after the move succeeded.
  Future<String?> paste(
    String directory, {
    required Future<bool> Function(String name) keepBoth,
  }) async {
    final clip = _clipboard;
    if (clip == null || !canPasteInto(directory)) return null;
    final operations = await sftp.fileOperations();
    var name = clip.name;
    if (await operations.exists(sftpChildPath(directory, name))) {
      if (_closed || !await keepBoth(name) || _closed) return null;
      name = await operations.availableName(directory, name);
    }
    if (!identical(_clipboard, clip)) return null;
    final String result;
    if (clip.mode == RemoteFileClipboardMode.cut) {
      result = await _runActivity(
        RemoteFileActivityKind.move,
        clip.name,
        (_) => operations.move(clip.path, directory, name),
      );
      if (identical(_clipboard, clip)) clearClipboard();
    } else {
      final plan = await operations.planCopy(clip.path);
      result = await _runActivity(
        RemoteFileActivityKind.copy,
        clip.name,
        (activity) => operations.copy(
          plan,
          clip.path,
          directory,
          name,
          cancellation: activity._cancellation,
          onProgress: (p) => activity._progress(p.done, p.total),
        ),
      );
    }
    if (!_closed && directory == _path) {
      await refresh(selectName: paths.posix.basename(result));
    }
    return result;
  }

  /// Moves a listed [entry] of the current folder into [directory] (internal
  /// drag). Never replaces an existing entry.
  Future<void> moveEntry(SftpName entry, String directory) async {
    final source = entryPath(entry);
    if (source == sftpChildPath(directory, entry.filename)) return;
    final operations = await sftp.fileOperations();
    await _runActivity(
      RemoteFileActivityKind.move,
      entry.filename,
      (_) => operations.move(source, directory, entry.filename),
    );
    if (!_closed) await refresh();
  }

  Future<void> renameEntry(
    String parent,
    SftpName entry,
    String newName,
  ) async {
    final operations = await sftp.fileOperations();
    final target = await operations.rename(parent, entry.filename, newName);
    final clip = _clipboard;
    if (clip != null &&
        (clip.path == sftpChildPath(parent, entry.filename) ||
            isSameOrDescendantPath(
              clip.path,
              sftpChildPath(parent, entry.filename),
            ))) {
      // The clipboard path no longer names the entry the user copied.
      clearClipboard();
    }
    if (!_closed && parent == _path) {
      await refresh(selectName: paths.posix.basename(target));
    }
  }

  /// Bounded preview of what deleting [entry] in [parent] would remove.
  Future<RemoteTreePlan> planDelete(String parent, SftpName entry) async {
    final operations = await sftp.fileOperations();
    return operations.planDelete(sftpChildPath(parent, entry.filename));
  }

  Future<void> deletePlanned(
    String parent,
    SftpName entry,
    RemoteTreePlan plan,
  ) async {
    final operations = await sftp.fileOperations();
    final target = sftpChildPath(parent, entry.filename);
    try {
      await _runActivity(
        RemoteFileActivityKind.delete,
        entry.filename,
        (activity) => operations.delete(
          plan,
          target,
          cancellation: activity._cancellation,
          onProgress: (p) => activity._progress(p.done, p.total),
        ),
      );
    } finally {
      final clip = _clipboard;
      if (clip != null && isSameOrDescendantPath(clip.path, target)) {
        clearClipboard();
      }
      if (!_closed && parent == _path) await refresh();
    }
  }

  // ------------------------------------------------------------------ uploads

  /// Uploads dropped local files into [directory] with exclusive create.
  ///
  /// [directory] and this controller's connection are captured before any
  /// await. Collisions ask [onConflict]; there is no overwrite choice.
  Future<UploadSummary> uploadLocalFiles(
    List<LocalUploadSource> files,
    String directory, {
    required Future<UploadConflictChoice> Function(String name) onConflict,
  }) async {
    if (_closed || busy) return const UploadSummary(0, 0, 0);
    if (protocol != SshTransferProtocol.sftp) {
      throw FormatException(currentL10n.fileManagerDropNeedsSftp);
    }
    if (files.length > fileManagerMaxDroppedFiles) {
      throw FormatException(
        currentL10n.fileManagerDropTooManyFiles(fileManagerMaxDroppedFiles),
      );
    }
    for (final file in files) {
      if (!isSafeSftpBasename(file.name) || file.name.length > 255) {
        throw FormatException(currentL10n.theLocalFileNameIsntA);
      }
      if (file.length < 0 || file.length > sshTransferMaximumBytes) {
        throw FormatException(currentL10n.fileExceeds1GibTransferLimit);
      }
    }
    final operations = await sftp.fileOperations();
    final targets = <(LocalUploadSource, String)>[];
    var skipped = 0;
    final reserved = <String>{};
    for (final file in files) {
      var name = file.name;
      if (reserved.contains(name) ||
          await operations.exists(sftpChildPath(directory, name))) {
        if (_closed) return UploadSummary(0, skipped, 0);
        final choice = await onConflict(name);
        if (_closed || choice == UploadConflictChoice.cancel) {
          return UploadSummary(0, skipped, 0);
        }
        if (choice == UploadConflictChoice.skip) {
          skipped++;
          continue;
        }
        name = await operations.availableName(
          directory,
          name,
          reserved: reserved,
        );
      }
      reserved.add(name);
      targets.add((file, name));
    }
    if (targets.isEmpty || _closed || busy) {
      return UploadSummary(0, skipped, 0);
    }
    final upload = uploader ?? _defaultUploader(connection.client);
    var uploaded = 0;
    var failed = 0;
    final activity = RemoteFileActivity._(
      RemoteFileActivityKind.upload,
      targets.first.$2,
      count: targets.length,
    );
    _activity = activity;
    notifyListeners();
    try {
      for (final (file, name) in targets) {
        if (_closed || activity.isCancelled) break;
        activity
          ..name = name
          .._progress(0, file.length);
        final cancellation = SshTransferCancellation();
        activity._transfer = cancellation;
        final job = sshTransferActivity.begin(cancellation);
        try {
          await upload(
            remotePath: sftpChildPath(directory, name),
            source: file.open(),
            size: file.length,
            cancellation: cancellation,
            onProgress: (p) {
              sshTransferActivity.update(job, p);
              activity._progress(p.transferred, p.total);
            },
          );
          uploaded++;
        } on SshTransferCancelled {
          break;
        } catch (_) {
          failed++;
        } finally {
          sshTransferActivity.end(job);
          activity._transfer = null;
          activity.index++;
        }
      }
    } finally {
      _finishActivity(activity);
    }
    if (!_closed && directory == _path) await refresh();
    return UploadSummary(uploaded, skipped, failed);
  }

  static RemoteFileUploader _defaultUploader(SSHClient client) {
    final service = SshFileTransferService(client);
    return ({
      required remotePath,
      required source,
      required size,
      required cancellation,
      required onProgress,
    }) => service.upload(
      protocol: SshTransferProtocol.sftp,
      remotePath: remotePath,
      source: source,
      size: size,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  Future<T> _runActivity<T>(
    RemoteFileActivityKind kind,
    String name,
    Future<T> Function(RemoteFileActivity activity) body,
  ) async {
    if (_closed) throw StateError(currentL10n.theSshSftpSessionIsClosed);
    if (busy) throw StateError(currentL10n.fileManagerBusy);
    final activity = RemoteFileActivity._(kind, name);
    _activity = activity;
    notifyListeners();
    try {
      return await body(activity);
    } finally {
      _finishActivity(activity);
    }
  }

  void _finishActivity(RemoteFileActivity activity) {
    if (!identical(_activity, activity)) return;
    _activity = null;
    if (!_closed) notifyListeners();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _generation++;
    _clipboard = null;
    _activity?.cancel();
    try {
      await _externalEdits?.close();
    } finally {
      await sftp.close();
    }
  }

  @override
  void dispose() {
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}

String fileWorkspaceErrorText(Object error) {
  final l10n = currentL10n;
  if (error is FormatException) return error.message;
  if (error is SshTransferCancelled) return l10n.fileManagerCancelled;
  if (error is RemoteFileOperationException) {
    final name = error.name ?? '';
    return switch (error.error) {
      RemoteFileOperationError.destinationExists => l10n.fileManagerErrorExists(
        name,
      ),
      RemoteFileOperationError.sourceChanged =>
        l10n.fileManagerErrorSourceChanged,
      RemoteFileOperationError.intoItself => l10n.fileManagerErrorIntoItself,
      RemoteFileOperationError.unsupportedEntry =>
        l10n.fileManagerErrorUnsupportedEntry(name),
      RemoteFileOperationError.limitExceeded =>
        l10n.fileManagerErrorLimitExceeded(2000, 32),
      RemoteFileOperationError.fileTooLarge =>
        l10n.fileManagerErrorFileTooLarge(name),
      RemoteFileOperationError.invalidName => l10n.invalidFileNameFormat,
      RemoteFileOperationError.cancelled => l10n.fileManagerCancelled,
    };
  }
  if (error is UnsupportedError && error.message != null) {
    // Unsupported errors in this stack carry app-owned localized text only.
    return error.message!;
  }
  return l10n.theFileActionFailedCheckThe;
}
