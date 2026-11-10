import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'direct/connection.dart';

// Implements the drawing subset used by guacd RDP/VNC with audio/video/GFX
// disabled. Protocol reference: Apache Guacamole 1.6 (Apache-2.0).
class DesktopDisplay extends ChangeNotifier {
  final Map<int, DesktopLayer> layers = {};
  final Map<int, _ImageStream> _streams = {};
  String clipboard = '';
  ui.Image? cursor;
  ui.Offset cursorHotspot = ui.Offset.zero;
  DesktopCursorKind cursorKind = DesktopCursorKind.defaultArrow;
  int _cursorEpoch = 0;
  (DesktopCursor, bool Function())? _pendingCursor;
  bool _decodingCursor = false;
  ui.Offset pointer = ui.Offset.zero;
  bool closed = false;
  ui.Size get size =>
      ui.Size(layer(0).width.toDouble(), layer(0).height.toDouble());
  void Function(List<Object>)? send;

  DesktopLayer layer(int id) {
    if (!layers.containsKey(id) && layers.length >= 256)
      throw const FormatException('Too many desktop layers');
    return layers.putIfAbsent(id, () => DesktopLayer(id));
  }

  void movePointer(ui.Offset value) {
    pointer = value;
    if (!closed) notifyListeners();
  }

  void resetCursor() {
    _cursorEpoch++;
    _pendingCursor = null;
    cursor?.dispose();
    cursor = null;
    cursorKind = DesktopCursorKind.defaultArrow;
    cursorHotspot = ui.Offset.zero;
    if (!closed) notifyListeners();
  }

  /// At most one decode and one newest pending shape. A closed/replaced
  /// connection can never publish a late decoded cursor into its successor.
  Future<void> updateCursor(
    DesktopCursor shape,
    bool Function() isCurrent,
  ) async {
    _pendingCursor = (shape, isCurrent);
    if (_decodingCursor) return;
    _decodingCursor = true;
    try {
      while (!closed && _pendingCursor != null) {
        final (next, current) = _pendingCursor!;
        _pendingCursor = null;
        if (!current()) continue;
        final epoch = _cursorEpoch;
        ui.Image? image;
        if (next.kind == DesktopCursorKind.image) {
          final bytes = next.bgra;
          if (next.width < 1 ||
              next.height < 1 ||
              next.width > 512 ||
              next.height > 512 ||
              next.hotX < 0 ||
              next.hotY < 0 ||
              next.hotX >= next.width ||
              next.hotY >= next.height ||
              bytes == null ||
              bytes.length != next.width * next.height * 4) {
            throw const FormatException('Invalid desktop cursor');
          }
          final done = Completer<ui.Image>();
          // Protocol pixels have straight alpha; Flutter BGRA requires
          // premultiplied channels, including zero RGB for invisible pixels.
          final premultiplied = Uint8List.fromList(bytes);
          for (var i = 0; i < premultiplied.length; i += 4) {
            final alpha = premultiplied[i + 3];
            for (var channel = 0; channel < 3; channel++) {
              premultiplied[i + channel] =
                  (premultiplied[i + channel] * alpha + 127) ~/ 255;
            }
          }
          ui.decodeImageFromPixels(
            premultiplied,
            next.width,
            next.height,
            ui.PixelFormat.bgra8888,
            done.complete,
          );
          image = await done.future;
        }
        if (closed || epoch != _cursorEpoch || !current()) {
          image?.dispose();
          continue;
        }
        cursor?.dispose();
        cursor = image;
        cursorKind = next.kind;
        cursorHotspot = ui.Offset(next.hotX.toDouble(), next.hotY.toDouble());
        notifyListeners();
      }
    } finally {
      _decodingCursor = false;
    }
  }

