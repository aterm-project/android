import 'app_menu.dart';
import '../platform/file_window_tracking.dart';
import '../desktop/window/desktop_window.dart';
import '../domain/window_combination.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'window_combinations.dart';
import '../terminal/local_shell_history.dart';
import '../terminal/terminal_tools.dart';
import 'terminal_tools_sidebar.dart';
import '../mcp/mcp_service.dart';
import '../mcp/mcp_workspace.dart';
import 'mcp_settings_panel.dart';
import 'account_settings.dart';
import 'settings_scaffold.dart';
import '../console/local_console.dart';
import '../console/local_shell_l10n.dart';
import 'local_shell_menu.dart';
import 'home_add_sharing_row.dart';
import '../telnet/telnet_errors.dart';
import '../telnet/telnet_session.dart';
import '../telnet/telnet_transport.dart';
import '../telnet/telnet_ui.dart';
import '../desktop/desktop_session.dart';
import '../desktop/rdp_certificate_persistence.dart';
import '../domain/quick_connect.dart';
import 'host_search_field.dart';
import 'host_search_palette.dart';
import '../desktop/desktop_view.dart';
import '../desktop/window/desktop_tab_windows.dart';
import 'host_file_session.dart';
import 'file_workspace_tabs.dart';
import 'group_session_layout.dart';
import 'remote_file_workspace.dart';
import '../platform/files_window_launch.dart';

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../archive/local_profile_archive.dart';
import '../attachments/attachment_file_saver.dart';
import '../crypto/vault_crypto.dart';
import '../domain/known_host.dart';
import '../domain/models.dart';
import '../domain/snippet_invocation.dart';
import '../domain/vault_preference.dart';
import '../storage/application_reload.dart';
import '../storage/database_quarantine.dart';
import '../storage/local_host_repository.dart';
import '../storage/local_profile_catalog.dart';
import '../storage/local_profile_service.dart';
import '../storage/local_vault_database.dart';
import '../ssh/local_profile_ssh_controller.dart';
import '../ssh/ssh_service.dart';
import '../ssh/host_operating_system_probe.dart';
import '../ssh/host_operating_system_persistence.dart';
import '../terminal/terminal_search.dart';
import '../terminal/mirrored_terminal.dart';
import '../terminal/session_log.dart';
import '../terminal/session_recovery.dart';
import 'session_recovery_overlay.dart';
import '../platform/application_windows.dart';
import 'session_workspace.dart';
import 'ssh_forwarding_page.dart';
import 'ssh_port_forwarding_dialog.dart';
import 'workspace_controls.dart';
import 'workspace_status_bar.dart';
import 'transfer_dialog.dart';
import '../terminal/terminal_shortcuts.dart';
import '../import/termius_transfer_target.dart';
import '../import/termius_keychain_bridge.dart';
import 'termius_transfer_dialog.dart';
import 'app_theme.dart';
import 'home_sidebar.dart';
import 'host_editor_panel.dart';
import 'keychain_page.dart';
import 'session_logs_page.dart';
import 'host_system_icon.dart';
import 'host_card_layout.dart';
import 'terminal_palette.dart';
import 'terminal_palette_picker.dart';
import 'terminal_shortcut_editor.dart';
import 'terminal_keybar.dart';
import 'workspace_mode_settings.dart';
import 'workspace_tab_bar.dart';
import 'new_window.dart';
import '../l10n/l10n.dart';
import 'app_language_settings.dart';
import 'app_theme_mode.dart';
import 'wallpaper.dart';
import 'wallpaper_settings.dart';

typedef LocalVaultDatabaseFactory = Future<LocalVaultDatabase> Function(
  UnlockedLocalProfile profile, {
  required LocalVaultOpenMode mode,
});
typedef LocalHostRepositoryFactory = LocalHostRepository Function({
  required LocalVaultDatabase database,
  required UnlockedLocalProfile profile,
  required VaultCrypto crypto,
});
typedef LocalProfileArchivePicker = Future<Uint8List?> Function();
typedef LocalProfileArchiveSaver = Future<bool> Function(Uint8List bytes);
typedef LocalProfileSshControllerFactory = LocalProfileSshController Function(
  LocalHostRepository repository,
);

enum _LocalWorkspace {
  hosts,
  credentials,
  groups,
  snippets,
  preferences,
  logs,
  forwarding,
}

/// Only display metadata is retained by the unlocked local Snippet list. The
/// script body and structured parameter values are fetched again when edited.

/// Test seam mirroring [AppController.localConsoleOpenerForTesting] for the
/// local Profile workspace (fake PTY / serial console).
@visibleForTesting
LocalConsole Function({
  LocalShellLaunch? shell,
  String? serialPort,
  int baudRate,
})?
localProfileConsoleOpenerForTesting;

class _LocalSnippetSummary {
  const _LocalSnippetSummary({
    required this.id,
    required this.title,
    required this.shell,
    required this.executionMode,
    required this.tags,
    required this.revisionId,
  });

  final String id;
  final String title;
  final String shell;
  final SnippetExecutionMode executionMode;
  final List<String> tags;
  final String revisionId;
}

/// Standalone entry flow for local-only profiles and encrypted records.
///
/// This widget deliberately has no dependency on the signed-in application
/// controller, API client, or server sync repository. Host records created
/// here remain local to this browser/device until an explicit migration path
/// exists.
class LocalProfileFlow extends StatefulWidget {
  const LocalProfileFlow({
    required this.catalog,
    required this.service,
    required this.crypto,
    required this.onExit,
    this.databaseFactory,
    this.repositoryFactory,
    this.quarantineRegistry,
    this.archivePicker,
    this.archiveSaver,
    this.sshControllerFactory,
    this.persistentMode = false,
    this.autoCreateOnFirstLaunch = false,
    this.filesLaunch,
    super.key,
  });

  final LocalProfileCatalog catalog;
  final LocalProfileService service;
  final VaultCrypto crypto;
  final FutureOr<void> Function() onExit;
  final bool persistentMode;
  final bool autoCreateOnFirstLaunch;
  final FilesWindowLaunch? filesLaunch;
  final LocalVaultDatabaseFactory? databaseFactory;
  final LocalHostRepositoryFactory? repositoryFactory;
  final DatabaseQuarantineRegistry? quarantineRegistry;
  final LocalProfileArchivePicker? archivePicker;
  final LocalProfileArchiveSaver? archiveSaver;
  final LocalProfileSshControllerFactory? sshControllerFactory;

  @override
  State<LocalProfileFlow> createState() => _LocalProfileFlowState();
}

class _LocalProfileFlowState extends State<LocalProfileFlow> {
  final _homeSearch = TextEditingController();
  late final McpWorkspace _mcpWorkspace;
  McpWorkspace _createMcpWorkspace() => McpWorkspace(
    scope: () =>
        !_disposing && !_storageRecoveryRequired && _activeProfile != null
        ? 'local:${_activeProfile!.record.profileId}'
        : null,
    describe: () => {
      'mode': 'local',
      'hosts': _hosts.length,
      'sessions': _sessions.length,
    },
    hosts: () => List.of(_hosts),
    sessions: () => _sessions
        .map(
          (session) => McpSession(
            id: session.id,
            name: session.host.name,
            kind: session.console != null
                ? 'console'
                : session.host.protocol.name,
            hostId: session.console == null ? session.host.id : null,
            state:
                session.desktop?.state ??
                session.telnetState ??
                (session.connected.value ? 'connected' : 'disconnected'),
            isAlive: () => !session._closed && _sessions.contains(session),
            terminal: session.desktop == null ? session.terminal : null,
            connection: session.connection,
            input: (text) => session.terminal.onOutput?.call(text),
            focus: () => _selectTerminalTab(session.id),
            close: () => _closeTerminalSession(session.id),
          ),
        )
        .toList(),
    connect: (host) async {
      if (_busy)
        throw const McpToolException(
          'workspace_busy',
          'The workspace is busy.',
        );
      await _connectLocalHost(host);
    },
    openConsole: _openConsole,
  );

  final _createPassword = TextEditingController();
  final _unlockPassword = TextEditingController();

  late final LocalVaultDatabaseFactory _databaseFactory =
      widget.databaseFactory ??
      ((profile, {required mode}) =>
          LocalVaultDatabase.open(profile, mode: mode));

  List<LocalProfileRecord> _profiles = const [];
  Set<String> _deviceManagedProfiles = const {};
  LocalProfileRecord? _selectedProfile;
  UnlockedLocalProfile? _activeProfile;
  LocalVaultDatabase? _database;
  LocalHostRepository? _repository;
  List<HostRecord> _hosts = const [];
  String? _hostListError;
  List<LocalCredentialSummary> _credentials = const [];
  String? _credentialListError;
  List<LocalGroupRecord> _groups = const [];
  String? _groupListError;
  List<_LocalSnippetSummary> _snippets = const [];
  String? _snippetListError;
  LocalPreferenceRecord? _defaultSectionPreference;
  _LocalWorkspace _defaultSectionChoice = _LocalWorkspace.hosts;
  LocalPreferenceRecord? _terminalFontSizePreference;
  int _terminalFontSizeChoice = VaultPreferenceRecord.defaultTerminalFontSize;
  LocalPreferenceRecord? _terminalThemePreference;
  VaultTerminalThemeChoice _terminalThemeChoice =
      VaultPreferenceRecord.defaultTerminalTheme;
  LocalPreferenceRecord? _terminalShortcutsPreference;
  TerminalShortcutBindings _terminalShortcutBindings =
      TerminalShortcutBindings.defaults;
  final Map<TerminalShortcutAction, TextEditingController>
  _terminalShortcutControllers = {};
  String? _preferenceLoadError;
  _LocalWorkspace _workspace = _LocalWorkspace.hosts;

  /// Device-local session logs, one book per unlocked Profile object.
  final _sessionLogBooks = Expando<SessionLogBook>('session-logs');
  SessionLogBook? get _sessionLogs {
    final profile = _activeProfile;
    return profile == null ? null : _sessionLogBooks[profile];
  }
  final List<_LocalTerminalSession> _sessions = [];
  final _portForwardChanges = SshPortForwardChangeRelay();

  /// Home "SSH Forwarding" page state that survives leaving the page (pending
  /// connect-and-start, chosen session per Host).
  late final SshForwardingSource _sshForwardingSource =
      _createSshForwardingSource();
  SshForwardingController? _sshForwardingControllerOrNull;
  SshForwardingController get _sshForwardingController =>
      _sshForwardingControllerOrNull ??= SshForwardingController(
        source: _sshForwardingSource,
      );
  String _selectedTabId = 'hosts';
  final _files = FileWorkspaceTabs();
  final _tabOrder = WorkspaceTabOrder();
  bool _filesLaunchScheduled = false;
  bool _filesLaunchConsumed = false;
  final _layout = SessionWorkspaceController();
  final _windowOwner = Object();
  final _dragScope = const Uuid().v4();
  final _detached = <String>{};
  VoidCallback? _unregisterWindowOwner, _unregisterOwnerCloser;
  bool _disposing = false;
  List<_LocalTerminalSession> get _visibleSessions =>
      _sessions.where((s) => !_detached.contains(s.id)).toList();

  bool _hostGrid = true;
  bool _groupConnecting = false;
  int _groupConnectionGeneration = 0;
  bool _catalogLoading = true;
  String? _profileListError;
  bool _busy = false;
  bool _storageRecoveryRequired = false;
  String? _pendingVaultProfileId;
  String? _pageError;
  int _operationGeneration = 0;
  int _catalogGeneration = 0;

  VoidCallback? _unregisterTrackedFileProvider;
  void _onTrackedFilesChanged() {
    if (mounted && !_disposing) setState(() {});
  }

  FilesWindowLaunch? _trackedFileDescriptor() {
    final expected = widget.filesLaunch, profile = _activeProfile;
    if (expected == null ||
        profile == null ||
        !expected.matchesScope(
          FilesWindowWorkspace.local,
          profile.record.profileId,
        ))
      return null;
    final file =
        _files.find(_selectedTabId) ??
        _files.entries
            .where(
              (e) =>
                  e.host.id == expected.hostId &&
                  e.controller.protocol.name == expected.protocol.name,
            )
            .firstOrNull;
    if (file == null || file.controller.isClosed) return null;
    return FilesWindowLaunch(
      workspace: FilesWindowWorkspace.local,
      scopeId: profile.record.profileId,
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
      scopeEpoch: () => (_activeProfile, _operationGeneration),
    );
    TrackedFilesWindows.instance.addListener(_onTrackedFilesChanged);
    _mcpWorkspace = _createMcpWorkspace();
    McpService.instance.attach(_mcpWorkspace);
    _files.addListener(_onSessionChanged);
    _unregisterWindowOwner = ApplicationWindows.instance.registerVisibleOwner(
      _windowOwner,
      () async {
        await TrackedFilesWindows.instance.releaseOwner(_windowOwner);
        _operationGeneration++;
        for (final session in List<_LocalTerminalSession>.of(
          _visibleSessions,
        )) {
          await _closeTerminalSession(session.id);
        }
      },
    );
    _unregisterOwnerCloser = ApplicationWindows.instance.registerOwnerCloser(
      _windowOwner,
      () async {
        _operationGeneration++;
        final profile = _activeProfile;
        final database = _database;
        _cancelHostSearch();
        _activeProfile = null;
        _database = null;
        _repository = null;
        _notifyForwardingScopeChanged();
        if (profile != null) {
          await _disposeSession(profile, database);
        } else {
          await _closeLocalConnections();
          await database?.close();
        }
      },
    );
    for (final action in TerminalShortcutAction.values) {
      _terminalShortcutControllers[action] = TextEditingController(
        text: TerminalShortcutBindings.defaults.chordFor(action),
      );
    }
    _databaseQuarantineRegistry.addListener(_onDatabaseQuarantineChanged);
    _storageRecoveryRequired = _hasRelevantDatabaseQuarantine;
    if (!_storageRecoveryRequired) unawaited(_refreshProfiles(initial: true));
  }

