// Device-local record of the last credential-visibility mode the user
// acknowledged on this device. Not a secret and never synced: every device
// shows the one-time notice itself (first sign-in counts).
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/secure_store.dart' show secureStorageNamespace;
import 'credential_visibility_models.dart';

class CredentialVisibilityAck {
  const CredentialVisibilityAck({required this.mode, required this.changedAt});

  final CredentialVisibilityMode mode;
  final String? changedAt;

  Map<String, Object?> toJson() => {
    'version': 1,
    'mode': mode.wire,
    'changed_at': changedAt,
  };

  static CredentialVisibilityAck? tryParse(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['version'] != 1) return null;
      final mode = CredentialVisibilityMode.tryParse(json['mode']);
      final changedAt = json['changed_at'];
      if (mode == null || (changedAt != null && changedAt is! String)) {
        return null;
      }
      return CredentialVisibilityAck(
        mode: mode,
        changedAt: changedAt as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

abstract class CredentialVisibilityAckStore {
  /// Persistent per-device store (platform secure storage, which every
  /// supported platform already provides). Failures degrade to "not yet
  /// acknowledged", which only means the notice is shown again.
  factory CredentialVisibilityAckStore.device([FlutterSecureStorage? storage]) =
      _SecureStorageAckStore;

  Future<CredentialVisibilityAck?> read({
    required String serverUrl,
    required String accountId,
  });

  Future<void> write({
    required String serverUrl,
    required String accountId,
    required CredentialVisibilityAck ack,
  });
}

String _ackKey(String serverUrl, String accountId) =>
    'atermius.v1.${Uri.encodeComponent(secureStorageNamespace(serverUrl))}'
    '.credential-visibility-ack.v1.$accountId';

class _SecureStorageAckStore implements CredentialVisibilityAckStore {
  _SecureStorageAckStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<CredentialVisibilityAck?> read({
    required String serverUrl,
    required String accountId,
  }) async {
    try {
      return CredentialVisibilityAck.tryParse(
        await _storage.read(key: _ackKey(serverUrl, accountId)),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write({
    required String serverUrl,
    required String accountId,
    required CredentialVisibilityAck ack,
  }) async {
    try {
      await _storage.write(
        key: _ackKey(serverUrl, accountId),
        value: jsonEncode(ack.toJson()),
      );
    } on Object {
      // Best effort: the notice is shown again on the next start.
    }
  }
}

/// In-memory store for tests.
class MemoryCredentialVisibilityAckStore
    implements CredentialVisibilityAckStore {
  final Map<String, CredentialVisibilityAck> values = {};
  int writes = 0;

  @override
  Future<CredentialVisibilityAck?> read({
    required String serverUrl,
    required String accountId,
  }) async => values[_ackKey(serverUrl, accountId)];

  @override
  Future<void> write({
    required String serverUrl,
    required String accountId,
    required CredentialVisibilityAck ack,
  }) async {
    writes++;
    values[_ackKey(serverUrl, accountId)] = ack;
  }
}
