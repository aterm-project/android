import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/ssh/scp_mobile_save_writer.dart';
import 'package:aterm_client/ssh/scp_transfer_service.dart';
import 'package:aterm_client/ssh/scp_protocol.dart';
import 'package:aterm_client/ssh/scp_mobile_file_picker.dart';

void main() {
  test(
    'native mobile picker null result reports cancellation and clears verified bytes',
    () async {
      FilePicker? original;
      try {
        original = FilePicker.platform;
      } on Object {
        /* Standalone test has no registered plugin. */
      }
      final picker = _MobilePicker(null);
      FilePicker.platform = picker;
      try {
        final writer = MobileSshTransferSaveWriter(
          save: (bytes) =>
              saveMobileSshTransferFile(fileName: 'example.bin', bytes: bytes),
        );
        await writer.write(Uint8List.fromList([7, 8]));
        await expectLater(
          writer.commit(),
          throwsA(isA<SshTransferCancelled>()),
        );
        expect(picker.bytes, [0, 0]);
        expect(writer.bufferedBytes, 0);
      } finally {
        if (original != null) FilePicker.platform = original;
      }
    },
  );
  test(
    'native mobile picker destination path reports a successful verified export',
    () async {
      FilePicker? original;
      try {
        original = FilePicker.platform;
      } on Object {
        /* Standalone test has no registered plugin. */
      }
      final picker = _MobilePicker('/selected/example.bin');
      FilePicker.platform = picker;
      try {
        expect(
          await saveMobileSshTransferFile(
            fileName: 'example.bin',
            bytes: Uint8List.fromList([9]),
          ),
          true,
        );
        expect(picker.bytes, [9]);
      } finally {
        if (original != null) FilePicker.platform = original;
      }
    },
  );
  test('mobile writer saves only on commit and clears owned buffers', () async {
    Uint8List? savedReference;
    List<int>? savedCopy;
    final writer = MobileSshTransferSaveWriter(
      save: (bytes) async {
        savedReference = bytes;
        savedCopy = List.of(bytes);
        return true;
      },
    );
    final source = Uint8List.fromList([1, 2, 3]);
    await writer.write(source);
    source[0] = 9;
    expect(savedReference, isNull);
    expect(writer.bufferedBytes, 3);
    await writer.commit();
    expect(savedCopy, [1, 2, 3]);
    expect(savedReference, [0, 0, 0]);
    expect(writer.bufferedBytes, 0);
    await expectLater(writer.write(Uint8List(1)), throwsStateError);
  });
  test('mobile overflow aborts and does not invoke native picker', () async {
    var saves = 0;
    final writer = MobileSshTransferSaveWriter(
      maximumBytes: 4,
      save: (_) async {
        saves++;
        return true;
      },
    );
    final input = Uint8List.fromList([1, 2, 3]);
    await writer.write(input);
    await expectLater(writer.write(Uint8List(2)), throwsFormatException);
    expect(writer.bufferedBytes, 0);
    expect(input, [1, 2, 3]);
    expect(saves, 0);
    await expectLater(writer.commit(), throwsStateError);
  });
  test(
    'cancel before commit wipes buffers and creates no local file',
    () async {
      var saves = 0;
      final writer = MobileSshTransferSaveWriter(
        save: (_) async {
          saves++;
          return true;
        },
      );
      await writer.write(Uint8List(65536));
      await writer.abort();
      await writer.abort();
      expect(writer.bufferedBytes, 0);
      expect(saves, 0);
      await expectLater(writer.commit(), throwsStateError);
    },
  );
  test('picker cancellation clears verified payload', () async {
    Uint8List? handedOff;
    final writer = MobileSshTransferSaveWriter(
      save: (bytes) async {
        handedOff = bytes;
        return false;
      },
    );
    await writer.write(Uint8List.fromList([4, 5]));
    await expectLater(writer.commit(), throwsA(isA<SshTransferCancelled>()));
    expect(handedOff, [0, 0]);
    expect(writer.bufferedBytes, 0);
  });
  test('picker failure clears payload as well', () async {
    Uint8List? handedOff;
    final writer = MobileSshTransferSaveWriter(
      save: (bytes) async {
        handedOff = bytes;
        throw StateError('picker failed');
      },
    );
    await writer.write(Uint8List.fromList([4]));
    await expectLater(writer.commit(), throwsStateError);
    expect(handedOff, [0]);
    expect(writer.bufferedBytes, 0);
  });
  test(
    'SFTP declared mobile oversize rejects before file open or buffer write',
    () async {
      final sftp = _OversizeSftp();
      final writer = MobileSshTransferSaveWriter(
        save: (_) async => fail('picker must not open'),
      );
      await expectLater(
        SshFileTransferService(
          _Client(sftp),
          maximumBytes: mobileSshTransferMaximumBytes,
        ).download(
          protocol: SshTransferProtocol.sftp,
          remotePath: '/too-large',
          destination: writer,
          cancellation: SshTransferCancellation(),
        ),
        throwsFormatException,
      );
      expect(sftp.openCount, 0);
      expect(sftp.closed, true);
      expect(writer.bufferedBytes, 0);
    },
  );
  test('SCP declared mobile oversize rejects before body allocation', () async {
    final channel = _HeaderChannel(
      'C0600 ${mobileSshTransferMaximumBytes + 1} huge.bin\n',
    );
    await expectLater(
      ScpProtocol(
        channel,
        SshTransferCancellation(),
        maximumBytes: mobileSshTransferMaximumBytes,
      ).download(onChunk: (_) async => fail('body must not be written')),
      throwsA(isA<ScpProtocolException>()),
    );
    expect(channel.closed, true);
  });
  test(
    'service cancellation aborts a mobile destination before any picker call',
    () async {
      final cancel = SshTransferCancellation();
      final sftp = _SmallSftp();
      var saves = 0;
      final writer = MobileSshTransferSaveWriter(
        save: (_) async {
          saves++;
          return true;
        },
      );
      await expectLater(
        SshFileTransferService(_Client(sftp)).download(
          protocol: SshTransferProtocol.sftp,
          remotePath: '/small',
          destination: writer,
          cancellation: cancel,
          onProgress: (p) {
            if (p.transferred > 0) cancel.cancel();
          },
        ),
        throwsA(isA<SshTransferCancelled>()),
      );
      expect(writer.bufferedBytes, 0);
      expect(saves, 0);
      expect(sftp.closed, true);
    },
  );
}

