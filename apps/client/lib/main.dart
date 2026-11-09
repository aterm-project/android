import 'platform/file_window_tracking.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sodium/sodium_sumo.dart';

import 'app_controller.dart';
import 'mcp/mcp_listener_lifecycle.dart';
import 'mcp/mcp_service.dart';
import 'platform/mcp_foreground.dart';
import 'desktop/window/desktop_window.dart';
import 'desktop/window/desktop_window_page.dart';
import 'platform/application_windows.dart';
import 'platform/file_drop_region.dart' show initializeFileDrop;
import 'platform/files_window_launch.dart';
import 'terminal/live_terminal_window.dart';
import 'ui/app_motion.dart';
import 'ui/live_terminal_window_page.dart';
import 'ui/window_caption.dart';
import 'ui/workspace_controls.dart';
import 'crypto/vault_crypto.dart';
import 'storage/application_reload.dart';
import 'storage/client_database.dart';
import 'storage/database_quarantine.dart';
import 'storage/local_profile_catalog.dart';
import 'storage/local_profile_service.dart';
import 'storage/secure_store.dart';
import 'storage/sync_preference_store.dart';
import 'storage/web_storage_policy.dart';
import 'storage/workspace_mode_store.dart';
import 'ui/workspace_mode_settings.dart';
import 'ui/new_window.dart';
import 'storage/insecure_web_storage_stub.dart'
    if (dart.library.js_interop) 'storage/insecure_web_storage_web.dart'
    as insecure_web_storage;
