import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import 'local_console_contract.dart';
import 'local_shell.dart';
export 'serial_console_io.dart' show openSerialConsole;
import '../l10n/l10n.dart';

bool get localConsoleSupported =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

LocalShellHost get _host => LocalShellHost(
  isWindows: Platform.isWindows,
  environment: Platform.environment,
  isFile: (path) {
    try {
      return FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
    } catch (_) {
      return false;
    }
  },
  isDirectory: (path) {
    try {
      return FileSystemEntity.isDirectorySync(path);
    } catch (_) {
      return false;
    }
  },
);

List<LocalShellKind>? _cachedKinds;
DateTime _cachedKindsAt = DateTime.fromMillisecondsSinceEpoch(0);

/// Installed shells; cached briefly because menus rebuild with every session
/// change and probing stats a handful of fixed paths.
List<LocalShellKind> availableLocalShellKinds() {
  if (!localConsoleSupported) return const [];
  final now = DateTime.now();
  final cached = _cachedKinds;
  if (cached != null && now.difference(_cachedKindsAt).inSeconds < 30) {
    return cached;
  }
  _cachedKindsAt = now;
  return _cachedKinds = List.unmodifiable(availableLocalShells(_host));
}

LocalConsole openLocalConsole({
  LocalShellLaunch launch = LocalShellLaunch.systemDefault,
}) {
  if (!localConsoleSupported) {
    throw UnsupportedError(currentL10n.theLocalConsoleRequiresTheDesktop);
  }
  final command = resolveLocalShell(launch, _host);
  final environment = {
    ...Platform.environment,
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
  };
  return _PtyConsole(
    Pty.start(
      command.executable,
      arguments: command.arguments,
      environment: environment,
      workingDirectory: command.workingDirectory,
    ),
  );
}

/// Largest single paste/keystroke batch accepted by a local shell.
const int maxLocalConsoleInputBytes = 1024 * 1024;
const int _inputChunkBytes = 4096;

class _PtyConsole implements LocalConsole, LocalConsoleWorkingDirectory {
  _PtyConsole(this.pty) {
    _output = StreamController<String>(
      onListen: _listen,
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _subscription?.cancel(),
    );
    // flutter_pty closes its own ports on exit, which ends [output] via
    // onDone; only the input side needs to know.
    unawaited(pty.exitCode.then((_) => _exited = true));
  }

  final Pty pty;
  late final StreamController<String> _output;
  StreamSubscription<String>? _subscription;
  final _pendingInput = <Uint8List>[];
  int _pendingInputBytes = 0;
  bool _writing = false;
  bool _closed = false;
  bool _exited = false;
  bool _outputFinished = false;
  Future<void>? _closing;

  void _listen() {
    // A late first listen after close must not reopen the PTY port.
    if (_outputFinished || _closed) {
      if (!_output.isClosed) unawaited(_output.close());
      return;
    }
    _subscription = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            if (!_output.isClosed) _output.add(text);
          },
          onError: (Object error) {
            if (!_output.isClosed) _output.addError(error);
          },
          onDone: _finishOutput,
        );
  }

  void _finishOutput() {
    _outputFinished = true;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (!_output.isClosed) unawaited(_output.close());
  }

  @override
  Stream<String> get output => _output.stream;
  @override
  Future<int> get exitCode => pty.exitCode;

  @override
  void input(String text) {
    if (_closed || _exited || text.isEmpty) return;
    void refuse() {
      if (!_output.isClosed) {
        _output.add('\r\n[${currentL10n.shellLocalInputTooLarge}]\r\n');
      }
    }

    // UTF-8 is never shorter than UTF-16 code units: reject huge pastes
    // before allocating their encoded copy.
    if (text.length > maxLocalConsoleInputBytes) return refuse();
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxLocalConsoleInputBytes ||
        _pendingInputBytes + bytes.length > maxLocalConsoleInputBytes) {
      return refuse();
    }
    for (var offset = 0; offset < bytes.length; offset += _inputChunkBytes) {
      final end = offset + _inputChunkBytes < bytes.length
          ? offset + _inputChunkBytes
          : bytes.length;
      _pendingInput.add(Uint8List.sublistView(bytes, offset, end));
    }
    _pendingInputBytes += bytes.length;
    if (!_writing) unawaited(_drainInput());
  }

  /// Writes in small chunks, yielding between them, so a large paste neither
  /// blocks the UI isolate in one write nor grows memory without bound.
  Future<void> _drainInput() async {
    _writing = true;
    try {
      var first = true;
      while (_pendingInput.isNotEmpty && !_closed && !_exited) {
        if (!first) await Future<void>.delayed(Duration.zero);
        first = false;
        if (_pendingInput.isEmpty || _closed || _exited) break;
        final chunk = _pendingInput.removeAt(0);
        _pendingInputBytes -= chunk.length;
        pty.write(chunk);
      }
    } catch (_) {
      // The PTY vanished between the checks and the write.
    } finally {
      _writing = false;
      if (_closed || _exited) {
        _pendingInput.clear();
        _pendingInputBytes = 0;
      }
    }
  }

  @override
  void resize(int columns, int rows) {
    if (!_closed && !_exited) {
      pty.resize(rows.clamp(1, 1000), columns.clamp(1, 1000));
    }
  }

  @override
  Future<String?> currentWorkingDirectory() async {
    if (_closed || _exited || !Platform.isLinux) return null;
    try {
      final path = await Link('/proc/${pty.pid}/cwd').target();
      return path.startsWith('/') &&
              path.length <= maxLocalShellWorkingDirectoryBytes &&
              !RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) &&
              await Directory(path).exists()
          ? path
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _pendingInput.clear();
    _pendingInputBytes = 0;
    if (!_exited) {
      try {
        if (Platform.isWindows) {
          pty.kill();
        } else if (!Process.killPid(-pty.pid, ProcessSignal.sighup)) {
          pty.kill(ProcessSignal.sighup);
        }
      } catch (_) {}
      await pty.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          if (!_exited) {
            try {
              if (!Platform.isWindows) {
                Process.killPid(-pty.pid, ProcessSignal.sigkill);
              }
              pty.kill(ProcessSignal.sigkill);
            } catch (_) {}
          }
          return -1;
        },
      );
    }
    _finishOutput();
  }
}
