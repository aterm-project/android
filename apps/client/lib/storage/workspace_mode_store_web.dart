import 'package:web/web.dart' as web;

import 'workspace_mode.dart';

class BrowserWorkspaceModeStore implements WorkspaceModeStore {
  static const _key = 'atermius.workspace-mode.v1';

  @override
  Future<WorkspaceMode?> read() async =>
      parseWorkspaceMode(web.window.localStorage.getItem(_key));

  @override
  Future<void> write(WorkspaceMode mode) async =>
      web.window.localStorage.setItem(_key, mode.name);
}

WorkspaceModeStore createModeStore() => BrowserWorkspaceModeStore();
