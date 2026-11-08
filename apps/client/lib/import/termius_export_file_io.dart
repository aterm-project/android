import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

bool get supportsRestrictedDesktopSave =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

Future<bool> saveRestricted({
  required String fileName,
  required Uint8List bytes,
  required bool restrictToOwner,
}) async {
  final path = await FilePicker.platform.saveFile(fileName: fileName);
  if (path == null) return false;
  await writeRestrictedExport(
    path: path,
    bytes: bytes,
    restrictToOwner: restrictToOwner,
  );
  return true;
}

/// Writes [bytes] to [path] via a sibling temporary file. When
/// [restrictToOwner] is set, permissions are restricted before writing.
Future<void> writeRestrictedExport({
  required String path,
  required Uint8List bytes,
  required bool restrictToOwner,
}) async {
  final destination = File(path);
  final temporary = File(
    '${destination.parent.path}${Platform.pathSeparator}'
    '.atermius-export-${const Uuid().v4()}.partial',
  );
  try {
    await temporary.create(exclusive: true);
    if (restrictToOwner) await _restrictToOwner(temporary.path);
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination.path);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // Best effort; the partial file is owner-only when it holds secrets.
    }
    rethrow;
  }
}

Future<void> _restrictToOwner(String path) async {
  if (Platform.isLinux || Platform.isMacOS) {
    final result = await Process.run('chmod', ['600', path]);
    final mode = (await File(path).stat()).mode & 0x1FF;
    if (result.exitCode != 0 || mode != 0x180) {
      throw FileSystemException('Could not restrict export permissions.', path);
    }
  } else if (Platform.isWindows) {
    final sid = await currentWindowsUserSid();
    final result = await Process.run('icacls', [
      path,
      '/inheritance:r',
      '/grant:r',
      '*$sid:F',
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not restrict export permissions.', path);
    }
    // Verify: exactly one explicit ACE remains and nothing is inherited.
    final check = await Process.run('icacls', [path]);
    final aces = parseIcaclsAces('${check.stdout}', path);
    if (check.exitCode != 0 ||
        aces.length != 1 ||
        aces.single.contains('(I)')) {
      throw FileSystemException('Export permissions were not verified.', path);
    }
  }
}

/// The current Windows identity SID from `whoami /user /fo csv /nh`.
Future<String> currentWindowsUserSid() async {
  final result = await Process.run('whoami', ['/user', '/fo', 'csv', '/nh']);
  final sid = parseWhoamiUserSid('${result.stdout}');
  if (result.exitCode != 0 || sid == null) {
    throw StateError('Could not identify the current Windows user SID.');
  }
  return sid;
}

/// Parses `"DOMAIN\user","S-1-5-21-..."`; returns null unless exactly one
/// well-formed SID is present.
String? parseWhoamiUserSid(String output) {
  final lines = output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length != 1) return null;
  final match = RegExp(
    r'^"[^"]*","(S-1-[0-9]+(?:-[0-9]+){1,14})"$',
  ).firstMatch(lines.single);
  return match?.group(1);
}

/// Extracts ACE strings (e.g. `NT AUTHORITY\SYSTEM:(F)`) from `icacls` output.
List<String> parseIcaclsAces(String output, String path) {
  final aces = <String>[];
  for (var line in output.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty || line.startsWith('Successfully processed')) {
      continue;
    }
    if (line.startsWith(path)) line = line.substring(path.length);
    final ace = line.trim();
    if (ace.contains(':(')) aces.add(ace);
  }
  return aces;
}
