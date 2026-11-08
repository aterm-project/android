import 'dart:math';
import 'dart:typed_data';

import 'package:aterm_client/sftp/sftp_text_editor_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySftp implements SftpTextFileSystem {
  _MemorySftp({Map<String, List<int>>? initialFiles}) {
    for (final entry
        in initialFiles?.entries ?? const <MapEntry<String, List<int>>>[]) {
      files[entry.key] = Uint8List.fromList(entry.value);
    }
  }

  final Map<String, Uint8List> files = {};
  final Map<String, bool> regularFiles = {};
  final Map<String, int?> modes = {};
  final List<SftpTextRemoteSnapshot> snapshots = [];
  final List<String> reads = [];
  final List<int> readLimits = [];
  final List<String> writeAttempts = [];
  final List<String> removals = [];
  final List<(String, String)> replacements = [];
  final List<String> permissionUpdates = [];
  bool atomicReplaceSupported = true;
  bool collideNextTempWrite = false;
  bool failNextWriteAfterPartial = false;
  bool failReplace = false;
  bool failPermissionUpdate = false;
  Future<void> Function(String path)? afterSuccessfulWrite;

  @override
  Future<SftpTextRemoteSnapshot> readFile(
    String path, {
    required int maxBytes,
  }) async {
    reads.add(path);
    readLimits.add(maxBytes);
    final bytes = files[path];
    if (bytes == null) throw StateError('No such remote file: $path');
    final snapshot = SftpTextRemoteSnapshot(
      bytes: Uint8List.fromList(bytes),
      isRegularFile: regularFiles[path] ?? true,
      permissionBits: modes[path] ?? 0x81a4, // Regular file, mode 0644.
    );
    snapshots.add(snapshot);
    return snapshot;
  }

  @override
  Future<bool> supportsAtomicReplace() async => atomicReplaceSupported;

  @override
  Future<void> writeExclusive(
    String path,
    Uint8List bytes, {
    int? permissionBits,
  }) async {
    writeAttempts.add(path);
    expect(permissionBits, 0x180);
    if (files.containsKey(path)) {
      throw SftpTextFileAlreadyExistsException(path);
    }
    if (collideNextTempWrite && path.contains('.atermius-')) {
      collideNextTempWrite = false;
      throw SftpTextFileAlreadyExistsException(path);
    }

    files[path] = Uint8List.fromList(bytes);
    modes[path] = permissionBits;
    if (failNextWriteAfterPartial) {
      failNextWriteAfterPartial = false;
      // Model the required adapter behavior: remove our partial file before
      // returning the write/close failure.
      files[path] = Uint8List.fromList(bytes.take(1).toList());
      files.remove(path);
      modes.remove(path);
      throw StateError('connection lost during exclusive write');
    }
    await afterSuccessfulWrite?.call(path);
  }

  @override
  Future<void> replaceAtomically(String tempPath, String targetPath) async {
    replacements.add((tempPath, targetPath));
    if (failReplace) throw StateError('atomic rename failed');
    final staged = files.remove(tempPath);
    if (staged == null) throw StateError('missing staged file');
    files[targetPath] = staged;
    modes[targetPath] = modes.remove(tempPath);
  }

  @override
  Future<void> setPermissionBits(String path, int permissionBits) async {
    permissionUpdates.add('$path:$permissionBits');
    if (failPermissionUpdate) throw StateError('permission update failed');
    modes[path] = permissionBits;
  }

  @override
  Future<void> removeFile(String path) async {
    removals.add(path);
    files.remove(path);
    modes.remove(path);
  }
}

class _BoundTrackingRandom implements Random {
  final Random _delegate = Random(13);
  final List<int> bounds = [];

  @override
  bool nextBool() => _delegate.nextBool();

  @override
  double nextDouble() => _delegate.nextDouble();

  @override
  int nextInt(int max) {
    bounds.add(max);
    return _delegate.nextInt(max);
  }
}

SftpTextEditorService _service(_MemorySftp filesystem) =>
    SftpTextEditorService(filesystem: filesystem, random: Random(11));

