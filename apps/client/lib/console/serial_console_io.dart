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

final _windowsComPattern = RegExp(r'^COM[1-9][0-9]{0,3}$');
final _macosSerialPattern = RegExp(r'^/dev/(?:cu|tty)\.[A-Za-z0-9._-]+$');

LocalConsole openSerialConsole(String port, {int baudRate = 115200}) {
  if (!Platform.isWindows && !Platform.isMacOS) {
    throw UnsupportedError(currentL10n.theComSerialConsoleRequiresThe);
  }
  if (baudRate < 50 || baudRate > 4000000) {
    throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
  }
  if (Platform.isWindows) {
    port = port.toUpperCase();
    if (!_windowsComPattern.hasMatch(port)) {
      throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
    }
    return _SerialConsole(port, baudRate, macos: false);
  }
  if (!_macosSerialPattern.hasMatch(port) || port.contains('..')) {
    throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
  }
  return _SerialConsole(port, baudRate, macos: true);
}

class _SerialConsole implements LocalConsole {
  _SerialConsole(String port, int baud, {required bool macos}) {
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
        await Isolate.spawn(
          macos ? _macosSerialWorker : _windowsSerialWorker,
          [_messages.sendPort, port, baud],
          onExit: _messages.sendPort,
        );
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

// Darwin POSIX serial bindings (64-bit macOS arm64 / x86_64).
const _darwinORdwr = 0x0002;
const _darwinONonblock = 0x0004;
const _darwinONoctty = 0x20000;
const _darwinCsize = 0x00000300;
const _darwinCs8 = 0x00000300;
const _darwinCread = 0x00000800;
const _darwinParenb = 0x00001000;
const _darwinCstopb = 0x00000400;
const _darwinClocal = 0x00008000;
const _darwinCrtscts = 0x00030000;
const _darwinVmin = 16;
const _darwinVtime = 17;
const _darwinTcsanow = 0;
const _darwinEagain = 35;
const _darwinEintr = 4;
const _darwinTiocexcl = 0x2000740d;
const _darwinIossiospeed = 0x80085402;
const _darwinTermiosBytes = 72;

typedef _DarwinOpenNative = Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>);
typedef _DarwinOpen = int Function(Pointer<Utf8>, int);
typedef _DarwinCloseNative = Int32 Function(Int32);
typedef _DarwinClose = int Function(int);
typedef _DarwinReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _DarwinRead = int Function(int, Pointer<Uint8>, int);
typedef _DarwinWriteNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _DarwinWrite = int Function(int, Pointer<Uint8>, int);
typedef _DarwinTcgetattrNative = Int32 Function(Int32, Pointer<Uint8>);
typedef _DarwinTcgetattr = int Function(int, Pointer<Uint8>);
typedef _DarwinTcsetattrNative = Int32 Function(Int32, Int32, Pointer<Uint8>);
typedef _DarwinTcsetattr = int Function(int, int, Pointer<Uint8>);
typedef _DarwinCfmakerawNative = Void Function(Pointer<Uint8>);
typedef _DarwinCfmakeraw = void Function(Pointer<Uint8>);
typedef _DarwinCfsetspeedNative = Int32 Function(Pointer<Uint8>, Uint64);
typedef _DarwinCfsetspeed = int Function(Pointer<Uint8>, int);
typedef _DarwinIoctlVoidNative = Int32 Function(Int32, Uint64, VarArgs<()>);
typedef _DarwinIoctlVoid = int Function(int, int);
typedef _DarwinIoctlPtrNative =
    Int32 Function(Int32, Uint64, VarArgs<(Pointer<Uint64>,)>);
typedef _DarwinIoctlPtr = int Function(int, int, Pointer<Uint64>);
typedef _DarwinErrorNative = Pointer<Int32> Function();
typedef _DarwinError = Pointer<Int32> Function();

const _standardBauds = <int>{
  50,
  75,
  110,
  134,
  150,
  200,
  300,
  600,
  1200,
  1800,
  2400,
  4800,
  9600,
  19200,
  38400,
  57600,
  115200,
  230400,
};

void _macosSerialWorker(List<dynamic> args) {
  final output = args[0] as SendPort, commands = ReceivePort();
  output.send(commands.sendPort);
  final libc = DynamicLibrary.process();
  final posixOpen = libc.lookupFunction<_DarwinOpenNative, _DarwinOpen>('open');
  final posixClose = libc.lookupFunction<_DarwinCloseNative, _DarwinClose>(
    'close',
  );
  final posixRead = libc.lookupFunction<_DarwinReadNative, _DarwinRead>('read');
  final posixWrite = libc.lookupFunction<_DarwinWriteNative, _DarwinWrite>(
    'write',
  );
  final tcgetattr = libc
      .lookupFunction<_DarwinTcgetattrNative, _DarwinTcgetattr>('tcgetattr');
  final tcsetattr = libc
      .lookupFunction<_DarwinTcsetattrNative, _DarwinTcsetattr>('tcsetattr');
  final cfmakeraw = libc
      .lookupFunction<_DarwinCfmakerawNative, _DarwinCfmakeraw>('cfmakeraw');
  final cfsetspeed = libc
      .lookupFunction<_DarwinCfsetspeedNative, _DarwinCfsetspeed>('cfsetspeed');
  final ioctlVoid = libc
      .lookupFunction<_DarwinIoctlVoidNative, _DarwinIoctlVoid>('ioctl');
  final ioctlPtr = libc.lookupFunction<_DarwinIoctlPtrNative, _DarwinIoctlPtr>(
    'ioctl',
  );
  final errnoPtr = libc.lookupFunction<_DarwinErrorNative, _DarwinError>(
    '__error',
  );

  var fd = -1;
  Timer? timer;
  var closed = false;
  final buffer = calloc<Uint8>(4096);

  void finish(int code, [String? message]) {
    if (closed) return;
    closed = true;
    timer?.cancel();
    commands.close();
    if (fd >= 0) posixClose(fd);
    calloc.free(buffer);
    if (message != null) {
      output.send(Uint8List.fromList(utf8.encode('\r\n[$message]\r\n')));
    }
    output.send(code);
  }

  try {
    final portPath = args[1] as String;
    final baud = args[2] as int;
    final cPath = portPath.toNativeUtf8();
    try {
      fd = posixOpen(cPath, _darwinORdwr | _darwinONoctty | _darwinONonblock);
    } finally {
      calloc.free(cPath);
    }
    if (fd < 0) {
      final err = errnoPtr().value;
      throw StateError(
        currentL10n.couldntOpenItemWindowsGetlasterrorCheck(portPath, err),
      );
    }

    // Best-effort exclusive access so two terminal tabs do not interleave bytes.
    ioctlVoid(fd, _darwinTiocexcl);

    final termios = calloc<Uint8>(_darwinTermiosBytes);
    final speedPtr = calloc<Uint64>();
    try {
      if (tcgetattr(fd, termios) != 0) {
        throw StateError(currentL10n.couldntReadTheSerialPortConfiguration);
      }
      cfmakeraw(termios);
      final flags = termios.cast<Uint64>();
      // c_cflag is at byte offset 16 (index 2 of Uint64). Configure 8N1.
      var cflag = flags[2];
      cflag &= ~(_darwinCsize | _darwinParenb | _darwinCstopb | _darwinCrtscts);
      cflag |= _darwinCs8 | _darwinClocal | _darwinCread;
      flags[2] = cflag;
      // c_cc starts at byte offset 32; non-blocking poll reads immediately.
      termios[32 + _darwinVmin] = 0;
      termios[32 + _darwinVtime] = 0;

      final initialSpeed = _standardBauds.contains(baud) ? baud : 9600;
      cfsetspeed(termios, initialSpeed);
      if (tcsetattr(fd, _darwinTcsanow, termios) != 0) {
        throw StateError(currentL10n.theSerialPortDoesntSupportThis);
      }
      speedPtr.value = baud;
      if (ioctlPtr(fd, _darwinIossiospeed, speedPtr) != 0 &&
          !_standardBauds.contains(baud)) {
        throw StateError(currentL10n.theSerialPortDoesntSupportThis);
      }
    } finally {
      calloc.free(termios);
      calloc.free(speedPtr);
    }

    output.send(
      Uint8List.fromList(utf8.encode('[$portPath · $baud baud · 8N1]\r\n')),
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
      final bytes = calloc<Uint8>(data.length.clamp(1, 65536));
      try {
        bytes.asTypedList(data.length).setAll(0, data);
        var offset = 0;
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (offset < data.length) {
          if (DateTime.now().isAfter(deadline)) {
            finish(1, currentL10n.serialWriteTimedOut);
            return;
          }
          final written = posixWrite(fd, bytes + offset, data.length - offset);
          if (written > 0) {
            offset += written;
            continue;
          }
          final err = errnoPtr().value;
          if (written < 0 && (err == _darwinEagain || err == _darwinEintr)) {
            sleep(const Duration(milliseconds: 2));
            continue;
          }
          finish(1, currentL10n.serialWriteFailedOrTheDevice);
          return;
        }
        output.send(['ack', data.length]);
      } finally {
        calloc.free(bytes);
      }
    });

    timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (closed) return;
      for (var i = 0; i < 8; i++) {
        final count = posixRead(fd, buffer, 4096);
        if (count > 0) {
          output.send(Uint8List.fromList(buffer.asTypedList(count)));
          if (count < 4096) break;
          continue;
        }
        if (count == 0) {
          finish(1, currentL10n.serialReadFailedOrTheDevice);
          return;
        }
        final err = errnoPtr().value;
        if (err == _darwinEagain || err == _darwinEintr) break;
        finish(1, currentL10n.serialReadFailedOrTheDevice);
        return;
      }
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

void _windowsSerialWorker(List<dynamic> args) {
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
