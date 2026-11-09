import 'dart:io';

import 'dart:async';

import 'package:aterm_client/platform/file_drop_region.dart';
import 'package:aterm_client/sftp/remote_file_operations.dart';
import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/remote_file_workspace.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<void> close() async {}
}

void main() {
  late MemoryRemoteFs fs;

  FileWorkspaceController controller(List<String> uploads) =>
      FileWorkspaceController(
        connection: SshConnection(client: _Client(), session: _Session()),
        protocol: SshTransferProtocol.sftp,
        initialPath: '/srv',
        transportFactory: (_) async => _Transport(fs),
        uploader:
            ({
              required remotePath,
              required source,
              required size,
              required cancellation,
              required onProgress,
            }) async {
              await source.drain<void>();
              uploads.add(remotePath);
              fs.addFile(remotePath, 'uploaded');
            },
      );

  setUp(() {
    fs = MemoryRemoteFs()
      ..addDirectory('/srv')
      ..addDirectory('/srv/dir')
      ..addFile('/srv/a.txt', 'A');
  });

  Future<void> pumpWorkspace(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [1440.0, 390.0]) {
    testWidgets(
      'right-click menu, clipboard bar and keep-both paste at $width',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        await tester.binding.setSurfaceSize(Size(width, 700));
        final model = controller([]);
        try {
          await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
          final folder = tester.widget<Text>(find.text('dir'));
          expect(
            folder.style?.color,
            buildAppTheme().colorScheme.primary,
            reason: 'folders follow the theme, not a fixed dark-mode color',
          );
          await tester.tapAt(
            tester.getCenter(find.text('a.txt')),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          for (final label in [
            'Rename',
            'Copy',
            'Cut',
            'Copy path',
            'Delete',
          ]) {
            expect(find.text(label), findsOneWidget, reason: label);
          }
          expect(model.selected?.filename, 'a.txt');
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          final bar = find.byKey(const ValueKey('file_manager_bar'));
          expect(bar, findsOneWidget);
          expect(tester.getRect(bar).right, lessThanOrEqualTo(width));
          expect(find.textContaining('Copied "a.txt"'), findsOneWidget);

          // Paste from the empty-background context menu.
          await tester.tapAt(
            tester.getBottomLeft(
                  find.byKey(const ValueKey('remote_file_background')),
                ) +
                const Offset(40, -20),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('file_menu_paste')));
          await tester.pumpAndSettle();
          expect(find.text('Name already in use'), findsOneWidget);
          await tester.tap(find.text('Keep both'));
          await tester.pumpAndSettle();
          expect(fs.text('/srv/a (copy).txt'), 'A');
          expect(fs.text('/srv/a.txt'), 'A');
          expect(find.text('a (copy).txt'), findsOneWidget);
          // Desktop rows are also Draggable; a plain click still opens folders.
          await tester.tap(find.text('dir'));
          await tester.pumpAndSettle();
          expect(model.path, '/srv/dir');
          expect(model.clipboard, isNotNull, reason: 'kept across navigation');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await model.close();
          debugDefaultTargetPlatformOverride = null;
          await tester.binding.setSurfaceSize(null);
        }
      },
    );
  }

  testWidgets('desktop drag onto a folder moves only after confirmation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final model = controller([]);
    Future<void> dragAToDir() async {
      // Row keys: a hover tooltip may also show the folder name.
      final from = tester.getCenter(
        find.byKey(const ValueKey('remote_file_row_a.txt')),
      );
      final to = tester.getCenter(
        find.byKey(const ValueKey('remote_file_row_dir')),
      );
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    try {
      await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
      await dragAToDir();
      expect(find.text('Move item'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fs.text('/srv/a.txt'), 'A');
      fs.addFile('/srv/dir/a.txt', 'OTHER');
      await dragAToDir();
      await tester.tap(find.widgetWithText(FilledButton, 'Move'));
      await tester.pumpAndSettle();
      expect(fs.text('/srv/a.txt'), 'A', reason: 'collision is refused');
      expect(fs.text('/srv/dir/a.txt'), 'OTHER');
      fs.nodes.remove('/srv/dir/a.txt');
      await dragAToDir();
      await tester.tap(find.widgetWithText(FilledButton, 'Move'));
      await tester.pumpAndSettle();
      expect(fs.nodes.containsKey('/srv/a.txt'), isFalse);
      expect(fs.text('/srv/dir/a.txt'), 'A');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await model.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android long press opens the anchored entry menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(390, 700));
    final model = controller([]);
    try {
      await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
      final row = tester.getCenter(find.text('a.txt'));
      await tester.longPressAt(row);
      await tester.pumpAndSettle();
      final rename = find.byKey(const ValueKey('file_menu_rename'));
      expect(rename, findsOneWidget);
      expect(tester.getSize(rename).height, greaterThanOrEqualTo(36));
      await tester.tap(rename);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('file_manager_name_input'));
      await tester.enterText(input, 'dir');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();
      // Collision is refused: nothing replaced, error surfaced.
      expect(fs.text('/srv/a.txt'), 'A');
      expect(fs.nodes['/srv/dir']!.kind, MemKind.directory);
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await model.close();
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  group('drop review regressions', () {
    Future<void> sendDrop(WidgetTester tester, List<String> paths) async {
      Future<void> send(String method, Object? arguments) =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                'desktop_drop',
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(method, arguments),
                ),
                (_) {},
              );
      final center = tester.getCenter(find.byType(RemoteFileWorkspace));
      await send('entered', [center.dx, center.dy]);
      await tester.pump();
      await send('performOperation', paths);
    }

    Future<void> sendWeb(
      WidgetTester tester,
      String method,
      Map<String, Object?> arguments,
    ) async {
      Future<void> send(String name, Object? args) =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                'desktop_drop',
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(name, args),
                ),
                (_) {},
              );
      final center = tester.getCenter(find.byType(RemoteFileWorkspace));
      await send('entered', [center.dx, center.dy]);
      await tester.pump();
      await send(method, arguments);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('bounded web drop events reach the tab with honest status', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final uploads = <String>[];
      final model = controller(uploads);
      try {
        await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
        expect(DesktopDropWebLimits.maxItems, fileManagerMaxDroppedFiles);
        expect(DesktopDropWebLimits.expandDirectories, isFalse);
        await sendWeb(tester, 'performOperation_web_rejected', {
          'reason': 'tooManyItems',
          'count': 500,
        });
        expect(find.text('Drop at most 64 files at a time.'), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(RemoteFileWorkspace)))
            .removeCurrentSnackBar();
        await tester.pump();
        await sendWeb(tester, 'performOperation_web_rejected', {
          'reason': 'failed',
          'count': 2,
        });
        expect(find.textContaining("couldn't be read"), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(RemoteFileWorkspace)))
            .removeCurrentSnackBar();
        await tester.pump();
        // A folder (no URL, no children) plus one skipped non-file item.
        await sendWeb(tester, 'performOperation_web_bounded', {
          'items': [
            {
              'uri': '',
              'children': <Object>[],
              'data': null,
              'name': 'photos',
              'type': 'directory',
              'size': 0,
              'relativePath': '/photos',
              'lastModified': 0,
            },
          ],
          'skipped': 1,
        });
        expect(
          find.textContaining('Only files can be dropped'),
          findsOneWidget,
        );
        expect(uploads, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await model.close();
      }
    });

    testWidgets('an oversized batch is rejected before any item is inspected', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var probes = 0;
      debugDroppedFileProbe = (_) async {
        probes++;
        return true;
      };
      final uploads = <String>[];
      final model = controller(uploads);
      try {
        await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
        await sendDrop(tester, [
          for (var i = 0; i < fileManagerMaxDroppedFiles + 1; i++) '/tmp/f$i',
        ]);
        await tester.pump();
        expect(probes, 0);
        expect(uploads, isEmpty);
        expect(find.text('Drop at most 64 files at a time.'), findsOneWidget);
      } finally {
        debugDroppedFileProbe = null;
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await model.close();
      }
    });

    testWidgets(
      'a drop inspected across a tab switch is not routed to the new tab',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final probe = Completer<bool>();
        debugDroppedFileProbe = (_) => probe.future;
        final firstUploads = <String>[];
        final secondUploads = <String>[];
        final first = controller(firstUploads);
        final second = controller(secondUploads);
        final shown = ValueNotifier<FileWorkspaceController>(first);
        try {
          await pumpWorkspace(
            tester,
            ValueListenableBuilder<FileWorkspaceController>(
              valueListenable: shown,
              builder: (_, model, _) => RemoteFileWorkspace(controller: model),
            ),
          );
          await sendDrop(tester, ['/tmp/local.txt']);
          // While the dropped item is still being inspected, the same pane
          // switches to another file tab (another controller).
          shown.value = second;
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<RemoteFileWorkspace>(find.byType(RemoteFileWorkspace))
                .controller,
            same(second),
          );
          // Even a rejected item must not be reported against the new tab.
          probe.complete(false);
          await tester.pump();
          await tester.pump();
          expect(
            find.textContaining('changed folder or connection'),
            findsOneWidget,
          );
          expect(firstUploads, isEmpty);
          expect(secondUploads, isEmpty);
        } finally {
          debugDroppedFileProbe = null;
          debugDefaultTargetPlatformOverride = null;
          await tester.pumpWidget(const SizedBox());
          await first.close();
          await second.close();
        }
      },
    );

    testWidgets('a drop inspected across folder navigation is rejected', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final probe = Completer<bool>();
      debugDroppedFileProbe = (_) => probe.future;
      final uploads = <String>[];
      final model = controller(uploads);
      try {
        await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
        await sendDrop(tester, ['/tmp/local.txt']);
        await model.navigate('/srv/dir');
        await tester.pumpAndSettle();
        expect(model.path, '/srv/dir');
        probe.complete(false);
        await tester.pump();
        await tester.pump();
        expect(
          find.textContaining('changed folder or connection'),
          findsOneWidget,
        );
        expect(uploads, isEmpty);
      } finally {
        debugDroppedFileProbe = null;
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await model.close();
      }
    });

    testWidgets('an inspection failure is reported, never unhandled', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      debugDroppedFileProbe = (_) async => throw StateError('stat failed');
      final uploads = <String>[];
      final model = controller(uploads);
      try {
        await pumpWorkspace(tester, RemoteFileWorkspace(controller: model));
        await sendDrop(tester, ['/tmp/local.txt']);
        await tester.pump();
        await tester.pump();
        expect(find.textContaining("couldn't be read"), findsOneWidget);
        expect(uploads, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        debugDroppedFileProbe = null;
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await model.close();
      }
    });
  });

  testWidgets('native drop uploads only into the visible tab', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final hiddenUploads = <String>[];
    final visibleUploads = <String>[];
    final hidden = controller(hiddenUploads);
    final visible = controller(visibleUploads);
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('atermius-drop-test-'),
    );
    final file = File('${directory!.path}/dropped.txt');
    await tester.runAsync(() => file.writeAsString('local'));
    try {
      await pumpWorkspace(
        tester,
        IndexedStack(
          index: 1,
          children: [
            RemoteFileWorkspace(controller: hidden),
            RemoteFileWorkspace(controller: visible),
          ],
        ),
      );
      final center = tester.getCenter(find.byType(IndexedStack));
      // desktop_drop's own platform checks use the host OS (Linux in CI),
      // which reports logical coordinates.
      Future<void> send(String method, Object? arguments) => tester.runAsync(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'desktop_drop',
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, arguments),
              ),
              (_) {},
            ),
      );
      await send('entered', [center.dx, center.dy]);
      await tester.pump();
      expect(find.byKey(const ValueKey('file_drop_highlight')), findsOneWidget);
      await send('performOperation', [file.path, directory.path]);
      // Real local file IO runs outside the fake clock.
      for (var i = 0; i < 100; i++) {
        if (find.textContaining('Uploaded').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(visibleUploads, ['/srv/dropped.txt']);
      expect(hiddenUploads, isEmpty);
      // The folder in the same drop was rejected, not expanded.
      expect(find.textContaining('Uploaded 1'), findsOneWidget);
      expect(find.textContaining('skipped 1'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await hidden.close();
      await visible.close();
      await tester.runAsync(() => directory.delete(recursive: true));
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
