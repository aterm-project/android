import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../storage/wallpaper_store.dart';
import 'app_theme.dart';

// ---------------------------------------------------------------------------
// Limits. The image is user content from the local device; it is bounded
// before decoding and decoded at a bounded size once, then shared by every
// window/pane layer.

/// Largest accepted encoded image (bytes copied into app-owned storage).
const wallpaperMaxEncodedBytes = 16 * 1024 * 1024;

/// Largest accepted source side and pixel count, checked from the header
/// before any decode (decompression-bomb guard).
const wallpaperMaxSourceSide = 12000;
const wallpaperMaxSourcePixels = 40000000;

/// Longest side of the decoded image kept in memory.
const wallpaperMaxDecodedSide = 2560;

/// Blur slider range (logical pixels at a 1280 px reference width).
const wallpaperMaxBlur = 24.0;
const wallpaperDefaultBlur = 8.0;

/// Terminal background opacity while a wallpaper is shown behind it. Only the
/// default background cell fill becomes translucent; ANSI/custom foreground
/// and explicit cell background colors are unchanged. 0.80 keeps the default
/// text of both built-in terminal palettes at >= 4.5:1 over ANY image (pure
/// white and pure black are the bounds; worst case 5.4:1) while 20% of the
/// wallpaper still shows through.
const wallpaperTerminalOpacity = 0.80;

const wallpaperAllowedExtensions = ['png', 'jpg', 'jpeg', 'webp'];

/// Whole window: one image spans the window. Panes: each terminal pane (and
/// the standalone terminal window) paints its own cover-fitted image.
enum WallpaperLayoutMode {
  window('window'),
  panes('panes');

  const WallpaperLayoutMode(this.code);
  final String code;

  static WallpaperLayoutMode parse(Object? value) {
    for (final mode in values) {
      if (mode.code == value) return mode;
    }
    return WallpaperLayoutMode.window;
  }
}

double sanitizeWallpaperBlur(Object? value) {
  if (value is! num || !value.isFinite) return wallpaperDefaultBlur;
  final clamped = value.toDouble().clamp(0.0, wallpaperMaxBlur);
  return (clamped * 2).roundToDouble() / 2;
}

@immutable
class WallpaperPreferences {
  const WallpaperPreferences({
    this.imageId,
    this.mode = WallpaperLayoutMode.window,
    this.blur = wallpaperDefaultBlur,
  });

  /// Random id of the app-owned image copy; never a path or file name.
  final String? imageId;
  final WallpaperLayoutMode mode;
  final double blur;

  /// Strict, sanitizing parse. Anything invalid falls back field by field.
  static WallpaperPreferences parse(String? raw) {
    if (raw == null || raw.length > wallpaperSettingsMaxLength) {
      return const WallpaperPreferences();
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const WallpaperPreferences();
    }
    if (decoded is! Map || decoded['v'] != 1) {
      return const WallpaperPreferences();
    }
    final image = decoded['image'];
    return WallpaperPreferences(
      imageId: image is String && isValidWallpaperImageId(image) ? image : null,
      mode: WallpaperLayoutMode.parse(decoded['mode']),
      blur: sanitizeWallpaperBlur(decoded['blur'] ?? wallpaperDefaultBlur),
    );
  }

  /// Whether [raw] is a well-formed v1 record whose image reference is known
  /// (absent or a valid id). Only then may stale image copies be cleaned.
  static bool isTrusted(String raw) {
    if (raw.length > wallpaperSettingsMaxLength) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return false;
    }
    if (decoded is! Map || decoded['v'] != 1) return false;
    final image = decoded['image'];
    return image == null || (image is String && isValidWallpaperImageId(image));
  }

  String encode() => jsonEncode({
    'v': 1,
    'image': ?imageId,
    'mode': mode.code,
    'blur': blur,
  });
}

// ---------------------------------------------------------------------------
// Validation.

enum WallpaperImageFormat { png, jpeg, webp }

