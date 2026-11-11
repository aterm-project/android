import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../platform/mcp_foreground.dart';
import 'mcp_service.dart';

/// The part of the MCP service the platform lifecycle needs. Kept minimal so
/// the lifecycle never sees tokens, policy or workspace data.
abstract interface class McpLifecycleTarget implements Listenable {
  bool get running;
  Uri? get endpoint;

  /// Stops listening and revokes the current token.
  Future<void> stop();
}

class McpServiceLifecycleTarget implements McpLifecycleTarget {
  McpServiceLifecycleTarget(this.service);
  final McpService service;

  @override
  bool get running => service.running;
  @override
  Uri? get endpoint => service.endpoint;
  @override
  Future<void> stop() => service.stop();
  @override
  void addListener(VoidCallback listener) => service.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      service.removeListener(listener);
}

enum McpBackgroundMode {
  /// MCP is not listening.
  inactive,

  /// Listening; waiting for the foreground service to confirm.
  starting,

  /// Listening and kept reachable in the background by an Android foreground
  /// service whose ongoing notification (with a Stop action that revokes the
  /// token) Android reports as displayable.
  protected,

  /// Listening only while the app is visible; leaving the app revokes. Used
  /// when no foreground service runs, and also when one runs but its
  /// notification cannot be shown (permission denied, app or channel
  /// notifications blocked): background access must always stay visible and
  /// stoppable.
  foregroundOnly,
}

/// Binds the MCP listener lifetime to Android's process lifecycle.
///
/// * Listener starts (explicit user action, app visible) -> foreground
///   service lease with an ongoing notification and Stop action.
/// * Listener stops for any reason -> lease released, notification removed.
/// * Notification Stop / task removal / service death -> token revoked.
/// * No foreground service (denied, failed, timed out) or no displayable
///   notification -> foreground-only: the token is revoked as soon as the app
///   is hidden, because background access must stay visible and stoppable and
///   a frozen process would otherwise hold a valid token.
/// * Notifications disabled while protected -> foreground-only when the app
///   is visible, immediate revocation when it is in the background.
/// * Notifications become displayable while the app is visible and the
///   service runs -> protected again.
/// * Flutter engine detaching -> token revoked.
class McpListenerLifecycle extends ChangeNotifier with WidgetsBindingObserver {
  McpListenerLifecycle({
    required this.target,
    McpForegroundChannel? channel,
    McpForegroundText Function()? text,
    WidgetsBinding? binding,
    String Function()? newLeaseId,
  }) : channel = channel ?? McpForegroundChannel(),
       _text = text ?? (() => const McpForegroundText()),
       _binding = binding ?? WidgetsBinding.instance,
       _newLeaseId = newLeaseId ?? (() => const Uuid().v4()) {
    _appState = _binding.lifecycleState;
    _binding.addObserver(this);
    _events = this.channel.events.listen(_onEvent);
    target.addListener(_targetChanged);
    _targetChanged();
  }

  static McpListenerLifecycle? _installed;

  /// Lifecycle bound to [McpService.instance], or null when the platform
  /// needs none (desktop/Web) or it has not been installed.
  static McpListenerLifecycle? get installed => _installed;

  /// Production entry point (see SERVICE_HOOKS.patch). Idempotent; a no-op
  /// on platforms without an Android foreground-service requirement.
  static McpListenerLifecycle? install(
    McpService service, {
    McpForegroundText Function()? text,
  }) {
    if (!needsMcpForegroundService) return null;
    return _installed ??= McpListenerLifecycle(
      target: McpServiceLifecycleTarget(service),
      text: text,
    );
  }

  final McpLifecycleTarget target;
  final McpForegroundChannel channel;
  final McpForegroundText Function() _text;
  final WidgetsBinding _binding;
  final String Function() _newLeaseId;
  late final StreamSubscription<McpForegroundEvent> _events;
  AppLifecycleState? _appState;
  String? _lease;
  int? _leasePort;
  bool _disposed = false;

  McpBackgroundMode _mode = McpBackgroundMode.inactive;
  bool _notificationsVisible = false;
  bool _serviceActive = false;
  String? _lastRevocation;

  McpBackgroundMode get mode => _mode;

  /// Whether Android reported the ongoing notification as displayable.
  bool get notificationsVisible => _notificationsVisible;

  /// Whether the native foreground service holds the current lease. It may be
  /// active in [McpBackgroundMode.foregroundOnly] while notifications are
  /// hidden, so that granting them can restore protection without a restart.
  bool get serviceActive => _serviceActive;

  /// Why the platform last revoked access (`user_stop`, `task_removed`,
  /// `timeout`, `service_destroyed`, `replaced`, `background_unprotected`,
  /// `notifications_hidden`, `detached`, `unknown`), or null. Cleared on the next start.
  String? get lastRevocation => _lastRevocation;

