import '../app_controller.dart';
import 'mcp_workspace.dart';

McpWorkspace appMcpWorkspace(AppController app) => McpWorkspace(
  scope: () => _cloudScope(app),
  // Host/session counters are computed by the tool runner from the
  // policy-filtered lists so denied machines are never counted.
  describe: () => {'mode': 'account', 'vault_id': app.currentVaultId},
  hosts: () => List.of(app.hosts),
  sessions: () => app.terminalTabs
      .map(
        (tab) => McpSession(
          id: tab.id,
          name: tab.host?.name ?? 'Console',
          kind: _isConsoleTab(tab)
              ? 'console'
              : tab.host?.protocol.name ?? 'ssh',
          hostId: _isConsoleTab(tab) ? null : tab.host?.id,
          state: tab.state,
          isAlive: () => !tab.closed && app.terminalTabs.contains(tab),
          terminal: tab.desktop == null ? tab.terminal : null,
          connection: tab.connection,
          input: (text) => app.sendTerminalInputFor(tab.id, text),
          focus: () {
            app.activateTerminalTab(tab.id);
            app.showWorkspacePage(WorkspacePage.terminal);
          },
          close: () => app.closeTerminalTab(tab.id),
        ),
      )
      .toList(),
  connect: app.openTerminalTab,
  openConsole: app.openConsoleTab,
);

/// Identifies the authorization (and stored MCP policy) scope: the pinned
/// server instance and space, the account and the Vault. Null while locked or
/// before the server identity is known, which denies all MCP access.
String? _cloudScope(AppController app) {
  final instance = app.instance;
  final session = app.session;
  if (!app.authenticated ||
      app.workspaceLocked ||
      app.activeVault == null ||
      instance == null ||
      session == null ||
      instance.instanceId.isEmpty ||
      instance.serverSpaceId.isEmpty) {
    return null;
  }
  return 'cloud:${instance.instanceId}:${instance.serverSpaceId}:'
      '${session.accountId}:${app.currentVaultId}';
}

// Keep a failed Shell/serial startup identifiable without exposing its
// synthetic Host id as a saved SSH host.
bool _isConsoleTab(TerminalTabSession tab) =>
    tab.console != null ||
    tab.consoleShell != null ||
    tab.consoleSerialPort != null;
