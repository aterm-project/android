import 'package:web/web.dart' as web;

import 'terminal_keybar_store.dart';

class BrowserTerminalKeybarStore implements TerminalKeybarStore {
  static const _key = 'atermius.terminal-keybar.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > terminalKeybarStoreMaxLength
          ? null
          : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

TerminalKeybarStore createTerminalKeybarStore() => BrowserTerminalKeybarStore();
