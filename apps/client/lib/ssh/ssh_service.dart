import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/models.dart';
import '../platform/ssh_background_keepalive.dart';
import '../sync/known_host_decision_lock.dart';
import 'port_forward_runtime.dart';
import 'openssh_certificate.dart';
import 'ssh_transport.dart';
import '../l10n/l10n.dart';

enum SshHostKeyFailure { rejected, changed }

class SshHostKeyVerificationException implements Exception {
  const SshHostKeyVerificationException(this.failure);

  final SshHostKeyFailure failure;
}

class SshRelayTransportException implements Exception {
  const SshRelayTransportException(this.cause);

  final Object cause;
}

class SshCredentialException implements Exception {
  const SshCredentialException();
}

class SshExecResult {
  const SshExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.exitSignal,
    this.cancelled = false,
    this.timedOut = false,
    this.outputTruncated = false,
    this.bashUnavailable = false,
    this.execOpenPending = false,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final String? exitSignal;
  final bool cancelled;
  final bool timedOut;
  final bool outputTruncated;
  final bool bashUnavailable;
  final bool execOpenPending;
}

/// Per-invocation cancellation. It closes only the exec channel bound to it;
/// the SSH transport and interactive terminal remain open.
class SshExecCancellation {
  bool _cancelled = false;
  void Function()? _closeExecChannel;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
    _closeExecChannel?.call();
  }

  void _bind(void Function() closeExecChannel) {
    _closeExecChannel = closeExecChannel;
    if (_cancelled) closeExecChannel();
  }

  void _unbind() => _closeExecChannel = null;
}

/// Cancels SSH connection establishment for one terminal tab. Each retry
/// creates an independent attempt, so a failed host-key handshake can be
/// cleaned up without poisoning the tab's later approved retry.
class SshConnectCancellation {
  bool _cancelled = false;
  final Set<_SshConnectAttempt> _attempts = <_SshConnectAttempt>{};
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  Future<void> cancel() async {
    if (_cancelled) {
      await Future.wait<void>(_attempts.map((attempt) => attempt.closeAll()));
      return;
    }
    _cancelled = true;
    _cancelledCompleter.complete();
    final attempts = List<_SshConnectAttempt>.of(_attempts);
    await Future.wait<void>(attempts.map((attempt) => attempt.cancel()));
  }

  void _attach(_SshConnectAttempt attempt) {
    if (_cancelled) {
      unawaited(attempt.cancel());
      return;
    }
    _attempts.add(attempt);
  }

  void _detach(_SshConnectAttempt attempt) => _attempts.remove(attempt);
}

class SshConnectCancelledException implements Exception {
  const SshConnectCancelledException();
}

/// Tracks resources as they are acquired, and closes in reverse acquisition
/// order. Each resource lease is close-once because cancellation, normal error
/// cleanup, and SshConnection.close() may race.
class _SshConnectAttempt {
  _SshConnectAttempt(this.cancellation) {
    cancellation._attach(this);
  }

  final SshConnectCancellation cancellation;
  final List<_SshConnectResource> _resources = <_SshConnectResource>[];
  final Completer<void> _cancelled = Completer<void>();
  bool _stopped = false;
  bool _closed = false;
  bool _detached = false;

  bool get isCancelled => _stopped || cancellation.isCancelled;

  void checkCancelled() {
    if (isCancelled) throw const SshConnectCancelledException();
  }

  void register(Future<void> Function() close) {
    checkCancelled();
    _resources.add(_SshConnectResource(close));
  }

  Future<T> wait<T>(Future<T> future) {
    checkCancelled();
    return Future.any<T>(<Future<T>>[
      future,
      _cancelled.future.then<T>(
        (_) => throw const SshConnectCancelledException(),
      ),
    ]);
  }

  /// Adds a late-result close handler before racing the acquisition against
  /// cancellation or an optional stage deadline. A resource arriving after
  /// either event is closed immediately and never becomes caller-owned.
  Future<T> acquire<T>(
    Future<T> Function() open,
    Future<void> Function(T value) close, {
    Duration? timeout,
    Object? timeoutError,
  }) async {
    checkCancelled();
    var abandoned = false;
    final future = open();
    final registered = future.then<T>((value) {
      if (_stopped || cancellation.isCancelled || abandoned) {
        unawaited(_closeQuietly(() => close(value)));
        throw const SshConnectCancelledException();
      }
      register(() => close(value));
      return value;
    });
    try {
      final bounded = timeout == null
          ? registered
          : registered.timeout(
              timeout,
              onTimeout: () =>
                  throw timeoutError ??
                      TimeoutException('SSH acquisition timed out.'),
            );
      return await wait<T>(bounded);
    } catch (_) {
      if (timeout != null) abandoned = true;
      rethrow;
    }
  }

