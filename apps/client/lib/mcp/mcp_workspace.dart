import 'package:xterm/xterm.dart';

import '../domain/models.dart';
import '../ssh/ssh_service.dart';

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

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'state': state,
    if (hostId != null) 'host_id': hostId,
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
  });

  /// Null while locked, retired, or not ready. Changes across Vault/profile switches.
  final String? Function() scope;
  final Map<String, Object?> Function() describe;
  final List<HostRecord> Function() hosts;
  final List<McpSession> Function() sessions;
  final Future<void> Function(HostRecord) connect;
  final Future<void> Function() openConsole;
}

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
  bool _cancelled = false;
  void check() {
    if (_cancelled) {
      throw const McpToolException('cancelled', 'Request cancelled.');
    }
    _validate();
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _cancellations.add(callback);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
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
