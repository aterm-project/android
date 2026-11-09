import 'mcp_access_policy.dart';
import 'mcp_access_policy_store.dart';

/// Browsers cannot host the MCP listener; there is nothing to authorize, and
/// any attempt to read or change policy fails closed.
class UnavailableMcpAccessPolicyStore implements McpAccessPolicyStore {
  @override
  Future<McpAccessPolicy?> read(String scope) =>
      Future.error(const McpAccessPolicyStoreUnavailable());

  @override
  Future<void> write(String scope, McpAccessPolicy policy) =>
      Future.error(const McpAccessPolicyStoreUnavailable());
}

McpAccessPolicyStore createStore() => UnavailableMcpAccessPolicyStore();
