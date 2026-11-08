import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../platform/transfer_foreground.dart';

/// file_picker 10.3.x Android and iOS save delegates return null when cancelled
/// and a destination path on successful export. Do not treat null as a save.
Future<bool> saveMobileSshTransferFile({
  required String fileName,
  required Uint8List bytes,
}) async {
  final path = await transferForeground.run(
    'download',
    () => FilePicker.platform.saveFile(fileName: fileName, bytes: bytes),
  );
  return path != null;
}