  Future<void> cancel() {
    if (!_stopped) {
      _stopped = true;
      if (!_cancelled.isCompleted) _cancelled.complete();
    }
    return closeAll();
  }

  Future<void> closeAll() async {
    if (!_stopped) {
      _stopped = true;
      if (!_cancelled.isCompleted) _cancelled.complete();
    }
    if (_closed) return;
    _closed = true;
    for (var index = _resources.length - 1; index >= 0; index--) {
      await _resources[index].close();
    }
  }

  void transferOwnership() {
    if (_detached) return;
    _detached = true;
    cancellation._detach(this);
  }

  void finishFailedAttempt() {
    transferOwnership();
  }
}

class _SshConnectResource {
  _SshConnectResource(this._close);

  final Future<void> Function() _close;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _closeQuietly(_close);
}

enum SshFailureStage { handshake, authentication, session }

class SshStageException implements Exception {
  const SshStageException(this.stage);

  final SshFailureStage stage;
}

/// The user cancelled a keyboard-interactive challenge. Throwing this from the
/// handler closes the SSH transport instead of letting dartssh2 fall through
/// to a different configured authentication method.
class SshKeyboardInteractiveCancelled implements Exception {
  const SshKeyboardInteractiveCancelled();
}

/// Terminates one remote exec process and destroys only its SSH channel.
///
/// This is safe for channels opened on a shared [SSHClient]: it does not close
/// the client or affect any other SSH sessions.
void terminateSshExecSession(SSHSession session) {
  // SSHSession.close() only sends EOF and waits for the peer to close its
  // channel. Aborting an exec must signal the remote process and destroy just
  // this SSH channel while preserving the shared SSHClient and terminal.
  try {
    session.kill(SSHSignal.TERM);
  } catch (_) {
    // The channel may already be closed or the server may reject signals.
  }
  try {
    session.channel.destroy();
  } catch (_) {
    // Teardown is best-effort; never surface transport text to the caller.
  }
}

String? sshConnectionFriendlyError(Object error) {
  bool isKeyboardInteractiveCancellation(Object? candidate) =>
      switch (candidate) {
        SshKeyboardInteractiveCancelled() => true,
        SSHInternalError(:final error) => isKeyboardInteractiveCancellation(
          error,
        ),
        SSHAuthAbortError(:final reason) => isKeyboardInteractiveCancellation(
          reason,
        ),
        _ => false,
      };

  if (isKeyboardInteractiveCancellation(error)) {
    return 'SSH interactive authentication was cancelled.';
  }
  if (error is SshHostKeyVerificationException) {
    return switch (error.failure) {
      SshHostKeyFailure.rejected => currentL10n.theUntrustedSshHostKeyWas,
      SshHostKeyFailure.changed => currentL10n.theSshHostKeyDiffersFrom,
    };
  }
  if (error is SshRelayTransportException) {
    return currentL10n.couldntEstablishTheSshRelayWebsocket;
  }
  if (error is SshCredentialException || error is SSHKeyDecodeError) {
    return currentL10n.theSshPrivateKeyCouldntBe;
  }
  if (error is SSHAuthAbortError) {
    final reason = error.reason;
    if (reason is SSHHostkeyError) {
      return currentL10n.sshHostKeyVerificationFailedThe;
    }
    if (reason is SSHHandshakeError || reason is SSHPacketError) {
      return currentL10n.sshHandshakeFailedCheckTheSsh;
    }
    if (reason is SSHSocketError) {
      return currentL10n.theSshNetworkConnectionWasInterrupted;
    }
    return currentL10n.theSshConnectionDroppedBeforeAuthentication;
  }
  if (error is SSHHostkeyError) {
    return currentL10n.sshHostKeyVerificationFailedThe;
  }
  if (error is SshStageException) {
    return switch (error.stage) {
      SshFailureStage.handshake => currentL10n.sshHandshakeFailedCheckTheSsh,
      SshFailureStage.authentication =>
        currentL10n.sshAuthenticationFailedCheckTheUser,
      SshFailureStage.session =>
        currentL10n.sshAuthenticatedButTheTerminalSession,
    };
  }
  if (error is SSHHandshakeError || error is SSHPacketError) {
    return currentL10n.sshHandshakeFailedCheckTheSsh;
  }
  if (error is SSHAuthError) {
    return currentL10n.sshAuthenticationFailedCheckTheUser;
  }
  if (error is SSHSocketError) {
    return currentL10n.theSshNetworkConnectionWasInterrupted;
  }
  if (error is TimeoutException) {
    return currentL10n.theSshRelayConnectionTimedOut;
  }
  if (error is ApiException) {
    switch (error.code) {
      case 'RELAY_DISABLED':
        return currentL10n.theServerHasntEnabledTheSsh;
      case 'INVALID_TARGET':
        return currentL10n.theSshRelayTargetMustBe;
      case 'TARGET_DENIED':
        return currentL10n.theServerRelayPolicyRejectedThis;
      case 'RELAY_RATE_LIMITED':
        return currentL10n.tooManySshRelayRequestsTry;
      case 'ORIGIN_DENIED':
        return currentL10n.theSshRelayOriginDoesntMatch;
      case 'RELAY_TICKET_EXPIRED':
      case 'RELAY_TICKET_INVALID':
        return currentL10n.theSshRelayTicketExpiredStart;
    }
  }
  return null;
}

