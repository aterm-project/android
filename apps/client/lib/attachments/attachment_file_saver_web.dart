import 'dart:async' show Timer;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'attachment_file_saver_model.dart';

const _streamChunkLimit = 4 * 1024 * 1024;

@JS()
extension type _SavePickerOptions._(JSObject _) implements JSObject {
  external factory _SavePickerOptions({String suggestedName});
}

@JS()
extension type _FileSystemFileHandle._(JSObject _) implements JSObject {
  external JSPromise<_FileSystemWritableFileStream> createWritable();
}

@JS()
extension type _FileSystemWritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny? data);

  external JSPromise<JSAny?> close();

  external JSPromise<JSAny?> abort();
}

@JS('window.showSaveFilePicker')
external JSPromise<_FileSystemFileHandle> _showSaveFilePicker(
  _SavePickerOptions options,
);

bool requiresDirectSave() => true;

bool get supportsStreamingAttachmentSave =>
    web.window.hasProperty('showSaveFilePicker'.toJS).toDart;

Future<AttachmentStreamingSaveWriter?> openStreamingSave({
  required String fileName,
  required String mediaType,
}) {
  if (!supportsStreamingAttachmentSave) {
    return Future<AttachmentStreamingSaveWriter?>.error(
      UnsupportedError('This browser does not support streaming file saves.'),
    );
  }
  // Start showSaveFilePicker before returning the pending future so Chromium
  // still sees the call in the user's click activation.
  late final JSPromise<_FileSystemFileHandle> picker;
  try {
    picker = _showSaveFilePicker(_SavePickerOptions(suggestedName: fileName));
  } catch (error, stackTrace) {
    return Future<AttachmentStreamingSaveWriter?>.error(error, stackTrace);
  }
  return _finishOpen(picker);
}

Future<AttachmentStreamingSaveWriter?> _finishOpen(
  JSPromise<_FileSystemFileHandle> picker,
) async {
  try {
    final handle = await picker.toDart;
    final writable = await handle.createWritable().toDart;
    return _WebAttachmentSaveWriter(writable);
  } catch (error) {
    if (_isAbortError(error)) return null;
    rethrow;
  }
}

bool _isAbortError(Object error) {
  if (!error.isA<JSObject>()) return false;
  try {
    final jsError = error as JSObject;
    return jsError.hasProperty('name'.toJS).toDart &&
        jsError.getProperty<JSString>('name'.toJS).toDart == 'AbortError';
  } on Object {
    return false;
  }
}

Future<void> saveDirectly({
  required String fileName,
  required String mediaType,
  required Uint8List bytes,
}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mediaType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  final body = web.document.body;
  if (body == null) {
    web.URL.revokeObjectURL(url);
    throw StateError('The browser document is not ready to save this file.');
  }
  body.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
    // Chromium starts consuming the Blob URL asynchronously after click().
    // Revoking it in this same turn can cancel the download before Playwright
    // or the browser's download manager observes it.
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }
}

class _WebAttachmentSaveWriter implements AttachmentStreamingSaveWriter {
  _WebAttachmentSaveWriter(this._writable);

  final _FileSystemWritableFileStream _writable;
  var _finished = false;

  @override
  Future<void> write(Uint8List plaintextChunk) async {
    if (_finished) {
      throw StateError('Attachment save writer is no longer open.');
    }
    if (plaintextChunk.length > _streamChunkLimit) {
      throw ArgumentError.value(
        plaintextChunk.length,
        'plaintextChunk.length',
        'must not exceed 4 MiB',
      );
    }
    await _writable.write(plaintextChunk.toJS).toDart;
  }

  @override
  Future<void> commit() async {
    if (_finished) return;
    // The caller invokes this only after the service has verified the final
    // length and digest, so the destination becomes visible at this point.
    await _writable.close().toDart;
    _finished = true;
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    _finished = true;
    await _writable.abort().toDart;
  }
}
