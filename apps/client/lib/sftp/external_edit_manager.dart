import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/sftp_entries.dart';
import 'external_edit_platform.dart';
import 'external_edit_policy.dart';
import 'sftp_text_editor_service.dart';

/// Resolves the byte-level SFTP filesystem of the owning file tab's session.
typedef ExternalEditRemoteFileSystem = Future<SftpTextFileSystem> Function();

enum ExternalEditStatus {
  /// Local copy equals the last baseline, or its change was ignored.
  watching,

  /// The local copy differs; waiting for an explicit choice.
  changed,
  uploading,

  /// The server copy changed since the baseline; needs confirmation.
  conflict,

  /// The last upload failed; the local change is still pending.
  failed,

  /// The local path became a link/non-regular/oversized file.
  rejected,
}

enum ExternalEditUploadResult {
  uploaded,

  /// Uploaded, but the local copy changed again while sending.
  uploadedChangedAgain,
  remoteChanged,
  failed,
  notPending,
}

/// One remote file opened in an external application.
///
/// Identity (session, remote path) is captured at open time and never
/// changes. Only SHA-256 digests are retained, never file contents.
final class ExternalEditItem {
  ExternalEditItem._({
    required this.id,
    required this.sessionId,
    required this.remotePath,
    required this.localPath,
    required this.mode,
    required Digest baseline,
    required this.permissionBits,
    required this._copy,
  }) : _remoteBaseline = baseline,
       _localBaseline = baseline,
       _localCurrent = baseline;

  final String id;
  final String sessionId;
  final String remotePath;
  final String localPath;
  final ExternalEditLaunchMode mode;
  final int? permissionBits;
  final ExternalEditLocalCopy _copy;

  /// Untrusted remote basename, for display only.
  String get name => remotePath.substring(remotePath.lastIndexOf('/') + 1);

  ExternalEditStatus _status = ExternalEditStatus.watching;
  ExternalEditStatus get status => _status;

  /// Last failure (an [ExternalEditException] or SFTP error); no contents.
  Object? error;

  Digest _remoteBaseline;
  Digest _localBaseline;
  Digest? _localCurrent;
  Digest? _ignored;
  Digest? _conflictRemote;
  StreamSubscription<void>? _watch;
  Timer? _debounce;
  Future<void>? _scanning;
  bool _rescan = false;
  bool _detached = false;

  /// Whether the footer must ask the user what to do with a local change.
  bool get needsAttention => _status != ExternalEditStatus.watching;

  bool get canUpload =>
      _status == ExternalEditStatus.changed ||
      _status == ExternalEditStatus.conflict ||
      _status == ExternalEditStatus.failed;
}

/// External-application edits of one file tab's SFTP session.
///
/// Nothing is ever uploaded by a watcher event, focus change or editor
/// close: only [upload] sends bytes, and it re-checks the server copy
/// against the captured baseline first. [close] cancels watchers, discards
/// pending changes and deletes every owned local copy.
final class ExternalEditManager extends ChangeNotifier {
  ExternalEditManager({
    required this.sessionId,
    required this._remote,
    required this._platform,
    required this._isOpen,
    required this._currentSessionId,
    this.debounce = const Duration(milliseconds: 400),
    Random? random,
  }) : _random = random ?? Random.secure();

  final String sessionId;
  final Duration debounce;
  final ExternalEditRemoteFileSystem _remote;
  final ExternalEditPlatform? _platform;
  final bool Function() _isOpen;
  final String Function() _currentSessionId;
  final Random _random;

  final _items = <ExternalEditItem>[];
  final _kept = <ExternalEditItem>[];
  final _opening = <String>{};
  Future<ExternalEditLocalWorkspace>? _workspace;
  bool _closed = false;

  bool get isSupported =>
      _platform != null &&
      _platform.kind != ExternalEditPlatformKind.unsupported;
  bool get isClosed => _closed;
  List<ExternalEditItem> get items => List.unmodifiable(_items);
  List<ExternalEditItem> get pending =>
      _items.where((item) => item.needsAttention).toList(growable: false);

  ExternalEditItem? itemFor(String remotePath) =>
      _items.where((item) => item.remotePath == remotePath).firstOrNull;

