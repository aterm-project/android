import 'terminal_keybar_store_native.dart'
    if (dart.library.js_interop) 'terminal_keybar_store_web.dart'
    as platform;

/// Device-local touch keybar preference (currently whether the expanded key
/// rows are pinned open).
///
/// Like the theme and display language this lives outside the encrypted
/// Vault/profile stores: it only affects terminal chrome, never contains
/// secrets and must be readable by credential-free terminal windows.
abstract interface class TerminalKeybarStore {
  Future<String?> read();
  Future<void> write(String value);
}

TerminalKeybarStore createTerminalKeybarStore() =>
    platform.createTerminalKeybarStore();

/// Longest accepted stored value; anything larger is ignored.
const terminalKeybarStoreMaxLength = 16;

/// In-memory store for tests and renderers that must not persist.
class MemoryTerminalKeybarStore implements TerminalKeybarStore {
  MemoryTerminalKeybarStore([this.value]);
  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes++;
    if (failWith case final error?) throw error;
    this.value = value;
  }
}
