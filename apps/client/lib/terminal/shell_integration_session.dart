import 'dart:convert';
import 'dart:math';

import 'shell_integration_hook.dart';
import 'shell_integration_protocol.dart';

/// One opt-in shell-integration binding for one live terminal tab.
///
/// The bootstrap command is shown/copied only after an explicit user action.
/// It is not sent to SSH automatically and writes no remote files. Completed
/// commands are returned to the caller as untrusted remote metadata; this class
/// does not persist or synchronize them.
class ShellIntegrationSession {
  factory ShellIntegrationSession({
    required String terminalId,
    String? sessionNonce,
    DateTime? issuedAt,
  }) {
    final issuedAtUtc = (issuedAt ?? DateTime.now()).toUtc();
    final nonce = sessionNonce ?? _newSessionNonce();
    return ShellIntegrationSession._(
      terminalId: terminalId,
      sessionNonce: nonce,
      issuedAt: issuedAtUtc,
    );
  }

  ShellIntegrationSession._({
    required this.terminalId,
    required this.sessionNonce,
    required this.issuedAt,
  }) : expiresAt = issuedAt.add(shellIntegrationMaxSessionLifetime),
       decoder = ShellIntegrationV1Decoder(
         terminalId: terminalId,
         sessionNonce: sessionNonce,
         issuedAt: issuedAt,
         expiresAt: issuedAt.add(shellIntegrationMaxSessionLifetime),
       ),
       bootstrapCommand = ShellIntegrationHook.buildBashCommand(
         sessionNonce: sessionNonce,
         terminalId: terminalId,
       );

  final String terminalId;
  final String sessionNonce;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final ShellIntegrationV1Decoder decoder;
  final String bootstrapCommand;

  bool get isActive => !decoder.isClosed;

  /// Validates one private OSC callback and returns newly completed commands.
  ///
  /// Returned command text originates on the remote host. Callers must render
  /// it as ordinary text and must never execute it or treat it as an audit log.
  List<ShellIntegrationCompletedCommand> accept(
    String code,
    List<String> args, {
    DateTime? now,
  }) {
    final result = decoder.accept(code, args, now: now);
    return result == ShellIntegrationDecodeResult.commandCompleted
        ? decoder.takeCompleted()
        : const <ShellIntegrationCompletedCommand>[];
  }

  void close() => decoder.close();
}

String _newSessionNonce() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  try {
    return base64Url.encode(bytes).replaceAll('=', '');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
