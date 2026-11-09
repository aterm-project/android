import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'sync_preference_store.dart';

class FileSyncPreferenceStore implements SyncPreferenceStore {
  FileSyncPreferenceStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/sync-preference-v1');

  @override
  Future<bool?> readAutomaticSync() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > syncPreferenceMaxStoredLength) {
      throw const SyncPreferenceUnreadableException();
    }
    return decodeAutomaticSyncPreference(await file.readAsString());
  }

  @override
  Future<void> writeAutomaticSync(bool enabled) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.sync-preference-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(
        encodeAutomaticSyncPreference(enabled),
        flush: true,
      );
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

SyncPreferenceStore createStore() => FileSyncPreferenceStore();
