import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:web/web.dart' as web;

/// Enables the browser-storage fallback for HTTP origins.
///
/// The fallback stores values as plaintext in same-origin localStorage because
/// WebCrypto is unavailable outside secure contexts. Use HTTPS or localhost
/// when browser-side storage encryption is required.
void useInsecureHttpStorageWhenNeeded() {
  if (web.window.location.protocol != 'http:' || web.window.isSecureContext) {
    return;
  }
  FlutterSecureStoragePlatform.instance = InsecureHttpStoragePlatform();
}

class InsecureHttpStoragePlatform extends FlutterSecureStoragePlatform {
  web.Storage _storage(Map<String, String> options) {
    return options['useSessionStorage'] == 'true'
        ? web.window.sessionStorage
        : web.window.localStorage;
  }

  String _storageKey(String key, Map<String, String> options) =>
      '${options['publicKey'] ?? 'FlutterSecureStorage'}.$key';

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _storage(options).setItem(_storageKey(key, options), value);
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      _storage(options).getItem(_storageKey(key, options));

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      _storage(options).getItem(_storageKey(key, options)) != null;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _storage(options).removeItem(_storageKey(key, options));
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    final storage = _storage(options);
    final prefix = '${options['publicKey'] ?? 'FlutterSecureStorage'}.';
    final result = <String, String>{};
    for (var index = 0; index < storage.length; index++) {
      final key = storage.key(index);
      if (key == null || !key.startsWith(prefix)) continue;
      final value = storage.getItem(key);
      if (value != null) result[key.substring(prefix.length)] = value;
    }
    return result;
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    final storage = _storage(options);
    final prefix = '${options['publicKey'] ?? 'FlutterSecureStorage'}.';
    final keys = <String>[];
    for (var index = 0; index < storage.length; index++) {
      final key = storage.key(index);
      if (key != null && key.startsWith(prefix)) keys.add(key);
    }
    for (final key in keys) {
      storage.removeItem(key);
    }
  }
}
