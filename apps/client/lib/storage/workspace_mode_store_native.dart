import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'workspace_mode.dart';

class FileWorkspaceModeStore implements WorkspaceModeStore {
  FileWorkspaceModeStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/workspace-mode-v1');

  @override
  Future<WorkspaceMode?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > 32) return null;
    return parseWorkspaceMode(await file.readAsString());
  }

  @override
  Future<void> write(WorkspaceMode mode) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.workspace-mode-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(mode.name, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

WorkspaceModeStore createModeStore() => FileWorkspaceModeStore();
