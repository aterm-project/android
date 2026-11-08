import '../platform/file_window_tracking.dart';
import '../platform/window_geometry.dart';
import '../platform/application_windows.dart';
import '../domain/window_placement.dart';

import 'package:flutter/material.dart';

import '../domain/window_combination.dart';
import 'app_motion.dart';
import 'session_workspace.dart';
import '../l10n/l10n.dart';

WindowCombination captureWindowCombination({
  required String id,
  required String name,
  required List<String> sessionIds,
  required SessionWorkspaceController workspace,
  required CombinationPane? Function(String) describe,
  String? Function(String)? fileOwner,
}) {
  final existingRoot = workspace.root;
  final ids = <String>{
    ...sessionIds,
    ...?existingRoot?.sessionIds,
    for (final group in workspace.retainedGroupSnapshots)
      ...group.root.sessionIds,
  }.toList();
  if (ids.isEmpty) throw StateError(currentL10n.thisWindowHasNoSessionsTo);
  final root = existingRoot ?? SessionWorkspacePane(ids.first);
  final panes = <CombinationPane>[];
  for (final id in ids) {
    final pane = describe(id);
    if (pane == null) {
      throw StateError(currentL10n.thisWindowHasSessionsThatCant);
    }
    if ({'sftp', 'scp'}.contains(pane.kind) && fileOwner != null) {
      final source = fileOwner(id);
      final owner = source == null ? -1 : ids.indexOf(source);
      if (owner < 0)
        throw StateError(currentL10n.fileSessionSshOwnerMissingFromWindowSet);
      panes.add(
        CombinationPane(
          kind: pane.kind,
          hostId: pane.hostId,
          remotePath: pane.remotePath,
          ownerPane: owner,
        ),
      );
    } else {
      panes.add(pane);
    }
  }
  Map<String, Object?> node(SessionWorkspaceNode value) {
    if (value is SessionWorkspacePane)
      return {'pane': ids.indexOf(value.sessionId)};
    final split = value as SessionWorkspaceSplit;
    return {
      'axis': split.axis.name,
      'ratio': split.ratio,
      'first': node(split.first),
      'second': node(split.second),
    };
  }

  return WindowCombination(
    id: id,
    name: name,
    panes: panes,
    tree: node(root),
    activePane: ids.indexOf(workspace.selectedId ?? root.sessionIds.first),
    groups: [
      for (final group in workspace.retainedGroupSnapshots)
        CombinationGroup(
          tree: node(group.root),
          activePane: ids.indexOf(group.selectedId),
        ),
    ],
  );
}

Future<WindowCombination> captureWindowCombinationWithPlacements({
  required String id,
  required String name,
  required List<String> sessionIds,
  required SessionWorkspaceController workspace,
  required CombinationPane? Function(String) describe,
  String? Function(String)? fileOwner,
  required Object owner,
  required bool Function() isCurrent,
  ApplicationWindows? applicationWindows,
  WindowGeometry? geometry,
  TrackedFilesWindows? fileWindows,
}) async {
  final manager = applicationWindows ?? ApplicationWindows.instance;
  final main = await (geometry ?? WindowGeometry.instance).capturePlacement();
  if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
  final detached = await manager.captureWindowPlacements(owner);
  if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
  final independent = await (fileWindows ?? TrackedFilesWindows.instance)
      .capture(owner);
  if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
  if ((fileWindows ?? TrackedFilesWindows.instance).ownedWindowCount(owner) >
      independent.length)
    throw const FileWindowCaptureUnavailable();
  final ids = <String>{
    ...sessionIds,
    ...?workspace.root?.sessionIds,
    for (final group in workspace.retainedGroupSnapshots)
      ...group.root.sessionIds,
  }.toList();
  final base = ids.isEmpty
      ? null
      : captureWindowCombination(
          id: id,
          name: name,
          sessionIds: ids,
          workspace: workspace,
          describe: describe,
          fileOwner: fileOwner,
        );
  final panes = <CombinationPane>[...?base?.panes];
  final windows = <CombinationWindow>[];
  for (final snapshot in detached) {
    final pane = ids.indexWhere(
      (id) => snapshot.windowId == id || snapshot.windowId.startsWith('$id#'),
    );
    if (pane < 0) continue;
    final viewport = snapshot.desktopSpec?.viewport;
    windows.add(
      CombinationWindow(
        pane: pane,
        placement: snapshot.placement,
        viewport: viewport == null
            ? null
            : {
                'x': viewport.left.round(),
                'y': viewport.top.round(),
                'width': viewport.width.round(),
                'height': viewport.height.round(),
              },
      ),
    );
  }
  for (final child in independent) {
    final launch = child.launch;
    windows.add(
      CombinationWindow(
        pane: panes.length,
        placement: child.placement,
        independentFile: true,
      ),
    );
    panes.add(
      CombinationPane(
        kind: launch.protocol.name,
        hostId: launch.hostId,
        remotePath: launch.initialPath,
      ),
    );
  }
  if (panes.isEmpty) throw StateError(currentL10n.thereAreNoReadySessionsTo);

  return WindowCombination(
    id: id,
    name: name,
    panes: panes,
    tree: base?.tree ?? {'pane': 0},
    activePane: base?.activePane ?? 0,
    mainPlacement: main,
    windows: windows,
    groups: base?.groups ?? const [],
  );
}

