import 'dart:typed_data';

import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/sftp/sftp_text_editor_service.dart';

void main() {
  group('LocalProfileSftpController', () {
    test(
      'filters unsafe names and resolves paths with safe basenames',
      () async {
        final transport = _FakeTransport()
          ..entries = [
            _entry('safe.txt'),
            _entry('..'),
            _entry('nested/name'),
            _entry(r'windows\path'),
            _entry('line\nbreak'),
            _entry('c1\u0085name'),
          ];
        final controller = _controller(transport);

        final entries = await controller.listDirectory('/srv/data');
        expect(entries.map((entry) => entry.filename), ['safe.txt']);
        await controller.createDirectory('/srv/data/', 'reports');
        await controller.uploadFile(
          parent: '/srv/data',
          name: 'safe.txt',
          bytes: Uint8List.fromList([1, 2]),
        );
        final bytes = await controller.downloadFile(
          parent: '/srv/data',
          name: 'safe.txt',
        );
        expect(bytes, [9, 8, 7]);
        await controller.deleteEntry(
          parent: '/srv/data',
          item: _entry('safe.txt'),
        );

        expect(transport.createdDirectories, ['/srv/data/reports']);
        expect(transport.uploads, ['/srv/data/safe.txt']);
        expect(transport.downloads.single.path, '/srv/data/safe.txt');
        expect(
          transport.downloads.single.maxBytes,
          localProfileSftpMaxDownloadBytes,
        );
        expect(transport.removedFiles, ['/srv/data/safe.txt']);
        bytes.fillRange(0, bytes.length, 0);
        await controller.close();
      },
    );

    test(
      'rejects unsafe remote basenames before opening the transport',
      () async {
        final transport = _FakeTransport();
        final controller = _controller(transport);

        await expectLater(
          controller.downloadFile(parent: '/', name: '../secret'),
          throwsFormatException,
        );
        await expectLater(
          controller.createDirectory('/', r'bad\name'),
          throwsFormatException,
        );
        await expectLater(
          controller.createDirectory('/', 'line\nbreak'),
          throwsFormatException,
        );
        await expectLater(
          controller.uploadFile(
            parent: '/',
            name: 'bad/name',
            bytes: Uint8List(0),
          ),
          throwsFormatException,
        );
        await expectLater(
          controller.uploadFile(
            parent: '/',
            name: 'tab\tname',
            bytes: Uint8List(0),
          ),
          throwsFormatException,
        );
        await expectLater(
          controller.deleteEntry(parent: '/', item: _entry('../secret')),
          throwsFormatException,
        );
        await expectLater(
          controller.listDirectory('/bad\u0000path'),
          throwsFormatException,
        );
        await expectLater(
          controller.downloadFile(parent: '/bad\npath', name: 'file.txt'),
          throwsFormatException,
        );

        expect(transport.opened, 0);
        await controller.close();
      },
    );

    test('closing the SFTP controller blocks later operations', () async {
      final transport = _FakeTransport();
      final controller = _controller(transport);
      await controller.listDirectory('/');
      await controller.close();

      expect(controller.isClosed, isTrue);
      expect(transport.closed, 1);
      await expectLater(controller.listDirectory('/'), throwsStateError);
    });

    test(
      'streams downloads and commits only after the channel completes',
      () async {
        final transport = _FakeTransport();
        final controller = _controller(transport);
        final destination = _FakeStreamingWriter();

        final byteCount = await controller.downloadFileTo(
          parent: '/srv/data',
          name: 'archive.bin',
          destination: destination,
        );

        expect(byteCount, 3);
        expect(destination.committed, 1);
        expect(destination.aborted, 0);
        expect(destination.bytes, [1, 2, 3]);
        expect(transport.streamDownloads.single.path, '/srv/data/archive.bin');
        expect(
          transport.streamDownloads.single.maxBytes,
          attachmentStreamingSaveLimitBytes,
        );
        destination.clear();
        await controller.close();
      },
    );

    test('aborts a streamed destination when the SFTP read fails', () async {
      final transport = _FakeTransport()..streamError = true;
      final controller = _controller(transport);
      final destination = _FakeStreamingWriter();

      await expectLater(
        controller.downloadFileTo(
          parent: '/srv/data',
          name: 'archive.bin',
          destination: destination,
        ),
        throwsStateError,
      );

      expect(destination.committed, 0);
      expect(destination.aborted, 1);
      destination.clear();
      await controller.close();
    });

    test('retries a failed SFTP channel open on the next operation', () async {
      final transport = _FakeTransport();
      var attempts = 0;
      final controller = LocalProfileSftpController(
        connection: SshConnection(
          client: _FakeSshClient(),
          session: _FakeSshSession(),
        ),
        transportFactory: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('temporary SFTP channel failure');
          return transport;
        },
      );

      await expectLater(controller.listDirectory('/'), throwsStateError);
      expect(await controller.listDirectory('/'), isEmpty);
      expect(attempts, 2);
      await controller.close();
    });

    test(
      'directories are removed with rmdir rather than file unlink',
      () async {
        final transport = _FakeTransport();
        final controller = _controller(transport);
        await controller.deleteEntry(
          parent: '/tmp',
          item: _entry('empty', directory: true),
        );

        expect(transport.removedDirectories, ['/tmp/empty']);
        expect(transport.removedFiles, isEmpty);
        await controller.close();
      },
    );
  });
}

