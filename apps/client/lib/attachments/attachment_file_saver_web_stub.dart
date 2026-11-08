import 'dart:typed_data';

import 'attachment_file_saver_model.dart';

bool requiresDirectSave() => false;
bool get supportsStreamingAttachmentSave => false;

Future<AttachmentStreamingSaveWriter?> openStreamingSave({
  required String fileName,
  required String mediaType,
}) => Future<AttachmentStreamingSaveWriter?>.error(
  UnsupportedError('Streaming attachment saves are unavailable.'),
);

Future<void> saveDirectly({
  required String fileName,
  required String mediaType,
  required Uint8List bytes,
}) async {
  throw UnsupportedError('Direct browser save is only available on Web.');
}
