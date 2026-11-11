import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import 'rdp_settings.dart';
import 'rdp_storage.dart';

const rdpStorageChannel = MethodChannel('atermius/rdp_storage');

/// Called only by an explicit Add disk/folder action. Connecting never opens
/// Android Settings or grants access on the user's behalf.
Future<void> requestRdpStorageAccess() async {
  if (Platform.isAndroid &&
      await rdpStorageChannel.invokeMethod<bool>('requestAccess') != true) {
    throw const RdpStorageException(RdpStorageIssue.permission);
  }
}

Future<List<RdpStorageRoot>> localRdpStorageRoots() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final values = await rdpStorageChannel.invokeListMethod<Object?>('roots');
    return [
      for (final value in values ?? const [])
        if (value is Map && value['path'] is String)
          RdpStorageRoot(
            path: value['path'] as String,
            label: value['label'] as String? ?? '',
            primary: value['primary'] == true,
          ),
    ];
  }
  if (Platform.isMacOS) {
    final roots = <RdpStorageRoot>[];
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && await Directory(home).exists()) {
      roots.add(RdpStorageRoot(path: home, label: 'Home', primary: true));
    }
    final volumes = Directory('/Volumes');
    if (await volumes.exists()) {
      try {
        await for (final entity in volumes.list(followLinks: false)) {
          if (entity is Directory) {
            final name = entity.uri.pathSegments
                .where((segment) => segment.isNotEmpty)
                .lastOrNull;
            if (name != null && !name.startsWith('.')) {
              roots.add(RdpStorageRoot(path: entity.path, label: name));
            }
          }
        }
      } on FileSystemException {
        // Ignore restricted mount points while listing user-visible volumes.
      }
    }
    return roots;
  }
  if (Platform.isWindows) {
    final mask = GetLogicalDrives();
    final result = <RdpStorageRoot>[];
    for (var i = 0; i < 26; i++) {
      if (mask & (1 << i) == 0) continue;
      final letter = String.fromCharCode(65 + i);
      final path = '$letter:\\';
      final native = path.toNativeUtf16();
      try {
        final type = GetDriveType(native);
        if (type == DRIVE_FIXED ||
            type == DRIVE_REMOVABLE ||
            type == DRIVE_REMOTE ||
            type == DRIVE_RAMDISK) {
          result.add(RdpStorageRoot(path: path, label: '$letter:'));
        }
      } finally {
        calloc.free(native);
      }
    }
    return result;
  }
  return const [];
}

/// Fail before the handshake if a synced path belongs to another device, its
/// disk was removed, or Android storage access was revoked. No test files are
/// created and no unrelated directories are enumerated.
Future<void> validateRdpDriveConfig(String config) async {
  final drives = <RdpDriveRedirect>[];
  for (final line in config.split('\n')) {
    if (!line.startsWith('drive=')) continue;
    final separator = line.indexOf('|', 6);
    if (separator < 0) throw const RdpStorageException(RdpStorageIssue.picker);
    drives.add(
      RdpDriveRedirect(
        name: line.substring(6, separator),
        path: line.substring(separator + 1),
      ),
    );
  }
  if (drives.isEmpty) return;
  if (Platform.isAndroid &&
      await rdpStorageChannel.invokeMethod<bool>('checkAccess') != true) {
    throw const RdpStorageException(RdpStorageIssue.permission);
  }
  await Future.wait(
    drives.map((drive) async {
      final windowsPath = RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)')
          .hasMatch(drive.path);
      if (drive.validate() != null ||
          Platform.isWindows != windowsPath ||
          !await Directory(drive.path)
              .exists()
              .timeout(const Duration(seconds: 5), onTimeout: () => false)) {
        throw RdpStorageException(RdpStorageIssue.unavailable, drive.name);
      }
    }),
  );
}
