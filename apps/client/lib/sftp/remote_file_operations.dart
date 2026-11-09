import 'dart:async';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';

import '../domain/sftp_entries.dart';

/// Remote file-manager primitives implemented by an SFTP channel.
///
/// This is an optional capability kept separate from the older transport
/// interface so existing transports and test fakes keep compiling.
/// Implementations must use SFTP protocol requests only (never a remote
/// shell), must not follow symbolic links for [lstat], and must keep
/// [renameNoReplace] and [copyRegularFileExclusive] strictly non-replacing.
abstract interface class RemoteFileSystemOperations {
  /// Returns `lstat` attributes, or `null` when [path] does not exist.
  Future<SftpFileAttrs?> lstat(String path);

  /// Streams a directory listing in server-sized batches.
  ///
  /// Cancelling the subscription must stop requesting further batches and
  /// close the remote directory handle, so a bounded caller never drains a
  /// huge directory.
  Stream<List<SftpName>> readDirectory(String path);

  /// Creates a directory; fails if anything already exists at [path].
  Future<void> createDirectory(String path);

  /// Renames using the standard SFTP rename, which refuses an existing
  /// destination. Never uses the replacing `posix-rename` extension.
  Future<void> renameNoReplace(String from, String to);

  Future<void> removeFile(String path);

  Future<void> removeDirectory(String path);

  /// Streams a regular file into a newly exclusive-created [to].
  ///
  /// The destination is created owner-only, the source mode's ordinary
  /// permission bits are applied after all bytes are written, and a partial
  /// destination this call created is removed on failure or cancellation.
  /// The source must be (and remain) a regular file no larger than [maxBytes].
  Future<int> copyRegularFileExclusive(
    String from,
    String to, {
    required int maxBytes,
    required RemoteFileCancellation cancellation,
    void Function(int bytes)? onBytes,
  });
}

/// Hard limits for recursive folder work so an operation can't expand an
/// unbounded remote tree or stream an unbounded number of bytes.
class RemoteFileOperationLimits {
  const RemoteFileOperationLimits({
    this.maxEntries = 2000,
    this.maxDepth = 32,
    this.maxFileBytes = 1024 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  });

  final int maxEntries;
  final int maxDepth;
  final int maxFileBytes;
  final int maxTotalBytes;
}

enum RemoteFileOperationError {
  /// The destination already exists; nothing was replaced.
  destinationExists,

  /// The source is missing or changed type since it was listed.
  sourceChanged,

  /// A folder can't be moved or copied into itself.
  intoItself,

  /// A symbolic link or special file blocks a recursive copy.
  unsupportedEntry,

  /// The tree exceeds [RemoteFileOperationLimits].
  limitExceeded,

  /// A file exceeds the per-file byte limit.
  fileTooLarge,

  /// The name isn't a safe single path component.
  invalidName,

  cancelled,
}

class RemoteFileOperationException implements Exception {
  const RemoteFileOperationException(this.error, {this.name});

  final RemoteFileOperationError error;

  /// The untrusted remote basename involved, for display only.
  final String? name;

  @override
  String toString() => 'RemoteFileOperationException(${error.name})';
}

/// Cooperative cancellation for copy/delete work.
class RemoteFileCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;

  void check() {
    if (_cancelled) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.cancelled,
      );
    }
  }
}

enum RemoteTreeEntryKind { file, directory, link, other }

class RemoteTreeEntry {
  const RemoteTreeEntry(this.relativePath, this.kind, this.size);

  /// Path relative to the planned root ('' for the root itself), built only
  /// from validated basenames.
  final String relativePath;
  final RemoteTreeEntryKind kind;
  final int size;
}

/// A bounded, pre-order snapshot of a remote tree taken with `lstat`
/// semantics (links are recorded, never followed).
class RemoteTreePlan {
  RemoteTreePlan(this.rootKind, this.entries);

  final RemoteTreeEntryKind rootKind;
  final List<RemoteTreeEntry> entries;

  int get fileCount =>
      entries.where((e) => e.kind != RemoteTreeEntryKind.directory).length;
  int get directoryCount =>
      entries.where((e) => e.kind == RemoteTreeEntryKind.directory).length;
  int get totalBytes => entries
      .where((e) => e.kind == RemoteTreeEntryKind.file)
      .fold(0, (sum, e) => sum + e.size);
}

