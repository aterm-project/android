import 'dart:collection';
import 'dart:convert';

/// Bounds for the accepted Atermius private-OSC command-history protocol.
const int shellIntegrationMaxCommandBytes = 4096;
const int shellIntegrationCompletedQueueLimit = 16;
const Duration shellIntegrationMaxSessionLifetime = Duration(hours: 12);
const Duration shellIntegrationMaxPendingCommandAge = Duration(hours: 2);

const int _maxSafeInteger = 9007199254740991;
const String _shellIntegrationOscCode = '777';
const String _shellIntegrationNamespace = 'atermius';
const String _shellIntegrationVersion = 'v1';
final RegExp _sessionNoncePattern = RegExp(r'^[A-Za-z0-9_-]{22}$');
final RegExp _terminalIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final RegExp _sequencePattern = RegExp(r'^[1-9][0-9]{0,15}$');
final RegExp _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _exitStatusPattern = RegExp(r'^(0|[1-9][0-9]{0,2})$');

/// Result of inspecting one xterm `onPrivateOSC` callback.
///
/// The result intentionally contains no diagnostic text derived from remote
/// input. Callers can distinguish an unrelated OSC from a rejected protocol
/// event without logging or displaying its payload.
enum ShellIntegrationDecodeResult {
  ignored,
  commandStarted,
  commandCompleted,
  rejected,
  closed,
}

/// A complete, paired shell command event awaiting client-side consumption.
///
/// [command] is untrusted remote metadata. Render it as ordinary escaped text;
/// never feed it to the terminal or execute it automatically.
class ShellIntegrationCompletedCommand {
  const ShellIntegrationCompletedCommand({
    required this.commandId,
    required this.command,
    required this.exitStatus,
    required this.startedAt,
    required this.completedAt,
  });

  final int commandId;
  final String command;
  final int exitStatus;
  final DateTime startedAt;
  final DateTime completedAt;
}

/// Strict decoder for the opt-in Atermius shell-integration private OSC v1.
///
/// Framing passed to xterm's `onPrivateOSC` callback uses OSC code `777` and
/// exactly seven arguments, in this order:
///
/// 1. `atermius` namespace
/// 2. `v1` protocol version
/// 3. 128-bit base64url session nonce
/// 4. terminal/tab ID
/// 5. canonical positive decimal command ID
/// 6. `start` or `end` event kind
/// 7. base64url UTF-8 command for `start`, canonical decimal exit status for
///    `end`
///
/// A command is exposed only after one valid start and its matching end/status
/// event. IDs start at 1 and increase by exactly one for each completed command. The decoder keeps one pending command and
/// a bounded queue of at most [shellIntegrationCompletedQueueLimit] completed
/// commands; malformed or out-of-order namespace events close it and discard
/// queued data.
///
/// Remote OSC is untrusted convenience metadata, not an authoritative shell
/// audit or security signal. This module does not inspect raw terminal input or
/// echoed output, render events, persist history, sync records, or install a
/// shell hook. In the current xterm fork, `onPrivateOSC` runs only after the
/// OSC parser has collected a BEL/ST terminator, so these payload limits do not
/// bound memory used by an oversized unterminated OSC frame. Parser-level frame
/// limits require a separate compatibility review for other OSC features.
class ShellIntegrationV1Decoder {
  ShellIntegrationV1Decoder({
    required String sessionNonce,
    required String terminalId,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) : _sessionNonce = sessionNonce,
       _terminalId = terminalId,
       _issuedAt = issuedAt.toUtc(),
       _expiresAt = expiresAt.toUtc(),
       _lastObservedAt = issuedAt.toUtc() {
    if (!_isCanonicalSessionNonce(sessionNonce) ||
        !_terminalIdPattern.hasMatch(terminalId) ||
        !_expiresAt.isAfter(_issuedAt) ||
        _expiresAt.difference(_issuedAt) > shellIntegrationMaxSessionLifetime) {
      throw ArgumentError('Invalid shell-integration session binding.');
    }
  }

  final String _sessionNonce;
  final String _terminalId;
  final DateTime _issuedAt;
  final DateTime _expiresAt;
  final Queue<ShellIntegrationCompletedCommand> _completed = Queue();

  _PendingShellCommand? _pending;
  DateTime _lastObservedAt;
  int _nextCommandId = 1;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Accepts the [code] and [args] values from xterm `onPrivateOSC`.
  ///
  /// Other OSC codes and OSC 777 events outside the `atermius` namespace are
  /// ignored. Once an event claims this namespace and v1, invalid framing,
  /// command contents, IDs, or ordering close the decoder fail-closed.
  ShellIntegrationDecodeResult accept(
    String code,
    List<String> args, {
    DateTime? now,
  }) {
    if (_closed) return ShellIntegrationDecodeResult.closed;

    final observedAt = (now ?? DateTime.now()).toUtc();
    if (!_observeTime(observedAt)) {
      _close();
      return ShellIntegrationDecodeResult.closed;
    }

    if (code != _shellIntegrationOscCode ||
        args.isEmpty ||
        args.first != _shellIntegrationNamespace) {
      return ShellIntegrationDecodeResult.ignored;
    }

    // Exact field count: namespace, version, nonce, tab, command id, event,
    // payload. Do not parse a prefix and accidentally accept trailing fields.
    if (args.length != 7 || args[1] != _shellIntegrationVersion) {
      return _rejectAndClose();
    }
    const maxEncodedCommandLength =
        ((shellIntegrationMaxCommandBytes + 2) ~/ 3) * 4;
    if (!_isCanonicalSessionNonce(args[2]) ||
        !_terminalIdPattern.hasMatch(args[3]) ||
        !_sequencePattern.hasMatch(args[4]) ||
        args[5].length > 5 ||
        !const {'start', 'end'}.contains(args[5]) ||
        (args[5] == 'end' && args[6].length > 3) ||
        (args[5] == 'start' && args[6].length > maxEncodedCommandLength)) {
      return _rejectAndClose();
    }

    // A valid event from another session/tab is stale for this decoder. It is
    // rejected without disturbing this tab's in-flight command.
    if (args[2] != _sessionNonce || args[3] != _terminalId) {
      return ShellIntegrationDecodeResult.rejected;
    }

    final commandId = _parseCommandId(args[4]);
    if (commandId == null || commandId >= _maxSafeInteger) {
      return _rejectAndClose();
    }

    switch (args[5]) {
      case 'start':
        return _acceptStart(commandId, args[6], observedAt);
      case 'end':
        return _acceptEnd(commandId, args[6], observedAt);
      default:
        return _rejectAndClose();
    }
  }

  /// Removes all currently queued completions in FIFO order.
  List<ShellIntegrationCompletedCommand> takeCompleted() {
    if (_completed.isEmpty) return const [];
    final drained = List<ShellIntegrationCompletedCommand>.unmodifiable(
      _completed,
    );
    _completed.clear();
    return drained;
  }

  /// Drops pending and completed protocol state and permanently closes decoder.
  void close() => _close();

  bool _observeTime(DateTime observedAt) {
    if (observedAt.isBefore(_lastObservedAt) ||
        observedAt.isBefore(_issuedAt) ||
        !observedAt.isBefore(_expiresAt)) {
      return false;
    }
    final pending = _pending;
    if (pending != null &&
        observedAt.difference(pending.startedAt) >
            shellIntegrationMaxPendingCommandAge) {
      return false;
    }
    _lastObservedAt = observedAt;
    return true;
  }

  ShellIntegrationDecodeResult _acceptStart(
    int commandId,
    String encodedCommand,
    DateTime observedAt,
  ) {
    if (_pending != null || commandId != _nextCommandId) {
      return _rejectAndClose();
    }
    final command = _decodeCommand(encodedCommand);
    if (command == null) return _rejectAndClose();
    _pending = _PendingShellCommand(
      commandId: commandId,
      command: command,
      startedAt: observedAt,
    );
    return ShellIntegrationDecodeResult.commandStarted;
  }

  ShellIntegrationDecodeResult _acceptEnd(
    int commandId,
    String encodedStatus,
    DateTime observedAt,
  ) {
    final pending = _pending;
    final exitStatus = _parseExitStatus(encodedStatus);
    if (pending == null ||
        pending.commandId != commandId ||
        exitStatus == null) {
      return _rejectAndClose();
    }
    if (_completed.length >= shellIntegrationCompletedQueueLimit) {
      return _rejectAndClose();
    }
    _completed.add(
      ShellIntegrationCompletedCommand(
        commandId: commandId,
        command: pending.command,
        exitStatus: exitStatus,
        startedAt: pending.startedAt,
        completedAt: observedAt,
      ),
    );
    _pending = null;
    _nextCommandId = commandId + 1;
    return ShellIntegrationDecodeResult.commandCompleted;
  }

  int? _parseCommandId(String value) {
    if (!_sequencePattern.hasMatch(value)) return null;
    final parsed = int.tryParse(value);
    if (parsed == null ||
        parsed.toString() != value ||
        parsed > _maxSafeInteger) {
      return null;
    }
    return parsed;
  }

  int? _parseExitStatus(String value) {
    if (!_exitStatusPattern.hasMatch(value)) return null;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed > 255 || parsed.toString() != value) {
      return null;
    }
    return parsed;
  }