  @override
  void dispose() {
    _unregisterTrackedFileProvider?.call();
    TrackedFilesWindows.instance.removeListener(_onTrackedFilesChanged);
    unawaited(TrackedFilesWindows.instance.releaseOwner(_windowOwner));
    _sshForwardingControllerOrNull?.dispose();
    _portForwardChanges.dispose();
    _homeSearch.dispose();
    McpService.instance.detach(_mcpWorkspace);
    _disposing = true;
    _groupConnectionGeneration++;
    _files.removeListener(_onSessionChanged);
    _files.dispose();
    _unregisterWindowOwner?.call();
    _unregisterOwnerCloser?.call();
    unawaited(ApplicationWindows.instance.closeOwner(_windowOwner));
    _layout.dispose();
    _databaseQuarantineRegistry.removeListener(_onDatabaseQuarantineChanged);
    // Invalidate every completion before scheduling awaited teardown. Closing
    // the profile waits for any repository lease before its database closes.
    _operationGeneration++;
    final profile = _activeProfile;
    final database = _database;
    _cancelHostSearch();
    _activeProfile = null;
    _database = null;
    _repository = null;
    if (profile != null) {
      unawaited(_disposeSession(profile, database).catchError((Object _) {}));
    } else if (database != null) {
      unawaited(database.close().catchError((Object _) {}));
    }
    _createPassword.dispose();
    _unlockPassword.dispose();
    for (final controller in _terminalShortcutControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  DatabaseQuarantineRegistry get _databaseQuarantineRegistry =>
      widget.quarantineRegistry ?? databaseQuarantineRegistry;

  bool get _hasRelevantDatabaseQuarantine {
    final names = _databaseQuarantineRegistry.quarantinedDatabaseNames;
    if (names.contains(localProfileCatalogDatabaseName)) return true;
    final profileId =
        _pendingVaultProfileId ??
        _activeProfile?.record.profileId ??
        _database?.profileId;
    return profileId != null &&
        names.contains(localVaultDatabaseName(profileId));
  }

  void _onDatabaseQuarantineChanged() {
    if (_hasRelevantDatabaseQuarantine) _requireDatabaseReload();
  }

  void _requireDatabaseReload() {
    unawaited(McpService.instance.stop());
    if (!mounted || _storageRecoveryRequired) return;
    final activeProfile = _activeProfile;
    setState(() {
      _storageRecoveryRequired = true;
      _catalogLoading = false;
    });
    _notifyForwardingScopeChanged();
    if (activeProfile != null) {
      unawaited(
        () async {
          await _closeLocalConnections();
          await activeProfile.lock();
        }().catchError((Object _) {}),
      );
    }
  }

  Future<void> _refreshProfiles({bool initial = false}) async {
    if (_storageRecoveryRequired) return;
    final generation = ++_catalogGeneration;
    if (initial && mounted) setState(() => _catalogLoading = true);
    try {
      var profiles = await widget.catalog.list();
      if (initial &&
          profiles.isEmpty &&
          widget.filesLaunch == null &&
          widget.autoCreateOnFirstLaunch &&
          !kIsWeb) {
        final operation = _beginOperation();
        if (operation >= 0) {
          UnlockedLocalProfile? created;
          try {
            created = await widget.service.createDeviceProtected(
              initializeVault: (profile) async {
                final database = await _databaseFactory(
                  profile,
                  mode: LocalVaultOpenMode.createNew,
                );
                await database.close();
              },
            );
            if (_isCurrentOperation(operation)) {
              await _activate(
                created,
                operation,
                vaultOpenMode: LocalVaultOpenMode.openExisting,
                remember: false,
              );
              created = null;
            }
          } on DatabaseRecoveryRequiredException {
            _requireDatabaseReload();
          } on Object {
            if (_isCurrentOperation(operation)) {
              _showMessage(currentL10n.couldntSafelySaveTheDeviceUnlock);
            }
          } finally {
            await created?.lock();
            _finishOperation(operation);
          }
          profiles = await widget.catalog.list();
        }
      }
      if (initial &&
          _activeProfile == null &&
          profiles.isNotEmpty &&
          mounted &&
          generation == _catalogGeneration) {
        final operation = _beginOperation();
        if (operation >= 0) {
          UnlockedLocalProfile? resumed;
          try {
            resumed = await widget.service.tryResume();
            if (resumed != null &&
                _isCurrentOperation(operation) &&
                (widget.filesLaunch == null ||
                    widget.filesLaunch!.matchesScope(
                      FilesWindowWorkspace.local,
                      resumed.record.profileId,
                    ))) {
              await _activate(
                resumed,
                operation,
                vaultOpenMode: LocalVaultOpenMode.openExisting,
              );
              resumed = null;
            }
          } on DatabaseRecoveryRequiredException {
            _requireDatabaseReload();
          } on Object {
            try {
              await widget.service.forgetResume();
            } on Object {
              /* Manual fallback. */
            }
          } finally {
            await resumed?.lock();
            _finishOperation(operation);
          }
        }
      }
      final deviceManaged = <String>{};
      for (final profile in profiles) {
        if (await widget.service.isDeviceManaged(profile.profileId)) {
          deviceManaged.add(profile.profileId);
        }
      }
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _deviceManagedProfiles = deviceManaged;
        _profiles = profiles;
        if (widget.filesLaunch case final request?) {
          _selectedProfile = profiles
              .where(
                (entry) => request.matchesScope(
                  FilesWindowWorkspace.local,
                  entry.profileId,
                ),
              )
              .firstOrNull;
          if (_activeProfile == null) {
            _pageError = _selectedProfile == null
                ? context.l10n.theLocalProfileRequestedByThe
                : context.l10n.unlockTheTargetLocalProfileTo;
          }
        }
        if (widget.filesLaunch == null &&
            _selectedProfile == null &&
            profiles.length == 1) {
          _selectedProfile = profiles.single;
        }
        _catalogLoading = false;
        _profileListError = null;
        if (_selectedProfile != null &&
            !profiles.any(
              (profile) => profile.profileId == _selectedProfile!.profileId,
            )) {
          _selectedProfile = null;
        }
      });
    } on DatabaseRecoveryRequiredException {
      if (mounted && generation == _catalogGeneration) {
        _requireDatabaseReload();
      }
    } on Object {
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _profiles = const [];
        _selectedProfile = null;
        _catalogLoading = false;
        _profileListError = context.l10n.couldntReadTheLocalProfileList2;
      });
    }
  }

  int _beginOperation() {
    if (_busy || _storageRecoveryRequired) return -1;
    final generation = ++_operationGeneration;
    setState(() {
      _busy = true;
      _pageError = null;
    });
    return generation;
  }

  bool _isCurrentOperation(int generation) =>
      mounted && generation == _operationGeneration;

  Future<void> _createProfile() async {
    final password = _createPassword.text;
    _createPassword.clear();
    if (password.length < LocalProfileService.minimumPasswordLength) {
      setState(() {
        _pageError =
            context.l10n.theMasterPasswordMustBeAt(LocalProfileService.minimumPasswordLength);
      });
      return;
    }
    final generation = _beginOperation();
    if (generation < 0) return;
    UnlockedLocalProfile? profile;
    try {
      profile = await widget.service.create(password: password);
      if (!_isCurrentOperation(generation)) {
        await profile.lock();
        return;
      }
      await _activate(
        profile,
        generation,
        vaultOpenMode: LocalVaultOpenMode.createNew,
      );
      profile = null;
    } on DatabaseRecoveryRequiredException {
      if (profile != null) {
        await profile.lock();
        profile = null;
      }
      if (_isCurrentOperation(generation)) _requireDatabaseReload();
    } on Object {
      if (profile != null) await profile.lock();
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.couldntCreateTheLocalProfileTry);
      }
    } finally {
      if (profile != null) await profile.lock();
      _finishOperation(generation);
    }
  }

  Future<void> _unlockSelectedProfile() async {
    final selected = _selectedProfile;
    final password = _unlockPassword.text;
    _unlockPassword.clear();
    if (selected == null) {
      setState(() => _pageError = context.l10n.chooseALocalProfileFirst);
      return;
    }
    final deviceManaged = _deviceManagedProfiles.contains(selected.profileId);
    if (password.isEmpty && !deviceManaged) {
      setState(() => _pageError = context.l10n.enterTheLocalProfileMasterPassword);
      return;
    }
    final generation = _beginOperation();
    if (generation < 0) return;
    UnlockedLocalProfile? profile;
    try {
      profile = deviceManaged
          ? await widget.service.unlockDeviceProfile(selected.profileId)
          : await widget.service.unlock(
              profileId: selected.profileId,
              password: password,
            );
      if (profile == null) {
        throw StateError(currentL10n.protectedDeviceKeyUnavailable);
      }
      if (!_isCurrentOperation(generation)) {
        await profile.lock();
        return;
      }
      await _activate(
        profile,
        generation,
        vaultOpenMode: LocalVaultOpenMode.openExisting,
      );
      profile = null;
    } on LocalVaultBindingMissingException {
      if (profile != null) await profile.lock();
      profile = null;
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.localProfileDataIsMissingOr);
      }
    } on DatabaseRecoveryRequiredException {
      if (profile != null) {
        await profile.lock();
        profile = null;
      }
      if (_isCurrentOperation(generation)) _requireDatabaseReload();
    } on Object {
      if (profile != null) await profile.lock();
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.wrongPasswordOrTheLocalProfile);
      }
    } finally {
      if (profile != null) await profile.lock();
      _finishOperation(generation);
    }
  }

  Future<void> _activate(
    UnlockedLocalProfile profile,
    int generation, {
    required LocalVaultOpenMode vaultOpenMode,
    bool remember = true,
  }) async {
    LocalVaultDatabase? database;
    _pendingVaultProfileId = profile.record.profileId;
    try {
      database = await _databaseFactory(profile, mode: vaultOpenMode);
      final repository =
          widget.repositoryFactory?.call(
            database: database,
            profile: profile,
            crypto: widget.crypto,
          ) ??
          LocalHostRepository(
            database: database,
            profile: profile,
            crypto: widget.crypto,
          );
      final hosts = await repository.listHosts();
      List<LocalCredentialSummary> credentials = const [];
      String? credentialListError;
      try {
        credentials = await repository.listCredentialSummaries();
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        credentialListError = currentL10n.couldntReadTheLocalCredentialList;
      }
      List<LocalGroupRecord> groups = const [];
      String? groupListError;
      try {
        groups = await repository.listGroups();
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        groupListError = currentL10n.couldntReadTheLocalGroupList;
      }
      List<LocalSnippetRecord> snippets = const [];
      String? snippetListError;
      try {
        snippets = await repository.listSnippets();
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        snippetListError = currentL10n.couldntReadTheLocalSnippetList;
      }
      LocalPreferenceRecord? defaultSectionPreference;
      LocalPreferenceRecord? terminalFontSizePreference;
      LocalPreferenceRecord? terminalThemePreference;
      LocalPreferenceRecord? terminalShortcutsPreference;
      String? preferenceLoadError;
      var defaultSection = _LocalWorkspace.hosts;
      var terminalFontSize = VaultPreferenceRecord.defaultTerminalFontSize;
      var terminalTheme = VaultPreferenceRecord.defaultTerminalTheme;
      var terminalShortcuts = TerminalShortcutBindings.defaults;
      try {
        defaultSectionPreference = await repository.getPreference(
          scope: 'workspace',
          key: 'defaultSection',
          platformFamily: 'all',
        );
        if (defaultSectionPreference != null) {
          defaultSection = _workspaceFromPreferenceValue(
            _strictPreference(defaultSectionPreference).value,
          );
        }
        terminalFontSizePreference = await repository.getPreference(
          scope: 'workspace',
          key: VaultPreferenceRecord.terminalFontSizeKey,
          platformFamily: 'all',
        );
        if (terminalFontSizePreference != null) {
          terminalFontSize = _strictPreference(terminalFontSizePreference)
              .terminalFontSizeValue;
        }
        terminalThemePreference = await repository.getPreference(
          scope: 'workspace',
          key: VaultPreferenceRecord.terminalThemeKey,
          platformFamily: 'all',
        );
        if (terminalThemePreference != null) {
          terminalTheme = _strictPreference(terminalThemePreference)
              .terminalThemeValue;
        }
        terminalShortcutsPreference = await repository.getPreference(
          scope: 'workspace',
          key: VaultPreferenceRecord.terminalShortcutsKey,
          platformFamily: 'all',
        );
        if (terminalShortcutsPreference != null) {
          terminalShortcuts = _strictPreference(terminalShortcutsPreference)
              .terminalShortcutBindings;
        }
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        defaultSectionPreference = null;
        terminalFontSizePreference = null;
        terminalThemePreference = null;
        terminalShortcutsPreference = null;
        defaultSection = _LocalWorkspace.hosts;
        terminalFontSize = VaultPreferenceRecord.defaultTerminalFontSize;
        terminalTheme = VaultPreferenceRecord.defaultTerminalTheme;
        terminalShortcuts = TerminalShortcutBindings.defaults;
        preferenceLoadError = currentL10n.couldntReadLocalPreferencesYouCan;
      }
      if (!_isCurrentOperation(generation)) {
        await _disposeSession(profile, database);
        return;
      }
      if (remember) await widget.service.remember(profile);
      if (!_isCurrentOperation(generation)) {
        await _disposeSession(profile, database);
        return;
      }
      final sessionLogs = SessionLogBook(
        storage: LocalPreferenceSessionLogStorage(repository),
      );
      _sessionLogBooks[profile] = sessionLogs;
      unawaited(sessionLogs.load());
      setState(() {
        _activeProfile = profile;
        _database = database;
        _repository = repository;
        _notifyForwardingScopeChanged();
        _hosts = hosts;
        _hostListError = null;
        _credentials = credentials;
        _credentialListError = credentialListError;
        _groups = groups;
        _groupListError = groupListError;
        _snippets = _snippetSummaries(snippets);
        _snippetListError = snippetListError;
        _defaultSectionPreference = defaultSectionPreference;
        _defaultSectionChoice = defaultSection;
        _terminalFontSizePreference = terminalFontSizePreference;
        _terminalFontSizeChoice = terminalFontSize;
        _terminalThemePreference = terminalThemePreference;
        _terminalThemeChoice = terminalTheme;
        _terminalShortcutsPreference = terminalShortcutsPreference;
        _terminalShortcutBindings = terminalShortcuts;
        for (final action in TerminalShortcutAction.values) {
          _terminalShortcutControllers[action]!.text = terminalShortcuts
              .chordFor(action);
        }
        _preferenceLoadError = preferenceLoadError;
        _workspace = defaultSection;
        _selectedProfile = null;
      });
    } on Object {
      await _disposeSession(profile, database);
      rethrow;
    } finally {
      _pendingVaultProfileId = null;
    }
  }

  void _finishOperation(int generation) {
    if (_isCurrentOperation(generation)) setState(() => _busy = false);
  }

  Future<void> _lockProfile() async {
    unawaited(McpService.instance.stop());
    if (_busy) return;
    final profile = _activeProfile;
    final database = _database;
    if (profile == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    setState(() {
      _cancelHostSearch();
      _activeProfile = null;
      _database = null;
      _repository = null;
      _notifyForwardingScopeChanged();
      _hosts = const [];
      _hostListError = null;
      _credentials = const [];
      _credentialListError = null;
      _groups = const [];
      _groupListError = null;
      _snippets = const [];
      _snippetListError = null;
      _defaultSectionPreference = null;
      _defaultSectionChoice = _LocalWorkspace.hosts;
      _terminalFontSizePreference = null;
      _terminalFontSizeChoice = VaultPreferenceRecord.defaultTerminalFontSize;
      _terminalThemePreference = null;
      _terminalThemeChoice = VaultPreferenceRecord.defaultTerminalTheme;
      _terminalShortcutsPreference = null;
      _terminalShortcutBindings = TerminalShortcutBindings.defaults;
      for (final action in TerminalShortcutAction.values) {
        _terminalShortcutControllers[action]!.text = TerminalShortcutBindings
            .defaults
            .chordFor(action);
      }
      _preferenceLoadError = null;
      _workspace = _LocalWorkspace.hosts;
    });
    try {
      try {
        await widget.service.forgetResume();
      } finally {
        await _disposeSession(profile, database);
      }
      if (!_isCurrentOperation(generation)) return;
      await _refreshProfiles();
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theProfileWasClosedButAutomatic);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _exit() async {
    unawaited(McpService.instance.stop());
    if (_busy) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    final profile = _activeProfile;
    final database = _database;
    setState(() {
      _cancelHostSearch();
      _activeProfile = null;
      _database = null;
      _repository = null;
      _notifyForwardingScopeChanged();
      _hosts = const [];
      _hostListError = null;
      _credentials = const [];
      _credentialListError = null;
      _groups = const [];
      _groupListError = null;
      _snippets = const [];
      _snippetListError = null;
      _defaultSectionPreference = null;
      _defaultSectionChoice = _LocalWorkspace.hosts;
      _terminalFontSizePreference = null;
      _terminalFontSizeChoice = VaultPreferenceRecord.defaultTerminalFontSize;
      _terminalThemePreference = null;
      _terminalThemeChoice = VaultPreferenceRecord.defaultTerminalTheme;
      _terminalShortcutsPreference = null;
      _terminalShortcutBindings = TerminalShortcutBindings.defaults;
      for (final action in TerminalShortcutAction.values) {
        _terminalShortcutControllers[action]!.text = TerminalShortcutBindings
            .defaults
            .chordFor(action);
      }
      _preferenceLoadError = null;
      _workspace = _LocalWorkspace.hosts;
    });
    try {
      if (profile != null) {
        await _disposeSession(profile, database);
      } else if (database != null) {
        await database.close();
      }
      if (!_isCurrentOperation(generation)) return;
      await widget.onExit();
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.couldntExitTheLocalProfileSafely);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<Uint8List?> _pickLocalArchive() async {
    final injected = widget.archivePicker;
    if (injected != null) {
      final bytes = await injected();
      if (bytes != null &&
          bytes.length > LocalProfileArchiveCodec.maxContainerBytes) {
        bytes.fillRange(0, bytes.length, 0);
        _showMessage(currentL10n.theLocalArchiveFileExceedsThe);
        return null;
      }
      return bytes;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['atlocal'],
      allowMultiple: false,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    if (file.size > LocalProfileArchiveCodec.maxContainerBytes) {
      final oversizedBytes = file.bytes;
      if (oversizedBytes != null) {
        oversizedBytes.fillRange(0, oversizedBytes.length, 0);
      }
      _showMessage(currentL10n.theLocalArchiveFileExceedsThe);
      return null;
    }
    final bytes = file.bytes;
    if (bytes == null ||
        bytes.length != file.size ||
        bytes.length > LocalProfileArchiveCodec.maxContainerBytes) {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      _showMessage(currentL10n.theLocalArchiveFileIsInvalid);
      return null;
    }
    return bytes;
  }

  Future<bool> _saveLocalArchive(Uint8List bytes) async {
    final injected = widget.archiveSaver;
    if (injected != null) return injected(bytes);
    return saveAttachmentFile(
      fileName: 'atermius-local-profile.atlocal',
      mediaType: 'application/octet-stream',
      bytes: bytes,
    );
  }

  Future<String?> _askLocalArchivePassword({
    required bool confirm,
    required bool creating,
  }) => showAppDialog<String>(
    context: context,
    builder: (_) =>
        _LocalArchivePasswordDialog(confirm: confirm, creating: creating),
  );

  Future<void> _exportLocalArchive() async {
    final repository = _repository;
    if (repository == null || _busy) return;
    final password = await _askLocalArchivePassword(
      confirm: true,
      creating: true,
    );
    if (password == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    Uint8List? bytes;
    try {
      final archive = LocalProfileArchiveService(widget.crypto.sodium);
      bytes = await archive.export(repository: repository, password: password);
      final saved = await _saveLocalArchive(bytes);
      if (_isCurrentOperation(generation)) {
        _showMessage(saved ? currentL10n.localEncryptedArchiveSaved : currentL10n.savingTheLocalEncryptedArchiveWas);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.couldntExportTheLocalProfileTry);
      }
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      _finishOperation(generation);
    }
  }

  Future<void> _importLocalArchive() async {
    final repository = _repository;
    if (repository == null || _busy) return;
    try {
      if (!await repository.isEmptyForArchiveImport()) {
        _showMessage(currentL10n.createAnEmptyLocalProfileFirst);
        return;
      }
    } on Object {
      _showMessage(currentL10n.couldntConfirmThatTheTargetProfile);
      return;
    }
    Uint8List? container;
    try {
      container = await _pickLocalArchive();
    } on Object {
      _showMessage(currentL10n.couldntReadTheLocalArchiveFile);
      return;
    }
    if (container == null) return;
    if (!mounted) {
      container.fillRange(0, container.length, 0);
      return;
    }
    final password = await _askLocalArchivePassword(
      confirm: false,
      creating: false,
    );
    if (password == null || !mounted) {
      container.fillRange(0, container.length, 0);
      return;
    }
    final generation = _beginOperation();
    if (generation < 0) {
      container.fillRange(0, container.length, 0);
      return;
    }
    try {
      final archive = LocalProfileArchiveService(widget.crypto.sodium);
      final snapshot = await archive.stageImport(
        container: container,
        password: password,
      );
      await archive.importIntoEmptyProfile(
        repository: repository,
        snapshot: snapshot,
      );
      if (!_isCurrentOperation(generation)) return;
      final hostsLoaded = await _reloadHosts(generation);
      final credentialsLoaded = await _reloadCredentials(generation);
      final groupsLoaded = await _reloadGroups(generation);
      final snippetsLoaded = await _reloadSnippets(generation);
      final preferenceLoaded = await _reloadDefaultSectionPreference(
        generation,
      );
      if (!_isCurrentOperation(generation)) return;
      setState(() {
        if (preferenceLoaded) {
          _workspace = _defaultSectionChoice;
        }
      });
      _showMessage(
        hostsLoaded &&
                credentialsLoaded &&
                groupsLoaded &&
                snippetsLoaded &&
                preferenceLoaded
            ? currentL10n.theLocalEncryptedArchiveWasImported
            : currentL10n.theArchiveWasImportedButSome,
      );
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.couldntImportTheLocalArchiveNothing);
      }
    } finally {
      container.fillRange(0, container.length, 0);
      _finishOperation(generation);
    }
  }

  Future<void> _disposeSession(
    UnlockedLocalProfile profile,
    LocalVaultDatabase? database,
  ) async {
    Object? failure;
    await _closeLocalConnections();
    // Closed tabs finished their log rows; persist them before the profile
    // lease ends, then drop every decrypted row from memory.
    final logs = _sessionLogBooks[profile];
    _sessionLogBooks[profile] = null;
    if (logs != null) {
      try {
        await logs.close().timeout(const Duration(seconds: 5));
      } on Object {
        // Logs are best effort; never block locking the profile.
      }
      logs.dispose();
    }
    try {
      // The repository holds an identity lease for each whole operation.
      // Lock first so the database is not closed under an in-flight write.
      await profile.lock();
    } on Object catch (error) {
      failure = error;
    }
    try {
      await database?.close();
    } on Object catch (error) {
      failure ??= error;
    }
    if (failure is DatabaseRecoveryRequiredException) throw failure;
    if (failure != null) throw StateError(currentL10n.localProfileCleanupFailed);
  }

  Future<void> _addHost([HostProtocol protocol = HostProtocol.ssh]) async {
    final openedRepository = _repository, openedProfile = _activeProfile;
    final draft = await _showHostEditor(
      groups: _groups,
      initialProtocol: protocol,
    );
    // Never save into a Profile other than the one the editor opened for.
    if (draft == null ||
        !mounted ||
        !identical(openedRepository, _repository) ||
        !identical(openedProfile, _activeProfile)) {
      return;
    }
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.createHost(draft);
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadHosts(generation)) {
        _showMessage(currentL10n.theHostWasSavedButThe);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theHostSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _editHost(HostRecord host) async {
    final edited = await _showHostEditor(existing: host, groups: _groups);
    if (edited == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      final baseRevision = host.revisionId;
      if (repository == null || baseRevision == null) {
        throw StateError(context.l10n.localHostRevisionIsMissing);
      }
      await repository.updateHost(host: edited, baseRevisionId: baseRevision);
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadHosts(generation)) {
        _showMessage(currentL10n.theHostWasUpdatedButThe);
      }
    } on LocalHostConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theHostWasChangedByAnother);
        await _reloadHosts(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) _showMessage(currentL10n.couldntUpdateTheHostTryAgain);
    } finally {
      _finishOperation(generation);
    }
  }

  /// Live SSH sessions of [host] in this window. Forwards run on exactly one
  /// connection, so Home can only start them when that choice is unambiguous.
  _LocalTerminalSession? _uniqueLiveSessionFor(HostRecord host) {
    final live = _sessions
        .where(
          (session) =>
              session.host.id == host.id &&
              session.connection != null &&
              !session._closed,
        )
        .toList(growable: false);
    return live.length == 1 ? live.single : null;
  }

  /// Opens the shared forwarding dialog bound to [host] in the local profile
  /// and repository that are active now. Profiles are stored in the existing
  /// encrypted local Host record; no other store holds forwarding data.
  Future<void> _openPortForwarding(
    HostRecord host, {
    _LocalTerminalSession? session,
  }) async {
    final repository = _repository;
    final profileId = _activeProfile?.record.profileId;
    if (repository == null ||
        profileId == null ||
        host.protocol != HostProtocol.ssh ||
        _storageRecoveryRequired) {
      return;
    }
    final hostId = host.id;
    bool inScope() =>
        mounted &&
        !_storageRecoveryRequired &&
        identical(_repository, repository) &&
        _activeProfile?.record.profileId == profileId;
    await showSshPortForwardingDialog(
      context,
      hostName: host.name,
      changes: _portForwardChanges,
      storageDescription:
          context.l10n.profilesAreEncryptedInsideThisHost2,
      profiles: () => inScope()
          ? _hosts
                .where((candidate) => candidate.id == hostId)
                .firstOrNull
                ?.portForwardProfiles
          : null,
      saveProfiles: (profiles) =>
          _saveHostPortForwardProfiles(repository, hostId, profiles, inScope),
      manager: () {
        final live = session;
        if (live == null || live._closed || !inScope()) return null;
        return live.connection?.portForwards;
      },
      canEdit: inScope,
      disconnectedNote: session == null
          ? context.l10n.notStartedFromASingleConnected
          : null,
      describeSaveError: (error) => error is LocalHostConflictException
          ? context.l10n.thisHostChangedInAnotherOperation
          : context.l10n.couldNotSaveForwardingSettingsNothing,
    );
    // Menu labels show the running count; refresh them after the dialog.
    if (mounted) setState(() {});
  }

  Future<void> _saveHostPortForwardProfiles(
    LocalHostRepository repository,
    String hostId,
    List<SshPortForwardProfile> profiles,
    bool Function() inScope,
  ) => _updateHostPortForwardProfiles(
    repository,
    hostId,
    (_) => profiles,
    inScope,
  );

  /// Writes `change(current rules)` onto the Host read inside the operation,
  /// with the repository's revision CAS ([LocalHostConflictException]).
  Future<void> _updateHostPortForwardProfiles(
    LocalHostRepository repository,
    String hostId,
    List<SshPortForwardProfile> Function(List<SshPortForwardProfile> current)
    change,
    bool Function() inScope,
  ) async {
    if (!inScope()) throw StateError(context.l10n.theLocalProfileChanged);
    final generation = _beginOperation();
    if (generation < 0) {
      throw StateError(context.l10n.anotherOperationIsRunningRetryWhen);
    }
    try {
      final current = _hosts
          .where((candidate) => candidate.id == hostId)
          .firstOrNull;
      final baseRevision = current?.revisionId;
      if (current == null || baseRevision == null) {
        throw StateError(context.l10n.localHostRevisionIsMissing);
      }
      try {
        await repository.updateHost(
          host: current.copyWith(
            portForwardProfiles: change(current.portForwardProfiles),
          ),
          baseRevisionId: baseRevision,
        );
      } on LocalHostConflictException {
        if (_isCurrentOperation(generation)) await _reloadHosts(generation);
        rethrow;
      }
      if (!_isCurrentOperation(generation) ||
          !await _reloadHosts(generation)) {
        throw StateError('Saved, but the Host list could not be refreshed.');
      }
    } finally {
      _finishOperation(generation);
      _portForwardChanges.fire();
    }
  }

  /// The forwarding scope (repository/profile lifetime) changed: pending
  /// connect-and-start requests are dropped even while the page is hidden.
  void _notifyForwardingScopeChanged() {
    // Never notify MCP listeners from inside this State's setState callback.
    scheduleMicrotask(McpService.instance.workspaceChanged);
    if (!_disposing && mounted) _portForwardChanges.fire();
  }

  Object? _sshForwardingScopeKey() =>
      (_repository, _activeProfile, _storageRecoveryRequired);

  /// Adapter for the shared Home "SSH Forwarding" page. Every closure reads
  /// the current profile, repository, Hosts and sessions when it runs, so a
  /// pending connect-and-start re-validates against live state. Rules stay in
  /// the encrypted local Host records; connections use [_connectLocalHost]
  /// (credential resolution and known-host approval included).
  SshForwardingSource _createSshForwardingSource() =>
      CallbackSshForwardingSource(
        // Object identities: a re-unlocked profile or rebuilt repository is a
        // new scope even with the same profile id (A -> B -> A).
        scopeKey: _sshForwardingScopeKey,
        hosts: () =>
            _repository == null ||
                _activeProfile == null ||
                _storageRecoveryRequired
            ? const []
            : _hosts,
        sessions: () {
          final perHost = <String, int>{};
          return [
            for (final session in _sessions)
              if (!session._closed &&
                  session.connection != null &&
                  session.host.protocol == HostProtocol.ssh)
                SshForwardingSessionInfo(
                  id: session.id,
                  hostId: session.host.id,
                  label: currentL10n.r7ForwardSessionLabel(
                    session.host.name,
                    perHost[session.host.id] =
                        (perHost[session.host.id] ?? 0) + 1,
                  ),
                  phase: session.connected.value
                      ? SshForwardingSessionPhase.connected
                      : SshForwardingSessionPhase.disconnected,
                  manager: session.connection!.portForwards,
                ),
          ];
        },
        saveRule: (hostId, expected, replacement, scope) {
          final repository = _repository;
          if (repository == null ||
              _activeProfile == null ||
              _storageRecoveryRequired ||
              _sshForwardingScopeKey() != scope) {
            throw StateError(currentL10n.theLocalProfileChanged);
          }
          bool inScope() =>
              mounted &&
              !_disposing &&
              _sshForwardingScopeKey() == scope;
          return _updateHostPortForwardProfiles(
            repository,
            hostId,
            (current) => applySshPortForwardRuleChange(
              current,
              expected: expected,
              replacement: replacement,
            ),
            inScope,
          );
        },
        connect: (host) async {
          if (kIsWeb || _storageRecoveryRequired) return null;
          _LocalTerminalSession? opened;
          await _connectLocalHost(
            host,
            onSessionOpened: (session) => opened = session,
          );
          final session = opened;
          return session != null &&
                  !session._closed &&
                  session.connection != null &&
                  session.connected.value &&
                  _sessions.contains(session)
              ? session.id
              : null;
        },
        storageDescription: currentL10n.profilesAreEncryptedInsideThisHost2,
        storageDescriptionGetter: () =>
            currentL10n.profilesAreEncryptedInsideThisHost2,
        changes: _portForwardChanges,
        canEdit: () =>
            mounted &&
            _repository != null &&
            _activeProfile != null &&
            !_storageRecoveryRequired,
        describeSaveError: (error) => error is LocalHostConflictException
            ? currentL10n.thisHostChangedInAnotherOperation
            : currentL10n.couldNotSaveForwardingSettingsNothing,
        showSession: _selectTerminalTab,
      );

  /// Body of the Home sidebar "SSH Forwarding" destination (wired by the
  /// navigation branch).
  // ignore: unused_element (embedded by the navigation branch's Home sidebar)
  Widget _buildSshForwardingPage({String? initialHostId}) => SshForwardingPage(
    source: _sshForwardingSource,
    controller: _sshForwardingController,
    initialHostId: initialHostId,
  );

  Future<void> _deleteHost(HostRecord host) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteHost),
        content: Text(context.l10n.nameWillBeDeletedFromThis(host.name)),
        actions: [
          TextButton(
            key: const ValueKey('local_host_delete_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('local_host_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      final baseRevision = host.revisionId;
      if (repository == null || baseRevision == null) {
        throw StateError(context.l10n.localHostRevisionIsMissing);
      }
      await repository.deleteHost(
        recordId: host.id,
        baseRevisionId: baseRevision,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadHosts(generation)) {
        _showMessage(currentL10n.theHostWasDeletedButThe);
      }
    } on LocalHostConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theHostWasChangedByAnother);
        await _reloadHosts(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) _showMessage(currentL10n.couldntDeleteTheHostTryAgain);
    } finally {
      _finishOperation(generation);
    }
  }

  void _addDeviceSession(_LocalTerminalSession session) {
    _installLocalRecovery(session);
    session.connected.addListener(_onSessionChanged);
    setState(() {
      _sessions.add(session);
      _selectedTabId = session.id;
      _layout.activate(session.id);
    });
    session.recovery?.update(connected: session.connected.value,
      connecting: session.telnetState == 'connecting' || session.desktop?.state == 'connecting');
  }

  void _installLocalRecovery(_LocalTerminalSession session) {
    if (session.recovery != null || session.console != null) return;
    final profile = _activeProfile, repository = _repository;
    final saved = _hosts.any((h) => h.id == session.host.id);
    bool current() => mounted && !_disposing &&
        identical(_activeProfile, profile) && identical(_repository, repository) &&
        _sessions.contains(session) && !session._closed &&
        (!saved || _hosts.any((h) => h.id == session.host.id));
    session.recovery = SessionRecovery(
      automatic: session.host.protocol.isTerminal,
      isCurrent: current,
      reconnect: () async {
        if (!current() || _busy) return;
        final host = _hosts.where((h) => h.id == session.host.id).firstOrNull ?? session.host;
        await _connectLocalHost(host, reuseSession: session, shouldContinue: current);
        if (current()) session.recovery?.update(connected: session.connected.value,
          connecting: session.telnetState == 'connecting');
      },
    );
  }

  /// Starts a local shell ([shell], default system shell) or a serial console
  /// ([serialPort]) and returns the new session id, or null on failure.
  Future<String?> _openConsole({
    String? serialPort,
    int baudRate = 115200,
    LocalShellLaunch? shell,
  }) async {
    final opener = localProfileConsoleOpenerForTesting;
    if (_activeProfile == null ||
        _busy ||
        _disposing ||
        (!localConsoleSupported && opener == null)) {
      if (!localConsoleSupported && opener == null && mounted) {
        unawaited(showLocalShellUnavailable(context));
      }
      return null;
    }
    final launch = serialPort == null
        ? shell ?? LocalShellLaunch.systemDefault
        : null;
    try {
      final console = opener != null
          ? opener(shell: launch, serialPort: serialPort, baudRate: baudRate)
          : serialPort == null
          ? openLocalConsole(launch: launch!)
          : openSerialConsole(serialPort, baudRate: baudRate);
      if (!mounted || _disposing) {
        unawaited(console.close().catchError((Object _) {}));
        return null;
      }
      final session = _LocalTerminalSession.console(
        console,
        title: serialPort == null
            ? localShellTabTitle(context.l10n, launch!)
            : '$serialPort · $baudRate',
        serialPort: serialPort,
        baudRate: serialPort == null ? null : baudRate,
        shell: launch,
      );
      _addDeviceSession(session);
      return session.id;
    } on LocalShellException catch (error) {
      _showMessage(localShellIssueMessage(context.l10n, error.issue));
    } catch (error) {
      _showMessage(
        error is UnsupportedError
            ? error.message ?? context.l10n.thisConsoleIsntSupportedOnThis
            : context.l10n.couldntStartTheConsole,
      );
    }
    return null;
  }

  /// Independent copy of a Console session: serial stays serial (same port and
  /// baud), a shell keeps its kind and current/launch working directory.
  Future<String?> _duplicateConsole(_LocalTerminalSession source) async {
    final serialPort = source.consoleSerialPort;
    if (serialPort != null) {
      return _openConsole(
        serialPort: serialPort,
        baudRate: source.consoleBaudRate ?? 115200,
      );
    }
    var launch = source.consoleShell ?? LocalShellLaunch.systemDefault;
    if (source.console case final LocalConsoleWorkingDirectory probe) {
      final cwd = await probe
          .currentWorkingDirectory()
          .timeout(const Duration(seconds: 1), onTimeout: () => null)
          .catchError((Object _) => null);
      if (cwd != null && isPlausibleLocalShellWorkingDirectory(cwd)) {
        launch = launch.copyWith(workingDirectory: cwd);
      }
    }
    if (!mounted || _disposing || !_sessions.contains(source)) return null;
    return _openConsole(shell: launch);
  }

  VoidCallback? _dismissHostSearch;
  bool _hostSearchOpen = false;
  void _cancelHostSearch() {
    final dismiss = _dismissHostSearch;
    _dismissHostSearch = null;
    if (dismiss != null)
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
  }

  Future<void> _openHostSearch() async {
    final profile = _activeProfile;
    if (profile == null || _hostSearchOpen || _busy || _quickConnectBusy)
      return;
    _hostSearchOpen = true;
    try {
      final result = await showHostSearchPalette(
        context,
        hosts: () => _hosts,
        groups: hostSearchGroupLabels(_groups.map((entry) => entry.group)),
        fieldKey: const ValueKey('local_host_search'),
        isCurrent: () => mounted && identical(profile, _activeProfile),
        onDismissChanged: (dismiss) => _dismissHostSearch = dismiss,
      );
      if (!mounted || !identical(profile, _activeProfile) || result == null)
        return;
      if (result.command case final command?) {
        await _quickConnect(command);
      } else {
        final host = _hosts
            .where((host) => host.id == result.hostId)
            .firstOrNull;
        if (host != null) await _connectLocalHost(host);
      }
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
    if (_busy || kIsWeb) return;
    if (command.isConsole) {
      await _openConsole(
        serialPort: command.kind == QuickConnectKind.serial
            ? command.address
            : null,
        baudRate: command.baudRate,
      );
      return;
    }
    final matchingProfile = _activeProfile;
    final matches = _hosts.where(command.matches).toList();
    if (matches.isNotEmpty) {
      final host = await chooseQuickConnectHost(context, matches);
      if (host != null && mounted && identical(matchingProfile, _activeProfile))
        await _connectLocalHost(host);
      return;
    }
    final repository = _repository, profile = _activeProfile;
    if (repository == null || profile == null) return;
    final draft = await _showHostEditor(
      initialDraft: command.draft(const Uuid().v4()),
      submitLabel: context.l10n.saveAndConnect,
      groups: _groups,
    );
    if (draft == null ||
        !mounted ||
        !identical(repository, _repository) ||
        !identical(profile, _activeProfile))
      return;
    final generation = _beginOperation();
    if (generation < 0) return;
    HostRecord? saved;
    try {
      saved = await repository.createHost(draft);
      if (_isCurrentOperation(generation)) await _reloadHosts(generation);
    } catch (_) {
      if (mounted) _showMessage(context.l10n.couldntSaveTheHostCheckThe);
    } finally {
      _finishOperation(generation);
    }
    if (saved != null &&
        mounted &&
        identical(repository, _repository) &&
        identical(profile, _activeProfile)) {
      await _connectLocalHost(saved);
    }
  }

  Future<void> _connectLocalHost(
    HostRecord host, {
    bool Function()? shouldContinue,
    void Function(_LocalTerminalSession session)? onSessionOpened,
    _LocalTerminalSession? reuseSession,
  }) async {
    if (kIsWeb) {
      // A browser LocalVault has no authenticated Relay and cannot open raw
      // TCP; say so instead of silently doing nothing.
      if (host.protocol == HostProtocol.telnet && mounted) {
        _showMessage(context.l10n.telnetUnsupportedInBrowser);
      }
      return;
    }
    if (host.protocol == HostProtocol.telnet) {
      if (_activeProfile == null || _busy) return;
      final issue = host.validate();
      if (issue != null) {
        _showMessage(issue);
        return;
      }
      // Plaintext, interactive login: no credential is resolved or sent.
      if (reuseSession != null) {
        reuseSession.host = host;
        reuseSession.telnetState = 'connecting';
        reuseSession.telnetError = null;
        final cancellation = TelnetConnectCancellation();
        reuseSession._telnetCancellation = cancellation;
        await reuseSession._connectTelnet(localTelnetConnector, cancellation);
        return;
      }
      final tab = _LocalTerminalSession.telnet(
        host,
        connector: localTelnetConnector,
        log: _sessionLogs?.begin(host: host, viaJump: false),
        onStateChanged: () {
          if (mounted && !_disposing) _onSessionChanged();
        },
      );
      _addDeviceSession(tab);
      onSessionOpened?.call(tab);
      await tab.telnetReady;
      return;
    }
    if (host.protocol != HostProtocol.ssh) {
      if (reuseSession != null) {
        await reuseSession.desktop?.reconnect();
        return;
      }
      if (_activeProfile == null || _busy) return;
      final repository = _repository;
      final profile = _activeProfile;
      if (repository == null) return;
      late final _LocalTerminalSession tab;
      bool current() =>
          mounted &&
          !_disposing &&
          identical(_activeProfile, profile) &&
          identical(_repository, repository) &&
          _sessions.contains(tab);
      void adoptSavedHost(HostRecord saved) {
        if (!current()) throw StateError(context.l10n.theWorkspaceChanged);
        setState(() {
          tab.host = saved;
          _hosts = [
            for (final h in _hosts)
              if (h.id == saved.id) saved else h,
          ];
        });
      }

      final desktop = DesktopSession(
        reconnectAllowed: current,
        saveRdpCertificate: (reviewed, pin) async {
          final saved = await RdpCertificatePersistence.saveLocal(
            repository: repository,
            reviewed: reviewed,
            pin: pin,
            isCurrent: current,
          );
          adoptSavedHost(saved);
          return saved;
        },
        // In-session resolution/scaling changes persist on top of the current
        // Host revision; a changed scope or Host keeps them session-only.
        saveDisplaySettings: (updated) async {
          final saved = await DesktopDisplayPersistence.saveLocal(
            repository: repository,
            updated: updated,
            isCurrent: current,
          );
          adoptSavedHost(saved);
          return saved;
        },
      );
      tab = _LocalTerminalSession.desktop(host, desktop);
      _addDeviceSession(tab);
      await desktop.connectLocal(host);
      return;
    }
    final repository = _repository;
    if (repository == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    SshConnection? connection;
    // Sanitized lifecycle row: categories only, never credential material.
    SessionLogRecorder? log = _sessionLogs?.begin(
      host: host,
      viaJump: host.jumpHostId != null,
    );
    try {
      final credential = await repository.resolveCredentialForHost(host);
      if (shouldContinue?.call() == false) return;
      if (credential == null) {
        log?.markFailed(const SshCredentialException());
        _finishOperation(generation);
        if (mounted) await _editHost(host);
        return;
      }
      final sshController =
          widget.sshControllerFactory?.call(repository) ??
          LocalProfileSshController(repository: repository);
      connection = await sshController.connect(
        host: host,
        credential: credential,
        askApproval: (request) async => shouldContinue?.call() == false
            ? false
            : _confirmLocalHostKey(request),
      );
      if (!_isCurrentOperation(generation) || shouldContinue?.call() == false) {
        return;
      }
      if (!mounted) return;
      log?.markConnected();
      final session = reuseSession ?? _LocalTerminalSession(
        host: host, connection: connection, log: log);
      if (reuseSession != null) {
        await session.attachSsh(connection, log);
        session.host = host;
      }
      log = null; // The tab now owns the log row.
      if (reuseSession == null) _addDeviceSession(session);
      unawaited(
        _observeHostOperatingSystem(session, repository, _activeProfile),
      );
      connection = null; // The tab now owns the connection.
      onSessionOpened?.call(session);
    } on SshHostKeyVerificationException catch (error) {
      reuseSession?.recovery?.blockAutomatic();
      log?.markFailed(error);
      if (_isCurrentOperation(generation)) {
        setState(() {
          _pageError = error.failure == SshHostKeyFailure.changed
              ? context.l10n.theSshHostKeyChangedOr
              : context.l10n.theSshHostKeyWasntApproved;
        });
      }
    } on UnsupportedError catch (error) {
      log?.markFailed(error);
      if (_isCurrentOperation(generation)) {
        setState(
          () => _pageError = error.message ?? context.l10n.thisLocalvaultSshRouteIsntSupported,
        );
      }
    } on Object catch (error) {
      log?.markFailed(error);
      if (_isCurrentOperation(generation)) {
        setState(() => _pageError = context.l10n.couldntConnectToTheLocalSsh);
      }
    } finally {
      // Abandoned (scope changed / cancelled) before a tab took ownership.
      log?.markClosed(SessionLogEndReason.user);
      if (connection != null) await connection.close();
      _finishOperation(generation);
    }
  }

  Future<void> _observeHostOperatingSystem(
    _LocalTerminalSession session,
    LocalHostRepository repository,
    UnlockedLocalProfile? profile,
  ) async {
    bool current() =>
        mounted &&
        !_disposing &&
        identical(_activeProfile, profile) &&
        identical(_repository, repository) &&
        _sessions.contains(session) &&
        session.connected.value;
    final connection = session.connection;
    if (connection == null) return;
    try {
      final observation = await HostOperatingSystemProbe().detect(connection);
      final updated = await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: session.host,
        observation: observation,
        isCurrentConnection: current,
      );
      if (updated != null && current()) {
        setState(
          () => _hosts = [
            for (final host in _hosts)
              if (host.id == updated.id) updated else host,
          ],
        );
      }
    } on Object {
      /* Optional metadata never interrupts the SSH workspace. */
    }
  }

  Future<bool> _confirmLocalHostKey(
    LocalKnownHostApprovalRequest request,
  ) async =>
      await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            request.previouslyRevoked ? context.l10n.thisHostKeyWasRevokedBefore : context.l10n.firstConnectionUnknownSshHostKey,
          ),
          content: SelectableText(
            context.l10n.targetHostPortAlgorithmAlgorithmFingerprint(request.host, request.port, request.algorithm, request.fingerprint, request.previouslyRevoked ? context.l10n.thisKeyWasRevokedBeforeOnly : context.l10n.verifyThisFingerprintOverATrusted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.reject),
            ),
            FilledButton(
              key: const ValueKey('local_ssh_host_key_approve'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.l10n.verifyAndTrustThisKey),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _manageLocalKnownHosts() async {
    final repository = _repository;
    if (repository == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      var records = await repository.listKnownHosts();
      var candidates = await repository.listImportedKnownHostCandidates();
      if (!_isCurrentOperation(generation)) return;
      if (!mounted) return;
      var dialogError = '';
      await showAppDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(context.l10n.localvaultHostKeyTrust),
            content: SizedBox(
              width: appDialogWidth(context, 560),
              height: 360,
              child: Column(
                children: [
                  if (dialogError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        dialogError,
                        style: TextStyle(color: context.palette.red),
                      ),
                    ),
                  Expanded(
                    child: records.isEmpty && candidates.isEmpty
                        ? Center(
                            child: Text(context.l10n.thisLocalvaultHasNoSshHost),
                          )
                        : ListView.separated(
                            itemCount: candidates.length + records.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              if (index < candidates.length) {
                                final candidate = candidates[index];
                                final record = candidate.record;
                                return ListTile(
                                  key: ValueKey(
                                    'local-known-host-import-${record.id}',
                                  ),
                                  leading: const Icon(
                                    Icons.rate_review_outlined,
                                  ),
                                  title: Text(
                                    context.l10n.hostPortPendingReview(record.host, record.port),
                                  ),
                                  subtitle: SelectableText(
                                    context.l10n.algorithmFingerprintOriginallyApprovedInArchive(record.algorithm, record.fingerprint, record.approvedAt.toLocal()),
                                  ),
                                  trailing: TextButton(
                                    key: ValueKey(
                                      'local-known-host-review-${record.id}',
                                    ),
                                    onPressed: () async {
                                      final confirmed = await showAppDialog<bool>(
                                        context: context,
                                        builder: (confirmContext) => AlertDialog(
                                          title: Text(context.l10n.reviewSshHostKeysFromThe),
                                          content: SelectableText(
                                            context.l10n.onlyContinueAfterVerifyingTheFingerprint(record.host, record.port, record.algorithm, record.fingerprint),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(
                                                confirmContext,
                                                false,
                                              ),
                                              child: Text(context.l10n.cancel),
                                            ),
                                            FilledButton(
                                              key: ValueKey(
                                                'local-known-host-confirm-${record.id}',
                                              ),
                                              onPressed: () => Navigator.pop(
                                                confirmContext,
                                                true,
                                              ),
                                              child: Text(context.l10n.confirmTrustingThisKey),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true) return;
                                      try {
                                        await repository
                                            .approveImportedKnownHost(
                                              candidateId: record.id,
                                              explicitlyConfirmed: true,
                                            );
                                        final updatedRecords = await repository
                                            .listKnownHosts();
                                        final updatedCandidates = await repository
                                            .listImportedKnownHostCandidates();
                                        if (dialogContext.mounted) {
                                          setDialogState(() {
                                            records = updatedRecords;
                                            candidates = updatedCandidates;
                                            dialogError = '';
                                          });
                                        }
                                      } on Object {
                                        if (dialogContext.mounted) {
                                          setDialogState(() {
                                            dialogError = context.l10n.trustReviewFailedTheExistingSsh;
                                          });
                                        }
                                      }
                                    },
                                    child: Text(context.l10n.reviewAndTrust),
                                  ),
                                );
                              }
                              final record = records[index - candidates.length];
                              final trusted =
                                  record.state == KnownHostState.trusted;
                              return ListTile(
                                title: Text('${record.host}:${record.port}'),
                                subtitle: SelectableText(
                                  '${record.algorithm}\n${record.fingerprint}\n${trusted ? context.l10n.trusted : context.l10n.revoked}',
                                ),
                                trailing: trusted
                                    ? IconButton(
                                        tooltip: context.l10n.revokeTrustForThisKey,
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                        ),
                                        onPressed: () async {
                                          final confirmed =
                                              await showAppDialog<bool>(
                                                context: context,
                                                builder: (confirmContext) =>
                                                    AlertDialog(
                                                      title: Text(
                                                        context.l10n.revokeSshHostKeyTrust,
                                                      ),
                                                      content: Text(
                                                        context.l10n.afterRevokingThisKeyForHost(record.host, record.port),
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                confirmContext,
                                                                false,
                                                              ),
                                                          child: Text(
                                                            context.l10n.cancel,
                                                          ),
                                                        ),
                                                        FilledButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                confirmContext,
                                                                true,
                                                              ),
                                                          child: Text(
                                                            context.l10n.revokeTrust,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                              );
                                          if (confirmed != true) return;
                                          try {
                                            await repository.revokeKnownHost(
                                              recordId: record.id,
                                            );
                                            final updated = await repository
                                                .listKnownHosts();
                                            if (dialogContext.mounted) {
                                              setDialogState(() {
                                                records = updated;
                                                dialogError = '';
                                              });
                                            }
                                          } on Object {
                                            if (dialogContext.mounted) {
                                              setDialogState(() {
                                                dialogError =
                                                    context.l10n.revokingFailedTheTrustStateIs;
                                              });
                                            }
                                          }
                                        },
                                      )
                                    : const Icon(Icons.block_outlined),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.done),
              ),
            ],
          ),
        ),
      );
    } on Object {
      if (_isCurrentOperation(generation)) {
        setState(() => _pageError = context.l10n.couldntReadLocalSshHostKey);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<HostRecord?> _showHostEditor({
    HostRecord? existing,
    HostRecord? initialDraft,
    String? submitLabel,
    HostProtocol initialProtocol = HostProtocol.ssh,
    required List<LocalGroupRecord> groups,
  }) async {
    CredentialRecord? credential;
    if (existing != null) {
      try {
        credential = await _repository?.resolveCredentialForHost(existing);
      } on Object {
        if (mounted) _showMessage(context.l10n.couldntReadThisHostsSignIn);
        return null;
      }
    }
    if (!mounted) return null;
    return showHostEditorPanel(
      context,
      keyPrefix: 'local_host',
      initialProtocol: initialProtocol,
      existing: existing,
      initialDraft: initialDraft,
      submitLabel: submitLabel,
      groups: groups.map((entry) => entry.group).toList(),
      hosts: _hosts,
      initialCredential: credential,
      keychain: [
        for (final item in _credentials)
          HostKeychainChoice(
            id: item.id,
            label: '${item.name} (${item.username})',
          ),
      ],
    );
  }

  void _onSessionChanged() {
    for (final session in _sessions) {
      session.recovery?.update(connected: session.connected.value,
        connecting: session.telnetState == 'connecting' ||
          session.desktop?.state == 'connecting' || session.desktop?.state == 'certificate');
    }
    _files.retainConnections({
      for (final session in _sessions)
        if (session.connected.value && session.connection != null)
          session.id: session.connection!,
    });
    if (!_disposing) {
      final liveIds = {
        ..._visibleSessions.map((session) => session.id),
        ..._files.entries.map((entry) => entry.id),
      };
      for (final id in {
        ..._layout.sessionIds,
        ..._layout.groupedSessionIds.expand((ids) => ids),
      }.toList()) {
        if (!liveIds.contains(id)) _layout.remove(id);
      }
      if (_selectedTabId != 'hosts' && !liveIds.contains(_selectedTabId)) {
        _selectedTabId = _layout.selectedId ?? liveIds.lastOrNull ?? 'hosts';
        if (_selectedTabId != 'hosts') _layout.activate(_selectedTabId);
      }
    }
    if (mounted && !_disposing) setState(() {});
  }

  Future<void> _closeLocalConnections() async {
    await TrackedFilesWindows.instance.releaseOwner(_windowOwner);
    _groupConnectionGeneration++;
    await _files.closeAll();
    await ApplicationWindows.instance.closeOwner(_windowOwner);
    final closing = List<_LocalTerminalSession>.of(_sessions);
    _sessions.clear();
    _detached.clear();
    _selectedTabId = 'hosts';
    // During dispose the layout is already disposed; touching it would throw
    // and skip closing the sessions below (leaking PTYs/SSH connections).
    if (!_disposing) _layout.restore(null);
    for (final session in closing) {
      session.connected.removeListener(_onSessionChanged);
      if (!_disposing) _layout.remove(session.id);
    }
    await Future.wait(closing.map((session) => session.close()));
  }

  Future<void> _closeTerminalSession(String id) async {
    if (_files.find(id) != null) {
      await _files.close(id);
      return;
    }
    await _files.closeSource(id);
    final session = _sessions.where((entry) => entry.id == id).firstOrNull;
    if (session == null) return;
    if (session.desktop != null) {
      // Main and per-monitor renderers end before the RDP/VNC session.
      await DesktopTabWindows.closeAll(
        windows: ApplicationWindows.instance,
        owner: _windowOwner,
        tabId: id,
      );
    } else {
      await ApplicationWindows.instance.closeSession(_windowOwner, id);
    }
    session.connected.removeListener(_onSessionChanged);
    if (mounted && !_disposing) {
      setState(() {
        _sessions.remove(session);
        _detached.remove(id);
        _layout.remove(id);
        if (_selectedTabId == id) {
          _selectedTabId =
              _layout.selectedId ?? _visibleSessions.lastOrNull?.id ?? 'hosts';
          if (_selectedTabId != 'hosts') _layout.activate(_selectedTabId);
        }
      });
    } else {
      _sessions.remove(session);
      _detached.remove(id);
    }
    await session.close();
  }

  void _closeTerminalTab(String id) {
    unawaited(_closeTerminalSession(id).catchError((Object _) {}));
  }

  void _unsplitTerminalTab(String id) {
    if (!_layout.unsplit(id)) return;
    final survivor = _layout.selectedId;
    if (survivor != null) _selectTerminalTab(survivor);
    if (mounted) setState(() {});
  }

  void _selectTerminalTab(String id) {
    if (!mounted || _disposing) return;
    setState(() {
      _selectedTabId = id;
      if (id == 'hosts') {
        _workspace = _LocalWorkspace.hosts;
      } else if (_visibleSessions.any((s) => s.id == id) ||
          _files.find(id) != null) {
        _layout.activate(id);
      }
    });
  }

  void _reorderTerminalTabs(String id, String? beforeId) {
    setState(() => _tabOrder.move(id, beforeId));
  }

  Future<void> _duplicateWorkspaceTab(String id) async {
    final file = _files.find(id);
    if (file != null) {
      if (file.controller.isClosed) return;
      final copy = _files.open(
        sourceSessionId: file.sourceSessionId,
        host: file.host,
        connection: file.controller.connection,
        protocol: file.controller.protocol,
        initialPath: file.controller.path,
        reuseExisting: false,
      );
      _selectTerminalTab(copy.id);
      return;
    }
    final source = _visibleSessions.where((s) => s.id == id).firstOrNull;
    if (source == null || _busy) return;
    if (source.console != null) {
      await _duplicateConsole(source);
    } else {
      await _connectLocalHost(source.host);
    }
  }

  Future<void> _splitTerminalTab(String id, Axis axis) async {
    final file = _files.find(id);
    final otherFile = _files.entries
        .where((entry) => entry.id != id)
        .firstOrNull;
    if (file != null || otherFile != null) {
      final target =
          _layout.sessionIds.where((value) => value != id).firstOrNull ??
          otherFile?.id ??
          file?.sourceSessionId;
      final liveIds = {
        ..._visibleSessions.map((session) => session.id),
        ..._files.entries.map((entry) => entry.id),
      };
      if (target == null || !liveIds.contains(id) || !liveIds.contains(target))
        return;
      _layout.activate(target);
      _layout.split(
        id,
        target,
        axis == Axis.horizontal
            ? SessionSplitEdge.right
            : SessionSplitEdge.bottom,
      );
      _selectTerminalTab(id);
      return;
    }
    final source = _visibleSessions.where((s) => s.id == id).firstOrNull;
    if (source == null || _busy) return;
    final target =
        _visibleSessions
            .where((s) => s.id != id && s.id == _selectedTabId)
            .firstOrNull ??
        _visibleSessions.where((s) => s.id != id).firstOrNull;
    var other = target;
    if (other == null && source.console != null) {
      // A lone Console splits into a new independent PTY/serial session.
      final copyId = await _duplicateConsole(source);
      other = _visibleSessions.where((s) => s.id == copyId).firstOrNull;
    } else if (other == null) {
      final before = _sessions.map((s) => s.id).toSet();
      await _connectLocalHost(source.host);
      other = _visibleSessions.where((s) => !before.contains(s.id)).firstOrNull;
    }
    if (!mounted ||
        _disposing ||
        other == null ||
        !_visibleSessions.contains(source)) {
      return;
    }
    setState(() {
      _layout.activate(other!.id);
      _layout.split(
        id,
        other.id,
        axis == Axis.horizontal
            ? SessionSplitEdge.right
            : SessionSplitEdge.bottom,
      );
      _selectedTabId = id;
    });
  }

  Future<void> _openSessionFilesById(String id) async {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session != null) await _openSessionFiles(session);
  }

  Future<void> _openSessionScp(
    String id,
    SshTransferDirection direction,
  ) async {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session != null) {
      await _openSessionFiles(session, protocol: SshTransferProtocol.scp);
    }
  }

  Future<void> _openHostFiles(
    HostRecord host, {
    SshTransferDirection? scpDirection,
  }) async {
    if (_busy || kIsWeb || _disposing || host.protocol != HostProtocol.ssh) {
      return;
    }
    final session = await resolveHostFileSession<_LocalTerminalSession>(
      hostId: host.id,
      sessions: () => _sessions,
      sessionId: (s) => s.id,
      sessionHostId: (s) => s.host.id,
      isConnected: (s) => s.connected.value,
      connect: () => _connectLocalHost(host),
    );
    if (!mounted || _disposing) return;
    if (session == null) return;
    if (scpDirection == null) {
      await _openSessionFiles(session);
    } else {
      await _openSessionScp(session.id, scpDirection);
    }
  }

  Future<void> _openSessionFiles(
    _LocalTerminalSession session, {
    SshTransferProtocol protocol = SshTransferProtocol.sftp,
    String initialPath = '/',
    bool reuseExisting = true,
  }) async {
    if (!mounted ||
        _disposing ||
        !_sessions.contains(session) ||
        !session.connected.value ||
        session.connection == null) {
      return;
    }
    final entry = _files.open(
      sourceSessionId: session.id,
      host: session.host,
      connection: session.connection!,
      protocol: protocol,
      initialPath: initialPath,
      reuseExisting: reuseExisting,
    );
    _selectTerminalTab(entry.id);
  }

  void _scheduleFilesLaunch() {
    final request = widget.filesLaunch;
    if (request == null ||
        _filesLaunchConsumed ||
        _filesLaunchScheduled ||
        _busy ||
        _catalogLoading ||
        _activeProfile == null) {
      return;
    }
    if (!request.matchesScope(
      FilesWindowWorkspace.local,
      _activeProfile!.record.profileId,
    )) {
      return;
    }
    _filesLaunchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _filesLaunchScheduled = false;
      if (!mounted || _disposing || _busy || _filesLaunchConsumed) return;
      final profile = _activeProfile;
      if (profile == null ||
          !request.matchesScope(
            FilesWindowWorkspace.local,
            profile.record.profileId,
          )) {
        return;
      }
      _filesLaunchConsumed = true;
      final host = _hosts
          .where((host) => host.id == request.hostId)
          .firstOrNull;
      if (host == null) {
        setState(() => _pageError = context.l10n.theHostRequestedByTheFile);
        return;
      }
      final session = await resolveHostFileSession<_LocalTerminalSession>(
        hostId: host.id,
        sessions: () => _sessions,
        sessionId: (s) => s.id,
        sessionHostId: (s) => s.host.id,
        isConnected: (s) => s.connected.value,
        connect: () => _connectLocalHost(host),
      );
      if (!mounted || _disposing || _activeProfile != profile) return;
      if (session == null) {
        setState(() {
          _selectedTabId = 'hosts';
          _pageError = context.l10n.couldntOpenTheRequestedFileWindow;
        });
        return;
      }
      await _openSessionFiles(
        session,
        protocol: request.protocol == FilesWindowProtocol.scp
            ? SshTransferProtocol.scp
            : SshTransferProtocol.sftp,
        initialPath: request.initialPath,
      );
    });
  }

  Future<void> _detachFilesTab(FileWorkspaceTab entry) async {
    final profile = _activeProfile;
    if (profile == null || !supportsFilesWindows) return;
    try {
      await openFilesWindow(
        FilesWindowLaunch(
          workspace: FilesWindowWorkspace.local,
          scopeId: profile.record.profileId,
          hostId: entry.host.id,
          protocol: entry.controller.protocol == SshTransferProtocol.scp
              ? FilesWindowProtocol.scp
              : FilesWindowProtocol.sftp,
          initialPath: entry.controller.path,
        ),
        trackingOwner: _windowOwner,
      );
      await _files.close(entry.id);
    } on Object {
      if (mounted) _showMessage(context.l10n.theFileWindowDidntOpenTry);
    }
  }

  Future<void> _detachTerminalTab(String id) async {
    final file = _files.find(id);
    if (file != null) {
      await _detachFilesTab(file);
      return;
    }
    final desktopTab = _visibleSessions.where((s) => s.id == id).firstOrNull;
    if (desktopTab?.desktop != null) {
      await _detachDesktopTab(desktopTab!);
      return;
    }
    final session = _visibleSessions.where((s) => s.id == id).firstOrNull;
    if (session == null ||
        !session.connected.value ||
        (session.connection == null && session.console == null))
      return;
    final opened = await ApplicationWindows.instance.detach(
      owner: _windowOwner,
      sessionId: id,
      terminal: session.terminal,
      title: session.host.name,
      onDetached: () {
        if (!mounted || _disposing || !_sessions.contains(session)) return;
        setState(() {
          _detached.add(id);
          _layout.remove(id);
          if (_selectedTabId == id) {
            _selectedTabId =
                _layout.selectedId ??
                _visibleSessions.lastOrNull?.id ??
                'hosts';
            if (_selectedTabId != 'hosts') _layout.activate(_selectedTabId);
          }
        });
      },
      onUserClosed: () => _closeTerminalSession(id),
      onRestored: () {
        if (!mounted || _disposing || !_sessions.contains(session)) return;
        _detached.remove(id);
        _selectTerminalTab(id);
      },
      onOpenFiles: session.connection == null
          ? null
          : () {
              unawaited(_openSessionFiles(session));
            },
    );
    if (!opened && mounted && !_disposing) _showMessage(context.l10n.theNewWindowDidntOpenThe);
  }

  Future<void> _detachDesktopTab(_LocalTerminalSession session) async {
    final id = session.id;
    final opened = await DesktopTabWindows.detach(
      windows: ApplicationWindows.instance,
      owner: _windowOwner,
      tabId: id,
      session: session.desktop!,
      title: session.host.name,
      onDetached: () {
        if (!mounted || _disposing || !_sessions.contains(session)) return;
        setState(() {
          _detached.add(id);
          _layout.remove(id);
          if (_selectedTabId == id) {
            _selectedTabId =
                _layout.selectedId ??
                _visibleSessions.lastOrNull?.id ??
                'hosts';
            if (_selectedTabId != 'hosts') _layout.activate(_selectedTabId);
          }
        });
      },
      onUserClosed: () => _closeTerminalSession(id),
      onRestored: () {
        if (!mounted || _disposing || !_sessions.contains(session)) return;
        _detached.remove(id);
        _selectTerminalTab(id);
      },
    );
    if (!opened && mounted && !_disposing) {
      _showMessage(context.l10n.theNewWindowDidntOpenThe2);
    }
  }

  Future<void> _openDesktopMonitorWindows(_LocalTerminalSession session) async {
    final expected = session.desktop?.rdpConfig?.monitors.length ?? 0;
    final opened = await DesktopTabWindows.openMonitors(
      windows: ApplicationWindows.instance,
      owner: _windowOwner,
      tabId: session.id,
      session: session.desktop!,
      title: session.host.name,
    );
    if (opened < expected && mounted && !_disposing) {
      _showMessage(context.l10n.valuevaluePlural11MonitorWindow(expected - opened));
    }
  }

  void _terminalProperties(String id) {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session != null) {
      unawaited(
        showHostProperties(
          context,
          session.host,
          state: session.connected.value ? context.l10n.connected : context.l10n.connectionClosed,
        ),
      );
    }
  }

  void _closeOtherTabs(String id) {
    for (final entry in _files.entries) {
      if (entry.id != id) _closeTerminalTab(entry.id);
    }
    for (final session in List<_LocalTerminalSession>.of(_visibleSessions)) {
      if (session.id != id && session.id != _files.find(id)?.sourceSessionId) {
        _closeTerminalTab(session.id);
      }
    }
  }

  Future<void> _newWindow() async {
    try {
      await openNewWindow();
    } on Object {
      if (mounted) _showMessage(context.l10n.couldntOpenANewWindowTry);
    }
  }

  Future<bool> _reloadHosts(int generation) async {
    final repository = _repository;
    if (repository == null) return false;
    try {
      final hosts = await repository.listHosts();
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _hosts = hosts;
        _hostListError = null;
      });
      _portForwardChanges.fire();
      return true;
    } on Object {
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _hostListError = context.l10n.couldntRefreshTheHostListThe;
      });
      return false;
    }
  }

  Future<void> _retryHostList() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadHosts(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  Future<bool> _reloadCredentials(int generation) async {
    final repository = _repository;
    if (repository == null) return false;
    try {
      final credentials = await repository.listCredentialSummaries();
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _credentials = credentials;
        _credentialListError = null;
      });
      return true;
    } on Object {
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _credentials = const [];
        _credentialListError = context.l10n.couldntRefreshTheLocalCredentialList;
      });
      return false;
    }
  }

  Future<void> _retryCredentialList() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadCredentials(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  Future<bool> _reloadGroups(int generation) async {
    final repository = _repository;
    if (repository == null) return false;
    try {
      final groups = await repository.listGroups();
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _groups = groups;
        _groupListError = null;
      });
      return true;
    } on Object {
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _groups = const [];
        _groupListError = context.l10n.couldntRefreshTheLocalGroupList;
      });
      return false;
    }
  }

  Future<void> _retryGroupList() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadGroups(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  List<_LocalSnippetSummary> _snippetSummaries(
    List<LocalSnippetRecord> records,
  ) => records
      .map(
        (record) => _LocalSnippetSummary(
          id: record.id,
          title: record.title,
          shell: record.snippet.shell,
          executionMode: record.snippet.executionMode,
          tags: List.unmodifiable(record.snippet.tags),
          revisionId: record.revisionId,
        ),
      )
      .toList(growable: false);

  Future<bool> _reloadSnippets(int generation) async {
    final repository = _repository;
    if (repository == null) return false;
    try {
      final snippets = await repository.listSnippets();
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _snippets = _snippetSummaries(snippets);
        _snippetListError = null;
      });
      return true;
    } on Object {
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _snippets = const [];
        _snippetListError = context.l10n.couldntRefreshTheLocalSnippetList;
      });
      return false;
    }
  }

  Future<void> _retrySnippetList() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadSnippets(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  _LocalWorkspace _workspaceFromPreferenceValue(Object? value) =>
      switch (value) {
        'hosts' => _LocalWorkspace.hosts,
        'credentials' => _LocalWorkspace.credentials,
        'groups' => _LocalWorkspace.groups,
        'snippets' => _LocalWorkspace.snippets,
        _ => throw FormatException(
          context.l10n.localDefaultWorkspacePreferenceIsInvalid,
        ),
      };

  String _preferenceValueForWorkspace(_LocalWorkspace workspace) =>
      switch (workspace) {
        _LocalWorkspace.hosts => 'hosts',
        _LocalWorkspace.credentials => 'credentials',
        _LocalWorkspace.groups => 'groups',
        _LocalWorkspace.snippets => 'snippets',
        // Device-local destinations are never a synced default section.
        _LocalWorkspace.preferences ||
        _LocalWorkspace.logs ||
        _LocalWorkspace.forwarding => throw StateError(
          context.l10n.preferencesCannotBeTheDefaultWorkspace,
        ),
      };

  Future<bool> _reloadDefaultSectionPreference(int generation) async {
    final repository = _repository;
    if (repository == null) return false;
    try {
      final defaultSectionPreference = await repository.getPreference(
        scope: 'workspace',
        key: 'defaultSection',
        platformFamily: 'all',
      );
      final fontSizePreference = await repository.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalFontSizeKey,
        platformFamily: 'all',
      );
      final themePreference = await repository.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalThemeKey,
        platformFamily: 'all',
      );
      final shortcutsPreference = await repository.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.terminalShortcutsKey,
        platformFamily: 'all',
      );
      final choice = defaultSectionPreference == null
          ? _LocalWorkspace.hosts
          : _workspaceFromPreferenceValue(
              _strictPreference(defaultSectionPreference).value,
            );
      final fontSize = fontSizePreference == null
          ? VaultPreferenceRecord.defaultTerminalFontSize
          : _strictPreference(fontSizePreference).terminalFontSizeValue;
      final theme = themePreference == null
          ? VaultPreferenceRecord.defaultTerminalTheme
          : _strictPreference(themePreference).terminalThemeValue;
      final shortcuts = shortcutsPreference == null
          ? TerminalShortcutBindings.defaults
          : _strictPreference(shortcutsPreference).terminalShortcutBindings;
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _defaultSectionPreference = defaultSectionPreference;
        _defaultSectionChoice = choice;
        _terminalFontSizePreference = fontSizePreference;
        _terminalFontSizeChoice = fontSize;
        _terminalThemePreference = themePreference;
        _terminalThemeChoice = theme;
        _terminalShortcutsPreference = shortcutsPreference;
        _terminalShortcutBindings = shortcuts;
        for (final action in TerminalShortcutAction.values) {
          _terminalShortcutControllers[action]!.text = shortcuts.chordFor(
            action,
          );
        }
        _preferenceLoadError = null;
      });
      return true;
    } on Object {
      if (!_isCurrentOperation(generation)) return false;
      setState(() {
        _preferenceLoadError = context.l10n.couldntReadLocalPreferencesTheSave;
      });
      return false;
    }
  }

  Future<void> _retryDefaultSectionPreference() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadDefaultSectionPreference(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  VaultPreferenceRecord _strictPreference(LocalPreferenceRecord preference) =>
      VaultPreferenceRecord.fromJson({
        'id': preference.id,
        'type': 'preference',
        'scope': preference.scope,
        'key': preference.key,
        'value': preference.value,
        'platform_family': preference.platformFamily,
      });

  TerminalShortcutBindings? get _terminalShortcutDraft {
    try {
      return TerminalShortcutBindings.fromBindings({
        for (final action in TerminalShortcutAction.values)
          action: _terminalShortcutControllers[action]!.text,
      });
    } on FormatException {
      return null;
    }
  }

  bool get _terminalFontSizeDirty =>
      _terminalFontSizeChoice !=
      (_terminalFontSizePreference == null
          ? VaultPreferenceRecord.defaultTerminalFontSize
          : _strictPreference(_terminalFontSizePreference!)
                .terminalFontSizeValue);

  /// Saved terminal theme of this profile. Live terminals use it, so an
  /// unsaved settings draft is never applied (or left applied) as if saved.
  VaultTerminalThemeChoice get _savedTerminalThemeChoice =>
      _terminalThemePreference == null
      ? VaultPreferenceRecord.defaultTerminalTheme
      : _strictPreference(_terminalThemePreference!).terminalThemeValue;

  bool get _terminalThemeDirty =>
      _terminalThemeChoice != _savedTerminalThemeChoice;

  bool get _terminalShortcutsDirty =>
      _terminalShortcutDraft !=
      (_terminalShortcutsPreference == null
          ? TerminalShortcutBindings.defaults
          : _strictPreference(_terminalShortcutsPreference!)
                .terminalShortcutBindings);

  Future<void> _saveLocalPreference({
    required String key,
    required Object value,
    required LocalPreferenceRecord? current,
    required void Function(LocalPreferenceRecord saved) onSaved,
  }) async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      final saved = current == null
          ? await repository.createPreference(
              scope: 'workspace',
              key: key,
              value: value,
              platformFamily: 'all',
            )
          : await repository.updatePreference(
              preference: LocalPreferenceRecord(
                id: current.id,
                scope: current.scope,
                key: current.key,
                value: value,
                platformFamily: current.platformFamily,
                revisionId: current.revisionId,
              ),
              baseRevisionId: current.revisionId,
            );
      if (!_isCurrentOperation(generation)) return;
      setState(() {
        onSaved(saved);
        _preferenceLoadError = null;
      });
      _showMessage(currentL10n.preferencesAreSavedEncryptedInThis);
    } on LocalPreferenceConflictException {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.preferencesWereChangedByAnotherOperation);
      }
    } on LocalPreferenceDuplicateException {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.thisPreferenceAlreadyExistsAndThe);
      }
    } on DatabaseRecoveryRequiredException {
      if (_isCurrentOperation(generation)) _requireDatabaseReload();
    } on Object {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.thePreferenceSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _saveTerminalFontSizePreference() => _saveLocalPreference(
    key: VaultPreferenceRecord.terminalFontSizeKey,
    value: _terminalFontSizeChoice.toString(),
    current: _terminalFontSizePreference,
    onSaved: (saved) {
      _terminalFontSizePreference = saved;
      _terminalFontSizeChoice = _strictPreference(saved).terminalFontSizeValue;
    },
  );

  Future<void> _saveTerminalThemePreference() {
    // Read before the awaited save: a device palette picked meanwhile (even
    // the same one again) must not be cleared by this save.
    final palettes = TerminalPaletteController.of(context);
    final paletteGeneration = palettes.selectionGeneration;
    return _saveLocalPreference(
      key: VaultPreferenceRecord.terminalThemeKey,
      value: _terminalThemeChoice.value,
      current: _terminalThemePreference,
      onSaved: (saved) {
        _terminalThemePreference = saved;
        _terminalThemeChoice = _strictPreference(saved).terminalThemeValue;
        // Only reached for the current operation: show the saved theme on
        // this device instead of a masking device palette overlay.
        palettes.followSyncedIf(paletteGeneration);
      },
    );
  }

  Future<void> _saveTerminalShortcutsPreference() {
    final bindings = _terminalShortcutDraft;
    if (bindings == null) {
      _showMessage(context.l10n.aShortcutIsInvalidOrDuplicated);
      return Future<void>.value();
    }
    return _saveLocalPreference(
      key: VaultPreferenceRecord.terminalShortcutsKey,
      value: bindings.toValue(),
      current: _terminalShortcutsPreference,
      onSaved: (saved) {
        _terminalShortcutsPreference = saved;
        _terminalShortcutBindings = _strictPreference(saved)
            .terminalShortcutBindings;
        for (final action in TerminalShortcutAction.values) {
          _terminalShortcutControllers[action]!.text = _terminalShortcutBindings
              .chordFor(action);
        }
      },
    );
  }

  Future<void> _saveDefaultSectionPreference() async {
    final generation = _beginOperation();
    if (generation < 0) return;
    final value = _preferenceValueForWorkspace(_defaultSectionChoice);
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      final current = _defaultSectionPreference;
      final saved = current == null
          ? await repository.createPreference(
              scope: 'workspace',
              key: 'defaultSection',
              value: value,
              platformFamily: 'all',
            )
          : await repository.updatePreference(
              preference: LocalPreferenceRecord(
                id: current.id,
                scope: current.scope,
                key: current.key,
                value: value,
                platformFamily: current.platformFamily,
                revisionId: current.revisionId,
              ),
              baseRevisionId: current.revisionId,
            );
      if (!_isCurrentOperation(generation)) return;
      setState(() {
        _defaultSectionPreference = saved;
        _defaultSectionChoice = _workspaceFromPreferenceValue(
          _strictPreference(saved).value,
        );
        _preferenceLoadError = null;
        _workspace = _workspaceFromPreferenceValue(saved.value);
      });
      _showMessage(currentL10n.preferencesSavedAndApplied);
    } on LocalPreferenceConflictException {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.preferencesWereChangedByAnotherOperation);
      }
    } on LocalPreferenceDuplicateException {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.thisPreferenceAlreadyExistsAndThe);
      }
    } on Object {
      if (!_isCurrentOperation(generation)) return;
      await _reloadDefaultSectionPreference(generation);
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.thePreferenceSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  void _openPreferences() {
    if (_busy) return;
    setState(() => _workspace = _LocalWorkspace.preferences);
  }

  Future<SnippetRecord?> _showSnippetEditor({SnippetRecord? existing}) =>
      showAppDialog(
        context: context,
        builder: (context) => _LocalSnippetEditorDialog(
          existing: existing,
          credentials: _credentials,
        ),
      );

  Future<void> _addSnippet() async {
    final draft = await _showSnippetEditor();
    if (draft == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.createSnippet(draft);
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadSnippets(generation)) {
        _showMessage(currentL10n.theSnippetWasSavedButThe);
      }
    } on LocalSnippetConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.thisSnippetIdAlreadyExistsCreate);
        await _reloadSnippets(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSnippetSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _editSnippet(_LocalSnippetSummary summary) async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      final existing = await repository.getSnippet(summary.id);
      if (!_isCurrentOperation(generation)) return;
      if (existing == null) {
        _showMessage(currentL10n.theSnippetNoLongerExistsRefresh);
        await _reloadSnippets(generation);
        return;
      }
      final edited = await _showSnippetEditor(existing: existing.snippet);
      if (edited == null || !_isCurrentOperation(generation)) return;
      await repository.updateSnippet(
        edited,
        expectedRevisionId: summary.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadSnippets(generation)) {
        _showMessage(currentL10n.theSnippetWasUpdatedButThe);
      }
    } on LocalSnippetConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSnippetWasChangedByAnother);
        await _reloadSnippets(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSnippetUpdateResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _deleteSnippet(_LocalSnippetSummary summary) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteSnippet2),
        content: Text(context.l10n.titleWillBeDeletedFromThis(summary.title)),
        actions: [
          TextButton(
            key: const ValueKey('local_snippet_delete_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('local_snippet_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.deleteSnippet(
        summary.id,
        expectedRevisionId: summary.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadSnippets(generation)) {
        _showMessage(currentL10n.theSnippetWasDeletedButThe);
      }
    } on LocalSnippetConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSnippetWasChangedByAnother);
        await _reloadSnippets(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSnippetDeletionResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Widget _groupMenu(LocalGroupRecord group) => PopupMenuButton<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    enabled: !_busy && !_groupConnecting,
    tooltip: context.l10n.groupActionsName(group.name),
    onSelected: (value) {
      switch (value) {
        case 'connect':
          unawaited(_connectGroup(group));
        case 'save':
          unawaited(_saveGroupLayout(group));
        case 'reset':
          unawaited(_saveGroupLayout(group, reset: true));
        case 'edit':
          unawaited(_editGroup(group));
        case 'delete':
          unawaited(_deleteGroup(group));
      }
    },
    itemBuilder: (_) => [
      if (!kIsWeb) appMenuItem(context,value: 'connect', child: Text(context.l10n.connectGroup)),
      appMenuItem(context,value: 'save', child: Text(context.l10n.saveCurrentWindowLayout)),
      appMenuItem(context,value: 'reset', child: Text(context.l10n.resetLayout)),
      appMenuItem(context,value: 'edit', child: Text(context.l10n.editGroup)),
      appMenuItem(context,value: 'delete', child: Text(context.l10n.deleteGroup)),
    ],
  );

  bool _openingCombination = false;
  Future<LocalPreferenceRecord?> _combinationPreference() async =>
      _repository?.getPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.windowCombinationsKey,
        platformFamily: 'all',
      );
  Future<List<WindowCombination>> _loadWindowCombinations() async {
    final preference = await _combinationPreference();
    return preference == null
        ? []
        : WindowCombination.decode(preference.value as String);
  }

  Future<void> _changeWindowCombinations(
    List<WindowCombination> Function(List<WindowCombination>) change,
  ) async {
    final repository = _repository;
    if (repository == null) throw StateError(context.l10n.unlockTheLocalProfileFirst);
    final existing = await _combinationPreference();
    if (!identical(repository, _repository)) return;
    final values = existing == null
        ? <WindowCombination>[]
        : WindowCombination.decode(existing.value as String);
    final value = WindowCombination.encode(change(values));
    if (existing == null) {
      await repository.createPreference(
        scope: 'workspace',
        key: VaultPreferenceRecord.windowCombinationsKey,
        value: value,
        platformFamily: 'all',
      );
    } else {
      await repository.updatePreference(
        preference: LocalPreferenceRecord(
          id: existing.id,
          scope: existing.scope,
          key: existing.key,
          value: value,
          platformFamily: existing.platformFamily,
          revisionId: existing.revisionId,
        ),
        baseRevisionId: existing.revisionId,
      );
    }
    if (mounted && identical(repository, _repository)) setState(() {});
  }

  Future<void> _saveWindowCombination() async {
    final profile = _activeProfile;
    final repository = _repository;
    if (profile == null || repository == null) return;
    final name = await askWindowCombinationName(context);
    if (name == null ||
        !mounted ||
        !identical(profile, _activeProfile) ||
        !identical(repository, _repository))
      return;
    try {
      final recipe = await captureWindowCombinationWithPlacements(
        id: const Uuid().v4(),
        name: name,
        sessionIds: [
          ..._sessions.map((s) => s.id),
          ..._files.entries.map((e) => e.id),
        ],
        workspace: _layout,
        owner: _windowOwner,
        isCurrent: () =>
            mounted &&
            !_disposing &&
            identical(profile, _activeProfile) &&
            identical(repository, _repository),
        fileOwner: (id) => _files.find(id)?.sourceSessionId,
        describe: (id) {
          final file = _files.find(id);
          if (file != null)
            return CombinationPane(
              kind: file.controller.protocol.name,
              hostId: file.host.id,
              remotePath: file.controller.path,
            );
          final session = _sessions.where((s) => s.id == id).firstOrNull;
          if (session == null) return null;
          return session.console != null
              ? CombinationPane(
                  kind: 'console',
                  serialPort: session.consoleSerialPort,
                  baudRate: session.consoleBaudRate,
                  shell: session.consoleSerialPort == null
                      ? session.consoleShell
                      : null,
                )
              : CombinationPane(
                  kind: session.host.protocol.name,
                  hostId: session.host.id,
                );
        },
      );

      if (!mounted ||
          !identical(profile, _activeProfile) ||
          !identical(repository, _repository))
        return;
      await _changeWindowCombinations((values) => [...values, recipe]);
      if (mounted && identical(profile, _activeProfile))
        {
_showMessage(
          recipe.windows.any((w) => w.placement == null)
              ? context.l10n.windowSetSavedSomeSeparateWindows
              : context.l10n.windowSetSavedEncrypted,
        );
}
    } catch (error) {
      if (mounted &&
          identical(profile, _activeProfile) &&
          identical(repository, _repository))
        {
_showMessage(error is FileWindowCaptureUnavailable?FileWindowCaptureUnavailable.message:context.l10n.couldntSaveTheWindowSetCheck);
}
    }
  }

  Future<String?> _detachCombinationWindow(
    int index,
    CombinationWindow window,
    String id,
  ) async {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return null;
    if (session.desktop == null) {
      await _detachTerminalTab(id);
      return ApplicationWindows.instance.isDetached(_windowOwner, id)
          ? id
          : null;
    }
    final profile = _activeProfile, repository = _repository;
    bool current() =>
        mounted &&
        !_disposing &&
        identical(profile, _activeProfile) &&
        identical(repository, _repository) &&
        _sessions.contains(session);
    final viewport = window.viewport;
    final windowId = viewport == null ? id : '$id#savedMonitor$index';
    final opened = await ApplicationWindows.instance.detachDesktop(
      owner: _windowOwner,
      windowId: windowId,
      session: session.desktop!,
      spec: DesktopWindowSpec(
        title: session.host.name,
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
        if (current() && viewport == null)
          setState(() {
            _detached.add(id);
            _layout.remove(id);
            if (_selectedTabId == id)
              _selectedTabId =
                  _layout.selectedId ??
                  _visibleSessions.lastOrNull?.id ??
                  'hosts';
            if (_selectedTabId != 'hosts') _layout.activate(_selectedTabId);
          });
      },
      onUserClosed: () async {
        if (current() && viewport == null) await _closeTerminalSession(id);
      },
      onRestored: () {
        if (current() && viewport == null) {
          _detached.remove(id);
          _selectTerminalTab(id);
        }
      },
    );
    return opened ? windowId : null;
  }

  final _combinationRestorer = CombinationRestoreCoordinator();
  Future<void> _openWindowCombination(WindowCombination recipe) async {
    final profile = _activeProfile;
    final repository = _repository;
    if (profile == null || repository == null || _busy || _openingCombination)
      return;
    bool current() =>
        mounted &&
        !_disposing &&
        identical(profile, _activeProfile) &&
        identical(repository, _repository);
    setState(() => _openingCombination = true);
    try {
      final latest = (await _loadWindowCombinations())
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
              workspace: FilesWindowWorkspace.local,
              scopeId: profile.record.profileId,
              hostId: pane.hostId!,
              protocol: FilesWindowProtocol.values.byName(pane.kind),
              initialPath: pane.remotePath ?? '/',
            ),
            owner: _windowOwner,
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
          final host = _hosts.where((h) => h.id == pane.hostId).firstOrNull;
          return host != null &&
              host.protocol.name ==
                  (pane.kind == 'sftp' || pane.kind == 'scp'
                      ? 'ssh'
                      : pane.kind);
        },
        openAttachedFile: (pane, ownerId) async {
          if (!current()) return null;
          final host = _hosts.where((h) => h.id == pane.hostId).firstOrNull;
          if (host == null || host.protocol != HostProtocol.ssh) return null;
          final owner = _visibleSessions
              .where(
                (t) =>
                    t.id == ownerId &&
                    t.host.id == host.id &&
                    t.connection != null &&
                    t.connected.value,
              )
              .firstOrNull;
          if (owner == null ||
              owner.host.protocol != host.protocol ||
              owner.host.address != host.address ||
              owner.host.port != host.port ||
              owner.host.username != host.username ||
              owner.host.jumpHostId != host.jumpHostId)
            return null;
          final beforeFiles = _files.entries.map((e) => e.id).toSet();
          await _openSessionFiles(
            owner,
            reuseExisting: false,
            initialPath: pane.remotePath ?? '/',
            protocol: pane.kind == 'scp'
                ? SshTransferProtocol.scp
                : SshTransferProtocol.sftp,
          );
          if (!current()) return null;
          return _files.entries
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
            final id = await _openConsole(
              serialPort: pane.serialPort,
              baudRate: pane.baudRate ?? 115200,
              shell: pane.serialPort == null ? pane.shell : null,
            );
            return _visibleSessions
                .where((s) => s.id == id && s.console != null)
                .firstOrNull
                ?.id;
          }
          final host = _hosts.where((h) => h.id == pane.hostId).firstOrNull;
          if (host == null) return null;
          final before = _sessions.map((s) => s.id).toSet();
          await _connectLocalHost(host, shouldContinue: current);
          return _visibleSessions
              .where(
                (s) =>
                    !before.contains(s.id) &&
                    s.host.id == host.id &&
                    (s.connected.value ||
                        (s.desktop != null &&
                            s.desktop!.state != 'disconnected') ||
                        s.telnetState == 'connecting'),
              )
              .firstOrNull
              ?.id;
        },
      );
      if (result == null || result.stale || !current()) return;
      if (result.sessions.isNotEmpty) {
        applyWindowCombination(recipe, _layout, result.sessions);
        final selected = _layout.selectedId;
        if (selected != null) _selectTerminalTab(selected);
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
                      .applyWindowPlacement(_windowOwner, id, value),
                  closeDetached: (id) => ApplicationWindows.instance
                      .closeSession(_windowOwner, id),
                ));
      if (!current()) return;
      if (windowFailures > 0 && result.failures == 0)
        {
_showMessage(currentL10n.someSeparateWindowsOrWindowPositions);
}
      if (result.failures > 0)
        {
_showMessage(
          currentL10n.windowSetOpenedValuevalueCountSessions(result.sessions.length + result.independentOpened, recipe.panes.length, result.failures) +
              (windowFailures > 0 ? currentL10n.windowfailuresPlural11MoreWindow(windowFailures) : ''),
        );
}
    } catch (error) {
      if (current())
        {
_showMessage(
          error is StateError ? error.message.toString() : currentL10n.couldntOpenTheWindowSet,
        );
}
    } finally {
      if (mounted) setState(() => _openingCombination = false);
    }
  }

  Future<void> _connectGroup(LocalGroupRecord group) async {
    if (_busy || _groupConnecting || kIsWeb || _disposing) return;
    final profile = _activeProfile;
    if (profile == null) return;
    final members = GroupSessionLayout.groupHosts(
      group.group,
      _groups.map((entry) => entry.group).toList(),
      _hosts,
    );
    if (members.isEmpty) {
      _showMessage(context.l10n.thisGroupDoesntHaveAnyConnectable);
      return;
    }
    if (members.length > 32) {
      _showMessage(context.l10n.eachLayoutCanHaveUpTo);
      return;
    }
    GroupSessionLayout layout;
    try {
      layout =
          GroupSessionLayout.read(group.group) ??
          GroupSessionLayout.forHosts(members.map((host) => host.id).toList());
    } on FormatException {
      _showMessage(context.l10n.theSavedGroupLayoutIsInvalid2);
      return;
    }
    final token = ++_groupConnectionGeneration;
    final connected = <String, String>{};
    final used = <String>{};
    bool current() =>
        mounted &&
        !_disposing &&
        identical(_activeProfile, profile) &&
        token == _groupConnectionGeneration;
    setState(() => _groupConnecting = true);
    try {
      for (final pane in layout.panes) {
        if (!current()) return;
        final host = members
            .where((host) => host.id == pane.hostId)
            .firstOrNull;
        if (host == null) continue;
        var session = _visibleSessions
            .where(
              (session) =>
                  matchesGroupHostConnection(session.host, host) &&
                  session.connected.value &&
                  !used.contains(session.id),
            )
            .firstOrNull;
        if (session == null) {
          final previous = _sessions.map((session) => session.id).toSet();
          await _connectLocalHost(host, shouldContinue: current);
          if (!current()) return;
          session = _visibleSessions
              .where(
                (session) =>
                    !previous.contains(session.id) &&
                    matchesGroupHostConnection(session.host, host) &&
                    session.connected.value,
              )
              .firstOrNull;
        }
        if (session == null) break;
        used.add(session.id);
        connected[pane.paneId] = session.id;
      }
      if (!current() || connected.isEmpty) return;
      if (layout.apply(_layout, sessionIdsByPane: connected)) {
        setState(
          () => _selectedTabId = _layout.selectedId ?? connected.values.first,
        );
      }
    } finally {
      if (mounted && !_disposing) setState(() => _groupConnecting = false);
    }
  }

  Future<void> _saveGroupLayout(
    LocalGroupRecord group, {
    bool reset = false,
  }) async {
    if (_busy || _groupConnecting) return;
    final root = _layout.root;
    GroupSessionLayout? captured;
    if (!reset) {
      final members = GroupSessionLayout.groupHosts(
        group.group,
        _groups.map((entry) => entry.group).toList(),
        _hosts,
      ).map((host) => host.id).toSet();
      final mapping = {
        for (final session in _visibleSessions)
          if (session.connected.value &&
              members.contains(session.host.id) &&
              _layout.sessionIds.contains(session.id))
            session.id: session.host.id,
      };
      if (root == null || mapping.isEmpty) {
        _showMessage(context.l10n.thisWindowHasNoSessionLayout);
        return;
      }
      try {
        captured = GroupSessionLayout.capture(
          root: root,
          hostIdsBySession: mapping,
          selectedSessionId: _layout.selectedId,
        );
      } on FormatException {
        _showMessage(context.l10n.thereAreTooManySplitsTo);
        return;
      }
    }
    final generation = _beginOperation();
    if (generation < 0) return;
    final repository = _repository;
    try {
      if (repository == null) return;
      final latest = await repository.getGroup(group.id);
      if (latest == null || !_isCurrentOperation(generation)) return;
      final updated = reset
          ? GroupSessionLayout.clear(latest.group)
          : captured!.writeTo(latest.group);
      await repository.updateGroup(
        group: updated,
        baseRevisionId: latest.revisionId,
      );
      if (_isCurrentOperation(generation)) {
        await _reloadGroups(generation);
        _showMessage(reset ? currentL10n.groupLayoutReset : currentL10n.groupWindowLayoutSaved);
      }
    } on LocalGroupConflictException {
      if (_isCurrentOperation(generation)) _showMessage(currentL10n.theGroupChangedRefreshAndSave);
    } on Object {
      if (_isCurrentOperation(generation)) _showMessage(currentL10n.couldntSaveTheGroupLayoutTry);
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _addGroup() async {
    final draft = await _showGroupEditor(
      groups: _groups,
      credentials: _credentials,
    );
    if (draft == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.createGroup(draft);
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadGroups(generation)) {
        _showMessage(currentL10n.theGroupWasSavedButThe);
      }
    } on LocalGroupDuplicateException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.aGroupWithThisNameAlready);
      }
    } on LocalGroupConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupRecordWasChangedBy);
        await _reloadGroups(generation);
      }
    } on FormatException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theSelectedParentGroupNoLonger);
        await _reloadGroups(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _editGroup(LocalGroupRecord group) async {
    final draft = await _showGroupEditor(
      existing: group.group,
      groups: _groups,
      credentials: _credentials,
    );
    if (draft == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.updateGroup(
        group: draft,
        baseRevisionId: group.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadGroups(generation)) {
        _showMessage(currentL10n.theGroupWasUpdatedButThe);
      }
    } on LocalGroupDuplicateException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.aGroupWithThisNameAlready);
      }
    } on LocalGroupConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupWasChangedByAnother2);
        await _reloadGroups(generation);
      }
    } on FormatException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theParentGroupNoLongerExists);
        await _reloadGroups(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupUpdateResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _deleteGroup(LocalGroupRecord group) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteGroup2),
        content: Text(context.l10n.nameWillBeDeletedFromThis(group.name)),
        actions: [
          TextButton(
            key: const ValueKey('local_group_delete_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('local_group_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.deleteGroup(
        recordId: group.id,
        baseRevisionId: group.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadGroups(generation)) {
        _showMessage(currentL10n.theGroupWasDeletedButThe);
      }
    } on LocalGroupInUseException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupIsStillUsedBy);
        await _reloadGroups(generation);
      }
    } on LocalGroupConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupWasChangedByAnother);
        await _reloadGroups(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theGroupDeletionResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<GroupRecord?> _showGroupEditor({
    GroupRecord? existing,
    required List<LocalGroupRecord> groups,
    required List<LocalCredentialSummary> credentials,
  }) => showAppDialog(
    context: context,
    builder: (context) => _LocalGroupEditorDialog(
      existing: existing,
      groups: groups,
      credentials: credentials,
    ),
  );

  Future<void> _addCredential() async {
    final draft = await _showCredentialEditor();
    if (draft == null || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.createCredential(draft);
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadCredentials(generation)) {
        _showMessage(currentL10n.theCredentialWasSavedButThe);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theCredentialSaveResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _editCredential(LocalCredentialSummary summary) async {
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      final existing = await repository.getCredential(summary.id);
      if (!_isCurrentOperation(generation)) return;
      if (existing == null) {
        _showMessage(currentL10n.theCredentialNoLongerExistsRefresh);
        await _reloadCredentials(generation);
        return;
      }
      final edited = await _showCredentialEditor(existing: existing);
      if (edited == null || !_isCurrentOperation(generation)) return;
      final preservesSecret = edited.kind == existing.kind;
      final credential = CredentialRecord(
        id: existing.id,
        name: edited.name,
        username: edited.username,
        kind: edited.kind,
        secret: edited.secret ?? (preservesSecret ? existing.secret : null),
        privateKey:
            edited.privateKey ?? (preservesSecret ? existing.privateKey : null),
        passphrase:
            edited.passphrase ?? (preservesSecret ? existing.passphrase : null),
        fingerprint:
            edited.fingerprint ?? (preservesSecret ? existing.fingerprint : null),
        // The editor always returns the full (possibly cleared) certificate.
        certificate: edited.kind == AuthKind.privateKey
            ? edited.certificate
            : null,
        manifest: existing.manifest,
      );
      await repository.updateCredential(
        credential: credential,
        baseRevisionId: summary.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadCredentials(generation)) {
        _showMessage(currentL10n.theCredentialWasUpdatedButThe);
      }
    } on LocalCredentialConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theCredentialWasChangedByAnother);
        await _reloadCredentials(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theCredentialUpdateResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _deleteCredential(LocalCredentialSummary summary) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteCredential2),
        content: Text(context.l10n.nameWillBeDeletedFromThis(summary.name)),
        actions: [
          TextButton(
            key: const ValueKey('local_credential_delete_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('local_credential_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final repository = _repository;
      if (repository == null) throw StateError(context.l10n.noLocalProfile);
      await repository.deleteCredential(
        recordId: summary.id,
        baseRevisionId: summary.revisionId,
      );
      if (!_isCurrentOperation(generation)) return;
      if (!await _reloadCredentials(generation)) {
        _showMessage(currentL10n.theCredentialWasDeletedButThe);
      }
    } on LocalCredentialInUseException catch (error) {
      if (_isCurrentOperation(generation)) {
        _showMessage(
          currentL10n.thisCredentialIsStillReferencedBy(_credentialReferenceLabel(error)),
        );
        await _reloadCredentials(generation);
      }
    } on LocalCredentialConflictException {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theCredentialWasChangedByAnother);
        await _reloadCredentials(generation);
      }
    } on Object {
      if (_isCurrentOperation(generation)) {
        _showMessage(currentL10n.theCredentialDeletionResultCouldntBe);
      }
    } finally {
      _finishOperation(generation);
    }
  }

  String _credentialReferenceLabel(LocalCredentialInUseException error) {
    final groupId = error.groupId;
    if (groupId != null) {
      final name = _groups
          .where((group) => group.id == groupId)
          .firstOrNull
          ?.name;
      return name == null ? context.l10n.groupGroupid(groupId) : context.l10n.groupName(name);
    }
    final hostId = error.hostId;
    if (hostId != null) {
      final name = _hosts.where((host) => host.id == hostId).firstOrNull?.name;
      return name == null ? context.l10n.hostHostid(hostId) : context.l10n.quotedHostName(name);
    }
    final snippetId = error.snippetId;
    if (snippetId != null) {
      final title = _snippets
          .where((snippet) => snippet.id == snippetId)
          .firstOrNull
          ?.title;
      return title == null ? context.l10n.snippetSnippetid(snippetId) : context.l10n.snippetTitle(title);
    }
    return context.l10n.otherLocalRecords;
  }

  Future<CredentialRecord?> _showCredentialEditor({
    CredentialRecord? existing,
  }) => showAppDialog(
    context: context,
    builder: (context) => _LocalCredentialEditorDialog(existing: existing),
  );

  void _showMessage(String message) {
    if (!mounted || _storageRecoveryRequired) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_activeProfile != null)
      validateTrackedFileScope(
        FilesWindowWorkspace.local,
        _activeProfile!.record.profileId,
      );
    final active = _activeProfile;
    _scheduleFilesLaunch();
    final activeSession = _sessions
        .where((session) => session.id == _selectedTabId)
        .firstOrNull;
    final List<WorkspaceAction> homeActions = _storageRecoveryRequired
        ? const []
        : [
            if (active != null) ...[
              WorkspaceAction(
                'local_save_window_combination',
                context.l10n.saveWindowSet,
                Icons.dashboard_customize_outlined,
                _saveWindowCombination,
                enabled:
                    !_busy &&
                    !_openingCombination &&
                    (_sessions.isNotEmpty ||
                        _files.entries.isNotEmpty ||
                        TrackedFilesWindows.instance.hasWindows(_windowOwner)),
              ),
              WorkspaceAction(
                'local_profile_hosts_toggle',
                context.l10n.hosts,
                Icons.dns_outlined,
                () => setState(() {
                  _selectedTabId = 'hosts';
                  _workspace = _LocalWorkspace.hosts;
                }),
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_profile_groups_toggle',
                context.l10n.groups,
                Icons.folder_outlined,
                () => setState(() {
                  _selectedTabId = 'hosts';
                  _workspace = _LocalWorkspace.groups;
                }),
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_profile_snippets_toggle',
                context.l10n.snippet,
                Icons.code,
                () => setState(() {
                  _selectedTabId = 'hosts';
                  _workspace = _LocalWorkspace.snippets;
                }),
                enabled: !_busy,
              ),
            ],
            WorkspaceAction(
              'local_profile_preferences_toggle',
              context.l10n.settings,
              Icons.settings_outlined,
              () {
                setState(() {
                  _selectedTabId = 'hosts';
                  _workspace = _LocalWorkspace.preferences;
                });
                if (active != null) _openPreferences();
              },
              enabled: !_busy,
            ),
            if (supportsNewWindow)
              WorkspaceAction(
                'local_new_window',
                context.l10n.newWindow,
                Icons.open_in_new,
                _newWindow,
              ),
            if (active != null) ...[
              WorkspaceAction(
                'local_profile_archive_export',
                context.l10n.exportLocalEncryptedArchive,
                Icons.download_outlined,
                _exportLocalArchive,
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_profile_archive_import',
                context.l10n.importLocalEncryptedArchive,
                Icons.upload_file_outlined,
                _importLocalArchive,
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_profile_lock',
                context.l10n.lockProfile,
                Icons.lock_outline,
                _lockProfile,
                enabled: !_busy,
              ),
            ],

            if (active != null) ...[
              WorkspaceAction(
                'local_host_add_group',
                context.l10n.newGroup,
                Icons.create_new_folder_outlined,
                _addGroup,
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_host_layout',
                _hostGrid ? context.l10n.listView : context.l10n.gridView,
                _hostGrid ? Icons.view_list_outlined : Icons.grid_view,
                () => setState(() => _hostGrid = !_hostGrid),
              ),
              WorkspaceAction(
                'local_known_hosts_manage',
                context.l10n.manageSshHostKeyTrust,
                Icons.verified_user_outlined,
                _manageLocalKnownHosts,
                enabled: !_busy,
              ),
              for (final protocol in HostProtocol.values)
                WorkspaceAction(
                  protocol == HostProtocol.ssh
                      ? 'local_host_add'
                      : 'local_new_${protocol.name}',
                  context.l10n.newTouppercaseHost(protocol.name.toUpperCase()),
                  hostProtocolIcon(protocol),
                  () => _addHost(protocol),
                  enabled: !_busy,
                ),
              ...localShellWorkspaceActions(
                context,
                idPrefix: 'local',
                onLaunch: (launch) => _openConsole(shell: launch),
                enabled: !_busy,
              ),
            ],
            if (activeSession != null && activeSession.connection != null) ...[
              WorkspaceAction(
                'local_ssh_open_sftp',
                context.l10n.sftpFileManager,
                Icons.folder_open_outlined,
                () => _openSessionFiles(activeSession),
              ),
              WorkspaceAction(
                'local_ssh_open_scp',
                context.l10n.scpFileManager,
                Icons.folder_copy_outlined,
                () => _openSessionFiles(
                  activeSession,
                  protocol: SshTransferProtocol.scp,
                ),
              ),
              WorkspaceAction(
                'local_ssh_port_forwarding',
                sshPortForwardingMenuLabel(
                  context.l10n.sshPortForwarding2,
                  activeSession.connection!.portForwards,
                ),
                Icons.hub_outlined,
                () => _openPortForwarding(
                  activeSession.host,
                  session: activeSession,
                ),
                enabled: !_busy,
              ),
              WorkspaceAction(
                'local_ssh_search',
                context.l10n.searchTerminal,
                Icons.search,
                () => activeSession.viewKey.currentState?._openSearch(),
              ),
              WorkspaceAction(
                'local_ssh_properties',
                context.l10n.connectionProperties,
                Icons.info_outline,
                () => _terminalProperties(activeSession.id),
              ),
              WorkspaceAction(
                'local_ssh_disconnect',
                context.l10n.disconnect,
                Icons.link_off,
                () => _closeTerminalTab(activeSession.id),
              ),
            ],
          ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            WorkspaceTabBar(
              groups: _layout.groupedSessionIds,
              groupSelections: _layout.retainedGroupSelections,
              onUnsplit: _unsplitTerminalTab,
              leading: _storageRecoveryRequired || widget.persistentMode
                  ? null
                  : IconButton(
                      key: const ValueKey('local_profile_exit'),
                      tooltip: context.l10n.exitLocalProfile,
                      onPressed: _busy ? null : _exit,
                      icon: const Icon(Icons.arrow_back),
                    ),
              homeMenuActions: homeActions,
              onToggleTools: activeSession?.connection != null
                  ? () => activeSession!.viewKey.currentState?.toggleTools()
                  : null,
              onSearch: active == null || _storageRecoveryRequired
                  ? null
                  : () => unawaited(_openHostSearch()),
              onSftp: (id) => unawaited(_openSessionFilesById(id)),
              onScp: (id) =>
                  unawaited(_openSessionScp(id, SshTransferDirection.upload)),
              tabs: [
                WorkspaceTab(id: 'hosts', title: context.l10n.home, isHome: true),
                ..._tabOrder.arrange<WorkspaceTab>([
                  for (final session in _visibleSessions)
                    WorkspaceTab(
                      id: session.id,
                      title: session.host.name,
                      isConnected: session.connected.value,
                      canOpenFiles: session.connection != null,
                      canDetach:
                          (session.connection != null ||
                              session.console != null) &&
                          ApplicationWindows.instance.supported,
                    ),
                  for (final entry in _files.entries)
                    WorkspaceTab(
                      id: entry.id,
                      title: entry.title,
                      isConnected: true,
                      isFile: true,
                      canDetach: supportsFilesWindows,
                    ),
                ], (tab) => tab.id),
              ],
              selectedId: _selectedTabId,
              onSelect: _selectTerminalTab,
              onClose: _closeTerminalTab,
              onReorder: _reorderTerminalTabs,
              onSplit: (id, axis) => unawaited(_splitTerminalTab(id, axis)),
              onDetach:
                  ApplicationWindows.instance.supported || supportsFilesWindows
                  ? (id) => unawaited(_detachTerminalTab(id))
                  : null,
              onProperties: _terminalProperties,
              onCloseOthers: _closeOtherTabs,
              onDuplicate: (id) => unawaited(_duplicateWorkspaceTab(id)),
              dragScope: _dragScope,
              supportsNewWindow: supportsNewWindow,
              onNewWindow: _newWindow,
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedTabId == 'hosts' ? 0 : 1,
                children: [
                  SafeArea(
                    child: _storageRecoveryRequired
                        ? _buildStorageRecoveryPage()
                        : _withHomeSidebar(
                            active,
                            Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    active != null &&
                                        (_workspace == _LocalWorkspace.hosts ||
                                            _workspace ==
                                                _LocalWorkspace.preferences)
                                    ? double.infinity
                                    : 900,
                              ),
                              child: Column(
                                children: [
                                  if (_pageError != null)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        20,
                                        8,
                                        20,
                                        0,
                                      ),
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          _pageError!,
                                          key: const ValueKey(
                                            'local_profile_error',
                                          ),
                                          style: TextStyle(
                                            color: context.palette.red,
                                          ),
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: active == null
                                        ? (_workspace ==
                                                  _LocalWorkspace.preferences
                                              ? ListView(
                                                  padding: const EdgeInsets.all(
                                                    20,
                                                  ),
                                                  children: [
                                                    ScopedWorkspaceModeSettings(
                                                      onSwitch: _exit,
                                                    ),
                                                    const SizedBox(height: 16),
                                                    LocalAccountSettingsPanel(
                                                      onSignIn: _exit,
                                                    ),
                                                  ],
                                                )
                                              : _buildProfiles())
                                        : switch (_workspace) {
                                            _LocalWorkspace.hosts =>
                                              _buildHosts(active),
                                            _LocalWorkspace.credentials =>
                                              _buildCredentials(active),
                                            _LocalWorkspace.groups =>
                                              _buildGroups(active),
                                            _LocalWorkspace.snippets =>
                                              _buildSnippets(active),
                                            _LocalWorkspace.preferences =>
                                              _buildPreferences(),
                                            _LocalWorkspace.logs =>
                                              _buildSessionLogs(),
                                            _LocalWorkspace.forwarding =>
                                              _forwardingPageBuilder?.call() ??
                                                  _buildHosts(active),
                                          },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ),
                  ),
                  TerminalToolsLayout(
                    sidebar: activeSession?.viewKey.currentState?.toolsSidebar,
                    child: SessionWorkspaceView(
                      controller: _layout,
                      dragScope: _dragScope,
                      acceptsSession: (id) =>
                          _files.find(id) != null ||
                          _visibleSessions.any((session) => session.id == id),
                      onSelect: _selectTerminalTab,
                      onClose: _closeTerminalTab,
                      onDuplicate: (id) => unawaited(_duplicateWorkspaceTab(id)),
                      onUnsplit: _unsplitTerminalTab,
                      paneLabel: (id) =>
                          _files.find(id)?.title ??
                          _visibleSessions
                              .where((s) => s.id == id)
                              .firstOrNull
                              ?.host
                              .name ??
                          context.l10n.console,
                      paneStatus: (id) => _files.find(id) != null
                          ? context.l10n.fileManager
                          : (_visibleSessions
                                        .where((s) => s.id == id)
                                        .firstOrNull
                                        ?.connected
                                        .value ==
                                    true
                                ? context.l10n.connected
                                : context.l10n.notConnected),
                      terminalBuilder: (_, id) {
                        final file = _files.find(id);
                        if (file != null) {
                          return RemoteFileWorkspace(
                            key: ValueKey(file.id),
                            controller: file.controller,
                          );
                        }
                        final session = _visibleSessions
                            .where((s) => s.id == id)
                            .firstOrNull;
                        if (session == null) return const SizedBox.shrink();
                        if (session.desktop != null) {
                          return ExcludeFocus(
                            excluding: _selectedTabId != id,
                            child: DesktopView(
                              key: ValueKey(session.id),
                              session: session.desktop!,
                              onDetach: ApplicationWindows.instance.supported
                                  ? () => unawaited(_detachTerminalTab(id))
                                  : null,
                              onOpenMonitorWindows:
                                  ApplicationWindows.instance.supported
                                  ? () => unawaited(
                                      _openDesktopMonitorWindows(session),
                                    )
                                  : null,
                            ),
                          );
                        }
                        if (session.isTelnet) {
                          return SessionRecoveryOverlay(recovery: session.recovery, child: ExcludeFocus(
                            excluding: _selectedTabId != id,
                            child: TerminalView(
                              session.terminal,
                              key: ValueKey('local_telnet_view_${session.id}'),
                              autofocus: _selectedTabId == id,
                              readOnly: !session.connected.value,
                              hardwareKeyboardOnly: false,
                              backgroundOpacity:
                                  wallpaperTerminalBackgroundOpacity(context),
                              textStyle: TerminalStyle(
                                fontSize: _terminalFontSizeChoice.toDouble(),
                              ),
                              theme: terminalColorThemeOf(
                                context,
                                _savedTerminalThemeChoice,
                              ),
                            ),
                          ));
                        }
                        if (session.console != null) {
                          return ExcludeFocus(
                            excluding: _selectedTabId != id,
                            child: TerminalView(
                              session.terminal,
                              autofocus: _selectedTabId == id,
                              readOnly: !session.connected.value,
                              backgroundOpacity:
                                  wallpaperTerminalBackgroundOpacity(context),
                              textStyle: TerminalStyle(
                                fontSize: _terminalFontSizeChoice.toDouble(),
                              ),
                              theme: terminalColorThemeOf(
                                context,
                                _savedTerminalThemeChoice,
                              ),
                            ),
                          );
                        }
                        return SessionRecoveryOverlay(recovery: session.recovery, child: _LocalSshTerminalDialog(
                          key: session.viewKey,
                          session: session,
                          host: session.host,
                          connection: session.connection!,
                          repository: _repository!,
                          fontSize: _terminalFontSizeChoice,
                          theme: _savedTerminalThemeChoice,
                          shortcuts: _terminalShortcutBindings,
                          active: _selectedTabId == session.id,
                          onDisconnect: () => _closeTerminalTab(session.id),
                          onToolsChanged: () {
                            if (mounted) setState(() {});
                          },
                        ));
                      },
                    ),
                  ),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: sshTransferActivity,
              builder: (_, _) {
                final session = _sessions
                    .where((s) => s.id == _selectedTabId)
                    .firstOrNull;
                return WorkspaceStatusBar(
                  status: active == null ? context.l10n.localLocked : context.l10n.localUnlocked,
                  detail: session == null
                      ? context.l10n.hostsAndSignInDetailsAre
                      : '${session.host.username.isEmpty ? '' : '${session.host.username}@'}${session.host.address}:${session.host.port} · ${session.isTelnet ? '${context.l10n.telnetProtocolUnencrypted} · ' : ''}${session.connected.value ? context.l10n.connected : context.l10n.disconnected}',
                  sessionCount: _sessions
                      .where((s) => s.connected.value)
                      .length,
                  onProperties: session == null
                      ? null
                      : () => _terminalProperties(session.id),
                  transfer: sshTransferActivity.activeCount == 0
                      ? null
                      : Text(
                          sshTransferActivity.summary,
                          style: const TextStyle(fontSize: 11),
                        ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- R7 Home LEFT sidebar -------------------------------------------------

  /// R7-INTEGRATION(forwarding): after the forwarding branch merges, root
  /// changes this to `=> _buildSshForwardingPage;` (the State-owned
  /// `_sshForwardingController`/`_sshForwardingSource`). While null the
  /// destination is hidden (no fake page).
  Widget Function()? get _forwardingPageBuilder => _buildSshForwardingPage;

  /// R7-INTEGRATION(import_export): root replaces with a
  /// `HomeSidebarAction` opening `showTermiusTransferDialog(context,
  /// target: LocalTermiusTransferTarget(repository, onChanged: ...))`.
  /// Omitted from the Import / Export menu while null.
  HomeSidebarAction? _termiusTransferAction() => HomeSidebarAction(
    id: 'local_termius_transfer',
    label: context.l10n.r7ImportMenuAction,
    icon: Icons.swap_horiz_outlined,
    enabled: !_busy && _repository != null,
    onSelected: _openTermiusTransfer,
  );

  Future<void> _openTermiusTransfer() async {
    final repository = _repository;
    if (repository == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await showTermiusTransferDialog(
        context,
        certificates: const KeychainTermiusCertificateBridge(),
        target: LocalTermiusTransferTarget(
          repository,
          onChanged: () async {
            if (!_isCurrentOperation(generation) ||
                !identical(_repository, repository)) return;
            await _reloadHosts(generation);
            await _reloadCredentials(generation);
            await _reloadGroups(generation);
          },
        ),
      );
    } finally {
      _finishOperation(generation);
    }
  }

  Widget _buildSessionLogs() {
    final book = _sessionLogs;
    if (book == null) return const Center(child: CircularProgressIndicator());
    return SessionLogsPage(book: book);
  }

  HomeDestination _homeDestinationFor(_LocalWorkspace workspace) =>
      switch (workspace) {
        _LocalWorkspace.hosts => HomeDestination.hosts,
        _LocalWorkspace.groups => HomeDestination.groups,
        _LocalWorkspace.logs => HomeDestination.logs,
        _LocalWorkspace.forwarding => HomeDestination.forwarding,
        _LocalWorkspace.snippets => HomeDestination.snippets,
        _LocalWorkspace.credentials => HomeDestination.keychain,
        _LocalWorkspace.preferences => HomeDestination.settings,
      };

  void _selectHomeDestination(HomeDestination destination) {
    if (_busy) return;
    final next = switch (destination) {
      HomeDestination.hosts => _LocalWorkspace.hosts,
      HomeDestination.groups => _LocalWorkspace.groups,
      HomeDestination.logs => _LocalWorkspace.logs,
      HomeDestination.forwarding => _LocalWorkspace.forwarding,
      HomeDestination.snippets => _LocalWorkspace.snippets,
      HomeDestination.keychain => _LocalWorkspace.credentials,
      HomeDestination.settings => _LocalWorkspace.preferences,
    };
    setState(() {
      _selectedTabId = 'hosts';
      _workspace = next;
    });
  }

  /// Wraps the Home body (only the Home surface, never terminal panes) with
  /// the LEFT navigation column once a Profile is unlocked.
  Widget _withHomeSidebar(UnlockedLocalProfile? active, Widget body) {
    if (active == null) return body;
    final termius = _termiusTransferAction();
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSidebar(
            layout: homeSidebarLayoutFor(constraints.maxWidth),
            selected: _homeDestinationFor(_workspace),
            onSelect: _selectHomeDestination,
            destinations: [
              HomeDestination.hosts,
              HomeDestination.groups,
              HomeDestination.logs,
              if (_forwardingPageBuilder != null) HomeDestination.forwarding,
              HomeDestination.snippets,
              HomeDestination.keychain,
              HomeDestination.settings,
            ],
            footerActions: [
              HomeSidebarAction(
                id: 'local_archive_import',
                label: context.l10n.importLocalEncryptedArchive,
                icon: Icons.upload_file_outlined,
                onSelected: _importLocalArchive,
                enabled: !_busy,
              ),
              HomeSidebarAction(
                id: 'local_archive_export',
                label: context.l10n.exportLocalEncryptedArchive,
                icon: Icons.download_outlined,
                onSelected: _exportLocalArchive,
                enabled: !_busy,
              ),
              ?termius,
            ],
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildStorageRecoveryPage() => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: appDialogWidth(context, 560)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.storage_rounded, size: 40),
            const SizedBox(height: 16),
            Text(
              context.l10n.aLocalStorageWriteWasInterrupted,
              key: const ValueKey('local_storage_recovery_message'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const ValueKey('local_profile_reload'),
              onPressed: reloadApplication,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.reloadPage),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildProfiles() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
    children: [
      Text(context.l10n.localProfile2, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text(
        context.l10n.profileHostAndCredentialRecordsAre,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: context.palette.muted),
      ),
      const SizedBox(height: 18),
      if (_catalogLoading)
        const Center(child: CircularProgressIndicator())
      else if (_profileListError != null)
        _ProfileListError(
          message: _profileListError!,
          onRetry: _catalogLoading
              ? null
              : () => _refreshProfiles(initial: true),
        )
      else ...[
        if (_profiles.isEmpty)
          _EmptyState(
            icon: Icons.lock_person_outlined,
            title: context.l10n.noLocalProfilesYet,
            description: context.l10n.afterCreatingALocalProfileYou,
          )
        else ...[
          Text(context.l10n.chooseAProfileToUnlock, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._profiles.map(_profileTile),
          if (_selectedProfile != null) ...[
            const SizedBox(height: 8),
            if (_deviceManagedProfiles.contains(_selectedProfile!.profileId))
              Text(context.l10n.thisWorkspaceIsProtectedByThe)
            else
              TextField(
                key: const ValueKey('local_profile_unlock_password'),
                controller: _unlockPassword,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: context.l10n.localProfileMasterPassword,
                  prefixIcon: const Icon(Icons.key_outlined),
                ),
                onSubmitted: (_) => _busy ? null : _unlockSelectedProfile(),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('local_profile_unlock_button'),
                onPressed: _busy ? null : _unlockSelectedProfile,
                icon: const Icon(Icons.lock_open),
                label: Text(
                  _deviceManagedProfiles.contains(_selectedProfile!.profileId)
                      ? context.l10n.openLocalWorkspace
                      : context.l10n.unlockLocalProfile,
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 26),
        Text(context.l10n.createNewProfile, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('local_profile_create_password'),
          controller: _createPassword,
          obscureText: true,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: context.l10n.masterPasswordAtLeast12Characters,
            prefixIcon: const Icon(Icons.password_outlined),
          ),
          onSubmitted: (_) => _busy ? null : _createProfile(),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('local_profile_create_button'),
            onPressed: _busy ? null : _createProfile,
            icon: const Icon(Icons.add),
            label: Text(context.l10n.createAndUnlock),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
      ],
    ],
  );

  Widget _profileTile(LocalProfileRecord profile) {
    final selected = _selectedProfile?.profileId == profile.profileId;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('local_profile_${profile.profileId}'),
        selected: selected,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.lock_outline,
          color: selected ? context.palette.lime : context.palette.muted,
        ),
        title: Text(context.l10n.localProfileSubstring2(profile.profileId.substring(0, 8))),
        subtitle: Text(context.l10n.createdFormatdate(_formatDate(profile.createdAt))),
        trailing: const Icon(Icons.chevron_right),
        onTap: _busy
            ? null
            : () => setState(() {
                _selectedProfile = profile;
                _unlockPassword.clear();
                _pageError = null;
              }),
      ),
    );
  }

  Widget _buildHosts(UnlockedLocalProfile profile) {
    final query = _homeSearch.text.trim().toLowerCase();
    final groupLabels = hostSearchGroupLabels(
      _groups.map((entry) => entry.group),
    );
    QuickConnectRequest? command;
    try {
      command = QuickConnectRequest.parse(_homeSearch.text);
    } on FormatException {
      // HostSearchField displays syntax guidance while typing.
    }
    final hosts = _hosts
        .where(
          (host) => command != null
              ? command.matches(host)
              : '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')} ${groupLabels[host.groupId] ?? ''}'
                    .toLowerCase()
                    .contains(query),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: HostSearchField(
            fieldKey: const ValueKey('local_home_search'),
            controller: _homeSearch,
            onChanged: (_) => setState(() {}),
            onConnect: (request) => unawaited(_quickConnect(request)),
            onSearchSubmitted: hosts.isEmpty
                ? null
                : () => unawaited(_connectLocalHost(hosts.first)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: HomeAddSharingRow(
            idPrefix: 'local',
            enabled: !_busy,
            onAddHost: _addHost,
            onLaunchShell: (launch) => _openConsole(shell: launch),
            onSerialConsole: _quickConnect,
            // A local Profile has no Vault members or presence: show the
            // truthful local-only indicator, never other users.
            sharing: HomeSharingCluster(
              idPrefix: 'local',
              snapshot: const HomeSharingSnapshot.local(),
              onOpenDetails: () =>
                  unawaited(showHomeLocalSharingDetails(context)),
            ),
          ),
        ),
        WindowCombinationsStrip(
          key: ValueKey('local-combinations-${profile.record.profileId}'),
          load: _loadWindowCombinations,
          open: _openWindowCombination,
          busy: _openingCombination,
          remove: (recipe) async {
            try {
              await _changeWindowCombinations(
                (values) => values.where((r) => r.id != recipe.id).toList(),
              );
            } catch (_) {
              _showMessage(currentL10n.couldntDeleteTheWindowSet);
            }
          },
        ),
        if (_groups.isNotEmpty || _groupConnecting)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                for (final group in _groups)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ActionChip(
                          key: ValueKey('local_host_group_${group.id}'),
                          avatar: const Icon(Icons.folder_outlined, size: 16),
                          label: Text(group.name),
                          onPressed: _busy || _groupConnecting || kIsWeb
                              ? null
                              : () => _connectGroup(group),
                        ),
                        _groupMenu(group),
                      ],
                    ),
                  ),
                if (_groupConnecting)
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _groupConnectionGeneration++),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(context.l10n.stopConnecting),
                  ),
              ],
            ),
          ),
        if (kIsWeb) _WebLocalVaultSshNotice(onReturnToWorkspace: _exit),
        if (_busy) const LinearProgressIndicator(),
        if (_hostListError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _hostListError!,
                      key: const ValueKey('local_host_list_error'),
                      style: TextStyle(color: context.palette.orange),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('local_host_list_retry'),
                    onPressed: _busy ? null : _retryHostList,
                    icon: const Icon(Icons.refresh),
                    label: Text(context.l10n.retryRefresh),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: _hosts.isEmpty
              ? _EmptyState(
                  icon: Icons.dns_outlined,
                  title: context.l10n.noHostsYet,
                  description: context.l10n.addHostDetailsToStoreThem,
                )
              : hosts.isEmpty
              ? Center(child: Text(context.l10n.noMatchingHosts))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final metrics = HostCardMetrics.of(context);
                    const padding = EdgeInsets.fromLTRB(20, 8, 20, 24);
                    final grid = _hostGrid &&
                        constraints.maxWidth - padding.horizontal >= 360;
                    return GridView.builder(
                      key: const ValueKey('local_host_list'),
                      padding: padding,
                      gridDelegate: grid
                          ? metrics.gridDelegate(
                              constraints.maxWidth - padding.horizontal,
                            )
                          : SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 1,
                              mainAxisExtent: metrics.extent(withMeta: false),
                              crossAxisSpacing: HostCardMetrics.spacing,
                              mainAxisSpacing: HostCardMetrics.spacing,
                            ),
                      itemCount: hosts.length,
                      itemBuilder: (_, index) =>
                          _hostTile(hosts[index], metrics, showMeta: grid),
                    );
                  },
                ),
        ),
      ],
    );
  }

  List<WorkspaceAction> _hostActions(HostRecord host) => [
    if (!kIsWeb)
      WorkspaceAction(
        'local_host_connect',
        context.l10n.connectDirectFromThisDevice,
        Icons.terminal,
        () => _connectLocalHost(host),
        enabled: !_busy,
      ),
    if (!kIsWeb && host.protocol == HostProtocol.ssh) ...[
      WorkspaceAction(
        'local_host_sftp',
        context.l10n.sftpFileManager,
        Icons.folder_open_outlined,
        () => _openHostFiles(host),
        enabled: !_busy,
      ),
      WorkspaceAction(
        'local_host_scp_upload',
        context.l10n.scpFileManager,
        Icons.upload_file_outlined,
        () => _openHostFiles(host, scpDirection: SshTransferDirection.upload),
        enabled: !_busy,
      ),
    ],
    if (host.protocol == HostProtocol.ssh)
      WorkspaceAction(
        'local_host_port_forwarding',
        context.l10n.portForwarding,
        Icons.hub_outlined,
        () => _openPortForwarding(host, session: _uniqueLiveSessionFor(host)),
        enabled: !_busy,
      ),
    WorkspaceAction(
      'local_host_edit',
      context.l10n.edit,
      Icons.edit_outlined,
      () => _editHost(host),
      enabled: !_busy,
    ),
    WorkspaceAction(
      'local_host_properties',
      context.l10n.properties,
      Icons.info_outline,
      () => showHostProperties(context, host),
    ),
    WorkspaceAction(
      'local_host_delete',
      context.l10n.delete,
      Icons.delete_outline,
      () => _deleteHost(host),
      enabled: !_busy,
      destructive: true,
    ),
  ];

  Widget _hostTile(
    HostRecord host,
    HostCardMetrics metrics, {
    required bool showMeta,
  }) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    child: InkWell(
      key: ValueKey('local_host_${host.id}'),
      onTap: _busy || kIsWeb ? null : () => _connectLocalHost(host),
      onSecondaryTapDown: (event) => showWorkspaceContextMenu(
        context,
        event.globalPosition,
        _hostActions(host),
      ),
      child: Padding(
        padding: HostCardMetrics.padding.copyWith(right: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.palette.accent.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(HostCardMetrics.iconPadding),
                    child: HostSystemIcon(
                      host: host,
                      size: metrics.glyphSize,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                        '${host.username}@${host.address}:${host.port}',
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
                WorkspaceOverflowMenu(
                  tooltip: context.l10n.hostActions,
                  actions: _hostActions(host),
                  child: SizedBox.square(
                    dimension: metrics.buttonExtent,
                    child: const Icon(Icons.more_horiz, size: 18),
                  ),
                ),
              ],
            ),
            if (showMeta) ...[
              const SizedBox(height: HostCardMetrics.metaGap),
              SizedBox(
                height: metrics.metaHeight,
                child: Text(
                  host.tags.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: metrics.metaTextStrut,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: metrics.metaTextSize,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  /// Home "Keychain": central keys/certificates/passwords of this Profile.
  /// Hosts keep their direct per-host sign-in; this page manages the shared
  /// Credential records hosts and groups reference.
  Widget _buildCredentials(UnlockedLocalProfile profile) {
    List<String> usedBy(String id) => [
      for (final host in _hosts)
        if (host.credentialId == id) context.l10n.quotedHostName(host.name),
      for (final group in _groups)
        if (group.defaultCredentialId == id) context.l10n.groupName(group.name),
    ];
    return KeychainPage(
      entries: [
        for (final credential in _credentials)
          KeychainEntry(
            id: credential.id,
            name: credential.name,
            username: credential.username,
            kind: credential.kind,
            keyFingerprint: credential.fingerprint,
            certificate: credential.certificate,
            usedBy: usedBy(credential.id),
          ),
      ],
      canWrite: true,
      busy: _busy,
      error: _credentialListError,
      onRetry: _busy ? null : _retryCredentialList,
      addButtonKey: const ValueKey('local_credential_add'),
      rowKeyPrefix: 'local_credential_',
      emptyText: context.l10n.noCredentialsYet,
      scopeLabel:
          '${context.l10n.r7NavKeychainSubtitle} · ${context.l10n.profileSubstring(profile.record.profileId.substring(0, 8))}',
      onAdd: _addCredential,
      onEdit: (entry) {
        final summary = _credentials
            .where((item) => item.id == entry.id)
            .firstOrNull;
        if (summary != null) unawaited(_editCredential(summary));
      },
      onDelete: (entry) {
        final summary = _credentials
            .where((item) => item.id == entry.id)
            .firstOrNull;
        if (summary != null) unawaited(_deleteCredential(summary));
      },
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: OutlinedButton.icon(
          key: const ValueKey('local_profile_lock_button'),
          onPressed: _busy ? null : _lockProfile,
          icon: const Icon(Icons.lock_outline),
          label: Text(context.l10n.lockAndReturnToProfiles),
        ),
      ),
    );
  }

  List<(LocalGroupRecord, int)> _flattenGroups() {
    final children = <String?, List<LocalGroupRecord>>{};
    for (final group in _groups) {
      children.putIfAbsent(group.parentId, () => []).add(group);
    }
    for (final siblings in children.values) {
      siblings.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }
    final result = <(LocalGroupRecord, int)>[];
    final visited = <String>{};
    void visit(String? parentId, int depth) {
      for (final group in children[parentId] ?? const <LocalGroupRecord>[]) {
        if (!visited.add(group.id)) continue;
        result.add((group, depth));
        visit(group.id, depth + 1);
      }
    }

    visit(null, 0);
    // Authenticated repository validation should make this unreachable. Keep
    // malformed legacy data visible rather than silently hiding records.
    for (final group in _groups) {
      if (visited.add(group.id)) result.add((group, 0));
    }
    return result;
  }

  String _groupParentLabel(LocalGroupRecord group) {
    final parentId = group.parentId;
    if (parentId == null) return context.l10n.topLevelGroup;
    final parent = _groups.where((item) => item.id == parentId).firstOrNull;
    return parent == null ? context.l10n.parentMissing : context.l10n.parentName(parent.name);
  }

  Widget _buildSnippets(UnlockedLocalProfile profile) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.snippets,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text(
                    context.l10n.profileSubstring(profile.record.profileId.substring(0, 8)),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.palette.muted),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('local_snippet_add'),
              onPressed: _busy ? null : _addSnippet,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.addSnippet),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            context.l10n.localModeOnlyManagesEncryptedSnippets,
            key: const ValueKey('local_snippet_execution_notice'),
          ),
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_snippetListError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _snippetListError!,
                    key: const ValueKey('local_snippet_list_error'),
                    style: TextStyle(color: context.palette.orange),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('local_snippet_list_retry'),
                  onPressed: _busy ? null : _retrySnippetList,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.l10n.retryRefresh),
                ),
              ],
            ),
          ),
        ),
      Expanded(
        child: _snippetListError != null
            ? const SizedBox.shrink()
            : _snippets.isEmpty
            ? _EmptyState(
                icon: Icons.code_rounded,
                title: context.l10n.noSnippetsYet,
                description: context.l10n.addAScriptOrAStructured,
              )
            : ListView.separated(
                key: const ValueKey('local_snippet_list'),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: _snippets.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final snippet = _snippets[index];
                  final modeLabel =
                      snippet.executionMode == SnippetExecutionMode.script
                      ? context.l10n.scriptShell(snippet.shell)
                      : context.l10n.structuredBashCommand;
                  final tags = snippet.tags.isEmpty
                      ? ''
                      : ' · ${snippet.tags.join(', ')}';
                  return Card(
                    child: ListTile(
                      key: ValueKey('local_snippet_${snippet.id}'),
                      leading: const CircleAvatar(
                        child: Icon(Icons.code_rounded),
                      ),
                      title: Text(snippet.title),
                      subtitle: Text('$modeLabel$tags'),
                      onTap: _busy ? null : () => _editSnippet(snippet),
                      trailing: PopupMenuButton<String>(
                        popUpAnimationStyle: AppMotion.menuStyle(context),
                        enabled: !_busy,
                        tooltip: context.l10n.snippetActionsTitle(snippet.title),
                        onSelected: (value) {
                          if (value == 'edit') {
                            unawaited(_editSnippet(snippet));
                          }
                          if (value == 'delete') {
                            unawaited(_deleteSnippet(snippet));
                          }
                        },
                        itemBuilder: (_) => [
                          appMenuItem(context,value: 'edit', child: Text(context.l10n.editSnippet)),
                          appMenuItem(context,value: 'delete', child: Text(context.l10n.deleteSnippet)),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: OutlinedButton.icon(
          key: const ValueKey('local_profile_lock_button'),
          onPressed: _busy ? null : _lockProfile,
          icon: const Icon(Icons.lock_outline),
          label: Text(context.l10n.lockAndReturnToProfiles),
        ),
      ),
    ],
  );

  Widget _buildPreferences() => SettingsScaffold(
    key: const ValueKey('local_profile_preferences'),
    sections: [
      SettingsSection(
        id: 'workspace',
        title: context.l10n.workspace,
        icon: Icons.dashboard_outlined,
        description: context.l10n.chooseTheWorkspaceModeAndThe,
        builder: (_) => SettingsCards(
          children: [
            const SettingsCard(child: AppLanguageSettings()),
            ScopedWorkspaceModeSettings(onSwitch: _exit),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<_LocalWorkspace>(
                    key: const ValueKey('local_default_section_dropdown'),
                    initialValue: _defaultSectionChoice,
                    decoration: InputDecoration(labelText: context.l10n.defaultWorkspace),
                    items: [
                      DropdownMenuItem(
                        value: _LocalWorkspace.hosts,
                        child: Text(context.l10n.hosts),
                      ),
                      DropdownMenuItem(
                        value: _LocalWorkspace.credentials,
                        child: Text(context.l10n.credentials),
                      ),
                      DropdownMenuItem(
                        value: _LocalWorkspace.groups,
                        child: Text(context.l10n.groups),
                      ),
                      DropdownMenuItem(
                        value: _LocalWorkspace.snippets,
                        child: Text(context.l10n.snippet),
                      ),
                    ],
                    onChanged: _busy || _preferenceLoadError != null
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() => _defaultSectionChoice = value);
                          },
                  ),
                  if (_preferenceLoadError != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _preferenceLoadError!,
                        key: const ValueKey('local_preference_load_error'),
                        style: TextStyle(color: context.palette.orange),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('local_preference_retry'),
                        onPressed: _busy
                            ? null
                            : _retryDefaultSectionPreference,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.retryReading),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('local_preference_save'),
                      onPressed: _busy || _preferenceLoadError != null
                          ? null
                          : _saveDefaultSectionPreference,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(context.l10n.saveDefaultWorkspace),
                    ),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
            Card(
              child: ListTile(
                key: const ValueKey('local_profile_credentials_toggle'),
                title: Text(context.l10n.legacySharedCredentials),
                subtitle: Text(context.l10n.passwordsAndKeysForNewHosts),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    setState(() => _workspace = _LocalWorkspace.credentials),
              ),
            ),
          ],
        ),
      ),
      // ACCOUNT worker: local mode explains sync and routes to sign-in.
      SettingsSection(
        id: accountSettingsSectionId,
        title: context.l10n.accountSettingsTitle,
        icon: Icons.account_circle_outlined,
        description: context.l10n.accountSettingsDescription,
        builder: (_) => LocalAccountSettingsPanel(onSignIn: _exit),
      ),
      SettingsSection(
        id: 'mcp',
        title: 'AI / MCP',
        icon: Icons.hub_outlined,
        description: context.l10n.letExternalAiAccessTheCurrent,
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
            if (_preferenceLoadError != null) _preferenceLoadErrorCard(),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.terminalFontSize, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    key: const ValueKey('local_terminal_font_size_dropdown'),
                    initialValue: _terminalFontSizeChoice,
                    decoration: InputDecoration(labelText: context.l10n.terminalFontSize2),
                    items:
                        (VaultPreferenceRecord.supportedTerminalFontSizes
                                .toList()
                              ..sort())
                            .map(
                              (size) => DropdownMenuItem<int>(
                                value: size,
                                child: Text('$size px'),
                              ),
                            )
                            .toList(growable: false),
                    onChanged: _busy || _preferenceLoadError != null
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() => _terminalFontSizeChoice = value);
                          },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('local_terminal_font_size_save'),
                      onPressed:
                          _busy ||
                              _preferenceLoadError != null ||
                              !_terminalFontSizeDirty
                          ? null
                          : _saveTerminalFontSizePreference,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(context.l10n.saveTerminalFontSize),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.terminalTheme, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  TerminalSyncedThemeSelector(
                    key: const ValueKey('local_terminal_theme_dropdown'),
                    selected: _terminalThemeChoice,
                    persisted: _savedTerminalThemeChoice,
                    onSelected: _busy || _preferenceLoadError != null
                        ? null
                        : (value) =>
                              setState(() => _terminalThemeChoice = value),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('local_terminal_theme_save'),
                      onPressed:
                          _busy ||
                              _preferenceLoadError != null ||
                              !_terminalThemeDirty
                          ? null
                          : _saveTerminalThemePreference,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(context.l10n.saveTerminalTheme),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
            SettingsCard(
              child: TerminalPaletteGallery(synced: _savedTerminalThemeChoice),
            ),
          ],
        ),
      ),
      SettingsSection(
        id: settingsShortcutsSectionId,
        title: context.l10n.settingsThemeShortcutsTitle,
        icon: Icons.keyboard_outlined,
        description: context.l10n.settingsThemeShortcutsDescription,
        builder: (_) => SettingsCards(
          children: [
            if (_preferenceLoadError != null) _preferenceLoadErrorCard(),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.terminalShortcuts, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.useTheModAltAndShift,
                  ),
                  const SizedBox(height: 8),
                  TerminalShortcutEditor(
                    controllers: _terminalShortcutControllers,
                    fieldKey: (action) =>
                        ValueKey('local_terminal_shortcut_${action.name}'),
                    enabled: !_busy && _preferenceLoadError == null,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  if (_terminalShortcutDraft == null)
                    Text(
                      context.l10n.invalidShortcutUseSupportedLetterDigit,
                      key: const ValueKey(
                        'local_terminal_shortcuts_validation_error',
                      ),
                      style: TextStyle(color: context.palette.red),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('local_terminal_shortcuts_save'),
                        onPressed:
                            _busy ||
                                _preferenceLoadError != null ||
                                _terminalShortcutDraft == null ||
                                !_terminalShortcutsDirty
                            ? null
                            : _saveTerminalShortcutsPreference,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(context.l10n.saveShortcuts),
                      ),
                      TextButton.icon(
                        key: const ValueKey(
                          'local_terminal_shortcuts_restore_defaults',
                        ),
                        onPressed: _busy || _preferenceLoadError != null
                            ? null
                            : () {
                                setState(() {
                                  _terminalShortcutBindings =
                                      TerminalShortcutBindings.defaults;
                                  for (final action
                                      in TerminalShortcutAction.values) {
                                    _terminalShortcutControllers[action]!.text =
                                        TerminalShortcutBindings.defaults
                                            .chordFor(action);
                                  }
                                });
                              },
                        icon: const Icon(Icons.restart_alt),
                        label: Text(context.l10n.restoreDefaultShortcuts),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  /// Preference read error with retry, shown on each preference category.
  Widget _preferenceLoadErrorCard() => SettingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_preferenceLoadError != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _preferenceLoadError!,
              key: const ValueKey('local_preference_load_error'),
              style: TextStyle(color: context.palette.orange),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('local_preference_retry'),
              onPressed: _busy ? null : _retryDefaultSectionPreference,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retryReading),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _buildGroups(UnlockedLocalProfile profile) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.groups, style: Theme.of(context).textTheme.headlineSmall),
                  Text(
                    context.l10n.profileSubstring(profile.record.profileId.substring(0, 8)),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.palette.muted),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('local_group_add'),
              onPressed: _busy ? null : _addGroup,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.addGroup),
            ),
          ],
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_groupListError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _groupListError!,
                    key: const ValueKey('local_group_list_error'),
                    style: TextStyle(color: context.palette.orange),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('local_group_list_retry'),
                  onPressed: _busy ? null : _retryGroupList,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.l10n.retryRefresh),
                ),
              ],
            ),
          ),
        ),
      Expanded(
        child: _groupListError != null
            ? const SizedBox.shrink()
            : _groups.isEmpty
            ? _EmptyState(
                icon: Icons.folder_outlined,
                title: context.l10n.noGroupsYet,
                description: context.l10n.createGroupsToOrganizeHostsGroups,
              )
            : ListView.separated(
                key: const ValueKey('local_group_list'),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: _flattenGroups().length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final (group, depth) = _flattenGroups()[index];
                  final childrenCount = _groups
                      .where((item) => item.parentId == group.id)
                      .length;
                  final hostsCount = _hosts
                      .where((item) => item.groupId == group.id)
                      .length;
                  return Card(
                    child: ListTile(
                      key: ValueKey('local_group_${group.id}'),
                      contentPadding: EdgeInsetsDirectional.only(
                        start: 16 + depth * 22,
                        end: 12,
                      ),
                      leading: CircleAvatar(
                        radius: AppDensity.of(context).isCompact ? 16 : 18,
                        backgroundColor: group.color == 0
                            ? context.palette.surfaceRaised
                            : Color(0xFF000000 | group.color),
                        child: Icon(
                          Icons.folder_outlined,
                          size: AppDensity.of(context).iconMd,
                        ),
                      ),
                      title: Text(group.name),
                      subtitle: Text(
                        context.l10n.groupparentlabelHostscountHostsChildrencountSubgroups(_groupParentLabel(group), hostsCount, childrenCount),
                      ),
                      onTap: _busy || _groupConnecting || kIsWeb
                          ? null
                          : () => _connectGroup(group),
                      trailing: _groupMenu(group),
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: OutlinedButton.icon(
          key: const ValueKey('local_profile_lock_button'),
          onPressed: _busy ? null : _lockProfile,
          icon: const Icon(Icons.lock_outline),
          label: Text(context.l10n.lockAndReturnToProfiles),
        ),
      ),
    ],
  );
}

