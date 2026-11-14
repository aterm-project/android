import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/fullscreen.dart';
import '../storage/keyboard_capture_store.dart';
import 'keyboard_capture_keymaps.dart';

/// When OS-reserved shortcuts (Windows key, Alt+Tab, Command+Tab, ...) are
/// sent to the remote computer instead of the local system. Persisted by name.
enum KeyboardCaptureMode { off, fullscreen, focused }

enum KeyboardCapturePermission { granted, required, notRequired }

/// Platforms whose runner implements "atermius/keyboard_capture". Linux and
/// web never capture (no channel), so their settings hide the option.
bool keyboardCaptureAvailable([TargetPlatform? platform]) =>
    !kIsWeb &&
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.android ||
      TargetPlatform.iOS => true,
      _ => false,
    };

/// Windows/macOS arm only while the pointer is over the focused desktop;
/// Android/iOS while Atermius is the front (first) window instead.
bool _pointerRule(TargetPlatform platform) =>
    platform == TargetPlatform.windows || platform == TargetPlatform.macOS;

typedef KeyboardCaptureSend = void Function(int keysym, bool down);

/// One remote-desktop view that can receive captured keys.
class KeyboardCaptureTarget {
  KeyboardCaptureTarget._(this._owner, this._send, this._menu);
  final KeyboardCaptureController _owner;
  KeyboardCaptureSend _send;
  final VoidCallback? _menu;
  bool _focused = false, _hovered = false, _enabled = true;
  bool _registered = true;

  bool get focused => _focused;
  bool get hovered => _hovered;

  /// False while the session cannot take input (connecting, disconnected).
  bool get enabled => _enabled;
  bool get armed => identical(_owner._armed, this);

  /// Ctrl and Alt are down locally, whether Flutter or the capture hook saw
  /// them (used for the Ctrl+Alt+End = Ctrl+Alt+Delete convention).
  bool get controlAndAltHeld => _owner._controlAndAltHeld(this);

  void update({bool? focused, bool? hovered, bool? enabled}) {
    if (!_registered) return;
    _focused = focused ?? _focused;
    _hovered = hovered ?? _hovered;
    _enabled = enabled ?? _enabled;
    _owner._update();
  }

  /// Releases captured keys on the previous receiver, then sends to [send].
  void retarget(KeyboardCaptureSend send) {
    if (!_registered) return;
    _owner._releaseHeld(this);
    _send = send;
  }

  void unregister() {
    if (!_registered) return;
    _registered = false;
    _owner._unregister(this);
  }
}

class _HeldKey {
  const _HeldKey(this.target, this.keysym);
  final KeyboardCaptureTarget target;

  /// 0 when the key was consumed locally (Ctrl+Alt+Home opens the menu).
  final int keysym;
}

const _delete = 0xffff, _end = 0xff57, _home = 0xff50;
const _shiftKeys = {0xffe1, 0xffe2};
const _controlKeys = {0xffe3, 0xffe4};
const _altKeys = {0xffe9, 0xffea};

/// "modifiers" of a captured press (Windows): Shift, Control and Alt the OS
/// had down before it. Those keys reach Dart through Flutter, which may still
/// hold them back behind an earlier key event.
const _shiftBit = 1, _controlBit = 2, _altBit = 4;

/// How long a captured press waits for Flutter to deliver the modifiers
/// pressed before it (they may never come, e.g. when they were pressed while
/// another window was active).
const _modifierWait = Duration(milliseconds: 500);

/// Arms the native shortcut capture for the focused remote desktop and turns
/// keys swallowed by the runner into X11 keysyms. Key contents only travel in
/// memory to the remote session; nothing is logged or stored.
class KeyboardCaptureController extends ChangeNotifier {
  KeyboardCaptureController({
    MethodChannel channel = const MethodChannel('atermius/keyboard_capture'),
    // Public channel injection keeps native bridge tests isolated.
    // ignore: prefer_initializing_formals
  }) : _channel = channel;

  static KeyboardCaptureController? _instance;
  static KeyboardCaptureController get instance =>
      _instance ??= KeyboardCaptureController();
  @visibleForTesting
  static set debugInstance(KeyboardCaptureController? value) =>
      _instance = value;

