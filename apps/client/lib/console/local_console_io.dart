import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import 'local_console_contract.dart';
export 'serial_console_io.dart' show openSerialConsole;
import '../l10n/l10n.dart';

bool get localConsoleSupported =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;
LocalConsole openLocalConsole() {
  if (!localConsoleSupported) {
    throw UnsupportedError(currentL10n.theLocalConsoleRequiresTheDesktop);
  }
  final shell = Platform.isWindows
      ? Platform.environment['COMSPEC'] ?? 'cmd.exe'
      : Platform.environment['SHELL'] ?? '/bin/sh';
  return _PtyConsole(
    Pty.start(
      shell,
      arguments: Platform.isWindows ? const [] : const ['-i'],
      environment: {...Platform.environment, 'TERM': 'xterm-256color'},
      workingDirectory:
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'],
    ),
  );
}

class _PtyConsole implements LocalConsole {
  _PtyConsole(this.pty) {
    unawaited(pty.exitCode.then((_) => _exited = true));
  }
  final Pty pty;
  bool _closed = false;
  bool _exited = false;
  @override
  Stream<String> get output => pty.output.cast<List<int>>().transform(
    const Utf8Decoder(allowMalformed: true),
  );
  @override
  Future<int> get exitCode => pty.exitCode;
  @override
  void input(String text) {
    if (!_closed) pty.write(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize(int columns, int rows) {
    if (!_closed) pty.resize(rows.clamp(1, 1000), columns.clamp(1, 1000));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_exited) return;
    if (Platform.isWindows) {
      pty.kill();
    } else {
      Process.killPid(-pty.pid, ProcessSignal.sighup);
    }
    await pty.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        if (!_exited) pty.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
