import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../crypto/vault_crypto.dart';

class GuestDisplayStore {
  GuestDisplayStore._();
  static String _key(String linkId, int version) =>
      'atermius.share.display.$linkId.$version';

  static Uint8List? read(String linkId, int version) {
    try {
      final value = web.window.sessionStorage.getItem(_key(linkId, version));
      return value == null ? null : decodeBase64Url(value);
    } catch (_) {
      return null;
    }
  }

  static void write(String linkId, int version, Uint8List key) {
    try {
      web.window.sessionStorage.setItem(
        _key(linkId, version),
        encodeBase64Url(key),
      );
    } catch (_) {}
  }

  static void clear(String linkId) {
    try {
      final storage = web.window.sessionStorage;
      for (var i = storage.length - 1; i >= 0; i--) {
        final key = storage.key(i);
        if (key != null && key.startsWith('atermius.share.display.$linkId.'))
          storage.removeItem(key);
      }
    } catch (_) {}
  }
}
