import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../rdp_file_clipboard.dart';
import '../../l10n/l10n.dart';

const fileContentsSize = 1;
const fileContentsRange = 2;
const maxServedChunk = 8 * 1024 * 1024;
const downloadChunk = 1024 * 1024;

/// Resource bounds for one remote-clipboard download. The declared total is
/// shown to the user before saving; the server's FILECONTENTS_SIZE answer
/// must match the descriptor it advertised, so a tiny descriptor cannot be
/// turned into an unbounded stream.
const maxDownloadFileBytes = 64 * 1024 * 1024 * 1024; // 64 GiB per file
const maxDownloadTotalBytes = 256 * 1024 * 1024 * 1024; // 256 GiB per download
const maxUndeclaredFileBytes = 1024 * 1024 * 1024; // 1 GiB when size omitted

/// Null when [entries] fit the download bounds, else a reason.
String? downloadBudgetIssue(List<ClipboardFileEntry> entries) {
  var total = 0;
  for (final e in entries) {
    if (e.isDirectory) continue;
    final cap = e.sizeKnown ? maxDownloadFileBytes : maxUndeclaredFileBytes;
    if (e.size > cap) return currentL10n.fileTooLargeRelativepath(e.relativePath);
    total += e.sizeKnown ? e.size : maxUndeclaredFileBytes;
  }
  return total > maxDownloadTotalBytes ? currentL10n.theTotalSizeOfTheRemote : null;
}

/// Local files offered to the server. Only the user-selected paths and their
/// regular-file/directory descendants are reachable; links are not followed.
class LocalFileOffer {
  LocalFileOffer._(this.entries, this._paths);
  final List<ClipboardFileEntry> entries;
  final List<String> _paths;
  RandomAccessFile? _open;
  int _openIndex = -1;

  static LocalFileOffer build(List<String> roots) {
    final entries = <ClipboardFileEntry>[];
    final paths = <String>[];
    final topNames = <String>{};
    void add(String path, String relative, bool directory, int size, DateTime? modified) {
      if (entries.length >= maxClipboardFiles) {
        throw FormatException(currentL10n.tooManyFilesForTheClipboard);
      }
      entries.add(
        ClipboardFileEntry(
          relativePath: relative,
          isDirectory: directory,
          size: size,
          modified: modified,
        ),
      );
      paths.add(path);
    }

    void walk(Directory dir, String relative, int depth) {
      if (depth >= maxClipboardDepth) {
        throw FormatException(currentL10n.folderNestingIsTooDeep);
      }
      final children = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final name = p.basename(child.path);
        if (!isSafeClipboardSegment(name)) continue;
        final rel = '$relative\\$name';
        if (child is File) {
          final stat = child.statSync();
          add(child.path, rel, false, stat.size, stat.modified);
        } else if (child is Directory) {
          add(child.path, rel, true, 0, child.statSync().modified);
          walk(child, rel, depth + 1);
        }
      }
    }

    for (final root in roots) {
      final type = FileSystemEntity.typeSync(root, followLinks: false);
      final name = p.basename(root);
      if (!isSafeClipboardSegment(name) || !topNames.add(name.toLowerCase())) {
        throw FormatException(currentL10n.unsupportedOrDuplicateFileNameName(name));
      }
      if (type == FileSystemEntityType.file) {
        final stat = File(root).statSync();
        add(root, name, false, stat.size, stat.modified);
      } else if (type == FileSystemEntityType.directory) {
        add(root, name, true, 0, Directory(root).statSync().modified);
        walk(Directory(root), name, 1);
      } else {
        throw FormatException(currentL10n.notARegularFileOrFolder(name));
      }
    }
    if (entries.isEmpty) throw FormatException(currentL10n.noFilesToSend);
    return LocalFileOffer._(List.unmodifiable(entries), paths);
  }

  Uint8List encode() => encodeFileList(entries);

  /// Answer one FileContentsRequest. Returns null to send a failure.
  Uint8List? serve(int index, int flags, int position, int requested) {
    if (index < 0 || index >= entries.length || entries[index].isDirectory) {
      return null;
    }
    try {
      if (flags == fileContentsSize) {
        final size = File(_paths[index]).lengthSync();
        return (ByteData(8)..setUint64(0, size, Endian.little))
            .buffer
            .asUint8List();
      }
      if (flags != fileContentsRange || position < 0 || requested < 0) {
        return null;
      }
      if (_openIndex != index) {
        _open?.closeSync();
        _open = File(_paths[index]).openSync();
        _openIndex = index;
      }
      final file = _open!;
      file.setPositionSync(position);
      return file.readSync(requested.clamp(0, maxServedChunk));
    } on FileSystemException {
      close();
      return null;
    }
  }

  void close() {
    try {
      _open?.closeSync();
    } catch (_) {}
    _open = null;
    _openIndex = -1;
  }
}

