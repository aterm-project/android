import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import '../rdp_features.dart';
import '../rdp_storage.dart';
import '../rdp_storage_io.dart';
import '../rdp_file_clipboard.dart';
import 'connection.dart';
import 'rdp_file_transfer_io.dart';
import '../../l10n/l10n.dart';

// Windows packages ship the engine. Other native platforms retain their
// existing gateway path until their own engine packaging is enabled.
bool get bundledRdpAvailable =>
    Platform.isWindows ||
    Platform.environment.containsKey('ATERMIUS_RDP_LIBRARY');

String get _libraryPath =>
    Platform.environment['ATERMIUS_RDP_LIBRARY'] ??
    (Platform.isWindows
        ? path.join(
            path.dirname(Platform.resolvedExecutable),
            'atermius_rdp.dll',
          )
        : 'libatermius_rdp.so');

RdpFeatures? _features;

/// Capabilities of the installed engine; [RdpFeatures.none] for an engine that
/// predates per-Host options or when no engine is installed.
RdpFeatures rdpEngineFeatures() {
  if (_features != null) return _features!;
  if (!bundledRdpAvailable) return _features = RdpFeatures.none;
  try {
    final library = DynamicLibrary.open(_libraryPath);
    if (!library.providesSymbol('aterm_rdp_features') ||
        !library.providesSymbol('aterm_rdp_create_ex')) {
      return _features = RdpFeatures.none;
    }
    final read = library.lookupFunction<Uint32 Function(), int Function()>(
      'aterm_rdp_features',
    );
    return _features = RdpFeatures(read());
  } catch (_) {
    return _features = RdpFeatures.none;
  }
}

class RdpConnection implements DirectDesktopConnection {
  RdpConnection._();
  final _events = StreamController<DesktopEvent>();
  final _messages = ReceivePort();
  final _done = Completer<void>();
  SendPort? _commands;
  bool _closed = false;
  @override
  Stream<DesktopEvent> get events => _events.stream;

  /// [config] is the `aterm_rdp_create_ex` text from
  /// `RdpSettings.toNativeConfig`; empty uses the original engine defaults.
  static RdpConnection connect(
    String host,
    int port,
    String username,
    String password,
    String pin, {
    String config = '',
  }) {
    final connection = RdpConnection._();
    connection._messages.listen(connection._message);
    final library = _libraryPath;
    unawaited(() async {
      try {
        await validateRdpDriveConfig(config);
        if (connection._closed) {
          connection._message(null);
          return;
        }
        await Isolate.spawn(
          _rdpWorker,
          [
            connection._messages.sendPort,
            library,
            host,
            port,
            username,
            password,
            pin,
            config,
          ],
          onExit: connection._messages.sendPort,
          errorsAreFatal: true,
        );
      } catch (error) {
        if (!connection._closed) {
          connection._events.addError(
            StateError(
              error is RdpStorageException
                  ? error.message
                  : currentL10n.couldntStartTheRdpEngineCheck,
            ),
          );
        }
        connection._message(null);
      }
    }());
    return connection;
  }

