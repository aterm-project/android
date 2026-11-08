import 'app_menu.dart';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'app_motion.dart';
import 'workspace_controls.dart';
import '../l10n/l10n.dart';

/// The same entry point for local and account workspaces.
class NewSessionMenu extends StatelessWidget {
  const NewSessionMenu({
    super.key,
    required this.onHost,
    this.onConsole,
    this.enabled = true,
    this.canCreateHost = true,
  });

  final ValueChanged<HostProtocol> onHost;
  final VoidCallback? onConsole;
  final bool enabled, canCreateHost;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    tooltip: context.l10n.newSession,
    enabled: enabled,
    icon: const Icon(Icons.add),
    shape: workspaceMenuShape,
    clipBehavior: Clip.antiAlias,
    onSelected: (value) {
      if (value == 'console') {
        onConsole?.call();
      } else {
        onHost(HostProtocol.values.byName(value));
      }
    },
    itemBuilder: (_) => [
      for (final item in [
        ('ssh', context.l10n.sshHost, Icons.terminal),
        ('telnet', context.l10n.telnetHost, Icons.settings_ethernet),
        ('rdp', context.l10n.rdpRemoteDesktop, Icons.desktop_windows_outlined),
        ('vnc', context.l10n.vncRemoteDesktop, Icons.desktop_mac_outlined),
      ])
        appMenuItem(
          context,
          value: item.$1,
          enabled: canCreateHost,
          child: AppMenuLabel(item.$3, item.$2),
        ),
      if (onConsole != null) ...[
        const PopupMenuDivider(height: 8),
        appMenuItem(
          context,
          value: 'console',
          child: AppMenuLabel(Icons.code, context.l10n.localConsole),
        ),
      ],
    ],
  );
}
