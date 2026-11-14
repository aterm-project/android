import 'package:web/web.dart' as web;

import 'keyboard_capture_store.dart';

class BrowserKeyboardCaptureStore implements KeyboardCaptureStore {
  static const _key = 'atermius.keyboard-capture.v1';
  @override
  Future<String?> read() async {
    final value = web.window.localStorage.getItem(_key);
    return value != null && value.length <= 32 ? value : null;
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

KeyboardCaptureStore createStore() => BrowserKeyboardCaptureStore();
