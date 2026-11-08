import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import 'port_forward_runtime_contract.dart';
import 'port_forward_runtime_stub.dart'
    if (dart.library.io) 'port_forward_runtime_io.dart'
    as platform;

export 'port_forward_runtime_contract.dart';
import '../l10n/l10n.dart';

SshPortForwardPlatform createSshPortForwardPlatform() =>
    platform.createSshPortForwardPlatform();

enum SshPortForwardState { stopped, starting, running, stopping, failed }

/// Volatile, per-connection status of one forward. Never persisted.
@immutable
class SshPortForwardStatus {
  const SshPortForwardStatus({
    required this.state,
    this.listeningPort,
    this.activeConnections = 0,
    this.totalConnections = 0,
    this.error,
    this.lastConnectionError,
  });

  static const stopped = SshPortForwardStatus(
    state: SshPortForwardState.stopped,
  );

  final SshPortForwardState state;
  final int? listeningPort;
  final int activeConnections;
  final int totalConnections;

  /// Why the forward failed to start or stopped unexpectedly.
  final String? error;

  /// Latest failure of an individual client connection while running.
  final String? lastConnectionError;

  bool get isRunning => state == SshPortForwardState.running;
}

/// Runtime forwarding state is attached to a single SSH connection and is
/// always closed before that SSH client is disposed. It also closes itself
/// when the SSH transport ends, so no listener outlives its connection and no
/// "running" badge can remain stale.
class SshPortForwardManager extends ChangeNotifier {
  SshPortForwardManager(
    this.client, {
    SshPortForwardPlatform? platform,
    this.pendingStartCloseBound = const Duration(seconds: 2),
  }) : _platform = platform ?? createSshPortForwardPlatform() {
    try {
      unawaited(
        client.done.then<void>(
          (_) => _onTransportEnded(),
          onError: (Object _) => _onTransportEnded(),
        ),
      );
    } catch (_) {
      // Test doubles may not implement `done`; SshConnection.close() still
      // calls closeAll() explicitly.
    }
  }

  final SSHClient client;
  final SshPortForwardPlatform _platform;

  /// How long [closeAll] waits for starts that are still in flight. A pending
  /// remote start may only abort once the SSH transport closes, and
  /// `SshConnection.close()` closes the transport after [closeAll], so this
  /// wait must be bounded. A start that settles later still closes its own
  /// handle (the manager is closed by then).
  final Duration pendingStartCloseBound;

  /// Settles when each in-flight [start] has finished, including closing a
  /// handle that arrived after cancellation or [closeAll].
  final Set<Future<void>> _startSettlements = {};

  /// The close future of every stop still in flight. Unlike [_stopping]
  /// (per-profile status, latest stop only), overlapping stops of one profile
  /// after restarts are all kept, so [closeAll] joins each of them.
  final Set<Future<void>> _stopSettlements = {};
  final Map<String, SshPortForwardHandle> _active = {};
  final Map<String, SshPortForwardProfile> _activeProfiles = {};
  final Map<String, SshPortForwardProfile> _startingProfiles = {};
  final Set<String> _cancelledStarts = {};

  /// Handles still being torn down, keyed by profile. Every removal is
  /// identity-checked, so a stop that finishes late can never untrack a newer
  /// listener of the same profile.
  final Map<
    String,
    ({
      SshPortForwardHandle handle,
      SshPortForwardProfile profile,
      Future<void> closing,
    })
  >
  _stopping = {};
  final Map<String, String> _errors = {};
  bool _closed = false;
  bool _disposed = false;

  bool get isSupported => _platform.isSupported;
  String? get unsupportedReason => _platform.unsupportedReason;

  /// False once the SSH connection ended or the manager was closed.
  bool get isOpen => !_closed;

  List<String> get activeProfileIds => List.unmodifiable(
    _active.entries
        .where((entry) => !entry.value.isClosed)
        .map((entry) => entry.key),
  );

  /// Profiles as they were when started. The saved profile may have changed
  /// or been removed (for example by sync) while the forward kept running.
  List<SshPortForwardProfile> get activeProfiles => List.unmodifiable(
    _activeProfiles.entries
        .where((entry) => _active[entry.key]?.isClosed == false)
        .map((entry) => entry.value),
  );

