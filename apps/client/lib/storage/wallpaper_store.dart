import 'dart:async';
import 'dart:typed_data';

import 'wallpaper_store_native.dart'
    if (dart.library.js_interop) 'wallpaper_store_web.dart'
    as platform;

/// Device-local wallpaper storage.
///
/// Like the UI theme this lives outside the encrypted Vault/profile stores so
/// credential-free child windows can read it. It is split in two parts:
/// - a tiny settings record (JSON: version, image id, layout mode, blur), and
/// - the image content, copied into app-owned storage under a random id.
///
/// The settings never contain image bytes, the original file name or path.
/// Image ids must match [wallpaperImageIdPattern]; implementations reject
/// anything else so a tampered settings record cannot reach other files.
abstract interface class WallpaperStore {
  /// Returns null only when no settings record exists. Access/read failures
  /// throw, so a transient error is never mistaken for "no wallpaper".
  Future<String?> readSettings();
  Future<void> writeSettings(String json);

  /// Returns null when the image is missing or larger than [maxBytes].
  Future<Uint8List?> readImage(String id, {required int maxBytes});
  Future<void> writeImage(String id, Uint8List bytes);

  /// Removes every owned image except [keepId] (all of them when null).
  /// Callers only use it when the saved keep-id state is known.
  Future<void> deleteImagesExcept(String? keepId);

  /// Removes one owned image (an uncommitted copy after a failed write).
  Future<void> deleteImage(String id);
}

WallpaperStore createWallpaperStore() => platform.createWallpaperStore();

/// Thrown when a picked source file is larger than the accepted limit.
class WallpaperSourceTooLargeException implements Exception {
  const WallpaperSourceTooLargeException();
}

/// Reads a user-picked local file (native only) after checking its size, so
/// an oversized file is never loaded. Its path is used once and not stored.
Future<Uint8List> readWallpaperSourceFile(
  String path, {
  required int maxBytes,
}) => platform.readWallpaperSourceFile(path, maxBytes);

/// Collects at most [maxBytes] from [source] and cancels it as soon as more
/// arrives, so a huge or still-growing source never allocates past the bound.
/// Throws [WallpaperSourceTooLargeException] when the bound is exceeded.
Future<Uint8List> readBoundedWallpaperBytes(
  Stream<List<int>> source, {
  required int maxBytes,
}) async {
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> subscription;
  subscription = source.listen(
    (chunk) {
      if (done.isCompleted) return;
      if (builder.length + chunk.length > maxBytes) {
        done.completeError(const WallpaperSourceTooLargeException());
        unawaited(subscription.cancel());
        return;
      }
      builder.add(chunk);
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
      unawaited(subscription.cancel());
    },
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  return done.future;
}

/// Longest accepted settings record; anything larger is ignored.
const wallpaperSettingsMaxLength = 512;

final wallpaperImageIdPattern = RegExp(r'^[0-9a-f]{32}$');

bool isValidWallpaperImageId(String? id) =>
    id != null && wallpaperImageIdPattern.hasMatch(id);

/// In-memory store for tests and renderers that must not persist.
class MemoryWallpaperStore implements WallpaperStore {
  MemoryWallpaperStore({this.settings, Map<String, Uint8List>? images})
    : images = images ?? <String, Uint8List>{};

  String? settings;
  final Map<String, Uint8List> images;
  int settingsWrites = 0;
  Object? failWith;

  /// When set, [readSettings] throws it (simulates an unreadable record).
  Object? readFailWith;

  /// When set, [readSettings] never completes (simulates a hung read).
  bool readHangs = false;

  @override
  Future<String?> readSettings() async {
    if (readHangs) return Completer<String?>().future;
    if (readFailWith case final error?) throw error;
    return settings;
  }

  @override
  Future<void> writeSettings(String json) async {
    if (failWith case final error?) throw error;
    settingsWrites++;
    settings = json;
  }

  @override
  Future<Uint8List?> readImage(String id, {required int maxBytes}) async {
    if (!isValidWallpaperImageId(id)) return null;
    final bytes = images[id];
    return bytes == null || bytes.length > maxBytes ? null : bytes;
  }

  @override
  Future<void> writeImage(String id, Uint8List bytes) async {
    if (failWith case final error?) throw error;
    if (!isValidWallpaperImageId(id)) throw ArgumentError.value(id, 'id');
    images[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteImagesExcept(String? keepId) async =>
      images.removeWhere((id, _) => id != keepId);

  @override
  Future<void> deleteImage(String id) async => images.remove(id);
}
