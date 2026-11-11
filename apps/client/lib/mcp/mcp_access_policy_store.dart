import 'mcp_access_policy.dart';
import 'mcp_access_policy_store_io.dart'
    if (dart.library.js_interop) 'mcp_access_policy_store_web.dart'
    as platform;

/// Device-local MCP access policy, keyed by the workspace scope (local
/// profile ID, or server instance + account + Vault). Never synced and never
/// written into Vault preferences: an external-AI grant on this computer must
/// not follow the account to another device.
abstract interface class McpAccessPolicyStore {
  /// Returns null when [scope] has never stored a policy. Throws when the
  /// store is unavailable or the stored value is unreadable so the caller can
  /// fail closed instead of silently applying a default.
  Future<McpAccessPolicy?> read(String scope);

  Future<void> write(String scope, McpAccessPolicy policy);
}

class McpAccessPolicyStoreUnavailable implements Exception {
  const McpAccessPolicyStoreUnavailable();
  @override
  String toString() => 'McpAccessPolicyStoreUnavailable';
}

/// For tests and embedded hosts. Stores the encoded form so the exact codec
/// (including the scope binding) is exercised.
class MemoryMcpAccessPolicyStore implements McpAccessPolicyStore {
  final raw = <String, String>{};
  Object? readError, writeError;

  @override
  Future<McpAccessPolicy?> read(String scope) async {
    if (readError case final error?) throw error;
    final value = raw[scope];
    return value == null ? null : McpAccessPolicy.decode(value, scope);
  }

  @override
  Future<void> write(String scope, McpAccessPolicy policy) async {
    if (writeError case final error?) throw error;
    raw[scope] = policy.encode(scope);
  }
}

McpAccessPolicyStore createMcpAccessPolicyStore() => platform.createStore();
