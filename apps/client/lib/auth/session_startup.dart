import 'dart:convert';
import 'session_credentials.dart';

/// Locates a secure snapshot. Contains no password or encryption key.
class SessionResumeHint {
  const SessionResumeHint({
    required this.username,
    required this.accountId,
    required this.deviceId,
  });
  final String username;
  final String accountId;
  final String deviceId;
  String encode() => jsonEncode({
    'username': username.trim().toLowerCase(),
    'account_id': accountId,
    'device_id': deviceId,
  });
  static SessionResumeHint? decode(String? value) {
    if (value == null || value.length > 4096) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic>) return null;
      final fields = ['username', 'account_id', 'device_id'];
      if (fields.any(
        (key) => data[key] is! String || (data[key] as String).trim().isEmpty,
      )) {
        return null;
      }
      return SessionResumeHint(
        username: data['username'] as String,
        accountId: data['account_id'] as String,
        deviceId: data['device_id'] as String,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Startup adopts credentials only after serialized snapshot validation and a
/// live server account/device check. It never loads or decrypts Vault keys.
Future<SessionCredentials> resumeStoredSession({
  required SessionResumeHint hint,
  required SessionRefreshCoordinator coordinator,
  required ReadSessionSnapshot readSnapshot,
  required Future<void> Function(SessionCredentials credentials) verify,
}) async {
  final snapshot = await readSnapshot();
  final stored = snapshot.credentials;
  if (snapshot.status != SessionSnapshotStatus.ready ||
      stored == null ||
      stored.accountId != hint.accountId ||
      stored.deviceId != hint.deviceId) {
    throw const SessionRecoveryRequiredException();
  }
  final outcome = await coordinator.refreshIfNeeded(stored, force: false);
  final credentials = outcome.credentials;
  if (!outcome.persisted ||
      credentials.accountId != hint.accountId ||
      credentials.deviceId != hint.deviceId ||
      !credentials.isAccessUsable()) {
    throw const SessionRecoveryRequiredException();
  }
  await verify(credentials);
  return credentials;
}
