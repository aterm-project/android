import 'session_credentials.dart';
import 'session_refresh_lock_native.dart'
    if (dart.library.js_interop) 'session_refresh_lock_web.dart'
    as platform;

export 'session_refresh_lock_native.dart'
    if (dart.library.js_interop) 'session_refresh_lock_web.dart';

SessionRefreshLock createSessionRefreshLock() =>
    platform.createSessionRefreshLock();