import 'ui/app_shell.dart';
import 'ui/app_theme.dart';
import 'ui/auth_flow.dart';
import 'ui/browser_storage_status_card.dart';
import 'ui/local_profile_flow.dart';
import 'ui/local_to_sync_migration_screen.dart';
import 'ui/locked_workspace_screen.dart';
import 'l10n/l10n.dart';
import 'storage/app_language_store.dart';
import 'storage/app_theme_store.dart';
import 'ui/app_theme_mode.dart';
import 'storage/wallpaper_store.dart';
import 'ui/wallpaper.dart';
import 'storage/terminal_palette_store.dart';
import 'ui/terminal_palette.dart';
import 'ui/app_language_settings.dart';
import 'cloud/cloud_access_api.dart';
import 'cloud/cloud_access_crypto.dart';
import 'cloud/pending_cloud_link.dart';
import 'ui/cloud_access/guest_app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  McpListenerLifecycle.install(
    McpService.instance,
    text: () => McpForegroundText(
      channelName: currentL10n.externalAiAccess,
      title: currentL10n.mcpForegroundNotificationTitle,
      body: currentL10n.mcpForegroundNotificationText(
        McpService.instance.endpoint?.port ?? 8765,
      ),
      stopLabel: currentL10n.mcpForegroundNotificationStop,
    ),
  );
  // Bounded browser-drop policy + central drop cleanup before any root runs.
  initializeFileDrop();
  if (kIsWeb) {
    // Temporary-link visitors get a separate account-free app. The link
    // secret was already removed from the address bar by share-bootstrap.js.
    PendingCloudLink.capture();
    final slug = guestSlugFromPath(Uri.base.path);
    if (slug != null) {
      await AppLanguageController.instance.load(createAppLanguageStore());
      await AppThemeController.instance.load(createAppThemeStore());
      Future<SodiumSumo>? sodium;
      runApp(
        GuestApp(
          slug: slug,
          secret: ShareLinkSecret.fromFragment(PendingCloudLink.takeLinkFragment()),
          api: GuestApi(origin: Uri.base),
          sodium: () => sodium ??= Future.value(SodiumSumoInit.init()),
        ),
      );
      return;
    }
  }
  LiveTerminalWindowLaunch? terminalLaunch;
  FilesWindowLaunch? filesLaunch;
  DesktopWindowLaunch? desktopLaunch;
  try {
    terminalLaunch = detectLiveTerminalWindow(arguments);
    filesLaunch = detectFilesWindow(arguments);
    desktopLaunch = detectDesktopWindow(arguments);
    validateFileTrackingArguments(arguments, filesLaunch);
    if ([terminalLaunch, filesLaunch, desktopLaunch].nonNulls.length > 1) {
      throw FormatException(currentL10n.conflictingWindowRequests);
    }
  } catch (_) {
    await ApplicationWindows.instance.start(terminalChild: true);
    await AppLanguageController.instance.load(createAppLanguageStore());
    // Device-local, non-secret UI theme (dark default), shared by every window.
    await AppThemeController.instance.load(createAppThemeStore());
    runApp(
      AppThemeModeBuilder(
        builder: (context, themeMode) => AppLanguageHost(
          builder: (context, locale) => MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(locale: locale, brightness: Brightness.light),
            darkTheme: buildAppTheme(locale: locale),
            themeMode: themeMode,
            builder: (context, child) => WindowsWindowChrome(child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: Text(context.l10n.couldntVerifyTheSeparateWindowTry),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  await ApplicationWindows.instance.start(
    terminalChild: terminalLaunch != null,
    desktopChild: desktopLaunch != null,
  );
  // Geometry-only file tracking is ready before any authentication/UI startup.
  await startFileWindowTracking(arguments, filesLaunch);
  // Device-local display language (plain preference file / localStorage, not
  // secure storage): safe for renderer children before any profile startup.
  await AppLanguageController.instance.load(createAppLanguageStore());
  // Device-local, non-secret UI theme (dark default), shared by every window.
  await AppThemeController.instance.load(createAppThemeStore());
  // Device-local wallpaper (separate from the theme): every window reads the
  // same preference and decodes its own bounded copy in the background. Only
  // the main window cleans up orphaned owned images.
  await WallpaperController.instance.load(
    createWallpaperStore(),
    cleanupStale:
        desktopLaunch == null && terminalLaunch == null && filesLaunch == null,
  );
  // Device-local, non-secret terminal palette overlay; terminal child windows
  // read it too so every terminal on this device uses the same palette.
  await TerminalPaletteController.instance.load(createTerminalPaletteStore());
  if (desktopLaunch != null) {
    // A remote desktop child only renders the parent's RDP/VNC session: never
    // initialize secure storage, profiles, Sodium, Firebase or a protocol
    // connection; credentials and Host records stay in the parent.
    final launch = desktopLaunch;
    runApp(
      AppThemeModeBuilder(
        builder: (context, themeMode) => AppLanguageHost(
          builder: (context, locale) => MaterialApp(
            onGenerateTitle: (context) => context.l10n.atermiusRemoteDesktop,
            debugShowCheckedModeBanner: false,
            locale: locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(locale: locale, brightness: Brightness.light),
            darkTheme: buildAppTheme(locale: locale),
            themeMode: themeMode,
            builder: (context, child) => WindowsWindowChrome(
              navigationEmbedded: () => true,
              child: WallpaperWindowHost(child: child!),
            ),
            home: DesktopWindowPage(launch: launch),
          ),
        ),
      ),
    );
    return;
  }
  if (terminalLaunch != null) {
    // A child is only a live terminal renderer: never initialize secure
    // storage, profile catalogs, Sodium, Firebase or a second SSH connection.
    final launch = terminalLaunch;
    runApp(
      AppThemeModeBuilder(
        builder: (context, themeMode) => AppLanguageHost(
          builder: (context, locale) => MaterialApp(
            onGenerateTitle: (context) => context.l10n.atermiusTerminal,
            debugShowCheckedModeBanner: false,
            locale: locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(locale: locale, brightness: Brightness.light),
            darkTheme: buildAppTheme(locale: locale),
            themeMode: themeMode,
            builder: (context, child) => WindowsWindowChrome(
              navigationEmbedded: () => true,
              child: WallpaperWindowHost(child: child!),
            ),
            home: LiveTerminalWindowPage(launch: launch),
          ),
        ),
      ),
    );
    return;
  }
  insecure_web_storage.useInsecureHttpStorageWhenNeeded();
  runApp(
    AtermiusStartup(
      initialize: () => _initializeAtermius(filesLaunch: filesLaunch),
    ),
  );
}

Future<Widget> _initializeAtermius({FilesWindowLaunch? filesLaunch}) async {
  final sodium = await SodiumSumoInit.init();
  final crypto = VaultCrypto(sodium);
  return AtermiusApp(
    localProfileCatalogInitializer: LocalProfileCatalog.open,
    crypto: crypto,
    enableProfileModeSelection: true,
    modeStore: createWorkspaceModeStore(),
    filesLaunch: filesLaunch,
    serverInitializer: () async {
      // Defer opening the shared server schema and restoring a server session
      // until the user explicitly selects account/sync mode.
      final database = await ClientDatabase.open();
      return AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        syncPreferenceStore: createSyncPreferenceStore(),
      );
    },
  );
}

typedef AtermiusInitializer = Future<Widget> Function();

/// Shows a retryable, privacy-safe recovery screen until local secure storage
/// and the encrypted database are ready.
class AtermiusStartup extends StatefulWidget {
  const AtermiusStartup({required this.initialize, super.key});

  final AtermiusInitializer initialize;

  @override
  State<AtermiusStartup> createState() => _AtermiusStartupState();
}

class _AtermiusStartupState extends State<AtermiusStartup> {
  Widget? _app;
  bool _starting = true;
  bool _attemptInFlight = false;
  bool _unsupportedStorage = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_attemptInFlight) return;
    _attemptInFlight = true;
    setState(() {
      _starting = true;
      _unsupportedStorage = false;
    });
    try {
      final app = await widget.initialize();
      if (!mounted) return;
      setState(() {
        _app = app;
        _starting = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _unsupportedStorage = error is UnsupportedWebStorageException;
        _starting = false;
      });
    } finally {
      _attemptInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app != null) return app;

    return AppThemeModeBuilder(
      builder: (context, themeMode) => AppLanguageHost(
        builder: (context, locale) => MaterialApp(
          title: 'Atermius',
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(locale: locale, brightness: Brightness.light),
          darkTheme: buildAppTheme(locale: locale),
          themeMode: themeMode,
          builder: (context, child) => WindowsWindowChrome(child: child!),
          home: _StartupRecovery(
            starting: _starting,
            unsupportedStorage: _unsupportedStorage,
            onRetry: _initialize,
          ),
        ),
      ),
    );
  }
}

class _StartupRecovery extends StatelessWidget {
  const _StartupRecovery({
    required this.starting,
    required this.unsupportedStorage,
    required this.onRetry,
  });

  final bool starting;
  final bool unsupportedStorage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final title = starting
        ? context.l10n.preparingSecureWorkspace
        : unsupportedStorage
        ? context.l10n.supportedBrowserStorageRequired
        : context.l10n.couldntInitializeTheSecureWorkspace;
    final description = starting
        ? context.l10n.checkingLocalEncryptedStorage
        : unsupportedStorage
        ? context.l10n.atermiusNeedsReliablePersistentBrowserStorage
        : context.l10n.theSecurityComponentsOrLocalStorage;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Semantics(
                container: true,
                liveRegion: !starting,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      starting ? Icons.lock_clock_outlined : Icons.lock_outline,
                      color: context.palette.orange,
                      size: 34,
                    ),
                    const SizedBox(height: 18),
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: context.palette.muted),
                    ),
                    if (starting) ...[
                      const SizedBox(height: 20),
                      const Center(child: CircularProgressIndicator()),
                    ] else ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        key: const ValueKey('startup_retry'),
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.retry),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AtermiusApp extends StatefulWidget {
  const AtermiusApp({
    this.controller,
    this.serverInitializer,
    this.localProfileCatalog,
    this.localProfileService,
    this.localProfileCatalogInitializer,
    this.crypto,
    this.enableProfileModeSelection = false,
    this.modeStore,
    this.filesLaunch,
    super.key,
  }) : assert(controller != null || serverInitializer != null),
       assert(
         !enableProfileModeSelection ||
             (localProfileCatalog == null) == (localProfileService == null),
       ),
       assert(localProfileCatalogInitializer == null || crypto != null);

  final AppController? controller;
  final Future<AppController> Function()? serverInitializer;
  final LocalProfileCatalog? localProfileCatalog;
  final LocalProfileService? localProfileService;
  final Future<LocalProfileCatalog> Function()? localProfileCatalogInitializer;
  final VaultCrypto? crypto;
  final bool enableProfileModeSelection;
  final WorkspaceModeStore? modeStore;
  final FilesWindowLaunch? filesLaunch;

  @override
  State<AtermiusApp> createState() => _AtermiusAppState();
}