/// Runs only after an explicit recipe restore. Failed/unsupported placement
/// leaves the already opened session available; stale scope closes new mirrors.
Future<int> restoreWindowCombinationPlacements({
  required WindowCombination recipe,
  required Map<int, String> sessions,
  required bool Function() isCurrent,
  required Future<String?> Function(
    int index,
    CombinationWindow window,
    String sessionId,
  )
  detach,
  required Future<bool> Function(
    String windowId,
    SavedWindowPlacement placement,
  )
  applyDetached,
  required Future<void> Function(String windowId) closeDetached,
  WindowGeometry? geometry,
}) async {
  var failures = 0;
  for (final (index, window) in recipe.windows.indexed) {
    if (window.independentFile) continue;
    if (!isCurrent()) return failures;
    final session = sessions[window.pane];
    if (session == null) {
      failures++;
      continue;
    }
    String? windowId;
    try {
      windowId = await detach(index, window, session);
      if (!isCurrent()) {
        if (windowId != null) await closeDetached(windowId);
        return failures;
      }
      if (windowId == null) {
        failures++;
        continue;
      }
      if (window.placement != null &&
          !await applyDetached(windowId, window.placement!))
        failures++;
      if (!isCurrent()) {
        await closeDetached(windowId);
        return failures;
      }
    } catch (_) {
      if (!isCurrent()) {
        if (windowId != null) await closeDetached(windowId);
        return failures;
      }
      failures++;
    }
  }
  if (isCurrent() && recipe.mainPlacement != null) {
    if (!await (geometry ?? WindowGeometry.instance).restorePlacement(
      recipe.mainPlacement!,
      isCurrent: isCurrent,
    ))
      failures++;
  }
  return failures;
}

void applyWindowCombination(
  WindowCombination recipe,
  SessionWorkspaceController workspace,
  Map<int, String> sessions,
) {
  SessionWorkspaceNode? node(Map<String, Object?> value) {
    if (value.containsKey('pane')) {
      final id = sessions[value['pane']];
      return id == null ? null : SessionWorkspacePane(id);
    }
    final first = node(Map<String, Object?>.from(value['first'] as Map));
    final second = node(Map<String, Object?>.from(value['second'] as Map));
    if (first == null) return second;
    if (second == null) return first;
    return SessionWorkspaceSplit(
      axis: value['axis'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
      ratio: (value['ratio'] as num).toDouble(),
      first: first,
      second: second,
    );
  }

  for (final group in recipe.groups) {
    final groupRoot = node(group.tree);
    if (groupRoot != null)
      workspace.restore(groupRoot, selectedId: sessions[group.activePane]);
  }
  final root =
      node(recipe.tree) ??
      (sessions.isEmpty ? null : SessionWorkspacePane(sessions.values.first));
  if (root != null)
    workspace.restore(root, selectedId: sessions[recipe.activePane]);
}

Future<String?> askWindowCombinationName(BuildContext context) =>
    showAppDialog<String>(
      context: context,
      builder: (_) => const _WindowCombinationNameDialog(),
    );

class _WindowCombinationNameDialog extends StatefulWidget {
  const _WindowCombinationNameDialog();
  @override
  State<_WindowCombinationNameDialog> createState() =>
      _WindowCombinationNameDialogState();
}

class _WindowCombinationNameDialogState
    extends State<_WindowCombinationNameDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.saveWindowSet),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 80,
      decoration: InputDecoration(labelText: context.l10n.setName),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(onPressed: _submit, child: Text(context.l10n.save2)),
    ],
  );
}

class WindowCombinationsStrip extends StatefulWidget {
  const WindowCombinationsStrip({
    super.key,
    required this.load,
    required this.open,
    required this.remove,
    this.busy = false,
    this.canRemove = true,
  });
  final Future<List<WindowCombination>> Function() load;
  final Future<void> Function(WindowCombination) open, remove;
  final bool busy, canRemove;
  @override
  State<WindowCombinationsStrip> createState() =>
      _WindowCombinationsStripState();
}

class _WindowCombinationsStripState extends State<WindowCombinationsStrip> {
  late Future<List<WindowCombination>> _future;
  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  void didUpdateWidget(covariant WindowCombinationsStrip old) {
    super.didUpdateWidget(old);
    _future = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<WindowCombination>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Text(context.l10n.couldntReadWindowSetsUnlockAgain),
        );
      }
      final values = snapshot.data ?? const <WindowCombination>[];
      if (values.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(context.l10n.windowSets),
            ),
            for (final value in values)
              InputChip(
                key: ValueKey('window-combination-${value.id}'),
                avatar: const Icon(Icons.dashboard_outlined, size: 16),
                label: Text('${value.name} · ${value.panes.length}'),
                tooltip: context.l10n.openWindowSet,
                onPressed: widget.busy ? null : () => widget.open(value),
                onDeleted: widget.busy || !widget.canRemove
                    ? null
                    : () async {
                        try {
                          await widget.remove(value);
                          if (mounted) setState(() => _future = widget.load());
                        } catch (_) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  currentL10n.couldntDeleteTheWindowSetUnlock,
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
          ],
        ),
      );
    },
  );
}
