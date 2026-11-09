import 'dart:async';

/// Owns the automatic sync triggers for one unlocked client session.
/// Errors are intentionally contained here; the callback is responsible for
/// updating visible sync status while local edits remain queued for retry.
///
/// Two independent gates decide whether a trigger may transfer Vault content:
/// [isEnabled] is the controller lifecycle (signed in, unlocked, healthy
/// database), and [userEnabled] is the device-local "Automatic sync" choice
/// (false until that choice has been loaded). Turning the user gate off
/// cancels pending timers without touching the durable outbox; explicit
/// callers keep using the controller directly.
class AutoSyncCoordinator {
  AutoSyncCoordinator({
    required this.isEnabled,
    required this.synchronize,
    this.debounce = const Duration(milliseconds: 700),
    this.interval = const Duration(seconds: 45),
    bool initialUserEnabled = true,
  }) : _userEnabled = initialUserEnabled;

  final bool Function() isEnabled;
  final Future<void> Function() synchronize;
  final Duration debounce;
  final Duration interval;

  Timer? _debounceTimer;
  Timer? _periodicTimer;
  bool _running = false;
  bool _followUpPending = false;
  bool _userEnabled;
  // True between a lifecycle start() and stop(). Exclusive controller
  // operations stop the coordinator; a user toggle must not restart it inside
  // that window, only the operation's own start() may.
  bool _started = false;

  bool get userEnabled => _userEnabled;
  bool get _active => _userEnabled && isEnabled();

  void start() {
    _started = true;
    if (!_active) return;
    _periodicTimer ??= Timer.periodic(interval, (_) => _runSafely());
    unawaited(_runSafely());
  }

  /// Applies the user's automatic sync choice. Disabling cancels scheduled
  /// work and any coalesced follow-up; a pass already on the wire finishes so
  /// the repository never observes a half-applied batch. Enabling resumes the
  /// lifecycle schedule and runs one catch-up pass for queued edits.
  void setUserEnabled(bool value) {
    if (_userEnabled == value) return;
    _userEnabled = value;
    if (!value) {
      _cancelTimers();
      return;
    }
    if (_started) start();
  }

  void scheduleEdit() {
    if (!_active) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _runSafely);
  }

  Future<void> foregroundResumed() => _runSafely();

  /// Coalesces realtime invalidation hints with an in-flight sync. A hint is
  /// only a reason to pull authoritative state; one extra sync is queued when
  /// a hint arrives while the current sync is already running.
  Future<void> hintReceived() async {
    if (!_active) return;
    if (_running) {
      _followUpPending = true;
      return;
    }
    await _runSafely();
  }

  Future<void> _runSafely() async {
    if (!_active) return;
    if (_running) {
      // Keep edit timers and other triggers that fire during the controller's
      // post-sync refresh. The active pass may already have finished its
      // repository push before the new edit reached the outbox.
      _followUpPending = true;
      return;
    }
    _running = true;
    try {
      await synchronize();
    } catch (_) {
      // Background sync must never create an unhandled future. The app's sync
      // callback records the status; queued ciphertext remains retryable.
    } finally {
      _running = false;
      if (_followUpPending && _active) {
        _followUpPending = false;
        unawaited(_runSafely());
      }
    }
  }

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _followUpPending = false;
  }

  void stop() {
    _started = false;
    _cancelTimers();
  }
}