  int get runningCount => activeProfileIds.length;

  bool isStarting(String profileId) => _startingProfiles.containsKey(profileId);

  /// True while an earlier listener of the profile is closing and no newer
  /// one is running.
  bool isStopping(String profileId) =>
      _stopping.containsKey(profileId) &&
      (_active[profileId] == null || _active[profileId]!.isClosed);

  int? activeListeningPort(String profileId) {
    final handle = _active[profileId];
    return handle == null || handle.isClosed ? null : handle.listeningPort;
  }

  SshPortForwardStatus statusOf(String profileId) {
    final handle = _active[profileId];
    if (handle != null && !handle.isClosed) {
      return SshPortForwardStatus(
        state: SshPortForwardState.running,
        listeningPort: handle.listeningPort,
        activeConnections: handle.activeConnections,
        totalConnections: handle.totalConnections,
        lastConnectionError: handle.lastConnectionError,
      );
    }
    if (_startingProfiles.containsKey(profileId)) {
      return const SshPortForwardStatus(state: SshPortForwardState.starting);
    }
    if (_stopping.containsKey(profileId)) {
      return const SshPortForwardStatus(state: SshPortForwardState.stopping);
    }
    final error = _errors[profileId];
    if (error != null) {
      return SshPortForwardStatus(
        state: SshPortForwardState.failed,
        error: error,
      );
    }
    return SshPortForwardStatus.stopped;
  }

  /// Forgets a displayed failure, e.g. after the profile was edited.
  void clearError(String profileId) {
    if (_errors.remove(profileId) != null) _notify();
  }

  Future<SshPortForwardHandle> start(SshPortForwardProfile profile) async {
    if (_closed) {
      throw SshPortForwardException(currentL10n.theSshConnectionForThisForward);
    }
    final issue = profile.validate();
    if (issue != null) throw ArgumentError.value(profile, 'profile', issue);
    if (!_platform.isSupported) {
      throw UnsupportedError(
        _platform.unsupportedReason ??
            currentL10n.sshPortForwardingRuntimeIsUnavailable,
      );
    }
    final current = _active[profile.id];
    if ((current != null && !current.isClosed) ||
        _startingProfiles.containsKey(profile.id)) {
      throw StateError(currentL10n.thisSshPortForwardProfileIs);
    }

    final occupiedProfiles = [
      ..._activeProfiles.entries
          .where((entry) => _active[entry.key]?.isClosed == false)
          .map((entry) => entry.value),
      ..._startingProfiles.values,
      // Another profile's listener that is still closing may still own its
      // address. The same profile may restart; its old handle reported
      // closed, and the OS or server reports a genuinely busy port.
      ..._stopping.entries
          .where((entry) => entry.key != profile.id)
          .map((entry) => entry.value.profile),
    ];
    if (occupiedProfiles.any(
      (active) => sshPortForwardListenersConflict(active, profile),
    )) {
      throw StateError(currentL10n.anotherForwardAlreadyUsesThisListener);
    }

    _errors.remove(profile.id);
    _active.remove(profile.id);
    _activeProfiles.remove(profile.id);
    _startingProfiles[profile.id] = profile;
    _notify();
    final settled = Completer<void>();
    _startSettlements.add(settled.future);
    try {
      return await _completeStart(profile);
    } finally {
      _startSettlements.remove(settled.future);
      settled.complete();
    }
  }

  Future<SshPortForwardHandle> _completeStart(
    SshPortForwardProfile profile,
  ) async {
    SshPortForwardHandle handle;
    try {
      handle = await _platform.start(client, profile);
    } catch (error) {
      _startingProfiles.remove(profile.id);
      if (!_cancelledStarts.remove(profile.id) && !_closed) {
        _errors[profile.id] = describeSshPortForwardError(error);
      }
      _notify();
      rethrow;
    }
    _startingProfiles.remove(profile.id);
    final cancelled = _cancelledStarts.remove(profile.id);
    if (_closed || cancelled) {
      try {
        await handle.close();
      } catch (_) {}
      _notify();
      throw StateError(
        cancelled
            ? currentL10n.forwardStartWasCancelled
            : currentL10n.sshConnectionClosedWhileForwardingWas,
      );
    }
    _active[profile.id] = handle;
    _activeProfiles[profile.id] = profile;
    handle.onChanged = () => _onHandleChanged(profile.id, handle);
    _notify();
    return handle;
  }

