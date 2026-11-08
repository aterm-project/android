import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'known_host_decision_lock_contract.dart';

class _WebKnownHostDecisionLock implements KnownHostDecisionLock {
  @override
  Future<T> run<T>(
    KnownHostDecisionScope scope,
    Future<T> Function() action, {
    KnownHostDecisionLockMode mode = KnownHostDecisionLockMode.exclusive,
    Future<void>? cancel,
  }) async {
    final navigator = web.window.navigator;
    if (!navigator.hasProperty('locks'.toJS).toDart) {
      throw const KnownHostDecisionCoordinationUnavailableException();
    }

    final abortController = web.AbortController();
    var cancelled = false;
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          cancelled = true;
          abortController.abort();
        }),
      );
    }

    T? result;
    var completed = false;
    Object? operationError;
    StackTrace? operationStack;
    final granted = ((web.Lock? _) {
      final work = Future<T>.sync(action).then<void>(
        (value) {
          result = value;
          completed = true;
        },
        onError: (Object error, StackTrace stackTrace) {
          operationError = error;
          operationStack = stackTrace;
          completed = true;
        },
      );
      return work.toJS;
    }).toJS;

    try {
      await navigator.locks
          .request(
            scope.lockName,
            web.LockOptions(
              mode: mode == KnownHostDecisionLockMode.shared
                  ? 'shared'
                  : 'exclusive',
              signal: abortController.signal,
            ),
            granted,
          )
          .toDart;
    } catch (_) {
      if (cancelled) throw const KnownHostDecisionCancelledException();
      final error = operationError;
      if (error != null) {
        Error.throwWithStackTrace(error, operationStack ?? StackTrace.current);
      }
      throw const KnownHostDecisionCoordinationUnavailableException();
    }

    final error = operationError;
    if (error != null) {
      Error.throwWithStackTrace(error, operationStack ?? StackTrace.current);
    }
    if (!completed) {
      throw const KnownHostDecisionCoordinationUnavailableException();
    }
    return result as T;
  }
}

KnownHostDecisionLock createKnownHostDecisionLock() =>
    _WebKnownHostDecisionLock();
