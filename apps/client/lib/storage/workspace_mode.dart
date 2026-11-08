enum WorkspaceMode { server, local }

/// Device-local navigation preference. Never stores passwords or Vault keys.
abstract interface class WorkspaceModeStore {
  Future<WorkspaceMode?> read();
  Future<void> write(WorkspaceMode mode);
}

WorkspaceMode? parseWorkspaceMode(String? value) => switch (value?.trim()) {
  'server' => WorkspaceMode.server,
  'local' => WorkspaceMode.local,
  _ => null,
};
