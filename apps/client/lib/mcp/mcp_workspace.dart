import 'package:xterm/xterm.dart';

import '../console/local_console.dart';
import '../domain/models.dart';
import '../ssh/ssh_service.dart';
import 'mcp_access_policy.dart';

/// Live views, never copies of credentials or decrypted Vault records.
class McpSession {
  const McpSession({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.isAlive,
    required this.focus,
    required this.close,
    required this.input,
    this.hostId,
    this.terminal,
    this.connection,
  });
  final String id, name, kind, state;
  final String? hostId;
  final bool Function() isAlive;
  final void Function() focus;
  final Future<void> Function() close;
  final void Function(String) input;
  final Terminal? terminal;
  final SshConnection? connection;

  /// The policy identity this live session is authorized under. Console
  /// (local shell/serial) sessions use [mcpLocalDeviceHostId]; a remote
  /// session without a saved host, or one claiming the reserved local
  /// identity, cannot be attributed and is denied (null).
  String? get accessHostId => kind == 'console'
      ? mcpLocalDeviceHostId
      : hostId == mcpLocalDeviceHostId
      ? null
      : hostId;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'state': state,
    if (kind != 'console' && hostId != null) 'host_id': hostId,
    'terminal_available': terminal != null,
    'ssh_exec_available': connection != null,
    'sftp_available': connection != null,
  };
}

class McpWorkspace {
  const McpWorkspace({
    required this.scope,
    required this.describe,
    required this.hosts,
    required this.sessions,
    required this.connect,
    required this.openConsole,
    this.localDeviceSupported = _localConsoleSupported,
  });

  /// Null while locked, retired, or not ready. Changes across Vault/profile switches.
  final String? Function() scope;
  final Map<String, Object?> Function() describe;
  final List<HostRecord> Function() hosts;
  final List<McpSession> Function() sessions;
  final Future<void> Function(HostRecord) connect;
  final Future<void> Function() openConsole;

  /// Whether this workspace can open local shell/serial sessions, so the
  /// local-device policy choice is meaningful to show.
  final bool Function() localDeviceSupported;
}

bool _localConsoleSupported() => localConsoleSupported;

Map<String, Object?> mcpHostMetadata(HostRecord host) => {
  'id': host.id,
  'name': host.name,
  'address': host.address,
  'port': host.port,
  'protocol': host.protocol.name,
  'username': host.username,
  if (host.groupId != null) 'group_id': host.groupId,
};

/// These messages are suitable for MCP clients; arbitrary exceptions are not.
class McpToolException implements Exception {
  const McpToolException(this.code, this.message);
  final String code, message;
}

class McpCallContext {
  McpCallContext(this._validate);
  final void Function() _validate;
  final List<void Function()> _cancellations = [];
  final List<void Function()> _guards = [];
  bool _cancelled = false;
  McpToolException? _reason;
  bool get cancelled => _cancelled;
  void check() {
    if (_cancelled) {
      throw _reason ??
          const McpToolException('cancelled', 'Request cancelled.');
    }
    _validate();
    for (final guard in _guards) {
      guard();
    }
  }

  /// Adds a per-target authorization check (for example "this host is still
  /// read-write") that every later [check], including the final one before a
  /// result is released, must pass.
  void guard(void Function() guard) {
    _guards.add(guard);
    guard();
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _cancellations.add(callback);
    }
  }

  void cancel([McpToolException? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final callback in _cancellations) {
      try {
        callback();
      } catch (_) {
        /* Continue cancelling remaining handles. */
      }
    }
    _cancellations.clear();
  }

  void finish() => _cancellations.clear();
}
