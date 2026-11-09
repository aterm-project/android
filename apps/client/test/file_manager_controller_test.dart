import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/sftp/remote_file_operations.dart';
import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_remote_fs.dart';

class _Client extends Fake implements SSHClient {}

class _Session extends Fake implements SSHSession {}

/// Old transport surface + optional file-operations capability.
class _Transport extends Fake
    implements LocalProfileSftpTransport, RemoteFileSystemOperations {
  _Transport(this.fs);
  final MemoryRemoteFs fs;
  int closed = 0;

  @override
  Future<List<SftpName>> listDirectory(String path) => fs.listDirectory(path);
  @override
  Future<SftpFileAttrs?> lstat(String path) => fs.lstat(path);
  @override
  Stream<List<SftpName>> readDirectory(String path) => fs.readDirectory(path);
  @override
  Future<void> createDirectory(String path) => fs.createDirectory(path);
  @override
  Future<void> renameNoReplace(String from, String to) =>
      fs.renameNoReplace(from, to);
  @override
  Future<void> removeFile(String path) => fs.removeFile(path);
  @override
  Future<void> removeDirectory(String path) => fs.removeDirectory(path);
  @override
  Future<int> copyRegularFileExclusive(
    String from,
    String to, {
    required int maxBytes,
    required RemoteFileCancellation cancellation,
    void Function(int bytes)? onBytes,
  }) => fs.copyRegularFileExclusive(
    from,
    to,
    maxBytes: maxBytes,
    cancellation: cancellation,
    onBytes: onBytes,
  );
  @override
  Future<void> close() async => closed++;
}

class _LegacyTransport extends Fake implements LocalProfileSftpTransport {
  @override
  Future<List<SftpName>> listDirectory(String path) async => [];
  @override
  Future<void> close() async {}
}

SftpName _entry(FileWorkspaceController model, String name) =>
    model.entries.firstWhere((e) => e.filename == name);

LocalUploadSource _local(String name, String text) => LocalUploadSource(
  name: name,
  length: text.length,
  open: () => Stream.value(Uint8List.fromList(text.codeUnits)),
);