  void _message(dynamic value) {
    if (value is SendPort) {
      _commands = value;
      if (_closed) _commands!.send(['close']);
      return;
    }
    if (value == null) {
      _messages.close();
      if (!_done.isCompleted) _done.complete();
      unawaited(_events.close());
      return;
    }
    if (_closed) return;
    final message = value as List;
    switch (message[0]) {
      case 'ready':
        _events.add(DesktopReady());
      case 'frame':
        _events.add(
          DesktopFrame(
            message[1] as int,
            message[2] as int,
            (message[7] as TransferableTypedData).materialize().asUint8List(),
            x: message[3] as int,
            y: message[4] as int,
            regionWidth: message[5] as int,
            regionHeight: message[6] as int,
            onConsumed: () => _commands?.send(['frameAck']),
          ),
        );
      case 'touchSupport':
        _events.add(DesktopTouchSupport(message[1] as bool));
      case 'clipboard':
        _events.add(DesktopClipboard(message[1] as String));
      case 'cursor':
        _events.add(
          DesktopCursor(
            DesktopCursorKind.values[message[1] as int],
            width: message[2] as int,
            height: message[3] as int,
            hotX: message[4] as int,
            hotY: message[5] as int,
            bgra: (message[6] as TransferableTypedData?)
                ?.materialize()
                .asUint8List(),
          ),
        );
      case 'pointerPosition':
        _events.add(
          DesktopPointerPosition(message[1] as int, message[2] as int),
        );
      case 'remoteFiles':
        _events.add(
          DesktopRemoteFiles(
            (message[1] as List).cast<String>(),
            message[2] as int,
            message[3] as int,
          ),
        );
      case 'transfer':
        _events.add(
          DesktopFileTransfer(
            done: message[1] as int,
            total: message[2] as int,
            bytes: message[3] as int,
            savedPaths: (message[4] as List?)?.cast<String>(),
            error: message[5] as String?,
          ),
        );
      case 'resizeStatus':
        _events.add(
          DesktopResizeStatus(
            serverResize: message[1] as bool,
            result: message[2] == null
                ? null
                : DesktopResizeResult.values.byName(message[2] as String),
          ),
        );
      case 'notice':
        _events.add(DesktopNotice(message[1] as String));
      case 'certificate':
        _events.addError(RdpCertificateException(message[1] as String));
      case 'error':
        _events.addError(StateError(message[1] as String));
    }
  }

  @override
  void send(List<Object> command) {
    if (!_closed) _commands?.send(command);
  }

  @override
  void paste(String text) {
    if (utf8.encode(text).length > 65536) {
      throw FormatException(currentL10n.clipboardIsLimitedTo64Kib);
    }
    send(['paste', text]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _commands?.send(['close']);
    // The worker owns native memory and will disconnect/free before exiting.
    // Do not kill it mid-FFI and orphan native networking threads.
    await _done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }
}

const _eventFileRequest = 1, _eventFileData = 2;
const _eventBufferBytes = 8 * 1024 * 1024 + 64;

void _rdpWorker(List<dynamic> args) {
  final output = args[0] as SendPort;
  final commands = ReceivePort();
  output.send(commands.sendPort);
  _RdpNative? api;
  Pointer<Void> handle = nullptr;
  Timer? timer;
  bool closed = false, framePending = false;
  int revision = -1, clipboardRevision = 0, filesRevision = 0;
  int lastWidth = -1, lastHeight = -1;
  int cursorRevision = -1, pointerRevision = 0;
  bool canResize = false;
  bool? canTouch;
  Pointer<Uint32> info = nullptr, clipRevision = nullptr, eventHeader = nullptr;
  Pointer<Uint32> pointerInfo = nullptr;
  Pointer<Uint8> clipBuffer = nullptr, eventBuffer = nullptr;
  LocalFileOffer? offer;
  List<ClipboardFileEntry> remoteFiles = const [];
  RemoteFileDownload? download;
  void close() {
    if (closed) return;
    closed = true;
    timer?.cancel();
    commands.close();
    download?.cancel();
    offer?.close();
    if (handle != nullptr) api!.free(handle);
    for (final pointer in [info, clipRevision, eventHeader, pointerInfo]) {
      if (pointer != nullptr) calloc.free(pointer);
    }
    for (final pointer in [clipBuffer, eventBuffer]) {
      if (pointer != nullptr) calloc.free(pointer);
    }
  }

  void withBytes(Uint8List bytes, void Function(Pointer<Uint8>) use) {
    final native = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      use(native);
    } finally {
      native.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(native);
    }
  }