  /// Apply a native desktop framebuffer update. Without a region, [bgra]
  /// replaces the whole desktop; with one it updates only that rectangle of an
  /// existing desktop of the same size. Caller serializes image decoding.
  Future<void> frame(
    int width,
    int height,
    Uint8List bgra, {
    int x = 0,
    int y = 0,
    int? regionWidth,
    int? regionHeight,
  }) async {
    if (closed) return;
    final rw = regionWidth ?? width, rh = regionHeight ?? height;
    final full = x == 0 && y == 0 && rw == width && rh == height;
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 8192 * 4096 ||
        x < 0 ||
        y < 0 ||
        rw < 1 ||
        rh < 1 ||
        x + rw > width ||
        y + rh > height ||
        bgra.length != rw * rh * 4) {
      throw const FormatException('Invalid desktop frame');
    }
    final base = layer(0);
    if (!full && (base.width != width || base.height != height)) {
      throw const FormatException('Partial frame for a different desktop size');
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bgra,
      rw,
      rh,
      ui.PixelFormat.bgra8888,
      done.complete,
    );
    final image = await done.future;
    try {
      if (closed) return;
      if (base.width != width || base.height != height) {
        base.resize(width, height);
      }
      base.canvas.drawImage(
        image,
        ui.Offset(x.toDouble(), y.toDouble()),
        ui.Paint()..blendMode = ui.BlendMode.src,
      );
      base.snapshot();
      notifyListeners();
    } finally {
      image.dispose();
    }
  }

  Future<void> instruction(List<String> v) async {
    if (closed) return;
    int n(int i) => int.parse(v[i]);
    double d(int i) => double.parse(v[i]);
    ui.Rect rect(int i) => ui.Rect.fromLTWH(d(i), d(i + 1), d(i + 2), d(i + 3));
    ui.Color color(int i) =>
        ui.Color.fromARGB(n(i + 3), n(i), n(i + 1), n(i + 2));
    switch (v[0]) {
      case 'size':
        final w = n(2), h = n(3);
        if (w < 0 ||
            h < 0 ||
            w > 4096 ||
            h > 4096 ||
            layers.values
                    .where((l) => l.id != n(1))
                    .fold<int>(w * h, (sum, l) => sum + l.width * l.height) >
                64 * 1024 * 1024) {
          throw const FormatException('Desktop dimensions exceed limit');
        }
        layer(n(1)).resize(w, h);
      case 'rect':
        _ensureBufferBounds(n(1), (d(2) + d(4)).ceil(), (d(3) + d(5)).ceil());
        layer(n(1)).pathForDrawing.addRect(rect(2));
      case 'start':
        _ensureBufferBounds(n(1), d(2).ceil(), d(3).ceil());
        layer(n(1)).pathForDrawing.moveTo(d(2), d(3));
      case 'line':
        _ensureBufferBounds(n(1), d(2).ceil(), d(3).ceil());
        layer(n(1)).pathForDrawing.lineTo(d(2), d(3));
      case 'curve':
        _ensureBufferBounds(n(1), d(6).ceil(), d(7).ceil());
        layer(n(1)).pathForDrawing.cubicTo(d(2), d(3), d(4), d(5), d(6), d(7));
      case 'arc':
        _ensureBufferBounds(n(1), d(2).ceil(), d(3).ceil());
        var sweep = d(6) - d(5);
        if (n(7) != 0 && sweep > 0) sweep -= 2 * math.pi;
        if (n(7) == 0 && sweep < 0) sweep += 2 * math.pi;
        layer(n(1)).pathForDrawing.arcTo(
          ui.Rect.fromCircle(center: ui.Offset(d(2), d(3)), radius: d(4)),
          d(5),
          sweep,
          false,
        );
      case 'close':
        layer(n(1)).path.close();
      case 'cfill':
        final l = layer(n(2));
        l.canvas.drawPath(
          l.path,
          ui.Paint()
            ..color = color(3)
            ..blendMode = _blend(n(1)),
        );
        l.pathConsumed = true;
      case 'cstroke':
        final l = layer(n(2));
        l.canvas.drawPath(
          l.path,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = d(5)
            ..strokeCap = [
              ui.StrokeCap.butt,
              ui.StrokeCap.round,
              ui.StrokeCap.square,
            ][n(3)]
            ..strokeJoin = [
              ui.StrokeJoin.bevel,
              ui.StrokeJoin.miter,
              ui.StrokeJoin.round,
            ][n(4)]
            ..strokeMiterLimit = l.miter
            ..color = color(6)
            ..blendMode = _blend(n(1)),
        );
        l.pathConsumed = true;
      case 'clip':
        final l = layer(n(1));
        final path = ui.Path.from(l.path);
        l.context((c) => c.clipPath(path));
        l.pathConsumed = true;
      case 'push':
        layer(n(1)).context((c) => c.save());
      case 'pop':
        layer(n(1)).context((c) {
          if (c.getSaveCount() > 2) c.restore();
        });
      case 'reset':
        layer(n(1)).reset();
      case 'identity':
        // guacd's raster RDP/VNC paths do not apply canvas transforms.
        layer(n(1)).reset();
      case 'transform':
        final m = Float64List.fromList([
          d(2),
          d(3),
          0,
          0,
          d(4),
          d(5),
          0,
          0,
          0,
          0,
          1,
          0,
          d(6),
          d(7),
          0,
          1,
        ]);
        layer(n(1)).context((c) => c.transform(m));
      case 'set':
        if (v[2] == 'miter-limit') layer(n(1)).miter = d(3);
      case 'copy':
        _ensureBufferBounds(n(7), (d(8) + d(4)).ceil(), (d(9) + d(5)).ceil());
        final source = layer(n(1)).snapshot();
        if (source != null)
          layer(n(7)).canvas.drawImageRect(
            source,
            rect(2),
            ui.Rect.fromLTWH(d(8), d(9), d(4), d(5)),
            ui.Paint()
              ..blendMode = _blend(n(6))
              ..filterQuality = ui.FilterQuality.none,
          );
      case 'transfer':
        await _transfer(v);
      case 'lfill':
      case 'lstroke':
        final l = layer(n(2)), source = layer(n(3)).snapshot();
        if (source != null)
          l.canvas.drawPath(
            l.path,
            ui.Paint()
              ..style = v[0] == 'lstroke'
                  ? ui.PaintingStyle.stroke
                  : ui.PaintingStyle.fill
              ..blendMode = _blend(n(1))
              ..shader = ui.ImageShader(
                source,
                ui.TileMode.repeated,
                ui.TileMode.repeated,
                Float64List.fromList([
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                ]),
              ),
          );
        l.pathConsumed = true;
      case 'img':
        if (_streams.length >= 32 ||
            !{'image/png', 'image/jpeg'}.contains(v[4]))
          throw const FormatException('Unsupported desktop image');
        _streams[n(1)] = _ImageStream(n(3), n(2), n(5), n(6));
      case 'clipboard':
        if (v[2] != 'text/plain' || _streams.length >= 32) {
          send?.call(['ack', n(1), 'Unsupported', 256]);
          break;
        }
        _streams[n(1)] = _ImageStream(null, 0, 0, 0);
      case 'blob':
        final stream = _streams[n(1)];
        if (stream == null) break;
        final bytes = base64Decode(v[2]);
        if (stream.bytes.length + bytes.length >
            (stream.layer == null ? 65536 : 16 * 1024 * 1024))
          throw const FormatException('Desktop stream exceeds limit');
        stream.bytes.add(bytes);
        send?.call(['ack', n(1), 'OK', 0]);
      case 'end':
        final stream = _streams.remove(n(1));
        if (stream == null) break;
        final bytes = stream.bytes.takeBytes();
        if (stream.layer == null) {
          clipboard = utf8.decode(bytes, allowMalformed: true);
        } else {
          await _image(bytes, stream.layer!, stream.mask, stream.x, stream.y);
        }
      case 'png':
      case 'jpeg':
        await _image(base64Decode(v[5]), n(2), n(1), n(3), n(4));
      case 'cursor':
        final source = layer(n(3)).snapshot();
        cursor?.dispose();
        cursor = null;
        if (source != null &&
            n(6) > 0 &&
            n(7) > 0 &&
            n(6) <= 512 &&
            n(7) <= 512) {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawImageRect(
            source,
            rect(4),
            ui.Rect.fromLTWH(0, 0, d(6), d(7)),
            ui.Paint(),
          );
          final picture = recorder.endRecording();
          cursor = picture.toImageSync(n(6), n(7));
          picture.dispose();
        }
        cursorHotspot = ui.Offset(d(1), d(2));
        cursorKind = cursor == null
            ? DesktopCursorKind.hidden
            : DesktopCursorKind.image;
      case 'mouse':
        movePointer(ui.Offset(d(1), d(2)));
      case 'move':
        if (n(1) <= 0 || n(2) < 0 || n(1) == n(2)) break;
        final l = layer(n(1));
        var ancestor = n(2);
        final seen = <int>{l.id};
        while (ancestor != 0) {
          if (!seen.add(ancestor))
            throw const FormatException('Desktop layer cycle');
          ancestor = layer(ancestor).parent;
        }
        l.parent = n(2);
        l.offset = ui.Offset(d(3), d(4));
        l.z = n(5);
      case 'shade':
        layer(n(1)).opacity = n(2).clamp(0, 255) / 255;
      case 'distort':
        layer(n(1)).transform = Float64List.fromList([
          d(2),
          d(3),
          0,
          0,
          d(4),
          d(5),
          0,
          0,
          0,
          0,
          1,
          0,
          d(6),
          d(7),
          0,
          1,
        ]);
      case 'dispose':
        if (n(1) != 0) layers.remove(n(1))?.dispose();
      case 'sync':
        for (final l in layers.values) {
          l.snapshot();
        }
        notifyListeners();
        send?.call(['sync', v[1]]);
      case 'name':
      case 'ready':
      case 'nop':
      case 'ack':
      case 'msg':
        break;
      case 'file':
      case 'pipe':
      case 'audio':
      case 'video':
      case 'argv':
        send?.call(['ack', v[1], 'Unsupported', 256]);
      case 'error':
        throw StateError(
          currentL10n.remoteDesktopConnectionFailedCodeLast(v.last),
        );
      case 'disconnect':
        throw StateError(currentL10n.remoteDesktopDisconnected);
      default:
        throw FormatException(
          'Unsupported desktop instruction: ${RegExp(r"^[a-z]{1,16}$").hasMatch(v[0]) ? v[0] : "invalid"}',
        );
    }
  }

  Future<void> _image(Uint8List bytes, int id, int mask, int x, int y) async {
    final dimensions = desktopImageDimensions(bytes);
    if (dimensions.$1 < 1 ||
        dimensions.$2 < 1 ||
        dimensions.$1 > 4096 ||
        dimensions.$2 > 4096) {
      throw const FormatException('Image dimensions exceed limit');
    }
    final codec = await ui.instantiateImageCodec(bytes);
    ui.Image? image;
    try {
      image = (await codec.getNextFrame()).image;
      if (!closed) {
        _ensureBufferBounds(id, x + image.width, y + image.height);
        layer(id).canvas.drawImage(
          image,
          ui.Offset(x.toDouble(), y.toDouble()),
          ui.Paint()..blendMode = _blend(mask),
        );
      }
    } finally {
      image?.dispose();
      codec.dispose();
    }
  }

  void _ensureBufferBounds(int id, int width, int height) {
    final l = layer(id);
    if (id >= 0 || (width <= l.width && height <= l.height)) return;
    final w = math.max(width, l.width), h = math.max(height, l.height);
    if (w > 4096 ||
        h > 4096 ||
        layers.values
                .where((v) => v.id != id)
                .fold<int>(w * h, (sum, v) => sum + v.width * v.height) >
            64 * 1024 * 1024) {
      throw const FormatException('Desktop buffer exceeds limit');
    }
    l.resize(w, h);
  }

  Future<void> _transfer(List<String> v) async {
    final a = v.skip(1).map(int.parse).toList();
    _ensureBufferBounds(a[6], a[7] + a[3], a[8] + a[4]);
    final src = layer(a[0]).snapshot(), dst = layer(a[6]).snapshot();
    if (src == null || dst == null || a[5] == 5) return;
    final w = a[3], h = a[4], fn = a[5];
    if (w <= 0 || h <= 0 || w * h > 16 * 1024 * 1024 || fn < 0 || fn > 15)
      throw const FormatException('Invalid pixel transfer');
    final s = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    final t = await dst.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (s == null || t == null || closed) return;
    final bytes = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final sx = a[1] + x, sy = a[2] + y, dx = a[7] + x, dy = a[8] + y;
        final out = (y * w + x) * 4;
        if (sx < 0 ||
            sy < 0 ||
            dx < 0 ||
            dy < 0 ||
            sx >= src.width ||
            sy >= src.height ||
            dx >= dst.width ||
            dy >= dst.height)
          continue;
        for (var c = 0; c < 3; c++) {
          final b = s.getUint8((sy * src.width + sx) * 4 + c),
              d = t.getUint8((dy * dst.width + dx) * 4 + c);
          // ROP truth table order: source/destination 11,10,01,00.
          bytes[out + c] =
              ((fn & 1 != 0 ? b & d : 0) |
                  (fn & 2 != 0 ? b & ~d : 0) |
                  (fn & 4 != 0 ? ~b & d : 0) |
                  (fn & 8 != 0 ? ~b & ~d : 0)) &
              255;
        }
        bytes[out + 3] = 255;
      }
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      w,
      h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final image = await done.future;
    if (!closed)
      layer(a[6]).canvas.drawImage(
        image,
        ui.Offset(a[7].toDouble(), a[8].toDouble()),
        ui.Paint()..blendMode = ui.BlendMode.src,
      );
    image.dispose();
  }

  void paint(ui.Canvas canvas, {bool includeCursor = true}) {
    void draw(int id, Set<int> ancestors) {
      final l = layers[id];
      if (l == null || l.opacity <= 0 || !ancestors.add(id)) return;
      canvas.save();
      canvas.translate(l.offset.dx, l.offset.dy);
      if (l.transform != null) canvas.transform(l.transform!);
      // Opaque desktop layers can draw directly. An unconditional saveLayer
      // allocates an extra full-size render target even for the root screen.
      if (l.opacity < 1) {
        canvas.saveLayer(
          null,
          ui.Paint()..color = ui.Color.fromRGBO(255, 255, 255, l.opacity),
        );
      }
      if (l.image != null)
        canvas.drawImage(l.image!, ui.Offset.zero, ui.Paint());
      final children =
          layers.values.where((c) => c.id > 0 && c.parent == id).toList()
            ..sort((a, b) => a.z.compareTo(b.z));
      for (final c in children) {
        draw(c.id, Set.of(ancestors));
      }
      if (l.opacity < 1) canvas.restore();
      canvas.restore();
    }

    draw(0, {});
    if (includeCursor && cursor != null)
      canvas.drawImage(cursor!, pointer - cursorHotspot, ui.Paint());
  }

  /// Cursor size is local UI size, independent of framebuffer zoom. Shape
  /// alpha and hotspot stay intact; SYSPTR_NULL must remain invisible.
  void paintPointer(ui.Canvas canvas, ui.Offset position) {
    if (cursorKind == DesktopCursorKind.hidden) return;
    if (cursor != null) {
      canvas.drawImage(cursor!, position - cursorHotspot, ui.Paint());
      return;
    }
    final arrow = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(0, 22)
      ..lineTo(6, 16)
      ..lineTo(10, 25)
      ..lineTo(14, 23)
      ..lineTo(10, 14)
      ..lineTo(19, 14)
      ..close();
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.drawShadow(arrow, const ui.Color(0x88000000), 1, true);
    canvas.drawPath(
      arrow,
      ui.Paint()
        ..color = const ui.Color(0xff000000)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.drawPath(arrow, ui.Paint()..color = const ui.Color(0xffffffff));
    canvas.restore();
  }

  @override
  void dispose() {
    closed = true;
    _cursorEpoch++;
    _pendingCursor = null;
    send = null;
    for (final l in layers.values) {
      l.dispose();
    }
    layers.clear();
    _streams.clear();
    cursor?.dispose();
    cursor = null;
    super.dispose();
  }
}

