import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../platform/transfer_foreground.dart';

import 'attachment_file_saver_model.dart';

import 'attachment_file_saver_io_stub.dart'
    if (dart.library.io) 'attachment_file_saver_io.dart'
    as io;
import 'attachment_file_saver_web_stub.dart'
    if (dart.library.js_interop) 'attachment_file_saver_web.dart'
    as web;

export 'attachment_file_saver_model.dart';

const attachmentSmallSaveLimitBytes = 256 * 1024 * 1024;
const attachmentStreamingSaveLimitBytes = 1024 * 1024 * 1024;

bool get supportsStreamingAttachmentSave =>
    io.supportsStreamingAttachmentSave || web.supportsStreamingAttachmentSave;

int get maxAttachmentBytesForPlatform => supportsStreamingAttachmentSave
    ? attachmentStreamingSaveLimitBytes
    : attachmentSmallSaveLimitBytes;

/// Opens the destination immediately, preserving the browser's user gesture.
/// A null result means that the user cancelled the picker.
Future<AttachmentStreamingSaveWriter?> openAttachmentStreamingSave({
  required String fileName,
  required String mediaType,
}) {
  if (web.supportsStreamingAttachmentSave) {
    return web.openStreamingSave(fileName: fileName, mediaType: mediaType);
  }
  if (io.supportsStreamingAttachmentSave) {
    return io.openStreamingSave(fileName: fileName, mediaType: mediaType);
  }
  return Future<AttachmentStreamingSaveWriter?>.error(
    UnsupportedError('Streaming attachment saves are unavailable.'),
  );
}

/// Saves verified plaintext to a user-selected local destination.
///
/// Web uses an in-page Blob download so the UI can reliably record that the
/// save action was triggered. Native platforms keep using file_picker.
Future<bool> saveAttachmentFile({
  required String fileName,
  required String mediaType,
  required Uint8List bytes,
}) async {
  if (web.requiresDirectSave()) {
    await web.saveDirectly(
      fileName: fileName,
      mediaType: mediaType,
      bytes: bytes,
    );
    return true;
  }

  final path = await transferForeground.run(
    'download',
    () => FilePicker.platform.saveFile(fileName: fileName, bytes: bytes),
  );
  // Desktop cancellation is reported as a null path. On mobile the plugin
  // performs the share/save action itself and may not return a filesystem
  // path, so a completed call is treated as initiated there.
  if (path == null && !io.mobileSaveHandledWithoutPath) return false;
  await io.finishSave(path: path, bytes: bytes);
  return true;
}
