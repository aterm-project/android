import 'application_reload_stub.dart'
    if (dart.library.js_interop) 'application_reload_web.dart'
    as platform;

void reloadApplication() => platform.reloadApplication();
