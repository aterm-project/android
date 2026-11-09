import 'dart:async';

import 'package:flutter/foundation.dart';

/// One retry flight per live owner. A retry never replays terminal input.
class SessionRecovery extends ChangeNotifier {
  SessionRecovery({
    required this.reconnect,
    required this.isCurrent,
    this.automatic = false,
  });
  final Future<void> Function() reconnect;
  final bool Function() isCurrent;
  final bool automatic;
  Timer? _timer;
  bool _disposed = false, _everConnected = false, _automaticBlocked = false;
  bool interrupted = false, busy = false;
  bool get available => !_disposed && isCurrent();
  bool get automaticEnabled =>
      automatic && _everConnected && !_automaticBlocked;

  void update({required bool connected, bool connecting = false}) {
    if (_disposed) return;
    if (connected) {
      _everConnected = true;
      _automaticBlocked = false;
      interrupted = false;
      _timer?.cancel();
      _timer = null;
    } else if (!connecting) {
      interrupted = true;
      _schedule();
    }
    notifyListeners();
  }

  void blockAutomatic() {
    _automaticBlocked = true;
    _timer?.cancel();
    _timer = null;
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    if (_disposed ||
        busy ||
        !automatic ||
        !_everConnected ||
        _automaticBlocked ||
        _timer != null ||
        !available)
      return;
    _timer = Timer(const Duration(seconds: 5), () {
      _timer = null;
      unawaited(retry(manual: false));
    });
  }

  Future<void> retry({bool manual = true}) async {
    if (!available || busy || !interrupted) return;
    _timer?.cancel();
    _timer = null;
    if (manual) _automaticBlocked = false;
    busy = true;
    notifyListeners();
    try {
      await reconnect();
    } on Object {
      // Owners publish a sanitized connection state; never surface secrets.
    } finally {
      busy = false;
      if (!_disposed) {
        if (interrupted) _schedule();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
