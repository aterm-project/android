import '../l10n/l10n.dart';

class RdpStorageRoot {
  const RdpStorageRoot({
    required this.path,
    this.label = '',
    this.primary = false,
  });
  final String path, label;
  final bool primary;
}

enum RdpStorageIssue { permission, unavailable, picker }

class RdpStorageException implements Exception {
  const RdpStorageException(this.issue, [this.name = '']);
  final RdpStorageIssue issue;
  final String name;
  String get message => switch (issue) {
    RdpStorageIssue.permission => currentL10n.rdpStoragePermissionRequired,
    RdpStorageIssue.unavailable => currentL10n.rdpStorageFolderUnavailable(
      name,
    ),
    RdpStorageIssue.picker => currentL10n.rdpStoragePickerFailed,
  };
  @override
  String toString() => message;
}

/// Operating systems whose local volumes RDP maps automatically. Elsewhere
/// (macOS, Linux, iOS, web) only folders saved on the Host are mapped.
enum RdpAutoDriveOs { windows, android }

/// A local volume found at connect time for automatic disk mapping.
class RdpLocalVolume {
  const RdpLocalVolume({
    required this.name,
    required this.path,
    this.ready = true,
  });

  /// Share name the server shows under `\\tsclient` (`C`, `Local Storage`).
  final String name;
  final String path;

  /// False while the volume is present but unusable, for example a card
  /// reader without media or a volume Android is still checking.
  final bool ready;

  @override
  bool operator ==(Object other) =>
      other is RdpLocalVolume &&
      other.name == name &&
      other.path == path &&
      other.ready == ready;
  @override
  int get hashCode => Object.hash(name, path, ready);
  @override
  String toString() => 'RdpLocalVolume($name, $path, ready: $ready)';
}

/// This device's volumes for automatic RDP disk mapping. Injectable so the
/// connect-time expansion can be tested without the platform.
abstract interface class RdpLocalVolumeSource {
  /// Null where automatic mapping is not offered.
  RdpAutoDriveOs? get os;

  /// Whether local paths on this device use the Windows form (`C:\`). A
  /// saved path in the other form was synchronized from another device.
  bool get windowsPaths;

  /// Android "All files access". Always true elsewhere. Never prompts.
  Future<bool> hasAccess();

  /// Opens the system permission screen (Android). Explicit user action only.
  Future<bool> requestAccess();

  /// Volumes present now, including ones that are not ready.
  Future<List<RdpLocalVolume>> volumes();
}

const _readyRootStates = {'mounted', 'mounted_ro'};

/// Whether one entry of the Android/iOS `roots` channel is a usable volume:
/// it has a path, is readable and is mounted. Runners without "state" report
/// only usable roots. The disk picker and automatic mapping both use this.
bool _rootUsable(Map<Object?, Object?> value) {
  final path = value['path'], state = value['state'];
  return path is String &&
      path.isNotEmpty &&
      value['readable'] != false &&
      (state == null || _readyRootStates.contains(state));
}

/// Roots the disk picker offers, from the Android/iOS `roots` channel: only
/// usable volumes (see [rdpAndroidVolumesFrom] for the connect-time list).
List<RdpStorageRoot> rdpStorageRootsFrom(List<Object?>? raw) => [
  for (final value in raw ?? const [])
    if (value is Map && _rootUsable(value))
      RdpStorageRoot(
        path: value['path'] as String,
        label: value['label'] is String ? value['label'] as String : '',
        primary: value['primary'] == true,
      ),
];

/// Volumes reported by the Android `roots` channel. Mounted, readable volumes
/// are ready; volumes Android still lists while checking, unmounting or
/// failing to mount are not ready; removed volumes are left out.
List<RdpLocalVolume> rdpAndroidVolumesFrom(List<Object?>? raw) {
  const present = {'checking', 'unmounted', 'unmountable', 'nofs', 'ejecting'};
  final result = <RdpLocalVolume>[];
  for (final value in raw ?? const []) {
    if (value is! Map) continue;
    final path = value['path'] is String ? value['path'] as String : '';
    final state = value['state'] is String ? value['state'] as String : null;
    final name = rdpAndroidVolumeName(
      primary: value['primary'] == true,
      uuid: value['uuid'] is String ? value['uuid'] as String : null,
      path: path,
    );
    if (_rootUsable(value)) {
      result.add(RdpLocalVolume(name: name, path: path));
    } else if (state != null &&
        (present.contains(state) || _readyRootStates.contains(state))) {
      result.add(RdpLocalVolume(name: name, path: path, ready: false));
    }
  }
  return result;
}

/// Stable short share name for an Android volume: internal storage is
/// `Local Storage`; SD cards and USB drives use their volume ID.
String rdpAndroidVolumeName({
  required bool primary,
  String? uuid,
  required String path,
}) {
  if (primary) return 'Local Storage';
  final id = (uuid ?? '').replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  if (id.isNotEmpty) {
    return 'Storage ${id.substring(0, id.length < 22 ? id.length : 22)}';
  }
  final segment = path
      .split('/')
      .lastWhere((part) => part.isNotEmpty, orElse: () => '')
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_');
  return RegExp(r'^[A-Za-z0-9]').hasMatch(segment)
      ? 'Storage ${segment.substring(0, segment.length < 22 ? segment.length : 22)}'
      : 'Storage';
}
