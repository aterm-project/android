import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<({Uint8List bytes, String name})?> pickBoundedImportFile({
  required int maxBytes,
  bool showHiddenFiles = false,
  List<String>? allowedExtensions,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: allowedExtensions != null && allowedExtensions.isNotEmpty
        ? FileType.custom
        : FileType.any,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
    withData: true,
  );
  final file = result?.files.single;
  if (file == null) return null;
  final bytes = file.bytes;
  if (file.size > maxBytes || bytes == null || bytes.length != file.size) {
    throw const FormatException('unreadable');
  }
  return (bytes: bytes, name: file.name);
}

bool hasLocalDefaultSshConfig() => false;

Future<({Uint8List bytes, String name})?> readLocalDefaultSshConfig({
  required int maxBytes,
}) async => null;

String? defaultSystemSshUsername() => null;
