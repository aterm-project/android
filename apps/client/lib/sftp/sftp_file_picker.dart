import 'sftp_file_picker_model.dart';
import 'sftp_file_picker_stub.dart'
    if (dart.library.io) 'sftp_file_picker_io.dart'
    if (dart.library.js_interop) 'sftp_file_picker_web.dart'
    as platform;

export 'sftp_file_picker_model.dart';

Future<SftpPickedFile?> pickSftpFile() => platform.pickSftpFile();
