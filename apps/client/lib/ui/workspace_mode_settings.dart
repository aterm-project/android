import 'dart:async';
import 'package:flutter/material.dart';

import '../storage/workspace_mode.dart';
import '../l10n/l10n.dart';

class WorkspaceModeScope extends InheritedWidget {
  const WorkspaceModeScope({
    required this.mode,
    required this.onSwitch,
    required this.busy,
    required super.child,
    super.key,
  });
  final WorkspaceMode mode;
  final Future<void> Function() onSwitch;
  final bool busy;
  static WorkspaceModeScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceModeScope>();
  @override
  bool updateShouldNotify(WorkspaceModeScope oldWidget) =>
      mode != oldWidget.mode || busy != oldWidget.busy;
}

class ScopedWorkspaceModeSettings extends StatefulWidget {
  const ScopedWorkspaceModeSettings({this.onSwitch, super.key});
  final FutureOr<void> Function()? onSwitch;

  @override
  State<ScopedWorkspaceModeSettings> createState() =>
      _ScopedWorkspaceModeSettingsState();
}

class _ScopedWorkspaceModeSettingsState
    extends State<ScopedWorkspaceModeSettings> {
  bool _switching = false;

  Future<void> _switch(WorkspaceModeScope scope) async {
    if (_switching || scope.busy) return;
    final route = ModalRoute.of(context);
    setState(() => _switching = true);
    try {
      await (widget.onSwitch ?? scope.onSwitch)();
      if (mounted && route is DialogRoute && route.isCurrent) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(context.l10n.couldntSwitchTheWorkspaceModeCheck)));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = WorkspaceModeScope.of(context);
    if (scope == null) return const SizedBox.shrink();
    return WorkspaceModeSettings(
      mode: scope.mode,
      onSwitch: () => _switch(scope),
      busy: scope.busy || _switching,
    );
  }
}

class WorkspaceModeSettings extends StatelessWidget {
  const WorkspaceModeSettings({
    required this.mode,
    required this.onSwitch,
    this.busy = false,
    super.key,
  });

  final WorkspaceMode mode;
  final FutureOr<void> Function() onSwitch;
  final bool busy;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.workspaceMode, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(mode == WorkspaceMode.local ? context.l10n.localMode : context.l10n.cloudSyncMode),
          const SizedBox(height: 4),
          Text(context.l10n.theAppOpensInTheCurrent),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('workspace_mode_switch'),
            onPressed: busy ? null : onSwitch,
            icon: const Icon(Icons.swap_horiz),
            label: Text(mode == WorkspaceMode.local ? context.l10n.switchToCloudMode : context.l10n.switchToLocalMode),
          ),
        ],
      ),
    ),
  );
}
