import '../app_controller.dart';
import 'mcp_workspace.dart';

McpWorkspace appMcpWorkspace(AppController app) => McpWorkspace(
  scope: () =>
      app.authenticated && !app.workspaceLocked && app.activeVault != null
      ? 'cloud:${app.session!.accountId}:${app.currentVaultId}'
      : null,
  describe: () => {
    'mode': 'account',
    'vault_id': app.currentVaultId,
    'hosts': app.hosts.length,
    'sessions': app.terminalTabs.length,
  },
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

// Keep a failed Shell/serial startup identifiable without exposing its
// synthetic Host id as a saved SSH host.
bool _isConsoleTab(TerminalTabSession tab) =>
    tab.console != null ||
    tab.consoleShell != null ||
    tab.consoleSerialPort != null;