  void _ensureOpen() {
    if (_closed || !_isOpen() || _currentSessionId() != sessionId) {
      throw const ExternalEditException(ExternalEditError.sessionChanged);
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  // --------------------------------------------------------------------- open

  /// Downloads [remotePath] (a regular file listed with [listedSize]) to an
  /// owned private copy, starts watching its directory and launches it.
  /// Re-opening a file already being edited only relaunches its copy.
  Future<ExternalEditItem> open(String remotePath, {int? listedSize}) async {
    final platform = _platform;
    if (platform == null || !isSupported) {
      throw const ExternalEditException(ExternalEditError.unsupported);
    }
    _ensureOpen();
    final existing = itemFor(remotePath);
    if (existing != null) {
      await platform.launch(existing.localPath, existing.mode);
      return existing;
    }
    if (_items.length + _opening.length >= externalEditMaxConcurrent) {
      throw const ExternalEditException(ExternalEditError.tooMany);
    }
    if (listedSize != null && listedSize > externalEditMaxBytes) {
      throw const ExternalEditException(ExternalEditError.tooLarge);
    }
    if (!_opening.add(remotePath)) {
      throw const ExternalEditException(ExternalEditError.tooMany);
    }
    ExternalEditLocalCopy? copy;
    Uint8List? bytes;
    try {
      final remoteName = remotePath.substring(remotePath.lastIndexOf('/') + 1);
      if (!isSafeSftpBasename(remoteName)) {
        throw const ExternalEditException(ExternalEditError.notRegularRemote);
      }
      final filesystem = await _remote();
      _ensureOpen();
      final snapshot = await _readRemote(filesystem, remotePath);
      bytes = snapshot.bytes;
      final localName = externalEditLocalName(remoteName);
      final mode = externalEditLaunchMode(
        localName,
        Uint8List.sublistView(bytes, 0, min(bytes.length, 64)),
        platform.kind,
      );
      // Blocked formats never reach the local disk.
      if (mode == ExternalEditLaunchMode.blocked) {
        throw const ExternalEditException(ExternalEditError.blockedType);
      }
      final workspace = await (_workspace ??= platform.openWorkspace());
      _ensureOpen();
      copy = await workspace.createCopy(localName, bytes);
      final baseline = sha256.convert(bytes);
      bytes.fillRange(0, bytes.length, 0);
      bytes = null;
      _ensureOpen();
      final item = ExternalEditItem._(
        id: '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}',
        sessionId: sessionId,
        remotePath: remotePath,
        localPath: copy.path,
        mode: mode,
        baseline: baseline,
        permissionBits: snapshot.permissionBits,
        copy: copy,
      );
      // Watch before launching so the first save is never missed.
      item._watch = copy.watch().listen(
        (_) => _schedule(item),
        onError: (Object _) => _schedule(item),
        onDone: () => _schedule(item),
      );
      _items.add(item);
      _notify();
      try {
        await platform.launch(item.localPath, mode);
      } catch (_) {
        await _discard(item);
        _notify();
        rethrow;
      }
      return item;
    } catch (_) {
      if (copy != null && itemFor(remotePath)?._copy != copy) {
        await copy.delete();
      }
      rethrow;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      _opening.remove(remotePath);
    }
  }

  // -------------------------------------------------------------------- watch

  void _schedule(ExternalEditItem item) {
    if (_closed || item._detached) return;
    item._debounce?.cancel();
    item._debounce = Timer(debounce, () => unawaited(scan(item)));
  }

  /// Re-hashes the local copy (debounced watcher callback; also a test hook).
  /// Serialized per item; never uploads.
  Future<void> scan(ExternalEditItem item) async {
    if (_closed || item._detached) return;
    if (item._scanning != null) {
      item._rescan = true;
      return item._scanning;
    }
    final done = Completer<void>();
    item._scanning = done.future;
    try {
      do {
        item._rescan = false;
        await _scanOnce(item);
      } while (item._rescan && !_closed && !item._detached);
    } finally {
      item._scanning = null;
      done.complete();
    }
  }

  Future<void> _scanOnce(ExternalEditItem item) async {
    Digest? digest;
    try {
      digest = await item._copy.hash(externalEditMaxBytes);
    } on ExternalEditException catch (error) {
      if (_closed || item._detached) return;
      if (item._status != ExternalEditStatus.uploading) {
        item
          .._status = ExternalEditStatus.rejected
          ..error = error;
        _notify();
      }
      return;
    } catch (error) {
      return; // Transient IO race; the next event re-scans.
    }
    if (_closed || item._detached) return;
    // Absent: an editor's atomic save is between unlink and rename.
    if (digest == null) return;
    item._localCurrent = digest;
    if (item._status == ExternalEditStatus.uploading) return;
    _updateStatus(item);
    _notify();
  }

  void _updateStatus(ExternalEditItem item) {
    final current = item._localCurrent;
    if (current == null ||
        current == item._localBaseline ||
        current == item._ignored) {
      item
        .._status = ExternalEditStatus.watching
        ..error = null
        .._conflictRemote = null;
      if (current == item._localBaseline) item._ignored = null;
      return;
    }
    // A conflict/failure stays visible until the user acts; a fresh local
    // change after it is still "changed" and re-checks the server on upload.
    if (item._status == ExternalEditStatus.conflict ||
        item._status == ExternalEditStatus.failed) {
      return;
    }
    item
      .._status = ExternalEditStatus.changed
      ..error = null;
  }

  // ------------------------------------------------------------------- upload

  /// Explicitly sends the current local bytes of [item] to its captured
  /// remote path on this session.
  ///
  /// The server copy must still equal the captured baseline; otherwise the
  /// item enters [ExternalEditStatus.conflict] and nothing is written. Pass
  /// [replaceRemoteChange] only after the user confirmed replacing the server
  /// change; the exact server bytes observed by that conflict are then the
  /// expected value, re-checked immediately before the atomic replace.
  Future<ExternalEditUploadResult> upload(
    ExternalEditItem item, {
    bool replaceRemoteChange = false,
  }) async {
    if (!_items.contains(item) || !item.canUpload) {
      return ExternalEditUploadResult.notPending;
    }
    final expected = replaceRemoteChange
        ? item._conflictRemote
        : item._remoteBaseline;
    if (expected == null) return ExternalEditUploadResult.notPending;
    final previous = item._status;
    item
      .._status = ExternalEditStatus.uploading
      ..error = null;
    _notify();
    Uint8List? local;
    try {
      _ensureOpen();
      if (item.sessionId != sessionId) {
        throw const ExternalEditException(ExternalEditError.sessionChanged);
      }
      local = await item._copy.read(externalEditMaxBytes);
      if (local == null) {
        throw const ExternalEditException(ExternalEditError.localMissing);
      }
      final sent = sha256.convert(local);
      final filesystem = await _remote();
      _ensureOpen();
      final observed = await _remoteDigest(filesystem, item.remotePath);
      if (observed != expected) {
        _conflict(item, observed);
        return ExternalEditUploadResult.remoteChanged;
      }
      final replaced = await _replace(filesystem, item, local, expected);
      if (!replaced.$1) {
        _conflict(item, replaced.$2!);
        return ExternalEditUploadResult.remoteChanged;
      }
      // The server now holds exactly the sent snapshot.
      item
        .._remoteBaseline = sent
        .._localBaseline = sent
        .._conflictRemote = null
        .._ignored = null
        .._status = ExternalEditStatus.watching;
      await scan(item);
      final changedAgain =
          item._localCurrent != null && item._localCurrent != sent;
      if (changedAgain && item._status == ExternalEditStatus.watching) {
        item._status = ExternalEditStatus.changed;
      }
      _notify();
      return changedAgain
          ? ExternalEditUploadResult.uploadedChangedAgain
          : ExternalEditUploadResult.uploaded;
    } catch (error) {
      if (_items.contains(item)) {
        item
          .._status = previous == ExternalEditStatus.conflict
              ? ExternalEditStatus.conflict
              : ExternalEditStatus.failed
          ..error = error;
        _notify();
      }
      return ExternalEditUploadResult.failed;
    } finally {
      local?.fillRange(0, local.length, 0);
    }
  }

  void _conflict(ExternalEditItem item, Digest observed) {
    item
      .._conflictRemote = observed
      .._status = ExternalEditStatus.conflict
      ..error = null;
    _notify();
  }

  /// Stages [bytes] next to the target (exclusive create, owner-only), then
  /// re-reads the target and atomically replaces it only if it still equals
  /// [expected]. Returns `(false, observed)` for a late remote change.
  Future<(bool, Digest?)> _replace(
    SftpTextFileSystem filesystem,
    ExternalEditItem item,
    Uint8List bytes,
    Digest expected,
  ) async {
    if (!await filesystem.supportsAtomicReplace()) {
      throw const ExternalEditException(
        ExternalEditError.atomicReplaceUnsupported,
      );
    }
    _ensureOpen();
    final temp = await _stage(filesystem, item.remotePath, bytes);
    var staged = true;
    try {
      _ensureOpen();
      final latest = await _remoteDigest(filesystem, item.remotePath);
      if (latest != expected) {
        staged = false;
        await filesystem.removeFile(temp);
        return (false, latest);
      }
      _ensureOpen();
      await filesystem.replaceAtomically(temp, item.remotePath);
      staged = false;
      final permissions = item.permissionBits;
      if (permissions != null && permissions != 0x180) {
        try {
          await filesystem.setPermissionBits(item.remotePath, permissions);
        } catch (_) {
          // Contents are published; the safe owner-only mode remains.
        }
      }
      return (true, null);
    } finally {
      if (staged) {
        try {
          await filesystem.removeFile(temp);
        } catch (_) {}
      }
    }
  }

  Future<String> _stage(
    SftpTextFileSystem filesystem,
    String target,
    Uint8List bytes,
  ) async {
    final slash = target.lastIndexOf('/');
    final directory = target.substring(0, slash + 1);
    final name = target.substring(slash + 1);
    for (var attempt = 0; attempt < 4; attempt++) {
      final random = List<String>.generate(
        4,
        (_) => _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
      ).join();
      final temp = '$directory.$name.atermius-$random.tmp';
      try {
        await filesystem.writeExclusive(temp, bytes, permissionBits: 0x180);
        return temp;
      } on SftpTextFileAlreadyExistsException {
        // Someone else's file; never touch it, retry another name.
      }
    }
    throw StateError('Could not allocate a staging file.');
  }

  Future<Digest> _remoteDigest(
    SftpTextFileSystem filesystem,
    String path,
  ) async {
    final snapshot = await _readRemote(filesystem, path);
    try {
      return sha256.convert(snapshot.bytes);
    } finally {
      snapshot.dispose();
    }
  }

  static Future<SftpTextRemoteSnapshot> _readRemote(
    SftpTextFileSystem filesystem,
    String path,
  ) async {
    final snapshot = await filesystem.readFile(
      path,
      maxBytes: externalEditMaxBytes + 1,
    );
    if (!snapshot.isRegularFile) {
      snapshot.dispose();
      throw const ExternalEditException(ExternalEditError.notRegularRemote);
    }
    if (snapshot.bytes.length > externalEditMaxBytes) {
      snapshot.dispose();
      throw const ExternalEditException(ExternalEditError.tooLarge);
    }
    return snapshot;
  }

  // ------------------------------------------------------------------ choices

  /// Dismisses the current local change without uploading; a later save that
  /// produces different bytes asks again.
  void ignore(ExternalEditItem item) {
    if (!_items.contains(item) ||
        item._status == ExternalEditStatus.uploading) {
      return;
    }
    item
      .._ignored = item._localCurrent
      .._conflictRemote = null
      ..error = null
      .._status = ExternalEditStatus.watching;
    _notify();
  }

  /// Stops tracking [item] without uploading. Its local copy stays on disk
  /// until this file tab closes (then all owned copies are removed).
  Future<void> keepLocal(ExternalEditItem item) async {
    if (!_items.contains(item) ||
        item._status == ExternalEditStatus.uploading) {
      return;
    }
    _items.remove(item);
    _stopWatching(item);
    _kept.add(item);
    _notify();
  }

  void _stopWatching(ExternalEditItem item) {
    item._detached = true;
    item._debounce?.cancel();
    unawaited(item._watch?.cancel());
    item._watch = null;
  }

  Future<void> _discard(ExternalEditItem item) async {
    _items.remove(item);
    _stopWatching(item);
    await item._copy.delete();
  }

  /// Ends the session: watchers stop, pending changes are discarded (never
  /// uploaded) and every owned copy, kept or not, is deleted.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final all = [..._items, ..._kept];
    _items.clear();
    _kept.clear();
    for (final item in all) {
      _stopWatching(item);
    }
    final workspace = _workspace;
    _workspace = null;
    for (final item in all) {
      await item._copy.delete();
    }
    if (workspace != null) {
      try {
        await (await workspace).close();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
