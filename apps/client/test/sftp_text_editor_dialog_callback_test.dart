import 'dart:typed_data';

import 'package:aterm_client/sftp/sftp_text_editor_service.dart';
import 'package:aterm_client/ui/sftp_text_editor_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SFTP editor saves through a LocalVault callback', (
    tester,
  ) async {
    final filesystem = _MemorySftpTextFileSystem();
    final service = SftpTextEditorService(filesystem: filesystem);
    final document = await service.open('/remote/note.txt');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SftpTextEditorDialog(
                  document: document,
                  saveDocument:
                      (document, text, {expectedRemoteBytes, saveAsName}) =>
                          service.save(
                            document,
                            text,
                            expectedRemoteBytes: expectedRemoteBytes,
                          ),
                  errorText: (error) => error.toString(),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final editor = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Remote file contents',
    );
    expect(tester.widget<TextField>(editor).controller?.text, 'original\n');
    await tester.enterText(editor, 'edited by LocalVault\n');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(filesystem.contents, 'edited by LocalVault\n');
    expect(find.text('Open editor'), findsOneWidget);
  });
}

class _MemorySftpTextFileSystem implements SftpTextFileSystem {
  final Map<String, Uint8List> _files = {
    '/remote/note.txt': Uint8List.fromList('original\n'.codeUnits),
  };
  final Map<String, Uint8List> _staged = {};

  String get contents => String.fromCharCodes(_files['/remote/note.txt']!);

  @override
  Future<SftpTextRemoteSnapshot> readFile(
    String path, {
    required int maxBytes,
  }) async => SftpTextRemoteSnapshot(
    bytes: Uint8List.fromList(_files[path]!),
    isRegularFile: true,
    permissionBits: 0x180,
  );

  @override
  Future<bool> supportsAtomicReplace() async => true;

  @override
  Future<void> writeExclusive(
    String path,
    Uint8List bytes, {
    int? permissionBits,
  }) async {
    if (_files.containsKey(path) || _staged.containsKey(path)) {
      throw SftpTextFileAlreadyExistsException(path);
    }
    _staged[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> replaceAtomically(String tempPath, String targetPath) async {
    _files[targetPath] = _staged.remove(tempPath)!;
  }

  @override
  Future<void> setPermissionBits(String path, int permissionBits) async {}

  @override
  Future<void> removeFile(String path) async {
    _files.remove(path);
    _staged.remove(path);
  }
}
