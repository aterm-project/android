import 'app_motion.dart';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../ssh/port_forward_runtime.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';

/// Shared SSH port forwarding management used by both cloud (Vault) and
/// standalone local profiles.
///
/// The dialog owns no persistence and no SSH state. Callers pass:
/// * [profiles]: the latest saved profiles of the bound Host, or `null` when
///   that Host is no longer in the caller's scope (deleted, vault/profile
///   switched). Read on every rebuild.
/// * [saveProfiles]: writes the complete list through the caller's existing
///   encrypted Host store and revision guard; throws on failure.
/// * [manager]: the forwarding runtime of the bound SSH connection, or `null`
///   when there is no live connection (profiles can still be configured).
/// * [changes]: rebuild trigger for Host/connection changes.
Future<void> showSshPortForwardingDialog(
  BuildContext context, {
  required String hostName,
  required List<SshPortForwardProfile>? Function() profiles,
  required Future<void> Function(List<SshPortForwardProfile> profiles)
  saveProfiles,
  required SshPortForwardManager? Function() manager,
  required String storageDescription,
  Listenable? changes,
  bool Function()? canEdit,
  String? readOnlyReason,
  String? disconnectedNote,
  String Function(Object error)? describeSaveError,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => SshPortForwardingDialog(
    hostName: hostName,
    profiles: profiles,
    saveProfiles: saveProfiles,
    manager: manager,
    storageDescription: storageDescription,
    changes: changes,
    canEdit: canEdit,
    readOnlyReason: readOnlyReason,
    disconnectedNote: disconnectedNote,
    describeSaveError: describeSaveError,
  ),
);

/// Short label for a menu entry, including how many forwards are running.
String sshPortForwardingMenuLabel(String base, SshPortForwardManager? manager) {
  final running = manager == null || !manager.isOpen ? 0 : manager.runningCount;
  return running == 0 ? base : '$base ($running)';
}

class SshPortForwardingDialog extends StatefulWidget {
  const SshPortForwardingDialog({
    required this.hostName,
    required this.profiles,
    required this.saveProfiles,
    required this.manager,
    required this.storageDescription,
    this.changes,
    this.canEdit,
    this.readOnlyReason,
    this.disconnectedNote,
    this.describeSaveError,
    super.key,
  });

  final String hostName;
  final List<SshPortForwardProfile>? Function() profiles;
  final Future<void> Function(List<SshPortForwardProfile> profiles)
  saveProfiles;
  final SshPortForwardManager? Function() manager;
  final String storageDescription;
  final Listenable? changes;
  final bool Function()? canEdit;
  final String? readOnlyReason;

  /// Shown instead of the default note when there is no live connection.
  final String? disconnectedNote;
  final String Function(Object error)? describeSaveError;

  @override
  State<SshPortForwardingDialog> createState() =>
      _SshPortForwardingDialogState();
}

class _SshPortForwardingDialogState extends State<SshPortForwardingDialog> {
  SshPortForwardManager? _manager;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_onExternalChange);
    _bindManager();
  }

  @override
  void didUpdateWidget(SshPortForwardingDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      oldWidget.changes?.removeListener(_onExternalChange);
      widget.changes?.addListener(_onExternalChange);
    }
    _bindManager();
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_onExternalChange);
    _manager?.removeListener(_onManagerChange);
    super.dispose();
  }

  /// Follows the bound tab's current connection: after a disconnect the old
  /// manager is closed and dropped, so stale "running" state is never shown.
  void _bindManager() {
    final next = widget.manager();
    if (identical(next, _manager)) return;
    _manager?.removeListener(_onManagerChange);
    _manager = next;
    _manager?.addListener(_onManagerChange);
  }

  void _onExternalChange() {
    if (!mounted) return;
    setState(_bindManager);
  }

  void _onManagerChange() {
    if (mounted) setState(() {});
  }

  SshPortForwardManager? get _liveManager {
    final manager = _manager;
    return manager != null && manager.isOpen ? manager : null;
  }

  bool get _canEdit => widget.canEdit?.call() ?? true;

  bool _isBusy(SshPortForwardManager? manager, String id) {
    if (manager == null) return false;
    return manager.activeProfileIds.contains(id) ||
        manager.isStarting(id) ||
        manager.isStopping(id);
  }

  Future<void> _edit(
    List<SshPortForwardProfile> current, [
    SshPortForwardProfile? existing,
  ]) async {
    if (_working) return;
    if (existing != null && _isBusy(_liveManager, existing.id)) {
      setState(() => _error = context.l10n.stopThisForwardBeforeEditingIts);
      return;
    }
    if (existing == null && current.length >= maxHostPortForwardProfiles) {
      setState(
        () => _error = context.l10n.aHostCanHaveAtMost(
          maxHostPortForwardProfiles,
        ),
      );
      return;
    }
    final profile = await showAppDialog<SshPortForwardProfile>(
      context: context,
      builder: (_) => SshPortForwardProfileEditor(
        existing: existing,
        siblings: current.where((item) => item.id != existing?.id).toList(),
      ),
    );
    if (profile == null || !mounted) return;
    final latest = widget.profiles();
    if (latest == null) {
      setState(() => _error = context.l10n.thisHostIsNoLongerAvailable);
      return;
    }
    final next = [...latest];
    final index = next.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    _manager?.clearError(profile.id);
    await _save(
      next,
      failure: context.l10n.couldNotSaveForwardingSettingsNothing,
    );
  }

  Future<void> _delete(SshPortForwardProfile profile) async {
    if (_working) return;
    final latest = widget.profiles();
    if (latest == null) {
      setState(() => _error = context.l10n.thisHostIsNoLongerAvailable);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final manager = _liveManager;
      if (manager != null && _isBusy(manager, profile.id)) {
        await manager.stop(profile.id);
      }
    } catch (error) {
      // The forward is no longer tracked even if stop reported a failure.
      if (mounted) _error = describeSshPortForwardError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted) return;
    await _save(
      latest.where((item) => item.id != profile.id).toList(),
      failure: context.l10n.couldNotRemoveThisForwardingProfile2,
    );
  }

  Future<void> _save(
    List<SshPortForwardProfile> profiles, {
    required String failure,
  }) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.saveProfiles(List.unmodifiable(profiles));
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = widget.describeSaveError?.call(error) ?? failure,
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _toggle(SshPortForwardProfile profile) async {
    if (_working) return;
    final manager = _liveManager;
    if (manager == null) {
      setState(() => _error = context.l10n.connectThisHostOverSshTo);
      return;
    }
    if (manager.isStopping(profile.id)) return;
    if (_isBusy(manager, profile.id)) {
      // Exclusive until teardown finished, so Start cannot race the stop.
      setState(() {
        _working = true;
        _error = null;
      });
      try {
        await manager.stop(profile.id);
      } catch (error) {
        if (mounted) _error = describeSshPortForwardError(error);
      } finally {
        if (mounted) setState(() => _working = false);
      }
      return;
    }
    if (profile.exposesBeyondLoopback) {
      final confirmed = await confirmSshPortForwardExposure(context, profile);
      if (!confirmed || !mounted) return;
    }
    setState(() => _error = null);
    try {
      await manager.start(profile);
    } catch (_) {
      // The per-profile status row shows the sanitized reason.
    }
  }

  Future<void> _stopOrphan(SshPortForwardProfile profile) async {
    try {
      await _manager?.stop(profile.id);
    } catch (error) {
      if (mounted) setState(() => _error = describeSshPortForwardError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.profiles();
    final manager = _liveManager;
    final hostMissing = profiles == null;
    final saved = profiles ?? const <SshPortForwardProfile>[];
    final savedIds = saved.map((profile) => profile.id).toSet();
    final orphans = manager == null
        ? const <SshPortForwardProfile>[]
        : manager.activeProfiles
              .where((profile) => !savedIds.contains(profile.id))
              .toList();
    final canEdit = _canEdit && !hostMissing;
    final supported = manager?.isSupported ?? true;
    final runtimeNote = !supported
        ? manager!.unsupportedReason ?? context.l10n.forwardRuntimeUnsupported
        : manager == null
        ? widget.disconnectedNote ?? context.l10n.forwardRuntimeDisconnected
        : context.l10n.forwardRuntimeRunningNote;
    return AlertDialog(
      key: const ValueKey('ssh-port-forwarding-dialog'),
      title: Text(context.l10n.sshPortForwardingHostname(widget.hostName)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.storageDescription,
                style: TextStyle(color: context.palette.muted, height: 1.45),
              ),
              const SizedBox(height: 4),
              Text(
                runtimeNote,
                key: const ValueKey('ssh-forward-runtime-note'),
                style: TextStyle(
                  color: supported ? context.palette.muted : context.palette.orange,
                  height: 1.45,
                ),
              ),
              if (hostMissing) ...[
                const SizedBox(height: 4),
                Text(
                  context.l10n.thisHostIsNotSavedIn,
                  key: const ValueKey('ssh-forward-host-missing'),
                  style: TextStyle(color: context.palette.orange, height: 1.45),
                ),
              ],
              if (!hostMissing &&
                  !_canEdit &&
                  widget.readOnlyReason != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.readOnlyReason!,
                  style: TextStyle(color: context.palette.orange),
                ),
              ],
              if (saved.any(
                (profile) => profile.type == SshPortForwardType.dynamic,
              )) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.dynamicForwardingIsASocks44a,
                  style: TextStyle(color: context.palette.orange, height: 1.4),
                ),
              ],
              const SizedBox(height: 12),
              if (saved.isEmpty && !hostMissing)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    context.l10n.noForwardingProfilesSavedForThis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.muted),
                  ),
                ),
              for (final profile in saved)
                _profileCard(
                  profile,
                  manager: manager,
                  supported: supported,
                  canEdit: canEdit,
                  current: saved,
                ),
              for (final profile in orphans)
                _orphanCard(profile, manager!.statusOf(profile.id)),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('ssh-forward-error'),
                  style: TextStyle(color: context.palette.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
        OutlinedButton.icon(
          key: const ValueKey('ssh-forward-add'),
          onPressed: _working || !canEdit ? null : () => _edit(saved),
          icon: const Icon(Icons.add),
          label: Text(context.l10n.addProfile),
        ),
      ],
    );
  }

  Widget _profileCard(
    SshPortForwardProfile profile, {
    required SshPortForwardManager? manager,
    required bool supported,
    required bool canEdit,
    required List<SshPortForwardProfile> current,
  }) {
    final status =
        manager?.statusOf(profile.id) ?? SshPortForwardStatus.stopped;
    final stopping = status.state == SshPortForwardState.stopping;
    final busy =
        status.state == SshPortForwardState.running ||
        status.state == SshPortForwardState.starting ||
        stopping;
    return Card(
      key: ValueKey('ssh-forward-profile-${profile.id}'),
      color: context.palette.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          children: [
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
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (profile.exposesBeyondLoopback) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: context.l10n.reachableBeyondLoopback,
                          child: Icon(
                            Icons.public,
                            size: 16,
                            color: context.palette.orange,
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
                    style: TextStyle(color: context.palette.muted),
                  ),
                  const SizedBox(height: 4),
                  _statusLine(profile.id, status),
                ],
              ),
            ),
            if (supported)
              IconButton(
                key: ValueKey('ssh-forward-toggle-${profile.id}'),
                tooltip: busy
                    ? context.l10n.stopForwarding
                    : context.l10n.startForwarding,
                onPressed: _working || stopping || (manager == null && !busy)
                    ? null
                    : () => _toggle(profile),
                icon: Icon(
                  busy ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                ),
              ),
            IconButton(
              key: ValueKey('ssh-forward-edit-${profile.id}'),
              tooltip: context.l10n.editForwardingProfile,
              onPressed: _working || !canEdit || busy
                  ? null
                  : () => _edit(current, profile),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              key: ValueKey('ssh-forward-delete-${profile.id}'),
              tooltip: context.l10n.deleteForwardingProfile,
              onPressed: _working || !canEdit ? null : () => _delete(profile),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _orphanCard(SshPortForwardProfile profile, SshPortForwardStatus s) =>
      Card(
        key: ValueKey('ssh-forward-orphan-${profile.id}'),
        color: context.palette.surface,
        child: ListTile(
          title: Text(profile.name),
          subtitle: Text(
            context.l10n.sshportforwardprofiledescriptionNoLongerSavedForThis(
              sshPortForwardProfileDescription(
                profile,
                activePort: s.listeningPort,
              ),
            ),
          ),
          isThreeLine: true,
          trailing: IconButton(
            key: ValueKey('ssh-forward-orphan-stop-${profile.id}'),
            tooltip: context.l10n.stopForwarding,
            onPressed: () => _stopOrphan(profile),
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ),
      );

  Widget _statusLine(String id, SshPortForwardStatus status) {
    final primary = Theme.of(context).colorScheme.primary;
    final (String text, Color color) = switch (status.state) {
      SshPortForwardState.running => (
        context.l10n.forwardStatusRunning(
          status.activeConnections,
          status.totalConnections,
        ),
        primary,
      ),
      SshPortForwardState.starting => (context.l10n.starting, context.palette.muted),
      SshPortForwardState.stopping => (
        context.l10n.forwardStatusStopping,
        context.palette.muted,
      ),
      SshPortForwardState.failed => (
        context.l10n.forwardStatusFailed(
          status.error ?? context.l10n.forwardStatusUnknownError,
        ),
        context.palette.red,
      ),
      SshPortForwardState.stopped => (
        context.l10n.forwardStatusStopped,
        context.palette.muted,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          key: ValueKey('ssh-forward-status-$id'),
          style: TextStyle(color: color, fontSize: 12),
        ),
        if (status.isRunning && status.lastConnectionError != null)
          Text(
            context.l10n.lastConnectionLastconnectionerror(
              '${status.lastConnectionError}',
            ),
            key: ValueKey('ssh-forward-connection-error-$id'),
            style: TextStyle(color: context.palette.orange, fontSize: 12),
          ),
      ],
    );
  }
}

