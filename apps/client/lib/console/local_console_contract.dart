abstract interface class LocalConsole {
  Stream<String> get output;
  Future<int> get exitCode;
  void input(String text);
  void resize(int columns, int rows);
  Future<void> close();
}

/// Optional capability of a PTY-backed local shell: the shell process's
/// current working directory, used when duplicating/splitting a shell. Returns
/// null when the platform cannot report it (callers fall back to the launch
/// directory).
abstract interface class LocalConsoleWorkingDirectory {
  Future<String?> currentWorkingDirectory();
}
