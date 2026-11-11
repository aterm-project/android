import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ssh_background_keepalive_platform_stub.dart'
    if (dart.library.io) 'ssh_background_keepalive_platform_io.dart'
    as platform;

/// Why an SSH session currently needs the process to stay alive.
enum SshKeepaliveKind {
  /// A connection attempt (socket, handshake, authentication, shell) is open.
  connecting,

  /// An authenticated SSH transport owned by a session is open.
  connected,

  /// A dropped session is waiting for, or running, its automatic retry.
  reconnecting,
}

/// Notification strings. Only counts are ever shown: no host, user, key,
/// credential or Vault detail crosses the channel.
class SshKeepaliveText {
  const SshKeepaliveText({
    this.channelName = 'SSH sessions',
    this.title = 'Atermius SSH sessions',
    this.connectedOne = '1 SSH connection open',
    this.connectedMany = '{count} SSH connections open',
    this.pendingSuffix = ' · connecting…',
    this.pendingOnly = 'Connecting SSH…',
    this.disconnectLabel = 'Disconnect all',
  });

  final String channelName;
  final String title;
  final String connectedOne;

  /// `{count}` is replaced with the number of open SSH connections.
  final String connectedMany;
  final String pendingSuffix;
  final String pendingOnly;
  final String disconnectLabel;

  static const maxLength = 160;

  static String _clip(String value) {
    final single = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return single.length <= maxLength ? single : single.substring(0, maxLength);
  }

  String body({required int connected, required int pending}) {
    if (connected <= 0) return pendingOnly;
    final base = connected == 1
        ? connectedOne
        : connectedMany.replaceAll('{count}', '$connected');
    return pending > 0 ? '$base$pendingSuffix' : base;
  }

  Map<String, String> toArguments({
    required int connected,
    required int pending,
  }) => {
    'channelName': _clip(channelName),
    'title': _clip(title),
    'body': _clip(body(connected: connected, pending: pending)),
    'disconnectLabel': _clip(disconnectLabel),
  };
}

/// Latest known state of the native session keepalive.
@immutable
class SshKeepaliveStatus {
  const SshKeepaliveStatus({
    required this.holds,
    this.active = false,
    this.starting = false,
    this.notifications = false,
    this.reason,
  });

  static const idle = SshKeepaliveStatus(holds: 0);

  /// Live session holds in this isolate.
  final int holds;

  /// The Android foreground service is running. This lowers the chance that
  /// Android freezes or kills the process; it never guarantees it.
  final bool active;

  /// A start was requested and has not been acknowledged yet.
  final bool starting;

  /// The ongoing notification (with Disconnect all) can be shown.
  final bool notifications;

  /// Why the service is not active (`waiting_visible`, `denied`,
  /// `start_timeout`, `user_disconnect`, `task_removed`, `timeout`,
  /// `service_destroyed`, `unavailable`), or null.
  final String? reason;

  SshKeepaliveStatus copyWith({
    int? holds,
    bool? active,
    bool? starting,
    bool? notifications,
    String? reason,
    bool clearReason = false,
  }) => SshKeepaliveStatus(
    holds: holds ?? this.holds,
    active: active ?? this.active,
    starting: starting ?? this.starting,
    notifications: notifications ?? this.notifications,
    reason: clearReason ? null : reason ?? this.reason,
  );

  @override
  bool operator ==(Object other) =>
      other is SshKeepaliveStatus &&
      other.holds == holds &&
      other.active == active &&
      other.starting == starting &&
      other.notifications == notifications &&
      other.reason == reason;

  @override
  int get hashCode =>
      Object.hash(holds, active, starting, notifications, reason);
}

/// One session's claim on background execution. Release is idempotent; a
/// released hold can never be revived (no ABA through a stale handle).
class SshKeepaliveHold {
  SshKeepaliveHold._(this._registry, this._kind, this._onUserDisconnect);

  final SshBackgroundKeepalive _registry;
  SshKeepaliveKind _kind;
  void Function()? _onUserDisconnect;
  bool _released = false;

  SshKeepaliveKind get kind => _kind;
  bool get released => _released;

  /// Changes what this hold represents (for example connecting → connected)
  /// and who is told when the user chooses Disconnect all.
  void update(SshKeepaliveKind kind, {void Function()? onUserDisconnect}) {
    if (_released) return;
    _onUserDisconnect = onUserDisconnect;
    if (_kind == kind) return;
    _kind = kind;
    _registry._changed();
  }

  void release() {
    if (_released) return;
    _released = true;
    _onUserDisconnect = null;
    _registry._remove(this);
  }
}