class _AtermiusAppState extends State<AtermiusApp> with WidgetsBindingObserver {
  AppController? _controller;
  LocalProfileCatalog? _localCatalog;
  LocalProfileService? _localService;
  bool _usingServer = false;
  bool _usingLocal = false;
  bool _serverBusy = false;
  bool _localBusy = false;
  bool _localReloadRequired = false;
  bool _serverRestoreStarted = false;
  String? _serverError;
  String? _localError;
  bool _restoringMode = false;
  bool _switchingMode = false;
  bool _modeReadFailed = false;
  VoidCallback? _unregisterWindowCloser;

  Future<void> _closeForNativeExit() async {
    final controller = _controller;
    if (controller != null) await controller.closeWorkspace();
    await _localCatalog?.close();
  }

  @override
  void initState() {
    super.initState();
    _unregisterWindowCloser = ApplicationWindows.instance.registerOwnerCloser(
      this,
      _closeForNativeExit,
    );
    _controller = widget.controller;
    _localCatalog = widget.localProfileCatalog;
    _localService = widget.localProfileService;
    WidgetsBinding.instance.addObserver(this);
    if (widget.filesLaunch != null ||
        (widget.enableProfileModeSelection && widget.modeStore != null)) {
      _restoringMode = true;
      unawaited(_restoreMode());
    } else if (!widget.enableProfileModeSelection) {
      if (_controller == null) {
        unawaited(_enterServerMode());
      } else {
        _usingServer = true;
        _restoreServerSession();
      }
    }
  }

