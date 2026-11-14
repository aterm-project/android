import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/rdp_local_drives_store.dart';
import 'rdp_settings.dart';
import 'rdp_storage.dart';
import 'rdp_storage_stub.dart'
    if (dart.library.io) 'rdp_storage_io.dart'
    as storage;

/// Device-local "Map local disks" choices. Mapping is on by default; this
/// stores the Hosts where it was turned off on this device and the Hosts that
/// already showed the one-time "disks mapped" notice. It is never part of the
/// Host manifest, sync, Vault export or backup: a choice made on one device
/// must never expose another device's disks.
///
/// The switch fails closed: a choice that could not be stored stays in force
/// (and is written again later) instead of being undone by the next read, and
/// while the store exists but cannot be read no Host maps local disks unless
/// its choice was made in this process.
class RdpLocalDrivesController extends ChangeNotifier {
  RdpLocalDrivesController({RdpLocalVolumeSource? source})
    : source = source ?? storage.platformRdpLocalVolumeSource();

  static RdpLocalDrivesController? _instance;
  static RdpLocalDrivesController get instance =>
      _instance ??= RdpLocalDrivesController();
  @visibleForTesting
  static set debugInstance(RdpLocalDrivesController? value) =>
      _instance = value;

  /// Bounds for each stored list; the oldest entries are dropped beyond it.
  static const maxEntries = 4096;
  static const _maxIdLength = 256;
  static const _readTimeout = Duration(seconds: 2);

  /// Lists this device's volumes (Windows drives, Android storage volumes).
  final RdpLocalVolumeSource source;
  RdpLocalDrivesStore? _store;
  // Set literals keep insertion order: the oldest entries go first when a
  // list is full.
  Set<String> _off = {};
  Set<String> _noticed = {};
  Future<void> _writes = Future.value();

  /// Changes made in this process that are not stored yet, oldest first.
  /// The in-memory choices are always the stored ones with these applied on
  /// top, so a failed write or an unreadable store never undoes them.
  final _unsaved = <void Function(Set<String> off, Set<String> noticed)>[];

  /// Hosts turned on in this process while the store could not be read.
  final _enabledWhileUnreadable = <String>{};

  /// Bumped by every completed write: a [refresh] whose read may predate it
  /// keeps the choices in memory.
  int _generation = 0;
  bool _disposed = false;

  /// The last write of a change made here failed; the change still applies
  /// in this process and is written again by the next [refresh] or change.
  bool writeFailed = false;

  /// The store exists but could not be read (an error or a timeout).
  /// Automatic mapping is off until a read succeeds, except for Hosts turned
  /// on in this process meanwhile.
  bool unreadable = false;

  /// Whether this device offers automatic mapping at all (Windows, Android).
  bool get offered => source.os != null;

  Future<void> load(RdpLocalDrivesStore store) async {
    _store = store;
    await refresh();
  }

  /// Reads the stored choices again. Connects call this so every connect and
  /// reconnect uses the current switch. Missing or corrupt data means the
  /// defaults (mapping on, no notice shown); a store that cannot be read
  /// means no automatic mapping (see [unreadable]). Changes that could not
  /// be written before are kept on top of what was read and written again.
  Future<void> refresh() async {
    final store = _store;
    if (store == null || _disposed) return;
    // This process's own pending writes land first.
    await _writes;
    if (_disposed) return;
    final generation = _generation;
    String? raw;
    try {
      raw = await store.read().timeout(_readTimeout);
    } on Object {
      if (!_disposed && !unreadable) {
        unreadable = true;
        notifyListeners();
      }
      return;
    }
    // A write that finished meanwhile may be missing from what was read.
    if (_disposed || generation != _generation) return;
    _rebase(raw);
    if (_unsaved.isNotEmpty) await _save();
  }

  /// Replaces the in-memory choices with [raw] plus this process's unsaved
  /// changes.
  void _rebase(String? raw) {
    final (off, noticed) = _decode(raw);
    for (final change in _unsaved) {
      change(off, noticed);
    }
    final changed =
        unreadable || !setEquals(off, _off) || !setEquals(noticed, _noticed);
    unreadable = false;
    _enabledWhileUnreadable.clear();
    _off = off;
    _noticed = noticed;
    if (changed && !_disposed) notifyListeners();
  }

  /// Whether local disks are mapped for [hostId] on this device. A Host that
  /// has no id yet uses the default (on).
  bool enabled(String? hostId) =>
      hostId == null ||
      (!_off.contains(hostId) &&
          (!unreadable || _enabledWhileUnreadable.contains(hostId)));