  try {
    api = _RdpNative(DynamicLibrary.open(args[1] as String));
    final config = args[7] as String;
    if (config.isNotEmpty && api.createEx == null) {
      throw StateError(currentL10n.theRdpEngineIsTooOld);
    }
    final strings = [
      args[2],
      args[4],
      args[5],
      args[6],
      config,
    ].map((value) => (value as String).toNativeUtf8()).toList();
    try {
      handle = config.isEmpty
          ? api.create(
              strings[0],
              args[3] as int,
              strings[1],
              strings[2],
              strings[3],
            )
          : api.createEx!(
              strings[0],
              args[3] as int,
              strings[1],
              strings[2],
              strings[3],
              strings[4],
            );
    } finally {
      for (final string in strings) {
        string
            .cast<Uint8>()
            .asTypedList(string.length)
            .fillRange(0, string.length, 0);
        calloc.free(string);
      }
      args.fillRange(2, args.length, '');
    }
    if (handle == nullptr)
      throw StateError(currentL10n.theRdpConfigurationIsInvalidOr);
    if (api.connect(handle) != 1) {
      final fingerprint = calloc<Uint8>(65);
      try {
        if (api.rejectedCertificate(handle, fingerprint, 65) == 64) {
          output.send(['certificate', fingerprint.cast<Utf8>().toDartString()]);
          close();
          return;
        }
      } finally {
        calloc.free(fingerprint);
      }
      final code = api.error(handle);
      throw StateError(
        code == 0x20008
            ? currentL10n.rdpTlsHandshakeFailed20008No
            : currentL10n.rdpConnectionFailedToradixstringCheckThe(
                code.toRadixString(16),
              ),
      );
    }
    info = calloc<Uint32>(8);
    pointerInfo = calloc<Uint32>(9);
    clipRevision = calloc<Uint32>();
    clipBuffer = calloc<Uint8>(131074);
    eventHeader = calloc<Uint32>(6);
    eventBuffer = calloc<Uint8>(_eventBufferBytes);
    output.send(['ready']);

    void transfer(
      int done,
      int total,
      int bytes, [
      List<String>? saved,
      String? error,
    ]) => output.send(['transfer', done, total, bytes, saved, error]);

    commands.listen((dynamic value) {
      if (closed) return;
      final command = value as List;
      switch (command[0]) {
        case 'close':
          close();
        case 'frameAck':
          framePending = false;
        case 'key':
          final sym = command[1] as int, down = command[2] as int;
          final scan = rdpScancode(sym);
          if (scan != null) {
            api!.key(handle, scan, down, 0);
          } else {
            final rune = sym & 0x00ffffff;
            if (rune >= 32 && rune <= 0x10ffff) {
              for (final unit in String.fromCharCode(rune).codeUnits) {
                api!.key(handle, unit, down, 1);
              }
            }
          }
        case 'mouse':
          api!.mouse(
            handle,
            command[1] as int,
            command[2] as int,
            command[3] as int,
          );
        case 'touch':
          api!.touch?.call(
            handle,
            command[1] as int,
            command[2] as int,
            command[3] as int,
            command[4] as int,
          );
        case 'size':
          final ok =
              api!.resize(handle, command[1] as int, command[2] as int) == 1;
          if (command.length > 3 && command[3] == true) {
            output.send([
              'resizeStatus',
              canResize,
              (ok
                      ? DesktopResizeResult.applied
                      : DesktopResizeResult.unsupported)
                  .name,
            ]);
          }
        case 'paste':
          final units = (command[1] as String).codeUnits;
          final bytes = calloc<Uint16>(units.length + 1);
          try {
            bytes.asTypedList(units.length).setAll(0, units);
            if (api!.paste(handle, bytes.cast(), units.length * 2) != 1) {
              output.send([
                'notice',
                currentL10n.theTargetRdpSessionDoesntHave2,
              ]);
            }
          } finally {
            bytes.asTypedList(units.length).fillRange(0, units.length, 0);
            calloc.free(bytes);
          }
        case 'offerFiles':
          final offerFiles = api!.offerFiles;
          if (offerFiles == null) {
            output.send([
              'notice',
              currentL10n.theCurrentRdpEngineDoesntSupport,
            ]);
            return;
          }
          try {
            final next = LocalFileOffer.build(
              (command[1] as List).cast<String>(),
            );
            var accepted = false;
            withBytes(next.encode(), (list) {
              accepted =
                  offerFiles(
                    handle,
                    list,
                    next.entries.length * fileDescriptorSize + 4,
                  ) ==
                  1;
            });
            if (!accepted) {
              next.close();
              output.send([
                'notice',
                currentL10n.theTargetRdpSessionDoesntHave,
              ]);
              return;
            }
            offer?.close();
            offer = next;
            output.send([
              'notice',
              currentL10n.placedCountFilesOnTheRemote(
                next.entries.where((e) => !e.isDirectory).length,
              ),
            ]);
          } on FormatException catch (e) {
            output.send([
              'notice',
              currentL10n.couldntSendFilesMessage(e.message),
            ]);
          } on FileSystemException {
            output.send(['notice', currentL10n.couldntReadTheSelectedFiles]);
          }
        case 'downloadFiles':
          final requestFile = api!.requestFile;
          if (requestFile == null || remoteFiles.isEmpty || download != null) {
            output.send(['notice', currentL10n.theRemoteClipboardHasNoFiles]);
            return;
          }
          final total = remoteFiles.where((e) => !e.isDirectory).length;
          final job = RemoteFileDownload(
            entries: remoteFiles,
            target: command[1] as String,
            request: (stream, index, flags, position, size) =>
                !closed &&
                requestFile(handle, stream, index, flags, position, size) == 1,
            onProgress: (p) => transfer(p.doneFiles, p.totalFiles, p.bytes),
          );
          download = job;
          transfer(0, total, 0);
          job.start().then(
            (saved) {
              if (identical(download, job)) download = null;
              if (!closed) transfer(total, total, 0, saved);
            },
            onError: (Object error) {
              if (identical(download, job)) download = null;
              if (!closed) {
                transfer(
                  0,
                  total,
                  0,
                  null,
                  error is FileSystemException
                      ? error.message
                      : error is FormatException
                      ? error.message
                      : currentL10n.theRemoteFilesCouldntBeSaved,
                );
              }
            },
          );
        case 'cancelDownload':
          download?.cancel();
      }
    });

    void drainEvents() {
      final next = api!.nextEvent;
      if (next == null) return;
      for (var i = 0; i < 256; i++) {
        final length = next(
          handle,
          eventHeader,
          eventBuffer,
          _eventBufferBytes,
        );
        if (length < 0) return;
        if (length > _eventBufferBytes) {
          throw StateError('RDP event too large');
        }
        final type = eventHeader[0], stream = eventHeader[1];
        if (type == _eventFileRequest) {
          final position = ByteData.sublistView(eventBuffer.asTypedList(8))
              .getUint64(0, Endian.little);
          final data = offer?.serve(
            eventHeader[2],
            eventHeader[3],
            position,
            eventHeader[4],
          );
          if (data == null) {
            api.fileResponse!(handle, stream, 0, nullptr, 0);
          } else {
            withBytes(data, (bytes) {
              api!.fileResponse!(handle, stream, 1, bytes, data.length);
            });
          }
        } else if (type == _eventFileData) {
          final bytes = Uint8List.fromList(eventBuffer.asTypedList(length));
          download?.onData(stream, eventHeader[2] == 1, bytes);
        }
      }
    }

    void readRemoteFiles() {
      final read = api!.remoteFiles;
      if (read == null) return;
      final length = read(handle, nullptr, 0, clipRevision);
      if (clipRevision.value == filesRevision) return;
      filesRevision = clipRevision.value;
      download?.cancel();
      var entries = const <ClipboardFileEntry>[];
      if (length > 0 && length <= 4 + maxClipboardFiles * fileDescriptorSize) {
        final buffer = calloc<Uint8>(length);
        try {
          read(handle, buffer, length, clipRevision);
          if (clipRevision.value == filesRevision) {
            entries = decodeFileList(
              Uint8List.fromList(buffer.asTypedList(length)),
            );
          }
        } on FormatException {
          output.send(['notice', currentL10n.anUnsafeFileNameOnThe]);
        } finally {
          calloc.free(buffer);
        }
      }
      remoteFiles = entries;
      output.send([
        'remoteFiles',
        topLevelNames(entries),
        entries.where((e) => !e.isDirectory).length,
        entries.fold<int>(0, (sum, e) => sum + e.size),
      ]);
    }

    timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      try {
        if (api!.poll(handle) != 1) {
          close();
          return;
        }
        drainEvents();
        final touchSupported = api.canTouch?.call(handle) == 1;
        if (touchSupported != canTouch) {
          canTouch = touchSupported;
          output.send(['touchSupport', touchSupported]);
        }
        final readPointer = api.pointer;
        if (readPointer != null) {
          final pixels = readPointer(handle, pointerInfo);
          if (pointerInfo[0] != cursorRevision) {
            cursorRevision = pointerInfo[0];
            final kind = pointerInfo[1], w = pointerInfo[2], h = pointerInfo[3];
            if (kind > 2 ||
                (kind == 2 &&
                    (pixels == nullptr ||
                        w < 1 ||
                        h < 1 ||
                        w > 512 ||
                        h > 512 ||
                        pointerInfo[4] >= w ||
                        pointerInfo[5] >= h))) {
              throw const FormatException('Invalid RDP pointer shape');
            }
            output.send([
              'cursor',
              kind,
              w,
              h,
              pointerInfo[4],
              pointerInfo[5],
              kind == 2
                  ? TransferableTypedData.fromList([
                      Uint8List.fromList(pixels.asTypedList(w * h * 4)),
                    ])
                  : null,
            ]);
          }
          if (pointerInfo[6] != pointerRevision) {
            pointerRevision = pointerInfo[6];
            output.send(['pointerPosition', pointerInfo[7], pointerInfo[8]]);
          }
        }
        final resizable = api.canResize?.call(handle) == 1;
        if (resizable != canResize) {
          canResize = resizable;
          output.send(['resizeStatus', canResize, null]);
        }
        if (!framePending) {
          final frame = api.frameEx != null
              ? api.frameEx!(handle, info)
              : api.frame(handle, info);
          if (frame != nullptr && info[3] != revision) {
            final w = info[0], h = info[1], stride = info[2];
            if (w < 1 ||
                h < 1 ||
                w > 8192 ||
                h > 8192 ||
                w * h > 8192 * 4096 ||
                stride < w * 4 ||
                stride > 65536) {
              throw StateError(currentL10n.invalidRdpImageSize);
            }
            var x = 0, y = 0, rw = w, rh = h;
            if (api.frameEx != null && w == lastWidth && h == lastHeight) {
              x = info[4];
              y = info[5];
              rw = info[6];
              rh = info[7];
              if (x + rw > w || y + rh > h) {
                x = 0;
                y = 0;
                rw = w;
                rh = h;
              }
            }
            revision = info[3];
            if (rw > 0 && rh > 0) {
              final bytes = Uint8List(rw * rh * 4),
                  source = frame.asTypedList(stride * h);
              for (var row = 0; row < rh; row++) {
                final from = (y + row) * stride + x * 4;
                bytes.setRange(row * rw * 4, (row + 1) * rw * 4, source, from);
              }
              for (var i = 3; i < bytes.length; i += 4) {
                bytes[i] = 255;
              }
              lastWidth = w;
              lastHeight = h;
              framePending = true;
              output.send([
                'frame',
                w,
                h,
                x,
                y,
                rw,
                rh,
                TransferableTypedData.fromList([bytes]),
              ]);
            }
          }
        }
        final length = api.clipboard(handle, clipBuffer, 131074, clipRevision);
        if (clipRevision.value != clipboardRevision &&
            length <= 131074 &&
            length.isEven) {
          clipboardRevision = clipRevision.value;
          final data = ByteData.sublistView(clipBuffer.asTypedList(length));
          final units = <int>[];
          for (var i = 0; i < length; i += 2) {
            final unit = data.getUint16(i, Endian.little);
            if (unit == 0) break;
            units.add(unit);
          }
          output.send(['clipboard', String.fromCharCodes(units)]);
        }
        readRemoteFiles();
      } catch (_) {
        output.send(['error', currentL10n.theRdpSessionDisconnected]);
        close();
      }
    });
  } catch (e) {
    output.send([
      'error',
      e is StateError ? e.message : currentL10n.theRdpEngineCantBeLoaded,
    ]);
    close();
  }
}