  @override
  void dispose() {
    _unregisterWindowCloser?.call();
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.closeWorkspace().catchError((Object _) {}));
    }
    final catalog = _localCatalog;
    if (catalog != null) unawaited(catalog.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _usingServer) {
      final controller = _controller;
      if (controller != null) unawaited(controller.onForegroundResumed());
    }
  }

  void _restoreServerSession() {
    final controller = _controller;
    if (controller == null || _serverRestoreStarted) return;
    _serverRestoreStarted = true;
    unawaited(controller.restoreLastServer());
  }

  Future<void> _restoreMode() async {
    setState(() {
      _restoringMode = true;
      _modeReadFailed = false;
    });
    try {
      final launch = widget.filesLaunch;
      if (launch != null) {
        // A child navigation request must not change the regular startup mode
        // or use its untrusted server metadata to redirect stored credentials.
        if (launch.workspace == FilesWindowWorkspace.local) {
          await _enterLocalMode(remember: false);
        } else {
          await _enterServerMode(remember: false);
        }
        return;
      }
      final mode = await widget.modeStore?.read();
      if (!mounted) return;
      if (mode == WorkspaceMode.local || (mode == null && !kIsWeb)) {
        await _enterLocalMode(remember: mode == null);
      }
      if (mode == WorkspaceMode.server) await _enterServerMode(remember: false);
    } on Object {
      if (mounted) setState(() => _modeReadFailed = true);
    } finally {
      if (mounted) setState(() => _restoringMode = false);
    }
  }

  Future<void> _enterServerMode({bool remember = true}) async {
    if (_serverBusy || _localBusy) return;
    setState(() {
      _serverBusy = true;
      _serverError = null;
    });
    AppController? created;
    try {
      final controller =
          _controller ?? (created = await widget.serverInitializer!());
      if (remember) await widget.modeStore?.write(WorkspaceMode.server);
      if (!mounted) {
        created?.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _usingServer = true;
        _usingLocal = false;
      });
      _restoreServerSession();
    } on UnsupportedWebStorageException {
      created?.dispose();
      if (mounted) {
        setState(
          () => _serverError =
              context.l10n.supportedBrowserStorageIsRequiredCheck,
        );
      }
    } on Object {
      if (created != null) await created.closeWorkspace();
      if (mounted) {
        setState(
          () => _serverError = context.l10n.couldntOpenTheCloudWorkspaceOr,
        );
      }
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  Future<void> _switchWorkspace() async {
    if (_switchingMode) return;
    final wasLocal = _usingLocal;
    setState(() => _switchingMode = true);
    try {
      if (wasLocal) {
        await _enterServerMode();
      } else {
        await _enterLocalMode();
      }
    } finally {
      if (mounted) setState(() => _switchingMode = false);
    }
    if (mounted && wasLocal == _usingLocal) {
      throw StateError(context.l10n.workspaceSwitchCouldNotBeCompleted);
    }
  }

  Future<bool> _ensureLocalProfileStorage() async {
    if (_localCatalog != null && _localService != null) return true;
    if (_localBusy) return false;
    final initialize = widget.localProfileCatalogInitializer;
    final crypto = widget.crypto;
    if (initialize == null || crypto == null) return false;
    setState(() {
      _localBusy = true;
      _localError = null;
      _localReloadRequired = false;
    });
    LocalProfileCatalog? catalog;
    try {
      catalog = await initialize();
      final service = LocalProfileService(catalog: catalog, crypto: crypto);
      if (!mounted) {
        await catalog.close();
        return false;
      }
      setState(() {
        _localCatalog = catalog;
        _localService = service;
        _localBusy = false;
      });
      return true;
    } on DatabaseRecoveryRequiredException {
      if (!mounted) return false;
      setState(() {
        _localBusy = false;
        _localReloadRequired = true;
        _localError = context.l10n.aLocalStorageWriteWasInterrupted;
      });
      return false;
    } on Object {
      if (catalog != null) {
        try {
          await catalog.close();
        } on Object {
          // Keep the user-facing failure generic and allow another attempt.
        }
      }
      if (!mounted) return false;
      setState(() {
        _localBusy = false;
        _localError = context.l10n.couldntOpenLocalProfileStorageAllow;
      });
      return false;
    }
  }

  Future<void> _enterLocalMode({bool remember = true}) async {
    if (!await _ensureLocalProfileStorage() || !mounted) return;
    try {
      if (remember) await widget.modeStore?.write(WorkspaceMode.local);
      if (!mounted) return;
      final retiring = _usingServer && widget.serverInitializer != null
          ? _controller
          : null;
      setState(() {
        _usingLocal = true;
        _usingServer = false;
        _serverError = null;
        _localError = null;
        if (retiring != null) {
          _controller = null;
          _serverRestoreStarted = false;
        }
      });
      if (retiring != null) await retiring.closeWorkspace();
    } on Object {
      if (mounted) {
        setState(
          () => _localError = context.l10n.couldntSaveOrSwitchTheWorkspace,
        );
      }
    }
  }

  Future<void> _openLocalMigration(BuildContext context) async {
    if (!await _ensureLocalProfileStorage() || !context.mounted) return;
    final catalog = _localCatalog;
    final service = _localService;
    final crypto = widget.crypto;
    final controller = _controller;
    if (catalog == null ||
        service == null ||
        crypto == null ||
        controller == null) {
      return;
    }
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LocalToSyncMigrationScreen(
          controller: controller,
          catalog: catalog,
          service: service,
          crypto: crypto,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppThemeModeBuilder(
    builder: (context, themeMode) => AppLanguageHost(
      builder: (context, locale) => _buildApp(locale, themeMode),
    ),
  );

  Widget _buildApp(Locale locale, ThemeMode themeMode) => MaterialApp(
    title: 'Atermius',
    debugShowCheckedModeBanner: false,
    locale: locale,
    localizationsDelegates: AppLocalizationSetup.delegates,
    supportedLocales: AppLocalizationSetup.locales,
    theme: buildAppTheme(locale: locale, brightness: Brightness.light),
    darkTheme: buildAppTheme(locale: locale),
    themeMode: themeMode,
    builder: (context, child) => WindowsWindowChrome(
      navigationState: _controller,
      navigationEmbedded: () =>
          !_restoringMode &&
          !_modeReadFailed &&
          (_usingLocal ||
              (_usingServer &&
                  _controller?.stage == ClientStage.workspace &&
                  _controller?.restoringStoredSession == false &&
                  _controller?.workspaceLocked == false)),
      child: WorkspaceModeScope(
        mode: _usingLocal ? WorkspaceMode.local : WorkspaceMode.server,
        onSwitch: _switchWorkspace,
        busy: _switchingMode,
        child: WorkspaceWindowShortcuts(
          child: WallpaperWindowHost(child: child!),
        ),
      ),
    ),
    home: _restoringMode || _modeReadFailed
        ? _StartupRecovery(
            starting: _restoringMode,
            unsupportedStorage: false,
            onRetry: _restoreMode,
          )
        : _usingLocal
        ? LocalProfileFlow(
            catalog: _localCatalog!,
            service: _localService!,
            crypto: widget.crypto!,
            persistentMode: widget.modeStore != null,
            autoCreateOnFirstLaunch: !kIsWeb && widget.modeStore != null,
            filesLaunch: widget.filesLaunch,
            onExit: () async {
              if (!mounted) return;
              if (widget.modeStore != null) {
                await _switchWorkspace();
              } else {
                setState(() => _usingLocal = false);
              }
            },
          )
        : _usingServer
        ? _serverWorkspace()
        : _ProfileModeChooser(
            serverAvailable:
                _controller != null || widget.serverInitializer != null,
            localAvailable:
                widget.crypto != null &&
                ((_localCatalog != null && _localService != null) ||
                    widget.localProfileCatalogInitializer != null),
            localBusy: _localBusy,
            localReloadRequired: _localReloadRequired,
            localError: _localError,
            serverBusy: _serverBusy,
            serverError: _serverError,
            onServer: _enterServerMode,
            onLocal: _enterLocalMode,
            onReloadLocal: reloadApplication,
          ),
  );

  Widget _withModeSettings(Widget child) {
    if (widget.modeStore == null) return child;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Builder(
                builder: (context) => WorkspaceOverflowMenu(
                  tooltip: context.l10n.workspaceMenu,
                  actions: [
                    WorkspaceAction(
                      'workspace_settings',
                      context.l10n.workspaceModeSettings,
                      Icons.settings_outlined,
                      () => showAppDialog<void>(
                        context: context,
                        builder: (context) => const Dialog(
                          child: SizedBox(
                            width: 440,
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ScopedWorkspaceModeSettings(),
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
                                    child: AppLanguageSettings(dense: true),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  Widget _serverWorkspace() {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.restoringStoredSession) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (controller.stage == ClientStage.workspace) {
          if (controller.workspaceLocked) {
            return _withModeSettings(
              LockedWorkspaceScreen(controller: controller),
            );
          }
          return AppShell(
            controller: controller,
            filesLaunch: widget.filesLaunch,
            onOpenLocalMigration: widget.crypto == null
                ? null
                : (context) => _openLocalMigration(context),
          );
        }
        return _withModeSettings(AuthFlow(controller: controller));
      },
    );
  }
}

class _ProfileModeChooser extends StatelessWidget {
  const _ProfileModeChooser({
    required this.serverAvailable,
    required this.localAvailable,
    required this.serverBusy,
    required this.localBusy,
    required this.localReloadRequired,
    required this.serverError,
    required this.localError,
    required this.onServer,
    required this.onLocal,
    required this.onReloadLocal,
  });

  final bool serverAvailable;
  final bool localAvailable;
  final bool serverBusy;
  final bool localBusy;
  final bool localReloadRequired;
  final String? serverError;
  final String? localError;
  final VoidCallback onServer;
  final VoidCallback onLocal;
  final VoidCallback onReloadLocal;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: context.palette.lime,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.terminal_rounded,
                          color: context.palette.onAccentText,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Atermius',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const AppLanguageMenuButton(),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text(
                    context.l10n.chooseAWorkspace,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.serverProfilesSyncEncryptedDataAcross,
                    style: TextStyle(color: context.palette.muted, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  _WorkspaceModeCard(
                    icon: Icons.sync_rounded,
                    iconColor: context.palette.teal,
                    title: context.l10n.serverAccountAndSync,
                    description: context.l10n.useYourSelfHostedServerAccount,
                    buttonLabel: serverBusy
                        ? context.l10n.opening
                        : context.l10n.continueLabel,
                    buttonKey: const ValueKey('server_mode_start'),
                    primary: true,
                    enabled: serverAvailable && !serverBusy,
                    onPressed: onServer,
                  ),
                  _WorkspaceModeCard(
                    icon: Icons.lock_outline,
                    iconColor: context.palette.lime,
                    title: context.l10n.localOnlyProfile,
                    description: context.l10n.createOrUnlockAnEncryptedHost,
                    buttonLabel: localBusy
                        ? context.l10n.opening
                        : context.l10n.openLocally,
                    buttonKey: const ValueKey('local_mode_start'),
                    primary: false,
                    enabled:
                        localAvailable && !localBusy && !localReloadRequired,
                    onPressed: onLocal,
                  ),
                  if (!localAvailable) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.localProfileStorageIsUnavailableServer,
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (localError != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        localError!,
                        key: const ValueKey('local_catalog_open_error'),
                        style: TextStyle(color: context.palette.orange),
                      ),
                    ),
                  ],
                  if (localReloadRequired) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      key: const ValueKey('local_catalog_reload'),
                      onPressed: onReloadLocal,
                      child: Text(context.l10n.reloadPage),
                    ),
                  ],
                  if (serverError != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        serverError!,
                        style: TextStyle(color: context.palette.orange),
                      ),
                    ),
                  ],
                  if (serverBusy || localBusy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 16),
                  const BrowserStorageStatusCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _WorkspaceModeCard extends StatelessWidget {
  const _WorkspaceModeCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.buttonKey,
    required this.primary,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String buttonLabel;
  final Key buttonKey;
  final bool primary;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compact = bounds.maxWidth < 520;
      final detail = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
      final action = primary
          ? FilledButton(
              key: buttonKey,
              onPressed: enabled ? onPressed : null,
              child: Text(buttonLabel),
            )
          : OutlinedButton(
              key: buttonKey,
              onPressed: enabled ? onPressed : null,
              child: Text(buttonLabel),
            );
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    detail,
                    const SizedBox(height: 14),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: detail),
                    const SizedBox(width: 16),
                    action,
                  ],
                ),
        ),
      );
    },
  );
}
