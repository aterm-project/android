import 'package:aterm_client/sftp/external_edit_manager.dart';
import 'package:aterm_client/sftp/external_edit_policy.dart';
import 'package:aterm_client/sftp/remote_file_operations.dart';
import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/remote_file_workspace.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/external_edit_fakes.dart';
import 'support/memory_remote_fs.dart';

class _Client extends Fake implements SSHClient {}

class _Session extends Fake implements SSHSession {}

class _Transport extends Fake
    implements LocalProfileSftpTransport, RemoteFileSystemOperations {
  _Transport(this.fs);
  final MemoryRemoteFs fs;
  @override
  Future<List<SftpName>> listDirectory(String path) => fs.listDirectory(path);
  @override
  Future<SftpFileAttrs?> lstat(String path) => fs.lstat(path);
  @override
  Future<void> close() async {}
}

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets('external edit: open, persistent footer, explicit upload and '
        'conflict confirmation at $width', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.binding.setSurfaceSize(Size(width, 700));
      final listing = MemoryRemoteFs()
        ..addDirectory('/srv')
        ..addFile('/srv/a.txt', 'A');
      final remote = MemorySftpBytesFs()
        ..files['/srv/a.txt'] = Uint8List.fromList('A\r\n'.codeUnits);
      final platform = MemoryExternalEditPlatform();
      final model = FileWorkspaceController(
        connection: SshConnection(client: _Client(), session: _Session()),
        protocol: SshTransferProtocol.sftp,
        initialPath: '/srv',
        transportFactory: (_) async => _Transport(listing),
        externalEditPlatform: platform,
        externalEditFileSystem: () async => remote,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(body: RemoteFileWorkspace(controller: model)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('file_edit_footer')), findsNothing);

        await tester.tapAt(
          tester.getCenter(find.text('a.txt')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('file_menu_openExternal')));
        await tester.pumpAndSettle();
        expect(platform.launches, hasLength(1));
        final item = model.externalEdits.items.single;
        final footer = find.byKey(const ValueKey('file_edit_footer'));
        expect(footer, findsOneWidget, reason: 'watched file is listed');
        expect(find.text('Watching for saves'), findsOneWidget);
        expect(find.text('Stop watching'), findsOneWidget);

        // An editor save only marks the file; nothing is sent.
        platform.copies.single.save('B\r\n'.codeUnits);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(item.status, ExternalEditStatus.changed);
        expect(remote.writes, 0);
        expect(find.text('Changed locally — not uploaded'), findsOneWidget);
        for (final key in ['upload', 'ignore', 'keep']) {
          final button = find.byKey(ValueKey('file_edit_${key}_${item.id}'));
          expect(button, findsOneWidget, reason: key);
          final rect = tester.getRect(button);
          expect(rect.right, lessThanOrEqualTo(width), reason: key);
          expect(rect.left, greaterThanOrEqualTo(0), reason: key);
        }
        expect(tester.getRect(footer).right, lessThanOrEqualTo(width));

        Future<void> hideSnack() async {
          tester
              .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
              .clearSnackBars();
          await tester.pumpAndSettle();
        }

        // Server changed meanwhile: Upload asks before replacing.
        remote.files['/srv/a.txt'] = Uint8List.fromList('theirs'.codeUnits);
        await hideSnack();
        await tester.tap(find.byKey(ValueKey('file_edit_upload_${item.id}')));
        await tester.pumpAndSettle();
        expect(find.text('Server copy changed'), findsOneWidget);
        expect(String.fromCharCodes(remote.files['/srv/a.txt']!), 'theirs');
        await tester.tap(find.text('Replace server copy'));
        await tester.pumpAndSettle();
        expect(String.fromCharCodes(remote.files['/srv/a.txt']!), 'B\r\n');
        expect(item.status, ExternalEditStatus.watching);
        expect(find.textContaining('Uploaded "a.txt"'), findsOneWidget);

        // Keep local stops tracking without uploading.
        platform.copies.single.save('C'.codeUnits);
        await tester.pump(const Duration(milliseconds: 500));
        await hideSnack();
        await tester.tap(find.byKey(ValueKey('file_edit_keep_${item.id}')));
        await tester.pumpAndSettle();
        expect(footer, findsNothing);
        expect(String.fromCharCodes(remote.files['/srv/a.txt']!), 'B\r\n');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await model.close();
        expect(
          platform.copies.single.deleted,
          isTrue,
          reason: 'kept copy removed when the tab closes',
        );
        expect(platform.closedWorkspaces, platform.openWorkspaces);
        debugDefaultTargetPlatformOverride = null;
        await tester.binding.setSurfaceSize(null);
      }
    });
  }

  testWidgets('browser/mobile explains external editing is unavailable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final listing = MemoryRemoteFs()
      ..addDirectory('/srv')
      ..addFile('/srv/a.txt', 'A');
    final model = FileWorkspaceController(
      connection: SshConnection(client: _Client(), session: _Session()),
      protocol: SshTransferProtocol.sftp,
      initialPath: '/srv',
      transportFactory: (_) async => _Transport(listing),
      externalEditPlatform: MemoryExternalEditPlatform(
        kind: ExternalEditPlatformKind.unsupported,
      ),
      externalEditFileSystem: () async => MemorySftpBytesFs(),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: RemoteFileWorkspace(controller: model)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('a.txt'));
      await tester.pumpAndSettle();
      expect(find.text('Edit text'), findsOneWidget, reason: 'internal stays');
      await tester.tap(find.byKey(const ValueKey('file_menu_openExternal')));
      await tester.pumpAndSettle();
      expect(find.textContaining('needs the desktop app'), findsOneWidget);
      expect(model.externalEdits.items, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await model.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
