import 'dart:typed_data';

import 'package:aterm_client/sftp/remote_file_operations.dart';
import 'package:dartssh2/dartssh2.dart';

enum MemKind { file, directory, link }

class MemNode {
  MemNode.file(List<int> bytes, {this.mode = 0x1a4})
    : kind = MemKind.file,
      bytes = Uint8List.fromList(bytes),
      target = null;
  MemNode.directory({this.mode = 0x1ed})
    : kind = MemKind.directory,
      bytes = null,
      target = null;
  MemNode.link(this.target) : kind = MemKind.link, bytes = null, mode = 0x1ff;

  final MemKind kind;
  Uint8List? bytes;
  final String? target;
  int mode;
}

/// In-memory POSIX-like tree with SFTP v3 semantics: rename never replaces,
/// mkdir/exclusive create fail on existing names and rmdir refuses non-empty
/// folders. Like a real server, every request follows symbolic links in
/// INTERMEDIATE path components (only `lstat`'s final component is not
/// followed), so a folder swapped for a link redirects later requests unless
/// the caller re-checks. Hooks inject races and failures.
class MemoryRemoteFs implements RemoteFileSystemOperations {
  MemoryRemoteFs({this.batchSize = 64}) {
    nodes['/'] = MemNode.directory();
  }

  final nodes = <String, MemNode>{};
  final calls = <String>[];

  /// Entries per readDirectory batch.
  final int batchSize;
  int openDirectoryHandles = 0;
  int directoryBatchesYielded = 0;

  /// Runs before a rename request reaches the "server".
  void Function(String from, String to)? beforeRename;

  /// Throws to simulate a mid-copy failure for a given destination.
  bool Function(String to)? failCopy;

  void Function(String path)? beforeRemoveDirectory;
  void Function(String path)? afterCreateDirectory;
  void Function(String path)? afterRemoveFile;

  /// Runs when a directory listing finished (or was cancelled).
  void Function(String path)? afterReadDirectory;

  void addFile(String path, String text, {int mode = 0x1a4}) =>
      nodes[path] = MemNode.file(text.codeUnits, mode: mode);
  void addDirectory(String path) => nodes[path] = MemNode.directory();
  void addLink(String path, String target) =>
      nodes[path] = MemNode.link(target);
  void replaceWithLink(String path, String target) {
    nodes.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    addLink(path, target);
  }

  String? text(String path) {
    final bytes = nodes[path]?.bytes;
    return bytes == null ? null : String.fromCharCodes(bytes);
  }

  static String _parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  /// Resolves links in every component except the last.
  String _resolve(String path) {
    if (path == '/') return path;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    var current = '';
    for (var index = 0; index < parts.length; index++) {
      current = '$current/${parts[index]}';
      final node = nodes[current];
      if (index < parts.length - 1 && node?.kind == MemKind.link) {
        current = _resolveFull(node!.target!);
      }
    }
    return current.isEmpty ? '/' : current;
  }

  /// Resolves links in every component, including the last.
  String _resolveFull(String path) {
    var resolved = _resolve(path);
    for (var hops = 0; hops < 8; hops++) {
      final node = nodes[resolved];
      if (node?.kind != MemKind.link) return resolved;
      resolved = _resolve(node!.target!);
    }
    throw SftpStatusError(SftpStatusCode.failure, 'too many links');
  }

