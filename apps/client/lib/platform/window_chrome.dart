import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class WindowChromeState {
  const WindowChromeState({
    this.enabled = false,
    bool? customFrame,
    this.maximized = false,
    this.minimized = false,
    this.focused = true,
    this.captionHeight,
    this.leadingInset = 0,
  }) : customFrame = customFrame ?? enabled;

  final bool enabled;

  /// True when the native runner removed the OS title bar so Flutter should
  /// draw custom caption controls (Windows). False when native window lifecycle
  /// and close-guard control are enabled while keeping the native title bar
  /// (macOS traffic-light title bar).
  final bool customFrame;
  final bool maximized;
  final bool minimized;
  final bool focused;

  /// Native title-bar height of the own window in logical pixels, reported
  /// by the Windows runner from GetSystemMetricsForDpi(SM_CYCAPTION) plus the
  /// top sizing frame (SM_CYSIZEFRAME + SM_CXPADDEDBORDER) at the window's
  /// GetDpiForWindow DPI. Null when the runner does not report it.
  final double? captionHeight;

  /// Leading horizontal safe inset reserved for native window controls inside a
  /// full-size unified title bar (e.g. macOS traffic lights, 0 in fullscreen).
  final double leadingInset;

  /// Plausibility bounds for the reported metric. Values outside them are
  /// ignored (treated as unreported) rather than trusted.
  static const minCaptionHeight = 16.0;
  static const maxCaptionHeight = 96.0;
  static const maxLeadingInset = 240.0;

  static double? _captionHeight(Object? value) {
    if (value is! num) return null;
    final height = value.toDouble();
    if (!height.isFinite ||
        height < minCaptionHeight ||
        height > maxCaptionHeight) {
      return null;
    }
    return height;
  }

  static double _leadingInset(Object? value) {
    if (value is! num) return 0;
    final inset = value.toDouble();
    if (!inset.isFinite || inset < 0 || inset > maxLeadingInset) {
      return 0;
    }
    return inset;
  }

  static WindowChromeState? fromNative(Object? value) {
    if (value is! Map ||
        const [
          'enabled',
          'maximized',
          'minimized',
          'focused',
        ].any((key) => value[key] is! bool)) {
      return null;
    }
    final enabled = value['enabled'] as bool;
    return WindowChromeState(
      enabled: enabled,
      customFrame: value['customFrame'] is bool
          ? (value['customFrame'] as bool && enabled)
          : enabled,
      maximized: value['maximized'] as bool,
      minimized: value['minimized'] as bool,
      focused: value['focused'] as bool,
      captionHeight: _captionHeight(value['captionHeight']),
      leadingInset: enabled ? _leadingInset(value['leadingInset']) : 0,
    );
  }
}

/// Own-window operations only; no process, path or arbitrary HWND arguments.
/// Foundation's platform check keeps dart:io out of web builds.
class WindowChromeController extends ChangeNotifier {
  WindowChromeController({
    MethodChannel channel = const MethodChannel('atermius/window_chrome'),
    bool? supported,
    // Public channel injection keeps native bridge tests isolated.
    // ignore: prefer_initializing_formals
  }) : _channel = channel,
       supported =
           supported ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.windows ||
                   defaultTargetPlatform == TargetPlatform.macOS));

  static final instance = WindowChromeController();
  final MethodChannel _channel;
  final bool supported;
  WindowChromeState _state = const WindowChromeState();
  WindowChromeState get state => _state;
  Future<void>? _starting;
  bool _disposed = false;
  Future<void> Function()? _closeGuard;
  bool _closeRequestInFlight = false;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!supported || _disposed) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') _accept(call.arguments);
      if (call.method == 'closeRequested' &&
          !_disposed &&
          !_closeRequestInFlight) {
        final guard = _closeGuard;
        if (guard == null) return;
        _closeRequestInFlight = true;
        try {
          await guard();
        } on Object {
          // A failed guard must not terminate an engine that owns SSH sessions.
        } finally {
          _closeRequestInFlight = false;
        }
      }
    });
    try {
      _accept(await _channel.invokeMethod<Object?>('enable'));
    } on MissingPluginException {
      // A runner without the bridge keeps its original system caption.
    } on PlatformException {
      // Keep the platform caption as fallback if setup is unavailable.
    }
  }

  void _accept(Object? value) {
    final next = WindowChromeState.fromNative(value);
    if (_disposed || next == null) return;
    if (next.enabled == _state.enabled &&
        next.customFrame == _state.customFrame &&
        next.maximized == _state.maximized &&
        next.minimized == _state.minimized &&
        next.focused == _state.focused &&
        next.captionHeight == _state.captionHeight &&
        next.leadingInset == _state.leadingInset) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!supported || _disposed) return;
    try {
      _accept(await _channel.invokeMethod<Object?>('getState'));
    } on MissingPluginException {
      // No native bridge in FlutterTester or an older runner.
    } on PlatformException {
      // State notifications can still provide the next update.
    }
  }

  Future<void> _command(String method) async {
    if (!supported || _disposed || !_state.enabled) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Keep controls available for retry; never strand a custom-frame window.
    } on PlatformException {
      // Native window state may be changing concurrently with this request.
    }
  }

  /// The callback decides whether to hide or closeNow after async cleanup.
  /// Native WM_CLOSE is delegated only after this explicit handshake succeeds.
  Future<void> setCloseGuard(Future<void> Function()? guard) async {
    await start();
    if (!supported || _disposed || !_state.enabled) return;
    final previous = _closeGuard;
    _closeGuard = guard;
    try {
      await _channel.invokeMethod<void>('enableCloseGuard', {
        'enabled': guard != null,
      });
    } on MissingPluginException {
      _closeGuard = previous;
    } on PlatformException {
      _closeGuard = previous;
    }
  }

  Future<void> hide() => _command('hide');
  Future<void> show() => _command('show');
  Future<void> closeNow() => _command('closeNow');
  Future<void> minimize() => _command('minimize');
  Future<void> toggleMaximize() => _command('toggleMaximize');
  Future<void> close() => _command('close');
  Future<void> beginDrag() => _command('beginDrag');
  Future<void> showSystemMenu() => _command('showSystemMenu');

  Future<void> _disableGuard() async {
    try {
      await _channel.invokeMethod<void>('enableCloseGuard', {'enabled': false});
    } on Object {
      // Engine teardown may already have removed the messenger.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (supported && _starting != null) {
      if (_closeGuard != null) unawaited(_disableGuard());
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