void main() {
  test(
    'open uses a bounded strict UTF-8 read and enforces the 10 MiB cap',
    () async {
      final atLimit = _MemorySftp(
        initialFiles: {
          '/remote/large.txt': List<int>.filled(sftpTextFileMaxBytes, 0x61),
        },
      );
      final doc = await _service(atLimit).open('/remote/large.txt');
      expect(doc.text.length, sftpTextFileMaxBytes);
      expect(atLimit.readLimits, [sftpTextFileMaxBytes + 1]);
      expect(atLimit.snapshots.single.bytes, everyElement(0));
      doc.dispose();

      final oversized = _MemorySftp(
        initialFiles: {
          '/remote/large.txt': List<int>.filled(sftpTextFileMaxBytes + 1, 0x61),
        },
      );
      await expectLater(
        _service(oversized).open('/remote/large.txt'),
        throwsA(isA<FormatException>()),
      );
      expect(oversized.readLimits, [sftpTextFileMaxBytes + 1]);
      expect(oversized.snapshots.single.bytes, everyElement(0));

      final invalidUtf8 = _MemorySftp(
        initialFiles: {
          '/remote/bad.txt': [0xc3, 0x28],
        },
      );
      await expectLater(
        _service(invalidUtf8).open('/remote/bad.txt'),
        throwsA(isA<FormatException>()),
      );
      expect(invalidUtf8.snapshots.single.bytes, everyElement(0));
    },
  );

  test('open rejects unsafe paths and non-regular entries', () async {
    final filesystem = _MemorySftp(
      initialFiles: {
        '/remote/link.txt': [0x6f, 0x6b],
        '/remote/safe.txt': [0x6f, 0x6b],
      },
    );
    filesystem.regularFiles['/remote/link.txt'] = false;
    final service = _service(filesystem);

    await expectLater(
      service.open('/remote/../secret.txt'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      service.open('/remote/link.txt'),
      throwsA(isA<FormatException>()),
    );
    expect(await service.open('/remote/safe.txt'), isA<SftpTextDocument>());
  });

  test('save replaces only when the exact baseline still matches', () async {
    final filesystem = _MemorySftp(
      initialFiles: {'/remote/config.txt': 'before'.codeUnits},
    );
    filesystem.modes['/remote/config.txt'] =
        0x89ed; // Type/special bits + 0775.
    final service = _service(filesystem);
    final document = await service.open('/remote/config.txt');
    final copy = document.originalBytes;
    copy[0] = 0;

    final result = await service.save(document, 'after');
    expect(result, isA<SftpTextSaveSuccess>());
    final saved = (result as SftpTextSaveSuccess).document;
    expect(saved.text, 'after');
    expect(saved.originalBytes, 'after'.codeUnits);
    expect(saved.permissionBits, 0x1ed); // Special/type bits stripped.
    expect(filesystem.files['/remote/config.txt'], 'after'.codeUnits);
    expect(filesystem.replacements, hasLength(1));
    expect(
      filesystem.replacements.single.$1,
      startsWith('/remote/.config.txt.'),
    );
    expect(filesystem.replacements.single.$2, '/remote/config.txt');
    expect(filesystem.modes['/remote/config.txt'], 0x1ed);
    expect(filesystem.permissionUpdates, ['/remote/config.txt:493']);
    document.dispose();
    saved.dispose();
    expect(() => document.originalBytes, throwsStateError);
  });

  test(
    'permission restoration failure still reports the published save',
    () async {
      final filesystem = _MemorySftp(
        initialFiles: {'/remote/config.txt': 'before'.codeUnits},
      )..failPermissionUpdate = true;
      final service = _service(filesystem);
      final document = await service.open('/remote/config.txt');

      final result = await service.save(document, 'after');

      expect(result, isA<SftpTextSaveSuccess>());
      final saved = result as SftpTextSaveSuccess;
      expect(saved.document.text, 'after');
      expect(saved.permissionRestoreFailed, isTrue);
      expect(saved.document.permissionBits, 0x180);
      expect(filesystem.files['/remote/config.txt'], 'after'.codeUnits);
      expect(filesystem.modes['/remote/config.txt'], 0x180);
      expect(
        filesystem.files.keys.where((path) => path.contains('.atermius-')),
        isEmpty,
      );
      document.dispose();
      saved.document.dispose();
    },
  );

  test('a changed remote version is returned before staging', () async {
    final filesystem = _MemorySftp(
      initialFiles: {'/remote/file.txt': 'first'.codeUnits},
    );
    final service = _service(filesystem);
    final document = await service.open('/remote/file.txt');
    filesystem.files['/remote/file.txt'] = Uint8List.fromList(
      'second'.codeUnits,
    );

    final result = await service.save(document, 'local edit');
    expect(result, isA<SftpTextRemoteChanged>());
    final conflict = (result as SftpTextRemoteChanged).latestDocument;
    expect(conflict.text, 'second');
    expect(filesystem.writeAttempts, isEmpty);
    expect(filesystem.files['/remote/file.txt'], 'second'.codeUnits);
    document.dispose();
    conflict.dispose();
  });

  test(
    'approved overwrite is rechecked and catches a second staging conflict',
    () async {
      final filesystem = _MemorySftp(
        initialFiles: {'/remote/file.txt': 'first'.codeUnits},
      );
      final service = _service(filesystem);
      final stale = await service.open('/remote/file.txt');
      filesystem.files['/remote/file.txt'] = Uint8List.fromList(
        'approved'.codeUnits,
      );
      final firstConflict = await service.save(stale, 'edited');
      expect(firstConflict, isA<SftpTextRemoteChanged>());
      final approved = (firstConflict as SftpTextRemoteChanged).latestDocument;
      var raced = false;
      filesystem.afterSuccessfulWrite = (path) async {
        if (path.contains('.atermius-') && !raced) {
          raced = true;
          filesystem.files['/remote/file.txt'] = Uint8List.fromList(
            'changed again'.codeUnits,
          );
        }
      };

      final result = await service.save(
        stale,
        'overwrite after approval',
        expectedRemoteBytes: approved.originalBytes,
      );
      expect(result, isA<SftpTextRemoteChanged>());
      final latest = (result as SftpTextRemoteChanged).latestDocument;
      expect(latest.text, 'changed again');
      expect(filesystem.files['/remote/file.txt'], 'changed again'.codeUnits);
      expect(filesystem.replacements, isEmpty);
      expect(filesystem.removals, hasLength(1));
      expect(
        filesystem.files.keys.where((path) => path.contains('.atermius-')),
        isEmpty,
      );
      stale.dispose();
      approved.dispose();
      latest.dispose();
    },
  );

  test(
    'temp-name collision retries without touching the colliding path',
    () async {
      final filesystem = _MemorySftp(
        initialFiles: {'/remote/file.txt': 'old'.codeUnits},
      );
      filesystem.collideNextTempWrite = true;
      final service = _service(filesystem);
      final document = await service.open('/remote/file.txt');
      final result = await service.save(document, 'new');

      expect(result, isA<SftpTextSaveSuccess>());
      expect(filesystem.writeAttempts, hasLength(2));
      expect(filesystem.writeAttempts[0], isNot(filesystem.writeAttempts[1]));
      expect(filesystem.files['/remote/file.txt'], 'new'.codeUnits);
      expect(filesystem.removals, isEmpty);
    },
  );

  test('staging-name random bound is a nonzero 32-bit range', () async {
    final filesystem = _MemorySftp(
      initialFiles: {'/remote/file.txt': 'old'.codeUnits},
    );
    final random = _BoundTrackingRandom();
    final document = await SftpTextEditorService(
      filesystem: filesystem,
      random: random,
    ).open('/remote/file.txt');
    final result = await SftpTextEditorService(
      filesystem: filesystem,
      random: random,
    ).save(document, 'new');

    expect(result, isA<SftpTextSaveSuccess>());
    expect(random.bounds, List<int>.filled(4, 0x100000000));
    document.dispose();
    (result as SftpTextSaveSuccess).document.dispose();
  });

  test('save-as uses exclusive create and defaults to mode 0600', () async {
    final filesystem = _MemorySftp();
    final saved = await _service(filesystem).saveAs('/remote/new.txt', 'new');
    expect(saved.document.permissionBits, 0x180);
    expect(filesystem.modes['/remote/new.txt'], 0x180);
    expect(filesystem.files['/remote/new.txt'], 'new'.codeUnits);

    filesystem.files['/remote/existing.txt'] = Uint8List.fromList(
      'keep'.codeUnits,
    );
    await expectLater(
      _service(filesystem).saveAs('/remote/existing.txt', 'replace'),
      throwsA(isA<SftpTextFileAlreadyExistsException>()),
    );
    expect(filesystem.files['/remote/existing.txt'], 'keep'.codeUnits);
    expect(filesystem.replacements, isEmpty);
    saved.document.dispose();
  });

  test(
    'write failure relies on adapter partial cleanup; rename failure cleans staging',
    () async {
      final writeFailureFs = _MemorySftp(
        initialFiles: {'/remote/file.txt': 'old'.codeUnits},
      )..failNextWriteAfterPartial = true;
      final writeFailureService = _service(writeFailureFs);
      final writeFailureDoc = await writeFailureService.open(
        '/remote/file.txt',
      );
      await expectLater(
        writeFailureService.save(writeFailureDoc, 'new'),
        throwsA(isA<StateError>()),
      );
      expect(
        writeFailureFs.files.keys.where((path) => path.contains('.atermius-')),
        isEmpty,
      );
      expect(writeFailureFs.files['/remote/file.txt'], 'old'.codeUnits);

      final renameFailureFs = _MemorySftp(
        initialFiles: {'/remote/file.txt': 'old'.codeUnits},
      )..failReplace = true;
      final renameFailureService = _service(renameFailureFs);
      final renameFailureDoc = await renameFailureService.open(
        '/remote/file.txt',
      );
      await expectLater(
        renameFailureService.save(renameFailureDoc, 'new'),
        throwsA(isA<StateError>()),
      );
      expect(
        renameFailureFs.files.keys.where((path) => path.contains('.atermius-')),
        isEmpty,
      );
      expect(renameFailureFs.removals, hasLength(1));
      expect(renameFailureFs.files['/remote/file.txt'], 'old'.codeUnits);
      writeFailureDoc.dispose();
      renameFailureDoc.dispose();
    },
  );

  test('refuses replacement when atomic replace is unsupported', () async {
    final filesystem = _MemorySftp(
      initialFiles: {'/remote/file.txt': 'old'.codeUnits},
    )..atomicReplaceSupported = false;
    final service = _service(filesystem);
    final document = await service.open('/remote/file.txt');

    await expectLater(
      service.save(document, 'new'),
      throwsA(isA<UnsupportedError>()),
    );
    expect(filesystem.writeAttempts, isEmpty);
    expect(filesystem.replacements, isEmpty);
    expect(filesystem.files['/remote/file.txt'], 'old'.codeUnits);
    document.dispose();
  });
}
