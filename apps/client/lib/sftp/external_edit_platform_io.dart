import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart' as win32;
import 'package:flutter/services.dart';

import 'external_edit_platform_contract.dart';
import 'external_edit_policy.dart';

const _rootDirectoryName = 'atermius-external-edit';
const _lockFileName = '.session.lock';
const _uuid = Uuid();

/// Session roots owned by this process (POSIX record locks do not exclude
/// the same process, so stale cleanup also consults this set).
final _activeSessionRoots = <String>{};

/// Desktop and Android private editing copies; unsupported on iOS.
ExternalEditPlatform? createDefaultExternalEditPlatform() {
  if (!(Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isAndroid)) {
    return null;
  }
  return IoExternalEditPlatform();
}

typedef ExternalEditLaunchOverride = Future<void> Function(
  String path,
  ExternalEditLaunchMode mode,
);

final class IoExternalEditPlatform implements ExternalEditPlatform {
  /// [root] and [launcher] are test seams; production uses the per-user
  /// application-support folder and the native opener.
  IoExternalEditPlatform({
    Future<Directory> Function()? root,
    this._launcher,
    ExternalEditPlatformKind? kind,
  }) : _root = root ?? _defaultRoot,
       kind = kind ?? _currentKind();

  final Future<Directory> Function() _root;
  final ExternalEditLaunchOverride? _launcher;

  @override
  final ExternalEditPlatformKind kind;

  static ExternalEditPlatformKind _currentKind() {
    if (Platform.isWindows) return ExternalEditPlatformKind.windows;
    if (Platform.isMacOS) return ExternalEditPlatformKind.macos;
    if (Platform.isLinux) return ExternalEditPlatformKind.linux;
    if (Platform.isAndroid) return ExternalEditPlatformKind.android;
    return ExternalEditPlatformKind.unsupported;
  }

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, _rootDirectoryName));
  }

  @override
  Future<ExternalEditLocalWorkspace> openWorkspace() async {
    final root = await _root();
    await root.create(recursive: true);
    await _restrict(root.path, directory: true);
    final canonicalRoot = await root.resolveSymbolicLinks();
    await _removeStaleSessions(Directory(canonicalRoot));
    final session = Directory(p.join(canonicalRoot, _uuid.v4()));
    await session.create();
    _activeSessionRoots.add(session.path);
    RandomAccessFile? lock;
    try {
      await _restrict(session.path, directory: true);
      lock = await File(p.join(session.path, _lockFileName))
          .open(mode: FileMode.write);
      await lock.lock(FileLock.exclusive);
      return _IoWorkspace(session.path, lock);
    } catch (_) {
      await lock?.close();
      await _deleteTree(session.path);
      _activeSessionRoots.remove(session.path);
      rethrow;
    }
  }

  /// Removes copies left by a crashed process: a session whose lock can be
  /// taken is not owned by any running process.
  static Future<void> _removeStaleSessions(Directory root) async {
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory || _activeSessionRoots.contains(entity.path)) {
          continue;
        }
        final lockFile = File(p.join(entity.path, _lockFileName));
        RandomAccessFile? handle;
        try {
          if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
              FileSystemEntityType.file) {
            handle = await lockFile.open(mode: FileMode.append);
            await handle.lock(FileLock.exclusive);
            await handle.unlock();
          }
        } on FileSystemException {
          await handle?.close();
          continue; // Held by another running process.
        }
        await handle?.close();
        await _deleteTree(entity.path);
      }
    } on FileSystemException {
      // Cleanup is best effort; a new session must still start.
    }
  }

  @override
  Future<void> launch(String path, ExternalEditLaunchMode mode) async {
    if (mode == ExternalEditLaunchMode.blocked || !p.isAbsolute(path)) {
      throw const ExternalEditException(ExternalEditError.blockedType);
    }
    final override = _launcher;
    if (override != null) return override(path, mode);
    try {
      switch (kind) {
        case ExternalEditPlatformKind.android:
          await const MethodChannel('atermius/external_edit')
              .invokeMethod<void>('open', {
                'path': path,
                'text': mode == ExternalEditLaunchMode.edit,
              });
        case ExternalEditPlatformKind.windows:
          _shellExecute(path, mode == ExternalEditLaunchMode.edit);
        case ExternalEditPlatformKind.macos:
          // argv only; `-t` is the default text editor and never runs files.
          await Process.start('/usr/bin/open', [
            if (mode == ExternalEditLaunchMode.edit) '-t',
            path,
          ], mode: ProcessStartMode.detached);
        case ExternalEditPlatformKind.linux:
          if (mode != ExternalEditLaunchMode.open) {
            throw const ExternalEditException(ExternalEditError.blockedType);
          }
          await Process.start('xdg-open', [
            path,
          ], mode: ProcessStartMode.detached);
        case ExternalEditPlatformKind.unsupported:
          throw const ExternalEditException(ExternalEditError.unsupported);
      }
    } on ExternalEditException {
      rethrow;
    } catch (_) {
      throw const ExternalEditException(ExternalEditError.launchFailed);
    }
  }

  /// ShellExecuteW on the absolute owned path: no `cmd /c start`, no command
  /// line is built, so the remote file name is never interpreted.
  static void _shellExecute(String path, bool edit) {
    final verb = (edit ? 'edit' : 'open').toNativeUtf16();
    final file = path.toNativeUtf16();
    final directory = p.dirname(path).toNativeUtf16();
    try {
      final result = win32.ShellExecute(
        0,
        verb,
        file,
        nullptr,
        directory,
        win32.SW_SHOWNORMAL,
      );
      if (result <= 32) {
        throw const ExternalEditException(ExternalEditError.launchFailed);
      }
    } finally {
      calloc
        ..free(verb)
        ..free(file)
        ..free(directory);
    }
  }
}

