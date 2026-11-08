import 'app_menu.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../ssh/port_forward_rule_change.dart';
import '../ssh/port_forward_runtime.dart';

export '../ssh/port_forward_rule_change.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'ssh_port_forwarding_dialog.dart';

/// Connection phase of one SSH session (terminal tab) as seen by the
/// forwarding page.
enum SshForwardingSessionPhase { connecting, connected, disconnected, failed }

/// One SSH session of a Host that can carry forwards. Built by the mode
/// adapter from its own tab/session objects; never persisted.
@immutable
class SshForwardingSessionInfo {
  const SshForwardingSessionInfo({
    required this.id,
    required this.hostId,
    required this.label,
    required this.phase,
    this.manager,
  });

  /// Stable id of the tab/session (cloud tab id, local session id).
  final String id;
  final String hostId;
  final String label;
  final SshForwardingSessionPhase phase;

  /// The forwarding runtime of this session's authenticated connection.
  final SshPortForwardManager? manager;

  /// The runtime only while the session is authenticated and its manager is
  /// still open; forwards are never started on anything else.
  SshPortForwardManager? get liveManager {
    final value = manager;
    return phase == SshForwardingSessionPhase.connected &&
            value != null &&
            value.isOpen
        ? value
        : null;
  }
}

/// Mode adapter between the shared page and one workspace (cloud Vault or
/// standalone local profile). Every getter reads the current state when it
/// is called, so a pending start re-validates against live data.
abstract class SshForwardingSource implements Listenable {
  /// Opaque identity of the active scope's lifetime (cloud: the open Vault
  /// repository object; local: repository + unlocked profile objects). It
  /// must change on every switch, lock or sign-out, so an A -> B -> A
  /// sequence never compares equal to the first A. Compared with `==`.
  /// A pending connect-and-start only starts while it is unchanged.
  Object? get scopeKey;

  /// Hosts in the active scope. The page shows SSH hosts only.
  List<HostRecord> get hosts;

  /// Every SSH session/tab of this workspace, across all hosts.
  List<SshForwardingSessionInfo> get sessions;

  bool get canEdit;
  String? get readOnlyReason;
  String get storageDescription;

  /// Persists ONE rule change through the existing encrypted Host store,
  /// applied with [applySshPortForwardRuleChange] to the Host as it is where
  /// the write is serialized (cloud: inside the mutation queue; local: inside
  /// the repository operation with its revision CAS), and only while [scope]
  /// (the [scopeKey] captured before the user edited/confirmed) is current.
  /// Throws [SshPortForwardRuleConflict] when the saved rule is not
  /// [expected] (or an inserted id exists), and other errors on failure.
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  });

  String describeSaveError(Object error);

  /// Opens a new SSH session for [host] through the workspace's normal
  /// connect flow (credential resolution, known-host and certificate gates,
  /// interactive prompts). Completes with the id of the session it opened
  /// once that session is authenticated, or `null` when it did not
  /// authenticate (cancelled, rejected, failed). Must never bypass trust.
  Future<String?> connect(HostRecord host);

  /// Shows the session (focuses its terminal tab). Optional.
  void showSession(String sessionId);
}

/// [SshForwardingSource] assembled from closures; used by the standalone
/// local profile (whose sessions are private to its state) and by tests.
class CallbackSshForwardingSource implements SshForwardingSource {
  CallbackSshForwardingSource({
    required Object? Function() scopeKey,
    required List<HostRecord> Function() hosts,
    required List<SshForwardingSessionInfo> Function() sessions,
    required Future<void> Function(
      String hostId,
      SshPortForwardProfile? expected,
      SshPortForwardProfile? replacement,
      Object? scope,
    )
    saveRule,
    required Future<String?> Function(HostRecord host) connect,
    required String storageDescription,
    // Resolve localized descriptions when read; retained adapters outlive locale changes.
    String Function()? storageDescriptionGetter,
    Listenable? changes,
    bool Function()? canEdit,
    String? readOnlyReason,
    String Function(Object error)? describeSaveError,
    void Function(String sessionId)? showSession,
  }) : _scopeKeyFn = scopeKey,
       _hostsFn = hosts,
       _sessionsFn = sessions,
       _saveRuleFn = saveRule,
       _connectFn = connect,
       _storageDescriptionValue = storageDescription,
       _storageDescriptionGetter = storageDescriptionGetter,
       _changesValue = changes,
       _canEditFn = canEdit,
       _readOnlyReasonValue = readOnlyReason,
       _describeSaveErrorFn = describeSaveError,
       _showSessionFn = showSession;

  final Object? Function() _scopeKeyFn;
  final List<HostRecord> Function() _hostsFn;
  final List<SshForwardingSessionInfo> Function() _sessionsFn;
  final Future<void> Function(
    String,
    SshPortForwardProfile?,
    SshPortForwardProfile?,
    Object?,
  )
  _saveRuleFn;
  final Future<String?> Function(HostRecord host) _connectFn;
  final String _storageDescriptionValue;
  final String Function()? _storageDescriptionGetter;
  final Listenable? _changesValue;
  final bool Function()? _canEditFn;
  final String? _readOnlyReasonValue;
  final String Function(Object error)? _describeSaveErrorFn;
  final void Function(String sessionId)? _showSessionFn;

