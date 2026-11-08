/// Saves a Termius transfer export through the platform's normal save picker.
///
/// Native desktop writes go to a sibling temporary file that is restricted to
/// the current user (0600 / owner-only ACL) BEFORE any content is written,
/// then renamed over the chosen destination. Web uses a browser download and
/// mobile uses the platform document picker, which own the file themselves.
library;


import 'package:flutter/foundation.dart';

import '../attachments/attachment_file_saver.dart';
import 'termius_export_file_stub.dart'
    if (dart.library.io) 'termius_export_file_io.dart'
    as platform;

/// Returns false when the user cancelled the picker.
Future<bool> saveTermiusExportFile({
  required String fileName,
  required Uint8List bytes,
  required bool containsSecrets,
}) async {
  try {
    final mediaType = fileName.endsWith('.csv')
        ? 'text/csv'
        : fileName.endsWith('.zip')
        ? 'application/zip'
        : 'text/plain';
    if (kIsWeb || !platform.supportsRestrictedDesktopSave) {
      return await saveAttachmentFile(
        fileName: fileName,
        mediaType: mediaType,
        bytes: bytes,
      );
    }
    return await platform.saveRestricted(
      fileName: fileName,
      bytes: bytes,
      restrictToOwner: containsSecrets,
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