class _WebLocalVaultSshNotice extends StatelessWidget {
  const _WebLocalVaultSshNotice({required this.onReturnToWorkspace});

  final VoidCallback onReturnToWorkspace;

  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('local_web_ssh_unavailable_notice'),
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    color: context.palette.surfaceRaised,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: context.palette.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.webLocalvaultDoesntSupportSshSftp,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.localvaultInTheBrowserCanManage,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              key: const ValueKey('local_web_ssh_workspace_button'),
              onPressed: onReturnToWorkspace,
              icon: const Icon(Icons.arrow_back),
              label: Text(context.l10n.backToWorkspaceSelection),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ProfileListError extends StatelessWidget {
  const _ProfileListError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('local_profile_catalog_error'),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: context.palette.orange),
          const SizedBox(height: 10),
          Text(message),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('local_profile_retry_catalog'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.retryReadingProfiles),
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
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: AppDensity.of(context).pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppDensity.of(context).isCompact ? 32 : 36,
              color: context.palette.muted,
            ),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: context.palette.muted),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LocalArchivePasswordDialog extends StatefulWidget {
  const _LocalArchivePasswordDialog({
    required this.confirm,
    required this.creating,
  });

  final bool confirm;
  final bool creating;

  @override
  State<_LocalArchivePasswordDialog> createState() =>
      _LocalArchivePasswordDialogState();
}