  @override
  Object? get scopeKey => _scopeKeyFn();
  @override
  List<HostRecord> get hosts => _hostsFn();
  @override
  List<SshForwardingSessionInfo> get sessions => _sessionsFn();
  @override
  bool get canEdit => _canEditFn?.call() ?? true;
  @override
  String? get readOnlyReason => _readOnlyReasonValue;
  @override
  String get storageDescription =>
      _storageDescriptionGetter?.call() ?? _storageDescriptionValue;
  @override
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) => _saveRuleFn(hostId, expected, replacement, scope);
  @override
  String describeSaveError(Object error) =>
      _describeSaveErrorFn?.call(error) ??
      currentL10n.couldNotSaveForwardingSettingsNothing;
  @override
  Future<String?> connect(HostRecord host) => _connectFn(host);
  @override
  void showSession(String sessionId) => _showSessionFn?.call(sessionId);
  @override
  void addListener(VoidCallback listener) => _changesValue?.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changesValue?.removeListener(listener);
}

class _PendingStart {
  bool cancelled = false;
}

/// Volatile forwarding UI state that should outlive one visit of the page:
/// the session chosen per Host and "connect and start" requests that are
/// waiting for authentication. Own one per workspace shell and pass it to
/// every [SshForwardingPage]; it holds no secrets and is never persisted.
class SshForwardingController extends ChangeNotifier {
  /// Pass the shell's [source] so every scope transition (Vault switch, lock,
  /// sign-out, profile change) drops pending starts even while the page is
  /// not shown. Pending starts also re-check the scope when they complete.
  SshForwardingController({
    bool? runtimeSupported,
    String? unsupportedReason,
    SshForwardingSource? source,
  }) : _supported = runtimeSupported,
       _reason = unsupportedReason,
       _source = source {
    if (source != null) {
      bindScope(source.scopeKey);
      source.addListener(_onSourceChanged);
    }
  }

  final SshForwardingSource? _source;

  void _onSourceChanged() {
    final source = _source;
    if (source != null && !_disposed) bindScope(source.scopeKey);
  }

  bool? _supported;
  String? _reason;
  Object? _scopeKey;
  bool _scopeBound = false;
  final Map<String, String> _selectedSession = {};
  final Map<String, _PendingStart> _pending = {};
  final Map<String, String> _notes = {};
  final Set<String> _busy = {};
  bool _disposed = false;

  static String _key(String hostId, String profileId) => '$hostId\n$profileId';

  /// Whether this platform can open forwarding listeners at all. Checked
  /// before connecting, so an unsupported build never opens a session just
  /// to fail.
  bool get runtimeSupported => _supported ??= _probePlatform();
  String? get unsupportedReason {
    runtimeSupported;
    return _reason;
  }

  bool _probePlatform() {
    final platform = createSshPortForwardPlatform();
    _reason ??= platform.unsupportedReason;
    return platform.isSupported;
  }

  /// Forgets selections, notes and pending starts when the workspace scope
  /// (Vault, local profile) changed. Pending starts re-check the scope too.
  void bindScope(Object? scopeKey) {
    if (_scopeBound && scopeKey == _scopeKey) return;
    final hadState =
        _selectedSession.isNotEmpty || _pending.isNotEmpty || _notes.isNotEmpty;
    _scopeBound = true;
    _scopeKey = scopeKey;
    for (final pending in _pending.values) {
      pending.cancelled = true;
    }
    _pending.clear();
    _selectedSession.clear();
    _notes.clear();
    if (hadState) _notify();
  }

  List<SshForwardingSessionInfo> sessionsOf(
    SshForwardingSource source,
    String hostId,
  ) => source.sessions
      .where((session) => session.hostId == hostId)
      .toList(growable: false);

  List<SshForwardingSessionInfo> liveSessionsOf(
    SshForwardingSource source,
    String hostId,
  ) => sessionsOf(
    source,
    hostId,
  ).where((session) => session.liveManager != null).toList(growable: false);

  String? selectedSessionId(String hostId) => _selectedSession[hostId];

  void selectSession(String hostId, String sessionId) {
    if (_selectedSession[hostId] == sessionId) return;
    _selectedSession[hostId] = sessionId;
    _notify();
  }

  /// The session new starts go to: the user's choice, or the only
  /// authenticated session. `null` when there is none or the choice is
  /// ambiguous.
  SshForwardingSessionInfo? targetSession(
    SshForwardingSource source,
    String hostId,
  ) {
    final live = liveSessionsOf(source, hostId);
    final selected = _selectedSession[hostId];
    for (final session in live) {
      if (session.id == selected) return session;
    }
    return live.length == 1 ? live.single : null;
  }

  bool isConnecting(String hostId, String profileId) =>
      _pending.containsKey(_key(hostId, profileId));

  bool isBusy(String hostId, String profileId) =>
      _busy.contains(_key(hostId, profileId));

  String? noteOf(String hostId, String profileId) =>
      _notes[_key(hostId, profileId)];

  void clearNote(String hostId, String profileId) {
    if (_notes.remove(_key(hostId, profileId)) != null) _notify();
  }

