import 'app_menu.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'app_motion.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

const workspaceMenuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(14)),
);

class WorkspaceAction {
  const WorkspaceAction(
    this.id,
    this.label,
    this.icon,
    this.run, {
    this.enabled = true,
    this.destructive = false,
  });
  final String id;
  final String label;
  final IconData icon;
  final FutureOr<void> Function() run;
  final bool enabled;
  final bool destructive;
}

class WorkspaceOverflowMenu extends StatelessWidget {
  const WorkspaceOverflowMenu({
    required this.actions,
    this.tooltip,
    this.child,
    super.key,
  });
  final List<WorkspaceAction> actions;
  final String? tooltip;
  final Widget? child;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    shape: Theme.of(context).popupMenuTheme.shape ?? workspaceMenuShape,
    clipBehavior: Clip.antiAlias,
    tooltip: tooltip ?? context.l10n.more,
    icon: child == null ? const Icon(Icons.more_horiz) : null,
    child: child,
    onSelected: (id) async {
      final action = actions.where((action) => action.id == id).firstOrNull;
      if (action == null || !action.enabled) return;
      try {
        await action.run();
      } on Object {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(context.l10n.theActionDidntCompleteTryAgain),
            ),
          );
        }
      }
    },
    itemBuilder: (_) => actions
        .map(
          (action) => appMenuItem<String>(
            context,
            key: ValueKey(action.id),
            value: action.id,
            enabled: action.enabled,
            child: AppMenuLabel(
              action.icon,
              action.label,
              color: action.destructive
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        )
        .toList(),
  );
}

Future<void> showWorkspaceContextMenu(
  BuildContext context,
  Offset position,
  List<WorkspaceAction> actions,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final localPosition = overlay.globalToLocal(position);
  final id = await showMenu<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    context: context,
    shape: Theme.of(context).popupMenuTheme.shape ?? workspaceMenuShape,
    clipBehavior: Clip.antiAlias,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(localPosition.dx, localPosition.dy, 1, 1),
      Offset.zero & overlay.size,
    ),
    items: actions
        .map(
          (action) => appMenuItem<String>(
            context,
            value: action.id,
            enabled: action.enabled,
            child: AppMenuLabel(
              action.icon,
              action.label,
              color: action.destructive
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        )
        .toList(),
  );
  if (id == null || !context.mounted) return;
  final action = actions.where((entry) => entry.id == id).firstOrNull;
  if (action != null && action.enabled) {
    try {
      await action.run();
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.theActionDidntCompleteTryAgain)),
        );
      }
    }
  }
}

Future<void> showHostProperties(
  BuildContext context,
  HostRecord host, {
  String? state,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(context.l10n.connectionProperties),
    content: SizedBox(
      width: appDialogWidth(context, 400),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in <String, String>{
              context.l10n.name: host.name,
              context.l10n.address: host.address,
              context.l10n.port2: '${host.port}',
              context.l10n.userName: host.username,
              context.l10n.protocol2: host.protocol == HostProtocol.ssh
                  ? 'SSH / SFTP / SCP'
                  : host.protocol == HostProtocol.telnet
                  ? context.l10n.telnetProtocolUnencrypted
                  : host.protocol.label,
              context.l10n.propertyAuthentication:
                  host.protocol == HostProtocol.telnet
                  ? context.l10n.telnetInteractiveLogin
                  : host.authKind == AuthKind.password
                  ? context.l10n.password2
                  : context.l10n.sshKey,
              context.l10n.propertyStatus: ?state,
              context.l10n.propertyRoute: host.jumpHostId == null
                  ? context.l10n.directConnection2
                  : context.l10n.viaJumpHost,
              if (host.tags.isNotEmpty)
                context.l10n.propertyTags: host.tags.join(', '),
            }.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 112, child: Text(entry.key)),
                    Expanded(child: SelectableText(entry.value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.close2),
      ),
    ],
  ),
);