  void _requireParent(String resolved) {
    if (nodes[_parent(resolved)]?.kind != MemKind.directory) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'no parent');
    }
  }

  SftpFileAttrs _attrs(MemNode node) => SftpFileAttrs(
    size: node.bytes?.length ?? 0,
    mode: SftpFileMode.value(
      switch (node.kind) {
            MemKind.file => 0x8000,
            MemKind.directory => 0x4000,
            MemKind.link => 0xa000,
          } |
          node.mode,
    ),
  );

  @override
  Future<SftpFileAttrs?> lstat(String path) async {
    final node = nodes[_resolve(path)];
    return node == null ? null : _attrs(node);
  }

  List<SftpName> _children(String resolved) => [
    for (final entry in nodes.entries)
      if (entry.key != '/' &&
          entry.key != resolved &&
          _parent(entry.key) == resolved)
        SftpName(
          filename: entry.key.substring(entry.key.lastIndexOf('/') + 1),
          longname: '',
          attr: _attrs(entry.value),
        ),
  ];

  /// Whole-listing helper for the legacy transport surface.
  Future<List<SftpName>> listDirectory(String path) async {
    calls.add('list $path');
    final resolved = _resolveFull(path);
    if (nodes[resolved]?.kind != MemKind.directory) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'not a directory');
    }
    return _children(resolved);
  }

  @override
  Stream<List<SftpName>> readDirectory(String path) async* {
    calls.add('readdir $path');
    final resolved = _resolveFull(path);
    if (nodes[resolved]?.kind != MemKind.directory) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'not a directory');
    }
    openDirectoryHandles++;
    try {
      final children = _children(resolved);
      for (var start = 0; start < children.length; start += batchSize) {
        directoryBatchesYielded++;
        yield children.sublist(
          start,
          start + batchSize > children.length
              ? children.length
              : start + batchSize,
        );
      }
    } finally {
      openDirectoryHandles--;
      afterReadDirectory?.call(path);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    calls.add('mkdir $path');
    final resolved = _resolve(path);
    _requireParent(resolved);
    if (nodes.containsKey(resolved)) {
      throw SftpStatusError(SftpStatusCode.failure, 'exists');
    }
    nodes[resolved] = MemNode.directory();
    afterCreateDirectory?.call(path);
  }

  @override
  Future<void> renameNoReplace(String from, String to) async {
    beforeRename?.call(from, to);
    calls.add('rename $from $to');
    final source = _resolve(from);
    final target = _resolve(to);
    if (!nodes.containsKey(source)) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'missing');
    }
    if (nodes.containsKey(target)) {
      throw SftpStatusError(SftpStatusCode.failure, 'exists');
    }
    _requireParent(target);
    final moved = {
      for (final key in nodes.keys)
        if (key == source || key.startsWith('$source/')) key: nodes[key]!,
    };
    for (final entry in moved.entries) {
      nodes.remove(entry.key);
      nodes[target + entry.key.substring(source.length)] = entry.value;
    }
  }

  @override
  Future<void> removeFile(String path) async {
    calls.add('remove $path');
    final resolved = _resolve(path);
    final node = nodes[resolved];
    if (node == null || node.kind == MemKind.directory) {
      throw SftpStatusError(SftpStatusCode.failure, 'not a file');
    }
    nodes.remove(resolved);
    afterRemoveFile?.call(path);
  }

  @override
  Future<void> removeDirectory(String path) async {
    beforeRemoveDirectory?.call(path);
    calls.add('rmdir $path');
    final resolved = _resolve(path);
    if (nodes[resolved]?.kind != MemKind.directory) {
      throw SftpStatusError(SftpStatusCode.failure, 'not a directory');
    }
    if (nodes.keys.any((key) => key.startsWith('$resolved/'))) {
      throw SftpStatusError(SftpStatusCode.failure, 'not empty');
    }
    nodes.remove(resolved);
  }

  @override
  Future<int> copyRegularFileExclusive(
    String from,
    String to, {
    required int maxBytes,
    required RemoteFileCancellation cancellation,
    void Function(int bytes)? onBytes,
  }) async {
    calls.add('copy $from $to');
    final source = nodes[_resolve(from)];
    final target = _resolve(to);
    if (source?.kind != MemKind.file) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
      );
    }
    _requireParent(target);
    if (nodes.containsKey(target)) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.destinationExists,
      );
    }
    nodes[target] = MemNode.file(const [], mode: 0x180);
    try {
      cancellation.check();
      if (failCopy?.call(to) == true) throw StateError('write failed');
      final bytes = source!.bytes!;
      // Like the real transport: refuse before writing past [maxBytes].
      if (bytes.length > maxBytes) {
        throw const RemoteFileOperationException(
          RemoteFileOperationError.fileTooLarge,
        );
      }
      nodes[target]!.bytes = Uint8List.fromList(bytes);
      nodes[target]!.mode = source.mode;
      onBytes?.call(bytes.length);
      return bytes.length;
    } catch (_) {
      nodes.remove(target);
      rethrow;
    }
  }
}