  /// Starts a saved rule. Uses the target session when there is one;
  /// otherwise opens a new session through [SshForwardingSource.connect] and
  /// starts only on exactly that session, only after it authenticated, and
  /// only if scope, Host and rule are unchanged. Exposure confirmation is the
  /// caller's job and must happen before this call.
  ///
  /// [expected] / [expectedScope] bind the start to the exact rule the user
  /// saw or approved (for example in the exposure confirmation) and the
  /// scope it was shown in; any difference cancels the start.
  Future<void> start(
    SshForwardingSource source,
    String hostId,
    String profileId, {
    SshPortForwardProfile? expected,
    Object? expectedScope,
  }) async {
    final key = _key(hostId, profileId);
    if (_pending.containsKey(key) || _busy.contains(key)) return;
    _notes.remove(key);
    final scope = source.scopeKey;
    if (expected != null && scope != expectedScope) {
      _note(key, currentL10n.r7ForwardScopeChanged);
      return;
    }
    bindScope(scope);
    final host = _hostOf(source, hostId);
    final profile = _profileOf(host, profileId);
    if (host == null ||
        profile == null ||
        (expected != null && profile != expected)) {
      _note(key, currentL10n.r7ForwardRuleChanged);
      return;
    }
    if (!runtimeSupported) {
      _note(
        key,
        unsupportedReason ?? currentL10n.forwardRuntimeUnsupported,
      );
      return;
    }
    final target = targetSession(source, hostId);
    if (target != null) {
      await _startOn(key, target.liveManager!, profile);
      return;
    }
    if (liveSessionsOf(source, hostId).length > 1) {
      _note(key, currentL10n.r7ForwardChooseSession);
      return;
    }
    if (sessionsOf(source, hostId).any(
      (session) => session.phase == SshForwardingSessionPhase.connecting,
    )) {
      _note(key, currentL10n.r7ForwardWaitForSession);
      return;
    }

    final pending = _PendingStart();
    _pending[key] = pending;
    _notify();
    String? sessionId;
    try {
      sessionId = await source.connect(host);
    } catch (_) {
      // The workspace's connect flow reports its own (sanitized) error.
      sessionId = null;
    }
    if (_disposed || pending.cancelled || !identical(_pending[key], pending)) {
      return;
    }
    _pending.remove(key);
    if (sessionId == null) {
      _note(key, currentL10n.r7ForwardNotConnected);
      return;
    }
    if (source.scopeKey != scope) {
      _note(key, currentL10n.r7ForwardScopeChanged);
      return;
    }
    final latestHost = _hostOf(source, hostId);
    final latest = _profileOf(latestHost, profileId);
    if (latest == null || latest != profile) {
      _note(key, currentL10n.r7ForwardRuleChanged);
      return;
    }
    SshForwardingSessionInfo? session;
    for (final candidate in source.sessions) {
      if (candidate.id == sessionId) session = candidate;
    }
    final manager = session?.liveManager;
    if (session == null || session.hostId != hostId || manager == null) {
      _note(key, currentL10n.r7ForwardNotConnected);
      return;
    }
    _selectedSession[hostId] = session.id;
    await _startOn(key, manager, latest);
  }

  /// Drops a pending "connect and start"; the connection itself (if it
  /// completes) stays open as a normal session.
  void cancelPending(String hostId, String profileId) {
    final key = _key(hostId, profileId);
    final pending = _pending.remove(key);
    if (pending == null) return;
    pending.cancelled = true;
    _notes[key] = currentL10n.r7ForwardStartCancelled;
    _notify();
  }

  Future<void> stop(
    SshPortForwardManager manager,
    String hostId,
    String profileId,
  ) async {
    final key = _key(hostId, profileId);
    _notes.remove(key);
    _busy.add(key);
    _notify();
    try {
      await manager.stop(profileId);
    } catch (error) {
      _notes[key] = describeSshPortForwardError(error);
    } finally {
      _busy.remove(key);
      _notify();
    }
  }

  /// Stops the rule on every session of the Host and drops a pending start.
  Future<void> stopEverywhere(
    SshForwardingSource source,
    String hostId,
    String profileId,
  ) async {
    final pending = _pending.remove(_key(hostId, profileId));
    if (pending != null) {
      pending.cancelled = true;
      _notify();
    }
    await Future.wait([
      for (final session in sessionsOf(source, hostId))
        if (session.manager != null &&
            ruleIsActive(session.manager!, profileId))
          stop(session.manager!, hostId, profileId),
    ]);
  }

  Future<void> _startOn(
    String key,
    SshPortForwardManager manager,
    SshPortForwardProfile profile,
  ) async {
    _busy.add(key);
    _notify();
    try {
      await manager.start(profile);
    } catch (error) {
      // Failures recorded by the manager show on the status line; others
      // (listener conflicts, closed connection) are noted on the row.
      if (manager.statusOf(profile.id).state != SshPortForwardState.failed) {
        _notes[key] = describeSshPortForwardError(error);
      }
    } finally {
      _busy.remove(key);
      _notify();
    }
  }

  void _note(String key, String message) {
    _notes[key] = message;
    _notify();
  }

  static HostRecord? _hostOf(SshForwardingSource source, String hostId) {
    for (final host in source.hosts) {
      if (host.id == hostId && host.protocol == HostProtocol.ssh) return host;
    }
    return null;
  }