/// Set 1 scancodes, with bit 8 denoting an extended key (FreeRDP convention).
int? rdpScancode(int keysym) {
  const special = <int, int>{
    0xff08: 0x0e,
    0xff09: 0x0f,
    0xff0d: 0x1c,
    0xff8d: 0x11c,
    0xff1b: 0x01,
    0xffff: 0x153,
    0xff63: 0x152,
    0xff50: 0x147,
    0xff57: 0x14f,
    0xff51: 0x14b,
    0xff52: 0x148,
    0xff53: 0x14d,
    0xff54: 0x150,
    0xff55: 0x149,
    0xff56: 0x151,
    0xffe1: 0x2a,
    0xffe2: 0x36,
    0xffe3: 0x1d,
    0xffe4: 0x11d,
    0xffe9: 0x38,
    0xffea: 0x138,
    0xffeb: 0x15b,
    0xffec: 0x15c,
    0xffe5: 0x3a,
    0xff7f: 0x45,
  };
  if (special.containsKey(keysym)) return special[keysym];
  if (keysym >= 0xffbe && keysym <= 0xffc7) return 0x3b + keysym - 0xffbe;
  if (keysym == 0xffc8) return 0x57;
  if (keysym == 0xffc9) return 0x58;
  const rows = [
    ("1234567890-=", 2),
    ("qwertyuiop[]", 16),
    ("asdfghjkl;'", 30),
    ("zxcvbnm,./", 44),
  ];
  if (keysym < 128) {
    final char = String.fromCharCode(keysym).toLowerCase();
    for (final row in rows) {
      final i = row.$1.indexOf(char);
      if (i >= 0) return row.$2 + i;
    }
    if (char == ' ') return 0x39;
    if (char == '\\') return 0x2b;
    if (char == '`') return 0x29;
  }
  return null;
}