class _LocalArchivePasswordDialogState
    extends State<_LocalArchivePasswordDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _continue() {
    final value = _password.text;
    if (value.length > LocalProfileArchiveCodec.maxPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseCanBe);
      return;
    }
    final passwordBytes = utf8.encode(value);
    final passwordLength = passwordBytes.length;
    passwordBytes.fillRange(0, passwordBytes.length, 0);
    if (passwordLength > LocalProfileArchiveCodec.maxPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseCanBe);
      return;
    }
    if (passwordLength < LocalProfileArchiveCodec.minPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseMustBe);
      return;
    }
    if (widget.confirm && value != _confirmation.text) {
      setState(() => _error = context.l10n.theLocalArchivePassphrasesDontMatch);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.creating ? context.l10n.setLocalArchivePassphrase : context.l10n.enterLocalArchivePassphrase),
    content: SizedBox(
      width: appDialogWidth(context, 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('local_archive_password'),
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: context.l10n.localArchivePassphrase),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('local_archive_password_confirm'),
                controller: _confirmation,
                obscureText: true,
                decoration: InputDecoration(labelText: context.l10n.confirmLocalArchivePassphrase),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.thisPassphraseIsSeparateFromThe,
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        key: const ValueKey('local_archive_password_continue'),
        onPressed: _continue,
        child: Text(context.l10n.continueLabel2),
      ),
    ],
  );
}

