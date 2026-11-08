import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'sftp_file_picker_model.dart';

/// Opens a connected DOM input synchronously from the Upload button tap.
/// Keeping it attached through the change/cancel event is required for the
/// selected file to reach Dart in Chromium and other browsers.
Future<SftpPickedFile?> pickSftpFile() {
  final body = web.document.body;
  if (body == null) {
    return Future<SftpPickedFile?>.error(
      StateError('The browser document is not ready to select a file.'),
    );
  }

  final completer = Completer<SftpPickedFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = false
    ..style.display = 'none';
  Timer? focusTimer;
  var completed = false;
  var readingFile = false;
  late JSFunction changeListener;
  late JSFunction cancelListener;
  late JSFunction focusListener;

  void cleanup() {
    focusTimer?.cancel();
    input.removeEventListener('change', changeListener);
    input.removeEventListener('cancel', cancelListener);
    web.window.removeEventListener('focus', focusListener);
    input.remove();
  }

  void complete(SftpPickedFile? result) {
    if (completed) return;
    completed = true;
    cleanup();
    completer.complete(result);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (completed) return;
    completed = true;
    cleanup();
    completer.completeError(error, stackTrace);
  }

  void onChange(web.Event _) {
    if (completed || readingFile) return;
    final files = input.files;
    final file = files == null || files.length == 0 ? null : files.item(0);
    if (file == null) {
      complete(null);
      return;
    }
    readingFile = true;
    focusTimer?.cancel();
    file.arrayBuffer().toDart.then(
      (buffer) {
        final bytes = Uint8List.fromList(buffer.toDart.asUint8List());
        complete(SftpPickedFile(name: file.name, bytes: bytes));
      },
      onError: (Object error, StackTrace stackTrace) =>
          completeError(error, stackTrace),
    );
  }

  void onCancel(web.Event _) {
    complete(null);
  }

  void onWindowFocus(web.Event _) {
    if (completed || readingFile) return;
    focusTimer?.cancel();
    // Some browsers do not dispatch the input's `cancel` event. A delayed
    // focus fallback lets a `change` event win when the user selected a file.
    focusTimer = Timer(const Duration(milliseconds: 800), () {
      if (!completed && !readingFile) complete(null);
    });
  }

  changeListener = onChange.toJS;
  cancelListener = onCancel.toJS;
  focusListener = onWindowFocus.toJS;
  input.addEventListener('change', changeListener);
  input.addEventListener('cancel', cancelListener);
  web.window.addEventListener('focus', focusListener);
  body.appendChild(input);
  try {
    // This call must happen before the function returns its pending Future so
    // the browser still sees the Upload button's user activation.
    input.click();
  } catch (error, stackTrace) {
    completeError(error, stackTrace);
  }
  return completer.future;
}
