import 'dart:ui';

import '../domain/window_placement.dart';
import 'window_chrome.dart';

import 'package:flutter/services.dart';

/// Client for the runner's `atermius/window_geometry` channel (Windows).
/// Acts only on this process's own window. On other platforms every call
/// returns null/false. Saved window combinations can use [bounds] and
/// [setBounds]; RDP monitor windows use [coverMonitor].
class WindowGeometry {
  WindowGeometry({MethodChannel? channel, WindowChromeController? chrome})
    : _channel = channel ?? const MethodChannel('atermius/window_geometry'),
      _chrome = chrome ?? WindowChromeController.instance;
  static final instance = WindowGeometry();
  final MethodChannel _channel;
  final WindowChromeController _chrome;

  static Rect? _rect(Object? value) {
    if (value is! Map) return null;
    final x = value['x'],
        y = value['y'],
        w = value['width'],
        h = value['height'];
    if (x is! int || y is! int || w is! int || h is! int) return null;
    return Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      w.toDouble(),
      h.toDouble(),
    );
  }

  Future<List<MonitorInfo>> monitors() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('getMonitors');
      return [
        for (final item in raw ?? const [])
          if (item is Map && _rect(item['bounds']) != null)
            MonitorInfo(
              bounds: _rect(item['bounds'])!,
              work: _rect(item['work']) ?? _rect(item['bounds'])!,
              primary: item['primary'] == true,
              dpi: item['dpi'] is int ? item['dpi'] as int : 96,
            ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<WindowBounds?> bounds() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getBounds',
      );
      final current = _rect(raw?['bounds']), normal = _rect(raw?['normal']);
      if (current == null || normal == null) return null;
      return WindowBounds(
        current: current,
        normal: normal,
        maximized: raw!['maximized'] == true,
        minimized: raw['minimized'] == true,
        covering: raw['covering'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> _rectCall(String method, Rect rect) async {
    try {
      return await _channel.invokeMethod<bool>(method, {
            'x': rect.left.round(),
            'y': rect.top.round(),
            'width': rect.width.round(),
            'height': rect.height.round(),
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<SavedWindowPlacement?> capturePlacement() async {
    final value = await bounds();
    if (value == null) return null;
    try {
      return SavedWindowPlacement(
        x: value.normal.left.round(),
        y: value.normal.top.round(),
        width: value.normal.width.round(),
        height: value.normal.height.round(),
        maximized: value.maximized,
      );
    } on FormatException {
      return null;
    }
  }

  /// Explicit restoration only. Monitor removal/changed work areas cannot strand
  /// the title bar offscreen; unsupported platforms keep their default position.
  Future<bool> restorePlacement(
    SavedWindowPlacement value, {
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) return false;
    final rect = safeWindowRect(value, await monitors());
    if (isCurrent?.call() == false) return false;
    if (rect == null || !await setBounds(rect)) return false;
    if (isCurrent?.call() == false) return false;
    if (value.maximized) {
      await _chrome.refresh();
      if (!_chrome.state.enabled || isCurrent?.call() == false) return false;
      final current = await bounds();
      if (current == null || isCurrent?.call() == false) return false;
      if (!current.maximized) await _chrome.toggleMaximize();
      if (isCurrent?.call() == false) return false;
      return (await bounds())?.maximized == true;
    }
    return true;
  }

  /// Returns false when [rect] is not on any current monitor.
  Future<bool> setBounds(Rect rect) => _rectCall('setBounds', rect);

  /// Borderless cover of an exact current monitor rectangle.
  Future<bool> coverMonitor(Rect monitor) => _rectCall('coverMonitor', monitor);

  Future<void> uncover() async {
    try {
      await _channel.invokeMethod<bool>('uncover');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

class MonitorInfo {
  const MonitorInfo({
    required this.bounds,
    required this.work,
    required this.primary,
    required this.dpi,
  });
  final Rect bounds, work;
  final bool primary;
  final int dpi;
}

class WindowBounds {
  const WindowBounds({
    required this.current,
    required this.normal,
    required this.maximized,
    required this.minimized,
    required this.covering,
  });
  final Rect current, normal;
  final bool maximized, minimized, covering;
}

/// Fits a saved normal window into a current work area. Largest overlap wins;
/// no overlap chooses primary. Bounds are clamped fully inside that monitor.
Rect? safeWindowRect(SavedWindowPlacement value, List<MonitorInfo> monitors) {
  final valid = monitors
      .where(
        (m) => m.work.isFinite && m.work.width >= 200 && m.work.height >= 150,
      )
      .take(16)
      .toList();
  if (valid.isEmpty) return null;
  final saved = Rect.fromLTWH(
    value.x.toDouble(),
    value.y.toDouble(),
    value.width.toDouble(),
    value.height.toDouble(),
  );
  var chosen = valid.where((m) => m.primary).firstOrNull ?? valid.first;
  var overlap = 0.0;
  for (final monitor in valid) {
    final intersection = saved.intersect(monitor.work);
    final area = intersection.width > 0 && intersection.height > 0
        ? intersection.width * intersection.height
        : 0.0;
    if (area > overlap) {
      overlap = area;
      chosen = monitor;
    }
  }
  final work = chosen.work;
  final width = saved.width.clamp(200.0, work.width),
      height = saved.height.clamp(150.0, work.height);
  return Rect.fromLTWH(
    saved.left.clamp(work.left, work.right - width),
    saved.top.clamp(work.top, work.bottom - height),
    width,
    height,
  );
}