class _LocalGroupEditorDialog extends StatefulWidget {
  const _LocalGroupEditorDialog({
    required this.groups,
    required this.credentials,
    this.existing,
  });

  final List<LocalGroupRecord> groups;
  final List<LocalCredentialSummary> credentials;
  final GroupRecord? existing;

  @override
  State<_LocalGroupEditorDialog> createState() =>
      _LocalGroupEditorDialogState();
}

class _LocalGroupEditorDialogState extends State<_LocalGroupEditorDialog> {
  static const _palette = <int>[
    0,
    0x4FC3F7,
    0x4DB6AC,
    0x81C784,
    0xFFD54F,
    0xFF8A65,
    0xBA68C8,
  ];

  final _uuid = const Uuid();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _parentId = widget.existing?.parentId ?? '';
  late String _defaultCredentialId = widget.existing?.defaultCredentialId ?? '';
  late int _color = widget.existing?.color ?? 0;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool _wouldCreateCycle(String candidateParentId) {
    final existingId = widget.existing?.id;
    if (existingId == null) return false;
    if (candidateParentId == existingId) return true;
    final byId = {for (final group in widget.groups) group.id: group};
    var cursor = byId[candidateParentId]?.parentId;
    final visited = <String>{candidateParentId};
    while (cursor != null && visited.add(cursor)) {
      if (cursor == existingId) return true;
      cursor = byId[cursor]?.parentId;
    }
    return false;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.enterAGroupName);
      return;
    }
    if (_parentId.isNotEmpty && _wouldCreateCycle(_parentId)) {
      setState(() => _error = context.l10n.aGroupCantBeMovedInto);
      return;
    }
    Navigator.pop(
      context,
      GroupRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        name: name,
        color: _color,
        parentId: _parentId.isEmpty ? null : _parentId,
        defaultCredentialId: _defaultCredentialId.isEmpty
            ? null
            : _defaultCredentialId,
        manifest: widget.existing?.manifest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = {..._palette, _color}.toList()..sort();
    final parents =
        widget.groups.where((group) => !_wouldCreateCycle(group.id)).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return AlertDialog(
      title: Text(widget.existing == null ? context.l10n.addLocalGroup : context.l10n.editLocalGroup),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('local_group_name'),
                controller: _name,
                autofocus: true,
                maxLength: 128,
                decoration: InputDecoration(labelText: context.l10n.groupName2),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('local_group_parent'),
                initialValue: _parentId,
                decoration: InputDecoration(labelText: context.l10n.parentGroup),
                items: [
                  DropdownMenuItem(value: '', child: Text(context.l10n.topLevelGroup)),
                  ...parents.map(
                    (group) => DropdownMenuItem(
                      value: group.id,
                      child: Text(group.name),
                    ),
                  ),
                  if (_parentId.isNotEmpty &&
                      !parents.any((group) => group.id == _parentId))
                    DropdownMenuItem(
                      value: _parentId,
                      child: Text(context.l10n.previousParentUnavailable),
                    ),
                ],
                onChanged: (value) => setState(() => _parentId = value ?? ''),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('local_group_default_credential'),
                initialValue: _defaultCredentialId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.defaultCredential,
                  helperText: context.l10n.whenAHostDoesntSelectA,
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(context.l10n.noDefaultCredential)),
                  ...widget.credentials.map(
                    (credential) => DropdownMenuItem(
                      value: credential.id,
                      child: Text(
                        '${credential.name} · ${credential.username} · ${credential.kind == AuthKind.password ? context.l10n.password2 : context.l10n.sshPrivateKey}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (_defaultCredentialId.isNotEmpty &&
                      !widget.credentials.any(
                        (credential) => credential.id == _defaultCredentialId,
                      ))
                    DropdownMenuItem(
                      value: _defaultCredentialId,
                      child: Text(context.l10n.previousDefaultCredentialUnavailable),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _defaultCredentialId = value ?? '';
                }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                key: const ValueKey('local_group_color'),
                initialValue: _color,
                decoration: InputDecoration(labelText: context.l10n.color),
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
                                ? context.l10n.defaultLabel
                                : '#${color.toRadixString(16).toUpperCase()}',
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _color = value ?? 0),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      key: const ValueKey('local_group_editor_error'),
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
          key: const ValueKey('local_group_cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('local_group_save'),
          onPressed: _save,
          child: Text(context.l10n.saveGroup),
        ),
      ],
    );
  }
}