class RemoteFileProgress {
  const RemoteFileProgress(this.done, this.total);

  /// Completed units (bytes for copy, entries for delete).
  final int done;
  final int total;
  double? get fraction => total <= 0 ? null : (done / total).clamp(0, 1);
}

RemoteTreeEntryKind remoteTreeEntryKind(SftpFileAttrs attributes) =>
    switch (attributes.mode?.type) {
      SftpFileType.regularFile => RemoteTreeEntryKind.file,
      SftpFileType.directory => RemoteTreeEntryKind.directory,
      SftpFileType.symbolicLink => RemoteTreeEntryKind.link,
      _ => RemoteTreeEntryKind.other,
    };

/// Same-server rename, move, copy and delete built on SFTP requests only.
///
/// Every operation re-validates untrusted names, never replaces an existing
/// destination, and never deletes the source of a failed copy or move.
/// Recursive work records links instead of following them and re-checks the
/// selected root and every in-tree ancestor with `lstat` (uncached)
/// immediately before each request. SFTP v3 has no `*at()`/no-follow
/// operations, so a concurrent remote change between such a check and the
/// following request cannot be excluded; it can only be narrowed.
/// [ensureOpen] is checked between remote requests so a closed file tab stops
/// issuing work.
class RemoteFileOperations {
  RemoteFileOperations(
    this._fs, {
    void Function()? ensureOpen,
    this.limits = const RemoteFileOperationLimits(),
    Random? random,
  }) : _ensureOpen = ensureOpen ?? _noop,
       _random = random ?? Random.secure();

  final RemoteFileSystemOperations _fs;
  final void Function() _ensureOpen;
  final RemoteFileOperationLimits limits;
  final Random _random;

  static void _noop() {}

  /// Renames [oldName] to [newName] within [parent]; returns the new path.
  Future<String> rename(String parent, String oldName, String newName) async {
    final name = newName.trim();
    _requireName(oldName);
    _requireName(name);
    final from = sftpChildPath(parent, oldName);
    final to = sftpChildPath(parent, name);
    if (from == to) return to;
    await _renameNoReplace(from, to, name);
    return to;
  }

