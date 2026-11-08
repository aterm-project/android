import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'browser_storage_client.dart';

BrowserStorageClient createBrowserStorageClient() => _WebBrowserStorageClient();

class _WebBrowserStorageClient implements BrowserStorageClient {
  web.StorageManager? get _storage {
    try {
      final navigator = web.window.navigator;
      if (!navigator.hasProperty('storage'.toJS).toDart) return null;
      return navigator.storage;
    } on Object {
      return null;
    }
  }

  bool _hasMethod(String name) {
    try {
      return _storage?.hasProperty(name.toJS).toDart ?? false;
    } on Object {
      return false;
    }
  }

  @override
  bool get canEstimate => _hasMethod('estimate');

  @override
  bool get canReadPersistence => _hasMethod('persisted');

  @override
  bool get canRequestPersistence => _hasMethod('persist');

  @override
  Future<BrowserStorageEstimate> estimate() async {
    final storage = _storage;
    if (storage == null || !canEstimate) {
      throw UnsupportedError('Storage estimate is unavailable.');
    }
    final value = await storage.estimate().toDart;
    return BrowserStorageEstimate(
      usageBytes: value.usage,
      quotaBytes: value.quota,
    );
  }

  @override
  Future<bool> persisted() async {
    final storage = _storage;
    if (storage == null || !canReadPersistence) {
      throw UnsupportedError('Persistent storage status is unavailable.');
    }
    return (await storage.persisted().toDart).toDart;
  }

  @override
  Future<bool> requestPersistence() async {
    final storage = _storage;
    if (storage == null || !canRequestPersistence) {
      throw UnsupportedError('Persistent storage requests are unavailable.');
    }
    return (await storage.persist().toDart).toDart;
  }
}
