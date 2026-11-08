abstract interface class LocalConsole {
  Stream<String> get output;
  Future<int> get exitCode;
  void input(String text);
  void resize(int columns, int rows);
  Future<void> close();
}
