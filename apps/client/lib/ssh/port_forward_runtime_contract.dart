import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';

/// A running forward owned by one SSH connection.
abstract interface class SshPortForwardHandle {
  String get profileId;
  int get listeningPort;
  bool get isClosed;

  /// Client connections currently bridged through this forward.
  int get activeConnections;

  /// Client connections accepted since the forward started.
  int get totalConnections;

  /// Sanitized description of the latest failed client connection (for
  /// example a server-side denial). It never contains credentials.
  String? get lastConnectionError;

  /// Invoked when the counters or [lastConnectionError] change, or when the
  /// forward closes by itself. Set by [SshPortForwardManager].
  set onChanged(void Function()? callback);

  Future<void> close();
}

abstract interface class SshPortForwardPlatform {
  bool get isSupported;

  /// User-facing reason when [isSupported] is false.
  String? get unsupportedReason;

  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  );
}

/// A start failure with a message that is safe to show in the UI.
class SshPortForwardException implements Exception {
  const SshPortForwardException(this.message);

  final String message;

  @override
  String toString() => message;
}