  bool noticeShown(String hostId) => _noticed.contains(hostId);

  Future<void> setEnabled(String hostId, bool enabled) {
    if (!_validId(hostId)) return _writes;
    // While the stored choices are unknown every explicit choice is kept, so
    // it can be applied over them once they are read.
    if (!unreadable && this.enabled(hostId) == enabled) return _writes;
    if (enabled && unreadable) {
      _enabledWhileUnreadable.add(hostId);
    } else {
      _enabledWhileUnreadable.remove(hostId);
    }
    return _change((off, _) {
      if (enabled) {
        off.remove(hostId);
      } else {
        _add(off, hostId);
      }
    });
  }

  Future<void> markNoticeShown(String hostId) {
    if (!_validId(hostId) || _noticed.contains(hostId)) return _writes;
    return _change((_, noticed) => _add(noticed, hostId));
  }

  /// A new Host may be stored under another id than the one its editor used
  /// (local profiles assign the record id); the choice follows it.
  Future<void> moveHost(String from, String to) {
    if (from == to || !_validId(to)) return _writes;
    if (_enabledWhileUnreadable.remove(from)) _enabledWhileUnreadable.add(to);
    if (!unreadable && !_off.contains(from) && !_noticed.contains(from)) {
      return _writes;
    }
    return _change((off, noticed) {
      if (off.remove(from)) _add(off, to);
      if (noticed.remove(from)) _add(noticed, to);
    });
  }

  static bool _validId(String id) =>
      id.isNotEmpty && id.length <= _maxIdLength;

  static void _add(Set<String> set, String id) {
    set.remove(id);
    set.add(id);
    while (set.length > maxEntries) {
      set.remove(set.first);
    }
  }

  Future<void> _change(
    void Function(Set<String> off, Set<String> noticed) change,
  ) {
    change(_off, _noticed);
    _unsaved.add(change);
    if (!_disposed) notifyListeners();
    return _save();
  }

  /// Writes the in-memory choices once every earlier write has finished.
  /// While the store cannot be read it is read first: choices that could not
  /// be read are never overwritten.
  Future<void> _save() {
    final store = _store;
    if (store == null || _disposed) return _writes;
    return _writes = _writes.then((_) async {
      if (_disposed || _unsaved.isEmpty) return;
      if (unreadable) {
        String? raw;
        try {
          raw = await store.read().timeout(_readTimeout);
        } on Object {
          _writeResult(failed: true);
          return;
        }
        if (_disposed) return;
        _rebase(raw);
      }
      final count = _unsaved.length;
      final value = _encode(_off, _noticed);
      var failed = false;
      try {
        await store.write(value);
        _unsaved.removeRange(0, count);
        _generation++;
      } on Object {
        failed = true;
      }
      _writeResult(failed: failed);
    });
  }

  void _writeResult({required bool failed}) {
    writeFailed = failed;
    if (!_disposed) notifyListeners();
  }

  static String _encode(Set<String> off, Set<String> noticed) =>
      jsonEncode({'version': 1, 'off': [...off], 'noticed': [...noticed]});

