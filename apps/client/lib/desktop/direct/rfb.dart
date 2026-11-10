import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../ssh/ssh_transport_io.dart'
    if (dart.library.js_interop) '../../ssh/ssh_transport_web.dart'
    as transport;
import 'connection.dart';

/// RFB 3.3/3.7/3.8, Raw/CopyRect/DesktopSize/ExtendedDesktopSize. No gateway
/// or viewer process. Server-side resize uses SetDesktopSize only after the
/// server advertised ExtendedDesktopSize (rfbproto: -308, message 251).
/// Wire format: RFC 6143. Bounds are checked before allocating pixel buffers.
class RfbConnection implements DirectDesktopConnection {
  RfbConnection._();
  final _events = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => _events.stream;
  void Function(List<int>)? _write;
  Future<void> Function()? _closeSocket;
  _Reader? _reader;
  bool _closed = false;
  Completer<void>? _frameConsumed;
  int _width = 0, _height = 0;
  Uint8List _pixels = Uint8List(0);
  bool _extendedDesktopSize = false;
  bool _resizePending = false;
  List<RfbScreen> _screens = const [];

  /// Whether the server negotiated SetDesktopSize support.
  bool get serverResize => _extendedDesktopSize;

  static RfbConnection connect(String host, int port, String password) {
    final connection = RfbConnection._();
    unawaited(connection._run(host, port, password));
    return connection;
  }

