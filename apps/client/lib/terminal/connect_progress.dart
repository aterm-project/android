import 'package:flutter/foundation.dart';

/// A step an owner has actually reached while opening a session. Stages are
/// only advanced from real callbacks (credential lookup finished, transport
/// started, host key presented, user prompt shown, ...); there is no
/// percentage and no timer-driven progress.
enum ConnectStage {
  /// Validating the Host and resolving saved sign-in material.
  preparing,

  /// Opening the transport (TCP, relay or native engine) and handshaking.
  connecting,

  /// The server presented its identity (SSH host key / RDP certificate).
  verifyingHost,

  /// Waiting for the user (host key review, keyboard-interactive prompt).
  awaitingUser,

  /// The host identity was accepted; user authentication is running.
  authenticating,

  /// Spawning a local shell / serial console or waiting for the first frame.
  startingSession,
}

/// Visible state of a tab's initial-connection surface. [idle] means the tab
/// has no pending/failed initial attempt (it connected, or was never tracked).
enum ConnectPhase { idle, loading, failed, cancelled }

/// Per-tab connection-attempt state shared by the cloud workspace and local
/// profiles. Every attempt gets a monotonically increasing token from [begin];
/// stale tokens (after [cancel], a newer [begin] or [retire]) are ignored, so a
/// late result from an abandoned attempt can never change what the tab shows.
///
/// Owners still enforce their own scope fences (account, Vault, profile,
/// generation); this object only records what the user should see.
class ConnectProgress extends ChangeNotifier {
  ConnectPhase _phase = ConnectPhase.idle;
  ConnectStage _stage = ConnectStage.preparing;
  String? _error;
  int _attempt = 0;
  bool _retired = false;

  ConnectPhase get phase => _phase;
  ConnectStage get stage => _stage;
  String? get error => _error;

  /// Token of the newest attempt (also bumped by [cancel] and [retire]).
  int get attempt => _attempt;
  bool get retired => _retired;
  bool get isVisible => !_retired && _phase != ConnectPhase.idle;
  bool get isLoading => !_retired && _phase == ConnectPhase.loading;

  /// Starts a new attempt and returns its token. Any earlier token is stale.
  int begin([ConnectStage stage = ConnectStage.preparing]) {
    if (_retired) return ++_attempt;
    _attempt++;
    _phase = ConnectPhase.loading;
    _stage = stage;
    _error = null;
    notifyListeners();
    return _attempt;
  }

  /// Whether [attempt] is still the live, loading attempt.
  bool isCurrent(int attempt) =>
      !_retired && attempt == _attempt && _phase == ConnectPhase.loading;

  void advance(int attempt, ConnectStage stage) {
    if (!isCurrent(attempt) || _stage == stage) return;
    _stage = stage;
    notifyListeners();
  }

  /// The attempt reached a live session: the progress surface disappears.
  bool succeed(int attempt) {
    if (!isCurrent(attempt)) return false;
    _phase = ConnectPhase.idle;
    _error = null;
    notifyListeners();
    return true;
  }

  bool fail(int attempt, String message) {
    if (!isCurrent(attempt)) return false;
    _phase = ConnectPhase.failed;
    _error = message;
    notifyListeners();
    return true;
  }

  /// User stopped loading. Returns false when nothing was loading. The
  /// cancelled attempt's token becomes stale immediately.
  bool cancel() {
    if (!isLoading) return false;
    _attempt++;
    _phase = ConnectPhase.cancelled;
    _error = null;
    notifyListeners();
    return true;
  }

  /// The tab closed: every token becomes stale and nothing is shown again.
  void retire() {
    if (_retired) return;
    _retired = true;
    _attempt++;
    _phase = ConnectPhase.idle;
    _error = null;
    notifyListeners();
  }
}
