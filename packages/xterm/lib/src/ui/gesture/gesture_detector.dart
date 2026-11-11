import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class TerminalGestureDetector extends StatefulWidget {
  const TerminalGestureDetector({
    super.key,
    this.child,
    this.onSingleTapUp,
    this.onTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressUp,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.onDragStart,
    this.onDragUpdate,
    this.onDoubleTapDown,
  });

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onDoubleTapDown;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final GestureLongPressStartCallback? onLongPressStart;

  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;

  final GestureLongPressUpCallback? onLongPressUp;

  /// Called when an accepted long press is released, with its final position.
  final GestureLongPressEndCallback? onLongPressEnd;

  /// Called when a long press is cancelled, including after it was accepted
  /// (for example when the platform cancels the pointer).
  final GestureLongPressCancelCallback? onLongPressCancel;

  final GestureDragStartCallback? onDragStart;

  final GestureDragUpdateCallback? onDragUpdate;

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  Timer? _doubleTapTimer;

  Offset? _lastTapOffset;

  // True if a second tap down of a double tap is detected. Used to discard
  // subsequent tap up / tap hold of the same tap.
  bool _isDoubleTap = false;

  // Touch/stylus tap-downs are held until the tap is confirmed by its tap-up.
  // The tap recognizer reports a down after [kPressTimeout] even when the
  // pointer then becomes a long press or a scroll; forwarding it eagerly would
  // focus/raise the keyboard, clear the selection being made and send an
  // unmatched mouse-down to remote applications that enable mouse reporting.
  TapDownDetails? _pendingTouchTapDown;

  static bool _deferTapDown(PointerDeviceKind? kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  void _handleRecognizerTapDown(TapDownDetails details) {
    if (_deferTapDown(details.kind)) {
      _pendingTouchTapDown = details;
      return;
    }
    _pendingTouchTapDown = null;
    _handleTapDown(details);
  }

  void _handleRecognizerTapUp(TapUpDetails details) {
    final pending = _pendingTouchTapDown;
    _pendingTouchTapDown = null;
    if (pending != null) {
      _handleTapDown(pending);
    }
    _handleTapUp(details);
  }

  void _handleRecognizerTapCancel() {
    _pendingTouchTapDown = null;
  }

  // The down handler is force-run on success of a single tap and optimistically
  // run before a long press success.
  void _handleTapDown(TapDownDetails details) {
    widget.onTapDown?.call(details);

    if (_doubleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      // If there was already a previous tap, the second down hold/tap is a
      // double tap down.
      widget.onDoubleTapDown?.call(details);

      _doubleTapTimer!.cancel();
      _doubleTapTimeout();
      _isDoubleTap = true;
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isDoubleTap) {
      widget.onSingleTapUp?.call(details);
      _lastTapOffset = details.globalPosition;
      _doubleTapTimer = Timer(kDoubleTapTimeout, _doubleTapTimeout);
    }
    _isDoubleTap = false;
  }

  void _doubleTapTimeout() {
    _doubleTapTimer = null;
    _lastTapOffset = null;
  }

  bool _isWithinDoubleTapTolerance(Offset secondTapOffset) {
    if (_lastTapOffset == null) {
      return false;
    }

    final Offset difference = secondTapOffset - _lastTapOffset!;
    return difference.distance <= kDoubleTapSlop;
  }

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};

    gestures[TapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
      () => TapGestureRecognizer(debugOwner: this),
      (TapGestureRecognizer instance) {
        instance
          ..onTapDown = _handleRecognizerTapDown
          ..onTapUp = _handleRecognizerTapUp
          ..onTapCancel = _handleRecognizerTapCancel
          ..onSecondaryTapDown = widget.onSecondaryTapDown
          ..onSecondaryTapUp = widget.onSecondaryTapUp
          ..onTertiaryTapDown = widget.onTertiaryTapDown
          ..onTertiaryTapUp = widget.onTertiaryTapUp;
      },
    );

    gestures[LongPressGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
      () => LongPressGestureRecognizer(
        debugOwner: this,
        supportedDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          // PointerDeviceKind.mouse, // for debugging purposes only
        },
      ),
      (LongPressGestureRecognizer instance) {
        instance
          ..onLongPressStart = widget.onLongPressStart
          ..onLongPressMoveUpdate = widget.onLongPressMoveUpdate
          ..onLongPressUp = widget.onLongPressUp
          ..onLongPressEnd = widget.onLongPressEnd
          ..onLongPressCancel = widget.onLongPressCancel;
      },
    );

    gestures[PanGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
      () => PanGestureRecognizer(
        debugOwner: this,
        supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse},
      ),
      (PanGestureRecognizer instance) {
        instance
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = widget.onDragStart
          ..onUpdate = widget.onDragUpdate;
      },
    );

    return RawGestureDetector(
      gestures: gestures,
      excludeFromSemantics: true,
      child: widget.child,
    );
  }
}
