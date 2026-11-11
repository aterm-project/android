import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/ssh_background_keepalive.dart';

/// One retry flight per live owner. A retry never replays terminal input.
class SessionRecovery extends ChangeNotifier {
  SessionRecovery({
    required this.reconnect,
    required this.isCurrent,
    this.automatic = false,
    bool keepSshAlive = false,
    @visibleForTesting SshBackgroundKeepalive? sshKeepalive,
    this.keepaliveLimit = const Duration(minutes: 5),
  }) : _keepalive = keepSshAlive
           ? _enabledOrNull(sshKeepalive ?? SshBackgroundKeepalive.instance)
           : null {
    // Notification "Disconnect all" must not be undone by a five-second
    // automatic retry of the transport it closed.
    _removeDisconnectListener = _keepalive?.addUserDisconnectListener(
      blockAutomatic,
    );
  }
  // Off Android there is nothing to keep alive: no hold, limit timer or
  // Disconnect all listener.
  static SshBackgroundKeepalive? _enabledOrNull(SshBackgroundKeepalive value) =>
      value.enabled ? value : null;

  final Future<void> Function() reconnect;
  final bool Function() isCurrent;
  final bool automatic;

  /// Longest time one interruption keeps the SSH background keepalive while
  /// automatic retries continue. Retries are not stopped by this limit.
  final Duration keepaliveLimit;
  final SshBackgroundKeepalive? _keepalive;
  void Function()? _removeDisconnectListener;
  SshKeepaliveHold? _hold;
  Timer? _holdLimit;
  bool _holdExpired = false;
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
      _holdExpired = false;
    } else if (!connecting) {
      interrupted = true;
      _schedule();
    }
    _syncKeepalive();
    notifyListeners();
  }

  void blockAutomatic() {
    _automaticBlocked = true;
    _timer?.cancel();
    _timer = null;
    _syncKeepalive();
    if (!_disposed) notifyListeners();
  }

  /// Holds the SSH keepalive only while an automatic retry is genuinely
  /// pending or running for a still-current owner, and at most
  /// [keepaliveLimit] per interruption.
  void _syncKeepalive() {
    final keepalive = _keepalive;
    final wanted =
        keepalive != null &&
        !_disposed &&
        !_holdExpired &&
        interrupted &&
        automaticEnabled &&
        (_timer != null || busy) &&
        isCurrent();
    if (wanted) {
      _hold ??= keepalive.hold(SshKeepaliveKind.reconnecting);
      _holdLimit ??= Timer(keepaliveLimit, () {
        _holdLimit = null;
        _holdExpired = true;
        _syncKeepalive();
      });
      return;
    }
    _hold?.release();
    _hold = null;
    _holdLimit?.cancel();
    _holdLimit = null;
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
    _syncKeepalive();
    notifyListeners();
    try {
      final keepalive = _keepalive;
      await (keepalive == null
          ? reconnect()
          : keepalive.runRecoveryFlight(reconnect));
    } on Object {
      // Owners publish a sanitized connection state; never surface secrets.
    } finally {
      busy = false;
      if (!_disposed) {
        if (interrupted) _schedule();
        _syncKeepalive();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _syncKeepalive();
    _removeDisconnectListener?.call();
    _removeDisconnectListener = null;
    super.dispose();
  }
}
