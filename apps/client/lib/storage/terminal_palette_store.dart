import 'terminal_palette_store_native.dart'
    if (dart.library.js_interop) 'terminal_palette_store_web.dart'
    as platform;

/// Device-local terminal palette overlay (a preset id, or absent to follow the
/// Vault-synced terminal theme).
///
/// Deliberately outside the encrypted Vault/profile stores: it is non-secret,
/// must be readable by credential-free terminal child windows, and keeps the
/// strictly validated synced `terminalTheme` enum unchanged for older clients.
abstract interface class TerminalPaletteStore {
  Future<String?> read();

  /// Null clears the overlay.
  Future<void> write(String? id);
}

TerminalPaletteStore createTerminalPaletteStore() =>
    platform.createTerminalPaletteStore();

/// In-memory store for tests.
class MemoryTerminalPaletteStore implements TerminalPaletteStore {
  MemoryTerminalPaletteStore([this.value]);
  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? id) async {
    writes++;
    if (failWith case final error?) throw error;
    value = id;
  }
}
