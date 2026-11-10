import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Direct touchscreen input. Native RDP contacts retain their IDs and never
/// synthesize a mouse. Servers without RDPEI (including standard VNC) get
/// tap/drag/long-press and two-finger scrolling instead.
class DesktopDirectTouch {
  final _points = <int, Offset>{};
  final _slots = <int, int>{};
  void Function(int, int, Offset)? _native;
  void Function(Offset, int)? _mouse;
  bool _nativeMode = false, _multiple = false, _dragging = false, _held = false;
  Offset _start = Offset.zero, _last = Offset.zero;
  double _travel = 0, _scroll = 0;
  Timer? _hold;

  void handle(
    PointerEvent event, {
    required Offset remotePoint,
    required bool nativeTouch,
    required void Function(int id, int phase, Offset point) sendNative,
    required void Function(Offset point, int buttons) sendMouse,
  }) {
    if (_points.isNotEmpty && nativeTouch != _nativeMode) reset();
    if (event is PointerDownEvent) {
      if (_points.isEmpty) {
        _nativeMode = nativeTouch;
        _native = sendNative;
        _mouse = sendMouse;
        _multiple = _dragging = _held = false;
        _travel = _scroll = 0;
        _start = _last = remotePoint;
      }
      if (_points.length >= 10 || _points.containsKey(event.pointer)) return;
      _points[event.pointer] = remotePoint;
      if (_nativeMode) {
        final slot = List.generate(
          10,
          (i) => i + 1,
        ).firstWhere((s) => !_slots.containsValue(s));
        _slots[event.pointer] = slot;
        _native!(slot, 0, remotePoint);
      } else if (_points.length == 1) {
        _mouse!(remotePoint, 0);
        _hold = Timer(kLongPressTimeout, () {
          if (_points.length == 1 && !_dragging && _travel < kTouchSlop) {
            _held = true;
            _click(_last, 4);
          }
        });
      } else {
        _multiple = true;
        _hold?.cancel();
        if (_dragging) _mouse!(_last, 0);
        _dragging = false;
      }
    } else if (event is PointerMoveEvent &&
        _points.containsKey(event.pointer)) {
      _points[event.pointer] = remotePoint;
      if (_nativeMode) {
        _native!(_slots[event.pointer]!, 1, remotePoint);
      } else {
        // Use screen-space distance for a stable gesture threshold at any zoom.
        _travel += event.delta.distance;
        if (_travel >= kTouchSlop) _hold?.cancel();
        if (_points.length > 1) {
          _scroll += event.delta.dy / _points.length;
          while (_scroll.abs() >= 20) {
            // Natural touch scrolling: dragging contents upwards scrolls down.
            final down = _scroll < 0;
            _click(_last, down ? 16 : 8);
            _scroll += down ? 20 : -20;
          }
        } else if (!_multiple && !_held && _travel >= kTouchSlop) {
          if (!_dragging) {
            _mouse!(_start, 1);
            _dragging = true;
          }
          _mouse!(remotePoint, 1);
        }
        _last = remotePoint;
      }
    } else if ((event is PointerUpEvent || event is PointerCancelEvent) &&
        _points.containsKey(event.pointer)) {
      if (_nativeMode) {
        _native!(
          _slots.remove(event.pointer)!,
          event is PointerCancelEvent ? 3 : 2,
          remotePoint,
        );
      } else {
        _hold?.cancel();
        if (_dragging) _mouse!(remotePoint, 0);
        if (event is PointerUpEvent &&
            _points.length == 1 &&
            !_multiple &&
            !_dragging &&
            !_held)
          _click(remotePoint, 1);
        _dragging = false;
      }
      _points.remove(event.pointer);
      if (_points.isEmpty) reset();
    }
  }

  void _click(Offset point, int button) {
    _mouse?.call(point, button);
    _mouse?.call(point, 0);
  }

  /// Releases the original session even when a pane is replaced or disposed.
  void reset() {
    _hold?.cancel();
    if (_nativeMode) {
      for (final entry in _slots.entries) {
        _native?.call(entry.value, 3, _points[entry.key]!);
      }
    } else if (_dragging) {
      _mouse?.call(_last, 0);
    }
    _points.clear();
    _slots.clear();
    _native = null;
    _mouse = null;
    _dragging = _multiple = _held = false;
  }
}
