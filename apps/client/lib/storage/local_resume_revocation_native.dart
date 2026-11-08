import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

import 'dart:convert';

import 'package:path_provider/path_provider.dart';

Future<File> _marker(String key) async => File(
  '${(await getApplicationSupportDirectory()).path}/local-resume-${sha256.convert(utf8.encode(key))}.revoked',
);
Future<bool> isRevoked(String key) async => (await _marker(key)).exists();
Future<void> setRevoked(String key, bool revoked) async {
  final file = await _marker(key);
  if (revoked) {
    await file.parent.create(recursive: true);
    await file.writeAsString('revoked', flush: true);
  } else if (await file.exists()) {
    await file.delete();
  }
}
