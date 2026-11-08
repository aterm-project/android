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
          kind: tab.console != null
              ? 'console'
              : tab.host?.protocol.name ?? 'ssh',
          hostId: tab.console == null ? tab.host?.id : null,
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
