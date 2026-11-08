import '../l10n/l10n.dart';

/// Fixed failure categories. Raw OS/socket/relay error text is never shown,
/// logged or returned through MCP; only these localized summaries are.
enum TelnetFailure {
  refused,
  timeout,
  hostLookup,
  unreachable,
  relayUnavailable,
  unsupportedPlatform,
  protocol,
  connectionLost,
  cancelled,
}

class TelnetException implements Exception {
  const TelnetException(this.failure);
  final TelnetFailure failure;

  /// Localized, sanitized text. `AppController.friendlyError` falls back to
  /// `toString()`, so this is what users and MCP clients see.
  @override
  String toString() => telnetFailureMessage(failure);
}

String telnetFailureMessage(TelnetFailure failure) {
  final l10n = currentL10n;
  return switch (failure) {
    TelnetFailure.refused => l10n.telnetConnectionRefused,
    TelnetFailure.timeout => l10n.telnetConnectionTimedOut,
    TelnetFailure.hostLookup => l10n.telnetHostLookupFailed,
    TelnetFailure.unreachable => l10n.telnetHostUnreachable,
    TelnetFailure.relayUnavailable => l10n.telnetRelayUnavailable,
    TelnetFailure.unsupportedPlatform => l10n.telnetUnsupportedInBrowser,
    TelnetFailure.protocol => l10n.telnetProtocolError,
    TelnetFailure.connectionLost => l10n.telnetConnectionLost,
    TelnetFailure.cancelled => l10n.telnetConnectCancelled,
  };
}

/// Yellow one-line notice written into a Telnet terminal before connecting,
/// so the plaintext nature is visible in the session itself.
///
/// The endpoint comes from saved/imported Host data, so C0/C1 control
/// characters (ESC, BEL, CR, LF, CSI ...) are removed and the length is
/// bounded before interpolation; only the fixed styling below is emitted.
String telnetPlaintextTerminalNotice(String endpoint) {
  final display = telnetSafeDisplayText(endpoint);
  return '\x1b[33m${telnetSafeDisplayText(currentL10n.telnetPlaintextTerminalNotice(display), maxLength: 1024)}\x1b[0m\r\n';
}

/// Removes terminal control characters and bounds [text] for display inside
/// a terminal.
String telnetSafeDisplayText(String text, {int maxLength = 300}) {
  final clean = text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
  if (clean.length <= maxLength) return clean;
  return '${clean.substring(0, maxLength)}…';
}
