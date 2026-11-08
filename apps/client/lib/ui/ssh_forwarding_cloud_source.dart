import 'package:flutter/foundation.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'ssh_forwarding_page.dart';

/// Cloud (Vault) adapter for [SshForwardingPage].
///
/// Rules persist through [AppController.saveHostPortForwardProfiles] (the
/// existing encrypted Host save path with its revision checks); runtimes are
/// the forwarding managers of connected SSH terminal tabs; new connections go
/// through [AppController.openTerminalTab], i.e. the normal credential,
/// Jump Host and known-host approval flow.
class CloudSshForwardingSource implements SshForwardingSource {
  CloudSshForwardingSource(this.app, {this.onShowSession});

  final AppController app;

  /// Shows a terminal tab in the shell; defaults to activating the tab.
  final void Function(String tabId)? onShowSession;

  @override
  /// Repository lifetime identity: changes on every Vault switch, lock,
  /// sign-out or rebuild, so an A -> B -> A switch never matches again.
  Object? get scopeKey => app.recordWriteScope;

  @override
  List<HostRecord> get hosts =>
      app.recordWriteScope == null || app.activeVault == null
      ? const []
      : app.hosts;

  @override
  List<SshForwardingSessionInfo> get sessions {
    final result = <SshForwardingSessionInfo>[];
    final perHost = <String, int>{};
    for (final tab in app.terminalTabs) {
      final host = tab.host;
      if (tab.closed ||
          host == null ||
          host.protocol != HostProtocol.ssh ||
          tab.desktop != null ||
          tab.console != null) {
        continue;
      }
      final index = perHost[host.id] = (perHost[host.id] ?? 0) + 1;
      final phase = switch (tab.state) {
        'connected' => SshForwardingSessionPhase.connected,
        'connecting' => SshForwardingSessionPhase.connecting,
        'failed' => SshForwardingSessionPhase.failed,
        _ => SshForwardingSessionPhase.disconnected,
      };
      result.add(
        SshForwardingSessionInfo(
          id: tab.id,
          hostId: host.id,
          label: currentL10n.r7ForwardSessionLabel(host.name, index),
          phase: phase,
          manager: phase == SshForwardingSessionPhase.connected
              ? tab.connection?.portForwards
              : null,
        ),
      );
    }
    return result;
  }

  @override
  bool get canEdit => app.activeVault?.canWrite == true;

  @override
  String? get readOnlyReason => currentL10n.youHaveReadOnlyAccessTo;

  @override
  String get storageDescription =>
      currentL10n.profilesAreEncryptedInsideThisHost;

  @override
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) {
    if (scope == null) {
      throw StateError(currentL10n.theVaultChangedReopenPortForwarding);
    }
    return app.updateHostPortForwardRuleInScope(
      hostId: hostId,
      expected: expected,
      replacement: replacement,
      scope: scope,
    );
  }

  @override
  String describeSaveError(Object error) =>
      currentL10n.couldNotSaveForwardingSettingsSync;

  @override
  Future<String?> connect(HostRecord host) async {
    String? opened;
    await app.openTerminalTab(host, onTabOpened: (id) => opened = id);
    final id = opened;
    if (id == null) return null;
    for (final tab in app.terminalTabs) {
      if (tab.id == id &&
          !tab.closed &&
          tab.state == 'connected' &&
          tab.connection != null &&
          tab.host?.id == host.id) {
        return id;
      }
    }
    return null;
  }

  @override
  void showSession(String sessionId) {
    final show = onShowSession;
    if (show != null) {
      show(sessionId);
    } else {
      app.activateTerminalTab(sessionId);
    }
  }

  @override
  void addListener(VoidCallback listener) => app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => app.removeListener(listener);
}
