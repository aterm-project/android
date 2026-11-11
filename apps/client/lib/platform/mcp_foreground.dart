import 'dart:async';

import 'package:flutter/services.dart';

import 'mcp_foreground_platform_stub.dart'
    if (dart.library.io) 'mcp_foreground_platform_io.dart'
    as platform;

export 'mcp_foreground_platform_stub.dart'
    if (dart.library.io) 'mcp_foreground_platform_io.dart'
    show needsMcpForegroundService;

/// User-visible strings for the Android MCP notification. Callers should pass
/// localized values; the defaults keep the notification meaningful when no
/// localization is available (for example during early startup).
class McpForegroundText {
  const McpForegroundText({
    this.channelName = 'External AI (MCP)',
    this.title = 'External AI access is on',
    this.body = 'Listening on {endpoint}. Stop to revoke access.',
    this.stopLabel = 'Stop',
  });

  final String channelName;
  final String title;

  /// `{endpoint}` is replaced with `127.0.0.1:<port>`. No token is ever sent.
  final String body;
  final String stopLabel;

  static const maxLength = 160;

  Map<String, String> toArguments(int port) {
    String clip(String value) {
      final single = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
      return single.length <= maxLength
          ? single
          : single.substring(0, maxLength);
    }

    return {
      'channelName': clip(channelName),
      'title': clip(title),
      'body': clip(body.replaceAll('{endpoint}', '127.0.0.1:$port')),
      'stopLabel': clip(stopLabel),
    };
  }
}

/// Outcome of a foreground-service request.
class McpForegroundGrant {
  const McpForegroundGrant({required this.active, required this.notifications});

  static const unavailable = McpForegroundGrant(
    active: false,
    notifications: false,
  );

  /// The native foreground service is running for this lease.
  final bool active;

  /// The ongoing notification (with its Stop action) can be shown. When
  /// false the service still appears in Android's active-apps list.
  final bool notifications;
}

/// Native-to-Dart events for one lease.
sealed class McpForegroundEvent {
  const McpForegroundEvent(this.leaseId);
  final String leaseId;
}

/// The native side ended the lease (notification Stop, task removal, OS
/// timeout or service destruction). The bound MCP token must be revoked.
final class McpForegroundRevoked extends McpForegroundEvent {
  const McpForegroundRevoked(super.leaseId, this.reason);
  final String reason;
}

/// Notification visibility changed (runtime permission answered).
final class McpForegroundNotifications extends McpForegroundEvent {
  const McpForegroundNotifications(super.leaseId, this.visible);
  final bool visible;
}

/// Thin, validated wrapper for `atermius/mcp_foreground`.
///
/// Only a random lease ID, the loopback port and display strings cross the
/// channel. Tokens, hosts, sessions and policy never do.
class McpForegroundChannel {
  McpForegroundChannel({
    this.channel = const MethodChannel('atermius/mcp_foreground'),
    bool? enabled,
    this.requestTimeout = const Duration(seconds: 12),
  }) : enabled = enabled ?? platform.needsMcpForegroundService;

  final MethodChannel channel;
  final bool enabled;
  final Duration requestTimeout;
  final _events = StreamController<McpForegroundEvent>.broadcast(sync: true);
  bool _listening = false;

  static final _leasePattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
  static const reasons = {
    'user_stop',
    'task_removed',
    'timeout',
    'service_destroyed',
    'replaced',
  };

  Stream<McpForegroundEvent> get events {
    _listen();
    return _events.stream;
  }

  void _listen() {
    if (_listening || !enabled) return;
    _listening = true;
    channel.setMethodCallHandler(_onNativeCall);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final id = arguments['leaseId'];
    if (id is! String || !_leasePattern.hasMatch(id)) return null;
    switch (call.method) {
      case 'revoked':
        final reason = arguments['reason'];
        _events.add(
          McpForegroundRevoked(
            id,
            reason is String && reasons.contains(reason) ? reason : 'unknown',
          ),
        );
      case 'notifications':
        _events.add(
          McpForegroundNotifications(id, arguments['visible'] == true),
        );
    }
    return null;
  }

  Future<McpForegroundGrant> start({
    required String leaseId,
    required int port,
    McpForegroundText text = const McpForegroundText(),
  }) async {
    if (!enabled) return McpForegroundGrant.unavailable;
    if (!_leasePattern.hasMatch(leaseId)) {
      throw ArgumentError.value(leaseId, 'leaseId');
    }
    if (port < 1 || port > 65535) throw RangeError.range(port, 1, 65535);
    _listen();
    final reply = await channel
        .invokeMapMethod<String, Object?>('start', {
          'leaseId': leaseId,
          'port': port,
          ...text.toArguments(port),
        })
        .timeout(requestTimeout);
    return McpForegroundGrant(
      active: reply?['active'] == true,
      notifications: reply?['notifications'] == true,
    );
  }

  Future<void> stop(String leaseId) async {
    if (!enabled || !_leasePattern.hasMatch(leaseId)) return;
    await channel
        .invokeMethod<void>('stop', {'leaseId': leaseId})
        .timeout(requestTimeout);
  }

  void dispose() {
    if (_listening) channel.setMethodCallHandler(null);
    _listening = false;
    unawaited(_events.close());
  }
}