typedef FileContentsRequester =
    bool Function(int stream, int index, int flags, int position, int size);

class DownloadProgress {
  const DownloadProgress(this.doneFiles, this.totalFiles, this.bytes);
  final int doneFiles, totalFiles, bytes;
}

/// Downloads the current remote clipboard file list into [target].
///
/// Safety rules (nothing that existed before the download is ever opened,
/// truncated, followed or deleted):
/// - every path comes from validated segments and stays inside [target];
///   top-level names get `name (2)` suffixes instead of colliding;
/// - directories are created one level at a time and must be real
///   directories afterwards (a symlink planted on the way aborts);
/// - each file first reserves its final name with an exclusive create (fails
///   on any existing file, directory or symlink), then data goes to a unique,
///   exclusively created temp file in the same directory, which is renamed
///   over that self-owned placeholder when complete;
/// - cleanup deletes only entries this download created, and only while they
///   are still regular files/directories (never through a symlink).
class RemoteFileDownload {
  RemoteFileDownload({
    required this.entries,
    required this.target,
    required this.request,
    this.responseTimeout = const Duration(seconds: 30),
    this.onProgress,
  });
  final List<ClipboardFileEntry> entries;
  final String target;
  final FileContentsRequester request;
  final Duration responseTimeout;
  final void Function(DownloadProgress)? onProgress;
  final _done = Completer<List<String>>();
  final Map<String, String> _topRenames = {};
  final List<String> _created = [];
  int _stream = 0x41540000, _index = -1, _size = 0, _position = 0, _bytes = 0;
  int _filesDone = 0;
  bool _awaitingSize = false, _finished = false;
  RandomAccessFile? _out;
  String? _partial, _final;
  Timer? _timer;

  /// Every file and directory this download created, newest last.
  final List<String> _ownedFiles = [];
  final List<String> _ownedDirs = [];
  static final _random = Random.secure();

  int get _fileCount => entries.where((e) => !e.isDirectory).length;
  Future<List<String>> get done => _done.future;

  /// Top-level paths created in [target], for the OS clipboard.
  List<String> get createdRoots => List.unmodifiable(_created);

  Future<List<String>> start() {
    try {
      final budget = downloadBudgetIssue(entries);
      if (budget != null) throw FileSystemException(budget);
      final root = Directory(target);
      if (!p.isAbsolute(target) || !root.existsSync()) {
        throw const FileSystemException('Download folder does not exist');
      }
      _next();
    } catch (e) {
      _fail(e);
    }
    return done;
  }

  String _localPath(ClipboardFileEntry entry) {
    final segments = entry.segments;
    final top = segments.first;
    final renamed = _topRenames.putIfAbsent(top, () {
      final name = uniqueName(
        top,
        (c) =>
            FileSystemEntity.typeSync(p.join(target, c), followLinks: false) !=
            FileSystemEntityType.notFound,
      );
      return name;
    });
    final path = p.joinAll([target, renamed, ...segments.skip(1)]);
    final normalized = p.normalize(path);
    if (!p.isWithin(p.normalize(target), normalized)) {
      throw const FormatException('Clipboard path escapes the download folder');
    }
    return normalized;
  }

  bool _isType(String path, FileSystemEntityType type) =>
      FileSystemEntity.typeSync(path, followLinks: false) == type;

  /// Create [dir] (inside [target]) one level at a time. Levels that already
  /// exist must be real directories we created earlier in this download, or
  /// [target] itself; anything else (including a symlink) aborts.
  void _ensureDirectory(String dir) {
    final root = p.normalize(target);
    final relative = p.split(p.relative(dir, from: root));
    var current = root;
    for (final part in relative) {
      if (part == '.') continue;
      current = p.join(current, part);
      if (_isType(current, FileSystemEntityType.notFound)) {
        Directory(current).createSync();
        if (!_isType(current, FileSystemEntityType.directory)) {
          throw FileSystemException('Unexpected entry while creating', current);
        }
        _ownedDirs.add(current);
        if (p.dirname(current) == root) _created.add(current);
      } else if (!_ownedDirs.contains(current) ||
          !_isType(current, FileSystemEntityType.directory)) {
        throw FileSystemException('Download path is not owned by this transfer', current);
      }
    }
  }