void main() {
  late MemoryRemoteFs fs;
  late FileWorkspaceController model;
  late List<String> uploads;
  Completer<void>? uploadGate;

  FileWorkspaceController build({LocalProfileSftpTransport? transport}) =>
      FileWorkspaceController(
        connection: SshConnection(client: _Client(), session: _Session()),
        protocol: SshTransferProtocol.sftp,
        initialPath: '/srv',
        transportFactory: (_) async => transport ?? _Transport(fs),
        uploader:
            ({
              required remotePath,
              required source,
              required size,
              required cancellation,
              required onProgress,
            }) async {
              uploads.add(remotePath);
              await uploadGate?.future;
              cancellation.check();
              if (fs.nodes.containsKey(remotePath)) {
                throw StateError('exclusive create refused');
              }
              final bytes = <int>[];
              await for (final chunk in source) {
                bytes.addAll(chunk);
              }
              fs.addFile(remotePath, String.fromCharCodes(bytes));
            },
      );

  setUp(() async {
    uploads = [];
    uploadGate = null;
    fs = MemoryRemoteFs()
      ..addDirectory('/srv')
      ..addDirectory('/srv/dir')
      ..addFile('/srv/a.txt', 'A');
    model = build();
    await model.refresh();
  });

  tearDown(() => model.close());

  test('copy/paste keeps both names and never replaces', () async {
    model.copyToClipboard(_entry(model, 'a.txt'));
    expect(model.canPasteInto('/srv'), isTrue);
    var asked = 0;
    final result = await model.paste(
      '/srv',
      keepBoth: (_) async {
        asked++;
        return true;
      },
    );
    expect(asked, 1);
    expect(result, '/srv/a (copy).txt');
    expect(fs.text('/srv/a.txt'), 'A');
    expect(fs.text('/srv/a (copy).txt'), 'A');
    expect(model.selected?.filename, 'a (copy).txt');
    expect(model.clipboard, isNotNull, reason: 'copy may be pasted again');
  });

  test('declined conflict leaves source, destination and clipboard', () async {
    fs.addFile('/srv/dir/a.txt', 'OTHER');
    model.cutToClipboard(_entry(model, 'a.txt'));
    expect(await model.paste('/srv/dir', keepBoth: (_) async => false), isNull);
    expect(fs.text('/srv/a.txt'), 'A');
    expect(fs.text('/srv/dir/a.txt'), 'OTHER');
    expect(model.clipboard?.mode, RemoteFileClipboardMode.cut);
  });

  test('cut/paste moves once and clears the clipboard', () async {
    model.cutToClipboard(_entry(model, 'a.txt'));
    expect(model.canPasteInto('/srv'), isFalse, reason: 'same folder no-op');
    await model.paste('/srv/dir', keepBoth: (_) async => true);
    expect(fs.nodes.containsKey('/srv/a.txt'), isFalse);
    expect(fs.text('/srv/dir/a.txt'), 'A');
    expect(model.clipboard, isNull);
  });

  test('folders cannot be pasted into themselves', () async {
    model.copyToClipboard(_entry(model, 'dir'));
    expect(model.canPasteInto('/srv/dir'), isFalse);
    expect(model.canPasteInto('/srv/dir/deeper'), isFalse);
    expect(model.canPasteInto('/srv'), isTrue);
  });

  test('clipboard is per tab and cleared on close', () async {
    final other = build();
    await other.refresh();
    model.copyToClipboard(_entry(model, 'a.txt'));
    expect(other.clipboard, isNull);
    expect(other.canPasteInto('/srv/dir'), isFalse);
    await model.close();
    expect(model.clipboard, isNull);
    expect(model.canPasteInto('/srv/dir'), isFalse);
    expect(await model.paste('/srv/dir', keepBoth: (_) async => true), isNull);
    expect(fs.nodes.containsKey('/srv/dir/a.txt'), isFalse);
    await other.close();
  });

  test(
    'rename collision keeps both entries; rename of clip clears it',
    () async {
      fs.addFile('/srv/b.txt', 'B');
      await model.refresh();
      await expectLater(
        model.renameEntry('/srv', _entry(model, 'a.txt'), 'b.txt'),
        throwsA(isA<RemoteFileOperationException>()),
      );
      expect(fs.text('/srv/a.txt'), 'A');
      expect(fs.text('/srv/b.txt'), 'B');
      model.copyToClipboard(_entry(model, 'a.txt'));
      await model.renameEntry('/srv', _entry(model, 'a.txt'), 'c.txt');
      expect(fs.text('/srv/c.txt'), 'A');
      expect(model.clipboard, isNull);
      expect(model.selected?.filename, 'c.txt');
    },
  );

  test('recursive delete runs only the confirmed plan', () async {
    fs.addFile('/srv/dir/x.txt', 'X');
    final plan = await model.planDelete('/srv', _entry(model, 'dir'));
    expect(plan.entries.length, 2);
    await model.deletePlanned('/srv', _entry(model, 'dir'), plan);
    expect(fs.nodes.containsKey('/srv/dir'), isFalse);
    expect(fs.text('/srv/a.txt'), 'A');
  });

  test('drop upload: skip and keep-both, never an existing path', () async {
    final asked = <String>[];
    final summary = await model.uploadLocalFiles(
      [_local('a.txt', 'NEW'), _local('n.txt', 'N'), _local('a.txt', 'NEW2')],
      '/srv',
      onConflict: (name) async {
        asked.add(name);
        return asked.length == 1
            ? UploadConflictChoice.keepBoth
            : UploadConflictChoice.skip;
      },
    );
    expect(asked, ['a.txt', 'a.txt'], reason: 'batch duplicates also ask');
    expect(uploads, ['/srv/a (copy).txt', '/srv/n.txt']);
    expect(summary.uploaded, 2);
    expect(summary.skipped, 1);
    expect(fs.text('/srv/a.txt'), 'A');
  });

  test('drop upload keeps the captured folder while browsing', () async {
    uploadGate = Completer<void>();
    final pending = model.uploadLocalFiles(
      [_local('n.txt', 'N')],
      '/srv',
      onConflict: (_) async => UploadConflictChoice.cancel,
    );
    await pumpEventQueue();
    expect(model.busy, isTrue);
    await model.navigate('/srv/dir');
    uploadGate!.complete();
    await pending;
    expect(uploads, ['/srv/n.txt']);
    expect(fs.text('/srv/n.txt'), 'N');
    expect(fs.nodes.containsKey('/srv/dir/n.txt'), isFalse);
  });

  test('closing the tab cancels a running upload batch', () async {
    uploadGate = Completer<void>();
    final pending = model.uploadLocalFiles(
      [_local('one.txt', '1'), _local('two.txt', '2')],
      '/srv',
      onConflict: (_) async => UploadConflictChoice.cancel,
    );
    await pumpEventQueue();
    await model.close();
    uploadGate!.complete();
    final summary = await pending;
    expect(summary.uploaded, 0);
    expect(uploads, ['/srv/one.txt']);
    expect(fs.nodes.containsKey('/srv/two.txt'), isFalse);
  });

  test('unsafe dropped names are refused before any request', () async {
    for (final name in ['../x', 'a/b', '..']) {
      await expectLater(
        model.uploadLocalFiles(
          [_local(name, 'x')],
          '/srv',
          onConflict: (_) async => UploadConflictChoice.keepBoth,
        ),
        throwsFormatException,
      );
    }
    expect(uploads, isEmpty);
  });

  test('transports without the capability report it honestly', () async {
    final legacy = build(transport: _LegacyTransport());
    await expectLater(
      legacy.renameEntry('/srv', _entry(model, 'a.txt'), 'z.txt'),
      throwsUnsupportedError,
    );
    await legacy.close();
  });
}
