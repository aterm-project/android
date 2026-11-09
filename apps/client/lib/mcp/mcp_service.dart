import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import 'mcp_access_policy.dart';
import 'mcp_access_policy_store.dart';
import 'mcp_listener.dart';
import 'mcp_protocol.dart';
import 'mcp_workspace.dart';

export 'mcp_access_policy.dart' show McpAccessMode, mcpLocalDeviceHostId;

class McpAuditEntry {
  McpAuditEntry(this.tool, this.success) : at = DateTime.now();
  final String tool;
  final bool success;
  final DateTime at;
}

/// Thrown by permission setters (and by [McpService.start]) when the policy
/// for the current workspace is not loaded or could not be read.
class McpPermissionsUnavailable implements Exception {
  const McpPermissionsUnavailable();
  @override
  String toString() => 'McpPermissionsUnavailable';
}

class McpService extends ChangeNotifier {
  McpService({McpAccessPolicyStore? policyStore})
    : _store = policyStore ?? createMcpAccessPolicyStore();

  static final instance = McpService();

  /// Policy identity for hostless local shell/serial sessions.
  static const localDeviceHostId = mcpLocalDeviceHostId;

  final McpAccessPolicyStore _store;
  McpWorkspace? _workspace;
  McpListener? _listener;
  McpProtocol? _protocol;
  String? _scope, _token;
  int _generation = 0;
  bool _starting = false;
  bool _disposed = false;
  final _audit = <McpAuditEntry>[];

  // Access policy. Everything below belongs to [_policyScope]; a different
  // live workspace scope means "not loaded" and therefore denied.
  String? _policyScope;
  int _policyEpoch = 0;
  bool _policyLoading = false;
  bool _policyError = false;
  McpAccessPolicy? _committed; // last value read from / written to the store
  McpAccessPolicy? _requested; // latest user intent (what settings show)
  final _pending = <McpAccessPolicy>[]; // intents not yet persisted
  McpAccessPolicy? _floor; // restrictions whose save failed
  McpAccessPolicy? _enforced; // meet(committed, pending..., floor)
  Future<void> _storeChain = Future.value();

  bool get supported => mcpListenerSupported;
  bool get running => _listener != null;
  bool get starting => _starting;
  bool get workspaceReady => _workspace?.scope() != null;
  Uri? get endpoint => _listener?.endpoint;
  List<McpAuditEntry> get audit => List.unmodifiable(_audit.reversed);

  // ---------------------------------------------------------------------
  // Per-machine access policy.

  String? get _liveScope => _workspace?.scope();