LocalProfileSftpController _controller(_FakeTransport transport) =>
    LocalProfileSftpController(
      connection: SshConnection(
        client: _FakeSshClient(),
        session: _FakeSshSession(),
      ),
      transportFactory: (_) async {
        transport.opened++;
        return transport;
      },
    );

SftpName _entry(String filename, {bool directory = false}) => SftpName(
  filename: filename,
  longname: filename,
  attr: SftpFileAttrs(
    mode: SftpFileMode.value((directory ? 0x4000 : 0x8000) | 0x1a4),
  ),
);

class _FakeTransport implements LocalProfileSftpTransport {
  int opened = 0;
  int closed = 0;
  List<SftpName> entries = [];
  final createdDirectories = <String>[];
  final uploads = <String>[];
  final downloads = <({String path, int maxBytes})>[];
  final streamDownloads = <({String path, int maxBytes})>[];
  final removedFiles = <String>[];
  final removedDirectories = <String>[];
  bool streamError = false;

  @override
  Future<List<SftpName>> listDirectory(String path) async => entries;

  @override
  Future<void> createDirectory(String path) async {
    createdDirectories.add(path);
  }

  @override
  Future<void> uploadExclusive(String path, Uint8List bytes) async {
    uploads.add(path);
  }

  @override
  Future<Uint8List> downloadRegularFile(
    String path, {
    required int maxBytes,
  }) async {
    downloads.add((path: path, maxBytes: maxBytes));
    return Uint8List.fromList([9, 8, 7]);
  }

  @override
  Future<int> downloadRegularFileTo(
    String path, {
    required int maxBytes,
    required Future<void> Function(Uint8List chunk) onChunk,
  }) async {
    streamDownloads.add((path: path, maxBytes: maxBytes));
    final chunk = Uint8List.fromList([1, 2, 3]);
    await onChunk(chunk);
    chunk.fillRange(0, chunk.length, 0);
    if (streamError) throw StateError('SFTP connection lost mid-download');
    return 3;
  }

  @override
  Future<void> removeFile(String path) async {
    removedFiles.add(path);
  }

  @override
  Future<void> removeDirectory(String path) async {
    removedDirectories.add(path);
  }

  @override
  Future<SftpTextEditorService> textEditor({required String sessionId}) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closed++;
  }
}

class _FakeSshClient extends Fake implements SSHClient {}

class _FakeSshSession extends Fake implements SSHSession {}

class _FakeStreamingWriter implements AttachmentStreamingSaveWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  int committed = 0;
  int aborted = 0;

  Uint8List get bytes => _bytes.toBytes();

  @override
  Future<void> write(Uint8List plaintextChunk) async {
    _bytes.add(plaintextChunk);
  }

  @override
  Future<void> commit() async {
    committed++;
  }

  @override
  Future<void> abort() async {
    aborted++;
  }

  void clear() {
    final bytes = _bytes.takeBytes();
    bytes.fillRange(0, bytes.length, 0);
  }
}
