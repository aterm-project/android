import 'local_resume_revocation_native.dart'
    if (dart.library.js_interop) 'local_resume_revocation_web.dart'
    as revocation;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/session_credentials.dart';
import '../auth/session_startup.dart';
import '../crypto/vault_crypto.dart';

/// Returns a stable namespace for credentials belonging to one server base URL.
/// Path prefixes matter because one origin can reverse-proxy multiple tenants.
String secureStorageNamespace(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = uri.port == defaultPort ? '' : ':${uri.port}';
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return '$scheme://$host$port${Uri.encodeComponent(path)}';
}

class ServerIdentityPin {
  const ServerIdentityPin({
    required this.instanceId,
    required this.serverSpaceId,
    required this.signingPublicKey,
  });

  final String instanceId;
  final String serverSpaceId;
  final String signingPublicKey;

  Map<String, String> toJson() => {
    'instance_id': instanceId,
    'server_space_id': serverSpaceId,
    'signing_public_key': signingPublicKey,
  };

  static ServerIdentityPin? fromStorage(String? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['instance_id'] is! String ||
        decoded['server_space_id'] is! String ||
        decoded['signing_public_key'] is! String) {
      throw const FormatException('Stored server identity pin is invalid.');
    }
    return ServerIdentityPin(
      instanceId: decoded['instance_id'] as String,
      serverSpaceId: decoded['server_space_id'] as String,
      signingPublicKey: decoded['signing_public_key'] as String,
    );
  }
}

class PendingAccountRecoveryStorageData {
  const PendingAccountRecoveryStorageData({
    required this.request,
    required this.device,
    required this.challengeExpiresAt,
    required this.completionAttempted,
  });

  final Map<String, dynamic> request;
  final Map<String, dynamic> device;
  final DateTime challengeExpiresAt;
  final bool completionAttempted;
}

class RedactionCapabilityReportState {
  const RedactionCapabilityReportState({
    required this.highestRevision,
    this.pendingRevision,
    this.pendingSyncRedactionVersion,
  });

  final int highestRevision;
  final int? pendingRevision;
  final int? pendingSyncRedactionVersion;

  bool get hasPending => pendingRevision != null;

  Map<String, Object?> toJson() => {
    'format': 'atermius-redaction-capability-report-state-v1',
    'highest_revision': highestRevision,
    'pending_revision': pendingRevision,
    'pending_sync_redaction_version': pendingSyncRedactionVersion,
  };

  static RedactionCapabilityReportState fromStorage(String? value) {
    if (value == null) {
      return const RedactionCapabilityReportState(highestRevision: 0);
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'atermius-redaction-capability-report-state-v1' ||
        decoded['highest_revision'] is! int) {
      throw const FormatException(
        'Stored redaction capability report state is invalid.',
      );
    }
    final highest = decoded['highest_revision'] as int;
    final pending = decoded['pending_revision'];
    final version = decoded['pending_sync_redaction_version'];
    if (highest < 0 ||
        highest > 9007199254740991 ||
        (pending != null && pending is! int) ||
        (version != null && version is! int) ||
        (pending == null) != (version == null) ||
        (pending is int && (pending < 1 || pending > highest)) ||
        (version is int && version < 1)) {
      throw const FormatException(
        'Stored redaction capability report state is invalid.',
      );
    }
    return RedactionCapabilityReportState(
      highestRevision: highest,
      pendingRevision: pending as int?,
      pendingSyncRedactionVersion: version as int?,
    );
  }
}