  final MethodChannel _channel;
  KeyboardCaptureMode mode = KeyboardCaptureMode.focused;
  bool writeFailed = false;

  /// Null until the runner answered; false without a native bridge.
  bool? supported;
  KeyboardCapturePermission permission = KeyboardCapturePermission.notRequired;

  /// Android/iOS focus-rule input; true until the runner reports otherwise.
  bool nativeWindowFocused = true;

  KeyboardCaptureStore? _store;
  Future<void> _writes = Future.value();

  /// Bumped by [select] so a slower [reload] never overrides a newer choice.
  int _selections = 0;
  bool _disposed = false, _attached = false, _channelMissing = false;
  bool _sentArmed = false;
  final _targets = <KeyboardCaptureTarget>[];
  KeyboardCaptureTarget? _armed;
  FullscreenController? _fullscreen;

  /// Keys pressed through the capture path, by native code (+ extended bit).
  final _held = <int, _HeldKey>{};

  /// Captured events held back until Flutter delivers the modifiers pressed
  /// before them, oldest first, so the remote gets Alt before Tab.
  final _waiting = <Map<Object?, Object?>>[];
  Timer? _waitTimer;

  /// Whether a remote desktop currently receives captured shortcuts.
  bool get armed => _armed != null;

  Future<void> load(KeyboardCaptureStore store) async {
    _store = store;
    String? value;
    try {
      value = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      /* A missing/unreadable preference keeps the focused default. */
    }
    if (_disposed) return;
    mode = KeyboardCaptureMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => KeyboardCaptureMode.focused,
    );
    notifyListeners();
    _attach();
    _update();
    unawaited(refreshState());
  }

  /// Re-reads the preference another process may have changed. Detached
  /// remote-desktop windows (separate processes on Windows and macOS) have
  /// no settings of their own: they follow the choice made in the main
  /// window whenever their window is focused again.
  Future<void> reload() async {
    final store = _store;
    if (store == null || _disposed) return;
    final selections = _selections;
    String? value;
    try {
      // This process's own pending writes land first and are never undone.
      await _writes;
      value = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      return; // An unreadable preference keeps the current mode.
    }
    if (_disposed || selections != _selections) return;
    final next = KeyboardCaptureMode.values
        .where((mode) => mode.name == value)
        .firstOrNull;
    if (next == null || next == mode) return;
    mode = next;
    notifyListeners();
    _update();
  }

  Future<void> select(KeyboardCaptureMode value) {
    _selections++;
    mode = value;
    notifyListeners();
    _update();
    final store = _store;
    if (store == null || _disposed) return Future<void>.value();
    return _writes = _writes.then((_) async {
      if (_disposed) return;
      try {
        await store.write(value.name);
        writeFailed = false;
      } on Object {
        writeFailed = true;
      }
      if (!_disposed) notifyListeners();
    });
  }

  /// Reads support, permission and (Android/iOS) window focus from the runner.
  Future<void> refreshState() => _invoke('getState');

  /// macOS asks for Accessibility access; other runners report notRequired.
  Future<void> requestPermission() => _invoke('requestPermission');

  KeyboardCaptureTarget register(
    KeyboardCaptureSend send, {
    VoidCallback? onMenuShortcut,
  }) {
    final target = KeyboardCaptureTarget._(this, send, onMenuShortcut);
    if (_disposed) {
      target._registered = false;
      return target;
    }
    _attach();
    if (_targets.isEmpty && keyboardCaptureAvailable()) {
      _fullscreen = FullscreenController.instance..addListener(_update);
    }
    _targets.add(target);
    return target;
  }

  void _unregister(KeyboardCaptureTarget target) {
    _releaseHeld(target);
    _targets.remove(target);
    if (_targets.isEmpty) {
      _fullscreen?.removeListener(_update);
      _fullscreen = null;
    }
    _update();
  }

  void _attach() {
    if (_attached || _disposed || !keyboardCaptureAvailable()) return;
    _attached = true;
    _channel.setMethodCallHandler(_handle);
  }

  KeyboardCaptureTarget? _eligible() {
    if (_disposed ||
        _targets.isEmpty ||
        mode == KeyboardCaptureMode.off ||
        !keyboardCaptureAvailable()) {
      return null;
    }
    if (mode == KeyboardCaptureMode.fullscreen &&
        !(_fullscreen ?? FullscreenController.instance).enabled) {
      return null;
    }
    final pointer = _pointerRule(defaultTargetPlatform);
    for (final target in _targets.reversed) {
      if (target._enabled &&
          target._focused &&
          (pointer ? target._hovered : nativeWindowFocused)) {
        return target;
      }
    }
    return null;
  }

  void _update() {
    if (_disposed) return;
    final next = _eligible();
    final previous = _armed;
    if (!identical(previous, next)) {
      // Presses waiting for their modifiers belong to the previous target.
      _flushWaiting(force: true);
      _armed = next;
      // Keys pressed through the capture path never stay down remotely.
      if (previous != null) _releaseHeld(previous);
    }
    final armed = next != null;
    if (armed != _sentArmed) {
      _sentArmed = armed;
      unawaited(_invoke('configure', {'armed': armed}));
    }
  }

  void _releaseHeld(KeyboardCaptureTarget target) {
    final codes = [
      for (final entry in _held.entries)
        if (identical(entry.value.target, target)) entry.key,
    ];
    for (final code in codes) {
      final held = _held.remove(code)!;
      if (held.keysym != 0) target._send(held.keysym, false);
    }
  }

  bool _controlAndAltHeld(KeyboardCaptureTarget target) =>
      (HardwareKeyboard.instance.isControlPressed ||
          _holds(target, _controlKeys)) &&
      (HardwareKeyboard.instance.isAltPressed || _holds(target, _altKeys));

  /// Whether one of [keysyms] is down through the capture path on [target].
  bool _holds(KeyboardCaptureTarget target, Set<int> keysyms) =>
      _held.values.any(
        (held) =>
            identical(held.target, target) && keysyms.contains(held.keysym),
      );

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (_disposed || _channelMissing || !keyboardCaptureAvailable()) return;
    try {
      _accept(await _channel.invokeMethod<Object?>(method, arguments));
    } on MissingPluginException {
      // An older runner (or a test host) without the native bridge.
      _channelMissing = true;
      _setSupported(false);
    } on PlatformException {
      _setSupported(false);
    }
  }

  void _setSupported(bool value) {
    if (_disposed || supported == value) return;
    supported = value;
    notifyListeners();
  }

  void _accept(Object? value) {
    if (_disposed || value is! Map) return;
    var changed = false;
    final supported = value['supported'];
    if (supported is bool && supported != this.supported) {
      this.supported = supported;
      changed = true;
    }
    final permission = switch (value['permission']) {
      'granted' => KeyboardCapturePermission.granted,
      'required' => KeyboardCapturePermission.required,
      'notRequired' => KeyboardCapturePermission.notRequired,
      _ => null,
    };
    if (permission != null && permission != this.permission) {
      this.permission = permission;
      changed = true;
    }
    final focused = value['windowFocused'];
    if (focused is bool) _windowFocus(focused);
    if (changed) notifyListeners();
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_disposed) return null;
    final arguments = call.arguments;
    switch (call.method) {
      case 'windowFocus':
        if (arguments is Map && arguments['focused'] is bool) {
          final focused = arguments['focused'] as bool;
          _windowFocus(focused);
          if (focused) unawaited(reload());
        }
      case 'key':
        if (arguments is Map) _receive(arguments);
    }
    return null;
  }

  void _receive(Map<Object?, Object?> event) {
    if (_waiting.isEmpty && !_awaitsModifiers(event)) {
      _key(event);
      return;
    }
    _waiting.add(event);
    if (_waitTimer == null) {
      _waitTimer = Timer(_modifierWait, () => _flushWaiting(force: true));
      HardwareKeyboard.instance.addHandler(_flutterKey);
    }
  }

  /// A captured press whose modifiers Flutter has not delivered yet. Modifiers
  /// held through the capture path itself count as delivered.
  bool _awaitsModifiers(Map<Object?, Object?> event) {
    final modifiers = event['modifiers'];
    final target = _armed;
    if (event['down'] != true ||
        modifiers is! int ||
        modifiers == 0 ||
        target == null) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    bool missing(int bit, bool pressed, Set<int> keysyms) =>
        modifiers & bit != 0 && !pressed && !_holds(target, keysyms);
    return missing(_shiftBit, keys.isShiftPressed, _shiftKeys) ||
        missing(_controlBit, keys.isControlPressed, _controlKeys) ||
        missing(_altBit, keys.isAltPressed, _altKeys);
  }

  /// Flutter key events run before the focused view sends them; check the
  /// waiting events once that is done.
  bool _flutterKey(KeyEvent event) {
    scheduleMicrotask(_flushWaiting);
    return false;
  }

  /// Delivers waiting events in order, up to the first one that still waits
  /// for its modifiers; [force] delivers them all.
  void _flushWaiting({bool force = false}) {
    while (_waiting.isNotEmpty) {
      if (_disposed) return;
      if (!force && _awaitsModifiers(_waiting.first)) return;
      _key(_waiting.removeAt(0));
    }
    _stopWaiting();
  }

  void _stopWaiting() {
    _waiting.clear();
    final timer = _waitTimer;
    if (timer == null) return;
    _waitTimer = null;
    timer.cancel();
    HardwareKeyboard.instance.removeHandler(_flutterKey);
  }

  void _windowFocus(bool focused) {
    if (nativeWindowFocused == focused) return;
    nativeWindowFocused = focused;
    _update();
  }

  void _key(Map<Object?, Object?> event) {
    final platform = event['platform'], down = event['down'];
    final code = event['code'];
    if (platform is! String ||
        down is! bool ||
        code is! int ||
        code < 0 ||
        code > 0xffff) {
      return;
    }
    // Main and keypad Enter share VK_RETURN; the extended flag tells them apart.
    final id = code | (event['extended'] == true ? 0x10000 : 0);
    final held = _held[id];
    if (!down) {
      if (held != null) {
        _held.remove(id);
        if (held.keysym != 0) held.target._send(held.keysym, false);
        return;
      }
      // A down that reached Flutter before arming: still release remotely.
      final keysym = _keysym(platform, code, event);
      if (keysym != null) _armed?._send(keysym, false);
      return;
    }
    final target = _armed;
    if (target == null) return; // Raced with disarming: drop the press.
    if (held != null) {
      // Auto-repeat keeps the keysym of the original press. A repeated
      // Ctrl+Alt+End must not send Ctrl+Alt+Delete again.
      if (held.keysym != 0 &&
          held.keysym != _delete &&
          identical(held.target, target)) {
        target._send(held.keysym, true);
      }
      return;
    }
    final keysym = _keysym(platform, code, event);
    if (keysym == null) return;
    if ((keysym == _end || keysym == _home) && _controlAndAltHeld(target)) {
      if (keysym == _end) {
        // Ctrl+Alt+Delete cannot be captured on Windows: Ctrl+Alt+End sends
        // Delete while Ctrl+Alt stay held remotely (mstsc convention).
        _held[id] = _HeldKey(target, _delete);
        target._send(_delete, true);
        return;
      }
      final menu = target._menu;
      if (menu != null) {
        // Ctrl+Alt+Home stays local and opens the session menu.
        _releaseHeld(target);
        _held[id] = _HeldKey(target, 0);
        menu();
        return;
      }
    }
    _held[id] = _HeldKey(target, keysym);
    target._send(keysym, true);
  }

  int? _keysym(String platform, int code, Map<Object?, Object?> event) {
    final char = event['char'], scan = event['scan'];
    return keyboardCaptureKeysym(
      platform: platform,
      code: code,
      char: char is String && char.length <= 8 ? char : '',
      extended: event['extended'] == true,
      scan: scan is int ? scan : 0,
    );
  }

  @override
  void dispose() {
    _stopWaiting();
    for (final target in List.of(_targets)) {
      _releaseHeld(target);
      target._registered = false;
    }
    _targets.clear();
    _armed = null;
    _fullscreen?.removeListener(_update);
    _fullscreen = null;
    if (_sentArmed) {
      _sentArmed = false;
      unawaited(_invoke('configure', {'armed': false}));
    }
    _disposed = true;
    if (_attached) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
