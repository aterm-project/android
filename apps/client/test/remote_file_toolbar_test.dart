import 'package:aterm_client/ssh/file_workspace_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/remote_file_workspace.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1440.0, 390.0, 240.0]) {
    testWidgets('path toolbar fits a $width pixel pane and keeps navigation', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      final transport = _Transport();
      final model = FileWorkspaceController(
        connection: SshConnection(client: _Client(), session: _Session()),
        protocol: SshTransferProtocol.sftp,
        initialPath:
            '/srv/production/very-long-project-name/releases/current/assets',
        transportFactory: (_) async => transport,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(body: RemoteFileWorkspace(controller: model)),
          ),
        );
        await tester.pumpAndSettle();
        final path = find.byKey(const ValueKey('remote_file_path_control'));
        expect(tester.getSize(path).width, lessThanOrEqualTo(480));
        expect(tester.getSize(path).height, 36);
        expect(find.byType(TextField), findsNothing);
        final label = tester.widget<Text>(
          find.descendant(of: path, matching: find.byType(Text)),
        );
        expect(label.overflow, TextOverflow.ellipsis);
        expect(find.byTooltip(model.path), findsOneWidget);
        final refresh = tester.getRect(find.byTooltip('Refresh'));
        final actions = tester.getRect(find.byTooltip('File actions'));
        expect(refresh.center.dy, tester.getRect(path).center.dy);
        expect(actions.right, lessThanOrEqualTo(width));
        await tester.tap(
          find.byKey(const ValueKey('remote_file_path_display')),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('remote_file_path_input'));
        final field = tester.widget<TextField>(input);
        expect(field.focusNode!.hasFocus, isTrue);
        expect(
          field.controller!.selection.textInside(field.controller!.text),
          model.path,
        );
        await tester.enterText(input, '/srv/next');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(model.path, '/srv/next');
        expect(transport.paths.last, '/srv/next');
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byTooltip('Parent folder'));
        await tester.pumpAndSettle();
        expect(model.path, '/srv');
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pumpAndSettle();
        expect(transport.paths.last, '/srv');
        await tester.tap(find.byTooltip('File actions'));
        await tester.pumpAndSettle();
        expect(find.text('Upload file'), findsOneWidget);
        expect(find.text('New folder'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    });
  }

  testWidgets(
    'draft survives updates and Escape restores the current directory',
    (tester) async {
      final transport = _Transport();
      final model = FileWorkspaceController(
        connection: SshConnection(client: _Client(), session: _Session()),
        protocol: SshTransferProtocol.sftp,
        initialPath: '/srv/original',
        transportFactory: (_) async => transport,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: RemoteFileWorkspace(controller: model)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('remote_file_path_display')),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('remote_file_path_input'));
        await tester.enterText(input, '/draft');
        model.select(null);
        await tester.pump();
        expect(tester.widget<TextField>(input).controller!.text, '/draft');
        final calls = transport.paths.length;
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.text('/srv/original'), findsOneWidget);
        expect(transport.paths.length, calls);
        await model.navigate('/external');
        await tester.pumpAndSettle();
        expect(find.text('/external'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
}

class _Client extends Fake implements SSHClient {}

class _Session extends Fake implements SSHSession {}

class _Transport extends Fake implements LocalProfileSftpTransport {
  final paths = <String>[];
  @override
  Future<List<SftpName>> listDirectory(String path) async {
    paths.add(path);
    return [];
  }

  @override
  Future<void> close() async {}
}
