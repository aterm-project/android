import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
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
    // Android also lists volumes that are not mounted (for the connect-time
    // notice); only usable ones can be chosen.
    return rdpStorageRootsFrom(
      await rdpStorageChannel.invokeListMethod<Object?>('roots'),
    );
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
      final native = path.toNativeUtf16(allocator: calloc);
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

/// Local volumes for automatic RDP disk mapping on Windows and Android.
RdpLocalVolumeSource platformRdpLocalVolumeSource() =>
    const _PlatformLocalVolumes();

class _PlatformLocalVolumes implements RdpLocalVolumeSource {
  const _PlatformLocalVolumes();
  @override
  RdpAutoDriveOs? get os => Platform.isWindows
      ? RdpAutoDriveOs.windows
      : Platform.isAndroid
      ? RdpAutoDriveOs.android
      : null;
  @override
  bool get windowsPaths => Platform.isWindows;
  @override
  Future<bool> hasAccess() async =>
      !Platform.isAndroid ||
      await rdpStorageChannel.invokeMethod<bool>('checkAccess') == true;
  @override
  Future<bool> requestAccess() async {
    try {
      await requestRdpStorageAccess();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<List<RdpLocalVolume>> volumes() async {
    if (Platform.isWindows) return _windowsVolumes();
    if (Platform.isAndroid) {
      return rdpAndroidVolumesFrom(
        await rdpStorageChannel.invokeListMethod<Object?>('roots'),
      );
    }
    return const [];
  }
}

/// Fixed, removable, optical and RAM disks. Network drives belong to another
/// computer and are never mapped automatically.
const _autoDriveTypes = {
  DRIVE_FIXED,
  DRIVE_REMOVABLE,
  DRIVE_CDROM,
  DRIVE_RAMDISK,
};

/// Optical drives and card readers can take seconds to answer.
const _readyProbeTimeout = Duration(seconds: 3);

Future<List<RdpLocalVolume>> _windowsVolumes() => windowsRdpVolumes(
  mask: GetLogicalDrives(),
  driveType: _driveType,
  ready: _probeReady,
);

/// Drive letters in [mask] (bit 0 is A) whose [driveType] is mapped
/// automatically, each named by its letter so the server shows `\\tsclient\C`.
/// [ready] is probed for all of them at once; a probe that fails or takes
/// longer than [timeout] counts as not ready.
@visibleForTesting
Future<List<RdpLocalVolume>> windowsRdpVolumes({
  required int mask,
  required int Function(String root) driveType,
  required Future<bool> Function(String root) ready,
  Duration timeout = _readyProbeTimeout,
}) {
  final probes = <Future<RdpLocalVolume>>[];
  for (var i = 0; i < 26; i++) {
    if (mask & (1 << i) == 0) continue;
    final letter = String.fromCharCode(65 + i);
    final root = '$letter:\\';
    if (!_autoDriveTypes.contains(driveType(root))) continue;
    probes.add(
      Future.sync(() => ready(root))
          .timeout(timeout, onTimeout: () => false)
          .catchError((Object _) => false)
          .then(
            (ready) => RdpLocalVolume(name: letter, path: root, ready: ready),
          ),
    );
  }
  return Future.wait(probes);
}

/// GetDriveType reads no media and never shows a dialog.
int _driveType(String root) {
  final native = root.toNativeUtf16(allocator: calloc);
  try {
    return GetDriveType(native);
  } finally {
    calloc.free(native);
  }
}

/// The probe runs on its own isolate (only [root] is sent), so a drive that
/// hangs never blocks the UI.
Future<bool> _probeReady(String root) =>
    Isolate.run(() => windowsVolumeReady(root));

/// Whether [root] has readable media. The critical-error dialog ("There is
/// no disk in the drive") is suppressed for the calling thread only and the
/// previous mode is restored afterwards, so a card reader without media
/// never shows a system dialog.
bool windowsVolumeReady(String root) {
  final path = root.toNativeUtf16(allocator: calloc);
  final previous = calloc<Uint32>();
  try {
    final changed =
        SetThreadErrorMode(
          SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX,
          previous,
        ) !=
        0;
    try {
      return GetVolumeInformation(
            path,
            nullptr,
            0,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            0,
          ) !=
          0;
    } finally {
      if (changed) SetThreadErrorMode(previous.value, nullptr);
    }
  } finally {
    calloc.free(previous);
    calloc.free(path);
  }
}
