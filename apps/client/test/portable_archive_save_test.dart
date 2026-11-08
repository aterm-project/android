import 'dart:typed_data';

import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop archive saver reports a canceled file picker', () async {
    FilePicker? originalPicker;
    try {
      try {
        originalPicker = FilePicker.platform;
      } catch (_) {
        // Some Flutter test bindings do not register a native picker plugin.
      }
      FilePicker.platform = _CancelFilePicker();
      final saved = await saveAttachmentFile(
        fileName: 'backup.atvlt',
        mediaType: 'application/octet-stream',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(saved, isFalse);
    } finally {
      if (originalPicker != null) FilePicker.platform = originalPicker;
    }
  });
}

class _CancelFilePicker extends FilePicker {
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => null;
}
