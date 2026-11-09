import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'wallpaper_store.dart';

/// Browser wallpaper store: the small settings record in localStorage and the
/// copied image content in an app-owned IndexedDB object store (localStorage
/// quotas are too small for image bytes and would need base64).
class BrowserWallpaperStore implements WallpaperStore {
  static const _settingsKey = 'atermius.wallpaper.v1';
  static const _databaseName = 'atermius-wallpaper-v1';
  static const _objectStore = 'images';

  Future<web.IDBDatabase>? _database;

  /// Storage access errors propagate (they are not "no wallpaper"); an
  /// oversized record is returned as-is and rejected by the parser.
  @override
  Future<String?> readSettings() async =>
      web.window.localStorage.getItem(_settingsKey);

  @override
  Future<void> writeSettings(String json) async =>
      web.window.localStorage.setItem(_settingsKey, json);

  @override
  Future<Uint8List?> readImage(String id, {required int maxBytes}) async {
    if (!isValidWallpaperImageId(id)) return null;
    final database = await _open();
    final transaction = database.transaction(_objectStore.toJS, 'readonly');
    final result = await _request(
      transaction.objectStore(_objectStore).get(id.toJS),
    );
    if (result == null || !result.isA<JSUint8Array>()) return null;
    final bytes = (result as JSUint8Array).toDart;
    return bytes.length > maxBytes ? null : bytes;
  }

  @override
  Future<void> writeImage(String id, Uint8List bytes) async {
    if (!isValidWallpaperImageId(id)) throw ArgumentError.value(id, 'id');
    final database = await _open();
    final transaction = database.transaction(_objectStore.toJS, 'readwrite');
    final done = _complete(transaction);
    transaction.objectStore(_objectStore).put(bytes.toJS, id.toJS);
    await done;
  }

  @override
  Future<void> deleteImage(String id) async {
    if (!isValidWallpaperImageId(id)) return;
    final database = await _open();
    final transaction = database.transaction(_objectStore.toJS, 'readwrite');
    final done = _complete(transaction);
    transaction.objectStore(_objectStore).delete(id.toJS);
    await done;
  }

  @override
  Future<void> deleteImagesExcept(String? keepId) async {
    final database = await _open();
    final transaction = database.transaction(_objectStore.toJS, 'readwrite');
    final done = _complete(transaction);
    final store = transaction.objectStore(_objectStore);
    final keys = await _request(store.getAllKeys());
    if (keys != null && keys.isA<JSArray>()) {
      for (final key in (keys as JSArray).toDart) {
        if (key == null || !key.isA<JSString>()) continue;
        if ((key as JSString).toDart == keepId) continue;
        store.delete(key);
      }
    }
    await done;
  }

  Future<web.IDBDatabase> _open() {
    final pending = _database;
    if (pending != null) return pending;
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains(_objectStore)) {
        database.createObjectStore(_objectStore);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.complete(request.result as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Wallpaper storage unavailable'));
      }
    }).toJS;
    final future = completer.future;
    _database = future;
    // A failed open may be retried by a later call.
    unawaited(future.then<void>((_) {}, onError: (Object _) => _database = null));
    return future;
  }

  static Future<JSAny?> _request(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => completer.complete(request.result))
        .toJS;
    request.onerror = ((web.Event _) => completer.completeError(
      StateError('Wallpaper storage request failed'),
    )).toJS;
    return completer.future;
  }

  static Future<void> _complete(web.IDBTransaction transaction) {
    final completer = Completer<void>();
    transaction.oncomplete = ((web.Event _) => completer.complete()).toJS;
    void fail(web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Wallpaper storage write failed'));
      }
    }

    transaction.onerror = fail.toJS;
    transaction.onabort = fail.toJS;
    return completer.future;
  }
}

WallpaperStore createWallpaperStore() => BrowserWallpaperStore();

/// Browsers hand picked files over as bytes; there is no path to read.
Future<Uint8List> readWallpaperSourceFile(String path, int maxBytes) =>
    Future<Uint8List>.error(UnsupportedError('No file paths on the web'));
