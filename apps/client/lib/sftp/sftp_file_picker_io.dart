import 'package:file_picker/file_picker.dart';

import '../platform/transfer_foreground.dart';

import 'sftp_file_picker_model.dart';

Future<SftpPickedFile?> pickSftpFile() async {
  final selection = await transferForeground.run(
    'upload',
    () => FilePicker.platform.pickFiles(withData: true, allowMultiple: false),
  );
  final file = selection?.files.single;
  final bytes = file?.bytes;
  if (file == null || bytes == null) return null;
  return SftpPickedFile(name: file.name, bytes: bytes);
}
