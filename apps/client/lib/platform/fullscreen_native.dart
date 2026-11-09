import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_geometry.dart';

const _channel = MethodChannel('atermius/fullscreen');
bool _iosFullscreen = false;
final _changes = StreamController<bool>.broadcast();
bool _listening = false;
Stream<bool> get fullscreenChanges {
  if (!_listening) {
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && call.arguments is bool) {
        _changes.add(call.arguments as bool);
      }
    });
  }
  return _changes.stream;
}

Future<bool?> readFullscreen() async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return (await WindowGeometry.instance.bounds())?.covering;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) return _iosFullscreen;
  return _channel.invokeMethod<bool>('get');
}

Future<bool> applyFullscreen(bool enabled) async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    final geometry = WindowGeometry.instance;
    if (!enabled) {
      await geometry.uncover();
      return (await geometry.bounds())?.covering ?? true;
    }
    final bounds = await geometry.bounds();
    final monitors = await geometry.monitors();
    if (bounds == null || monitors.isEmpty) return false;
    monitors.sort((a, b) {
      double area(MonitorInfo m) {
        final rect = m.bounds.intersect(bounds.current);
        return rect.isEmpty ? 0 : rect.width * rect.height;
      }

      return area(b).compareTo(area(a));
    });
    return await geometry.coverMonitor(monitors.first.bounds);
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: enabled ? const [] : SystemUiOverlay.values,
    );
    _iosFullscreen = enabled;
    return enabled;
  }
  return await _channel.invokeMethod<bool>('set', {'enabled': enabled}) ??
      false;
}
