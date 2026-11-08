import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_app_update_monitor.dart';

@JS('atermiusWebBuildId')
external JSString get _currentBuildId;

@JS('atermiusProbeWebBuild')
external JSPromise<JSString> _probeWebBuild();

WebAppUpdateMonitor createWebAppUpdateMonitor() => WebAppUpdateMonitor(
  currentBuildId: _currentBuildId.toDart,
  probeBuildId: () async => (await _probeWebBuild().toDart).toDart,
  reload: () async => web.window.location.reload(),
);