  bool get _inBackground =>
      _appState == AppLifecycleState.hidden ||
      _appState == AppLifecycleState.paused ||
      _appState == AppLifecycleState.detached;

  void _set(McpBackgroundMode mode, {bool? notifications, bool? service}) {
    _mode = mode;
    if (service != null) _serviceActive = service;
    if (notifications != null) _notificationsVisible = notifications;
    if (!_disposed) notifyListeners();
  }

  void _targetChanged() {
    if (_disposed) return;
    final port = target.running ? target.endpoint?.port : null;
    if (port != null) {
      if (_lease != null && _leasePort == port) return;
      if (_lease != null) _release();
      _acquire(port);
    } else if (_lease != null) {
      _release();
    }
  }

  void _acquire(int port) {
    final id = _newLeaseId();
    _lease = id;
    _leasePort = port;
    _lastRevocation = null;
    _set(McpBackgroundMode.starting, notifications: false, service: false);
    unawaited(_requestGrant(id, port));
  }

  Future<void> _requestGrant(String id, int port) async {
    var grant = McpForegroundGrant.unavailable;
    try {
      grant = await channel.start(leaseId: id, port: port, text: _text());
    } on Object {
      grant = McpForegroundGrant.unavailable;
    }
    if (_disposed || _lease != id) {
      // Stopped (or restarted) while the native side was starting: make sure
      // a late-started service for this stale lease is torn down.
      if (grant.active) unawaited(_stopNative(id));
      return;
    }
    if (!grant.active) {
      // A timed-out request may still start natively later; release it.
      unawaited(_stopNative(id));
      _set(
        McpBackgroundMode.foregroundOnly,
        notifications: false,
        service: false,
      );
      if (_inBackground) await _revoke('background_unprotected');
      return;
    }
    // The service runs, but without a displayable notification background
    // access would be invisible and unstoppable from the shade: keep the
    // lease (so a later grant can restore protection) but stay foreground-only.
    _set(
      grant.notifications
          ? McpBackgroundMode.protected
          : McpBackgroundMode.foregroundOnly,
      notifications: grant.notifications,
      service: true,
    );
    if (!grant.notifications && _inBackground) {
      await _revoke('background_unprotected');
    }
  }

  void _release() {
    final id = _lease;
    _lease = null;
    _leasePort = null;
    _set(McpBackgroundMode.inactive, notifications: false, service: false);
    if (id != null) unawaited(_stopNative(id));
  }

  Future<void> _stopNative(String id) async {
    try {
      await channel.stop(id);
    } on Object {
      // Engine teardown releases any remaining native lease.
    }
  }

  Future<void> _revoke(String reason, {bool native = true}) async {
    final id = _lease;
    _lease = null;
    _leasePort = null;
    _lastRevocation = reason;
    _set(McpBackgroundMode.inactive, notifications: false, service: false);
    if (native && id != null) unawaited(_stopNative(id));
    // Stop even without a lease: a running listener must never outlive the
    // reason for revocation.
    if (target.running) await target.stop();
  }

  void _onEvent(McpForegroundEvent event) {
    if (_disposed || event.leaseId != _lease) return;
    switch (event) {
      case McpForegroundRevoked(:final reason):
        unawaited(_revoke(reason, native: false));
      case McpForegroundNotifications(:final visible):
        _notificationsChanged(visible);
    }
  }

  void _notificationsChanged(bool visible) {
    // While starting, the grant reply carries the authoritative value; the
    // native side only reports changes for an acknowledged lease.
    if (!_serviceActive || _mode == McpBackgroundMode.starting) return;
    if (!visible) {
      if (_mode != McpBackgroundMode.protected) {
        _set(_mode, notifications: false);
      } else if (_inBackground) {
        // Notification blocked while nobody can see the app: the user has no
        // visible way left to stop access, so revoke now.
        unawaited(_revoke('notifications_hidden'));
      } else {
        _set(McpBackgroundMode.foregroundOnly, notifications: false);
      }
      return;
    }
    // Only restore protection while the app is visible; a foreground-only
    // listener in the background has already been revoked.
    if (_mode == McpBackgroundMode.foregroundOnly && !_inBackground) {
      _set(McpBackgroundMode.protected, notifications: true);
    } else {
      _set(_mode, notifications: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
    if (_disposed || !target.running) return;
    if (state == AppLifecycleState.detached) {
      unawaited(_revoke('detached'));
    } else if (_inBackground && _mode == McpBackgroundMode.foregroundOnly) {
      unawaited(_revoke('background_unprotected'));
    }
    // `starting` is resolved in _requestGrant once the native answer arrives.
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _binding.removeObserver(this);
    target.removeListener(_targetChanged);
    unawaited(_events.cancel());
    final id = _lease;
    _lease = null;
    if (id != null) unawaited(_stopNative(id));
    if (identical(_installed, this)) _installed = null;
    super.dispose();
  }
}
