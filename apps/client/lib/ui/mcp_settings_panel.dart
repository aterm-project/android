import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../mcp/mcp_access_policy.dart';
import '../mcp/mcp_service.dart';
import '../mcp/mcp_listener_lifecycle.dart';
import '../mcp/mcp_tools.dart';
import 'app_theme.dart';
import 'responsive_layout.dart';
import 'settings_scaffold.dart';

/// Localized name of an MCP access level, shared by every MCP surface.
String mcpAccessModeLabel(AppLocalizations l10n, McpAccessMode mode) =>
    switch (mode) {
      McpAccessMode.denied => l10n.mcpAccessModeDenied,
      McpAccessMode.readOnly => l10n.mcpAccessModeReadOnly,
      McpAccessMode.readWrite => l10n.mcpAccessModeReadWrite,
    };

String mcpAccessModeDescription(AppLocalizations l10n, McpAccessMode mode) =>
    switch (mode) {
      McpAccessMode.denied => l10n.mcpAccessModeDeniedDescription,
      McpAccessMode.readOnly => l10n.mcpAccessModeReadOnlyDescription,
      McpAccessMode.readWrite => l10n.mcpAccessModeReadWriteDescription,
    };

IconData mcpAccessModeIcon(McpAccessMode mode) => switch (mode) {
  McpAccessMode.denied => Icons.block_outlined,
  McpAccessMode.readOnly => Icons.visibility_outlined,
  McpAccessMode.readWrite => Icons.edit_outlined,
};

/// The per-machine choice: inherit the default, or one explicit level.
enum _HostChoice {
  inherit(null),
  denied(McpAccessMode.denied),
  readOnly(McpAccessMode.readOnly),
  readWrite(McpAccessMode.readWrite);

  const _HostChoice(this.mode);
  final McpAccessMode? mode;

  static _HostChoice of(McpAccessMode? mode) =>
      values.firstWhere((choice) => choice.mode == mode);
}

/// Settings › AI / MCP. The same panel is used by the Windows, Linux, macOS
/// and Android clients; only the arrangement adapts to the available width.
class McpSettingsPanel extends StatefulWidget {
  const McpSettingsPanel({this.service, super.key});
  final McpService? service;

  /// Machines rendered before "Show more"; keeps huge inventories responsive.
  static const machinePageSize = 50;

  @override
  State<McpSettingsPanel> createState() => _McpSettingsPanelState();
}

class _McpSettingsPanelState extends State<McpSettingsPanel> {
  final _port = TextEditingController(text: '8765');
  final _query = TextEditingController();
  McpService get service => widget.service ?? McpService.instance;
  String? _error;
  String? _accessError;
  bool _copied = false;
  bool _defaultPending = false;
  final _pendingHosts = <String>{};

  /// Bumped when a save fails so every choice field is rebuilt from the
  /// value the policy actually holds instead of the rejected selection.
  int _resetEpoch = 0;
  int _visibleMachines = McpSettingsPanel.machinePageSize;

  @override
  void initState() {
    super.initState();
    service.addListener(_syncListeningPort);
    _syncListeningPort();
  }

  void _syncListeningPort() {
    final endpoint = service.endpoint;
    if (endpoint != null && _port.text != '${endpoint.port}') {
      _port.text = '${endpoint.port}';
    }
  }

  @override
  void didUpdateWidget(McpSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.service ?? McpService.instance;
    if (!identical(previous, service)) {
      previous.removeListener(_syncListeningPort);
      service.addListener(_syncListeningPort);
      _syncListeningPort();
    }
  }

