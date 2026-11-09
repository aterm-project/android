import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/fullscreen.dart';
import 'workspace_controls.dart';

Future<void> toggleAppFullscreen(BuildContext context) async {
  if (!await FullscreenController.instance.toggle() && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.fullscreenUnavailable)),
    );
  }
}

class FullscreenToolsMenu extends StatelessWidget {
  const FullscreenToolsMenu({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = FullscreenController.instance;
    if (!controller.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => WorkspaceOverflowMenu(
        key: const ValueKey('workspace_view_tools_menu'),
        tooltip: context.l10n.tools,
        onOpened: () => unawaited(controller.refresh()),
        actions: [
          WorkspaceAction(
            'workspace_fullscreen',
            controller.enabled
                ? context.l10n.exitFullscreen
                : context.l10n.enterFullscreen,
            controller.enabled ? Icons.fullscreen_exit : Icons.fullscreen,
            () => toggleAppFullscreen(context),
            enabled: !controller.busy,
          ),
        ],
      ),
    );
  }
}
