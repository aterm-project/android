import 'package:web/web.dart' as web;

import 'app_theme_store.dart';

class BrowserAppThemeStore implements AppThemeStore {
  static const _key = 'atermius.app-theme.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > appThemeStoreMaxLength
          ? null
          : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String code) async =>
      web.window.localStorage.setItem(_key, code);
}

AppThemeStore createThemeStore() => BrowserAppThemeStore();