  Future<void> _run(String host, int port, String password) async {
    try {
      final socket = await transport.connectDirect(host, port);
      if (_closed) {
        await socket.close();
        return;
      }
      _write = socket.sink.add;
      _closeSocket = socket.close;
      final reader = _reader = _Reader(socket.stream);
      await _handshake(reader, password).timeout(const Duration(seconds: 20));
      password = '';
      if (_closed) return;
      _events.add(DesktopReady());
      _request(false);
      while (!_closed) {
        final type = (await reader.read(1))[0];
        switch (type) {
          case 0:
            final header = ByteData.sublistView(await reader.read(3));
            final count = header.getUint16(1);
            if (count > 4096)
              throw const FormatException('Too many VNC rectangles');
            var resized = false;
            var frameChanged = false;
            for (var i = 0; i < count; i++) {
              final h = ByteData.sublistView(await reader.read(12));
              final x = h.getUint16(0), y = h.getUint16(2);
              final w = h.getUint16(4), height = h.getUint16(6);
              final encoding = h.getInt32(8);
              if (encoding == -239) {
                // RichCursor: pixels followed by 1-bit alpha mask.
                if (w == 0 || height == 0) {
                  _events.add(DesktopCursor(DesktopCursorKind.hidden));
                  continue;
                }
                if (w > 512 || height > 512 || x >= w || y >= height) {
                  throw const FormatException('Invalid VNC cursor');
                }
                final pixels = await reader.read(w * height * 4);
                final stride = (w + 7) ~/ 8;
                final mask = await reader.read(stride * height);
                for (var row = 0; row < height; row++) {
                  for (var col = 0; col < w; col++) {
                    pixels[(row * w + col) * 4 + 3] =
                        mask[row * stride + col ~/ 8] & (0x80 >> (col % 8)) != 0
                        ? 255
                        : 0;
                  }
                }
                _events.add(
                  DesktopCursor(
                    DesktopCursorKind.image,
                    width: w,
                    height: height,
                    hotX: x,
                    hotY: y,
                    bgra: pixels,
                  ),
                );
                continue;
              }
              if (encoding == -232) {
                // PointerPos, independent of framebuffer damage.
                _events.add(DesktopPointerPosition(x, y));
                continue;
              }
              if (encoding == -223) {
                _resize(w, height);
                resized = frameChanged = true;
                continue;
              }
              if (encoding == -308) {
                final head = await reader.read(4);
                final screens = head[0];
                if (screens > 16) {
                  throw const FormatException('Too many VNC screens');
                }
                final raw = ByteData.sublistView(
                  await reader.read(screens * 16),
                );
                final layout = [
                  for (var s = 0; s < screens; s++)
                    RfbScreen(
                      id: raw.getUint32(s * 16),
                      x: raw.getUint16(s * 16 + 4),
                      y: raw.getUint16(s * 16 + 6),
                      width: raw.getUint16(s * 16 + 8),
                      height: raw.getUint16(s * 16 + 10),
                      flags: raw.getUint32(s * 16 + 12),
                    ),
                ];
                final reason = x, status = y;
                final first = !_extendedDesktopSize;
                _extendedDesktopSize = true;
                if (status == 0) {
                  frameChanged = true;
                  if (w != _width || height != _height) {
                    _resize(w, height);
                    resized = frameChanged = true;
                  }
                  _screens = List.unmodifiable(layout);
                }
                if (reason == 1 && _resizePending) {
                  _resizePending = false;
                  _events.add(
                    DesktopResizeStatus(
                      serverResize: true,
                      result: rfbResizeResult(status),
                    ),
                  );
                } else if (first) {
                  _events.add(DesktopResizeStatus(serverResize: true));
                }
                continue;
              }
              if (x + w > _width ||
                  y + height > _height ||
                  w == 0 ||
                  height == 0) {
                throw const FormatException('Invalid VNC rectangle');
              }
              if (encoding == 0) {
                frameChanged = true;
                final data = await reader.read(w * height * 4);
                for (var row = 0; row < height; row++) {
                  final start = ((y + row) * _width + x) * 4;
                  _pixels.setRange(start, start + w * 4, data, row * w * 4);
                }
              } else if (encoding == 1) {
                frameChanged = true;
                final source = ByteData.sublistView(await reader.read(4));
                final sx = source.getUint16(0), sy = source.getUint16(2);
                if (sx + w > _width || sy + height > _height) {
                  throw const FormatException('Invalid VNC copy rectangle');
                }
                // Copy via a temporary buffer so overlapping rows are safe.
                final copy = Uint8List(w * height * 4);
                for (var row = 0; row < height; row++) {
                  final start = ((sy + row) * _width + sx) * 4;
                  copy.setRange(row * w * 4, (row + 1) * w * 4, _pixels, start);
                }
                for (var row = 0; row < height; row++) {
                  final start = ((y + row) * _width + x) * 4;
                  _pixels.setRange(start, start + w * 4, copy, row * w * 4);
                }
              } else {
                throw const FormatException('Unsupported VNC encoding');
              }
            }
            // RFB's fourth byte is padding, Flutter requires opaque alpha.
            if (frameChanged) {
              for (var i = 3; i < _pixels.length; i += 4) {
                _pixels[i] = 255;
              }
            }
            if (!_closed && frameChanged) {
              final consumed = _frameConsumed = Completer<void>();
              _events.add(
                DesktopFrame(
                  _width,
                  _height,
                  Uint8List.fromList(_pixels),
                  onConsumed: () {
                    if (!consumed.isCompleted) consumed.complete();
                  },
                ),
              );
              await consumed.future;
              _frameConsumed = null;
            }
            _request(!resized);
          case 2: // bell
            break;
          case 3:
            final h = ByteData.sublistView(await reader.read(7));
            final length = h.getUint32(3);
            if (length > 65536)
              throw const FormatException('VNC clipboard exceeds limit');
            final text = latin1.decode(await reader.read(length));
            if (!_closed) _events.add(DesktopClipboard(text));
          default:
            throw const FormatException('Unsupported VNC message');
        }
      }
    } catch (e, stack) {
      if (!_closed) _events.addError(e, stack);
    } finally {
      await close();
    }
  }