final class _IoWorkspace implements ExternalEditLocalWorkspace {
  _IoWorkspace(this.path, this._lock);

  final String path;
  final RandomAccessFile _lock;
  bool _closed = false;

  @override
  Future<ExternalEditLocalCopy> createCopy(
    String localName,
    Uint8List bytes,
  ) async {
    if (_closed) {
      throw const ExternalEditException(ExternalEditError.sessionChanged);
    }
    if (localName != p.basename(localName) ||
        localName == '.' ||
        localName == '..' ||
        localName == _lockFileName) {
      throw const ExternalEditException(ExternalEditError.localRejected);
    }
    final directory = Directory(p.join(path, _uuid.v4()));
    await directory.create();
    try {
      await _restrict(directory.path, directory: true);
      final canonical = await directory.resolveSymbolicLinks();
      if (canonical != directory.path) {
        throw const ExternalEditException(ExternalEditError.localRejected);
      }
      final file = File(p.join(directory.path, localName));
      await file.create(exclusive: true);
      await _restrict(file.path, directory: false);
      final handle = await file.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      return _IoCopy(directory.path, file.path);
    } catch (_) {
      await _deleteTree(directory.path);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _lock.unlock();
    } catch (_) {}
    try {
      await _lock.close();
    } catch (_) {}
    await _deleteTree(path);
    _activeSessionRoots.remove(path);
  }
}

final class _IoCopy implements ExternalEditLocalCopy {
  _IoCopy(this.directory, this.path);

  final String directory;

  @override
  final String path;

  @override
  Stream<void> watch() => Directory(directory).watch().map<void>((_) {});

  /// Opens the copy only while it is a regular file directly inside its
  /// still-real owned directory, bounded before any byte is read.
  Future<RandomAccessFile?> _openChecked(int maxBytes) async {
    if (await FileSystemEntity.type(directory, followLinks: false) !=
            FileSystemEntityType.directory ||
        await Directory(directory).resolveSymbolicLinks() != directory) {
      throw const ExternalEditException(ExternalEditError.localRejected);
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const ExternalEditException(ExternalEditError.localRejected);
    }
    final RandomAccessFile handle;
    try {
      handle = await File(path).open();
    } on FileSystemException {
      // Replaced or removed between the type check and open.
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return null;
      }
      rethrow;
    }
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const ExternalEditException(ExternalEditError.localRejected);
      }
      if (await handle.length() > maxBytes) {
        throw const ExternalEditException(ExternalEditError.localTooLarge);
      }
      return handle;
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  @override
  Future<Digest?> hash(int maxBytes) async {
    final handle = await _openChecked(maxBytes);
    if (handle == null) return null;
    final buffer = Uint8List(64 * 1024);
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    try {
      var total = 0;
      while (true) {
        final count = await handle.readInto(buffer);
        if (count <= 0) break;
        total += count;
        if (total > maxBytes) {
          throw const ExternalEditException(ExternalEditError.localTooLarge);
        }
        input.add(Uint8List.sublistView(buffer, 0, count));
      }
      input.close();
      return sink.value;
    } finally {
      buffer.fillRange(0, buffer.length, 0);
      await handle.close();
    }
  }

  @override
  Future<Uint8List?> read(int maxBytes) async {
    final handle = await _openChecked(maxBytes);
    if (handle == null) return null;
    try {
      final bytes = await handle.read(maxBytes + 1);
      if (bytes.length > maxBytes) {
        bytes.fillRange(0, bytes.length, 0);
        throw const ExternalEditException(ExternalEditError.localTooLarge);
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> delete() => _deleteTree(directory);
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Deletes an owned tree without following links (Dart removes a link
/// entry itself, never its target).
Future<void> _deleteTree(String path) async {
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  } on FileSystemException {
    // Best effort: an editor may briefly hold a file open on Windows.
  }
}

Future<void> _restrict(String path, {required bool directory}) async {
  if (Platform.isLinux || Platform.isMacOS) {
    final result = await Process.run('chmod', [
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not restrict permissions.', path);
    }
  } else if (Platform.isWindows) {
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) {
      throw const FileSystemException('Could not identify the Windows user.');
    }
    final result = await Process.run('icacls', [
      path,
      '/inheritance:r',
      '/grant:r',
      '$user:${directory ? '(OI)(CI)F' : 'F'}',
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not restrict permissions.', path);
    }
  }
}