/// Process-wide registry of SSH session holds, mirrored to the Android
/// `atermius/ssh_keepalive` foreground service.
///
/// Ownership is session/connection lifetime: SSH transports (while
/// connecting and while open) and pending automatic recoveries take holds;
/// focus, panes, keyboards and app visibility never do. When the last hold is
/// released the service stops after a short hand-off window, so a dropped
/// transport can pass its claim to its recovery without the service stopping
/// (Android forbids restarting it while the app is hidden).
///
/// Only counts and display strings cross the channel; nothing is persisted
/// and the native side never reconnects or restarts after process death.
class SshBackgroundKeepalive {
  SshBackgroundKeepalive({
    this.channel = const MethodChannel('atermius/ssh_keepalive'),
    bool? enabled,
    this.handoffGrace = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 10),
    this.text = const SshKeepaliveText(),
  }) : enabled = enabled ?? platform.needsSshBackgroundKeepalive;

  /// Shared by SSH transports and recoveries in this isolate.
  static SshBackgroundKeepalive instance = SshBackgroundKeepalive();

  final MethodChannel channel;
  final bool enabled;
  final Duration handoffGrace;
  final Duration requestTimeout;
  final SshKeepaliveText text;

  final Set<SshKeepaliveHold> _holds = <SshKeepaliveHold>{};
  final List<void Function()> _disconnectListeners = <void Function()>[];
  final ValueNotifier<SshKeepaliveStatus> _status = ValueNotifier(
    SshKeepaliveStatus.idle,
  );
  Timer? _stopTimer;
  bool _flushScheduled = false;
  bool _listening = false;
  bool _disposed = false;
  int _nativeRevision = -1;
  int _userDisconnects = 0;
  static final Object _flightKey = Object();
  // Nothing to stop until a non-zero count has been sent.
  (int, int)? _sent = (0, 0);

  ValueListenable<SshKeepaliveStatus> get status => _status;
  int get holdCount => _holds.length;

  SshKeepaliveHold hold(
    SshKeepaliveKind kind, {
    void Function()? onUserDisconnect,
  }) {
    final hold = SshKeepaliveHold._(this, kind, onUserDisconnect);
    if (_disposed) {
      hold._released = true;
      return hold;
    }
    _holds.add(hold);
    _changed();
    return hold;
  }

  /// Called (before transports are closed) when the user chooses Disconnect
  /// all from the notification, so automatic recovery can stand down.
  void Function() addUserDisconnectListener(void Function() listener) {
    _disconnectListeners.add(listener);
    var removed = false;
    return () {
      if (removed) return;
      removed = true;
      _disconnectListeners.remove(listener);
    };
  }

  /// Runs one recovery attempt. An SSH open that this attempt reaches only
  /// after the user chose Disconnect all (for example after waiting for a
  /// busy profile or a credential lookup) is refused by
  /// [disconnectedSinceFlightStarted], so Disconnect all is atomic with
  /// in-flight five-second recoveries.
  Future<T> runRecoveryFlight<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_flightKey: (this, _userDisconnects)});

  /// True inside a [runRecoveryFlight] of this registry that started before
  /// the latest Disconnect all.
  bool get disconnectedSinceFlightStarted {
    final flight = Zone.current[_flightKey];
    return flight is (SshBackgroundKeepalive, int) &&
        identical(flight.$1, this) &&
        flight.$2 != _userDisconnects;
  }

  void _remove(SshKeepaliveHold hold) {
    if (_holds.remove(hold)) _changed();
  }

  void _changed() {
    if (_disposed) return;
    _setStatus(_status.value.copyWith(holds: _holds.length));
    // Other platforms only count holds: no timers, microtasks or channel.
    if (!enabled) return;
    if (_holds.isEmpty) {
      // Hand-off window: a transport's recovery (or a reconnect) usually
      // takes its own hold within the same event-loop turn.
      _stopTimer ??= Timer(handoffGrace, () {
        _stopTimer = null;
        unawaited(_flush());
      });
      return;
    }
    _stopTimer?.cancel();
    _stopTimer = null;
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() => unawaited(_flush()));
  }

  Future<void> _flush() async {
    _flushScheduled = false;
    if (_disposed) return;
    var connected = 0;
    for (final hold in _holds) {
      if (hold.kind == SshKeepaliveKind.connected) connected++;
    }
    final total = _holds.length;
    final next = (connected, total - connected);
    if (_sent == next) return;
    _sent = next;
    if (!enabled) return;
    _listen();
    try {
      final reply = await channel
          .invokeMapMethod<String, Object?>('sync', {
            'sessions': total,
            ...text.toArguments(connected: connected, pending: next.$2),
          })
          .timeout(requestTimeout);
      if (reply != null) _applyNative(reply);
    } on Object {
      // No plugin/timeout: retry on the next hold change, never claim
      // protection that was not acknowledged.
      if (_sent == next) _sent = null;
      _setStatus(
        _status.value.copyWith(
          active: false,
          starting: false,
          reason: total == 0 ? null : 'unavailable',
          clearReason: total == 0,
        ),
      );
    }
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler(_onNativeCall);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'state':
        final arguments = call.arguments;
        if (arguments is Map) _applyNative(arguments);
      case 'disconnectAll':
        _userDisconnect();
    }
    return null;
  }

  static const _reasons = {
    'waiting_visible',
    'denied',
    'start_timeout',
    'user_disconnect',
    'task_removed',
    'timeout',
    'service_destroyed',
  };

  void _applyNative(Map<Object?, Object?> state) {
    final revision = state['revision'];
    if (revision is! int || revision < _nativeRevision) return;
    _nativeRevision = revision;
    final reason = state['reason'];
    _setStatus(
      SshKeepaliveStatus(
        holds: _holds.length,
        active: state['active'] == true,
        starting: state['starting'] == true,
        notifications: state['notifications'] == true,
        reason: reason is String && _reasons.contains(reason) ? reason : null,
      ),
    );
  }

  void _userDisconnect() {
    _userDisconnects++;
    // Recoveries stand down first so a transport closed below is not
    // treated as an interruption to retry automatically.
    for (final listener in List.of(_disconnectListeners)) {
      try {
        listener();
      } on Object {
        // One owner must not stop the others from disconnecting.
      }
    }
    for (final hold in List.of(_holds)) {
      final callback = hold._onUserDisconnect;
      if (callback == null || hold.released) continue;
      try {
        callback();
      } on Object {
        // Same as above.
      }
    }
  }

  void _setStatus(SshKeepaliveStatus value) {
    if (!_disposed) _status.value = value;
  }

  @visibleForTesting
  void dispose() {
    _disposed = true;
    _stopTimer?.cancel();
    _stopTimer = null;
    _holds.clear();
    _disconnectListeners.clear();
    if (_listening) channel.setMethodCallHandler(null);
    _listening = false;
    _status.dispose();
  }
}
