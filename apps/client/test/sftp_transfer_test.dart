import 'dart:typed_data';

import 'package:aterm_client/domain/sftp_transfer.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUploadHandle implements SftpUploadHandle {
  _FakeUploadHandle({required this.onWrite, required this.onClose});

  final Future<void> Function(Uint8List bytes) onWrite;
  final Future<void> Function() onClose;
  var closeCalls = 0;

  @override
  Future<void> writeBytes(Uint8List bytes) => onWrite(bytes);

  @override
  Future<void> close() {
    closeCalls++;
    return onClose();
  }
}

void main() {
  test('requires SFTP v3 exclusive create and never requests truncate', () {
    expect(supportsSftpExclusiveCreate(2), isFalse);
    expect(supportsSftpExclusiveCreate(3), isTrue);
    expect(supportsSftpExclusiveCreate(4), isTrue);
    expect(
      sftpExclusiveCreateMode.flag & SftpFileOpenMode.write.flag,
      isNot(0),
    );
    expect(
      sftpExclusiveCreateMode.flag & SftpFileOpenMode.create.flag,
      isNot(0),
    );
    expect(
      sftpExclusiveCreateMode.flag & SftpFileOpenMode.exclusive.flag,
      isNot(0),
    );
    expect(sftpExclusiveCreateMode.flag & SftpFileOpenMode.truncate.flag, 0);
  });

  test('writes and closes a new exclusive target without cleanup', () async {
    final written = <int>[];
    var cleanupCalls = 0;
    final handle = _FakeUploadHandle(
      onWrite: (bytes) async => written.addAll(bytes),
      onClose: () async {},
    );

    await writeSftpFileWithoutOverwrite(
      remotePath: '/selected/new.txt',
      bytes: Uint8List.fromList([1, 2, 3]),
      createExclusive: () async => handle,
      removePartial: () async => cleanupCalls++,
    );

    expect(written, [1, 2, 3]);
    expect(handle.closeCalls, 1);
    expect(cleanupCalls, 0);
  });

  test(
    'an exclusive-create collision leaves existing bytes untouched',
    () async {
      final files = <String, List<int>>{
        '/selected/existing.txt': [9, 8, 7],
      };
      var cleanupCalls = 0;

      await expectLater(
        writeSftpFileWithoutOverwrite(
          remotePath: '/selected/existing.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
          createExclusive: () async {
            if (files.containsKey('/selected/existing.txt')) {
              throw StateError('exclusive create rejected existing target');
            }
            files['/selected/existing.txt'] = [];
            return _FakeUploadHandle(
              onWrite: (bytes) async =>
                  files['/selected/existing.txt']!.addAll(bytes),
              onClose: () async {},
            );
          },
          removePartial: () async {
            cleanupCalls++;
            files.remove('/selected/existing.txt');
          },
        ),
        throwsStateError,
      );

      expect(files['/selected/existing.txt'], [9, 8, 7]);
      expect(cleanupCalls, 0);
    },
  );

  test(
    'removes only a newly created partial file after write failure',
    () async {
      final files = <String, List<int>>{};
      var closed = false;

      await expectLater(
        writeSftpFileWithoutOverwrite(
          remotePath: '/selected/new.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
          createExclusive: () async {
            files['/selected/new.txt'] = [];
            return _FakeUploadHandle(
              onWrite: (bytes) async {
                files['/selected/new.txt']!.add(bytes.first);
                throw StateError('connection lost during write');
              },
              onClose: () async => closed = true,
            );
          },
          removePartial: () async => files.remove('/selected/new.txt'),
        ),
        throwsStateError,
      );

      expect(closed, isTrue);
      expect(files, isEmpty);
    },
  );

  test('reports when cleanup of a newly created partial file fails', () async {
    final handle = _FakeUploadHandle(
      onWrite: (_) async => throw StateError('write failed'),
      onClose: () async {},
    );

    await expectLater(
      writeSftpFileWithoutOverwrite(
        remotePath: '/selected/new.txt',
        bytes: Uint8List.fromList([1]),
        createExclusive: () async => handle,
        removePartial: () async => throw StateError('remove denied'),
      ),
      throwsA(
        isA<SftpPartialUploadCleanupException>()
            .having((error) => error.remotePath, 'path', '/selected/new.txt')
            .having(
              (error) => error.cleanupError.toString(),
              'cleanup error',
              contains('remove denied'),
            ),
      ),
    );
  });
}
