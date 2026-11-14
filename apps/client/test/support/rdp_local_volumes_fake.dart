import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/storage/rdp_local_drives_store.dart';

/// This device's volumes, as the platform would report them.
class FakeLocalVolumes implements RdpLocalVolumeSource {
  FakeLocalVolumes({
    this.os = RdpAutoDriveOs.windows,
    bool? windowsPaths,
    this.access = true,
    this.grant = true,
    List<RdpLocalVolume>? volumes,
  }) : windowsPaths = windowsPaths ?? os == RdpAutoDriveOs.windows,
       list = volumes ?? const [];

  @override
  final RdpAutoDriveOs? os;
  @override
  final bool windowsPaths;
  bool access, grant;
  List<RdpLocalVolume> list;
  Object? error;
  int listed = 0, requests = 0;

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<bool> requestAccess() async {
    requests++;
    if (grant) access = true;
    return grant;
  }

  @override
  Future<List<RdpLocalVolume>> volumes() async {
    listed++;
    final failure = error;
    if (failure != null) throw failure;
    return list;
  }
}

const windowsC = RdpLocalVolume(name: 'C', path: r'C:\');
const windowsE = RdpLocalVolume(name: 'E', path: r'E:\');

/// A controller over an in-memory store, as main() loads it.
Future<RdpLocalDrivesController> fakeLocalDrives(
  FakeLocalVolumes source, {
  MemoryRdpLocalDrivesStore? store,
}) async {
  final controller = RdpLocalDrivesController(source: source);
  await controller.load(store ?? MemoryRdpLocalDrivesStore());
  return controller;
}
