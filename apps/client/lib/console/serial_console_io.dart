import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import 'local_console_contract.dart';
import '../l10n/l10n.dart';

LocalConsole openSerialConsole(String port, {int baudRate = 115200}) {
  if (!Platform.isWindows) {
    throw UnsupportedError(currentL10n.theComSerialConsoleRequiresThe);
  }
  port = port.toUpperCase();
  if (!RegExp(r'^COM[1-9][0-9]{0,3}$').hasMatch(port) ||
      baudRate < 50 ||
      baudRate > 4000000) {
    throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
  }
  return _SerialConsole(port, baudRate);
}

class _SerialConsole implements LocalConsole {
  _SerialConsole(String port, int baud) {
    _messages.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (_closed) {
          message.send(null);
        } else {
          for (final text in _pending) {
            message.send(text);
          }
        }
        _pending.clear();
      } else if (message is List &&
          message.length == 2 &&
          message[0] == 'ack') {
        _pendingBytes = (_pendingBytes - (message[1] as int)).clamp(0, 65536);
      } else if (message is Uint8List) {
        if (!_output.isClosed) _output.add(message);
      } else if (message is int) {
        if (!_exit.isCompleted) _exit.complete(message);
      } else if (message == null) {
        if (!_exit.isCompleted) _exit.complete(1);
        _messages.close();
        unawaited(_output.close());
      }
    });
    unawaited(() async {
      try {
        await Isolate.spawn(_serialWorker, [
          _messages.sendPort,
          port,
          baud,
        ], onExit: _messages.sendPort);
      } catch (_) {
        if (!_exit.isCompleted) _exit.complete(1);
        _messages.close();
        if (!_output.isClosed) {
          _output.add(utf8.encode(currentL10n.couldntStartTheSerialConsole));
          unawaited(_output.close());
        }
      }
    }());
  }
  final _messages = ReceivePort();
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _pending = <Uint8List>[];
  int _pendingBytes = 0;
  bool _closed = false;
  SendPort? _commands;
  @override
  Stream<String> get output =>
      _output.stream.transform(const Utf8Decoder(allowMalformed: true));
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void input(String text) {
    if (_closed || _exit.isCompleted) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > 65536 || _pendingBytes + bytes.length > 65536) {
      _output.add(utf8.encode(currentL10n.theSerialInputQueueIsFull));
      return;
    }
    _pendingBytes += bytes.length;
    if (_commands != null) {
      _commands!.send(bytes);
      return;
    }
    _pending.add(bytes);
  }

  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    _pendingBytes = 0;
    _commands?.send(null);
    await _exit.future.timeout(const Duration(seconds: 2), onTimeout: () => -1);
  }
}

void _serialWorker(List<dynamic> args) {
  final output = args[0] as SendPort, commands = ReceivePort();
  output.send(commands.sendPort);
  var handle = win.INVALID_HANDLE_VALUE;
  Timer? timer;
  var closed = false;
  final buffer = calloc<Uint8>(4096), count = calloc<Uint32>();
  void finish(int code, [String? message]) {
    if (closed) return;
    closed = true;
    timer?.cancel();
    commands.close();
    if (handle != win.INVALID_HANDLE_VALUE) win.CloseHandle(handle);
    calloc.free(buffer);
    calloc.free(count);
    if (message != null)
      output.send(Uint8List.fromList(utf8.encode('\r\n[$message]\r\n')));
    output.send(code);
  }

  try {
    final name = ('\\\\.\\${args[1]}').toNativeUtf16();
    try {
      handle = win.CreateFile(
        name,
        win.GENERIC_READ | win.GENERIC_WRITE,
        0,
        nullptr,
        win.OPEN_EXISTING,
        0,
        0,
      );
    } finally {
      calloc.free(name);
    }
    if (handle == win.INVALID_HANDLE_VALUE) {
      throw StateError(
        currentL10n.couldntOpenItemWindowsGetlasterrorCheck(
          '${args[1]}',
          win.GetLastError(),
        ),
      );
    }
    final dcb = calloc<win.DCB>(), timeout = calloc<win.COMMTIMEOUTS>();
    try {
      dcb.ref.DCBlength = sizeOf<win.DCB>();
      if (win.GetCommState(handle, dcb) == 0) {
        throw StateError(currentL10n.couldntReadTheSerialPortConfiguration);
      }
      dcb.ref
        ..BaudRate = args[2] as int
        ..bitfield = 1
        ..ByteSize = 8
        ..Parity = 0
        ..StopBits = 0;
      timeout.ref
        ..ReadIntervalTimeout = 0xffffffff
        ..ReadTotalTimeoutMultiplier = 0
        ..ReadTotalTimeoutConstant = 0
        ..WriteTotalTimeoutMultiplier = 0
        ..WriteTotalTimeoutConstant = 1000;
      if (win.SetCommState(handle, dcb) == 0 ||
          win.SetCommTimeouts(handle, timeout) == 0) {
        throw StateError(currentL10n.theSerialPortDoesntSupportThis);
      }
    } finally {
      calloc.free(dcb);
      calloc.free(timeout);
    }
    output.send(
      Uint8List.fromList(
        utf8.encode('[${args[1]} · ${args[2]} baud · 8N1]\r\n'),
      ),
    );
    commands.listen((message) {
      if (closed) return;
      if (message == null) {
        finish(0);
        return;
      }
      final data = message as Uint8List;
      if (data.length > 65536) {
        finish(1, currentL10n.serialInputExceedsTheLimit);
        return;
      }
      final bytes = calloc<Uint8>(data.length);
      try {
        bytes.asTypedList(data.length).setAll(0, data);
        var offset = 0;
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (offset < data.length) {
          if (DateTime.now().isAfter(deadline)) {
            finish(1, currentL10n.serialWriteTimedOut);
            return;
          }
          if (win.WriteFile(
                    handle,
                    bytes + offset,
                    data.length - offset,
                    count,
                    nullptr,
                  ) ==
                  0 ||
              count.value == 0) {
            finish(1, currentL10n.serialWriteFailedOrTheDevice);
            return;
          }
          offset += count.value;
        }
        output.send(['ack', data.length]);
      } finally {
        calloc.free(bytes);
      }
    });
    timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (closed) return;
      if (win.ReadFile(handle, buffer, 4096, count, nullptr) == 0) {
        finish(1, currentL10n.serialReadFailedOrTheDevice);
        return;
      }
      if (count.value > 0)
        output.send(Uint8List.fromList(buffer.asTypedList(count.value)));
    });
  } catch (e) {
    finish(
      1,
      e is StateError
          ? e.message.toString()
          : currentL10n.theSerialConsoleFailedToStart,
    );
  }
}
