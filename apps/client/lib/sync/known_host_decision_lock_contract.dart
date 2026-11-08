import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Cross-context authorization scope for a synchronized KnownHost Vault.
///
/// The Web lock name contains only a digest so host names, account identifiers,
/// and Vault identifiers do not appear in browser lock diagnostics.
final class KnownHostDecisionScope {
  const KnownHostDecisionScope({
    required this.serverSpaceId,
    required this.vaultId,
  });

  final String serverSpaceId;
  final String vaultId;

  String get lockName {
    if (serverSpaceId.isEmpty || vaultId.isEmpty) {
      throw StateError('KnownHost decision scope is incomplete.');
    }
    final digest = sha256
        .convert(utf8.encode('$serverSpaceId\u0000$vaultId'))
        .toString();
    return 'atermius.known-host-auth.v1.$digest';
  }
}

/// SSH authentication only reads the trust projection and can run concurrently.
/// Any operation that may change or publish that projection uses [exclusive].
enum KnownHostDecisionLockMode { shared, exclusive }

/// Serializes a Vault trust projection update with SSH host-key verification
/// and authentication in every same-origin browser tab.
abstract interface class KnownHostDecisionLock {
  Future<T> run<T>(
    KnownHostDecisionScope scope,
    Future<T> Function() action, {
    KnownHostDecisionLockMode mode = KnownHostDecisionLockMode.exclusive,
    Future<void>? cancel,
  });
}

final class KnownHostDecisionCoordinationUnavailableException
    implements Exception {
  const KnownHostDecisionCoordinationUnavailableException();

  @override
  String toString() =>
      'Browser coordination for SSH host-key trust is unavailable.';
}

final class KnownHostDecisionCancelledException implements Exception {
  const KnownHostDecisionCancelledException();
}
