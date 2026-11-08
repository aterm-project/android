import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/mcp_service.dart';
import '../mcp/mcp_tools.dart';
import 'app_theme.dart';
import 'settings_scaffold.dart';
import '../l10n/l10n.dart';

class McpSettingsPanel extends StatefulWidget {
  const McpSettingsPanel({this.service, super.key});
  final McpService? service;
  @override
  State<McpSettingsPanel> createState() => _McpSettingsPanelState();
}

class _McpSettingsPanelState extends State<McpSettingsPanel> {
  final _port = TextEditingController(text: '8765');
  McpService get service => widget.service ?? McpService.instance;
  String? _error;
  bool _copied = false;
  @override
  void dispose() {
    _port.dispose();
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
      if (mounted)
        {
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
      if (mounted) setState(() => _error = context.l10n.couldntCopyTheConfigurationCheckClipboard);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => SettingsCards(
      children: [
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.externalAiAccess,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.letExternalAiUseTheHosts,
                style: const TextStyle(color: AppColors.muted, height: 1.5),
              ),
              const SizedBox(height: 12),
              if (!service.supported)
                Text(
                  context.l10n.theBrowserAndMobileAppsDont,
                  key: const ValueKey('mcp_platform_unavailable'),
                )
              else ...[
                Text(
                  service.running
                      ? context.l10n.runningValuevalue(service.allowOperations ? context.l10n.actionsAllowed : context.l10n.readOnly)
                      : context.l10n.off,
                  key: const ValueKey('mcp_status'),
                  style: TextStyle(
                    color: service.running ? AppColors.lime : AppColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('mcp_port'),
                  controller: _port,
                  enabled: !service.running && !service.starting,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: context.l10n.localListeningPort),
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('mcp_allow_operations'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.allowExternalAiToPerformActions),
                  subtitle: Text(
                    context.l10n.allowsConnectingClosingSessionsTerminalInput,
                  ),
                  value: service.allowOperations,
                  onChanged: service.starting
                      ? null
                      : (value) {
                          service.setAllowOperations(value);
                          setState(() => _copied = false);
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.readOnlyModeCanStillRead,
                  style: const TextStyle(
                    color: AppColors.muted,
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
                      onPressed: service.starting || (!service.running && !service.workspaceReady)
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
                            ? context.l10n.starting
                            : service.running
                            ? context.l10n.stopAndRevokeToken
                            : context.l10n.enableMcp,
                      ),
                    ),
                    if (service.running)
                      OutlinedButton.icon(
                        key: const ValueKey('mcp_copy_configuration'),
                        onPressed: _copy,
                        icon: const Icon(Icons.copy),
                        label: Text(_copied ? context.l10n.copiedIncludesAccessToken : context.l10n.copyConnectionConfigIncludesToken),
                      ),
                  ],
                ),
                if (service.endpoint case final endpoint?)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: SelectableText(endpoint.toString()),
                  ),
                const SizedBox(height: 10),
                Text(
                  context.l10n.listensOn127001,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppColors.red),
                  ),
                ),
            ],
          ),
        ),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.availableTools, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                context.l10n.sshConsoleSupportReadingTextAnd,
                style: const TextStyle(color: AppColors.muted, height: 1.5),
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
        ),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.recentCalls, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                context.l10n.onlyTheLast50ToolNames,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
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
                    entry.success
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: entry.success ? AppColors.lime : AppColors.orange,
                  ),
                  title: Text(entry.tool),
                  subtitle: Text(
                    entry.at.toLocal().toString().split('.').first,
                  ),
                  trailing: Text(entry.success ? context.l10n.done : context.l10n.failed),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
