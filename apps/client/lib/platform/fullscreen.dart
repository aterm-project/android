import 'dart:async';

import 'package:flutter/foundation.dart';

import 'fullscreen_platform.dart' as platform;

/// Operates only on this engine's window; native placement is restored on exit.
class FullscreenController extends ChangeNotifier {
  FullscreenController({
    Future<bool> Function(bool)? apply,
    Future<bool?> Function()? read,
    Stream<bool>? changes,
    bool? supported,
  }) : _apply = apply ?? platform.applyFullscreen,
       _read = read ?? platform.readFullscreen,
       supported =
           supported ??
           (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) {
    _subscription = (changes ?? platform.fullscreenChanges).listen((value) {
      if (!_disposed && enabled != value) {
        _epoch++;
        enabled = value;
        notifyListeners();
      }
    });
    unawaited(refresh());
  }

  static FullscreenController? _instance;
  static FullscreenController get instance =>
      _instance ??= FullscreenController();
  @visibleForTesting
  static set debugInstance(FullscreenController? value) => _instance = value;
  final Future<bool> Function(bool) _apply;
  final Future<bool?> Function() _read;
  final bool supported;
  StreamSubscription<bool>? _subscription;
  bool enabled = false, busy = false, _disposed = false;
  int _epoch = 0;

  Future<void> refresh() async {
    if (_disposed || busy || !supported) return;
    final epoch = _epoch;
    try {
      final actual = await _read();
      if (!_disposed &&
          !busy &&
          epoch == _epoch &&
          actual != null &&
          actual != enabled) {
        enabled = actual;
        notifyListeners();
      }
    } on Object {
      /* An older runner keeps the normal window. */
    }
  }

  Future<bool> toggle() async {
    if (_disposed || busy || !supported) return false;
    _epoch++;
    busy = true;
    notifyListeners();
    try {
      // Browser requests must be made inside the user activation callback:
      // do not await a platform query before requestFullscreen().
      final desired = !enabled;
      final actual = await _apply(desired);
      if (!_disposed) enabled = actual;
      return actual == desired;
    } on Object {
      return false;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