/// Read bounds before decoding; ImageDescriptor metadata is not implemented
/// by Flutter Web. Only the two image formats advertised to guacd are accepted.
(int, int) desktopImageDimensions(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[12] == 73 &&
      bytes[13] == 72 &&
      bytes[14] == 68 &&
      bytes[15] == 82) {
    return (data.getUint32(16), data.getUint32(20));
  }
  if (bytes.length >= 4 && bytes[0] == 255 && bytes[1] == 216) {
    var pos = 2;
    while (pos + 3 < bytes.length) {
      if (bytes[pos++] != 255) break;
      while (pos < bytes.length && bytes[pos] == 255) {
        pos++;
      }
      if (pos >= bytes.length) break;
      final marker = bytes[pos++];
      if (marker == 217 || marker == 218) break;
      if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
      if (pos + 2 > bytes.length) break;
      final length = data.getUint16(pos);
      if (length < 2 || pos + length > bytes.length) break;
      if ({
            192,
            193,
            194,
            195,
            197,
            198,
            199,
            201,
            202,
            203,
            205,
            206,
            207,
          }.contains(marker) &&
          length >= 8) {
        return (data.getUint16(pos + 5), data.getUint16(pos + 3));
      }
      pos += length;
    }
  }
  throw const FormatException('Unsupported desktop image encoding');
}

