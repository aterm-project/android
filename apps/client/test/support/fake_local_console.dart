import 'dart:async';

import 'package:aterm_client/console/local_console.dart';

/// Recording stand-in for a PTY/serial console (no native process).
class FakeLocalConsole implements LocalConsole, LocalConsoleWorkingDirectory {
  FakeLocalConsole({this.shell, this.serialPort, this.baudRate, this.cwd});
  final LocalShellLaunch? shell;
  final String? serialPort;
  final int? baudRate;
  String? cwd;
  final _output = StreamController<String>();
  final _exit = Completer<int>();
  final inputs = <String>[];
  final resizes = <(int, int)>[];
  int closeCalls = 0;
  bool get closed => closeCalls > 0;
  bool get outputHasListener => _output.hasListener;

  void emit(String text) => _output.add(text);
  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    unawaited(_output.close());
  }

  @override
  Stream<String> get output => _output.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void input(String text) {
    if (!closed) inputs.add(text);
  }

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));
  @override
  Future<String?> currentWorkingDirectory() async => closed ? null : cwd;
  @override
  Future<void> close() async {
    closeCalls++;
    exit(-1);
  }
}

/// Factory matching `localConsoleOpenerForTesting` seams.
class FakeConsoleFactory {
  final opened = <FakeLocalConsole>[];
  String? nextCwd;
  Object? failWith;
  LocalConsole call({LocalShellLaunch? shell, String? serialPort, int baudRate = 115200}) {
    final error = failWith;
    if (error != null) throw error;
    final console = FakeLocalConsole(
      shell: shell,
      serialPort: serialPort,
      baudRate: serialPort == null ? null : baudRate,
      cwd: nextCwd ?? shell?.workingDirectory,
    );
    opened.add(console);
    return console;
  }
}
