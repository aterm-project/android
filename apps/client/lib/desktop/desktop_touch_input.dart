import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Converts touchpad gestures to the same pointer packets as a real mouse.
/// Physical mice are handled by DesktopView and never pass through this class.
class DesktopTouchInput {
  DesktopTouchInput({required this.pointer, required this.send});

  final Offset Function() pointer;
  final void Function(Offset point, int buttons) send;
  bool trackpad = false;
  final _points = <int, Offset>{};
  Offset? _start;
  Offset? _lastTap;
  DateTime? _started, _lastTapTime;
  double _travel = 0, _scroll = 0;
  bool _multiple = false, _dragging = false, _longClicked = false;
  Timer? _hold;
  Rect _bounds = Rect.zero;

  void _mouse(Offset point, int buttons) {
    if (_bounds.isEmpty) return;
    send(
      Offset(
        point.dx.clamp(_bounds.left, _bounds.right - 1),
        point.dy.clamp(_bounds.top, _bounds.bottom - 1),
      ),
      buttons,
    );
  }

  void _click(int button) {
    _mouse(pointer(), button);
    _mouse(pointer(), 0);
  }

  void handle(
    PointerEvent event, {
    required Rect bounds,
    required double scale,
  }) {
    _bounds = bounds;
    if (!trackpad || bounds.isEmpty || !scale.isFinite || scale <= 0) return;
    if (event is PointerDownEvent) {
      _points[event.pointer] = event.position;
      if (_points.length == 1) {
        _start = event.position;
        _started = DateTime.now();
        _travel = _scroll = 0;
        _multiple = _longClicked = false;
        _dragging =
            _lastTapTime != null &&
            _started!.difference(_lastTapTime!) < kDoubleTapTimeout &&
            (_lastTap! - event.position).distance < 32;
        _lastTapTime = null;
        if (_dragging) _mouse(pointer(), 1);
        _hold = Timer(kLongPressTimeout, () {
          if (_points.length == 1 && !_dragging && _travel < kTouchSlop) {
            _longClicked = true;
            _click(4);
          }
        });
      } else {
        _multiple = true;
        _hold?.cancel();
        if (_dragging) _mouse(pointer(), 0);
        _dragging = false;
      }
    } else if (event is PointerMoveEvent &&
        _points.containsKey(event.pointer)) {
      final previous = _points[event.pointer]!;
      final delta = event.position - previous;
      _points[event.pointer] = event.position;
      _travel += delta.distance;
      if (_travel >= kTouchSlop) _hold?.cancel();
      if (_points.length > 1) {
        _scroll += delta.dy / _points.length;
        while (_scroll.abs() >= 20) {
          final down = _scroll > 0;
          _mouse(pointer(), down ? 16 : 8);
          _mouse(pointer(), 0);
          _scroll += down ? -20 : 20;
        }
      } else if (!_multiple && !_longClicked) {
        _mouse(pointer() + delta / scale, _dragging ? 1 : 0);
      }
    } else if (event is PointerUpEvent &&
        _points.remove(event.pointer) != null) {
      if (_points.isNotEmpty) return;
      _hold?.cancel();
      if (_dragging) {
        _mouse(pointer(), 0);
      } else if (!_longClicked &&
          _travel < kTouchSlop &&
          DateTime.now().difference(_started!) < kLongPressTimeout) {
        _click(_multiple ? 4 : 1);
        if (!_multiple) {
          _lastTapTime = DateTime.now();
          _lastTap = _start;
        }
      }
      _dragging = false;
    } else if (event is PointerCancelEvent) {
      reset();
    }
  }

  void reset() {
    _hold?.cancel();
    if (_dragging) _mouse(pointer(), 0);
    _points.clear();
    _dragging = _multiple = _longClicked = false;
    _lastTapTime = null;
  }

  void dispose() => reset();
}
