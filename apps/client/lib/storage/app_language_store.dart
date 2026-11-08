import 'app_language_store_native.dart'
    if (dart.library.js_interop) 'app_language_store_web.dart'
    as platform;

/// Device-local display-language preference.
///
/// This is deliberately outside the encrypted Vault/profile stores: the
/// language must be known before any secure storage is unlocked, and it never
/// contains secrets. Values are the stable codes `system`, `en`, `zh`, `ja`
/// and `ru`.
abstract interface class AppLanguageStore {
  Future<String?> read();
  Future<void> write(String code);
}

AppLanguageStore createAppLanguageStore() => platform.createLanguageStore();

/// In-memory store for tests and child renderers that must not persist.
class MemoryAppLanguageStore implements AppLanguageStore {
  MemoryAppLanguageStore([this.value]);
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String code) async {
    writes++;
    value = code;
  }
}