  static (Set<String>, Set<String>) _decode(String? raw) {
    final off = <String>{}, noticed = <String>{};
    if (raw == null ||
        raw.isEmpty ||
        raw.length > rdpLocalDrivesStoreMaxBytes) {
      return (off, noticed);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) return (off, noticed);
      List<String>? ids(Object? list) => list is List &&
              list.every((id) => id is String && _validId(id))
          ? list.cast<String>()
          : null;
      final storedOff = ids(value['off'] ?? const []);
      final storedNoticed = ids(value['noticed'] ?? const []);
      if (storedOff == null || storedNoticed == null) {
        return (<String>{}, <String>{});
      }
      for (final id in storedOff) {
        _add(off, id);
      }
      for (final id in storedNoticed) {
        _add(noticed, id);
      }
      return (off, noticed);
    } on FormatException {
      return (<String>{}, <String>{});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What one connection maps: the Host's own folders, then this device's
/// volumes, with everything that was left out named for the notices.
class RdpDriveExpansion {
  const RdpDriveExpansion({
    required this.drives,
    this.mapped = const [],
    this.unavailable = const [],
    this.otherDevice = const [],
    this.tooLong = const [],
    this.leftOut = const [],
    this.accessRequired = false,
  });

  /// Mappings sent to the engine, Host folders first.
  final List<RdpDriveRedirect> drives;

  /// Share names of local volumes added automatically.
  final List<String> mapped;

  /// Local volumes skipped because they are not ready, vanished or have a
  /// path the engine cannot carry.
  final List<String> unavailable;

  /// Host folders skipped because their path belongs to the other operating
  /// system (synchronized from another device).
  final List<String> otherDevice;

  /// Host folders skipped because their path is longer than the engine's
  /// drive channel carries ([rdpMaxDrivePathBytes]); older versions stored
  /// such paths.
  final List<String> tooLong;

  /// Mappings over [RdpSettings.maxConnectionDrives].
  final List<String> leftOut;

  /// Android: local volumes were not mapped because All files access is off.
  final bool accessRequired;
}

/// Whether [path] is in the Windows form (`C:\`, `\\server\share`).
bool rdpPathIsWindows(String path) =>
    RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)').hasMatch(path);

String _pathKey(String path, bool windows) {
  if (!windows) {
    var key = path;
    while (key.length > 1 && key.endsWith('/')) {
      key = key.substring(0, key.length - 1);
    }
    return key;
  }
  var key = path.replaceAll('/', r'\').toLowerCase();
  while (key.length > 1 && key.endsWith(r'\')) {
    key = key.substring(0, key.length - 1);
  }
  return RegExp(r'^[a-z]:$').hasMatch(key) ? '$key\\' : key;
}

String _shareName(String proposed) {
  final base = proposed.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_').trim();
  if (base.isEmpty || !RegExp('^[A-Za-z0-9]').hasMatch(base)) return 'Disk';
  return base.substring(0, base.length.clamp(0, 24));
}

/// Builds this connection's mappings. The Host's folders come first; a
/// folder whose path belongs to the other operating system or is too long
/// for the engine is skipped instead of failing the connection. When
/// [automatic] is on, every local volume that is ready now follows, unless a
/// Host folder already maps the same path; volumes that are not ready,
/// vanished or whose path is too long are skipped. Names stay unique and the
/// total stays within [RdpSettings.maxConnectionDrives]. Never throws: a
/// volume list that cannot be read maps no local volumes.
Future<RdpDriveExpansion> expandRdpDrives({
  required List<RdpDriveRedirect> explicit,
  required bool automatic,
  required RdpLocalVolumeSource source,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final windows = source.windowsPaths;
  final drives = <RdpDriveRedirect>[];
  final otherDevice = <String>[], tooLong = <String>[];
  for (final drive in explicit) {
    if (rdpPathIsWindows(drive.path) != windows) {
      otherDevice.add(drive.name);
    } else if (!rdpPathFitsEngine(drive.path)) {
      tooLong.add(drive.name);
    } else {
      drives.add(drive);
    }
  }
  final mapped = <String>[], unavailable = <String>[], leftOut = <String>[];
  var accessRequired = false;
  if (automatic && source.os != null) {
    var volumes = const <RdpLocalVolume>[];
    try {
      if (source.os == RdpAutoDriveOs.android &&
          !await source.hasAccess().timeout(timeout)) {
        accessRequired = true;
      } else {
        volumes = await source.volumes().timeout(timeout);
      }
    } on Object {
      volumes = const [];
    }
    final paths = {for (final drive in drives) _pathKey(drive.path, windows)};
    final names = {for (final drive in drives) drive.name.toLowerCase()};
    for (final volume in volumes) {
      final key = _pathKey(volume.path, windows);
      if (volume.path.isNotEmpty && paths.contains(key)) continue;
      final base = _shareName(volume.name);
      if (!volume.ready ||
          !isSafeLocalPath(volume.path) ||
          !rdpPathFitsEngine(volume.path) ||
          rdpPathIsWindows(volume.path) != windows) {
        unavailable.add(base);
        continue;
      }
      paths.add(key);
      var name = base;
      for (var i = 2; names.contains(name.toLowerCase()); i++) {
        name = '$base $i';
      }
      if (drives.length >= RdpSettings.maxConnectionDrives) {
        leftOut.add(name);
        continue;
      }
      names.add(name.toLowerCase());
      drives.add(RdpDriveRedirect(name: name, path: volume.path));
      mapped.add(name);
    }
  }
  return RdpDriveExpansion(
    drives: List.unmodifiable(drives),
    mapped: List.unmodifiable(mapped),
    unavailable: List.unmodifiable(unavailable),
    otherDevice: List.unmodifiable(otherDevice),
    tooLong: List.unmodifiable(tooLong),
    leftOut: List.unmodifiable(leftOut),
    accessRequired: accessRequired,
  );
}