class _Client extends Fake implements SSHClient {
  _Client(this.client);
  final SftpClient client;
  @override
  Future<SftpClient> sftp() async => client;
}

class _OversizeSftp extends Fake implements SftpClient {
  var openCount = 0;
  var closed = false;
  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(
        mode: const SftpFileMode.value(0x81a4),
        size: mobileSshTransferMaximumBytes + 1,
      );
  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    openCount++;
    throw StateError('not allowed');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _HeaderChannel implements ScpChannel {
  _HeaderChannel(this.header);
  final String header;
  bool closed = false;
  @override
  Stream<Uint8List> get stdout =>
      Stream.value(Uint8List.fromList(utf8.encode(header)));
  @override
  int? get exitCode => 0;
  @override
  Future<void> get done async {}
  @override
  Future<void> send(Uint8List bytes) async {}
  @override
  Future<void> finishInput() async {}
  @override
  void close() {
    closed = true;
  }
}

class _SmallSftp extends Fake implements SftpClient {
  bool closed = false;
  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(mode: const SftpFileMode.value(0x81a4), size: 4);
  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => _SmallFile();
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _SmallFile extends Fake implements SftpFile {
  @override
  Future<SftpFileAttrs> stat() async =>
      SftpFileAttrs(mode: const SftpFileMode.value(0x81a4), size: 4);
  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int)? onProgress,
    int chunkSize = 32768,
    int maxPendingRequests = 1,
  }) async* {
    yield Uint8List.fromList([1, 2]);
    yield Uint8List.fromList([3, 4]);
  }
}

class _MobilePicker extends FilePicker {
  _MobilePicker(this.path);
  final String? path;
  Uint8List? bytes;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    this.bytes = bytes;
    return path;
  }
}
