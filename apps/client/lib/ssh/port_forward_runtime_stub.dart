import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';
import 'port_forward_runtime_contract.dart';
import '../l10n/l10n.dart';

String get _unsupportedReason => currentL10n.thisBrowserBuildCannotOpenTcp;

SshPortForwardPlatform createSshPortForwardPlatform() =>
    const _UnsupportedSshPortForwardPlatform();

class _UnsupportedSshPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedSshPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => _unsupportedReason;

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError(_unsupportedReason);
}