  @override
  void dispose() {
    service.removeListener(_syncListeningPort);
    _port.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = context.l10n.portMustBe102465535);
      return;
    }
    setState(() {
      _error = null;
      _copied = false;
    });
    try {
      await service.start(port: port);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.couldntStartMcpMakeSureThe);
      }
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: service.connectionConfiguration()),
      );
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.l10n.couldntCopyTheConfigurationCheckClipboard,
        );
      }
    }
  }

  Future<bool> _confirmReadWriteDefault() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('mcp_confirm_read_write_default'),
        title: Text(l10n.mcpConfirmReadWriteDefaultTitle),
        content: Text(l10n.mcpConfirmReadWriteDefaultBody),
        actions: [
          TextButton(
            key: const ValueKey('mcp_confirm_read_write_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('mcp_confirm_read_write_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.mcpConfirmReadWriteDefaultConfirm),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _setDefault(McpAccessMode mode) async {
    if (_defaultPending || mode == service.defaultAccess) return;
    // Widening every machine (including future ones) to read & write is the
    // one choice that deserves an explicit confirmation.
    if (mode == McpAccessMode.readWrite && !await _confirmReadWriteDefault()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _defaultPending = true;
      _accessError = null;
    });
    try {
      await service.setDefaultAccess(mode);
    } catch (_) {
      if (mounted) {
        setState(() => _accessError = context.l10n.mcpAccessSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _defaultPending = false);
    }
  }

  Future<void> _setHost(String hostId, McpAccessMode? mode) async {
    if (_pendingHosts.contains(hostId)) return;
    if (service.accessOverrideForHost(hostId) == mode) return;
    setState(() {
      _pendingHosts.add(hostId);
      _accessError = null;
    });
    try {
      await service.setHostAccess(hostId, mode);
    } catch (_) {
      if (mounted) {
        setState(() {
          _accessError = context.l10n.mcpAccessSaveFailed;
          _resetEpoch++;
        });
      }
    } finally {
      if (mounted) setState(() => _pendingHosts.remove(hostId));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      service,
      if (McpListenerLifecycle.installed case final lifecycle?) lifecycle,
    ]),
    builder: (context, _) => SettingsCards(
      children: [
        _serviceCard(context),
        if (service.supported) _machineAccessCard(context),
        _toolsCard(context),
        _auditCard(context),
      ],
    ),
  );

  Widget _serviceCard(BuildContext context) {
    final l10n = context.l10n;
    final ready = service.permissionsReady && !service.permissionsLoading;
    final defaultMode = ready ? service.defaultAccess : McpAccessMode.denied;
    final endpoint = service.endpoint;
    return SettingsCard(
      // Holds fields and buttons: keep each control its own a11y node.
      semanticContainer: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.externalAiAccess,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.letExternalAiUseTheHosts,
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          const SizedBox(height: 12),
          if (!service.supported)
            Text(
              l10n.theBrowserAndMobileAppsDont,
              key: const ValueKey('mcp_platform_unavailable'),
            )
          else ...[
            Text(
              service.running
                  ? l10n.mcpRunningDefaultAccess(
                      mcpAccessModeLabel(l10n, defaultMode),
                    )
                  : l10n.off,
              key: const ValueKey('mcp_status'),
              style: TextStyle(
                color: service.running
                    ? context.palette.lime
                    : context.palette.muted,
              ),
            ),
            if (McpListenerLifecycle.installed case final lifecycle?
                when service.running && identical(service, McpService.instance))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  switch (lifecycle.mode) {
                    McpBackgroundMode.protected => l10n.mcpAndroidProtected,
                    McpBackgroundMode.foregroundOnly =>
                      l10n.mcpAndroidForegroundOnly,
                    _ => l10n.mcpAndroidStarting,
                  },
                  key: const ValueKey('mcp_android_lifecycle_status'),
                  style: TextStyle(color: context.palette.muted),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('mcp_port'),
              controller: _port,
              enabled: !service.running && !service.starting,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: l10n.localListeningPort),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.readOnlyModeCanStillRead,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const ValueKey('mcp_toggle'),
                  onPressed:
                      service.starting ||
                          (!service.running && !service.workspaceReady)
                      ? null
                      : service.running
                      ? () => service.stop()
                      : _start,
                  icon: Icon(
                    service.running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  label: Text(
                    service.starting
                        ? l10n.starting
                        : service.running
                        ? l10n.stopAndRevokeToken
                        : l10n.enableMcp,
                  ),
                ),
                if (service.running)
                  OutlinedButton.icon(
                    key: const ValueKey('mcp_copy_configuration'),
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                    label: Text(
                      _copied
                          ? l10n.copiedIncludesAccessToken
                          : l10n.copyConnectionConfigIncludesToken,
                    ),
                  ),
              ],
            ),
            if (endpoint != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SelectableText(
                  endpoint.toString(),
                  key: const ValueKey('mcp_endpoint'),
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android)
                _AndroidForwardingHint(port: endpoint.port),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.listensOn127001,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android) ...[
              const SizedBox(height: 8),
              Text(
                l10n.mcpAndroidBackgroundHint,
                key: const ValueKey('mcp_android_background_hint'),
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const ValueKey('mcp_error'),
                style: TextStyle(color: context.palette.red),
              ),
            ),
        ],
      ),
    );
  }

  Widget _machineAccessCard(BuildContext context) {
    final l10n = context.l10n;
    final loading = service.permissionsLoading;
    final ready = service.permissionsReady && !loading;
    final defaultMode = service.defaultAccess;
    final hosts = ready ? service.permissionHosts : const <HostRecord>[];
    // Only offered where hostless local console sessions can exist.
    final localDevice = ready && service.localDeviceAccessApplicable;
    final customized =
        (localDevice &&
                service.accessOverrideForHost(mcpLocalDeviceHostId) != null
            ? 1
            : 0) +
        hosts.where((h) => service.accessOverrideForHost(h.id) != null).length;
    final query = _query.text.trim().toLowerCase();
    final matching = query.isEmpty
        ? hosts
        : hosts
              .where(
                (h) =>
                    h.name.toLowerCase().contains(query) ||
                    h.address.toLowerCase().contains(query) ||
                    h.username.toLowerCase().contains(query),
              )
              .toList();
    final shown = matching.take(_visibleMachines).toList();
    final hidden = matching.length - shown.length;
    final muted = TextStyle(
      color: context.palette.muted,
      fontSize: 12,
      height: 1.5,
    );

    return SettingsCard(
      key: const ValueKey('mcp_machine_access'),
      // Holds fields and buttons: keep each control its own a11y node.
      semanticContainer: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.mcpMachineAccessTitle,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.mcpMachineAccessDescription,
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          if (loading)
            Padding(
              key: const ValueKey('mcp_access_loading'),
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.mcpAccessLoading)),
                ],
              ),
            )
          else if (!ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Notice(
                key: const ValueKey('mcp_access_unavailable'),
                icon: Icons.lock_outline,
                color: context.palette.orange,
                text: l10n.mcpAccessUnavailable,
              ),
            ),
          if (_accessError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Notice(
                key: const ValueKey('mcp_access_error'),
                icon: Icons.error_outline,
                color: context.palette.red,
                text: _accessError!,
              ),
            ),
          const SizedBox(height: 16),
          Text(
            l10n.mcpDefaultAccessTitle,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(l10n.mcpDefaultAccessDescription, style: muted),
          const SizedBox(height: 4),
          RadioGroup<McpAccessMode>(
            groupValue: ready ? defaultMode : null,
            onChanged: (mode) {
              if (mode != null && ready && !_defaultPending) _setDefault(mode);
            },
            child: Column(
              children: [
                for (final mode in McpAccessMode.values)
                  RadioListTile<McpAccessMode>(
                    key: ValueKey('mcp_default_access_${mode.name}'),
                    value: mode,
                    enabled: ready && !_defaultPending,
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(mcpAccessModeIcon(mode)),
                    title: Text(mcpAccessModeLabel(l10n, mode)),
                    subtitle: Text(
                      mcpAccessModeDescription(l10n, mode),
                      style: muted,
                    ),
                  ),
              ],
            ),
          ),
          if (ready) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: context.palette.line),
            const SizedBox(height: 16),
            Text(
              l10n.mcpPerMachineTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.mcpCustomizedCount(customized),
              key: const ValueKey('mcp_customized_count'),
              style: muted,
            ),
            const SizedBox(height: 12),
            if (localDevice)
              _machineRow(
                context,
                id: mcpLocalDeviceHostId,
                name: l10n.mcpLocalDeviceName,
                detail: l10n.mcpLocalDeviceDetail,
                icon: Theme.of(context).platform == TargetPlatform.android
                    ? Icons.phone_android_outlined
                    : Icons.computer_outlined,
              ),
            if (hosts.length > 6) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('mcp_machine_search'),
                controller: _query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: l10n.mcpSearchMachines,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (_) => setState(
                  () => _visibleMachines = McpSettingsPanel.machinePageSize,
                ),
              ),
            ],
            if (hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(l10n.mcpNoSavedMachines, style: muted),
              )
            else if (matching.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.mcpNoMachinesMatch(_query.text.trim()),
                  key: const ValueKey('mcp_machine_no_match'),
                  style: muted,
                ),
              ),
            for (final host in shown)
              _machineRow(
                context,
                id: host.id,
                name: host.name.isEmpty ? host.address : host.name,
                detail: _hostDetail(host),
                icon: Icons.dns_outlined,
              ),
            if (hidden > 0)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('mcp_machine_show_more'),
                  onPressed: () => setState(
                    () => _visibleMachines += McpSettingsPanel.machinePageSize,
                  ),
                  icon: const Icon(Icons.expand_more),
                  label: Text(l10n.mcpShowMoreMachines(hidden)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _hostDetail(HostRecord host) {
    final user = host.username.isEmpty ? '' : '${host.username}@';
    return '${host.protocol.name.toUpperCase()} · $user${host.address}:${host.port}';
  }

  Widget _machineRow(
    BuildContext context, {
    required String id,
    required String name,
    required String detail,
    required IconData icon,
  }) {
    final l10n = context.l10n;
    final override = service.accessOverrideForHost(id);
    final effective = service.effectiveAccessForHost(id);
    final pending = _pendingHosts.contains(id);
    final defaultLabel = mcpAccessModeLabel(l10n, service.defaultAccess);
    String choiceLabel(_HostChoice choice) => choice.mode == null
        ? l10n.mcpHostUseDefault(defaultLabel)
        : mcpAccessModeLabel(l10n, choice.mode!);

    final dropdown = Semantics(
      label: l10n.mcpHostAccessFor(name),
      child: DropdownButtonFormField<_HostChoice>(
        key: ValueKey('mcp_host_access_$id'),
        initialValue: _HostChoice.of(override),
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(mcpAccessModeIcon(effective), size: 18),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
        ),
        items: [
          for (final choice in _HostChoice.values)
            DropdownMenuItem(
              value: choice,
              child: Text(
                choiceLabel(choice),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: pending
            ? null
            : (choice) {
                if (choice != null) _setHost(id, choice.mode);
              },
      ),
    );

    return Padding(
      key: ValueKey('mcp_host_row_$id'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ResponsiveControlRow(
        leading: Icon(icon, size: 20, color: context.palette.muted),
        label: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (override != null) ...[
                  const SizedBox(width: 6),
                  _Tag(
                    key: ValueKey('mcp_host_custom_$id'),
                    text: l10n.mcpHostCustom,
                  ),
                ],
              ],
            ),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          ],
        ),
        // Keyed by the stored override (and failed-save epoch) so an
        // external change or a rejected save resets the field to the value
        // actually in effect.
        control: KeyedSubtree(
          key: ValueKey('mcp_host_choice_${id}_${override?.name}_$_resetEpoch'),
          child: dropdown,
        ),
      ),
    );
  }

  Widget _toolsCard(BuildContext context) => SettingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.availableTools,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.sshConsoleSupportReadingTextAnd,
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tool in mcpTools)
              Chip(
                label: Text(
                  tool.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _auditCard(BuildContext context) => SettingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.recentCalls,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.onlyTheLast50ToolNames,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        if (service.audit.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(context.l10n.noCallsYet),
          ),
        for (final entry in service.audit.take(10))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              entry.success ? Icons.check_circle_outline : Icons.error_outline,
              color: entry.success
                  ? context.palette.lime
                  : context.palette.orange,
            ),
            title: Text(entry.tool),
            subtitle: Text(entry.at.toLocal().toString().split('.').first),
            trailing: Text(
              entry.success ? context.l10n.done : context.l10n.failed,
            ),
          ),
      ],
    ),
  );
}

class _AndroidForwardingHint extends StatelessWidget {
  const _AndroidForwardingHint({required this.port});
  final int port;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.mcpAndroidForwardingHint,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: context.palette.codeBackground,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            'adb forward tcp:$port tcp:$port',
            key: const ValueKey('mcp_android_forward_command'),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: context.palette.codeText,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    super.key,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, style: TextStyle(color: color, height: 1.4)),
      ),
    ],
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: context.palette.accentText.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: context.palette.accentText),
    ),
  );
}
