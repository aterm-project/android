import 'cloud_access/organizations_page.dart' show CloudAccessAccountCard;
import 'cloud_access/share_host_dialog.dart' show showCloudShareDialog;
import '../cloud/cloud_access_service.dart' show CloudAccessService;
import 'app_menu.dart';
import '../desktop/desktop_keyboard_mode.dart';
import '../platform/file_window_tracking.dart';
import '../desktop/window/desktop_window.dart';
import '../domain/window_combination.dart';
import 'app_density.dart';
import '../telnet/telnet_ui.dart';
import 'app_motion.dart';
import 'window_combinations.dart';
import '../terminal/terminal_tools.dart';
import 'terminal_tools_sidebar.dart';
import '../mcp/app_mcp_workspace.dart';
import '../mcp/mcp_service.dart';
import '../mcp/mcp_workspace.dart';
import 'mcp_settings_panel.dart';
import 'settings_scaffold.dart';
import '../console/local_console.dart';
import 'local_shell_menu.dart';
import 'home_add_sharing_row.dart';
import '../desktop/desktop_view.dart';
import '../desktop/window/desktop_tab_windows.dart';
import 'host_file_session.dart';
import 'host_system_icon.dart';
import 'file_workspace_tabs.dart';
import 'group_session_layout.dart';
import 'remote_file_workspace.dart';
import '../platform/files_window_launch.dart';
import '../storage/secure_store.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../app_controller.dart';
import '../api/api_client.dart';
import '../attachments/attachment_file_saver.dart';
import '../archive/portable_vault_archive.dart';
import '../crypto/vault_crypto.dart';
import '../domain/conflict_feed.dart';
import '../domain/device_redaction_capability.dart';
import '../domain/ansible_inventory_metadata.dart';
import '../domain/credential_conflict_merge.dart';
import '../domain/host_security_conflict_merge.dart';
import '../domain/known_host.dart';
import '../domain/models.dart';
import '../domain/quick_connect.dart';
import 'host_search_field.dart';
import 'host_search_palette.dart';
import 'host_card_layout.dart';
import 'terminal_palette.dart';
import 'terminal_palette_picker.dart';
import 'terminal_shortcut_editor.dart';
import '../domain/sftp_entries.dart';
import '../domain/snippet_invocation.dart';
import '../domain/vault_preference.dart';
import '../domain/workspace_layout.dart';
import 'openssh_config_import_dialog.dart';
import 'termius_transfer_dialog.dart';
import '../import/termius_local_app_import.dart';
import '../import/termius_transfer_target.dart';
import '../import/termius_keychain_bridge.dart';
import 'ansible_inventory_import_dialog.dart';
import '../terminal/terminal_search.dart';
import '../terminal/terminal_shortcuts.dart';
import '../ssh/ssh_service.dart';
import '../ssh/host_operating_system_probe.dart';
import '../ssh/host_operating_system_persistence.dart';
import '../sftp/sftp_text_editor_service.dart';
import '../sync/sync_repository.dart';
import '../sync/sync_diagnostics_export.dart';
import 'app_theme.dart';
import 'ssh_forwarding_cloud_source.dart';
import 'ssh_forwarding_page.dart';
import 'ssh_port_forwarding_dialog.dart';
import 'account_mfa_panel.dart';
import 'browser_storage_status_card.dart';
import 'host_attachments_dialog.dart';
import 'host_editor_panel.dart';
import 'home_sidebar.dart' show HomeSidebarAction;
import 'keychain_page.dart';
import 'session_logs_page.dart';
import 'terminal_keybar.dart';
import 'workspace_mode_settings.dart';
import 'workspace_tab_bar.dart';
import 'session_workspace.dart';
import 'workspace_controls.dart';
import 'workspace_status_bar.dart';
import 'session_recovery_overlay.dart';
import 'connect_progress_view.dart';
import 'transfer_dialog.dart';
import '../platform/application_windows.dart';
import 'new_window.dart';
import 'sftp_text_editor_dialog.dart';
import '../web_update/web_app_update_factory.dart';
import '../web_update/web_app_update_monitor.dart';
import '../l10n/l10n.dart';
import 'app_language_settings.dart';
import 'account_settings.dart';
import 'app_theme_mode.dart';
import 'wallpaper.dart';
import 'wallpaper_settings.dart';

const _uuid = Uuid();
const _syncDiagnosticsClientVersion =
    '${String.fromEnvironment('FLUTTER_BUILD_NAME', defaultValue: '0.1.0')}'
    '+${String.fromEnvironment('FLUTTER_BUILD_NUMBER', defaultValue: '1')}';

// AppController records the sync status and a user-facing error before it
// rethrows foreground failures. Button callbacks cannot propagate that Future
// to a caller, so contain it here after the controller has updated the UI.
Future<void> _runSyncFromUi(AppController app) async {
  try {
    await app.synchronize();
  } catch (_) {
    // The sync status and SnackBar already surface the failure.
  }
}

Future<void> _refreshDevicesFromUi(AppController app) async {
  try {
    await app.refreshDevices();
  } catch (_) {
    // AppController has already reported the refresh error to the UI.
  }
}

Future<void> _refreshVaultReadinessFromUi(AppController app) async {
  try {
    await app.refreshVaultDeviceRows(recoverCurrentDevice: true);
  } catch (_) {
    // AppController retains a safe, user-facing refresh error for the panel.
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.controller,
    this.filesLaunch,
    this.onOpenLocalMigration,
    this.webAppUpdateMonitor,
    this.enableWebCommandSuggestionsForTesting = false,
    super.key,
  });

  final AppController controller;
  final FilesWindowLaunch? filesLaunch;
  final Future<void> Function(BuildContext context)? onOpenLocalMigration;
  final WebAppUpdateMonitor? webAppUpdateMonitor;
  @visibleForTesting
  final bool enableWebCommandSuggestionsForTesting;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// R7-INTEGRATION(forwarding): after the forwarding branch merges, root
  /// changes this to `=> _buildSshForwardingPage;` (state-owned controller and
  /// source survive leaving the page). Null hides the destination.
  Widget Function()? get _forwardingPageBuilder => _buildSshForwardingPage;

  Future<void> _importOpenSshConfig(
    BuildContext context,
    AppController app,
  ) async {
    final imported = await showOpenSshConfigImportDialog(context, app: app);
    if (mounted && imported != null && context.mounted) {
      _snack(context, currentL10n.importedImportedHostSRecordsAre(imported));
    }
  }

  Future<void> _importAnsibleInventory(
    BuildContext context,
    AppController app,
  ) async {
    final applied = await showAnsibleInventoryImportDialog(context, app: app);
    if (mounted && applied != null && context.mounted) {
      _snack(context, currentL10n.appliedAppliedInventoryChangeSHost(applied));
    }
  }

  /// Home sidebar Import / Export menu (real existing actions + Termius hook).
  List<HomeSidebarAction> _cloudImportExportActions(
    BuildContext context,
    AppController app,
  ) {
    final writable = app.activeVault?.canWrite == true;
    return [
      HomeSidebarAction(
        id: 'cloud_import_openssh_config',
        label: context.l10n.importSshConfig,
        icon: Icons.file_open_outlined,
        onSelected: () => _importOpenSshConfig(context, app),
        enabled: writable,
      ),
      HomeSidebarAction(
        id: 'cloud_import_ansible_inventory',
        label: context.l10n.importAnsibleInventory,
        icon: Icons.inventory_2_outlined,
        onSelected: () => _importAnsibleInventory(context, app),
        enabled: writable,
      ),
      ?_cloudTermiusOneClickAction(context, app),
      ?_cloudTermiusTransferAction(context, app),
    ];
  }

  final _terminalPageKey = GlobalKey<_TerminalPageState>();
  late final McpWorkspace _mcpWorkspace;
  AppController get app => widget.controller;
  final _sessionWorkspace = SessionWorkspaceController();
  final _fileTabs = FileWorkspaceTabs();
  final _tabOrder = WorkspaceTabOrder();
  final _observedConnections = <SshConnection>{};

  /// Home "SSH Forwarding" page state (pending connect-and-start, chosen
  /// session per Host) that survives leaving the page.
  late final _sshForwardingSource = CloudSshForwardingSource(
    app,
    onShowSession: _selectWorkspaceTab,
  );
  SshForwardingController? _sshForwardingControllerOrNull;
  SshForwardingController get _sshForwardingController =>
      _sshForwardingControllerOrNull ??= SshForwardingController(
        source: _sshForwardingSource,
      );
  String? _selectedFileId;
  String? _filesScope;
  bool _launchHandled = false;
  bool _launchRunning = false;
  bool _openingGroup = false;
  int _groupGeneration = 0;
  int _scopeGeneration = 0;
  VoidCallback? _unregisterVisibleOwner;
  final _cloudDragScope = 'cloud-terminal-${_uuid.v4()}';
  WebAppUpdateMonitor? _webUpdateMonitor;
  bool _ownsWebUpdateMonitor = false;
  int? _archivedPendingCount;
  String? _archivedVaultId;
  String? _archivedOutboxFingerprint;
  DateTime? _archiveConfirmedAt;
  ({int pendingCount, String vaultId, String fingerprint})? _archiveExportStart;
  int _controllerNotificationGeneration = 0;
  int _archiveValidationGeneration = 0;

  VoidCallback? _unregisterTrackedFileProvider;
  void _onTrackedFilesChanged() {
    if (mounted) setState(() {});
  }

  FilesWindowLaunch? _trackedFileDescriptor() {
    final expected = widget.filesLaunch;
    if (expected == null ||
        _currentFilesScope == null ||
        app.api == null ||
        !expected.matchesScope(
          FilesWindowWorkspace.cloud,
          app.currentVaultId,
          serverNamespace: secureStorageNamespace(app.api!.baseUrl),
          accountId: app.currentAccountId,
        ))
      return null;
    final file =
        _fileTabs.find(_selectedFileId ?? _sessionWorkspace.selectedId ?? '') ??
        _fileTabs.entries
            .where(
              (e) =>
                  e.host.id == expected.hostId &&
                  e.controller.protocol.name == expected.protocol.name,
            )
            .firstOrNull;
    if (file == null || file.controller.isClosed) return null;
    return FilesWindowLaunch(
      workspace: FilesWindowWorkspace.cloud,
      scopeId: app.currentVaultId,
      serverNamespace: secureStorageNamespace(app.api!.baseUrl),
      accountId: app.currentAccountId,
      hostId: file.host.id,
      protocol: FilesWindowProtocol.values.byName(
        file.controller.protocol.name,
      ),
      initialPath: file.controller.path,
    );
  }

  @override
  void initState() {
    super.initState();
    _unregisterTrackedFileProvider = registerTrackedFileProvider(
      _trackedFileDescriptor,
      scopeEpoch: () => _scopeGeneration,
    );
    TrackedFilesWindows.instance.addListener(_onTrackedFilesChanged);
    _mcpWorkspace = appMcpWorkspace(app);
    McpService.instance.attach(_mcpWorkspace);
    _ownsWebUpdateMonitor = widget.webAppUpdateMonitor == null;
    _webUpdateMonitor =
        widget.webAppUpdateMonitor ??
        (kIsWeb ? createWebAppUpdateMonitor() : null);
    _webUpdateMonitor?.addListener(_onWebUpdateChanged);
    if (_webUpdateMonitor != null) unawaited(_webUpdateMonitor!.start());
    app.addListener(_onControllerChanged);
    _syncSessionWorkspace();
    _fileTabs.addListener(_onFilesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeFilesLaunch());
    _unregisterVisibleOwner = ApplicationWindows.instance.registerVisibleOwner(
      app,
      () async {
        await TrackedFilesWindows.instance.releaseOwner(app);
        await _fileTabs.closeAll();
        for (final tab in app.visibleTerminalTabs.toList()) {
          await app.closeTerminalTab(tab.id);
        }
      },
    );
    app.askTrustHost = _askTrustHost;
    app.askTrustHostApproval = _askTrustHostApproval;
    app.askSshUserInfo = _askSshUserInfo;
  }

  @override
  void dispose() {
    _unregisterTrackedFileProvider?.call();
    TrackedFilesWindows.instance.removeListener(_onTrackedFilesChanged);
    unawaited(TrackedFilesWindows.instance.releaseOwner(app));
    McpService.instance.detach(_mcpWorkspace);
    _groupGeneration++;
    app.removeListener(_onControllerChanged);
    _unregisterVisibleOwner?.call();
    _fileTabs.removeListener(_onFilesChanged);
    _fileTabs.dispose();
    _sessionWorkspace.dispose();
    _sshForwardingControllerOrNull?.dispose();
    _webUpdateMonitor?.removeListener(_onWebUpdateChanged);
    if (_ownsWebUpdateMonitor) _webUpdateMonitor?.dispose();
    if (app.askTrustHost == _askTrustHost) app.askTrustHost = null;
    if (app.askTrustHostApproval == _askTrustHostApproval) {
      app.askTrustHostApproval = null;
    }
    if (app.askSshUserInfo == _askSshUserInfo) app.askSshUserInfo = null;
    super.dispose();
  }

  void _onWebUpdateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _onArchiveExportStarting() async {
    _archiveExportStart = null;
    final vaultId = app.currentVaultId;
    if (vaultId.isEmpty) return;
    final pendingCount = app.pendingCount;
    final notificationGeneration = _controllerNotificationGeneration;
    final fingerprint = await app.database.pendingOutboxFingerprint(
      vaultId,
      instanceId: app.currentSyncInstanceId,
      serverSpaceId: app.currentSyncServerSpaceId,
    );
    if (!mounted ||
        notificationGeneration != _controllerNotificationGeneration ||
        app.currentVaultId != vaultId ||
        app.pendingCount != pendingCount) {
      return;
    }
    _archiveExportStart = (
      pendingCount: pendingCount,
      vaultId: vaultId,
      fingerprint: fingerprint,
    );
  }

  void _onArchiveExported() {
    unawaited(_recordArchiveExported());
  }

  Future<void> _recordArchiveExported() async {
    final start = _archiveExportStart;
    _archiveExportStart = null;
    if (!mounted || start == null) return;
    final currentFingerprint = await app.database.pendingOutboxFingerprint(
      start.vaultId,
      instanceId: app.currentSyncInstanceId,
      serverSpaceId: app.currentSyncServerSpaceId,
    );
    if (!mounted) return;
    final coversCurrentOutbox =
        app.currentVaultId == start.vaultId &&
        app.pendingCount == start.pendingCount &&
        currentFingerprint == start.fingerprint;
    setState(() {
      if (!coversCurrentOutbox) {
        _clearPendingOutboxArchive();
        return;
      }
      _archivedPendingCount = start.pendingCount;
      _archivedVaultId = start.vaultId;
      _archivedOutboxFingerprint = currentFingerprint;
      _archiveConfirmedAt = DateTime.now();
      _archiveValidationGeneration++;
    });
  }

  void _clearPendingOutboxArchive() {
    _archivedPendingCount = null;
    _archivedVaultId = null;
    _archivedOutboxFingerprint = null;
    _archiveConfirmedAt = null;
  }

  bool get _pendingOutboxArchiveCoversCurrentState {
    if (app.pendingCount == 0) return true;
    final confirmedAt = _archiveConfirmedAt;
    return _archivedPendingCount == app.pendingCount &&
        _archivedVaultId == app.currentVaultId &&
        _archivedOutboxFingerprint != null &&
        confirmedAt != null &&
        DateTime.now().difference(confirmedAt) <= const Duration(minutes: 20);
  }

  Future<bool> _pendingOutboxArchiveStillCoversCurrentState() async {
    final vaultId = app.currentVaultId;
    if (vaultId.isEmpty) return app.pendingCount == 0;
    final projectedPendingCount = app.pendingCount;
    final actualPendingCount = await app.refreshPendingCountForVault(vaultId);
    if (app.currentVaultId != vaultId ||
        actualPendingCount != projectedPendingCount ||
        app.pendingCount != actualPendingCount) {
      return false;
    }
    if (actualPendingCount == 0) return true;
    if (!_pendingOutboxArchiveCoversCurrentState) return false;
    final archivedFingerprint = _archivedOutboxFingerprint;
    if (archivedFingerprint == null) return false;
    final fingerprint = await app.database.pendingOutboxFingerprint(
      vaultId,
      instanceId: app.currentSyncInstanceId,
      serverSpaceId: app.currentSyncServerSpaceId,
    );
    final covered =
        _pendingOutboxArchiveCoversCurrentState &&
        app.currentVaultId == vaultId &&
        fingerprint == archivedFingerprint;
    if (!covered && mounted) {
      setState(_clearPendingOutboxArchive);
    }
    return covered;
  }

  Future<void> _refreshPendingOutboxArchiveCoverage() async {
    final archivedFingerprint = _archivedOutboxFingerprint;
    final archivedVaultId = _archivedVaultId;
    if (archivedFingerprint == null || archivedVaultId == null) return;
    final validationGeneration = ++_archiveValidationGeneration;
    if (app.currentVaultId != archivedVaultId ||
        app.pendingCount != _archivedPendingCount) {
      if (mounted && validationGeneration == _archiveValidationGeneration) {
        setState(_clearPendingOutboxArchive);
      }
      return;
    }
    final fingerprint = await app.database.pendingOutboxFingerprint(
      archivedVaultId,
      instanceId: app.currentSyncInstanceId,
      serverSpaceId: app.currentSyncServerSpaceId,
    );
    if (!mounted || validationGeneration != _archiveValidationGeneration) {
      return;
    }
    if (app.currentVaultId != archivedVaultId ||
        app.pendingCount != _archivedPendingCount ||
        fingerprint != archivedFingerprint) {
      setState(_clearPendingOutboxArchive);
    }
  }

  Future<bool> _askTrustHost(String endpoint, String fingerprint) =>
      _confirmSshHostKey(context, endpoint: endpoint, fingerprint: fingerprint);

  Future<bool> _askTrustHostApproval(KnownHostApprovalRequest request) =>
      _confirmSshHostKey(
        context,
        endpoint: request.endpoint,
        fingerprint: request.fingerprint,
        algorithm: request.algorithm,
        previouslyRevoked: request.previouslyRevoked,
        offlineTransportUnavailable: request.offlineTransportUnavailable,
      );

  Future<List<String>?> _askSshUserInfo(
    HostRecord host,
    SSHUserInfoRequest request,
    Future<void> cancelled,
  ) async {
    if (!mounted) return null;
    const maxPrompts = 8;
    const maxPromptRunes = 512;
    String safeText(String value, int maxRunes) {
      final visible = value.replaceAll(
        RegExp(
          r'[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
        ),
        ' ',
      );
      return String.fromCharCodes(visible.runes.take(maxRunes));
    }

    final promptLimitExceeded = request.prompts.length > maxPrompts;
    final safePrompts = promptLimitExceeded
        ? const <_SafeSshUserInfoPrompt>[]
        : request.prompts
              .map(
                (prompt) => _SafeSshUserInfoPrompt(
                  text: safeText(prompt.promptText, maxPromptRunes),
                  echo: prompt.echo,
                ),
              )
              .toList(growable: false);
    final safeRequestName = safeText(request.name, 512);
    final safeInstruction = safeText(request.instruction, 2048);
    // OpenSSH/PAM can send a final empty INFO_REQUEST after the last actual
    // answer. There is nothing for the user to review or enter in that packet.
    if (safePrompts.isEmpty &&
        !promptLimitExceeded &&
        safeRequestName.isEmpty &&
        safeInstruction.isEmpty) {
      return const <String>[];
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<List<String>?>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: false,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (_) => _SshUserInfoDialog(
        hostLabel: safeText('${host.name} · ${host.endpoint}', 512),
        requestName: safeRequestName,
        instruction: safeInstruction,
        prompts: safePrompts,
        promptLimitExceeded: promptLimitExceeded,
      ),
    );
    final dialogResult = navigator.push(route);
    final outcome = await Future.any<(bool, List<String>?)>([
      dialogResult.then((responses) => (false, responses)),
      cancelled.then((_) => (true, null)),
    ]);
    if (outcome.$1) {
      if (route.isActive) navigator.removeRoute(route);
      return null;
    }
    return outcome.$2;
  }

  String? get _currentFilesScope =>
      app.api == null ||
          app.currentAccountId == null ||
          app.workspaceLocked ||
          app.currentVaultId.isEmpty
      ? null
      : '${secureStorageNamespace(app.api!.baseUrl)}|${app.currentAccountId}|${app.currentVaultId}';

  bool _matchesLaunch(FilesWindowLaunch launch) =>
      !app.workspaceLocked &&
      app.api != null &&
      launch.matchesScope(
        FilesWindowWorkspace.cloud,
        app.currentVaultId,
        serverNamespace: secureStorageNamespace(app.api!.baseUrl),
        accountId: app.currentAccountId,
      );

  void _onFilesChanged() {
    if (!mounted) return;
    final hadSelectedFile = _selectedFileId != null;
    final liveIds = {
      ...app.visibleTerminalTabs.map((tab) => tab.id),
      ..._fileTabs.entries.map((entry) => entry.id),
    };
    for (final id in {
      ..._sessionWorkspace.sessionIds,
      ..._sessionWorkspace.groupedSessionIds.expand((ids) => ids),
    }.toList()) {
      if (!liveIds.contains(id)) _sessionWorkspace.remove(id);
    }
    if (_fileTabs.find(_selectedFileId ?? '') == null) {
      _selectedFileId = _fileTabs.find(_sessionWorkspace.selectedId ?? '')?.id;
      if (hadSelectedFile &&
          _selectedFileId == null &&
          _sessionWorkspace.selectedId != null) {
        app.activateTerminalTab(_sessionWorkspace.selectedId!);
      }
    }
    setState(() {});
  }

  Future<void> _consumeFilesLaunch() async {
    final launch = widget.filesLaunch;
    if (!mounted ||
        launch == null ||
        _launchHandled ||
        _launchRunning ||
        !_matchesLaunch(launch))
      return;
    _launchRunning = true;
    _launchHandled = true;
    try {
      final host = app.hosts
          .where((host) => host.id == launch.hostId)
          .firstOrNull;
      if (host == null) throw StateError(context.l10n.theHostSpecifiedByTheFile);
      await _openHostFiles(
        host,
        launch.protocol == FilesWindowProtocol.scp
            ? SshTransferProtocol.scp
            : SshTransferProtocol.sftp,
        initialPath: launch.initialPath,
      );
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    } finally {
      _launchRunning = false;
    }
  }

  Future<void> _openHostFiles(
    HostRecord host,
    SshTransferProtocol protocol, {
    String initialPath = '/',
  }) async {
    final scope = _currentFilesScope;
    if (scope == null) return;
    final tab = await resolveHostFileSession<TerminalTabSession>(
      hostId: host.id,
      sessions: () => app.terminalTabs,
      sessionId: (s) => s.id,
      sessionHostId: (s) => s.host?.id,
      isConnected: (s) =>
          !s.closed && s.state == 'connected' && s.connection != null,
      connect: () => app.openTerminalTab(host),
    );
    if (!mounted ||
        scope != _currentFilesScope ||
        tab == null ||
        tab.host?.id != host.id)
      return;
    await _openSessionFiles(
      tab.id,
      protocol: protocol,
      initialPath: initialPath,
    );
  }

  void _probeHostOperatingSystems() {
    final scope = _currentFilesScope;
    if (scope == null) return;
    _observedConnections.removeWhere(
      (connection) =>
          !app.terminalTabs.any((tab) => identical(tab.connection, connection)),
    );
    for (final tab in app.terminalTabs) {
      final connection = tab.connection;
      final host = tab.host;
      if (tab.closed ||
          tab.state != 'connected' ||
          connection == null ||
          host == null ||
          host.protocol != HostProtocol.ssh ||
          !_observedConnections.add(connection))
        continue;
      final vaultId = app.currentVaultId;
      final generation = _scopeGeneration;
      bool current() =>
          generation == _scopeGeneration &&
          mounted &&
          _currentFilesScope == scope &&
          !tab.closed &&
          tab.state == 'connected' &&
          identical(app.terminalTabFor(tab.id), tab) &&
          identical(tab.connection, connection);
      unawaited(
        () async {
          final observation = await HostOperatingSystemProbe().detect(
            connection,
          );
          if (!current()) return;
          await HostOperatingSystemPersistence.saveCloud(
            controller: app,
            connectedHost: host,
            observation: observation,
            vaultId: vaultId,
            isCurrentConnection: current,
          );
        }().catchError((Object _) {}),
      );
    }
  }

  void _syncSessionWorkspace() {
    if (_currentFilesScope != null && app.api != null)
      validateTrackedFileScope(
        FilesWindowWorkspace.cloud,
        app.currentVaultId,
        serverNamespace: secureStorageNamespace(app.api!.baseUrl),
        accountId: app.currentAccountId,
      );
    final scope = _currentFilesScope;
    if (_filesScope != scope) {
      _groupGeneration++;
      _scopeGeneration++;
      _filesScope = scope;
      unawaited(TrackedFilesWindows.instance.releaseOwner(app));
      _sessionWorkspace.restore(null);
      _selectedFileId = null;
      unawaited(_fileTabs.closeAll());
    }
    _probeHostOperatingSystems();
    _fileTabs.retainConnections({
      for (final tab in app.terminalTabs)
        if (!tab.closed && tab.state == 'connected' && tab.connection != null)
          tab.id: tab.connection!,
    });
    if (app.page != WorkspacePage.terminal) _selectedFileId = null;
    final visible = {
      ...app.visibleTerminalTabs.map((tab) => tab.id),
      ..._fileTabs.entries.map((entry) => entry.id),
    };
    for (final id in {
      ..._sessionWorkspace.sessionIds,
      ..._sessionWorkspace.groupedSessionIds.expand((ids) => ids),
    }.toList()) {
      if (!visible.contains(id)) _sessionWorkspace.remove(id);
    }
    final active = _selectedFileId ?? app.activeTerminalTabId;
    if (active != null &&
        visible.contains(active) &&
        _sessionWorkspace.selectedId != active) {
      _sessionWorkspace.activate(active);
    }
  }

  bool _openingCombination = false;
  Future<void> _saveWindowCombination() async {
    final scope = _currentFilesScope;
    final generation = _scopeGeneration;
    if (scope == null) return;
    final name = await askWindowCombinationName(context);
    if (name == null ||
        !mounted ||
        scope != _currentFilesScope ||
        generation != _scopeGeneration)
      return;
    try {
      final recipe = await captureWindowCombinationWithPlacements(
        id: const Uuid().v4(),
        name: name,
        sessionIds: [
          ...app.terminalTabs.where((t) => !t.closed).map((t) => t.id),
          ..._fileTabs.entries.map((e) => e.id),
        ],
        workspace: _sessionWorkspace,
        owner: app,
        isCurrent: () =>
            mounted &&
            scope == _currentFilesScope &&
            generation == _scopeGeneration,
        fileOwner: (id) => _fileTabs.find(id)?.sourceSessionId,
        describe: (id) {
          final file = _fileTabs.find(id);
          if (file != null)
            return CombinationPane(
              kind: file.controller.protocol.name,
              hostId: file.host.id,
              remotePath: file.controller.path,
            );
          final tab = app.terminalTabs.where((t) => t.id == id).firstOrNull;
          if (tab == null || tab.closed) return null;
          if (tab.console != null)
            return CombinationPane(
              kind: 'console',
              serialPort: tab.consoleSerialPort,
              baudRate: tab.consoleBaudRate,
              shell: tab.consoleSerialPort == null ? tab.consoleShell : null,
            );
          final host = tab.host;
          return host == null
              ? null
              : CombinationPane(kind: host.protocol.name, hostId: host.id);
        },
      );
      if (!mounted ||
          scope != _currentFilesScope ||
          generation != _scopeGeneration)
        return;
      await app.saveWindowCombinations([...app.windowCombinations, recipe]);
      if (mounted &&
          scope == _currentFilesScope &&
          generation == _scopeGeneration)
        {
_snack(
          context,
          recipe.windows.any((w) => w.placement == null)
              ? context.l10n.windowSetSavedSomeSeparateWindows
              : context.l10n.windowSetSavedEncrypted,
        );
}
    } catch (error) {
      if (mounted &&
          scope == _currentFilesScope &&
          generation == _scopeGeneration)
        _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<String?> _detachCombinationWindow(
    int index,
    CombinationWindow window,
    String id,
  ) async {
    final tab = app.terminalTabFor(id);
    if (tab == null || tab.closed) return null;
    if (tab.desktop == null) {
      await _detachSession(id);
      return ApplicationWindows.instance.isDetached(app, id) ? id : null;
    }
    final scope = _currentFilesScope, generation = _scopeGeneration;
    bool current() =>
        mounted &&
        scope != null &&
        scope == _currentFilesScope &&
        generation == _scopeGeneration &&
        app.terminalTabFor(id) == tab;
    final viewport = window.viewport;
    final windowId = viewport == null ? id : '$id#savedMonitor$index';
    final opened = await ApplicationWindows.instance.detachDesktop(
      owner: app,
      windowId: windowId,
      session: tab.desktop!,
      spec: DesktopWindowSpec(
        title: tab.host?.name ?? context.l10n.remoteDesktop,
        viewport: viewport == null
            ? null
            : Rect.fromLTWH(
                viewport['x']!.toDouble(),
                viewport['y']!.toDouble(),
                viewport['width']!.toDouble(),
                viewport['height']!.toDouble(),
              ),
      ),
      onDetached: () {
        if (current() && viewport == null) app.markTerminalDetached(id, true);
      },
      onUserClosed: () async {
        if (current() && viewport == null) await app.closeTerminalTab(id);
      },
      onRestored: () {
        if (current() && viewport == null) {
          app.markTerminalDetached(id, false);
          app.showWorkspacePage(WorkspacePage.terminal);
        }
      },
    );
    return opened ? windowId : null;
  }

  final _combinationRestorer = CombinationRestoreCoordinator();
  Future<void> _openWindowCombination(WindowCombination recipe) async {
    final scope = _currentFilesScope;
    final generation = _scopeGeneration;
    if (scope == null || _openingCombination) return;
    bool current() =>
        mounted &&
        scope == _currentFilesScope &&
        generation == _scopeGeneration;
    setState(() => _openingCombination = true);
    try {
      final latest = app.windowCombinations
          .where((value) => value.id == recipe.id).firstOrNull;
      if (latest == null || !current()) return;
      recipe = latest;
      var independentPlacementFailures = 0;
      final result = await _combinationRestorer.restore(
        recipe: recipe,
        isCurrent: current,
        independentPane: (index) =>
            recipe.windows.any((w) => w.pane == index && w.independentFile),
        openIndependent: (index, pane) async {
          final window = recipe.windows.firstWhere(
            (w) => w.pane == index && w.independentFile,
          );
          final child = await openTrackedFilesWindow(
            FilesWindowLaunch(
              workspace: FilesWindowWorkspace.cloud,
              scopeId: app.currentVaultId,
              serverNamespace: secureStorageNamespace(app.api!.baseUrl),
              accountId: app.currentAccountId,
              hostId: pane.hostId!,
              protocol: FilesWindowProtocol.values.byName(pane.kind),
              initialPath: pane.remotePath ?? '/',
            ),
            owner: app,
            placement: window.placement,
            isCurrent: current,
          );
          final ready = await child.ready.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          );
          if (!current()) {
            await child.stopTracking();
            return false;
          }
          if (window.placement != null &&
              (!ready || !await child.initialPlacementApplied))
            independentPlacementFailures++;
          return true;
        },
        canResolve: (pane) {
          if (pane.kind == 'console') return true;
          final host = app.hosts.where((h) => h.id == pane.hostId).firstOrNull;
          return host != null &&
              host.protocol.name ==
                  (pane.kind == 'sftp' || pane.kind == 'scp'
                      ? 'ssh'
                      : pane.kind);
        },
        openAttachedFile: (pane, ownerId) async {
          if (!current()) return null;
          final host = app.hosts.where((h) => h.id == pane.hostId).firstOrNull;
          if (host == null || host.protocol != HostProtocol.ssh) return null;
          final owner = app.visibleTerminalTabs
              .where(
                (t) =>
                    t.id == ownerId &&
                    t.host?.id == host.id &&
                    t.connection != null &&
                    t.state == 'connected',
              )
              .firstOrNull;
          if (owner == null ||
              owner.host?.protocol != host.protocol ||
              owner.host?.address != host.address ||
              owner.host?.port != host.port ||
              owner.host?.username != host.username ||
              owner.host?.jumpHostId != host.jumpHostId)
            return null;
          if (kIsWeb) return null;
          final beforeFiles = _fileTabs.entries.map((e) => e.id).toSet();
          await _openSessionFiles(
            owner.id,
            protocol: pane.kind == 'scp'
                ? SshTransferProtocol.scp
                : SshTransferProtocol.sftp,
            reuseExisting: false,
            initialPath: pane.remotePath ?? '/',
          );
          if (!current()) return null;
          return _fileTabs.entries
              .where(
                (e) =>
                    !beforeFiles.contains(e.id) &&
                    e.host.id == host.id &&
                    e.sourceSessionId == owner.id &&
                    e.controller.protocol.name == pane.kind,
              )
              .lastOrNull
              ?.id;
        },
        open: (pane) async {
          if (pane.kind == 'console') {
            if (!localConsoleSupported) return null;
            if (pane.serialPort == null) {
              final id = await app.openLocalShellTab(
                launch: pane.shell ?? LocalShellLaunch.systemDefault,
              );
              return app.visibleTerminalTabs
                  .where((t) => t.id == id && t.console != null)
                  .firstOrNull
                  ?.id;
            }
            final before = app.terminalTabs.map((t) => t.id).toSet();
            await app.openConsoleTab(
              serialPort: pane.serialPort,
              baudRate: pane.baudRate ?? 115200,
            );
            return app.visibleTerminalTabs
                .where((t) => !before.contains(t.id) && t.console != null)
                .firstOrNull
                ?.id;
          }
          final host = app.hosts.where((h) => h.id == pane.hostId).firstOrNull;
          if (host == null) return null;
          final before = app.terminalTabs.map((t) => t.id).toSet();
          await app.openTerminalTab(host);
          return app.visibleTerminalTabs
              .where(
                (t) =>
                    !before.contains(t.id) &&
                    t.host?.id == host.id &&
                    !t.closed &&
                    (t.state == 'connected' ||
                        (t.desktop != null && t.state != 'disconnected')),
              )
              .firstOrNull
              ?.id;
        },
      );
      if (result == null || result.stale || !current()) return;
      if (result.sessions.isNotEmpty) {
        applyWindowCombination(recipe, _sessionWorkspace, result.sessions);
        final selected = _sessionWorkspace.selectedId;
        if (selected != null) _selectWorkspaceTab(selected);
      }
      final windowFailures =
          independentPlacementFailures +
          (result.sessions.isEmpty && result.independentOpened == 0
              ? 0
              : await restoreWindowCombinationPlacements(
                  recipe: recipe,
                  sessions: result.sessions,
                  isCurrent: current,
                  detach: _detachCombinationWindow,
                  applyDetached: (id, value) => ApplicationWindows.instance
                      .applyWindowPlacement(app, id, value),
                  closeDetached: (id) =>
                      ApplicationWindows.instance.closeSession(app, id),
                ));
      if (!current()) return;
      if (windowFailures > 0 && result.failures == 0)
        {
_snack(context, currentL10n.someSeparateWindowsOrWindowPositions, error: true);
}
      if (result.failures > 0)
        {
_snack(
          context,
          currentL10n.windowSetOpenedValuevalueCountSessions(result.sessions.length + result.independentOpened, recipe.panes.length, result.failures) +
              (windowFailures > 0 ? currentL10n.windowfailuresPlural11MoreWindow(windowFailures) : ''),
          error: true,
        );
}
    } catch (error) {
      if (current()) _snack(context, app.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _openingCombination = false);
    }
  }

  Future<void> _openGroup(GroupRecord group) async {
    final scope = _currentFilesScope;
    if (scope == null || _openingGroup) return;
    final generation = ++_groupGeneration;
    setState(() => _openingGroup = true);
    GroupRecord? connectedGroup;
    bool current() =>
        mounted &&
        generation == _groupGeneration &&
        scope == _currentFilesScope &&
        identical(
          app.groups.where((candidate) => candidate.id == group.id).firstOrNull,
          connectedGroup,
        );
    final sessionsByPane = <String, String>{};
    final usedSessions = <String>{};
    try {
      final latest = app.groups
          .where((candidate) => candidate.id == group.id)
          .firstOrNull;
      if (latest == null) return;
      connectedGroup = latest;
      final groupHostIds = GroupSessionLayout.groupHosts(
        latest,
        app.groups,
        app.hosts,
      ).map((host) => host.id).toSet();
      final saved = GroupSessionLayout.read(latest);
      if (saved == null && groupHostIds.length > 32)
        {
throw FormatException(context.l10n.eachGroupLayoutCanConnectUp);
}
      final layout =
          saved ?? GroupSessionLayout.forHosts(groupHostIds.toList());
      if (layout.panes.isEmpty) throw StateError(context.l10n.thisGroupHasNoConnectableSsh);
      for (final pane in layout.panes) {
        if (!current()) break;
        final host = app.hosts
            .where(
              (host) =>
                  host.id == pane.hostId && groupHostIds.contains(host.id),
            )
            .firstOrNull;
        if (host == null) continue;
        var tab = app.visibleTerminalTabs
            .where(
              (tab) =>
                  !usedSessions.contains(tab.id) &&
                  !tab.closed &&
                  tab.host != null &&
                  matchesGroupHostConnection(tab.host!, host) &&
                  tab.state == 'connected' &&
                  tab.connection != null,
            )
            .firstOrNull;
        if (tab == null) {
          final before = app.terminalTabs.map((tab) => tab.id).toSet();
          await app.openTerminalTab(host);
          if (!current()) break;
          tab = app.visibleTerminalTabs
              .where(
                (tab) =>
                    !before.contains(tab.id) &&
                    !tab.closed &&
                    tab.host != null &&
                    matchesGroupHostConnection(tab.host!, host) &&
                    tab.state == 'connected' &&
                    tab.connection != null,
              )
              .firstOrNull;
          // A cancelled/failed handshake stops the sequence, never borrowing an
          // unrelated active tab or proceeding into another trust prompt.
          if (tab == null) break;
        }
        usedSessions.add(tab.id);
        sessionsByPane[pane.paneId] = tab.id;
      }
      if (current() && sessionsByPane.isNotEmpty) {
        layout.apply(_sessionWorkspace, sessionIdsByPane: sessionsByPane);
        final selected = _sessionWorkspace.selectedId;
        if (selected != null) app.activateTerminalTab(selected);
        _selectedFileId = null;
        app.showWorkspacePage(WorkspacePage.terminal);
      }
    } catch (error) {
      if (current())
        _snack(
          context,
          error is FormatException ? error.message : app.friendlyError(error),
          error: true,
        );
    } finally {
      if (mounted) setState(() => _openingGroup = false);
    }
  }

  Future<void> _saveGroupLayout(GroupRecord group) async {
    final scope = _currentFilesScope;
    if (scope == null) return;
    try {
      final latest = app.groups
          .where((candidate) => candidate.id == group.id)
          .firstOrNull;
      final root = _sessionWorkspace.root;
      if (latest == null || root == null)
        {
throw StateError(context.l10n.thisWindowHasNoSshLayout);
}
      final hostIds = GroupSessionLayout.groupHosts(
        latest,
        app.groups,
        app.hosts,
      ).map((host) => host.id).toSet();
      final layout = GroupSessionLayout.capture(
        root: root,
        hostIdsBySession: {
          for (final tab in app.visibleTerminalTabs)
            if (tab.host != null && hostIds.contains(tab.host!.id))
              tab.id: tab.host!.id,
        },
        selectedSessionId: _sessionWorkspace.selectedId,
      );
      if (scope != _currentFilesScope || !mounted) return;
      await app.saveGroup(
        layout.writeTo(latest),
        isCurrentContext: () =>
            mounted &&
            scope == _currentFilesScope &&
            identical(
              app.groups
                  .where((candidate) => candidate.id == latest.id)
                  .firstOrNull,
              latest,
            ),
      );
      if (mounted && scope == _currentFilesScope)
        {
_snack(context, context.l10n.theCurrentWindowLayoutForThis);
}
    } catch (error) {
      if (mounted && scope == _currentFilesScope)
        _snack(context, _groupMutationError(app, error), error: true);
    }
  }

  Future<void> _resetGroupLayout(GroupRecord group) async {
    final scope = _currentFilesScope;
    if (scope == null) return;
    final latest = app.groups
        .where((candidate) => candidate.id == group.id)
        .firstOrNull;
    if (latest == null) return;
    try {
      await app.saveGroup(
        GroupSessionLayout.clear(latest),
        isCurrentContext: () =>
            mounted &&
            scope == _currentFilesScope &&
            identical(
              app.groups
                  .where((candidate) => candidate.id == latest.id)
                  .firstOrNull,
              latest,
            ),
      );
      if (mounted && scope == _currentFilesScope) _snack(context, context.l10n.groupLayoutReset);
    } catch (error) {
      if (mounted && scope == _currentFilesScope)
        _snack(context, _groupMutationError(app, error), error: true);
    }
  }

  Future<void> _openSessionFiles(
    String id, {
    SshTransferProtocol protocol = SshTransferProtocol.sftp,
    String initialPath = '/',
    bool reuseExisting = true,
  }) async {
    if (app.workspaceLocked) return;
    final tab = app.terminalTabFor(id);
    if (tab == null ||
        tab.closed ||
        tab.state != 'connected' ||
        tab.connection == null ||
        tab.host == null ||
        tab.host!.protocol != HostProtocol.ssh)
      return;
    if (kIsWeb) {
      app.activateTerminalTab(id);
      if (protocol == SshTransferProtocol.sftp) {
        app.showWorkspacePage(WorkspacePage.sftp);
      } else {
        await _showSessionScp(context, app, id, SshTransferDirection.upload);
      }
      return;
    }
    final entry = _fileTabs.open(
      sourceSessionId: id,
      host: tab.host!,
      connection: tab.connection!,
      protocol: protocol,
      initialPath: initialPath,
      reuseExisting: reuseExisting,
    );
    if (mounted) _selectWorkspaceTab(entry.id);
  }

  /// Body of the Home sidebar "SSH Forwarding" destination (wired by the
  /// navigation branch). Starts go through [AppController.openTerminalTab].
  // ignore: unused_element (embedded by the navigation branch's Home sidebar)
  Widget _buildSshForwardingPage({String? initialHostId}) => SshForwardingPage(
    source: _sshForwardingSource,
    controller: _sshForwardingController,
    initialHostId: initialHostId,
  );

  void _selectWorkspaceTab(String id) {
    if (!mounted) return;
    final file = _fileTabs.find(id);
    setState(() => _selectedFileId = file?.id);
    if (id == 'hosts') {
      app.showWorkspacePage(WorkspacePage.hosts);
      return;
    }
    _sessionWorkspace.activate(id);
    if (file == null) app.activateTerminalTab(id);
    app.showWorkspacePage(WorkspacePage.terminal);
  }

  Future<void> _duplicateWorkspaceTab(String id) async {
    final file = _fileTabs.find(id);
    if (file != null) {
      if (file.controller.isClosed || _currentFilesScope == null) return;
      final copy = _fileTabs.open(
        sourceSessionId: file.sourceSessionId,
        host: file.host,
        connection: file.controller.connection,
        protocol: file.controller.protocol,
        initialPath: file.controller.path,
        reuseExisting: false,
      );
      _selectWorkspaceTab(copy.id);
      return;
    }
    final tab = app.terminalTabFor(id);
    if (tab == null || tab.closed) return;
    setState(() => _selectedFileId = null);
    try {
      if (tab.console != null) {
        // Serial stays serial; a shell keeps its kind and working directory.
        await app.duplicateConsoleTab(id);
      } else if (tab.host != null) {
        await app.openTerminalTab(tab.host!);
      }
      if (mounted) app.showWorkspacePage(WorkspacePage.terminal);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  void _unsplitWorkspaceTab(String id) {
    if (!_sessionWorkspace.unsplit(id)) return;
    final survivor = _sessionWorkspace.selectedId;
    if (survivor != null) _selectWorkspaceTab(survivor);
    if (mounted) setState(() {});
  }

  Future<void> _closeWorkspaceTab(String id) async {
    if (_fileTabs.find(id) != null) {
      await _fileTabs.close(id);
    } else {
      await _fileTabs.closeSource(id);
      await app.closeTerminalTab(id);
    }
  }

  Future<void> _detachFile(String id) async {
    final entry = _fileTabs.find(id);
    final scope = _currentFilesScope;
    if (entry == null || scope == null || !supportsFilesWindows) return;
    try {
      await openFilesWindow(
        FilesWindowLaunch(
          workspace: FilesWindowWorkspace.cloud,
          scopeId: app.currentVaultId,
          hostId: entry.host.id,
          serverNamespace: secureStorageNamespace(app.api!.baseUrl),
          accountId: app.currentAccountId,
          protocol: entry.controller.protocol == SshTransferProtocol.scp
              ? FilesWindowProtocol.scp
              : FilesWindowProtocol.sftp,
          initialPath: entry.controller.path,
        ),
        trackingOwner: app,
      );
      if (mounted && scope == _currentFilesScope) await _fileTabs.close(id);
    } catch (_) {
      if (mounted) _snack(context, context.l10n.couldntOpenTheFileWindow, error: true);
    }
  }

  /// [newSession]: the pane handle's direction choices always open a fresh
  /// connection (or Console copy) beside [id] instead of pairing it with an
  /// already-open tab; those are offered separately as explicit partners.
  Future<void> _splitSession(
    String id,
    Axis axis, {
    bool newSession = false,
  }) async {
    final file = _fileTabs.find(id);
    final otherFile = _fileTabs.entries
        .where((entry) => entry.id != id)
        .firstOrNull;
    if (file != null || (!newSession && otherFile != null)) {
      final target =
          _sessionWorkspace.sessionIds
              .where((value) => value != id)
              .firstOrNull ??
          otherFile?.id ??
          file?.sourceSessionId;
      final liveIds = {
        ...app.visibleTerminalTabs.map((tab) => tab.id),
        ..._fileTabs.entries.map((entry) => entry.id),
      };
      if (target == null || !liveIds.contains(id) || !liveIds.contains(target))
        return;
      _sessionWorkspace.activate(target);
      _sessionWorkspace.split(
        id,
        target,
        axis == Axis.horizontal
            ? SessionSplitEdge.right
            : SessionSplitEdge.bottom,
      );
      _selectWorkspaceTab(id);
      return;
    }
    final tab = app.terminalTabFor(id);
    if (tab == null || tab.detached) return;
    Future<void>? opening;
    try {
      var source = newSession
          ? null
          : app.visibleTerminalTabs
                .where(
                  (candidate) =>
                      candidate.id != id &&
                      (candidate.connection != null ||
                          candidate.telnet != null ||
                          candidate.desktop != null ||
                          candidate.console != null),
                )
                .firstOrNull;
      if (source == null && tab.console != null) {
        // A lone Console splits into a new independent PTY/serial session.
        final copyId = await app.duplicateConsoleTab(id);
        source = app.visibleTerminalTabs
            .where((candidate) => candidate.id == copyId)
            .firstOrNull;
      } else if (source == null && tab.host != null) {
        final previous = app.terminalTabs.map((tab) => tab.id).toSet();
        // The new tab exists before its connection settles: split now so the
        // pane shows the real progress, then report a failure afterwards.
        opening = app.openTerminalTab(tab.host!);
        TerminalTabSession? created() => app.visibleTerminalTabs
            .where((tab) => !previous.contains(tab.id))
            .firstOrNull;
        source = created();
        if (source == null) {
          final pending = opening;
          opening = null;
          await pending;
          source = created();
        }
      }
      if (!mounted || source == null || app.terminalTabFor(id) == null) {
        if (opening != null) await opening;
        return;
      }
      _sessionWorkspace.activate(id);
      _sessionWorkspace.split(
        source.id,
        id,
        axis == Axis.horizontal
            ? SessionSplitEdge.right
            : SessionSplitEdge.bottom,
      );
      app.activateTerminalTab(source.id);
      app.showWorkspacePage(WorkspacePage.terminal);
      if (opening != null) await opening;
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _detachSession(String id) async {
    final tab = app.terminalTabFor(id);
    if (tab != null && !tab.closed && tab.desktop != null) {
      final opened = await _detachCloudDesktop(app, id);
      if (!opened && mounted) {
        _snack(context, context.l10n.theNewWindowWasntReadyThe2, error: true);
      }
      return;
    }
    if (tab == null ||
        tab.closed ||
        (tab.connection == null && tab.console == null))
      return;
    final opened = await ApplicationWindows.instance.detach(
      owner: app,
      sessionId: id,
      terminal: tab.terminal,
      title: tab.host?.name ?? context.l10n.sshTerminal,
      onDetached: () => app.markTerminalDetached(id, true),
      onUserClosed: () => app.closeTerminalTab(id),
      onRestored: () {
        app.markTerminalDetached(id, false);
        if (mounted) app.showWorkspacePage(WorkspacePage.terminal);
      },
      onOpenFiles: tab.connection == null
          ? null
          : () => unawaited(_openSessionFiles(id)),
    );
    if (!opened && mounted)
      {
_snack(context, context.l10n.theNewWindowWasntReadyThe, error: true);
}
  }

  void _showSessionProperties(String id) {
    final file = _fileTabs.find(id);
    final tab = app.terminalTabFor(file?.sourceSessionId ?? id);
    final host = file?.host ?? tab?.host;
    if (host != null) {
      unawaited(
        showHostProperties(
          context,
          host,
          state: tab == null
              ? null
              : terminalStateLabel(context.l10n, tab.state),
        ),
      );
    }
  }

  bool _hostSearchOpen = false;
  Future<void> _openHostSearch() async {
    final vault = app.activeVault?.id;
    final account = app.session?.accountId;
    final api = app.api;
    bool current() =>
        mounted &&
        !app.workspaceLocked &&
        app.activeVault?.id == vault &&
        app.session?.accountId == account &&
        identical(app.api, api);
    if (vault == null || !current() || _hostSearchOpen || _quickConnectBusy)
      return;
    _hostSearchOpen = true;
    try {
      final result = await showHostSearchPalette(
        context,
        hosts: () => app.hosts,
        groups: hostSearchGroupLabels(app.groups),
        fieldKey: const ValueKey('cloud_host_search'),
        isCurrent: current,
        changes: app,
      );
      if (!current() || result == null) return;
      if (result.command case final command?) {
        await _quickConnect(command);
      } else {
        final host = app.hosts
            .where((host) => host.id == result.hostId)
            .firstOrNull;
        if (host != null) await app.openTerminalTab(host);
      }
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    } finally {
      _hostSearchOpen = false;
    }
  }

  bool _quickConnectBusy = false;
  Future<void> _quickConnect(QuickConnectRequest command) async {
    if (_quickConnectBusy) return;
    setState(() => _quickConnectBusy = true);
    try {
      await _runQuickConnect(command);
    } finally {
      if (mounted) setState(() => _quickConnectBusy = false);
    }
  }

  Future<void> _runQuickConnect(QuickConnectRequest command) async {
    try {
      if (command.isConsole) {
        await app.openConsoleTab(
          serialPort: command.kind == QuickConnectKind.serial
              ? command.address
              : null,
          baudRate: command.baudRate,
        );
        return;
      }
      final matchingVault = app.activeVault?.id,
          matchingAccount = app.session?.accountId;
      final matches = app.hosts.where(command.matches).toList();
      if (matches.isNotEmpty) {
        final host = await chooseQuickConnectHost(context, matches);
        if (host != null &&
            mounted &&
            matchingVault == app.activeVault?.id &&
            matchingAccount == app.session?.accountId)
          await app.openTerminalTab(host);
        return;
      }
      if (app.activeVault?.canWrite != true) throw StateError(context.l10n.hostsCantBeAddedInThe);
      final vaultId = app.activeVault?.id, accountId = app.session?.accountId;
      final draft = await showHostEditorPanel(
        context,
        initialDraft: command.draft(const Uuid().v4()),
        submitLabel: context.l10n.saveAndConnect,
        groups: app.groups,
        hosts: app.hosts,
        onValidate: app.validateHostReferences,
      );
      if (draft == null ||
          !mounted ||
          app.activeVault?.id != vaultId ||
          app.session?.accountId != accountId)
        return;
      await app.saveHost(draft);
      if (!mounted ||
          app.activeVault?.id != vaultId ||
          app.session?.accountId != accountId)
        return;
      final saved = app.hosts.where((host) => host.id == draft.id).firstOrNull;
      if (saved != null) await app.openTerminalTab(saved);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Widget _statusBar() {
    final file = _fileTabs.find(_selectedFileId ?? '');
    final tab = file == null
        ? app.activeTerminalTab
        : app.terminalTabFor(file.sourceSessionId);
    final host = file?.host ?? tab?.host;
    final phase = tab?.state;
    final telnet = host?.protocol == HostProtocol.telnet;
    final status = phase == 'connected'
        ? (telnet
              ? context.l10n.telnetConnectedUnencrypted
              : context.l10n.sshConnected)
        : phase == 'connecting'
        ? (telnet ? context.l10n.telnetConnecting : context.l10n.sshConnecting)
        : (telnet
              ? context.l10n.telnetDisconnected
              : context.l10n.sshDisconnected);
    final detail = [
      if (host != null)
        host.username.isEmpty
            ? host.endpoint
            : '${host.username}@${host.endpoint}',
      app.currentVaultName,
      '${_statusLabel(app.syncStatus)} · ${context.l10n.pendingCountShort(app.pendingCount)}',
    ].join(' · ');
    return ListenableBuilder(
      listenable: sshTransferActivity,
      builder: (_, _) => WorkspaceStatusBar(
        status: status,
        detail: detail,
        sessionCount: app.terminalTabs
            .where((tab) => tab.connection != null && tab.state == 'connected')
            .length,
        onProperties: host == null
            ? null
            : () => unawaited(
                showHostProperties(
                  context,
                  host,
                  state: phase == null
                      ? null
                      : terminalStateLabel(context.l10n, phase),
                ),
              ),
        transfer: sshTransferActivity.activeCount == 0
            ? null
            : Text(
                sshTransferActivity.summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
      ),
    );
  }

  void _onControllerChanged() {
    McpService.instance.workspaceChanged();
    if (!mounted) return;
    _syncSessionWorkspace();
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeFilesLaunch());
    _controllerNotificationGeneration++;
    unawaited(_refreshPendingOutboxArchiveCoverage());
    setState(() {});
    final message = app.errorMessage ?? app.noticeMessage;
    if (message != null && message.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(SnackBar(content: Text(message)));
        if (app.errorMessage != null) app.errorMessage = null;
        if (app.noticeMessage != null) app.noticeMessage = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1120;
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              WorkspaceTabBar(
                onDisconnect: (id) => unawaited(app.disconnectTerminalTab(id)),
                groups: _sessionWorkspace.groupedSessionIds,
                groupSelections: _sessionWorkspace.retainedGroupSelections,
                onUnsplit: _unsplitWorkspaceTab,
                onSftp: (id) => unawaited(_openSessionFiles(id)),
                onScp: kIsWeb
                    ? null
                    : (id) => unawaited(
                        _openSessionFiles(
                          id,
                          protocol: SshTransferProtocol.scp,
                        ),
                      ),
                onScpUpload: kIsWeb
                    ? (id) => unawaited(
                        _showSessionScp(
                          context,
                          app,
                          id,
                          SshTransferDirection.upload,
                        ),
                      )
                    : null,
                onScpDownload: kIsWeb
                    ? (id) => unawaited(
                        _showSessionScp(
                          context,
                          app,
                          id,
                          SshTransferDirection.download,
                        ),
                      )
                    : null,
                onSearch: app.activeVault == null
                    ? null
                    : () => unawaited(_openHostSearch()),
                onToggleTools:
                    app.page == WorkspacePage.terminal &&
                        _fileTabs.find(_sessionWorkspace.selectedId ?? '') ==
                            null &&
                        app.activeTerminalTab != null &&
                        app.activeTerminalTab!.desktop == null
                    ? () => _terminalPageKey.currentState?.toggleTools()
                    : null,
                homeMenuActions: [
                  WorkspaceAction(
                    'cloud_add_group',
                    context.l10n.addGroup,
                    Icons.create_new_folder_outlined,
                    () => showAppDialog<void>(
                      context: context,
                      builder: (_) => _ServerGroupEditorDialog(app: app),
                    ),
                    enabled: app.activeVault?.canWrite == true,
                  ),
                  WorkspaceAction(
                    'host_import_openssh_config',
                    context.l10n.importSshConfig,
                    Icons.file_open_outlined,
                    () => _importOpenSshConfig(context, app),
                    enabled: app.activeVault?.canWrite == true,
                  ),
                  if (hasLocalTermiusInstallation())
                    WorkspaceAction(
                      'host_termius_one_click',
                      context.l10n.termiusLocalOneClickAction,
                      Icons.bolt_rounded,
                      () => _runCloudOneClickTermiusImport(context, app),
                      enabled: app.activeVault?.canWrite == true,
                    ),
                  WorkspaceAction(
                    'host_termius_transfer',
                    context.l10n.r7ImportMenuAction,
                    Icons.swap_horiz_outlined,
                    () async {
                      final outcome = await showTermiusTransferDialog(
                        context,
                        target: CloudTermiusTransferTarget(app),
                        certificates: const KeychainTermiusCertificateBridge(),
                      );
                      if (!context.mounted || outcome == null) return;
                      _snack(
                        context,
                        outcome.exported
                            ? currentL10n.r7ImportExported
                            : currentL10n.r7ImportDone(
                                outcome.importedHosts,
                                outcome.createdGroups,
                              ),
                      );
                    },
                    enabled: app.activeVault != null,
                  ),
                  WorkspaceAction(
                    'host_import_ansible_inventory',
                    context.l10n.importAnsibleInventory,
                    Icons.inventory_2_outlined,
                    () => _importAnsibleInventory(context, app),
                    enabled: app.activeVault?.canWrite == true,
                  ),
                  WorkspaceAction(
                    'recycle_bin_open',
                    context.l10n.recycleBin,
                    Icons.delete_outline,
                    () => showAppDialog<void>(
                      context: context,
                      builder: (_) => _RecycleBinDialog(app: app),
                    ),
                    enabled: app.activeVault != null,
                  ),
                  WorkspaceAction(
                    'cloud_save_window_combination',
                    context.l10n.saveWindowSet,
                    Icons.dashboard_customize_outlined,
                    _saveWindowCombination,
                    enabled:
                        app.activeVault?.canWrite == true &&
                        (app.terminalTabs.any((t) => !t.closed) ||
                            TrackedFilesWindows.instance.hasWindows(app)) &&
                        !_openingCombination,
                  ),
                  ..._cloudFunctionsActions(app, (page) {
                    setState(() => _selectedFileId = null);
                    app.showWorkspacePage(page);
                  }, forwarding: _forwardingPageBuilder != null),
                  for (final protocol in HostProtocol.values)
                    WorkspaceAction(
                      'cloud_new_${protocol.name}',
                      context.l10n.newTouppercaseHost(protocol.name.toUpperCase()),
                      hostProtocolIcon(protocol),
                      () => _showCloudHostEditor(
                        context,
                        app,
                        initialProtocol: protocol,
                      ),
                      enabled: app.activeVault?.canWrite == true,
                    ),
                  ...localShellWorkspaceActions(
                    context,
                    idPrefix: 'cloud',
                    onLaunch: (launch) async {
                      setState(() => _selectedFileId = null);
                      try {
                        await app.openLocalShellTab(launch: launch);
                      } catch (error) {
                        if (mounted) {
                          _snack(
                            context,
                            app.friendlyError(error),
                            error: true,
                          );
                        }
                      }
                    },
                  ),
                  if (supportsNewWindow)
                    WorkspaceAction(
                      'cloud_new_window',
                      context.l10n.newWindow,
                      Icons.open_in_new,
                      openNewWindow,
                    ),
                ],
                tabs: [
                  WorkspaceTab(id: 'hosts', title: context.l10n.home, isHome: true),
                  ..._tabOrder.arrange<WorkspaceTab>([
                    for (final tab in app.visibleTerminalTabs)
                      WorkspaceTab(
                        id: tab.id,
                        title: tab.host?.name ?? context.l10n.terminal,
                        isConnected: tab.state == 'connected',
                        canDisconnect: tab.host?.protocol.isTerminal == true && tab.console == null &&
                            (tab.state == 'connected' || tab.state == 'connecting' || tab.recovery?.automaticEnabled == true),
                        canOpenFiles:
                            tab.host?.protocol == HostProtocol.ssh &&
                            (kIsWeb || tab.connection != null),
                        status: terminalStateLabel(context.l10n, tab.state),
                        canDetach:
                            (tab.connection != null || tab.console != null) &&
                            ApplicationWindows.instance.supported,
                      ),
                    for (final file in _fileTabs.entries)
                      WorkspaceTab(
                        id: file.id,
                        title: file.title,
                        isFile: true,
                        isConnected: true,
                        canDetach: supportsFilesWindows,
                      ),
                  ], (tab) => tab.id),
                ],
                selectedId:
                    _selectedFileId ??
                    (app.page == WorkspacePage.terminal
                        ? app.activeTerminalTabId ?? 'hosts'
                        : 'hosts'),
                onSelect: _selectWorkspaceTab,
                onDuplicate: (id) => unawaited(_duplicateWorkspaceTab(id)),
                onClose: (id) => unawaited(_closeWorkspaceTab(id)),
                onReorder: (id, beforeId) =>
                    setState(() => _tabOrder.move(id, beforeId)),
                onSplit: (id, axis) => unawaited(_splitSession(id, axis)),
                onDetach: (id) => unawaited(
                  _fileTabs.find(id) != null
                      ? _detachFile(id)
                      : _detachSession(id),
                ),
                onProperties: _showSessionProperties,
                onCloseOthers: (id) async {
                  final sourceId = _fileTabs.find(id)?.sourceSessionId;
                  for (final file
                      in _fileTabs.entries.where((f) => f.id != id).toList()) {
                    await _fileTabs.close(file.id);
                  }
                  for (final other
                      in app.visibleTerminalTabs
                          .where((tab) => tab.id != id && tab.id != sourceId)
                          .toList()) {
                    await _closeWorkspaceTab(other.id);
                  }
                },
                dragScope: _cloudDragScope,
                supportsNewWindow: supportsNewWindow,
                onNewWindow: () async {
                  try {
                    await openNewWindow();
                  } on Object {
                    if (context.mounted)
                      {
_snack(context, context.l10n.couldntOpenANewWindow, error: true);
}
                  }
                },
              ),
              if (app.databaseRecoveryRequired)
                Container(
                  key: const ValueKey('database_recovery_required'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  color: context.palette.errorContainer,
                  child: Text(
                    context.l10n.localStorageNeedsRecoveryReadingEditing,
                    style: TextStyle(color: context.palette.onErrorContainer),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    // Home-only navigation: terminal/file panes get the full
                    // width (no permanent sidebar beside a terminal).
                    if (app.page != WorkspacePage.terminal &&
                        _selectedFileId == null)
                      _SideNavigation(
                        app: app,
                        wide: wide,
                        forwardingAvailable: _forwardingPageBuilder != null,
                        importExportActions: app.activeVault == null
                            ? const []
                            : _cloudImportExportActions(context, app),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          if (_webUpdateMonitor != null)
                            _WebAppUpdateBanner(
                              app: app,
                              monitor: _webUpdateMonitor!,
                              pendingOutboxArchiveCoversCurrentState:
                                  _pendingOutboxArchiveCoversCurrentState,
                              pendingOutboxArchiveStillCoversCurrentState:
                                  _pendingOutboxArchiveStillCoversCurrentState,
                            ),
                          if (app.activeVault?.status == 'deleting')
                            _VaultReadOnlyBanner(vault: app.activeVault!),
                          Expanded(
                            child: _WorkspacePage(
                              terminalPageKey: _terminalPageKey,
                              onQuickConnect: (request) =>
                                  unawaited(_quickConnect(request)),
                              fileTabs: _fileTabs,
                              onOpenWindowCombination: _openWindowCombination,
                              openingCombination: _openingCombination,
                              onWorkspaceSelect: _selectWorkspaceTab,
                              onWorkspaceClose: (id) =>
                                  unawaited(_closeWorkspaceTab(id)),
                              onWorkspaceUnsplit: _unsplitWorkspaceTab,
                              onWorkspaceDuplicate: (id) => unawaited(_duplicateWorkspaceTab(id)),
                              onWorkspaceSplit: (id, axis) => unawaited(
                                _splitSession(id, axis, newSession: true),
                              ),
                              workspaceSplitTargets: () => _tabOrder.arrange<String>([
                                for (final tab in app.visibleTerminalTabs)
                                  if (!tab.closed) tab.id,
                                for (final file in _fileTabs.entries) file.id,
                              ], (id) => id),
                              app: app,
                              onOpenFiles: _openHostFiles,
                              onOpenGroup: _openGroup,
                              onSaveGroupLayout: _saveGroupLayout,
                              onResetGroupLayout: _resetGroupLayout,
                              sessionWorkspace: _sessionWorkspace,
                              dragScope: _cloudDragScope,
                              enableWebCommandSuggestionsForTesting:
                                  widget.enableWebCommandSuggestionsForTesting,
                              onOpenLocalMigration: widget.onOpenLocalMigration,
                              webAppUpdateMonitor: _webUpdateMonitor,
                              onArchiveExportStarting: _onArchiveExportStarting,
                              onArchiveExport: _onArchiveExported,
                              forwardingBuilder: _forwardingPageBuilder,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _statusBar(),
            ],
          ),
        ),
      );
    },
  );
}

class _WebAppUpdateBanner extends StatelessWidget {
  const _WebAppUpdateBanner({
    required this.app,
    required this.monitor,
    required this.pendingOutboxArchiveCoversCurrentState,
    required this.pendingOutboxArchiveStillCoversCurrentState,
  });

  final AppController app;
  final WebAppUpdateMonitor monitor;
  final bool pendingOutboxArchiveCoversCurrentState;
  final Future<bool> Function() pendingOutboxArchiveStillCoversCurrentState;

  bool get _hasActiveTerminal =>
      app.terminalTabs.any(
        (tab) => tab.connection != null || tab.state == 'connecting',
      ) ||
      app.terminalShareObservers.any(
        (observer) =>
            !observer.closed &&
            (observer.state == 'connecting' || observer.state == 'connected'),
      );

  bool get _vaultBusy => app.syncing || app.snapshotRecoveryActive;

  bool get _canApply =>
      monitor.hasUpdate &&
      !_hasActiveTerminal &&
      !_vaultBusy &&
      (app.pendingCount == 0 || pendingOutboxArchiveCoversCurrentState);

  Future<void> _reviewUpdate(BuildContext context) async {
    if (!_canApply ||
        !await pendingOutboxArchiveStillCoversCurrentState() ||
        !_canApply) {
      return;
    }
    final accepted = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: Listenable.merge([app, monitor]),
        builder: (context, _) => AlertDialog(
          key: const ValueKey('web_app_update_confirmation'),
          icon: const Icon(Icons.system_update_alt_rounded),
          title: Text(context.l10n.applyWebUpdate),
          content: SizedBox(
            width: appDialogWidth(context, 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.atermiusWillReloadThisPageTo,
                ),
                if (app.syncStatus == 'upgrade_required') ...[
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.theServerRequiresANewerClient,
                    style: TextStyle(color: context.palette.orange),
                  ),
                ],
                if (app.pendingCount > 0 &&
                    pendingOutboxArchiveCoversCurrentState) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.anEncryptedVaultArchiveCoveringPendingcount(app.pendingCount),
                  ),
                ],
                if (!_canApply) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.updateReadinessChangedFinishTheVisible,
                    style: TextStyle(color: context.palette.orange),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('web_app_update_cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              key: const ValueKey('web_app_update_confirm'),
              onPressed: _canApply
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(context.l10n.updateAndReload),
            ),
          ],
        ),
      ),
    );
    if (accepted == true &&
        await pendingOutboxArchiveStillCoversCurrentState() &&
        _canApply) {
      await monitor.applyUpdate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final protocolMismatch = app.syncStatus == 'upgrade_required';
    if (!monitor.hasUpdate && !protocolMismatch) return const SizedBox.shrink();

    final blockers = <String>[];
    if (_hasActiveTerminal) {
      blockers.add(context.l10n.closeActiveSshTerminalsBeforeApplying);
    }
    if (_vaultBusy) {
      blockers.add(context.l10n.waitForVaultSynchronizationOrRecovery);
    }
    if (app.pendingCount > 0 && !pendingOutboxArchiveCoversCurrentState) {
      blockers.add(
        '${app.pendingCount} encrypted outbox operation(s) need to sync or be included in a new encrypted Vault archive.',
      );
    }

    return Semantics(
      key: const ValueKey('web_app_update_banner'),
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        color: protocolMismatch
            ? context.palette.errorContainer
            : context.palette.lime.withValues(alpha: .13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              protocolMismatch
                  ? context.l10n.theServerRequiresANewerWeb
                  : context.l10n.aNewerAtermiusWebBuildIs,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              protocolMismatch && !monitor.hasUpdate
                  ? context.l10n.noNewerBundleIsAvailableAt
                  : context.l10n.atermiusWillKeepThisPageAnd,
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
            if (blockers.isNotEmpty) ...[
              const SizedBox(height: 5),
              ...blockers.map(
                (blocker) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '• $blocker',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (app.pendingCount > 0)
                  OutlinedButton.icon(
                    key: const ValueKey('web_app_update_sync'),
                    onPressed: app.syncing ? null : () => _runSyncFromUi(app),
                    icon: const Icon(Icons.sync_rounded, size: 17),
                    label: Text(context.l10n.syncPendingChanges),
                  ),
                if (app.pendingCount > 0)
                  OutlinedButton.icon(
                    key: const ValueKey('web_app_update_archive'),
                    onPressed: () =>
                        app.showWorkspacePage(WorkspacePage.settings),
                    icon: const Icon(Icons.lock_outline_rounded, size: 17),
                    label: Text(
                      context.l10n.openSettingsDataAndMigrationTo,
                    ),
                  ),
                if (_hasActiveTerminal)
                  OutlinedButton.icon(
                    key: const ValueKey('web_app_update_close_terminal'),
                    onPressed: () =>
                        app.showWorkspacePage(WorkspacePage.terminal),
                    icon: const Icon(Icons.terminal_rounded, size: 17),
                    label: Text(context.l10n.openActiveTerminals),
                  ),
                if (monitor.hasUpdate)
                  FilledButton.icon(
                    key: const ValueKey('web_app_update_review'),
                    onPressed: _canApply ? () => _reviewUpdate(context) : null,
                    icon: const Icon(Icons.system_update_alt_rounded, size: 17),
                    label: Text(context.l10n.reviewUpdate),
                  ),
                if (!monitor.hasUpdate)
                  OutlinedButton.icon(
                    onPressed: monitor.checking ? null : monitor.checkNow,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text(
                      monitor.checking ? 'Checking…' : context.l10n.checkForUpdates,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WebAppUpdateSettingsCard extends StatelessWidget {
  const _WebAppUpdateSettingsCard({required this.monitor});

  final WebAppUpdateMonitor monitor;

  String get _status => switch ((
    monitor.checking,
    monitor.hasUpdate,
    monitor.lastCheckSucceeded,
  )) {
    (true, _, _) => currentL10n.checkingThisSelfHostedInstanceFor,
    (false, true, _) => currentL10n.aNewerWebBuildIsAvailable,
    (false, false, true) => currentL10n.thisWebBuildIsCurrent,
    _ => currentL10n.theUpdateCheckCouldNotConfirm,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.webApplicationUpdates,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 7),
            Text(
              _status,
              key: const ValueKey('web_app_update_status'),
              style: TextStyle(
                color: context.palette.muted,
                height: 1.4,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              key: const ValueKey('web_app_update_check'),
              onPressed: monitor.checking ? null : monitor.checkNow,
              icon: monitor.checking
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.checkForUpdates),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> _confirmSshHostKey(
  BuildContext context, {
  required String endpoint,
  required String fingerprint,
  String? algorithm,
  bool previouslyRevoked = false,
  bool offlineTransportUnavailable = false,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.gpp_maybe_outlined, color: context.palette.orange),
      title: Text(context.l10n.verifySshHostKey),
      content: SizedBox(
        width: appDialogWidth(context, 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.thisSshKeyIsNotTrusted(endpoint),
            ),
            if (algorithm != null) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.algorithmAlgorithm(algorithm),
                style: TextStyle(fontSize: 12, color: context.palette.muted),
              ),
            ],
            const SizedBox(height: 14),
            Semantics(
              key: const ValueKey('ssh-host-key-fingerprint'),
              container: true,
              label: context.l10n.sshHostKeyFingerprintFingerprint(fingerprint),
              child: SelectableText(
                fingerprint,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: context.palette.lime,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              offlineTransportUnavailable
                  ? context.l10n.vaultSyncIsUnreachableThisConfirmation
                  : previouslyRevoked
                  ? context.l10n.thisExactFingerprintWasRevokedBefore
                  : context.l10n.afterConfirmationThisFingerprintIsSaved,
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.reject2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            offlineTransportUnavailable
                ? context.l10n.queueApprovalAndStop
                : context.l10n.trustAfterVerification,
          ),
        ),
      ],
    ),
  );
  return result == true;
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    required this.app,
    required this.wide,
    this.forwardingAvailable = false,
    this.importExportActions = const [],
  });

  final AppController app;
  final bool wide;
  final List<HomeSidebarAction> importExportActions;

  /// The Forwarding destination is listed only once a page builder is wired.
  final bool forwardingAvailable;

  // Page/icon descriptors are static; labels are resolved from the active
  // catalog at render/action time so a runtime language switch relabels them.
  static const _items = [
    _NavItem(WorkspacePage.hosts, Icons.dns_outlined, _NavLabel.hosts),
    _NavItem(WorkspacePage.groups, Icons.folder_copy_outlined, _NavLabel.groups),
    _NavItem(WorkspacePage.logs, Icons.receipt_long_outlined, _NavLabel.logs),
    _NavItem(WorkspacePage.forwarding, Icons.hub_outlined, _NavLabel.forwarding),
    _NavItem(WorkspacePage.snippets, Icons.code_rounded, _NavLabel.snippets),
    _NavItem(WorkspacePage.credentials, Icons.key_outlined, _NavLabel.keychain),
    _NavItem(
      WorkspacePage.savedWorkspaces,
      Icons.view_quilt_outlined,
      _NavLabel.workspaces,
    ),
    _NavItem(WorkspacePage.terminal, Icons.terminal_rounded, _NavLabel.terminal),
    _NavItem(WorkspacePage.sftp, Icons.folder_open_outlined, _NavLabel.files),
    _NavItem(WorkspacePage.sync, Icons.sync_rounded, _NavLabel.sync),
    _NavItem(WorkspacePage.audit, Icons.history_rounded, _NavLabel.audit),
    _NavItem(WorkspacePage.devices, Icons.devices_outlined, _NavLabel.devices),
    _NavItem(WorkspacePage.settings, Icons.settings_outlined, _NavLabel.settings),
  ];

  @override
  Widget build(BuildContext context) {
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final phone = MediaQuery.sizeOf(context).width < 600;
    final itemHeight = touch ? 48.0 : 38.0;
    final itemInset = wide ? 8.0 : touch ? 1.0 : 6.0;
    final items = app.activeVault == null
        ? _items
              .where(
                (item) =>
                    item.page == WorkspacePage.devices ||
                    item.page == WorkspacePage.settings,
              )
              .toList(growable: false)
        : _items
              .where(
                (item) => _cloudNavItemAvailable(
                  item,
                  forwarding: forwardingAvailable,
                ),
              )
              .toList(growable: false);
    return Container(
      width: wide ? 200 : phone ? 52 : 72,
      decoration: BoxDecoration(
        color: wallpaperWindowFill(context, context.palette.rail, opacity: .72),
        border: Border(right: BorderSide(color: context.palette.line)),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              wide ? 16 : 8,
              19,
              wide ? 16 : 8,
              25,
            ),
            child: Row(
              mainAxisAlignment: wide
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: context.palette.lime,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.terminal_rounded,
                    color: context.palette.onAccentText,
                    size: 22,
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: 10),
                  const Expanded(
                    child: const Text(
                      'Atermius',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Pill(label: context.l10n.private),
                ],
              ],
            ),
          ),
          if (wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(19, 0, 16, 9),
              child: Row(
                children: [
                  // Both labels shrink with ellipsis so large text scales and
                  // long translations never overflow the compact column.
                  Flexible(
                    child: Text(
                      context.l10n.workspace2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.2,
                        color: context.palette.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      context.l10n.countHosts(app.hosts.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 10,
                        color: context.palette.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: items.map((item) {
                final selected = app.page == item.page;
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: itemInset,
                    vertical: 2,
                  ),
                  child: Tooltip(
                    message: item.label(context.l10n),
                    child: InkWell(
                      key: ValueKey('home_nav_${item.page.name}'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () => app.showWorkspacePage(item.page),
                      child: AnimatedContainer(
                        duration: AppMotion.duration(
                          context,
                          MotionDurations.quick,
                        ),
                        curve: MotionCurves.move,
                        height: itemHeight,
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? 11 : 0,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? context.palette.lime.withValues(alpha: .105)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          border: selected
                              ? Border.all(
                                  color: context.palette.lime.withValues(alpha: .18),
                                )
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: wide
                              ? MainAxisAlignment.start
                              : MainAxisAlignment.center,
                          children: [
                            Icon(
                              item.icon,
                              size: 19,
                              color: selected
                                  ? context.palette.lime
                                  : context.palette.muted,
                            ),
                            if (wide) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  item.label(context.l10n),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: selected
                                        ? context.palette.text
                                        : context.palette.muted,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (item.page == WorkspacePage.sync &&
                                  app.unresolvedConflictCount > 0)
                                _CountBadge(count: app.unresolvedConflictCount),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          if (importExportActions.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: itemInset),
              child: MenuAnchor(
                menuChildren: [
                  for (final action in importExportActions)
                    MenuItemButton(
                      key: ValueKey('home_nav_action_${action.id}'),
                      leadingIcon: Icon(action.icon, size: 18),
                      onPressed: action.enabled ? action.onSelected : null,
                      child: Text(action.label),
                    ),
                ],
                builder: (context, controller, _) => Tooltip(
                  message: wide ? '' : context.l10n.r7NavImportExport,
                  child: InkWell(
                    key: const ValueKey('home_nav_import_export'),
                    borderRadius: BorderRadius.circular(11),
                    onTap: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    child: SizedBox(
                      height: itemHeight,
                      child: Row(
                        mainAxisAlignment: wide
                            ? MainAxisAlignment.start
                            : MainAxisAlignment.center,
                        children: [
                          if (wide) const SizedBox(width: 11),
                          Icon(
                            Icons.import_export_rounded,
                            size: 19,
                            color: context.palette.muted,
                          ),
                          if (wide) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                context.l10n.r7NavImportExport,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.palette.muted,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (wide)
            Container(
              margin: const EdgeInsets.all(14),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.palette.line),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: context.palette.surfaceSoft,
                    child: Icon(
                      Icons.person_outline,
                      size: 16,
                      color: context.palette.teal,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.account?.accountId.substring(0, 8) ??
                              context.l10n.localDevice,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          app.activeVault == null ? context.l10n.accountSessionUnlocked : context.l10n.encryptedSessionUnlocked,
                          style: TextStyle(
                            fontSize: 10,
                            color: context.palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.lockWorkspace,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => app.lock(),
                    icon: Icon(
                      Icons.lock_outline,
                      size: 17,
                      color: context.palette.muted,
                    ),
                  ),
                ],
              ),
            )
          else
            IconButton(
              tooltip: context.l10n.lockWorkspace,
              onPressed: () => app.lock(),
              icon: Icon(Icons.lock_outline, color: context.palette.muted),
            ),
          const SizedBox(height: 9),
        ],
      ),
    );
  }
}

enum _NavLabel {
  hosts,
  groups,
  logs,
  forwarding,
  keychain,
  snippets,
  workspaces,
  terminal,
  files,
  sync,
  audit,
  devices,
  settings,
}

/// Display label for a terminal tab's stable state id. Unknown ids are shown
/// verbatim; the ids themselves are never localized or persisted translated.
String terminalStateLabel(AppLocalizations l10n, String state) =>
    switch (state) {
      'connected' => l10n.terminalStateConnected,
      'connecting' => l10n.terminalStateConnecting,
      'reconnecting' => l10n.terminalStateReconnecting,
      'disconnected' => l10n.terminalStateDisconnected,
      'closed' => l10n.terminalStateClosed,
      'ended' => l10n.terminalStateEnded,
      'failed' => l10n.terminalStateFailed,
      _ => state,
    };

class _NavItem {
  const _NavItem(this.page, this.icon, this.labelId);
  final WorkspacePage page;
  final IconData icon;
  final _NavLabel labelId;

  String label(AppLocalizations l10n) => switch (labelId) {
    _NavLabel.hosts => l10n.hosts,
    _NavLabel.groups => l10n.groups,
    _NavLabel.logs => l10n.r7NavLogs,
    _NavLabel.forwarding => l10n.r7NavPortForwarding,
    _NavLabel.keychain => l10n.r7NavKeychain,
    _NavLabel.snippets => l10n.r7NavSnippets,
    _NavLabel.workspaces => l10n.workspaceLayouts,
    _NavLabel.terminal => l10n.terminal2,
    _NavLabel.files => l10n.files,
    _NavLabel.sync => l10n.syncAndConflicts,
    _NavLabel.audit => l10n.auditLog2,
    _NavLabel.devices => l10n.devices,
    _NavLabel.settings => l10n.settings,
  };
}

/// R7-INTEGRATION(import_export): root replaces with a `HomeSidebarAction`
/// (id `cloud_termius_transfer`) opening `showTermiusTransferDialog(context,
/// target: CloudTermiusTransferTarget(app))`; omitted while null. The import
/// branch's own `host_termius_transfer` home-menu action stays separate.
Future<void> _runCloudOneClickTermiusImport(
  BuildContext context,
  AppController app,
) async {
  final outcome = await runOneClickTermiusImport(
    context,
    target: CloudTermiusTransferTarget(app),
    certificates: const KeychainTermiusCertificateBridge(),
  );
  if (!context.mounted || outcome == null || outcome.importedHosts == 0) {
    return;
  }
  _snack(
    context,
    currentL10n.r7ImportDone(outcome.importedHosts, outcome.createdGroups),
  );
}

HomeSidebarAction? _cloudTermiusOneClickAction(
  BuildContext context,
  AppController app,
) {
  if (!hasLocalTermiusInstallation()) return null;
  return HomeSidebarAction(
    id: 'cloud_termius_one_click',
    label: context.l10n.termiusLocalOneClickAction,
    icon: Icons.bolt_rounded,
    enabled: app.activeVault?.canWrite == true,
    onSelected: () => _runCloudOneClickTermiusImport(context, app),
  );
}

HomeSidebarAction? _cloudTermiusTransferAction(
  BuildContext context,
  AppController app,
) => HomeSidebarAction(
  id: 'cloud_termius_transfer',
  label: context.l10n.r7ImportMenuAction,
  icon: Icons.swap_horiz_outlined,
  enabled: app.activeVault != null,
  onSelected: () => showTermiusTransferDialog(
    context,
    target: CloudTermiusTransferTarget(app),
    certificates: const KeychainTermiusCertificateBridge(),
  ),
);

bool _cloudNavItemAvailable(_NavItem item, {required bool forwarding}) =>
    item.page != WorkspacePage.forwarding || forwarding;

List<WorkspaceAction> _cloudFunctionsActions(
  AppController app,
  ValueChanged<WorkspacePage> onNavigate, {
  bool forwarding = false,
}) => [
  for (final item in _SideNavigation._items.where(
    (item) => _cloudNavItemAvailable(item, forwarding: forwarding),
  ))
    WorkspaceAction(
      'cloud-page-${item.page.name}',
      item.label(currentL10n),
      item.icon,
      () => onNavigate(item.page),
      enabled:
          app.activeVault != null ||
          item.page == WorkspacePage.settings ||
          item.page == WorkspacePage.devices,
    ),
  if (app.activeVault != null)
    WorkspaceAction(
      'cloud-sync-now',
      _topBarSyncLabel(app.syncStatus, app.pendingCount),
      _syncIcon(app.syncStatus),
      () => _runSyncFromUi(app),
      enabled: !app.syncing,
    ),
  for (final vault in app.vaults)
    WorkspaceAction(
      'cloud-vault-${vault.id}',
      currentL10n.vaultVaultname(app.vaultNameFor(vault.id)),
      Icons.folder_outlined,
      () => app.selectVault(vault.id),
    ),
  WorkspaceAction('cloud-lock', currentL10n.lockWorkspace, Icons.lock_outline, app.lock),
];

IconData _syncIcon(String status) => switch (status) {
  'idle' => Icons.cloud_done_outlined,
  'pending' => Icons.cloud_upload_outlined,
  'syncing' => Icons.sync_rounded,
  'deletion_pending' || 'read_only' => Icons.lock_clock_outlined,
  'revoked' || 'auth_required' => Icons.lock_clock_outlined,
  'resnapshot_required' ||
  'snapshot_too_large' ||
  'epoch_update_required' ||
  'snapshot_recovering' => Icons.warning_amber_rounded,
  _ => Icons.cloud_off_outlined,
};

Color _syncColor(BuildContext context, String status) => switch (status) {
  'idle' => context.palette.teal,
  'pending' || 'syncing' || 'snapshot_recovering' => context.palette.lime,
  'deletion_pending' => context.palette.orange,
  'snapshot_too_large' => context.palette.red,
  'read_only' => context.palette.muted,
  'revoked' || 'auth_required' || 'error' => context.palette.red,
  _ => context.palette.orange,
};

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: context.palette.orange.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      '$count',
      style: TextStyle(fontSize: 10, color: context.palette.orange),
    ),
  );
}

class _WorkspacePage extends StatelessWidget {
  const _WorkspacePage({
    required this.terminalPageKey,
    required this.onQuickConnect,
    required this.app,
    required this.onOpenFiles,
    required this.onOpenGroup,
    required this.onSaveGroupLayout,
    required this.onResetGroupLayout,
    required this.sessionWorkspace,
    required this.dragScope,
    required this.fileTabs,
    required this.onOpenWindowCombination,
    required this.openingCombination,
    required this.onWorkspaceSelect,
    required this.onWorkspaceClose,
    required this.onWorkspaceUnsplit,
    required this.onWorkspaceDuplicate,
    this.onWorkspaceSplit,
    this.workspaceSplitTargets,
    this.enableWebCommandSuggestionsForTesting = false,
    this.onOpenLocalMigration,
    this.webAppUpdateMonitor,
    this.onArchiveExportStarting,
    this.onArchiveExport,
    this.forwardingBuilder,
  });

  /// State-owned Forwarding page builder (`_AppShellState
  /// ._buildSshForwardingPage`); null hides the destination.
  final Widget Function()? forwardingBuilder;
  final GlobalKey<_TerminalPageState> terminalPageKey;
  final ValueChanged<QuickConnectRequest> onQuickConnect;
  final AppController app;
  final Future<void> Function(GroupRecord) onOpenGroup,
      onSaveGroupLayout,
      onResetGroupLayout;
  final Future<void> Function(HostRecord, SshTransferProtocol) onOpenFiles;
  final SessionWorkspaceController sessionWorkspace;
  final FileWorkspaceTabs fileTabs;
  final Future<void> Function(WindowCombination) onOpenWindowCombination;
  final bool openingCombination;
  final ValueChanged<String> onWorkspaceSelect;
  final ValueChanged<String> onWorkspaceClose, onWorkspaceUnsplit, onWorkspaceDuplicate;
  final void Function(String id, Axis axis)? onWorkspaceSplit;
  final Iterable<String> Function()? workspaceSplitTargets;
  final String dragScope;
  final bool enableWebCommandSuggestionsForTesting;
  final Future<void> Function(BuildContext context)? onOpenLocalMigration;
  final WebAppUpdateMonitor? webAppUpdateMonitor;
  final Future<void> Function()? onArchiveExportStarting;
  final VoidCallback? onArchiveExport;

  @override
  Widget build(BuildContext context) {
    final emptyVault =
        app.activeVault == null &&
        app.page != WorkspacePage.settings &&
        app.page != WorkspacePage.devices;
    // One stable wrapper for every page: switching category replays a short
    // fade + lift on the incoming page only. The page widgets keep their
    // existing identity rules (no re-keying, no outgoing copy), so terminal
    // views and their GlobalKeys are never mounted twice.
    return MotionEntrance(
      key: const ValueKey('workspace_page_motion'),
      trigger: emptyVault ? null : app.page,
      child: emptyVault ? _EmptyVaultWorkspace(app: app) : _page(),
    );
  }

  Widget _page() {
    return switch (app.page) {
      WorkspacePage.hosts => _HostsPage(
        onQuickConnect: onQuickConnect,
        onOpenWindowCombination: onOpenWindowCombination,
        openingCombination: openingCombination,
        app: app,
        onOpenFiles: onOpenFiles,
        onOpenGroup: onOpenGroup,
        onSaveGroupLayout: onSaveGroupLayout,
        onResetGroupLayout: onResetGroupLayout,
      ),
      WorkspacePage.groups => _GroupsPage(app: app),
      WorkspacePage.credentials => _CredentialsPage(app: app),
      WorkspacePage.logs => SessionLogsPage(book: app.sessionLogs),
      WorkspacePage.forwarding =>
        forwardingBuilder?.call() ??
            _HostsPage(
              onQuickConnect: onQuickConnect,
              onOpenWindowCombination: onOpenWindowCombination,
              openingCombination: openingCombination,
              app: app,
              onOpenFiles: onOpenFiles,
              onOpenGroup: onOpenGroup,
              onSaveGroupLayout: onSaveGroupLayout,
              onResetGroupLayout: onResetGroupLayout,
            ),
      WorkspacePage.snippets => _SnippetsPage(app: app),
      WorkspacePage.savedWorkspaces => _SavedWorkspacesPage(app: app),
      WorkspacePage.terminal => _TerminalPage(
        key: terminalPageKey,
        app: app,
        sessionWorkspace: sessionWorkspace,
        dragScope: dragScope,
        fileTabs: fileTabs,
        onWorkspaceSelect: onWorkspaceSelect,
        onWorkspaceClose: onWorkspaceClose,
        onWorkspaceUnsplit: onWorkspaceUnsplit,
        onWorkspaceDuplicate: onWorkspaceDuplicate,
        onWorkspaceSplit: onWorkspaceSplit,
        workspaceSplitTargets: workspaceSplitTargets,
        enableWebCommandSuggestionsForTesting:
            enableWebCommandSuggestionsForTesting,
      ),
      WorkspacePage.sftp => _SftpPage(app: app),
      WorkspacePage.sync => _SyncPage(app: app),
      WorkspacePage.audit => _AuditPage(app: app),
      WorkspacePage.devices => _DevicesPage(app: app),
      WorkspacePage.settings => _SettingsPage(
        app: app,
        onOpenLocalMigration: onOpenLocalMigration,
        webAppUpdateMonitor: webAppUpdateMonitor,
        onArchiveExportStarting: onArchiveExportStarting,
        onArchiveExport: onArchiveExport,
      ),
    };
  }
}

class _EmptyVaultWorkspace extends StatelessWidget {
  const _EmptyVaultWorkspace({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: appDialogWidth(context, 660)),
        child: Card(
          child: Padding(
            padding: AppDensity.of(context).pagePadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_open_rounded,
                  size: AppDensity.of(context).isCompact ? 30 : 34,
                  color: context.palette.lime,
                ),
                SizedBox(height: AppDensity.of(context).space5),
                Text(
                  context.l10n.noAccessibleVaults,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.thisAccountHasNoVaultAvailable,
                  style: TextStyle(
                    color: context.palette.muted,
                    height: 1.55,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: app.vaultLifecycleBusy
                          ? null
                          : () => _createVault(context, app),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: Text(context.l10n.createEncryptedVault),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _acceptVaultInvitation(context, app),
                      icon: const Icon(Icons.mark_email_read_outlined),
                      label: Text(context.l10n.acceptInvitation),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          app.showWorkspacePage(WorkspacePage.devices),
                      icon: const Icon(Icons.devices_outlined),
                      label: Text(context.l10n.trustedDevices),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _HostsPage extends StatefulWidget {
  const _HostsPage({
    required this.onQuickConnect,
    required this.app,
    required this.onOpenWindowCombination,
    required this.openingCombination,
    required this.onOpenFiles,
    required this.onOpenGroup,
    required this.onSaveGroupLayout,
    required this.onResetGroupLayout,
  });
  final ValueChanged<QuickConnectRequest> onQuickConnect;
  final AppController app;
  final Future<void> Function(WindowCombination) onOpenWindowCombination;
  final bool openingCombination;
  final Future<void> Function(GroupRecord) onOpenGroup,
      onSaveGroupLayout,
      onResetGroupLayout;
  final Future<void> Function(HostRecord, SshTransferProtocol) onOpenFiles;
  @override
  State<_HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<_HostsPage> {
  final Set<String> _connectingHosts = {};
  final _homeSearch = TextEditingController();
  @override
  void dispose() {
    _homeSearch.dispose();
    super.dispose();
  }

  AppController get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final canWrite = app.activeVault?.canWrite == true;
    final jumpHostRouteIssues = app.jumpHostRouteIssues;
    final hostGroupReferenceIssues = app.hostGroupReferenceIssues;
    final hostsNeedingGroupRepair = app.hostsNeedingGroupRepair;
    final query = _homeSearch.text.trim().toLowerCase();
    final groupLabels = hostSearchGroupLabels(app.groups);
    QuickConnectRequest? command;
    try {
      command = QuickConnectRequest.parse(_homeSearch.text);
    } on FormatException {
      // HostSearchField displays syntax guidance while typing.
    }
    final visible = app.hosts
        .where(
          (host) => command != null
              ? command.matches(host)
              : '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')} ${groupLabels[host.groupId] ?? ''}'
                    .toLowerCase()
                    .contains(query),
        )
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HostSearchField(
            fieldKey: const ValueKey('cloud_home_search'),
            controller: _homeSearch,
            onChanged: (_) => setState(() {}),
            onConnect: widget.onQuickConnect,
            onSearchSubmitted: visible.isEmpty
                ? null
                : () => _connect(visible.first),
          ),
          const SizedBox(height: 10),
          HomeAddSharingRow(
            idPrefix: 'cloud',
            canAddHosts: canWrite,
            onQuickImportTermius: hasLocalTermiusInstallation()
                ? () => _runCloudOneClickTermiusImport(context, app)
                : null,
            onAddHost: (protocol) => _showCloudHostEditor(
              context,
              app,
              initialProtocol: protocol,
            ),
            onLaunchShell: (launch) async {
              try {
                await app.openLocalShellTab(launch: launch);
              } catch (error) {
                if (context.mounted) {
                  _snack(context, app.friendlyError(error), error: true);
                }
              }
            },
            onSerialConsole: widget.onQuickConnect,
            sharing: CloudHomeSharingStatus(
              key: ValueKey('cloud-home-sharing-${app.currentVaultId}'),
              app: app,
              onOpenDetails: () => unawaited(_manageVaultMembers(context, app)),
            ),
          ),
          const SizedBox(height: 12),
          WindowCombinationsStrip(
            key: ValueKey('cloud-combinations-${app.currentVaultId}'),
            canRemove: app.activeVault?.canWrite == true,
            load: () async => app.windowCombinations,
            open: widget.onOpenWindowCombination,
            busy: widget.openingCombination,
            remove: (recipe) async {
              await app.saveWindowCombinations(
                app.windowCombinations.where((r) => r.id != recipe.id).toList(),
              );
            },
          ),
          if (hostsNeedingGroupRepair.isNotEmpty) ...[
            Card(
              key: const ValueKey('host_group_reference_repair_warning'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.hostsReferenceUnavailableGroups(
                              hostsNeedingGroupRepair.length,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const ValueKey(
                          'host_group_reference_repair_action',
                        ),
                        onPressed: canWrite
                            ? () => _editHost(
                                context,
                                hostsNeedingGroupRepair.first,
                              )
                            : null,
                        child: Text(context.l10n.repairAHost),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (app.groups.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final group in app.groups)
                  DecoratedBox(
                    key: ValueKey('cloud_group_tile_${group.id}'),
                    decoration: BoxDecoration(
                      color: context.palette.surface,
                      border: Border.all(color: context.palette.line),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Long group names ellipsize instead of overflowing
                        // narrow Home layouts.
                        Flexible(
                          child: Tooltip(
                            message: context.l10n.connectEverySshHostInThe,
                            child: TextButton.icon(
                              key: ValueKey('cloud_group_connect_${group.id}'),
                              onPressed: () =>
                                  unawaited(widget.onOpenGroup(group)),
                              icon: const Icon(
                                Icons.folder_open_outlined,
                                size: 17,
                              ),
                              label: Text(
                                '${group.name} · ${GroupSessionLayout.groupHosts(group, app.groups, app.hosts).length}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        WorkspaceOverflowMenu(
                          actions: [
                            WorkspaceAction(
                              'cloud-group-save-layout-${group.id}',
                              context.l10n.saveCurrentWindowLayout,
                              Icons.dashboard_customize_outlined,
                              () => widget.onSaveGroupLayout(group),
                              enabled: canWrite,
                            ),
                            WorkspaceAction(
                              'cloud-group-reset-layout-${group.id}',
                              context.l10n.resetLayout,
                              Icons.restart_alt,
                              () => widget.onResetGroupLayout(group),
                              enabled: canWrite,
                            ),
                            WorkspaceAction(
                              'cloud-group-edit-${group.id}',
                              context.l10n.editGroup,
                              Icons.edit_outlined,
                              () => _editGroup(context, group),
                              enabled: canWrite,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 15),
          if (visible.isEmpty)
            _EmptyState(
              icon: Icons.dns_outlined,
              title: app.hosts.isEmpty
                  ? context.l10n.noHostsSavedYet
                  : context.l10n.noMatchingHosts2,
              body: app.hosts.isEmpty
                  ? context.l10n.createYourFirstHostAndAttach
                  : context.l10n.adjustTheSearchOrGroupFilter,
              action: app.hosts.isEmpty
                  ? FilledButton.icon(
                      onPressed: canWrite ? () => _editHost(context) : null,
                      icon: const Icon(Icons.add),
                      label: Text(context.l10n.addYourFirstHost),
                    )
                  : null,
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final metrics = HostCardMetrics.of(context);
                final cards = visible
                    .map(
                      (host) => Padding(
                        padding: EdgeInsets.zero,
                        child: _HostCard(
                          host: host,
                          compact: constraints.maxWidth < 360,
                          canWrite: canWrite,
                          groupName: app.groups
                              .where((g) => g.id == host.groupId)
                              .firstOrNull
                              ?.name,
                          groupReferenceIssue:
                              hostGroupReferenceIssues[host.id],
                          jumpHostName: host.jumpHostId == null
                              ? null
                              : app.hosts
                                        .where(
                                          (candidate) =>
                                              candidate.id == host.jumpHostId,
                                        )
                                        .firstOrNull
                                        ?.name ??
                                    context.l10n.unavailableJumpHost,
                          jumpHostRouteIssue: jumpHostRouteIssues[host.id],
                          onConnect: () => _connect(host),
                          onSftp: () => _openHostFiles(host),
                          onScpUpload: () => _openHostFiles(
                            host,
                            scpDirection: SshTransferDirection.upload,
                          ),
                          onScpDownload: () => _openHostFiles(
                            host,
                            scpDirection: SshTransferDirection.download,
                          ),
                          onEdit: () => _editHost(context, host),
                          onDelete: () => _deleteHost(context, host),
                          onFavorite: () => app.saveHostFromEditor(
                            original: host,
                            edited: host.copyWith(isFavorite: !host.isFavorite),
                          ),
                          onAttachments: () => showHostAttachmentsDialog(
                            context,
                            app: app,
                            host: host,
                          ),
                          onShare: _cloudShareAvailable(app)
                              ? () => showCloudShareDialog(
                                  context,
                                  app: app,
                                  host: host,
                                )
                              : null,
                        ),
                      ),
                    )
                    .toList();
                if (constraints.maxWidth < 360) {
                  return Column(
                    children: [
                      for (final card in cards)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: HostCardMetrics.spacing,
                          ),
                          child: SizedBox(
                            height: metrics.extent(withMeta: false),
                            child: card,
                          ),
                        ),
                    ],
                  );
                }
                return GridView(
                  key: const ValueKey('cloud_host_grid'),
                  gridDelegate: metrics.gridDelegate(constraints.maxWidth),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: cards,
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _connect(HostRecord host) async {
    if (!_connectingHosts.add(host.id)) return;
    try {
      await app.openTerminalTab(host);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    } finally {
      _connectingHosts.remove(host.id);
    }
  }

  Future<void> _openHostFiles(
    HostRecord host, {
    SshTransferDirection? scpDirection,
  }) async {
    if (!_connectingHosts.add(host.id)) return;
    final routeContext = Navigator.of(context, rootNavigator: true).context;
    try {
      if (kIsWeb && scpDirection != null) {
        final tab = await resolveHostFileSession<TerminalTabSession>(
          hostId: host.id,
          sessions: () => app.terminalTabs,
          sessionId: (s) => s.id,
          sessionHostId: (s) => s.host?.id,
          isConnected: (s) =>
              !s.closed && s.state == 'connected' && s.connection != null,
          connect: () => app.openTerminalTab(host),
        );
        if (routeContext.mounted && tab != null) {
          await _showSessionScp(routeContext, app, tab.id, scpDirection);
        }
        return;
      }
      await widget.onOpenFiles(
        host,
        scpDirection == null
            ? SshTransferProtocol.sftp
            : SshTransferProtocol.scp,
      );
    } catch (error) {
      if (routeContext.mounted)
        _snack(routeContext, app.friendlyError(error), error: true);
    } finally {
      _connectingHosts.remove(host.id);
    }
  }

  bool _cloudShareAvailable(AppController app) {
    final service = CloudAccessService(app);
    return service.linksAvailable || service.organizationsAvailable;
  }

  Future<void> _editHost(BuildContext context, [HostRecord? existing]) =>
      _showCloudHostEditor(context, app, existing: existing);

  Future<void> _editGroup(BuildContext context, [GroupRecord? existing]) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) =>
          _ServerGroupEditorDialog(app: app, existing: existing),
    );
  }

  Future<void> _deleteHost(BuildContext context, HostRecord host) async {
    final ok = await _confirmDelete(context, host.name);
    if (ok != true) return;
    await app.deleteHost(host);
  }
}

class _RecycleBinDialog extends StatefulWidget {
  const _RecycleBinDialog({required this.app});

  final AppController app;

  @override
  State<_RecycleBinDialog> createState() => _RecycleBinDialogState();
}

class _RecycleBinDialogState extends State<_RecycleBinDialog> {
  AppController get app => widget.app;
  late Future<List<RecycleBinRecord>> _records;
  bool _restoring = false;
  bool _purging = false;
  bool _automaticPurgeUpdating = false;
  String? _restoreError;
  String? _purgeError;
  String? _purgeNotice;
  String? _automaticPurgeError;
  String? _automaticPurgeNotice;

  @override
  void initState() {
    super.initState();
    _records = app.loadRecycleBin();
    if (app.activeVault?.role == 'owner' && app.activeVault != null) {
      app.addListener(_onAppChanged);
      unawaited(app.refreshVaultDeviceRows(background: true));
    }
  }

  @override
  void dispose() {
    app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() {
    if (mounted) setState(() {});
  }

  void _reload() {
    setState(() {
      _restoreError = null;
      _purgeError = null;
      _purgeNotice = null;
      _automaticPurgeError = null;
      _automaticPurgeNotice = null;
      _records = app.loadRecycleBin();
    });
    if (app.activeVault?.role == 'owner') {
      unawaited(app.refreshVaultDeviceRows(background: true));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.recycleBin),
    content: SizedBox(
      width: appDialogWidth(context, 640),
      child: FutureBuilder<List<RecycleBinRecord>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 150,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return SizedBox(
              height: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    app.friendlyError(snapshot.error!),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.red),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('recycle_bin_retry'),
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.retry2),
                  ),
                ],
              ),
            );
          }
          final entries = snapshot.data ?? const <RecycleBinRecord>[];
          if (entries.isEmpty) {
            return SizedBox(
              height: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_purgeNotice != null) ...[
                    Text(
                      _purgeNotice!,
                      key: const ValueKey('recycle_bin_purge_notice'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.lime),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_purgeError != null) ...[
                    Text(
                      _purgeError!,
                      key: const ValueKey('recycle_bin_purge_error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.red),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_automaticPurgeNotice != null) ...[
                    Text(
                      _automaticPurgeNotice!,
                      key: const ValueKey('recycle_bin_auto_purge_notice'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.lime),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_automaticPurgeError != null) ...[
                    Text(
                      _automaticPurgeError!,
                      key: const ValueKey('recycle_bin_auto_purge_error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.red),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(context.l10n.noDeletedRecordsInThisVault),
                ],
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.recordsAreDecryptedOnlyOnThis,
                style: TextStyle(color: context.palette.muted, height: 1.4),
              ),
              if (_restoreError != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _restoreError!,
                    key: const ValueKey('recycle_bin_restore_error'),
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (_purgeNotice != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _purgeNotice!,
                    key: const ValueKey('recycle_bin_purge_notice'),
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              if (_purgeError != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _purgeError!,
                    key: const ValueKey('recycle_bin_purge_error'),
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (_automaticPurgeNotice != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _automaticPurgeNotice!,
                    key: const ValueKey('recycle_bin_auto_purge_notice'),
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              if (_automaticPurgeError != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _automaticPurgeError!,
                    key: const ValueKey('recycle_bin_auto_purge_error'),
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (app.activeVault?.role == 'owner') ...[
                const SizedBox(height: 8),
                _VaultRedactionReadinessPanel(
                  app: app,
                  compact: true,
                  showReviewDevices: true,
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: (entries.length * 174.0).clamp(150.0, 500.0).toDouble(),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _RecycleBinRow(
                    entry: entries[index],
                    busy: _restoring || _purging || _automaticPurgeUpdating,
                    isOwner: app.activeVault?.role == 'owner',
                    canManageAutomaticPurge: _canManageAutomaticPurge,
                    canPurge: _canOfferPurge(entries[index]),
                    onRestore: entries[index].canRestore
                        ? () => _confirmRestore(entries[index])
                        : null,
                    onPurge: _canOfferPurge(entries[index])
                        ? () => _confirmPurge(entries[index])
                        : null,
                    onAutomaticPurge: _canManageAutomaticPurge
                        ? () => _confirmAutomaticPurge(entries[index])
                        : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: _restoring || _purging || _automaticPurgeUpdating
            ? null
            : () => Navigator.pop(context),
        child: Text(context.l10n.close),
      ),
    ],
  );

  Future<void> _confirmRestore(RecycleBinRecord entry) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.restoreThisRecord),
        content: Text(
          context.l10n.displaynameWillBeRestoredFromIts(entry.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('recycle_bin_restore_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.restore),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    try {
      await app.restoreRecycleBinRecord(entry);
      if (mounted) {
        setState(() {
          _restoring = false;
          _records = app.loadRecycleBin();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _restoreError = app.friendlyError(error);
          _records = app.loadRecycleBin();
        });
      }
    }
  }

  bool _canOfferPurge(RecycleBinRecord entry) {
    final restoreUntil = entry.restoreUntil;
    return app.activeVault?.role == 'owner' &&
        restoreUntil != null &&
        !DateTime.now().toUtc().isBefore(restoreUntil);
  }

  bool get _canManageAutomaticPurge {
    final vault = app.activeVault;
    return vault?.role == 'owner' &&
        vault?.status == 'active' &&
        vault?.canWrite == true;
  }

  Future<void> _confirmAutomaticPurge(RecycleBinRecord entry) async {
    if (!_canManageAutomaticPurge) return;
    if (entry.autoPurgeEnabled) {
      await _saveAutomaticPurgeConsent(entry, enabled: false);
      return;
    }

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (_) =>
          _AutomaticPurgeConsentDialog(recordDisplayName: entry.displayName),
    );
    if (confirmed != true || !mounted) return;
    await _saveAutomaticPurgeConsent(entry, enabled: true);
  }

  Future<void> _saveAutomaticPurgeConsent(
    RecycleBinRecord entry, {
    required bool enabled,
  }) async {
    if (!_canManageAutomaticPurge) return;
    setState(() {
      _automaticPurgeUpdating = true;
      _automaticPurgeError = null;
      _automaticPurgeNotice = null;
    });
    try {
      await app.setRecycleBinRecordAutomaticPurge(entry, enabled: enabled);
      if (mounted) {
        setState(() {
          _automaticPurgeUpdating = false;
          _automaticPurgeNotice = enabled
              ? context.l10n.automaticPurgeConsentRecordedForThis
              : context.l10n.futureAutomaticPurgeConsentWithdrawn;
          _records = app.loadRecycleBin();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _automaticPurgeUpdating = false;
          _automaticPurgeError = app.friendlyError(error);
          _records = app.loadRecycleBin();
        });
      }
    }
  }

  Future<void> _confirmPurge(RecycleBinRecord entry) async {
    if (!_canOfferPurge(entry)) return;
    final restoreUntil = entry.restoreUntil!;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var acknowledged = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(context.l10n.permanentlyPurgeThisRecord),
            content: SizedBox(
              width: appDialogWidth(context, 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.displaynameAndItsEncryptedPayloadsWill(entry.displayName),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.restoreDeadlineFormatTheServerChecks(DateFormat.yMMMd().add_jm().format(restoreUntil.toLocal())),
                    style: TextStyle(color: context.palette.muted),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.offlineDeviceCopiesAndRetainedBackups,
                    style: TextStyle(color: context.palette.orange),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('recycle_bin_purge_acknowledgement'),
                    contentPadding: EdgeInsets.zero,
                    value: acknowledged,
                    onChanged: (value) =>
                        setDialogState(() => acknowledged = value ?? false),
                    title: Text(
                      context.l10n.iUnderstandThisPermanentlyRemovesThe,
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.l10n.cancel2),
              ),
              FilledButton(
                key: const ValueKey('recycle_bin_purge_confirm'),
                onPressed: acknowledged
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: Text(context.l10n.permanentlyPurge),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _purging = true;
      _purgeError = null;
      _purgeNotice = null;
    });
    try {
      await app.purgeRecycleBinRecord(entry);
      if (mounted) {
        setState(() {
          _purging = false;
          _purgeNotice = context.l10n.recordPermanentlyRemovedFromActiveServer;
          _records = app.loadRecycleBin();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _purging = false;
          _purgeError = _purgeErrorMessage(error);
          _records = app.loadRecycleBin();
        });
      }
    }
  }

  String _purgeErrorMessage(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 501 ||
          error.code == 'RECORD_PURGE_BACKEND_PENDING') {
        return context.l10n.thisServerBackendDoesNotSupport;
      }
      if (error.code == 'RECORD_PURGE_NOT_DUE') {
        final rawDeadline = error.details['restore_until'];
        final deadline = rawDeadline is String
            ? DateTime.tryParse(rawDeadline)
            : null;
        final deadlineText = deadline == null
            ? ''
            : context.l10n.restoreDeadlineFormat2(DateFormat.yMMMd().add_jm().format(deadline.toLocal()));
        return context.l10n.theServerRestorePeriodHasNot2(deadlineText);
      }
      if (error.code == 'RECORD_DELETE_CHANGED') {
        return context.l10n.thisRecordsDeletedVersionChangedThe;
      }
      if (error.code == 'RECORD_HAS_UNRESOLVED_CONFLICTS') {
        return context.l10n.resolveOrDiscardThisRecordsOutstanding;
      }
      if (error.code == 'VAULT_REDACTION_CAPABILITY_REQUIRED') {
        return context.l10n.everyActiveVaultDeviceMustSupport;
      }
    }
    return app.friendlyError(error);
  }
}

class _AutomaticPurgeConsentDialog extends StatefulWidget {
  const _AutomaticPurgeConsentDialog({required this.recordDisplayName});

  final String recordDisplayName;

  @override
  State<_AutomaticPurgeConsentDialog> createState() =>
      _AutomaticPurgeConsentDialogState();
}

class _AutomaticPurgeConsentDialogState
    extends State<_AutomaticPurgeConsentDialog> {
  static const _requiredPhrase = 'ENABLE AUTOMATIC PURGE';
  final _phraseController = TextEditingController();
  bool _acknowledged = false;

  @override
  void dispose() {
    _phraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.allowFutureAutomaticPurge),
    content: SizedBox(
      width: appDialogWidth(context, 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.thisRecordsConsentForThisExact(widget.recordDisplayName),
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.offlineDeviceCopiesAndExportsAre,
            style: TextStyle(color: context.palette.orange),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('recycle_bin_auto_purge_acknowledgement'),
            contentPadding: EdgeInsets.zero,
            value: _acknowledged,
            onChanged: (value) =>
                setState(() => _acknowledged = value ?? false),
            title: Text(
              context.l10n.iUnderstandBoundedMaintenanceMayPurge,
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('recycle_bin_auto_purge_phrase'),
            controller: _phraseController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.typeEnableAutomaticPurge,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        key: const ValueKey('recycle_bin_auto_purge_confirm'),
        onPressed: _acknowledged && _phraseController.text == _requiredPhrase
            ? () => Navigator.pop(context, true)
            : null,
        child: Text(context.l10n.recordConsent),
      ),
    ],
  );
}

class _RecycleBinRow extends StatelessWidget {
  const _RecycleBinRow({
    required this.entry,
    required this.busy,
    required this.isOwner,
    required this.canManageAutomaticPurge,
    required this.canPurge,
    required this.onRestore,
    required this.onPurge,
    required this.onAutomaticPurge,
  });

  final RecycleBinRecord entry;
  final bool busy;
  final bool isOwner;
  final bool canManageAutomaticPurge;
  final bool canPurge;
  final VoidCallback? onRestore;
  final VoidCallback? onPurge;
  final VoidCallback? onAutomaticPurge;

  @override
  Widget build(BuildContext context) {
    final expiredByClientClock =
        entry.restoreUntil != null &&
        !DateTime.now().toUtc().isBefore(entry.restoreUntil!);
    final automaticPurgeConsentText =
        context.l10n.automaticPurgeConsentValuevalue(entry.autoPurgeEnabled ? context.l10n.purgeConsentEnabled : context.l10n.purgeConsentOff);
    final restoreDeadlineSemantics = entry.restoreUntil == null
        ? context.l10n.restoreDeadlineStatusUnavailable
        : expiredByClientClock
        ? context.l10n.restoreDeadlineStatusPassed
        : context.l10n.restoreDeadlineStatusFuture(
            entry.restoreUntil!.toLocal(),
          );
    final automaticPurgeConsentLine = isOwner
        ? context.l10n.recycleBinPurgeConsentLineOwner(
            automaticPurgeConsentText,
          )
        : context.l10n.recycleBinPurgeConsentLine(automaticPurgeConsentText);
    return Semantics(
      key: ValueKey('recycle_bin_semantics-${entry.recordId}'),
      container: true,
      explicitChildNodes: true,
      label:
          context.l10n.recycleBinRecordDisplaynameIdSubstring(entry.displayName, entry.recordId.substring(0, 8), automaticPurgeConsentText, restoreDeadlineSemantics),
      child: Card(
        key: ValueKey('recycle_bin_record-${entry.recordId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconFor(entry.recordType), color: context.palette.orange),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.l10n.labelforIdSubstringDeletedFormat(_labelFor(entry.recordType), entry.recordId.substring(0, 8), DateFormat.yMMMd().add_jm().format(entry.deletedAt.toLocal())),
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      automaticPurgeConsentLine,
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 11,
                      ),
                    ),
                    if (entry.restoreUntil != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        expiredByClientClock
                            ? context.l10n.restoreDeadlinePassedAccordingToThis
                            : context.l10n.restoreDeadlineFormat3(DateFormat.yMMMd().add_jm().format(entry.restoreUntil!.toLocal())),
                        style: TextStyle(
                          color: expiredByClientClock
                              ? context.palette.orange
                              : context.palette.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    if (isOwner && entry.restoreUntil != null && !canPurge) ...[
                      const SizedBox(height: 3),
                      Text(
                        context.l10n.permanentPurgeBecomesAvailableAfterThis,
                        style: TextStyle(color: context.palette.muted, fontSize: 11),
                      ),
                    ],
                    if (isOwner && entry.restoreUntil == null) ...[
                      const SizedBox(height: 3),
                      Text(
                        context.l10n.permanentPurgeIsUnavailableBecauseThis,
                        style: TextStyle(color: context.palette.muted, fontSize: 11),
                      ),
                    ],
                    if (!entry.canRestore &&
                        entry.unavailableReason != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.unavailableReason!,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (canManageAutomaticPurge)
                    TextButton.icon(
                      key: ValueKey('recycle_bin_auto_purge-${entry.recordId}'),
                      onPressed: busy ? null : onAutomaticPurge,
                      icon: Icon(
                        entry.autoPurgeEnabled
                            ? Icons.notifications_off_outlined
                            : Icons.schedule_rounded,
                        size: 17,
                      ),
                      label: Text(
                        entry.autoPurgeEnabled
                            ? context.l10n.withdrawConsent
                            : context.l10n.allowFuturePurge,
                      ),
                    ),
                  TextButton.icon(
                    key: ValueKey('recycle_bin_restore-${entry.recordId}'),
                    onPressed: busy ? null : onRestore,
                    icon: entry.restorePending
                        ? const Icon(Icons.cloud_upload_outlined, size: 17)
                        : const Icon(Icons.restore_rounded, size: 17),
                    label: Text(
                      entry.restorePending ? context.l10n.waitingToSync : context.l10n.restore,
                    ),
                  ),
                  if (canPurge)
                    TextButton.icon(
                      key: ValueKey('recycle_bin_purge-${entry.recordId}'),
                      onPressed: busy ? null : onPurge,
                      style: TextButton.styleFrom(
                        foregroundColor: context.palette.red,
                      ),
                      icon: const Icon(Icons.delete_forever_outlined, size: 17),
                      label: Text(context.l10n.permanentlyPurge),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String type) => switch (type) {
    'host' => Icons.dns_outlined,
    'credential' => Icons.key_outlined,
    'group' => Icons.folder_outlined,
    'snippet' => Icons.code_rounded,
    'workspace' => Icons.dashboard_outlined,
    'knownHost' => Icons.verified_user_outlined,
    'shellHistory' => Icons.history_rounded,
    _ => Icons.inventory_2_outlined,
  };

  static String _labelFor(String type) => switch (type) {
    'host' => currentL10n.host,
    'credential' => currentL10n.credential,
    'group' => currentL10n.group,
    'snippet' => currentL10n.snippet2,
    'workspace' => currentL10n.workspace3,
    'preference' => currentL10n.preference,
    'knownHost' => currentL10n.knownHost,
    'shellHistory' => currentL10n.terminalHistory,
    _ => currentL10n.record,
  };
}

class _GroupsPage extends StatefulWidget {
  const _GroupsPage({required this.app});

  final AppController app;

  @override
  State<_GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<_GroupsPage> {
  AppController get app => widget.app;

  Future<void> _editGroup([GroupRecord? existing]) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) =>
          _ServerGroupEditorDialog(app: app, existing: existing),
    );
  }

  Future<void> _deleteGroup(GroupRecord group) async {
    final hostCount = app.hosts
        .where((host) => host.groupId == group.id)
        .length;
    final childCount = app.groups
        .where((candidate) => candidate.parentId == group.id)
        .length;
    final hasReferences = hostCount > 0 || childCount > 0;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteGroup4),
        content: Text(
          hasReferences
              ? context.l10n.moveOrUnassignHostcountHostS(hostCount, childCount, group.name)
              : '“${group.name}” will be deleted from this Vault and synced to its authorized devices.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('server_group_delete_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('server_group_delete_confirm'),
            onPressed: hasReferences
                ? null
                : () => Navigator.pop(context, true),
            child: Text(context.l10n.deleteGroup3),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.deleteGroup(group);
    } catch (error) {
      if (mounted) {
        _snack(context, _groupMutationError(app, error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = [...app.groups]
      ..sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    final groupsNeedingParentRepair = app.groupsNeedingParentRepair;
    final groupsNeedingParentRepairIds = {
      for (final group in groupsNeedingParentRepair) group.id,
    };
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    return SingleChildScrollView(
      padding: AppDensity.of(context).pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.hostGroups,
            subtitle: context.l10n.organizeYourHostsIntoGroups,
            trailing: FilledButton.icon(
              key: const ValueKey('server_group_create'),
              onPressed: canWrite ? () => _editGroup() : null,
              icon: const Icon(Icons.create_new_folder_outlined, size: 17),
              label: Text(context.l10n.newGroup2),
            ),
          ),
          const SizedBox(height: 20),
          if (groupsNeedingParentRepair.isNotEmpty) ...[
            Card(
              key: const ValueKey('server_group_graph_repair_warning'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.countGroupParentRelationshipSAre(groupsNeedingParentRepair.length),
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const ValueKey('server_group_graph_repair_action'),
                        onPressed: canWrite
                            ? () => _editGroup(groupsNeedingParentRepair.first)
                            : null,
                        child: Text(context.l10n.repairAGroup),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (groups.isEmpty)
            _EmptyState(
              icon: Icons.folder_copy_outlined,
              title: context.l10n.noHostGroupsYet,
              body: context.l10n.createAGroupToOrganizeRelated,
              action: canWrite
                  ? FilledButton.icon(
                      key: const ValueKey('server_group_create_empty'),
                      onPressed: () => _editGroup(),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: Text(context.l10n.createYourFirstGroup),
                    )
                  : null,
            )
          else
            ...groups.map((group) {
              final parent = groups
                  .where((candidate) => candidate.id == group.parentId)
                  .firstOrNull;
              final hostCount = app.hosts
                  .where((host) => host.groupId == group.id)
                  .length;
              final childCount = groups
                  .where((candidate) => candidate.parentId == group.id)
                  .length;
              final parentNeedsRepair = groupsNeedingParentRepairIds.contains(
                group.id,
              );
              final defaultCredential = app.credentials
                  .where(
                    (credential) => credential.id == group.defaultCredentialId,
                  )
                  .firstOrNull;
              return Card(
                child: ListTile(
                  key: ValueKey('server_group_${group.id}'),
                  leading: Icon(
                    Icons.folder_copy_outlined,
                    color: group.color == 0
                        ? context.palette.teal
                        : Color(0xFF000000 | group.color),
                  ),
                  title: Text(group.name),
                  subtitle: Text(
                    [
                      if (parentNeedsRepair)
                        context.l10n.groupParentNeedsRepair
                      else if (parent != null)
                        context.l10n.groupInsideParent(parent.name),
                      context.l10n.groupHostCount(hostCount),
                      if (childCount > 0)
                        context.l10n.groupSubgroupCount(childCount),
                      if (group.defaultCredentialId != null)
                        defaultCredential == null
                            ? context.l10n.groupDefaultCredentialUnavailable
                            : context.l10n.groupDefaultCredentialName(
                                defaultCredential.name,
                              ),
                    ].join(' · '),
                  ),
                  onTap: canWrite ? () => _editGroup(group) : null,
                  trailing: PopupMenuButton<String>(
                    popUpAnimationStyle: AppMotion.menuStyle(context),
                    key: ValueKey('server_group_actions_${group.id}'),
                    enabled: canWrite,
                    tooltip: context.l10n.groupActionsName2(group.name),
                    onSelected: (value) {
                      if (value == 'edit') unawaited(_editGroup(group));
                      if (value == 'delete') unawaited(_deleteGroup(group));
                    },
                    itemBuilder: (context) => [
                      appMenuItem(context,value: 'edit', child: Text(context.l10n.editGroup2)),
                      appMenuItem(context,
                        value: 'delete',
                        child: Text(context.l10n.deleteGroup3),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _ServerGroupEditorDialog extends StatefulWidget {
  const _ServerGroupEditorDialog({required this.app, this.existing});

  final AppController app;
  final GroupRecord? existing;

  @override
  State<_ServerGroupEditorDialog> createState() =>
      _ServerGroupEditorDialogState();
}

class _ServerGroupEditorDialogState extends State<_ServerGroupEditorDialog> {
  static const _palette = <int>[
    0,
    0x4FC3F7,
    0x4DB6AC,
    0x81C784,
    0xFFD54F,
    0xFF8A65,
    0xBA68C8,
  ];

  late final String _groupId = widget.existing?.id ?? _uuid.v4();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String? _parentId = widget.existing?.parentId;
  late String? _defaultCredentialId = widget.existing?.defaultCredentialId;
  late int _color = widget.existing?.color ?? 0;
  bool _saving = false;
  String? _error;

  AppController get app => widget.app;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final group = GroupRecord(
      id: _groupId,
      name: _name.text.trim(),
      color: _color,
      parentId: _parentId,
      defaultCredentialId: _defaultCredentialId,
      manifest: widget.existing?.manifest,
    );
    final validation = app.validateGroup(group);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.saveGroup(group);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = _groupMutationError(app, error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = {..._palette, _color}.toList()..sort();
    final groups = [...app.groups]
      ..sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    final validParents = groups
        .where(
          (group) =>
              app.canUseGroupAsParent(groupId: _groupId, parentId: group.id),
        )
        .toList(growable: false);
    final currentParentMissing =
        _parentId != null &&
        !validParents.any((group) => group.id == _parentId);
    final currentCredentialMissing =
        _defaultCredentialId != null &&
        !app.credentials.any(
          (credential) => credential.id == _defaultCredentialId,
        );
    final canEdit = app.activeVault?.canWrite == true;

    return AlertDialog(
      title: Text(
        widget.existing == null ? context.l10n.newHostGroup : context.l10n.editHostGroup,
      ),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('server_group_name'),
                controller: _name,
                enabled: !_saving,
                autofocus: true,
                maxLength: 128,
                decoration: InputDecoration(labelText: context.l10n.groupName3),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                key: const ValueKey('server_group_parent'),
                isExpanded: true,
                initialValue: _parentId,
                decoration: InputDecoration(labelText: context.l10n.parentGroup2),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(context.l10n.topLevelGroup2),
                  ),
                  ...validParents.map(
                    (group) => DropdownMenuItem<String?>(
                      value: group.id,
                      child: Text(group.name),
                    ),
                  ),
                  if (currentParentMissing)
                    DropdownMenuItem<String?>(
                      value: _parentId,
                      child: Text(
                        context.l10n.unavailableParentChooseAgain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _parentId = value;
                        _error = null;
                      }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                key: const ValueKey('server_group_color'),
                isExpanded: true,
                initialValue: _color,
                decoration: InputDecoration(labelText: context.l10n.color2),
                items: [
                  for (final color in colors)
                    DropdownMenuItem(
                      value: color,
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 10,
                            backgroundColor: color == 0
                                ? context.palette.surfaceRaised
                                : Color(0xFF000000 | color),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            color == 0
                                ? context.l10n.defaultLabel2
                                : '#${color.toRadixString(16).toUpperCase()}',
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _color = value ?? 0;
                        _error = null;
                      }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                key: const ValueKey('server_group_default_credential'),
                isExpanded: true,
                initialValue: _defaultCredentialId,
                decoration: InputDecoration(
                  labelText: context.l10n.defaultSshCredential,
                  helperText: currentCredentialMissing
                      ? context.l10n.thisGroupDefaultIsUnavailableChoose
                      : context.l10n.hostsWithoutAnOverrideInheritThe,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(context.l10n.noDefaultCredential2),
                  ),
                  if (currentCredentialMissing)
                    DropdownMenuItem<String?>(
                      value: _defaultCredentialId,
                      enabled: false,
                      child: Text(
                        context.l10n.unavailableCredential,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ...app.credentials.map(
                    (credential) => DropdownMenuItem<String?>(
                      value: credential.id,
                      child: Text(credential.name),
                    ),
                  ),
                ],
                onChanged: _saving || !canEdit
                    ? null
                    : (value) => setState(() {
                        _defaultCredentialId = value;
                        _error = null;
                      }),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      key: const ValueKey('server_group_editor_error'),
                      style: TextStyle(color: context.palette.red),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('server_group_cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          key: const ValueKey('server_group_save'),
          onPressed: _saving || !canEdit ? null : _save,
          child: Text(_saving ? context.l10n.saving : context.l10n.saveEncryptedGroup),
        ),
      ],
    );
  }
}

String _groupMutationError(AppController app, Object error) {
  if (error is FormatException) return error.message.toString();
  if (error is ApiException && error.code == 'REVISION_CONFLICT') {
    return currentL10n.thisGroupChangedOnAnotherDevice;
  }
  return currentL10n.couldNotSaveThisGroupYour;
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    this.compact = false,
    required this.canWrite,
    required this.groupName,
    required this.groupReferenceIssue,
    required this.jumpHostName,
    required this.jumpHostRouteIssue,
    required this.onConnect,
    required this.onSftp,
    required this.onScpUpload,
    required this.onScpDownload,
    required this.onEdit,
    required this.onDelete,
    required this.onFavorite,
    required this.onAttachments,
    this.onShare,
  });
  final HostRecord host;
  final bool compact;
  final bool canWrite;
  final String? groupName;
  final String? groupReferenceIssue;
  final String? jumpHostName;
  final String? jumpHostRouteIssue;
  final VoidCallback onConnect;
  final VoidCallback onSftp;
  final VoidCallback onScpUpload;
  final VoidCallback onScpDownload;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onFavorite;
  final VoidCallback onAttachments;

  /// Cloud access "Share…" (null when the server offers no sharing).
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final issue = groupReferenceIssue ?? jumpHostRouteIssue;
    final metrics = HostCardMetrics.of(context);
    return Semantics(
      container: true,
      identifier: 'ssh-host-${host.id}',
      label:
          context.l10n.hostNameUsernameEndpointValuevalue(host.name, host.username, host.endpoint, groupName == null ? '' : '; ${context.l10n.groupGroupname('$groupName')}'),
      child: GestureDetector(
        onSecondaryTapDown: (event) => unawaited(
          showWorkspaceContextMenu(context, event.globalPosition, [
            WorkspaceAction(
              'host-connect-${host.id}',
              context.l10n.connect2,
              Icons.terminal,
              onConnect,
            ),
            WorkspaceAction(
              'host-sftp-${host.id}',
              context.l10n.sftpFileManager,
              Icons.folder_open_outlined,
              onSftp,
              enabled: host.protocol == HostProtocol.ssh,
            ),
            WorkspaceAction(
              'host-scp-upload-${host.id}',
              kIsWeb ? context.l10n.scpUpload : context.l10n.scpFileManager,
              Icons.folder_open_outlined,
              onScpUpload,
              enabled: host.protocol == HostProtocol.ssh,
            ),
            if (kIsWeb)
              WorkspaceAction(
                'host-scp-download-${host.id}',
                context.l10n.scpDownload,
                Icons.download_outlined,
                onScpDownload,
                enabled: host.protocol == HostProtocol.ssh,
              ),
            WorkspaceAction(
              'host-properties-${host.id}',
              context.l10n.properties,
              Icons.info_outline,
              () => showHostProperties(context, host),
            ),
            WorkspaceAction(
              'host-edit-${host.id}',
              context.l10n.edit,
              Icons.edit_outlined,
              onEdit,
              enabled: canWrite,
            ),
            WorkspaceAction(
              'host-attachments-${host.id}',
              context.l10n.attachments,
              Icons.attach_file,
              onAttachments,
            ),
            if (onShare != null)
              WorkspaceAction(
                'host-share-${host.id}',
                context.l10n.cloudAccessShareMenu,
                Icons.ios_share,
                onShare!,
              ),
            WorkspaceAction(
              'host-delete-${host.id}',
              context.l10n.delete,
              Icons.delete_outline,
              onDelete,
              enabled: canWrite,
              destructive: true,
            ),
          ]),
        ),
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          child: InkWell(
            key: ValueKey('host_connect_${host.id}'),
            onTap: onConnect,
            child: Padding(
              padding: compact
                  ? HostCardMetrics.padding.copyWith(left: 8, right: 4)
                  : HostCardMetrics.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: _hostColor(context, host.color).withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(
                            HostCardMetrics.iconPadding,
                          ),
                          child: HostSystemIcon(
                            host: host,
                            size: metrics.glyphSize,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              host.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              strutStyle: metrics.titleTextStrut,
                              style: TextStyle(
                                fontSize: metrics.titleTextSize,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: HostCardMetrics.titleGap),
                            Text(
                              host.protocol == HostProtocol.ssh
                                  ? '${host.username}@${host.endpoint}'
                                  : '${host.protocol.label} · ${host.endpoint}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              strutStyle: metrics.subtitleTextStrut,
                              style: TextStyle(
                                color: context.palette.muted,
                                fontSize: metrics.subtitleTextSize,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canWrite)
                        IconButton(
                          tooltip: host.isFavorite
                              ? context.l10n.removeFavorite
                              : context.l10n.favorite,
                          // Standard density: compact would shave 8 px off
                          // the explicit box below.
                          visualDensity: VisualDensity.standard,
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            tapTargetSize: metrics.tapTargetSize,
                          ),
                          constraints: BoxConstraints.tightFor(
                            width: metrics.buttonExtent,
                            height: metrics.buttonExtent,
                          ),
                          onPressed: onFavorite,
                          icon: Icon(
                            host.isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 17,
                          ),
                        ),
                      WorkspaceOverflowMenu(
                        actions: [
                          WorkspaceAction(
                            'host-connect-${host.id}',
                            context.l10n.connect2,
                            Icons.terminal,
                            onConnect,
                          ),
                          WorkspaceAction(
                            'host-sftp-${host.id}',
                            context.l10n.sftpFileManager,
                            Icons.folder_open_outlined,
                            onSftp,
                            enabled: host.protocol == HostProtocol.ssh,
                          ),
                          WorkspaceAction(
                            'host-scp-upload-${host.id}',
                            kIsWeb ? context.l10n.scpUpload : context.l10n.scpFileManager,
                            Icons.folder_open_outlined,
                            onScpUpload,
                            enabled: host.protocol == HostProtocol.ssh,
                          ),
                          if (kIsWeb)
                            WorkspaceAction(
                              'host-scp-download-${host.id}',
                              context.l10n.scpDownload,
                              Icons.download_outlined,
                              onScpDownload,
                              enabled: host.protocol == HostProtocol.ssh,
                            ),
                          WorkspaceAction(
                            'host-properties-${host.id}',
                            context.l10n.properties,
                            Icons.info_outline,
                            () => showHostProperties(context, host),
                          ),
                          WorkspaceAction(
                            'host-edit-${host.id}',
                            context.l10n.edit,
                            Icons.edit_outlined,
                            onEdit,
                            enabled: canWrite,
                          ),
                          WorkspaceAction(
                            'host-attachments-${host.id}',
                            context.l10n.attachments,
                            Icons.attach_file,
                            onAttachments,
                          ),
                          if (onShare != null)
                            WorkspaceAction(
                              'host-share-${host.id}',
                              context.l10n.cloudAccessShareMenu,
                              Icons.ios_share,
                              onShare!,
                            ),
                          WorkspaceAction(
                            'host-delete-${host.id}',
                            context.l10n.delete,
                            Icons.delete_outline,
                            onDelete,
                            enabled: canWrite,
                            destructive: true,
                          ),
                        ],
                        child: SizedBox.square(
                          dimension: metrics.buttonExtent,
                          child: const Icon(Icons.more_horiz, size: 18),
                        ),
                      ),
                    ],
                  ),
                  if (!compact) ...[
                    const SizedBox(height: HostCardMetrics.metaGap),
                    SizedBox(
                      height: metrics.metaHeight,
                      child: Row(
                        children: [
                          if (groupName != null)
                            Flexible(
                              child: Semantics(
                                key: ValueKey('host-group-tag-${host.id}'),
                                identifier: 'ssh-host-group-${host.id}',
                                label: context.l10n.groupGroupname('$groupName'),
                                child: ExcludeSemantics(
                                  child: Text(
                                    groupName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    strutStyle: metrics.metaTextStrut,
                                    style: TextStyle(
                                      color: context.palette.teal,
                                      fontSize: metrics.metaTextSize,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (groupName != null && host.tags.isNotEmpty)
                            const SizedBox(width: 6),
                          if (host.tags.isNotEmpty)
                            Flexible(
                              child: Text(
                                host.tags.take(2).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                strutStyle: metrics.metaTextStrut,
                                style: TextStyle(
                                  color: context.palette.muted,
                                  fontSize: metrics.metaTextSize,
                                ),
                              ),
                            ),
                          if (groupReferenceIssue != null)
                            Semantics(
                              key: ValueKey(
                                'host-group-unavailable-${host.id}',
                              ),
                              identifier:
                                  'ssh-host-group-unavailable-${host.id}',
                              label: context.l10n.unavailableGroup,
                              child: Text(
                                context.l10n.unavailableGroup,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                strutStyle: metrics.metaTextStrut,
                                style: TextStyle(
                                  color: context.palette.orange,
                                  fontSize: metrics.metaTextSize,
                                ),
                              ),
                            ),
                          if (issue != null || jumpHostName != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Tooltip(
                                message:
                                    issue ?? context.l10n.viaJumpHostJumphostname('$jumpHostName'),
                                child: Icon(
                                  issue != null
                                      ? Icons.warning_amber_rounded
                                      : Icons.alt_route,
                                  size: HostCardMetrics.metaIconSize,
                                  color: issue != null
                                      ? context.palette.orange
                                      : context.palette.muted,
                                ),
                              ),
                            ),
                          if (host.ansibleInventoryImport?.state ==
                              AnsibleInventoryEntryState.stale)
                            Tooltip(
                              message: context.l10n.inventoryEntryStale,
                              child: Icon(
                                Icons.history,
                                size: HostCardMetrics.metaIconSize,
                                color: context.palette.orange,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cloud Home "Keychain": shared keys, certificates and passwords of the
/// active Vault. Hosts keep their direct per-host sign-in as before.
class _CredentialsPage extends StatefulWidget {
  const _CredentialsPage({required this.app});
  final AppController app;

  @override
  State<_CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<_CredentialsPage> {
  final _search = TextEditingController();

  AppController get app => widget.app;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _usedBy(BuildContext context, String id) => [
    for (final host in app.hosts)
      if (host.credentialId == id) context.l10n.quotedHostName(host.name),
    for (final group in app.groups)
      if (group.defaultCredentialId == id) context.l10n.groupName(group.name),
  ];

  @override
  Widget build(BuildContext context) {
    final canWrite = app.activeVault?.canWrite == true;
    final query = _search.text.trim().toLowerCase();
    final visible = app.credentials.where((credential) {
      if (query.isEmpty) return true;
      return credential.name.toLowerCase().contains(query) ||
          credential.username.toLowerCase().contains(query) ||
          (credential.fingerprint?.toLowerCase().contains(query) ?? false);
    }).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.r7NavKeychain,
            subtitle: context.l10n.r7NavKeychainSubtitle,
            trailing: FilledButton.icon(
              onPressed: canWrite ? () => _editCredential(context, app) : null,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.addCredential2),
            ),
          ),
          const SizedBox(height: 14),
          if (app.credentials.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                key: const ValueKey('keychain_search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: context.l10n.r7NavKeychainSearchHint,
                ),
              ),
            ),
          if (app.credentials.isEmpty)
            _EmptyState(
              icon: Icons.key_outlined,
              title: context.l10n.noCredentialsSaved,
              body: context.l10n.addAPasswordOrPrivateKey,
              action: FilledButton.icon(
                onPressed: canWrite
                    ? () => _editCredential(context, app)
                    : null,
                icon: const Icon(Icons.add),
                label: Text(context.l10n.createCredential),
              ),
            )
          else
            ...visible.map(
              (credential) => Semantics(
                container: true,
                explicitChildNodes: true,
                identifier: 'ssh-credential-${credential.id}',
                label:
                    context.l10n.credentialNameUsernameValuevalue(credential.name, credential.username, credential.kind == AuthKind.password ? context.l10n.password : context.l10n.privateKey),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 17,
                      vertical: 7,
                    ),
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: context.palette.teal.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        credential.kind == AuthKind.password
                            ? Icons.password_rounded
                            : Icons.key_rounded,
                        color: context.palette.teal,
                      ),
                    ),
                    title: Text(credential.name),
                    subtitle: _CloudKeychainDetails(
                      credential: credential,
                      usedBy: _usedBy(context, credential.id),
                    ),
                    trailing: PopupMenuButton<String>(
                      popUpAnimationStyle: AppMotion.menuStyle(context),
                      tooltip: context.l10n.credentialActionsName(credential.name),
                      enabled: canWrite,
                      onSelected: (value) async {
                        if (value == 'delete') {
                          if (await _confirmDelete(context, credential.name) ==
                              true)
                            try {
                              await app.deleteCredential(credential);
                            } catch (error) {
                              if (context.mounted) {
                                _snack(
                                  context,
                                  app.friendlyError(error),
                                  error: true,
                                );
                              }
                            }
                        } else {
                          await _editCredential(context, app, credential);
                        }
                      },
                      itemBuilder: (_) => [
                        appMenuItem(context,value: 'edit', child: Text(context.l10n.edit2)),
                        // Referenced credentials cannot be deleted (no silent
                        // relink); AppController enforces the same rule.
                        appMenuItem(context,
                          value: 'delete',
                          enabled: _usedBy(context, credential.id).isEmpty,
                          child: Text(context.l10n.delete2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CloudKeychainDetails extends StatelessWidget {
  const _CloudKeychainDetails({required this.credential, required this.usedBy});

  final CredentialRecord credential;
  final List<String> usedBy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cert = tryParseCertificate(credential.certificate);
    final muted = TextStyle(color: context.palette.muted, fontSize: 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${credential.username} · ${credential.kind == AuthKind.password ? l10n.credentialPasswordStoredEncrypted : cert != null ? l10n.r7NavKindKeyWithCertificate : l10n.credentialPrivateKeyStoredEncrypted}',
          style: TextStyle(color: context.palette.muted),
        ),
        if (credential.fingerprint != null)
          Text(
            credential.fingerprint!,
            style: muted.copyWith(fontFamily: 'monospace', fontSize: 11),
          ),
        if (cert != null)
          Text(
            [
              if (cert.keyId.isNotEmpty) 'ID ${cert.keyId}',
              cert.principals.isEmpty
                  ? l10n.r7NavCertAnyPrincipal
                  : l10n.r7NavCertPrincipals(cert.principals.join(', ')),
              certificateValidityLabel(l10n, cert),
            ].join(' · '),
            style: muted.copyWith(
              color: cert.isValidAt(DateTime.now())
                  ? context.palette.muted
                  : context.palette.orange,
            ),
          ),
        Text(
          usedBy.isEmpty
              ? l10n.r7NavNotUsed
              : l10n.r7NavUsedBy(usedBy.length, usedBy.take(3).join(', ')),
          style: muted,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

Future<void> _editCredential(
  BuildContext context,
  AppController app, [
  CredentialRecord? existing,
]) async {
  final result = await showAppDialog<CredentialRecord>(
    context: context,
    builder: (_) => _CredentialEditorDialog(existing: existing),
  );
  if (result == null) return;
  try {
    await app.saveCredential(result);
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

class _CredentialEditorDialog extends StatefulWidget {
  const _CredentialEditorDialog({this.existing});

  final CredentialRecord? existing;

  @override
  State<_CredentialEditorDialog> createState() =>
      _CredentialEditorDialogState();
}

class _CredentialEditorDialogState extends State<_CredentialEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _secret;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late final TextEditingController _certificate;
  late AuthKind _kind;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _certificate = TextEditingController(text: existing?.certificate ?? '');
    _name = TextEditingController(text: existing?.name ?? '');
    _username = TextEditingController(text: existing?.username ?? '');
    _secret = TextEditingController(text: existing?.secret ?? '');
    _privateKey = TextEditingController(text: existing?.privateKey ?? '');
    _passphrase = TextEditingController(text: existing?.passphrase ?? '');
    _kind = existing?.kind ?? AuthKind.password;
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _secret.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _certificate.dispose();
    super.dispose();
  }

  CredentialRecord? _buildCredential() {
    KeychainKeyCheck? check;
    if (_kind == AuthKind.privateKey) {
      check = checkKeychainKey(
        privateKey: _privateKey.text,
        passphrase: _passphrase.text,
        certificateText: _certificate.text,
      );
      if (check.error != null) {
        setState(() => _error = check!.error);
        return null;
      }
    }
    return CredentialRecord(
      id: widget.existing?.id ?? _uuid.v4(),
      name: _name.text.trim(),
      username: _username.text.trim(),
      kind: _kind,
      secret: _kind == AuthKind.password ? _secret.text : null,
      privateKey: _kind == AuthKind.privateKey ? _privateKey.text : null,
      passphrase: _kind == AuthKind.privateKey ? _passphrase.text : null,
      fingerprint: check?.fingerprint,
      certificate: check?.certificate,
      manifest: widget.existing?.manifest,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? context.l10n.newSshCredential : context.l10n.editCredential2,
    ),
    content: SizedBox(
      width: 510,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: context.l10n.credentialName2),
            ),
            const SizedBox(height: 11),
            TextField(
              controller: _username,
              decoration: InputDecoration(labelText: context.l10n.sshUsername),
            ),
            const SizedBox(height: 11),
            SegmentedButton<AuthKind>(
              segments: [
                ButtonSegment(
                  value: AuthKind.password,
                  label: Text(context.l10n.password),
                  icon: const Icon(Icons.password_outlined),
                ),
                ButtonSegment(
                  value: AuthKind.privateKey,
                  label: Text(context.l10n.privateKey),
                  icon: const Icon(Icons.key_outlined),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (values) =>
                  setState(() => _kind = values.first),
            ),
            const SizedBox(height: 12),
            if (_kind == AuthKind.password)
              TextField(
                key: const ValueKey('ssh-credential-password'),
                controller: _secret,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.l10n.password,
                  prefixIcon: const Icon(Icons.lock_outline),
                ),
              )
            else ...[
              TextField(
                key: const ValueKey('ssh-credential-private-key'),
                controller: _privateKey,
                minLines: 4,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                decoration: InputDecoration(
                  labelText: context.l10n.pemPrivateKey,
                  alignLabelWithHint: true,
                  prefixIcon: const Icon(Icons.key_rounded),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: KeychainKeyFileButton(
                  onLoaded: (text) => setState(() {
                    _privateKey.text = text;
                    _error = null;
                  }),
                  onError: (message) => setState(() => _error = message),
                ),
              ),
              TextField(
                controller: _passphrase,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.l10n.keyPassphraseOptional,
                ),
              ),
              const SizedBox(height: 10),
              KeychainCertificateField(controller: _certificate),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('ssh-credential-error'),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            const SizedBox(height: 9),
            Text(
              context.l10n.thisFormNeverSubmitsCredentialText,
              style: TextStyle(color: context.palette.teal, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        onPressed: () {
          final credential = _buildCredential();
          if (credential != null) Navigator.pop(context, credential);
        },
        child: Text(context.l10n.saveEncryptedCredential2),
      ),
    ],
  );
}

class _SnippetsPage extends StatelessWidget {
  const _SnippetsPage({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final canWrite = app.activeVault?.canWrite == true;
    return SingleChildScrollView(
      padding: AppDensity.of(context).pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.commandSnippets,
            subtitle: context.l10n.keepRepeatableCommandsInTheSame,
            trailing: FilledButton.icon(
              onPressed: canWrite ? () => _editSnippet(context, app) : null,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.newSnippet),
            ),
          ),
          const SizedBox(height: 20),
          if (app.snippets.isEmpty)
            _EmptyState(
              icon: Icons.code_rounded,
              title: context.l10n.noSnippetsYet2,
              body: context.l10n.previewStructuredCommandsOrReviewAnd,
              action: FilledButton.icon(
                onPressed: canWrite ? () => _editSnippet(context, app) : null,
                icon: const Icon(Icons.add),
                label: Text(context.l10n.createSnippet),
              ),
            )
          else
            ...app.snippets.map(
              (snippet) => Semantics(
                container: true,
                explicitChildNodes: true,
                label: context.l10n.snippetTitle3(snippet.title),
                child: Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(17, 15, 12, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.code_rounded,
                              color: context.palette.lime,
                              size: 18,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                snippet.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            _Tag(label: snippet.shell),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: context.l10n.edit2,
                              onPressed: canWrite
                                  ? () => _editSnippet(context, app, snippet)
                                  : null,
                              icon: Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: context.palette.muted,
                              ),
                            ),
                            IconButton(
                              tooltip: context.l10n.delete2,
                              onPressed: !canWrite
                                  ? null
                                  : () async {
                                      if (await _confirmDelete(
                                            context,
                                            snippet.title,
                                          ) ==
                                          true)
                                        await app.deleteSnippet(snippet);
                                    },
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: context.palette.muted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: context.palette.codeBackground,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: context.palette.line),
                          ),
                          child: SelectableText(
                            snippet.executionMode == SnippetExecutionMode.script
                                ? snippet.body
                                : '${snippet.program} · ${snippet.arguments.length} arguments · ${snippet.parameters.length} parameters',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.55,
                              color: context.palette.codeText,
                            ),
                          ),
                        ),
                        const SizedBox(height: 9),
                        Row(
                          children: [
                            for (final tag in snippet.tags)
                              Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: _Tag(label: tag),
                              ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed:
                                  snippet.executionMode ==
                                      SnippetExecutionMode.script
                                  ? () => Clipboard.setData(
                                      ClipboardData(text: snippet.body),
                                    )
                                  : null,
                              icon: const Icon(Icons.copy, size: 15),
                              label: Text(context.l10n.copy),
                            ),
                            const SizedBox(width: 7),
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  _runSnippet(context, app, snippet),
                              icon: const Icon(
                                Icons.visibility_outlined,
                                size: 17,
                              ),
                              label: Text(context.l10n.reviewAndRun),
                            ),
                          ],
                        ),
                        if (snippet.executionMode ==
                                SnippetExecutionMode.bashCommand &&
                            _availableSnippetTargets(app).length > 1) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton.icon(
                              key: ValueKey('snippet-batch-run-${snippet.id}'),
                              onPressed: () =>
                                  _runSnippetBatch(context, app, snippet),
                              icon: const Icon(Icons.dns_outlined, size: 16),
                              label: Text(
                                context.l10n.reviewOnCountConnectedHosts(_availableSnippetTargets(app).length),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SavedWorkspacesPage extends StatelessWidget {
  const _SavedWorkspacesPage({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final canWrite = app.activeVault?.canWrite == true;
    final canSaveCurrent = app.terminalTabs.isNotEmpty;
    final canCreateSplit = canWrite && app.hosts.length >= 2;
    return SingleChildScrollView(
      padding: AppDensity.of(context).pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.savedWorkspaces,
            subtitle:
                context.l10n.namedTerminalLayoutsSyncEncryptedIncluding,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('workspace-save-current'),
                  onPressed: canWrite && canSaveCurrent
                      ? () => _saveCurrentWorkspace(context, app)
                      : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(context.l10n.saveCurrentTabs),
                ),
                FilledButton.icon(
                  key: const ValueKey('workspace-create-split'),
                  onPressed: canCreateSplit
                      ? () => _createSplitWorkspace(context, app)
                      : null,
                  icon: const Icon(Icons.splitscreen_rounded),
                  label: Text(context.l10n.createSplitWorkspace),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.palette.teal.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.palette.teal.withValues(alpha: .25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 17,
                  color: context.palette.teal,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    context.l10n.onlyTheHostIdTabOrder,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (app.savedWorkspaces.isEmpty)
            _EmptyState(
              icon: Icons.view_quilt_outlined,
              title: context.l10n.noSavedWorkspaces,
              body: canSaveCurrent
                  ? context.l10n.saveTheCurrentTerminalTabsTo
                  : context.l10n.openOneOrMoreTabsOn,
              action: canSaveCurrent
                  ? FilledButton.icon(
                      onPressed: canWrite
                          ? () => _saveCurrentWorkspace(context, app)
                          : null,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: Text(context.l10n.saveCurrentTabs),
                    )
                  : OutlinedButton.icon(
                      onPressed: () =>
                          app.showWorkspacePage(WorkspacePage.terminal),
                      icon: const Icon(Icons.terminal_rounded),
                      label: Text(context.l10n.openTerminal),
                    ),
            )
          else
            ...app.savedWorkspaces.map(
              (workspace) => _SavedWorkspaceCard(
                app: app,
                workspace: workspace,
                canWrite: canWrite,
              ),
            ),
        ],
      ),
    );
  }
}

class _SavedWorkspaceCard extends StatelessWidget {
  const _SavedWorkspaceCard({
    required this.app,
    required this.workspace,
    required this.canWrite,
  });

  final AppController app;
  final WorkspaceRecord workspace;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    final isSplit = workspace.isSplit;
    final ratio = workspace.splitRatioBasisPoints ?? 5000;
    final firstPercent = ratio ~/ 100;
    final secondPercent = 100 - firstPercent;
    final missingCount = workspace.hostIds
        .where((id) => !app.hosts.any((host) => host.id == id))
        .length;
    return Card(
      key: ValueKey('saved-workspace-${workspace.id}'),
      margin: const EdgeInsets.only(bottom: 11),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 15, 13, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.view_quilt_outlined,
                  size: 19,
                  color: context.palette.lime,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    workspace.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _Tag(
                  label: isSplit
                      ? context.l10n.splitFirstpercentSecondpercent(firstPercent, secondPercent)
                      : context.l10n.countTabs(workspace.panes.length),
                ),
                if (isSplit)
                  _Tag(
                    label: workspace.splitAxis == WorkspaceSplitAxis.horizontal
                        ? context.l10n.sideBySide
                        : context.l10n.stacked,
                  ),
                if (isSplit) ...[
                  const SizedBox(width: 6),
                  _Tag(label: context.l10n.activePaneValuevalue(workspace.activeIndex + 1)),
                ],
                if (missingCount > 0) ...[
                  const SizedBox(width: 7),
                  _Tag(label: context.l10n.missingcountMissing(missingCount)),
                ],
                PopupMenuButton<String>(
                  popUpAnimationStyle: AppMotion.menuStyle(context),
                  tooltip: context.l10n.workspaceActions,
                  onSelected: (action) =>
                      _runWorkspaceAction(context, app, workspace, action),
                  itemBuilder: (context) => [
                    appMenuItem(context,value: 'rename', child: Text(context.l10n.rename)),
                    appMenuItem(context,
                      value: 'duplicate',
                      child: Text(context.l10n.duplicate),
                    ),
                    appMenuItem(context,value: 'delete', child: Text(context.l10n.delete2)),
                  ],
                ),
              ],
            ),
            if (workspace.layoutTree case final tree?) ...[
              const SizedBox(height: 6),
              Wrap(
                key: ValueKey('workspace-topology-${workspace.id}'),
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final (index, label) in _workspaceSplitDescriptions(
                    tree,
                  ).indexed)
                    Container(
                      key: ValueKey(
                        'workspace-topology-${workspace.id}-split-$index',
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: context.palette.line),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.palette.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            for (final (index, pane) in workspace.panes.indexed)
              _WorkspacePaneSummary(
                app: app,
                workspace: workspace,
                pane: pane,
                index: index,
                canWrite: canWrite,
              ),
            const SizedBox(height: 9),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                key: ValueKey('workspace-preview-${workspace.id}'),
                onPressed: () => app.stageWorkspace(workspace.id),
                icon: const Icon(Icons.preview_outlined, size: 17),
                label: Text(context.l10n.previewDisconnectedLayout),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _workspaceSplitDescriptions(WorkspaceLayoutNode tree) {
  final descriptions = <String>[];
  void visit(WorkspaceLayoutNode node) {
    if (node is WorkspaceTerminalNode) return;
    final split = node as WorkspaceSplitNode;
    final axis = split.axis == WorkspaceSplitAxis.horizontal
        ? currentL10n.splitAxisSideBySide
        : currentL10n.splitAxisStacked;
    final firstPercent = split.splitRatioBasisPoints ~/ 100;
    descriptions.add(
      currentL10n.splitValuevalueAxisFirstpercentValuevalue2(descriptions.length + 1, axis, firstPercent, 100 - firstPercent),
    );
    visit(split.first);
    visit(split.second);
  }

  visit(tree);
  return descriptions;
}

class _WorkspacePaneSummary extends StatelessWidget {
  const _WorkspacePaneSummary({
    required this.app,
    required this.workspace,
    required this.pane,
    required this.index,
    required this.canWrite,
  });

  final AppController app;
  final WorkspaceRecord workspace;
  final WorkspacePane pane;
  final int index;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    final host = app.hosts.where((item) => item.id == pane.hostId).firstOrNull;
    final missing = host == null;
    final paneLabel = workspace.isSplit
        ? context.l10n.paneValuevalue(index + 1)
        : context.l10n.tabValuevalue(index + 1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            missing ? Icons.link_off_rounded : Icons.dns_outlined,
            size: 16,
            color: missing ? context.palette.orange : context.palette.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              missing
                  ? '$paneLabel · Missing Host · ${_shortAuditId(pane.hostId)}'
                  : '$paneLabel · ${host.name} · ${host.endpoint}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: missing ? context.palette.orange : context.palette.text,
              ),
            ),
          ),
          if (missing)
            TextButton(
              key: ValueKey('workspace-repair-${workspace.id}-${pane.paneId}'),
              onPressed: canWrite && app.hosts.isNotEmpty
                  ? () => _repairWorkspacePane(context, app, workspace, pane)
                  : null,
              child: Text(context.l10n.replaceHost),
            )
          else if (index == workspace.activeIndex)
            _Tag(label: context.l10n.activePane2),
        ],
      ),
    );
  }
}

Future<void> _createSplitWorkspace(
  BuildContext context,
  AppController app,
) async {
  final vaultId = app.activeVault?.id;
  if (vaultId == null ||
      app.activeVault?.canWrite != true ||
      app.hosts.length < 2) {
    return;
  }
  final draft = await showAppDialog<_SplitWorkspaceDraft>(
    context: context,
    builder: (_) => _CreateSplitWorkspaceDialog(
      hosts: List<HostRecord>.unmodifiable(app.hosts),
    ),
  );
  if (draft == null || !context.mounted) return;
  if (app.activeVault?.id != vaultId ||
      app.activeVault?.canWrite != true ||
      _workspaceDraftHostIds(draft.layoutTree)
          .any((id) => !app.hosts.any((host) => host.id == id))) {
    _snack(
      context,
      context.l10n.theVaultOrOneOfThe,
      error: true,
    );
    return;
  }
  try {
    await app.saveWorkspaceLayout(
      name: draft.name,
      layoutTree: _workspaceDraftToLayoutNode(draft.layoutTree),
      activePaneId: draft.activePaneId,
    );
    if (context.mounted) {
      _snack(context, context.l10n.splitWorkspaceSavedEncryptedToThis);
    }
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

class _SplitWorkspaceDraft {
  const _SplitWorkspaceDraft({
    required this.name,
    required this.layoutTree,
    required this.activePaneId,
  });

  final String name;
  final _WorkspaceDraftNode layoutTree;
  final String activePaneId;
}

sealed class _WorkspaceDraftNode {
  const _WorkspaceDraftNode();
}

class _WorkspaceDraftTerminal extends _WorkspaceDraftNode {
  const _WorkspaceDraftTerminal({required this.paneId, required this.hostId});

  final String paneId;
  final String hostId;
}

class _WorkspaceDraftSplit extends _WorkspaceDraftNode {
  const _WorkspaceDraftSplit({
    required this.id,
    required this.axis,
    required this.ratioBasisPoints,
    required this.first,
    required this.second,
  });

  final String id;
  final WorkspaceSplitAxis axis;
  final int ratioBasisPoints;
  final _WorkspaceDraftNode first;
  final _WorkspaceDraftNode second;

  _WorkspaceDraftSplit copyWith({
    WorkspaceSplitAxis? axis,
    int? ratioBasisPoints,
    _WorkspaceDraftNode? first,
    _WorkspaceDraftNode? second,
  }) => _WorkspaceDraftSplit(
    id: id,
    axis: axis ?? this.axis,
    ratioBasisPoints: ratioBasisPoints ?? this.ratioBasisPoints,
    first: first ?? this.first,
    second: second ?? this.second,
  );
}

List<_WorkspaceDraftTerminal> _workspaceDraftTerminals(
  _WorkspaceDraftNode node,
) => switch (node) {
  _WorkspaceDraftTerminal() => [node],
  _WorkspaceDraftSplit() => [
    ..._workspaceDraftTerminals(node.first),
    ..._workspaceDraftTerminals(node.second),
  ],
};

List<_WorkspaceDraftSplit> _workspaceDraftSplits(_WorkspaceDraftNode node) =>
    switch (node) {
      _WorkspaceDraftTerminal() => const [],
      _WorkspaceDraftSplit() => [
        node,
        ..._workspaceDraftSplits(node.first),
        ..._workspaceDraftSplits(node.second),
      ],
    };

List<String> _workspaceDraftHostIds(_WorkspaceDraftNode node) =>
    _workspaceDraftTerminals(node).map((pane) => pane.hostId).toList();

WorkspaceLayoutNode _workspaceDraftToLayoutNode(_WorkspaceDraftNode node) =>
    switch (node) {
      _WorkspaceDraftTerminal() => WorkspaceTerminalNode(
        paneId: node.paneId,
        hostId: node.hostId,
      ),
      _WorkspaceDraftSplit() => WorkspaceSplitNode(
        axis: node.axis,
        splitRatioBasisPoints: node.ratioBasisPoints,
        first: _workspaceDraftToLayoutNode(node.first),
        second: _workspaceDraftToLayoutNode(node.second),
      ),
    };

_WorkspaceDraftNode _replaceWorkspaceDraftLeaf(
  _WorkspaceDraftNode node,
  String paneId,
  _WorkspaceDraftNode Function(_WorkspaceDraftTerminal leaf) replace,
) {
  if (node is _WorkspaceDraftTerminal) {
    return node.paneId == paneId ? replace(node) : node;
  }
  final split = node as _WorkspaceDraftSplit;
  final first = _replaceWorkspaceDraftLeaf(split.first, paneId, replace);
  if (!identical(first, split.first)) return split.copyWith(first: first);
  final second = _replaceWorkspaceDraftLeaf(split.second, paneId, replace);
  if (!identical(second, split.second)) return split.copyWith(second: second);
  return split;
}

_WorkspaceDraftNode? _removeWorkspaceDraftLeaf(
  _WorkspaceDraftNode node,
  String paneId,
) {
  if (node is _WorkspaceDraftTerminal) {
    return node.paneId == paneId ? null : node;
  }
  final split = node as _WorkspaceDraftSplit;
  if (split.first case final _WorkspaceDraftTerminal first
      when first.paneId == paneId) {
    return split.second;
  }
  if (split.second case final _WorkspaceDraftTerminal second
      when second.paneId == paneId) {
    return split.first;
  }
  final first = _removeWorkspaceDraftLeaf(split.first, paneId);
  final second = _removeWorkspaceDraftLeaf(split.second, paneId);
  if (first == null) return second;
  if (second == null) return first;
  return split.copyWith(first: first, second: second);
}

_WorkspaceDraftNode _updateWorkspaceDraftSplit(
  _WorkspaceDraftNode node,
  String splitId,
  _WorkspaceDraftSplit Function(_WorkspaceDraftSplit split) update,
) {
  if (node is _WorkspaceDraftTerminal) return node;
  final split = node as _WorkspaceDraftSplit;
  if (split.id == splitId) return update(split);
  return split.copyWith(
    first: _updateWorkspaceDraftSplit(split.first, splitId, update),
    second: _updateWorkspaceDraftSplit(split.second, splitId, update),
  );
}

class _CreateSplitWorkspaceDialog extends StatefulWidget {
  const _CreateSplitWorkspaceDialog({required this.hosts});

  final List<HostRecord> hosts;

  @override
  State<_CreateSplitWorkspaceDialog> createState() =>
      _CreateSplitWorkspaceDialogState();
}

class _CreateSplitWorkspaceDialogState
    extends State<_CreateSplitWorkspaceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late _WorkspaceDraftNode _layoutTree;
  late String _selectedPaneId;
  late String _activePaneId;
  WorkspaceSplitAxis _newSplitAxis = WorkspaceSplitAxis.horizontal;
  int _newSplitPercent = 50;

  HostRecord? _selectedHost(String? id) =>
      widget.hosts.where((host) => host.id == id).firstOrNull;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    final first = _WorkspaceDraftTerminal(
      paneId: _uuid.v4(),
      hostId: widget.hosts.first.id,
    );
    final second = _WorkspaceDraftTerminal(
      paneId: _uuid.v4(),
      hostId: widget.hosts[1].id,
    );
    final root = _WorkspaceDraftSplit(
      id: _uuid.v4(),
      axis: WorkspaceSplitAxis.horizontal,
      ratioBasisPoints: 5000,
      first: first,
      second: second,
    );
    _layoutTree = root;
    _selectedPaneId = first.paneId;
    _activePaneId = first.paneId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _addPane() {
    final leaves = _workspaceDraftTerminals(_layoutTree);
    if (leaves.length >= maxWorkspacePanes) return;
    final selected = leaves
        .where((leaf) => leaf.paneId == _selectedPaneId)
        .firstOrNull;
    if (selected == null) return;
    final availableHosts = widget.hosts;
    if (availableHosts.isEmpty) return;
    final selectedHostIndex = availableHosts.indexWhere(
      (host) => host.id == selected.hostId,
    );
    final nextHost =
        availableHosts[(selectedHostIndex + 1) % availableHosts.length];
    final added = _WorkspaceDraftTerminal(
      paneId: _uuid.v4(),
      hostId: nextHost.id,
    );
    final split = _WorkspaceDraftSplit(
      id: _uuid.v4(),
      axis: _newSplitAxis,
      ratioBasisPoints: _newSplitPercent * 100,
      first: selected,
      second: added,
    );
    final replaced = _replaceWorkspaceDraftLeaf(
      _layoutTree,
      selected.paneId,
      (_) => split,
    );
    setState(() {
      _layoutTree = replaced;
      _selectedPaneId = added.paneId;
    });
  }

  void _removePane(String paneId) {
    final leaves = _workspaceDraftTerminals(_layoutTree);
    if (leaves.length <= 2) return;
    final updated = _removeWorkspaceDraftLeaf(_layoutTree, paneId);
    if (updated == null) return;
    final remaining = _workspaceDraftTerminals(updated);
    setState(() {
      _layoutTree = updated;
      if (paneId == _selectedPaneId) _selectedPaneId = remaining.first.paneId;
      if (paneId == _activePaneId) _activePaneId = remaining.first.paneId;
    });
  }

  void _changePaneHost(String paneId, String? hostId) {
    if (hostId == null) return;
    final updated = _replaceWorkspaceDraftLeaf(
      _layoutTree,
      paneId,
      (leaf) => _WorkspaceDraftTerminal(paneId: leaf.paneId, hostId: hostId),
    );
    setState(() => _layoutTree = updated);
  }

  void _changeSplitAxis(String splitId, WorkspaceSplitAxis? axis) {
    if (axis == null) return;
    setState(() {
      _layoutTree = _updateWorkspaceDraftSplit(
        _layoutTree,
        splitId,
        (split) => split.copyWith(axis: axis),
      );
    });
  }

  void _changeSplitRatio(String splitId, String? value) {
    final percent = int.tryParse(value?.trim() ?? '');
    if (percent == null || percent < 25 || percent > 75) return;
    setState(() {
      _layoutTree = _updateWorkspaceDraftSplit(
        _layoutTree,
        splitId,
        (split) => split.copyWith(ratioBasisPoints: percent * 100),
      );
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final leaves = _workspaceDraftTerminals(_layoutTree);
    if (leaves.length < 2 ||
        leaves.length > maxWorkspacePanes ||
        !leaves.any((leaf) => leaf.paneId == _activePaneId)) {
      return;
    }
    Navigator.of(context).pop(
      _SplitWorkspaceDraft(
        name: _nameController.text.trim(),
        layoutTree: _layoutTree,
        activePaneId: _activePaneId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final leaves = _workspaceDraftTerminals(_layoutTree);
    final splits = _workspaceDraftSplits(_layoutTree);
    final canAddPane = leaves.length < maxWorkspacePanes;
    final previewNode = _layoutTree;
    return AlertDialog(
      title: Text(context.l10n.createSplitWorkspace),
      content: SizedBox(
        width: appDialogWidth(context, 690),
        child: Form(
          key: _formKey,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const ValueKey('workspace-split-name'),
                    controller: _nameController,
                    autofocus: true,
                    maxLength: 256,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: context.l10n.workspaceName,
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? context.l10n.enterAWorkspaceName
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.l10n.terminalPanesCountMaxworkspacepanes(leaves.length, maxWorkspacePanes),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  for (final (index, pane) in leaves.indexed) ...[
                    Container(
                      key: ValueKey('workspace-split-pane-${pane.paneId}'),
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.fromLTRB(8, 3, 5, 3),
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _selectedPaneId == pane.paneId
                              ? context.palette.teal
                              : context.palette.line,
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 94,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextButton.icon(
                                  key: ValueKey(
                                    'workspace-split-target-pane-$index',
                                  ),
                                  onPressed: () => setState(
                                    () => _selectedPaneId = pane.paneId,
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 30),
                                    alignment: Alignment.centerLeft,
                                  ),
                                  icon: Icon(
                                    _selectedPaneId == pane.paneId
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    size: 15,
                                  ),
                                  label: Text(context.l10n.paneValuevalue(index + 1)),
                                ),
                                if (_activePaneId == pane.paneId)
                                  Text(
                                    context.l10n.activePane,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: context.palette.teal,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey(
                                'workspace-split-host-${pane.paneId}',
                              ),
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                  index == 0
                                      ? 'workspace-split-first-host'
                                      : index == 1
                                      ? 'workspace-split-second-host'
                                      : 'workspace-tree-host-field-$index',
                                ),
                                initialValue: pane.hostId,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: context.l10n.hostPaneValuevalue(index + 1),
                                  isDense: true,
                                ),
                                items: widget.hosts
                                    .map(
                                      (host) => DropdownMenuItem(
                                        value: host.id,
                                        child: Text(
                                          '${host.name} · ${host.endpoint}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) =>
                                    _changePaneHost(pane.paneId, value),
                                validator: (value) => value == null
                                    ? context.l10n.chooseAHostForPaneValuevalue(index + 1)
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          IconButton(
                            key: ValueKey('workspace-tree-remove-pane-$index'),
                            tooltip: leaves.length <= 2
                                ? context.l10n.aSplitWorkspaceNeedsAtLeast
                                : context.l10n.removePaneValuevalue(index + 1),
                            onPressed: leaves.length <= 2
                                ? null
                                : () => _removePane(pane.paneId),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('workspace-split-active-pane'),
                          initialValue: _activePaneId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: context.l10n.activePane,
                            isDense: true,
                          ),
                          items: [
                            for (final (index, pane) in leaves.indexed)
                              DropdownMenuItem(
                                value: pane.paneId,
                                child: Text(
                                  context.l10n.paneValuevalueValuevalue2(index + 1, _selectedHost(pane.hostId)?.name ?? context.l10n.missingHost),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _activePaneId = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 13),
                  Row(
                    children: [
                      Icon(
                        Icons.call_split_rounded,
                        size: 16,
                        color: context.palette.muted,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          context.l10n.splitControlsCountDividersEachRatio(splits.length),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.palette.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  for (final (index, split) in splits.indexed)
                    Container(
                      key: ValueKey('workspace-split-editor-${split.id}'),
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                      margin: const EdgeInsets.only(top: 5),
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        border: Border.all(color: context.palette.line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 72,
                            child: Text(
                              context.l10n.splitValuevalue(index + 1),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey(
                                'workspace-split-axis-editor-${split.id}',
                              ),
                              child:
                                  DropdownButtonFormField<WorkspaceSplitAxis>(
                                    key: ValueKey(
                                      index == 0
                                          ? 'workspace-split-axis'
                                          : 'workspace-split-axis-${split.id}',
                                    ),
                                    initialValue: split.axis,
                                    isExpanded: true,
                                    decoration: InputDecoration(
                                      labelText: context.l10n.direction,
                                      isDense: true,
                                    ),
                                    items: [
                                      DropdownMenuItem(
                                        value: WorkspaceSplitAxis.horizontal,
                                        child: Text(
                                          context.l10n.sideBySideLeftRight,
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: WorkspaceSplitAxis.vertical,
                                        child: Text(context.l10n.stackedTopBottom),
                                      ),
                                    ],
                                    onChanged: (axis) =>
                                        _changeSplitAxis(split.id, axis),
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 145,
                            child: KeyedSubtree(
                              key: ValueKey(
                                'workspace-split-ratio-editor-${split.id}',
                              ),
                              child: TextFormField(
                                key: ValueKey(
                                  index == 0
                                      ? 'workspace-split-ratio'
                                      : 'workspace-split-ratio-${split.id}',
                                ),
                                initialValue:
                                    '${split.ratioBasisPoints ~/ 100}',
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: InputDecoration(
                                  labelText: context.l10n.firstChild,
                                  helperText: '25–75%',
                                  suffixText: '%',
                                  isDense: true,
                                ),
                                onChanged: (value) =>
                                    _changeSplitRatio(split.id, value),
                                validator: (value) {
                                  final percent = int.tryParse(
                                    value?.trim() ?? '',
                                  );
                                  if (percent == null) {
                                    return context.l10n.enterAWholeNumberPercent;
                                  }
                                  if (percent < 25 || percent > 75) {
                                    return context.l10n.choose2575;
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<WorkspaceSplitAxis>(
                        key: const ValueKey('workspace-split-new-axis'),
                        value: _newSplitAxis,
                        onChanged: (axis) {
                          if (axis != null)
                            setState(() => _newSplitAxis = axis);
                        },
                        items: [
                          DropdownMenuItem(
                            value: WorkspaceSplitAxis.horizontal,
                            child: Text(context.l10n.newSplitSideBySide),
                          ),
                          DropdownMenuItem(
                            value: WorkspaceSplitAxis.vertical,
                            child: Text(context.l10n.newSplitStacked),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: 112,
                        child: TextFormField(
                          key: const ValueKey('workspace-split-new-ratio'),
                          initialValue: '50',
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: context.l10n.newFirstChild,
                            suffixText: '%',
                            isDense: true,
                          ),
                          onChanged: (value) {
                            final percent = int.tryParse(value);
                            if (percent != null &&
                                percent >= 25 &&
                                percent <= 75) {
                              _newSplitPercent = percent;
                            }
                          },
                          validator: (value) {
                            final percent = int.tryParse(value?.trim() ?? '');
                            if (percent == null ||
                                percent < 25 ||
                                percent > 75) {
                              return context.l10n.choose2575;
                            }
                            return null;
                          },
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('workspace-split-add-pane'),
                        onPressed: canAddPane ? _addPane : null,
                        icon: const Icon(Icons.call_split_rounded, size: 16),
                        label: Text(context.l10n.splitSelectedPane),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 16,
                        color: context.palette.muted,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        context.l10n.disconnectedRecursivePreview,
                        style: TextStyle(fontSize: 11, color: context.palette.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  SizedBox(
                    height: 230,
                    child: _WorkspaceDraftTreePreview(
                      key: const ValueKey('workspace-split-draft-preview'),
                      node: previewNode,
                      hosts: widget.hosts,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    context.l10n.savingAndPreviewingDoNotConnect,
                    style: TextStyle(fontSize: 11, color: context.palette.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton.icon(
          key: const ValueKey('workspace-split-save'),
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(context.l10n.saveSplitWorkspace),
        ),
      ],
    );
  }
}

class _SplitPreviewHostCard extends StatelessWidget {
  const _SplitPreviewHostCard({required this.title, required this.host});

  final String title;
  final HostRecord? host;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: context.palette.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: context.palette.line),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: context.palette.teal,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          host?.name ?? context.l10n.chooseAHost,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        if (host != null)
          Text(
            host!.endpoint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: context.palette.muted),
          ),
      ],
    ),
  );
}

class _WorkspaceDraftTreePreview extends StatelessWidget {
  const _WorkspaceDraftTreePreview({
    required this.node,
    required this.hosts,
    super.key,
  });

  final _WorkspaceDraftNode node;
  final List<HostRecord> hosts;

  @override
  Widget build(BuildContext context) {
    final leaves = _workspaceDraftTerminals(node);
    final rootSplit = node is _WorkspaceDraftSplit
        ? node as _WorkspaceDraftSplit
        : null;
    final singleSplit =
        rootSplit != null &&
        leaves.length == 2 &&
        rootSplit.first is _WorkspaceDraftTerminal &&
        rootSplit.second is _WorkspaceDraftTerminal;
    final rootRatio = rootSplit?.ratioBasisPoints ?? 5000;
    var splitIndex = 0;
    Widget buildNode(_WorkspaceDraftNode current) {
      if (current is _WorkspaceDraftTerminal) {
        final index = leaves.indexWhere(
          (leaf) => leaf.paneId == current.paneId,
        );
        final host = hosts
            .where((item) => item.id == current.hostId)
            .firstOrNull;
        final title = singleSplit
            ? context.l10n.paneValuevalueValuevalue22(index + 1, index == 0 ? rootRatio ~/ 100 : 100 - rootRatio ~/ 100)
            : context.l10n.paneValuevalue(index + 1);
        return _SplitPreviewHostCard(title: title, host: host);
      }
      final split = current as _WorkspaceDraftSplit;
      final index = splitIndex++;
      return _SplitWorkspaceLayoutPreview(
        keyPrefix: index == 0
            ? 'workspace-split'
            : 'workspace-split-nested-$index',
        axis: split.axis,
        ratioBasisPoints: split.ratioBasisPoints,
        firstPane: buildNode(split.first),
        secondPane: buildNode(split.second),
      );
    }

    return buildNode(node);
  }
}

class _SplitWorkspaceLayoutPreview extends StatelessWidget {
  const _SplitWorkspaceLayoutPreview({
    this.keyPrefix = 'workspace-split',
    required this.axis,
    required this.ratioBasisPoints,
    required this.firstPane,
    required this.secondPane,
    super.key,
  });

  final String keyPrefix;
  final WorkspaceSplitAxis axis;
  final int ratioBasisPoints;
  final Widget firstPane;
  final Widget secondPane;

  @override
  Widget build(BuildContext context) {
    final gap = axis == WorkspaceSplitAxis.horizontal ? 7.0 : 6.0;
    return Flex(
      key: ValueKey('$keyPrefix-flex-${axis.name}'),
      direction: axis == WorkspaceSplitAxis.horizontal
          ? Axis.horizontal
          : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: ratioBasisPoints, child: firstPane),
        SizedBox(
          width: axis == WorkspaceSplitAxis.horizontal ? gap : 0,
          height: axis == WorkspaceSplitAxis.vertical ? gap : 0,
        ),
        Expanded(flex: 10000 - ratioBasisPoints, child: secondPane),
      ],
    );
  }
}

Future<void> _saveCurrentWorkspace(
  BuildContext context,
  AppController app,
) async {
  final name = await _workspaceNamePrompt(context, title: context.l10n.saveWorkspace);
  if (name == null || !context.mounted) return;
  try {
    await app.saveCurrentWorkspace(name);
    if (context.mounted) {
      _snack(context, context.l10n.workspaceSavedEncryptedToThisVault);
    }
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<void> _runWorkspaceAction(
  BuildContext context,
  AppController app,
  WorkspaceRecord workspace,
  String action,
) async {
  if (action == 'delete') {
    if (await _confirmDelete(context, workspace.name) != true ||
        !context.mounted) {
      return;
    }
    try {
      await app.deleteWorkspace(workspace.id);
    } catch (error) {
      if (context.mounted) {
        _snack(context, app.friendlyError(error), error: true);
      }
    }
    return;
  }
  final name = await _workspaceNamePrompt(
    context,
    title: action == 'rename' ? context.l10n.renameWorkspace : context.l10n.duplicateWorkspace,
    initialValue: action == 'rename'
        ? workspace.name
        : '${workspace.name} copy',
  );
  if (name == null || !context.mounted) return;
  try {
    if (action == 'rename') {
      await app.renameWorkspace(workspace.id, name);
    } else {
      await app.duplicateWorkspace(workspace.id, name);
    }
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<void> _repairWorkspacePane(
  BuildContext context,
  AppController app,
  WorkspaceRecord workspace,
  WorkspacePane pane,
) async {
  final replacement = await showAppDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.replaceMissingHost),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.chooseAHostFromTheActive,
              ),
            ),
            const SizedBox(height: 12),
            for (final host in app.hosts)
              ListTile(
                key: ValueKey('workspace-host-choice-${host.id}'),
                leading: const Icon(Icons.dns_outlined),
                title: Text(host.name),
                subtitle: Text(host.endpoint),
                onTap: () => Navigator.pop(dialogContext, host.id),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.cancel2),
        ),
      ],
    ),
  );
  if (replacement == null || !context.mounted) return;
  try {
    await app.replaceWorkspaceHost(workspace.id, pane.paneId, replacement);
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<String?> _workspaceNamePrompt(
  BuildContext context, {
  required String title,
  String initialValue = '',
}) => showAppDialog<String>(
  context: context,
  builder: (_) =>
      _WorkspaceNameDialog(title: title, initialValue: initialValue),
);

class _WorkspaceNameDialog extends StatefulWidget {
  const _WorkspaceNameDialog({required this.title, required this.initialValue});

  final String title;
  final String initialValue;

  @override
  State<_WorkspaceNameDialog> createState() => _WorkspaceNameDialogState();
}

class _WorkspaceNameDialogState extends State<_WorkspaceNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    final trimmed = (value ?? _controller.text).trim();
    if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('workspace-name-input'),
      controller: _controller,
      autofocus: true,
      maxLength: 256,
      textCapitalization: TextCapitalization.none,
      decoration: InputDecoration(labelText: context.l10n.workspaceName),
      onSubmitted: _submit,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        key: const ValueKey('workspace-name-save'),
        onPressed: _submit,
        child: Text(context.l10n.save),
      ),
    ],
  );
}

class _SnippetRunConfirmation {
  const _SnippetRunConfirmation({required this.values, required this.preview});

  final Map<String, String> values;
  final SnippetInvocationPreview preview;
}

class _SnippetBatchConfirmation {
  const _SnippetBatchConfirmation({
    required this.targets,
    required this.values,
    required this.preview,
  });

  final List<PreparedSnippetExecution> targets;
  final Map<String, String> values;
  final SnippetInvocationPreview preview;
}

List<TerminalTabSession> _availableSnippetTargets(AppController app) {
  final activeId = app.activeTerminalTabId;
  final tabs = app.terminalTabs
      .where(
        (tab) =>
            !tab.closed &&
            tab.state == 'connected' &&
            tab.connection != null &&
            tab.host != null &&
            app.hosts.any((host) => host.id == tab.host!.id),
      )
      .toList();
  tabs.sort((left, right) {
    if (left.id == activeId) return -1;
    if (right.id == activeId) return 1;
    return 0;
  });
  final seenHostIds = <String>{};
  return tabs
      .where((tab) => seenHostIds.add(tab.host!.id))
      .toList(growable: false);
}

Future<void> _runSnippetBatch(
  BuildContext context,
  AppController app,
  SnippetRecord snippet,
) async {
  if (snippet.executionMode != SnippetExecutionMode.bashCommand) return;
  final targets = _availableSnippetTargets(app);
  if (targets.length < 2) return;
  final initiallySelected = <String>{
    if (targets.any((tab) => tab.id == app.activeTerminalTabId))
      app.activeTerminalTabId!,
  };
  final selectedIds = await showAppDialog<Set<String>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(context.l10n.chooseConnectedHosts),
        content: SizedBox(
          width: appDialogWidth(context, 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.onlyAlreadyConnectedSshSessionsAre,
                  ),
                ),
                const SizedBox(height: 10),
                for (final tab in targets)
                  CheckboxListTile(
                    key: ValueKey('snippet-batch-target-${tab.host!.id}'),
                    value: initiallySelected.contains(tab.id),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(tab.host!.name),
                    subtitle: Text(tab.host!.endpoint),
                    onChanged: (selected) => setDialogState(() {
                      if (selected == true) {
                        initiallySelected.add(tab.id);
                      } else {
                        initiallySelected.remove(tab.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('snippet-batch-choose-targets'),
            onPressed: initiallySelected.length < 2
                ? null
                : () => Navigator.pop(
                    dialogContext,
                    Set<String>.unmodifiable(initiallySelected),
                  ),
            child: Text(context.l10n.reviewCountHosts(initiallySelected.length)),
          ),
        ],
      ),
    ),
  );
  if (selectedIds == null || !context.mounted) return;
  final selectedTabs = targets
      .where((tab) => selectedIds.contains(tab.id))
      .toList(growable: false);
  if (selectedTabs.length < 2) return;

  final preparedTargets = <PreparedSnippetExecution>[];
  try {
    for (final tab in selectedTabs) {
      preparedTargets.add(
        app.prepareSnippetExecution(snippet, terminalTabId: tab.id),
      );
    }
  } catch (error) {
    for (final prepared in preparedTargets) {
      prepared.discard();
    }
    if (context.mounted) {
      _snack(context, app.friendlyError(error), error: true);
    }
    return;
  }

  final controllers = <String, TextEditingController>{
    for (final parameter in snippet.parameters)
      if (parameter.type == SnippetParameterType.text)
        parameter.name: TextEditingController(
          text: parameter.defaultValue ?? '',
        ),
  };
  _SnippetBatchConfirmation? confirmation;
  Future<void>? dialogTransitionFinished;
  try {
    confirmation = await showAppDialog<_SnippetBatchConfirmation>(
      context: context,
      builder: (dialogContext) {
        dialogTransitionFinished ??= ModalRoute.of(dialogContext)?.completed
            .then<void>((_) {});
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final values = {
              for (final entry in controllers.entries)
                entry.key: entry.value.text,
            };
            SnippetInvocationPreview? preview;
            String? previewError;
            try {
              preview = app.previewSnippetExecution(snippet, values: values);
            } on FormatException catch (error) {
              previewError = error.message.toString();
            }
            final previewText = formatSnippetPreviewText(
              preview?.command ??
                  previewError ??
                  context.l10n.enterRequiredValuesToPreview,
            );
            final hasCredentials = snippet.parameters.any(
              (item) => item.type == SnippetParameterType.credentialSecret,
            );
            final executionBlockedMessage = preview?.blockedReason;
            return AlertDialog(
              title: Text(context.l10n.reviewBatchCommand),
              content: SizedBox(
                width: appDialogWidth(context, 680),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.targetsRunSequentiallyNoTargetStarts,
                      ),
                      for (final parameter in snippet.parameters)
                        if (parameter.type == SnippetParameterType.text) ...[
                          const SizedBox(height: 12),
                          TextField(
                            key: ValueKey(
                              'snippet-batch-param-${parameter.name}',
                            ),
                            controller: controllers[parameter.name],
                            maxLines: 1,
                            onChanged: (_) => setDialogState(() {}),
                            decoration: InputDecoration(
                              labelText: parameter.name,
                              hintText: parameter.defaultValue == null
                                  ? context.l10n.requiredTextValue
                                  : context.l10n.defaultDefaultvalue('${parameter.defaultValue}'),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                      for (final parameter in snippet.parameters)
                        if (parameter.type ==
                            SnippetParameterType.credentialSecret) ...[
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.nameValuevaluePasswordHiddenFromPreview(parameter.name, app.credentials.where((item) => item.id == parameter.credentialId).firstOrNull?.name ?? context.l10n.unavailableCredential2),
                          ),
                        ],
                      if (hasCredentials) ...[
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.eachSelectedHostReceivesReferencedCredential,
                          style: TextStyle(color: context.palette.orange),
                        ),
                      ],
                      if (executionBlockedMessage != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          executionBlockedMessage,
                          style: TextStyle(color: context.palette.orange),
                        ),
                      ],
                      for (
                        var index = 0;
                        index < preparedTargets.length;
                        index++
                      ) ...[
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.targetValuevalueHostnameEndpoint(index + 1, preparedTargets[index].hostName, preparedTargets[index].endpoint),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 7),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context.palette.codeBackground,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: context.palette.line),
                          ),
                          child: Semantics(
                            key: ValueKey('snippet-batch-preview-$index'),
                            container: true,
                            label: previewText,
                            child: ExcludeSemantics(
                              child: SelectableText(
                                previewText,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: context.palette.codeText,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.cancel2),
                ),
                FilledButton(
                  key: const ValueKey('snippet-batch-confirm'),
                  onPressed: preview == null || !preview.canExecute
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          _SnippetBatchConfirmation(
                            targets: List.unmodifiable(preparedTargets),
                            values: Map.unmodifiable(values),
                            preview: preview!,
                          ),
                        ),
                  child: Text(
                    executionBlockedMessage == null
                        ? context.l10n.confirmAndRunOnCountHosts(preparedTargets.length)
                        : context.l10n.previewOnly,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (dialogTransitionFinished != null) {
      await dialogTransitionFinished;
    }
  } finally {
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }
  final confirmed = confirmation;
  if (confirmed == null || !context.mounted) {
    for (final prepared in preparedTargets) {
      prepared.discard();
    }
    return;
  }

  final cancellation = SshExecCancellation();
  Future<List<SnippetBatchTargetOutcome>>? execution;
  try {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var cancelRequested = false;
        var currentIndex = -1;
        String? currentHostName;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            if (execution == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!dialogContext.mounted || execution != null) return;
                execution = app.executeSnippetBatch(
                  snippet: snippet,
                  targets: confirmed.targets,
                  confirmedPreview: confirmed.preview,
                  values: confirmed.values,
                  cancellation: cancellation,
                  onTargetStarted: (index, target) {
                    if (!dialogContext.mounted) return;
                    setDialogState(() {
                      currentIndex = index;
                      currentHostName = target.hostName;
                    });
                  },
                );
                setDialogState(() {});
              });
            }
            return FutureBuilder<List<SnippetBatchTargetOutcome>>(
              future: execution,
              builder: (dialogContext, snapshot) {
                final complete = snapshot.hasData || snapshot.hasError;
                final outcomes = snapshot.data ?? const [];
                return PopScope(
                  canPop: complete,
                  child: AlertDialog(
                    title: Text(context.l10n.batchCommandExecution),
                    content: SizedBox(
                      width: appDialogWidth(context, 680),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!complete) ...[
                              const LinearProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                cancelRequested
                                    ? context.l10n.cancellationRequestedTheActiveCommandMay
                                    : currentIndex < 0
                                    ? context.l10n.validatingAllSelectedHostsBeforeSending
                                    : context.l10n.targetValuevalueOfCountValuevalue2(currentIndex + 1, confirmed.targets.length, currentHostName ?? 'connected Host'),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                context.l10n.commandsRunOneAtATime,
                              ),
                            ] else if (snapshot.hasError) ...[
                              Text(
                                app.friendlyError(snapshot.error!),
                                style: TextStyle(color: context.palette.red),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                context.l10n.preflightFailedBeforeAnyTargetReceived,
                              ),
                            ] else ...[
                              Text(
                                context.l10n.countTargetSReportedAKnown(outcomes.where((item) => item.result != null && !_snippetBatchResultCompletionUnknown(item.result!)).length, outcomes.where((item) => item.completionUnknown || (item.result != null && _snippetBatchResultCompletionUnknown(item.result!))).length, outcomes.where((item) => item.error != null && !item.skipped && !item.completionUnknown).length, outcomes.where((item) => item.skipped).length),
                              ),
                              const SizedBox(height: 8),
                              for (final outcome in outcomes)
                                _snippetBatchOutcomeTile(context, outcome),
                            ],
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      if (complete)
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: Text(context.l10n.close),
                        )
                      else
                        TextButton(
                          onPressed: cancelRequested
                              ? null
                              : () {
                                  setDialogState(() => cancelRequested = true);
                                  cancellation.cancel();
                                },
                          child: Text(
                            cancelRequested ? 'Canceling…' : context.l10n.cancelBatch,
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  } catch (error) {
    if (context.mounted) {
      _snack(context, app.friendlyError(error), error: true);
    }
  } finally {
    cancellation.cancel();
    for (final prepared in preparedTargets) {
      prepared.discard();
    }
  }
}

Widget _snippetBatchOutcomeTile(
  BuildContext context,
  SnippetBatchTargetOutcome outcome,
) {
  final result = outcome.result;
  final icon = outcome.skipped
      ? Icons.skip_next_outlined
      : outcome.error != null ||
            (result != null && !_snippetBatchResultSucceeded(result))
      ? Icons.error_outline
      : Icons.check_circle_outline;
  final title = '${outcome.hostName} · ${outcome.endpoint}';
  final status = outcome.skipped
      ? currentL10n.notStarted
      : outcome.completionUnknown ||
            (result != null && _snippetBatchResultCompletionUnknown(result))
      ? currentL10n.remoteCompletionUnknownNotRetried
      : outcome.error ??
            (result == null
                ? currentL10n.noResult
                : result.exitCode == null
                ? currentL10n.completionStatusUnknown
                : currentL10n.exitCodeExitcode('${result.exitCode}'));
  return Card(
    key: ValueKey('snippet-batch-outcome-${outcome.hostId}'),
    child: ExpansionTile(
      leading: Icon(icon, color: outcome.skipped ? context.palette.orange : null),
      title: Text(title),
      subtitle: Text(status),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        if (result != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: _snippetExecutionStatus(context, result),
          ),
          const SizedBox(height: 8),
          _snippetExecutionOutput(context, result),
        ] else if (outcome.error != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (outcome.completionUnknown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    currentL10n.sshExecFailedAfterDispatchThe,
                    style: TextStyle(color: context.palette.orange),
                  ),
                ),
              Text(
                outcome.error!,
                style: TextStyle(color: context.palette.orange),
              ),
            ],
          ),
      ],
    ),
  );
}

bool _snippetBatchResultSucceeded(SshExecResult result) =>
    result.exitCode == 0 &&
    result.exitSignal == null &&
    !result.cancelled &&
    !result.timedOut &&
    !result.outputTruncated &&
    !result.bashUnavailable &&
    !result.execOpenPending;

bool _snippetBatchResultCompletionUnknown(SshExecResult result) =>
    !result.bashUnavailable &&
    (result.cancelled ||
        result.timedOut ||
        result.outputTruncated ||
        result.execOpenPending ||
        result.exitSignal != null ||
        result.exitCode == null);

Future<void> _runSnippet(
  BuildContext context,
  AppController app,
  SnippetRecord snippet,
) async {
  PreparedSnippetExecution prepared;
  try {
    prepared = app.prepareSnippetExecution(snippet);
  } catch (error) {
    _snack(context, app.friendlyError(error), error: true);
    return;
  }

  final controllers = <String, TextEditingController>{
    for (final parameter in snippet.parameters)
      if (parameter.type == SnippetParameterType.text)
        parameter.name: TextEditingController(
          text: parameter.defaultValue ?? '',
        ),
  };
  _SnippetRunConfirmation? confirmation;
  Future<void>? dialogTransitionFinished;
  try {
    confirmation = await showAppDialog<_SnippetRunConfirmation>(
      context: context,
      builder: (dialogContext) {
        dialogTransitionFinished ??= ModalRoute.of(dialogContext)?.completed
            .then<void>((_) {});
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final values = {
              for (final entry in controllers.entries)
                entry.key: entry.value.text,
            };
            SnippetInvocationPreview? preview;
            String? previewError;
            try {
              preview = app.previewSnippetExecution(snippet, values: values);
            } on FormatException catch (error) {
              previewError = error.message.toString();
            }
            final hasCredentials = snippet.parameters.any(
              (item) => item.type == SnippetParameterType.credentialSecret,
            );
            final executionBlockedMessage = preview?.blockedReason;
            final previewText = formatSnippetPreviewText(
              preview?.command ??
                  previewError ??
                  context.l10n.enterRequiredValuesToPreview,
            );
            return AlertDialog(
              title: Text(context.l10n.reviewCommandExecution),
              content: SizedBox(
                width: appDialogWidth(context, 600),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.targetHostnameEndpoint(prepared.hostName, prepared.endpoint),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        snippet.executionMode ==
                                SnippetExecutionMode.bashCommand
                            ? context.l10n.bashNonInteractiveExecutionRequiresA
                            : context.l10n.shellLabelShellSentToThe(prepared.shell),
                      ),
                      for (final parameter in snippet.parameters)
                        if (parameter.type == SnippetParameterType.text) ...[
                          const SizedBox(height: 12),
                          TextField(
                            key: ValueKey('snippet-param-${parameter.name}'),
                            controller: controllers[parameter.name],
                            maxLines: 1,
                            onChanged: (_) => setDialogState(() {}),
                            decoration: InputDecoration(
                              labelText: parameter.name,
                              hintText: parameter.defaultValue == null
                                  ? context.l10n.requiredTextValue
                                  : context.l10n.defaultDefaultvalue('${parameter.defaultValue}'),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                      for (final parameter in snippet.parameters)
                        if (parameter.type ==
                            SnippetParameterType.credentialSecret) ...[
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.nameValuevaluePasswordHiddenFromPreview(parameter.name, app.credentials.where((item) => item.id == parameter.credentialId).firstOrNull?.name ?? context.l10n.unavailableCredential2),
                          ),
                        ],
                      if (hasCredentials) ...[
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.credentialValuesAreSentOnlyThrough,
                          style: TextStyle(color: context.palette.orange),
                        ),
                      ],
                      if (executionBlockedMessage != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          executionBlockedMessage,
                          style: TextStyle(color: context.palette.orange),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        context.l10n.executionPreview,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 7),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.palette.codeBackground,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: context.palette.line),
                        ),
                        child: Semantics(
                          key: const ValueKey('snippet_execution_preview'),
                          container: true,
                          label: previewText,
                          child: ExcludeSemantics(
                            child: SelectableText(
                              previewText,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: context.palette.codeText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.cancel2),
                ),
                FilledButton(
                  onPressed: preview == null || !preview.canExecute
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          _SnippetRunConfirmation(
                            values: Map.unmodifiable(values),
                            preview: preview!,
                          ),
                        ),
                  child: Text(
                    executionBlockedMessage == null
                        ? context.l10n.confirmAndRun
                        : context.l10n.previewOnly,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (dialogTransitionFinished != null) {
      await dialogTransitionFinished;
    }
  } finally {
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }
  final confirmed = confirmation;
  if (confirmed == null || !context.mounted) {
    prepared.discard();
    return;
  }
  if (snippet.executionMode == SnippetExecutionMode.bashCommand) {
    final cancellation = SshExecCancellation();
    Future<SshExecResult?>? execution;
    try {
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var cancelRequested = false;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              // Start after this result route mounts. executeSnippet notifies
              // the host page synchronously before awaiting SSH; starting it
              // before showDialog could unmount this caller's BuildContext.
              if (execution == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!dialogContext.mounted || execution != null) return;
                  execution = app.executeSnippet(
                    snippet,
                    prepared: prepared,
                    confirmedPreview: confirmed.preview,
                    values: confirmed.values,
                    cancellation: cancellation,
                  );
                  setDialogState(() {});
                });
              }
              return FutureBuilder<SshExecResult?>(
                future: execution,
                builder: (dialogContext, snapshot) {
                  final complete = snapshot.hasData || snapshot.hasError;
                  return PopScope(
                    canPop: complete,
                    child: AlertDialog(
                      title: Text(context.l10n.bashNonInteractiveExecution),
                      content: SizedBox(
                        width: appDialogWidth(context, 620),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.targetHostnameEndpoint(prepared.hostName, prepared.endpoint),
                              ),
                              const SizedBox(height: 12),
                              if (!complete) ...[
                                const LinearProgressIndicator(),
                                const SizedBox(height: 12),
                                Text(
                                  cancelRequested
                                      ? context.l10n.cancellationRequestedTheCommandMayAlready
                                      : context.l10n.runningOnceThroughANonPty,
                                ),
                              ] else if (snapshot.hasError) ...[
                                Text(
                                  app.friendlyError(snapshot.error!),
                                  style: TextStyle(color: context.palette.red),
                                ),
                              ] else ...[
                                _snippetExecutionStatus(context, snapshot.data!),
                                const SizedBox(height: 10),
                                _snippetExecutionOutput(context, snapshot.data!),
                              ],
                            ],
                          ),
                        ),
                      ),
                      actions: [
                        if (complete)
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(context.l10n.close),
                          )
                        else
                          TextButton(
                            onPressed: cancelRequested
                                ? null
                                : () {
                                    setDialogState(
                                      () => cancelRequested = true,
                                    );
                                    cancellation.cancel();
                                  },
                            child: Text(
                              cancelRequested
                                  ? 'Canceling…'
                                  : context.l10n.cancelExecution,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      );
    } catch (error) {
      if (context.mounted) {
        _snack(context, app.friendlyError(error), error: true);
      }
    } finally {
      // If navigation removed the dialog while the operation was pending,
      // close its exec channel. A finished token has already been unbound.
      cancellation.cancel();
      prepared.discard();
    }
    return;
  }
  try {
    await app.executeSnippet(
      snippet,
      prepared: prepared,
      confirmedPreview: confirmed.preview,
      values: confirmed.values,
    );
  } catch (error) {
    if (context.mounted) {
      _snack(context, app.friendlyError(error), error: true);
    }
  } finally {
    prepared.discard();
  }
}

Widget _snippetExecutionStatus(BuildContext context, SshExecResult result) {
  final (text, color) = switch (result) {
    SshExecResult(cancelled: true, execOpenPending: true) => (
      'Canceled. The SSH exec request has not replied; disconnect and reconnect before retrying. Remote completion is unknown.',
      context.palette.orange,
    ),
    SshExecResult(cancelled: true) => (
      currentL10n.execCancelledUnknown,
      context.palette.orange,
    ),
    SshExecResult(timedOut: true, execOpenPending: true) => (
      currentL10n.execOpenTimedOut,
      context.palette.orange,
    ),
    SshExecResult(timedOut: true) => (
      currentL10n.execTimedOutUnknown,
      context.palette.orange,
    ),
    SshExecResult(outputTruncated: true) => (
      currentL10n.execOutputTruncated,
      context.palette.orange,
    ),
    SshExecResult(bashUnavailable: true) => (
      currentL10n.execBashUnavailable,
      context.palette.red,
    ),
    SshExecResult(exitCode: final int code) => (
      'Exit code: $code',
      code == 0 ? context.palette.teal : context.palette.red,
    ),
    _ => (
      result.exitSignal == null
          ? 'SSH ended without reporting an exit status.'
          : 'SSH process ended by signal ${result.exitSignal}.',
      context.palette.orange,
    ),
  };
  return Text(text, style: TextStyle(color: color));
}

Widget _snippetExecutionOutput(BuildContext context, SshExecResult result) {
  final sections = <String>[
    if (result.stdout.isNotEmpty) 'stdout:\n${result.stdout}',
    if (result.stderr.isNotEmpty) 'stderr:\n${result.stderr}',
  ];
  final output = sections.isEmpty ? '(no output)' : sections.join('\n\n');
  final outputText = formatSnippetPreviewText(output);
  return Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 300),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.palette.codeBackground,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: context.palette.line),
    ),
    child: SingleChildScrollView(
      child: Semantics(
        key: const ValueKey('snippet_execution_output'),
        container: true,
        label: outputText,
        child: ExcludeSemantics(
          child: SelectableText(
            outputText,
            key: const ValueKey('snippet_execution_output_text'),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: context.palette.codeText,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _editSnippet(
  BuildContext context,
  AppController app, [
  SnippetRecord? existing,
]) async {
  final title = TextEditingController(text: existing?.title ?? '');
  final body = TextEditingController(text: existing?.body ?? '');
  final tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
  final program = TextEditingController(text: existing?.program ?? '');
  final parameters = TextEditingController(
    text: jsonEncode(
      existing?.parameters.map((item) => item.toJson()).toList() ?? const [],
    ),
  );
  final arguments = TextEditingController(
    text: jsonEncode(
      existing?.arguments.map((item) => item.toJson()).toList() ?? const [],
    ),
  );
  var mode = existing?.executionMode ?? SnippetExecutionMode.script;
  var shell = existing?.shell ?? 'bash';
  String? validationError;
  Future<void>? dialogTransitionFinished;
  final result = await showAppDialog<SnippetRecord>(
    context: context,
    builder: (dialogContext) {
      dialogTransitionFinished ??= ModalRoute.of(dialogContext)?.completed
          .then<void>((_) {});
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? context.l10n.newCommandSnippet : context.l10n.editCommandSnippet,
          ),
          content: SizedBox(
            width: appDialogWidth(context, 600),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    decoration: InputDecoration(labelText: context.l10n.title),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<SnippetExecutionMode>(
                    initialValue: mode,
                    decoration: InputDecoration(
                      labelText: context.l10n.executionMode,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: SnippetExecutionMode.script,
                        child: Text(context.l10n.freeFormScriptLegacy),
                      ),
                      DropdownMenuItem(
                        value: SnippetExecutionMode.bashCommand,
                        child: Text(context.l10n.structuredBashCommand2),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        mode = value;
                        if (mode == SnippetExecutionMode.bashCommand) {
                          shell = 'bash';
                        }
                        validationError = null;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  if (mode == SnippetExecutionMode.script) ...[
                    DropdownButtonFormField<String>(
                      initialValue: shell,
                      decoration: InputDecoration(
                        labelText: context.l10n.shellLabel2,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'bash',
                          child: Text('Bash'),
                        ),
                        const DropdownMenuItem(
                          value: 'powershell',
                          child: Text('PowerShell'),
                        ),
                        if (shell != 'bash' && shell != 'powershell')
                          DropdownMenuItem(
                            value: shell,
                            child: Text(context.l10n.existingShellLabelShell2(shell)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => shell = value);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: body,
                      minLines: 5,
                      maxLines: 12,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: context.l10n.scriptBody2,
                        alignLabelWithHint: true,
                        helperText: context.l10n.theFullScriptIsReviewedBefore,
                      ),
                    ),
                  ] else ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.l10n.bashOnlyEachArgvItemIs,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const ValueKey('snippet-program'),
                      controller: program,
                      decoration: InputDecoration(
                        labelText: context.l10n.program2,
                        hintText: context.l10n.eGGrep,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const ValueKey('snippet-parameter-definitions'),
                      controller: parameters,
                      minLines: 3,
                      maxLines: 6,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: context.l10n.parameterDefinitionsJsonArray2,
                        helperText: '[{"name":"pattern","type":"text"}] or [{"name":"token","type":"credentialSecret","credential_id":"…"}]. Secret values stay in the referenced password Credential.',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('add_credential_secret_parameter'),
                        onPressed:
                            app.credentials.any(
                              (item) =>
                                  item.kind == AuthKind.password &&
                                  (item.secret ?? '').isNotEmpty,
                            )
                            ? () async {
                                final parameter =
                                    await _promptCredentialSnippetParameter(
                                      dialogContext,
                                      app,
                                    );
                                if (parameter == null) return;
                                try {
                                  final existing = _parseSnippetJsonArray(
                                    parameters.text,
                                  );
                                  existing.add(parameter.toJson());
                                  parameters.text = jsonEncode(existing);
                                  setDialogState(() => validationError = null);
                                } catch (error) {
                                  setDialogState(
                                    () => validationError = error.toString(),
                                  );
                                }
                              }
                            : null,
                        icon: const Icon(Icons.key_outlined, size: 16),
                        label: Text(context.l10n.addCredentialSecretParameter),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: arguments,
                      minLines: 3,
                      maxLines: 7,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: context.l10n.argumentsJsonArray2,
                        helperText: '[{"kind":"literal","value":"-e"},{"kind":"parameter","name":"pattern"}]',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: tags,
                    decoration: InputDecoration(
                      labelText: context.l10n.tagsSeparatedByCommas,
                    ),
                  ),
                  if (validationError != null) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        validationError!,
                        style: TextStyle(color: context.palette.red),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final parsedParameters = mode == SnippetExecutionMode.script
                      ? const <SnippetParameter>[]
                      : _parseSnippetJsonArray(parameters.text)
                            .map(SnippetParameter.fromJson)
                            .toList(growable: false);
                  final parsedArguments = mode == SnippetExecutionMode.script
                      ? const <SnippetArgument>[]
                      : _parseSnippetJsonArray(arguments.text)
                            .map(SnippetArgument.fromJson)
                            .toList(growable: false);
                  final candidate = SnippetRecord(
                    id: existing?.id ?? _uuid.v4(),
                    title: title.text.trim(),
                    body: mode == SnippetExecutionMode.script ? body.text : '',
                    shell: shell,
                    executionMode: mode,
                    program: mode == SnippetExecutionMode.script
                        ? ''
                        : program.text,
                    arguments: parsedArguments,
                    parameters: parsedParameters,
                    tags: tags.text
                        .split(',')
                        .map((tag) => tag.trim())
                        .where((tag) => tag.isNotEmpty)
                        .toList(),
                    manifest: existing?.manifest,
                  );
                  if (candidate.title.isEmpty) {
                    throw FormatException(context.l10n.snippetTitleIsRequired);
                  }
                  validateSnippetDefinition(candidate);
                  for (final parameter in parsedParameters) {
                    if (parameter.type !=
                        SnippetParameterType.credentialSecret) {
                      continue;
                    }
                    final credential = app.credentials
                        .where((item) => item.id == parameter.credentialId)
                        .firstOrNull;
                    if (credential == null) {
                      throw FormatException(
                        context.l10n.credentialReferenceNameWasNotFound(parameter.name),
                      );
                    }
                    if (credential.kind != AuthKind.password ||
                        (credential.secret ?? '').isEmpty) {
                      throw FormatException(
                        context.l10n.credentialReferenceNameMustPointTo(parameter.name),
                      );
                    }
                  }
                  if (mode == SnippetExecutionMode.script &&
                      candidate.body.trim().isEmpty) {
                    throw FormatException(context.l10n.snippetScriptIsRequired);
                  }
                  Navigator.pop(dialogContext, candidate);
                } catch (error) {
                  setDialogState(() => validationError = error.toString());
                }
              },
              child: Text(context.l10n.saveSnippet),
            ),
          ],
        ),
      );
    },
  );
  if (dialogTransitionFinished != null) await dialogTransitionFinished;
  title.dispose();
  body.dispose();
  tags.dispose();
  program.dispose();
  parameters.dispose();
  arguments.dispose();
  if (result == null) return;
  try {
    await app.saveSnippet(result);
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<SnippetParameter?> _promptCredentialSnippetParameter(
  BuildContext context,
  AppController app,
) async {
  final candidates = app.credentials
      .where(
        (item) =>
            item.kind == AuthKind.password && (item.secret ?? '').isNotEmpty,
      )
      .toList(growable: false);
  if (candidates.isEmpty) return Future<SnippetParameter?>.value(null);
  final name = TextEditingController(text: 'token');
  var selectedCredentialId = candidates.first.id;
  Future<void>? dialogTransitionFinished;
  final result = await showAppDialog<SnippetParameter>(
    context: context,
    builder: (dialogContext) {
      dialogTransitionFinished ??= ModalRoute.of(dialogContext)?.completed
          .then<void>((_) {});
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.l10n.addCredentialSecretParameter),
          content: SizedBox(
            width: appDialogWidth(context, 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('snippet-secret-parameter-name'),
                  controller: name,
                  decoration: InputDecoration(
                    labelText: context.l10n.parameterName,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('snippet-secret-credential-choice'),
                  initialValue: selectedCredentialId,
                  decoration: InputDecoration(
                    labelText: context.l10n.passwordCredential,
                  ),
                  items: [
                    for (final credential in candidates)
                      DropdownMenuItem(
                        value: credential.id,
                        child: Text(credential.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedCredentialId = value);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.theSecretIsReadFromThe,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () {
                final parameterName = name.text.trim();
                if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$')
                    .hasMatch(parameterName)) {
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  SnippetParameter.credential(
                    name: parameterName,
                    credentialId: selectedCredentialId,
                  ),
                );
              },
              child: Text(context.l10n.addParameter),
            ),
          ],
        ),
      );
    },
  );
  if (dialogTransitionFinished != null) await dialogTransitionFinished;
  name.dispose();
  return result;
}

List<Object?> _parseSnippetJsonArray(String input) {
  final decoded = jsonDecode(input);
  if (decoded is! List) {
    throw FormatException(currentL10n.expectedAJsonArray);
  }
  return decoded.cast<Object?>();
}

class _TerminalPage extends StatefulWidget {
  const _TerminalPage({
    super.key,
    required this.app,
    required this.sessionWorkspace,
    required this.dragScope,
    required this.fileTabs,
    required this.onWorkspaceSelect,
    required this.onWorkspaceClose,
    required this.onWorkspaceUnsplit,
    required this.onWorkspaceDuplicate,
    this.onWorkspaceSplit,
    this.workspaceSplitTargets,
    this.enableWebCommandSuggestionsForTesting = false,
  });
  final AppController app;
  final SessionWorkspaceController sessionWorkspace;
  final FileWorkspaceTabs fileTabs;
  final ValueChanged<String> onWorkspaceSelect;
  final ValueChanged<String> onWorkspaceClose, onWorkspaceUnsplit, onWorkspaceDuplicate;
  final void Function(String id, Axis axis)? onWorkspaceSplit;
  final Iterable<String> Function()? workspaceSplitTargets;
  final String dragScope;
  final bool enableWebCommandSuggestionsForTesting;
  @override
  State<_TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<_TerminalPage> {
  void toggleTools() {
    final id = widget.sessionWorkspace.selectedId;
    if (id == null) return;
    final tab = app.terminalTabFor(id);
    if (tab == null || tab.desktop != null) return;
    final search = _terminalSearches[id];
    if (search?.isOpen == true) {
      _closeTerminalSearch(search!);
      _focusNodeFor(id).requestFocus();
    } else {
      _openTerminalTools(tab, TerminalToolsSection.search);
    }
  }

  final Map<String, FocusNode> _terminalFocusNodes = {};
  final Map<String, GlobalKey<TerminalViewState>> _terminalViewKeys = {};
  final Map<String, _TerminalSearchSession> _terminalSearches = {};
  String? _focusRequestedForTab;
  AppController get app => widget.app;

  FocusNode _focusNodeFor(String id) => _terminalFocusNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'SSH terminal input $id'),
  );

  GlobalKey<TerminalViewState> _viewKeyFor(String id) =>
      _terminalViewKeys.putIfAbsent(id, () => GlobalKey<TerminalViewState>());

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (final node in _terminalFocusNodes.values) {
      node.dispose();
    }
    for (final search in _terminalSearches.values) {
      search.dispose();
    }
    super.dispose();
  }

  Future<void> _confirmWorkspaceTmuxAction({
    required WorkspaceRecord workspace,
    required WorkspacePane pane,
    required bool resume,
  }) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          resume ? context.l10n.resumeTmuxSession : context.l10n.startResumableTmuxSession,
        ),
        content: Text(
          resume
              ? context.l10n.thisAttachesTheCurrentSshPane
              : context.l10n.thisCreatesATmuxSessionOn,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: ValueKey(
              resume ? 'tmux-resume-confirm' : 'tmux-start-confirm',
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(resume ? context.l10n.resumeSession : context.l10n.startSession),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (resume) {
        await app.resumeWorkspacePaneTmux(workspace.id, pane.paneId);
      } else {
        await app.startWorkspacePaneTmux(workspace.id, pane.paneId);
      }
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : context.l10n.couldntCompleteTheTmuxSessionAction;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmClearWorkspaceTmuxReference({
    required WorkspaceRecord workspace,
    required WorkspacePane pane,
  }) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.removeTmuxSessionReference),
        content: Text(
          context.l10n.thisRemovesTheEncryptedWorkspaceReference,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('tmux-clear-reference-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.removeReference),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.clearWorkspacePaneTmuxReference(workspace.id, pane.paneId);
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : context.l10n.couldntSaveChangesToTheTmux;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    _pruneClosedTerminalState();
    if (widget.sessionWorkspace.sessionIds.any(
      (id) => widget.fileTabs.find(id) != null,
    )) {
      final selected = app.terminalTabFor(
        widget.sessionWorkspace.selectedId ?? '',
      );
      if (selected?.liveTerminalTransport != null) {
        _focusConnectedTerminalAfterMount(
          selected!.id,
          selected.liveTerminalTransport!,
        );
      } else {
        _focusRequestedForTab = null;
      }
      return _workspaceView();
    }
    final activeTab = app.activeTerminalTab;
    final connected = activeTab?.connection != null;
    // Telnet renders like a device terminal; SSH-only actions keep using
    // [connected] (SSH connection only).
    final deviceSession =
        activeTab?.desktop != null ||
        activeTab?.console != null ||
        activeTab?.telnet != null;
    final shareStatus = activeTab == null
        ? null
        : app.terminalShareStatusFor(activeTab.id);
    final sharingThisTab = app.isTerminalShareHost(activeTab?.id);
    final collaborationEnabled =
        kIsWeb &&
        (app.instance?.capabilities.contains('terminal_collaboration') ??
            false);
    final stagedWorkspace = app.activeSavedWorkspace;
    final tmuxWorkspacePane = activeTab == null || stagedWorkspace == null
        ? null
        : stagedWorkspace.panes
              .where(
                (pane) =>
                    app
                        .workspacePaneTerminalTab(
                          stagedWorkspace.id,
                          pane.paneId,
                        )
                        ?.id ==
                    activeTab.id,
              )
              .firstOrNull;
    final tmuxDescriptor = tmuxWorkspacePane == null
        ? null
        : app.workspacePaneSessionDescriptor(
            stagedWorkspace!.id,
            tmuxWorkspacePane.paneId,
          );
    final tmuxBusy =
        tmuxWorkspacePane != null &&
        app.workspacePaneTmuxBusy(
          stagedWorkspace!.id,
          tmuxWorkspacePane.paneId,
        );
    final tmuxAttached =
        tmuxWorkspacePane != null &&
        app.workspacePaneTmuxAttached(
          stagedWorkspace!.id,
          tmuxWorkspacePane.paneId,
        );
    final stagedSplitTabs = stagedWorkspace?.isSplit == true
        ? [
            for (final pane in stagedWorkspace!.panes)
              app
                          .workspacePaneTerminalTab(
                            stagedWorkspace.id,
                            pane.paneId,
                          )
                          ?.detached ==
                      true
                  ? null
                  : app.workspacePaneTerminalTab(
                      stagedWorkspace.id,
                      pane.paneId,
                    ),
          ]
        : const <TerminalTabSession?>[];
    final liveSplitReady =
        stagedWorkspace?.isSplit == true &&
        stagedSplitTabs.length == stagedWorkspace!.panes.length &&
        stagedSplitTabs.any(
          (tab) => tab?.connection != null || tab?.telnet != null,
        ) &&
        stagedSplitTabs.any((tab) => tab?.id == activeTab?.id);
    if (activeTab != null && activeTab.liveTerminalTransport != null) {
      _focusConnectedTerminalAfterMount(
        activeTab.id,
        activeTab.liveTerminalTransport!,
      );
    } else {
      _focusRequestedForTab = null;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 17),
      child: Row(
        children: [
          Container(
            width: 250,
            decoration: BoxDecoration(
              color: context.palette.surface,
              border: Border.all(color: context.palette.line),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(15),
                  child: Row(
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 17,
                        color: context.palette.muted,
                      ),
                      const SizedBox(width: 8),
                      if (localConsoleSupported)
                        IconButton(
                          key: const ValueKey('open_local_console'),
                          tooltip: context.l10n.localConsole,
                          icon: const Icon(Icons.terminal, size: 18),
                          onPressed: () => app.openConsoleTab(),
                        ),
                      Expanded(
                        child: Text(
                          context.l10n.connections,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        '${app.hosts.length}',
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: app.hosts.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Text(
                              context.l10n.addAHostFirst,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: context.palette.muted),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: app.hosts.length,
                          itemBuilder: (context, index) {
                            final host = app.hosts[index];
                            final connected = app.terminalTabs.any(
                              (tab) =>
                                  tab.host?.id == host.id &&
                                  tab.state == 'connected',
                            );
                            return Material(
                              color: Colors.transparent,
                              child: ListTile(
                                dense: true,
                                selected: app.selectedHost?.id == host.id,
                                selectedTileColor: context.palette.lime.withValues(
                                  alpha: .06,
                                ),
                                leading: Icon(
                                  connected ? Icons.circle : Icons.dns_outlined,
                                  size: connected ? 10 : 17,
                                  color: connected
                                      ? context.palette.teal
                                      : context.palette.muted,
                                ),
                                title: Text(
                                  host.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  host.endpoint,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: context.palette.muted,
                                  ),
                                ),
                                onTap: () => app.selectHost(host),
                                trailing: IconButton(
                                  tooltip: context.l10n.openANewTerminalTab,
                                  icon: const Icon(Icons.add_rounded, size: 18),
                                  onPressed:
                                      app.terminalTabs.length >=
                                          AppController.maxTerminalTabs
                                      ? null
                                      : () => _connect(host),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (app.activeSavedWorkspace case final workspace?)
                  _StagedWorkspaceLayout(app: app, workspace: workspace),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: app.selectedHost == null
                              ? null
                              : () => _connect(app.selectedHost!),
                          icon: const Icon(Icons.play_arrow_rounded, size: 17),
                          label: Text(context.l10n.newTab),
                        ),
                      ),
                      if (activeTab != null) ...[
                        const SizedBox(width: 7),
                        IconButton(
                          tooltip: context.l10n.disconnect2,
                          onPressed: () => app.disconnectTerminalTab(activeTab.id),
                          icon: Icon(
                            Icons.link_off_rounded,
                            color: context.palette.red,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              children: [
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: wallpaperWindowFill(context, const Color(0xFF080C11)),
                      border: Border.all(color: context.palette.line),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Column(
                        children: [
                          Container(
                            height: 43,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: context.palette.line),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    !connected
                                        ? '${activeTab?.console != null ? context.l10n.console : activeTab?.host?.protocol.label ?? 'SSH'} · ${terminalStateLabel(context.l10n, activeTab?.state ?? 'disconnected')}'
                                        : '${activeTab!.host?.username}@${activeTab.host?.address}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.palette.muted,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                WorkspaceOverflowMenu(
                                  key: const ValueKey('terminal_function_menu'),
                                  actions: [
                                    if (connected && tmuxWorkspacePane != null)
                                      WorkspaceAction(
                                        'terminal-workspace-tmux-session',
                                        tmuxDescriptor == null
                                            ? context.l10n.startResumableSession
                                            : context.l10n.resumeTmuxSession2,
                                        Icons.terminal,
                                        () => _confirmWorkspaceTmuxAction(
                                          workspace: stagedWorkspace!,
                                          pane: tmuxWorkspacePane,
                                          resume: tmuxDescriptor != null,
                                        ),
                                        enabled: !tmuxBusy && !tmuxAttached,
                                      ),
                                    if (tmuxWorkspacePane != null &&
                                        tmuxDescriptor != null)
                                      WorkspaceAction(
                                        'terminal-workspace-tmux-clear-reference',
                                        context.l10n.removeTmuxSessionReference2,
                                        Icons.link_off,
                                        () => _confirmClearWorkspaceTmuxReference(
                                          workspace: stagedWorkspace!,
                                          pane: tmuxWorkspacePane,
                                        ),
                                        enabled: !tmuxBusy && !tmuxAttached,
                                      ),
                                    if (connected)
                                      WorkspaceAction(
                                        'terminal-port-forwarding',
                                        context.l10n.sshPortForwarding,
                                        Icons.hub_outlined,
                                        () => _openPortForwarding(activeTab!),
                                      ),
                                    if (activeTab != null &&
                                        (connected ||
                                            app
                                                .shellIntegrationHistoryFor(
                                                  activeTab.id,
                                                )
                                                .isNotEmpty))
                                      WorkspaceAction(
                                        'terminal-shell-integration',
                                        app.shellIntegrationActiveFor(
                                                  activeTab.id,
                                                ) ||
                                                !connected
                                            ? context.l10n.viewCommandHistory
                                            : context.l10n.enableBashCommandHistory,
                                        Icons.history,
                                        () => _showShellIntegration(activeTab),
                                      ),
                                    if (connected &&
                                        (kIsWeb ||
                                            widget
                                                .enableWebCommandSuggestionsForTesting))
                                      WorkspaceAction(
                                        'terminal-command-suggestions',
                                        context.l10n.commandSuggestions,
                                        Icons.auto_awesome_outlined,
                                        () => _showTerminalCommandSuggestions(
                                          activeTab!,
                                        ),
                                      ),
                                    if (connected)
                                      WorkspaceAction(
                                        'terminal-search',
                                        context.l10n.searchTerminalScrollback,
                                        Icons.search,
                                        () => _openTerminalSearch(activeTab!),
                                      ),
                                    if (connected &&
                                        sharingThisTab &&
                                        shareStatus?.inputControlEnabled == true)
                                      WorkspaceAction(
                                        shareStatus?.controllerDeviceId == null
                                            ? 'terminal-share-controller-grant'
                                            : 'terminal-share-controller-revoke',
                                        shareStatus?.controllerDeviceId == null
                                            ? context.l10n.grantInputControl
                                            : context.l10n.revokeInputControl,
                                        Icons.front_hand_outlined,
                                        () =>
                                            shareStatus?.controllerDeviceId ==
                                                null
                                            ? _grantTerminalShareControl(
                                                activeTab!,
                                              )
                                            : _revokeTerminalShareControl(
                                                activeTab!,
                                              ),
                                        enabled: shareStatus?.phase == 'active',
                                      ),
                                    if (connected && sharingThisTab)
                                      WorkspaceAction(
                                        'terminal-share-stop',
                                        context.l10n.stopTerminalSharing,
                                        Icons.stop_circle_outlined,
                                        () => app.stopTerminalShareFor(
                                          activeTab!.id,
                                        ),
                                      )
                                    else if (connected && collaborationEnabled)
                                      WorkspaceAction(
                                        'terminal-share-start',
                                        context.l10n.shareThisTerminal,
                                        Icons.screen_share_outlined,
                                        () => _startTerminalShare(activeTab!),
                                        enabled: shareStatus?.phase != 'starting',
                                      ),
                                    if (collaborationEnabled)
                                      WorkspaceAction(
                                        'terminal-share-join-open',
                                        context.l10n.joinASharedTerminal,
                                        Icons.group_add_outlined,
                                        _joinTerminalShare,
                                        enabled:
                                            app.activeVault?.status == 'active',
                                      ),
                                    if (connected)
                                      WorkspaceAction(
                                        'terminal-open-files',
                                        context.l10n.browseFiles2,
                                        Icons.folder_open_outlined,
                                        () => app.showWorkspacePage(
                                          WorkspacePage.sftp,
                                        ),
                                      ),
                                    if (activeTab?.host != null)
                                      WorkspaceAction(
                                        'terminal-properties',
                                        context.l10n.properties,
                                        Icons.info_outline,
                                        () => showHostProperties(
                                          context,
                                          activeTab!.host!,
                                          state: activeTab.state,
                                        ),
                                      ),
                                    if (activeTab != null)
                                      WorkspaceAction(
                                        'terminal-disconnect',
                                        context.l10n.disconnect,
                                        Icons.link_off,
                                        () => app.disconnectTerminalTab(activeTab.id),
                                        enabled: activeTab.console != null || activeTab.state == 'connected' ||
                                            activeTab.state == 'connecting' || activeTab.recovery?.automaticEnabled == true,
                                        destructive: true,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (shareStatus != null)
                            Container(
                              key: const ValueKey('terminal-share-status'),
                              height: 34,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: context.palette.line),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    shareStatus.phase == 'active'
                                        ? Icons.lock_outline_rounded
                                        : shareStatus.phase == 'failed'
                                        ? Icons.error_outline_rounded
                                        : Icons.sync_rounded,
                                    size: 14,
                                    color: shareStatus.phase == 'active'
                                        ? context.palette.teal
                                        : shareStatus.phase == 'failed'
                                        ? context.palette.red
                                        : context.palette.orange,
                                  ),
                                  const SizedBox(width: 7),
                                  Text(
                                    shareStatus.errorMessage ??
                                        context.l10n.terminalSharePhase(shareStatus.phase),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.palette.muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  if (shareStatus.inputControlEnabled) ...[
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        shareStatus.controllerLabel == null
                                            ? shareStatus.controllerRevoking
                                                  ? context.l10n.inputControlRevoking
                                                  : context.l10n.inputControlOff
                                            : context.l10n.inputControlControllerlabel('${shareStatus.controllerLabel}'),
                                        key: const ValueKey(
                                          'terminal-share-controller-status',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: context.palette.muted,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if ({
                                    'starting',
                                    'connecting',
                                    'active',
                                  }.contains(shareStatus.phase)) ...[
                                    const SizedBox(width: 10),
                                    Text(
                                      'ID',
                                      style: TextStyle(
                                        color: context.palette.muted,
                                        fontSize: 10,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    SelectableText(
                                      shareStatus.sessionId,
                                      key: const ValueKey('terminal-share-code'),
                                      style: TextStyle(
                                        color: context.palette.muted,
                                        fontSize: 10,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: context.l10n.copyTerminalShareId,
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints.tightFor(
                                        width: 28,
                                        height: 28,
                                      ),
                                      padding: EdgeInsets.zero,
                                      onPressed: () => Clipboard.setData(
                                        ClipboardData(
                                          text: shareStatus.sessionId,
                                        ),
                                      ),
                                      icon: const Icon(Icons.copy, size: 13),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          Expanded(
                            child:
                                widget.sessionWorkspace.sessionIds.length > 1 ||
                                    (!liveSplitReady &&
                                        (connected ||
                                            deviceSession ||
                                            activeTab?.connectProgress
                                                    .isVisible ==
                                                true) &&
                                        activeTab != null)
                                ? _workspaceView()
                                : liveSplitReady
                                ? _liveSplitTerminalViews(
                                    stagedWorkspace,
                                    stagedSplitTabs,
                                  )
                                : _TerminalWelcome(
                                    app: app,
                                    errorMessage: activeTab?.errorMessage,
                                  ),
                          ),
                          if (connected && activeTab != null)
                            TerminalKeybar(
                              terminal: activeTab.terminal,
                              focusNode: _focusNodeFor(activeTab.id),
                              readOnly: activeTab.state != 'connected',
                              // Exclude this column's fixed header/share rows.
                              availablePaneHeight: constraints.maxHeight -
                                  43 - (shareStatus != null ? 34 : 0),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _workspaceView() {
    final selected = widget.sessionWorkspace.selectedId;
    final tab = app.terminalTabFor(selected);
    final child = _workspaceViewContent();
    return tab == null || tab.desktop != null
        ? TerminalToolsLayout(child: child)
        : _terminalToolsLayout(tab, child);
  }

  Widget _workspaceViewContent() => SessionWorkspaceView(
    controller: widget.sessionWorkspace,
    dragScope: widget.dragScope,
    acceptsSession: (id) =>
        widget.fileTabs.find(id) != null ||
        app.visibleTerminalTabs.any((tab) => tab.id == id && !tab.closed),
    onSelect: widget.onWorkspaceSelect,
    onClose: widget.onWorkspaceClose,
    onUnsplit: widget.onWorkspaceUnsplit,
    onDuplicate: widget.onWorkspaceDuplicate,
    onSplit: widget.onWorkspaceSplit,
    splitTargets: widget.workspaceSplitTargets,
    paneLabel: (id) =>
        widget.fileTabs.find(id)?.title ??
        app.terminalTabFor(id)?.host?.name ??
        context.l10n.console,
    paneStatus: (id) => widget.fileTabs.find(id) != null
        ? context.l10n.fileManager
        : app.terminalTabFor(id)?.state ?? '',
    terminalBuilder: (context, id) {
      final file = widget.fileTabs.find(id);
      if (file != null) {
        return RemoteFileWorkspace(
          key: ValueKey(file.id),
          controller: file.controller,
        );
      }
      return ExcludeFocus(
        excluding: widget.sessionWorkspace.selectedId != id,
        child: _withConnectProgress(
          id,
          SessionRecoveryOverlay(
            recovery: app.terminalTabFor(id)?.desktop == null
                ? app.terminalTabFor(id)?.recovery : null,
            child: _temporarySessionPane(id),
          ),
        ),
      );
    },
  );

  /// Loading / failed / stopped surface of a tab's initial connection, with
  /// stop loading, retry and close. Covers the pane until the first connect.
  Widget _withConnectProgress(String id, Widget child) {
    final tab = app.terminalTabFor(id);
    if (tab == null) return child;
    final host = tab.host;
    final console = tab.consoleShell != null || tab.consoleSerialPort != null;
    return ConnectProgressView(
      key: ValueKey('connect_progress_$id'),
      progress: tab.connectProgress,
      title: host?.name ?? context.l10n.console,
      detail: console || host == null
          ? context.l10n.console
          : connectProgressDetail(host),
      canRetry: () => app.canRetryTerminalConnect(id),
      onStop: () => unawaited(app.cancelTerminalConnect(id)),
      onRetry: () => unawaited(app.retryTerminalConnect(id)),
      onClose: () => widget.onWorkspaceClose(id),
      child: child,
    );
  }

  Widget _temporarySessionPane(String id) {
    final tab = app.terminalTabFor(id);
    if (tab == null || tab.detached) return const SizedBox.shrink();
    if (tab.desktop != null)
      {
return DesktopView(
        key: ValueKey(tab.id),
        session: tab.desktop!,
        onDetach: ApplicationWindows.instance.supported
            ? () => unawaited(
                _detachCloudDesktop(app, id).then((opened) {
                  if (!opened && mounted) {
                    _snack(context, context.l10n.theNewWindowWasntReadyThe2, error: true);
                  }
                }),
              )
            : null,
        onOpenMonitorWindows: ApplicationWindows.instance.supported
            ? () => unawaited(
                _openCloudDesktopMonitors(app, id).then((missing) {
                  if (missing > 0 && mounted) {
                    _snack(
                      context,
                      context.l10n.missingPlural11MonitorWindow(missing),
                      error: true,
                    );
                  }
                }),
              )
            : null,
      );
}
    final search = _terminalSearches[id];
    final surface = kIsWeb
        ? _webTerminalInputSurface(
            tab,
            autofocus: id == app.activeTerminalTabId,
          )
        : TerminalView(
            tab.terminal,
            key: _viewKeyFor(id),
            controller: search?.controller,
            scrollController: search?.scrollController,
            focusNode: _focusNodeFor(id),
            autofocus: id == app.activeTerminalTabId,
            hardwareKeyboardOnly: false,
            showKeyboardOnTap: !terminalTouchKeyboardOnDemand,
            readOnly: tab.state != 'connected',
            onKeyEvent: (_, event) => _handleTerminalKeyEvent(id, event),
            padding: const EdgeInsets.all(12),
            backgroundOpacity: wallpaperTerminalBackgroundOpacity(context),
            textStyle: TerminalStyle(
              fontSize: app.terminalFontSize.toDouble(),
              fontFamily: 'monospace',
            ),
            theme: terminalColorThemeOf(context, app.terminalTheme),
          );
    return GestureDetector(
      onSecondaryTapDown: (event) => unawaited(
        showWorkspaceContextMenu(context, event.globalPosition, [
          if (tab.host?.protocol.isTerminal == true && tab.console == null)
            WorkspaceAction('terminal-disconnect-$id', context.l10n.disconnect,
              Icons.link_off, () => app.disconnectTerminalTab(id),
              enabled: tab.state == 'connected' || tab.state == 'connecting' ||
                  tab.recovery?.automaticEnabled == true),
          WorkspaceAction(
            'terminal-properties-$id',
            context.l10n.properties,
            Icons.info_outline,
            () => showHostProperties(context, tab.host!, state: terminalStateLabel(context.l10n, tab.state)),
            enabled: tab.host != null,
          ),
          WorkspaceAction(
            'terminal-files-$id',
            context.l10n.browseFiles,
            Icons.folder_open_outlined,
            () {
              app.activateTerminalTab(id);
              app.showWorkspacePage(WorkspacePage.sftp);
            },
            enabled: tab.connection != null,
          ),
        ]),
      ),
      child: Column(
        children: [
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                app.activateTerminalTab(id);
                if (terminalTouchKeyboardOnDemand) {
                  // Touch only focuses; the keybar button opens the keyboard.
                  _focusTerminalWithoutKeyboard(id);
                } else {
                  _requestTerminalKeyboard(id, fromUserGesture: true);
                }
              },
              child: MergeSemantics(
                child: Semantics(
                  label: context.l10n.sshTerminalInput,
                  textField: true,
                  enabled: tab.liveTerminalTransport != null,
                  onTap: () =>
                      _requestTerminalKeyboard(id, fromUserGesture: true),
                  child: surface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _focusConnectedTerminalAfterMount(String id, Object connection) {
    if (_focusRequestedForTab == id) return;
    _focusRequestedForTab = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          app.activeTerminalTabId != id ||
          !identical(app.terminalTabFor(id)?.liveTerminalTransport, connection)) {
        return;
      }
      _requestTerminalKeyboard(id);
    });
  }

  Widget _webTerminalInputSurface(
    TerminalTabSession tab, {
    bool autofocus = true,
  }) {
    final focusNode = _focusNodeFor(tab.id);
    final viewKey = _viewKeyFor(tab.id);
    final terminalView = TerminalView(
      tab.terminal,
      key: viewKey,
      controller: _terminalSearches[tab.id]?.controller,
      scrollController: _terminalSearches[tab.id]?.scrollController,
      focusNode: focusNode,
      autofocus: autofocus,
      hardwareKeyboardOnly: false,
      onKeyEvent: (_, event) => _handleTerminalKeyEvent(tab.id, event),
      padding: const EdgeInsets.all(14),
      backgroundOpacity: wallpaperTerminalBackgroundOpacity(context),
      textStyle: TerminalStyle(
        fontSize: app.terminalFontSize.toDouble(),
        fontFamily: 'monospace',
      ),
      theme: terminalColorThemeOf(context, app.terminalTheme),
    );

    // Keep Web's editable semantics node beside the repainting terminal
    // surface. Merging it with the terminal's changing scroll semantics lets
    // Flutter detach the active DOM input during remote echo updates.
    return Stack(
      children: [
        Positioned.fill(child: ExcludeSemantics(child: terminalView)),
        Positioned(
          left: 0,
          top: 0,
          child: ListenableBuilder(
            listenable: focusNode,
            builder: (context, _) => Semantics(
              label: context.l10n.sshTerminalInput,
              textField: true,
              container: true,
              enabled: true,
              focusable: true,
              focused: focusNode.hasFocus,
              onFocus: () =>
                  _requestTerminalKeyboard(tab.id, fromUserGesture: true),
              onTap: () =>
                  _requestTerminalKeyboard(tab.id, fromUserGesture: true),
              child: const SizedBox(width: 1, height: 1),
            ),
          ),
        ),
      ],
    );
  }

  Widget _liveSplitTerminalViews(
    WorkspaceRecord workspace,
    List<TerminalTabSession?> tabs,
  ) {
    final tree = workspace.layoutTree;
    if (tree == null) return const SizedBox.shrink();
    var splitIndex = 0;
    Widget buildNode(WorkspaceLayoutNode node) {
      if (node is WorkspaceTerminalNode) {
        final paneIndex = workspace.panes.indexWhere(
          (pane) => pane.paneId == node.paneId,
        );
        if (paneIndex < 0 || paneIndex >= tabs.length) {
          return const SizedBox.shrink();
        }
        final tab = tabs[paneIndex];
        return tab?.connection != null || tab?.telnet != null
            ? _liveSplitTerminalPane(workspace, tab!, paneIndex)
            : _disconnectedLiveSplitPane(workspace, paneIndex);
      }
      final split = node as WorkspaceSplitNode;
      final index = splitIndex++;
      return _SplitWorkspaceLayoutPreview(
        keyPrefix: index == 0
            ? 'workspace-live-split'
            : 'workspace-live-split-nested-$index',
        axis: split.axis,
        ratioBasisPoints: split.splitRatioBasisPoints,
        firstPane: buildNode(split.first),
        secondPane: buildNode(split.second),
      );
    }

    return buildNode(tree);
  }

  Widget _liveSplitTerminalPane(
    WorkspaceRecord workspace,
    TerminalTabSession tab,
    int index,
  ) {
    final search = _terminalSearches[tab.id];
    final host = tab.host;
    final sftpActionLabel = context.l10n.browseFilesOnValuevalue(host?.name ?? 'terminal');
    final Widget inputSurface;
    if (kIsWeb) {
      inputSurface = _webTerminalInputSurface(
        tab,
        autofocus: tab.id == app.activeTerminalTabId,
      );
    } else {
      inputSurface = MergeSemantics(
        child: Semantics(
          label: context.l10n.sshTerminalInput,
          textField: true,
          enabled: true,
          onFocus: () => _requestTerminalKeyboard(tab.id),
          onTap: () => _requestTerminalKeyboard(tab.id, fromUserGesture: true),
          child: TerminalView(
            tab.terminal,
            key: _viewKeyFor(tab.id),
            controller: search?.controller,
            scrollController: search?.scrollController,
            focusNode: _focusNodeFor(tab.id),
            autofocus: tab.id == app.activeTerminalTabId,
            hardwareKeyboardOnly: false,
            showKeyboardOnTap: !terminalTouchKeyboardOnDemand,
            onKeyEvent: (_, event) => _handleTerminalKeyEvent(tab.id, event),
            padding: const EdgeInsets.all(10),
            backgroundOpacity: wallpaperTerminalBackgroundOpacity(context),
            textStyle: TerminalStyle(
              fontSize: app.terminalFontSize.toDouble(),
              fontFamily: 'monospace',
            ),
            theme: terminalColorThemeOf(context, app.terminalTheme),
          ),
        ),
      );
    }

    return Container(
      key: ValueKey(
        'workspace-live-split-pane-${workspace.panes[index].paneId}',
      ),
      decoration: BoxDecoration(
        color: wallpaperWindowFill(context, const Color(0xFF080C11)),
        border: Border.all(color: context.palette.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      // Stable slot: follow-splits wallpaper for this pane (incl. its chrome).
      child: WallpaperPaneBackdrop(
        child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.paneValuevalueValuevalue2Valuevalue3(index + 1, host?.name ?? 'Terminal', host?.endpoint ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.searchValuevalueScrollback(host?.name ?? 'terminal'),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    app.activateTerminalTab(tab.id);
                    _openTerminalSearch(tab);
                  },
                  icon: const Icon(Icons.search, size: 16),
                ),
                IconButton(
                  key: ValueKey(
                    'workspace-live-split-sftp-${workspace.id}-${workspace.panes[index].paneId}',
                  ),
                  tooltip: sftpActionLabel,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    app.activateTerminalTab(tab.id);
                    app.showWorkspacePage(WorkspacePage.sftp);
                  },
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                ),
              ],
            ),
          ),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                app.activateTerminalTab(tab.id);
                if (terminalTouchKeyboardOnDemand) {
                  // Touch only focuses; the keybar button opens the keyboard.
                  _focusTerminalWithoutKeyboard(tab.id);
                } else {
                  _requestTerminalKeyboard(tab.id, fromUserGesture: true);
                }
              },
              child: _terminalToolsLayout(tab, inputSurface),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _disconnectedLiveSplitPane(WorkspaceRecord workspace, int index) {
    final pane = workspace.panes[index];
    final host = app.hosts.where((item) => item.id == pane.hostId).firstOrNull;
    return Container(
      key: ValueKey('workspace-live-split-pane-${pane.paneId}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: context.palette.surface,
        border: Border.all(color: context.palette.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            context.l10n.paneValuevalueValuevalue2(index + 1, host?.name ?? context.l10n.missingHost),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.palette.muted, fontSize: 10),
          ),
          const SizedBox(height: 4),
          Text(
            host == null ? context.l10n.hostUnavailable : context.l10n.disconnected2,
            style: TextStyle(color: context.palette.muted, fontSize: 10),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            key: ValueKey(
              'workspace-live-split-connect-${workspace.id}-${pane.paneId}',
            ),
            onPressed: host == null
                ? null
                : () async {
                    try {
                      await app.connectWorkspacePane(workspace.id, pane.paneId);
                    } catch (error) {
                      if (mounted) {
                        _snack(context, app.friendlyError(error), error: true);
                      }
                    }
                  },
            icon: const Icon(Icons.play_arrow_rounded, size: 15),
            label: Text(context.l10n.connect, style: const TextStyle(fontSize: 10)),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  void _focusTerminalWithoutKeyboard(String id) {
    if (app.activeTerminalTabId != id ||
        app.terminalTabFor(id)?.liveTerminalTransport == null) {
      return;
    }
    final view = _viewKeyFor(id).currentState;
    if (view != null) {
      view.requestFocusWithoutKeyboard();
    } else {
      _focusNodeFor(id).requestFocus();
    }
  }

  void _requestTerminalKeyboard(String id, {bool fromUserGesture = false}) {
    final focusNode = _focusNodeFor(id);
    final viewKey = _viewKeyFor(id);
    if (app.activeTerminalTabId != id ||
        app.terminalTabFor(id)?.liveTerminalTransport == null) {
      return;
    }
    if (fromUserGesture && focusNode.hasFocus) {
      // If connection autofocus has already placed focus, show the existing
      // Web TextInput connection on the pointer/semantic event stack itself.
      viewKey.currentState?.requestKeyboard();
    }
    focusNode.requestFocus();
    void openWhenFocused() {
      if (!mounted ||
          app.activeTerminalTabId != id ||
          app.terminalTabFor(id)?.liveTerminalTransport == null ||
          !focusNode.hasFocus) {
        return;
      }
      viewKey.currentState?.requestKeyboard();
    }

    if (fromUserGesture) {
      // FocusManager applies the request in a microtask. Open TextInput in the
      // same browser activation task so WebKit/Chromium allow the editable host
      // to attach and receive subsequent hardware keyboard events.
      scheduleMicrotask(() {
        if (focusNode.hasFocus && app.activeTerminalTabId == id) {
          openWhenFocused();
        } else {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => openWhenFocused(),
          );
        }
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => openWhenFocused());
  }

  Future<void> _connect(HostRecord host) async {
    try {
      await app.openTerminalTab(host);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _startTerminalShare(TerminalTabSession tab) async {
    try {
      final choices = await app.terminalShareEligibleDevices();
      if (!mounted) return;
      if (choices.isEmpty) {
        _snack(
          context,
          context.l10n.noOtherActiveVaultDevicesCan,
          error: true,
        );
        return;
      }
      final selected = await showAppDialog<TerminalShareStartSelection>(
        context: context,
        builder: (_) => _TerminalShareDevicePicker(choices: choices),
      );
      if (!mounted || selected == null || selected.devices.isEmpty) return;
      await app.startTerminalShareFor(
        tab.id,
        selected.devices,
        allowInputControl: selected.allowInputControl,
      );
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : context.l10n.couldNotStartTerminalSharingCheck;
      _snack(context, message, error: true);
    }
  }

  Future<void> _grantTerminalShareControl(TerminalTabSession tab) async {
    final choices = app.terminalShareApprovedObserversFor(tab.id);
    if (choices.isEmpty) return;
    final deviceId = await showAppDialog<String>(
      context: context,
      builder: (_) => _TerminalShareControllerPicker(choices: choices),
    );
    if (!mounted || deviceId == null) return;
    try {
      await app.grantTerminalShareControl(tabId: tab.id, deviceId: deviceId);
    } catch (error) {
      if (mounted) {
        final message = error is StateError
            ? error.message.toString()
            : context.l10n.couldNotGrantInputControlCheck;
        _snack(context, message, error: true);
      }
    }
  }

  Future<void> _revokeTerminalShareControl(TerminalTabSession tab) async {
    try {
      await app.revokeTerminalShareControl(tab.id);
    } catch (_) {
      if (mounted) {
        _snack(
          context,
          context.l10n.couldNotConfirmInputControlRevocation,
          error: true,
        );
      }
    }
  }

  Future<void> _joinTerminalShare() async {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TerminalShareJoinDialog(app: app),
    );
  }

  Future<void> _showTerminalCommandSuggestions(TerminalTabSession tab) async {
    if (tab.connection == null ||
        tab.closed ||
        app.activeTerminalTabId != tab.id) {
      return;
    }
    var queryText = '';
    String? selectedCommand;
    selectedCommand = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final suggestions = app.terminalCommandSuggestionsFor(
            tab.id,
            queryText,
          );
          return AlertDialog(
            key: const ValueKey('terminal-command-suggestions-dialog'),
            title: Text(context.l10n.commandSuggestions),
            content: SizedBox(
              width: appDialogWidth(context, 620),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.searchThisHostsCompletedCommandsPlain,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('terminal-command-suggestion-query'),
                    autofocus: true,
                    onChanged: (value) =>
                        setDialogState(() => queryText = value),
                    decoration: InputDecoration(
                      labelText: context.l10n.filterCommands,
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (queryText.trim().isEmpty)
                    Text(context.l10n.typeACommandFragmentToSee)
                  else if (suggestions.isEmpty)
                    Text(context.l10n.noMatchingSingleLineCommands)
                  else ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(context.l10n.countSuggestions(suggestions.length)),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (
                            var index = 0;
                            index < suggestions.length;
                            index++
                          )
                            ListTile(
                              key: ValueKey(
                                'terminal-command-suggestion-$index',
                              ),
                              dense: true,
                              title: Text(
                                suggestions[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                              onTap: () => Navigator.pop(
                                dialogContext,
                                suggestions[index],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.close),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || selectedCommand == null) return;
    if (!app.insertTerminalCommandSuggestionFor(tab.id, selectedCommand)) {
      _snack(
        context,
        context.l10n.theTerminalChangedBeforeTheSuggestion,
        error: true,
      );
      return;
    }
    _requestTerminalKeyboard(tab.id, fromUserGesture: true);
  }

  KeyEventResult _handleTerminalKeyEvent(String tabId, KeyEvent event) {
    final windowResult = handleNewWindowKeyEvent(context, event);
    if (windowResult == KeyEventResult.handled) return windowResult;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    return dispatchTerminalShortcut(
      bindings: app.terminalShortcutBindings,
      logicalKey: event.logicalKey,
      controlPressed: HardwareKeyboard.instance.isControlPressed,
      metaPressed: HardwareKeyboard.instance.isMetaPressed,
      altPressed: HardwareKeyboard.instance.isAltPressed,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      platform: defaultTargetPlatform,
      onAction: (action) {
        final tab = app.terminalTabFor(tabId);
        if (tab == null || tab.connection == null) return;
        switch (action) {
          case TerminalShortcutAction.search:
            _openTerminalSearch(tab);
          case TerminalShortcutAction.searchNext:
            final search = _terminalSearches[tabId];
            if (search?.isOpen != true) {
              _openTerminalSearch(tab);
            } else {
              search!.nextMatch();
            }
          case TerminalShortcutAction.searchPrevious:
            final search = _terminalSearches[tabId];
            if (search?.isOpen != true) {
              _openTerminalSearch(tab);
            } else {
              search!.previousMatch();
            }
          case TerminalShortcutAction.disconnect:
            unawaited(app.disconnectTerminalTab(tabId));
        }
      },
    );
  }

  Future<void> _showShellIntegration(TerminalTabSession tab) async {
    unawaited(app.loadShellHistorySyncPreference().catchError((Object _) {}));
    var enabled = app.shellIntegrationActiveFor(tab.id);
    var syncBusy = false;
    String? bootstrapCommand;
    String? copyError;
    String? syncError;
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Semantics(
            header: true,
            child: Text(
              enabled ? context.l10n.commandHistory : context.l10n.enableBashIntegration,
              semanticsLabel: enabled
                  ? context.l10n.commandHistory
                  : context.l10n.enableBashIntegration,
            ),
          ),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: appDialogWidth(context, 560), maxHeight: 560),
            child: SizedBox(
              width: appDialogWidth(context, 560),
              child: AnimatedBuilder(
                animation: app,
                builder: (context, _) {
                  final history = app
                      .shellIntegrationHistoryFor(tab.id)
                      .reversed
                      .toList(growable: false);
                  final emptyHistoryLabel = enabled
                      ? context.l10n.noCommandEventsReceivedYetPaste
                      : context.l10n.commandsAppearHereAfterTheHook;
                  final hasActiveVault = app.activeVault != null;
                  final syncEnabled = app.shellHistorySyncEnabled;
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          enabled
                              ? context.l10n.theOptInRemoteBashHook
                              : context.l10n.thisIsOptInAndBash,
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile.adaptive(
                          key: const ValueKey('shell-history-vault-sync'),
                          contentPadding: EdgeInsets.zero,
                          value: syncEnabled,
                          onChanged: syncBusy || !hasActiveVault
                              ? null
                              : (value) async {
                                  if (value) {
                                    final confirmed = await showAppDialog<bool>(
                                      context: dialogContext,
                                      builder: (confirmationContext) =>
                                          AlertDialog(
                                            title: Text(
                                              context.l10n.syncCommandHistoryToThisVault,
                                            ),
                                            content: Text(
                                              context.l10n.enablingSyncUploadsUpTo500,
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  confirmationContext,
                                                  false,
                                                ),
                                                child: Text(context.l10n.cancel2),
                                              ),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(
                                                  confirmationContext,
                                                  true,
                                                ),
                                                child: Text(
                                                  context.l10n.enableVaultSync,
                                                ),
                                              ),
                                            ],
                                          ),
                                    );
                                    if (confirmed != true ||
                                        !dialogContext.mounted) {
                                      return;
                                    }
                                  }

                                  setDialogState(() {
                                    syncBusy = true;
                                    syncError = null;
                                  });
                                  try {
                                    await app.setShellHistorySyncEnabled(value);
                                    if (dialogContext.mounted) {
                                      setDialogState(() {
                                        syncBusy = false;
                                      });
                                    }
                                  } on Object {
                                    if (dialogContext.mounted) {
                                      setDialogState(() {
                                        syncBusy = false;
                                        syncError = value
                                            ? context.l10n.couldNotEnableVaultHistorySync
                                            : context.l10n.couldNotTurnOffVaultHistory;
                                      });
                                    }
                                  }
                                },
                          title: Text(context.l10n.syncCommandHistoryToVault),
                          subtitle: Text(
                            !hasActiveVault
                                ? context.l10n.selectAnActiveVaultBeforeEnabling
                                : syncEnabled
                                ? context.l10n.encryptedWithTheActiveVaultKey
                                : context.l10n.offByDefaultEnablingUploadsUp,
                          ),
                        ),
                        if (syncBusy)
                          const Padding(
                            padding: EdgeInsets.only(left: 12, bottom: 8),
                            child: LinearProgressIndicator(),
                          ),
                        if (syncError != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 12, bottom: 8),
                            child: Text(
                              syncError!,
                              style: TextStyle(color: context.palette.red),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            context.l10n.clearLocalHistoryOnlyRemovesThis,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (bootstrapCommand != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            context.l10n.copiedPasteThisCommandIntoThe,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            bootstrapCommand!,
                            maxLines: 3,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ],
                        if (copyError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            copyError!,
                            style: TextStyle(color: context.palette.red),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (history.isEmpty)
                          Semantics(
                            container: true,
                            label: emptyHistoryLabel,
                            child: Text(
                              emptyHistoryLabel,
                              semanticsLabel: emptyHistoryLabel,
                              style: TextStyle(color: context.palette.muted),
                            ),
                          )
                        else ...[
                          Text(
                            '${history.length} recent command${history.length == 1 ? '' : 's'}',
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 300,
                            child: ListView.separated(
                              itemCount: history.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final command = history[index];
                                final completedAt = DateFormat('HH:mm:ss')
                                    .format(command.completedAt.toLocal());
                                final exitLabel =
                                    context.l10n.exitExitstatusCompletedat(command.exitStatus, completedAt);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Semantics(
                                        container: true,
                                        explicitChildNodes: true,
                                        label: command.command,
                                        child: SelectableText(
                                          command.command,
                                          semanticsLabel: command.command,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Semantics(
                                        container: true,
                                        explicitChildNodes: true,
                                        label: exitLabel,
                                        child: Text(
                                          exitLabel,
                                          semanticsLabel: exitLabel,
                                          style: TextStyle(
                                            color: command.exitStatus == 0
                                                ? context.palette.muted
                                                : context.palette.red,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.close),
            ),
            if (app.shellIntegrationHistoryFor(tab.id).isNotEmpty)
              TextButton(
                onPressed: () async {
                  try {
                    await app.clearTerminalShellHistoryFor(tab.id);
                    if (dialogContext.mounted) setDialogState(() {});
                  } on Object {
                    if (dialogContext.mounted) {
                      setDialogState(() {
                        copyError =
                            context.l10n.couldNotClearThisHostsLocal;
                      });
                    }
                  }
                },
                child: Text(context.l10n.clearThisHostsLocalHistory),
              ),
            if (enabled)
              TextButton(
                onPressed: () {
                  app.disableShellIntegrationFor(tab.id);
                  setDialogState(() {
                    enabled = false;
                    bootstrapCommand = null;
                  });
                },
                child: Text(context.l10n.stopLocalCapture),
              )
            else if (tab.connection != null)
              FilledButton.icon(
                onPressed: () async {
                  try {
                    final command = app.enableShellIntegrationFor(tab.id);
                    await Clipboard.setData(ClipboardData(text: command));
                    setDialogState(() {
                      enabled = true;
                      bootstrapCommand = command;
                      copyError = null;
                    });
                  } catch (_) {
                    app.disableShellIntegrationFor(tab.id);
                    setDialogState(() {
                      copyError = context.l10n.couldNotCopyTheSetupCommand;
                    });
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(context.l10n.enableAndCopy),
              ),
          ],
        ),
      ),
    );
  }

  void _openTerminalTools(
    TerminalTabSession tab,
    TerminalToolsSection section,
  ) {
    app.activateTerminalTab(tab.id);
    _focusNodeFor(tab.id).unfocus();
    _openTerminalSearch(tab);
    setState(() => _terminalSearches[tab.id]!.section = section);
  }

  Widget _terminalToolsLayout(TerminalTabSession tab, Widget child) {
    final search = _terminalSearches[tab.id];
    return TerminalToolsLayout(
      child: child,
      sidebar: search?.isOpen == true
          ? TerminalToolsSidebar(
              key: ValueKey('terminal-tools-${tab.id}'),
              section: search!.section,
              onSection: (section) => setState(() => search.section = section),
              onClose: () => _closeTerminalSearch(search),
              query: search.queryController,
              queryFocus: search.queryFocusNode,
              onQuery: search.updateQuery,
              searchStatus: search.matchCountLabel,
              previous: search.matches.isEmpty ? null : search.previousMatch,
              next: search.matches.isEmpty ? null : search.nextMatch,
              searchHistory: search.searchHistory,
              onSearchKey: (_, event) => _handleTerminalKeyEvent(tab.id, event),
              loadCommands: () async => terminalQuickCommands(app.snippets),
              editCommand: (existing) async {
                final draft = await editTerminalQuickCommand(
                  context,
                  existing: existing,
                );
                if (draft == null ||
                    !mounted ||
                    tab.closed ||
                    app.workspaceLocked)
                  return;
                final original = app.snippets
                    .where((s) => s.id == draft.id)
                    .firstOrNull;
                if (existing != null &&
                    (original == null ||
                        original.body != existing.command ||
                        terminalQuickCommands([original]).isEmpty))
                  {
throw StateError(context.l10n.snippetChanged);
}
                await app.saveSnippet(
                  updateTerminalQuickCommand(original, draft),
                );
              },
              deleteCommand: (item) async {
                final original = app.snippets
                    .where((s) => s.id == item.id)
                    .firstOrNull;
                if (original != null) await app.deleteSnippet(original);
              },
              history: () => [
                for (final command
                    in app.shellIntegrationHistoryFor(tab.id).reversed)
                  TerminalCommandItem(
                    id: '${command.commandId}-${command.completedAt.microsecondsSinceEpoch}',
                    title:
                        context.l10n.tolocalExitExitstatus(command.completedAt.toLocal(), command.exitStatus),
                    command: command.command,
                  ),
              ],
              historyChanges: app,
              onInsert: (command) {
                if (!isSafeTerminalCommand(command) ||
                    app.activeTerminalTabId != tab.id ||
                    tab.closed ||
                    tab.state != 'connected' ||
                    app.workspaceLocked)
                  return false;
                app.sendTerminalInputFor(tab.id, command);
                _requestTerminalKeyboard(tab.id, fromUserGesture: true);
                return true;
              },
              onConfigureHistory: () => _showShellIntegration(tab),
              onClearHistory: () => app.clearTerminalShellHistoryFor(tab.id),
              historyNotice: () => app.shellIntegrationActiveFor(tab.id)
                  ? context.l10n.bashRecordingIsOnUpTo
                  : context.l10n.completedCommandsAreRecordedAfterEnabling2,
            )
          : null,
    );
  }

  void _openTerminalSearch(TerminalTabSession tab) {
    final search = _terminalSearches.putIfAbsent(
      tab.id,
      () => _TerminalSearchSession(
        tab.terminal,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
    setState(() {
      search.isOpen = true;
      search.section = TerminalToolsSection.search;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          search.isOpen &&
          search.section == TerminalToolsSection.search)
        search.queryFocusNode.requestFocus();
    });
  }

  /// Binds the shared forwarding dialog to this tab's Host inside the Vault
  /// that was active when it opened. Profiles persist through the normal
  /// encrypted Host save path; the runtime follows the tab's live connection.
  Future<void> _openPortForwarding(TerminalTabSession tab) async {
    final hostId = tab.host?.id;
    final vaultId = app.activeVault?.id;
    bool inScope() =>
        hostId != null && vaultId != null && app.activeVault?.id == vaultId;
    await showSshPortForwardingDialog(
      context,
      hostName: tab.host?.name ?? 'SSH',
      changes: app,
      storageDescription:
          context.l10n.profilesAreEncryptedInsideThisHost,
      profiles: () => inScope()
          ? app.hosts
                .where((host) => host.id == hostId)
                .firstOrNull
                ?.portForwardProfiles
          : null,
      saveProfiles: (profiles) {
        if (!inScope()) {
          throw StateError(context.l10n.theVaultChangedReopenPortForwarding);
        }
        return app.saveHostPortForwardProfiles(
          hostId: hostId!,
          profiles: profiles,
        );
      },
      manager: () => tab.closed || tab.state != 'connected'
          ? null
          : tab.connection?.portForwards,
      canEdit: () => inScope() && app.activeVault?.canWrite == true,
      readOnlyReason: context.l10n.youHaveReadOnlyAccessTo,
      describeSaveError: (_) =>
          context.l10n.couldNotSaveForwardingSettingsSync,
    );
    // Menu labels show the running count; refresh them after the dialog.
    if (mounted) setState(() {});
  }

  void _closeTerminalSearch(_TerminalSearchSession search) {
    search.queryFocusNode.unfocus();
    setState(search.closeSearch);
  }

  void _pruneClosedTerminalState() {
    final openIds = app.terminalTabs.map((tab) => tab.id).toSet();
    for (final id in _terminalFocusNodes.keys.toList()) {
      if (!openIds.contains(id)) _terminalFocusNodes.remove(id)?.dispose();
    }
    _terminalViewKeys.removeWhere((id, _) => !openIds.contains(id));
    for (final id in _terminalSearches.keys.toList()) {
      if (!openIds.contains(id)) _terminalSearches.remove(id)?.dispose();
    }
  }
}

class _SafeSshUserInfoPrompt {
  const _SafeSshUserInfoPrompt({required this.text, required this.echo});

  final String text;
  final bool echo;
}

class _SshUserInfoDialog extends StatefulWidget {
  const _SshUserInfoDialog({
    required this.hostLabel,
    required this.requestName,
    required this.instruction,
    required this.prompts,
    required this.promptLimitExceeded,
  });

  final String hostLabel;
  final String requestName;
  final String instruction;
  final List<_SafeSshUserInfoPrompt> prompts;
  final bool promptLimitExceeded;

  @override
  State<_SshUserInfoDialog> createState() => _SshUserInfoDialogState();
}

class _SshUserInfoDialogState extends State<_SshUserInfoDialog> {
  late final _responses = List<TextEditingController>.generate(
    widget.prompts.length,
    (_) => TextEditingController(),
    growable: false,
  );

  void _clearResponses() {
    for (final response in _responses) {
      response.clear();
    }
  }

  void _cancel() {
    _clearResponses();
    Navigator.of(context).pop();
  }

  void _submit() {
    if (widget.promptLimitExceeded) return;
    final responses = _responses.map((controller) => controller.text).toList();
    _clearResponses();
    Navigator.of(context).pop(responses);
  }

  @override
  void dispose() {
    _clearResponses();
    for (final response in _responses) {
      response.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('ssh-user-info-dialog'),
    title: Text(context.l10n.sshAuthenticationChallenge),
    content: SizedBox(
      width: appDialogWidth(context, 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.hostLabel,
              key: const ValueKey('ssh-user-info-host'),
              style: TextStyle(color: context.palette.muted),
            ),
            if (widget.requestName.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.requestName,
                key: const ValueKey('ssh-user-info-name'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (widget.instruction.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                widget.instruction,
                key: const ValueKey('ssh-user-info-instruction'),
              ),
            ],
            if (widget.promptLimitExceeded) ...[
              const SizedBox(height: 14),
              Text(
                context.l10n.theSshServerRequestedTooMany,
                key: const ValueKey('ssh-user-info-prompt-limit'),
                style: TextStyle(color: context.palette.red),
              ),
            ] else if (widget.prompts.isEmpty) ...[
              const SizedBox(height: 14),
              Text(context.l10n.theServerDidNotRequestA),
            ] else ...[
              const SizedBox(height: 14),
              for (var index = 0; index < widget.prompts.length; index++) ...[
                if (index > 0) const SizedBox(height: 10),
                TextField(
                  key: ValueKey('ssh-user-info-response-$index'),
                  controller: _responses[index],
                  autofocus: index == 0,
                  obscureText: !widget.prompts[index].echo,
                  autocorrect: false,
                  enableSuggestions: widget.prompts[index].echo,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: widget.prompts[index].echo
                      ? TextInputType.text
                      : TextInputType.visiblePassword,
                  maxLength: 4096,
                  decoration: InputDecoration(
                    labelText: widget.prompts[index].text.isEmpty
                        ? context.l10n.responseValuevalue(index + 1)
                        : widget.prompts[index].text,
                    counterText: '',
                  ),
                  onSubmitted: index == widget.prompts.length - 1
                      ? (_) => _submit()
                      : null,
                ),
              ],
            ],
            const SizedBox(height: 10),
            Text(
              context.l10n.responsesAreSentOnlyForThis,
              key: const ValueKey('ssh-user-info-not-saved'),
              style: TextStyle(color: context.palette.muted),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('ssh-user-info-cancel'),
        onPressed: _cancel,
        child: Text(
          widget.promptLimitExceeded ? context.l10n.stopAuthentication : context.l10n.cancel2,
        ),
      ),
      if (!widget.promptLimitExceeded)
        FilledButton(
          key: const ValueKey('ssh-user-info-submit'),
          onPressed: _submit,
          child: Text(context.l10n.sendResponses),
        ),
    ],
  );
}

class _StagedWorkspaceLayout extends StatelessWidget {
  const _StagedWorkspaceLayout({required this.app, required this.workspace});

  final AppController app;
  final WorkspaceRecord workspace;

  @override
  Widget build(BuildContext context) {
    final splitRatio = workspace.splitRatioBasisPoints ?? 5000;
    final firstPercent = splitRatio ~/ 100;
    final secondPercent = 100 - firstPercent;
    final livePanes = workspace.isSplit
        ? workspace.panes
              .map(
                (pane) =>
                    app.workspacePaneTerminalTab(workspace.id, pane.paneId),
              )
              .where((tab) => tab?.connection != null)
              .length
        : 0;
    final directionLabel = switch (workspace.splitAxis) {
      WorkspaceSplitAxis.horizontal => context.l10n.sideBySide,
      WorkspaceSplitAxis.vertical => context.l10n.stacked,
      null => '',
    };
    final paneCount = workspace.panes.length;
    final statusLine = workspace.isSplit
        ? livePanes == 0
              ? context.l10n.disconnectedDirectionlabelFirstpercentSecondpercentPanecountPanes(directionLabel, firstPercent, secondPercent, paneCount)
              : '$livePanes/$paneCount live · $directionLabel · $firstPercent/$secondPercent · Connect each pane explicitly'
        : context.l10n.disconnectedConnectTabsExplicitly;
    return SizedBox(
      height: 170,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
        decoration: BoxDecoration(
          color: context.palette.surface,
          border: Border(bottom: BorderSide(color: context.palette.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 15,
                  color: context.palette.teal,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    workspace.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('workspace-clear-staged'),
                  tooltip: context.l10n.closeSavedLayoutPreview,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 27,
                    height: 27,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: app.clearStagedWorkspace,
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              ],
            ),
            Text(
              statusLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: context.palette.muted),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: workspace.isSplit
                  ? _savedWorkspaceSplitPreview(app, workspace)
                  : ListView.builder(
                      itemCount: workspace.panes.length,
                      itemBuilder: (context, index) {
                        final pane = workspace.panes[index];
                        final host = app.hosts
                            .where((item) => item.id == pane.hostId)
                            .firstOrNull;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: OutlinedButton.icon(
                            key: ValueKey(
                              'workspace-connect-${workspace.id}-${pane.paneId}',
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 31),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: host == null
                                ? null
                                : () async {
                                    try {
                                      await app.connectWorkspacePane(
                                        workspace.id,
                                        pane.paneId,
                                      );
                                    } catch (error) {
                                      if (context.mounted) {
                                        _snack(
                                          context,
                                          app.friendlyError(error),
                                          error: true,
                                        );
                                      }
                                    }
                                  },
                            icon: Icon(
                              host == null
                                  ? Icons.link_off_rounded
                                  : Icons.play_arrow_rounded,
                              size: 14,
                            ),
                            label: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                host == null
                                    ? context.l10n.tabValuevalueMissingHost(index + 1)
                                    : context.l10n.tabValuevalueName(index + 1, host.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _savedWorkspaceSplitPreview(
  AppController app,
  WorkspaceRecord workspace,
) {
  final tree = workspace.layoutTree;
  if (tree == null) return const SizedBox.shrink();
  var splitIndex = 0;
  Widget buildNode(WorkspaceLayoutNode node) {
    if (node is WorkspaceTerminalNode) {
      final paneIndex = workspace.panes.indexWhere(
        (pane) => pane.paneId == node.paneId,
      );
      if (paneIndex < 0) return const SizedBox.shrink();
      return _StagedSplitWorkspacePane(
        app: app,
        workspace: workspace,
        index: paneIndex,
      );
    }
    final split = node as WorkspaceSplitNode;
    final index = splitIndex++;
    return _SplitWorkspaceLayoutPreview(
      key: ValueKey(
        index == 0
            ? 'workspace-split-preview-${split.axis.name}'
            : 'workspace-split-preview-nested-$index-${split.axis.name}',
      ),
      keyPrefix: index == 0
          ? 'workspace-split'
          : 'workspace-split-nested-$index',
      axis: split.axis,
      ratioBasisPoints: split.splitRatioBasisPoints,
      firstPane: buildNode(split.first),
      secondPane: buildNode(split.second),
    );
  }

  return buildNode(tree);
}

class _StagedSplitWorkspacePane extends StatelessWidget {
  const _StagedSplitWorkspacePane({
    required this.app,
    required this.workspace,
    required this.index,
  });

  final AppController app;
  final WorkspaceRecord workspace;
  final int index;

  @override
  Widget build(BuildContext context) {
    final pane = workspace.panes[index];
    final host = app.hosts.where((item) => item.id == pane.hostId).firstOrNull;
    final connected =
        app.workspacePaneTerminalTab(workspace.id, pane.paneId)?.connection !=
        null;
    final connectButton = OutlinedButton(
      key: ValueKey('workspace-connect-${workspace.id}-${pane.paneId}'),
      style: OutlinedButton.styleFrom(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: host == null
          ? null
          : () async {
              try {
                await app.connectWorkspacePane(workspace.id, pane.paneId);
              } catch (error) {
                if (context.mounted) {
                  _snack(context, app.friendlyError(error), error: true);
                }
              }
            },
      child: Text(
        connected ? context.l10n.focus : context.l10n.connect,
        style: const TextStyle(fontSize: 8),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 100;
        final short = constraints.maxHeight < 48;
        return Container(
          key: ValueKey('workspace-split-pane-$index'),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: context.palette.surface,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: context.palette.line),
          ),
          child: narrow && !short
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.paneValuevalue(index + 1),
                      style: TextStyle(
                        color: context.palette.teal,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      host?.name ?? context.l10n.missingHost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9),
                    ),
                    connectButton,
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: short
                          ? Text(
                              context.l10n.paneValuevalueValuevalue2(index + 1, host?.name ?? context.l10n.missingHost),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 9),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.paneValuevalue(index + 1),
                                  style: TextStyle(
                                    color: context.palette.teal,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  host?.name ?? context.l10n.missingHost,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(width: 5),
                    connectButton,
                  ],
                ),
        );
      },
    );
  }
}

class _TerminalSearchSession {
  _TerminalSearchSession(this.terminal, {required this.onChanged}) {
    terminal.addListener(_onTerminalChanged);
  }

  static const _currentHighlightColor = Color(0xFF8A6620);
  static const _matchHighlightColor = Color(0xFF514A2F);

  final Terminal terminal;
  final VoidCallback onChanged;
  final controller = TerminalController();
  final scrollController = ScrollController();
  final queryController = TextEditingController();
  final queryFocusNode = FocusNode(debugLabel: 'terminal scrollback search');
  List<TerminalSearchMatch> matches = const [];
  final List<TerminalHighlight> _matchHighlights = [];
  int selectedIndex = -1;
  bool isOpen = false;
  TerminalToolsSection section = TerminalToolsSection.search;
  final searchHistory = TerminalSearchHistory();
  bool _resultsTruncated = false;
  bool _isSearching = false;
  bool _queryTooLong = false;
  TerminalHighlight? _selectedHighlight;
  Timer? _refreshTimer;

  String get matchCountLabel => terminalSearchCountLabel(
    matchCount: matches.length,
    selectedIndex: selectedIndex,
    truncated: _resultsTruncated,
    searching: _isSearching,
    queryTooLong: _queryTooLong,
  );

  void updateQuery(String value) {
    _refreshTimer?.cancel();
    _queryTooLong = false;
    if (value.isEmpty) {
      _isSearching = false;
      _resultsTruncated = false;
      matches = const [];
      selectedIndex = -1;
      _clearHighlights();
      onChanged();
      return;
    }

    _isSearching = true;
    matches = const [];
    selectedIndex = -1;
    _clearHighlights();
    onChanged();
    _refreshTimer = Timer(const Duration(milliseconds: 160), _refreshMatches);
  }

  void _onTerminalChanged() {
    if (queryController.text.isEmpty) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 120), _refreshMatches);
  }

  void _refreshMatches() {
    final result = searchTerminalBuffer(terminal, queryController.text);
    matches = result.matches;
    _resultsTruncated = result.truncated;
    _queryTooLong = result.queryTooLong;
    _isSearching = false;
    selectedIndex = matches.isEmpty ? -1 : 0;
    _paintMatches();
    onChanged();
    if (matches.isNotEmpty) _revealSelectedMatch();
  }

  void nextMatch() {
    if (matches.isEmpty) return;
    selectedIndex = (selectedIndex + 1) % matches.length;
    _paintSelectedMatch();
    _revealSelectedMatch();
    onChanged();
  }

  void previousMatch() {
    if (matches.isEmpty) return;
    selectedIndex = (selectedIndex - 1 + matches.length) % matches.length;
    _paintSelectedMatch();
    _revealSelectedMatch();
    onChanged();
  }

  void _paintSelectedMatch() {
    _selectedHighlight?.dispose();
    _selectedHighlight = null;
    if (selectedIndex < 0 || selectedIndex >= matches.length) return;
    final match = matches[selectedIndex];
    final buffer = terminal.buffer;
    if (match.start.y >= buffer.lines.length ||
        match.end.y >= buffer.lines.length) {
      return;
    }
    _selectedHighlight = controller.highlight(
      p1: buffer.createAnchorFromOffset(match.start),
      p2: buffer.createAnchorFromOffset(match.end),
      color: _currentHighlightColor,
    );
  }

  void _paintMatches() {
    _clearHighlights();
    final buffer = terminal.buffer;
    for (final match in matches) {
      if (match.start.y >= buffer.lines.length ||
          match.end.y >= buffer.lines.length) {
        continue;
      }
      _matchHighlights.add(
        controller.highlight(
          p1: buffer.createAnchorFromOffset(match.start),
          p2: buffer.createAnchorFromOffset(match.end),
          color: _matchHighlightColor,
        ),
      );
    }
    // The selected range is painted after all normal hit ranges, so its
    // stronger color remains visible while the other hits stay highlighted.
    _paintSelectedMatch();
  }

  void _clearHighlights() {
    _selectedHighlight?.dispose();
    _selectedHighlight = null;
    for (final highlight in _matchHighlights) {
      highlight.dispose();
    }
    _matchHighlights.clear();
  }

  void _revealSelectedMatch() {
    if (selectedIndex < 0 || selectedIndex >= matches.length) return;
    final row = matches[selectedIndex].start.y;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      final position = scrollController.position;
      final totalHeight = position.maxScrollExtent + position.viewportDimension;
      final rowCount = terminal.buffer.lines.length;
      if (rowCount == 0) return;
      final rowHeight = totalHeight / rowCount;
      final target = (row * rowHeight - position.viewportDimension / 2).clamp(
        0.0,
        position.maxScrollExtent,
      );
      scrollController.jumpTo(target);
    });
  }

  void closeSearch() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    isOpen = false;
    searchHistory.remember(queryController.text);
    queryController.clear();
    matches = const [];
    selectedIndex = -1;
    _resultsTruncated = false;
    _isSearching = false;
    _queryTooLong = false;
    _clearHighlights();
  }

  void dispose() {
    _refreshTimer?.cancel();
    terminal.removeListener(_onTerminalChanged);
    closeSearch();
    controller.dispose();
    scrollController.dispose();
    queryController.dispose();
    queryFocusNode.dispose();
  }
}

class _TerminalShareDevicePicker extends StatefulWidget {
  const _TerminalShareDevicePicker({required this.choices});

  final List<TerminalShareDeviceChoice> choices;

  @override
  State<_TerminalShareDevicePicker> createState() =>
      _TerminalShareDevicePickerState();
}

class _TerminalShareDevicePickerState
    extends State<_TerminalShareDevicePicker> {
  final Set<String> _selectedDeviceIds = {};
  bool _allowInputControl = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.shareThisTerminal),
    content: SizedBox(
      width: appDialogWidth(context, 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.chooseActiveVaultDevicesThatMay,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 285),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.choices.length,
              itemBuilder: (context, index) {
                final choice = widget.choices[index];
                final selected = _selectedDeviceIds.contains(
                  choice.recipient.deviceId,
                );
                return CheckboxListTile(
                  key: ValueKey(
                    'terminal-share-device-${choice.recipient.deviceId}',
                  ),
                  value: selected,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(choice.label),
                  subtitle: Text(
                    context.l10n.deviceSubstring(choice.recipient.deviceId.substring(0, 8)),
                    style: TextStyle(color: context.palette.muted),
                  ),
                  onChanged: !selected && _selectedDeviceIds.length >= 8
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selectedDeviceIds.add(choice.recipient.deviceId);
                          } else {
                            _selectedDeviceIds.remove(
                              choice.recipient.deviceId,
                            );
                          }
                        }),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('terminal-share-enable-input-control'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _allowInputControl,
            title: Text(context.l10n.enableHostApprovedInputControl),
            subtitle: Text(
              context.l10n.createsAV2RoomInputStays,
            ),
            onChanged: (value) => setState(() {
              _allowInputControl = value == true;
            }),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.theShareExpiresAfter15Minutes,
            style: TextStyle(color: context.palette.muted, fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        key: const ValueKey('terminal-share-start-confirm'),
        onPressed: _selectedDeviceIds.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                TerminalShareStartSelection(
                  devices: widget.choices
                      .where(
                        (choice) => _selectedDeviceIds.contains(
                          choice.recipient.deviceId,
                        ),
                      )
                      .toList(growable: false),
                  allowInputControl: _allowInputControl,
                ),
              ),
        child: Text(context.l10n.startSharing),
      ),
    ],
  );
}

class _TerminalShareControllerPicker extends StatefulWidget {
  const _TerminalShareControllerPicker({required this.choices});

  final List<TerminalShareDeviceChoice> choices;

  @override
  State<_TerminalShareControllerPicker> createState() =>
      _TerminalShareControllerPickerState();
}

class _TerminalShareControllerPickerState
    extends State<_TerminalShareControllerPicker> {
  String? _selectedDeviceId;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.grantInputControl),
    content: SizedBox(
      width: appDialogWidth(context, 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.chooseOneDeviceAlreadyApprovedFor,
          ),
          const SizedBox(height: 12),
          for (final choice in widget.choices)
            RadioListTile<String>(
              key: ValueKey(
                'terminal-share-controller-device-${choice.recipient.deviceId}',
              ),
              value: choice.recipient.deviceId,
              groupValue: _selectedDeviceId,
              title: Text(choice.label),
              subtitle: Text(
                context.l10n.deviceSubstring(choice.recipient.deviceId.substring(0, 8)),
                style: TextStyle(color: context.palette.muted),
              ),
              onChanged: (value) => setState(() => _selectedDeviceId = value),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        key: const ValueKey('terminal-share-controller-grant-confirm'),
        onPressed: _selectedDeviceId == null
            ? null
            : () => Navigator.pop(context, _selectedDeviceId),
        child: Text(context.l10n.grantFor5Minutes),
      ),
    ],
  );
}

class _TerminalShareJoinDialog extends StatefulWidget {
  const _TerminalShareJoinDialog({required this.app});

  final AppController app;

  @override
  State<_TerminalShareJoinDialog> createState() =>
      _TerminalShareJoinDialogState();
}

class _TerminalShareJoinDialogState extends State<_TerminalShareJoinDialog> {
  final TextEditingController _sessionIdController = TextEditingController();
  String? _error;
  bool _busy = false;
  TerminalObserverTabSession? _observer;

  @override
  void dispose() {
    final observer = _observer;
    if (observer != null) {
      unawaited(widget.app.leaveTerminalShare(observer.id));
    }
    _sessionIdController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final observer = await widget.app.joinTerminalShare(
        _sessionIdController.text,
      );
      if (mounted) {
        setState(() => _observer = observer);
      } else {
        await widget.app.leaveTerminalShare(observer.id);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.l10n.couldNotJoinCheckTheSession;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final observer = _observer;
    if (observer != null) {
      return _TerminalObserverDialog(app: widget.app, observer: observer);
    }
    return AlertDialog(
      title: Text(context.l10n.joinASharedTerminal),
      content: SizedBox(
        width: appDialogWidth(context, 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.enterTheSessionUuidProvidedBy,
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('terminal-share-join-code'),
              controller: _sessionIdController,
              autofocus: true,
              maxLength: 36,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _join(),
              decoration: InputDecoration(
                labelText: context.l10n.sessionId,
                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!, style: TextStyle(color: context.palette.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          key: const ValueKey('terminal-share-join'),
          onPressed: _busy ? null : _join,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.join),
        ),
      ],
    );
  }
}

class _TerminalObserverDialog extends StatefulWidget {
  const _TerminalObserverDialog({required this.app, required this.observer});

  final AppController app;
  final TerminalObserverTabSession observer;

  @override
  State<_TerminalObserverDialog> createState() =>
      _TerminalObserverDialogState();
}

class _TerminalObserverDialogState extends State<_TerminalObserverDialog> {
  GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  Terminal? _terminalViewModel;
  final FocusNode _terminalFocusNode = FocusNode();
  bool _controllerWasActive = false;
  bool _controllerFocusRequestScheduled = false;

  @override
  void initState() {
    super.initState();
    _terminalFocusNode.addListener(_onTerminalFocusChanged);
  }

  @override
  void dispose() {
    _terminalFocusNode.removeListener(_onTerminalFocusChanged);
    _terminalFocusNode.dispose();
    super.dispose();
  }

  void _onTerminalFocusChanged() {
    if (mounted) setState(() {});
  }

  void _requestControllerFocusAfterBuild() {
    if (_controllerFocusRequestScheduled) return;
    _controllerFocusRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_controllerWasActive) {
        _controllerFocusRequestScheduled = false;
        return;
      }
      if (terminalTouchKeyboardOnDemand) {
        _terminalViewKey.currentState?.requestFocusWithoutKeyboard();
        _controllerFocusRequestScheduled = false;
        return;
      }
      _terminalFocusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controllerFocusRequestScheduled = false;
        if (!mounted || !_controllerWasActive) return;
        _terminalViewKey.currentState?.requestKeyboard();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        // Rejoining replaces the runtime-only Terminal so the observer gets
        // an empty buffer. Give that model a new TerminalView state too; this
        // resets the old viewport/selection anchors and binds rendering to the
        // fresh model before any post-rejoin live output arrives.
        if (!identical(_terminalViewModel, widget.observer.terminal)) {
          _terminalViewModel = widget.observer.terminal;
          _terminalViewKey = GlobalKey<TerminalViewState>();
        }
        final controller = widget.observer.controller;
        final hasController = controller?.isConnected == true;
        // Desktop Web has a hardware keyboard. Using xterm's keyboard listener
        // avoids losing printable input when Flutter Web replaces its hidden
        // TextInput host as a read-only observer becomes a controller. Mobile
        // Web keeps the regular TextInput path so the on-screen keyboard stays
        // available.
        final hardwareKeyboardOnly =
            hasController &&
            kIsWeb &&
            defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS;
        if (hasController && !_controllerWasActive) {
          _controllerWasActive = true;
          _requestControllerFocusAfterBuild();
        } else if (!hasController) {
          if (_controllerWasActive) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _controllerWasActive) return;
              _terminalViewKey.currentState?.closeKeyboard();
              _terminalFocusNode.unfocus();
            });
          }
          _controllerWasActive = false;
        }
        final grantAvailable =
            widget.observer.grantedLeaseId != null &&
            widget.observer.grantedControlExpiresAt?.isAfter(
                  DateTime.now().toUtc(),
                ) ==
                true;
        final title = hasController
            ? context.l10n.sharedTerminalHostApprovedControl
            : context.l10n.sharedTerminalReadOnly;
        return Dialog(
          child: SizedBox(
            width: (size.width - 48).clamp(320.0, 1000.0).toDouble(),
            height: (size.height - 48).clamp(280.0, 760.0).toDouble(),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.visibility_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Semantics(
                          container: true,
                          header: true,
                          label: title,
                          child: Text(
                            title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      Flexible(
                        child: Semantics(
                          container: true,
                          liveRegion: true,
                          label:
                              widget.observer.controlErrorMessage ??
                              widget.observer.errorMessage ??
                              context.l10n.observerState(widget.observer.state),
                          child: Text(
                            widget.observer.controlErrorMessage ??
                                widget.observer.errorMessage ??
                                context.l10n.observerState(widget.observer.state),
                            key: const ValueKey('terminal-share-status'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  widget.observer.controlErrorMessage != null ||
                                      widget.observer.state == 'failed'
                                  ? context.palette.red
                                  : widget.observer.state == 'connected'
                                  ? context.palette.teal
                                  : context.palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                      if (!hasController &&
                          (widget.observer.state == 'ended' ||
                              widget.observer.state == 'failed'))
                        TextButton(
                          key: const ValueKey('terminal-share-reconnect'),
                          onPressed: widget.observer.reconnecting
                              ? null
                              : () => widget.app
                                    .reconnectTerminalShare(widget.observer.id)
                                    .then<void>((_) {}, onError: (Object _) {}),
                          child: widget.observer.reconnecting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(context.l10n.reconnectObserver),
                        ),
                      if (!hasController && grantAvailable)
                        TextButton(
                          key: const ValueKey('terminal-share-controller-join'),
                          onPressed: widget.observer.joiningController
                              ? null
                              : () => widget.app
                                    .joinTerminalShareController(
                                      widget.observer.id,
                                    )
                                    .then<void>((_) {}, onError: (Object _) {}),
                          child: widget.observer.joiningController
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(context.l10n.joinHostGrantedControl),
                        ),
                      if (hasController)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            context.l10n.controlActive,
                            style: TextStyle(
                              color: context.palette.teal,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: context.l10n.leaveSharedTerminal,
                        onPressed: () {
                          unawaited(
                            widget.app.leaveTerminalShare(widget.observer.id),
                          );
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Container(
                    color: const Color(0xFF080C11),
                    padding: const EdgeInsets.all(14),
                    child: Semantics(
                      container: true,
                      label: hasController
                          ? context.l10n.hostApprovedTerminalInput
                          : context.l10n.sharedTerminalOutputReadOnly,
                      textField: hasController,
                      focused: hasController && _terminalFocusNode.hasFocus,
                      child: TerminalView(
                        widget.observer.terminal,
                        key: _terminalViewKey,
                        focusNode: _terminalFocusNode,
                        readOnly: !hasController,
                        autoResize: false,
                        autofocus:
                            hasController && !terminalTouchKeyboardOnDemand,
                        hardwareKeyboardOnly: hardwareKeyboardOnly,
                        showKeyboardOnTap: !terminalTouchKeyboardOnDemand,
                        padding: EdgeInsets.zero,
                        textStyle: TerminalStyle(
                          fontSize: widget.app.terminalFontSize.toDouble(),
                          fontFamily: 'monospace',
                        ),
                        theme: terminalColorThemeOf(
                          context,
                          widget.app.terminalTheme,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    hasController
                        ? context.l10n.inputIsEncryptedToTheHost
                        : context.l10n.outputIsEncryptedForThisDevice,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (terminalTouchKeyboardOnDemand && hasController)
                  TerminalKeybar(
                    key: const ValueKey('shared_terminal_keybar'),
                    terminal: widget.observer.terminal,
                    focusNode: _terminalFocusNode,
                    readOnly: !hasController,
                    availablePaneHeight:
                        (size.height -
                                48 -
                                MediaQuery.viewInsetsOf(context).bottom)
                            .clamp(0.0, 760.0)
                            .toDouble(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TerminalWelcome extends StatelessWidget {
  const _TerminalWelcome({required this.app, this.errorMessage});
  final AppController app;
  final String? errorMessage;

  // Welcome ⇄ connection-failed swap replays a short fade + 4 px lift so the
  // error reads as a new state; the panel holds no session or input.
  @override
  Widget build(BuildContext context) => MotionEntrance(
    trigger: errorMessage == null,
    duration: MotionDurations.standard,
    offset: const Offset(0, 4),
    child: _content(context),
  );

  Widget _content(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: context.palette.lime.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Icon(
            Icons.terminal_rounded,
            size: 29,
            color: context.palette.lime,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          errorMessage == null
              ? currentL10n.secureTerminalWorkspace
              : currentL10n.sshConnectionFailed,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (errorMessage != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.red, height: 1.45),
              ),
            ),
          )
        else
          Text(
            app.selectedHost == null
                ? currentL10n.chooseAHostOnTheLeft
                : currentL10n.connectToNameToOpenAn(app.selectedHost!.name),
            style: TextStyle(color: context.palette.muted),
          ),
        if (errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            currentL10n.chooseConnectOnTheLeftTo,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.palette.muted),
          ),
        ],
        const SizedBox(height: 14),
        if (app.selectedHost == null && app.hosts.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => app.selectHost(app.hosts.first),
            icon: const Icon(Icons.dns_outlined),
            label: Text(currentL10n.selectFirstHost),
          ),
      ],
    ),
  );
}

Future<void> _showSessionScp(
  BuildContext context,
  AppController app,
  String id,
  SshTransferDirection direction,
) async {
  final tab = app.terminalTabFor(id);
  final connection = tab?.connection;
  if (tab == null ||
      tab.closed ||
      tab.state != 'connected' ||
      connection == null)
    return;
  await showSshTransferDialog(
    context: context,
    client: connection.client,
    direction: direction,
    remotePath: direction == SshTransferDirection.upload ? tab.sftpPath : '',
    uploadIntoDirectory: direction == SshTransferDirection.upload,
    initialProtocol: SshTransferProtocol.scp,
  );
}

class _SftpPage extends StatefulWidget {
  const _SftpPage({required this.app});
  final AppController app;
  @override
  State<_SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends State<_SftpPage> {
  bool _loading = false;
  String? _error;
  Future<void> _listingQueue = Future<void>.value();
  int _latestListRequest = 0;
  String? _boundSessionId;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _boundSessionId = app.activeTerminalTabId;
    app.addListener(_handleSessionChanged);
    if (app.terminalConnection != null) {
      unawaited(_load(_boundSessionPath, sessionId: _boundSessionId));
    }
  }

  String get _boundSessionPath =>
      app.terminalTabFor(_boundSessionId)?.sftpPath ?? '/';

  @override
  void dispose() {
    app.removeListener(_handleSessionChanged);
    super.dispose();
  }

  void _handleSessionChanged() {
    final nextSessionId = app.activeTerminalTabId;
    if (nextSessionId == _boundSessionId) return;
    _boundSessionId = nextSessionId;
    _latestListRequest++;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = null;
    });
    if (nextSessionId != null &&
        app.terminalTabFor(nextSessionId)?.connection != null) {
      unawaited(
        _load(
          app.terminalTabFor(nextSessionId)?.sftpPath ?? '/',
          sessionId: nextSessionId,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = app.terminalConnection != null;
    final sftpEntries = visibleSftpEntries(app.sftpEntries);
    return Padding(
      padding: AppDensity.of(context).pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.sftpFileBrowser,
            subtitle: connected
                ? context.l10n.remoteFilesEndpoint('${app.connectedHost?.endpoint}')
                : context.l10n.connectAnSshHostToBrowse,
            trailing: connected
                ? Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _newDirectory,
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 17,
                        ),
                        label: Text(context.l10n.newFolder2),
                      ),
                      FilledButton.icon(
                        onPressed: _upload,
                        icon: const Icon(Icons.upload_rounded, size: 17),
                        label: Text(context.l10n.upload),
                      ),
                    ],
                  )
                : null,
          ),
          const SizedBox(height: 16),
          if (!connected)
            Expanded(
              child: _EmptyState(
                icon: Icons.folder_open_outlined,
                title: context.l10n.noActiveSshSession,
                body: context.l10n.openTerminalChooseAHostAnd,
                action: FilledButton.icon(
                  onPressed: () =>
                      app.showWorkspacePage(WorkspacePage.terminal),
                  icon: const Icon(Icons.terminal_rounded),
                  label: Text(context.l10n.openTerminal2),
                ),
              ),
            )
          else
            Expanded(
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      decoration: BoxDecoration(
                        color: context.palette.surfaceRaised,
                        border: Border(
                          bottom: BorderSide(color: context.palette.line),
                        ),
                      ),
                      child: Row(
                        children: [
                          Semantics(
                            button: true,
                            enabled: true,
                            label: context.l10n.upOneDirectory,
                            onTap: _up,
                            child: ExcludeSemantics(
                              child: IconButton(
                                tooltip: context.l10n.upOneDirectory,
                                onPressed: _up,
                                icon: const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Icon(
                            Icons.folder_open_outlined,
                            size: 17,
                            color: context.palette.lime,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Semantics(
                              label: context.l10n.remotePathSftppath(app.sftpPath),
                              child: ExcludeSemantics(
                                child: Text(
                                  app.sftpPath,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          Semantics(
                            button: true,
                            enabled: true,
                            label: context.l10n.goToPath,
                            onTap: _goToPath,
                            child: ExcludeSemantics(
                              child: IconButton(
                                tooltip: context.l10n.goToPath,
                                onPressed: _goToPath,
                                icon: const Icon(
                                  Icons.drive_file_move_outline,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          Semantics(
                            button: true,
                            enabled: true,
                            label: context.l10n.refresh2,
                            onTap: () => _load(app.sftpPath),
                            child: ExcludeSemantics(
                              child: IconButton(
                                tooltip: context.l10n.refresh2,
                                onPressed: () => _load(app.sftpPath),
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 19,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        color: context.palette.red.withValues(alpha: .08),
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: context.palette.red,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : sftpEntries.isEmpty
                          ? _EmptyState(
                              icon: Icons.folder_open_outlined,
                              title: context.l10n.directoryIsEmpty,
                              body: context.l10n.uploadAFileOrCreateA,
                            )
                          : ListView.separated(
                              itemCount: sftpEntries.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: 56),
                              itemBuilder: (context, index) {
                                final item = sftpEntries[index];
                                final isDirectory = item.attr.isDirectory;
                                return ListTile(
                                  leading: Icon(
                                    isDirectory
                                        ? Icons.folder_rounded
                                        : Icons.insert_drive_file_outlined,
                                    color: isDirectory
                                        ? context.palette.orange
                                        : context.palette.muted,
                                  ),
                                  title: Text(
                                    item.filename,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    isDirectory
                                        ? context.l10n.directory
                                        : _fileDetails(item),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.palette.muted,
                                    ),
                                  ),
                                  onTap: isDirectory
                                      ? () => _load(
                                          _remotePath(
                                            app.sftpPath,
                                            item.filename,
                                          ),
                                        )
                                      : null,
                                  trailing: PopupMenuButton<String>(
                                    popUpAnimationStyle: AppMotion.menuStyle(
                                      context,
                                    ),
                                    tooltip: context.l10n.actionsForFilename(item.filename),
                                    onSelected: (action) {
                                      switch (action) {
                                        case 'download':
                                          _download(item.filename);
                                          break;
                                        case 'edit-text':
                                          _editText(item.filename);
                                          break;
                                        default:
                                          _delete(item);
                                          break;
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      if (!isDirectory)
                                        appMenuItem(context,
                                          value: 'download',
                                          child: Text(context.l10n.download2),
                                        ),
                                      if (!isDirectory)
                                        appMenuItem(context,
                                          value: 'edit-text',
                                          child: Text(context.l10n.editText2),
                                        ),
                                      appMenuItem(context,
                                        value: 'delete',
                                        child: Text(context.l10n.delete2),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    if (_loading) const LinearProgressIndicator(minHeight: 2),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _fileDetails(SftpName item) {
    final size = item.attr.size;
    if (size == null) return context.l10n.file;
    return '${NumberFormat.compact().format(size)} bytes';
  }

  Future<void> _load(String path, {String? sessionId}) {
    final capturedSessionId = sessionId ?? _boundSessionId;
    final request = ++_latestListRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    final operation = _listingQueue.catchError((Object _) {}).then((_) async {
      // SFTP startup loads `/` as soon as this page mounts. Queue subsequent
      // navigation so an older listing cannot complete last and replace the
      // destination the user selected.
      if (!mounted || request != _latestListRequest) return;
      try {
        if (capturedSessionId == null) return;
        await app.listSftp(path, sessionId: capturedSessionId);
      } catch (error) {
        if (mounted &&
            request == _latestListRequest &&
            capturedSessionId == _boundSessionId) {
          setState(() => _error = app.friendlyError(error));
        }
      }
    });
    _listingQueue = operation;
    return operation.whenComplete(() {
      if (mounted &&
          request == _latestListRequest &&
          capturedSessionId == _boundSessionId) {
        setState(() => _loading = false);
      }
    });
  }

  Future<void> _up() async {
    final path = app.sftpPath;
    if (path == '/') return;
    final parts = path.split('/')..removeWhere((part) => part.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    await _load(parts.isEmpty ? '/' : '/${parts.join('/')}');
  }

  Future<void> _goToPath() async {
    final path = TextEditingController(text: app.sftpPath);
    final value = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.goToRemotePath),
        content: TextField(
          controller: path,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: context.l10n.remotePath2),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, path.text),
            child: Text(context.l10n.go),
          ),
        ],
      ),
    );
    path.dispose();
    final destination = value?.trim();
    if (destination == null || destination.isEmpty) return;
    await _load(destination);
  }

  Future<void> _newDirectory() async {
    final name = TextEditingController();
    final value = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.createRemoteFolder),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(labelText: context.l10n.folderName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text),
            child: Text(context.l10n.create2),
          ),
        ],
      ),
    );
    name.dispose();
    if (value == null) return;
    try {
      await app.makeSftpDirectory(value, sessionId: _boundSessionId);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _upload() async {
    try {
      final id = _boundSessionId;
      final connection = app.terminalTabFor(id)?.connection;
      if (connection == null) {
        await app.uploadSftpFile(sessionId: id);
      } else {
        final done = await showSshTransferDialog(
          context: context,
          client: connection.client,
          direction: SshTransferDirection.upload,
          remotePath: _boundSessionPath,
          uploadIntoDirectory: true,
        );
        if (done == true && mounted && id == _boundSessionId)
          await _load(_boundSessionPath, sessionId: id);
      }
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _download(String name) async {
    try {
      final id = _boundSessionId;
      final connection = app.terminalTabFor(id)?.connection;
      if (connection == null) {
        await app.downloadSftpFile(name, sessionId: id);
      } else {
        final path = sftpChildPath(_boundSessionPath, name);
        await showSshTransferDialog(
          context: context,
          client: connection.client,
          direction: SshTransferDirection.download,
          remotePath: path,
          suggestedName: name,
          legacySftpDownload: (remotePath) => app.downloadSftpFile(
            remotePath.split('/').last,
            sessionId: id,
            remotePath: remotePath,
            maximumBytes: 16 * 1024 * 1024,
          ),
        );
      }
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _editText(String name) async {
    SftpTextDocument? document;
    try {
      document = await app.openSftpTextFile(name, sessionId: _boundSessionId);
      if (!mounted) {
        document.dispose();
        return;
      }
      await showAppDialog<void>(
        context: context,
        builder: (_) => SftpTextEditorDialog(app: app, document: document!),
      );
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
      document?.dispose();
    }
  }

  Future<void> _delete(SftpName item) async {
    if (await _confirmDelete(
          context,
          item.filename,
          description: context.l10n.filenameWillBeRemovedFromThe(item.filename),
        ) !=
        true) {
      return;
    }
    try {
      await app.deleteSftpEntry(item, sessionId: _boundSessionId);
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    }
  }
}

class _SyncPage extends StatelessWidget {
  const _SyncPage({required this.app});
  final AppController app;

  Future<void> _exportAnonymousDiagnostics(BuildContext context) async {
    try {
      final checkpointGeneration = app.syncCheckpointServerGeneration;
      final verifiedGeneration = app.instance?.generation;
      final report = SyncDiagnosticsExport.create(
        syncStatus: app.syncStatus,
        generationChanged:
            checkpointGeneration != null &&
            checkpointGeneration.isNotEmpty &&
            verifiedGeneration != null &&
            verifiedGeneration.isNotEmpty &&
            checkpointGeneration != verifiedGeneration,
        pendingCount: app.pendingCount,
        receivedCount: app.receivedCount,
        conflictCount: app.unresolvedConflictCount,
        unavailableRecordCount: app.unavailableRecordCount,
        lastSuccessfulSyncAt: app.lastSuccessfulSyncAt,
        clientVersion: _syncDiagnosticsClientVersion,
      );
      final saved = await saveAttachmentFile(
        fileName: 'atermius-sync-diagnostics.json',
        mediaType: 'application/json',
        bytes: report.toBytes(),
      );
      if (!context.mounted) return;
      _snack(
        context,
        saved
            ? context.l10n.anonymousSyncDiagnosticsExported
            : context.l10n.diagnosticsExportCancelled,
      );
    } on Object {
      if (context.mounted) {
        _snack(
          context,
          context.l10n.couldNotExportAnonymousSyncDiagnostics,
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: AppDensity.of(context).pagePadding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PageHeading(
          title: context.l10n.syncHealth,
          subtitle: context.l10n.encryptedRecordsImmutableRetriesAndRecovery,
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              if (app.syncStatus == 'resnapshot_required' ||
                  app.syncStatus == 'snapshot_recovering' ||
                  app.snapshotRecoveryActive)
                OutlinedButton.icon(
                  onPressed: app.syncing || app.snapshotRecoveryActive
                      ? null
                      : app.recoverFromSnapshot,
                  icon: app.snapshotRecoveryActive
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_rounded),
                  label: Text(
                    app.snapshotRecoveryActive
                        ? context.l10n.rebuildingSnapshot2
                        : context.l10n.rebuildSnapshot,
                  ),
                ),
              FilledButton.icon(
                onPressed:
                    app.databaseRecoveryRequired ||
                        app.syncStatus == 'snapshot_too_large' ||
                        app.syncing ||
                        app.snapshotRecoveryActive
                    ? null
                    : () => _runSyncFromUi(app),
                icon: const Icon(Icons.sync_rounded),
                label: Text(
                  app.syncStatus == 'snapshot_too_large'
                      ? context.l10n.snapshotLimitReached
                      : app.databaseRecoveryRequired
                      ? app.syncing
                            ? context.l10n.recoveryRequiredSyncing
                            : context.l10n.recoveryRequired
                      : app.syncing
                      ? 'Syncing…'
                      : context.l10n.syncNow,
                ),
              ),
            ],
          ),
        ),
        if (kIsWeb && app.pendingCount > 0) ...[
          const SizedBox(height: 12),
          BrowserStorageStatusCard(pendingCount: app.pendingCount),
        ],
        if (app.snapshotRecoveryActive ||
            app.syncStatus == 'resnapshot_required' ||
            app.syncStatus == 'snapshot_too_large') ...[
          const SizedBox(height: 12),
          Card(
            color: context.palette.orange.withValues(alpha: .08),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    app.snapshotRecoveryActive
                        ? Icons.sync_rounded
                        : Icons.warning_amber_rounded,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      app.snapshotRecoveryActive
                          ? context.l10n.snapshotVerificationIsInProgressLocal
                          : app.syncStatus == 'snapshot_too_large'
                          ? context.l10n.thisSnapshotExceedsThisClientsLimit
                          : context.l10n.theSyncCursorExpiredOrThe,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: context.palette.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (app.activeVault?.status == 'deleting' ||
            app.syncStatus == 'deletion_pending') ...[
          const SizedBox(height: 12),
          Card(
            color: context.palette.orange.withValues(alpha: .08),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_clock_outlined,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.vaultIsInItsDeletionGrace(app.pendingCount),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: context.palette.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, bounds) {
            final count = bounds.maxWidth > 850 ? 3 : 2;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: count,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: count == 3 ? 2.2 : 2.6,
              children: [
                _StatCard(
                  icon: Icons.cloud_done_outlined,
                  label: context.l10n.syncStatus,
                  value: _statusLabel(app.syncStatus),
                  accent: _syncColor(context, app.syncStatus),
                ),
                _StatCard(
                  icon: Icons.upload_rounded,
                  label: context.l10n.outboxItems,
                  value: '${app.pendingCount}',
                  accent: context.palette.lime,
                ),
                _StatCard(
                  icon: Icons.download_rounded,
                  label: context.l10n.lastPull,
                  value: '${app.receivedCount} changes',
                  accent: context.palette.teal,
                ),
                _StatCard(
                  icon: Icons.compare_arrows_rounded,
                  label: context.l10n.openConflicts,
                  value: '${app.unresolvedConflictCount}',
                  accent: app.unresolvedConflictCount > 0
                      ? context.palette.orange
                      : context.palette.teal,
                ),
                _StatCard(
                  icon: Icons.history_rounded,
                  label: context.l10n.lastSuccessfulSync,
                  value: app.lastSuccessfulSyncAt == null
                      ? 'Never'
                      : DateFormat.yMMMd().add_jm().format(
                          app.lastSuccessfulSyncAt!.toLocal(),
                        ),
                  accent: context.palette.teal,
                ),
                _StatCard(
                  icon: Icons.report_gmailerrorred_outlined,
                  label: context.l10n.issueCategory,
                  value: _syncIssueCategoryLabel(app.syncStatus),
                  accent: _syncIssueCategoryLabel(app.syncStatus) == 'None'
                      ? context.palette.teal
                      : context.palette.orange,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 15),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.privacy_tip_outlined, color: context.palette.teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.anonymousDiagnostics,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.theExportContainsARandomReport,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _exportAnonymousDiagnostics(context),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(context.l10n.exportDiagnostics),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 15),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_outlined, color: context.palette.teal),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        context.l10n.generationCheckpoint,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    _StatusDot(
                      label: _syncGenerationStatus(app),
                      color: switch (_syncGenerationStatus(app)) {
                        'Generation matches' => context.palette.teal,
                        'Generation mismatch' => context.palette.orange,
                        _ => context.palette.muted,
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.comparedWithTheLastVerifiedServer,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.savedCheckpointShortkey(_shortKey(app.syncCheckpointServerGeneration)),
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                Text(
                  context.l10n.lastVerifiedServerShortkey(_shortKey(app.instance?.generation)),
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 15),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.offline_pin_outlined, color: context.palette.teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.offlineFirstCiphertextOnly,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.localEditsAreEncryptedAndCommitted,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.55,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusDot(
                  label: _statusLabel(app.syncStatus).toUpperCase(),
                  color: _syncColor(context, app.syncStatus),
                ),
              ],
            ),
          ),
        ),
        if (app.unavailableRecordCount > 0) ...[
          const SizedBox(height: 12),
          Card(
            color: context.palette.orange.withValues(alpha: .08),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.unavailablerecordcountEncryptedRecordSCouldNot(app.unavailableRecordCount),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: context.palette.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 23),
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.conflictBranches,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            if (app.unresolvedConflictCount > 0)
              _Tag(label: context.l10n.unresolvedconflictcountNeedsReview(app.unresolvedConflictCount)),
          ],
        ),
        const SizedBox(height: 10),
        if (app.openConflicts.isEmpty)
          _EmptyState(
            icon: Icons.check_circle_outline,
            title: context.l10n.noOpenConflicts,
            body: context.l10n.conflictingBranchesArePreservedUntilYou,
          )
        else
          ...app.openConflicts.map(
            (conflict) => _ConflictCard(app: app, conflict: conflict),
          ),
        const SizedBox(height: 23),
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.crossDeviceConflictInbox,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            if (app.openFeedConflictItems.isNotEmpty)
              _Tag(label: context.l10n.countPendingReview(app.openFeedConflictItems.length)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.concurrentBranchesSubmittedToTheServer,
          style: TextStyle(fontSize: 12, height: 1.5, color: context.palette.muted),
        ),
        const SizedBox(height: 10),
        if (app.openFeedConflictItems.isEmpty)
          _EmptyState(
            icon: Icons.inbox_outlined,
            title: context.l10n.noPendingCrossDeviceBranches,
            body: context.l10n.newBranchesSyncAutomaticallyWithConflict,
          )
        else
          ...app.openFeedConflictItems.map(
            (item) => _ConflictFeedCard(app: app, item: item),
          ),
        if (app.resolvedFeedConflictItems.isNotEmpty) ...[
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              leading: Icon(
                Icons.task_alt_outlined,
                color: context.palette.teal,
              ),
              title: Text(context.l10n.processedBranchesCount(app.resolvedFeedConflictItems.length)),
              children: app.resolvedFeedConflictItems
                  .map((item) => _ConflictFeedCard(app: app, item: item))
                  .toList(growable: false),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.recoveryDetails,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                _DetailLine(
                  label: context.l10n.instance,
                  value: app.instance?.instanceId ?? '—',
                ),
                _DetailLine(
                  label: context.l10n.generation,
                  value: app.instance?.generation ?? '—',
                ),
                _DetailLine(
                  label: context.l10n.protocol,
                  value: 'v${app.instance?.protocolVersion ?? 1}',
                ),
                _DetailLine(label: context.l10n.currentVault2, value: app.currentVaultId),
                _DetailLine(
                  label: context.l10n.cursorPolicy,
                  value: context.l10n.advanceOnlyAfterEachPageIs,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ConflictFeedCard extends StatefulWidget {
  const _ConflictFeedCard({required this.app, required this.item});

  final AppController app;
  final ConflictFeedReviewItem item;

  @override
  State<_ConflictFeedCard> createState() => _ConflictFeedCardState();
}

class _HostSecurityConflictMergeAction extends StatefulWidget {
  const _HostSecurityConflictMergeAction({
    required this.app,
    required this.conflictId,
    required this.enabled,
  });

  final AppController app;
  final String conflictId;
  final bool enabled;

  @override
  State<_HostSecurityConflictMergeAction> createState() =>
      _HostSecurityConflictMergeActionState();
}

class _HostSecurityConflictMergeActionState
    extends State<_HostSecurityConflictMergeAction> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const ValueKey('host-security-merge-open'),
    onPressed: widget.enabled && !_busy ? _open : null,
    icon: _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.security_rounded, size: 16),
    label: Text(context.l10n.reviewHostConnectionSettings),
  );

  Future<void> _open() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.app.loadHostSecurityConflictMergePreview(
        conflictId: widget.conflictId,
      );
      if (!mounted) return;
      if (preview == null) {
        _snack(
          context,
          context.l10n.thisHostConflictHasNoSafely,
          error: true,
        );
        return;
      }
      final merged = await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _HostSecurityConflictMergeDialog(app: widget.app, preview: preview),
      );
      if (merged == true && mounted) {
        _snack(
          context,
          context.l10n.hostConnectionSettingsReviewedAndQueued,
        );
      }
    } catch (error) {
      if (mounted) {
        _snack(
          context,
          context.l10n.unableToReviewHostConnectionSettings(
            widget.app.friendlyError(error),
          ),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ConflictFeedCardState extends State<_ConflictFeedCard> {
  bool _actionBusy = false;
  bool _mergeEligibilityLoading = false;
  bool _credentialMergeEligible = false;
  int _mergeEligibilityGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refreshCredentialMergeEligibility();
  }

  @override
  void didUpdateWidget(covariant _ConflictFeedCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.conflictId != widget.item.conflictId ||
        oldWidget.item.isVerified != widget.item.isVerified ||
        oldWidget.item.isResolved != widget.item.isResolved ||
        oldWidget.item.resolutionState != widget.item.resolutionState) {
      _refreshCredentialMergeEligibility();
    }
  }

  Future<void> _refreshCredentialMergeEligibility() async {
    final generation = ++_mergeEligibilityGeneration;
    final item = widget.item;
    if (!item.isVerified ||
        item.isResolved ||
        item.resolutionState == 'pending' ||
        item.resolutionState == 'committed') {
      if (mounted) {
        setState(() {
          _mergeEligibilityLoading = false;
          _credentialMergeEligible = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _mergeEligibilityLoading = true;
        _credentialMergeEligible = false;
      });
    }
    var eligible = false;
    try {
      eligible = await widget.app.isPasswordCredentialMergeEligible(
        conflictId: item.conflictId,
      );
    } catch (_) {
      // The existing branch actions remain available if preview eligibility
      // cannot be checked. The repository/controller owns the error detail.
    }
    if (!mounted || generation != _mergeEligibilityGeneration) return;
    setState(() {
      _mergeEligibilityLoading = false;
      _credentialMergeEligible = eligible;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final item = widget.item;
    final canWrite = app.activeVault?.canWrite == true;
    final waitingForPush = item.resolutionState == 'pending';
    final waitingForResolution = item.resolutionState == 'committed';
    final needsReselect = item.resolutionState == 'reselect_required';
    final terminal = item.isResolved || item.resolutionState == 'resolved';
    final canResolve =
        canWrite &&
        item.isVerified &&
        !terminal &&
        !waitingForPush &&
        !waitingForResolution &&
        !_actionBusy;
    final isHostUpdate =
        item.branchOperation == 'update' &&
        app.hosts.any((host) => host.id == item.recordId);
    final timestamp = DateTime.tryParse(item.createdAt)?.toLocal();
    final operation = switch (item.branchOperation) {
      'create' => context.l10n.newLabel,
      'update' => context.l10n.change,
      'delete' => context.l10n.delete,
      'restore' => context.l10n.restore3,
      _ => context.l10n.unknownAction,
    };
    final keyEpoch = _safeConflictCounter(item.keyEpoch);
    final membershipVersion = _safeConflictCounter(item.membershipVersion);
    final statusText = terminal
        ? context.l10n.resolved
        : waitingForPush
        ? context.l10n.waitingForThisDeviceToSync
        : waitingForResolution
        ? context.l10n.versionCommittedWaitingForTheServer
        : needsReselect
        ? context.l10n.theCurrentVersionChangedChooseAgain
        : !item.isVerified
        ? context.l10n.branchNotVerifiedYetKeptRead
        : null;

    return Card(
      key: ValueKey('conflict-feed-${item.conflictId}'),
      margin: const EdgeInsets.only(bottom: 9),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  terminal ? Icons.task_alt_outlined : Icons.merge_type_rounded,
                  color: terminal ? context.palette.teal : context.palette.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.labelForRecord(item.recordId),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        context.l10n.branchSequenceSeqValuevalue(item.seq, timestamp == null ? item.createdAt : DateFormat.yMMMd().add_Hm().format(timestamp)),
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                _Tag(label: terminal ? context.l10n.resolved : context.l10n.serverBranch),
              ],
            ),
            const SizedBox(height: 10),
            _DetailLine(
              label: context.l10n.branchVersion,
              value: item.branchRevisionId == null
                  ? context.l10n.unreadable
                  : _shortAuditId(item.branchRevisionId),
            ),
            _DetailLine(
              label: context.l10n.sourceDevice,
              value: item.branchDeviceId == null
                  ? (item.isVerified ? context.l10n.unknownDevice : context.l10n.notVerifiedYet)
                  : _shortAuditId(item.branchDeviceId),
            ),
            _DetailLine(label: context.l10n.branchActions, value: operation),
            if (keyEpoch != null)
              _DetailLine(label: context.l10n.vaultKeyGeneration, value: keyEpoch),
            if (membershipVersion != null)
              _DetailLine(label: context.l10n.membershipVersion, value: membershipVersion),
            _DetailLine(
              label: context.l10n.currentServerVersion,
              value: !item.currentHeadExists
                  ? context.l10n.doesntExist
                  : item.currentHeadDeleted
                  ? context.l10n.deletedValuevalue(item.currentHeadRevisionId == null ? '' : ' · ${_shortAuditId(item.currentHeadRevisionId)}')
                  : '${item.currentHeadCommitted ? context.l10n.committed : context.l10n.notCommittedLocally}${item.currentHeadRevisionId == null ? '' : ' · ${_shortAuditId(item.currentHeadRevisionId)}'}',
            ),
            if (item.baseRevisionId != null)
              _DetailLine(
                label: context.l10n.branchsOriginalBase,
                value: _shortAuditId(item.baseRevisionId),
              ),
            if (statusText != null) ...[
              const SizedBox(height: 9),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (item.isVerified ? context.palette.teal : context.palette.orange)
                      .withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      item.isVerified
                          ? Icons.info_outline_rounded
                          : Icons.gpp_bad_outlined,
                      size: 17,
                      color: item.isVerified
                          ? context.palette.teal
                          : context.palette.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        statusText,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: canResolve
                      ? () => _resolve(context, adoptBranch: true)
                      : null,
                  icon: _actionBusy
                      ? const Icon(Icons.pending_actions_rounded, size: 16)
                      : const Icon(Icons.download_done_rounded, size: 16),
                  label: Text(_actionBusy ? context.l10n.working : context.l10n.adoptThisBranch),
                ),
                OutlinedButton.icon(
                  onPressed: canResolve && item.currentHeadCommitted
                      ? () => _resolve(context, adoptBranch: false)
                      : null,
                  icon: const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 16,
                  ),
                  label: Text(context.l10n.keepCurrentVersion),
                ),
                if (canResolve && _credentialMergeEligible)
                  OutlinedButton.icon(
                    key: const ValueKey('credential-merge-open'),
                    onPressed: () => _openCredentialMerge(context),
                    icon: const Icon(Icons.merge_rounded, size: 16),
                    label: Text(context.l10n.mergePasswordFields),
                  ),
                if (canResolve && isHostUpdate)
                  _HostSecurityConflictMergeAction(
                    app: app,
                    conflictId: item.conflictId,
                    enabled: canResolve,
                  ),
                if (canResolve && _mergeEligibilityLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (needsReselect)
                  Chip(
                    avatar: const Icon(Icons.refresh_rounded, size: 15),
                    label: Text(context.l10n.needsANewChoice),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolve(
    BuildContext context, {
    required bool adoptBranch,
  }) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(adoptBranch ? context.l10n.adoptTheVerifiedDeviceBranch : context.l10n.keepTheCurrentCommittedVersion),
          content: Text(
            adoptBranch
                ? context.l10n.thisDeviceDecryptsTheVerifiedBranch
                : context.l10n.theCurrentServerVersionIsCommitted,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(adoptBranch ? context.l10n.reSignAndSync : context.l10n.confirmKeptVersion),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (adoptBranch) {
        await widget.app.adoptRemoteConflict(widget.item.conflictId);
      } else {
        await widget.app.retainCurrentConflictHead(widget.item.conflictId);
      }
      if (context.mounted) {
        final current = widget.app.feedConflictItems
            .where((item) => item.conflictId == widget.item.conflictId)
            .firstOrNull;
        final message = switch (current?.resolutionState) {
          'pending' => context.l10n.choiceSavedEncryptedOnThisDevice2,
          'committed' => context.l10n.theSelectedVersionIsCommittedWaiting,
          'reselect_required' => context.l10n.theRecordChangedAgainDuringCommit,
          'resolved' => context.l10n.conflictResolved,
          _ => context.l10n.choiceSavedTheInboxUpdatesAfter,
        };
        _snack(context, message);
      }
    } catch (error) {
      if (context.mounted) {
        final action = adoptBranch ? context.l10n.couldntAdoptTheBranch : context.l10n.couldntKeepTheCurrentVersion;
        _snack(
          context,
          context.l10n.actionFriendlyerror(action, widget.app.friendlyError(error)),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _openCredentialMerge(BuildContext context) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final preview = await widget.app.loadCredentialConflictMergePreview(
        conflictId: widget.item.conflictId,
      );
      if (!context.mounted) return;
      if (preview == null) {
        setState(() => _credentialMergeEligible = false);
        _snack(
          context,
          context.l10n.thisConflictNoLongerSupportsPassword,
          error: true,
        );
        return;
      }
      final merged = await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _CredentialConflictMergeDialog(app: widget.app, preview: preview),
      );
      if (merged == true && context.mounted) {
        _snack(context, context.l10n.credentialMergeSavedAndSyncing);
      }
    } catch (error) {
      if (context.mounted) {
        _snack(
          context,
          context.l10n.unableToReviewPasswordFieldsFriendlyerror(widget.app.friendlyError(error)),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }
}

class _HostSecurityConflictMergeDialog extends StatefulWidget {
  const _HostSecurityConflictMergeDialog({
    required this.app,
    required this.preview,
  });

  final AppController app;
  final HostSecurityConflictMergePreview preview;

  @override
  State<_HostSecurityConflictMergeDialog> createState() =>
      _HostSecurityConflictMergeDialogState();
}

class _HostSecurityConflictMergeDialogState
    extends State<_HostSecurityConflictMergeDialog> {
  late HostSecurityConflictMergePreview _preview = widget.preview;
  HostSecurityMergeBranch? _choice;
  bool _saving = false;
  bool _stale = false;
  bool _loadingCurrent = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('host-security-merge-dialog'),
      semanticLabel: context.l10n.reviewHostConnectionSettings,
      title: Text(context.l10n.reviewHostConnectionSettings),
      content: SizedBox(
        width: appDialogWidth(context, 720),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 650),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.connectionSettingsAreKeptAsOne,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.baseRevisionShortauditidCurrentHeadShortauditid2(_shortAuditId(_preview.baseRevisionId), _shortAuditId(_preview.currentHeadRevisionId)),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                _buildReviewTable(theme),
                const SizedBox(height: 10),
                Text(
                  context.l10n.credentialSelectionProxySettingsForwardingDetails,
                  key: const ValueKey('host-security-merge-masked-note'),
                  style: TextStyle(fontSize: 12, color: context.palette.muted),
                ),
                const SizedBox(height: 14),
                RadioListTile<HostSecurityMergeBranch>(
                  key: const ValueKey('host-security-merge-choice-conflict'),
                  value: HostSecurityMergeBranch.conflict,
                  groupValue: _choice,
                  onChanged: _saving || _stale
                      ? null
                      : (value) => setState(() => _choice = value),
                  title: Text(context.l10n.useTheConflictBranchTuple),
                  subtitle: Text(
                    context.l10n.branchShortauditid(_shortAuditId(_preview.branchRevisionId)),
                  ),
                ),
                RadioListTile<HostSecurityMergeBranch>(
                  key: const ValueKey('host-security-merge-choice-current'),
                  value: HostSecurityMergeBranch.current,
                  groupValue: _choice,
                  onChanged: _saving || _stale
                      ? null
                      : (value) => setState(() => _choice = value),
                  title: Text(context.l10n.useTheCurrentVaultTuple),
                  subtitle: Text(
                    context.l10n.headShortauditid(_shortAuditId(_preview.currentHeadRevisionId)),
                  ),
                ),
                if (_stale) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    key: const ValueKey('host-security-merge-stale'),
                    container: true,
                    identifier: 'host-security-merge-stale',
                    label: context.l10n.theCommittedHostChangedReviewIts,
                    child: Text(
                      context.l10n.theCommittedHostChangedAfterThis,
                      style: TextStyle(color: context.palette.orange),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const ValueKey('host-security-merge-error'),
                    style: TextStyle(color: context.palette.orange),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _loadingCurrent
              ? null
              : () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel2),
        ),
        if (_stale)
          OutlinedButton(
            key: const ValueKey('host-security-merge-review-current'),
            onPressed: _loadingCurrent ? null : _reviewCurrent,
            child: Text(
              _loadingCurrent ? 'Loading…' : context.l10n.reviewCurrentVersion,
            ),
          ),
        FilledButton(
          key: const ValueKey('host-security-merge-save'),
          onPressed: _saving || _stale || _choice == null ? null : _save,
          child: Text(_saving ? context.l10n.saving : context.l10n.saveReviewedTuple),
        ),
      ],
    );
  }

  Widget _buildReviewTable(ThemeData theme) => Column(
    children: [
      for (final field in _preview.fields)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 115,
                child: Text(field.label, style: theme.textTheme.labelLarge),
              ),
              Expanded(child: _reviewValue('Base', field.base)),
              const SizedBox(width: 8),
              Expanded(child: _reviewValue('Conflict', field.conflict)),
              const SizedBox(width: 8),
              Expanded(child: _reviewValue('Current', field.current)),
            ],
          ),
        ),
    ],
  );

  Widget _reviewValue(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 10, color: context.palette.muted)),
      Text(value, style: const TextStyle(fontSize: 12), maxLines: 2),
    ],
  );

  Future<void> _save() async {
    final choice = _choice;
    if (choice == null || _saving || _stale) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await widget.app.mergeHostSecurityConflict(
        conflictId: _preview.conflictId,
        expectedHeadRevisionId: _preview.currentHeadRevisionId,
        choice: choice,
      );
      if (!mounted) return;
      if (outcome.status == HostSecurityMergeStatus.reviewRequired) {
        setState(() {
          _saving = false;
          _stale = true;
          _choice = null;
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            context.l10n.couldNotSaveTheReviewedTuple(widget.app.friendlyError(error));
      });
    }
  }

  Future<void> _reviewCurrent() async {
    if (_loadingCurrent) return;
    setState(() {
      _loadingCurrent = true;
      _error = null;
    });
    try {
      final preview = await widget.app.loadHostSecurityConflictMergePreview(
        conflictId: _preview.conflictId,
      );
      if (!mounted) return;
      if (preview == null) {
        setState(() {
          _loadingCurrent = false;
          _error = context.l10n.theHostConflictCanNoLonger;
        });
        return;
      }
      setState(() {
        _preview = preview;
        _choice = null;
        _stale = false;
        _loadingCurrent = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingCurrent = false;
        _error =
            context.l10n.couldNotLoadTheCurrentHost(widget.app.friendlyError(error));
      });
    }
  }
}

class _CredentialConflictMergeDialog extends StatefulWidget {
  const _CredentialConflictMergeDialog({
    required this.app,
    required this.preview,
  });

  final AppController app;
  final CredentialConflictMergePreview preview;

  @override
  State<_CredentialConflictMergeDialog> createState() =>
      _CredentialConflictMergeDialogState();
}

class _CredentialConflictMergeDialogState
    extends State<_CredentialConflictMergeDialog> {
  late CredentialConflictMergePreview _preview = widget.preview;
  final Map<CredentialConflictMergeField, CredentialConflictMergeBranch>
  _choices = {};
  bool _saving = false;
  bool _stale = false;
  bool _loadingCurrent = false;
  bool _revealSecret = false;
  String? _error;

  bool get _canSave =>
      !_saving &&
      !_stale &&
      _choices.containsKey(CredentialConflictMergeField.secret) &&
      (_preview.name.sameOnBothBranches ||
          _choices.containsKey(CredentialConflictMergeField.name)) &&
      (_preview.username.sameOnBothBranches ||
          _choices.containsKey(CredentialConflictMergeField.username));

  Map<CredentialConflictMergeField, CredentialConflictMergeBranch>
  get _submittedChoices => {
    for (final field in CredentialConflictMergeField.values)
      if (_choices.containsKey(field)) field: _choices[field]!,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      semanticLabel: context.l10n.mergePasswordFields,
      title: Text(context.l10n.mergePasswordFields),
      content: SizedBox(
        width: appDialogWidth(context, 620),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.chooseASourceForEachChanged,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.currentHeadShortauditid(_shortAuditId(_preview.currentHeadRevisionId)),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  field: CredentialConflictMergeField.name,
                  label: context.l10n.name2,
                  value: _preview.name,
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  field: CredentialConflictMergeField.username,
                  label: context.l10n.username,
                  value: _preview.username,
                ),
                const SizedBox(height: 10),
                _buildSecretField(),
                if (_stale) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    key: const ValueKey('credential-merge-stale'),
                    container: true,
                    identifier: 'credential-merge-stale',
                    label: context.l10n.theCommittedVaultVersionChangedReview,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.palette.orange.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        context.l10n.theCurrentVaultVersionChangedWhile,
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _loadingCurrent
              ? null
              : () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel2),
        ),
        if (_stale)
          OutlinedButton(
            key: const ValueKey('credential-merge-review-current'),
            onPressed: _loadingCurrent ? null : _reloadCurrentVersion,
            child: Text(
              _loadingCurrent ? 'Reviewing…' : context.l10n.reviewCurrentVersion,
            ),
          ),
        FilledButton(
          key: const ValueKey('credential-merge-save'),
          onPressed: _canSave ? _save : null,
          child: Text(_saving ? context.l10n.saving : context.l10n.saveMergedCredential),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required CredentialConflictMergeField field,
    required String label,
    required CredentialConflictMergeFieldPreview value,
  }) {
    if (value.sameOnBothBranches) {
      return _SameCredentialField(label: label, value: value.localValue);
    }
    return _CredentialMergeChoiceGroup(
      key: ValueKey('credential-merge-field-${field.name}'),
      field: field,
      label: label,
      conflictValue: value.localValue,
      currentValue: value.remoteValue,
      selected: _choices[field],
      enabled: !_saving && !_stale,
      onChanged: (choice) => setState(() {
        _choices[field] = choice;
        _error = null;
      }),
    );
  }

  Widget _buildSecretField() {
    final value = _preview.secret;
    final obscuredValue = '••••••••';
    return _CredentialMergeChoiceGroup(
      key: const ValueKey('credential-merge-field-secret'),
      field: CredentialConflictMergeField.secret,
      label: context.l10n.passwordSecret,
      conflictValue: _revealSecret ? value.localValue : obscuredValue,
      currentValue: _revealSecret ? value.remoteValue : obscuredValue,
      selected: _choices[CredentialConflictMergeField.secret],
      enabled: !_saving && !_stale,
      trailing: IconButton(
        tooltip: _revealSecret
            ? context.l10n.hidePasswordSecret
            : context.l10n.revealPasswordSecret,
        onPressed: _saving || _stale
            ? null
            : () => setState(() => _revealSecret = !_revealSecret),
        icon: Icon(
          _revealSecret
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
        ),
      ),
      onChanged: (choice) => setState(() {
        _choices[CredentialConflictMergeField.secret] = choice;
        _error = null;
      }),
    );
  }

  Future<void> _reloadCurrentVersion() async {
    setState(() {
      _loadingCurrent = true;
      _error = null;
    });
    try {
      final latest = await widget.app.loadCredentialConflictMergePreview(
        conflictId: _preview.conflictId,
      );
      if (!mounted) return;
      if (latest == null) {
        setState(() {
          _error = context.l10n.passwordFieldMergeIsNoLonger;
        });
        return;
      }
      setState(() {
        _preview = latest;
        _choices.clear();
        _stale = false;
        _revealSecret = false;
      });
    } catch (error) {
      if (mounted) setState(() => _error = widget.app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingCurrent = false);
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await widget.app.mergePasswordCredentialConflict(
        conflictId: _preview.conflictId,
        expectedHeadRevisionId: _preview.currentHeadRevisionId,
        choices: _submittedChoices,
      );
      if (!mounted) return;
      if (outcome.status == CredentialConflictMergeStatus.reviewRequired) {
        setState(() {
          _choices.clear();
          _stale = true;
          _revealSecret = false;
          _error = null;
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = widget.app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _SameCredentialField extends StatelessWidget {
  const _SameCredentialField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: label,
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(context.l10n.sameOnBothBranchesValuevalue(value))),
        ],
      ),
    ),
  );
}

class _CredentialMergeChoiceGroup extends StatelessWidget {
  const _CredentialMergeChoiceGroup({
    super.key,
    required this.field,
    required this.label,
    required this.conflictValue,
    required this.currentValue,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    this.trailing,
  });

  final CredentialConflictMergeField field;
  final String label;
  final String conflictValue;
  final String currentValue;
  final CredentialConflictMergeBranch? selected;
  final bool enabled;
  final ValueChanged<CredentialConflictMergeBranch> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    identifier: 'credential-merge-field-${field.name}',
    label: label,
    child: Card(
      semanticContainer: false,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          label,
                          style:
                              ListTileTheme.of(context).titleTextStyle ??
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                      ),
                    ),
                    if (trailing case final trailing?) trailing,
                  ],
                ),
              ),
            ),
            RadioListTile<CredentialConflictMergeBranch>(
              key: ValueKey('credential-merge-field-${field.name}-local'),
              value: CredentialConflictMergeBranch.local,
              groupValue: selected,
              onChanged: enabled
                  ? (branch) {
                      if (branch != null) onChanged(branch);
                    }
                  : null,
              title: Text(context.l10n.useConflictBranch),
              subtitle: Text(
                conflictValue,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
            ),
            RadioListTile<CredentialConflictMergeBranch>(
              key: ValueKey('credential-merge-field-${field.name}-remote'),
              value: CredentialConflictMergeBranch.remote,
              groupValue: selected,
              onChanged: enabled
                  ? (branch) {
                      if (branch != null) onChanged(branch);
                    }
                  : null,
              title: Text(context.l10n.useCurrentVaultVersion),
              subtitle: Text(
                currentValue,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
            ),
          ],
        ),
      ),
    ),
  );
}

String? _safeConflictCounter(String? value) =>
    value != null && RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(value)
    ? value
    : null;

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.app, required this.conflict});
  final AppController app;
  final Map<String, dynamic> conflict;

  @override
  Widget build(BuildContext context) {
    final id = conflict['record_id'] as String? ?? 'unknown';
    final conflictId = conflict['conflict_id'] as String? ?? '';
    final kind = conflict['kind'] as String? ?? 'concurrent_edit';
    if (kind == 'record_redacted') {
      final proof = conflict['redaction_proof'] is Map
          ? Map<String, dynamic>.from(conflict['redaction_proof'] as Map)
          : const <String, dynamic>{};
      return Card(
        key: ValueKey('redacted-draft-$conflictId'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.delete_forever_outlined,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      app.labelForRecord(id),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  _Tag(label: context.l10n.redactedDraft),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.theServerProvidedASignedCleanup,
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              if (proof['redaction_id'] is String) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.redactionProofItem('${proof['redaction_id']}'),
                  style: TextStyle(
                    fontSize: 11,
                    color: context.palette.muted,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final local = Map<String, dynamic>.from(conflict['branch_envelope'] as Map);
    final remote = Map<String, dynamic>.from(
      conflict['remote_envelope'] as Map,
    );
    final localHeader = Map<String, dynamic>.from(local['header'] as Map);
    final remoteHeader = remote['header'] is Map
        ? Map<String, dynamic>.from(remote['header'] as Map)
        : null;
    final canWrite = app.activeVault?.canWrite == true;
    final feedConflict = app.feedConflictItemForLocalConflict(conflictId, id);
    final verifiedFeedConflict = feedConflict != null && feedConflict.isVerified
        ? feedConflict
        : null;
    final canReviewHostSecurityConflict =
        canWrite &&
        verifiedFeedConflict?.branchOperation == 'update' &&
        verifiedFeedConflict != null &&
        !verifiedFeedConflict.isTerminal &&
        !const {
          'pending',
          'committed',
        }.contains(verifiedFeedConflict.resolutionState) &&
        app.hosts.any((host) => host.id == id);
    final canResolveLocalConflict =
        canWrite &&
        !const {'pending', 'committed'}.contains(feedConflict?.resolutionState);
    final canAdoptFeedBranch =
        canResolveLocalConflict &&
        feedConflict != null &&
        feedConflict.isVerified &&
        !feedConflict.isTerminal &&
        (!feedConflict.currentHeadExists || feedConflict.currentHeadCommitted);
    final canRetainFeedHead =
        canResolveLocalConflict &&
        feedConflict != null &&
        feedConflict.isVerified &&
        !feedConflict.isTerminal &&
        feedConflict.currentHeadCommitted &&
        !const {'pending', 'committed'}.contains(feedConflict.resolutionState);
    final importedFromOtherDevice = kind == 'archive_from_other_device';
    final isWorkspaceConflict = app.savedWorkspaces.any(
      (workspace) => workspace.id == id,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: context.palette.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    app.labelForRecord(id),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _Tag(label: kind.replaceAll('_', ' ')),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.localRevisionItem('${localHeader['revision_id']}'),
              style: TextStyle(
                fontSize: 11,
                color: context.palette.muted,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 3),
            Text(
              remoteHeader == null
                  ? context.l10n.remoteHeadIsAbsent
                  : context.l10n.remoteRevisionItem('${remoteHeader['revision_id']}'),
              style: TextStyle(
                fontSize: 11,
                color: context.palette.muted,
                fontFamily: 'monospace',
              ),
            ),
            if (verifiedFeedConflict != null) ...[
              const SizedBox(height: 9),
              _DetailLine(
                label: context.l10n.branchActions,
                value: switch (verifiedFeedConflict.branchOperation) {
                  'create' => context.l10n.newLabel,
                  'update' => context.l10n.change,
                  'delete' => context.l10n.delete,
                  'restore' => context.l10n.restore3,
                  _ => context.l10n.unknownAction,
                },
              ),
              _DetailLine(
                label: context.l10n.currentServerVersion,
                value: !verifiedFeedConflict.currentHeadExists
                    ? context.l10n.doesntExist
                    : verifiedFeedConflict.currentHeadDeleted
                    ? context.l10n.deleted
                    : verifiedFeedConflict.currentHeadCommitted
                    ? context.l10n.committed
                    : context.l10n.notCommittedLocally,
              ),
            ] else if (feedConflict != null) ...[
              const SizedBox(height: 9),
              Text(
                context.l10n.theCrossDeviceBranchIsntVerified,
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              isWorkspaceConflict
                  ? context.l10n.concurrentLayoutEditsAreKeptAs
                  : importedFromOtherDevice
                  ? context.l10n.thisSignedOutboxBranchCameFrom
                  : remoteHeader == null
                  ? context.l10n.theLocalBranchAndItsOriginal
                  : context.l10n.bothRevisionsStayEncryptedInLocal,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isWorkspaceConflict)
                  OutlinedButton.icon(
                    key: ValueKey('workspace-conflict-copy-$conflictId'),
                    // Copying this branch creates a different record, so it
                    // remains available while a feed resolution is pending.
                    // The repository still rechecks that the source branch
                    // is open before staging the copy.
                    onPressed: canWrite
                        ? () => _copyWorkspaceBranch(context, conflictId)
                        : null,
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: Text(context.l10n.saveLocalLayoutAsNamedCopy),
                  ),
                OutlinedButton.icon(
                  onPressed: canResolveLocalConflict
                      ? () => _resolve(context, conflictId, true)
                      : null,
                  icon: const Icon(Icons.computer_rounded, size: 16),
                  label: Text(context.l10n.keepThisDeviceVersion),
                ),
                if (remoteHeader != null)
                  FilledButton.icon(
                    onPressed: canResolveLocalConflict
                        ? () => _resolve(context, conflictId, false)
                        : null,
                    icon: const Icon(Icons.cloud_download_outlined, size: 16),
                    label: Text(context.l10n.useSyncedVersion),
                  ),
                if (canReviewHostSecurityConflict)
                  _HostSecurityConflictMergeAction(
                    app: app,
                    conflictId: conflictId,
                    enabled: canReviewHostSecurityConflict,
                  ),
                if (feedConflict != null &&
                    feedConflict.isVerified &&
                    !feedConflict.isTerminal)
                  OutlinedButton.icon(
                    key: ValueKey('adopt-feed-conflict-$conflictId'),
                    onPressed: canAdoptFeedBranch
                        ? () => _adoptFeedConflictBranch(context, conflictId)
                        : null,
                    icon: const Icon(Icons.call_received_rounded, size: 16),
                    label: Text(context.l10n.adoptThisBranch),
                  ),
                if (feedConflict != null)
                  OutlinedButton.icon(
                    key: ValueKey('retain-current-feed-conflict-$conflictId'),
                    onPressed: canRetainFeedHead
                        ? () => _retainCurrentFeedHead(context, conflictId)
                        : null,
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    label: Text(context.l10n.keepCurrentVersion),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolve(BuildContext context, String id, bool keepLocal) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          keepLocal ? context.l10n.keepThisDeviceVersion2 : context.l10n.useTheSyncedVersion,
        ),
        content: Text(
          context.l10n.aNewEncryptedRevisionWillBe,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.createResolution),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await app.resolveConflict(id, keepLocal: keepLocal);
      if (context.mounted) {
        final stillOpen = app.openConflicts.any(
          (item) =>
              item['conflict_id'] == id &&
              item['record_id'] == conflict['record_id'],
        );
        _snack(
          context,
          stillOpen
              ? context.l10n.resolutionSavedOnThisDeviceWaiting
              : context.l10n.conflictResolutionSynced,
        );
      }
    } catch (error) {
      if (context.mounted)
        _snack(context, app.friendlyError(error), error: true);
    }
  }

  Future<void> _retainCurrentFeedHead(
    BuildContext context,
    String conflictId,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.keepTheCurrentCommittedVersion),
        content: Text(context.l10n.theServerMarksTheCurrentCommitted),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.confirmKeptVersion),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await app.retainCurrentConflictHead(conflictId);
      if (context.mounted) {
        final current = app.feedConflictItemForLocalConflict(
          conflictId,
          conflict['record_id'] as String,
        );
        final message = switch (current?.resolutionState) {
          'resolved' => context.l10n.conflictResolved,
          'committed' => context.l10n.theCurrentVersionIsCommittedWaiting,
          'pending' => context.l10n.choiceSavedEncryptedOnThisDevice,
          'reselect_required' => context.l10n.theRecordChangedCheckTheCurrent,
          _ => context.l10n.choiceSavedOnThisDeviceWaiting,
        };
        _snack(context, message);
      }
    } catch (error) {
      if (context.mounted) {
        _snack(context, app.friendlyError(error), error: true);
      }
    }
  }

  Future<void> _adoptFeedConflictBranch(
    BuildContext context,
    String conflictId,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.adoptTheVerifiedDeviceBranch),
        content: Text(context.l10n.theBranchAndTheCurrentRecord),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.reSignAndSync),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await app.adoptRemoteConflict(conflictId);
      if (context.mounted) {
        final current = app.feedConflictItemForLocalConflict(
          conflictId,
          conflict['record_id'] as String,
        );
        final message = switch (current?.resolutionState) {
          'resolved' => context.l10n.conflictResolved,
          'committed' => context.l10n.theSelectedBranchIsCommittedWaiting,
          'pending' => context.l10n.branchSavedEncryptedOnThisDevice,
          'reselect_required' => context.l10n.theRecordChangedCheckTheCurrent,
          _ => context.l10n.branchSavedOnThisDeviceWaiting,
        };
        _snack(context, message);
      }
    } catch (error) {
      if (context.mounted) {
        _snack(context, app.friendlyError(error), error: true);
      }
    }
  }

  Future<void> _copyWorkspaceBranch(
    BuildContext context,
    String conflictId,
  ) async {
    final name = await _workspaceNamePrompt(
      context,
      title: context.l10n.saveConflictBranchAsWorkspaceCopy,
      initialValue:
          '${app.labelForRecord(conflict['record_id'] as String)} copy',
    );
    if (name == null || !context.mounted) return;
    try {
      await app.saveWorkspaceConflictBranchAsNamedCopy(
        conflictId: conflictId,
        copyName: name,
      );
      if (context.mounted) {
        _snack(
          context,
          context.l10n.theLocalLayoutBranchWasSaved,
        );
      }
    } catch (error) {
      if (context.mounted) {
        _snack(context, app.friendlyError(error), error: true);
      }
    }
  }
}

class _AuditPage extends StatelessWidget {
  const _AuditPage({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final events = app.visibleAuditEvents;
    final vaultSelected = app.auditScope == AuditScope.activeVault;
    final cannotReadVault = vaultSelected && !app.canReadActiveVaultAudit;
    final hasUnfilteredEvents = app.auditPageEvents.isNotEmpty;
    return SingleChildScrollView(
      padding: AppDensity.of(context).pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeading(
            title: context.l10n.auditRecords,
            subtitle: context.l10n.readOnlyViewOfCommittedAccount,
            trailing: OutlinedButton.icon(
              onPressed: app.auditLoading ? null : app.refreshAudit,
              icon: app.auditLoading
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.refresh),
            ),
          ),
          const SizedBox(height: 17),
          SegmentedButton<AuditScope>(
            segments: [
              ButtonSegment(
                value: AuditScope.account,
                icon: const Icon(Icons.person_outline),
                label: Text(context.l10n.account2),
              ),
              ButtonSegment(
                value: AuditScope.activeVault,
                icon: const Icon(Icons.lock_outline),
                label: Text(context.l10n.currentVault3),
              ),
            ],
            selected: {app.auditScope},
            onSelectionChanged: app.auditLoading
                ? null
                : (selection) => app.selectAuditScope(selection.single),
          ),
          const SizedBox(height: 12),
          if (vaultSelected)
            _AuditInlineNotice(
              icon: cannotReadVault
                  ? Icons.info_outline_rounded
                  : Icons.lock_outline_rounded,
              color: cannotReadVault ? context.palette.orange : context.palette.teal,
              text: cannotReadVault
                  ? context.l10n.vaultScopedAuditIsAvailableOnly
                  : context.l10n.showingEventsForCurrentvaultnameSwitchingThe(app.currentVaultName),
            ),
          const SizedBox(height: 15),
          if (app.auditError != null)
            Card(
              color: context.palette.red.withValues(alpha: .07),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, color: context.palette.red),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            liveRegion: true,
                            container: true,
                            label: context.l10n.couldntLoadAuditRecords,
                            excludeSemantics: true,
                            child: Text(
                              context.l10n.couldntLoadAuditRecords,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            app.auditError!,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: app.auditLoading
                                ? null
                                : app.refreshAudit,
                            icon: const Icon(Icons.restart_alt_rounded),
                            label: Text(context.l10n.retryFromTheFirstPage),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (app.auditLoading && !hasUnfilteredEvents)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 45),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 13),
                      Text(context.l10n.readingAuditRecords),
                    ],
                  ),
                ),
              ),
            )
          else if (events.isEmpty)
            _EmptyState(
              icon: cannotReadVault
                  ? Icons.admin_panel_settings_outlined
                  : Icons.history_toggle_off_rounded,
              title: cannotReadVault
                  ? context.l10n.yourCurrentRoleCantViewThe
                  : app.auditHasMore
                  ? context.l10n.noEventsInThisScopeOn
                  : context.l10n.noAuditRecordsInTheCurrent,
              body: cannotReadVault
                  ? context.l10n.accountEventsAreStillVisibleOnly
                  : app.auditHasMore
                  ? context.l10n.theServerPageContainsSeveralVisible
                  : context.l10n.committedAdminActionsAppearHereNew,
            )
          else
            ...events.map((event) => _AuditEventCard(event: event)),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Text(
                    context.l10n.pageValuevalue2(app.auditPageIndex + 1),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.muted,
                    ),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: app.auditLoading || !app.auditHasPrevious
                        ? null
                        : app.previousAuditPage,
                    icon: const Icon(Icons.chevron_left),
                    label: Text(context.l10n.previousPage),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: app.auditLoading || !app.auditHasMore
                        ? null
                        : app.nextAuditPage,
                    icon: const Icon(Icons.chevron_right),
                    label: Text(context.l10n.nextPage),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditEventCard extends StatelessWidget {
  const _AuditEventCard({required this.event});

  final AuditEvent event;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 9),
    child: Padding(
      padding: const EdgeInsets.all(15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: context.palette.teal.withValues(alpha: .13),
            child: Icon(
              event.source == 'maintenance'
                  ? Icons.settings_suggest_outlined
                  : Icons.check_circle_outline,
              size: 18,
              color: context.palette.teal,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _auditActionLabel(event.action),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  '${event.resourceType}${event.resourceId == null ? '' : ' · ${_shortAuditId(event.resourceId!)}'}',
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.l10n.accountShortauditidDeviceShortauditid2Valuevalue(_shortAuditId(event.actorUserId), _shortAuditId(event.actorDeviceId), event.source == 'maintenance' ? context.l10n.maintenanceJobs : 'API'),
                  style: TextStyle(color: context.palette.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                DateFormat.yMMMd().add_jm().format(event.occurredAt.toLocal()),
                style: TextStyle(fontSize: 11, color: context.palette.muted),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 5),
              Text(
                '#${event.eventId}',
                style: TextStyle(
                  fontSize: 10,
                  color: context.palette.muted,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _AuditInlineNotice extends StatelessWidget {
  const _AuditInlineNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

String _auditActionLabel(String action) => switch (action) {
  'account.created' => currentL10n.accountCreated,
  'account.deletion_requested' => currentL10n.accountDeletionScheduled,
  'account.deletion_scheduled' => currentL10n.accountDeletionScheduled,
  'account.deletion_cancelled' => currentL10n.accountDeletionCancelled,
  'account.deletion_canceled' => currentL10n.accountDeletionCancelled,
  'account.purged' => currentL10n.accountDataCleared,
  'auth.account_recovered' => currentL10n.accountRecoveryCompleted,
  'auth.account_recovery_disabled' => currentL10n.accountRecoveryDisabled,
  'auth.account_recovery_enabled' => currentL10n.accountRecoveryEnabled,
  'auth.account_recovery_key_envelopes_updated' => currentL10n.recoveryKeyDeviceEnvelopesUpdated,
  'auth.account_recovery_rotated' => currentL10n.accountRecoveryKeyRotated,
  'auth.mfa_login_challenge_created' => currentL10n.multiFactorSignInStarted,
  'auth.mfa_recovery_codes_rotated' => currentL10n.multiFactorRecoveryCodesRotated,
  'auth.mfa_reset_by_recovery' => currentL10n.multiFactorAuthenticationWasResetAfter2,
  'auth.mfa_state_reset_by_restore' => currentL10n.multiFactorAuthenticationWasResetAfter,
  'auth.mfa_totp_disabled' => currentL10n.multiFactorAuthenticationTurnedOff,
  'auth.mfa_totp_enabled' => currentL10n.multiFactorAuthenticationEnabled,
  'auth.login_succeeded' => currentL10n.signedIn,
  'auth.login_failed' => currentL10n.signInFailed,
  'auth.logout_succeeded' => currentL10n.signedOut,
  'auth.password_changed' => currentL10n.masterPasswordChanged,
  'auth.password_change_failed' => currentL10n.couldntChangeTheMasterPassword,
  'auth.refresh_reuse_detected' => currentL10n.refreshCredentialReplayDetectedTheRelated,
  'device.registered' => currentL10n.deviceApproved2,
  'device.revoked' => currentL10n.deviceRevoked,
  'relay.ticket_issued' => currentL10n.sshRelayConnectionTicketIssued,
  'relay.connected' => currentL10n.sshRelayConnected,
  'vault.created' => currentL10n.vaultCreated,
  'vault.invitation_created' => currentL10n.memberInvitationCreated,
  'vault.invitation.created' => currentL10n.memberInvitationCreated,
  'vault.invitation_accepted' => currentL10n.memberInvitationAccepted,
  'vault.invitation.accepted' => currentL10n.memberInvitationAccepted,
  'vault.key_rotated' => currentL10n.vaultKeyRotated,
  'vault.key.rotated' => currentL10n.vaultKeyRotated,
  'vault.sync_batch_committed' => currentL10n.vaultEncryptedDataSynced,
  'vault.member_role_changed' => currentL10n.memberPermissionsChanged,
  'vault.member_revoked' => currentL10n.memberAccessRevoked,
  'vault.conflict_resolved' => currentL10n.vaultConflictResolved,
  'vault.ownership_transferred' => currentL10n.vaultOwnershipTransferred,
  'vault.deletion_requested' => currentL10n.vaultDeletionScheduled,
  'vault.deletion_scheduled' => currentL10n.vaultDeletionScheduled,
  'vault.deletion_cancelled' => currentL10n.vaultDeletionCancelled,
  'vault.deletion_canceled' => currentL10n.vaultDeletionCancelled,
  'vault.purged' => currentL10n.vaultPurged,
  _ => action.replaceAll('.', ' · '),
};

String _instanceAdminAuditActionLabel(String action) => switch (action) {
  'admin.metrics_credential_rotated' => currentL10n.anAdministratorRotatedThePrometheusScrape,
  'admin.metrics_credential_revoked' => currentL10n.anAdministratorRevokedThePrometheusScrape,
  'admin.account_disabled' => currentL10n.anAdministratorDisabledTheAccount,
  'admin.account_enabled' => currentL10n.anAdministratorEnabledTheAccount,
  'admin.account_session_revoked' => currentL10n.anAdministratorRevokedAnAccountSession,
  'admin.account_sessions_revoked' => currentL10n.anAdministratorRevokedAllOfThe,
  'admin.backup_completed' => currentL10n.adminBackupCompleted,
  'admin.backup_failed' => currentL10n.adminBackupFailed,
  'admin.backup_interrupted' => currentL10n.adminBackupInterrupted,
  'admin.backup_requested' => currentL10n.anAdministratorRequestedABackup,
  'admin.backup_schedule_updated' => currentL10n.anAdministratorChangedTheScheduledBackup,
  'admin.backup_started' => currentL10n.adminBackupStarted,
  'admin.maintenance_completed' => currentL10n.adminMaintenanceJobCompleted,
  'admin.maintenance_failed' => currentL10n.adminMaintenanceJobFailed,
  'admin.maintenance_interrupted' => currentL10n.adminMaintenanceJobInterrupted,
  'admin.maintenance_requested' => currentL10n.anAdministratorRequestedAMaintenanceJob,
  'admin.maintenance_started' => currentL10n.adminMaintenanceJobStarted,
  'admin.relay_policy_updated' => currentL10n.anAdministratorUpdatedTheSshRelay,
  'admin.relay_group_created' => currentL10n.anAdministratorCreatedAnSshRelay,
  'admin.relay_group_renamed' => currentL10n.anAdministratorRenamedAnSshRelay,
  'admin.relay_group_deleted' => currentL10n.anAdministratorDeletedAnSshRelay,
  'admin.relay_group_membership_updated' => currentL10n.anAdministratorChangedSshRelayAccess,
  'admin.relay_group_policy_updated' => currentL10n.anAdministratorChangedTheSshRelay,
  'admin.relay_group_policy_reset' => currentL10n.anAdministratorResetTheSshRelay,
  'admin.restore_completed' => currentL10n.adminRestoreJobCompleted,
  'admin.restore_failed' => currentL10n.adminRestoreJobFailed,
  'admin.restore_interrupted' => currentL10n.adminRestoreJobInterrupted,
  'admin.restore_requested' => currentL10n.anAdministratorRequestedARestoreJob,
  'admin.restore_stage_discarded' => currentL10n.anAdministratorDiscardedTheIsolatedRestore,
  'admin.restore_started' => currentL10n.adminRestoreJobStarted,
  'admin.vault_quota_set' => currentL10n.anAdministratorChangedTheVaultQuota,
  'instance.account_invitation_issued' => currentL10n.instanceAdminInvitationIssued,
  'instance.account_invitation_revoked' => currentL10n.instanceAdminInvitationRevoked,
  // Keep older rows written before action names were namespaced readable.
  'maintenance.backup.completed' => currentL10n.backupCompleted,
  _ => action.replaceAll('.', ' · '),
};

String _instanceAdminAuditResultLabel(String result) => switch (result) {
  'success' => currentL10n.succeeded,
  'failure' => currentL10n.failed,
  _ => currentL10n.unknownResult,
};

String _shortAuditId(String? value) {
  if (value == null || value.isEmpty) return '—';
  if (value.length <= 16) return value;
  return '${value.substring(0, 8)}…${value.substring(value.length - 5)}';
}

class _VaultRedactionReadinessPanel extends StatelessWidget {
  const _VaultRedactionReadinessPanel({
    required this.app,
    this.compact = false,
    this.showReviewDevices = false,
  });

  final AppController app;
  final bool compact;
  final bool showReviewDevices;

  @override
  Widget build(BuildContext context) {
    final devices = app.activeVaultDeviceRows
        .where(
          (device) =>
              device['status'] == 'active' &&
              device['membership_status'] == 'active',
        )
        .toList(growable: false);
    final readiness = devices
        .map(
          (device) => (
            device: device,
            status: DeviceRedactionReadiness.fromVaultDeviceRow(
              device,
              crypto: app.crypto,
            ),
          ),
        )
        .toList(growable: false);
    final readyCount = readiness
        .where(
          (item) => item.status.status == DeviceRedactionReadinessStatus.ready,
        )
        .length;
    final blockers = readiness
        .where((item) => item.status.blocksPurge)
        .toList(growable: false);
    final shownDevices = compact ? blockers.take(3).toList() : readiness;
    final cardKey = showReviewDevices
        ? const ValueKey('recycle_bin_redaction_readiness')
        : const ValueKey('vault_redaction_readiness_section');

    return Card(
      key: cardKey,
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sync_problem_outlined,
                  color: context.palette.teal,
                  size: 19,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.redactionReadiness,
                    key: const ValueKey('vault_redaction_readiness_summary'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (app.vaultDeviceRowsLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              readiness.isEmpty
                  ? context.l10n.noActiveVaultDeviceReportsAre
                  : '$readyCount of ${readiness.length} active Vault devices are ready; ${blockers.length} report(s) block permanent purge.',
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (app.vaultDeviceRowsError case final error?) ...[
              const SizedBox(height: 5),
              Text(
                error,
                key: const ValueKey('vault_redaction_readiness_error'),
                style: TextStyle(color: context.palette.red, fontSize: 12),
              ),
            ],
            if (shownDevices.isNotEmpty) ...[
              const SizedBox(height: 7),
              for (final item in shownDevices)
                _VaultRedactionDeviceReadinessRow(
                  device: item.device,
                  readiness: item.status,
                ),
              if (compact && blockers.length > shownDevices.length)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    context.l10n.valuevalueMoreDeviceSNeedReview(blockers.length - shownDevices.length),
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
            ] else if (!app.vaultDeviceRowsLoading &&
                app.vaultDeviceRowsError == null &&
                readiness.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                context.l10n.allActiveVaultDevicesReportSupport,
                style: TextStyle(color: context.palette.lime, fontSize: 12),
              ),
            ],
            const SizedBox(height: 7),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('vault_redaction_readiness_refresh'),
                  onPressed: app.vaultDeviceRowsLoading
                      ? null
                      : () => unawaited(_refreshVaultReadinessFromUi(app)),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(context.l10n.refreshReadiness),
                ),
                if (showReviewDevices)
                  TextButton.icon(
                    key: const ValueKey('recycle_bin_review_trusted_devices'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      app.showWorkspacePage(WorkspacePage.devices);
                    },
                    icon: const Icon(Icons.devices_outlined, size: 17),
                    label: Text(context.l10n.reviewTrustedDevices),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VaultRedactionDeviceReadinessRow extends StatelessWidget {
  const _VaultRedactionDeviceReadinessRow({
    required this.device,
    required this.readiness,
  });

  final Map<String, dynamic> device;
  final DeviceRedactionReadiness readiness;

  @override
  Widget build(BuildContext context) {
    final name =
        device['name'] is String && (device['name'] as String).trim().isNotEmpty
        ? (device['name'] as String).trim()
        : 'Unnamed device';
    final deviceId = device['device_id'] as String? ?? '';
    final shortId = deviceId.length >= 8 ? deviceId.substring(0, 8) : 'unknown';
    final statusColor = switch (readiness.status) {
      DeviceRedactionReadinessStatus.ready => context.palette.lime,
      DeviceRedactionReadinessStatus.missing ||
      DeviceRedactionReadinessStatus.invalidated ||
      DeviceRedactionReadinessStatus.unsupported => context.palette.orange,
      DeviceRedactionReadinessStatus.unverifiable => context.palette.red,
    };
    return Semantics(
      key: ValueKey('vault_redaction_device-$deviceId'),
      container: true,
      label: context.l10n.vaultDeviceNameStatuslabel(name, readiness.statusLabel),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$name · $shortId',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              readiness.statusLabel,
              style: TextStyle(color: statusColor, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: AppDensity.of(context).pagePadding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PageHeading(
          title: context.l10n.trustedDevices,
          subtitle: context.l10n.onlyASignedEnrollmentFromAn,
          trailing: app.activeVault == null
              ? OutlinedButton.icon(
                  onPressed: () => _approveDevice(context, app),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(context.l10n.approveEnrollment),
                )
              : OutlinedButton.icon(
                  onPressed: app.activeVault?.canWrite == true
                      ? () => _approveDevice(context, app)
                      : null,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(context.l10n.approveEnrollment),
                ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.admin_panel_settings_outlined,
                  color: context.palette.teal,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    context.l10n.eachDeviceKeepsItsPrivateSigning,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (app.activeVault != null) ...[
          _VaultRedactionReadinessPanel(app: app),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Text(
            context.l10n.accountDevices,
            style: TextStyle(
              color: context.palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (app.devices.isEmpty)
          _EmptyState(
            icon: Icons.devices_other_outlined,
            title: context.l10n.noDeviceListLoaded,
            body: context.l10n.refreshToLoadApprovedDevicesFrom,
            action: OutlinedButton.icon(
              onPressed: () => _refreshDevicesFromUi(app),
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.refreshDevices),
            ),
          )
        else
          ...app.devices.map((device) {
            final id = device['device_id'] as String? ?? 'unknown';
            final current = id == app.identity?.deviceId;
            final status = _trustedDeviceStatus(device['status']);
            final createdAt = _deviceTimestamp(device['created_at']);
            final revokedAt = _deviceTimestamp(device['revoked_at']);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 6,
                ),
                leading: CircleAvatar(
                  backgroundColor: current
                      ? context.palette.lime.withValues(alpha: .15)
                      : context.palette.surfaceSoft,
                  child: Icon(
                    current ? Icons.laptop_mac_rounded : Icons.devices_rounded,
                    color: current ? context.palette.lime : context.palette.muted,
                    size: 19,
                  ),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        device['name'] as String? ?? context.l10n.unnamedDevice,
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        container: true,
                        label: context.l10n.currentDevice,
                        child: ExcludeSemantics(
                          child: _Tag(label: context.l10n.thisDevice),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.itemSigningKeyShortkey('${device['device_id']}', _shortKey(device['signing_public_key'] as String?)),
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 11,
                        height: 1.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 7,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _DeviceStatusTag(status: status),
                        if (createdAt != null)
                          Text(
                            context.l10n.createdFormat(DateFormat.yMMMd().add_jm().format(createdAt)),
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        if (revokedAt != null)
                          Text(
                            context.l10n.revokedFormat2(DateFormat.yMMMd().add_jm().format(revokedAt)),
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    _deviceCapabilitySummary(context, app, device),
                  ],
                ),
                isThreeLine: true,
                trailing: current || status != _TrustedDeviceStatus.active
                    ? null
                    : IconButton(
                        tooltip: context.l10n.revokeDevice,
                        onPressed: () async {
                          if (await _confirmRevokeDevice(
                                context,
                                device['name'] as String? ?? 'device',
                              ) !=
                              true) {
                            return;
                          }
                          try {
                            await app.revokeDevice(id);
                          } catch (error) {
                            if (context.mounted)
                              _snack(
                                context,
                                app.friendlyError(error),
                                error: true,
                              );
                          }
                        },
                        icon: Icon(
                          Icons.block_rounded,
                          color: context.palette.red,
                        ),
                      ),
              ),
            );
          }),
      ],
    ),
  );
}

Widget _deviceCapabilitySummary(
  BuildContext context,
  AppController app,
  Map<String, dynamic> device,
) {
  final textStyle = TextStyle(
    color: context.palette.muted,
    fontSize: 11,
    height: 1.45,
  );
  final rawReport = device['capability_report'];
  if (rawReport == null) {
    return Text(currentL10n.compatibilityReportNotReported, style: textStyle);
  }

  try {
    final accountId = app.session?.accountId;
    final deviceId = device['device_id'];
    final signingKeyText = device['signing_public_key'];
    if (accountId == null ||
        deviceId is! String ||
        signingKeyText is! String ||
        rawReport is! Map) {
      throw FormatException(currentL10n.deviceCompatibilityReportIsInvalid);
    }
    final signingKey = decodeBase64Url(signingKeyText);
    if (signingKey.length != 32 ||
        encodeBase64Url(signingKey) != signingKeyText) {
      throw FormatException(currentL10n.deviceCapabilitySignerIsInvalid);
    }
    final verified = app.crypto.verifyDeviceCapabilityReport(
      report: Map<String, dynamic>.from(rawReport),
      expectedAccountId: accountId,
      expectedDeviceId: deviceId,
      signingPublicKey: signingKey,
    );
    final attachmentVersions = verified.hostAttachmentManifestVersions.join(
      ', ',
    );
    return Text(
      currentL10n.verifiedCapabilitiesReportRevisionRevisionRecord(verified.revision, verified.maxRecordSchema, attachmentVersions, _formatAdminBytes(verified.maxAttachmentBytes)),
      style: textStyle,
    );
  } on Object {
    return Text(
      currentL10n.compatibilityReportUnverifiedDetailsHidden,
      style: TextStyle(color: context.palette.red, fontSize: 11, height: 1.45),
    );
  }
}

enum _TrustedDeviceStatus { active, revoked, unknown }

_TrustedDeviceStatus _trustedDeviceStatus(Object? value) =>
    switch (value?.toString().toLowerCase()) {
      'active' => _TrustedDeviceStatus.active,
      'revoked' => _TrustedDeviceStatus.revoked,
      _ => _TrustedDeviceStatus.unknown,
    };

DateTime? _deviceTimestamp(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toLocal();
}

class _DeviceStatusTag extends StatelessWidget {
  const _DeviceStatusTag({required this.status});

  final _TrustedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      _TrustedDeviceStatus.active => ('Active', context.palette.teal),
      _TrustedDeviceStatus.revoked => ('Revoked', context.palette.red),
      _TrustedDeviceStatus.unknown => ('Status unavailable', context.palette.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

Future<bool?> _confirmRevokeDevice(
  BuildContext context,
  String name,
) => showAppDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(context.l10n.revokeDevice2),
    content: Text(
      context.l10n.nameWillLoseAccountAccessAnd(name),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        style: FilledButton.styleFrom(backgroundColor: context.palette.red),
        child: Text(context.l10n.revokeDevice),
      ),
    ],
  ),
);

Future<void> _approveDevice(BuildContext context, AppController app) async {
  final enrollment = TextEditingController();
  Map<String, dynamic>? target;
  final response = await showAppDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(
          target == null
              ? context.l10n.reviewDeviceEnrollment
              : context.l10n.approveValuevalue('${target!['name'] ?? 'new device'}'),
        ),
        content: SizedBox(
          width: appDialogWidth(context, 540),
          child: target == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.pasteThePublicRequestFromThe,
                    ),
                    const SizedBox(height: 13),
                    TextField(
                      controller: enrollment,
                      minLines: 6,
                      maxLines: 11,
                      decoration: InputDecoration(
                        labelText: context.l10n.enrollmentJson,
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailLine(
                      label: context.l10n.account,
                      value: app.account?.accountId ?? '—',
                    ),
                    _DetailLine(
                      label: context.l10n.instance,
                      value: app.instance?.instanceId ?? '—',
                    ),
                    _DetailLine(
                      label: context.l10n.newDevice,
                      value: target!['name'] as String? ?? 'Unnamed',
                    ),
                    _DetailLine(
                      label: context.l10n.deviceId,
                      value: target!['device_id'] as String? ?? '—',
                    ),
                    const SizedBox(height: 7),
                    Text(
                      context.l10n.signingKeyFingerprint,
                      style: TextStyle(color: context.palette.muted, fontSize: 11),
                    ),
                    _PublicFingerprint(
                      app: app,
                      encodedKey: target!['signing_public_key'] as String?,
                      color: context.palette.lime,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      context.l10n.encryptionKeyFingerprint,
                      style: TextStyle(color: context.palette.muted, fontSize: 11),
                    ),
                    _PublicFingerprint(
                      app: app,
                      encodedKey: target!['encryption_public_key'] as String?,
                      color: context.palette.teal,
                    ),
                    const SizedBox(height: 13),
                    _MessageBoxLikeWarning(
                      text: context.l10n.byApprovingThisActiveMemberDevice,
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel2),
          ),
          if (target != null)
            TextButton(
              onPressed: () => setDialogState(() => target = null),
              child: Text(context.l10n.back),
            ),
          if (target == null)
            FilledButton(
              onPressed: () {
                try {
                  final decoded = jsonDecode(enrollment.text);
                  if (decoded is! Map<String, dynamic> ||
                      decoded['format'] != 'atermius-device-enrollment-v1' ||
                      decoded['device'] is! Map)
                    {
throw FormatException(
                      context.l10n.enrollmentJsonIsNotValid,
                    );
}
                  if (decoded['account_id'] != app.account?.accountId)
                    {
throw FormatException(
                      context.l10n.thisRequestBelongsToAnotherAccount,
                    );
}
                  setDialogState(
                    () => target = Map<String, dynamic>.from(
                      decoded['device'] as Map,
                    ),
                  );
                } catch (error) {
                  _snack(context, app.friendlyError(error), error: true);
                }
              },
              child: Text(context.l10n.reviewKeys),
            )
          else
            FilledButton.icon(
              onPressed: () async {
                try {
                  final approved = await app.approveDeviceEnrollment(
                    enrollment.text,
                  );
                  if (context.mounted) Navigator.pop(context, approved);
                } catch (error) {
                  if (context.mounted)
                    _snack(context, app.friendlyError(error), error: true);
                }
              },
              icon: const Icon(Icons.verified_user_outlined, size: 17),
              label: Text(context.l10n.approveSealKeys),
            ),
        ],
      ),
    ),
  );
  enrollment.dispose();
  if (response == null || !context.mounted) return;
  final export = TextEditingController(text: response);
  await showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.deviceApproved),
      content: SizedBox(
        width: appDialogWidth(context, 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.copyThisResponseToTheNew,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: export,
              readOnly: true,
              minLines: 5,
              maxLines: 9,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: response));
            if (context.mounted) _snack(context, context.l10n.approvalJsonCopied);
          },
          icon: const Icon(Icons.copy),
          label: Text(context.l10n.copy),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.done2),
        ),
      ],
    ),
  );
  export.dispose();
}

class VaultLifecycleTile extends StatelessWidget {
  const VaultLifecycleTile({
    required this.vault,
    required this.displayName,
    required this.isCurrent,
    required this.busy,
    this.onOpen,
    this.onDelete,
    this.onCancel,
    super.key,
  });

  final VaultDescriptor vault;
  final String displayName;
  final bool isCurrent;
  final bool busy;
  final Future<void> Function()? onOpen;
  final Future<void> Function()? onDelete;
  final Future<void> Function()? onCancel;

  @override
  Widget build(BuildContext context) {
    final deleting = vault.status == 'deleting';
    final statusLabel = switch (vault.status) {
      'active' => vault.canWrite ? 'ACTIVE' : context.l10n.readOnly2,
      'deleting' => context.l10n.deletionScheduled,
      _ => 'UNAVAILABLE',
    };
    final statusColor = switch (vault.status) {
      'active' when vault.canWrite => context.palette.teal,
      'deleting' => context.palette.orange,
      _ => context.palette.muted,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: context.palette.surfaceSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: context.palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_outlined, color: context.palette.lime),
            title: Text(displayName),
            subtitle: Text(
              context.l10n.roleKeyEpochActivekeyepochMembershipMembershipversion(vault.role, vault.activeKeyEpoch, vault.membershipVersion),
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                _StatusDot(label: statusLabel, color: statusColor),
                if (onOpen != null)
                  IconButton(
                    tooltip: context.l10n.openVault,
                    onPressed: () => unawaited(onOpen!()),
                    icon: const Icon(Icons.open_in_new_rounded),
                  ),
              ],
            ),
          ),
          if (deleting) ...[
            const Divider(height: 14),
            Text(
              context.l10n.readOnlyGracePeriodAllMembers,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 7),
            _DetailLine(
              label: context.l10n.deletionRequested,
              value: _vaultLifecycleDate(vault.requestedAt),
            ),
            _DetailLine(
              label: context.l10n.permanentPurgeAfter,
              value: _vaultLifecycleDate(vault.purgeAfter),
            ),
            const SizedBox(height: 7),
            Text(
              context.l10n.atTheServerDeadlineRecordsHistory,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            if (vault.role == 'owner' &&
                vault.canCancel &&
                onCancel != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : () => unawaited(onCancel!()),
                  icon: const Icon(Icons.undo_rounded),
                  label: Text(context.l10n.cancelDeletion),
                ),
              ),
            ],
          ] else if (vault.status == 'active' && vault.role == 'owner') ...[
            const Divider(height: 14),
            Text(
              context.l10n.deletingThisVaultStartsTheServer,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy || onDelete == null
                    ? null
                    : () => unawaited(onDelete!()),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(context.l10n.scheduleVaultDeletion),
              ),
            ),
          ] else if (!vault.canWrite) ...[
            const Divider(height: 14),
            Text(
              context.l10n.thisVaultIsReadOnlyFor,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
          if (isCurrent && onOpen == null && !deleting)
            Align(
              alignment: Alignment.centerLeft,
              child: _StatusDot(label: context.l10n.currentVault, color: context.palette.lime),
            ),
        ],
      ),
    );
  }
}

class _VaultReadOnlyBanner extends StatelessWidget {
  const _VaultReadOnlyBanner({required this.vault});

  final VaultDescriptor vault;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    color: context.palette.orange.withValues(alpha: .1),
    child: Row(
      children: [
        Icon(
          Icons.lock_clock_outlined,
          color: context.palette.orange,
          size: 18,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            context.l10n.vaultDeletionIsScheduledThisVault(_vaultLifecycleDate(vault.purgeAfter)),
            style: const TextStyle(fontSize: 11, height: 1.4),
          ),
        ),
      ],
    ),
  );
}

String _vaultLifecycleDate(String? value) {
  if (value == null) return '—';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  return '${DateFormat.yMMMd().add_jm().format(parsed.toLocal())} (local time)';
}

class _MobilePushSettingsCard extends StatelessWidget {
  const _MobilePushSettingsCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final configured = app.mobilePushConfigured;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('mobile_push_enabled'),
              contentPadding: EdgeInsets.zero,
              value: app.mobilePushEnabled,
              onChanged:
                  app.mobilePushBusy ||
                      (app.mobilePushEnabled == false && !configured)
                  ? null
                  : (enabled) async {
                      try {
                        await app.setMobilePushEnabled(enabled);
                      } catch (error) {
                        if (context.mounted) {
                          _snack(
                            context,
                            app.friendlyError(error),
                            error: true,
                          );
                        }
                      }
                    },
              secondary: const Icon(Icons.notifications_active_outlined),
              title: Text(context.l10n.backgroundSyncNotifications),
              subtitle: Text(
                app.mobilePushBusy
                    ? context.l10n.updatingThisDevice
                    : app.mobilePushEnabled
                    ? context.l10n.enabledForThisDeviceTheServer
                    : context.l10n.optionalBackgroundSyncHintsForThis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: 8),
              child: Text(
                configured
                    ? context.l10n.theOperatingSystemWillAskFor
                    : context.l10n.thisMobileAppBuildHasNo,
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.app,
    this.onOpenLocalMigration,
    this.webAppUpdateMonitor,
    this.onArchiveExportStarting,
    this.onArchiveExport,
  });
  final AppController app;
  final Future<void> Function(BuildContext context)? onOpenLocalMigration;
  final WebAppUpdateMonitor? webAppUpdateMonitor;
  final Future<void> Function()? onArchiveExportStarting;
  final VoidCallback? onArchiveExport;

  @override
  Widget build(BuildContext context) {
    final supportedActions =
        app.adminMaintenanceJobsPage?.supportedActions ?? const <String>[];
    final backupStatusSupported = supportedActions.contains('backup_status');
    final backupReplicationSupported = supportedActions.contains(
      'backup_replication',
    );
    final backupScheduleSupported = supportedActions.contains(
      'backup_schedule',
    );
    final cloudAccess = CloudAccessService(app);
    return SettingsScaffold(
      key: const ValueKey('cloud_settings'),
      sections: [
        SettingsSection(
          id: 'workspace',
          title: context.l10n.workspace,
          icon: Icons.dashboard_outlined,
          description: context.l10n.chooseTheWorkspaceModeAndThe2,
          builder: (_) => SettingsCards(
            children: [
              const SettingsCard(child: AppLanguageSettings()),
              const ScopedWorkspaceModeSettings(),
              if (app.activeVault != null)
                _VaultSyncedPreferencesPanel(app: app),
              Card(
                child: ListTile(
                  title: Text(context.l10n.legacySharedCredentials),
                  subtitle: Text(context.l10n.passwordsAndKeysForNewHosts2),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => app.showWorkspacePage(WorkspacePage.credentials),
                ),
              ),
            ],
          ),
        ),
        // ACCOUNT worker: account/login category (identity, session actions).
        if (remoteDesktopSettingsAvailable(Theme.of(context).platform))
          SettingsSection(
            id: 'remote-desktop',
            title: context.l10n.remoteDesktop,
            icon: Icons.desktop_windows_outlined,
            description: context.l10n.desktopKeyboardModeTitle,
            builder: (_) => const SettingsCard(child: DesktopKeyboardSettings()),
          ),
        SettingsSection(
          id: accountSettingsSectionId,
          title: context.l10n.accountSettingsTitle,
          icon: Icons.account_circle_outlined,
          description: context.l10n.accountSettingsDescription,
          builder: (_) => AccountSettingsPanel(
            app: app,
            cloudAccessControls:
                cloudAccess.organizationsAvailable || cloudAccess.linksAvailable
                ? CloudAccessAccountCard(service: cloudAccess)
                : null,
          ),
        ),
        SettingsSection(
          id: 'mcp',
          title: 'AI / MCP',
          icon: Icons.hub_outlined,
          description: context.l10n.letExternalAiAccessTheCurrent2,
          builder: (_) => const McpSettingsPanel(),
        ),
        // SETTINGS worker: Theme (UI mode + terminal font/colors) and
        // Shortcuts are separate categories.
        SettingsSection(
          id: settingsThemeSectionId,
          title: context.l10n.settingsThemeTitle,
          icon: Icons.palette_outlined,
          description: context.l10n.settingsThemeDescription,
          builder: (_) => SettingsCards(
            children: [
              const SettingsCard(child: AppThemeSettings()),
              const SettingsCard(child: WallpaperSettings()),
              if (app.activeVault != null) ...[
                SettingsCard(
                  child: _TerminalFontSizePreferenceSection(app: app),
                ),
                SettingsCard(child: _TerminalThemePreferenceSection(app: app)),
              ],
              SettingsCard(
                child: TerminalPaletteGallery(synced: app.terminalTheme),
              ),
            ],
          ),
        ),
        if (app.activeVault != null)
          SettingsSection(
            id: settingsShortcutsSectionId,
            title: context.l10n.settingsThemeShortcutsTitle,
            icon: Icons.keyboard_outlined,
            description: context.l10n.settingsThemeShortcutsDescription,
            builder: (_) => SettingsCards(
              children: [
                SettingsCard(
                  child: _TerminalShortcutsPreferenceSection(app: app),
                ),
              ],
            ),
          ),
        SettingsSection(
          id: 'security',
          title: context.l10n.accountSecurity,
          icon: Icons.shield_outlined,
          description: context.l10n.manageTheMasterPasswordTwoFactor,
          builder: (_) => SettingsCards(
            children: [
              _AccountPasswordPanel(app: app),
              AccountMfaPanel(app: app),
              _AccountRecoveryPanel(app: app),
              _AccountDeletionPanel(app: app),
            ],
          ),
        ),
        SettingsSection(
          id: 'vaults',
          title: context.l10n.vaultsAndMembers,
          icon: Icons.folder_shared_outlined,
          description: context.l10n.manageVaultsMembersAndInvitations,
          builder: (_) => Card(
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.vaults,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (app.activeVault == null) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.noVaultIsCurrentlyAvailableTo,
                      style: TextStyle(
                        color: context.palette.muted,
                        height: 1.45,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ...app.vaults.map(
                    (vault) => VaultLifecycleTile(
                      vault: vault,
                      displayName: app.vaultNameFor(vault.id),
                      isCurrent: vault.id == app.currentVaultId,
                      busy: app.vaultLifecycleBusy,
                      onOpen: vault.id == app.currentVaultId
                          ? null
                          : () => app.selectVault(vault.id),
                      onDelete:
                          vault.role == 'owner' && vault.status == 'active'
                          ? () => _deleteVault(context, app, vault)
                          : null,
                      onCancel:
                          vault.role == 'owner' &&
                              vault.status == 'deleting' &&
                              vault.canCancel
                          ? () => _cancelVaultDeletion(context, app, vault)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: app.vaultLifecycleBusy
                        ? null
                        : () => _refreshVaultStates(context, app),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.refreshVaultStates),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _createVault(context, app),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(
                      app.activeVault == null
                          ? context.l10n.createEncryptedVault
                          : context.l10n.createAnotherVault,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (app.activeVault?.role == 'owner')
                    OutlinedButton.icon(
                      onPressed: app.activeVault?.canWrite == true
                          ? () => _inviteVaultMember(context, app)
                          : null,
                      icon: const Icon(Icons.group_add_outlined),
                      label: Text(context.l10n.inviteMember),
                    ),
                  if (app.activeVault != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: app.vaultMembershipBusy
                          ? null
                          : () => _manageVaultMembers(context, app),
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: Text(
                        app.activeVault?.role == 'owner' &&
                                app.activeVault?.canWrite == true
                            ? context.l10n.manageVaultMembers
                            : context.l10n.viewVaultMembers,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _acceptVaultInvitation(context, app),
                    icon: const Icon(Icons.mark_email_read_outlined),
                    label: Text(context.l10n.acceptInvitation),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (app.activeVault != null || onOpenLocalMigration != null)
          SettingsSection(
            id: 'data',
            title: context.l10n.dataAndMigration,
            icon: Icons.import_export,
            description: context.l10n.importAndExportEncryptedArchivesOr,
            builder: (context) => SettingsCards(
              children: [
                if (app.activeVault != null)
                  _VaultArchivePanel(
                    app: app,
                    onExportStarting: onArchiveExportStarting,
                    onExported: onArchiveExport,
                  ),
                if (onOpenLocalMigration != null) ...[
                  const SizedBox(height: 13),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(17),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.localOnlyProfiles,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            context.l10n.moveEncryptedLocalHostsCredentialsGroups,
                            style: TextStyle(
                              color: context.palette.muted,
                              height: 1.45,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 11),
                          OutlinedButton.icon(
                            key: const ValueKey('local_to_sync_migration_open'),
                            onPressed: () => onOpenLocalMigration!(context),
                            icon: const Icon(Icons.sync_alt_rounded),
                            label: Text(context.l10n.reviewLocalProfileMigration),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (app.activeVault != null)
          SettingsSection(
            id: 'trust',
            title: context.l10n.sshHostTrust,
            icon: Icons.verified_user_outlined,
            description: context.l10n.reviewTrustedHostKeysAndTheir,
            builder: (_) => _KnownHostTrustPanel(app: app),
          ),
        if (webAppUpdateMonitor != null || app.mobilePushSupported)
          SettingsSection(
            id: 'notifications',
            title: context.l10n.notificationsAndUpdates,
            icon: Icons.notifications_outlined,
            description: context.l10n.manageNotificationsAndClientUpdates,
            builder: (_) => SettingsCards(
              children: [
                if (webAppUpdateMonitor != null)
                  _WebAppUpdateSettingsCard(monitor: webAppUpdateMonitor!),
                if (app.mobilePushSupported) _MobilePushSettingsCard(app: app),
              ],
            ),
          ),
        if (app.isInstanceAdmin) ...[
          SettingsSection(
            id: 'instance',
            title: context.l10n.instanceOverview,
            icon: Icons.dns_outlined,
            description: context.l10n.viewInstanceAndPushServiceStatus,
            builder: (_) => SettingsCards(
              children: [
                _InstanceAdminOverviewCard(app: app),
                _InstanceAdminPushHealthCard(app: app),
                _InstanceAdminMetricsCredentialCard(app: app),
              ],
            ),
          ),
          SettingsSection(
            id: 'access',
            title: context.l10n.accountsAndAccessPolicies,
            icon: Icons.admin_panel_settings_outlined,
            description: context.l10n.manageInstanceAccountsInvitationsRelayGroups,
            builder: (_) => SettingsCards(
              children: [
                _InstanceAdminRelayPolicyCard(app: app),
                _AdminAccountsCard(app: app),
                _AdminRelayGroupsCard(app: app),
                _AdminAccountInvitationsCard(app: app),
                _AdminVaultsCard(app: app),
              ],
            ),
          ),
          SettingsSection(
            id: 'backup',
            title: context.l10n.backupRestoreAndMaintenance,
            icon: Icons.backup_outlined,
            description: context.l10n.manageBackupsAndRestoreCopiesAnd,
            builder: (_) => SettingsCards(
              children: [
                if (backupStatusSupported)
                  _InstanceAdminBackupStatusCard(app: app),
                if (backupReplicationSupported)
                  _InstanceAdminBackupReplicationCard(app: app),
                if (backupScheduleSupported)
                  _InstanceAdminBackupScheduleCard(app: app),
                _AdminMaintenanceJobsCard(app: app),
                _InstanceAdminRestoreStageCard(app: app),
              ],
            ),
          ),
          SettingsSection(
            id: 'audit',
            title: context.l10n.auditLog,
            icon: Icons.fact_check_outlined,
            description: context.l10n.reviewInstanceActionsAndAccessAudit,
            builder: (_) =>
                SettingsCards(children: [_InstanceAdminAuditCard(app: app)]),
          ),
        ],
        SettingsSection(
          id: 'about',
          title: context.l10n.accountAndDeviceInformation,
          icon: Icons.info_outline,
          description: context.l10n.viewTheCurrentAccountDevicesAnd,
          builder: (_) => SettingsCards(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.accountDevice,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 9),
                      _DetailLine(
                        label: context.l10n.accountId,
                        value: app.account?.accountId ?? '—',
                      ),
                      _DetailLine(
                        label: context.l10n.deviceId,
                        value: app.identity?.deviceId ?? '—',
                      ),
                      _DetailLine(
                        label: context.l10n.apiEndpoint,
                        value: app.serverUrl ?? '—',
                      ),
                      _DetailLine(
                        label: context.l10n.instanceId,
                        value: app.instance?.instanceId ?? '—',
                      ),
                      const SizedBox(height: 7),
                      Text(
                        context.l10n.instanceSigningKeyFingerprintSha256,
                        style: TextStyle(color: context.palette.muted, fontSize: 11),
                      ),
                      _PublicFingerprint(
                        app: app,
                        encodedKey: app.instance?.signingPublicKey,
                        color: context.palette.lime,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        context.l10n.compareThisPublicFingerprintWithAnother,
                        style: TextStyle(color: context.palette.muted, fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => _exportVaultShareRequest(context, app),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: Text(context.l10n.copySignedShareRequest),
                      ),
                      _DetailLine(
                        label: context.l10n.protocol,
                        value: 'v${app.instance?.protocolVersion ?? 1}',
                      ),
                      _DetailLine(
                        label: context.l10n.capabilities,
                        value: app.instance?.capabilities.join(', ') ?? '—',
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.securityPolicy,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      _PolicyRow(
                        icon: Icons.check_circle_outline,
                        text: context.l10n.masterPasswordIsUsedOnlyFor,
                      ),
                      _PolicyRow(
                        icon: Icons.check_circle_outline,
                        text: context.l10n.vaultNameHostsCredentialsAndSnippets,
                      ),
                      _PolicyRow(
                        icon: Icons.check_circle_outline,
                        text: context.l10n.sshHostKeyChangesAreRejected,
                      ),
                      _PolicyRow(
                        icon: Icons.check_circle_outline,
                        text: context.l10n.privateSigningAndEncryptionKeysStay,
                      ),
                      _PolicyRow(
                        icon: Icons.info_outline,
                        text: context.l10n.instanceWideBootstrapAndNetworkPolicy,
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => app.logout(),
                  icon: const Icon(Icons.logout),
                  label: Text(context.l10n.signOut),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InstanceAdminPushHealthCard extends StatelessWidget {
  const _InstanceAdminPushHealthCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final health = app.instanceAdminPushHealth;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.pushProviderHealth,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.readOnlyProviderConfigurationAggregateQueue,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Semantics(
              label: context.l10n.pushIsABestEffortWake,
              child: Text(
                context.l10n.configuredMeansThisServerProcessLoaded,
                style: const TextStyle(fontSize: 12, height: 1.45),
              ),
            ),
            if (app.instanceAdminPushHealthLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.readingPushServiceStatus),
            ],
            if (app.instanceAdminPushHealthError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadPushServiceStatus,
                child: Text(
                  context.l10n.couldntLoadPushServiceStatusError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (health case final value?) ...[
              const SizedBox(height: 10),
              if (value.providers.isEmpty)
                Text(context.l10n.noPushProviderSnapshotIsAvailable)
              else
                for (final provider in value.providers) ...[
                  const Divider(height: 18),
                  Text(
                    _pushProviderLabel(provider.provider),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  _DetailLine(
                    label: context.l10n.providerAdapter,
                    value: provider.configured
                        ? 'Configured'
                        : context.l10n.notConfigured,
                  ),
                  _DetailLine(
                    label: context.l10n.registeredEndpoints,
                    value: _adminCount(provider.registeredEndpoints),
                  ),
                  _DetailLine(label: context.l10n.due, value: _adminCount(provider.due)),
                  _DetailLine(
                    label: context.l10n.retryWaiting,
                    value: _adminCount(provider.retryWaiting),
                  ),
                  _DetailLine(
                    label: context.l10n.leased,
                    value: _adminCount(provider.leased),
                  ),
                  _DetailLine(
                    label: context.l10n.deadLettered,
                    value: _adminCount(provider.deadLettered),
                  ),
                  if (provider.deliveryResultsAvailable) ...[
                    _DetailLine(
                      label: context.l10n.acceptedByAdapter7UtcDays,
                      value: _adminCount(provider.deliveryResults.accepted),
                    ),
                    _DetailLine(
                      label: context.l10n.invalidToken7UtcDays,
                      value: _adminCount(provider.deliveryResults.invalidToken),
                    ),
                    _DetailLine(
                      label: context.l10n.retryableFailure7UtcDays,
                      value: _adminCount(
                        provider.deliveryResults.retryableFailure,
                      ),
                    ),
                  ] else
                    Text(
                      context.l10n.deliveryHistoryIsUnavailableOnThis,
                    ),
                ],
              const SizedBox(height: 8),
              if (value.deliveryWindowAvailable)
                _DetailLine(
                  label: context.l10n.deliveryWindowUtc,
                  value:
                      '${value.deliveryStartDateUtc} – ${value.deliveryEndDateUtc}',
                ),
              _DetailLine(
                label: context.l10n.snapshotGenerated,
                value: DateFormat.yMMMd().add_jm().format(
                  value.generatedAt.toLocal(),
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('admin_push_health_load'),
              onPressed: app.instanceAdminPushHealthLoading
                  ? null
                  : () => unawaited(app.loadInstanceAdminPushHealth()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                health == null ? context.l10n.loadPushHealth : context.l10n.refreshPushHealth,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _pushProviderLabel(String provider) => switch (provider) {
  'apns' => 'APNs',
  'fcm_v1' => 'FCM HTTP v1',
  _ => currentL10n.unknownPushProvider,
};

class _InstanceAdminOverviewCard extends StatelessWidget {
  const _InstanceAdminOverviewCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final overview = app.instanceAdminOverview;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.instanceAdminOverview,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.readOnlyInstanceIdentityUsageAnd,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminOverviewLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.readingInstanceOverview),
            ],
            if (app.instanceAdminOverviewError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadInstanceOverview,
                child: Text(
                  context.l10n.couldntLoadInstanceOverviewError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (overview case final value?) ...[
              const SizedBox(height: 10),
              _DetailLine(label: context.l10n.instanceId, value: value.instanceId),
              _DetailLine(label: context.l10n.serverSpaceId, value: value.serverSpaceId),
              _DetailLine(label: context.l10n.generation, value: value.generation),
              _DetailLine(
                label: context.l10n.protocolVersion,
                value: 'v${value.protocolVersion}',
              ),
              const Divider(height: 20),
              _DetailLine(
                label: context.l10n.accounts,
                value:
                    '${_adminCount(value.accountsTotal)} total · ${_adminCount(value.accountsActive)} active · ${_adminCount(value.accountsDisabled)} disabled · ${_adminCount(value.accountsDeleting)} deleting',
              ),
              _DetailLine(
                label: context.l10n.devicesActive,
                value: _adminCount(value.devicesActive),
              ),
              _DetailLine(
                label: context.l10n.vaults,
                value:
                    '${_adminCount(value.vaultsActive)} active · ${_adminCount(value.vaultsDeleting)} deleting',
              ),
              _DetailLine(
                label: context.l10n.storedData,
                value:
                    '${_formatAdminBytes(value.storedBytes)} used · ${_formatAdminBytes(value.reservedUploadBytes)} reserved · ${_formatAdminBytes(value.vaultQuotaBytes)} quota',
              ),
              const Divider(height: 20),
              _DetailLine(
                label: context.l10n.sshRelay,
                value: value.relayEnabled ? 'Enabled' : 'Disabled',
              ),
              _DetailLine(
                label: context.l10n.relayCidrs,
                value: value.relayAllowCidrs.isEmpty
                    ? 'None'
                    : value.relayAllowCidrs.join(', '),
              ),
              _DetailLine(
                label: context.l10n.relayPorts,
                value: value.relayAllowPorts.isEmpty
                    ? 'None'
                    : value.relayAllowPorts.join(', '),
              ),
              _DetailLine(
                label: context.l10n.maxRelayConnectionsPerUser,
                value: _adminCount(value.relayMaxConnectionsPerUser),
              ),
              _DetailLine(
                label: context.l10n.generatedAt,
                value: DateFormat.yMMMd().add_jm().format(
                  value.generatedAt.toLocal(),
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: app.instanceAdminOverviewLoading
                  ? null
                  : () => unawaited(app.loadInstanceAdminOverview()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                overview == null ? context.l10n.loadOverview : context.l10n.refreshOverview,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminMetricsCredentialCard extends StatelessWidget {
  const _InstanceAdminMetricsCredentialCard({required this.app});

  final AppController app;

  Future<void> _rotate(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.rotatePrometheusScrapeCredential),
        content: Text(
          context.l10n.rotationImmediatelyInvalidatesTheCurrentCredential,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('admin-metrics-credential-confirm-rotate'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.rotateCredential),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final rotated = await app.rotateInstanceAdminMetricsCredential();
    if (!rotated || !context.mounted) return;
    try {
      await showAppDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.saveThisCredentialNow),
          content: ListenableBuilder(
            listenable: app,
            builder: (context, _) {
              final credential = app.instanceAdminMetricsCredentialOneTimeValue;
              if (credential == null) {
                return Text(
                  context.l10n.theCredentialIsNoLongerAvailable,
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.addThisValueAsTheBearer,
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    label: context.l10n.oneTimePrometheusScrapeCredential,
                    value: credential,
                    readOnly: true,
                    child: SelectableText(
                      credential,
                      key: const ValueKey('admin-metrics-credential-value'),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.ifCopyingIsUnavailableSelectThe,
                  ),
                  const SizedBox(height: 12),
                  Builder(
                    builder: (context) {
                      var copied = false;
                      var copyFailed = false;
                      var copyAttempt = 0;
                      return StatefulBuilder(
                        builder: (context, setDialogState) =>
                            OutlinedButton.icon(
                              key: const ValueKey(
                                'admin-metrics-credential-copy',
                              ),
                              onPressed: () async {
                                final attempt = ++copyAttempt;
                                setDialogState(() {
                                  copied = false;
                                  copyFailed = false;
                                });
                                try {
                                  await Clipboard.setData(
                                    ClipboardData(text: credential),
                                  ).timeout(const Duration(seconds: 5));
                                  if (context.mounted &&
                                      attempt == copyAttempt) {
                                    setDialogState(() => copied = true);
                                  }
                                } catch (_) {
                                  if (context.mounted &&
                                      attempt == copyAttempt) {
                                    setDialogState(() => copyFailed = true);
                                  }
                                }
                              },
                              icon: const Icon(Icons.copy_rounded),
                              label: Semantics(
                                key: const ValueKey(
                                  'admin-metrics-credential-copy-status',
                                ),
                                liveRegion: copyFailed,
                                child: Text(
                                  copied
                                      ? context.l10n.copied
                                      : copyFailed
                                      ? context.l10n.copyFailedSelectTheValueManually
                                      : context.l10n.copyCredential,
                                ),
                              ),
                            ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
          actions: [
            FilledButton(
              key: const ValueKey('admin-metrics-credential-saved'),
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.iveSavedIt),
            ),
          ],
        ),
      );
    } finally {
      app.clearInstanceAdminMetricsCredentialOneTimeValue();
    }
  }

  Future<void> _revoke(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.revokePrometheusScrapeCredential),
        content: Text(
          context.l10n.prometheusRequestsUsingThisCredentialWill,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('admin-metrics-credential-confirm-revoke'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.revokeCredential),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await app.revokeInstanceAdminMetricsCredential();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = app.instanceAdminMetricsCredentialStatus;
    final busy =
        app.instanceAdminMetricsCredentialLoading ||
        app.instanceAdminMetricsCredentialSaving;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.prometheusScrapeCredential,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.createADedicatedReadOnlyBearer,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminMetricsCredentialLoading ||
                app.instanceAdminMetricsCredentialSaving) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (status case final value?) ...[
              const SizedBox(height: 10),
              _DetailLine(
                label: context.l10n.credentialStatus,
                value: value.active ? 'Active' : context.l10n.noActiveCredential,
              ),
              if (value.updatedAt case final updatedAt?)
                _DetailLine(
                  label: context.l10n.lastChanged,
                  value: DateFormat.yMMMd().add_jm().format(
                    updatedAt.toLocal(),
                  ),
                ),
            ],
            if (app.instanceAdminMetricsCredentialError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: error,
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.instanceAdminMetricsCredentialNotice
                case final notice?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: notice,
                liveRegion: true,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('admin-metrics-credential-rotate'),
                  onPressed: busy ? null : () => _rotate(context),
                  icon: const Icon(Icons.key_rounded),
                  label: Text(
                    app.instanceAdminMetricsCredentialSaving
                        ? 'Rotating…'
                        : status?.active == true
                        ? context.l10n.rotateCredential
                        : context.l10n.createCredential,
                  ),
                ),
                if (status?.active == true)
                  OutlinedButton.icon(
                    key: const ValueKey('admin-metrics-credential-revoke'),
                    onPressed: busy ? null : () => _revoke(context),
                    icon: const Icon(Icons.key_off_rounded),
                    label: Text(context.l10n.revokeCredential),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('admin-metrics-credential-load'),
                  onPressed: busy
                      ? null
                      : () =>
                            unawaited(app.loadInstanceAdminMetricsCredential()),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(
                    status == null ? context.l10n.loadStatus : context.l10n.refreshStatus,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminRelayPolicyCard extends StatefulWidget {
  const _InstanceAdminRelayPolicyCard({required this.app});

  final AppController app;

  @override
  State<_InstanceAdminRelayPolicyCard> createState() =>
      _InstanceAdminRelayPolicyCardState();
}

class _InstanceAdminRelayPolicyCardState
    extends State<_InstanceAdminRelayPolicyCard> {
  late final TextEditingController _cidrsController;
  late final TextEditingController _portsController;
  InstanceAdminRelayPolicy? _observedPolicy;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _cidrsController = TextEditingController();
    _portsController = TextEditingController();
    _observedPolicy = widget.app.instanceAdminRelayPolicy;
    _applyPolicy(_observedPolicy);
    widget.app.addListener(_syncPolicyDraft);
  }

  @override
  void didUpdateWidget(covariant _InstanceAdminRelayPolicyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_syncPolicyDraft);
      _observedPolicy = widget.app.instanceAdminRelayPolicy;
      _applyPolicy(_observedPolicy);
      widget.app.addListener(_syncPolicyDraft);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_syncPolicyDraft);
    _cidrsController.dispose();
    _portsController.dispose();
    super.dispose();
  }

  void _syncPolicyDraft() {
    final policy = widget.app.instanceAdminRelayPolicy;
    if (identical(policy, _observedPolicy)) return;
    _observedPolicy = policy;
    _applyPolicy(policy);
  }

  void _applyPolicy(InstanceAdminRelayPolicy? value) {
    _enabled = value?.policy.enabled ?? false;
    _cidrsController.text = value?.policy.allowCidrs.join('\n') ?? '';
    _portsController.text = value?.policy.allowPorts.join(', ') ?? '';
  }

  Future<void> _save() async {
    await widget.app.saveInstanceAdminRelayPolicy(
      enabled: _enabled,
      allowCidrsText: _cidrsController.text,
      allowPortsText: _portsController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final value = app.instanceAdminRelayPolicy;
    final busy =
        app.instanceAdminRelayPolicyLoading ||
        app.instanceAdminRelayPolicySaving;
    final limits = value?.deploymentLimits;
    final conflict = app.instanceAdminRelayPolicyConflict;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.sshRelayPolicy,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.savedSettingsCanOnlyNarrowThe,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminRelayPolicyLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.loadingSshRelayPolicy),
            ],
            if (app.instanceAdminRelayPolicyError case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: error,
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (value case final policy?) ...[
              const Divider(height: 20),
              _DetailLine(
                label: context.l10n.deploymentRelayAvailability,
                value: policy.deploymentLimits.relayAvailable
                    ? 'Available'
                    : 'Unavailable',
              ),
              _DetailLine(
                label: context.l10n.effectiveSshRelayService,
                value: !policy.deploymentLimits.relayAvailable
                    ? 'Unavailable (deployment gate)'
                    : !policy.policy.enabled
                    ? context.l10n.disabledByPolicy
                    : policy.policyWithinDeploymentLimits
                    ? 'Enabled (deployment limits apply)'
                    : 'Enabled (current limits restrict effective access)',
              ),
              _DetailLine(
                label: context.l10n.deploymentCidrLimits,
                value: policy.deploymentLimits.allowCidrs.isEmpty
                    ? 'None'
                    : policy.deploymentLimits.allowCidrs.join(', '),
              ),
              _DetailLine(
                label: context.l10n.deploymentPortLimits,
                value: policy.deploymentLimits.allowPorts.isEmpty
                    ? 'None'
                    : policy.deploymentLimits.allowPorts.join(', '),
              ),
              _DetailLine(
                label: context.l10n.maxSshRelayConnectionsPerUser,
                value: _adminCount(policy.maxConnectionsPerUser),
              ),
              _DetailLine(
                label: context.l10n.policyRevision,
                value: policy.revision.toString(),
              ),
              _DetailLine(
                label: context.l10n.lastUpdated,
                value: policy.updatedAt == null
                    ? 'Never'
                    : '${DateFormat.yMMMd().add_jm().format(policy.updatedAt!.toLocal())} (local time)',
              ),
              const SizedBox(height: 9),
              Text(
                !policy.deploymentLimits.relayAvailable && policy.policy.enabled
                    ? context.l10n.theSavedPolicyRemainsSelectedAs
                    : !policy.policyWithinDeploymentLimits
                    ? context.l10n.theSavedPolicyExceedsTheCurrent
                    : policy.deploymentLimits.relayAvailable
                    ? context.l10n.theDeploymentGateIsAvailableWith
                    : context.l10n.toEnableSshRelayTheServer,
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('admin-relay-policy-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.enableSshRelay),
                subtitle: Text(
                  context.l10n.theServerDeploymentGateMustAlso,
                ),
                value: _enabled,
                onChanged:
                    busy ||
                        conflict ||
                        (!policy.deploymentLimits.relayAvailable && !_enabled)
                    ? null
                    : (enabled) {
                        if (enabled &&
                            !policy.deploymentLimits.relayAvailable) {
                          return;
                        }
                        setState(() => _enabled = enabled);
                      },
              ),
              TextField(
                key: const ValueKey('admin-relay-policy-cidrs'),
                controller: _cidrsController,
                enabled: !busy && !conflict,
                minLines: 2,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: context.l10n.allowedCidrsOnePerLine,
                  hintText: context.l10n.forExample104000,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 9),
              TextField(
                key: const ValueKey('admin-relay-policy-ports'),
                controller: _portsController,
                enabled: !busy && !conflict,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: context.l10n.allowedPorts,
                  hintText: context.l10n.commaOrNewlineSeparatedForExample,
                  alignLabelWithHint: true,
                ),
              ),
              if (app.instanceAdminRelayPolicySaveError case final error?) ...[
                const SizedBox(height: 9),
                Semantics(
                  label: error,
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (app.instanceAdminRelayPolicyNotice case final notice?) ...[
                const SizedBox(height: 9),
                Semantics(
                  label: notice,
                  liveRegion: true,
                  child: Text(
                    notice,
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const ValueKey('admin-relay-policy-save'),
                onPressed: busy || conflict || limits == null ? null : _save,
                icon: app.instanceAdminRelayPolicySaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  app.instanceAdminRelayPolicySaving
                      ? context.l10n.saving
                      : context.l10n.saveRelayPolicy,
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('admin-relay-policy-load'),
              onPressed: busy
                  ? null
                  : () => unawaited(app.loadInstanceAdminRelayPolicy()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                conflict
                    ? context.l10n.reloadLatestPolicy
                    : value == null
                    ? context.l10n.loadRelayPolicy
                    : context.l10n.refreshRelayPolicy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminBackupStatusCard extends StatelessWidget {
  const _InstanceAdminBackupStatusCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final status = app.instanceAdminBackupStatus;
    final attempt = status?.lastAttempt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.instanceBackupStatus,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.showsTheLatestCompletedBackupAttempt,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminBackupStatusLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.readingTheLatestBackupCommandStatus),
            ],
            if (app.instanceAdminBackupStatusError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadBackupCommandStatus,
                child: Text(
                  context.l10n.couldntLoadBackupCommandStatusError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (status != null && attempt == null) ...[
              const SizedBox(height: 12),
              Text(context.l10n.noCliOrServerTriggeredBackup),
            ],
            if (attempt case final value?) ...[
              const SizedBox(height: 12),
              _DetailLine(
                label: context.l10n.result,
                value: value.result == 'succeeded' ? 'Succeeded' : 'Failed',
              ),
              _DetailLine(
                label: context.l10n.attemptedAt,
                value: DateFormat.yMMMd().add_jm().format(
                  value.attemptedAt.toLocal(),
                ),
              ),
              if (value.result == 'succeeded') ...[
                _DetailLine(
                  label: context.l10n.migrationVersion,
                  value: value.migrationVersion.toString(),
                ),
                _DetailLine(
                  label: context.l10n.archiveBytes,
                  value: value.archiveBytes == null
                      ? context.l10n.unavailableOnThisNode
                      : _formatAdminBytes(value.archiveBytes!),
                ),
              ] else
                _DetailLine(
                  label: context.l10n.failureCategory,
                  value: context.l10n.backupCommandFailed,
                ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: app.instanceAdminBackupStatusLoading
                  ? null
                  : () => unawaited(app.loadInstanceAdminBackupStatus()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                status == null ? context.l10n.loadBackupStatus : context.l10n.refreshBackupStatus,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminBackupReplicationCard extends StatelessWidget {
  const _InstanceAdminBackupReplicationCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final status = app.instanceAdminBackupReplicationStatus;
    final attempt = status?.latestAttempt;
    final statusLoading = app.instanceAdminBackupReplicationLoading;
    final bucketCheckLoading = app.instanceAdminBackupBucketAccessCheckLoading;
    final controlsBusy = statusLoading || bucketCheckLoading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.offSiteEncryptedBackupCopies,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.theServerCanCopyEncryptedInstance,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (statusLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.readingOffSiteBackupStatus),
            ],
            if (app.instanceAdminBackupReplicationError case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.unableToLoadOffSiteBackup(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (bucketCheckLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.checkingConfiguredBucketAccessWithHeadbucket),
            ],
            if (app.instanceAdminBackupBucketAccessCheckError
                case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.unableToCheckBackupBucketAccess(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.instanceAdminBackupBucketAccessCheckNotice
                case final notice?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.backupBucketAccessCheckResultNotice(notice),
                liveRegion: true,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            if (status != null) ...[
              const SizedBox(height: 10),
              _DetailLine(
                label: context.l10n.remoteReplication,
                value: status.configured ? 'Configured' : context.l10n.notConfigured,
              ),
              if (status.configured)
                _DetailLine(
                  label: context.l10n.copiesWaiting,
                  value: status.pendingCount.toString(),
                ),
              if (status.configured && attempt == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(context.l10n.noRemoteCopyAttemptRecordedYet),
                ),
              if (attempt case final value?) ...[
                _DetailLine(
                  label: context.l10n.latestCopy,
                  value: _backupReplicationStateLabel(value.state),
                ),
                _DetailLine(
                  label: context.l10n.attemptedAt,
                  value: DateFormat.yMMMd().add_jm().format(
                    value.attemptedAt.toLocal(),
                  ),
                ),
                if (value.archiveBytes case final bytes?)
                  _DetailLine(
                    label: context.l10n.encryptedArchiveBytes,
                    value: _formatAdminBytes(bytes),
                  ),
                if (value.failureCategory case final category?)
                  _DetailLine(
                    label: context.l10n.failureCategory,
                    value: _backupReplicationFailureLabel(category),
                  ),
              ],
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('admin-backup-replication-refresh'),
              onPressed: controlsBusy
                  ? null
                  : () => unawaited(
                      app.loadInstanceAdminBackupReplicationStatus(),
                    ),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                status == null
                    ? context.l10n.loadReplicationStatus
                    : context.l10n.refreshReplicationStatus,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('admin-backup-replication-preflight'),
              onPressed: controlsBusy
                  ? null
                  : () => unawaited(app.checkInstanceAdminBackupBucketAccess()),
              icon: bucketCheckLoading
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              label: Text(context.l10n.checkBucketAccess),
            ),
          ],
        ),
      ),
    );
  }
}

String _backupReplicationStateLabel(String state) => switch (state) {
  'pending_archive' => currentL10n.preparingLocalEncryptedArchive,
  'pending' => currentL10n.waitingForRemoteCopy,
  'running' => currentL10n.copyingEncryptedArchive,
  'retry_wait' => currentL10n.retryScheduled,
  'succeeded' => currentL10n.remoteCopyVerified,
  'interrupted' => currentL10n.interruptedRetryPending,
  'failed' => currentL10n.needsOperatorAttention,
  _ => currentL10n.unknown,
};

String _backupReplicationFailureLabel(String category) => switch (category) {
  'archive_unavailable' => currentL10n.localEncryptedArchiveUnavailable,
  'credentials_invalid' => currentL10n.remoteCredentialsUnavailable,
  'remote_unavailable' => currentL10n.remoteStorageUnavailable,
  'remote_integrity_mismatch' => currentL10n.remoteArchiveIntegrityMismatch,
  'replication_failed' => currentL10n.remoteCopyFailed,
  _ => currentL10n.remoteCopyFailed,
};

class _InstanceAdminBackupScheduleCard extends StatefulWidget {
  const _InstanceAdminBackupScheduleCard({required this.app});

  final AppController app;

  @override
  State<_InstanceAdminBackupScheduleCard> createState() =>
      _InstanceAdminBackupScheduleCardState();
}

class _InstanceAdminBackupScheduleCardState
    extends State<_InstanceAdminBackupScheduleCard> {
  late final TextEditingController _intervalController;
  InstanceAdminBackupSchedule? _observedSchedule;
  bool _enabled = false;
  String? _intervalError;

  @override
  void initState() {
    super.initState();
    _intervalController = TextEditingController(text: '24');
    _observedSchedule = widget.app.instanceAdminBackupSchedule;
    _applySchedule(_observedSchedule);
    widget.app.addListener(_syncScheduleDraft);
  }

  @override
  void didUpdateWidget(covariant _InstanceAdminBackupScheduleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_syncScheduleDraft);
      _observedSchedule = widget.app.instanceAdminBackupSchedule;
      _applySchedule(_observedSchedule);
      widget.app.addListener(_syncScheduleDraft);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_syncScheduleDraft);
    _intervalController.dispose();
    super.dispose();
  }

  void _syncScheduleDraft() {
    final schedule = widget.app.instanceAdminBackupSchedule;
    if (identical(schedule, _observedSchedule)) return;
    _observedSchedule = schedule;
    _applySchedule(schedule);
  }

  void _applySchedule(InstanceAdminBackupSchedule? schedule) {
    final interval = schedule?.intervalHours;
    _enabled = interval != null;
    _intervalController.text = interval?.toString() ?? '24';
    _intervalError = null;
  }

  Future<void> _save() async {
    final schedule = widget.app.instanceAdminBackupSchedule;
    if (schedule == null) return;
    int? intervalHours;
    if (_enabled) {
      intervalHours = int.tryParse(_intervalController.text.trim());
      if (intervalHours == null || intervalHours < 1 || intervalHours > 720) {
        setState(() {
          _intervalError = context.l10n.enterAWholeNumberFrom1;
        });
        return;
      }
    }
    setState(() => _intervalError = null);
    await widget.app.saveInstanceAdminBackupSchedule(intervalHours);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final schedule = app.instanceAdminBackupSchedule;
    final busy =
        app.instanceAdminBackupScheduleLoading ||
        app.instanceAdminBackupScheduleSaving;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.scheduledEncryptedBackups,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.chooseHowOftenThisServerCreates,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminBackupScheduleLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.loadingBackupSchedule),
            ],
            if (app.instanceAdminBackupScheduleError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.unableToLoadScheduledBackupsError(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (schedule case final value?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: value.backupConfigured
                    ? context.l10n.serverBackupConfigurationReady
                    : context.l10n.serverBackupConfigurationNotReady,
                child: Row(
                  children: [
                    Icon(
                      value.backupConfigured
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 18,
                      color: value.backupConfigured
                          ? context.palette.lime
                          : context.palette.orange,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      value.backupConfigured
                          ? context.l10n.serverBackupConfigurationReady
                          : context.l10n.serverBackupConfigurationNotReady,
                    ),
                  ],
                ),
              ),
              if (!value.backupConfigured) ...[
                const SizedBox(height: 5),
                Text(
                  context.l10n.askTheServerOperatorToConfigure,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ],
              SwitchListTile.adaptive(
                key: const ValueKey('admin-backup-schedule-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.enableScheduledBackups),
                subtitle: Text(
                  context.l10n.setTheIntervalBelowThenSave,
                ),
                value: _enabled,
                onChanged: busy || (!value.backupConfigured && !_enabled)
                    ? null
                    : (enabled) => setState(() {
                        _enabled = enabled;
                        _intervalError = null;
                      }),
              ),
              if (_enabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: const ValueKey('admin-backup-schedule-interval'),
                    controller: _intervalController,
                    enabled: value.backupConfigured && !busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: context.l10n.intervalInHours,
                      hintText: context.l10n.wholeHoursFrom1To720,
                      errorText: _intervalError,
                    ),
                  ),
                ),
              _DetailLine(
                label: context.l10n.nextRun,
                value: !value.enabled
                    ? 'Disabled'
                    : value.nextRunAt == null
                    ? context.l10n.notScheduledYet
                    : '${DateFormat.yMMMd().add_jm().format(value.nextRunAt!.toLocal())} (local time)',
              ),
              if (value.lastRun case final run?) ...[
                _DetailLine(
                  label: context.l10n.lastRunStatus,
                  value: _scheduledBackupStatusLabel(run.status),
                ),
                _DetailLine(
                  label: context.l10n.scheduledFor,
                  value: DateFormat.yMMMd().add_jm().format(
                    run.scheduledFor.toLocal(),
                  ),
                ),
                _DetailLine(
                  label: context.l10n.startedAt,
                  value: DateFormat.yMMMd().add_jm().format(
                    run.startedAt.toLocal(),
                  ),
                ),
                if (run.finishedAt case final finishedAt?)
                  _DetailLine(
                    label: context.l10n.finishedAt,
                    value: DateFormat.yMMMd().add_jm().format(
                      finishedAt.toLocal(),
                    ),
                  ),
                if (run.archiveBytes case final bytes?)
                  _DetailLine(
                    label: context.l10n.archiveBytes,
                    value: _formatAdminBytes(bytes),
                  ),
                if (run.migrationVersion case final version?)
                  _DetailLine(
                    label: context.l10n.migrationVersion,
                    value: version.toString(),
                  ),
              ] else
                _DetailLine(
                  label: context.l10n.lastRun,
                  value: context.l10n.noScheduledBackupRunsRecorded,
                ),
              if (app.instanceAdminBackupScheduleSaveError
                  case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  label: context.l10n.unableToSaveScheduledBackupsError(error),
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (app.instanceAdminBackupScheduleNotice case final notice?) ...[
                const SizedBox(height: 8),
                Semantics(
                  label: notice,
                  liveRegion: true,
                  child: Text(
                    notice,
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('admin-backup-schedule-save'),
                onPressed: busy ? null : _save,
                icon: app.instanceAdminBackupScheduleSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  app.instanceAdminBackupScheduleSaving
                      ? context.l10n.saving
                      : context.l10n.saveSchedule,
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => unawaited(app.loadInstanceAdminBackupSchedule()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                schedule == null ? context.l10n.loadBackupSchedule : context.l10n.refreshSchedule,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminRestoreStageCard extends StatefulWidget {
  const _InstanceAdminRestoreStageCard({required this.app});

  final AppController app;

  @override
  State<_InstanceAdminRestoreStageCard> createState() =>
      _InstanceAdminRestoreStageCardState();
}

class _InstanceAdminRestoreStageCardState
    extends State<_InstanceAdminRestoreStageCard> {
  String? _selectedArchiveId;
  String? _selectedArchiveSource;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = widget.app;
      if (mounted &&
          app.isInstanceAdmin &&
          app.adminMaintenanceJobsPage == null &&
          !app.adminMaintenanceJobsLoading) {
        unawaited(app.loadAdminMaintenanceJobs(offset: 0));
      }
    });
  }

  Future<void> _confirmAndStart() async {
    final archiveId = _selectedArchiveId;
    final archiveSource = _selectedArchiveSource;
    if (archiveId == null || archiveSource == null) return;
    final restoreReplicaSupported =
        widget.app.adminMaintenanceJobsPage?.supportedActions.contains(
          'restore_replica',
        ) ==
        true;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.prepareIsolatedRestoreCopy2),
        content: Text(
          restoreReplicaSupported
              ? context.l10n.theServiceStaysOnlineWhileIt2
              : context.l10n.theServiceStaysOnlineWhileIt,
        ),
        actions: [
          TextButton(
            key: const ValueKey('admin-restore-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('admin-restore-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.prepareIsolatedCopy),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await widget.app.startAdminRestoreStage(
      archiveId: archiveId,
      archiveSource: archiveSource,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final jobsPage = app.adminMaintenanceJobsPage;
    final restoreSupported =
        jobsPage?.supportedActions.contains('restore') == true;
    final restoreJob =
        app.adminRestoreJob ??
        jobsPage?.jobs.where((item) => item.isRestore).firstOrNull;
    if (!restoreSupported && restoreJob == null) {
      return const SizedBox.shrink();
    }
    final restoreReplicaSupported =
        restoreSupported &&
        jobsPage?.supportedActions.contains('restore_replica') == true;
    final page = app.adminRestoreSourcesPage;
    final sources =
        page?.sources
            .where(
              (source) => source.source != 'replica' || restoreReplicaSupported,
            )
            .toList(growable: false) ??
        const <InstanceAdminRestoreSource>[];
    final busy = app.adminRestoreSourcesLoading || app.adminRestoreSubmitting;
    final selectedArchiveId = _selectedArchiveId;
    final selectedArchiveSource = _selectedArchiveSource;
    final selectedExists =
        sources.any(
          (source) =>
              source.archiveId == selectedArchiveId &&
              source.source == selectedArchiveSource,
        ) ??
        false;
    final canRetry =
        selectedArchiveId != null &&
        selectedArchiveSource != null &&
        app.canRetryAdminRestoreFor(selectedArchiveId, selectedArchiveSource);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.prepareIsolatedRestoreCopy,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (!restoreSupported && restoreJob != null) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.thisServerIsNotCurrentlyAccepting,
                style: TextStyle(color: context.palette.muted),
              ),
            ],
            const SizedBox(height: 5),
            Text(
              restoreReplicaSupported
                  ? context.l10n.chooseALocalEncryptedArchiveOr
                  : context.l10n.chooseALocalEncryptedArchiveTo,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            if (app.adminRestoreSourcesLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.loadingEncryptedArchiveSources),
            ],
            if (app.adminRestoreSourcesError case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.unableToLoadRestoreSourcesError(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (page case final sourcePage?) ...[
              const SizedBox(height: 8),
              if (sources.isEmpty)
                Text(
                  context.l10n.noSupportedEncryptedArchivesAreAvailable,
                  style: TextStyle(color: context.palette.muted),
                )
              else ...[
                RadioGroup<String>(
                  groupValue:
                      selectedArchiveId == null || selectedArchiveSource == null
                      ? null
                      : '$selectedArchiveSource:$selectedArchiveId',
                  onChanged: (value) {
                    if (restoreSupported &&
                        !busy &&
                        restoreJob?.isActive != true) {
                      final source = sources
                          .where(
                            (item) =>
                                '${item.source}:${item.archiveId}' == value,
                          )
                          .firstOrNull;
                      setState(() {
                        _selectedArchiveId = source?.archiveId;
                        _selectedArchiveSource = source?.source;
                      });
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: sources
                        .map((source) {
                          final selected =
                              source.archiveId == selectedArchiveId &&
                              source.source == selectedArchiveSource;
                          final origin = source.origin == 'scheduled'
                              ? 'Scheduled'
                              : 'Manual';
                          final sourceLabel = source.source == 'replica'
                              ? context.l10n.remoteReplica
                              : context.l10n.localArchive;
                          final createdAt = DateFormat.yMMMd().add_jm().format(
                            source.createdAt.toLocal(),
                          );
                          return RadioListTile<String>(
                            key: ValueKey(
                              'admin-restore-source-option-${source.source}-${source.archiveId}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: '${source.source}:${source.archiveId}',
                            enabled:
                                restoreSupported &&
                                !busy &&
                                restoreJob?.isActive != true,
                            // The source UUID is an internal selection value and is
                            // intentionally omitted from the visible label.
                            title: Text(
                              '$sourceLabel · $origin · $createdAt · ${_formatAdminBytes(source.archiveBytes)}',
                            ),
                            subtitle: Text(
                              selected
                                  ? context.l10n.selectedArchive
                                  : context.l10n.encryptedArchive,
                              style: TextStyle(color: context.palette.muted),
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
              ],
              if (sourcePage.total > sourcePage.limit) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      restoreReplicaSupported
                          ? context.l10n.showingValuevalueValuevalue2OfTotal(sourcePage.offset + 1, sourcePage.offset + sourcePage.sources.length, sourcePage.total)
                          : context.l10n.showingCountLocalArchivesOnThis(sources.length),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton(
                      key: const ValueKey('admin-restore-source-previous'),
                      onPressed: busy || !sourcePage.hasPrevious
                          ? null
                          : () => unawaited(
                              app.loadAdminRestoreSources(
                                offset: (sourcePage.offset - sourcePage.limit)
                                    .clamp(0, 1000000)
                                    .toInt(),
                              ),
                            ),
                      child: Text(context.l10n.previous),
                    ),
                    const SizedBox(width: 7),
                    OutlinedButton(
                      key: const ValueKey('admin-restore-source-next'),
                      onPressed: busy || !sourcePage.hasNext
                          ? null
                          : () => unawaited(
                              app.loadAdminRestoreSources(
                                offset: sourcePage.offset + sourcePage.limit,
                              ),
                            ),
                      child: Text(context.l10n.next),
                    ),
                  ],
                ),
              ],
            ],
            if (app.adminRestoreError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.unableToPrepareIsolatedRestoreCopy(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              if (canRetry && restoreSupported) ...[
                const SizedBox(height: 7),
                OutlinedButton.icon(
                  key: const ValueKey('admin-restore-retry'),
                  onPressed: app.adminRestoreSubmitting
                      ? null
                      : () => unawaited(
                          app.startAdminRestoreStage(
                            archiveId: selectedArchiveId!,
                            archiveSource: selectedArchiveSource!,
                          ),
                        ),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(context.l10n.retryRequestSafely),
                ),
              ],
            ],
            if (app.adminRestorePollingError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.unableToRefreshRestoreStageStatus(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.orange),
                ),
              ),
            ],
            if (app.adminRestoreNotice case final notice?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: notice,
                liveRegion: true,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            if (restoreJob case final stageJob?) ...[
              const Divider(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.restoreStagingAdminrestorejobstatuslabel(_adminRestoreJobStatusLabel(stageJob)),
                      key: const ValueKey('admin-restore-job-status'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (app.adminRestorePolling)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (stageJob.isActive) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 8),
              _DetailLine(label: context.l10n.stageId, value: stageJob.jobId),
              _DetailLine(
                label: context.l10n.requestedAt,
                value: DateFormat.yMMMd().add_jm().format(
                  stageJob.requestedAt.toLocal(),
                ),
              ),
              if (restoreSupported || stageJob.isActive)
                OutlinedButton.icon(
                  key: const ValueKey('admin-restore-status-refresh'),
                  onPressed:
                      app.adminRestorePolling || app.adminRestoreSourcesLoading
                      ? null
                      : () => unawaited(app.refreshAdminRestoreStage()),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(context.l10n.refreshRestoreStatus),
                ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('admin-restore-submit'),
                  onPressed:
                      busy ||
                          !restoreSupported ||
                          !selectedExists ||
                          restoreJob?.isActive == true
                      ? null
                      : _confirmAndStart,
                  icon: app.adminRestoreSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_rounded),
                  label: Text(
                    app.adminRestoreSubmitting
                        ? 'Submitting…'
                        : context.l10n.prepareIsolatedCopy,
                  ),
                ),
                if (restoreSupported)
                  OutlinedButton.icon(
                    key: const ValueKey('admin-restore-source-load'),
                    onPressed: busy || restoreJob?.isActive == true
                        ? null
                        : () =>
                              unawaited(app.loadAdminRestoreSources(offset: 0)),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(
                      page == null
                          ? context.l10n.loadRestoreSources
                          : context.l10n.refreshRestoreSources,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _adminRestoreJobStatusLabel(AdminMaintenanceJob job) {
  if (job.status == 'succeeded' ||
      (job.status == 'interrupted' &&
          const {
            'ready',
            'discarding',
            'discarded',
          }.contains(job.restoreStageStatus))) {
    return switch (job.restoreStageStatus) {
      'ready' => currentL10n.prepared,
      'discarding' => currentL10n.cleanupPending,
      'discarded' => currentL10n.discarded,
      'unverified' => currentL10n.unverified,
      _ => currentL10n.unverified,
    };
  }
  return switch (job.status) {
    'queued' => currentL10n.queued,
    'running' => currentL10n.preparingIsolatedCopy,
    'failed' => currentL10n.failed2,
    'interrupted' => currentL10n.interrupted,
    _ => currentL10n.unknown,
  };
}

String _scheduledBackupStatusLabel(String status) => switch (status) {
  'running' => currentL10n.running,
  'succeeded' => currentL10n.succeeded2,
  'failed' => currentL10n.failed2,
  'interrupted' => currentL10n.interrupted,
  _ => currentL10n.unknown,
};

class _AdminVaultsCard extends StatelessWidget {
  const _AdminVaultsCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final page = app.adminVaultsPage;
    final start = page == null || page.vaults.isEmpty ? 0 : page.offset + 1;
    final end = page == null ? 0 : page.offset + page.vaults.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.instanceVaultQuotas,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.vaultMetadataAndStorageLimitsEncrypted,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.adminVaultsLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.readingVaultList),
            ],
            if (app.adminVaultsError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadTheAdminVaultList,
                child: Text(
                  context.l10n.couldntLoadTheVaultListError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminVaultMutationError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntUpdateTheVaultQuota,
                child: Text(
                  context.l10n.couldntUpdateTheVaultQuotaError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminVaultMutationNotice case final notice?) ...[
              const SizedBox(height: 12),
              Text(notice, style: TextStyle(color: context.palette.lime)),
            ],
            if (page case final value?) ...[
              const SizedBox(height: 12),
              Text(
                value.total == 0
                    ? context.l10n.noVaultsFound
                    : context.l10n.showingStartEndOfAdmincountVaults(start, end, _adminCount(value.total)),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              if (value.vaults.isEmpty && value.total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(context.l10n.noVaultsOnThisPage),
                ),
              ...value.vaults.map(
                (vault) => _AdminVaultMetadataTile(app: app, vault: vault),
              ),
              if (value.hasPrevious || value.hasNext) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasPrevious ||
                              app.adminVaultsLoading ||
                              app.adminVaultQuotaSaving
                          ? null
                          : () => unawaited(app.previousAdminVaultsPage()),
                      icon: const Icon(Icons.chevron_left_rounded),
                      label: Text(context.l10n.previous),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasNext ||
                              app.adminVaultsLoading ||
                              app.adminVaultQuotaSaving
                          ? null
                          : () => unawaited(app.nextAdminVaultsPage()),
                      icon: const Icon(Icons.chevron_right_rounded),
                      label: Text(context.l10n.next),
                    ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: app.adminVaultsLoading || app.adminVaultQuotaSaving
                  ? null
                  : () => unawaited(
                      app.loadAdminVaults(offset: page?.offset ?? 0),
                    ),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(page == null ? context.l10n.loadVaults : context.l10n.refreshVaultList),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminVaultMetadataTile extends StatelessWidget {
  const _AdminVaultMetadataTile({required this.app, required this.vault});

  final AppController app;
  final AdminVaultMetadata vault;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 10),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  vault.ownerUsername,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Chip(label: Text(vault.state)),
            ],
          ),
          _DetailLine(label: context.l10n.vaultId, value: vault.vaultId),
          _DetailLine(label: context.l10n.ownerUserId, value: vault.ownerUserId),
          _DetailLine(
            label: context.l10n.stored,
            value: _formatAdminBytes(vault.storedBytes),
          ),
          _DetailLine(
            label: context.l10n.reservedUploads,
            value: _formatAdminBytes(vault.reservedUploadBytes),
          ),
          _DetailLine(
            label: context.l10n.quota,
            value: _formatAdminBytes(vault.quotaBytes),
          ),
          _DetailLine(
            label: context.l10n.createdAt,
            value: DateFormat.yMMMd().add_jm().format(
              vault.createdAt.toLocal(),
            ),
          ),
          const SizedBox(height: 5),
          OutlinedButton.icon(
            onPressed: app.adminVaultQuotaSaving
                ? null
                : () => unawaited(_editAdminVaultQuota(context, app, vault)),
            icon: const Icon(Icons.storage_rounded),
            label: Text(context.l10n.editQuota),
          ),
        ],
      ),
    ),
  );
}

Future<void> _editAdminVaultQuota(
  BuildContext context,
  AppController app,
  AdminVaultMetadata vault,
) async {
  final quotaBytes = await showAppDialog<int>(
    context: context,
    builder: (_) => _AdminVaultQuotaDialog(vault: vault),
  );
  if (quotaBytes == null || !context.mounted) return;
  await app.updateAdminVaultQuota(
    vaultId: vault.vaultId,
    quotaBytes: quotaBytes,
  );
}

class _AdminVaultQuotaDialog extends StatefulWidget {
  const _AdminVaultQuotaDialog({required this.vault});

  final AdminVaultMetadata vault;

  @override
  State<_AdminVaultQuotaDialog> createState() => _AdminVaultQuotaDialogState();
}

class _AdminVaultQuotaDialogState extends State<_AdminVaultQuotaDialog> {
  late final TextEditingController _quotaController = TextEditingController(
    text: '${widget.vault.quotaBytes}',
  );
  String? _error;

  @override
  void dispose() {
    _quotaController.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_quotaController.text.trim());
    if (value == null || value < 1 || value > maxAdminVaultQuotaBytes) {
      setState(() => _error = context.l10n.enterAQuotaFrom1Byte);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.editVaultQuota),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.vaultVaultid(widget.vault.vaultId)),
        const SizedBox(height: 10),
        TextField(
          controller: _quotaController,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: context.l10n.quotaInBytes,
            errorText: _error,
          ),
          onSubmitted: (_) => _save(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(onPressed: _save, child: Text(context.l10n.saveQuota)),
    ],
  );
}

class _InstanceAdminAuditCard extends StatelessWidget {
  const _InstanceAdminAuditCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final page = app.adminAuditPage;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.instanceAdminAudit,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.installationWideEventsSeparateFromAccount,
                        style: TextStyle(color: context.palette.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: page == null
                      ? context.l10n.loadAdminAudit
                      : context.l10n.refreshAdminAudit,
                  onPressed: app.adminAuditLoading
                      ? null
                      : () => unawaited(app.refreshInstanceAdminAudit()),
                  icon: app.adminAuditLoading
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (app.adminAuditError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadInstanceAdminAuditRecords,
                child: Text(
                  context.l10n.couldntLoadInstanceAdminAuditRecords2(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: app.adminAuditLoading
                    ? null
                    : () => unawaited(app.refreshInstanceAdminAudit()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(context.l10n.reloadFirstPage),
              ),
            ] else if (app.adminAuditLoading && page == null) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.readingInstanceAdminAuditRecords),
            ] else if (page case final value?) ...[
              if (value.events.isEmpty) ...[
                const SizedBox(height: 14),
                Text(context.l10n.noInstanceAdminAuditEvents),
              ] else ...[
                const SizedBox(height: 12),
                ...value.events.map(
                  (event) => _InstanceAdminAuditEventTile(event: event),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    context.l10n.pageValuevalue(app.adminAuditPageIndex + 1),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.muted,
                    ),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed:
                        app.adminAuditLoading || app.adminAuditPageIndex == 0
                        ? null
                        : () => unawaited(app.previousInstanceAdminAuditPage()),
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: Text(context.l10n.previous),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: app.adminAuditLoading || !value.hasMore
                        ? null
                        : () => unawaited(app.nextInstanceAdminAuditPage()),
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: Text(context.l10n.next),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InstanceAdminAuditEventTile extends StatelessWidget {
  const _InstanceAdminAuditEventTile({required this.event});

  final InstanceAdminAuditEvent event;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 9),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _instanceAdminAuditActionLabel(event.action),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                _instanceAdminAuditResultLabel(event.result),
                style: TextStyle(
                  color: event.result == 'success'
                      ? context.palette.lime
                      : context.palette.red,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _DetailLine(label: context.l10n.eventId, value: event.eventId),
          _DetailLine(label: context.l10n.resourceType, value: event.resourceType),
          _DetailLine(
            label: context.l10n.resourceIdHmacSha256,
            value: event.resourceIdHmac ?? '—',
          ),
          _DetailLine(label: context.l10n.actorUserId, value: event.actorUserId ?? '—'),
          _DetailLine(
            label: context.l10n.actorDeviceId,
            value: event.actorDeviceId ?? '—',
          ),
          _DetailLine(
            label: context.l10n.occurredAt,
            value: DateFormat.yMMMd().add_jm().format(
              event.occurredAt.toLocal(),
            ),
          ),
          _DetailLine(
            label: context.l10n.source,
            value: event.source == 'maintenance' ? 'Maintenance' : 'API',
          ),
        ],
      ),
    ),
  );
}

class _AdminMaintenanceJobsCard extends StatelessWidget {
  const _AdminMaintenanceJobsCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final page = app.adminMaintenanceJobsPage;
    final active = page?.jobs.any((job) => job.isActive) ?? false;
    final supportedActions = page?.supportedActions ?? const <String>[];
    final backupSupported = supportedActions.contains('backup');
    final restoreSupported = supportedActions.contains('restore');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.instanceJobs,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.maintenanceRunsTheConfiguredRetentionAnd,
                        style: TextStyle(color: context.palette.muted, fontSize: 12),
                      ),
                      if (backupSupported) ...[
                        const SizedBox(height: 7),
                        Text(
                          context.l10n.encryptedBackupsAreCreatedOnThe,
                          style: TextStyle(
                            color: context.palette.muted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ],
                      if (restoreSupported) ...[
                        const SizedBox(height: 7),
                        Text(
                          context.l10n.restorePreparesAnIsolatedCopyWhile,
                          style: TextStyle(
                            color: context.palette.muted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: page == null
                      ? context.l10n.loadInstanceJobs
                      : context.l10n.refreshInstanceJobs,
                  onPressed: app.adminMaintenanceJobsLoading
                      ? null
                      : () => unawaited(app.refreshAdminMaintenanceJobs()),
                  icon: app.adminMaintenanceJobsLoading
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed:
                      app.adminMaintenanceJobSubmitting ||
                          app.adminBackupJobSubmitting ||
                          active
                      ? null
                      : () => unawaited(app.runAdminMaintenance()),
                  icon: app.adminMaintenanceJobSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cleaning_services_rounded),
                  label: Text(
                    app.adminMaintenanceJobSubmitting
                        ? 'Submitting…'
                        : context.l10n.runMaintenanceNow,
                  ),
                ),
                if (backupSupported)
                  FilledButton.tonalIcon(
                    onPressed:
                        app.adminMaintenanceJobSubmitting ||
                            app.adminBackupJobSubmitting ||
                            active
                        ? null
                        : () => unawaited(app.runAdminBackup()),
                    icon: app.adminBackupJobSubmitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.backup_outlined),
                    label: Text(
                      app.adminBackupJobSubmitting
                          ? context.l10n.submittingBackup
                          : context.l10n.runEncryptedBackup,
                    ),
                  ),
                if (page == null && !app.adminMaintenanceJobsLoading)
                  OutlinedButton.icon(
                    onPressed: () =>
                        unawaited(app.loadAdminMaintenanceJobs(offset: 0)),
                    icon: const Icon(Icons.list_alt_rounded),
                    label: Text(context.l10n.loadInstanceJobs),
                  ),
              ],
            ),
            if (app.adminMaintenanceJobsNotice case final notice?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.instanceMaintenanceJobSubmitted,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            if (app.adminBackupJobNotice case final notice?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.encryptedBackupJobSubmitted,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            if (app.adminBackupJobError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.couldntSubmitTheEncryptedBackupJob,
                child: Text(
                  context.l10n.couldntSubmitTheEncryptedBackupJob2(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              const SizedBox(height: 7),
              OutlinedButton.icon(
                onPressed: app.adminBackupJobSubmitting
                    ? null
                    : () => unawaited(app.runAdminBackup()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(
                  app.canRetryAdminBackupSubmission
                      ? context.l10n.retryBackupRequestSafely
                      : context.l10n.submitBackupRequest,
                ),
              ),
            ],
            if (app.adminRestoreStageDiscardError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.unableToDiscardIsolatedRestoreCopy(error),
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              if (app.adminRestoreStageDiscardRetryJobId case final jobId?)
                OutlinedButton.icon(
                  key: const ValueKey('admin-restore-stage-discard-retry'),
                  onPressed: app.adminRestoreStageDiscardingJobId != null
                      ? null
                      : () => unawaited(app.discardAdminRestoreStage(jobId)),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(context.l10n.retryDiscardSafely),
                ),
            ],
            if (app.adminRestoreStageDiscardNotice case final notice?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: notice,
                liveRegion: true,
                child: Text(
                  notice,
                  style: TextStyle(color: context.palette.lime),
                ),
              ),
            ],
            if (app.adminMaintenanceJobsError case final error?) ...[
              const SizedBox(height: 9),
              Semantics(
                label: context.l10n.couldntReadOrSubmitInstanceJobs,
                child: Text(
                  context.l10n.couldntReadOrSubmitInstanceJobs2(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              const SizedBox(height: 7),
              OutlinedButton.icon(
                onPressed: app.adminMaintenanceJobSubmitting
                    ? null
                    : () => unawaited(
                        !app.canRetryAdminMaintenanceSubmission
                            ? app.refreshAdminMaintenanceJobs()
                            : app.runAdminMaintenance(),
                      ),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(
                  !app.canRetryAdminMaintenanceSubmission
                      ? context.l10n.reloadFirstPage
                      : context.l10n.retryRequestSafely,
                ),
              ),
            ] else if (app.adminMaintenanceJobsLoading && page == null) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.readingInstanceJobs),
            ] else if (page case final value?) ...[
              if (value.jobs.isEmpty) ...[
                const SizedBox(height: 14),
                Text(context.l10n.noInstanceJobs),
              ] else ...[
                const SizedBox(height: 8),
                ...value.jobs.map(
                  (job) => _AdminMaintenanceJobTile(job, app: app),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    value.total == 0
                        ? context.l10n.noJobs
                        : context.l10n.showingValuevalueValuevalue2OfTotal(value.offset + 1, value.offset + value.jobs.length, value.total),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.muted,
                    ),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed:
                        app.adminMaintenanceJobsLoading || !value.hasPrevious
                        ? null
                        : () =>
                              unawaited(app.previousAdminMaintenanceJobsPage()),
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: Text(context.l10n.previous),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: app.adminMaintenanceJobsLoading || !value.hasNext
                        ? null
                        : () => unawaited(app.nextAdminMaintenanceJobsPage()),
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: Text(context.l10n.next),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminMaintenanceJobTile extends StatelessWidget {
  const _AdminMaintenanceJobTile(this.job, {required this.app});

  final AdminMaintenanceJob job;
  final AppController app;

  Future<void> _confirmAndDiscard(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.discardIsolatedRestoreCopy),
        content: Text(
          context.l10n.theServerFirstValidatesThatThis,
        ),
        actions: [
          TextButton(
            key: const ValueKey('admin-restore-stage-discard-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('admin-restore-stage-discard-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.discardIsolatedCopy),
          ),
        ],
      ),
    );
    if (context.mounted && confirmed == true) {
      await app.discardAdminRestoreStage(job.jobId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final restoreReplicaSupported =
        app.adminMaintenanceJobsPage?.supportedActions.contains(
          'restore_replica',
        ) ==
        true;
    final title = job.isRestore
        ? context.l10n.restoreStaging
        : job.isBackup
        ? context.l10n.encryptedBackup
        : context.l10n.maintenance;
    final result = switch ((job.action, job.resultCode)) {
      ('backup', 'completed') => context.l10n.adminJobBackupCompleted,
      ('backup', 'backup_failed') => context.l10n.adminJobBackupFailed,
      ('backup', 'interrupted') => context.l10n.adminJobBackupInterrupted,
      ('restore', 'completed') => context.l10n.adminJobRestorePrepared,
      ('restore', 'restore_failed') => context.l10n.adminJobRestoreFailed,
      ('restore', 'interrupted') =>
        job.restoreStageStatus == 'ready'
            ? context.l10n.adminJobRestorePreparedStatusInterrupted
            : context.l10n.adminJobRestoreInterrupted,
      ('maintenance', 'maintenance_failed') =>
        context.l10n.adminJobMaintenanceFailed,
      ('maintenance', 'interrupted') =>
        context.l10n.adminJobMaintenanceInterrupted,
      (_, final code?) => context.l10n.adminJobResultCode(code),
      _ => null,
    };
    final stageActionLabel = switch (job.restoreStageStatus) {
      'ready' => context.l10n.discardIsolatedCopy,
      'discarding' => context.l10n.retryDiscard,
      'unverified' => context.l10n.verifyAndDiscard,
      _ => null,
    };
    final restoreStageDiscardSupported =
        app.adminMaintenanceJobsPage?.supportedActions.contains(
          'restore_stage_discard',
        ) ==
        true;
    return Card(
      margin: const EdgeInsets.only(top: 7),
      child: ListTile(
        leading: Icon(
          job.isActive
              ? Icons.hourglass_top_rounded
              : job.status == 'succeeded'
              ? Icons.check_circle_outline_rounded
              : Icons.info_outline_rounded,
          color: job.status == 'failed' ? context.palette.red : context.palette.lime,
        ),
        title: Text('$title · ${job.status}'),
        subtitle: Text(
          [
            'Requested ${DateFormat.yMMMd().add_jm().format(job.requestedAt.toLocal())}',
            if (job.isRestore &&
                (job.archiveSource != 'replica' || restoreReplicaSupported))
              'Source: ${job.archiveSource == 'replica' ? 'Remote replica' : 'Local archive'}',
            if (job.isRestore && job.restoreStageStatus == 'ready')
              'Isolated copy: ready',
            if (job.isRestore && job.restoreStageStatus == 'discarded')
              'Isolated copy: discarded',
            if (job.isRestore && job.restoreStageStatus == 'discarding')
              'Isolated copy: cleanup pending',
            if (job.isRestore && job.restoreStageStatus == 'unverified')
              'Isolated copy: unverified',
            if (result != null) result,
            'Job ${job.jobId}',
          ].join(' · '),
        ),
        trailing:
            job.isRestore &&
                restoreStageDiscardSupported &&
                (job.status == 'succeeded' ||
                    (job.status == 'interrupted' &&
                        const {
                          'ready',
                          'discarding',
                        }.contains(job.restoreStageStatus))) &&
                stageActionLabel != null
            ? app.adminRestoreStageDiscardingJobId == job.jobId
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      key: ValueKey('admin-restore-stage-discard-${job.jobId}'),
                      tooltip: stageActionLabel,
                      onPressed: app.adminRestoreStageDiscardingJobId != null
                          ? null
                          : () => unawaited(_confirmAndDiscard(context)),
                      icon: const Icon(Icons.delete_outline_rounded),
                    )
            : null,
        isThreeLine: false,
      ),
    );
  }
}

class _AdminAccountsCard extends StatelessWidget {
  const _AdminAccountsCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final page = app.adminAccountsPage;
    final first = page == null || page.accounts.isEmpty ? 0 : page.offset + 1;
    final last = page == null ? 0 : page.offset + page.accounts.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.instanceAccountsAndSessions,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.disableOrReEnableAccountsAnd,
                        style: TextStyle(color: context.palette.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: page == null
                      ? context.l10n.loadAdminAccounts
                      : context.l10n.refreshAdminAccounts,
                  onPressed:
                      app.adminAccountsLoading ||
                          app.adminAccountActionBusyId != null
                      ? null
                      : () => unawaited(
                          app.loadAdminAccounts(offset: page?.offset ?? 0),
                        ),
                  icon: app.adminAccountsLoading
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (app.adminAccountsError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadTheAdminAccountList,
                child: Text(
                  context.l10n.couldntLoadTheAccountListError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    app.adminAccountsLoading ||
                        app.adminAccountActionBusyId != null
                    ? null
                    : () => unawaited(
                        app.loadAdminAccounts(offset: page?.offset ?? 0),
                      ),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(context.l10n.retryAccountList),
              ),
            ],
            if (app.adminAccountActionError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.adminAccountActionFailed,
                child: Text(
                  context.l10n.accountActionFailedError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminAccountActionNotice case final notice?) ...[
              const SizedBox(height: 12),
              Text(notice, style: TextStyle(color: context.palette.lime)),
            ],
            if (app.adminAccountsLoading && page == null) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.readingAdminAccountList),
            ] else if (page case final value?) ...[
              const SizedBox(height: 12),
              Text(
                value.total == 0
                    ? context.l10n.noAccountsFound
                    : context.l10n.showingFirstLastOfAdmincountAccounts(first, last, _adminCount(value.total)),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              if (value.accounts.isEmpty && value.total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(context.l10n.noAccountsOnThisPage),
                ),
              ...value.accounts.map(
                (account) => _AdminAccountTile(app: app, account: account),
              ),
              if (value.hasPrevious || value.hasNext) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasPrevious ||
                              app.adminAccountsLoading ||
                              app.adminAccountActionBusyId != null
                          ? null
                          : () => unawaited(app.previousAdminAccountsPage()),
                      icon: const Icon(Icons.chevron_left_rounded),
                      label: Text(context.l10n.previous),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasNext ||
                              app.adminAccountsLoading ||
                              app.adminAccountActionBusyId != null
                          ? null
                          : () => unawaited(app.nextAdminAccountsPage()),
                      icon: const Icon(Icons.chevron_right_rounded),
                      label: Text(context.l10n.next),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminRelayGroupsCard extends StatefulWidget {
  const _AdminRelayGroupsCard({required this.app});

  final AppController app;

  @override
  State<_AdminRelayGroupsCard> createState() => _AdminRelayGroupsCardState();
}

class _AdminRelayGroupsCardState extends State<_AdminRelayGroupsCard> {
  late final TextEditingController _createNameController;
  late final TextEditingController _renameController;
  late final TextEditingController _cidrsController;
  late final TextEditingController _portsController;
  String? _selectedMemberId;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _createNameController = TextEditingController();
    _renameController = TextEditingController(
      text: app.adminRelayGroupNameDraft,
    );
    _cidrsController = TextEditingController(
      text: app.adminRelayGroupPolicyCidrsDraft,
    );
    _portsController = TextEditingController(
      text: app.adminRelayGroupPolicyPortsDraft,
    );
  }

  @override
  void didUpdateWidget(covariant _AdminRelayGroupsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(_renameController, app.adminRelayGroupNameDraft);
    _syncController(_cidrsController, app.adminRelayGroupPolicyCidrsDraft);
    _syncController(_portsController, app.adminRelayGroupPolicyPortsDraft);
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _createNameController.dispose();
    _renameController.dispose();
    _cidrsController.dispose();
    _portsController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final created = await app.createAdminRelayGroup(
      name: _createNameController.text,
    );
    if (created && mounted) _createNameController.clear();
  }

  Future<void> _deleteGroup() async {
    final detail = app.adminRelayGroupDetail;
    if (detail == null) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteServerManagedGroup2),
        content: Text(
          context.l10n.permanentlyDeleteNameItsMembershipAnd(detail.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.deleteGroup3),
          ),
        ],
      ),
    );
    if (confirmed == true) await app.deleteAdminRelayGroup();
  }

  String _summarize(List<Object> values) {
    if (values.isEmpty) return 'none';
    final visible = values.take(6).join(', ');
    final remaining = values.length - 6;
    return remaining > 0 ? '$visible, and $remaining more' : visible;
  }

  String _formatTime(DateTime? value) =>
      value == null ? '—' : DateFormat.yMMMd().add_jm().format(value.toLocal());

  @override
  Widget build(BuildContext context) {
    final detail = app.adminRelayGroupDetail;
    final instancePolicy = app.adminRelayGroupInstancePolicy;
    final groups = app.adminRelayGroups;
    final isBusy =
        app.adminRelayGroupsLoading ||
        app.adminRelayGroupSaving ||
        app.adminRelayGroupDetailLoading ||
        app.adminRelayGroupDetailSaving;
    final accountsPage = app.adminAccountsPage;
    final availableMembers = (accountsPage?.accounts ?? const [])
        .where(
          (account) =>
              account.status == 'active' &&
              !app.adminRelayGroupMemberIdsDraft.contains(account.userId),
        )
        .toList(growable: false);
    final canAddMember = availableMembers.any(
      (account) => account.userId == _selectedMemberId,
    );
    final selectedPolicy = detail?.policy.policy;
    final effectivePolicy = detail?.policy.effectivePolicy;
    final limits = instancePolicy?.effectiveUserRelayPolicyLimits;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.serverManagedAccessGroups,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.theseInstanceGroupsControlSshRelay,
                        style: TextStyle(color: context.palette.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('admin_relay_groups_refresh'),
                  tooltip: groups.isEmpty
                      ? context.l10n.loadServerManagedGroups
                      : context.l10n.refreshServerManagedGroups,
                  onPressed: isBusy
                      ? null
                      : () => unawaited(app.loadAdminRelayGroups()),
                  icon: app.adminRelayGroupsLoading
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (app.adminRelayGroupsError case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.unableToLoadServerManagedGroups,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              OutlinedButton.icon(
                onPressed: isBusy
                    ? null
                    : () => unawaited(app.loadAdminRelayGroups()),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retryGroupList),
              ),
            ],
            if (app.adminRelayGroupActionError case final error?) ...[
              const SizedBox(height: 8),
              Semantics(
                label: context.l10n.serverManagedGroupActionFailed,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminRelayGroupNotice case final notice?) ...[
              const SizedBox(height: 8),
              Text(notice, style: TextStyle(color: context.palette.lime)),
            ],
            if (app.adminRelayGroupsLoading && groups.isEmpty) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.loadingServerManagedGroups),
            ] else if (groups.isEmpty && app.adminRelayGroupsError == null) ...[
              const SizedBox(height: 10),
              Text(context.l10n.noServerManagedGroupsYet),
            ],
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...groups.map((group) {
                final selected = group.groupId == app.adminRelayGroupId;
                return Card(
                  key: ValueKey('server_relay_group_${group.groupId}'),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    selected: selected,
                    leading: Icon(
                      selected
                          ? Icons.folder_open_rounded
                          : Icons.group_outlined,
                    ),
                    title: Text(group.name),
                    subtitle: Text(
                      context.l10n.membercountMembersValuevalueRevisionRevision(group.memberCount, group.policyInherited ? 'inherits instance Relay policy' : 'group Relay override', group.revision),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: isBusy
                        ? null
                        : () => unawaited(
                            app.selectAdminRelayGroup(groupId: group.groupId),
                          ),
                  ),
                );
              }),
            ],
            const SizedBox(height: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('admin_relay_group_create_name'),
                  controller: _createNameController,
                  enabled: !isBusy,
                  maxLength: 80,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_createGroup()),
                  decoration: InputDecoration(
                    labelText: context.l10n.newServerGroupName,
                    helperText: context.l10n.n180UnicodeCharactersUniqueWithout,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: FilledButton.icon(
                    onPressed: isBusy ? null : () => unawaited(_createGroup()),
                    icon: app.adminRelayGroupSaving
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    label: Text(context.l10n.createGroup),
                  ),
                ),
              ],
            ),
            if (app.adminRelayGroupDetailLoading && detail == null) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.loadingGroupMembershipAndRelayPolicy),
            ],
            if (app.adminRelayGroupDetailError case final error?) ...[
              const SizedBox(height: 10),
              Semantics(
                label: context.l10n.unableToLoadServerManagedGroup,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              OutlinedButton.icon(
                onPressed: isBusy || app.adminRelayGroupId == null
                    ? null
                    : () => unawaited(
                        app.loadAdminRelayGroupDetail(
                          groupId: app.adminRelayGroupId!,
                          preserveDraft: true,
                        ),
                      ),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retryGroupDetails),
              ),
            ],
            if (detail != null) ...[
              const Divider(height: 26),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.selectedServerManagedGroup,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.reloadGroupAndInstancePoliciesKeep,
                    onPressed: isBusy
                        ? null
                        : () => unawaited(
                            app.loadAdminRelayGroupDetail(
                              groupId: detail.groupId,
                              preserveDraft: true,
                            ),
                          ),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: context.l10n.deleteServerManagedGroup,
                    onPressed: isBusy || app.adminRelayGroupConflict
                        ? null
                        : () => unawaited(_deleteGroup()),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              Text(
                context.l10n.groupRevisionRevisionMembershipRevisionMembershiprevision(detail.revision, detail.membershipRevision, detail.policy.revision),
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
              Text(
                context.l10n.createdFormattimeUpdatedFormattime2(_formatTime(detail.createdAt), _formatTime(detail.updatedAt)),
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('admin_relay_group_rename'),
                      controller: _renameController,
                      enabled: !isBusy,
                      maxLength: 80,
                      decoration: InputDecoration(
                        labelText: context.l10n.groupName3,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: app.editAdminRelayGroupNameDraft,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton.icon(
                      onPressed:
                          isBusy ||
                              app.adminRelayGroupConflict ||
                              app.adminRelayGroupNameDraft.trim() == detail.name
                          ? null
                          : () => unawaited(app.saveAdminRelayGroupName()),
                      icon: const Icon(Icons.save_outlined),
                      label: Text(context.l10n.rename),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.members,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (detail.members.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(context.l10n.thisGroupHasNoMembers),
                ),
              ...detail.members.map((member) {
                final selected = app.adminRelayGroupMemberIdsDraft.contains(
                  member.userId,
                );
                return ListTile(
                  key: ValueKey('server_relay_group_member_${member.userId}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(member.username),
                  subtitle: Text(member.userId),
                  trailing: IconButton(
                    tooltip: selected
                        ? context.l10n.removeUsernameFromGroupDraft(member.username)
                        : context.l10n.restoreUsernameInGroupDraft(member.username),
                    onPressed: isBusy
                        ? null
                        : () {
                            final next = [...app.adminRelayGroupMemberIdsDraft];
                            if (selected) {
                              next.remove(member.userId);
                            } else {
                              next.add(member.userId);
                            }
                            app.editAdminRelayGroupMemberIdsDraft(next);
                          },
                    icon: Icon(
                      selected
                          ? Icons.person_remove_outlined
                          : Icons.undo_rounded,
                    ),
                  ),
                );
              }),
              if (accountsPage == null || accountsPage.accounts.isEmpty) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: app.adminAccountsLoading || isBusy
                      ? null
                      : () => unawaited(app.loadAdminAccounts(offset: 0)),
                  icon: app.adminAccountsLoading
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_search_outlined),
                  label: Text(context.l10n.loadAccountsToAddMembers),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'admin_relay_group_member_picker_${accountsPage.offset}',
                        ),
                        initialValue: canAddMember ? _selectedMemberId : null,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.l10n.activeAccountOnCurrentPage,
                          border: const OutlineInputBorder(),
                        ),
                        items: availableMembers
                            .map(
                              (account) => DropdownMenuItem(
                                value: account.userId,
                                child: Text(
                                  account.username,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: isBusy
                            ? null
                            : (value) =>
                                  setState(() => _selectedMemberId = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: isBusy || !canAddMember
                          ? null
                          : () {
                              app.editAdminRelayGroupMemberIdsDraft([
                                ...app.adminRelayGroupMemberIdsDraft,
                                _selectedMemberId!,
                              ]);
                              setState(() => _selectedMemberId = null);
                            },
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: Text(context.l10n.add),
                    ),
                  ],
                ),
                if (accountsPage.hasPrevious || accountsPage.hasNext)
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed:
                            !accountsPage.hasPrevious ||
                                app.adminAccountsLoading ||
                                isBusy
                            ? null
                            : () => unawaited(app.previousAdminAccountsPage()),
                        child: Text(context.l10n.previousAccounts),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed:
                            !accountsPage.hasNext ||
                                app.adminAccountsLoading ||
                                isBusy
                            ? null
                            : () => unawaited(app.nextAdminAccountsPage()),
                        child: Text(context.l10n.nextAccounts),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed:
                    isBusy ||
                        app.adminRelayGroupConflict ||
                        app.adminRelayGroupMemberIdsDraft.toSet().length ==
                                detail.members.length &&
                            app.adminRelayGroupMemberIdsDraft
                                .toSet()
                                .containsAll(
                                  detail.members.map((member) => member.userId),
                                )
                    ? null
                    : () => unawaited(app.saveAdminRelayGroupMembers()),
                icon: const Icon(Icons.save_outlined),
                label: Text(context.l10n.saveMembership),
              ),
              if (detail.members.isNotEmpty) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'admin_relay_group_effective_preview_${detail.groupId}',
                  ),
                  initialValue:
                      detail.members.any(
                        (member) =>
                            member.userId == app.adminRelayGroupPreviewUserId,
                      )
                      ? app.adminRelayGroupPreviewUserId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.previewMemberEffectiveRelayAccess,
                    helperText: context.l10n.includesTheInstanceAccountAndEvery,
                    border: const OutlineInputBorder(),
                  ),
                  items: detail.members
                      .map(
                        (member) => DropdownMenuItem(
                          value: member.userId,
                          child: Text(
                            member.username,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: isBusy
                      ? null
                      : (userId) => unawaited(
                          app.loadAdminRelayGroupMemberEffectivePolicy(
                            userId: userId,
                          ),
                        ),
                ),
                if (app.adminRelayGroupMemberEffectivePolicyLoading) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
                if (app.adminRelayGroupMemberEffectivePolicyError
                    case final previewError?) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    label: context.l10n.unableToLoadMemberEffectiveRelay,
                    child: Text(
                      previewError,
                      style: TextStyle(color: context.palette.red),
                    ),
                  ),
                ],
                if (app.adminRelayGroupMemberEffectivePolicy
                    case final memberPolicy?) ...[
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.memberEffectiveRelayAccessValuevalueCidrs(memberPolicy.effectivePolicy.enabled ? 'enabled' : 'disabled', _summarize(memberPolicy.effectivePolicy.allowCidrs), _summarize(memberPolicy.effectivePolicy.allowPorts)),
                    key: const ValueKey(
                      'admin_relay_group_member_effective_policy',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
              const Divider(height: 26),
              Text(
                context.l10n.groupRelayPolicy,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                detail.policy.inherited
                    ? 'Selection: inherited from the instance Relay policy'
                    : 'Selection: group override',
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              Text(
                context.l10n.policyRevisionRevisionInstanceRevisionInstancepolicyrevision(detail.policy.revision, detail.policy.instancePolicyRevision, _formatTime(detail.policy.updatedAt)),
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
              if (selectedPolicy != null)
                Text(
                  context.l10n.selectedStateValuevalueCidrsSummarizePorts(selectedPolicy.enabled ? 'enabled' : 'disabled', _summarize(selectedPolicy.allowCidrs), _summarize(selectedPolicy.allowPorts)),
                  style: const TextStyle(fontSize: 12),
                ),
              if (effectivePolicy != null)
                Text(
                  context.l10n.effectiveGroupStateValuevalueCidrsSummarize(effectivePolicy.enabled ? 'enabled' : 'disabled', _summarize(effectivePolicy.allowCidrs), _summarize(effectivePolicy.allowPorts)),
                  style: const TextStyle(fontSize: 12),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  context.l10n.aUsersEffectiveRelayAccessAlso,
                  style: TextStyle(color: context.palette.muted, fontSize: 11),
                ),
              ),
              if (limits != null)
                Text(
                  context.l10n.editableCeilingValuevalueCidrsSummarizePorts(limits.relayAvailable ? context.l10n.relayAvailable : context.l10n.relayUnavailable, _summarize(limits.allowCidrs), _summarize(limits.allowPorts)),
                  style: TextStyle(color: context.palette.muted, fontSize: 11),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.enableRelayForThisGroup),
                value: app.adminRelayGroupPolicyEnabledDraft,
                onChanged: isBusy
                    ? null
                    : (value) => app.editAdminRelayGroupPolicyDraft(
                        enabled: value ?? false,
                      ),
              ),
              TextField(
                key: const ValueKey('admin_relay_group_policy_cidrs'),
                controller: _cidrsController,
                enabled: !isBusy,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: context.l10n.allowedCidrNetworks,
                  helperText: context.l10n.oneCanonicalNetworkCidrPerLine,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    app.editAdminRelayGroupPolicyDraft(allowCidrsText: value),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('admin_relay_group_policy_ports'),
                controller: _portsController,
                enabled: !isBusy,
                decoration: InputDecoration(
                  labelText: context.l10n.allowedPorts,
                  helperText: context.l10n.commaOrLineSeparatedPortNumbers,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    app.editAdminRelayGroupPolicyDraft(allowPortsText: value),
              ),
              if (app.adminRelayGroupDetailSaveError case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  label: context.l10n.serverManagedGroupSaveFailed,
                  child: Text(
                    error,
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (app.adminRelayGroupDetailNotice case final notice?) ...[
                const SizedBox(height: 8),
                Text(notice, style: TextStyle(color: context.palette.lime)),
              ],
              if (app.adminRelayGroupConflict) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.aConcurrentChangeWasDetectedYour,
                  style: TextStyle(color: context.palette.red),
                ),
                OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => unawaited(
                          app.loadAdminRelayGroupDetail(
                            groupId: detail.groupId,
                            preserveDraft: true,
                          ),
                        ),
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(context.l10n.reloadLatestGroupKeepDrafts),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    onPressed: isBusy || app.adminRelayGroupConflict
                        ? null
                        : () => unawaited(app.saveAdminRelayGroupPolicy()),
                    icon: app.adminRelayGroupDetailSaving
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(context.l10n.saveGroupOverride),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        isBusy ||
                            app.adminRelayGroupConflict ||
                            detail.policy.inherited
                        ? null
                        : () => unawaited(
                            app.resetAdminRelayGroupPolicyToInherit(),
                          ),
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: Text(context.l10n.resetToInherit),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminAccountInvitationIssueDialog extends StatefulWidget {
  const _AdminAccountInvitationIssueDialog({required this.app});

  final AppController app;

  @override
  State<_AdminAccountInvitationIssueDialog> createState() =>
      _AdminAccountInvitationIssueDialogState();
}

class _AdminAccountInvitationIssueDialogState
    extends State<_AdminAccountInvitationIssueDialog> {
  late final TextEditingController _usernameController;
  var _expiresInDays = 7;
  var _submitting = false;
  String? _error;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final success = await app.issueAdminAccountInvitation(
      username: _usernameController.text,
      expiresInDays: _expiresInDays,
    );
    if (!mounted) return;
    if (success) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = app.adminAccountInvitationActionError;
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.issueAccountInvitation),
    content: SizedBox(
      width: appDialogWidth(context, 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('admin_account_invitation_username'),
              controller: _usernameController,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: context.l10n.invitationUsername,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('admin_account_invitation_expiry'),
              initialValue: _expiresInDays,
              decoration: InputDecoration(
                labelText: context.l10n.invitationExpiresInDays,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (var day = 1; day <= 30; day++)
                  DropdownMenuItem(
                    value: day,
                    child: Text('$day ${day == 1 ? 'day' : 'days'}'),
                  ),
              ],
              onChanged: _submitting
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _expiresInDays = value);
                      }
                    },
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _submitting ? null : () => Navigator.pop(context, false),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        onPressed: _submitting ? null : _submit,
        child: _submitting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(context.l10n.createInvitation),
      ),
    ],
  );
}

class _AdminAccountInvitationTokenDialog extends StatefulWidget {
  const _AdminAccountInvitationTokenDialog({
    required this.app,
    required this.tokenBuffer,
    required this.username,
    required this.expiresAt,
  });

  final AppController app;
  final _TransientInvitationToken tokenBuffer;
  final String username;
  final DateTime? expiresAt;

  @override
  State<_AdminAccountInvitationTokenDialog> createState() =>
      _AdminAccountInvitationTokenDialogState();
}

class _AdminAccountInvitationTokenDialogState
    extends State<_AdminAccountInvitationTokenDialog> {
  var _copied = false;
  String? _copyError;

  Future<void> _copyToken() async {
    if (_copied) return;
    final token = widget.tokenBuffer.value;
    if (token == null || token.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: token));
      if (!mounted) return;
      widget.tokenBuffer.clear();
      widget.app.clearAdminAccountInvitationToken();
      setState(() {
        _copied = true;
        _copyError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _copyError = widget.app.friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.accountInvitationCreated),
    content: SizedBox(
      width: appDialogWidth(context, 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.copyThisOneTimeInvitationToken,
            ),
            const SizedBox(height: 12),
            _DetailLine(label: context.l10n.invitationUsername, value: widget.username),
            _DetailLine(
              label: context.l10n.expires,
              value: widget.expiresAt == null
                  ? '—'
                  : DateFormat.yMMMd().add_jm().format(
                      widget.expiresAt!.toLocal(),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.oneTimeInvitationToken,
              key: const ValueKey('admin_account_invitation_token'),
              style: TextStyle(
                color: context.palette.text,
                fontSize: 12,
                fontFamily: 'monospace',
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.palette.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.palette.line),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: widget.tokenBuffer.value == null
                    ? const SizedBox.shrink()
                    : SelectionContainer.disabled(
                        child: Text(
                          widget.tokenBuffer.value!,
                          key: const ValueKey(
                            'admin_account_invitation_token_value',
                          ),
                          style: TextStyle(
                            color: context.palette.text,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
              ),
            ),
            if (_copied)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(context.l10n.invitationTokenCopied),
              ),
            if (_copyError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.done2),
      ),
      FilledButton.icon(
        onPressed: _copied ? null : _copyToken,
        icon: const Icon(Icons.copy_outlined),
        label: Text(context.l10n.copyInvitationToken),
      ),
    ],
  );
}

class _TransientInvitationToken {
  _TransientInvitationToken(String value) : value = value;

  String? value;

  void clear() => value = null;
}

class _AdminAccountInvitationsCard extends StatefulWidget {
  const _AdminAccountInvitationsCard({required this.app});

  final AppController app;

  @override
  State<_AdminAccountInvitationsCard> createState() =>
      _AdminAccountInvitationsCardState();
}

class _AdminAccountInvitationsCardState
    extends State<_AdminAccountInvitationsCard> {
  AppController get app => widget.app;

  Future<void> _loadInvitations() async {
    await Future.wait([
      app.loadAdminAccountInvitations(offset: 0),
      app.loadAdminAccounts(offset: app.adminAccountsPage?.offset ?? 0),
    ]);
  }

  Future<void> _issueInvitation() async {
    final created = await showAppDialog<bool>(
      context: context,
      builder: (_) => _AdminAccountInvitationIssueDialog(app: app),
    );
    if (created != true || !mounted) return;
    var token = app.adminAccountInvitationToken;
    if (token == null || token.isEmpty) return;
    final tokenBuffer = _TransientInvitationToken(token);
    token = null;
    final issuedUsername = app.adminAccountInvitationTokenUsername ?? '';
    final expiresAt = app.adminAccountInvitationTokenExpiresAt;
    try {
      await showAppDialog<void>(
        context: context,
        builder: (_) => _AdminAccountInvitationTokenDialog(
          app: app,
          tokenBuffer: tokenBuffer,
          username: issuedUsername,
          expiresAt: expiresAt,
        ),
      );
    } finally {
      tokenBuffer.clear();
      app.clearAdminAccountInvitationToken();
    }
  }

  Future<void> _confirmRevoke(AdminAccountInvitationMetadata invitation) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.revokeAccountInvitation),
        content: Text(
          context.l10n.thePendingInvitationForUsernameWill(invitation.username),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.confirmRevokeInvitation),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await app.revokeAdminAccountInvitation(
      invitationId: invitation.invitationId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = app.adminAccountInvitationsPage;
    final first = page == null || page.invitations.isEmpty
        ? 0
        : page.offset + 1;
    final last = page == null ? 0 : page.offset + page.invitations.length;
    return Card(
      key: const ValueKey('admin_account_invitations_card'),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.accountInvitations,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.createUsernameBoundInvitationsAndReview,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('admin_account_invitation_issue'),
                  onPressed:
                      app.adminAccountInvitationSubmitting ||
                          app.adminAccountInvitationBusyId != null
                      ? null
                      : () => unawaited(_issueInvitation()),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(context.l10n.issueAccountInvitation),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('admin_account_invitations_load'),
                  onPressed: app.adminAccountInvitationsLoading
                      ? null
                      : () => unawaited(_loadInvitations()),
                  icon: app.adminAccountInvitationsLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(
                    page == null
                        ? context.l10n.loadAccountInvitations
                        : context.l10n.refreshAccountInvitations,
                  ),
                ),
              ],
            ),
            if (app.adminAccountInvitationsError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.couldntLoadTheAccountInvitationList,
                child: Text(
                  context.l10n.couldntLoadTheInvitationListError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: app.adminAccountInvitationsLoading
                    ? null
                    : () => unawaited(_loadInvitations()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(context.l10n.retryAccountInvitations),
              ),
            ],
            if (app.adminAccountInvitationActionError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                label: context.l10n.adminAccountInvitationActionFailed,
                child: Text(
                  context.l10n.invitationActionFailedError(error),
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminAccountInvitationNotice case final notice?) ...[
              const SizedBox(height: 12),
              Text(notice, style: TextStyle(color: context.palette.lime)),
            ],
            if (app.adminAccountInvitationsLoading && page == null) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(context.l10n.loadingAccountInvitations),
            ] else if (page case final value?) ...[
              const SizedBox(height: 12),
              Text(
                value.total == 0
                    ? context.l10n.noAccountInvitationsFound
                    : context.l10n.showingFirstLastOfAdmincountInvitations(first, last, _adminCount(value.total)),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              if (value.invitations.isEmpty && value.total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(context.l10n.noInvitationsOnThisPage),
                ),
              ...value.invitations.map(
                (invitation) => _AdminAccountInvitationTile(
                  invitation: invitation,
                  busy:
                      app.adminAccountInvitationBusyId ==
                      invitation.invitationId,
                  onRevoke: invitation.status == 'pending'
                      ? () => unawaited(_confirmRevoke(invitation))
                      : null,
                ),
              ),
              if (value.hasPrevious || value.hasNext) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasPrevious ||
                              app.adminAccountInvitationsLoading
                          ? null
                          : () => unawaited(
                              app.previousAdminAccountInvitationsPage(),
                            ),
                      icon: const Icon(Icons.chevron_left_rounded),
                      label: Text(context.l10n.previousInvitations),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          !value.hasNext || app.adminAccountInvitationsLoading
                          ? null
                          : () => unawaited(
                              app.nextAdminAccountInvitationsPage(),
                            ),
                      icon: const Icon(Icons.chevron_right_rounded),
                      label: Text(context.l10n.nextInvitations),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminAccountInvitationTile extends StatelessWidget {
  const _AdminAccountInvitationTile({
    required this.invitation,
    required this.busy,
    required this.onRevoke,
  });

  final AdminAccountInvitationMetadata invitation;
  final bool busy;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (invitation.status) {
      'pending' => context.l10n.pending,
      'expired' => context.l10n.expired,
      'consumed' => context.l10n.consumed,
      'revoked' => context.l10n.revoked3,
      _ => invitation.status,
    };
    final statusColor = switch (invitation.status) {
      'pending' => context.palette.teal,
      'expired' || 'revoked' => context.palette.orange,
      _ => context.palette.muted,
    };
    return Card(
      key: ValueKey('admin_account_invitation_${invitation.invitationId}'),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    invitation.username,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(statusLabel),
                  labelStyle: TextStyle(color: statusColor),
                ),
              ],
            ),
            _DetailLine(
              label: context.l10n.created,
              value: DateFormat.yMMMd().add_jm().format(
                invitation.createdAt.toLocal(),
              ),
            ),
            _DetailLine(
              label: context.l10n.expires,
              value: DateFormat.yMMMd().add_jm().format(
                invitation.expiresAt.toLocal(),
              ),
            ),
            if (onRevoke != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy ? null : onRevoke,
                  icon: busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_off_rounded),
                  label: Text(context.l10n.revokeInvitation),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdminAccountTile extends StatelessWidget {
  const _AdminAccountTile({required this.app, required this.account});

  final AppController app;
  final AdminAccountMetadata account;

  @override
  Widget build(BuildContext context) {
    final isCurrentAccount = app.isCurrentAdminAccount(account.userId);
    final isDeleting = account.status == 'deleting';
    final isBusy = app.adminAccountActionBusyId == account.userId;
    final expanded = app.adminAccountSessionsUserId == account.userId;
    final relayPolicyExpanded =
        app.adminAccountRelayPolicyUserId == account.userId;
    final actionsEnabled =
        !isCurrentAccount &&
        !isDeleting &&
        app.adminAccountActionBusyId == null &&
        app.adminAccountSessionActionBusyId == null &&
        !app.adminAccountsLoading;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    account.username,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(label: Text(account.status)),
              ],
            ),
            _DetailLine(label: context.l10n.userId, value: account.userId),
            _DetailLine(
              label: context.l10n.activeDevices,
              value: _adminCount(account.activeDeviceCount),
            ),
            _DetailLine(
              label: context.l10n.activeSessions,
              value: _adminCount(account.activeSessionCount),
            ),
            _DetailLine(
              label: context.l10n.createdAt,
              value: DateFormat.yMMMd().add_jm().format(
                account.createdAt.toLocal(),
              ),
            ),
            if (isCurrentAccount)
              Text(
                context.l10n.currentSignedInAccountAdministrativeActions,
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              )
            else if (isDeleting)
              Text(
                context.l10n.deletingAccountAdministrativeActionsUnavailable,
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              )
            else ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: !actionsEnabled
                        ? null
                        : () => unawaited(
                            _confirmAdminAccountStatus(
                              context,
                              app,
                              account,
                              account.status == 'active'
                                  ? 'disabled'
                                  : 'active',
                            ),
                          ),
                    icon: isBusy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            account.status == 'active'
                                ? Icons.block_outlined
                                : Icons.check_circle_outline,
                          ),
                    label: Text(
                      account.status == 'active'
                          ? context.l10n.disableAccount
                          : 'Re-enable account',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: !actionsEnabled
                        ? null
                        : () => unawaited(
                            _confirmAdminAccountSessionRevocation(
                              context,
                              app,
                              account,
                            ),
                          ),
                    icon: const Icon(Icons.logout_rounded),
                    label: Text(context.l10n.revokeAllSessions),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        app.adminAccountActionBusyId != null ||
                            app.adminAccountsLoading
                        ? null
                        : () => unawaited(
                            app.toggleAdminAccountSessions(
                              userId: account.userId,
                            ),
                          ),
                    icon: Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.devices_other_rounded,
                    ),
                    label: Text(expanded ? context.l10n.hideSessions : context.l10n.viewSessions),
                  ),
                  OutlinedButton.icon(
                    key: ValueKey(
                      'admin_account_relay_policy_${account.userId}',
                    ),
                    onPressed:
                        !relayPolicyExpanded &&
                            (app.adminAccountActionBusyId != null ||
                                app.adminAccountsLoading)
                        ? null
                        : () => unawaited(
                            app.toggleAdminAccountRelayPolicy(
                              userId: account.userId,
                            ),
                          ),
                    icon: Icon(
                      relayPolicyExpanded
                          ? Icons.expand_less_rounded
                          : Icons.policy_outlined,
                    ),
                    label: Text(
                      relayPolicyExpanded
                          ? context.l10n.hideRelayPolicy
                          : context.l10n.relayPolicy,
                    ),
                  ),
                ],
              ),
            ],
            if (expanded && !isCurrentAccount && !isDeleting)
              _AdminAccountSessionsPanel(app: app, account: account),
            if (relayPolicyExpanded && !isCurrentAccount && !isDeleting)
              _AdminAccountRelayPolicyPanel(
                key: ValueKey('account_relay_policy_${account.userId}'),
                app: app,
                account: account,
              ),
          ],
        ),
      ),
    );
  }
}

class _AdminAccountRelayPolicyPanel extends StatefulWidget {
  const _AdminAccountRelayPolicyPanel({
    required this.app,
    required this.account,
    super.key,
  });

  final AppController app;
  final AdminAccountMetadata account;

  @override
  State<_AdminAccountRelayPolicyPanel> createState() =>
      _AdminAccountRelayPolicyPanelState();
}

class _AdminAccountRelayPolicyPanelState
    extends State<_AdminAccountRelayPolicyPanel> {
  late final TextEditingController _cidrsController;
  late final TextEditingController _portsController;

  AppController get app => widget.app;
  AdminAccountMetadata get account => widget.account;

  @override
  void initState() {
    super.initState();
    _cidrsController = TextEditingController(
      text: app.adminAccountRelayPolicyCidrsDraft,
    );
    _portsController = TextEditingController(
      text: app.adminAccountRelayPolicyPortsDraft,
    );
  }

  @override
  void didUpdateWidget(covariant _AdminAccountRelayPolicyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTextController(
      _cidrsController,
      app.adminAccountRelayPolicyCidrsDraft,
    );
    _syncTextController(
      _portsController,
      app.adminAccountRelayPolicyPortsDraft,
    );
  }

  void _syncTextController(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _cidrsController.dispose();
    _portsController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime? value) =>
      value == null ? '—' : DateFormat.yMMMd().add_jm().format(value.toLocal());

  String _summarize<T>(List<T> values) {
    if (values.isEmpty) return 'none';
    final visible = values.take(8).join(', ');
    final remaining = values.length - 8;
    return remaining > 0 ? '$visible, and $remaining more' : visible;
  }

  @override
  Widget build(BuildContext context) {
    final userPolicy = app.adminAccountRelayUserPolicy;
    final instancePolicy = app.adminAccountRelayInstancePolicy;
    final isBusy =
        app.adminAccountRelayPolicyLoading ||
        app.adminAccountRelayPolicySaving ||
        app.adminAccountRelayPolicyResetting;
    final limits = instancePolicy?.effectiveUserRelayPolicyLimits;
    final selectedPolicy = userPolicy?.policy;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.accountRelayPolicy,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: context.l10n.reloadAccountAndInstanceRelayPolicies,
                onPressed: isBusy
                    ? null
                    : () => unawaited(
                        app.loadAdminAccountRelayPolicy(
                          userId: account.userId,
                          preserveDraft: true,
                        ),
                      ),
                icon: app.adminAccountRelayPolicyLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          if (app.adminAccountRelayPolicyLoading && userPolicy == null) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(context.l10n.loadingAccountAndInstancePolicyRevisions),
          ],
          if (app.adminAccountRelayPolicyError case final error?) ...[
            const SizedBox(height: 6),
            Semantics(
              label: context.l10n.unableToLoadAccountRelayPolicy,
              child: Text(error, style: TextStyle(color: context.palette.red)),
            ),
          ],
          if (userPolicy != null && instancePolicy != null) ...[
            const SizedBox(height: 4),
            Text(
              userPolicy.inherited
                  ? 'Selection: inherited from the instance policy'
                  : 'Selection: account override',
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            Text(
              context.l10n.accountRevisionRevisionUpdatedFormattime(userPolicy.revision, _formatTime(userPolicy.updatedAt)),
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
            Text(
              context.l10n.instanceRevisionRevisionUpdatedFormattime(instancePolicy.revision, _formatTime(instancePolicy.updatedAt)),
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (selectedPolicy != null)
              Text(
                context.l10n.selectedStateValuevalueCidrsSummarizePorts(selectedPolicy.enabled ? 'enabled' : 'disabled', _summarize(selectedPolicy.allowCidrs), _summarize(selectedPolicy.allowPorts)),
                style: const TextStyle(fontSize: 12),
              ),
            const SizedBox(height: 4),
            Text(
              context.l10n.effectiveStateValuevalueCidrsSummarizePorts(userPolicy.effectivePolicy.enabled ? 'enabled' : 'disabled', _summarize(userPolicy.effectivePolicy.allowCidrs), _summarize(userPolicy.effectivePolicy.allowPorts)),
              style: const TextStyle(fontSize: 12),
            ),
            if (limits != null) ...[
              const SizedBox(height: 4),
              Text(
                context.l10n.editableCeilingValuevalueCidrsSummarizePorts(limits.relayAvailable ? context.l10n.relayAvailable : context.l10n.relayUnavailable, _summarize(limits.allowCidrs), _summarize(limits.allowPorts)),
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.enableRelayForThisAccount),
              value: app.adminAccountRelayPolicyEnabledDraft,
              onChanged: isBusy
                  ? null
                  : (value) => app.editAdminAccountRelayPolicyDraft(
                      userId: account.userId,
                      enabled: value ?? false,
                    ),
            ),
            TextField(
              key: ValueKey('relay_policy_cidrs_${account.userId}'),
              enabled: !isBusy,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: context.l10n.allowedCidrNetworks,
                helperText: context.l10n.oneCanonicalNetworkCidrPerLine,
                border: const OutlineInputBorder(),
              ),
              controller: _cidrsController,
              onChanged: (value) => app.editAdminAccountRelayPolicyDraft(
                userId: account.userId,
                allowCidrsText: value,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('relay_policy_ports_${account.userId}'),
              enabled: !isBusy,
              decoration: InputDecoration(
                labelText: context.l10n.allowedPorts,
                helperText: context.l10n.commaOrLineSeparatedPortNumbers,
                border: const OutlineInputBorder(),
              ),
              controller: _portsController,
              onChanged: (value) => app.editAdminAccountRelayPolicyDraft(
                userId: account.userId,
                allowPortsText: value,
              ),
            ),
            if (app.adminAccountRelayPolicySaveError case final error?) ...[
              const SizedBox(height: 8),
              Semantics(
                label: context.l10n.accountRelayPolicySaveFailed,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (app.adminAccountRelayPolicyNotice case final notice?) ...[
              const SizedBox(height: 8),
              Text(notice, style: TextStyle(color: context.palette.lime)),
            ],
            if (app.adminAccountRelayPolicyConflict) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: isBusy
                    ? null
                    : () => unawaited(
                        app.loadAdminAccountRelayPolicy(
                          userId: account.userId,
                          preserveDraft: true,
                        ),
                      ),
                icon: const Icon(Icons.sync_rounded),
                label: Text(context.l10n.reloadLatestPolicyKeepDraft),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.icon(
                  onPressed: isBusy || app.adminAccountRelayPolicyConflict
                      ? null
                      : () => unawaited(
                          app.saveAdminAccountRelayPolicyDraft(
                            userId: account.userId,
                          ),
                        ),
                  icon: app.adminAccountRelayPolicySaving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(context.l10n.saveOverride),
                ),
                OutlinedButton.icon(
                  onPressed:
                      isBusy ||
                          app.adminAccountRelayPolicyConflict ||
                          userPolicy.inherited
                      ? null
                      : () => unawaited(
                          app.resetAdminAccountRelayPolicyToInherit(
                            userId: account.userId,
                          ),
                        ),
                  icon: app.adminAccountRelayPolicyResetting
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt_rounded),
                  label: Text(context.l10n.resetToInherit),
                ),
              ],
            ),
          ] else if (!app.adminAccountRelayPolicyLoading) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: isBusy
                  ? null
                  : () => unawaited(
                      app.loadAdminAccountRelayPolicy(
                        userId: account.userId,
                        preserveDraft: true,
                      ),
                    ),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                app.adminAccountRelayPolicyConflict
                    ? context.l10n.reloadLatestPolicyKeepDraft
                    : context.l10n.loadRelayPolicies,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AdminAccountSessionsPanel extends StatelessWidget {
  const _AdminAccountSessionsPanel({required this.app, required this.account});

  final AppController app;
  final AdminAccountMetadata account;

  @override
  Widget build(BuildContext context) {
    final page = app.adminAccountSessionsPage;
    final first = page == null || page.sessions.isEmpty ? 0 : page.offset + 1;
    final last = page == null ? 0 : page.offset + page.sessions.length;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.accountSessions,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: context.l10n.refreshAccountSessions,
                onPressed:
                    app.adminAccountSessionsLoading ||
                        app.adminAccountActionBusyId != null ||
                        app.adminAccountSessionActionBusyId != null
                    ? null
                    : () => unawaited(
                        app.loadAdminAccountSessions(
                          userId: account.userId,
                          offset: page?.offset ?? 0,
                        ),
                      ),
                icon: app.adminAccountSessionsLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          if (app.adminAccountSessionsError case final error?) ...[
            Semantics(
              label: context.l10n.couldntLoadTheAccountSessionList,
              child: Text(
                context.l10n.couldntLoadTheSessionListError(error),
                style: TextStyle(color: context.palette.red),
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: app.adminAccountSessionsLoading
                  ? null
                  : () => unawaited(
                      app.loadAdminAccountSessions(
                        userId: account.userId,
                        offset: page?.offset ?? 0,
                      ),
                    ),
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(context.l10n.retrySessionList),
            ),
          ],
          if (app.adminAccountSessionsLoading && page == null) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(context.l10n.loadingAccountSessions),
          ] else if (page case final value?) ...[
            Text(
              value.total == 0
                  ? context.l10n.noSessionsFound
                  : context.l10n.showingFirstLastOfAdmincountSessions(first, last, _adminCount(value.total)),
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (value.sessions.isEmpty && value.total > 0)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(context.l10n.noSessionsOnThisPage),
              ),
            ...value.sessions.map(
              (session) => _AdminAccountSessionTile(
                app: app,
                account: account,
                session: session,
              ),
            ),
            if (value.hasPrevious || value.hasNext) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        !value.hasPrevious ||
                            app.adminAccountSessionsLoading ||
                            app.adminAccountSessionActionBusyId != null
                        ? null
                        : () => unawaited(
                            app.previousAdminAccountSessionsPage(
                              userId: account.userId,
                            ),
                          ),
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: Text(context.l10n.previousSessions),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed:
                        !value.hasNext ||
                            app.adminAccountSessionsLoading ||
                            app.adminAccountSessionActionBusyId != null
                        ? null
                        : () => unawaited(
                            app.nextAdminAccountSessionsPage(
                              userId: account.userId,
                            ),
                          ),
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: Text(context.l10n.nextSessions),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _AdminAccountSessionTile extends StatelessWidget {
  const _AdminAccountSessionTile({
    required this.app,
    required this.account,
    required this.session,
  });

  final AppController app;
  final AdminAccountMetadata account;
  final AdminAccountSessionMetadata session;

  @override
  Widget build(BuildContext context) {
    final isBusy = app.adminAccountSessionActionBusyId == session.sessionId;
    final canRevoke =
        session.active &&
        app.adminAccountSessionActionBusyId == null &&
        app.adminAccountActionBusyId == null;
    String format(DateTime value) =>
        DateFormat.yMMMd().add_jm().format(value.toLocal());
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.deviceName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(
                    session.active
                        ? 'active'
                        : session.revokedAt == null
                        ? 'inactive'
                        : 'revoked',
                  ),
                ),
              ],
            ),
            _DetailLine(label: context.l10n.sessionId, value: session.sessionId),
            _DetailLine(label: context.l10n.deviceId, value: session.deviceId),
            _DetailLine(label: context.l10n.createdAt, value: format(session.createdAt)),
            _DetailLine(
              label: context.l10n.accessExpires,
              value: format(session.accessExpiresAt),
            ),
            _DetailLine(
              label: context.l10n.refreshExpires,
              value: format(session.refreshExpiresAt),
            ),
            _DetailLine(
              label: context.l10n.revokedAt,
              value: session.revokedAt == null
                  ? '—'
                  : format(session.revokedAt!),
            ),
            if (session.active)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: !canRevoke
                      ? null
                      : () => unawaited(
                          _confirmAdminAccountSessionRevocationOne(
                            context,
                            app,
                            account,
                            session,
                          ),
                        ),
                  icon: isBusy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout_rounded),
                  label: Text(context.l10n.revokeSession),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmAdminAccountStatus(
  BuildContext context,
  AppController app,
  AdminAccountMetadata account,
  String status,
) async {
  final isDisabling = status == 'disabled';
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isDisabling ? context.l10n.disableAccount2 : 'Re-enable account?'),
      content: Text(
        isDisabling
            ? context.l10n.disableUsernameServerSessionsWillBe(account.username)
            : 'Re-enable ${account.username} so they can sign in again?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(isDisabling ? context.l10n.disableAccount : 'Re-enable account'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await app.setAdminAccountStatus(userId: account.userId, status: status);
  }
}

Future<void> _confirmAdminAccountSessionRevocation(
  BuildContext context,
  AppController app,
  AdminAccountMetadata account,
) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.revokeAllSessions2),
      content: Text(
        context.l10n.revokeEveryActiveSessionForUsername(account.username),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(context.l10n.revokeSessions),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await app.revokeAdminAccountSessions(userId: account.userId);
  }
}

Future<void> _confirmAdminAccountSessionRevocationOne(
  BuildContext context,
  AppController app,
  AdminAccountMetadata account,
  AdminAccountSessionMetadata session,
) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.revokeThisSession),
      content: Text(
        context.l10n.revokeTheSessionOnDevicenameFor(session.deviceName, account.username),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(context.l10n.revokeSession),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await app.revokeAdminAccountSession(
      userId: account.userId,
      sessionId: session.sessionId,
    );
  }
}

String _adminCount(int value) => NumberFormat.decimalPattern().format(value);

String _formatAdminBytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var amount = value.toDouble();
  var unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  final formatted = unit == 0 ? '$value' : amount.toStringAsFixed(1);
  return '$formatted ${units[unit]} (${_adminCount(value)} bytes)';
}

const _vaultWorkspaceSections = <String, String>{
  'hosts': 'Hosts',
  'credentials': 'Credentials',
  'groups': 'Groups',
  'snippets': 'Snippets',
};

class _VaultSyncedPreferencesPanel extends StatefulWidget {
  const _VaultSyncedPreferencesPanel({required this.app});

  final AppController app;

  @override
  State<_VaultSyncedPreferencesPanel> createState() =>
      _VaultSyncedPreferencesPanelState();
}

class _VaultSyncedPreferencesPanelState
    extends State<_VaultSyncedPreferencesPanel> {
  static String get _repairRetryMessage =>
    currentL10n.repairIsNotConfirmedYetSync;
  static String get _repairRecoveredMessage =>
    currentL10n.theDefaultPreferenceWasConfirmedAfter;

  late String _selectedSection;
  late String _lastPersistedSection;
  late String _lastVaultId;
  late int _lastVaultSelectionGeneration;
  String? _selectedRepairRecordId;
  late String _lastRepairCandidateFingerprint;
  bool _saving = false;
  bool _repairing = false;
  bool _repairOutcomeMessage = false;
  String? _message;
  bool _saveSucceeded = false;

  AppController get app => widget.app;

  String _validSection(String section) =>
      _vaultWorkspaceSections.containsKey(section) ? section : 'hosts';

  String _repairCandidateFingerprint() => app.defaultSectionConflictCandidates
      .map(
        (candidate) =>
            '${candidate.id}:${candidate.value}:${candidate.revisionId ?? ''}',
      )
      .toList(growable: false)
      .join('|');

  bool get _isDirty =>
      _selectedSection != _validSection(app.defaultWorkspaceSection);

  bool get _hasVerifiedSingletonRecovery =>
      !app.hasDefaultSectionPreferenceConflict &&
      app.preferenceError == null &&
      app.preferences
              .where((candidate) => candidate.isDefaultWorkspaceSection)
              .length ==
          1;

  @override
  void initState() {
    super.initState();
    _selectedSection = _validSection(app.defaultWorkspaceSection);
    _lastPersistedSection = _selectedSection;
    _lastVaultId = app.currentVaultId;
    _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
    _lastRepairCandidateFingerprint = _repairCandidateFingerprint();
    _selectedRepairRecordId = app.defaultSectionConflictRetainedRecordId;
  }

  @override
  void didUpdateWidget(covariant _VaultSyncedPreferencesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final persistedSection = _validSection(app.defaultWorkspaceSection);
    if (app.currentVaultId != _lastVaultId ||
        app.vaultSelectionGeneration != _lastVaultSelectionGeneration) {
      _selectedSection = persistedSection;
      _lastPersistedSection = persistedSection;
      _lastVaultId = app.currentVaultId;
      _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
      _lastRepairCandidateFingerprint = _repairCandidateFingerprint();
      _selectedRepairRecordId = app.defaultSectionConflictRetainedRecordId;
      return;
    }
    final candidateFingerprint = _repairCandidateFingerprint();
    if (candidateFingerprint != _lastRepairCandidateFingerprint) {
      _lastRepairCandidateFingerprint = candidateFingerprint;
      _selectedRepairRecordId = app.defaultSectionConflictRetainedRecordId;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
    if (_repairOutcomeMessage &&
        !_saveSucceeded &&
        _message == _repairRetryMessage &&
        _hasVerifiedSingletonRecovery) {
      // A later full sync can safely clear the conflict latch after an
      // earlier repair call reported a transient failure. Reflect that
      // verified singleton recovery in the UI, without claiming which record
      // won unless the repair call itself confirmed the selected record.
      _message = _repairRecoveredMessage;
      _saveSucceeded = true;
    }
    if (_saving) return;
    if (persistedSection != _lastPersistedSection &&
        (_selectedSection == _lastPersistedSection ||
            _selectedSection == persistedSection)) {
      _selectedSection = persistedSection;
      _lastPersistedSection = persistedSection;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
  }

  Future<void> _save() async {
    if (_saving ||
        !_isDirty ||
        app.activeVault?.canWrite != true ||
        app.preferenceError != null) {
      return;
    }
    final section = _selectedSection;
    final startingVaultId = app.currentVaultId;
    final startingVaultName = app.currentVaultName;
    final startingVaultGeneration = app.vaultSelectionGeneration;
    setState(() {
      _saving = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });

    try {
      final outcome = await app.saveWorkspaceDefaultSection(section);
      if (!mounted) return;
      final sameVaultContext =
          app.currentVaultId == startingVaultId &&
          app.vaultSelectionGeneration == startingVaultGeneration;
      if (!sameVaultContext ||
          outcome != WorkspacePreferenceSaveOutcome.savedToActiveVault) {
        setState(() {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            final currentSection = _validSection(app.defaultWorkspaceSection);
            _selectedSection = currentSection;
            _lastPersistedSection = currentSection;
          }
          _message =
              context.l10n.vaultChangedWhileSavingTheEncrypted(startingVaultName);
          _saveSucceeded = false;
        });
        return;
      }
      setState(() {
        _lastPersistedSection = section;
        _message =
            context.l10n.savedAsItemThisPreferenceIs('${_vaultWorkspaceSections[section]}');
        _saveSucceeded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final sameVaultContext =
            app.currentVaultId == startingVaultId &&
            app.vaultSelectionGeneration == startingVaultGeneration;
        if (!sameVaultContext) {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            final currentSection = _validSection(app.defaultWorkspaceSection);
            _selectedSection = currentSection;
            _lastPersistedSection = currentSection;
          }
          _message =
              context.l10n.vaultChangedWhileSavingCheckThe(startingVaultName);
          _saveSucceeded = false;
          return;
        }
        final committed = _validSection(app.defaultWorkspaceSection) == section;
        if (committed) _lastPersistedSection = section;
        _message = committed
            ? context.l10n.savedAsItemThisPreferenceIs('${_vaultWorkspaceSections[section]}')
            : context.l10n.couldNotSaveThisPreferenceCheck;
        _saveSucceeded = committed;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _repairConflict(String recordId) async {
    if (_repairing ||
        app.activeVault?.canWrite != true ||
        !app.defaultSectionConflictCandidates.any(
          (candidate) => candidate.id == recordId,
        )) {
      return;
    }
    final startingVaultId = app.currentVaultId;
    final startingVaultGeneration = app.vaultSelectionGeneration;
    setState(() {
      _repairing = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      await app.repairDefaultWorkspaceSectionConflict(
        retainedRecordId: recordId,
      );
      if (!mounted) return;
      if (app.currentVaultId != startingVaultId ||
          app.vaultSelectionGeneration != startingVaultGeneration) {
        return;
      }
      setState(() {
        _message =
            context.l10n.theSelectedDefaultPreferenceWasConfirmed;
        _saveSucceeded = true;
        _repairOutcomeMessage = true;
      });
    } catch (_) {
      if (!mounted) return;
      if (app.currentVaultId != startingVaultId ||
          app.vaultSelectionGeneration != startingVaultGeneration) {
        return;
      }
      final verifiedSingletonRecovery = _hasVerifiedSingletonRecovery;
      setState(() {
        _message = verifiedSingletonRecovery
            ? _repairRecoveredMessage
            : _repairRetryMessage;
        _saveSucceeded = verifiedSingletonRecovery;
        _repairOutcomeMessage = true;
      });
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = app.activeVault;
    final canWrite = vault?.canWrite == true && vault?.status == 'active';
    final preferenceError = app.preferenceError;
    final canEdit = canWrite && preferenceError == null;
    final value = _validSection(app.defaultWorkspaceSection);
    final repairCandidates = app.defaultSectionConflictCandidates;
    final selectedRepairCandidate = repairCandidates
        .where((candidate) => candidate.id == _selectedRepairRecordId)
        .firstOrNull;
    final retainedRepairId = app.defaultSectionConflictRetainedRecordId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.vaultSyncedPreferences,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 7),
            Text(
              context.l10n.chooseTheDefaultWorkspaceSectionFor,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _DetailLine(label: context.l10n.currentVault2, value: app.currentVaultName),
            const SizedBox(height: 8),
            if (app.hasDefaultSectionPreferenceConflict) ...[
              Container(
                key: const ValueKey('vault_preference_conflict_repair'),
                decoration: BoxDecoration(
                  color: context.palette.surfaceRaised,
                  border: Border.all(
                    color: context.palette.orange.withValues(alpha: 0.55),
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(12),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.chooseTheDefaultPreferenceRecordTo,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        context.l10n.compareEachValueAndRecordId,
                        style: TextStyle(color: context.palette.muted, fontSize: 12),
                      ),
                      if (retainedRepairId != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          context.l10n.aPreviousRepairAlreadySelectedRetainedrepairid(retainedRepairId),
                          style: TextStyle(
                            color: context.palette.orange,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      RadioGroup<String>(
                        groupValue: _selectedRepairRecordId,
                        onChanged: (recordId) {
                          if (recordId == null) return;
                          setState(() {
                            _selectedRepairRecordId = recordId;
                            _message = null;
                            _saveSucceeded = false;
                            _repairOutcomeMessage = false;
                          });
                        },
                        child: Column(
                          children: [
                            for (final candidate in repairCandidates)
                              Builder(
                                builder: (context) {
                                  final sectionLabel =
                                      _vaultWorkspaceSections[candidate
                                          .value] ??
                                      candidate.value;
                                  final revisionLabel =
                                      candidate.revisionId ?? 'unverified';
                                  return RadioListTile<String>(
                                    key: ValueKey(
                                      'preference-repair-${candidate.id}',
                                    ),
                                    contentPadding: EdgeInsets.zero,
                                    value: candidate.id,
                                    enabled:
                                        canWrite &&
                                        !_repairing &&
                                        (retainedRepairId == null ||
                                            retainedRepairId == candidate.id),
                                    title: Semantics(
                                      label:
                                          context.l10n.defaultSectionSectionlabelRecordIdId(sectionLabel, candidate.id, revisionLabel),
                                      excludeSemantics: true,
                                      child: Text(sectionLabel),
                                    ),
                                    subtitle: ExcludeSemantics(
                                      child: Text(
                                        context.l10n.recordIdIdRevisionRevisionlabel(candidate.id, revisionLabel),
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      if (repairCandidates.isEmpty)
                        Text(
                          context.l10n.noVerifiedCandidateIsAvailableRetry3,
                          style: TextStyle(
                            color: context.palette.orange,
                            fontSize: 12,
                          ),
                        ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        key: const ValueKey('repair_vault_preference_conflict'),
                        onPressed:
                            canWrite &&
                                !_repairing &&
                                selectedRepairCandidate != null
                            ? () => _repairConflict(selectedRepairCandidate.id)
                            : null,
                        icon: _repairing || app.defaultSectionConflictRepairBusy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: Text(
                          retainedRepairId == null
                              ? context.l10n.keepSelectedRecordAndRemoveDuplicates
                              : context.l10n.retryAndVerifyRepair,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            KeyedSubtree(
              key: const ValueKey('vault_default_workspace_section'),
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                label: context.l10n.defaultWorkspaceSection,
                value: _vaultWorkspaceSections[_selectedSection],
                child: DropdownButtonFormField<String>(
                  key: ValueKey('vault-section-$_selectedSection'),
                  isExpanded: true,
                  initialValue: _selectedSection,
                  decoration: InputDecoration(
                    labelText: context.l10n.defaultWorkspaceSection,
                  ),
                  items: _vaultWorkspaceSections.entries
                      .map(
                        (entry) => DropdownMenuItem<String>(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: canEdit && !_saving
                      ? (section) {
                          if (section == null) return;
                          setState(() {
                            _selectedSection = section;
                            _message = null;
                            _saveSucceeded = false;
                            _repairOutcomeMessage = false;
                          });
                        }
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: canEdit && !_saving && _selectedSection != value
                  ? _save
                  : null,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync_outlined),
              label: Text(context.l10n.saveSyncedPreference),
            ),
            const SizedBox(height: 8),
            if (preferenceError case final error?)
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  key: const ValueKey('vault_preference_error'),
                  style: TextStyle(color: context.palette.orange, fontSize: 12),
                ),
              )
            else
              Text(
                vault == null
                    ? context.l10n.openAVaultToReadOr
                    : canWrite
                    ? context.l10n.thisSettingIsStoredAsAn(app.currentVaultName)
                    : context.l10n.thisVaultIsReadOnlyYou,
                style: TextStyle(
                  color: canWrite ? context.palette.muted : context.palette.orange,
                  fontSize: 12,
                ),
              ),
            if (_message case final message?) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  key: const ValueKey('vault_synced_preference_status'),
                  style: TextStyle(
                    color: _saveSucceeded ? context.palette.teal : context.palette.orange,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TerminalFontSizePreferenceSection extends StatefulWidget {
  const _TerminalFontSizePreferenceSection({required this.app});

  final AppController app;

  @override
  State<_TerminalFontSizePreferenceSection> createState() =>
      _TerminalFontSizePreferenceSectionState();
}

class _TerminalFontSizePreferenceSectionState
    extends State<_TerminalFontSizePreferenceSection> {
  late int _selectedFontSize;
  late int _lastPersistedFontSize;
  late String _lastVaultId;
  late int _lastVaultSelectionGeneration;
  late String _lastConflictCandidateFingerprint;
  String? _selectedConflictRecordId;
  bool _saving = false;
  bool _repairing = false;
  bool _repairOutcomeMessage = false;
  bool _saveSucceeded = false;
  String? _message;

  AppController get app => widget.app;

  List<int> get _supportedSizes =>
      VaultPreferenceRecord.supportedTerminalFontSizes.toList()..sort();

  int _validFontSize(int fontSize) =>
      VaultPreferenceRecord.supportedTerminalFontSizes.contains(fontSize)
      ? fontSize
      : VaultPreferenceRecord.defaultTerminalFontSize;

  String _candidateFingerprint() => app.terminalFontSizeConflictCandidates
      .map(
        (candidate) =>
            '${candidate.id}:${candidate.value}:${candidate.revisionId ?? ''}',
      )
      .toList(growable: false)
      .join('|');

  bool get _isDirty =>
      _selectedFontSize != _validFontSize(app.terminalFontSize);

  @override
  void initState() {
    super.initState();
    _selectedFontSize = _validFontSize(app.terminalFontSize);
    _lastPersistedFontSize = _selectedFontSize;
    _lastVaultId = app.currentVaultId;
    _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
    _lastConflictCandidateFingerprint = _candidateFingerprint();
    _selectedConflictRecordId = app.terminalFontSizeConflictRetainedRecordId;
  }

  @override
  void didUpdateWidget(covariant _TerminalFontSizePreferenceSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final persistedFontSize = _validFontSize(app.terminalFontSize);
    if (app.currentVaultId != _lastVaultId ||
        app.vaultSelectionGeneration != _lastVaultSelectionGeneration) {
      _selectedFontSize = persistedFontSize;
      _lastPersistedFontSize = persistedFontSize;
      _lastVaultId = app.currentVaultId;
      _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
      _lastConflictCandidateFingerprint = _candidateFingerprint();
      _selectedConflictRecordId = app.terminalFontSizeConflictRetainedRecordId;
      return;
    }

    final candidateFingerprint = _candidateFingerprint();
    if (candidateFingerprint != _lastConflictCandidateFingerprint) {
      _lastConflictCandidateFingerprint = candidateFingerprint;
      _selectedConflictRecordId = app.terminalFontSizeConflictRetainedRecordId;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }

    if (_saving) return;
    if (persistedFontSize != _lastPersistedFontSize &&
        (_selectedFontSize == _lastPersistedFontSize ||
            _selectedFontSize == persistedFontSize)) {
      _selectedFontSize = persistedFontSize;
      _lastPersistedFontSize = persistedFontSize;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
  }

  Future<void> _save() async {
    if (_saving ||
        !_isDirty ||
        app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active' ||
        app.preferenceError != null ||
        app.hasTerminalFontSizePreferenceConflict ||
        app.terminalFontSizeConflictRepairBusy) {
      return;
    }
    final fontSize = _selectedFontSize;
    final startingVaultId = app.currentVaultId;
    final startingVaultName = app.currentVaultName;
    final startingVaultGeneration = app.vaultSelectionGeneration;
    setState(() {
      _saving = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });

    try {
      final outcome = await app.saveTerminalFontSizePreference(fontSize);
      if (!mounted) return;
      final sameVaultContext =
          app.currentVaultId == startingVaultId &&
          app.vaultSelectionGeneration == startingVaultGeneration;
      if (!sameVaultContext ||
          outcome != WorkspacePreferenceSaveOutcome.savedToActiveVault) {
        setState(() {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            final currentFontSize = _validFontSize(app.terminalFontSize);
            _selectedFontSize = currentFontSize;
            _lastPersistedFontSize = currentFontSize;
          }
          _message =
              context.l10n.vaultChangedWhileSavingTheFont(startingVaultName);
          _saveSucceeded = false;
        });
        return;
      }
      setState(() {
        _lastPersistedFontSize = fontSize;
        _message =
            context.l10n.savedFontsizePxThisEncryptedPreference(fontSize);
        _saveSucceeded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final sameVaultContext =
            app.currentVaultId == startingVaultId &&
            app.vaultSelectionGeneration == startingVaultGeneration;
        if (!sameVaultContext) {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            final currentFontSize = _validFontSize(app.terminalFontSize);
            _selectedFontSize = currentFontSize;
            _lastPersistedFontSize = currentFontSize;
          }
          _message =
              context.l10n.vaultChangedWhileSavingCheckThe(startingVaultName);
          _saveSucceeded = false;
          return;
        }
        final committed = _validFontSize(app.terminalFontSize) == fontSize;
        if (committed) _lastPersistedFontSize = fontSize;
        _message = committed
            ? context.l10n.savedFontsizePxThisEncryptedPreference(fontSize)
            : context.l10n.couldNotSaveTerminalFontSize;
        _saveSucceeded = committed;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _repairConflict(String recordId) async {
    final retainedRecordId = app.terminalFontSizeConflictRetainedRecordId;
    if (_repairing ||
        app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active' ||
        !app.terminalFontSizeConflictCandidates.any(
          (candidate) => candidate.id == recordId,
        ) ||
        (retainedRecordId != null && retainedRecordId != recordId)) {
      return;
    }
    setState(() {
      _repairing = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      await app.repairTerminalFontSizePreferenceConflict(
        retainedRecordId: recordId,
      );
      if (!mounted) return;
      setState(() {
        _message =
            context.l10n.theSelectedTerminalFontSizeWas;
        _saveSucceeded = true;
        _repairOutcomeMessage = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = context.l10n.repairIsNotConfirmedYetSync;
        _saveSucceeded = false;
        _repairOutcomeMessage = true;
      });
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    final retainedRecordId = app.terminalFontSizeConflictRetainedRecordId;
    final conflictCandidates = app.terminalFontSizeConflictCandidates;
    final selectedCandidate = conflictCandidates
        .where((candidate) => candidate.id == _selectedConflictRecordId)
        .firstOrNull;
    final editingBlocked =
        !canWrite ||
        app.preferenceError != null ||
        app.hasTerminalFontSizePreferenceConflict ||
        app.terminalFontSizeConflictRepairBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.terminalFontSize3,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.setTheSharedTerminalTextSize(_supportedSizes.join(', '), VaultPreferenceRecord.defaultTerminalFontSize),
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        if (app.hasTerminalFontSizePreferenceConflict) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('terminal_font_size_conflict'),
            decoration: BoxDecoration(
              color: context.palette.surfaceRaised,
              border: Border.all(
                color: context.palette.orange.withValues(alpha: .55),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.chooseTheTerminalFontSizeRecord,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.reviewTheSizeAndRecordId,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
                if (retainedRecordId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    context.l10n.aPreviousRepairSelectedRetainedrecordidRetry2(retainedRecordId),
                    style: TextStyle(
                      color: context.palette.orange,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Material(
                  type: MaterialType.transparency,
                  child: RadioGroup<String>(
                    groupValue: _selectedConflictRecordId,
                    onChanged: (recordId) {
                      if (recordId == null) return;
                      setState(() {
                        _selectedConflictRecordId = recordId;
                        _message = null;
                        _saveSucceeded = false;
                        _repairOutcomeMessage = false;
                      });
                    },
                    child: Column(
                      children: [
                        for (final candidate in conflictCandidates)
                          Builder(
                            builder: (context) {
                              final fontSize = int.tryParse(candidate.value);
                              final revisionLabel =
                                  candidate.revisionId ?? 'unverified';
                              return RadioListTile<String>(
                                key: ValueKey(
                                  'terminal-font-size-conflict-${candidate.id}',
                                ),
                                contentPadding: EdgeInsets.zero,
                                value: candidate.id,
                                enabled:
                                    canWrite &&
                                    !_repairing &&
                                    !app.terminalFontSizeConflictRepairBusy &&
                                    (retainedRecordId == null ||
                                        retainedRecordId == candidate.id),
                                title: Semantics(
                                  label:
                                      context.l10n.terminalFontSizeValuevaluePxRecord(fontSize ?? candidate.value, candidate.id, revisionLabel),
                                  excludeSemantics: true,
                                  child: Text(
                                    fontSize == null
                                        ? context.l10n.invalidFontSizeValue
                                        : '$fontSize px',
                                  ),
                                ),
                                subtitle: ExcludeSemantics(
                                  child: Text(
                                    context.l10n.recordIdIdRevisionRevisionlabel(candidate.id, revisionLabel),
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                if (conflictCandidates.isEmpty)
                  Text(
                    context.l10n.noVerifiedCandidateIsAvailableRetry2,
                    style: TextStyle(color: context.palette.orange, fontSize: 12),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('repair_terminal_font_size_conflict'),
                  onPressed:
                      canWrite &&
                          !_repairing &&
                          !app.terminalFontSizeConflictRepairBusy &&
                          selectedCandidate != null
                      ? () => _repairConflict(selectedCandidate.id)
                      : null,
                  icon: _repairing || app.terminalFontSizeConflictRepairBusy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    retainedRecordId == null
                        ? context.l10n.keepSelectedFontSizeAndRemove
                        : context.l10n.retryAndVerifyRepair,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          key: const ValueKey('vault_terminal_font_size'),
          isExpanded: true,
          initialValue: _validFontSize(_selectedFontSize),
          decoration: InputDecoration(labelText: context.l10n.terminalFontSize3),
          items: _supportedSizes
              .map(
                (size) => DropdownMenuItem<int>(
                  key: ValueKey('terminal-font-size-option-$size'),
                  value: size,
                  child: Text('$size px'),
                ),
              )
              .toList(growable: false),
          onChanged:
              !editingBlocked &&
                  !_saving &&
                  !_repairing &&
                  !app.terminalFontSizeConflictRepairBusy
              ? (fontSize) {
                  if (fontSize == null ||
                      !VaultPreferenceRecord.supportedTerminalFontSizes
                          .contains(fontSize)) {
                    return;
                  }
                  setState(() {
                    _selectedFontSize = fontSize;
                    _message = null;
                    _saveSucceeded = false;
                    _repairOutcomeMessage = false;
                  });
                }
              : null,
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const ValueKey('save_vault_terminal_font_size'),
          onPressed:
              !editingBlocked &&
                  !_saving &&
                  !_repairing &&
                  !app.terminalFontSizeConflictRepairBusy &&
                  _isDirty
              ? _save
              : null,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined),
          label: Text(context.l10n.saveTerminalFontSize2),
        ),
        if (app.preferenceError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              context.l10n.vaultPreferenceDataNeedsAttentionBefore2,
              key: const ValueKey('terminal_font_size_error'),
              style: TextStyle(color: context.palette.orange, fontSize: 12),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            app.activeVault == null
                ? context.l10n.openAVaultToReadOr3
                : canWrite
                ? context.l10n.thisSettingIsEncryptedInCurrentvaultname(app.currentVaultName)
                : context.l10n.thisVaultIsReadOnlyYou4,
            style: TextStyle(
              color: canWrite ? context.palette.muted : context.palette.orange,
              fontSize: 12,
            ),
          ),
        ],
        if (_message case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey('vault_terminal_font_size_status'),
              style: TextStyle(
                color: _saveSucceeded ? context.palette.teal : context.palette.orange,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TerminalThemePreferenceSection extends StatefulWidget {
  const _TerminalThemePreferenceSection({required this.app});

  final AppController app;

  @override
  State<_TerminalThemePreferenceSection> createState() =>
      _TerminalThemePreferenceSectionState();
}

class _TerminalThemePreferenceSectionState
    extends State<_TerminalThemePreferenceSection> {
  late VaultTerminalThemeChoice _selectedTheme;
  late VaultTerminalThemeChoice _lastPersistedTheme;
  late String _lastVaultId;
  late int _lastVaultSelectionGeneration;
  late String _lastConflictCandidateFingerprint;
  String? _selectedConflictRecordId;
  bool _saving = false;
  bool _repairing = false;
  String? _message;
  bool _saveSucceeded = false;
  bool _repairOutcomeMessage = false;

  AppController get app => widget.app;

  String _candidateFingerprint() => app.terminalThemeConflictCandidates
      .map(
        (candidate) =>
            '${candidate.id}:${candidate.value}:${candidate.revisionId ?? ''}',
      )
      .toList(growable: false)
      .join('|');

  bool get _isDirty => _selectedTheme != app.terminalTheme;

  @override
  void initState() {
    super.initState();
    _selectedTheme = app.terminalTheme;
    _lastPersistedTheme = _selectedTheme;
    _lastVaultId = app.currentVaultId;
    _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
    _lastConflictCandidateFingerprint = _candidateFingerprint();
    _selectedConflictRecordId = app.terminalThemeConflictRetainedRecordId;
  }

  @override
  void didUpdateWidget(covariant _TerminalThemePreferenceSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final persistedTheme = app.terminalTheme;
    if (app.currentVaultId != _lastVaultId ||
        app.vaultSelectionGeneration != _lastVaultSelectionGeneration) {
      _selectedTheme = persistedTheme;
      _lastPersistedTheme = persistedTheme;
      _lastVaultId = app.currentVaultId;
      _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
      _lastConflictCandidateFingerprint = _candidateFingerprint();
      _selectedConflictRecordId = app.terminalThemeConflictRetainedRecordId;
      return;
    }
    final candidateFingerprint = _candidateFingerprint();
    if (candidateFingerprint != _lastConflictCandidateFingerprint) {
      _lastConflictCandidateFingerprint = candidateFingerprint;
      _selectedConflictRecordId = app.terminalThemeConflictRetainedRecordId;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
    if (_saving) return;
    if (persistedTheme != _lastPersistedTheme &&
        (_selectedTheme == _lastPersistedTheme ||
            _selectedTheme == persistedTheme)) {
      _selectedTheme = persistedTheme;
      _lastPersistedTheme = persistedTheme;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
  }

  Future<void> _save() async {
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    if (_saving ||
        !_isDirty ||
        !canWrite ||
        app.preferenceError != null ||
        app.hasTerminalThemePreferenceConflict ||
        app.terminalThemeConflictRepairBusy) {
      return;
    }
    final theme = _selectedTheme;
    final startingVaultId = app.currentVaultId;
    final startingVaultName = app.currentVaultName;
    final startingVaultGeneration = app.vaultSelectionGeneration;
    // A saved synced theme must become visible on this device, so a device
    // palette overlay is cleared afterwards, unless the user picked a device
    // palette while the save was running.
    final palettes = TerminalPaletteController.of(context);
    final paletteGeneration = palettes.selectionGeneration;
    setState(() {
      _saving = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      final outcome = await app.saveTerminalThemePreference(theme);
      if (!mounted) return;
      final sameVault =
          app.currentVaultId == startingVaultId &&
          app.vaultSelectionGeneration == startingVaultGeneration;
      if (!sameVault ||
          outcome != WorkspacePreferenceSaveOutcome.savedToActiveVault) {
        setState(() {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            _selectedTheme = app.terminalTheme;
            _lastPersistedTheme = _selectedTheme;
          }
          _message =
              context.l10n.vaultChangedWhileSavingTheTheme(startingVaultName);
        });
        return;
      }
      palettes.followSyncedIf(paletteGeneration);
      setState(() {
        _lastPersistedTheme = theme;
        _message =
            context.l10n.savedLabelThisEncryptedPreferenceWill(theme.label);
        _saveSucceeded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final sameVault =
            app.currentVaultId == startingVaultId &&
            app.vaultSelectionGeneration == startingVaultGeneration;
        if (!sameVault) {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            _selectedTheme = app.terminalTheme;
            _lastPersistedTheme = _selectedTheme;
          }
          _message =
              context.l10n.vaultChangedWhileSavingCheckThe(startingVaultName);
          return;
        }
        final committed = app.terminalTheme == theme;
        if (committed) {
          _lastPersistedTheme = theme;
          palettes.followSyncedIf(paletteGeneration);
        }
        _message = committed
            ? context.l10n.savedLabelThisEncryptedPreferenceWill(theme.label)
            : context.l10n.couldNotSaveTerminalThemeCheck;
        _saveSucceeded = committed;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _repairConflict(String recordId) async {
    final retainedRecordId = app.terminalThemeConflictRetainedRecordId;
    if (_repairing ||
        app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active' ||
        !app.terminalThemeConflictCandidates.any(
          (candidate) => candidate.id == recordId,
        ) ||
        (retainedRecordId != null && retainedRecordId != recordId)) {
      return;
    }
    setState(() {
      _repairing = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      await app.repairTerminalThemePreferenceConflict(
        retainedRecordId: recordId,
      );
      if (!mounted) return;
      setState(() {
        _message =
            context.l10n.theSelectedTerminalThemeWasConfirmed;
        _saveSucceeded = true;
        _repairOutcomeMessage = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = context.l10n.repairIsNotConfirmedYetSync;
        _saveSucceeded = false;
        _repairOutcomeMessage = true;
      });
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    final retainedRecordId = app.terminalThemeConflictRetainedRecordId;
    final conflictCandidates = app.terminalThemeConflictCandidates;
    final selectedCandidate = conflictCandidates
        .where((candidate) => candidate.id == _selectedConflictRecordId)
        .firstOrNull;
    final editingBlocked =
        !canWrite ||
        app.preferenceError != null ||
        app.hasTerminalThemePreferenceConflict ||
        app.terminalThemeConflictRepairBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.terminalColorTheme,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.chooseTheTerminalPaletteSharedBy,
          style: TextStyle(color: context.palette.muted, fontSize: 12, height: 1.4),
        ),
        if (app.hasTerminalThemePreferenceConflict) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('terminal_theme_conflict'),
            decoration: BoxDecoration(
              color: context.palette.surfaceRaised,
              border: Border.all(
                color: context.palette.orange.withValues(alpha: .55),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.chooseTheTerminalThemeRecordTo,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.reviewThePaletteAndRecordId,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
                if (retainedRecordId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    context.l10n.aPreviousRepairSelectedRetainedrecordidRetry2(retainedRecordId),
                    style: TextStyle(
                      color: context.palette.orange,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Material(
                  type: MaterialType.transparency,
                  child: RadioGroup<String>(
                    groupValue: _selectedConflictRecordId,
                    onChanged: (recordId) {
                      if (recordId == null) return;
                      setState(() {
                        _selectedConflictRecordId = recordId;
                        _message = null;
                        _saveSucceeded = false;
                        _repairOutcomeMessage = false;
                      });
                    },
                    child: Column(
                      children: [
                        for (final candidate in conflictCandidates)
                          RadioListTile<String>(
                            key: ValueKey(
                              'terminal-theme-conflict-${candidate.id}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            value: candidate.id,
                            enabled:
                                canWrite &&
                                !_repairing &&
                                !app.terminalThemeConflictRepairBusy &&
                                (retainedRecordId == null ||
                                    retainedRecordId == candidate.id),
                            title: Semantics(
                              label:
                                  context.l10n.terminalThemeThemelabelRecordIdId(_themeLabel(candidate.value), candidate.id, candidate.revisionId ?? 'unverified'),
                              excludeSemantics: true,
                              child: Text(_themeLabel(candidate.value)),
                            ),
                            subtitle: ExcludeSemantics(
                              child: Text(
                                context.l10n.recordIdIdRevisionValuevalue(candidate.id, candidate.revisionId ?? 'unverified'),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (conflictCandidates.isEmpty)
                  Text(
                    context.l10n.noVerifiedCandidateIsAvailableRetry2,
                    style: TextStyle(color: context.palette.orange, fontSize: 12),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('repair_terminal_theme_conflict'),
                  onPressed:
                      canWrite &&
                          !_repairing &&
                          !app.terminalThemeConflictRepairBusy &&
                          selectedCandidate != null
                      ? () => _repairConflict(selectedCandidate.id)
                      : null,
                  icon: _repairing || app.terminalThemeConflictRepairBusy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    retainedRecordId == null
                        ? context.l10n.keepSelectedThemeAndRemoveDuplicates
                        : context.l10n.retryAndVerifyRepair,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          context.l10n.terminalColorTheme,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        const SizedBox(height: 6),
        TerminalSyncedThemeSelector(
          key: const ValueKey('vault_terminal_theme'),
          selected: _selectedTheme,
          persisted: app.terminalTheme,
          onSelected: editingBlocked || _saving || _repairing
              ? null
              : (theme) => setState(() {
                  _selectedTheme = theme;
                  _message = null;
                  _saveSucceeded = false;
                  _repairOutcomeMessage = false;
                }),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const ValueKey('save_vault_terminal_theme'),
          onPressed: !editingBlocked && !_saving && !_repairing && _isDirty
              ? _save
              : null,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined),
          label: Text(context.l10n.saveTerminalColorTheme),
        ),
        if (app.preferenceError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              context.l10n.vaultPreferenceDataNeedsAttentionBefore2,
              key: const ValueKey('terminal_theme_error'),
              style: TextStyle(color: context.palette.orange, fontSize: 12),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            app.activeVault == null
                ? context.l10n.openAVaultToReadOr3
                : canWrite
                ? context.l10n.thisSettingIsEncryptedInCurrentvaultname(app.currentVaultName)
                : context.l10n.thisVaultIsReadOnlyYou3,
            style: TextStyle(
              color: canWrite ? context.palette.muted : context.palette.orange,
              fontSize: 12,
            ),
          ),
        ],
        if (_message case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey('vault_terminal_theme_status'),
              style: TextStyle(
                color: _saveSucceeded ? context.palette.teal : context.palette.orange,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _themeLabel(String value) {
    try {
      return VaultTerminalThemeChoice.fromValue(value).label;
    } on FormatException {
      return context.l10n.unsupportedTheme;
    }
  }
}

class _TerminalShortcutsPreferenceSection extends StatefulWidget {
  const _TerminalShortcutsPreferenceSection({required this.app});

  final AppController app;

  @override
  State<_TerminalShortcutsPreferenceSection> createState() =>
      _TerminalShortcutsPreferenceSectionState();
}

class _TerminalShortcutsPreferenceSectionState
    extends State<_TerminalShortcutsPreferenceSection> {
  late final Map<TerminalShortcutAction, TextEditingController> _controllers;
  late String _lastVaultId;
  late int _lastVaultSelectionGeneration;
  late String _lastConflictCandidateFingerprint;
  late TerminalShortcutBindings _lastObservedBindings;
  int _draftEditGeneration = 0;
  int _observedDraftEditGeneration = 0;
  String? _selectedConflictRecordId;
  String? _message;
  bool _saving = false;
  bool _repairing = false;
  bool _saveSucceeded = false;
  bool _repairOutcomeMessage = false;

  AppController get app => widget.app;

  String _candidateFingerprint() => app.terminalShortcutsConflictCandidates
      .map(
        (candidate) =>
            '${candidate.id}:${candidate.value}:${candidate.revisionId ?? ''}',
      )
      .toList(growable: false)
      .join('|');

  TerminalShortcutBindings? get _draftBindings {
    try {
      return TerminalShortcutBindings.fromBindings({
        for (final action in TerminalShortcutAction.values)
          action: _controllers[action]!.text,
      });
    } on FormatException {
      return null;
    }
  }

  bool get _isDirty => _draftBindings != app.terminalShortcutBindings;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final action in TerminalShortcutAction.values)
        action: TextEditingController(
          text: app.terminalShortcutBindings.chordFor(action),
        ),
    };
    _lastVaultId = app.currentVaultId;
    _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
    _lastConflictCandidateFingerprint = _candidateFingerprint();
    _lastObservedBindings = app.terminalShortcutBindings;
    _observedDraftEditGeneration = _draftEditGeneration;
    _selectedConflictRecordId = app.terminalShortcutsConflictRetainedRecordId;
  }

  @override
  void didUpdateWidget(
    covariant _TerminalShortcutsPreferenceSection oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    final vaultChanged =
        app.currentVaultId != _lastVaultId ||
        app.vaultSelectionGeneration != _lastVaultSelectionGeneration;
    if (vaultChanged) {
      _replaceDraft(app.terminalShortcutBindings);
      _lastObservedBindings = app.terminalShortcutBindings;
      _observedDraftEditGeneration = _draftEditGeneration;
      _lastVaultId = app.currentVaultId;
      _lastVaultSelectionGeneration = app.vaultSelectionGeneration;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
      _lastConflictCandidateFingerprint = _candidateFingerprint();
      _selectedConflictRecordId = app.terminalShortcutsConflictRetainedRecordId;
      return;
    }

    final fingerprint = _candidateFingerprint();
    if (fingerprint != _lastConflictCandidateFingerprint) {
      _lastConflictCandidateFingerprint = fingerprint;
      _selectedConflictRecordId = app.terminalShortcutsConflictRetainedRecordId;
      if (!_repairing && !_repairOutcomeMessage) {
        _message = null;
        _saveSucceeded = false;
      }
    }
    if (_saving) return;
    final currentBindings = app.terminalShortcutBindings;
    final draftBindings = _draftBindings;
    // Compare against the last value this form actually observed. Comparing
    // against currentBindings here mistakes an asynchronously received Vault
    // update for a local edit: the app already exposes the new value while
    // these text controllers still contain the old one.
    if (_draftEditGeneration != _observedDraftEditGeneration) {
      if (draftBindings == currentBindings) {
        _lastObservedBindings = currentBindings;
        _observedDraftEditGeneration = _draftEditGeneration;
      }
      return;
    }
    if (currentBindings == _lastObservedBindings) return;
    _replaceDraft(currentBindings);
    _lastObservedBindings = currentBindings;
    _observedDraftEditGeneration = _draftEditGeneration;
    if (!_repairing && !_repairOutcomeMessage) {
      _message = null;
      _saveSucceeded = false;
    }
  }

  void _replaceDraft(TerminalShortcutBindings bindings) {
    for (final action in TerminalShortcutAction.values) {
      _controllers[action]!.text = bindings.chordFor(action);
    }
  }

  void _noteDraftEdit() {
    _draftEditGeneration++;
    final currentBindings = app.terminalShortcutBindings;
    if (_draftBindings == currentBindings) {
      _lastObservedBindings = currentBindings;
      _observedDraftEditGeneration = _draftEditGeneration;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final bindings = _draftBindings;
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    if (_saving ||
        bindings == null ||
        !_isDirty ||
        !canWrite ||
        app.preferenceError != null ||
        app.hasTerminalShortcutsPreferenceConflict ||
        app.terminalShortcutsConflictRepairBusy) {
      return;
    }
    final startingVaultId = app.currentVaultId;
    final startingVaultName = app.currentVaultName;
    final startingVaultGeneration = app.vaultSelectionGeneration;
    setState(() {
      _saving = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      final outcome = await app.saveTerminalShortcutsPreference(bindings);
      if (!mounted) return;
      final sameVault =
          app.currentVaultId == startingVaultId &&
          app.vaultSelectionGeneration == startingVaultGeneration;
      if (!sameVault ||
          outcome != WorkspacePreferenceSaveOutcome.savedToActiveVault) {
        setState(() {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            _replaceDraft(app.terminalShortcutBindings);
          }
          _message =
              context.l10n.vaultChangedWhileSavingTheShortcut(startingVaultName);
        });
        return;
      }
      setState(() {
        _lastObservedBindings = bindings;
        _observedDraftEditGeneration = _draftEditGeneration;
        _message = 'Saved. These encrypted semantic bindings will sync to devices with access to this Vault.';
        _saveSucceeded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final sameVault =
            app.currentVaultId == startingVaultId &&
            app.vaultSelectionGeneration == startingVaultGeneration;
        if (!sameVault) {
          if (_lastVaultId == app.currentVaultId &&
              _lastVaultSelectionGeneration == app.vaultSelectionGeneration) {
            _replaceDraft(app.terminalShortcutBindings);
          }
          _message =
              context.l10n.vaultChangedWhileSavingCheckThe2(startingVaultName);
          return;
        }
        final committed = _draftBindings == app.terminalShortcutBindings;
        if (committed) {
          _lastObservedBindings = app.terminalShortcutBindings;
          _observedDraftEditGeneration = _draftEditGeneration;
        }
        _message = committed
            ? 'Saved. These encrypted semantic bindings will sync to devices with access to this Vault.'
            : context.l10n.couldNotSaveTerminalShortcutsCheck;
        _saveSucceeded = committed;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _repairConflict(String recordId) async {
    final retainedRecordId = app.terminalShortcutsConflictRetainedRecordId;
    if (_repairing ||
        app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active' ||
        !app.terminalShortcutsConflictCandidates.any(
          (candidate) => candidate.id == recordId,
        ) ||
        (retainedRecordId != null && retainedRecordId != recordId)) {
      return;
    }
    setState(() {
      _repairing = true;
      _message = null;
      _saveSucceeded = false;
      _repairOutcomeMessage = false;
    });
    try {
      await app.repairTerminalShortcutsPreferenceConflict(
        retainedRecordId: recordId,
      );
      if (!mounted) return;
      setState(() {
        _lastObservedBindings = app.terminalShortcutBindings;
        _replaceDraft(app.terminalShortcutBindings);
        _observedDraftEditGeneration = _draftEditGeneration;
        _message =
            context.l10n.theSelectedShortcutBindingsWereConfirmed;
        _saveSucceeded = true;
        _repairOutcomeMessage = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = context.l10n.repairIsNotConfirmedYetSync;
        _saveSucceeded = false;
        _repairOutcomeMessage = true;
      });
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        app.activeVault?.canWrite == true &&
        app.activeVault?.status == 'active';
    final retainedRecordId = app.terminalShortcutsConflictRetainedRecordId;
    final conflictCandidates = app.terminalShortcutsConflictCandidates;
    final selectedCandidate = conflictCandidates
        .where((candidate) => candidate.id == _selectedConflictRecordId)
        .firstOrNull;
    final draftBindings = _draftBindings;
    final editingBlocked =
        !canWrite ||
        app.preferenceError != null ||
        app.hasTerminalShortcutsPreferenceConflict ||
        app.terminalShortcutsConflictRepairBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.terminalKeyboardShortcuts,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.bindingsSyncAsSemanticActionsMod,
          style: TextStyle(color: context.palette.muted, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
        TerminalShortcutEditor(
          controllers: _controllers,
          fieldKey: (action) => ValueKey('terminal-shortcut-${action.name}'),
          enabled: !editingBlocked && !_saving && !_repairing,
          onChanged: () => setState(() {
            _noteDraftEdit();
            _message = null;
            _saveSucceeded = false;
            _repairOutcomeMessage = false;
          }),
        ),
        if (draftBindings == null) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.enterASupportedNonReservedChord,
            key: const ValueKey('terminal_shortcuts_validation_error'),
            style: TextStyle(color: context.palette.orange, fontSize: 12),
          ),
        ],
        if (app.hasTerminalShortcutsPreferenceConflict) ...[
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('terminal_shortcuts_conflict'),
            decoration: BoxDecoration(
              color: context.palette.surfaceRaised,
              border: Border.all(
                color: context.palette.orange.withValues(alpha: .55),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.chooseTheShortcutPreferenceRecordTo,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.reviewEachSynchronizedBindingAndRecord,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
                if (retainedRecordId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    context.l10n.aPreviousRepairSelectedRetainedrecordidRetry(retainedRecordId),
                    style: TextStyle(
                      color: context.palette.orange,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Material(
                  type: MaterialType.transparency,
                  child: RadioGroup<String>(
                    groupValue: _selectedConflictRecordId,
                    onChanged: (recordId) {
                      if (recordId == null) return;
                      setState(() {
                        _selectedConflictRecordId = recordId;
                        _message = null;
                        _saveSucceeded = false;
                        _repairOutcomeMessage = false;
                      });
                    },
                    child: Column(
                      children: [
                        for (final candidate in conflictCandidates)
                          RadioListTile<String>(
                            key: ValueKey(
                              'terminal-shortcut-conflict-${candidate.id}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            value: candidate.id,
                            enabled:
                                canWrite &&
                                !_repairing &&
                                !app.terminalShortcutsConflictRepairBusy &&
                                (retainedRecordId == null ||
                                    retainedRecordId == candidate.id),
                            title: Text(_formatCandidate(candidate)),
                            subtitle: Text(
                              context.l10n.recordIdIdRevisionValuevalue(candidate.id, candidate.revisionId ?? 'unverified'),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (conflictCandidates.isEmpty)
                  Text(
                    context.l10n.noVerifiedCandidateIsAvailableRetry,
                    style: TextStyle(color: context.palette.orange, fontSize: 12),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('repair_terminal_shortcuts_conflict'),
                  onPressed:
                      canWrite &&
                          !_repairing &&
                          !app.terminalShortcutsConflictRepairBusy &&
                          selectedCandidate != null
                      ? () => _repairConflict(selectedCandidate.id)
                      : null,
                  icon: _repairing || app.terminalShortcutsConflictRepairBusy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    retainedRecordId == null
                        ? context.l10n.keepSelectedBindingsAndRemoveDuplicates
                        : context.l10n.retryAndVerifyRepair,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('restore_default_terminal_shortcuts'),
              onPressed: editingBlocked || _saving || _repairing
                  ? null
                  : () => setState(() {
                      _replaceDraft(TerminalShortcutBindings.defaults);
                      _noteDraftEdit();
                      _message = null;
                      _saveSucceeded = false;
                      _repairOutcomeMessage = false;
                    }),
              icon: const Icon(Icons.restart_alt),
              label: Text(context.l10n.restoreDefaults),
            ),
            FilledButton.icon(
              key: const ValueKey('save_terminal_shortcuts'),
              onPressed:
                  !editingBlocked &&
                      !_saving &&
                      !_repairing &&
                      draftBindings != null &&
                      _isDirty
                  ? _save
                  : null,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync_outlined),
              label: Text(context.l10n.saveShortcuts2),
            ),
          ],
        ),
        if (app.preferenceError != null) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.vaultPreferenceDataNeedsAttentionBefore,
            key: const ValueKey('terminal_shortcuts_error'),
            style: TextStyle(color: context.palette.orange, fontSize: 12),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            app.activeVault == null
                ? context.l10n.openAVaultToReadOr2
                : canWrite
                ? context.l10n.bindingsAreEncryptedInCurrentvaultnameAnd(app.currentVaultName)
                : context.l10n.thisVaultIsReadOnlyYou2,
            style: TextStyle(
              color: canWrite ? context.palette.muted : context.palette.orange,
              fontSize: 12,
            ),
          ),
        ],
        if (_message case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey('terminal_shortcuts_status'),
              style: TextStyle(
                color: _saveSucceeded ? context.palette.teal : context.palette.orange,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _formatCandidate(
    VaultPreferenceRecord candidate,
  ) => TerminalShortcutAction.values
      .map(
        (action) =>
            '${action.label}: ${candidate.terminalShortcutBindings.chordFor(action)}',
      )
      .join(' · ');
}

class _AccountRecoveryPanel extends StatefulWidget {
  const _AccountRecoveryPanel({required this.app});

  final AppController app;

  @override
  State<_AccountRecoveryPanel> createState() => _AccountRecoveryPanelState();
}

class _AccountRecoveryPanelState extends State<_AccountRecoveryPanel> {
  final _passwordController = TextEditingController();
  bool _busy = false;
  bool _unconfirmedCode = false;
  String? _error;
  String? _notice;

  AppController get app => widget.app;

  @override
  void dispose() {
    _passwordController.clear();
    _passwordController.dispose();
    super.dispose();
  }

  String get _statusLabel => switch (app.accountRecoveryStatus) {
    'current' => context.l10n.ready,
    'stale' || 'incomplete' => context.l10n.needsMoreVaultKeys,
    _ => context.l10n.notConfigured,
  };

  Future<String?> _askPassword({required bool disabling}) async {
    _passwordController.clear();
    try {
      return await showAppDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            disabling ? context.l10n.disableAccountRecovery2 : context.l10n.setUpAccountRecovery,
          ),
          content: TextField(
            controller: _passwordController,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.currentMasterPassword,
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _passwordController.text),
              child: Text(context.l10n.continueLabel),
            ),
          ],
        ),
      );
    } finally {
      _passwordController.clear();
    }
  }

  Future<bool> _showRecoveryCode(String code) async {
    var confirmed = false;
    // Stable outcome (null = none); the label is formatted at render time so
    // a runtime language switch never changes the success/failure meaning.
    bool? copyFeedback;
    final result = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.l10n.storeYourRecoveryCode),
          content: SizedBox(
            width: appDialogWidth(context, 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.thisCodeIsShownOnceAnyone,
                ),
                const SizedBox(height: 14),
                Semantics(
                  key: const ValueKey('account_recovery_code_semantics'),
                  label: context.l10n.accountRecoveryCodeCode(code),
                  excludeSemantics: true,
                  child: SelectableText(
                    code,
                    key: const ValueKey('account_recovery_code'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      setDialogState(() => copyFeedback = null);
                      try {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (dialogContext.mounted) {
                          setDialogState(
                            () => copyFeedback = true,
                          );
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(
                            () => copyFeedback = false,
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(context.l10n.copyCode),
                  ),
                ),
                if (copyFeedback != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        copyFeedback!
                            ? dialogContext.l10n.recoveryCodeCopiedFeedback
                            : dialogContext.l10n.recoveryCodeCopyFailedFeedback,
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: copyFeedback!
                                  ? context.palette.teal
                                  : Theme.of(dialogContext).colorScheme.error,
                            ),
                      ),
                    ),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmed,
                  onChanged: (value) =>
                      setDialogState(() => confirmed = value == true),
                  title: Text(context.l10n.iStoredThisCodeSecurely),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.close),
            ),
            FilledButton(
              onPressed: confirmed
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(context.l10n.finish),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _configure() async {
    if (_busy) return;
    final password = await _askPassword(disabling: false);
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await app.configureAccountRecovery(
        currentPassword: password,
      );
      final confirmed = await _showRecoveryCode(result.recoveryCode);
      if (mounted) {
        setState(() {
          _unconfirmedCode = !confirmed;
          _notice = confirmed
              ? context.l10n.recoveryIsStatusCoveredcontextsOfRequiredcontexts(result.status, result.coveredContexts, result.requiredContexts)
              : context.l10n.recoveryIsEnabledButThisCode;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = app.friendlyError(error);
          _notice = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    if (_busy) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.disableAccountRecovery),
        content: Text(
          context.l10n.theServerWillDeleteTheEncrypted,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.continueLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final password = await _askPassword(disabling: true);
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await app.disableAccountRecovery(currentPassword: password);
      if (mounted) {
        setState(() {
          _unconfirmedCode = false;
          _notice = context.l10n.accountRecoveryWasDisabled;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 9,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.key_rounded, color: context.palette.lime),
                Text(
                  context.l10n.accountRecovery,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Chip(
                  label: Text(
                    _statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              context.l10n.aRandomRecoveryCodeEncryptsA,
              style: TextStyle(
                color: context.palette.muted,
                height: 1.45,
                fontSize: 12,
              ),
            ),
            if (app.accountRecoveryStatus != 'disabled') ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.countOfCount2VaultKeyContexts(app.accountRecoveryPresentContexts.length, app.accountRecoveryRequiredContexts.length),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ],
            if (_unconfirmedCode) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.thePreviousCodeWasNotConfirmed,
                style: TextStyle(color: context.palette.orange, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: context.palette.red)),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Text(_notice!, style: TextStyle(color: context.palette.lime)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('account_recovery_configure'),
                  onPressed: _busy || app.accountRecoveryBusy
                      ? null
                      : _configure,
                  icon: const Icon(Icons.vpn_key_outlined),
                  label: Text(
                    app.accountRecoveryStatus == 'disabled'
                        ? context.l10n.setUpRecovery
                        : context.l10n.rotateRecoveryCode,
                  ),
                ),
                if (app.accountRecoveryStatus != 'disabled')
                  OutlinedButton.icon(
                    key: const ValueKey('account_recovery_disable'),
                    onPressed: _busy || app.accountRecoveryBusy
                        ? null
                        : _disable,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(context.l10n.disableRecovery),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('account_recovery_refresh'),
                  onPressed: _busy
                      ? null
                      : () => app.refreshAccountRecoveryState(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(context.l10n.refreshKeyCoverage),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _AccountPasswordPanel extends StatefulWidget {
  const _AccountPasswordPanel({required this.app});

  final AppController app;

  @override
  State<_AccountPasswordPanel> createState() => _AccountPasswordPanelState();
}

class _AccountPasswordPanelState extends State<_AccountPasswordPanel> {
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmationPassword = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _success;

  AppController get app => widget.app;

  @override
  void dispose() {
    _currentPassword.clear();
    _newPassword.clear();
    _confirmationPassword.clear();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmationPassword.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_currentPassword.text.length < 12) {
      return context.l10n.enterTheCurrentMasterPasswordAt;
    }
    if (_newPassword.text.length < 12) {
      return context.l10n.theNewMasterPasswordMustContain;
    }
    if (_newPassword.text != _confirmationPassword.text) {
      return context.l10n.theNewMasterPasswordsDoNot;
    }
    if (_newPassword.text == _currentPassword.text) {
      return context.l10n.chooseANewMasterPasswordDifferent;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final validationError = _validate();
    if (validationError != null) {
      setState(() {
        _error = validationError;
        _success = null;
      });
      return;
    }
    final currentPassword = _currentPassword.text;
    final newPassword = _newPassword.text;
    final confirmationPassword = _confirmationPassword.text;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    // Remove the UI copies before any network round trip. The controller never
    // stores these strings; only its immutable verifier/envelope retry body
    // survives an uncertain response.
    _currentPassword.clear();
    _newPassword.clear();
    _confirmationPassword.clear();
    try {
      await app.changeAccountPassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
        confirmationPassword: confirmationPassword,
      );
      if (mounted) {
        setState(() {
          _success = currentL10n.masterPasswordChangedSessionsRevoked;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = app.friendlyError(error);
          _success = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await app.retryAccountPasswordChange();
      if (mounted) {
        setState(() {
          _success =
              currentL10n.masterPasswordChangeConfirmedSessionsRevoked;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = app.friendlyError(error);
          _success = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = app.accountPasswordChangePending;
    final canChange =
        app.session != null &&
        app.account != null &&
        app.authenticatedUsername != null;
    final busy = _busy || app.accountPasswordChangeBusy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.accountPassword,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.theServerReceivesPasswordDerivedVerifiers,
              style: TextStyle(color: context.palette.muted, height: 1.45),
            ),
            if (pending) ...[
              const SizedBox(height: 11),
              Text(
                context.l10n.theLastResponseWasNotConfirmed,
                style: TextStyle(color: context.palette.orange, height: 1.45),
              ),
            ] else ...[
              const SizedBox(height: 11),
              _masterPasswordField(
                controller: _currentPassword,
                label: context.l10n.currentMasterPassword,
                onChanged: _onPasswordEdited,
              ),
              const SizedBox(height: 9),
              _masterPasswordField(
                controller: _newPassword,
                label: context.l10n.newMasterPassword,
                onChanged: _onPasswordEdited,
              ),
              const SizedBox(height: 9),
              _masterPasswordField(
                controller: _confirmationPassword,
                label: context.l10n.confirmNewMasterPassword,
                onChanged: _onPasswordEdited,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.useAtLeast12CharactersIf,
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: context.palette.red)),
            ],
            if (_success != null) ...[
              const SizedBox(height: 10),
              Text(_success!, style: TextStyle(color: context.palette.teal)),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: !canChange || busy
                    ? null
                    : pending
                    ? _retry
                    : _submit,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        pending
                            ? Icons.refresh_rounded
                            : Icons.password_rounded,
                      ),
                label: Text(
                  busy
                      ? context.l10n.changingPassword
                      : pending
                      ? context.l10n.retryPasswordChange
                      : context.l10n.changeMasterPassword,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _masterPasswordField({
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
  }) => TextField(
    controller: controller,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    textInputAction: TextInputAction.next,
    onChanged: onChanged,
    decoration: InputDecoration(labelText: label),
  );

  void _onPasswordEdited(String _) {
    if (_error != null || _success != null) {
      setState(() {
        _error = null;
        _success = null;
      });
    }
  }
}

class _AccountDeletionPanel extends StatelessWidget {
  const _AccountDeletionPanel({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.accountDeletion,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.accountDeletionImmediatelyRevokesAllSessions,
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: app.accountLifecycleBusy || app.syncing
                ? null
                : () => _deleteAccount(context, app),
            icon: const Icon(Icons.person_remove_outlined),
            label: Text(context.l10n.scheduleAccountDeletion),
            style: OutlinedButton.styleFrom(foregroundColor: context.palette.orange),
          ),
        ],
      ),
    ),
  );
}

class _KnownHostTrustPanel extends StatelessWidget {
  const _KnownHostTrustPanel({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final records = app.knownHosts;
    final trustedCountByEndpoint = <String, int>{};
    for (final record in records) {
      if (record.state == KnownHostState.trusted &&
          !app.pendingKnownHostRecordIds.contains(record.id)) {
        trustedCountByEndpoint.update(
          record.endpoint,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final conflictEndpoints = trustedCountByEndpoint.entries
        .where((entry) => entry.value > 1)
        .map((entry) => entry.key)
        .toSet();
    final canRevoke =
        app.activeVault?.canWrite == true &&
        !app.vaultMembershipBusy &&
        !app.vaultLifecycleBusy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.sshHostKeyTrust,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              context.l10n.fingerprintsApprovedDuringSshConnectionAre,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (conflictEndpoints.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.palette.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.palette.orange.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  context.l10n.conflictingSshKeysAreSavedFor(conflictEndpoints.join(', ')),
                  style: const TextStyle(fontSize: 12, height: 1.45),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (records.isEmpty)
              Text(
                context.l10n.noHostKeysHaveBeenApproved,
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              )
            else
              ...records.map((record) {
                final revoked = record.state == KnownHostState.revoked;
                final pending = app.pendingKnownHostRecordIds.contains(
                  record.id,
                );
                final conflicted =
                    !revoked &&
                    !pending &&
                    (trustedCountByEndpoint[record.endpoint] ?? 0) > 1;
                final trustStatus = revoked
                    ? 'REVOKED'
                    : pending
                    ? context.l10n.queuedNotTrusted
                    : conflicted
                    ? context.l10n.conflictConnectionsBlocked
                    : 'TRUSTED';
                final revokedAt = record.revokedAt?.toLocal();
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
                  decoration: BoxDecoration(
                    color: context.palette.surfaceSoft,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.palette.line),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 11),
                        child: Icon(
                          revoked
                              ? Icons.key_off_outlined
                              : pending
                              ? Icons.sync_outlined
                              : Icons.verified_user_outlined,
                          color: revoked
                              ? context.palette.muted
                              : pending
                              ? context.palette.orange
                              : context.palette.teal,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record.endpoint,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Semantics(
                                key: ValueKey<String>(
                                  'known-host-status-${record.id}-$trustStatus',
                                ),
                                container: true,
                                excludeSemantics: true,
                                label: '${record.algorithm} · $trustStatus',
                                child: Text(
                                  '${record.algorithm} · $trustStatus',
                                  style: TextStyle(
                                    color: conflicted
                                        ? context.palette.orange
                                        : context.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                              SelectableText(
                                record.fingerprint,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                              if (revoked && revokedAt != null)
                                Text(
                                  context.l10n.revokedFormat(DateFormat.yMMMd().add_Hm().format(revokedAt)),
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip:
                            context.l10n.revokeSshHostKeyTrustFor(record.endpoint, record.fingerprint),
                        onPressed: canRevoke && !revoked && !pending
                            ? () => unawaited(
                                _revokeKnownHostTrust(context, app, record),
                              )
                            : null,
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

Future<void> _revokeKnownHostTrust(
  BuildContext context,
  AppController app,
  KnownHostRecord record,
) async {
  var revocationStarted = false;
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.key_off_outlined, color: context.palette.orange),
      title: Text(context.l10n.revokeSshHostKeyTrust2),
      content: Text(
        context.l10n.connectionsToEndpointUsingAlgorithmWill(record.endpoint, record.algorithm),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () {
            if (revocationStarted) return;
            revocationStarted = true;
            Navigator.pop(dialogContext);
            unawaited(_applyKnownHostRevocation(context, app, record));
          },
          child: Text(context.l10n.revokeTrust2),
        ),
      ],
    ),
  );
}

Future<void> _applyKnownHostRevocation(
  BuildContext context,
  AppController app,
  KnownHostRecord record,
) async {
  try {
    await app.revokeKnownHost(record.id);
  } catch (error) {
    if (context.mounted) {
      _snack(context, app.friendlyError(error), error: true);
    }
  }
}

class _VaultArchivePanel extends StatefulWidget {
  const _VaultArchivePanel({
    required this.app,
    this.onExportStarting,
    this.onExported,
  });
  final AppController app;
  final Future<void> Function()? onExportStarting;
  final VoidCallback? onExported;

  @override
  State<_VaultArchivePanel> createState() => _VaultArchivePanelState();
}

class _ArchivePasswordDialog extends StatefulWidget {
  const _ArchivePasswordDialog({required this.confirmation});

  final bool confirmation;

  @override
  State<_ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<_ArchivePasswordDialog> {
  final _password = TextEditingController();
  final _repeated = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _repeated.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confirmation = widget.confirmation;
    return AlertDialog(
      title: Text(confirmation ? context.l10n.encryptVaultArchive : context.l10n.unlockArchive),
      content: SizedBox(
        width: appDialogWidth(context, 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: confirmation
                    ? context.l10n.newArchivePassword
                    : context.l10n.archivePassword,
                helperText: confirmation
                    ? context.l10n.atLeast12CharactersIndependentFrom
                    : context.l10n.thisPasswordIsUsedOnlyTo,
              ),
            ),
            if (confirmation) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _repeated,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.l10n.confirmArchivePassword,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () {
            final value = _password.text;
            if (value.length < 12 ||
                (confirmation && value != _repeated.text)) {
              return;
            }
            Navigator.pop(context, value);
          },
          child: Text(confirmation ? context.l10n.continueLabel : context.l10n.verifyArchive),
        ),
      ],
    );
  }
}

class _VaultArchivePanelState extends State<_VaultArchivePanel> {
  AppController get app => widget.app;
  bool _busy = false;

  Future<String?> _passwordDialog({required bool confirmation}) =>
      showAppDialog<String>(
        context: context,
        builder: (_) => _ArchivePasswordDialog(confirmation: confirmation),
      );

  Future<void> _export() async {
    final password = await _passwordDialog(confirmation: true);
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onExportStarting?.call();
      final saved = await app.exportPortableVaultArchive(password);
      if (mounted) {
        _snack(
          context,
          saved
              ? context.l10n.encryptedVaultArchiveSaved
              : context.l10n.archiveSaveWasCanceled,
        );
        if (saved) widget.onExported?.call();
      }
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['atvlt'],
      allowMultiple: false,
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    final password = await _passwordDialog(confirmation: false);
    if (password == null || !mounted) return;
    final bytes = Uint8List.fromList(file.bytes!);
    late final StagedVaultArchive staged;
    setState(() => _busy = true);
    try {
      staged = await app.stagePortableVaultArchive(
        container: bytes,
        exportPassword: password,
      );
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
      return;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) {
      staged.dispose();
      return;
    }
    final apply = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.importVerifiedVaultArchive),
        content: SizedBox(
          width: appDialogWidth(context, 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.vaultVaultid2(staged.vaultId)),
              Text(context.l10n.serverSpaceServerspaceid(staged.serverSpaceId)),
              const SizedBox(height: 10),
              Text(context.l10n.verifiedRevisionsRecordcount(staged.recordCount)),
              Text(context.l10n.serverLocalConflictBranchesConflictcount(staged.conflictCount)),
              Text(context.l10n.uncommittedOperationsCount(staged.operations.length)),
              Text(context.l10n.encryptedObjectBlocksCount(staged.objects.length)),
              Text(context.l10n.epochKeyVersionsCount(staged.epochKeysByVersion.length)),
              const SizedBox(height: 12),
              Text(
                context.l10n.theArchiveHasPassedSignatureMembership,
                style: const TextStyle(height: 1.45),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.recordsAndConflictsRemainEncryptedExisting,
                style: const TextStyle(height: 1.45, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.importToThisVault),
          ),
        ],
      ),
    );
    if (apply != true || !mounted) {
      staged.dispose();
      return;
    }
    setState(() => _busy = true);
    try {
      await app.applyPortableVaultArchive(staged);
      if (mounted)
        {
_snack(context, context.l10n.vaultArchiveImportedAndLocalState);
}
    } catch (error) {
      if (mounted) _snack(context, app.friendlyError(error), error: true);
    } finally {
      staged.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(BuildContext context, String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? context.palette.orange : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.portableEncryptedVaultArchive,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.exportTheFixedServerHistoryCurrent,
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 7),
          Text(
            context.l10n.restoreIsRestrictedToTheSame,
            style: TextStyle(color: context.palette.muted, height: 1.45),
          ),
          if (_busy || app.archiveBusy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            if (app.archiveProgress != null) ...[
              const SizedBox(height: 6),
              Text(app.archiveProgress!, style: const TextStyle(fontSize: 12)),
            ],
          ],
          if (!_busy &&
              !app.archiveBusy &&
              app.archiveFailurePhase != null) ...[
            const SizedBox(height: 10),
            Text(
              context.l10n.lastArchiveVerificationFailedAtArchivefailurephase('${app.archiveFailurePhase}'),
              style: TextStyle(color: context.palette.orange, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || app.archiveBusy ? null : _export,
                icon: const Icon(Icons.download_outlined),
                label: Text(context.l10n.exportArchive),
              ),
              OutlinedButton.icon(
                onPressed: _busy || app.archiveBusy ? null : _import,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(context.l10n.importArchive),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> _refreshVaultStates(
  BuildContext context,
  AppController app,
) async {
  try {
    await app.refreshVaultLifecycle();
    if (context.mounted) {
      _snack(context, context.l10n.vaultStatesRefreshedFromTheServer);
    }
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<void> _deleteAccount(BuildContext context, AppController app) async {
  final review = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.scheduleAccountDeletion2),
      content: SizedBox(
        width: appDialogWidth(context, 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.thisImmediatelyRevokesEverySessionAnd,
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 11),
            Text(
              context.l10n.ifYouOwnASharedVault,
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.keepAccount),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(context.l10n.continueToFinalConfirmation),
        ),
      ],
    ),
  );
  if (review != true || !context.mounted) return;

  final scheduled = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AccountDeletionConfirmationDialog(app: app),
  );
  if (scheduled == true && context.mounted) {
    _snack(
      context,
      app.accountDeletionPurgeAfter == null
          ? context.l10n.accountDeletionScheduledByTheServer
          : context.l10n.accountDeletionScheduledServerPurgeAfter('${app.accountDeletionPurgeAfter}'),
    );
  }
}

class _AccountDeletionConfirmationDialog extends StatefulWidget {
  const _AccountDeletionConfirmationDialog({required this.app});

  final AppController app;

  @override
  State<_AccountDeletionConfirmationDialog> createState() =>
      _AccountDeletionConfirmationDialogState();
}

class _AccountDeletionConfirmationDialogState
    extends State<_AccountDeletionConfirmationDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  var _submitting = false;
  String? _errorMessage;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await widget.app.scheduleAccountDeletion(
        username: widget.app.authenticatedUsername ?? '',
        password: _password.text,
      );
      // Clear the password as soon as the server accepts the request. The
      // controllers remain alive through the route's reverse animation and
      // are disposed by this dialog's State when it is finally removed.
      _password.clear();
      _confirmation.clear();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = widget.app.friendlyError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.confirmAndReAuthenticate),
    content: SizedBox(
      width: appDialogWidth(context, 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.currentAccountValuevalue(widget.app.authenticatedUsername ?? '—')),
          const SizedBox(height: 11),
          TextField(
            controller: _confirmation,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.typeDeleteToConfirm,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.reEnterAccountMasterPassword,
              helperText: context.l10n.thePasswordStaysInThisForm,
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _errorMessage!,
              style: TextStyle(color: context.palette.red, height: 1.4),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _submitting ? null : () => Navigator.pop(context, false),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton.icon(
        onPressed:
            _submitting ||
                widget.app.accountLifecycleBusy ||
                _confirmation.text != 'DELETE' ||
                _password.text.isEmpty
            ? null
            : _submit,
        icon: _submitting
            ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_forever_outlined),
        label: Text(_submitting ? 'Scheduling…' : context.l10n.scheduleDeletion),
      ),
    ],
  );
}

Future<void> _deleteVault(
  BuildContext context,
  AppController app,
  VaultDescriptor vault,
) async {
  final vaultName = app.vaultNameFor(vault.id);
  final confirmImpact = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.scheduleVaultDeletion2),
      content: SizedBox(
        width: appDialogWidth(context, 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.vaultVaultname(vaultName)),
            const SizedBox(height: 11),
            Text(
              context.l10n.theServerWillStartItsConfigured,
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.atTheDeadlineTheServerPurges,
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
            if (app.pendingCount > 0) ...[
              const SizedBox(height: 10),
              _MessageBoxLikeWarning(
                text:
                    context.l10n.pendingcountEncryptedLocalChangeSAre(app.pendingCount),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.keepVault),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(context.l10n.continueToReAuthenticate),
        ),
      ],
    ),
  );
  if (confirmImpact != true || !context.mounted) return;

  final password = TextEditingController();
  final nameConfirmation = TextEditingController();
  var submitting = false;
  String? errorMessage;
  final scheduled = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(context.l10n.confirmAndReAuthenticate),
        content: SizedBox(
          width: appDialogWidth(context, 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.currentAccountValuevalue(app.authenticatedUsername ?? '—')),
              const SizedBox(height: 11),
              TextField(
                controller: nameConfirmation,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: context.l10n.typeVaultnameToConfirm(vaultName),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: password,
                obscureText: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: context.l10n.reEnterAccountMasterPassword,
                  helperText:
                      context.l10n.thePasswordStaysInThisForm,
                ),
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  errorMessage!,
                  style: TextStyle(color: context.palette.red, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting
                ? null
                : () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton.icon(
            onPressed:
                submitting ||
                    app.vaultLifecycleBusy ||
                    nameConfirmation.text.trim() != vaultName ||
                    password.text.isEmpty
                ? null
                : () async {
                    setDialogState(() {
                      submitting = true;
                      errorMessage = null;
                    });
                    try {
                      await app.scheduleVaultDeletion(
                        vaultId: vault.id,
                        username: app.authenticatedUsername ?? '',
                        password: password.text,
                      );
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } catch (error) {
                      setDialogState(() {
                        submitting = false;
                        errorMessage = app.friendlyError(error);
                      });
                    }
                  },
            icon: submitting
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever_outlined),
            label: Text(submitting ? 'Scheduling…' : context.l10n.scheduleDeletion),
          ),
        ],
      ),
    ),
  );
  password.clear();
  password.dispose();
  nameConfirmation.dispose();
  if (scheduled == true && context.mounted) {
    final current = app.vaults.where((item) => item.id == vault.id).firstOrNull;
    _snack(
      context,
      current?.purgeAfter == null
          ? context.l10n.deletionScheduledByTheServer
          : context.l10n.deletionScheduledServerPurgeAfterVaultlifecycledate(_vaultLifecycleDate(current!.purgeAfter)),
    );
  }
}

Future<void> _cancelVaultDeletion(
  BuildContext context,
  AppController app,
  VaultDescriptor vault,
) async {
  final vaultName = app.vaultNameFor(vault.id);
  final continueCancel = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.cancelScheduledDeletion),
      content: Text(
        context.l10n.cancelThePendingDeletionForVaultname(vaultName, _vaultLifecycleDate(vault.purgeAfter)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.keepScheduledDeletion),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(context.l10n.continueLabel),
        ),
      ],
    ),
  );
  if (continueCancel != true || !context.mounted) return;

  final password = TextEditingController();
  var submitting = false;
  String? errorMessage;
  final canceled = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(context.l10n.reAuthenticateToCancel),
        content: SizedBox(
          width: appDialogWidth(context, 450),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.currentAccountValuevalue(app.authenticatedUsername ?? '—')),
              const SizedBox(height: 10),
              TextField(
                controller: password,
                autofocus: true,
                obscureText: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: context.l10n.reEnterAccountMasterPassword,
                ),
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  errorMessage!,
                  style: TextStyle(color: context.palette.red, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting
                ? null
                : () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton.icon(
            onPressed:
                submitting || app.vaultLifecycleBusy || password.text.isEmpty
                ? null
                : () async {
                    setDialogState(() {
                      submitting = true;
                      errorMessage = null;
                    });
                    try {
                      await app.cancelVaultDeletion(
                        vaultId: vault.id,
                        username: app.authenticatedUsername ?? '',
                        password: password.text,
                      );
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } catch (error) {
                      setDialogState(() {
                        submitting = false;
                        errorMessage = app.friendlyError(error);
                      });
                    }
                  },
            icon: submitting
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.undo_rounded),
            label: Text(submitting ? 'Canceling…' : context.l10n.cancelDeletion),
          ),
        ],
      ),
    ),
  );
  password.clear();
  password.dispose();
  if (canceled == true && context.mounted) {
    _snack(context, context.l10n.deletionCanceledPendingEncryptedSyncCan);
  }
}

Future<void> _createVault(BuildContext context, AppController app) async {
  var name = '';
  final value = await showAppDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.createVault),
      content: SizedBox(
        width: appDialogWidth(context, 420),
        child: TextField(
          autofocus: true,
          onChanged: (value) => name = value,
          decoration: InputDecoration(labelText: context.l10n.vaultName),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, name),
          child: Text(context.l10n.createEncryptedVault),
        ),
      ],
    ),
  );
  if (value == null) return;
  try {
    await app.createVault(value);
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<void> _exportVaultShareRequest(
  BuildContext context,
  AppController app,
) async {
  try {
    final request = app.exportVaultShareRequest();
    final controller = TextEditingController(text: request);
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.signedVaultShareRequest),
        content: SizedBox(
          width: appDialogWidth(context, 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.thisCardContainsTheAccountAnd,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                readOnly: true,
                minLines: 5,
                maxLines: 9,
                decoration: InputDecoration(
                  labelText: context.l10n.publicDeviceCard,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.close),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: request));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (context.mounted) {
                _snack(context, context.l10n.signedShareRequestCopied);
              }
            },
            icon: const Icon(Icons.copy_outlined),
            label: Text(context.l10n.copy),
          ),
        ],
      ),
    );
    controller.dispose();
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

Future<void> _inviteVaultMember(BuildContext context, AppController app) async {
  final cardJson = TextEditingController();
  PublicDeviceCard? recipient;
  String role = 'editor';
  String? formError;
  final result = await showAppDialog<Map<String, dynamic>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(context.l10n.inviteToCurrentvaultname(app.currentVaultName)),
        content: SizedBox(
          width: appDialogWidth(context, 580),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.pasteTheRecipientsSignedPublicDevice,
                  style: TextStyle(color: context.palette.muted, height: 1.45),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cardJson,
                  enabled: recipient == null,
                  minLines: 5,
                  maxLines: 10,
                  decoration: InputDecoration(
                    labelText: context.l10n.publicDeviceCardJson,
                    errorText: formError,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: InputDecoration(labelText: context.l10n.vaultRole),
                  items: [
                    DropdownMenuItem(
                      value: 'editor',
                      child: Text(context.l10n.editorCanEditVaultRecords),
                    ),
                    DropdownMenuItem(
                      value: 'viewer',
                      child: Text(context.l10n.viewerReadOnlyVaultAccess),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => role = value);
                  },
                ),
                if (recipient != null) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  Text(
                    context.l10n.confirmTargetName(recipient!.name),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  _DetailLine(
                    label: context.l10n.thisInstance,
                    value: app.instance?.instanceId ?? '—',
                  ),
                  _DetailLine(
                    label: context.l10n.ownerAccountId,
                    value: app.account?.accountId ?? '—',
                  ),
                  _DetailLine(label: context.l10n.accountId, value: recipient!.accountId),
                  _DetailLine(label: context.l10n.deviceId, value: recipient!.deviceId),
                  const SizedBox(height: 5),
                  Text(
                    context.l10n.signingKeyFingerprintSha256,
                    style: TextStyle(color: context.palette.muted, fontSize: 11),
                  ),
                  _PublicFingerprint(
                    app: app,
                    encodedKey: encodeBase64Url(recipient!.signingPublicKey),
                    color: context.palette.lime,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    context.l10n.encryptionKeyFingerprintSha256,
                    style: TextStyle(color: context.palette.muted, fontSize: 11),
                  ),
                  _PublicFingerprint(
                    app: app,
                    encodedKey: encodeBase64Url(recipient!.encryptionPublicKey),
                    color: context.palette.teal,
                  ),
                  const SizedBox(height: 13),
                  _MessageBoxLikeWarning(
                    text:
                        context.l10n.thisGrantsRoleAccessToAll(role),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.cancel2),
          ),
          if (recipient == null)
            FilledButton.icon(
              onPressed: () {
                try {
                  final verified = app.verifyVaultShareRequest(cardJson.text);
                  setDialogState(() {
                    recipient = verified;
                    formError = null;
                  });
                } catch (error) {
                  setDialogState(() => formError = app.friendlyError(error));
                }
              },
              icon: const Icon(Icons.fingerprint),
              label: Text(context.l10n.verifyAndReview),
            )
          else ...[
            TextButton(
              onPressed: () => setDialogState(() {
                recipient = null;
                formError = null;
              }),
              child: Text(context.l10n.back),
            ),
            FilledButton.icon(
              onPressed: () async {
                try {
                  final created = await app.createVaultInvitation(
                    recipient: recipient!,
                    role: role,
                  );
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, created);
                  }
                } catch (error) {
                  if (dialogContext.mounted) {
                    setDialogState(() => formError = app.friendlyError(error));
                  }
                }
              },
              icon: const Icon(Icons.key_outlined),
              label: Text(context.l10n.signAndCreateInvitation),
            ),
          ],
        ],
      ),
    ),
  );
  cardJson.dispose();
  final token = result?['token'] as String?;
  if (token == null || !context.mounted) return;
  final expiration = result?['expires_at'] as String? ?? '—';
  final vaultId = result?['vault_id'] as String? ?? app.currentVaultId;
  final invitation = TextEditingController(text: token);
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.invitationCreated),
      content: SizedBox(
        width: appDialogWidth(context, 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MessageBoxLikeWarning(
              text: context.l10n.thisIsABearerTokenShare,
            ),
            const SizedBox(height: 10),
            _DetailLine(label: context.l10n.vaultId, value: vaultId),
            _DetailLine(label: context.l10n.role, value: role),
            _DetailLine(label: context.l10n.expires, value: expiration),
            const SizedBox(height: 9),
            TextField(
              controller: invitation,
              readOnly: true,
              decoration: InputDecoration(labelText: context.l10n.oneTimeToken),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.done2),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: token));
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            if (context.mounted) _snack(context, context.l10n.invitationTokenCopied);
          },
          icon: const Icon(Icons.copy_outlined),
          label: Text(context.l10n.copyToken),
        ),
      ],
    ),
  );
  invitation.dispose();
}

Future<void> _manageVaultMembers(
  BuildContext context,
  AppController app,
) async {
  try {
    await app.refreshVaultMembers();
  } catch (error) {
    if (context.mounted) {
      _snack(context, app.friendlyError(error), error: true);
    }
    return;
  }
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (_) => _VaultMembersDialog(app: app),
  );
}

class _VaultMembersDialog extends StatefulWidget {
  const _VaultMembersDialog({required this.app});

  final AppController app;

  @override
  State<_VaultMembersDialog> createState() => _VaultMembersDialogState();
}

class _VaultMembersDialogState extends State<_VaultMembersDialog> {
  String? _busyUserId;
  String? _error;
  Timer? _presenceRefreshTimer;
  bool _presenceRefreshBusy = false;

  AppController get app => widget.app;

  bool get _membershipChangeBlocked =>
      app.syncing || app.snapshotRecoveryActive || app.vaultMembershipBusy;

  void _handleAppChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    app.addListener(_handleAppChanged);
    _presenceRefreshTimer = Timer.periodic(
      app.membersPresenceRefreshIntervalForTesting,
      (_) => _refreshPresenceOnly(),
    );
  }

  @override
  void dispose() {
    app.removeListener(_handleAppChanged);
    _presenceRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshPresenceOnly() async {
    if (!mounted ||
        _presenceRefreshBusy ||
        app.vaultPresenceLoading ||
        app.vaultMembershipBusy) {
      return;
    }
    _presenceRefreshBusy = true;
    try {
      await app.refreshVaultPresenceList();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      _presenceRefreshBusy = false;
      if (mounted) setState(() {});
    }
  }

  String _label(Map<String, dynamic> member) {
    final username = member['username'] as String?;
    if (username != null && username.trim().isNotEmpty) return username;
    final id = member['user_id'] as String? ?? 'Unknown account';
    return id.length > 13 ? '${id.substring(0, 8)}…' : id;
  }

  String? _invitationStatus(Map<String, dynamic> member) {
    if (member['state'] != 'invited') return null;
    final invitation = member['invitation'];
    if (invitation is! Map) return 'reissue_required';
    final status = invitation['status'];
    return switch (status) {
      'pending' => 'pending',
      'expired' => 'expired',
      'stale' => 'stale',
      'reissue_required' => 'reissue_required',
      _ => 'reissue_required',
    };
  }

  String _memberStateLabel(Map<String, dynamic> member) {
    final state = member['state'] as String;
    if (state != 'invited') {
      return switch (state) {
        'active' => context.l10n.active2,
        'revoked' => context.l10n.revoked3,
        _ => state,
      };
    }
    return switch (_invitationStatus(member)) {
      'expired' => context.l10n.invitationExpired,
      'stale' || 'reissue_required' => context.l10n.invitationNeedsReissue,
      _ => context.l10n.invitationPending,
    };
  }

  String _presenceLine(String userId) {
    if (app.vaultPresenceLoading) return context.l10n.checkingOnlineDevices;
    if (app.vaultPresenceError != null) return context.l10n.onlineStatusUnavailable;
    final devices = app.vaultPresenceDevices
        .where((item) => item.userId == userId)
        .toList(growable: false);
    if (devices.isEmpty) return context.l10n.noDevicesOnline;
    final latestSeen = devices
        .map((item) => item.lastSeenAt)
        .reduce((left, right) => left.isAfter(right) ? left : right);
    final countLabel = devices.length == 1
        ? '1 device online'
        : '${devices.length} devices online';
    return '$countLabel · last seen ${DateFormat.Hm().format(latestSeen.toLocal())}';
  }

  Future<void> _refreshMembers() async {
    setState(() => _error = null);
    try {
      await app.refreshVaultMembers();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    }
    if (mounted) setState(() {});
  }

  String? _invitationDetail(Map<String, dynamic> member) {
    switch (_invitationStatus(member)) {
      case 'pending':
        final invitation = member['invitation'];
        final rawExpiry = invitation is Map ? invitation['expires_at'] : null;
        final expiry = rawExpiry is String
            ? DateTime.tryParse(rawExpiry)
            : null;
        final formattedExpiry = expiry == null
            ? 'unavailable'
            : DateFormat.yMMMd().add_jm().format(expiry.toLocal());
        return context.l10n.invitationExpiresFormattedexpiry(formattedExpiry);
      case 'expired':
        return context.l10n.sendANewInvitationFromSettings;
      case 'stale':
        return context.l10n.thisInvitationWasInvalidatedAfterA;
      case 'reissue_required':
        return context.l10n.thisInvitationsValidityCouldNotBe;
      default:
        return null;
    }
  }

  Future<void> _setRole(Map<String, dynamic> member, String role) async {
    final userId = member['user_id']! as String;
    final username = _label(member);
    final confirmed = await showAppDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.key_outlined, color: context.palette.lime),
        title: Text(context.l10n.rotateKeyAndChangeRole),
        content: SizedBox(
          width: appDialogWidth(context, 480),
          child: Text(
            context.l10n.changeUsernameFromItemToRole(username, '${member['role']}', role),
            style: const TextStyle(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.sync_lock_rounded),
            label: Text(context.l10n.changeToRole(role)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_membershipChangeBlocked) {
      setState(() {
        _error = context.l10n.waitForVaultSyncOrRecovery;
      });
      return;
    }
    await _runChange(
      userId,
      () => app.changeVaultMemberRole(userId: userId, role: role),
    );
  }

  Future<void> _revoke(Map<String, dynamic> member) async {
    final userId = member['user_id']! as String;
    final username = _label(member);
    final pending = member['state'] == 'invited';
    final confirmed = await showAppDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.person_remove_alt_1_outlined,
          color: context.palette.orange,
        ),
        title: Text(pending ? context.l10n.revokeInvitation2 : context.l10n.revokeMemberAccess),
        content: SizedBox(
          width: appDialogWidth(context, 480),
          child: Text(
            pending
                ? context.l10n.confirmCancelInvitationAndRotate(username)
                : context.l10n.confirmRemoveMemberAndRotate(username),
            style: const TextStyle(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.keepAccess),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: context.palette.orange),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.person_remove_alt_1_outlined),
            label: Text(context.l10n.revokeAndRotateKey),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_membershipChangeBlocked) {
      setState(() {
        _error = context.l10n.waitForVaultSyncOrRecovery;
      });
      return;
    }
    await _runChange(userId, () => app.revokeVaultMember(userId));
  }

  Future<void> _transferOwnership(Map<String, dynamic> member) async {
    final userId = member['user_id']! as String;
    final username = _label(member);
    final confirmed = await showAppDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.admin_panel_settings_outlined,
          color: context.palette.orange,
        ),
        title: Text(context.l10n.transferVaultOwnership),
        content: SizedBox(
          width: appDialogWidth(context, 480),
          child: Text(
            context.l10n.makeUsernameTheSoleOwnerYour(username),
            style: const TextStyle(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.keepCurrentOwner),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: context.palette.orange),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.swap_horiz_rounded),
            label: Text(context.l10n.transferAndRotateKey),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_membershipChangeBlocked) {
      setState(() {
        _error = context.l10n.waitForVaultSyncOrRecovery;
      });
      return;
    }
    final completed = await _runChange(
      userId,
      () => app.transferVaultOwnership(newOwnerUserId: userId),
    );
    if (completed && mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Future<bool> _runChange(String userId, Future<void> Function() change) async {
    var completed = false;
    setState(() {
      _busyUserId = userId;
      _error = null;
    });
    try {
      await change();
      await app.refreshVaultMembers();
      completed = true;
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
    return completed;
  }

  @override
  Widget build(BuildContext context) {
    final vault = app.activeVault;
    final canManageMembers = vault?.role == 'owner' && vault?.canWrite == true;
    final members = [...app.vaultMembers]
      ..sort((left, right) {
        final leftOwner = left['role'] == 'owner';
        final rightOwner = right['role'] == 'owner';
        if (leftOwner != rightOwner) return leftOwner ? -1 : 1;
        return _label(left)
            .toLowerCase()
            .compareTo(_label(right).toLowerCase());
      });
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(context.l10n.membersCurrentvaultname(app.currentVaultName))),
          IconButton(
            tooltip: context.l10n.refreshMembersAndOnlineDevices,
            onPressed: app.vaultMembershipBusy || app.vaultPresenceLoading
                ? null
                : _refreshMembers,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: appDialogWidth(context, 580),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.everyRoleChangeAndRevocationCommits,
                style: TextStyle(color: context.palette.muted, height: 1.45),
              ),
              if (vault?.status == 'deleting' || vault?.canWrite != true) ...[
                const SizedBox(height: 10),
                _MessageBoxLikeWarning(
                  text: context.l10n.thisVaultIsReadOnlyMember,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                _MessageBoxLikeWarning(text: _error!),
              ],
              if (app.vaultPresenceError != null) ...[
                const SizedBox(height: 10),
                _MessageBoxLikeWarning(
                  text:
                      context.l10n.onlineDeviceStatusCouldNotBe('${app.vaultPresenceError}'),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: members.isEmpty
                    ? Center(child: Text(context.l10n.noMembersWereReturned))
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: members.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final member = members[index];
                          final userId = member['user_id']! as String;
                          final role = member['role']! as String;
                          final state = member['state']! as String;
                          final isOwner = role == 'owner';
                          final isActive = state == 'active';
                          final invitationDetail = _invitationDetail(member);
                          final busy =
                              _busyUserId == userId || app.vaultMembershipBusy;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(_label(member)),
                                  subtitle: Text(
                                    [
                                      '${role.toUpperCase()} · ${_memberStateLabel(member)}',
                                      if (invitationDetail != null)
                                        invitationDetail,
                                      if (isActive) _presenceLine(userId),
                                    ].join('\n'),
                                    style: TextStyle(
                                      color: context.palette.muted,
                                      height: 1.4,
                                    ),
                                  ),
                                  trailing: _memberStatus(
                                    role,
                                    state,
                                    _invitationStatus(member),
                                  ),
                                ),
                                if (canManageMembers &&
                                    !isOwner &&
                                    state != 'revoked')
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      if (isActive)
                                        OutlinedButton.icon(
                                          onPressed:
                                              busy ||
                                                  _membershipChangeBlocked ||
                                                  vault?.canWrite != true
                                              ? null
                                              : () => _setRole(
                                                  member,
                                                  role == 'editor'
                                                      ? 'viewer'
                                                      : 'editor',
                                                ),
                                          icon: const Icon(Icons.swap_horiz),
                                          label: Text(
                                            role == 'editor'
                                                ? context.l10n.makeViewer
                                                : context.l10n.makeEditor,
                                          ),
                                        ),
                                      if (isActive &&
                                          const {
                                            'editor',
                                            'viewer',
                                          }.contains(role))
                                        OutlinedButton.icon(
                                          onPressed:
                                              busy ||
                                                  _membershipChangeBlocked ||
                                                  vault?.role != 'owner' ||
                                                  vault?.canWrite != true
                                              ? null
                                              : () =>
                                                    _transferOwnership(member),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: context.palette.orange,
                                          ),
                                          icon: const Icon(
                                            Icons.admin_panel_settings_outlined,
                                          ),
                                          label: Text(
                                            context.l10n.transferOwnership,
                                          ),
                                        ),
                                      OutlinedButton.icon(
                                        onPressed:
                                            busy ||
                                                _membershipChangeBlocked ||
                                                vault?.canWrite != true
                                            ? null
                                            : () => _revoke(member),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: context.palette.orange,
                                        ),
                                        icon: const Icon(
                                          Icons.person_remove_alt_1_outlined,
                                        ),
                                        label: Text(
                                          isActive
                                              ? context.l10n.revokeAccess
                                              : context.l10n.revokeInvitation,
                                        ),
                                      ),
                                    ],
                                  ),
                                if (_busyUserId == userId) ...[
                                  const SizedBox(height: 8),
                                  const LinearProgressIndicator(),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: app.vaultMembershipBusy
              ? null
              : () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }

  Widget _memberStatus(String role, String state, String? invitationStatus) =>
      switch (state) {
        'invited' => _StatusDot(
          label: switch (invitationStatus) {
            'expired' => 'EXPIRED',
            'stale' || 'reissue_required' => context.l10n.reissueRequired,
            _ => 'INVITED',
          },
          color: context.palette.orange,
        ),
        'revoked' => _StatusDot(label: context.l10n.revoked2, color: context.palette.muted),
        _ when role == 'owner' => _StatusDot(
          label: context.l10n.owner,
          color: context.palette.lime,
        ),
        _ => _StatusDot(label: context.l10n.active, color: context.palette.teal),
      };
}

Future<void> _acceptVaultInvitation(
  BuildContext context,
  AppController app,
) async {
  var token = '';
  final suppliedToken = await showAppDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.acceptVaultInvitation),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.useTheAccountAndApprovedDevice,
              style: TextStyle(color: context.palette.muted, height: 1.45),
            ),
            const SizedBox(height: 8),
            _DetailLine(
              label: context.l10n.currentAccount,
              value: app.account?.accountId ?? '—',
            ),
            _DetailLine(
              label: context.l10n.currentDevice,
              value: app.identity?.deviceId ?? '—',
            ),
            const SizedBox(height: 12),
            TextField(
              obscureText: true,
              onChanged: (value) => token = value,
              decoration: InputDecoration(labelText: context.l10n.invitationToken),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, token),
          child: Text(context.l10n.acceptAndUnlockVault),
        ),
      ],
    ),
  );
  if (suppliedToken == null || !context.mounted) return;
  try {
    await app.acceptVaultInvitation(suppliedToken);
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({
    required this.title,
    required this.subtitle,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            // R7 density: 20 compact / 22 touch (R6a 22).
            fontSize: Theme.of(context).textTheme.titleLarge!.fontSize! + 1,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: context.palette.muted,
            height: 1.45,
            fontSize: 12,
          ),
        ),
      ],
    );
    if (trailing == null) return heading;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 14),
              Align(alignment: Alignment.centerRight, child: trailing!),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 14),
            trailing!,
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 35,
            height: 35,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 10, color: context.palette.muted),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppDensity.of(context).space7,
        vertical: AppDensity.of(context).isCompact ? 32 : 40,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: AppDensity.of(context).isCompact ? 44 : 48,
            height: AppDensity.of(context).isCompact ? 44 : 48,
            decoration: BoxDecoration(
              color: context.palette.surfaceRaised,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: context.palette.muted),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: appDialogWidth(context, 470)),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.55,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: context.palette.surfaceRaised,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 9, color: context.palette.muted),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: context.palette.lime.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 8,
        color: context.palette.lime,
        fontWeight: FontWeight.w700,
        letterSpacing: .6,
      ),
    ),
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: .6,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: context.palette.muted),
          ),
        ),
        Expanded(
          child: Semantics(
            label: value,
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PolicyRow extends StatelessWidget {
  const _PolicyRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: icon == Icons.check_circle_outline
              ? context.palette.teal
              : context.palette.orange,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: context.palette.muted),
          ),
        ),
      ],
    ),
  );
}

class _MessageBoxLikeWarning extends StatelessWidget {
  const _MessageBoxLikeWarning({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: context.palette.orange.withValues(alpha: .08),
      border: Border.all(color: context.palette.orange.withValues(alpha: .25)),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.warning_amber_rounded,
          color: context.palette.orange,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: context.palette.orange,
              fontSize: 11,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

Future<bool?> _confirmDelete(
  BuildContext context,
  String name, {
  String? description,
}) => showAppDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(context.l10n.deleteThisItem),
    content: Text(
      description ??
          '$name will be removed locally and a signed encrypted tombstone will sync to your other devices.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.cancel2),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        style: FilledButton.styleFrom(backgroundColor: context.palette.red),
        child: Text(context.l10n.delete2),
      ),
    ],
  ),
);

String _statusLabel(String status) => switch (status) {
  'idle' => currentL10n.idle,
  'pending' => currentL10n.pending,
  'syncing' => currentL10n.syncing,
  'deletion_pending' => currentL10n.vaultDeletionPendingReadOnly,
  'read_only' => currentL10n.readOnly,
  'snapshot_recovering' => currentL10n.rebuildingSnapshot,
  'retry_wait' => currentL10n.retryQueued,
  'resnapshot_required' => currentL10n.snapshotNeeded,
  'snapshot_too_large' => currentL10n.snapshotExceedsClientLimit,
  'epoch_update_required' => currentL10n.keyUpdateNeeded,
  'revoked' => currentL10n.deviceRevoked3,
  'auth_required' => currentL10n.signInNeeded,
  'offline' => currentL10n.offline,
  'error' => currentL10n.syncError,
  _ => currentL10n.syncError,
};

String _syncIssueCategoryLabel(String status) => switch (status) {
  'idle' ||
  'pending' ||
  'syncing' ||
  'read_only' ||
  'deletion_pending' => currentL10n.none,
  'snapshot_recovering' => currentL10n.recoveryInProgress,
  'resnapshot_required' => currentL10n.recoveryRequired,
  'snapshot_too_large' => currentL10n.snapshotSizeLimit,
  'epoch_update_required' => currentL10n.vaultKeyState,
  'auth_required' => 'Sign-in required',
  'revoked' => currentL10n.deviceAccessRevoked,
  'offline' => currentL10n.networkUnavailable,
  'retry_wait' => currentL10n.retryPending,
  'error' => currentL10n.syncServiceError,
  _ => currentL10n.otherSyncIssue,
};

String _syncGenerationStatus(AppController app) {
  final checkpoint = app.syncCheckpointServerGeneration;
  final current = app.instance?.generation;
  if (checkpoint == null || checkpoint.isEmpty) return currentL10n.noCheckpoint;
  if (current == null || current.isEmpty) return currentL10n.serverGenerationUnknown;
  return checkpoint == current ? currentL10n.generationMatches : currentL10n.generationMismatch;
}

String _topBarSyncLabel(String status, int pendingCount) {
  if ((status == 'idle' || status == 'pending') && pendingCount > 0) {
    return '$pendingCount pending';
  }
  return _statusLabel(status);
}

Color _hostColor(BuildContext context, int color) => switch (color % 4) {
  0 => context.palette.lime,
  1 => context.palette.teal,
  2 => context.palette.hostBlue,
  _ => context.palette.orange,
};

String _shortKey(String? key) {
  if (key == null || key.length < 14) return key ?? '—';
  return '${key.substring(0, 8)}…${key.substring(key.length - 5)}';
}

class _PublicFingerprint extends StatefulWidget {
  const _PublicFingerprint({
    required this.app,
    required this.encodedKey,
    required this.color,
  });

  final AppController app;
  final String? encodedKey;
  final Color color;

  @override
  State<_PublicFingerprint> createState() => _PublicFingerprintState();
}

class _PublicFingerprintState extends State<_PublicFingerprint> {
  Future<String>? _fingerprint;

  @override
  void initState() {
    super.initState();
    _loadFingerprint();
  }

  @override
  void didUpdateWidget(covariant _PublicFingerprint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.encodedKey != widget.encodedKey ||
        oldWidget.app != widget.app) {
      _loadFingerprint();
    }
  }

  void _loadFingerprint() {
    final encodedKey = widget.encodedKey;
    _fingerprint = encodedKey == null
        ? null
        : widget.app.publicKeyFingerprint(encodedKey);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.encodedKey == null) return const SelectableText('—');
    return FutureBuilder<String>(
      future: _fingerprint,
      builder: (context, snapshot) {
        final value = snapshot.hasError
            ? 'Fingerprint unavailable'
            : snapshot.data ?? 'Calculating SHA-256…';
        return SelectableText(
          value,
          style: TextStyle(
            color: widget.color,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        );
      },
    );
  }
}

String _remotePath(String base, String child) => sftpChildPath(base, child);

void _snack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: error ? context.palette.errorContainer : null,
    ),
  );
}

Future<void> _showCloudHostEditor(
  BuildContext context,
  AppController app, {
  HostRecord? existing,
  HostProtocol initialProtocol = HostProtocol.ssh,
}) async {
  // Exact scope the editor (its groups/hosts/keychain/permissions) belongs to.
  final vaultId = app.activeVault?.id, accountId = app.session?.accountId;
  final api = app.api, selectionGeneration = app.vaultSelectionGeneration;
  final result = await showHostEditorPanel(
    context,
    existing: existing,
    initialProtocol: initialProtocol,
    groups: app.groups,
    hosts: app.hosts,
    initialCredential: existing == null
        ? null
        : app
              .resolveHostCredential(
                host: existing,
                groupId: existing.groupId,
                hostCredentialId: existing.credentialId,
              )
              .credential,
    keychain: [
      for (final item in app.credentials)
        HostKeychainChoice(id: item.id, label: '${item.name} (${item.username})'),
    ],
    onValidate: app.validateHostReferences,
    canEdit: app.activeVault?.canWrite == true,
  );
  // Never save into a scope other than the one the editor opened for. Same
  // IDs can survive a server/session change or a Vault A->B->A reselection.
  if (result == null ||
      app.activeVault?.id != vaultId ||
      app.session?.accountId != accountId ||
      !identical(app.api, api) ||
      app.vaultSelectionGeneration != selectionGeneration) {
    return;
  }
  try {
    final original = existing;
    if (original == null) {
      await app.saveHost(result);
    } else {
      await app.saveHostFromEditor(original: original, edited: result);
    }
  } catch (error) {
    if (context.mounted) _snack(context, app.friendlyError(error), error: true);
  }
}

/// Account workspace: move a desktop tab into its own window (terminal-style
/// lifecycle: closing the window closes the tab, losing it restores the tab).
Future<bool> _detachCloudDesktop(AppController app, String id) async {
  final tab = app.terminalTabFor(id);
  final desktop = tab?.desktop;
  if (tab == null || tab.closed || desktop == null) return false;
  return DesktopTabWindows.detach(
    windows: ApplicationWindows.instance,
    owner: app,
    tabId: id,
    session: desktop,
    title: tab.host?.name ?? currentL10n.remoteDesktop2,
    onDetached: () => app.markTerminalDetached(id, true),
    onUserClosed: () => app.closeTerminalTab(id),
    onRestored: () {
      app.markTerminalDetached(id, false);
      app.showWorkspacePage(WorkspacePage.terminal);
    },
  );
}

/// Account workspace: one window per remote monitor; returns how many failed.
Future<int> _openCloudDesktopMonitors(AppController app, String id) async {
  final tab = app.terminalTabFor(id);
  final desktop = tab?.desktop;
  if (tab == null || tab.closed || desktop == null) return 0;
  final expected = desktop.rdpConfig?.monitors.length ?? 0;
  final opened = await DesktopTabWindows.openMonitors(
    windows: ApplicationWindows.instance,
    owner: app,
    tabId: id,
    session: desktop,
    title: tab.host?.name ?? currentL10n.remoteDesktop2,
  );
  return expected - opened;
}
