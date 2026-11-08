import 'dart:typed_data';

import 'attachment_file_saver_model.dart';

bool get mobileSaveHandledWithoutPath => false;
bool get supportsStreamingAttachmentSave => false;

Future<AttachmentStreamingSaveWriter?> openStreamingSave({
  required String fileName,
  required String mediaType,
}) => Future<AttachmentStreamingSaveWriter?>.error(
  UnsupportedError('Streaming attachment saves are unavailable.'),
);

Future<void> finishSave({
  required String? path,
  required Uint8List bytes,
}) async {}
