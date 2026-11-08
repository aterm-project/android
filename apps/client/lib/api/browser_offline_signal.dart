import 'browser_offline_signal_stub.dart'
    if (dart.library.js_interop) 'browser_offline_signal_web.dart'
    as platform;

bool get browserReportsOffline => platform.browserReportsOffline;
