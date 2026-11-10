import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/sftp/external_edit_manager.dart';
import 'package:aterm_client/sftp/external_edit_platform.dart';
import 'package:aterm_client/sftp/external_edit_platform_io.dart';
import 'package:aterm_client/sftp/external_edit_policy.dart';
import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/external_edit_fakes.dart';

class _Client extends Fake implements SSHClient {}

class _Session extends Fake implements SSHSession {}

class _Transport extends Fake implements LocalProfileSftpTransport {
  @override
  Future<void> close() async {}
}

/// Exact bytes with a UTF-8 BOM, CRLF + lone LF line endings and NUL/0xff.
final _original = Uint8List.fromList([
  0xef, 0xbb, 0xbf, ...'line1\r\nline2\n'.codeUnits, 0x00, 0xff, 0x0d, //
]);

Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Mimics vim/VS Code "atomic save": write a sibling temp, rename it over.
Future<void> _atomicSave(String path, List<int> bytes) async {
  final temp = File(p.join(p.dirname(path), '.${p.basename(path)}.swp~'));
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(path);
}

void main() {
  late Directory root;
  late MemorySftpBytesFs remote;
  late List<(String, ExternalEditLaunchMode)> launches;
  late bool open;

  ExternalEditManager manager({
    ExternalEditPlatformKind kind = ExternalEditPlatformKind.linux,
  }) => ExternalEditManager(
    sessionId: 's1',
    remote: () async => remote,
    platform: IoExternalEditPlatform(
      root: () async => root,
      launcher: (path, mode) async => launches.add((path, mode)),
      kind: kind,
    ),
    isOpen: () => open,
    currentSessionId: () => 's1',
    debounce: const Duration(milliseconds: 60),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('external-edit-test-');
    remote = MemorySftpBytesFs()
      ..files['/srv/notes.txt'] = Uint8List.fromList(_original)
      ..modes['/srv/notes.txt'] = 0x1a4;
    launches = [];
    open = true;
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('policy', () {
    test('local names are inert on every desktop', () {
      expect(externalEditLocalName('a.exe.  '), 'a.exe');
      expect(externalEditLocalName('con.txt'), '_con.txt');
      expect(externalEditLocalName('LPT1'), '_LPT1');
      expect(externalEditLocalName('a:b?.txt'), 'a_b_.txt');
      expect(externalEditLocalName('x\u202Etxt.exe'), 'x_txt.exe');
      expect(externalEditLocalName('...'), 'file');
      final long = externalEditLocalName('${'n' * 300}.json');
      expect(long.length, lessThanOrEqualTo(120));
      expect(long, endsWith('.json'));
    });

    test('active formats use a safe edit verb or are blocked', () {
      final text = Uint8List.fromList('hello'.codeUnits);
      final shebang = Uint8List.fromList('#!/bin/sh\n'.codeUnits);
      const w = ExternalEditPlatformKind.windows;
      const m = ExternalEditPlatformKind.macos;
      const l = ExternalEditPlatformKind.linux;
      expect(
        externalEditLaunchMode('a.txt', text, w),
        ExternalEditLaunchMode.open,
      );
      expect(
        externalEditLaunchMode('a.BAT', text, w),
        ExternalEditLaunchMode.edit,
      );
      expect(
        externalEditLaunchMode('a.ps1', text, w),
        ExternalEditLaunchMode.edit,
      );
      expect(
        externalEditLaunchMode('a.exe', text, w),
        ExternalEditLaunchMode.blocked,
      );
      expect(
        externalEditLaunchMode('a.lnk', text, w),
        ExternalEditLaunchMode.blocked,
      );
      expect(
        externalEditLaunchMode('a.command', text, m),
        ExternalEditLaunchMode.edit,
      );
      expect(
        externalEditLaunchMode('Makefile', text, m),
        ExternalEditLaunchMode.edit,
      );
      expect(
        externalEditLaunchMode('a.png', text, m),
        ExternalEditLaunchMode.open,
      );
      expect(
        externalEditLaunchMode('a.desktop', text, l),
        ExternalEditLaunchMode.blocked,
      );
      expect(
        externalEditLaunchMode('a.sh', text, l),
        ExternalEditLaunchMode.blocked,
      );
      expect(
        externalEditLaunchMode('run', shebang, l),
        ExternalEditLaunchMode.blocked,
      );
      expect(
        externalEditLaunchMode('a.txt', text, l),
        ExternalEditLaunchMode.open,
      );
    });
  });

  test('blocked formats are never written locally or launched', () async {
    remote.files['/srv/deploy.sh'] = Uint8List.fromList(
      '#!/bin/sh\n'.codeUnits,
    );
    final edits = manager();
    await expectLater(
      edits.open('/srv/deploy.sh'),
      throwsA(
        isA<ExternalEditException>().having(
          (e) => e.error,
          'error',
          ExternalEditError.blockedType,
        ),
      ),
    );
    expect(launches, isEmpty);
    final files = await root
        .list(recursive: true)
        .where((e) => e is File && !e.path.endsWith('.session.lock'))
        .toList();
    expect(files, isEmpty);
    await edits.close();
  });

  test(
    'Android chooser uses text MIME and watches changes without auto-upload',
    () async {
      for (final name in [
        'notes.txt',
        'settings.yaml',
        'script.sh',
        'README',
        'app.exe',
      ]) {
        expect(
          externalEditLaunchMode(
            name,
            Uint8List(0),
            ExternalEditPlatformKind.android,
          ),
          ExternalEditLaunchMode.edit,
        );
      }
      expect(
        externalEditLaunchMode(
          'photo.png',
          Uint8List(0),
          ExternalEditPlatformKind.android,
        ),
        ExternalEditLaunchMode.open,
      );
      final edits = manager(kind: ExternalEditPlatformKind.android);
      final item = await edits.open('/srv/notes.txt');
      expect(launches.single.$2, ExternalEditLaunchMode.edit);
      await File(item.localPath)
          .writeAsString('Android edited file', flush: true);
      await _until(() => item.status == ExternalEditStatus.changed);
      expect(remote.writes, 0);
      expect(await edits.upload(item), ExternalEditUploadResult.uploaded);
      expect(
        String.fromCharCodes(remote.files['/srv/notes.txt']!),
        'Android edited file',
      );
      await edits.close();
    },
  );

  test(
    'directory atomic save marks a change; only Upload sends exact bytes',
    () async {
      final edits = manager();
      final item = await edits.open(
        '/srv/notes.txt',
        listedSize: _original.length,
      );
      expect(launches.single.$1, item.localPath);
      expect(launches.single.$2, ExternalEditLaunchMode.open);
      expect(
        p.isWithin(root.path, item.localPath) ||
            p.isWithin(await root.resolveSymbolicLinks(), item.localPath),
        isTrue,
      );
      expect(
        await File(item.localPath).readAsBytes(),
        _original,
        reason: 'BOM, CRLF and binary bytes are copied exactly',
      );
      if (!Platform.isWindows) {
        final mode = (await File(item.localPath).stat()).mode & 0x1ff;
        expect(mode, 0x180, reason: 'private copy is owner-only');
      }

      final edited = Uint8List.fromList([
        ..._original,
        ...'\r\nadded'.codeUnits,
      ]);
      await _atomicSave(item.localPath, edited);
      await _until(
        () => item.status == ExternalEditStatus.changed,
        reason: 'rename-over save seen through the directory watcher',
      );
      // Give any (forbidden) auto-upload a chance to happen.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(remote.writes, 0, reason: 'no upload without the explicit choice');
      expect(remote.files['/srv/notes.txt'], _original);

      expect(await edits.upload(item), ExternalEditUploadResult.uploaded);
      expect(remote.files['/srv/notes.txt'], edited);
      expect(remote.modes['/srv/notes.txt'], 0x1a4, reason: 'mode restored');
      expect(remote.files.keys, ['/srv/notes.txt'], reason: 'staging removed');
      expect(item.status, ExternalEditStatus.watching);
      await edits.close();
    },
  );

  test(
    'ignore dismisses one change; different later bytes ask again',
    () async {
      final edits = manager();
      final item = await edits.open('/srv/notes.txt');
      await File(item.localPath).writeAsBytes([1, 2, 3], flush: true);
      await _until(() => item.status == ExternalEditStatus.changed);
      edits.ignore(item);
      expect(item.status, ExternalEditStatus.watching);
      expect(await edits.upload(item), ExternalEditUploadResult.notPending);
      // Same ignored bytes rewritten: still nothing to ask.
      await File(item.localPath).writeAsBytes([1, 2, 3], flush: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(item.status, ExternalEditStatus.watching);
      await _atomicSave(item.localPath, [4, 5]);
      await _until(() => item.status == ExternalEditStatus.changed);
      expect(remote.writes, 0);
      await edits.close();
    },
  );

  test(
    'server change since opening needs confirmation, then replaces',
    () async {
      final edits = manager();
      final item = await edits.open('/srv/notes.txt');
      remote.files['/srv/notes.txt'] = Uint8List.fromList('theirs'.codeUnits);
      await File(item.localPath).writeAsBytes('mine'.codeUnits, flush: true);
      await _until(() => item.status == ExternalEditStatus.changed);

      expect(await edits.upload(item), ExternalEditUploadResult.remoteChanged);
      expect(item.status, ExternalEditStatus.conflict);
      expect(String.fromCharCodes(remote.files['/srv/notes.txt']!), 'theirs');
      expect(remote.writes, 0);

      // Another writer changes it again between staging and replace.
      remote.afterStage = (_) async {
        remote.afterStage = null;
        remote.files['/srv/notes.txt'] = Uint8List.fromList('third'.codeUnits);
      };
      expect(
        await edits.upload(item, replaceRemoteChange: true),
        ExternalEditUploadResult.remoteChanged,
      );
      expect(String.fromCharCodes(remote.files['/srv/notes.txt']!), 'third');
      expect(remote.files.keys, ['/srv/notes.txt'], reason: 'stage removed');

      expect(
        await edits.upload(item, replaceRemoteChange: true),
        ExternalEditUploadResult.uploaded,
      );
      expect(String.fromCharCodes(remote.files['/srv/notes.txt']!), 'mine');
      await edits.close();
    },
  );

  test('a local change during upload stays pending; baseline is the sent '
      'snapshot', () async {
    final edits = manager();
    final item = await edits.open('/srv/notes.txt');
    await File(item.localPath).writeAsBytes('first'.codeUnits, flush: true);
    await _until(() => item.status == ExternalEditStatus.changed);
    remote.beforeReplace = () async {
      remote.beforeReplace = null;
      await _atomicSave(item.localPath, 'second'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    };
    expect(
      await edits.upload(item),
      ExternalEditUploadResult.uploadedChangedAgain,
    );
    expect(String.fromCharCodes(remote.files['/srv/notes.txt']!), 'first');
    expect(item.status, ExternalEditStatus.changed);
    // The next explicit upload expects the server to hold "first".
    expect(await edits.upload(item), ExternalEditUploadResult.uploaded);
    expect(String.fromCharCodes(remote.files['/srv/notes.txt']!), 'second');
    await edits.close();
  });

  test(
    'links and oversized local copies are rejected, never uploaded',
    () async {
      final outside = File(p.join(root.path, 'outside.txt'))
        ..writeAsStringSync('secret');
      final edits = manager();
      final item = await edits.open('/srv/notes.txt');
      await File(item.localPath).delete();
      await Link(item.localPath).create(outside.path);
      await _until(() => item.status == ExternalEditStatus.rejected);
      expect(item.canUpload, isFalse);
      expect(await edits.upload(item), ExternalEditUploadResult.notPending);

      await Link(item.localPath).delete();
      await File(item.localPath)
          .writeAsBytes(Uint8List(externalEditMaxBytes + 1), flush: true);
      await _until(
        () =>
            item.status == ExternalEditStatus.rejected &&
            (item.error as ExternalEditException?)?.error ==
                ExternalEditError.localTooLarge,
      );
      expect(remote.writes, 0);
      expect(remote.files['/srv/notes.txt'], _original);
      await edits.close();
    },
  );

  test('closing the file tab drops pending edits, watchers and owned temp; '
      'a reconnected tab starts empty', () async {
    final platform = IoExternalEditPlatform(
      root: () async => root,
      launcher: (path, mode) async => launches.add((path, mode)),
      kind: ExternalEditPlatformKind.linux,
    );
    FileWorkspaceController tab() => FileWorkspaceController(
      connection: SshConnection(client: _Client(), session: _Session()),
      protocol: SshTransferProtocol.sftp,
      initialPath: '/srv',
      transportFactory: (_) async => _Transport(),
      externalEditPlatform: platform,
      externalEditFileSystem: () async => remote,
    );
    final first = tab();
    final item = await first.externalEdits.open('/srv/notes.txt');
    await File(item.localPath).writeAsBytes('pending'.codeUnits, flush: true);
    await _until(() => item.status == ExternalEditStatus.changed);

    await first.close();
    expect(first.externalEdits.items, isEmpty);
    expect(
      await first.externalEdits.upload(item),
      ExternalEditUploadResult.notPending,
    );
    expect(await File(item.localPath).exists(), isFalse);
    final leftovers = await root.list().toList();
    expect(leftovers, isEmpty, reason: 'session root removed');
    // A late save after close neither throws nor uploads.
    await Directory(p.dirname(item.localPath)).create(recursive: true);
    await File(item.localPath).writeAsBytes('late'.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(remote.writes, 0);
    expect(remote.files['/srv/notes.txt'], _original);

    final second = tab();
    expect(
      second.externalEdits.items,
      isEmpty,
      reason: 'pending edits never follow a reconnect',
    );
    expect(second.externalEdits.sessionId, isNot(first.sftp.sessionId));
    await second.close();
  });

  test(
    'stale copies of a crashed process are removed on the next session',
    () async {
      final stale = Directory(p.join(root.path, 'dead-session'))
        ..createSync(recursive: true);
      File(p.join(stale.path, '.session.lock')).writeAsStringSync('');
      File(p.join(stale.path, 'secret.txt')).writeAsStringSync('plaintext');
      final edits = manager();
      await edits.open('/srv/notes.txt');
      expect(stale.existsSync(), isFalse);
      await edits.close();
    },
  );
}