class _LocalSnippetEditorDialog extends StatefulWidget {
  const _LocalSnippetEditorDialog({required this.credentials, this.existing});

  final SnippetRecord? existing;
  final List<LocalCredentialSummary> credentials;

  @override
  State<_LocalSnippetEditorDialog> createState() =>
      _LocalSnippetEditorDialogState();
}

class _LocalSnippetEditorDialogState extends State<_LocalSnippetEditorDialog> {
  final _uuid = const Uuid();
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.existing?.body ?? '',
  );
  late final TextEditingController _tags = TextEditingController(
    text: widget.existing?.tags.join(', ') ?? '',
  );
  late final TextEditingController _program = TextEditingController(
    text: widget.existing?.program ?? '',
  );
  late final TextEditingController _parameters = TextEditingController(
    text: jsonEncode(
      widget.existing?.parameters.map((item) => item.toJson()).toList() ??
          const [],
    ),
  );
  late final TextEditingController _arguments = TextEditingController(
    text: jsonEncode(
      widget.existing?.arguments.map((item) => item.toJson()).toList() ??
          const [],
    ),
  );
  late SnippetExecutionMode _mode =
      widget.existing?.executionMode ?? SnippetExecutionMode.script;
  late String _shell = widget.existing?.shell ?? 'bash';
  String? _error;

  @override
  void dispose() {
    // Snippets can contain sensitive command literals while the profile is
    // unlocked. Clear editable text when the dialog closes.
    _body.clear();
    _parameters.clear();
    _arguments.clear();
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    _program.dispose();
    _parameters.dispose();
    _arguments.dispose();
    super.dispose();
  }

  List<Object?> _jsonArray(TextEditingController controller, String label) {
    final decoded = jsonDecode(controller.text);
    if (decoded is! List) {
      throw FormatException('$label must be a JSON array.');
    }
    return decoded.cast<Object?>();
  }

  void _save() {
    try {
      final title = _title.text.trim();
      if (title.isEmpty) throw FormatException(context.l10n.enterASnippetTitle);
      final parameters = _mode == SnippetExecutionMode.script
          ? const <SnippetParameter>[]
          : _jsonArray(
              _parameters,
              context.l10n.parameterDefinitions,
            ).map(SnippetParameter.fromJson).toList(growable: false);
      final arguments = _mode == SnippetExecutionMode.script
          ? const <SnippetArgument>[]
          : _jsonArray(
              _arguments,
              context.l10n.argumentList,
            ).map(SnippetArgument.fromJson).toList(growable: false);
      for (final parameter in parameters) {
        if (parameter.type != SnippetParameterType.credentialSecret) continue;
        final credential = widget.credentials
            .where((item) => item.id == parameter.credentialId)
            .firstOrNull;
        if (credential == null || credential.kind != AuthKind.password) {
          throw FormatException(context.l10n.credentialParameterNameMustReferenceA(parameter.name));
        }
      }
      final candidate = SnippetRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        title: title,
        body: _mode == SnippetExecutionMode.script ? _body.text : '',
        shell: _shell,
        executionMode: _mode,
        program: _mode == SnippetExecutionMode.script ? '' : _program.text,
        parameters: parameters,
        arguments: arguments,
        tags: _tags.text
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList(growable: false),
        manifest: widget.existing?.manifest,
      );
      validateSnippetDefinition(candidate);
      if (_mode == SnippetExecutionMode.script &&
          candidate.body.trim().isEmpty) {
        throw FormatException(context.l10n.enterTheScriptBody);
      }
      Navigator.pop(context, candidate);
    } on Object catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? context.l10n.addLocalSnippet : context.l10n.editLocalSnippet),
    content: SizedBox(
      width: appDialogWidth(context, 600),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('local_snippet_title'),
              controller: _title,
              autofocus: true,
              maxLength: 128,
              decoration: InputDecoration(labelText: context.l10n.snippetTitle2),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<SnippetExecutionMode>(
              key: const ValueKey('local_snippet_mode'),
              initialValue: _mode,
              decoration: InputDecoration(labelText: context.l10n.executionType),
              items: [
                DropdownMenuItem(
                  value: SnippetExecutionMode.script,
                  child: Text(context.l10n.script),
                ),
                DropdownMenuItem(
                  value: SnippetExecutionMode.bashCommand,
                  child: Text(context.l10n.structuredBashCommand),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _mode = value;
                  if (value == SnippetExecutionMode.bashCommand) {
                    _shell = 'bash';
                  }
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 10),
            if (_mode == SnippetExecutionMode.script) ...[
              DropdownButtonFormField<String>(
                key: const ValueKey('local_snippet_shell'),
                initialValue: _shell,
                decoration: InputDecoration(labelText: context.l10n.shellLabel),
                items: [
                  const DropdownMenuItem(value: 'bash', child: Text('Bash')),
                  const DropdownMenuItem(
                    value: 'powershell',
                    child: Text('PowerShell'),
                  ),
                  if (_shell != 'bash' && _shell != 'powershell')
                    DropdownMenuItem(
                      value: _shell,
                      child: Text(context.l10n.existingShellLabelShell(_shell)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _shell = value);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('local_snippet_body'),
                controller: _body,
                minLines: 5,
                maxLines: 12,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: context.l10n.scriptBody,
                  alignLabelWithHint: true,
                ),
              ),
            ] else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(context.l10n.structuredCommandsSupportBashOnlyHere),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('local_snippet_program'),
                controller: _program,
                decoration: InputDecoration(labelText: context.l10n.program),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('local_snippet_parameters'),
                controller: _parameters,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: context.l10n.parameterDefinitionsJsonArray,
                  helperText: context.l10n.textParametersAndPasswordCredentialReferences,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('local_snippet_arguments'),
                controller: _arguments,
                minLines: 3,
                maxLines: 7,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: context.l10n.argumentsJsonArray,
                  alignLabelWithHint: true,
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('local_snippet_tags'),
              controller: _tags,
              decoration: InputDecoration(labelText: context.l10n.tagsCommaSeparated),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    key: const ValueKey('local_snippet_editor_error'),
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
        key: const ValueKey('local_snippet_cancel'),
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        key: const ValueKey('local_snippet_save'),
        onPressed: _save,
        child: Text(context.l10n.saveEncryptedSnippet),
      ),
    ],
  );
}

