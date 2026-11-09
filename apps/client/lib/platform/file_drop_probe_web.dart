import 'package:web/web.dart' as web;

/// Browser drops arrive as `blob:` object URLs for files.
Future<bool> isDroppedRegularFile(String path) async =>
    path.startsWith('blob:');

/// Revokes the object URL created by the drop plugin once it's consumed.
void releaseDroppedFile(String path) {
  if (path.startsWith('blob:')) web.URL.revokeObjectURL(path);
}