  /// Starts (re)loading the policy when the live scope differs from the
  /// loaded one. Never notifies synchronously, so it is safe from getters
  /// used during build.
  void _syncScope() {
    if (_disposed) return;
    final scope = _liveScope;
    if (scope == _policyScope) return;
    _policyEpoch++;
    _policyScope = scope;
    _policyError = false;
    _committed = _requested = _floor = _enforced = null;
    _pending.clear();
    _policyLoading = scope != null;
    _protocol?.revalidate();
    if (scope != null) unawaited(_load(scope, _policyEpoch));
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _storeChain.then((_) => operation());
    _storeChain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _load(String scope, int epoch) => _enqueue(() async {
    McpAccessPolicy? policy;
    try {
      policy = await _store.read(scope) ?? McpAccessPolicy();
    } catch (_) {
      policy = null;
    }
    if (_disposed || epoch != _policyEpoch) return;
    _policyLoading = false;
    _policyError = policy == null;
    _committed = _requested = policy;
    _recompute();
    notifyListeners();
  });

  void _recompute() {
    final committed = _committed;
    if (committed == null) {
      _enforced = null;
      return;
    }
    var policy = committed;
    for (final pending in _pending) {
      policy = McpAccessPolicy.meet(policy, pending);
    }
    if (_floor case final floor?) policy = McpAccessPolicy.meet(policy, floor);
    _enforced = policy;
  }

  /// The enforced policy if it belongs to the live scope, otherwise null.
  McpAccessPolicy? get _current {
    _syncScope();
    return _policyScope != null && _policyScope == _liveScope
        ? _enforced
        : null;
  }

  McpAccessPolicy? get _shown {
    _syncScope();
    return _policyScope != null && _policyScope == _liveScope
        ? _requested
        : null;
  }

  bool get permissionsLoading {
    _syncScope();
    return _policyLoading;
  }

  bool get permissionsReady => _current != null;

  /// The current scope's stored policy could not be read (or the platform
  /// has no store). Every machine is denied until [reloadPermissions]
  /// succeeds.
  bool get permissionsError {
    _syncScope();
    return _policyError;
  }

  /// True while a change is being persisted. Restrictions are already
  /// enforced; grants take effect once saved.
  bool get permissionsSaving => _pending.isNotEmpty;

  /// Default for machines without an explicit choice (as last chosen in
  /// settings). [McpAccessMode.denied] whenever the policy is unavailable.
  McpAccessMode get defaultAccess =>
      _shown?.defaultAccess ?? McpAccessMode.denied;

  /// Explicit choice for [hostId], or null when it inherits [defaultAccess].
  McpAccessMode? accessOverrideForHost(String hostId) =>
      _shown?.overrides[hostId];

  /// Access actually enforced for [hostId] right now.
  McpAccessMode effectiveAccessForHost(String hostId) =>
      _current?.effective(hostId) ?? McpAccessMode.denied;

  /// Saved machines of the live workspace that can be configured. Empty
  /// while locked or before the policy is loaded.
  List<HostRecord> get permissionHosts {
    if (_current == null) return const [];
    return _workspace!
        .hosts()
        .where((h) => h.id != mcpLocalDeviceHostId)
        .toList(growable: false);
  }

  /// Whether to offer the local-device (local shell/serial) choice.
  bool get localDeviceAccessApplicable =>
      _workspace?.localDeviceSupported() ?? false;

  Future<void> setDefaultAccess(McpAccessMode mode) =>
      _update((policy) => policy.withDefault(mode));

  /// A null [mode] removes the override so [hostId] inherits the default.
  Future<void> setHostAccess(String hostId, McpAccessMode? mode) {
    if (!mcpAccessPolicyValidHostId(hostId)) {
      return Future.error(ArgumentError.value(hostId, 'hostId'));
    }
    return _update((policy) => policy.withHost(hostId, mode));
  }

  /// Retries reading the current scope's policy after an error.
  Future<void> reloadPermissions() {
    if (_disposed) return Future.value();
    _policyScope = null;
    _syncScope();
    return _storeChain;
  }

  Future<void> _update(McpAccessPolicy Function(McpAccessPolicy) change) async {
    if (_disposed) throw StateError('MCP service disposed.');
    _syncScope();
    final scope = _policyScope;
    final epoch = _policyEpoch;
    final base = _requested;
    if (scope == null || base == null || _policyError) {
      throw const McpPermissionsUnavailable();
    }
    final next = change(base);
    if (next == base) return;
    final before = _enforced!;
    _requested = next;
    _pending.add(next);
    _recompute();
    if (before.reducedBy(_enforced!)) _protocol?.revalidate();
    notifyListeners();
    try {
      // Keyed by the captured scope, so a lock or switch while queued still
      // records the user's choice for that scope only, never another one.
      await _enqueue(() => _store.write(scope, next));
    } catch (_) {
      if (!_disposed && epoch == _policyEpoch) {
        _pending.removeWhere((p) => identical(p, next));
        final floor = _floor;
        _floor = floor == null ? next : McpAccessPolicy.meet(floor, next);
        _recompute();
        notifyListeners();
      }
      rethrow;
    }
    if (_disposed || epoch != _policyEpoch) return;
    _pending.removeWhere((p) => identical(p, next));
    _committed = next;
    // Every later intent was derived from this one, so earlier failed
    // restrictions are either included or deliberately undone by the user.
    _floor = null;
    _recompute();
    notifyListeners();
  }

  /// Compatibility alias for the former global switch: true when the
  /// default for unconfigured machines is read-write. Per-machine overrides
  /// (including denied) always take precedence.
  bool get allowOperations => defaultAccess == McpAccessMode.readWrite;

  /// Compatibility alias: sets [defaultAccess] to read-write or read-only.
  /// Never widens a machine with an explicit override.
  void setAllowOperations(bool value) => unawaited(
    setDefaultAccess(value ? McpAccessMode.readWrite : McpAccessMode.readOnly)
        .catchError((Object _) {}),
  );

  McpAccessMode _resolve(
    String? hostKey,
    int generation,
    McpWorkspace workspace,
    String scope,
  ) {
    if (_disposed ||
        generation != _generation ||
        !identical(_workspace, workspace) ||
        workspace.scope() != scope ||
        _policyScope != scope) {
      return McpAccessMode.denied;
    }
    return _enforced?.effective(hostKey) ?? McpAccessMode.denied;
  }

  // ---------------------------------------------------------------------
  // Lifecycle.

  void attach(McpWorkspace workspace) {
    if (identical(_workspace, workspace)) return;
    unawaited(stop());
    _workspace = workspace;
    _syncScope();
  }

  void detach(McpWorkspace workspace) {
    if (!identical(_workspace, workspace)) return;
    _workspace = null;
    unawaited(stop());
    _syncScope();
  }

  void workspaceChanged() {
    if (_scope != null && _scope != _workspace?.scope()) unawaited(stop());
    final previous = _policyScope;
    _syncScope();
    if (previous != _policyScope && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _policyEpoch++;
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
    if (!_disposed) notifyListeners();
    McpProtocol? protocol;
    try {
      _syncScope();
      await _storeChain;
      if (generation != _generation) return;
      if (workspace.scope() != scope) {
        throw const McpToolException(
          'workspace_changed',
          'Workspace authorization expired.',
        );
      }
      if (_policyScope != scope || _enforced == null) {
        throw const McpPermissionsUnavailable();
      }
      _token = base64UrlEncode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      ).replaceAll('=', '');
      protocol = McpProtocol(
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
        access: (hostKey) => _resolve(hostKey, generation, workspace, scope),
        onCall: (name, success) {
          if (generation != _generation) return;
          _audit.add(McpAuditEntry(name, success));
          if (_audit.length > 50) _audit.removeAt(0);
          if (!_disposed) notifyListeners();
        },
      );
      _protocol = protocol;
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
      protocol?.close();
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
