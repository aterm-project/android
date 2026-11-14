import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'rdp_local_drives_store.dart';

class FileRdpLocalDrivesStore implements RdpLocalDrivesStore {
  FileRdpLocalDrivesStore({Future<Directory> Function()? directory})
    : _directory = directory ?? _deviceLocalDirectory;
  final Future<Directory> Function() _directory;
  Future<File> _file() async =>
      File('${(await _directory()).path}/rdp-local-drives-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists() ||
        await file.length() > rdpLocalDrivesStoreMaxBytes) {
      return null;
    }
    return (await file.readAsString()).trim();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.rdp-local-drives-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

/// The app support directory, except on Windows: there it is under Roaming
/// AppData, which follows the user to other PCs with roaming profiles, so
/// this file goes to the same folder under Local AppData instead. (Android
/// excludes the file from Auto Backup and device transfer in
/// res/xml/backup_rules.xml and data_extraction_rules.xml.)
Future<Directory> _deviceLocalDirectory() async {
  final support = await getApplicationSupportDirectory();
  if (!Platform.isWindows) return support;
  return Directory(
    windowsDeviceLocalPath(
      support.path,
      roaming: Platform.environment['APPDATA'],
      local: Platform.environment['LOCALAPPDATA'],
    ),
  );
}

/// [support] (under [roaming]) moved under [local]; [support] itself when
/// either folder is unknown or [support] is not under [roaming].
@visibleForTesting
String windowsDeviceLocalPath(
  String support, {
  required String? roaming,
  required String? local,
}) {
  String trim(String path) =>
      path.endsWith(r'\') || path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  if (roaming == null || local == null || roaming.isEmpty || local.isEmpty) {
    return support;
  }
  final from = trim(roaming), to = trim(local);
  final prefix = '${from.toLowerCase()}\\';
  if (from.isEmpty ||
      to.isEmpty ||
      !support.toLowerCase().startsWith(prefix) ||
      support.length == prefix.length) {
    return support;
  }
  return '$to${support.substring(from.length)}';
}

RdpLocalDrivesStore createStore() => FileRdpLocalDrivesStore();
