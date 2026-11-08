import 'dart:async';

import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'file tabs keep independent paths and transfer protocol on one SSH owner',
    () async {
      final owner = SshConnection(client: _Client(), session: _Session());
      final transport = _Transport();
      final a = FileWorkspaceController(
        connection: owner,
        protocol: SshTransferProtocol.sftp,
        transportFactory: (_) async => transport,
      );
      final b = FileWorkspaceController(
        connection: owner,
        protocol: SshTransferProtocol.scp,
        transportFactory: (_) async => _Transport(),
      );
      await a.navigate('/srv/a');
      await b.navigate('/srv/b');
      expect(a.path, '/srv/a');
      expect(b.path, '/srv/b');
      expect(b.protocol, SshTransferProtocol.scp);
      await a.close();
      expect(b.isClosed, false);
      expect(transport.closed, 1);
      await b.close();
    },
  );

  test('late navigation and close cannot replace current directory', () async {
    final transport = _Transport();
    final pending = Completer<List<SftpName>>();
    transport.pending = pending;
    final model = FileWorkspaceController(
      connection: SshConnection(client: _Client(), session: _Session()),
      protocol: SshTransferProtocol.sftp,
      transportFactory: (_) async => transport,
    );
    final old = model.navigate('/slow');
    await Future<void>.delayed(Duration.zero);
    await model.navigate('/new');
    pending.complete([]);
    await old;
    expect(model.path, '/new');
    transport.pending = Completer<List<SftpName>>();
    final closing = model.navigate('/closing');
    await Future<void>.delayed(Duration.zero);
    await model.close();
    transport.pending!.complete([]);
    await closing;
    expect(model.path, '/new');
  });

  test('relative navigation stays absolute and parents reach root', () async {
    final model = FileWorkspaceController(
      connection: SshConnection(client: _Client(), session: _Session()),
      protocol: SshTransferProtocol.sftp,
      initialPath: 'srv/data',
      transportFactory: (_) async => _Transport(),
    );
    expect(model.path, '/srv/data');
    await model.up();
    expect(model.path, '/srv');
    await model.up();
    expect(model.path, '/');
    await model.up();
    expect(model.path, '/');
    await model.navigate('srv/data');
    await model.navigate('../other');
    expect(model.path, '/srv/other');
    await model.navigate('../../../../');
    expect(model.path, '/');
    await model.close();
  });

  test('unexpected errors never disclose transport details', () {
    expect(
      fileWorkspaceErrorText(StateError('password=hidden')),
      isNot(contains('hidden')),
    );
    expect(
      fileWorkspaceErrorText(const FormatException('Invalid folder name format.')),
      'Invalid folder name format.',
    );
  });

  test('untrusted path and entry names never reach transport', () async {
    final transport = _Transport();
    final model = FileWorkspaceController(
      connection: SshConnection(client: _Client(), session: _Session()),
      protocol: SshTransferProtocol.scp,
      transportFactory: (_) async => transport,
    );
    await model.navigate('/bad\npath');
    expect(transport.paths, isEmpty);
    expect(model.error, contains('SFTP'));
    expect(
      () => model.enter(
        SftpName(
          filename: '../escape',
          longname: '',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(0x4000)),
        ),
      ),
      throwsFormatException,
    );
    expect(transport.paths, isEmpty);
    await model.close();
  });
}

class _Client extends Fake implements SSHClient {}

class _Session extends Fake implements SSHSession {}

class _Transport extends Fake implements LocalProfileSftpTransport {
  final paths = <String>[];
  Completer<List<SftpName>>? pending;
  int closed = 0;
  @override
  Future<List<SftpName>> listDirectory(String path) {
    paths.add(path);
    return path == '/slow' || path == '/closing'
        ? pending!.future
        : Future.value([]);
  }

  @override
  Future<void> close() async {
    closed++;
  }
}