ui.BlendMode _blend(int mask) => switch (mask) {
  0 => ui.BlendMode.clear,
  1 => ui.BlendMode.dstIn,
  2 => ui.BlendMode.dstOut,
  4 => ui.BlendMode.srcIn,
  6 => ui.BlendMode.srcATop,
  8 => ui.BlendMode.srcOut,
  9 => ui.BlendMode.dstATop,
  10 => ui.BlendMode.xor,
  11 => ui.BlendMode.dstOver,
  12 => ui.BlendMode.src,
  14 => ui.BlendMode.srcOver,
  15 => ui.BlendMode.plus,
  _ => throw const FormatException('Unsupported desktop composite mask'),
};

class _ImageStream {
  _ImageStream(this.layer, this.mask, this.x, this.y);
  final int? layer;
  final int mask, x, y;
  final bytes = BytesBuilder(copy: false);
}

class DesktopLayer {
  DesktopLayer(this.id);
  final int id;
  int width = 1, height = 1, parent = 0, z = 0;
  double opacity = 1, miter = 10;
  ui.Offset offset = ui.Offset.zero;
  Float64List? transform;
  ui.Path path = ui.Path();
  bool pathConsumed = true;
  ui.Image? image;
  ui.PictureRecorder? _recorder;
  ui.Canvas? _canvas;
  final List<void Function(ui.Canvas)> _context = [];
  ui.Path get pathForDrawing {
    if (pathConsumed) {
      path = ui.Path();
      pathConsumed = false;
    }
    return path;
  }

