import 'local_resume_revocation_native.dart'
    if (dart.library.js_interop) 'local_resume_revocation_web.dart'
    as revocation;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local key retention. Implementations must provide OS protected storage;
/// browser storage is deliberately excluded from this contract.
abstract interface class LocalProfileResumeStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class NativeLocalProfileResumeStore implements LocalProfileResumeStore {
  NativeLocalProfileResumeStore({
    FlutterSecureStorage? storage,
    String keyPrefix = 'atermius',
    Future<bool> Function(String)? isRevoked,
    Future<void> Function(String, bool)? setRevoked,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _key = '$keyPrefix.local-profile-resume.v1',
       _isRevoked = isRevoked ?? revocation.isRevoked,
       _setRevoked = setRevoked ?? revocation.setRevoked;
  final FlutterSecureStorage _storage;
  final String _key;
  final Future<bool> Function(String) _isRevoked;
  final Future<void> Function(String, bool) _setRevoked;
  @override
  Future<String?> read() async =>
      kIsWeb || await _isRevoked(_key) ? null : _storage.read(key: _key);
  @override
  Future<void> write(String value) async {
    if (!kIsWeb) {
      await _storage.write(key: _key, value: value);
      await _setRevoked(_key, false);
    }
  }

  @override
  Future<void> clear() async {
    if (!kIsWeb) {
      // A non-secret durable veto survives a secure-plugin delete failure.
      Object? failure;
      var revoked = false;
      try {
        await _setRevoked(_key, true);
        revoked = true;
      } on Object catch (error) {
        failure = error;
      }
      try {
        await _storage.delete(key: _key);
        revoked = true;
      } on Object catch (error) {
        failure ??= error;
      }
      if (!revoked) {
        throw StateError(
          'Could not revoke local profile resume: ${failure.runtimeType}',
        );
      }
    }
  }
}