  /// Moves [sourcePath] into [destinationDirectory] as [name].
  Future<String> move(
    String sourcePath,
    String destinationDirectory,
    String name,
  ) async {
    _requireName(name);
    final to = sftpChildPath(destinationDirectory, name);
    if (to == sourcePath) return to;
    if (isSameOrDescendantPath(destinationDirectory, sourcePath)) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.intoItself,
        name: name,
      );
    }
    await _renameNoReplace(sourcePath, to, name);
    return to;
  }

  Future<void> _renameNoReplace(String from, String to, String name) async {
    _ensureOpen();
    if (await _fs.lstat(from) == null) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
        name: _basename(from),
      );
    }
    _ensureOpen();
    if (await _fs.lstat(to) != null) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.destinationExists,
        name: name,
      );
    }
    _ensureOpen();
    try {
      // The standard SFTP rename itself refuses an existing destination, so a
      // destination created after the pre-check above is never replaced.
      await _fs.renameNoReplace(from, to);
    } catch (_) {
      if (await _existsQuietly(to)) {
        throw RemoteFileOperationException(
          RemoteFileOperationError.destinationExists,
          name: name,
        );
      }
      rethrow;
    }
    _ensureOpen();
  }

  /// Returns [name] when unused in [directory], otherwise the first free
  /// "name (copy)", "name (copy 2)" … variant (extension preserved).
  ///
  /// Names in [reserved] (already claimed by the same batch) are skipped.
  Future<String> availableName(
    String directory,
    String name, {
    Set<String> reserved = const {},
  }) async {
    _requireName(name);
    if (!reserved.contains(name) &&
        !await _exists(sftpChildPath(directory, name))) {
      return name;
    }
    final dot = name.lastIndexOf('.');
    final hasExtension = dot > 0 && dot < name.length - 1;
    final stem = hasExtension ? name.substring(0, dot) : name;
    final extension = hasExtension ? name.substring(dot) : '';
    for (var index = 1; index <= 99; index++) {
      final suffix = index == 1 ? ' (copy)' : ' (copy $index)';
      final candidate = '$stem$suffix$extension';
      if (!isSafeSftpBasename(candidate) || candidate.length > 255) break;
      if (!reserved.contains(candidate) &&
          !await _exists(sftpChildPath(directory, candidate))) {
        return candidate;
      }
    }
    throw RemoteFileOperationException(
      RemoteFileOperationError.destinationExists,
      name: name,
    );
  }

  Future<bool> exists(String path) => _exists(path);

  /// Plans a recursive copy. Links and special files block the whole copy
  /// (they are reported, not followed or silently skipped).
  Future<RemoteTreePlan> planCopy(String sourcePath) async {
    final plan = await _plan(sourcePath);
    final blocked = plan.entries
        .where(
          (e) =>
              e.kind == RemoteTreeEntryKind.link ||
              e.kind == RemoteTreeEntryKind.other,
        )
        .firstOrNull;
    if (blocked != null) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.unsupportedEntry,
        name: blocked.relativePath.isEmpty
            ? _basename(sourcePath)
            : blocked.relativePath,
      );
    }
    for (final entry in plan.entries) {
      if (entry.kind == RemoteTreeEntryKind.file &&
          entry.size > limits.maxFileBytes) {
        throw RemoteFileOperationException(
          RemoteFileOperationError.fileTooLarge,
          name: entry.relativePath.isEmpty
              ? _basename(sourcePath)
              : entry.relativePath,
        );
      }
    }
    if (plan.totalBytes > limits.maxTotalBytes) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.limitExceeded,
      );
    }
    return plan;
  }

  /// Copies a planned tree to [destinationDirectory]/[name].
  ///
  /// The copy is built under a private, randomly named staging entry in
  /// [destinationDirectory] (folders with mkdir, files with exclusive
  /// create) and only then published with [RemoteFileSystemOperations
  /// .renameNoReplace], so nothing existing is replaced and rollback only
  /// touches staging names this call created. Before each request the source
  /// root, the staging root and every in-tree ancestor are re-checked as
  /// directories. Actually streamed bytes are charged against
  /// [RemoteFileOperationLimits.maxTotalBytes], so files that grew after
  /// planning can't exceed the aggregate bound. The source is never modified.
  Future<String> copy(
    RemoteTreePlan plan,
    String sourcePath,
    String destinationDirectory,
    String name, {
    required RemoteFileCancellation cancellation,
    void Function(RemoteFileProgress progress)? onProgress,
  }) async {
    _requireName(name);
    final rootDirectory = plan.rootKind == RemoteTreeEntryKind.directory;
    if (rootDirectory &&
        isSameOrDescendantPath(destinationDirectory, sourcePath)) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.intoItself,
        name: name,
      );
    }
    final target = sftpChildPath(destinationDirectory, name);
    final staging = sftpChildPath(destinationDirectory, _stagingName());
    final created = <(String, bool)>[];
    final total = plan.totalBytes;
    var done = 0;
    onProgress?.call(RemoteFileProgress(0, total));
    try {
      for (final entry in plan.entries) {
        cancellation.check();
        _ensureOpen();
        final from = _join(sourcePath, entry.relativePath);
        final to = _join(staging, entry.relativePath);
        if (rootDirectory) {
          await _requireTreeDirectories(sourcePath, entry.relativePath);
          if (entry.relativePath.isNotEmpty) {
            await _requireTreeDirectories(staging, entry.relativePath);
          }
        }
        if (entry.kind == RemoteTreeEntryKind.directory) {
          // The planned source folder itself must still be a folder.
          await _requireDirectory(from, entry.relativePath);
          await _fs.createDirectory(to);
          created.add((to, true));
          continue;
        }
        final remaining = limits.maxTotalBytes - done;
        final cap = min(limits.maxFileBytes, max(0, remaining));
        final int copied;
        try {
          copied = await _fs.copyRegularFileExclusive(
            from,
            to,
            maxBytes: cap,
            cancellation: cancellation,
            onBytes: (bytes) {
              done += bytes;
              if (done > limits.maxTotalBytes) {
                throw const RemoteFileOperationException(
                  RemoteFileOperationError.limitExceeded,
                );
              }
              onProgress?.call(RemoteFileProgress(done, total));
            },
          );
        } on RemoteFileOperationException catch (error) {
          if (error.error == RemoteFileOperationError.fileTooLarge &&
              cap < limits.maxFileBytes) {
            // The aggregate budget, not the per-file limit, was reached.
            throw const RemoteFileOperationException(
              RemoteFileOperationError.limitExceeded,
            );
          }
          rethrow;
        }
        // The exclusive-created file exists from here, even if a later check
        // fails, so record it for rollback before validating the result.
        created.add((to, false));
        if (copied < 0 || copied > cap) {
          throw const RemoteFileOperationException(
            RemoteFileOperationError.limitExceeded,
          );
        }
      }
      cancellation.check();
      _ensureOpen();
      try {
        await _fs.renameNoReplace(staging, target);
      } catch (_) {
        if (await _existsQuietly(target)) {
          throw RemoteFileOperationException(
            RemoteFileOperationError.destinationExists,
            name: name,
          );
        }
        rethrow;
      }
      return target;
    } catch (error, stackTrace) {
      await _rollback(created);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  String _stagingName() {
    final hex = List<String>.generate(
      4,
      (_) => _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '.atermius-copy-$hex.tmp';
  }

  /// Requires [base] and each in-tree ancestor of [relative] (not [relative]
  /// itself) to be directories right now. Deliberately uncached.
  Future<void> _requireTreeDirectories(String base, String relative) async {
    await _requireDirectory(base, '');
    if (relative.isEmpty) return;
    final parts = relative.split('/');
    var path = base;
    for (var index = 0; index < parts.length - 1; index++) {
      path = sftpChildPath(path, parts[index]);
      await _requireDirectory(path, parts.sublist(0, index + 1).join('/'));
    }
  }

  Future<void> _requireDirectory(String path, String displayName) async {
    _ensureOpen();
    final attributes = await _fs.lstat(path);
    _ensureOpen();
    if (attributes == null ||
        remoteTreeEntryKind(attributes) != RemoteTreeEntryKind.directory) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
        name: displayName.isEmpty ? _basename(path) : displayName,
      );
    }
  }

  Future<void> _rollback(List<(String, bool)> created) async {
    for (final (path, directory) in created.reversed) {
      try {
        if (directory) {
          // rmdir refuses non-empty folders, so foreign files are never lost.
          await _fs.removeDirectory(path);
        } else {
          await _fs.removeFile(path);
        }
      } catch (_) {
        // Best effort: the caller reports the original failure.
      }
    }
  }

  /// Plans a recursive delete. Links are recorded as links.
  Future<RemoteTreePlan> planDelete(String path) => _plan(path);

  /// Deletes a planned tree deepest-first.
  ///
  /// Before any request, the selected root must still have its planned kind.
  /// Before each removal the root and every in-tree ancestor are re-checked
  /// with `lstat` (uncached), and the entry itself must still have its
  /// planned folder/non-folder kind. Links are removed with remove(), which
  /// acts on the link. Folders are removed with rmdir, so anything added
  /// after planning stops the delete instead of being removed unseen.
  Future<void> delete(
    RemoteTreePlan plan,
    String path, {
    required RemoteFileCancellation cancellation,
    void Function(RemoteFileProgress progress)? onProgress,
  }) async {
    final total = plan.entries.length;
    var done = 0;
    onProgress?.call(RemoteFileProgress(0, total));
    final rootDirectory = plan.rootKind == RemoteTreeEntryKind.directory;
    _ensureOpen();
    final root = await _fs.lstat(path);
    if (root == null || remoteTreeEntryKind(root) != plan.rootKind) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
        name: _basename(path),
      );
    }
    for (final entry in plan.entries.reversed) {
      cancellation.check();
      _ensureOpen();
      final target = _join(path, entry.relativePath);
      if (rootDirectory && entry.relativePath.isNotEmpty) {
        await _requireTreeDirectories(path, entry.relativePath);
      }
      final current = await _fs.lstat(target);
      if (current == null) {
        done++;
        continue;
      }
      final kind = remoteTreeEntryKind(current);
      final plannedDirectory = entry.kind == RemoteTreeEntryKind.directory;
      if ((kind == RemoteTreeEntryKind.directory) != plannedDirectory) {
        throw RemoteFileOperationException(
          RemoteFileOperationError.sourceChanged,
          name: _basename(target),
        );
      }
      if (plannedDirectory) {
        await _fs.removeDirectory(target);
      } else {
        await _fs.removeFile(target);
      }
      done++;
      onProgress?.call(RemoteFileProgress(done, total));
    }
    _ensureOpen();
  }

  Future<RemoteTreePlan> _plan(String rootPath) async {
    _ensureOpen();
    final root = await _fs.lstat(rootPath);
    if (root == null) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
        name: _basename(rootPath),
      );
    }
    final rootKind = remoteTreeEntryKind(root);
    final entries = <RemoteTreeEntry>[
      RemoteTreeEntry('', rootKind, root.size ?? 0),
    ];
    if (rootKind != RemoteTreeEntryKind.directory) {
      return RemoteTreePlan(rootKind, entries);
    }
    // Parents always precede their descendants; only one remote directory
    // handle is open at a time (subfolders are walked after their parent's
    // listing finished).
    Future<void> walk(String relative, int depth) async {
      if (depth > limits.maxDepth) {
        throw const RemoteFileOperationException(
          RemoteFileOperationError.limitExceeded,
        );
      }
      final directory = _join(rootPath, relative);
      // Re-check right before listing: a folder replaced by a link after its
      // parent was listed is not followed.
      await _requireDirectory(directory, relative);
      final subdirectories = <String>[];
      // Throwing inside the loop cancels the subscription, which stops the
      // listing and closes the remote handle without draining it.
      await for (final batch in _fs.readDirectory(directory)) {
        _ensureOpen();
        for (final child in batch) {
          if (child.filename == '.' || child.filename == '..') continue;
          if (!isSafeSftpBasename(child.filename)) {
            // An unrepresentable name can't be copied or deleted safely.
            throw RemoteFileOperationException(
              RemoteFileOperationError.unsupportedEntry,
              name: relative.isEmpty ? _basename(rootPath) : relative,
            );
          }
          if (entries.length >= limits.maxEntries) {
            throw const RemoteFileOperationException(
              RemoteFileOperationError.limitExceeded,
            );
          }
          final childRelative = relative.isEmpty
              ? child.filename
              : '$relative/${child.filename}';
          final kind = remoteTreeEntryKind(child.attr);
          entries.add(
            RemoteTreeEntry(childRelative, kind, child.attr.size ?? 0),
          );
          if (kind == RemoteTreeEntryKind.directory) {
            subdirectories.add(childRelative);
          }
        }
      }
      _ensureOpen();
      for (final subdirectory in subdirectories) {
        await walk(subdirectory, depth + 1);
      }
    }

    await walk('', 1);
    return RemoteTreePlan(rootKind, entries);
  }

  Future<bool> _exists(String path) async {
    _ensureOpen();
    final attributes = await _fs.lstat(path);
    _ensureOpen();
    return attributes != null;
  }

  Future<bool> _existsQuietly(String path) async {
    try {
      return await _fs.lstat(path) != null;
    } catch (_) {
      return false;
    }
  }

  static void _requireName(String name) {
    if (!isSafeSftpBasename(name) || name.length > 255) {
      throw RemoteFileOperationException(
        RemoteFileOperationError.invalidName,
        name: name,
      );
    }
  }

  static String _join(String base, String relative) {
    if (relative.isEmpty) return base;
    var path = base;
    for (final part in relative.split('/')) {
      path = sftpChildPath(path, part);
    }
    return path;
  }

  static String _basename(String path) =>
      path.substring(path.lastIndexOf('/') + 1);
}

/// Whether [path] equals [ancestor] or lies below it (normalized POSIX).
bool isSameOrDescendantPath(String path, String ancestor) {
  String trim(String value) {
    final trimmed = value.replaceFirst(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }

  final a = trim(ancestor);
  final p = trim(path);
  if (p == a) return true;
  return a == '/' ? true : p.startsWith('$a/');
}
