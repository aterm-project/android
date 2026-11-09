import 'sync_preference_store_native.dart'
    if (dart.library.js_interop) 'sync_preference_store_web.dart'
    as platform;

/// Device-local, non-secret sync preferences. Only the "Automatic sync"
/// choice is stored; it is never synced and never contains account data.
abstract interface class SyncPreferenceStore {
  /// Returns the stored automatic-sync choice, or `null` when this device has
  /// never stored one. Throws when an existing value cannot be read or is
  /// not recognised, so callers can fail closed instead of overriding a
  /// previously chosen "off" with the default.
  Future<bool?> readAutomaticSync();

  Future<void> writeAutomaticSync(bool enabled);
}

/// Thrown when a stored sync preference exists but is unreadable.
class SyncPreferenceUnreadableException implements Exception {
  const SyncPreferenceUnreadableException();

  @override
  String toString() => 'SyncPreferenceUnreadableException';
}

/// Exact stored representation: a short, bounded ASCII token.
const syncPreferenceMaxStoredLength = 16;
const _automaticOn = 'automatic=on';
const _automaticOff = 'automatic=off';

String encodeAutomaticSyncPreference(bool enabled) =>
    enabled ? _automaticOn : _automaticOff;

/// Parses a stored value. `null` input means "absent". Anything that is not
/// exactly one of the two tokens is treated as unreadable.
bool? decodeAutomaticSyncPreference(String? raw) {
  if (raw == null) return null;
  if (raw.length > syncPreferenceMaxStoredLength) {
    throw const SyncPreferenceUnreadableException();
  }
  return switch (raw.trim()) {
    _automaticOn => true,
    _automaticOff => false,
    _ => throw const SyncPreferenceUnreadableException(),
  };
}

/// In-memory store used when no platform store is injected (tests, embedded
/// controllers). Absent value resolves to the default.
class MemorySyncPreferenceStore implements SyncPreferenceStore {
  MemorySyncPreferenceStore([this._value]);

  bool? _value;

  @override
  Future<bool?> readAutomaticSync() async => _value;

  @override
  Future<void> writeAutomaticSync(bool enabled) async => _value = enabled;
}

SyncPreferenceStore createSyncPreferenceStore() => platform.createStore();