  ui.Canvas get canvas {
    if (_canvas == null) {
      _recorder = ui.PictureRecorder();
      _canvas = ui.Canvas(_recorder!);
      if (image != null)
        _canvas!.drawImage(
          image!,
          ui.Offset.zero,
          ui.Paint()..blendMode = ui.BlendMode.src,
        );
      _canvas!.save();
      for (final op in _context) {
        op(_canvas!);
      }
    }
    return _canvas!;
  }

  void context(void Function(ui.Canvas) op) {
    if (_context.length >= 4096)
      throw const FormatException('Desktop context exceeds limit');
    op(canvas);
    _context.add(op);
  }

  ui.Image? snapshot() {
    if (_recorder != null) {
      final picture = _recorder!.endRecording();
      final next = picture.toImageSync(math.max(1, width), math.max(1, height));
      picture.dispose();
      image?.dispose();
      image = next;
      _recorder = null;
      _canvas = null;
    }
    return image;
  }

  void resize(int w, int h) {
    snapshot();
    width = w;
    height = h;
    reset();
    final _ = canvas;
  }

  void reset() {
    if (_canvas != null) {
      while (_canvas!.getSaveCount() > 1) {
        _canvas!.restore();
      }
    }
    _canvas?.save();
    _context.clear();
    path = ui.Path();
    pathConsumed = true;
  }

  void dispose() {
    if (_recorder != null) _recorder!.endRecording().dispose();
    image?.dispose();
    image = null;
    _recorder = null;
    _canvas = null;
  }
}
