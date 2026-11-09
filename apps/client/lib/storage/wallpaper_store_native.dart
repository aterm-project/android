import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'wallpaper_store.dart';

/// Stores the wallpaper under `<application support>/wallpaper-v1/`:
/// `settings.json` plus one `<id>.img` copy of the chosen image content.
class FileWallpaperStore implements WallpaperStore {
  FileWallpaperStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const _folder = 'wallpaper-v1';
  static const _settingsName = 'settings.json';
  static const _imageSuffix = '.img';

  Future<Directory> _root() async =>
      Directory('${(await _directory()).path}/$_folder');

  Future<File> _image(String id) async {
    if (!isValidWallpaperImageId(id)) throw ArgumentError.value(id, 'id');
    return File('${(await _root()).path}/$id$_imageSuffix');
  }

  @override
  Future<String?> readSettings() async {
    final file = File('${(await _root()).path}/$_settingsName');
    if (!await file.exists()) return null;
    // Oversized is "unreadable", never "absent": it must not enable cleanup.
    if (await file.length() > wallpaperSettingsMaxLength) {
      throw const FormatException('Wallpaper settings record too large');
    }
    return (await file.readAsString()).trim();
  }

  @override
  Future<void> writeSettings(String json) =>
      _atomicWrite(_settingsName, (file) => file.writeAsString(json, flush: true));

  @override
  Future<Uint8List?> readImage(String id, {required int maxBytes}) async {
    if (!isValidWallpaperImageId(id)) return null;
    final file = await _image(id);
    if (!await file.exists()) return null;
    if (await file.length() > maxBytes) return null;
    try {
      return await readBoundedWallpaperBytes(
        file.openRead(0, maxBytes + 1),
        maxBytes: maxBytes,
      );
    } on WallpaperSourceTooLargeException {
      return null;
    }
  }

  @override
  Future<void> writeImage(String id, Uint8List bytes) async {
    if (!isValidWallpaperImageId(id)) throw ArgumentError.value(id, 'id');
    await _atomicWrite(
      '$id$_imageSuffix',
      (file) => file.writeAsBytes(bytes, flush: true),
    );
  }

  @override
  Future<void> deleteImage(String id) async {
    if (!isValidWallpaperImageId(id)) return;
    final file = await _image(id);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort; the next replace/reset cleans it.
    }
  }

  @override
  Future<void> deleteImagesExcept(String? keepId) async {
    final root = await _root();
    if (!await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => '',
      );
      // Only files this store created: `<32 hex>.img`, plus stale temp dirs.
      final owned =
          name.endsWith(_imageSuffix) &&
          isValidWallpaperImageId(
            name.substring(0, name.length - _imageSuffix.length),
          );
      final staleTemp = name.startsWith('.wallpaper-');
      if (!owned && !staleTemp) continue;
      if (owned && name == '$keepId$_imageSuffix') continue;
      try {
        await entity.delete(recursive: staleTemp);
      } on FileSystemException {
        // Best effort; a later replace/reset retries.
      }
    }
  }

  Future<void> _atomicWrite(
    String name,
    Future<void> Function(File candidate) write,
  ) async {
    final root = await _root();
    await root.create(recursive: true);
    final temporary = await root.createTemp('.wallpaper-');
    try {
      final candidate = File('${temporary.path}/value');
      await write(candidate);
      await candidate.rename('${root.path}/$name');
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }
}

WallpaperStore createWallpaperStore() => FileWallpaperStore();

Future<Uint8List> readWallpaperSourceFile(String path, int maxBytes) async {
  final file = File(path);
  if (await file.length() > maxBytes) {
    throw const WallpaperSourceTooLargeException();
  }
  // Bounded even if the file grows after the length check.
  return readBoundedWallpaperBytes(
    file.openRead(0, maxBytes + 1),
    maxBytes: maxBytes,
  );
}