class ClientSecureStore {
  ClientSecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String baseUrl, String kind) {
    final origin = secureStorageNamespace(baseUrl);
    return 'atermius.v1.${Uri.encodeComponent(origin)}.$kind';
  }

  /// Account keys are retained only by native OS secure storage, never by the
  /// web plugin (whose storage is accessible to same-origin scripts).
  Future<void> saveRememberedAccountKey(
    String baseUrl, {
    required Map<String, Object> binding,
    required Uint8List accountKey,
  }) async {
    if (kIsWeb) return;
    if (accountKey.length != 32) {
      throw const FormatException('Invalid account key.');
    }
    await _storage.write(
      key: _key(baseUrl, 'remembered-account-key.v1'),
      value: jsonEncode({
        'version': 1,
        'binding': binding,
        'key': base64Encode(accountKey),
      }),
    );
    await revocation.setRevoked(
      _rememberedKeyRevocationScope(
        baseUrl,
        binding['account_id'] as String,
        binding['device_id'] as String,
      ),
      false,
    );
  }

  Future<Uint8List?> rememberedAccountKey(
    String baseUrl, {
    required Map<String, Object> binding,
  }) async {
    if (kIsWeb ||
        await revocation.isRevoked(
          _rememberedKeyRevocationScope(
            baseUrl,
            binding['account_id'] as String,
            binding['device_id'] as String,
          ),
        )) {
      return null;
    }
    final value = await _storage.read(
      key: _key(baseUrl, 'remembered-account-key.v1'),
    );
    if (value == null || value.length > 8192) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['binding'] is! Map ||
          !mapEquals(
            Map<Object?, Object?>.from(decoded['binding'] as Map),
            binding,
          ) ||
          decoded['key'] is! String) {
        return null;
      }
      final key = base64Decode(decoded['key'] as String);
      if (key.length == 32) return key;
      key.fillRange(0, key.length, 0);
    } on FormatException {
      return null;
    }
    return null;
  }

  String _rememberedKeyRevocationScope(
    String baseUrl,
    String accountId,
    String deviceId,
  ) => _key(
    baseUrl,
    'remembered-account-key.v1.${Uri.encodeComponent(accountId)}.${Uri.encodeComponent(deviceId)}',
  );

  Future<void> clearRememberedAccountKey(
    String baseUrl, {
    String? accountId,
    String? deviceId,
  }) async {
    if (kIsWeb) return;
    final storageKey = _key(baseUrl, 'remembered-account-key.v1');
    String? value;
    try {
      value = await _storage.read(key: storageKey);
      if (value == null) return;
    } catch (_) {
      // Without a readable record, do not delete a possibly newer account's
      // key. A scoped durable veto is sufficient to revoke this identity.
      if (accountId != null && deviceId != null) {
        await revocation.setRevoked(
          _rememberedKeyRevocationScope(baseUrl, accountId, deviceId),
          true,
        );
        return;
      }
      rethrow;
    }
    Map? binding;
    try {
      if (value.length <= 8192) {
        final decoded = jsonDecode(value);
        if (decoded is Map && decoded['binding'] is Map)
          binding = decoded['binding'] as Map;
      }
    } on FormatException {
      // Invalid records cannot authorize auto-unlock.
    }
    if (accountId != null || deviceId != null) {
      if (binding == null) return;
      if (accountId != null && binding['account_id'] != accountId) return;
      if (deviceId != null && binding['device_id'] != deviceId) return;
    }
    final scopedAccount = accountId ?? binding?['account_id'];
    final scopedDevice = deviceId ?? binding?['device_id'];
    var vetoWritten = false;
    if (scopedAccount is String && scopedDevice is String) {
      try {
        await revocation.setRevoked(
          _rememberedKeyRevocationScope(baseUrl, scopedAccount, scopedDevice),
          true,
        );
        vetoWritten = true;
      } catch (_) {
        // Secure deletion is independent of the support-directory marker.
      }
    }
    try {
      await _storage.delete(key: storageKey);
    } catch (_) {
      if (!vetoWritten) {
        throw StateError('Unable to revoke remembered account key.');
      }
    }
  }

  Future<void> saveDevice(String baseUrl, DeviceIdentity identity) async =>
      _storage.write(
        key: _key(baseUrl, 'device'),
        value: jsonEncode(identity.toStorageJson()),
      );

  String _terminalHistorySyncKey({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required String vaultId,
  }) {
    if (accountId.isEmpty || deviceId.isEmpty || vaultId.isEmpty) {
      throw ArgumentError('Terminal history sync scope must not be empty.');
    }
    return _key(
      baseUrl,
      'terminal-history-sync.${Uri.encodeComponent(accountId)}.${Uri.encodeComponent(deviceId)}.${Uri.encodeComponent(vaultId)}',
    );
  }

  String _redactionCapabilityReportStateKey({
    required String baseUrl,
    required String instanceId,
    required String serverSpaceId,
    required String accountId,
    required String deviceId,
  }) {
    if ([
      instanceId,
      serverSpaceId,
      accountId,
      deviceId,
    ].any((value) => value.isEmpty)) {
      throw ArgumentError(
        'Redaction capability report scope must not be empty.',
      );
    }
    return _key(
      baseUrl,
      'redaction-capability-report.${Uri.encodeComponent(instanceId)}.'
      '${Uri.encodeComponent(serverSpaceId)}.'
      '${Uri.encodeComponent(accountId)}.'
      '${Uri.encodeComponent(deviceId)}',
    );
  }

  /// Stores the local high-water mark before a report is sent. The pending
  /// revision is retained across process restarts so an ambiguous network
  /// failure can retry the exact same signed report.
  Future<RedactionCapabilityReportState> redactionCapabilityReportState({
    required String baseUrl,
    required String instanceId,
    required String serverSpaceId,
    required String accountId,
    required String deviceId,
  }) async => RedactionCapabilityReportState.fromStorage(
    await _storage.read(
      key: _redactionCapabilityReportStateKey(
        baseUrl: baseUrl,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        accountId: accountId,
        deviceId: deviceId,
      ),
    ),
  );

  Future<RedactionCapabilityReportState> reserveRedactionCapabilityReport({
    required String baseUrl,
    required String instanceId,
    required String serverSpaceId,
    required String accountId,
    required String deviceId,
    required int syncRedactionVersion,
  }) async {
    if (syncRedactionVersion < 1) {
      throw ArgumentError.value(syncRedactionVersion, 'syncRedactionVersion');
    }
    final key = _redactionCapabilityReportStateKey(
      baseUrl: baseUrl,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      accountId: accountId,
      deviceId: deviceId,
    );
    final current = RedactionCapabilityReportState.fromStorage(
      await _storage.read(key: key),
    );
    if (current.hasPending) return current;
    if (current.highestRevision >= 9007199254740991) {
      throw StateError('Redaction capability report revision is exhausted.');
    }
    final revision = current.highestRevision + 1;
    final reserved = RedactionCapabilityReportState(
      highestRevision: revision,
      pendingRevision: revision,
      pendingSyncRedactionVersion: syncRedactionVersion,
    );
    await _storage.write(key: key, value: jsonEncode(reserved.toJson()));
    return reserved;
  }

  /// A conflict proves that the server retained a higher revision (commonly
  /// after this installation's local marker was lost). Advance durably before
  /// retrying; the server deliberately does not disclose its stored revision.
  Future<RedactionCapabilityReportState>
  advanceRedactionCapabilityReportAfterConflict({
    required String baseUrl,
    required String instanceId,
    required String serverSpaceId,
    required String accountId,
    required String deviceId,
    required int rejectedRevision,
    required int syncRedactionVersion,
  }) async {
    final key = _redactionCapabilityReportStateKey(
      baseUrl: baseUrl,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      accountId: accountId,
      deviceId: deviceId,
    );
    final current = RedactionCapabilityReportState.fromStorage(
      await _storage.read(key: key),
    );
    final base = current.highestRevision > rejectedRevision
        ? current.highestRevision
        : rejectedRevision;
    if (base >= 9007199254740991) {
      throw StateError('Redaction capability report revision is exhausted.');
    }
    final revision = base + 1;
    final advanced = RedactionCapabilityReportState(
      highestRevision: revision,
      pendingRevision: revision,
      pendingSyncRedactionVersion: syncRedactionVersion,
    );
    await _storage.write(key: key, value: jsonEncode(advanced.toJson()));
    return advanced;
  }

  Future<void> completeRedactionCapabilityReport({
    required String baseUrl,
    required String instanceId,
    required String serverSpaceId,
    required String accountId,
    required String deviceId,
    required int acceptedRevision,
  }) async {
    final key = _redactionCapabilityReportStateKey(
      baseUrl: baseUrl,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      accountId: accountId,
      deviceId: deviceId,
    );
    final current = RedactionCapabilityReportState.fromStorage(
      await _storage.read(key: key),
    );
    final completed = RedactionCapabilityReportState(
      highestRevision: current.highestRevision > acceptedRevision
          ? current.highestRevision
          : acceptedRevision,
      pendingRevision: current.pendingRevision == acceptedRevision
          ? null
          : current.pendingRevision,
      pendingSyncRedactionVersion: current.pendingRevision == acceptedRevision
          ? null
          : current.pendingSyncRedactionVersion,
    );
    await _storage.write(key: key, value: jsonEncode(completed.toJson()));
  }

  /// Reads the device-local opt-in for creating encrypted Vault history
  /// records. Missing or malformed values fail closed to disabled. This is a
  /// per-device control and is deliberately not a Vault record itself.
  Future<bool> terminalHistorySyncEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required String vaultId,
  }) async {
    final value = await _storage.read(
      key: _terminalHistorySyncKey(
        baseUrl: baseUrl,
        accountId: accountId,
        deviceId: deviceId,
        vaultId: vaultId,
      ),
    );
    return value == 'true';
  }

  Future<void> setTerminalHistorySyncEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required String vaultId,
    required bool enabled,
  }) => _storage.write(
    key: _terminalHistorySyncKey(
      baseUrl: baseUrl,
      accountId: accountId,
      deviceId: deviceId,
      vaultId: vaultId,
    ),
    value: enabled ? 'true' : 'false',
  );

  String _mobilePushOptInKey({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) {
    if (accountId.isEmpty || deviceId.isEmpty) {
      throw ArgumentError('Mobile push scope must not be empty.');
    }
    return _key(
      baseUrl,
      'mobile-push-opt-in.${Uri.encodeComponent(accountId)}.${Uri.encodeComponent(deviceId)}',
    );
  }

  /// Stores only the user's opt-in bit. The provider token is never written
  /// into app storage; it remains owned by Firebase and is sent to the server
  /// only when needed for registration or token refresh.
  Future<bool> mobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) async =>
      await _storage.read(
        key: _mobilePushOptInKey(
          baseUrl: baseUrl,
          accountId: accountId,
          deviceId: deviceId,
        ),
      ) ==
      'true';

  Future<void> setMobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required bool enabled,
  }) => _storage.write(
    key: _mobilePushOptInKey(
      baseUrl: baseUrl,
      accountId: accountId,
      deviceId: deviceId,
    ),
    value: enabled ? 'true' : 'false',
  );

  Future<void> clearMobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) => _storage.delete(
    key: _mobilePushOptInKey(
      baseUrl: baseUrl,
      accountId: accountId,
      deviceId: deviceId,
    ),
  );

  String _mobilePushCleanupPendingKey({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) {
    if (accountId.isEmpty || deviceId.isEmpty) {
      throw ArgumentError('Mobile push scope must not be empty.');
    }
    return _key(
      baseUrl,
      'mobile-push-cleanup-pending.${Uri.encodeComponent(accountId)}.${Uri.encodeComponent(deviceId)}',
    );
  }

  /// Tracks only whether endpoint deletion should be retried. Provider tokens
  /// and endpoint credentials are never stored in this marker.
  Future<bool> mobilePushCleanupPending({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) async =>
      await _storage.read(
        key: _mobilePushCleanupPendingKey(
          baseUrl: baseUrl,
          accountId: accountId,
          deviceId: deviceId,
        ),
      ) ==
      'true';

  Future<void> setMobilePushCleanupPending({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required bool pending,
  }) => _storage.write(
    key: _mobilePushCleanupPendingKey(
      baseUrl: baseUrl,
      accountId: accountId,
      deviceId: deviceId,
    ),
    value: pending ? 'true' : 'false',
  );

  /// Persists the exact signed full-recovery request and the enrolled device
  /// key needed to retry it after a process restart. This record is scoped to
  /// one normalized server URL. Its `completion_attempted` bit is written
  /// before POST so a restart can distinguish an unsubmitted preparation
  /// (which must be discarded because its one-time code was not persisted)
  /// from a request whose server outcome may be uncertain. As with the other
  /// values stored through FlutterSecureStorage, the default Web implementation
  /// does not protect against same-origin script access or XSS.
  Future<void> savePendingFullAccountRecovery({
    required String baseUrl,
    required Map<String, Object?> request,
    required DeviceIdentity device,
    required DateTime challengeExpiresAt,
    required bool completionAttempted,
  }) => _storage.write(
    key: _key(baseUrl, 'pending-full-account-recovery'),
    value: jsonEncode({
      'version': 1,
      'request': request,
      'device': device.toStorageJson(),
      'challenge_expires_at': challengeExpiresAt.toUtc().toIso8601String(),
      'completion_attempted': completionAttempted,
    }),
  );

  Future<PendingAccountRecoveryStorageData?> loadPendingFullAccountRecovery(
    String baseUrl,
  ) async {
    final value = await _storage.read(
      key: _key(baseUrl, 'pending-full-account-recovery'),
    );
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['request'] is! Map ||
        decoded['device'] is! Map ||
        decoded['challenge_expires_at'] is! String ||
        decoded['completion_attempted'] is! bool) {
      throw const FormatException(
        'Stored full account recovery request is invalid.',
      );
    }
    final expiresAt = DateTime.tryParse(
      decoded['challenge_expires_at'] as String,
    );
    if (expiresAt == null) {
      throw const FormatException(
        'Stored full account recovery expiry is invalid.',
      );
    }
    return PendingAccountRecoveryStorageData(
      request: Map<String, dynamic>.from(decoded['request'] as Map),
      device: Map<String, dynamic>.from(decoded['device'] as Map),
      challengeExpiresAt: expiresAt.toUtc(),
      completionAttempted: decoded['completion_attempted'] as bool,
    );
  }

  Future<void> clearPendingFullAccountRecovery(String baseUrl) =>
      _storage.delete(key: _key(baseUrl, 'pending-full-account-recovery'));

  Future<void> savePendingDevice(
    String baseUrl,
    DeviceIdentity identity, {
    required String accountId,
  }) async {
    await _storage.write(
      key: _key(baseUrl, 'pending-device'),
      value: jsonEncode(identity.toStorageJson()),
    );
    await _storage.write(
      key: _key(baseUrl, 'pending-account'),
      value: accountId,
    );
  }

  Future<DeviceIdentity?> loadPendingDevice(
    String baseUrl,
    VaultCrypto crypto,
  ) async {
    final stored = await _storage.read(key: _key(baseUrl, 'pending-device'));
    if (stored == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) return null;
    return DeviceIdentity.fromStorage(crypto.sodium, decoded);
  }

  Future<String?> pendingAccountId(String baseUrl) =>
      _storage.read(key: _key(baseUrl, 'pending-account'));

  Future<void> savePendingDeviceApproval(String baseUrl, String approvalJson) =>
      _storage.write(
        key: _key(baseUrl, 'pending-device-approval'),
        value: approvalJson,
      );

  Future<String?> pendingDeviceApproval(String baseUrl) =>
      _storage.read(key: _key(baseUrl, 'pending-device-approval'));

  Future<void> clearPendingDeviceApproval(String baseUrl) =>
      _storage.delete(key: _key(baseUrl, 'pending-device-approval'));

  Future<void> clearPendingDevice(String baseUrl) async {
    await _storage.delete(key: _key(baseUrl, 'pending-device'));
    await _storage.delete(key: _key(baseUrl, 'pending-account'));
  }

  Future<DeviceIdentity?> loadDevice(String baseUrl, VaultCrypto crypto) async {
    final stored = await _storage.read(key: _key(baseUrl, 'device'));
    if (stored == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) return null;
    return DeviceIdentity.fromStorage(crypto.sodium, decoded);
  }

  Future<void> saveSessionResumeHint(String baseUrl, SessionResumeHint hint) =>
      _storage.write(
        key: _key(baseUrl, 'session-resume.v1'),
        value: hint.encode(),
      );

  Future<SessionResumeHint?> sessionResumeHint(String baseUrl) async =>
      SessionResumeHint.decode(
        await _storage.read(key: _key(baseUrl, 'session-resume.v1')),
      );

  /// Call under the session coordination lock when a live scope is supplied.
  Future<void> clearSessionResumeHint(
    String baseUrl, {
    String? accountId,
    String? deviceId,
  }) async {
    final current = await sessionResumeHint(baseUrl);
    if (accountId != null && current?.accountId != accountId) return;
    if (deviceId != null && current?.deviceId != deviceId) return;
    await _storage.delete(key: _key(baseUrl, 'session-resume.v1'));
  }

  Future<void> saveRefreshToken(
    String baseUrl,
    String username,
    String token,
  ) async => _storage.write(
    key: _key(
      baseUrl,
      'refresh.${Uri.encodeComponent(username.toLowerCase())}',
    ),
    value: token,
  );

  String _sessionSnapshotKey(
    String baseUrl,
    String username,
    String deviceId,
  ) => _key(
    baseUrl,
    'session.${Uri.encodeComponent(username.toLowerCase())}.${Uri.encodeComponent(deviceId)}',
  );

  /// Persists a complete current session snapshot through FlutterSecureStorage
  /// so same-origin Web tabs can adopt a rotated access token. The update
  /// notification carries no bearer material. The default Web plugin stores
  /// its AES key beside encrypted values in same-origin localStorage, so this
  /// API is not an at-rest or same-origin XSS confidentiality boundary.
  Future<void> saveSessionSnapshot(
    String baseUrl,
    String username,
    SessionCredentials credentials,
  ) async {
    await _storage.write(
      key: _sessionSnapshotKey(baseUrl, username, credentials.deviceId),
      value: jsonEncode({
        'state': 'ready',
        'account_id': credentials.accountId,
        'device_id': credentials.deviceId,
        'access_token': credentials.accessToken,
        'refresh_token': credentials.refreshToken,
        'access_expires_at_ms': credentials.accessExpiresAt
            .toUtc()
            .millisecondsSinceEpoch,
      }),
    );
  }

  /// Persists a same-key interruption marker before a single-use refresh call.
  /// Writing this key replaces the prior ready value atomically from the view
  /// of tabs sharing FlutterSecureStorage. If the request or following ready
  /// snapshot write is interrupted, no tab can replay the old refresh token.
  Future<void> markSessionRotationPending(
    String baseUrl,
    String username,
    SessionScope scope,
  ) async {
    await _storage.write(
      key: _sessionSnapshotKey(baseUrl, username, scope.deviceId),
      value: jsonEncode({
        'state': 'rotation_pending',
        'account_id': scope.accountId,
        'device_id': scope.deviceId,
      }),
    );
  }

  /// Persists a ready snapshot and the legacy refresh-token key used by older
  /// local flows. Coordinated refreshes write the authoritative snapshot first.
  Future<void> saveSessionCredentials(
    String baseUrl,
    String username,
    SessionCredentials credentials,
  ) async {
    // The legacy key is not authoritative for new builds, but older tabs may
    // still use it. Refresh it before publishing this session as ready so an
    // interrupted migration cannot expose the already-consumed old token.
    await saveRefreshToken(baseUrl, username, credentials.refreshToken);
    await saveSessionSnapshot(baseUrl, username, credentials);
  }

  Future<SessionCredentials?> readSessionCredentials(
    String baseUrl,
    String username,
    String deviceId,
  ) async {
    final snapshot = await readSessionSnapshot(baseUrl, username, deviceId);
    return snapshot.status == SessionSnapshotStatus.ready
        ? snapshot.credentials
        : null;
  }

  /// Reads a snapshot without conflating absent, corrupt, and interrupted
  /// rotation states. A caller must not use an in-memory refresh token when
  /// this does not return [SessionSnapshotStatus.ready].
  Future<SessionSnapshotRead> readSessionSnapshot(
    String baseUrl,
    String username,
    String deviceId,
  ) async {
    final value = await _storage.read(
      key: _sessionSnapshotKey(baseUrl, username, deviceId),
    );
    if (value == null) return const SessionSnapshotRead.missing();
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic> ||
          decoded['account_id'] is! String ||
          (decoded['account_id'] as String).isEmpty ||
          decoded['device_id'] is! String ||
          decoded['device_id'] != deviceId) {
        return const SessionSnapshotRead.invalid();
      }
      final state = decoded['state'];
      if (state == 'rotation_pending') {
        return const SessionSnapshotRead.rotationPending();
      }
      if (state != null && state != 'ready') {
        return const SessionSnapshotRead.invalid();
      }
      if (decoded['access_token'] is! String ||
          (decoded['access_token'] as String).isEmpty ||
          decoded['refresh_token'] is! String ||
          (decoded['refresh_token'] as String).isEmpty ||
          decoded['access_expires_at_ms'] is! int) {
        return const SessionSnapshotRead.invalid();
      }
      return SessionSnapshotRead.ready(
        SessionCredentials(
          accountId: decoded['account_id'] as String,
          deviceId: decoded['device_id'] as String,
          accessToken: decoded['access_token'] as String,
          refreshToken: decoded['refresh_token'] as String,
          accessExpiresAt: DateTime.fromMillisecondsSinceEpoch(
            decoded['access_expires_at_ms'] as int,
            isUtc: true,
          ),
        ),
      );
    } on FormatException {
      return const SessionSnapshotRead.invalid();
    }
  }

  /// Removes this tab's snapshot only if it is still current. A delayed logout
  /// must not erase credentials written by a newer login in another tab.
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async {
    final latest = await readSessionCredentials(baseUrl, username, deviceId);
    final refreshToken =
        latest?.refreshToken ?? await readRefreshToken(baseUrl, username);
    if (refreshToken != expectedRefreshToken) return false;
    await clearRememberedAccountKey(
      baseUrl,
      accountId: latest?.accountId,
      deviceId: deviceId,
    );
    await _storage.delete(
      key: _sessionSnapshotKey(baseUrl, username, deviceId),
    );
    await _storage.delete(
      key: _key(
        baseUrl,
        'refresh.${Uri.encodeComponent(username.toLowerCase())}',
      ),
    );
    return true;
  }

  Future<String?> readRefreshToken(String baseUrl, String username) =>
      _storage.read(
        key: _key(
          baseUrl,
          'refresh.${Uri.encodeComponent(username.toLowerCase())}',
        ),
      );

  Future<void> deleteRefreshToken(String baseUrl, String username) async {
    await _storage.delete(
      key: _key(
        baseUrl,
        'refresh.${Uri.encodeComponent(username.toLowerCase())}',
      ),
    );
    final sessionPrefix = _key(
      baseUrl,
      'session.${Uri.encodeComponent(username.toLowerCase())}.',
    );
    final entries = await _storage.readAll();
    final sessionKeys = entries.keys
        .where((key) => key.startsWith(sessionPrefix))
        .toList(growable: false);
    for (final key in sessionKeys) {
      final value = entries[key];
      if (value != null) {
        try {
          final snapshot = jsonDecode(value);
          if (snapshot is Map &&
              snapshot['account_id'] is String &&
              snapshot['device_id'] is String) {
            await clearRememberedAccountKey(
              baseUrl,
              accountId: snapshot['account_id'] as String,
              deviceId: snapshot['device_id'] as String,
            );
          }
        } on FormatException {
          // Corrupt snapshots cannot authenticate a remembered key.
        }
      }
      await _storage.delete(key: key);
    }
  }

  Future<String?> readKnownHost(String baseUrl, String endpoint) =>
      _storage.read(
        key: _key(
          baseUrl,
          'known-host.${Uri.encodeComponent(endpoint.toLowerCase())}',
        ),
      );

  Future<void> saveKnownHost(
    String baseUrl,
    String endpoint,
    String fingerprint,
  ) => _storage.write(
    key: _key(
      baseUrl,
      'known-host.${Uri.encodeComponent(endpoint.toLowerCase())}',
    ),
    value: fingerprint,
  );

  Future<void> clearKnownHost(String baseUrl, String endpoint) =>
      _storage.delete(
        key: _key(
          baseUrl,
          'known-host.${Uri.encodeComponent(endpoint.toLowerCase())}',
        ),
      );

  Future<ServerIdentityPin?> readServerIdentityPin(String baseUrl) async =>
      ServerIdentityPin.fromStorage(
        await _storage.read(key: _key(baseUrl, 'instance-identity')),
      );

  Future<void> saveServerIdentityPin(String baseUrl, ServerIdentityPin pin) =>
      _storage.write(
        key: _key(baseUrl, 'instance-identity'),
        value: jsonEncode(pin.toJson()),
      );

  Future<void> saveLastServer(String baseUrl) =>
      _storage.write(key: 'atermius.v1.last_server', value: baseUrl);

  Future<String?> lastServer() => _storage.read(key: 'atermius.v1.last_server');
}
