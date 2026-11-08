import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// An advisory process lock. Keep its file permanently: deleting it can let a
/// second process lock a new inode while the first still owns the old one.
class ProcessFileLock {
  ProcessFileLock(this.directory);

  final Directory directory;
  static final Map<String, _LeaseGroup> _groups = {};

  Future<T> run<T>(
    String namespace,
    Future<T> Function() action, {
    bool shared = false,
    Future<void>? cancel,
  }) async {
    final name = sha256.convert(utf8.encode(namespace)).toString();
    final path = '${directory.path}${Platform.pathSeparator}$name.lock';
    // Callers serialize writers locally. Sharing one descriptor for a reader
    // batch also avoids POSIX process-wide unlock-on-close surprises.
    var existing = _groups[path];
    while (existing != null && existing.retiring) {
      final retirement = existing.retired.future;
      if (cancel == null) {
        await retirement;
      } else {
        final finished = await Future.any<bool>([
          retirement.then((_) => true),
          cancel.then((_) => false),
        ]);
        if (!finished) throw const ProcessLockCancelled();
      }
      existing = _groups[path];
    }
    final group = shared && existing != null && existing.shared
        ? existing
        : _LeaseGroup(shared);
    if (existing != null && !identical(existing, group)) {
      throw StateError('Process lock requires a local reader/writer queue.');
    }
    _groups[path] = group;
    group.users++;
    group.acquiring ??= _acquire(path, shared, group.cancel.future);
    try {
      if (cancel == null) {
        await group.acquiring;
      } else {
        final acquired = await Future.any<bool>([
          group.acquiring!.then((_) => true),
          cancel.then((_) => false),
        ]);
        if (!acquired) throw const ProcessLockCancelled();
      }
      return await action();
    } finally {
      group.users--;
      if (group.users == 0) {
        group.retiring = true;
        group.cancel.complete();
        try {
          await group.acquiring;
        } catch (_) {
          /* acquisition failed */
        }
        try {
          final handle = group.handle;
          if (handle != null) await handle.close();
        } finally {
          if (identical(_groups[path], group)) _groups.remove(path);
          group.retired.complete();
        }
      }
    }
  }

  Future<void> _acquire(String path, bool shared, Future<void>? cancel) async {
    var cancelled = false;
    Object? cancellationError;
    cancel?.then(
      (_) {
        cancelled = true;
      },
      onError: (Object error) {
        cancellationError = error;
        cancelled = true;
      },
    );
    await directory.create(recursive: true);
    final handle = await File(path).open(mode: FileMode.append);
    try {
      while (true) {
        if (cancelled) throw cancellationError ?? const ProcessLockCancelled();
        try {
          await handle.lock(shared ? FileLock.shared : FileLock.exclusive);
          if (cancelled) {
            throw cancellationError ?? const ProcessLockCancelled();
          }
          _groups[path]!.handle = handle;
          return;
        } on FileSystemException catch (error) {
          // EAGAIN/EACCES (Unix), ERROR_LOCK_VIOLATION (Windows).
          if (![11, 13, 33, 35].contains(error.osError?.errorCode)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }
}

class _LeaseGroup {
  _LeaseGroup(this.shared);
  final bool shared;
  int users = 0;
  bool retiring = false;
  final retired = Completer<void>();
  final cancel = Completer<void>();
  Future<void>? acquiring;
  RandomAccessFile? handle;
}

class ProcessLockCancelled implements Exception {
  const ProcessLockCancelled();
}