  static SshPortForwardProfile? _profileOf(HostRecord? host, String id) {
    if (host == null) return null;
    for (final profile in host.portForwardProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _source?.removeListener(_onSourceChanged);
    for (final pending in _pending.values) {
      pending.cancelled = true;
    }
    _pending.clear();
    super.dispose();
  }
}

/// True while [profileId] runs, starts or stops on [manager].
bool ruleIsActive(SshPortForwardManager manager, String profileId) =>
    manager.isOpen &&
    (manager.activeProfileIds.contains(profileId) ||
        manager.isStarting(profileId) ||
        manager.isStopping(profileId));

/// Home page listing every SSH Host's forwarding rules (local `-L`, remote
/// `-R`, dynamic SOCKS `-D`) with create/edit/duplicate/delete and per
/// session start/stop/status. Shared by cloud and standalone local mode.
///
/// Visiting the page never connects or starts anything.
class SshForwardingPage extends StatefulWidget {
  const SshForwardingPage({
    required this.source,
    this.controller,
    this.initialHostId,
    super.key,
  });

  final SshForwardingSource source;

  /// Shell-owned state that survives leaving the page (pending
  /// connect-and-start, chosen sessions). Created per page when omitted.
  final SshForwardingController? controller;

  /// Shows this Host first (for example when opened from a Host menu).
  final String? initialHostId;

  @override
  State<SshForwardingPage> createState() => _SshForwardingPageState();
}

class _SshForwardingPageState extends State<SshForwardingPage> {
  SshForwardingController? _ownController;
  final Set<SshPortForwardManager> _managers = {};
  final _search = TextEditingController();
  String _query = '';
  bool _showAllHosts = false;
  bool _working = false;
  String? _error;

  SshForwardingController get _controller =>
      widget.controller ?? (_ownController ??= SshForwardingController());

  SshForwardingSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    _source.addListener(_onSourceChanged);
    _controller.addListener(_onChanged);
    _controller.bindScope(_source.scopeKey);
    _bindManagers();
  }