  Future<void> _handshake(_Reader reader, String password) async {
    final version = ascii.decode(await reader.read(12));
    if (!RegExp(r'^RFB 003\.(003|007|008)\n$').hasMatch(version)) {
      throw const FormatException('Unsupported VNC protocol version');
    }
    _write!(ascii.encode(version));
    final minor = int.parse(version.substring(8, 11));
    int security;
    if (minor == 3) {
      security = ByteData.sublistView(await reader.read(4)).getUint32(0);
    } else {
      final count = (await reader.read(1))[0];
      if (count == 0)
        throw const FormatException('VNC server refused connection');
      final types = await reader.read(count);
      // Prefer password authentication whenever the server offers it.
      security = types.contains(2)
          ? 2
          : types.contains(1)
          ? 1
          : 0;
      if (security != 0) _write!([security]);
    }
    if (security == 2) {
      if (password.isEmpty)
        throw const FormatException('VNC requires a saved password');
      final challenge = await reader.read(16);
      _write!(vncChallengeResponse(password, challenge));
    } else if (security != 1) {
      throw const FormatException(
        'VNC security type unsupported (use VNC password authentication)',
      );
    }
    if (security == 2 || minor >= 8) {
      final result = ByteData.sublistView(await reader.read(4)).getUint32(0);
      if (result != 0) throw const FormatException('VNC authentication failed');
    }
    _write!([1]); // shared session; never evict another viewer
    final init = ByteData.sublistView(await reader.read(24));
    _resize(init.getUint16(0), init.getUint16(2));
    final nameLength = init.getUint32(20);
    if (nameLength > 65536)
      throw const FormatException('VNC name exceeds limit');
    await reader.read(nameLength);
    // 32-bit, depth 24, little endian, true color, B G R padding.
    _write!([
      0,
      0,
      0,
      0,
      32,
      24,
      0,
      1,
      0,
      255,
      0,
      255,
      0,
      255,
      16,
      8,
      0,
      0,
      0,
      0,
    ]);
    final encodings = ByteData(28)
      ..setUint8(0, 2)
      ..setUint16(2, 6)
      ..setInt32(4, 0)
      ..setInt32(8, 1)
      ..setInt32(12, -223)
      ..setInt32(16, -308)
      ..setInt32(20, -239)
      ..setInt32(24, -232);
    _write!(encodings.buffer.asUint8List());
  }

  void _resize(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 8192 * 4096) {
      throw const FormatException('VNC dimensions exceed limit');
    }
    _width = width;
    _height = height;
    _pixels = Uint8List(width * height * 4);
  }

  void _request(bool incremental) {
    if (_closed) return;
    final data = ByteData(10)
      ..setUint8(0, 3)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(6, _width)
      ..setUint16(8, _height);
    _write?.call(data.buffer.asUint8List());
  }

  @override
  void send(List<Object> command) {
    if (_closed) return;
    if (command[0] == 'key') {
      final data = ByteData(8)
        ..setUint8(0, 4)
        ..setUint8(1, command[2] as int)
        ..setUint32(4, command[1] as int);
      _write?.call(data.buffer.asUint8List());
    } else if (command[0] == 'mouse') {
      final data = ByteData(6)
        ..setUint8(0, 5)
        ..setUint8(1, command[3] as int)
        ..setUint16(2, (command[1] as int).clamp(0, _width - 1))
        ..setUint16(4, (command[2] as int).clamp(0, _height - 1));
      _write?.call(data.buffer.asUint8List());
    } else if (command[0] == 'size') {
      final explicit = command.length > 3 && command[3] == true;
      final request = rfbSetDesktopSize(
        command[1] as int,
        command[2] as int,
        _screens,
        supported: _extendedDesktopSize,
      );
      if (request == null) {
        // The server owns the framebuffer; the view only scales it locally.
        if (explicit) {
          _events.add(
            DesktopResizeStatus(
              serverResize: _extendedDesktopSize,
              result: DesktopResizeResult.unsupported,
            ),
          );
        }
        return;
      }
      _resizePending = true;
      _write?.call(request);
    }
  }

  @override
  void paste(String text) {
    if (_closed) return;
    final bytes = latin1.encode(
      text,
    ); // RFC 6143 clipboard; reject lossy Unicode
    if (bytes.length > 65536)
      throw const FormatException('Clipboard is limited to 64 KiB');
    final data = ByteData(8)
      ..setUint8(0, 6)
      ..setUint32(4, bytes.length);
    _write?.call([...data.buffer.asUint8List(), ...bytes]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_frameConsumed?.isCompleted == false) _frameConsumed!.complete();
    await _closeSocket?.call();
    await _reader?.close();
    _pixels = Uint8List(0);
    _write = null;
    unawaited(_events.close());
  }
}

