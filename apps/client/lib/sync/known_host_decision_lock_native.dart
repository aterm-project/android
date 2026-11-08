import 'dart:async';
import 'dart:collection';

import 'known_host_decision_lock_contract.dart';
import '../platform/native_coordination.dart';
import '../platform/process_file_lock.dart';

/// FIFO local readers/writers plus cross-process trust projection locking.
class _NativeKnownHostDecisionLock implements KnownHostDecisionLock {
  static final Map<String, _NativeLockState> _states =
      <String, _NativeLockState>{};

  @override
  Future<T> run<T>(
    KnownHostDecisionScope scope,
    Future<T> Function() action, {
    KnownHostDecisionLockMode mode = KnownHostDecisionLockMode.exclusive,
    Future<void>? cancel,
  }) async {
    final key = scope.lockName;
    final state = _states.putIfAbsent(key, _NativeLockState.new);
    final waiter = _NativeLockWaiter(mode);
    state.enqueue(waiter);

    if (cancel != null) {
      try {
        final acquired = await Future.any<bool>([
          waiter.acquired.future.then((_) => true),
          cancel.then((_) => false),
        ]);
        if (!acquired && !waiter.granted) {
          state.cancel(waiter);
          _removeIfIdle(key, state);
          throw const KnownHostDecisionCancelledException();
        }
      } catch (error) {
        if (error is KnownHostDecisionCancelledException) rethrow;
        if (!waiter.granted) {
          state.cancel(waiter);
          _removeIfIdle(key, state);
        }
        rethrow;
      }
    }

    if (!waiter.granted) await waiter.acquired.future;
    try {
      final lock = await nativeProcessLock();
      try {
        return await lock.run(
          key,
          action,
          shared: mode == KnownHostDecisionLockMode.shared,
          cancel: cancel,
        );
      } on ProcessLockCancelled {
        throw const KnownHostDecisionCancelledException();
      }
    } finally {
      state.release(mode);
      _removeIfIdle(key, state);
    }
  }

  void _removeIfIdle(String key, _NativeLockState state) {
    if (state.isIdle && identical(_states[key], state)) _states.remove(key);
  }
}

class _NativeLockState {
  final Queue<_NativeLockWaiter> _queue = Queue<_NativeLockWaiter>();
  var _activeReaders = 0;
  var _exclusiveActive = false;

  bool get isIdle => _queue.isEmpty && _activeReaders == 0 && !_exclusiveActive;

  void enqueue(_NativeLockWaiter waiter) {
    _queue.addLast(waiter);
    _drain();
  }

  void cancel(_NativeLockWaiter waiter) {
    if (waiter.granted) return;
    if (_queue.remove(waiter)) _drain();
  }

  void release(KnownHostDecisionLockMode mode) {
    switch (mode) {
      case KnownHostDecisionLockMode.shared:
        if (_activeReaders == 0) {
          throw StateError(
            'KnownHost shared lock was released without a reader.',
          );
        }
        _activeReaders--;
        break;
      case KnownHostDecisionLockMode.exclusive:
        if (!_exclusiveActive) {
          throw StateError(
            'KnownHost exclusive lock was released without a writer.',
          );
        }
        _exclusiveActive = false;
        break;
    }
    _drain();
  }

  void _drain() {
    if (_exclusiveActive || _queue.isEmpty) return;

    if (_activeReaders > 0) {
      // New readers may join the current batch only while no writer is ahead
      // of them. A queued writer therefore cannot be starved by later readers.
      while (_queue.isNotEmpty &&
          _queue.first.mode == KnownHostDecisionLockMode.shared) {
        _grantReader(_queue.removeFirst());
      }
      return;
    }

    if (_queue.first.mode == KnownHostDecisionLockMode.exclusive) {
      _exclusiveActive = true;
      _queue.removeFirst().grant();
      return;
    }

    while (_queue.isNotEmpty &&
        _queue.first.mode == KnownHostDecisionLockMode.shared) {
      _grantReader(_queue.removeFirst());
    }
  }

  void _grantReader(_NativeLockWaiter waiter) {
    _activeReaders++;
    waiter.grant();
  }
}

class _NativeLockWaiter {
  _NativeLockWaiter(this.mode);

  final KnownHostDecisionLockMode mode;
  final Completer<void> acquired = Completer<void>();
  var granted = false;

  void grant() {
    granted = true;
    acquired.complete();
  }
}

KnownHostDecisionLock createKnownHostDecisionLock() =>
    _NativeKnownHostDecisionLock();
