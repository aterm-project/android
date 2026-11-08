import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb;

import '../crypto/jcs.dart';
import 'local_profile_resume_store.dart';

import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../crypto/vault_crypto.dart';
import 'local_profile_catalog.dart';
import 'local_profile_bootstrap_lock.dart';

/// Creates and unlocks local-only profile key hierarchies.
///
/// This service has no API, server session, SyncRepository, or shared server
/// database dependency. Its catalog contains only metadata and encrypted key
/// envelopes; unlocked key material is owned by [UnlockedLocalProfile].
class LocalProfileService {
  factory LocalProfileService({
    required LocalProfileCatalog catalog,
    required VaultCrypto crypto,
    Uuid uuid = const Uuid(),
    LocalProfileResumeStore? resumeStore,
    LocalProfileResumeStore? deviceKeyStore,
  }) => LocalProfileService._(
    catalog,
    crypto,
    uuid,
    resumeStore ?? NativeLocalProfileResumeStore(),
    deviceKeyStore ??
        NativeLocalProfileResumeStore(keyPrefix: 'atermius.device-key'),
  );

  LocalProfileService._(
    this._catalog,
    this._crypto,
    this._uuid,
    this._resumeStore,
    this._deviceKeyStore,
  );

  static const minimumPasswordLength = 12;

  final LocalProfileCatalog _catalog;
  final VaultCrypto _crypto;
  final Uuid _uuid;
  final LocalProfileResumeStore _resumeStore;
  final LocalProfileResumeStore _deviceKeyStore;

  String _fingerprint(LocalProfileRecord record) => sha256
      .convert(
        utf8.encode(
          canonicalJson({
            'version': record.profileVersion,
            'profile': record.profileId,
            'domain': record.localDataDomainId,
            'umk': record.umkEnvelope,
            'vault': record.vaultKeyEnvelope,
            'device': record.deviceIdentityEnvelope,
          }),
        ),
      )
      .toString();

