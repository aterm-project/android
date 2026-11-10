import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'desktop_keyboard_store.dart';

class FileDesktopKeyboardStore implements DesktopKeyboardStore {
  FileDesktopKeyboardStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<File> _file() async =>
      File('${(await _directory()).path}/desktop-keyboard-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists() || await file.length() > 32) return null;
    return (await file.readAsString()).trim();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.desktop-keyboard-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

DesktopKeyboardStore createStore() => FileDesktopKeyboardStore();
