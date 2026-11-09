import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/sftp/external_edit_platform.dart';
import 'package:aterm_client/sftp/external_edit_policy.dart';
import 'package:aterm_client/sftp/sftp_text_editor_service.dart';
import 'package:crypto/crypto.dart';

/// In-memory byte-exact SFTP filesystem with posix-rename semantics.
class MemorySftpBytesFs implements SftpTextFileSystem {
  final files = <String, Uint8List>{};
  final modes = <String, int>{};
  final calls = <String>[];
  bool atomic = true;

  /// Runs before each readFile; may mutate [files] to inject races.
  void Function(String path)? beforeRead;

  /// Runs after a staging file was written.
  Future<void> Function(String tempPath)? afterStage;

  /// Runs right before the atomic replace.
  Future<void> Function()? beforeReplace;

  int get writes => calls
      .where((c) => c.startsWith('write') || c.startsWith('replace'))
      .length;

  @override
  Future<SftpTextRemoteSnapshot> readFile(
    String path, {
    required int maxBytes,
  }) async {
    calls.add('read $path');
    beforeRead?.call(path);
    final bytes = files[path];
    if (bytes == null) throw StateError('missing $path');
    final length = bytes.length < maxBytes ? bytes.length : maxBytes;
    return SftpTextRemoteSnapshot(
      bytes: Uint8List.fromList(bytes.sublist(0, length)),
      isRegularFile: true,
      permissionBits: modes[path],
    );
  }

  @override
  Future<bool> supportsAtomicReplace() async => atomic;

  @override
  Future<void> writeExclusive(
    String path,
    Uint8List bytes, {
    int? permissionBits,
  }) async {
    calls.add('write $path');
    if (files.containsKey(path)) {
      throw SftpTextFileAlreadyExistsException(path);
    }
    files[path] = Uint8List.fromList(bytes);
    modes[path] = permissionBits ?? 0x180;
    await afterStage?.call(path);
  }

  @override
  Future<void> replaceAtomically(String tempPath, String targetPath) async {
    await beforeReplace?.call();
    calls.add('replace $tempPath -> $targetPath');
    files[targetPath] = files.remove(tempPath)!;
    modes[targetPath] = modes.remove(tempPath)!;
  }

  @override
  Future<void> setPermissionBits(String path, int permissionBits) async {
    calls.add('chmod $path');
    modes[path] = permissionBits;
  }

  @override
  Future<void> removeFile(String path) async {
    calls.add('remove $path');
    files.remove(path);
    modes.remove(path);
  }
}

/// Local platform kept entirely in memory (for widget tests).
class MemoryExternalEditPlatform implements ExternalEditPlatform {
  MemoryExternalEditPlatform({this.kind = ExternalEditPlatformKind.linux});

  @override
  final ExternalEditPlatformKind kind;
  final launches = <(String, ExternalEditLaunchMode)>[];
  final copies = <MemoryLocalCopy>[];
  int openWorkspaces = 0;
  int closedWorkspaces = 0;

  @override
  Future<ExternalEditLocalWorkspace> openWorkspace() async {
    openWorkspaces++;
    return _MemoryWorkspace(this);
  }

  @override
  Future<void> launch(String path, ExternalEditLaunchMode mode) async {
    launches.add((path, mode));
  }
}

class _MemoryWorkspace implements ExternalEditLocalWorkspace {
  _MemoryWorkspace(this.platform);
  final MemoryExternalEditPlatform platform;

  @override
  Future<ExternalEditLocalCopy> createCopy(
    String localName,
    Uint8List bytes,
  ) async {
    final copy = MemoryLocalCopy(
      '/private/${platform.copies.length}/$localName',
      bytes,
    );
    platform.copies.add(copy);
    return copy;
  }

  @override
  Future<void> close() async => platform.closedWorkspaces++;
}

class MemoryLocalCopy implements ExternalEditLocalCopy {
  MemoryLocalCopy(this.path, Uint8List bytes)
    : bytes = Uint8List.fromList(bytes);

  @override
  final String path;
  Uint8List? bytes;
  bool deleted = false;
  final _events = StreamController<void>.broadcast();

  /// Simulates an editor save: new bytes plus a directory event.
  void save(List<int> next) {
    bytes = Uint8List.fromList(next);
    _events.add(null);
  }

  @override
  Stream<void> watch() => _events.stream;

  @override
  Future<Digest?> hash(int maxBytes) async {
    final current = bytes;
    return current == null ? null : sha256.convert(current);
  }

  @override
  Future<Uint8List?> read(int maxBytes) async {
    final current = bytes;
    return current == null ? null : Uint8List.fromList(current);
  }

  @override
  Future<void> delete() async {
    deleted = true;
    bytes = null;
  }
}
