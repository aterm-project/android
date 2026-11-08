import 'dart:async';

import 'session_credentials.dart';
import '../platform/native_coordination.dart';

/// Serialize refreshes both within this process and across desktop windows.
class _NativeSessionRefreshLock implements SessionRefreshLock {
  static Future<void> _tail = Future<void>.value();

  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      final lock = await nativeProcessLock();
      return await lock.run('atermius.session-refresh.v1', action);
    } finally {
      release.complete();
    }
  }
}

SessionRefreshLock createSessionRefreshLock() => _NativeSessionRefreshLock();