String sshPortForwardProfileDescription(
  SshPortForwardProfile profile, {
  int? activePort,
}) {
  final port = profile.bindPort == 0
      ? activePort?.toString() ?? 'auto'
      : profile.bindPort.toString();
  final bind = profile.bindAddress.contains(':')
      ? '[${profile.bindAddress}]:$port'
      : '${profile.bindAddress}:$port';
  final destination = profile.destinationAddress == null
      ? ''
      : profile.destinationAddress!.contains(':')
      ? '[${profile.destinationAddress}]:${profile.destinationPort}'
      : '${profile.destinationAddress}:${profile.destinationPort}';
  return switch (profile.type) {
    SshPortForwardType.local => currentL10n.localLBindDestinationViaSsh(
      bind,
      destination,
    ),
    SshPortForwardType.remote => currentL10n.remoteRSshServerBindThis(
      bind,
      destination,
    ),
    SshPortForwardType.dynamic => currentL10n.dynamicSocksDBind(bind),
  };
}

/// Explicit confirmation before saving or starting a profile that is reachable
/// beyond loopback.
Future<bool> confirmSshPortForwardExposure(
  BuildContext context,
  SshPortForwardProfile profile,
) async {
  final l10n = context.l10n;
  final destination =
      '${profile.destinationAddress}:${profile.destinationPort}';
  final what = switch (profile.type) {
    SshPortForwardType.local => l10n.forwardExposureLocal(
      profile.bindAddress,
      destination,
    ),
    SshPortForwardType.dynamic => l10n.forwardExposureDynamic(
      profile.bindAddress,
    ),
    SshPortForwardType.remote =>
      isLoopbackForwardAddress(profile.bindAddress)
          ? l10n.forwardExposureRemoteLoopback(destination)
          : l10n.forwardExposureRemotePublic(destination),
  };
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('ssh-forward-exposure-confirm'),
      title: Text(context.l10n.exposeThisForwardBeyondLoopback),
      content: SizedBox(
        width: 460,
        child: Text(
          context.l10n.whatOnlyContinueOnANetwork(what),
          style: const TextStyle(height: 1.45),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ssh-forward-exposure-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          key: const ValueKey('ssh-forward-exposure-accept'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.expose),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class SshPortForwardProfileEditor extends StatefulWidget {
  const SshPortForwardProfileEditor({
    this.existing,
    this.template,
    this.siblings = const [],
    super.key,
  });

  final SshPortForwardProfile? existing;

  /// Prefills a new profile (duplicate). Saved with a new id; never replaces
  /// the template. Ignored when [existing] is set.
  final SshPortForwardProfile? template;

  /// Other saved profiles of the Host, for listener conflict checks.
  final List<SshPortForwardProfile> siblings;

  @override
  State<SshPortForwardProfileEditor> createState() =>
      _SshPortForwardProfileEditorState();
}

class _SshPortForwardProfileEditorState
    extends State<SshPortForwardProfileEditor> {
  late final SshPortForwardProfile? _initial =
      widget.existing ?? widget.template;
  late final _name = TextEditingController(text: _initial?.name ?? '');
  late final _bindAddress = TextEditingController(
    text: _initial?.bindAddress ?? '127.0.0.1',
  );
  late final _bindPort = TextEditingController(
    text: '${_initial?.bindPort ?? 0}',
  );
  late final _destinationAddress = TextEditingController(
    text: _initial?.destinationAddress ?? '',
  );
  late final _destinationPort = TextEditingController(
    text: _initial?.destinationPort?.toString() ?? '',
  );
  late SshPortForwardType _type =
      _initial?.type ?? SshPortForwardType.local;
  late bool _expose = _initial?.exposeToNetwork ?? false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _bindAddress.dispose();
    _bindPort.dispose();
    _destinationAddress.dispose();
    _destinationPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bindLabel = switch (_type) {
      SshPortForwardType.local => context.l10n.deviceListenerAddress,
      SshPortForwardType.remote => context.l10n.sshServerListenerAddress,
      SshPortForwardType.dynamic => context.l10n.deviceSocksListenerAddress,
    };
    final destinationLabel = _type == SshPortForwardType.remote
        ? context.l10n.destinationReachedFromThisDevice
        : context.l10n.destinationReachedFromTheSshServer;
    return AlertDialog(
      title: Text(
        widget.existing != null
            ? context.l10n.editForwardingProfile
            : widget.template != null
            ? context.l10n.r7ForwardDuplicateTitle
            : context.l10n.addForwardingProfile,
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('ssh-forward-profile-name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: context.l10n.profileName,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<SshPortForwardType>(
                key: const ValueKey('ssh-forward-type'),
                initialValue: _type,
                decoration: InputDecoration(
                  labelText: context.l10n.forwardType,
                ),
                items: [
                  DropdownMenuItem(
                    value: SshPortForwardType.local,
                    child: Text(context.l10n.localL),
                  ),
                  DropdownMenuItem(
                    value: SshPortForwardType.remote,
                    child: Text(context.l10n.remoteR),
                  ),
                  DropdownMenuItem(
                    value: SshPortForwardType.dynamic,
                    child: Text(context.l10n.dynamicSocksD),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _type = value);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ssh-forward-bind-address'),
                      controller: _bindAddress,
                      decoration: InputDecoration(
                        labelText: bindLabel,
                        helperText: _expose
                            ? context.l10n.loopbackOrAnIpAddress
                            : context.l10n.loopbackOnly,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 104,
                    child: TextField(
                      key: const ValueKey('ssh-forward-bind-port'),
                      controller: _bindPort,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: context.l10n.port,
                        helperText: context.l10n.n0Auto,
                      ),
                    ),
                  ),
                ],
              ),
              if (_type != SshPortForwardType.dynamic) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('ssh-forward-destination-address'),
                        controller: _destinationAddress,
                        decoration: InputDecoration(
                          labelText: destinationLabel,
                          helperText:
                              _type == SshPortForwardType.remote && !_expose
                              ? context.l10n.thisDeviceLoopbackOnly
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 104,
                      child: TextField(
                        key: const ValueKey('ssh-forward-destination-port'),
                        controller: _destinationPort,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: context.l10n.port,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_type == SshPortForwardType.dynamic) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.socks44a5ConnectWithoutSocks,
                    style: TextStyle(
                      color: context.palette.orange,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              if (_type == SshPortForwardType.remote) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.theSshServerGatewayportsSettingMay2,
                    style: TextStyle(
                      color: context.palette.orange,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const ValueKey('ssh-forward-advanced'),
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: _expose,
                  title: Text(context.l10n.advanced),
                  children: [
                    SwitchListTile(
                      key: const ValueKey('ssh-forward-expose'),
                      contentPadding: EdgeInsets.zero,
                      value: _expose,
                      onChanged: (value) => setState(() => _expose = value),
                      title: Text(context.l10n.allowNetworkExposure),
                      subtitle: Text(
                        context.l10n.permitANonLoopbackListenerFor,
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    key: const ValueKey('ssh-forward-profile-error'),
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
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          key: const ValueKey('ssh-forward-profile-save'),
          onPressed: _save,
          child: Text(context.l10n.saveEncryptedProfile),
        ),
      ],
    );
  }

  Future<void> _save() async {
    // Unparsable ports become out-of-range values so validate() reports them.
    final bindPort = int.tryParse(_bindPort.text.trim()) ?? -1;
    final destinationPort = int.tryParse(_destinationPort.text.trim());
    final profile = SshPortForwardProfile(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      type: _type,
      bindAddress: _bindAddress.text.trim(),
      bindPort: bindPort,
      destinationAddress: _type == SshPortForwardType.dynamic
          ? null
          : _destinationAddress.text.trim(),
      destinationPort: _type == SshPortForwardType.dynamic
          ? null
          : destinationPort,
      // Only persist the acknowledgement when it is actually needed.
      exposeToNetwork: false,
    );
    final candidate = _expose && profile.exposesBeyondLoopback
        ? profile.copyWith(exposeToNetwork: true)
        : profile;
    final issue = candidate.validate();
    if (issue != null) {
      setState(() => _error = issue);
      return;
    }
    if (widget.siblings.any(
      (other) => sshPortForwardListenersConflict(other, candidate),
    )) {
      setState(() => _error = context.l10n.anotherProfileOfThisHostAlready);
      return;
    }
    if (candidate.exposesBeyondLoopback &&
        !(widget.existing?.exposeToNetwork == true &&
            widget.existing == candidate)) {
      final confirmed = await confirmSshPortForwardExposure(context, candidate);
      if (!confirmed || !mounted) return;
    }
    if (mounted) Navigator.pop(context, candidate);
  }
}

/// Manual change signal for callers without a Listenable model (local mode
/// fires it after Host reloads and session changes).
class SshPortForwardChangeRelay extends ChangeNotifier {
  void fire() => notifyListeners();
}