enum WallpaperImageError {
  /// Larger than [wallpaperMaxEncodedBytes].
  tooLarge,

  /// Not PNG, JPEG or still WebP.
  unsupported,

  /// Header or image data is damaged.
  corrupt,

  /// Header dimensions exceed the source limits.
  dimensions,

  /// The app-owned copy could not be written or read.
  storage,
}

class WallpaperImageException implements Exception {
  const WallpaperImageException(this.error);
  final WallpaperImageError error;

  @override
  String toString() => 'WallpaperImageException(${error.name})';
}

@immutable
class WallpaperImageInfo {
  const WallpaperImageInfo(this.format, this.width, this.height);
  final WallpaperImageFormat format;
  final int width;
  final int height;
}

/// Identifies the format by its signature (never by file name) and reads the
/// dimensions from the header, without decoding pixels.
WallpaperImageInfo wallpaperInspectImage(Uint8List bytes) {
  if (bytes.length > wallpaperMaxEncodedBytes) {
    throw const WallpaperImageException(WallpaperImageError.tooLarge);
  }
  final info = _inspectHeader(bytes);
  if (info.width <= 0 || info.height <= 0) {
    throw const WallpaperImageException(WallpaperImageError.corrupt);
  }
  if (info.width > wallpaperMaxSourceSide ||
      info.height > wallpaperMaxSourceSide ||
      info.width * info.height > wallpaperMaxSourcePixels) {
    throw const WallpaperImageException(WallpaperImageError.dimensions);
  }
  return info;
}

WallpaperImageInfo _inspectHeader(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  bool ascii(int i, String s) {
    if (i + s.length > b.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (b[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  const corrupt = WallpaperImageException(WallpaperImageError.corrupt);
  const unsupported = WallpaperImageException(WallpaperImageError.unsupported);

  // PNG: signature + IHDR first chunk.
  const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (b.length >= 8 &&
      Iterable<int>.generate(8).every((i) => b[i] == pngSignature[i])) {
    if (b.length < 33 || !ascii(12, 'IHDR')) throw corrupt;
    return WallpaperImageInfo(WallpaperImageFormat.png, be32(16), be32(20));
  }

  // JPEG: walk markers to the first start-of-frame.
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) throw corrupt;
      while (i < b.length && b[i] == 0xFF) {
        i++;
      }
      if (i >= b.length) break;
      final marker = b[i++];
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
      if (marker == 0xD9 || marker == 0xDA) break;
      if (i + 2 > b.length) break;
      final length = be16(i);
      if (length < 2) throw corrupt;
      final sof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (sof) {
        if (i + 7 > b.length) throw corrupt;
        return WallpaperImageInfo(
          WallpaperImageFormat.jpeg,
          be16(i + 5),
          be16(i + 3),
        );
      }
      i += length;
    }
    throw corrupt;
  }

  // WebP (RIFF): still images only.
  if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) {
    if (b.length < 30) throw corrupt;
    if (ascii(12, 'VP8 ')) {
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) throw corrupt;
      return WallpaperImageInfo(
        WallpaperImageFormat.webp,
        le16(26) & 0x3FFF,
        le16(28) & 0x3FFF,
      );
    }
    if (ascii(12, 'VP8L')) {
      if (b[20] != 0x2F) throw corrupt;
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return WallpaperImageInfo(
        WallpaperImageFormat.webp,
        (bits & 0x3FFF) + 1,
        ((bits >> 14) & 0x3FFF) + 1,
      );
    }
    if (ascii(12, 'VP8X')) {
      if ((b[20] & 0x02) != 0) throw unsupported; // animated
      return WallpaperImageInfo(
        WallpaperImageFormat.webp,
        le24(24) + 1,
        le24(27) + 1,
      );
    }
    throw corrupt;
  }
  throw unsupported;
}

