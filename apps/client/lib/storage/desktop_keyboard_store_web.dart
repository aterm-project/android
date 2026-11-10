import 'package:web/web.dart' as web;

import 'desktop_keyboard_store.dart';

class BrowserDesktopKeyboardStore implements DesktopKeyboardStore {
  static const _key = 'atermius.desktop-keyboard.v1';
  @override
  Future<String?> read() async {
    final value = web.window.localStorage.getItem(_key);
    return value != null && value.length <= 32 ? value : null;
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

DesktopKeyboardStore createStore() => BrowserDesktopKeyboardStore();