typedef _CreateNative = Pointer<Void> Function(
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _Create = Pointer<Void> Function(
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _CreateExNative = Pointer<Void> Function(
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _CreateEx = Pointer<Void> Function(
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _Buffer = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _BufferNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _Revisioned = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
);
typedef _RevisionedNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Frame = Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint32>);
typedef _FileResponse = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint8>,
  int,
);
typedef _RequestFile = int Function(Pointer<Void>, int, int, int, int, int);
typedef _NextEvent = int Function(
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Uint8>,
  int,
);

class _RdpNative {
  _RdpNative(DynamicLibrary library)
    : create = library.lookupFunction<_CreateNative, _Create>(
        'aterm_rdp_create',
      ),
      createEx = library.providesSymbol('aterm_rdp_create_ex')
          ? library.lookupFunction<_CreateExNative, _CreateEx>(
              'aterm_rdp_create_ex',
            )
          : null,
      connect = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('aterm_rdp_connect'),
      error = library
          .lookupFunction<
            Uint32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('aterm_rdp_error'),
      rejectedCertificate = library.lookupFunction<_BufferNative, _Buffer>(
        'aterm_rdp_rejected_certificate',
      ),
      poll = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('aterm_rdp_poll'),
      frame = library
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint32>),
            _Frame
          >('aterm_rdp_frame'),
      frameEx = library.providesSymbol('aterm_rdp_frame_ex')
          ? library.lookupFunction<
              Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint32>),
              _Frame
            >('aterm_rdp_frame_ex')
          : null,
      pointer = library.providesSymbol('aterm_rdp_pointer')
          ? library.lookupFunction<
              Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint32>),
              _Frame
            >('aterm_rdp_pointer')
          : null,
      key = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Int32, Int32),
            int Function(Pointer<Void>, int, int, int)
          >('aterm_rdp_key'),
      mouse = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32, Uint32),
            int Function(Pointer<Void>, int, int, int)
          >('aterm_rdp_mouse'),
      canTouch = library.providesSymbol('aterm_rdp_can_touch')
          ? library.lookupFunction<
              Int32 Function(Pointer<Void>),
              int Function(Pointer<Void>)
            >('aterm_rdp_can_touch')
          : null,
      touch = library.providesSymbol('aterm_rdp_touch')
          ? library.lookupFunction<
              Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32),
              int Function(Pointer<Void>, int, int, int, int)
            >('aterm_rdp_touch')
          : null,
      resize = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Uint32),
            int Function(Pointer<Void>, int, int)
          >('aterm_rdp_resize'),
      paste = library.lookupFunction<_BufferNative, _Buffer>('aterm_rdp_paste'),
      clipboard = library.lookupFunction<_RevisionedNative, _Revisioned>(
        'aterm_rdp_clipboard',
      ),
      offerFiles = library.providesSymbol('aterm_rdp_offer_files')
          ? library.lookupFunction<_BufferNative, _Buffer>(
              'aterm_rdp_offer_files',
            )
          : null,
      fileResponse = library.providesSymbol('aterm_rdp_file_response')
          ? library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                Int32,
                Pointer<Uint8>,
                Uint32,
              ),
              _FileResponse
            >('aterm_rdp_file_response')
          : null,
      remoteFiles = library.providesSymbol('aterm_rdp_remote_files')
          ? library.lookupFunction<_RevisionedNative, _Revisioned>(
              'aterm_rdp_remote_files',
            )
          : null,
      requestFile = library.providesSymbol('aterm_rdp_request_file')
          ? library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                Uint32,
                Uint32,
                Uint64,
                Uint32,
              ),
              _RequestFile
            >('aterm_rdp_request_file')
          : null,
      canResize = library.providesSymbol('aterm_rdp_can_resize')
          ? library.lookupFunction<
              Int32 Function(Pointer<Void>),
              int Function(Pointer<Void>)
            >('aterm_rdp_can_resize')
          : null,
      nextEvent = library.providesSymbol('aterm_rdp_next_event')
          ? library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Pointer<Uint32>,
                Pointer<Uint8>,
                Uint32,
              ),
              _NextEvent
            >('aterm_rdp_next_event')
          : null,
      free = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('aterm_rdp_free');
  final _Create create;
  final _CreateEx? createEx;
  final int Function(Pointer<Void>) connect, error, poll;
  final _Buffer rejectedCertificate, paste;
  final _Frame frame;
  final _Frame? frameEx;
  final _Frame? pointer;
  final int Function(Pointer<Void>, int, int, int) key, mouse;
  final int Function(Pointer<Void>, int, int) resize;
  final _Revisioned clipboard;
  final _Buffer? offerFiles;
  final _FileResponse? fileResponse;
  final _Revisioned? remoteFiles;
  final _RequestFile? requestFile;
  final _NextEvent? nextEvent;
  final int Function(Pointer<Void>)? canResize, canTouch;
  final int Function(Pointer<Void>, int, int, int, int)? touch;
  final void Function(Pointer<Void>) free;
}
