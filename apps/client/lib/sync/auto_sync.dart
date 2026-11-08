import 'dart:async';

/// Owns the automatic sync triggers for one unlocked client session.
/// Errors are intentionally contained here; the callback is responsible for
/// updating visible sync status while local edits remain queued for retry.
class AutoSyncCoordinator {
  AutoSyncCoordinator({
    required this.isEnabled,
    required this.synchronize,
    this.debounce = const Duration(milliseconds: 700),
    this.interval = const Duration(seconds: 45),
  });

  final bool Function() isEnabled;
  final Future<void> Function() synchronize;
  final Duration debounce;
  final Duration interval;

  Timer? _debounceTimer;
  Timer? _periodicTimer;
  bool _running = false;
  bool _followUpPending = false;

  void start() {
    if (!isEnabled()) return;
    _periodicTimer ??= Timer.periodic(interval, (_) => _runSafely());
    unawaited(_runSafely());
  }

  void scheduleEdit() {
    if (!isEnabled()) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _runSafely);
  }

  Future<void> foregroundResumed() => _runSafely();

  /// Coalesces realtime invalidation hints with an in-flight sync. A hint is
  /// only a reason to pull authoritative state; one extra sync is queued when
  /// a hint arrives while the current sync is already running.
  Future<void> hintReceived() async {
    if (!isEnabled()) return;
    if (_running) {
      _followUpPending = true;
      return;
    }
    await _runSafely();
  }

  Future<void> _runSafely() async {
    if (!isEnabled()) return;
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
      if (_followUpPending && isEnabled()) {
        _followUpPending = false;
        unawaited(_runSafely());
      }
    }
  }

  void stop() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _followUpPending = false;
  }
}
