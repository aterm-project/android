import 'package:web/web.dart' as web;

bool get browserReportsOffline => !web.window.navigator.onLine;