  @override
  void didUpdateWidget(SshForwardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      oldWidget.source.removeListener(_onSourceChanged);
      widget.source.addListener(_onSourceChanged);
    }
    final oldController = oldWidget.controller ?? _ownController;
    if (!identical(oldController, _controller)) {
      oldController?.removeListener(_onChanged);
      _controller.addListener(_onChanged);
    }
    _controller.bindScope(_source.scopeKey);
    _bindManagers();
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceChanged);
    _controller.removeListener(_onChanged);
    for (final manager in _managers) {
      manager.removeListener(_onChanged);
    }
    _ownController?.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Listens to every session runtime so connection counts and failures
  /// update live; managers of ended sessions are dropped.
  void _bindManagers() {
    final next = <SshPortForwardManager>{
      for (final session in _source.sessions)
        if (session.manager != null) session.manager!,
    };
    for (final manager in _managers.difference(next)) {
      manager.removeListener(_onChanged);
    }
    for (final manager in next.difference(_managers)) {
      manager.addListener(_onChanged);
    }
    _managers
      ..clear()
      ..addAll(next);
  }

  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      _controller.bindScope(_source.scopeKey);
      _bindManagers();
    });
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<HostRecord> get _sshHosts => _source.hosts
      .where((host) => host.protocol == HostProtocol.ssh)
      .toList(growable: false);

  HostRecord? _currentHost(String hostId) {
    for (final host in _sshHosts) {
      if (host.id == hostId) return host;
    }
    return null;
  }

  bool _activeAnywhere(String hostId, String profileId) {
    if (_controller.isConnecting(hostId, profileId) ||
        _controller.isBusy(hostId, profileId)) {
      return true;
    }
    for (final session in _controller.sessionsOf(_source, hostId)) {
      final manager = session.manager;
      if (manager != null && ruleIsActive(manager, profileId)) return true;
    }
    return false;
  }

  // ---- editing --------------------------------------------------------

  Future<void> _newRule() async {
    final hosts = _sshHosts;
    if (hosts.isEmpty) return;
    final host = hosts.length == 1
        ? hosts.single
        : await showAppDialog<HostRecord>(
            context: context,
            builder: (_) => _HostPicker(hosts: hosts),
          );
    if (host == null || !mounted) return;
    await _edit(host);
  }

  /// Opens the shared encrypted-profile editor for a new ([existing] and
  /// [template] null), edited, or duplicated ([template]) rule and saves the
  /// result into the Host's latest rule list.
  Future<void> _edit(
    HostRecord host, {
    SshPortForwardProfile? existing,
    SshPortForwardProfile? template,
  }) async {
    if (_working || !_source.canEdit) return;
    final l10n = context.l10n;
    if (existing != null && _activeAnywhere(host.id, existing.id)) {
      setState(() => _error = l10n.stopThisForwardBeforeEditingIts);
      return;
    }
    final current = _currentHost(host.id)?.portForwardProfiles;
    if (current == null) {
      setState(() => _error = l10n.thisHostIsNoLongerAvailable);
      return;
    }
    if (existing == null && current.length >= maxHostPortForwardProfiles) {
      setState(() => _error = l10n.aHostCanHaveAtMost(maxHostPortForwardProfiles));
      return;
    }
    // The rule as the user sees it now; the save is a compare-and-set
    // against exactly this rule in exactly this scope.
    final scope = _source.scopeKey;
    final profile = await showAppDialog<SshPortForwardProfile>(
      context: context,
      builder: (_) => SshPortForwardProfileEditor(
        existing: existing,
        template: template,
        siblings: current.where((item) => item.id != existing?.id).toList(),
      ),
    );
    if (profile == null || !mounted) return;
    if (_source.scopeKey != scope || _currentHost(host.id) == null) {
      setState(() => _error = l10n.thisHostIsNoLongerAvailable);
      return;
    }
    if (existing != null && _activeAnywhere(host.id, existing.id)) {
      setState(() => _error = l10n.stopThisForwardBeforeEditingIts);
      return;
    }
    for (final session in _controller.sessionsOf(_source, host.id)) {
      session.manager?.clearError(profile.id);
    }
    _controller.clearNote(host.id, profile.id);
    await _save(
      host.id,
      expected: existing,
      replacement: profile,
      scope: scope,
    );
  }

  Future<void> _duplicate(HostRecord host, SshPortForwardProfile profile) {
    final name = context.l10n.r7ForwardCopyName(profile.name);
    return _edit(
      host,
      template: profile.copyWith(
        name: name.length > 64 ? name.substring(0, 64) : name,
      ),
    );
  }

  Future<void> _delete(HostRecord host, SshPortForwardProfile profile) async {
    if (_working || !_source.canEdit) return;
    // Bind the confirmation to this scope and this exact rule.
    final scope = _source.scopeKey;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('r7fwd-delete-confirm'),
        title: Text(context.l10n.r7ForwardDeleteTitle),
        content: Text(context.l10n.r7ForwardDeleteBody(profile.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('r7fwd-delete-accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!_stillSaved(scope, host.id, profile)) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      // Never leave a listener running for a rule that no longer exists.
      await _controller.stopEverywhere(_source, host.id, profile.id);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted || !_stillSaved(scope, host.id, profile)) return;
    await _save(host.id, expected: profile, scope: scope);
  }

  /// True while [scope] is current and the Host still saves exactly
  /// [profile]; otherwise shows why the action was dropped.
  bool _stillSaved(Object? scope, String hostId, SshPortForwardProfile profile) {
    final l10n = context.l10n;
    if (_source.scopeKey != scope) {
      setState(() => _error = l10n.r7ForwardScopeChanged);
      return false;
    }
    final saved = _currentHost(hostId)?.portForwardProfiles
        .where((rule) => rule.id == profile.id)
        .firstOrNull;
    if (saved != profile) {
      setState(() => _error = l10n.r7ForwardRuleConflict);
      return false;
    }
    return true;
  }

  Future<void> _save(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _source.saveRule(
        hostId,
        expected: expected,
        replacement: replacement,
        scope: scope,
      );
    } on SshPortForwardRuleConflict {
      if (mounted) setState(() => _error = context.l10n.r7ForwardRuleConflict);
    } catch (error) {
      if (mounted) setState(() => _error = _source.describeSaveError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  // ---- runtime --------------------------------------------------------

  Future<void> _start(HostRecord host, SshPortForwardProfile profile) async {
    setState(() => _error = null);
    // The start is bound to the rule the user saw (and approved) in this
    // scope; a rule changed meanwhile is never started blindly.
    final scope = _source.scopeKey;
    if (profile.exposesBeyondLoopback) {
      // Asked before every start, including before a new connection.
      final confirmed = await confirmSshPortForwardExposure(context, profile);
      if (!confirmed || !mounted) return;
    }
    await _controller.start(
      _source,
      host.id,
      profile.id,
      expected: profile,
      expectedScope: scope,
    );
  }

  // ---- build ----------------------------------------------------------

  bool _matches(HostRecord host) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    bool has(String value) => value.toLowerCase().contains(query);
    return has(host.name) ||
        has(host.address) ||
        has(host.username) ||
        host.portForwardProfiles.any(
          (profile) =>
              has(profile.name) ||
              has(sshPortForwardProfileDescription(profile)),
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hosts = _sshHosts;
    final hostIds = hosts.map((host) => host.id).toSet();
    final sessions = _source.sessions;
    var ruleCount = 0;
    var running = 0;
    for (final host in hosts) {
      ruleCount += host.portForwardProfiles.length;
    }
    for (final session in sessions) {
      final manager = session.liveManager;
      if (manager != null) running += manager.runningCount;
    }
    final searching = _query.trim().isNotEmpty;
    final visible =
        hosts
            .where(
              (host) =>
                  _matches(host) &&
                  (searching ||
                      _showAllHosts ||
                      host.portForwardProfiles.isNotEmpty ||
                      host.id == widget.initialHostId ||
                      _controller
                          .liveSessionsOf(_source, host.id)
                          .any((s) => s.liveManager!.runningCount > 0)),
            )
            .toList()
          ..sort((a, b) {
            if (a.id == widget.initialHostId) return -1;
            if (b.id == widget.initialHostId) return 1;
            final rules = (b.portForwardProfiles.isNotEmpty ? 1 : 0)
                .compareTo(a.portForwardProfiles.isNotEmpty ? 1 : 0);
            if (rules != 0) return rules;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    final removedHostSessions = sessions
        .where(
          (session) =>
              !hostIds.contains(session.hostId) &&
              (session.liveManager?.activeProfiles.isNotEmpty ?? false),
        )
        .toList(growable: false);
    final supported = _controller.runtimeSupported;
    final anyDynamic = hosts.any(
      (host) => host.portForwardProfiles.any(
        (profile) => profile.type == SshPortForwardType.dynamic,
      ),
    );

    return Material(
      key: const ValueKey('ssh-forwarding-page'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.r7ForwardTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.r7ForwardSummary(
                            ruleCount,
                            hosts
                                .where(
                                  (host) => host.portForwardProfiles.isNotEmpty,
                                )
                                .length,
                            running,
                          ),
                          key: const ValueKey('r7fwd-summary'),
                          style: const TextStyle(color: AppColors.muted),
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      key: const ValueKey('r7fwd-new-rule'),
                      onPressed: _working || !_source.canEdit || hosts.isEmpty
                          ? null
                          : _newRule,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.r7ForwardNewRule),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: TextField(
                        key: const ValueKey('r7fwd-search'),
                        controller: _search,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: l10n.r7ForwardSearchHint,
                        ),
                      ),
                    ),
                    FilterChip(
                      key: const ValueKey('r7fwd-show-all'),
                      selected: _showAllHosts,
                      onSelected: (value) =>
                          setState(() => _showAllHosts = value),
                      label: Text(l10n.r7ForwardShowAllHosts),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${_source.storageDescription} ${l10n.r7ForwardNoAutoStart}',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (!supported)
                  _Banner(
                    key: const ValueKey('r7fwd-unsupported'),
                    text:
                        _controller.unsupportedReason ??
                        l10n.forwardRuntimeUnsupported,
                  ),
                if (!_source.canEdit && _source.readOnlyReason != null)
                  _Banner(text: _source.readOnlyReason!),
                if (anyDynamic)
                  _Banner(text: l10n.dynamicForwardingIsASocks44a),
                if (_error != null)
                  _Banner(
                    key: const ValueKey('r7fwd-error'),
                    text: _error!,
                    color: AppColors.red,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              key: const ValueKey('r7fwd-list'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (hosts.isEmpty)
                  _Empty(text: l10n.r7ForwardNoHosts)
                else if (visible.isEmpty && removedHostSessions.isEmpty)
                  _Empty(
                    text: searching
                        ? l10n.r7ForwardNoMatches
                        : l10n.r7ForwardNoRules,
                  ),
                for (final host in visible)
                  _hostCard(host, supported: supported),
                for (final session in removedHostSessions)
                  _removedHostCard(session),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hostCard(HostRecord host, {required bool supported}) {
    final l10n = context.l10n;
    final sessions = _controller.sessionsOf(_source, host.id);
    final live = sessions
        .where((session) => session.liveManager != null)
        .toList(growable: false);
    final connecting = sessions.any(
      (session) => session.phase == SshForwardingSessionPhase.connecting,
    );
    final target = _controller.targetSession(_source, host.id);
    final pendingAny = host.portForwardProfiles.any(
      (profile) => _controller.isConnecting(host.id, profile.id),
    );
    final (String state, Color color) = live.isEmpty
        ? (connecting || pendingAny)
              ? (l10n.r7ForwardHostConnecting, AppColors.orange)
              : (l10n.r7ForwardHostNotConnected, AppColors.muted)
        : live.length == 1
        ? (l10n.r7ForwardHostConnected, Theme.of(context).colorScheme.primary)
        : (
            l10n.r7ForwardHostSessions(live.length),
            Theme.of(context).colorScheme.primary,
          );
    final savedIds = host.portForwardProfiles.map((p) => p.id).toSet();
    final orphans = [
      for (final session in live)
        for (final profile in session.liveManager!.activeProfiles)
          if (!savedIds.contains(profile.id)) (session, profile),
    ];
    final endpoint = host.username.isEmpty
        ? '${host.address}:${host.port}'
        : '${host.username}@${host.address}:${host.port}';
    return Card(
      key: ValueKey('r7fwd-host-${host.id}'),
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.dns_outlined, size: 18),
                Text(
                  host.name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  endpoint,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                Text(
                  state,
                  key: ValueKey('r7fwd-host-state-${host.id}'),
                  style: TextStyle(color: color, fontSize: 12),
                ),
                if (live.length > 1)
                  DropdownButton<String>(
                    key: ValueKey('r7fwd-session-select-${host.id}'),
                    value: target?.id,
                    isDense: true,
                    hint: Text(l10n.r7ForwardChooseSession),
                    items: [
                      for (final session in live)
                        DropdownMenuItem(
                          value: session.id,
                          child: Text(session.label),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) _controller.selectSession(host.id, id);
                    },
                  )
                else if (target != null)
                  Text(
                    target.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                if (target != null)
                  TextButton.icon(
                    key: ValueKey('r7fwd-open-session-${host.id}'),
                    onPressed: () => _source.showSession(target.id),
                    icon: const Icon(Icons.terminal, size: 16),
                    label: Text(l10n.r7ForwardOpenSession),
                  ),
                TextButton.icon(
                  key: ValueKey('r7fwd-add-${host.id}'),
                  onPressed: _working || !_source.canEdit
                      ? null
                      : () => _edit(host),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(l10n.addProfile),
                ),
              ],
            ),
            if (host.portForwardProfiles.isEmpty && orphans.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.noForwardingProfilesSavedForThis,
                  style: const TextStyle(color: AppColors.muted),
                ),
              ),
            for (final profile in host.portForwardProfiles)
              _ruleRow(
                host,
                profile,
                live: live,
                target: target,
                connectingSession: connecting,
                supported: supported,
              ),
            for (final (session, profile) in orphans)
              _orphanRow(host.id, session, profile),
          ],
        ),
      ),
    );
  }

  Widget _ruleRow(
    HostRecord host,
    SshPortForwardProfile profile, {
    required List<SshForwardingSessionInfo> live,
    required SshForwardingSessionInfo? target,
    required bool connectingSession,
    required bool supported,
  }) {
    final l10n = context.l10n;
    final id = '${host.id}-${profile.id}';
    final pending = _controller.isConnecting(host.id, profile.id);
    final busy = _controller.isBusy(host.id, profile.id);
    final manager = target?.liveManager;
    final status =
        manager?.statusOf(profile.id) ?? SshPortForwardStatus.stopped;
    final active =
        status.state == SshPortForwardState.running ||
        status.state == SshPortForwardState.starting;
    final stopping = status.state == SshPortForwardState.stopping;
    final note = _controller.noteOf(host.id, profile.id);
    final others = [
      for (final session in live)
        if (!identical(session, target) &&
            session.id != target?.id &&
            ruleIsActive(session.liveManager!, profile.id))
          session,
    ];
    final editable =
        !_working && _source.canEdit && !_activeAnywhere(host.id, profile.id);

    // What the primary button does right now.
    VoidCallback? onToggle;
    String tooltip;
    IconData icon;
    if (active) {
      tooltip = l10n.stopForwarding;
      icon = Icons.stop_circle_outlined;
      onToggle = busy || manager == null
          ? null
          : () => _controller.stop(manager, host.id, profile.id);
    } else if (target != null) {
      tooltip = l10n.startForwarding;
      icon = Icons.play_circle_outline;
      onToggle = busy || stopping || pending || !supported
          ? null
          : () => _start(host, profile);
    } else {
      tooltip = live.length > 1
          ? l10n.r7ForwardChooseSession
          : connectingSession
          ? l10n.r7ForwardWaitForSession
          : l10n.r7ForwardConnectAndStart;
      icon = Icons.power_settings_new;
      onToggle =
          busy || pending || !supported || live.length > 1 || connectingSession
          ? null
          : () => _start(host, profile);
    }

    return Container(
      key: ValueKey('r7fwd-rule-$id'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TypeBadge(profile.type),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (profile.exposesBeyondLoopback) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: l10n.reachableBeyondLoopback,
                        child: const Icon(
                          Icons.public,
                          size: 15,
                          color: AppColors.orange,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sshPortForwardProfileDescription(
                    profile,
                    activePort: status.listeningPort,
                  ),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 3),
                if (pending)
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          l10n.r7ForwardConnectingStart,
                          key: ValueKey('r7fwd-status-$id'),
                          style: const TextStyle(
                            color: AppColors.orange,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        key: ValueKey('r7fwd-cancel-$id'),
                        onPressed: () =>
                            _controller.cancelPending(host.id, profile.id),
                        child: Text(l10n.cancel2),
                      ),
                    ],
                  )
                else
                  _statusText(id, status),
                if (status.isRunning && status.lastConnectionError != null)
                  Text(
                    l10n.lastConnectionLastconnectionerror(
                      status.lastConnectionError!,
                    ),
                    key: ValueKey('r7fwd-connection-error-$id'),
                    style: const TextStyle(
                      color: AppColors.orange,
                      fontSize: 12,
                    ),
                  ),
                if (note != null)
                  Text(
                    note,
                    key: ValueKey('r7fwd-note-$id'),
                    style: const TextStyle(
                      color: AppColors.orange,
                      fontSize: 12,
                    ),
                  ),
                for (final session in others)
                  _otherSessionLine(host.id, profile.id, session),
              ],
            ),
          ),
          if (supported)
            IconButton(
              key: ValueKey('r7fwd-toggle-$id'),
              tooltip: tooltip,
              onPressed: onToggle,
              icon: Icon(icon),
            ),
          PopupMenuButton<String>(
            key: ValueKey('r7fwd-menu-$id'),
            tooltip: l10n.r7ForwardMoreActions,
            enabled: !_working && _source.canEdit,
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  _edit(host, existing: profile);
                case 'duplicate':
                  _duplicate(host, profile);
                case 'delete':
                  _delete(host, profile);
              }
            },
            itemBuilder: (context) => [
              appMenuItem(context,
                key: const ValueKey('r7fwd-edit'),
                value: 'edit',
                enabled: editable,
                child: Text(l10n.editForwardingProfile),
              ),
              appMenuItem(context,
                key: const ValueKey('r7fwd-duplicate'),
                value: 'duplicate',
                enabled: !_working && _source.canEdit,
                child: Text(l10n.r7ForwardDuplicate),
              ),
              appMenuItem(context,
                key: const ValueKey('r7fwd-delete'),
                value: 'delete',
                enabled: !_working && _source.canEdit,
                child: Text(l10n.deleteForwardingProfile),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusText(String id, SshPortForwardStatus status) {
    final l10n = context.l10n;
    final (String text, Color color) = switch (status.state) {
      SshPortForwardState.running => (
        l10n.forwardStatusRunning(
          status.activeConnections,
          status.totalConnections,
        ),
        Theme.of(context).colorScheme.primary,
      ),
      SshPortForwardState.starting => (l10n.starting, AppColors.muted),
      SshPortForwardState.stopping => (
        l10n.forwardStatusStopping,
        AppColors.muted,
      ),
      SshPortForwardState.failed => (
        l10n.forwardStatusFailed(status.error ?? l10n.forwardStatusUnknownError),
        AppColors.red,
      ),
      SshPortForwardState.stopped => (
        l10n.forwardStatusStopped,
        AppColors.muted,
      ),
    };
    return Text(
      text,
      key: ValueKey('r7fwd-status-$id'),
      style: TextStyle(color: color, fontSize: 12),
    );
  }

  Widget _otherSessionLine(
    String hostId,
    String profileId,
    SshForwardingSessionInfo session,
  ) {
    final manager = session.liveManager!;
    final status = manager.statusOf(profileId);
    final stopping = status.state == SshPortForwardState.stopping;
    return Row(
      key: ValueKey('r7fwd-other-$hostId-$profileId-${session.id}'),
      children: [
        Flexible(
          child: Text(
            context.l10n.r7ForwardOnSession(
              session.label,
              switch (status.state) {
                SshPortForwardState.running => context.l10n
                    .forwardStatusRunning(
                      status.activeConnections,
                      status.totalConnections,
                    ),
                SshPortForwardState.starting => context.l10n.starting,
                SshPortForwardState.stopping =>
                  context.l10n.forwardStatusStopping,
                _ => context.l10n.forwardStatusStopped,
              },
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        IconButton(
          key: ValueKey('r7fwd-other-stop-$hostId-$profileId-${session.id}'),
          tooltip: context.l10n.stopForwarding,
          visualDensity: VisualDensity.compact,
          onPressed: stopping || _controller.isBusy(hostId, profileId)
              ? null
              : () => _controller.stop(manager, hostId, profileId),
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
        ),
      ],
    );
  }

  Widget _orphanRow(
    String hostId,
    SshForwardingSessionInfo session,
    SshPortForwardProfile profile,
  ) {
    final manager = session.liveManager!;
    final status = manager.statusOf(profile.id);
    return ListTile(
      key: ValueKey('r7fwd-orphan-${session.id}-${profile.id}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      leading: _TypeBadge(profile.type),
      title: Text(profile.name),
      subtitle: Text(
        '${context.l10n.sshportforwardprofiledescriptionNoLongerSavedForThis(sshPortForwardProfileDescription(profile, activePort: status.listeningPort))}\n${session.label}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        key: ValueKey('r7fwd-orphan-stop-${session.id}-${profile.id}'),
        tooltip: context.l10n.stopForwarding,
        onPressed: status.state == SshPortForwardState.stopping
            ? null
            : () => _controller.stop(manager, hostId, profile.id),
        icon: const Icon(Icons.stop_circle_outlined),
      ),
    );
  }

  Widget _removedHostCard(SshForwardingSessionInfo session) {
    final manager = session.liveManager!;
    return Card(
      key: ValueKey('r7fwd-removed-${session.id}'),
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${session.label} · ${context.l10n.r7ForwardRemovedHost}',
              style: const TextStyle(color: AppColors.orange),
            ),
            for (final profile in manager.activeProfiles)
              _orphanRow(session.hostId, session, profile),
          ],
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge(this.type);

  final SshPortForwardType type;

  @override
  Widget build(BuildContext context) {
    final (String letter, String label) = switch (type) {
      SshPortForwardType.local => ('L', context.l10n.localL),
      SshPortForwardType.remote => ('R', context.l10n.remoteR),
      SshPortForwardType.dynamic => ('D', context.l10n.dynamicSocksD),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          letter,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.color = AppColors.orange, super.key});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: TextStyle(color: color, height: 1.4)),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
    child: Text(
      text,
      key: const ValueKey('r7fwd-empty'),
      textAlign: TextAlign.center,
      style: const TextStyle(color: AppColors.muted),
    ),
  );
}

class _HostPicker extends StatefulWidget {
  const _HostPicker({required this.hosts});

  final List<HostRecord> hosts;

  @override
  State<_HostPicker> createState() => _HostPickerState();
}

class _HostPickerState extends State<_HostPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final hosts = widget.hosts
        .where(
          (host) =>
              query.isEmpty ||
              host.name.toLowerCase().contains(query) ||
              host.address.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return AlertDialog(
      key: const ValueKey('r7fwd-host-picker'),
      title: Text(context.l10n.r7ForwardChooseHost),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('r7fwd-host-picker-search'),
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: context.l10n.r7ForwardSearchHint,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final host in hosts)
                    ListTile(
                      key: ValueKey('r7fwd-pick-${host.id}'),
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(host.name),
                      subtitle: Text('${host.address}:${host.port}'),
                      onTap: () => Navigator.pop(context, host),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
      ],
    );
  }
}
