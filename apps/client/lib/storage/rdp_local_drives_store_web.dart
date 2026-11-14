import 'package:web/web.dart' as web;

import 'rdp_local_drives_store.dart';

class BrowserRdpLocalDrivesStore implements RdpLocalDrivesStore {
  static const _key = 'atermius.rdp-local-drives.v1';
  @override
  Future<String?> read() async {
    final value = web.window.localStorage.getItem(_key);
    return value != null && value.length <= rdpLocalDrivesStoreMaxBytes
        ? value
        : null;
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

RdpLocalDrivesStore createStore() => BrowserRdpLocalDrivesStore();
