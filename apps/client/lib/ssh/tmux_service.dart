import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_service.dart';

/// Typed failures returned by the tmux service.
///
/// Remote output and SSH exception text are deliberately excluded. Callers can
/// present a stable message based on [TmuxServiceException.reason].
enum TmuxServiceFailureReason {
  invalidSessionName,
  invalidTerminalSize,
  commandFailure,
  timeout,
  cancelled,
  transportFailure,
}

class TmuxServiceException implements Exception {
  const TmuxServiceException(this.reason);

  final TmuxServiceFailureReason reason;

  @override
  String toString() => 'TmuxServiceException(${reason.name})';
}

enum TmuxProbeStatus { available, unavailable }

/// Result of checking a named session. [unavailable] means tmux itself could
/// not be confirmed by the fixed `tmux -V` probe.
enum TmuxSessionStatus { exists, absent, unavailable }

/// Injectable interface for application controllers and tests.
abstract interface class TmuxService {
  Future<TmuxProbeStatus> probe(
    SshConnection connection, {
    SshExecCancellation? cancellation,
  });

  Future<TmuxSessionStatus> hasSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  });

  Future<void> createSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  });

  Future<void> killSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  });

  Future<TmuxAttachHandle> openAttach(
    SshConnection connection,
    String sessionName, {
    required int columns,
    required int rows,
    SshExecCancellation? cancellation,
  });
}

/// The only management operations this module can send to a remote host.
enum TmuxManagementOperation { version, hasSession, createSession, killSession }

/// A fixed, reviewed management command. Its constructor is private so callers
/// can only obtain instances from [SshTmuxService] after name validation.
class TmuxManagementCommand {
  const TmuxManagementCommand._(this.operation, this.sessionName);

  final TmuxManagementOperation operation;
  final String? sessionName;

  /// Exposed read-only for transport adapters and deterministic tests.
  String get command => switch (operation) {
    TmuxManagementOperation.version => 'tmux -V',
    TmuxManagementOperation.hasSession => 'tmux has-session -t =$sessionName',
    TmuxManagementOperation.createSession =>
      'tmux new-session -d -s $sessionName',
    TmuxManagementOperation.killSession => 'tmux kill-session -t =$sessionName',
  };
}

/// A bounded result from one management command. It intentionally has no
/// stdout/stderr fields, so remote text cannot leak through the service API.
class TmuxCommandOutcome {
  const TmuxCommandOutcome({
    required this.exitCode,
    this.timedOut = false,
    this.cancelled = false,
    this.outputTruncated = false,
  });

  final int? exitCode;
  final bool timedOut;
  final bool cancelled;
  final bool outputTruncated;
}

/// Executes a typed management command on the already authenticated SSH
/// transport supplied by the caller.
abstract interface class TmuxCommandRunner {
  Future<TmuxCommandOutcome> run(
    SshConnection connection,
    TmuxManagementCommand command, {
    required Duration timeout,
    SshExecCancellation? cancellation,
  });
}

/// A fixed attach command. Only [SshTmuxService] can construct one.
class TmuxAttachCommand {
  const TmuxAttachCommand._(this.sessionName);

  final String sessionName;

  String get command => 'tmux attach-session -t =$sessionName';
}

/// The PTY channel opened for a tmux session.
abstract interface class TmuxAttachHandle {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;

  /// Enqueues bytes to the attached PTY and completes after the local SSH
  /// stream flushes writable data. This does not mean the remote process has
  /// consumed it; implementations must copy [bytes] before handing it off.
  Future<void> input(Uint8List bytes);
  void resize(int columns, int rows);
  void close();
}

/// Opens only the fixed tmux attach command on the existing SSH client.
abstract interface class TmuxPtyOpener {
  Future<TmuxAttachHandle> open(
    SshConnection connection,
    TmuxAttachCommand command, {
    required int columns,
    required int rows,
  });
}

const _sessionNamePattern = r'^atermius_[0-9a-f]{32}$';
final RegExp _sessionNameAllowlist = RegExp(_sessionNamePattern);

const _defaultManagementTimeout = Duration(seconds: 5);
const _defaultAttachOpenTimeout = Duration(seconds: 15);
const _maxManagementOutputBytes = 256;
const _maxTerminalDimension = 500;

