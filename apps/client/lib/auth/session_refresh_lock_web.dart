import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'session_credentials.dart';

class _WebSessionRefreshLock implements SessionRefreshLock {
  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final navigator = web.window.navigator;
    if (!navigator.hasProperty('locks'.toJS).toDart) {
      throw const SessionCoordinationUnavailableException();
    }

    T? result;
    var completed = false;
    Object? operationError;
    StackTrace? operationStack;
    final granted = ((web.Lock? _) {
      final work = action().then<void>(
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
            'atermius.auth-refresh.v1',
            web.LockOptions(mode: 'exclusive'),
            granted,
          )
          .toDart;
    } catch (_) {
      // Do not send a refresh request if lock acquisition failed. Replaying a
      // single-use token could revoke a valid session family.
      throw const SessionCoordinationUnavailableException();
    }
    final error = operationError;
    if (error != null) {
      Error.throwWithStackTrace(error, operationStack ?? StackTrace.current);
    }
    if (!completed) {
      throw const SessionCoordinationUnavailableException();
    }
    return result as T;
  }
}

SessionRefreshLock createSessionRefreshLock() => _WebSessionRefreshLock();
