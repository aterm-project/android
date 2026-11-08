import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'mcp_listener.dart';
import 'mcp_protocol.dart';
import 'mcp_workspace.dart';

class McpAuditEntry {
  McpAuditEntry(this.tool, this.success) : at = DateTime.now();
  final String tool;
  final bool success;
  final DateTime at;
}

class McpService extends ChangeNotifier {
  static final instance = McpService();
  McpWorkspace? _workspace;
  McpListener? _listener;
  McpProtocol? _protocol;
  String? _scope, _token;
  int _generation = 0;
  bool _starting = false;
  bool _disposed = false;
  bool _operations = false;
  final _audit = <McpAuditEntry>[];

  bool get supported => mcpListenerSupported;
  bool get running => _listener != null;
  bool get starting => _starting;
  bool get workspaceReady => _workspace?.scope() != null;
  bool get allowOperations => _operations;
  Uri? get endpoint => _listener?.endpoint;
  List<McpAuditEntry> get audit => List.unmodifiable(_audit.reversed);

  void attach(McpWorkspace workspace) {
    if (identical(_workspace, workspace)) return;
    unawaited(stop());
    _workspace = workspace;
    _operations = false;
  }

  void detach(McpWorkspace workspace) {
    if (!identical(_workspace, workspace)) return;
    _workspace = null;
    unawaited(stop());
  }

  void workspaceChanged() {
    if (_scope != null && _scope != _workspace?.scope()) unawaited(stop());
  }

  void setAllowOperations(bool value) {
    // Changing capabilities revokes outstanding requests and their token.
    if (_operations == value) return;
    unawaited(stop());
    _operations = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }

  Future<void> start({int port = 8765}) async {
    if (_disposed) throw StateError('MCP service disposed.');
    if (_starting || running) return;
    final workspace = _workspace;
    final scope = workspace?.scope();
    if (workspace == null || scope == null) {
      throw const McpToolException(
        'locked',
        'Unlock a workspace before enabling MCP.',
      );
    }
    if (!supported) {
      throw UnsupportedError('MCP listening requires the desktop application.');
    }
    final generation = ++_generation;
    _starting = true;
    _scope = scope;
    _token = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final protocol = McpProtocol(
      workspace: workspace,
      validateAccess: () {
        if (generation != _generation ||
            !identical(_workspace, workspace) ||
            workspace.scope() != scope) {
          throw const McpToolException(
            'workspace_changed',
            'Workspace authorization expired.',
          );
        }
      },
      allowOperations: () => _operations,
      onCall: (name, success) {
        if (generation != _generation) return;
        _audit.add(McpAuditEntry(name, success));
        if (_audit.length > 50) _audit.removeAt(0);
        if (!_disposed) notifyListeners();
      },
    );
    _protocol = protocol;
    if (!_disposed) notifyListeners();
    try {
      final listener = await startMcpListener(
        port: port,
        token: _token!,
        handler: protocol.handle,
      );
      if (generation != _generation || workspace.scope() != scope) {
        protocol.close();
        await listener.close();
        return;
      }
      _listener = listener;
    } catch (_) {
      protocol.close();
      if (generation == _generation) {
        _scope = null;
        _token = null;
        _protocol = null;
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        _starting = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  String connectionConfiguration() {
    if (!running || _token == null) throw StateError('MCP is stopped.');
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'atermius': {
          'url': endpoint.toString(),
          'headers': {'Authorization': 'Bearer $_token'},
        },
      },
    });
  }

  Future<void> stop() async {
    ++_generation;
    _starting = false;
    _protocol?.close();
    _protocol = null;
    _scope = null;
    _token = null;
    _audit.clear();
    final listener = _listener;
    _listener = null;
    if (listener != null) await listener.close();
    if (!_disposed) notifyListeners();
  }
}