  /// Storage failures leave password-based use available without startup errors.
  Future<void> remember(UnlockedLocalProfile profile) async {
    final key = profile.copyUmk();
    try {
      await _resumeStore.write(
        jsonEncode({
          'version': 1,
          'profile_id': profile.record.profileId,
          'fingerprint': _fingerprint(profile.record),
          'umk': base64Encode(key),
        }),
      );
    } on Object {
      try {
        await forgetResume();
      } on Object {
        /* Manual use still works. */
      }
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Future<void> forgetResume() => _resumeStore.clear();

  Future<UnlockedLocalProfile?> tryResume() => _tryResumeFrom(_resumeStore);

  Future<bool> isDeviceManaged(String profileId) async {
    try {
      final value = await _deviceKeyStore.read();
      if (value == null || value.length > 32768) return false;
      final data = jsonDecode(value);
      final record = await _catalog.get(profileId);
      return record != null &&
          data is Map<String, dynamic> &&
          data['profile_id'] == profileId &&
          data['fingerprint'] == _fingerprint(record);
    } on Object {
      return false;
    }
  }

  /// Explicit user action can reopen device-managed profiles after manual lock.
  /// The durable device key never enables startup resume by itself.
  Future<UnlockedLocalProfile?> unlockDeviceProfile(String profileId) async {
    final profile = await _tryResumeFrom(
      _deviceKeyStore,
      clearOnFailure: false,
    );
    if (profile == null || profile.record.profileId == profileId) {
      return profile;
    }
    await profile.lock();
    return null;
  }

  Future<UnlockedLocalProfile?> _tryResumeFrom(
    LocalProfileResumeStore store, {
    bool clearOnFailure = true,
  }) async {
    Uint8List? umk;
    Uint8List? vaultKey;
    DeviceIdentity? identity;
    try {
      final stored = await store.read();
      if (stored == null) return null;
      if (stored.length > 32768) {
        throw const FormatException('Invalid resume size');
      }
      final data = jsonDecode(stored);
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['profile_id'] is! String ||
          data['umk'] is! String) {
        throw const FormatException('Invalid resume record');
      }
      final record = await _catalog.get(data['profile_id'] as String);
      if (record == null || data['fingerprint'] != _fingerprint(record)) {
        throw const FormatException('Stale resume record');
      }
      umk = base64Decode(data['umk'] as String);
      if (umk.length != 32) throw const FormatException('Invalid resume key');
      vaultKey = await _crypto.unwrapLocalVaultKey(
        umk: umk,
        envelope: Map<String, dynamic>.from(record.vaultKeyEnvelope),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
        keyEpoch: record.vaultKeyEpoch,
      );
      identity = await _crypto.unwrapLocalDeviceIdentity(
        umk: umk,
        envelope: Map<String, dynamic>.from(record.deviceIdentityEnvelope),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localDeviceId: record.localDeviceId,
        keyVersion: record.deviceKeyVersion,
      );
      final profile = UnlockedLocalProfile._(
        record: record,
        umk: umk,
        vaultKey: vaultKey,
        identity: identity,
      );
      umk = null;
      vaultKey = null;
      identity = null;
      return profile;
    } on Object {
      if (clearOnFailure) {
        try {
          await store.clear();
        } on Object {
          /* Manual use still works. */
        }
      }
      return null;
    } finally {
      umk?.fillRange(0, umk.length, 0);
      vaultKey?.fillRange(0, vaultKey.length, 0);
      identity?.dispose();
    }
  }

  /// Creates a profile with fresh independent identifiers and random keys.
  /// The returned profile is already unlocked; call [UnlockedLocalProfile.lock]
  /// when its foreground session ends.
  Future<UnlockedLocalProfile> create({required String password}) =>
      _create(password: password);

  /// A fresh native workspace requires durable OS-protected key retention.
  /// Existing profiles are never replaced or given a new unlock mechanism.
  Future<UnlockedLocalProfile> createDeviceProtected({
    Future<void> Function(UnlockedLocalProfile profile)? initializeVault,
  }) => withLocalProfileBootstrapLock(() async {
    if (kIsWeb) throw StateError('Device bootstrap requires native storage.');
    final profiles = await _catalog.list();
    if (profiles.isNotEmpty) {
      if (profiles.length == 1 &&
          await isDeviceManaged(profiles.single.profileId)) {
        final resumed = await tryResume();
        if (resumed != null &&
            resumed.record.profileId == profiles.single.profileId) {
          return resumed;
        }
        await resumed?.lock();
      }
      throw StateError('Existing local profiles require their normal unlock.');
    }
    // Incomplete cleanup must never overwrite the only retained key. Its
    // protected staged descriptor remains available for recovery.
    if (await _deviceKeyStore.read() != null ||
        await _resumeStore.read() != null) {
      throw StateError('Incomplete protected bootstrap requires recovery.');
    }
    final random = _crypto.randomBytes(32);
    try {
      return await _create(
        password: base64Encode(random),
        requireResumePersistence: true,
        initializeVault: initializeVault,
      );
    } finally {
      random.fillRange(0, random.length, 0);
    }
  });

  Future<void> _clearBootstrapKey(
    LocalProfileResumeStore store,
    String profileId,
  ) async {
    try {
      final value = await store.read();
      if (value == null || value.length > 32768) return;
      final data = jsonDecode(value);
      if (data is Map<String, dynamic> && data['profile_id'] == profileId) {
        await store.clear();
      }
    } on Object {
      /* Preserve unreadable keys instead of deleting another owner. */
    }
  }

  Future<UnlockedLocalProfile> _create({
    required String password,
    bool requireResumePersistence = false,
    Future<void> Function(UnlockedLocalProfile profile)? initializeVault,
  }) async {
    if (password.length < minimumPasswordLength) {
      throw const FormatException('Local master password is too short.');
    }

    final profileId = _uuid.v4();
    final localDataDomainId = _uuid.v4();
    final localVaultId = _uuid.v4();
    final kdf = KdfParameters.defaults(_crypto.sodium);
    Uint8List? umk;
    Uint8List? vaultKey;
    DeviceIdentity? identity;
    try {
      umk = _crypto.randomBytes(32);
      vaultKey = _crypto.randomBytes(32);
      identity = DeviceIdentity.create(_crypto.sodium);

      final umkEnvelope = await _crypto.wrapLocalUmk(
        password: password,
        params: kdf,
        umk: umk,
        profileId: profileId,
        localDataDomainId: localDataDomainId,
      );
      final vaultKeyEnvelope = await _crypto.wrapLocalVaultKey(
        umk: umk,
        vaultKey: vaultKey,
        profileId: profileId,
        localDataDomainId: localDataDomainId,
        localVaultId: localVaultId,
        keyEpoch: 1,
      );
      final deviceIdentityEnvelope = await _crypto.wrapLocalDeviceIdentity(
        umk: umk,
        identity: identity,
        profileId: profileId,
        localDataDomainId: localDataDomainId,
        localDeviceId: identity.deviceId,
        keyVersion: 1,
      );

      LocalProfileRecord? stagedRecord;
      if (requireResumePersistence) {
        final staged = LocalProfileRecord.create(
          profileId: profileId,
          localDataDomainId: localDataDomainId,
          localVaultId: localVaultId,
          localDeviceId: identity.deviceId,
          kdfMetadata: kdf.toJson(),
          umkEnvelope: umkEnvelope,
          vaultKeyEnvelope: vaultKeyEnvelope,
          deviceIdentityEnvelope: deviceIdentityEnvelope,
        );
        stagedRecord = staged;
        final retained = jsonEncode({
          'version': 1,
          'profile_id': profileId,
          'fingerprint': _fingerprint(staged),
          'umk': base64Encode(umk),
        });
        try {
          final deviceRetained = jsonEncode({
            ...jsonDecode(retained) as Map<String, dynamic>,
            'pending_profile': staged.toJson(),
          });
          await _deviceKeyStore.write(deviceRetained);
          if (await _deviceKeyStore.read() != deviceRetained) {
            throw StateError(
              'Protected device key persistence could not be verified.',
            );
          }
          await _resumeStore.write(retained);
          if (await _resumeStore.read() != retained) {
            throw StateError(
              'Protected key persistence could not be verified.',
            );
          }
        } on Object {
          rethrow;
        }
      }

      if (initializeVault != null) {
        final stagedProfile = UnlockedLocalProfile._(
          record: stagedRecord!,
          umk: umk,
          vaultKey: vaultKey,
          identity: identity,
          isNewlyCreated: true,
        );
        await initializeVault(stagedProfile);
        stagedProfile._requireUnlocked();
      }
      // Publishing the catalog row is last: contenders must see a fully
      // initialized Vault, never a profile whose binding is still pending.
      final record = await _catalog.create(
        profileId: profileId,
        localDataDomainId: localDataDomainId,
        localVaultId: localVaultId,
        localDeviceId: identity.deviceId,
        kdfMetadata: kdf.toJson(),
        umkEnvelope: umkEnvelope,
        vaultKeyEnvelope: vaultKeyEnvelope,
        deviceIdentityEnvelope: deviceIdentityEnvelope,
      );
      final unlocked = UnlockedLocalProfile._(
        isNewlyCreated: true,
        record: record,
        umk: umk,
        vaultKey: vaultKey,
        identity: identity,
      );
      umk = null;
      vaultKey = null;
      identity = null;
      return unlocked;
    } on Object {
      if (requireResumePersistence) {
        try {
          // A database exception may follow a durable commit: retain its keys.
          if (await _catalog.get(profileId) == null) {
            await _clearBootstrapKey(_resumeStore, profileId);
            await _clearBootstrapKey(_deviceKeyStore, profileId);
          }
        } on Object {
          /* Keep protected recovery material on uncertain commit. */
        }
      }
      rethrow;
    } finally {
      umk?.fillRange(0, umk.length, 0);
      vaultKey?.fillRange(0, vaultKey.length, 0);
      identity?.dispose();
    }
  }

  /// Opens one catalog row and authenticates all three key envelopes before
  /// returning an unlocked profile. Wrong passwords and tampered envelopes
  /// fail closed and clear any key material opened earlier in the sequence.
  Future<UnlockedLocalProfile> unlock({
    required String profileId,
    required String password,
  }) async {
    final record = await _catalog.get(profileId);
    if (record == null) {
      throw StateError('Local profile does not exist.');
    }

    Uint8List? umk;
    Uint8List? vaultKey;
    DeviceIdentity? identity;
    try {
      umk = await _crypto.unwrapLocalUmk(
        password: password,
        envelope: Map<String, dynamic>.from(record.umkEnvelope),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
      );
      vaultKey = await _crypto.unwrapLocalVaultKey(
        umk: umk,
        envelope: Map<String, dynamic>.from(record.vaultKeyEnvelope),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
        keyEpoch: record.vaultKeyEpoch,
      );
      identity = await _crypto.unwrapLocalDeviceIdentity(
        umk: umk,
        envelope: Map<String, dynamic>.from(record.deviceIdentityEnvelope),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localDeviceId: record.localDeviceId,
        keyVersion: record.deviceKeyVersion,
      );

      final unlocked = UnlockedLocalProfile._(
        record: record,
        umk: umk,
        vaultKey: vaultKey,
        identity: identity,
      );
      umk = null;
      vaultKey = null;
      identity = null;
      return unlocked;
    } finally {
      umk?.fillRange(0, umk.length, 0);
      vaultKey?.fillRange(0, vaultKey.length, 0);
      identity?.dispose();
    }
  }
}

/// In-memory unlocked key state for one local profile.
///
/// Call [lock] as soon as the user locks or leaves the local profile. Dart
/// cannot guarantee erasure of prior runtime copies, so the service only
/// exposes explicit mutable key copies and a borrowed DeviceIdentity callback;
/// callers must clear copies and must not retain the borrowed identity.
class UnlockedLocalProfile {
  UnlockedLocalProfile._({
    required this.record,
    required this._umk,
    required this._vaultKey,
    required this._identity,
    this.isNewlyCreated = false,
  });

