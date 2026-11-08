import 'package:web/web.dart' as web;

import 'app_language_store.dart';

class BrowserAppLanguageStore implements AppLanguageStore {
  static const _key = 'atermius.app-language.v1';

  @override
  Future<String?> read() async {
    try {
      return web.window.localStorage.getItem(_key);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String code) async =>
      web.window.localStorage.setItem(_key, code);
}

AppLanguageStore createLanguageStore() => BrowserAppLanguageStore();
