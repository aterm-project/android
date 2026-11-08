import 'session_credentials.dart';
import 'session_update_notifier_native.dart'
    if (dart.library.js_interop) 'session_update_notifier_web.dart'
    as platform;

export 'session_update_notifier_native.dart'
    if (dart.library.js_interop) 'session_update_notifier_web.dart';

SessionUpdateNotifier createSessionUpdateNotifier() =>
    platform.createSessionUpdateNotifier();