/// Validates [bytes] and decodes the first frame with its longest side
/// bounded by [wallpaperMaxDecodedSide]. Throws [WallpaperImageException].
Future<ui.Image> decodeWallpaperImage(Uint8List bytes) async {
  wallpaperInspectImage(bytes);
  ui.Codec codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        if (width <= 0 ||
            height <= 0 ||
            width > wallpaperMaxSourceSide ||
            height > wallpaperMaxSourceSide ||
            width * height > wallpaperMaxSourcePixels) {
          throw const WallpaperImageException(WallpaperImageError.dimensions);
        }
        if (math.max(width, height) <= wallpaperMaxDecodedSide) {
          return const ui.TargetImageSize();
        }
        return width >= height
            ? const ui.TargetImageSize(width: wallpaperMaxDecodedSide)
            : const ui.TargetImageSize(height: wallpaperMaxDecodedSide);
      },
    );
  } on WallpaperImageException {
    rethrow;
  } on Object {
    throw const WallpaperImageException(WallpaperImageError.corrupt);
  }
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    if (image.width <= 0 ||
        image.height <= 0 ||
        math.max(image.width, image.height) > wallpaperMaxDecodedSide + 1) {
      image.dispose();
      throw const WallpaperImageException(WallpaperImageError.dimensions);
    }
    return image;
  } on WallpaperImageException {
    rethrow;
  } on Object {
    throw const WallpaperImageException(WallpaperImageError.corrupt);
  } finally {
    codec.dispose();
  }
}

/// Image-space blur sigma for slider value [blur] on [image].
double _imageSigma(ui.Image image, double blur) =>
    blur * math.max(image.width, image.height) / 1280;

/// Renders a blurred copy once so steady-state frames draw a plain image (no
/// per-frame filter over terminal output). Heavier blurs are baked at half
/// resolution, which is visually identical after the blur.
Future<ui.Image> bakeWallpaperBlur(ui.Image source, double blur) async {
  final scale = blur >= 4 ? 0.5 : 1.0;
  final width = math.max(1, (source.width * scale).round());
  final height = math.max(1, (source.height * scale).round());
  final sigma = _imageSigma(source, blur) * scale;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Draw slightly larger than the output so the blur's transparent edge
  // falls outside the bitmap.
  final margin = sigma * 2;
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(-margin, -margin, width + margin * 2, height + margin * 2),
    Paint()
      ..filterQuality = FilterQuality.medium
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

/// Relative-luminance range (0..1) of an image's 16x16 averaged thumbnail:
/// its darkest and brightest regions of at least ~1/256 of the area.
@immutable
class WallpaperLuminance {
  const WallpaperLuminance(this.min, this.max);

  /// Unknown content: assume both extremes (strongest scrim).
  static const unknown = WallpaperLuminance(0, 1);

  final double min;
  final double max;

  @override
  bool operator ==(Object other) =>
      other is WallpaperLuminance && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);
}

/// Measures [image] once (tiny GPU downscale + one 1 KiB pixel read).
Future<WallpaperLuminance> measureWallpaperLuminance(ui.Image image) async {
  const side = 16;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    const Rect.fromLTWH(0, 0, side * 1.0, side * 1.0),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final thumbnail = await picture.toImage(side, side);
  picture.dispose();
  try {
    final data = await thumbnail.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return WallpaperLuminance.unknown;
    var low = 1.0, high = 0.0;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final y = Color.fromARGB(
        255,
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      ).computeLuminance();
      low = math.min(low, y);
      high = math.max(high, y);
    }
    return low > high ? WallpaperLuminance.unknown : WallpaperLuminance(low, high);
  } finally {
    thumbnail.dispose();
  }
}

/// Default text and secondary (muted) text must reach this contrast over the
/// scrimmed wallpaper (WCAG AA for normal text).
const wallpaperChromeMinContrast = 4.5;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

Color _grayOfLuminance(double y) {
  final v = y <= 0.0031308 ? 12.92 * y : 1.055 * math.pow(y, 1 / 2.4) - 0.055;
  final c = (v.clamp(0.0, 1.0) * 255).round();
  return Color.fromARGB(255, c, c, c);
}

