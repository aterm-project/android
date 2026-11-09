import 'package:web/web.dart' as web;

import 'sync_preference_store.dart';

class BrowserSyncPreferenceStore implements SyncPreferenceStore {
  static const _key = 'atermius.sync-preference.v1';

  @override
  Future<bool?> readAutomaticSync() async =>
      decodeAutomaticSyncPreference(web.window.localStorage.getItem(_key));

  @override
  Future<void> writeAutomaticSync(bool enabled) async => web.window.localStorage
      .setItem(_key, encodeAutomaticSyncPreference(enabled));
}

SyncPreferenceStore createStore() => BrowserSyncPreferenceStore();