/// tmux operations that reuse an existing, authenticated [SshConnection].
///
/// [probe], [hasSession], [createSession], and [killSession] use a fixed
/// command allowlist with short deadlines and bounded output. The attach path
/// opens a PTY for the exact `tmux attach-session` command; it never creates a
/// session or silently attaches as a side effect.
class SshTmuxService implements TmuxService {
  SshTmuxService({
    TmuxCommandRunner? commandRunner,
    TmuxPtyOpener? ptyOpener,
    Duration attachOpenTimeout = _defaultAttachOpenTimeout,
  }) : _commandRunner = commandRunner ?? const SshTmuxCommandRunner(),
       _ptyOpener = ptyOpener ?? const SshTmuxPtyOpener(),
       _attachOpenTimeout = _validateAttachOpenTimeout(attachOpenTimeout);

  final TmuxCommandRunner _commandRunner;
  final TmuxPtyOpener _ptyOpener;
  final Duration _attachOpenTimeout;

  @override
  Future<TmuxProbeStatus> probe(
    SshConnection connection, {
    SshExecCancellation? cancellation,
  }) async {
    final outcome = await _run(
      connection,
      const TmuxManagementCommand._(TmuxManagementOperation.version, null),
      cancellation: cancellation,
    );
    return outcome.exitCode == 0
        ? TmuxProbeStatus.available
        : TmuxProbeStatus.unavailable;
  }

  @override
  Future<TmuxSessionStatus> hasSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    final name = _validatedSessionName(sessionName);
    final availability = await probe(connection, cancellation: cancellation);
    if (availability == TmuxProbeStatus.unavailable) {
      return TmuxSessionStatus.unavailable;
    }
    final outcome = await _run(
      connection,
      TmuxManagementCommand._(TmuxManagementOperation.hasSession, name),
      cancellation: cancellation,
    );
    return outcome.exitCode == 0
        ? TmuxSessionStatus.exists
        : TmuxSessionStatus.absent;
  }

  @override
  Future<void> createSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    final name = _validatedSessionName(sessionName);
    final availability = await probe(connection, cancellation: cancellation);
    if (availability == TmuxProbeStatus.unavailable) {
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
    final outcome = await _run(
      connection,
      TmuxManagementCommand._(TmuxManagementOperation.createSession, name),
      cancellation: cancellation,
    );
    _requireSuccessfulMutation(outcome);
  }

  @override
  Future<void> killSession(
    SshConnection connection,
    String sessionName, {
    SshExecCancellation? cancellation,
  }) async {
    final name = _validatedSessionName(sessionName);
    final availability = await probe(connection, cancellation: cancellation);
    if (availability == TmuxProbeStatus.unavailable) {
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
    final outcome = await _run(
      connection,
      TmuxManagementCommand._(TmuxManagementOperation.killSession, name),
      cancellation: cancellation,
    );
    _requireSuccessfulMutation(outcome);
  }

  @override
  Future<TmuxAttachHandle> openAttach(
    SshConnection connection,
    String sessionName, {
    required int columns,
    required int rows,
    SshExecCancellation? cancellation,
  }) async {
    final name = _validatedSessionName(sessionName);
    _validateTerminalSize(columns, rows);
    if (cancellation?.isCancelled ?? false) {
      throw const TmuxServiceException(TmuxServiceFailureReason.cancelled);
    }

    late final Future<TmuxAttachHandle> opening;
    try {
      opening = _ptyOpener.open(
        connection,
        TmuxAttachCommand._(name),
        columns: columns,
        rows: rows,
      );
    } on Object {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.transportFailure,
      );
    }

    var openingAborted = false;
    unawaited(
      opening.then<void>((lateHandle) {
        if (openingAborted) lateHandle.close();
      }, onError: (Object _, StackTrace _) {}),
    );

    final timedOut = Object();
    final cancelled = Object();
    final timeoutCompleter = Completer<Object>();
    final timer = Timer(_attachOpenTimeout, () {
      openingAborted = true;
      if (!timeoutCompleter.isCompleted) timeoutCompleter.complete(timedOut);
    });
    final cancelFuture = cancellation == null
        ? Completer<Object>().future
        : cancellation.whenCancelled.then<Object>((_) {
            openingAborted = true;
            return cancelled;
          });

    late final Object opened;
    try {
      opened = await Future.any<Object>([
        opening,
        cancelFuture,
        timeoutCompleter.future,
      ]);
    } on Object {
      timer.cancel();
      throw const TmuxServiceException(
        TmuxServiceFailureReason.transportFailure,
      );
    }
    timer.cancel();

    if (identical(opened, timedOut)) {
      throw const TmuxServiceException(TmuxServiceFailureReason.timeout);
    }
    if (identical(opened, cancelled) || (cancellation?.isCancelled ?? false)) {
      if (opened is TmuxAttachHandle) opened.close();
      throw const TmuxServiceException(TmuxServiceFailureReason.cancelled);
    }
    return opened as TmuxAttachHandle;
  }

  Future<TmuxCommandOutcome> _run(
    SshConnection connection,
    TmuxManagementCommand command, {
    SshExecCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const TmuxServiceException(TmuxServiceFailureReason.cancelled);
    }
    late final TmuxCommandOutcome outcome;
    try {
      outcome = await _commandRunner.run(
        connection,
        command,
        timeout: _defaultManagementTimeout,
        cancellation: cancellation,
      );
    } on Object {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.transportFailure,
      );
    }
    if (outcome.cancelled || (cancellation?.isCancelled ?? false)) {
      throw const TmuxServiceException(TmuxServiceFailureReason.cancelled);
    }
    if (outcome.timedOut) {
      throw const TmuxServiceException(TmuxServiceFailureReason.timeout);
    }
    if (outcome.outputTruncated || outcome.exitCode == null) {
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
    return outcome;
  }

  String _validatedSessionName(String value) {
    if (!_sessionNameAllowlist.hasMatch(value)) {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.invalidSessionName,
      );
    }
    return value;
  }

  void _validateTerminalSize(int columns, int rows) {
    if (columns < 1 ||
        columns > _maxTerminalDimension ||
        rows < 1 ||
        rows > _maxTerminalDimension) {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.invalidTerminalSize,
      );
    }
  }

  void _requireSuccessfulMutation(TmuxCommandOutcome outcome) {
    if (outcome.exitCode != 0) {
      throw const TmuxServiceException(TmuxServiceFailureReason.commandFailure);
    }
  }
}

