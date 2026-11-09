import 'app_theme_store_native.dart'
    if (dart.library.js_interop) 'app_theme_store_web.dart'
    as platform;

/// Device-local UI theme preference (`system`, `dark` or `light`).
///
/// Like the display language this lives outside the encrypted Vault/profile
/// stores: it must be readable before any secure storage is unlocked and by
/// credential-free terminal/files/remote-desktop child windows, and it never
/// contains secrets. It only affects UI chrome, never terminal palettes.
abstract interface class AppThemeStore {
  Future<String?> read();
  Future<void> write(String code);
}

AppThemeStore createAppThemeStore() => platform.createThemeStore();

/// Longest accepted stored value; anything larger is ignored.
const appThemeStoreMaxLength = 16;

/// In-memory store for tests and child renderers that must not persist.
class MemoryAppThemeStore implements AppThemeStore {
  MemoryAppThemeStore([this.value]);
  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String code) async {
    writes++;
    if (failWith case final error?) throw error;
    value = code;
  }
}
