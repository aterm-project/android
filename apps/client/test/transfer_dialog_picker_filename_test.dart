import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/ui/transfer_dialog.dart';

void main() {
  testWidgets(
    'valid selection then malicious provider invalidates prior upload source',
    (tester) async {
      FilePicker? original;
      try {
        original = FilePicker.platform;
      } on Object {
      // No native plugin is registered in this standalone widget test.
    }
      FilePicker.platform = _Picker('initial.txt');
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showSshTransferDialog(
                    context: context,
                    client: _UnusedClient(),
                    direction: SshTransferDirection.upload,
                    remotePath: '/chosen',
                    uploadIntoDirectory: true,
                  ),
                  child: const Text('Open transfer'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open transfer'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose local file'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Upload'))
              .onPressed,
          isNotNull,
        );
        FilePicker.platform = _Picker('unused', cancelled: true);
        await tester.tap(find.text('initial.txt'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Upload'))
              .onPressed,
          isNotNull,
        );
        expect(find.text('initial.txt'), findsOneWidget);
        FilePicker.platform = _Picker('../escape.txt');
        await tester.tap(find.text('initial.txt'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Remote file path'),
              )
              .controller!
              .text,
          '/chosen/initial.txt',
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Upload'))
              .onPressed,
          isNull,
        );
        expect(find.text('Choose local file'), findsOneWidget);
        expect(
          find.text('Could not open a streaming file source.'),
          findsOneWidget,
        );
      } finally {
        if (original != null) FilePicker.platform = original;
      }
    },
  );

  for (final name in [
    '../escape.txt',
    'a/b.txt',
    r'a\b.txt',
    'nul\x00name',
    '..',
    "报告 '完整'.txt",
  ]) {
    testWidgets(
      'provider filename ${name.replaceAll('\x00', '<NUL>')} stays inside selected directory',
      (tester) async {
        FilePicker? original;
        try {
          original = FilePicker.platform;
        } on Object {
          /* no native plugin in unit tests */
        }
        FilePicker.platform = _Picker(name);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: ElevatedButton(
                    onPressed: () => showSshTransferDialog(
                      context: context,
                      client: _UnusedClient(),
                      direction: SshTransferDirection.upload,
                      remotePath: '/chosen',
                      uploadIntoDirectory: true,
                    ),
                    child: const Text('Open transfer'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open transfer'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Choose local file'));
          await tester.pumpAndSettle();
          final path = tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Remote file path'),
              )
              .controller!
              .text;
          if (name == "报告 '完整'.txt") {
            expect(path, "/chosen/报告 '完整'.txt");
            expect(
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Upload'),
                  )
                  .onPressed,
              isNotNull,
            );
          } else {
            expect(path, '/chosen');
            expect(
              find.text('Could not open a streaming file source.'),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Upload'),
                  )
                  .onPressed,
              isNull,
            );
          }
          await tester.tap(find.widgetWithText(TextButton, 'Close'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } finally {
          if (original != null) FilePicker.platform = original;
        }
      },
    );
  }
}

class _UnusedClient extends Fake implements SSHClient {}

class _Picker extends FilePicker {
  _Picker(this.name, {this.cancelled = false});
  final String name;
  final bool cancelled;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => cancelled
      ? null
      : FilePickerResult([
          PlatformFile(
            name: name,
            size: 1,
            readStream: Stream.value(Uint8List.fromList([1])),
          ),
        ]);
}