typedef RelaySocketConnector = Future<SSHSocket> Function(
  Uri relayUri,
  String ticket,
);

/// Provides one SSH keyboard-interactive challenge to the user for [host].
///
/// SSH servers may issue multiple sequential requests. The service invokes
/// this callback once per request and does not retain the returned answers.
typedef SshKeyboardInteractiveHandler = FutureOr<List<String>?> Function(
  HostRecord host,
  SSHUserInfoRequest request,
);

typedef SshClientFactory = SSHClient Function({
  required SSHSocket socket,
  required String username,
  required List<SSHIdentity> identities,
  required FutureOr<String?> Function()? onPasswordRequest,
  required SSHUserInfoRequestHandler? onUserInfoRequest,
  required FutureOr<bool> Function(String type, Uint8List fingerprint)
  onVerifyHostKey,
  required Duration handshakeTimeout,
  required Duration authTimeout,
});

typedef SshDirectSocketConnector = Future<SSHSocket> Function(
  String host,
  int port,
);

/// One independently authenticated and host-key checked SSH hop.
///
/// [jumpHops] passed to [SshService.connect] are ordered from the first host
/// reached by the direct socket to the host immediately before the target.
class SshJumpHop {
  const SshJumpHop({
    required this.host,
    required this.credential,
    required this.verifyHostKey,
  });

  final HostRecord host;
  final CredentialRecord credential;
  final Future<bool> Function(String type, String fingerprint) verifyHostKey;
}

SSHClient _createSshClient({
  required SSHSocket socket,
  required String username,
  required List<SSHIdentity> identities,
  required FutureOr<String?> Function()? onPasswordRequest,
  required SSHUserInfoRequestHandler? onUserInfoRequest,
  required FutureOr<bool> Function(String type, Uint8List fingerprint)
  onVerifyHostKey,
  required Duration handshakeTimeout,
  required Duration authTimeout,
}) => SSHClient(
  socket,
  username: username,
  identities: identities,
  onPasswordRequest: onPasswordRequest,
  onUserInfoRequest: onUserInfoRequest,
  onVerifyHostKey: onVerifyHostKey,
  handshakeTimeout: handshakeTimeout,
  authTimeout: authTimeout,
);

class SshConnection {
  SshConnection({
    required this.client,
    required this.session,
    SSHSocket? forwardedSocket,
    SSHClient? jumpClient,
    SSHSocket? jumpSocket,
    List<SSHSocket> jumpChannels = const <SSHSocket>[],
    List<SSHClient> jumpClients = const <SSHClient>[],
    SSHSocket? initialJumpSocket,
  }) : _jumpChannels = jumpChannels.isNotEmpty
           ? List<SSHSocket>.unmodifiable(jumpChannels)
           : forwardedSocket == null
           ? const <SSHSocket>[]
           : <SSHSocket>[forwardedSocket],
       _jumpClients = jumpClients.isNotEmpty
           ? List<SSHClient>.unmodifiable(jumpClients)
           : jumpClient == null
           ? const <SSHClient>[]
           : <SSHClient>[jumpClient],
       _initialJumpSocket = initialJumpSocket ?? jumpSocket;

  final SSHClient client;
  final SSHSession session;
  late final SshPortForwardManager portForwards = SshPortForwardManager(client);
  final List<SSHSocket> _jumpChannels;
  final List<SSHClient> _jumpClients;
  final SSHSocket? _initialJumpSocket;
  _SshConnectAttempt? _connectAttempt;
  SshKeepaliveHold? _keepalive;
  bool _execOpenPending = false;