  void _onHandleChanged(String profileId, SshPortForwardHandle handle) {
    if (!identical(_active[profileId], handle)) return;
    if (handle.isClosed && !_closed) {
      // The listener stopped by itself (interface removed, socket error).
      _active.remove(profileId);
      _activeProfiles.remove(profileId);
      _errors[profileId] =
          handle.lastConnectionError ??
          currentL10n.theForwardStoppedUnexpectedly;
    }
    _notify();
  }

  /// Stops a running forward, or cancels one that is still starting.
  Future<bool> stop(String profileId) async {
    _errors.remove(profileId);
    if (_startingProfiles.containsKey(profileId)) {
      _cancelledStarts.add(profileId);
      _notify();
      return true;
    }
    final handle = _active[profileId];
    final profile = _activeProfiles[profileId];
    if (handle == null || profile == null) {
      _notify();
      // An earlier stop of this profile still owns its teardown.
      return _stopping.containsKey(profileId);
    }
    handle.onChanged = null;
    // Untrack this exact handle first so status reads "stopping" while it is
    // torn down; a newer start then gets a fresh, independently tracked slot.
    _active.remove(profileId);
    _activeProfiles.remove(profileId);
    // The single close of this handle; closeAll() awaits this same future
    // instead of closing the handle a second time.
    final closing = Future<void>.sync(handle.close);
    _stopping[profileId] = (handle: handle, profile: profile, closing: closing);
    _stopSettlements.add(closing);
    _notify();
    try {
      await closing;
    } finally {
      _stopSettlements.remove(closing);
      if (identical(_stopping[profileId]?.handle, handle)) {
        _stopping.remove(profileId);
      }
      _notify();
    }
    return true;
  }

  void _onTransportEnded() {
    if (_closed) return;
    unawaited(closeAll());
  }

  Future<void>? _closeAll;

  /// Closes every forward of this connection. All handles begin closing at
  /// once: a close that blocks (for example a remote cancellation that a dead
  /// transport never answers) must not keep later device listeners open.
  /// Repeated calls return the same teardown, so callers such as
  /// [SshConnection.close] wait until it actually finished.
  Future<void> closeAll() => _closeAll ??= _closeEverything();

  Future<void> _closeEverything() async {
    _closed = true;
    _cancelledStarts.addAll(_startingProfiles.keys);
    final handles = _active.values.toList(growable: false);
    _active.clear();
    _activeProfiles.clear();
    _errors.clear();
    for (final handle in handles) {
      handle.onChanged = null;
    }
    // A single failed or slow teardown must not keep others open.
    Future<void> isolated(Future<void> Function() operation) =>
        Future<void>.sync(operation).then<void>((_) {}, onError: (Object _) {});
    final stopping = _stopSettlements.toList(growable: false);
    final starts = _startSettlements.toList(growable: false);
    await Future.wait([
      // Active handles: close each exactly once, all at the same time.
      for (final handle in handles) isolated(handle.close),
      // Stops already in progress: join their existing close.
      for (final closing in stopping) isolated(() => closing),
      // Starts in flight: their settlement includes closing a late handle.
      if (starts.isNotEmpty)
        isolated(
          () =>
              Future.wait(starts.map((start) => isolated(() => start)))
                  .timeout(pendingStartCloseBound, onTimeout: () => const []),
        ),
    ]);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(closeAll());
    _disposed = true;
    super.dispose();
  }
}

/// A user-facing message for a forwarding failure. Messages from this
/// runtime are already sanitized; anything else is replaced with a generic
/// sentence so library errors (which may echo protocol data) never reach the
/// UI verbatim.
String describeSshPortForwardError(Object error) {
  if (error is SshPortForwardException) return error.message;
  if (error is UnsupportedError) {
    return error.message ?? currentL10n.sshPortForwardingIsUnavailableHere;
  }
  if (error is ArgumentError) {
    final message = error.message;
    return message is String ? message : currentL10n.theForwardProfileIsInvalid;
  }
  if (error is StateError) return error.message;
  return currentL10n.couldNotStartThisForwardCheck;
}
