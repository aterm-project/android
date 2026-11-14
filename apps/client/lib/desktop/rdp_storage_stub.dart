import 'rdp_storage.dart';

Future<void> requestRdpStorageAccess() async {}
Future<List<RdpStorageRoot>> localRdpStorageRoots() async => const [];
Future<void> validateRdpDriveConfig(String config) async {}

/// No local volumes are mapped automatically on the web.
RdpLocalVolumeSource platformRdpLocalVolumeSource() =>
    const _NoLocalVolumes();

class _NoLocalVolumes implements RdpLocalVolumeSource {
  const _NoLocalVolumes();
  @override
  RdpAutoDriveOs? get os => null;
  @override
  bool get windowsPaths => false;
  @override
  Future<bool> hasAccess() async => true;
  @override
  Future<bool> requestAccess() async => true;
  @override
  Future<List<RdpLocalVolume>> volumes() async => const [];
}