/// Readable, theme-aware scrim alpha for UI text drawn straight over the
/// wallpaper (window mode: the scaffold; panes: pane chrome, file lists).
/// Starts at the historic floor (window .58/.64, pane .38/.46) and rises only
/// as far as the image's worst extreme for this theme needs (brightest region
/// for dark UI, darkest for light UI) so `text` and `muted` keep
/// [wallpaperChromeMinContrast]. Images that suit the theme stay as visible
/// as before; clashing extremes get a stronger scrim.
double wallpaperScrimAlpha(
  AppPalette palette,
  WallpaperLuminance luminance, {
  required bool pane,
}) {
  final floor = pane
      ? (palette.isDark ? .38 : .46)
      : (palette.isDark ? .58 : .64);
  final backdrop = _grayOfLuminance(
    palette.isDark ? luminance.max : luminance.min,
  );
  for (var alpha = floor; alpha < 1; alpha += .01) {
    final surface = Color.alphaBlend(
      palette.background.withValues(alpha: alpha),
      backdrop,
    );
    if (_contrast(palette.text, surface) >= wallpaperChromeMinContrast + .1 &&
        _contrast(palette.muted, surface) >= wallpaperChromeMinContrast + .1) {
      return alpha;
    }
  }
  return 1;
}

String _newImageId() {
  final random = math.Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

// ---------------------------------------------------------------------------
// Controller.

enum WallpaperStatus { none, loading, ready, missing, failed }

/// Owns the device wallpaper preference and the single shared decoded image.
/// Separate from the UI theme enum/store. Changing any value only repaints the
/// wallpaper layers; it never rebuilds or re-parents window/pane content.
class WallpaperController extends ChangeNotifier {
  WallpaperController({
    Future<ui.Image> Function(ui.Image source, double blur)? bakeBlur,
  }) : _bakeBlur = bakeBlur ?? bakeWallpaperBlur;

  final Future<ui.Image> Function(ui.Image source, double blur) _bakeBlur;

  static WallpaperController? _instance;

  /// Process-wide controller used by the app roots (one per window process).
  static WallpaperController get instance =>
      _instance ??= WallpaperController();

  @visibleForTesting
  static set debugInstance(WallpaperController? controller) =>
      _instance = controller;

  /// The controller installed by the nearest [WallpaperWindowHost], else the
  /// process instance. Does not register a rebuild dependency.
  static WallpaperController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_WallpaperVisibility>()?.controller ??
      instance;

  WallpaperStore? _store;
  WallpaperLayoutMode _mode = WallpaperLayoutMode.window;
  double _blur = wallpaperDefaultBlur;
  String? _imageId;
  ui.Image? _image;
  ui.Image? _baked;
  double? _bakedBlur;
  WallpaperStatus _status = WallpaperStatus.none;
  WallpaperImageError? _lastError;
  bool _busy = false;
  bool _writeFailed = false;
  bool _disposed = false;
  int _imageGeneration = 0;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  Timer? _bakeTimer;
  bool _baking = false;
  // Image + blur whose bake failed; not retried until either changes.
  ui.Image? _bakeFailedImage;
  double? _bakeFailedBlur;

  /// Whether the saved image reference is known. False after an unreadable,
  /// timed-out or untrusted settings record: then no image copy is cleaned
  /// and mode/blur changes are not persisted (they would drop the saved
  /// reference) until the user explicitly chooses or removes an image.
  bool _settingsKnown = true;
  Future<void>? _restoring;

  WallpaperLayoutMode get mode => _mode;
  double get blur => _blur;
  WallpaperStatus get status => _status;
  WallpaperImageError? get lastError => _lastError;

  /// Whether an image is configured (it may still be loading or missing).
  bool get hasImage => _imageId != null;

  /// Whether a decoded wallpaper is available to paint.
  bool get active => _image != null;
  bool get busy => _busy;
  bool get writeFailed => _writeFailed;
  ui.Image? get image => _image;

  /// Luminance range of [image], measured once per image.
  WallpaperLuminance get luminance => _luminance;
  WallpaperLuminance _luminance = WallpaperLuminance.unknown;

  /// The pre-blurred image when it matches the current [blur], else null.
  ui.Image? get bakedImage => _bakedBlur == _blur ? _baked : null;

  @visibleForTesting
  Future<void> get debugRestoring => _restoring ?? Future<void>.value();

  @visibleForTesting
  Future<void> get debugIdle async {
    await _writeChain;
    while (_baking || (_bakeTimer?.isActive ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Reads the preference and starts decoding the stored image in the
  /// background (startup is never blocked on decode). [cleanupStale] removes
  /// orphaned owned images; only the main window passes it, so a child window
  /// can never race a parent's in-progress replace.
  Future<void> load(WallpaperStore store, {bool cleanupStale = false}) async {
    _store = store;
    String? raw;
    var readable = true;
    try {
      raw = await store.readSettings().timeout(const Duration(seconds: 2));
    } on Object {
      readable = false;
    }
    if (_disposed) return;
    // Corrupt/untrusted records still fall back visually field by field.
    final preferences = readable
        ? WallpaperPreferences.parse(raw)
        : const WallpaperPreferences();
    _settingsKnown =
        readable && (raw == null || WallpaperPreferences.isTrusted(raw));
    _mode = preferences.mode;
    _blur = preferences.blur;
    _imageId = preferences.imageId;
    final generation = ++_imageGeneration;
    _setImage(null);
    _status = _imageId == null ? WallpaperStatus.none : WallpaperStatus.loading;
    notifyListeners();
    // Only a successfully read, trusted record says which copy to keep.
    if (cleanupStale && _settingsKnown && raw != null) {
      final keep = _imageId;
      unawaited(_enqueue(() => store.deleteImagesExcept(keep)));
    }
    final id = _imageId;
    _restoring = id == null ? null : _restore(store, id, generation);
  }

  Future<void> _restore(WallpaperStore store, String id, int generation) async {
    ui.Image? decoded;
    var luminance = WallpaperLuminance.unknown;
    var status = WallpaperStatus.ready;
    try {
      final bytes = await store.readImage(id, maxBytes: wallpaperMaxEncodedBytes);
      if (bytes == null) {
        status = WallpaperStatus.missing;
      } else {
        decoded = await decodeWallpaperImage(bytes);
        luminance = await _measure(decoded);
      }
    } on Object {
      status = WallpaperStatus.failed;
    }
    if (_disposed || generation != _imageGeneration) {
      decoded?.dispose();
      return;
    }
    _status = status;
    _setImage(decoded, luminance);
    notifyListeners();
  }

  /// Validates, decodes and stores a copy of [bytes] as the wallpaper.
  /// Returns null on success. The previous image stays on any failure.
  Future<WallpaperImageError?> setImageBytes(Uint8List bytes) async {
    if (_busy || _disposed) return null;
    _busy = true;
    _lastError = null;
    notifyListeners();
    final generation = ++_imageGeneration;
    bool superseded() => _disposed || generation != _imageGeneration;
    final store = _store;
    ui.Image? decoded;
    final id = _newImageId();
    try {
      decoded = await decodeWallpaperImage(bytes);
      final luminance = await _measure(decoded);
      if (superseded()) return null;
      if (store != null) {
        final copy = Uint8List.fromList(bytes);
        var committed = false;
        await _enqueue(() async {
          if (superseded()) return;
          await store.writeImage(id, copy);
          if (superseded()) return;
          await store.writeSettings(
            WallpaperPreferences(imageId: id, mode: _mode, blur: _blur).encode(),
          );
          // Committed inside the chain so later coalesced writes keep it.
          if (!superseded()) {
            _imageId = id;
            _settingsKnown = true;
            committed = true;
          }
        });
        // Committed: the saved record names [id], so other copies are stale.
        // Superseded: only this uncommitted copy is removed.
        unawaited(
          _enqueue(
            () => committed
                ? store.deleteImagesExcept(id)
                : store.deleteImage(id),
          ),
        );
        if (!committed) return null;
      }
      if (superseded()) return null;
      _imageId = id;
      _status = WallpaperStatus.ready;
      _writeFailed = false;
      _setImage(decoded, luminance);
      decoded = null;
      return null;
    } on WallpaperImageException catch (error) {
      _lastError = error.error;
      return error.error;
    } on Object {
      // Never "delete all except current": the current reference may be
      // unknown. Only the copy this attempt may have written is removed.
      if (store != null) unawaited(_enqueue(() => store.deleteImage(id)));
      _lastError = WallpaperImageError.storage;
      return WallpaperImageError.storage;
    } finally {
      decoded?.dispose();
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Removes the wallpaper and every owned image copy.
  Future<void> reset() async {
    if (_disposed) return;
    ++_imageGeneration;
    _imageId = null;
    _settingsKnown = true; // explicit user choice: no wallpaper
    _status = WallpaperStatus.none;
    _lastError = null;
    _setImage(null);
    notifyListeners();
    final store = _store;
    if (store == null) return;
    await _persist(() => store.deleteImagesExcept(null));
  }

  void setMode(WallpaperLayoutMode mode) {
    if (mode == _mode || _disposed) return;
    _mode = mode;
    notifyListeners();
    unawaited(_persist());
  }

  /// Applies [value] immediately (sanitized). [persist] is false while a
  /// slider drags; the final value is persisted on release.
  void setBlur(double value, {bool persist = true}) {
    if (_disposed) return;
    final next = sanitizeWallpaperBlur(value);
    if (next != _blur) {
      _blur = next;
      notifyListeners();
      _scheduleBake();
    }
    if (persist) unawaited(_persist());
  }

  Future<void> _persist([Future<void> Function()? after]) {
    final store = _store;
    if (store == null) return Future<void>.value();
    if (!_settingsKnown) {
      // Applies for this run only; see [_settingsKnown].
      if (!_writeFailed) {
        _writeFailed = true;
        notifyListeners();
      }
      return Future<void>.value();
    }
    final revision = ++_writeRevision;
    return _enqueue(() async {
      if (_disposed) return;
      var failed = false;
      try {
        // Coalesced: only the latest snapshot is written.
        if (revision == _writeRevision) {
          await store.writeSettings(
            WallpaperPreferences(
              imageId: _imageId,
              mode: _mode,
              blur: _blur,
            ).encode(),
          );
        }
        await after?.call();
      } on Object {
        failed = true;
      }
      if (_disposed || revision != _writeRevision) return;
      if (_writeFailed != failed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
  }

  /// Serializes storage operations; errors propagate to the caller only.
  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeChain.then((_) => operation());
    _writeChain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Unmeasurable content keeps the conservative (strongest) scrim.
  static Future<WallpaperLuminance> _measure(ui.Image image) async {
    try {
      return await measureWallpaperLuminance(image);
    } on Object {
      return WallpaperLuminance.unknown;
    }
  }

  void _setImage(
    ui.Image? image, [
    WallpaperLuminance luminance = WallpaperLuminance.unknown,
  ]) {
    if (identical(image, _image)) return;
    _image?.dispose();
    _image = image;
    _luminance = luminance;
    _baked?.dispose();
    _baked = null;
    _bakedBlur = null;
    _bakeFailedImage = null;
    _bakeFailedBlur = null;
    _scheduleBake();
  }

  void _scheduleBake() {
    _bakeTimer?.cancel();
    _bakeTimer = null;
    if (_image == null || _blur == 0 || _disposed) return;
    if (identical(_image, _bakeFailedImage) && _blur == _bakeFailedBlur) return;
    _bakeTimer = Timer(const Duration(milliseconds: 120), () {
      _bakeTimer = null;
      unawaited(_bake());
    });
  }

  Future<void> _bake() async {
    if (_baking) return;
    _baking = true;
    try {
      // At most a few passes if the value keeps changing during a bake.
      for (var pass = 0; pass < 3; pass++) {
        final source = _image;
        final blur = _blur;
        if (_disposed || source == null || blur == 0) return;
        if (_bakedBlur == blur && _baked != null) return;
        final ui.Image result;
        try {
          result = await _bakeBlur(source, blur);
        } on Object {
          // The live filter keeps working; no retry for this signature.
          _bakeFailedImage = source;
          _bakeFailedBlur = blur;
          return;
        }
        if (_disposed || !identical(source, _image)) {
          result.dispose();
          return;
        }
        _baked?.dispose();
        _baked = result;
        _bakedBlur = blur;
        notifyListeners();
      }
    } finally {
      _baking = false;
      if (!_disposed && _image != null && _blur != 0 && _bakedBlur != _blur) {
        _scheduleBake();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _bakeTimer?.cancel();
    _image?.dispose();
    _image = null;
    _baked?.dispose();
    _baked = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Painting.

class _WallpaperVisibility extends InheritedWidget {
  const _WallpaperVisibility({
    required this.controller,
    required this.windowActive,
    required this.panesActive,
    required this.luminance,
    required super.child,
  });

  final WallpaperController controller;
  final bool windowActive;
  final bool panesActive;

  /// Changes only with the image (never on blur ticks).
  final WallpaperLuminance luminance;

  bool get anyActive => windowActive || panesActive;

  static _WallpaperVisibility? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WallpaperVisibility>();

  @override
  bool updateShouldNotify(_WallpaperVisibility old) =>
      old.controller != controller ||
      old.windowActive != windowActive ||
      old.panesActive != panesActive ||
      old.luminance != luminance;
}

/// TerminalView `backgroundOpacity` for terminals hosted in a window or pane
/// that shows the wallpaper; 1 otherwise. Rebuilds only on visibility changes
/// (never on blur ticks).
double wallpaperTerminalBackgroundOpacity(BuildContext context) =>
    _WallpaperVisibility.of(context)?.anyActive == true
    ? wallpaperTerminalOpacity
    : 1;

/// [color] made translucent while the whole-window wallpaper is shown, so
/// large chrome fills (rail, terminal frame) let it through; else [color].
Color wallpaperWindowFill(
  BuildContext context,
  Color color, {
  double opacity = .3,
}) => _WallpaperVisibility.of(context)?.windowActive == true
    ? color.withValues(alpha: color.a * opacity)
    : color;

/// Installs the wallpaper for one window (wrap a MaterialApp `builder` child).
///
/// The tree shape is identical whether a wallpaper is set or not and in both
/// modes: toggling never re-parents or disposes [child]'s State.
class WallpaperWindowHost extends StatelessWidget {
  const WallpaperWindowHost({required this.child, this.controller, super.key});

  final Widget child;
  final WallpaperController? controller;

  @override
  Widget build(BuildContext context) {
    final wallpapers = controller ?? WallpaperController.instance;
    return ListenableBuilder(
      listenable: wallpapers,
      builder: (context, body) => _WallpaperVisibility(
        controller: wallpapers,
        windowActive:
            wallpapers.active && wallpapers.mode == WallpaperLayoutMode.window,
        panesActive:
            wallpapers.active && wallpapers.mode == WallpaperLayoutMode.panes,
        luminance: wallpapers.luminance,
        child: body!,
      ),
      child: _WallpaperWindowBody(child: child),
    );
  }
}

class _WallpaperWindowBody extends StatelessWidget {
  const _WallpaperWindowBody({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visibility = _WallpaperVisibility.of(context);
    final active = visibility?.windowActive == true;
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [
        Positioned.fill(
          child: active
              ? WallpaperImageLayer(controller: visibility!.controller)
              : const SizedBox.shrink(),
        ),
        _WallpaperThemeOverride(
          scaffoldBackground: active
              ? (palette) => palette.background.withValues(
                  alpha: wallpaperScrimAlpha(
                    palette,
                    visibility!.luminance,
                    pane: false,
                  ),
                )
              : null,
          child: child,
        ),
      ],
    );
  }
}

/// Paints one pane's own wallpaper in "follow splits" mode and keeps nested
/// scaffolds translucent while any wallpaper is shown. The slot structure is
/// fixed, so the pane child (session view) keeps its State and owner key.
class WallpaperPaneBackdrop extends StatelessWidget {
  const WallpaperPaneBackdrop({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visibility = _WallpaperVisibility.of(context);
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [
        Positioned.fill(
          child: visibility?.panesActive == true
              ? WallpaperImageLayer(
                  controller: visibility!.controller,
                  scrim: true,
                )
              : const SizedBox.shrink(),
        ),
        _WallpaperThemeOverride(
          scaffoldBackground: visibility?.anyActive == true
              ? (_) => Colors.transparent
              : null,
          child: child,
        ),
      ],
    );
  }
}

/// Always a [Theme]; only its data changes, and it is cached per base theme.
class _WallpaperThemeOverride extends StatefulWidget {
  const _WallpaperThemeOverride({
    required this.scaffoldBackground,
    required this.child,
  });

  final Color Function(AppPalette palette)? scaffoldBackground;
  final Widget child;

  @override
  State<_WallpaperThemeOverride> createState() =>
      _WallpaperThemeOverrideState();
}

class _WallpaperThemeOverrideState extends State<_WallpaperThemeOverride> {
  ThemeData? _base;
  Color? _color;
  ThemeData? _data;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final color = widget.scaffoldBackground?.call(AppPalette.of(context));
    if (!identical(base, _base) || color != _color || _data == null) {
      _base = base;
      _color = color;
      _data = color == null
          ? base
          : base.copyWith(scaffoldBackgroundColor: color);
    }
    return Theme(data: _data!, child: widget.child);
  }
}

/// The shared decoded wallpaper, cover-fitted to this layer's box. Uses the
/// pre-blurred image when ready; while a new blur value is baking it filters
/// only this image (never text, controls, terminal glyphs or framebuffers).
class WallpaperImageLayer extends StatelessWidget {
  const WallpaperImageLayer({
    required this.controller,
    this.scrim = false,
    super.key,
  });

  final WallpaperController controller;
  final bool scrim;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final source = controller.image;
              if (source == null) return const SizedBox.expand();
              final baked = controller.bakedImage;
              return CustomPaint(
                size: Size.infinite,
                painter: _WallpaperPainter(
                  image: baked ?? source,
                  sourceSigma: baked != null || controller.blur == 0
                      ? 0
                      : _imageSigma(source, controller.blur),
                  scrim: scrim
                      ? palette.background.withValues(
                          alpha: wallpaperScrimAlpha(
                            palette,
                            controller.luminance,
                            pane: true,
                          ),
                        )
                      : null,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WallpaperPainter extends CustomPainter {
  _WallpaperPainter({
    required this.image,
    required this.sourceSigma,
    required this.scrim,
  });

  final ui.Image image;

  /// Live blur in source-image pixels (0 when [image] is already blurred).
  final double sourceSigma;
  final Color? scrim;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, imageSize, size);
    final src = Alignment.center.inscribe(fitted.source, Offset.zero & imageSize);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    var dst = bounds;
    if (sourceSigma > 0) {
      // Source-image pixels -> logical pixels of this layer.
      final sigma = sourceSigma * size.width / src.width;
      paint.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      dst = bounds.inflate(sigma * 2);
    }
    canvas.drawImageRect(image, src, dst, paint);
    if (scrim case final color?) canvas.drawRect(bounds, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) =>
      !identical(old.image, image) ||
      old.sourceSigma != sourceSigma ||
      old.scrim != scrim;
}
