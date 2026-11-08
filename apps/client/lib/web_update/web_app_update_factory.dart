import 'web_app_update_monitor.dart';
import 'web_app_update_stub.dart'
    if (dart.library.js_interop) 'web_app_update_web.dart'
    as platform;

WebAppUpdateMonitor? createWebAppUpdateMonitor() =>
    platform.createWebAppUpdateMonitor();