  String _tempName(String local) {
    final nonce = List.generate(8, (_) => _random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return p.join(
      p.dirname(local),
      '.${p.basename(local)}.$nonce.atermius-partial',
    );
  }

  void _next() {
    while (true) {
      _index++;
      if (_index >= entries.length) {
        _finish();
        return;
      }
      final entry = entries[_index];
      final local = _localPath(entry);
      if (entry.isDirectory) {
        _ensureDirectory(local);
        continue;
      }
      _ensureDirectory(p.dirname(local));
      // Reserve the final name: exclusive create fails on any existing entry,
      // including a dangling or planted symlink.
      File(local).createSync(exclusive: true);
      _ownedFiles.add(local);
      if (p.dirname(local) == p.normalize(target)) _created.add(local);
      _final = local;
      final temp = _tempName(local);
      File(temp).createSync(exclusive: true);
      _ownedFiles.add(temp);
      _partial = temp;
      if (!_isType(temp, FileSystemEntityType.file)) {
        throw FileSystemException('Temporary file was replaced', temp);
      }
      _out = File(temp).openSync(mode: FileMode.writeOnly);
      _position = 0;
      _awaitingSize = true;
      _send(fileContentsSize, 0, 8);
      return;
    }
  }

  void _send(int flags, int position, int size) {
    _stream = (_stream + 1) & 0x7fffffff;
    _timer?.cancel();
    _timer = Timer(responseTimeout, () => _fail(TimeoutException('No response')));
    if (!request(_stream, _index, flags, position, size)) {
      _fail(const FileSystemException('Remote clipboard is no longer available'));
    }
  }

  /// Feed an EVENT_FILE_DATA response.
  void onData(int stream, bool ok, Uint8List data) {
    if (_finished || stream != _stream) return;
    _timer?.cancel();
    try {
      if (!ok) throw const FileSystemException('Remote file read failed');
      if (_awaitingSize) {
        if (data.length != 8) throw const FormatException('Invalid file size');
        _size = ByteData.sublistView(data).getUint64(0, Endian.little);
        final entry = entries[_index];
        // The answer must agree with the advertised descriptor; without one,
        // a stricter cap applies. Aggregate bytes stay within the budget.
        if (_size < 0 ||
            (entry.sizeKnown && _size != entry.size) ||
            (!entry.sizeKnown && _size > maxUndeclaredFileBytes) ||
            _bytes + _size > maxDownloadTotalBytes) {
          throw const FormatException('Remote file size does not match its description');
        }
        _awaitingSize = false;
      } else {
        if (data.length > _size - _position) {
          throw const FormatException('Remote sent more data than declared');
        }
        _out!.writeFromSync(data);
        _position += data.length;
        _bytes += data.length;
        if (data.isEmpty && _position < _size) {
          throw const FormatException('Remote file ended early');
        }
      }
      if (_position >= _size) {
        _out!.closeSync();
        _out = null;
        // Replace only our own empty placeholder, never a different entry.
        if (!_isType(_final!, FileSystemEntityType.file) ||
            File(_final!).lengthSync() != 0 ||
            !_isType(_partial!, FileSystemEntityType.file)) {
          throw FileSystemException('Download target changed during transfer', _final);
        }
        File(_partial!).renameSync(_final!);
        _ownedFiles.remove(_partial);
        _partial = null;
        final modified = entries[_index].modified;
        if (modified != null) {
          try {
            File(_final!).setLastModifiedSync(modified);
          } catch (_) {}
        }
        _filesDone++;
        onProgress?.call(DownloadProgress(_filesDone, _fileCount, _bytes));
        _next();
      } else {
        _send(
          fileContentsRange,
          _position,
          (_size - _position).clamp(0, downloadChunk),
        );
      }
    } catch (e) {
      _fail(e);
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _done.complete(createdRoots);
  }

  void cancel() => _fail(const FileSystemException('Download cancelled'));

  void _fail(Object error) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    try {
      _out?.closeSync();
    } catch (_) {}
    _out = null;
    // Remove only what this download created, newest first, and only while it
    // is still a regular file / directory (never follow a symlink).
    for (final path in _ownedFiles.reversed) {
      try {
        if (_isType(path, FileSystemEntityType.file)) File(path).deleteSync();
      } catch (_) {}
    }
    for (final path in _ownedDirs.reversed) {
      try {
        if (_isType(path, FileSystemEntityType.directory)) {
          Directory(path).deleteSync(); // non-recursive: fails if not empty
        }
      } catch (_) {}
    }
    _ownedFiles.clear();
    _ownedDirs.clear();
    _created.clear();
    _partial = null;
    _done.completeError(error);
  }
}
