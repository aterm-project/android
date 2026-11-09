import 'dart:io';

/// Classifies a dropped local path without following it into a directory
/// walk. Only existing regular files (or links to them) are uploadable.
Future<bool> isDroppedRegularFile(String path) async {
  try {
    if (path.isEmpty || !File(path).isAbsolute) return false;
    return await FileSystemEntity.type(path) == FileSystemEntityType.file;
  } catch (_) {
    // Unreadable, malformed or vanished paths are simply not uploadable.
    return false;
  }
}

/// io paths are owned by the OS; nothing to release.
void releaseDroppedFile(String path) {}