  /// Moves the connect attempt's background keepalive hold to this open
  /// transport. It is released by [close] or when the SSH client ends, so a
  /// dropped transport never keeps Android's session service running.
  void _adoptKeepalive(SshKeepaliveHold hold) {
    _keepalive = hold;
    // Notification "Disconnect all": end the target transport; the owning
    // tab/session observes the ended shell and performs its normal cleanup.
    hold.update(
      SshKeepaliveKind.connected,
      onUserDisconnect: () => unawaited(_closeQuietly(client.close)),
    );
    try {
      client.done.then<void>(
        (_) => hold.release(),
        onError: (Object _, StackTrace _) => hold.release(),
      );
    } catch (_) {
      // Test doubles may not implement `done`; close() still releases.
    }
  }

  /// True after an exec request timed out/cancelled before dartssh2 returned
  /// its channel. The request cannot be individually cancelled in dartssh2
  /// 4.1.0, so do not allow another command to accumulate on this transport.
  bool get hasUnresolvedExecOpen => _execOpenPending;

  Stream<String> get output => utf8.decoder.bind(session.stdout);

  void input(String text) =>
      session.write(Uint8List.fromList(utf8.encode(text)));

  void resize(int columns, int rows) => session.resizeTerminal(columns, rows);

  /// Runs one already-reviewed remote command on this target SSH transport.
  /// This opens a non-PTY session and does not affect the interactive shell.
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 64 * 1024,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    if (maxOutputBytes < 1) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes');
    }
    if (cancellation.isCancelled) {
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
      );
    }
    if (_execOpenPending) {
      throw StateError(
        'A previous SSH exec request is still pending. Disconnect and reconnect before running another command.',
      );
    }

    _execOpenPending = true;
    late final Future<SSHSession> opening;
    try {
      opening = client.execute(command);
    } catch (error) {
      _execOpenPending = false;
      rethrow;
    }
    final cancelledWhileOpening = Object();
    final timedOutWhileOpening = Object();
    var openingAborted = false;
    final cancellationOutcome = cancellation.whenCancelled.then<Object>((_) {
      openingAborted = true;
      return cancelledWhileOpening;
    });
    final openDeadline = Completer<Object>();
    final openTimer = Timer(const Duration(seconds: 15), () {
      openingAborted = true;
      if (!openDeadline.isCompleted) {
        openDeadline.complete(timedOutWhileOpening);
      }
    });
    // If cancellation or the open deadline wins, dispose a channel that the
    // SSH server accepts later. This continuation also consumes late errors.
    unawaited(
      opening.then<void>(
        (lateSession) {
          if (openingAborted) terminateSshExecSession(lateSession);
          _execOpenPending = false;
        },
        onError: (Object _, StackTrace _) {
          _execOpenPending = false;
        },
      ),
    );

    late final SSHSession execSession;
    Object opened;
    try {
      opened = await Future.any<Object>([
        opening,
        cancellationOutcome,
        openDeadline.future,
      ]);
    } finally {
      openTimer.cancel();
    }
    if (identical(opened, cancelledWhileOpening)) {
      // Any later open is handled by the continuation above.
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
        execOpenPending: true,
      );
    }
    if (identical(opened, timedOutWhileOpening)) {
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        timedOut: true,
        execOpenPending: true,
      );
    }
    execSession = opened as SSHSession;

    if (cancellation.isCancelled) {
      terminateSshExecSession(execSession);
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
      );
    }

    final stdoutBytes = BytesBuilder(copy: false);
    final stderrBytes = BytesBuilder(copy: false);
    final drainSubscriptions = <StreamSubscription<Uint8List>>[];
    final drainCompletions = <Completer<void>>[];
    final subscriptionCancellations = <Future<void>>[];
    var retainedBytes = 0;
    var outputTruncated = false;
    var aborting = false;
    var completedNormally = false;
    Object? drainError;
    StackTrace? drainStack;
    final finished = Completer<void>();

    void finishDrain(Completer<void> completer) {
      if (!completer.isCompleted) completer.complete();
    }

    void abortExecChannel() {
      if (aborting) return;
      aborting = true;
      terminateSshExecSession(execSession);
      for (final subscription in drainSubscriptions) {
        subscriptionCancellations.add(
          subscription.cancel().catchError((Object _) {}),
        );
      }
      for (final completer in drainCompletions) {
        finishDrain(completer);
      }
      if (!finished.isCompleted) finished.complete();
    }

    void collect(Uint8List bytes, BytesBuilder destination) {
      if (outputTruncated || aborting) return;
      final remaining = maxOutputBytes - retainedBytes;
      final retained = bytes.length <= remaining ? bytes.length : remaining;
      if (retained > 0) {
        destination.add(
          retained == bytes.length ? bytes : bytes.sublist(0, retained),
        );
        retainedBytes += retained;
      }
      if (retained < bytes.length) {
        outputTruncated = true;
        // Bound output and stop the remote process as soon as the combined
        // stdout/stderr budget is exceeded.
        abortExecChannel();
      }
    }

    Future<void> drain(Stream<Uint8List> stream, BytesBuilder destination) {
      final completed = Completer<void>();
      drainCompletions.add(completed);
      final subscription = stream.listen(
        (bytes) {
          collect(bytes, destination);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!aborting) {
            drainError ??= error;
            drainStack ??= stackTrace;
            abortExecChannel();
          }
          finishDrain(completed);
        },
        onDone: () => finishDrain(completed),
      );
      drainSubscriptions.add(subscription);
      if (aborting) {
        subscriptionCancellations.add(
          subscription.cancel().catchError((Object _) {}),
        );
        finishDrain(completed);
      }
      return completed.future;
    }

    final stdoutDrain = drain(execSession.stdout, stdoutBytes);
    final stderrDrain = drain(execSession.stderr, stderrBytes);
    final done = Future.wait<void>([
      execSession.done,
      stdoutDrain,
      stderrDrain,
    ]);
    var timedOut = false;
    var cancelled = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      abortExecChannel();
      if (!finished.isCompleted) finished.complete();
    });
    cancellation._bind(() {
      cancelled = true;
      abortExecChannel();
      if (!finished.isCompleted) finished.complete();
    });
    done.then<void>(
      (_) {
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!aborting) {
          drainError = error;
          drainStack = stackTrace;
          abortExecChannel();
        }
        if (!finished.isCompleted) finished.complete();
      },
    );

    try {
      if (cancellation.isCancelled) {
        cancelled = true;
        abortExecChannel();
      } else {
        // Secret parameters use the SSH-encrypted exec channel's stdin, never
        // the command string or WebSocket request. Ordinary commands receive
        // EOF immediately. Do not let a stalled write/close bypass the
        // execution deadline or cancellation.
        try {
          final input = stdinData == null || stdinData.isEmpty
              ? null
              : Uint8List.fromList(stdinData);
          final inputTask = () async {
            try {
              if (input != null) {
                await execSession.stdin.addStream(
                  Stream<Uint8List>.value(input),
                );
              }
              await execSession.stdin.close();
            } finally {
              input?.fillRange(0, input.length, 0);
            }
          }();
          await Future.any<void>([inputTask, finished.future]);
        } catch (_) {
          if (!aborting) rethrow;
        }
      }
      await finished.future;
      if (timedOut || cancelled || outputTruncated || drainError != null) {
        try {
          await done.timeout(const Duration(seconds: 2));
        } catch (_) {
          // Cleanup below cancels both stream listeners and closes the channel.
        }
      }
      if (drainError != null) {
        Error.throwWithStackTrace(drainError!, drainStack!);
      }
      final stderr = utf8.decode(stderrBytes.takeBytes(), allowMalformed: true);
      final stdout = utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true);
      final result = SshExecResult(
        stdout: stdout,
        stderr: stderr,
        exitCode: timedOut || cancelled || outputTruncated
            ? null
            : execSession.exitCode,
        exitSignal: timedOut || cancelled || outputTruncated
            ? null
            : execSession.exitSignal?.signalName,
        cancelled: cancelled,
        timedOut: timedOut,
        outputTruncated: outputTruncated,
        bashUnavailable: stderr
            .split(RegExp(r'\r?\n'))
            .contains(bashUnavailableMarker),
      );
      completedNormally = true;
      return result;
    } finally {
      timer.cancel();
      cancellation._unbind();
      if (completedNormally) {
        execSession.close();
      } else {
        // Every exceptional exit must abort the channel and detach both drain
        // listeners. SSHSession.close() only sends EOF and can leave a remote
        // command and its output streams alive after stdin/network failures.
        abortExecChannel();
      }
      try {
        await stdoutDrain.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await stderrDrain.timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (subscriptionCancellations.isNotEmpty) {
        try {
          await Future.wait<void>(subscriptionCancellations)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  }

  Future<void> close() async {
    final keepalive = _keepalive;
    _keepalive = null;
    try {
      await _closeResources();
    } finally {
      keepalive?.release();
    }
  }

  Future<void> _closeResources() async {
    // Resources are acquired as initial socket, then for each hop its client
    // and the channel to the next hop, then the target client/session. Close
    // in reverse and continue even if one resource refuses to close.
    _pendingConnectOwnership[this] = null;
    await portForwards.closeAll();
    final connectAttempt = _connectAttempt;
    if (connectAttempt != null) {
      await connectAttempt.closeAll();
      return;
    }
    try {
      session.close();
    } catch (_) {}
    await _closeQuietly(client.close);
    for (var index = _jumpClients.length - 1; index >= 0; index--) {
      if (index < _jumpChannels.length) {
        await _closeQuietly(_jumpChannels[index].close);
      }
      await _closeQuietly(_jumpClients[index].close);
    }
    if (_initialJumpSocket != null) {
      await _closeQuietly(_initialJumpSocket.close);
    }
  }
}

final Expando<_SshConnectAttempt> _pendingConnectOwnership =
    Expando<_SshConnectAttempt>('pending SSH connection ownership');

/// Stops tab-close cancellation once AppController has attached this
/// connection to the still-open tab. The connection itself remains
/// responsible for closing its resources. The top-level adapter also avoids
/// adding a lifecycle method to [SshConnection] test implementations.
void transferSshConnectOwnership(SshConnection connection) =>
    _transferPendingConnectOwnership(connection);

void _transferPendingConnectOwnership(SshConnection connection) {
  _pendingConnectOwnership[connection]?.transferOwnership();
  _pendingConnectOwnership[connection] = null;
}

Future<void> _closeQuietly(Future<void> Function() close) async {
  try {
    await close().timeout(const Duration(seconds: 3));
  } catch (_) {
    // Cleanup must not obscure the connection error or stop later closes.
  }
}

class SshService {
  SshService({
    required this.api,
    required this.deviceId,
    bool? useRelay,
    RelaySocketConnector? relaySocketConnector,
    SshDirectSocketConnector? directSocketConnector,
    SshClientFactory? sshClientFactory,
    KnownHostDecisionLock? knownHostDecisionLock,
    SshBackgroundKeepalive? backgroundKeepalive,
  }) : _useRelay = useRelay ?? kIsWeb,
       _backgroundKeepalive = backgroundKeepalive,
       _relaySocketConnector = relaySocketConnector ?? connectRelaySocket,
       _directSocketConnector = directSocketConnector ?? connectDirect,
       _sshClientFactory = sshClientFactory ?? _createSshClient,
       _knownHostDecisionLock = knownHostDecisionLock;

  /// Null for a LocalVault native connection. Relay mode always requires the
  /// server API; local-only trust never constructs or calls one.
  final ApiClient? api;
  final String deviceId;
  final bool _useRelay;
  final RelaySocketConnector _relaySocketConnector;
  final SshDirectSocketConnector _directSocketConnector;
  final SshClientFactory _sshClientFactory;
  final KnownHostDecisionLock? _knownHostDecisionLock;
  final SshBackgroundKeepalive? _backgroundKeepalive;

  Future<SshConnection> connect({
    required HostRecord host,
    required CredentialRecord credential,
    required Future<bool> Function(String type, String fingerprint)
    verifyHostKey,
    SshKeyboardInteractiveHandler? onUserInfoRequest,
    List<SshJumpHop> jumpHops = const <SshJumpHop>[],
    // Kept for callers built against the earlier one-hop service API.
    HostRecord? jumpHost,
    CredentialRecord? jumpCredential,
    Future<bool> Function(String type, String fingerprint)? verifyJumpHostKey,
    KnownHostDecisionScope? knownHostDecisionScope,
    SshConnectCancellation? cancellation,
  }) async {
    if (host.protocol != HostProtocol.ssh) {
      throw ArgumentError('SSH connections require an SSH Host.');
    }
    if ((_knownHostDecisionLock == null) != (knownHostDecisionScope == null)) {
      throw ArgumentError(
        'KnownHost decision lock and Vault scope must be supplied together.',
      );
    }
    final route = List<SshJumpHop>.of(jumpHops);
    if (jumpHost != null ||
        jumpCredential != null ||
        verifyJumpHostKey != null) {
      if (route.isNotEmpty) {
        throw ArgumentError(
          'Use either jumpHops or the legacy Jump Host arguments.',
        );
      }
      if (jumpHost == null ||
          jumpCredential == null ||
          verifyJumpHostKey == null) {
        throw ArgumentError(
          'A Jump Host requires a credential and a host-key verifier.',
        );
      }
      route.add(
        SshJumpHop(
          host: jumpHost,
          credential: jumpCredential,
          verifyHostKey: verifyJumpHostKey,
        ),
      );
    }

    if (route.length > maxJumpHostHops) {
      throw ArgumentError('SSH Jump Host chain exceeds the supported depth.');
    }
    final seenHostIds = <String>{host.id};
    for (final hop in route) {
      if (hop.host.protocol != HostProtocol.ssh) {
        throw ArgumentError('SSH Jump Hosts must use SSH.');
      }
      if (hop.host.id.isEmpty || !seenHostIds.add(hop.host.id)) {
        throw ArgumentError('SSH Jump Host chain contains a repeated Host.');
      }
    }

    final keepaliveRegistry =
        _backgroundKeepalive ?? SshBackgroundKeepalive.instance;
    // A recovery attempt that began before the notification's Disconnect all
    // must not open a new transport afterwards.
    if (keepaliveRegistry.disconnectedSinceFlightStarted) {
      throw const SshConnectCancelledException();
    }
    final attempt = _SshConnectAttempt(
      cancellation ?? SshConnectCancellation(),
    );
    // Android: the user-started attempt claims the session keepalive while
    // the app is still visible; failure/cancellation releases it below.
    final keepalive = keepaliveRegistry.hold(
      SshKeepaliveKind.connecting,
      onUserDisconnect: () => unawaited(attempt.cancel()),
    );
    try {
      final firstSocket = await _connectSocket(
        route.isEmpty ? host : route.first.host,
        attempt,
      );
      final jumpClients = <SSHClient>[];
      final jumpChannels = <SSHSocket>[];
      SSHClient? targetClient;
      var currentSocket = firstSocket;
      for (var index = 0; index < route.length; index++) {
        final hop = route[index];
        final jumpClient = await _createAndAuthenticate(
          socket: currentSocket,
          host: hop.host,
          credential: hop.credential,
          verifyHostKey: hop.verifyHostKey,
          onUserInfoRequest: onUserInfoRequest,
          attempt: attempt,
          knownHostDecisionScope: knownHostDecisionScope,
        );
        jumpClients.add(jumpClient);
        final nextHost = index + 1 < route.length
            ? route[index + 1].host
            : host;
        final nextSocket = await _openForwardedSocket(
          jumpClient,
          nextHost,
          attempt,
        );
        jumpChannels.add(nextSocket);
        currentSocket = nextSocket;
      }

      targetClient = await _createAndAuthenticate(
        socket: route.isEmpty ? firstSocket : jumpChannels.last,
        host: host,
        credential: credential,
        verifyHostKey: verifyHostKey,
        onUserInfoRequest: onUserInfoRequest,
        attempt: attempt,
        knownHostDecisionScope: knownHostDecisionScope,
      );
      final shellClient = targetClient;
      final session = await attempt.acquire<SSHSession>(
        () => shellClient
            .shell(pty: const SSHPtyConfig(width: 100, height: 30))
            .onError((error, stackTrace) {
              if (error is TimeoutException) {
                Error.throwWithStackTrace(
                  const SshStageException(SshFailureStage.session),
                  stackTrace,
                );
              }
              Error.throwWithStackTrace(
                error ?? StateError('SSH shell request failed.'),
                stackTrace,
              );
            }),
        (session) async => session.close(),
        timeout: const Duration(seconds: 20),
        timeoutError: const SshStageException(SshFailureStage.session),
      );
      final connection = SshConnection(
        client: targetClient,
        session: session,
        jumpChannels: jumpChannels,
        jumpClients: jumpClients,
        initialJumpSocket: route.isEmpty ? null : firstSocket,
      );
      connection._connectAttempt = attempt;
      connection._adoptKeepalive(keepalive);
      _pendingConnectOwnership[connection] = attempt;
      // Standalone callers do not have a tab lifecycle to transfer ownership
      // to. AppController supplies a token and transfers after attachment.
      if (cancellation == null) transferSshConnectOwnership(connection);
      return connection;
    } catch (error) {
      keepalive.release();
      attempt.finishFailedAttempt();
      await attempt.closeAll();
      rethrow;
    }
  }

  Future<SSHClient> _createAndAuthenticate({
    required SSHSocket socket,
    required HostRecord host,
    required CredentialRecord credential,
    required Future<bool> Function(String type, String fingerprint)
    verifyHostKey,
    required SshKeyboardInteractiveHandler? onUserInfoRequest,
    required _SshConnectAttempt attempt,
    required KnownHostDecisionScope? knownHostDecisionScope,
  }) async {
    Future<SSHClient> connectAndAuthenticate() async {
      attempt.checkCancelled();
      final client = _createClient(
        socket: socket,
        host: host,
        credential: credential,
        verifyHostKey: verifyHostKey,
        onUserInfoRequest: onUserInfoRequest,
      );
      attempt.register(client.close);
      await _authenticate(client, attempt);
      return client;
    }

    final lock = _knownHostDecisionLock;
    if (lock == null) return connectAndAuthenticate();
    try {
      return await lock.run(
        knownHostDecisionScope!,
        connectAndAuthenticate,
        mode: KnownHostDecisionLockMode.shared,
        cancel: attempt.cancellation.whenCancelled,
      );
    } on KnownHostDecisionCancelledException {
      throw const SshConnectCancelledException();
    }
  }

  Future<SSHSocket> _connectSocket(
    HostRecord host,
    _SshConnectAttempt attempt,
  ) async {
    attempt.checkCancelled();
    if (!_useRelay) {
      return attempt.acquire<SSHSocket>(
        () => _directSocketConnector(host.address, host.port),
        (socket) => socket.close(),
      );
    }
    final api = this.api;
    if (api == null) {
      throw StateError(
        'SSH Relay requires an authenticated server API client.',
      );
    }
    final ticket = await attempt.wait(
      api
          .createRelayTicket(
            deviceId: deviceId,
            targetHost: host.address,
            targetPort: host.port,
          )
          .timeout(const Duration(seconds: 15)),
    );
    // Connect through the browser WebSocket transport. The endpoint route is
    // imported conditionally; native targets never compile web-only APIs.
    try {
      return await attempt.acquire<SSHSocket>(
        () => _relaySocketConnector(api.relayUri(), ticket.value),
        (socket) => socket.close(),
        timeout: const Duration(seconds: 18),
      );
    } on SshConnectCancelledException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (error) {
      throw SshRelayTransportException(error);
    }
  }

  SSHClient _createClient({
    required SSHSocket socket,
    required HostRecord host,
    required CredentialRecord credential,
    required Future<bool> Function(String type, String fingerprint)
    verifyHostKey,
    required SshKeyboardInteractiveHandler? onUserInfoRequest,
  }) => _sshClientFactory(
    socket: socket,
    username: credential.username.isEmpty ? host.username : credential.username,
    identities: _parseIdentities(credential),
    onPasswordRequest: credential.kind == AuthKind.password
        ? () => credential.secret
        : null,
    onUserInfoRequest: onUserInfoRequest == null
        ? null
        : (request) => onUserInfoRequest(host, request),
    onVerifyHostKey: (type, fingerprint) =>
        verifyHostKey(type, utf8.decode(fingerprint, allowMalformed: true)),
    // The controller ends the transport before any host-key Vault pull or
    // user prompt, then retries with a one-use verified-key proof. Keep the
    // wire handshake deadline independent for each route hop.
    handshakeTimeout: const Duration(seconds: 90),
    authTimeout: const Duration(seconds: 20),
  );

  Future<void> _authenticate(
    SSHClient client,
    _SshConnectAttempt attempt,
  ) async {
    try {
      await attempt.wait(
        client.authenticated.timeout(const Duration(seconds: 35)),
      );
    } on SSHAuthError {
      rethrow;
    } on SSHHandshakeError {
      rethrow;
    } on SSHPacketError {
      rethrow;
    } on TimeoutException {
      throw const SshStageException(SshFailureStage.authentication);
    }
  }

  Future<SSHSocket> _openForwardedSocket(
    SSHClient jumpClient,
    HostRecord target,
    _SshConnectAttempt attempt,
  ) async {
    try {
      return await attempt.acquire<SSHSocket>(
        () => jumpClient.forwardLocal(target.address, target.port),
        (channel) => channel.close(),
        timeout: const Duration(seconds: 15),
      );
    } on TimeoutException catch (_, stackTrace) {
      Error.throwWithStackTrace(
        const SshStageException(SshFailureStage.handshake),
        stackTrace,
      );
    } on SSHChannelOpenError {
      throw const SshStageException(SshFailureStage.handshake);
    }
  }
}

List<SSHIdentity> _parseIdentities(CredentialRecord credential) {
  if (credential.kind != AuthKind.privateKey || credential.privateKey == null) {
    return <SSHIdentity>[];
  }

  // The credential editor stores its empty optional passphrase as ''.
  // dartssh2 treats any non-null passphrase as an encryption request and
  // rejects it for an unencrypted SEC1 PEM before SSHClient can send its
  // identification banner. Normalize only the empty value; preserve all
  // non-empty passphrases exactly as entered.
  final passphrase = credential.passphrase?.isEmpty == true
      ? null
      : credential.passphrase;
  final List<SSHKeyPair> pairs;
  try {
    pairs = SSHKeyPair.fromPem(credential.privateKey!, passphrase);
  } catch (_) {
    // Library parser errors can include PEM fragments. Keep them out of UI
    // error text, logs and telemetry.
    throw const SshCredentialException();
  }
  try {
    // A stored OpenSSH user certificate is offered first; it must certify one
    // of these keys, otherwise authentication fails closed instead of
    // silently falling back and reporting a certificate login.
    return sshIdentitiesFor(pairs, certificateText: credential.certificate);
  } on OpenSshCertificateException {
    throw const SshCredentialException();
  }
}