Uint8List vncChallengeResponse(String password, Uint8List challenge) {
  if (challenge.length != 16)
    throw const FormatException('Invalid VNC challenge');
  final key = Uint8List(8);
  final bytes = latin1.encode(password);
  for (var i = 0; i < 8 && i < bytes.length; i++) {
    var value = bytes[i], reverse = 0;
    for (var bit = 0; bit < 8; bit++) {
      reverse = (reverse << 1) | (value & 1);
      value >>= 1;
    }
    key[i] = reverse;
  }
  // EDE with the same key in all three positions is exactly single DES.
  final tripleKey = Uint8List.fromList([...key, ...key, ...key]);
  final cipher = DESedeEngine()..init(true, KeyParameter(tripleKey));
  final result = Uint8List(16);
  cipher.processBlock(challenge, 0, result, 0);
  cipher.processBlock(challenge, 8, result, 8);
  key.fillRange(0, key.length, 0);
  tripleKey.fillRange(0, tripleKey.length, 0);
  return result;
}

class _Reader {
  _Reader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);
  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const [];
  int _offset = 0;
  Future<Uint8List> read(int count) async {
    if (count < 0 || count > 8192 * 4096 * 4)
      throw const FormatException('VNC frame exceeds limit');
    final result = Uint8List(count);
    var position = 0;
    while (position < count) {
      if (_offset == _chunk.length) {
        if (!await _iterator.moveNext())
          throw const FormatException('VNC connection closed');
        _chunk = _iterator.current;
        _offset = 0;
      }
      final n = (count - position).clamp(0, _chunk.length - _offset);
      result.setRange(position, position + n, _chunk, _offset);
      position += n;
      _offset += n;
    }
    return result;
  }

  Future<void> close() => _iterator.cancel();
}

class RfbScreen {
  const RfbScreen({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.flags,
  });
  final int id, x, y, width, height, flags;
}

DesktopResizeResult rfbResizeResult(int status) => switch (status) {
  0 => DesktopResizeResult.applied,
  1 => DesktopResizeResult.prohibited,
  2 => DesktopResizeResult.outOfResources,
  3 => DesktopResizeResult.invalidLayout,
  _ => DesktopResizeResult.invalidLayout,
};

/// SetDesktopSize (type 251) for a single screen, keeping the server's first
/// screen id as rfbproto requires. Returns null when the server did not
/// advertise ExtendedDesktopSize or the size is out of bounds.
Uint8List? rfbSetDesktopSize(
  int width,
  int height,
  List<RfbScreen> screens, {
  required bool supported,
}) {
  if (!supported ||
      width < 200 ||
      height < 200 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 8192 * 4096) {
    return null;
  }
  final id = screens.isEmpty ? 0 : screens.first.id;
  final flags = screens.isEmpty ? 0 : screens.first.flags;
  return (ByteData(24)
        ..setUint8(0, 251)
        ..setUint16(2, width)
        ..setUint16(4, height)
        ..setUint8(6, 1)
        ..setUint32(8, id)
        ..setUint16(12, 0)
        ..setUint16(14, 0)
        ..setUint16(16, width)
        ..setUint16(18, height)
        ..setUint32(20, flags))
      .buffer
      .asUint8List();
}
