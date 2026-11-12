import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

const _macosFilePanelChannel = MethodChannel('atermius/file_panel');

/// Picks a single import file bounded by [maxBytes].
///
/// On macOS, when [showHiddenFiles] is true (e.g., selecting `~/.ssh/config`),
/// attempts the native `atermius/file_panel` sheet first so dotfiles such as
/// `~/.ssh` and `~/.termius` are visible, falling back cleanly to
/// [FilePicker.platform] when unavailable or in widget tests.
Future<({Uint8List bytes, String name})?> pickBoundedImportFile({
  required int maxBytes,
  bool showHiddenFiles = false,
  List<String>? allowedExtensions,
}) async {
  // Only use the native hidden-file panel when FilePicker.platform has not been
  // replaced by a test fake (`_ReadOnlyFilePicker` etc.).
  if (Platform.isMacOS &&
      showHiddenFiles &&
      FilePicker.platform.runtimeType.toString() == 'FilePickerMacOS') {
    try {
      final home = Platform.environment['HOME'];
      final sshDir = home != null ? Directory('$home/.ssh') : null;
      final path = await _macosFilePanelChannel.invokeMethod<String>(
        'openFile',
        <String, Object?>{
          'showsHiddenFiles': true,
          'initialDirectory': sshDir != null && sshDir.existsSync()
              ? sshDir.path
              : home,
          'allowedExtensions': allowedExtensions,
        },
      );
      if (path == null) return null;
      if (path.isNotEmpty) {
        return readBoundedFilePath(path, maxBytes: maxBytes);
      }
    } on MissingPluginException {
      // Fall back to standard FilePicker below.
    } on PlatformException {
      // Fall back to standard FilePicker below.
    }
  }

  final result = await FilePicker.platform.pickFiles(
    type: allowedExtensions != null && allowedExtensions.isNotEmpty
        ? FileType.custom
        : FileType.any,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
    withData: true,
  );
  final file = result?.files.single;
  if (file == null) return null;
  final inMemory = file.bytes;
  if (inMemory != null) {
    if (file.size > maxBytes ||
        inMemory.length > maxBytes ||
        (file.path == null && inMemory.length != file.size)) {
      throw const FormatException('unreadable');
    }
    // Verify exact size unless a path fallback shows updated length.
    if (inMemory.length != file.size) {
      throw const FormatException('unreadable');
    }
    return (bytes: inMemory, name: file.name);
  }
  final path = file.path;
  if (path != null && path.isNotEmpty) {
    return readBoundedFilePath(path, maxBytes: maxBytes, displayName: file.name);
  }
  throw const FormatException('unreadable');
}

/// Safely reads [path] up to [maxBytes], throwing [FormatException] if missing
/// or oversized.
Future<({Uint8List bytes, String name})> readBoundedFilePath(
  String path, {
  required int maxBytes,
  String? displayName,
}) async {
  final file = File(path);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size > maxBytes) {
    throw const FormatException('unreadable');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maxBytes) {
    bytes.fillRange(0, bytes.length, 0);
    throw const FormatException('unreadable');
  }
  final slash = path.replaceAll('\\', '/').lastIndexOf('/');
  final name = displayName ?? (slash >= 0 ? path.substring(slash + 1) : path);
  return (bytes: bytes, name: name);
}

/// Returns true when `~/.ssh/config` exists as a regular file on this desktop.
bool hasLocalDefaultSshConfig() {
  if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
    return false;
  }
  final path = _defaultSshConfigPath();
  if (path == null) return false;
  try {
    return File(path).statSync().type == FileSystemEntityType.file;
  } on Object {
    return false;
  }
}

/// Reads `~/.ssh/config` after explicit user click, bounded by [maxBytes].
Future<({Uint8List bytes, String name})?> readLocalDefaultSshConfig({
  required int maxBytes,
}) async {
  final path = _defaultSshConfigPath();
  if (path == null) return null;
  return readBoundedFilePath(
    path,
    maxBytes: maxBytes,
    displayName: '~/.ssh/config',
  );
}

/// Suggested OS account username for SSH rows exported without a `Username`.
String? defaultSystemSshUsername() {
  final raw = (Platform.environment['USER'] ?? Platform.environment['USERNAME'])
      ?.trim();
  if (raw == null ||
      raw.isEmpty ||
      raw.length > 64 ||
      !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(raw)) {
    return null;
  }
  return raw;
}

String? _defaultSshConfigPath() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) return null;
  return '$home/.ssh/config';
}