  final LocalProfileRecord record;
  final bool isNewlyCreated;
  final Uint8List _umk;
  final Uint8List _vaultKey;
  DeviceIdentity? _identity;
  bool _locked = false;
  bool _locking = false;
  int _activeIdentityUses = 0;
  Completer<void>? _identityUsesDrained;
  Completer<void>? _lockCompleted;

  bool get isLocked => _locked || _locking;

  Uint8List copyUmk() {
    _requireUnlocked();
    return Uint8List.fromList(_umk);
  }

  Uint8List copyVaultKey() {
    _requireUnlocked();
    return Uint8List.fromList(_vaultKey);
  }

  /// Borrows the identity for the entire sync or async callback. Calling
  /// [lock] while an operation is active prevents new uses and waits for this
  /// callback to finish before disposing its private keys.
  Future<T> withDeviceIdentity<T>(
    FutureOr<T> Function(DeviceIdentity identity) operation,
  ) async {
    _requireUnlocked();
    _activeIdentityUses++;
    try {
      return await operation(_identity!);
    } finally {
      _activeIdentityUses--;
      if (_activeIdentityUses == 0) {
        _identityUsesDrained?.complete();
      }
    }
  }

  /// Best-effort clears owned mutable key bytes and disposes private-key
  /// SecureKeys. Repeated or concurrent calls are safe. The future completes
  /// only after any borrowed identity callback has returned.
  Future<void> lock() async {
    if (_locked) return;
    if (_locking) {
      await _lockCompleted!.future;
      return;
    }

    _locking = true;
    final completed = Completer<void>();
    _lockCompleted = completed;
    try {
      if (_activeIdentityUses > 0) {
        final drained = Completer<void>();
        _identityUsesDrained = drained;
        await drained.future;
      }
      _umk.fillRange(0, _umk.length, 0);
      _vaultKey.fillRange(0, _vaultKey.length, 0);
      final identity = _identity;
      _identity = null;
      _locked = true;
      identity?.dispose();
    } finally {
      _identityUsesDrained = null;
      _locking = false;
      _lockCompleted = null;
      completed.complete();
    }
  }

  void _requireUnlocked() {
    if (_locked || _locking) throw StateError('Local profile is locked.');
  }
}