  String? _decodeCommand(String encoded) {
    const maxEncodedLength = ((shellIntegrationMaxCommandBytes + 2) ~/ 3) * 4;
    if (encoded.isEmpty ||
        encoded.length > maxEncodedLength ||
        !_base64UrlPattern.hasMatch(encoded) ||
        encoded.length % 4 == 1) {
      return null;
    }

    try {
      final remainder = encoded.length % 4;
      if (remainder == 1) return null;
      final padded =
          encoded +
          (remainder == 2
              ? '=='
              : remainder == 3
              ? '='
              : '');
      final bytes = base64Url.decode(padded);
      if (bytes.isEmpty ||
          bytes.length > shellIntegrationMaxCommandBytes ||
          base64Url.encode(bytes).replaceAll('=', '') != encoded) {
        return null;
      }
      final command = utf8.decode(bytes, allowMalformed: false);
      if (_hasForbiddenControlCharacter(command)) return null;
      return command;
    } on FormatException {
      return null;
    }
  }

  ShellIntegrationDecodeResult _rejectAndClose() {
    _close();
    return ShellIntegrationDecodeResult.rejected;
  }

  void _close() {
    _closed = true;
    _pending = null;
    _completed.clear();
  }
}

class _PendingShellCommand {
  const _PendingShellCommand({
    required this.commandId,
    required this.command,
    required this.startedAt,
  });

  final int commandId;
  final String command;
  final DateTime startedAt;
}

bool _isCanonicalSessionNonce(String nonce) {
  if (!_sessionNoncePattern.hasMatch(nonce)) return false;
  try {
    final bytes = base64Url.decode('$nonce==');
    return bytes.length == 16 &&
        base64Url.encode(bytes).replaceAll('=', '') == nonce;
  } on FormatException {
    return false;
  }
}

bool _hasForbiddenControlCharacter(String value) {
  for (final rune in value.runes) {
    if (rune == 0 ||
        rune == 0x1b ||
        rune == 0x7f ||
        (rune < 0x20 && rune != 0x09 && rune != 0x0a) ||
        (rune >= 0x80 && rune <= 0x9f)) {
      return true;
    }
  }
  return false;
}
