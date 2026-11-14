import 'rdp_local_drives_store_native.dart'
    if (dart.library.js_interop) 'rdp_local_drives_store_web.dart'
    as platform;

/// Non-secret, device-local RDP local-disk mapping preferences (which Hosts
/// have automatic mapping turned off, and which have shown the one-time
/// notice). Never part of the Host manifest, sync, Vault export or backup:
/// a choice made on one device must not expose another device's disks.
abstract interface class RdpLocalDrivesStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Largest stored value accepted; anything larger is treated as corrupt.
const rdpLocalDrivesStoreMaxBytes = 256 * 1024;

RdpLocalDrivesStore createRdpLocalDrivesStore() => platform.createStore();

class MemoryRdpLocalDrivesStore implements RdpLocalDrivesStore {
  MemoryRdpLocalDrivesStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}
