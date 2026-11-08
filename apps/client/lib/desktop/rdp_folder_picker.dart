import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Folder chooser for RDP drive redirection; unavailable on the web.
Future<String?> pickRdpRedirectFolder() async {
  if (kIsWeb) return null;
  return FilePicker.platform.getDirectoryPath(dialogTitle: 'Folder to redirect');
}
