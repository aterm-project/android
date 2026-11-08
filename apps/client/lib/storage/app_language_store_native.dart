import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_language_store.dart';

class FileAppLanguageStore implements AppLanguageStore {
  FileAppLanguageStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/app-language-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > 32) return null;
    return (await file.readAsString()).trim();
  }

  @override
  Future<void> write(String code) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.app-language-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(code, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

AppLanguageStore createLanguageStore() => FileAppLanguageStore();