Duration _validateAttachOpenTimeout(Duration timeout) {
  if (timeout <= Duration.zero || timeout > _defaultAttachOpenTimeout) {
    throw ArgumentError.value(
      timeout,
      'attachOpenTimeout',
      'must be greater than zero and no longer than 15 seconds',
    );
  }
  return timeout;
}

/// Production management runner. It routes through [SshConnection]'s
/// authenticated SSH client and discards remote text immediately.
class SshTmuxCommandRunner implements TmuxCommandRunner {
  const SshTmuxCommandRunner();

  @override
  Future<TmuxCommandOutcome> run(
    SshConnection connection,
    TmuxManagementCommand command, {
    required Duration timeout,
    SshExecCancellation? cancellation,
  }) async {
    final result = await connection.executeRemoteCommand(
      command.command,
      cancellation: cancellation ?? SshExecCancellation(),
      timeout: timeout,
      maxOutputBytes: _maxManagementOutputBytes,
    );
    return TmuxCommandOutcome(
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      cancelled: result.cancelled,
      outputTruncated: result.outputTruncated,
    );
  }
}

/// Production PTY opener. The remote command is a fixed tmux attach and runs
/// over the supplied connection's already authenticated SSHClient.
class SshTmuxPtyOpener implements TmuxPtyOpener {
  const SshTmuxPtyOpener();

  @override
  Future<TmuxAttachHandle> open(
    SshConnection connection,
    TmuxAttachCommand command, {
    required int columns,
    required int rows,
  }) async {
    if (!_sessionNameAllowlist.hasMatch(command.sessionName)) {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.invalidSessionName,
      );
    }
    if (columns < 1 ||
        columns > _maxTerminalDimension ||
        rows < 1 ||
        rows > _maxTerminalDimension) {
      throw const TmuxServiceException(
        TmuxServiceFailureReason.invalidTerminalSize,
      );
    }
    if (connection.hasUnresolvedExecOpen) {
      throw StateError('SSH transport has an unresolved exec open.');
    }
    final session = await connection.client.execute(
      command.command,
      pty: SSHPtyConfig(width: columns, height: rows),
    );
    return SshTmuxAttachHandle(session);
  }
}

/// A PTY attach session opened by [SshTmuxPtyOpener]. Closing it terminates
/// only the attach exec process and its SSH channel.
class SshTmuxAttachHandle implements TmuxAttachHandle {
  SshTmuxAttachHandle(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  Future<void> input(Uint8List bytes) async {
    if (bytes.isEmpty) return;

    // SSHSession.write adds this argument to an asynchronous StreamController.
    // Give dartssh2 an owned copy and leave it untouched after handoff: flush
    // can complete while the remote channel window is still zero.
    final owned = Uint8List.fromList(bytes);
    _session.write(owned);
    await _session.flush();
  }

  @override
  void resize(int columns, int rows) => _session.resizeTerminal(columns, rows);

  @override
  void close() => terminateSshExecSession(_session);
}
