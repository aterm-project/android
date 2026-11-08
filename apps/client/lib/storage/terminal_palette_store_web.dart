import 'package:web/web.dart' as web;

import 'terminal_palette_store.dart';

class BrowserTerminalPaletteStore implements TerminalPaletteStore {
  static const _key = 'atermius.terminal-palette.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > 64 ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String? id) async => id == null
      ? web.window.localStorage.removeItem(_key)
      : web.window.localStorage.setItem(_key, id);
}

TerminalPaletteStore createTerminalPaletteStore() =>
    BrowserTerminalPaletteStore();