class _LocalCredentialEditorDialog extends StatefulWidget {
  const _LocalCredentialEditorDialog({this.existing});

  final CredentialRecord? existing;

  @override
  State<_LocalCredentialEditorDialog> createState() =>
      _LocalCredentialEditorDialogState();
}

class _LocalCredentialEditorDialogState
    extends State<_LocalCredentialEditorDialog> {
  final _uuid = const Uuid();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();
  late final TextEditingController _certificate = TextEditingController(
    text: widget.existing?.certificate ?? '',
  );
  late AuthKind _kind = widget.existing?.kind ?? AuthKind.password;
  bool _revealSecret = false;
  String? _error;

  @override
  void dispose() {
    _secret.clear();
    _passphrase.clear();
    _certificate.dispose();
    _name.dispose();
    _username.dispose();
    _secret.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final username = _username.text.trim();
    final secret = _secret.text.isEmpty ? null : _secret.text;
    final passphrase = _passphrase.text.isEmpty ? null : _passphrase.text;
    if (name.isEmpty || username.isEmpty) {
      setState(() => _error = context.l10n.enterACredentialNameAndUser);
      return;
    }
    if ((_kind == AuthKind.password || _kind == AuthKind.privateKey) &&
        secret == null &&
        (widget.existing == null || widget.existing!.kind != _kind)) {
      setState(
        () => _error = _kind == AuthKind.password ? context.l10n.enterAPassword : context.l10n.enterTheSshPrivateKey,
      );
      return;
    }
    KeychainKeyCheck? keyCheck;
    if (_kind == AuthKind.privateKey) {
      final sameKind = widget.existing?.kind == AuthKind.privateKey;
      final effectiveKey = secret ?? (sameKind ? widget.existing?.privateKey : null);
      final effectivePassphrase =
          passphrase ?? (sameKind ? widget.existing?.passphrase : null);
      if (effectiveKey != null) {
        keyCheck = checkKeychainKey(
          privateKey: effectiveKey,
          passphrase: effectivePassphrase,
          certificateText: _certificate.text,
        );
        if (keyCheck.error != null) {
          setState(() => _error = keyCheck!.error);
          return;
        }
      }
    }
    Navigator.pop(
      context,
      CredentialRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        name: name,
        username: username,
        kind: _kind,
        secret: _kind == AuthKind.password ? secret : null,
        privateKey: _kind == AuthKind.privateKey ? secret : null,
        passphrase: _kind == AuthKind.privateKey ? passphrase : null,
        fingerprint: keyCheck?.fingerprint ??
            (_kind == AuthKind.password ? null : widget.existing?.fingerprint),
        certificate: _kind == AuthKind.privateKey ? keyCheck?.certificate : null,
        manifest: widget.existing?.manifest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? context.l10n.addLocalCredential : context.l10n.editLocalCredential),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('local_credential_name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: context.l10n.credentialName),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('local_credential_username'),
              controller: _username,
              decoration: InputDecoration(labelText: context.l10n.userName),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<AuthKind>(
              key: const ValueKey('local_credential_kind'),
              initialValue: _kind,
              decoration: InputDecoration(labelText: context.l10n.authenticationType),
              items: [
                DropdownMenuItem(value: AuthKind.password, child: Text(context.l10n.password2)),
                DropdownMenuItem(
                  value: AuthKind.privateKey,
                  child: Text(context.l10n.sshPrivateKey),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              key: ValueKey(
                _kind == AuthKind.password
                    ? 'local_credential_secret'
                    : 'local_credential_private_key',
              ),
              controller: _secret,
              obscureText: !_revealSecret,
              maxLines: _revealSecret && _kind == AuthKind.privateKey ? 5 : 1,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _kind == AuthKind.password ? context.l10n.password2 : context.l10n.sshPrivateKey,
                helperText: widget.existing == null
                    ? null
                    : context.l10n.leaveBlankToKeepTheCurrent,
                suffixIcon: IconButton(
                  tooltip: _revealSecret ? context.l10n.hideKey : context.l10n.showKey,
                  onPressed: () =>
                      setState(() => _revealSecret = !_revealSecret),
                  icon: Icon(
                    _revealSecret ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            if (_kind == AuthKind.privateKey) ...[
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: KeychainKeyFileButton(
                  onLoaded: (text) => setState(() {
                    _secret.text = text;
                    _error = null;
                  }),
                  onError: (message) => setState(() => _error = message),
                ),
              ),
              TextField(
                key: const ValueKey('local_credential_passphrase'),
                controller: _passphrase,
                obscureText: !_revealSecret,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: context.l10n.privateKeyPassphraseOptional),
              ),
              const SizedBox(height: 10),
              KeychainCertificateField(controller: _certificate),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    key: const ValueKey('local_credential_editor_error'),
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
        key: const ValueKey('local_credential_cancel'),
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton.icon(
        key: const ValueKey('local_credential_save'),
        onPressed: _save,
        icon: const Icon(Icons.save_outlined),
        label: Text(context.l10n.saveEncryptedCredential),
      ),
    ],
  );
}

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class _LocalTerminalSession {
  _LocalTerminalSession({
    required this.host,
    required SshConnection connection,
    this.log,
  }) : connection = connection {
    _bindSsh(connection);
  }

  Future<void> attachSsh(SshConnection value, SessionLogRecorder? recorder) async {
    final old = connection;
    await _stdout?.cancel();
    await _stderr?.cancel();
    await old?.close();
    if (_closed) { await value.close(); return; }
    connection = value;
    log = recorder;
    _bindSsh(value);
    connected.value = true;
  }

  void _bindSsh(SshConnection connection) {
    terminal.onOutput = connection.input;
    terminal.onResize = (width, height, _, _) =>
        connection.resize(width, height);
    _stdout = connection.output.listen(
      (text) {
        terminal.write(text);
        log?.output(text);
      },
      onError: (Object error) {
        if (_closed || !identical(this.connection, connection)) return;
        connected.value = false;
        terminal.write(currentL10n.sshOutputStreamError);
        log?.markClosed(SessionLogEndReason.error, error: error);
      },
      onDone: () {
        if (_closed || !identical(this.connection, connection)) return;
        connected.value = false;
        terminal.write(currentL10n.sshConnectionClosed);
        log?.markClosed(SessionLogEndReason.remote);
      },
    );
    _stderr = utf8.decoder
        .bind(connection.session.stderr)
        .listen(
          (text) {
            terminal.write(text);
            log?.output(text);
          },
          onError: (_) => terminal.write(currentL10n.sshErrorStreamUnavailable),
        );
  }

  /// Session-log lifecycle handle (SSH tabs only; null when logging is
  /// unavailable). Output reaches it only if transcript capture was enabled
  /// before this session started.
  SessionLogRecorder? log;
  _LocalTerminalSession.console(
    LocalConsole value, {
    String? title,
    String? serialPort,
    int? baudRate,
    LocalShellLaunch? shell,
  }) : host = HostRecord(
         id: const Uuid().v4(),
         name: title ?? currentL10n.localConsole,
         address: 'localhost',
       ),
       connection = null,
       log = null {
    console = value;
    consoleSerialPort = serialPort;
    consoleBaudRate = baudRate;
    consoleShell = serialPort == null ? shell : null;
    terminal.onOutput = value.input;
    terminal.onResize = (w, h, _, _) => value.resize(w, h);
    _stdout = value.output.listen(
      terminal.write,
      onError: (_) {
        if (!_closed) connected.value = false;
      },
    );
    unawaited(
      value.exitCode.then((code) {
        if (!_closed) {
          connected.value = false;
          terminal.write(currentL10n.consoleExitedCode(code));
        }
      }),
    );
  }
  /// Plaintext Telnet tab. The tab appears immediately in `connecting`
  /// state; [telnetReady] completes when the connection attempt settles.
  /// A late completion after [close] is closed and never attached.
  _LocalTerminalSession.telnet(
    this.host, {
    required TelnetChannelConnector connector,
    this.log,
    VoidCallback? onStateChanged,
  }) : connection = null {
    _onTelnetStateChanged = onStateChanged;
    telnetState = 'connecting';
    connected.value = false;
    terminal.write(telnetPlaintextTerminalNotice(host.endpoint));
    final cancellation = TelnetConnectCancellation();
    _telnetCancellation = cancellation;
    telnetReady = _connectTelnet(connector, cancellation);
  }

  Future<void> _connectTelnet(
    TelnetChannelConnector connector,
    TelnetConnectCancellation cancellation,
  ) async {
    try {
      final session = await TelnetSession.connect(
        host: host.address,
        port: host.port,
        connector: connector,
        cancellation: cancellation,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      if (_closed) {
        await session.close();
        return;
      }
      telnet = session;
      _telnetCancellation = null;
      terminal.onOutput = (text) {
        if (session.input(text) == TelnetInputResult.tooLarge) {
          // Rejected whole; nothing partial was sent.
          terminal.write(
            '\r\n\x1b[33m${currentL10n.telnetInputTooLarge}\x1b[0m\r\n',
          );
        }
      };
      terminal.onResize = (width, height, _, _) =>
          session.resize(width, height);
      _stdout = session.output.listen(
        (text) {
          if (_closed) return;
          terminal.write(text);
          log?.output(text);
        },
        onError: (Object error) {
          if (_closed) return;
          telnetError = error.toString();
          log?.markClosed(SessionLogEndReason.error, error: error);
        },
        onDone: () {
          if (_closed) return;
          telnetState = 'disconnected';
          connected.value = false;
          terminal.write(currentL10n.telnetConnectionClosedTerminal);
          log?.markClosed(SessionLogEndReason.remote);
          _onTelnetStateChanged?.call();
        },
      );
      session.resize(terminal.viewWidth, terminal.viewHeight);
      log?.markConnected();
      telnetState = 'connected';
      connected.value = true;
    } catch (error) {
      if (_closed) return;
      _telnetCancellation = null;
      telnetState = 'failed';
      telnetError = error is TelnetException
          ? error.toString()
          : telnetFailureMessage(TelnetFailure.unreachable);
      log?.markFailed(error);
      terminal.write('\r\n\x1b[31m$telnetError\x1b[0m\r\n');
      _onTelnetStateChanged?.call();
    }
  }

  _LocalTerminalSession.desktop(this.host, DesktopSession value)
    : connection = null,
      log = null {
    desktop = value;
    connected.value = false;
    value.addListener(() {
      if (!_closed) connected.value = value.state == 'connected';
    });
  }
  final String id = const Uuid().v4();
  HostRecord host;
  SshConnection? connection;
  SessionRecovery? recovery;
  LocalConsole? console;
  String? consoleSerialPort;
  int? consoleBaudRate;
  LocalShellLaunch? consoleShell;
  DesktopSession? desktop;

  /// Set only for Telnet tabs (never SSH/Console); SSH-only tools check
  /// [connection], which stays null here.
  TelnetSession? telnet;
  TelnetConnectCancellation? _telnetCancellation;
  VoidCallback? _onTelnetStateChanged;
  String? telnetState;
  String? telnetError;
  Future<void> telnetReady = Future<void>.value();
  bool get isTelnet =>
      host.protocol == HostProtocol.telnet && desktop == null && console == null;
  final terminal = MirroredTerminal(maxLines: 5000);
  final connected = ValueNotifier<bool>(true);
  final viewKey = GlobalKey<_LocalSshTerminalDialogState>();
  StreamSubscription<String>? _stdout, _stderr;
  bool _closed = false;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    recovery?.dispose();
    recovery = null;
    log?.markClosed(SessionLogEndReason.user);
    connected.value = false;
    terminal.onOutput = null;
    terminal.onResize = null;
    await Future.wait([
      if (_stdout != null) _stdout!.cancel(),
      if (_stderr != null) _stderr!.cancel(),
    ]);
    await terminal.closeMirror();
    _telnetCancellation?.cancel();
    _telnetCancellation = null;
    _onTelnetStateChanged = null;
    await telnet?.close();
    await connection?.close();
    await console?.close();
    await desktop?.close();
    desktop?.dispose();
    connected.dispose();
  }
}

class _LocalSshTerminalDialog extends StatefulWidget {
  const _LocalSshTerminalDialog({
    required this.session,
    required this.repository,
    required this.host,
    required this.connection,
    required this.fontSize,
    required this.theme,
    required this.shortcuts,
    required this.active,
    required this.onDisconnect,
    required this.onToolsChanged,
    super.key,
  });

  final _LocalTerminalSession session;
  final LocalHostRepository repository;
  final bool active;
  final VoidCallback onDisconnect;
  final VoidCallback onToolsChanged;
  final HostRecord host;
  final SshConnection connection;
  final int fontSize;
  final VaultTerminalThemeChoice theme;
  final TerminalShortcutBindings shortcuts;

  @override
  State<_LocalSshTerminalDialog> createState() =>
      _LocalSshTerminalDialogState();
}

class _LocalSshTerminalDialogState extends State<_LocalSshTerminalDialog> {
  Widget? get toolsSidebar => _searchOpen ? _toolsSidebar() : null;

  void _updateTools(VoidCallback change) {
    setState(change);
    widget.onToolsChanged();
  }

  void toggleTools() {
    if (_searchOpen) {
      _closeSearch();
      _terminalFocus.requestFocus();
    } else {
      _openTools(TerminalToolsSection.search);
    }
  }

  Terminal get _terminal => widget.session.terminal;
  final TerminalController _terminalController = TerminalController();
  final FocusNode _terminalFocus = FocusNode(debugLabel: 'Local SSH input');
  final ScrollController _terminalScrollController = ScrollController();
  final TextEditingController _searchQuery = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'LocalVault terminal scrollback search',
  );
  final List<TerminalHighlight> _searchHighlights = [];
  TerminalHighlight? _selectedSearchHighlight;
  List<TerminalSearchMatch> _searchMatches = const [];
  Timer? _searchTimer;
  int _selectedSearchMatch = -1;
  bool _searchOpen = false;
  TerminalToolsSection _toolsSection = TerminalToolsSection.search;
  final _searchHistory = TerminalSearchHistory();
  late final LocalShellHistory _history;
  bool _searching = false;
  bool _searchTruncated = false;
  bool _searchQueryTooLong = false;

  @override
  void initState() {
    super.initState();
    _terminal.addListener(_onTerminalChanged);
    _history = LocalShellHistory(
      repository: widget.repository,
      hostId: widget.host.id,
      terminalId: widget.session.id,
    );
    _terminal.onPrivateOSC = _history.accept;
    unawaited(_history.load());
  }

  @override
  void didUpdateWidget(covariant _LocalSshTerminalDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _terminalFocus.unfocus();
      _searchFocusNode.unfocus();
    }
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _terminalFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _history.dispose();
    _terminal.onPrivateOSC = null;
    _searchTimer?.cancel();
    _terminal.removeListener(_onTerminalChanged);
    _clearSearchHighlights();
    _terminalController.dispose();
    _terminalFocus.dispose();
    _terminalScrollController.dispose();
    _searchQuery.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (!_searchOpen || _searchQuery.text.isEmpty) return;
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 120), _refreshMatches);
  }

  void _onSearchChanged(String query) {
    _searchTimer?.cancel();
    _clearSearchHighlights();
    _updateTools(() {
      _searchMatches = const [];
      _selectedSearchMatch = -1;
      _searching = query.isNotEmpty;
      _searchTruncated = false;
      _searchQueryTooLong = false;
    });
    if (query.isEmpty) return;
    _searchTimer = Timer(const Duration(milliseconds: 160), _refreshMatches);
  }

  void _refreshMatches() {
    _searchTimer = null;
    final result = searchTerminalBuffer(_terminal, _searchQuery.text);
    if (!mounted) return;
    _updateTools(() {
      _searchMatches = result.matches;
      _selectedSearchMatch = result.matches.isEmpty ? -1 : 0;
      _searching = false;
      _searchTruncated = result.truncated;
      _searchQueryTooLong = result.queryTooLong;
    });
    _paintSearchMatches();
    if (_searchMatches.isNotEmpty) _revealSelectedMatch();
  }

  void _openSearch() {
    if (!mounted) return;
    _updateTools(() {
      _searchOpen = true;
      _toolsSection = TerminalToolsSection.search;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _toolsSection == TerminalToolsSection.search)
        _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchFocusNode.unfocus();
    _searchHistory.remember(_searchQuery.text);
    _searchQuery.clear();
    _clearSearchHighlights();
    _updateTools(() {
      _searchOpen = false;
      _searchMatches = const [];
      _selectedSearchMatch = -1;
      _searching = false;
      _searchTruncated = false;
      _searchQueryTooLong = false;
    });
  }

  void _moveSearch(bool forward) {
    if (!_searchOpen) {
      _openSearch();
      return;
    }
    if (_searchQuery.text.isEmpty) return;
    if (_searchMatches.isEmpty) {
      if (!_searching) _refreshMatches();
      return;
    }
    _updateTools(() {
      _selectedSearchMatch = forward
          ? (_selectedSearchMatch + 1) % _searchMatches.length
          : (_selectedSearchMatch - 1 + _searchMatches.length) %
                _searchMatches.length;
    });
    _paintSelectedSearchMatch();
    _revealSelectedMatch();
  }

  void _dispatchTerminalShortcut(TerminalShortcutAction action) {
    switch (action) {
      case TerminalShortcutAction.search:
        _openSearch();
      case TerminalShortcutAction.searchNext:
        _moveSearch(true);
      case TerminalShortcutAction.searchPrevious:
        _moveSearch(false);
      case TerminalShortcutAction.disconnect:
        widget.onDisconnect();
    }
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    final windowResult = handleNewWindowKeyEvent(context, event);
    if (windowResult == KeyEventResult.handled) return windowResult;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    return dispatchTerminalShortcut(
      bindings: widget.shortcuts,
      logicalKey: event.logicalKey,
      controlPressed: HardwareKeyboard.instance.isControlPressed,
      metaPressed: HardwareKeyboard.instance.isMetaPressed,
      altPressed: HardwareKeyboard.instance.isAltPressed,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      platform: defaultTargetPlatform,
      onAction: _dispatchTerminalShortcut,
    );
  }

  String get _searchStatus => terminalSearchCountLabel(
    matchCount: _searchMatches.length,
    selectedIndex: _selectedSearchMatch,
    truncated: _searchTruncated,
    searching: _searching,
    queryTooLong: _searchQueryTooLong,
  );

  void _clearSearchHighlights() {
    _selectedSearchHighlight?.dispose();
    _selectedSearchHighlight = null;
    for (final highlight in _searchHighlights) {
      highlight.dispose();
    }
    _searchHighlights.clear();
  }

  void _paintSearchMatches() {
    _clearSearchHighlights();
    final buffer = _terminal.buffer;
    final theme = readTerminalColorTheme(context, widget.theme);
    for (final match in _searchMatches) {
      if (match.start.y >= buffer.lines.length ||
          match.end.y >= buffer.lines.length) {
        continue;
      }
      _searchHighlights.add(
        _terminalController.highlight(
          p1: buffer.createAnchorFromOffset(match.start),
          p2: buffer.createAnchorFromOffset(match.end),
          color: theme.searchHitBackground,
        ),
      );
    }
    _paintSelectedSearchMatch();
  }

  void _paintSelectedSearchMatch() {
    _selectedSearchHighlight?.dispose();
    _selectedSearchHighlight = null;
    if (_searchMatches.isEmpty ||
        _selectedSearchMatch < 0 ||
        _selectedSearchMatch >= _searchMatches.length) {
      return;
    }
    final match = _searchMatches[_selectedSearchMatch];
    final buffer = _terminal.buffer;
    if (match.start.y >= buffer.lines.length ||
        match.end.y >= buffer.lines.length) {
      return;
    }
    _selectedSearchHighlight = _terminalController.highlight(
      p1: buffer.createAnchorFromOffset(match.start),
      p2: buffer.createAnchorFromOffset(match.end),
      color: readTerminalColorTheme(
        context,
        widget.theme,
      ).searchHitBackgroundCurrent,
    );
  }

  void _revealSelectedMatch() {
    if (_selectedSearchMatch < 0 ||
        _selectedSearchMatch >= _searchMatches.length) {
      return;
    }
    final row = _searchMatches[_selectedSearchMatch].start.y;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_terminalScrollController.hasClients) return;
      final position = _terminalScrollController.position;
      final totalHeight = position.maxScrollExtent + position.viewportDimension;
      final rowCount = _terminal.buffer.lines.length;
      if (rowCount == 0) return;
      final rowHeight = totalHeight / rowCount;
      final target = (row * rowHeight - position.viewportDimension / 2).clamp(
        0.0,
        position.maxScrollExtent,
      );
      _terminalScrollController.jumpTo(target);
    });
  }

  void _openTools(TerminalToolsSection section) {
    _terminalFocus.unfocus();
    _openSearch();
    _updateTools(() => _toolsSection = section);
  }

  Future<void> _configureHistory() async {
    await showAppDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(context.l10n.bashInputHistory),
          content: SizedBox(
            width: appDialogWidth(context, 460),
            child: Text(
              context.l10n.afterEnablingCopyTheSetupCommand,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.close2),
            ),
            if (_history.enabled)
              TextButton(
                onPressed: () {
                  _history.disable();
                  update(() {});
                },
                child: Text(context.l10n.stopCapture),
              ),
            FilledButton(
              onPressed: () async {
                try {
                  final setup = _history.enable();
                  await Clipboard.setData(ClipboardData(text: setup));
                  if (context.mounted) Navigator.pop(context);
                } catch (_) {
                  _history.disable();
                }
              },
              child: Text(context.l10n.enableAndCopySetupCommand),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolsSidebar() => TerminalToolsSidebar(
    section: _toolsSection,
    onSection: (section) => _updateTools(() => _toolsSection = section),
    onClose: _closeSearch,
    query: _searchQuery,
    queryFocus: _searchFocusNode,
    onQuery: _onSearchChanged,
    searchStatus: _searchStatus,
    previous: _searchMatches.isEmpty ? null : () => _moveSearch(false),
    next: _searchMatches.isEmpty ? null : () => _moveSearch(true),
    searchHistory: _searchHistory,
    onSearchKey: _handleTerminalKeyEvent,
    loadCommands: () async => terminalQuickCommands(
      (await widget.repository.listSnippets()).map((r) => r.snippet),
    ),
    editCommand: (item) async {
      final old = item == null
          ? null
          : await widget.repository.getSnippet(item.id);
      if (!mounted) return;
      if (item != null &&
          (old == null ||
              old.snippet.body != item.command ||
              terminalQuickCommands([old.snippet]).isEmpty))
        {
throw StateError(context.l10n.snippetChanged);
}
      final draft = await editTerminalQuickCommand(context, existing: item);
      if (draft == null || !mounted || widget.session._closed) return;
      if (old == null) {
        await widget.repository.createSnippet(draft);
      } else {
        await widget.repository.updateSnippet(
          updateTerminalQuickCommand(old.snippet, draft),
          expectedRevisionId: old.revisionId,
        );
      }
    },
    deleteCommand: (item) async {
      final old = await widget.repository.getSnippet(item.id);
      if (old != null)
        await widget.repository.deleteSnippet(
          old.id,
          expectedRevisionId: old.revisionId,
        );
    },
    history: () => _history.items,
    historyChanges: _history,
    historyNotice: () => _history.storageFailed
        ? context.l10n.couldntSaveHistoryCommandsInMemory
        : _history.enabled
        ? context.l10n.bashRecordingIsOnClickTo
        : context.l10n.completedCommandsAreRecordedAfterEnabling,
    onConfigureHistory: _configureHistory,
    onClearHistory: _history.clear,
    onInsert: (command) {
      if (!widget.active ||
          widget.session._closed ||
          !widget.session.connected.value ||
          !isSafeTerminalCommand(command))
        return false;
      _terminal.onOutput?.call(command);
      _terminalFocus.requestFocus();
      return true;
    },
  );

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !widget.active,
    child: Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(
              child: TerminalView(
                _terminal,
                key: const ValueKey('local_ssh_terminal_view'),
                controller: _terminalController,
                scrollController: _terminalScrollController,
                focusNode: _terminalFocus,
                autofocus: widget.active && !_searchOpen,
                onKeyEvent: _handleTerminalKeyEvent,
                padding: const EdgeInsets.all(12),
                backgroundOpacity: wallpaperTerminalBackgroundOpacity(context),
                textStyle: TerminalStyle(
                  fontSize: widget.fontSize.toDouble(),
                  fontFamily: 'monospace',
                ),
                theme: terminalColorThemeOf(context, widget.theme),
              ),
            ),
            TerminalKeybar(
              terminal: _terminal,
              focusNode: _terminalFocus,
              availablePaneHeight: constraints.maxHeight,
            ),
          ],
        ),
      ),
    ),
  );
}
