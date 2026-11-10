import 'app_menu.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'app_motion.dart';
import 'app_density.dart';
import 'wallpaper.dart';
import '../l10n/l10n.dart';
import '../platform/fullscreen.dart';
import 'fullscreen_menu.dart';
import 'fullscreen_tabs_peek.dart';
import 'window_caption.dart';

@immutable
class WorkspaceTabDragData {
  const WorkspaceTabDragData({required this.tabId, required this.scope});
  final String tabId;
  final String scope;
}

enum SessionSplitEdge { left, right, top, bottom }

sealed class SessionWorkspaceNode {
  const SessionWorkspaceNode();
  Iterable<String> get sessionIds;
}

class SessionWorkspacePane extends SessionWorkspaceNode {
  const SessionWorkspacePane(this.sessionId);
  final String sessionId;
  @override
  Iterable<String> get sessionIds sync* {
    yield sessionId;
  }
}

class SessionWorkspaceSplit extends SessionWorkspaceNode {
  SessionWorkspaceSplit({
    required this.axis,
    required this.first,
    required this.second,
    this.ratio = .5,
  });
  final Axis axis;
  SessionWorkspaceNode first;
  SessionWorkspaceNode second;
  double ratio;
  @override
  Iterable<String> get sessionIds sync* {
    yield* first.sessionIds;
    yield* second.sessionIds;
  }
}

class SessionWorkspaceGroupSnapshot {
  const SessionWorkspaceGroupSnapshot({
    required this.root,
    required this.selectedId,
  });
  final SessionWorkspaceNode root;
  final String selectedId;
}

class _RetainedSessionGroup {
  _RetainedSessionGroup(this.root, this.selectedId);
  SessionWorkspaceNode root;
  String selectedId;
}

SessionWorkspaceNode _copySessionTree(
  SessionWorkspaceNode node, [
  int depth = 0,
]) {
  if (depth > 31) throw FormatException(currentL10n.layoutIsNestedTooDeeply);
  if (node is SessionWorkspacePane) return SessionWorkspacePane(node.sessionId);
  final split = node as SessionWorkspaceSplit;
  return SessionWorkspaceSplit(
    axis: split.axis,
    ratio: split.ratio,
    first: _copySessionTree(split.first, depth + 1),
    second: _copySessionTree(split.second, depth + 1),
  );
}

/// Stores layout IDs only. Connections and key material stay with their owner.
class SessionWorkspaceController extends ChangeNotifier {
  SessionWorkspaceNode? _root;
  final List<_RetainedSessionGroup> _groups = [];
  String? _selectedId;
  SessionWorkspaceNode? get root => _root;
  String? get selectedId => _selectedId;
  List<String> get sessionIds =>
      _root?.sessionIds.toList(growable: false) ?? const [];

  List<List<String>> get groupedSessionIds => List.unmodifiable(
    _groups.map((group) => List<String>.unmodifiable(group.root.sessionIds)),
  );
  List<String>? groupFor(String id) {
    for (final group in _groups) {
      if (group.root.sessionIds.contains(id))
        return List.unmodifiable(group.root.sessionIds);
    }
    return null;
  }

  Map<String, String> get retainedGroupSelections => Map.unmodifiable({
    for (final group in _groups) group.root.sessionIds.first: group.selectedId,
  });
  List<SessionWorkspaceGroupSnapshot> get retainedGroupSnapshots =>
      List.unmodifiable(
        _groups.map(
          (group) => SessionWorkspaceGroupSnapshot(
            root: _copySessionTree(group.root),
            selectedId: group.selectedId,
          ),
        ),
      );

  void _rememberRoot() {
    if (_root is! SessionWorkspaceSplit) return;
    final ids = _root!.sessionIds.toSet();
    final previous = _groups
        .where((group) => group.root.sessionIds.any(ids.contains))
        .firstOrNull;
    final selected = ids.contains(_selectedId)
        ? _selectedId!
        : ids.contains(previous?.selectedId)
        ? previous!.selectedId
        : ids.first;
    _groups.removeWhere((group) => group.root.sessionIds.any(ids.contains));
    _groups.add(_RetainedSessionGroup(_root!, selected));
  }

  void _removeMembership(String id) {
    final next = <_RetainedSessionGroup>[];
    for (final group in _groups) {
      final remaining = _remove(group.root, id);
      if (remaining is SessionWorkspaceSplit) {
        group.root = remaining;
        if (!remaining.sessionIds.contains(group.selectedId))
          group.selectedId = remaining.sessionIds.first;
        next.add(group);
      }
    }
    _groups
      ..clear()
      ..addAll(next);
    _root = _remove(_root, id);
  }

  /// Rebinds a saved layout to live sessions owned by this workspace.
  void restore(SessionWorkspaceNode? root, {String? selectedId}) {
    final seen = <String>{};
    SessionWorkspaceNode copy(SessionWorkspaceNode node, int depth) {
      if (depth > 31) {
        throw FormatException(currentL10n.layoutIsNestedTooDeeply);
      }
      if (node is SessionWorkspacePane) {
        if (node.sessionId.isEmpty ||
            !seen.add(node.sessionId) ||
            seen.length > 32) {
          throw FormatException(currentL10n.invalidLayoutSession);
        }
        return SessionWorkspacePane(node.sessionId);
      }
      final split = node as SessionWorkspaceSplit;
      if (!split.ratio.isFinite || split.ratio < .15 || split.ratio > .85) {
        throw FormatException(currentL10n.invalidLayoutRatio);
      }
      return SessionWorkspaceSplit(
        axis: split.axis,
        ratio: split.ratio,
        first: copy(split.first, depth + 1),
        second: copy(split.second, depth + 1),
      );
    }

    final next = root == null ? null : copy(root, 0);
    if (next == null) _groups.clear();
    if (next != null) {
      for (final id in next.sessionIds.toList()) {
        _removeMembership(id);
      }
    }
    _root = next;
    _selectedId = seen.contains(selectedId)
        ? selectedId
        : next?.sessionIds.firstOrNull;
    _rememberRoot();
    notifyListeners();
  }

  void activate(String id) {
    if (!sessionIds.contains(id)) {
      _rememberRoot();
      _root =
          _groups
              .where((group) => group.root.sessionIds.contains(id))
              .firstOrNull
              ?.root ??
          SessionWorkspacePane(id);
    }
    _selectedId = id;
    _rememberRoot();
    notifyListeners();
  }

  void split(String sourceId, String targetId, SessionSplitEdge edge) {
    if (sourceId == targetId || !sessionIds.contains(targetId)) return;
    _removeMembership(sourceId);
    final horizontal =
        edge == SessionSplitEdge.left || edge == SessionSplitEdge.right;
    final sourceFirst =
        edge == SessionSplitEdge.left || edge == SessionSplitEdge.top;
    _root = _replace(
      _root!,
      targetId,
      (target) => SessionWorkspaceSplit(
        axis: horizontal ? Axis.horizontal : Axis.vertical,
        first: sourceFirst ? SessionWorkspacePane(sourceId) : target,
        second: sourceFirst ? target : SessionWorkspacePane(sourceId),
      ),
    );
    _selectedId = sourceId;
    _rememberRoot();
    notifyListeners();
  }

  void remove(String id) {
    _removeMembership(id);
    _rememberRoot();
    if (_selectedId == id) _selectedId = sessionIds.firstOrNull;
    notifyListeners();
  }

  /// Removes layout membership only; the owner keeps the session as a tab.
  /// The surviving group remains selected instead of activating the removed tab.
  bool unsplit(String id) {
    if (groupFor(id) == null) return false;
    remove(id);
    return true;
  }

  void resize(SessionWorkspaceSplit node, double ratio) {
    node.ratio = ratio.clamp(.15, .85);
    notifyListeners();
  }

  SessionWorkspaceNode? _remove(SessionWorkspaceNode? node, String id) {
    if (node == null) return null;
    if (node is SessionWorkspacePane) return node.sessionId == id ? null : node;
    final split = node as SessionWorkspaceSplit;
    final first = _remove(split.first, id), second = _remove(split.second, id);
    if (first == null) return second;
    if (second == null) return first;
    split.first = first;
    split.second = second;
    return split;
  }

  SessionWorkspaceNode _replace(
    SessionWorkspaceNode node,
    String targetId,
    SessionWorkspaceNode Function(SessionWorkspaceNode) replacement,
  ) {
    if (node is SessionWorkspacePane) {
      return node.sessionId == targetId ? replacement(node) : node;
    }
    final split = node as SessionWorkspaceSplit;
    split.first = _replace(split.first, targetId, replacement);
    split.second = _replace(split.second, targetId, replacement);
    return split;
  }
}

/// Actual drop targets and resizable terminal panes, sharing existing sessions.
class SessionWorkspaceView extends StatefulWidget {
  const SessionWorkspaceView({
    super.key,
    required this.controller,
    required this.terminalBuilder,
    this.onSelect,
    this.onUnsplit,
    this.onClose,
    this.onDuplicate,
    this.onSplit,
    this.splitTargets,
    this.paneLabel,
    this.paneStatus,
    this.dragScope = 'workspace',
    this.acceptsSession,
  });
  final SessionWorkspaceController controller;
  final Widget Function(BuildContext, String) terminalBuilder;
  final ValueChanged<String>? onSelect, onUnsplit, onClose, onDuplicate;

  /// Splits the pane with a fresh connection/Console copy of its session
  /// (left/right or top/bottom), via the owner's existing split flow. Offered
  /// from the Android pane handle, including in fullscreen.
  final void Function(String id, Axis axis)? onSplit;

  /// Every open session/file tab; those outside the pane's current layout
  /// are offered as explicit split partners on the Android pane handle.
  final Iterable<String> Function()? splitTargets;
  final String Function(String)? paneLabel, paneStatus;
  final String dragScope;
  final bool Function(String)? acceptsSession;
  @override
  State<SessionWorkspaceView> createState() => _SessionWorkspaceViewState();
}

class _SessionWorkspaceViewState extends State<SessionWorkspaceView> {
  final _paneKeys = <String, GlobalKey>{};
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      FullscreenController.instance,
      FullscreenTabsPeek.instance,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final root = widget.controller.root;
        if (root == null) return const SizedBox.shrink();
        final android = Theme.of(context).platform == TargetPlatform.android;
        final immersive = android && FullscreenController.instance.enabled;
        final peek = FullscreenTabsPeek.instance;
        final peekVisible = immersive && peek.visible;
        // The dropped-down strip covers the top of the selected pane; its
        // handle and actions move just below it.
        final peekInset = WindowBarMetrics.of(
          context,
          WindowChromeScope.of(context),
        ).height;
        final panes = <({String id, Rect bounds})>[];
        final dividers =
            <({SessionWorkspaceSplit split, Rect bounds, double usable})>[];
        void layout(SessionWorkspaceNode node, Rect bounds) {
          if (node is SessionWorkspacePane) {
            panes.add((id: node.sessionId, bounds: bounds));
            return;
          }
          final split = node as SessionWorkspaceSplit;
          final horizontal = split.axis == Axis.horizontal;
          final extent = horizontal ? bounds.width : bounds.height;
          final dividerExtent = extent.clamp(0.0, 6.0);
          final usable = (extent - dividerExtent).clamp(0.0, double.infinity);
          final firstExtent = usable * split.ratio;
          final first = Rect.fromLTWH(
            bounds.left,
            bounds.top,
            horizontal ? firstExtent : bounds.width,
            horizontal ? bounds.height : firstExtent,
          );
          final divider = Rect.fromLTWH(
            horizontal ? bounds.left + firstExtent : bounds.left,
            horizontal ? bounds.top : bounds.top + firstExtent,
            horizontal ? dividerExtent : bounds.width,
            horizontal ? bounds.height : dividerExtent,
          );
          final second = Rect.fromLTWH(
            horizontal ? divider.right : bounds.left,
            horizontal ? bounds.top : divider.bottom,
            horizontal ? usable - firstExtent : bounds.width,
            horizontal ? bounds.height : usable - firstExtent,
          );
          layout(split.first, first);
          layout(split.second, second);
          dividers.add((split: split, bounds: divider, usable: usable));
        }

        layout(root, Offset.zero & constraints.biggest);
        final grouped = panes.length > 1;
        // Android handle: Close also covers a lone pane (closing its tab) and
        // Split reuses the tab menu's flow, so fullscreen keeps both.
        final handleClose = grouped || android;
        final handleSplit = android && widget.onSplit != null;
        Rect paneRect(({String id, Rect bounds}) pane) =>
            immersive && widget.controller.selectedId == pane.id
            ? Offset.zero & constraints.biggest
            : pane.bounds;
        return PopScope(
          canPop: !immersive,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !immersive) return;
            // Back first retracts a dropped-down strip, then leaves fullscreen.
            peek.visible ? peek.hide() : toggleAppFullscreen(context);
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final pane in panes)
                Positioned.fromRect(
                  key: ValueKey('position-${pane.id}'),
                  rect: paneRect(pane),
                  child: Offstage(
                    offstage:
                        immersive && widget.controller.selectedId != pane.id,
                    child: _SessionPaneDropTarget(
                      key: _paneKeys.putIfAbsent(pane.id, () => GlobalKey()),
                      sessionId: pane.id,
                      scope: widget.dragScope,
                      acceptsSession: widget.acceptsSession,
                      selected: widget.controller.selectedId == pane.id,
                      // Split does not count here: on a narrow pane the action
                      // row wraps instead of hiding Close behind a menu.
                      compactActions:
                          paneRect(pane).width <
                          ((FullscreenController.instance.supported ? 1 : 0) +
                                      (grouped && widget.onUnsplit != null
                                          ? 1
                                          : 0) +
                                      (handleClose && widget.onClose != null
                                          ? 1
                                          : 0) +
                                      (widget.onDuplicate != null ? 1 : 0)) *
                                  (AppDensity.of(context).isCompact ? 36 : 48) +
                              16,
                      label: widget.paneLabel?.call(pane.id) ?? pane.id,
                      status: widget.paneStatus?.call(pane.id),
                      fullscreen: FullscreenController.instance.enabled,
                      immersive:
                          immersive && widget.controller.selectedId == pane.id,
                      peekVisible:
                          peekVisible &&
                          widget.controller.selectedId == pane.id,
                      peekInset: peekInset,
                      onFullscreen: FullscreenController.instance.supported
                          ? () {
                              widget.controller.activate(pane.id);
                              widget.onSelect?.call(pane.id);
                              toggleAppFullscreen(context);
                            }
                          : null,
                      onUnsplit: grouped && widget.onUnsplit != null
                          ? () => widget.onUnsplit!(pane.id)
                          : null,
                      onClose: handleClose && widget.onClose != null
                          ? () => widget.onClose!(pane.id)
                          : null,
                      closeLabel: grouped
                          ? context.l10n.closePane
                          : context.l10n.closeTab,
                      onSplit: handleSplit
                          ? (axis) => widget.onSplit!(pane.id, axis)
                          : null,
                      splitTargets: !handleSplit || widget.splitTargets == null
                          ? null
                          : () => [
                              for (final id in {...widget.splitTargets!()})
                                if (id != pane.id &&
                                    (widget.acceptsSession?.call(pane.id) ??
                                        true) &&
                                    !widget.controller.sessionIds.contains(
                                      id,
                                    ) &&
                                    (widget.acceptsSession?.call(id) ?? true))
                                  (
                                    id: id,
                                    label: widget.paneLabel?.call(id) ?? id,
                                    status: widget.paneStatus?.call(id),
                                  ),
                            ],
                      onSplitWith: (source, edge) {
                        // Same as dropping [source] on this pane's edge.
                        widget.controller.split(source, pane.id, edge);
                        widget.onSelect?.call(source);
                      },
                      onDuplicate: widget.onDuplicate == null
                          ? null
                          : () => widget.onDuplicate!(pane.id),
                      onSelect: () {
                        widget.controller.activate(pane.id);
                        widget.onSelect?.call(pane.id);
                      },
                      onDrop: (source, edge) {
                        widget.controller.split(source, pane.id, edge);
                        widget.onSelect?.call(source);
                      },
                      child: widget.terminalBuilder(context, pane.id),
                    ),
                  ),
                ),
              if (!immersive)
                for (final divider in dividers)
                  Positioned.fromRect(
                    key: ObjectKey(divider.split),
                    rect: divider.bounds,
                    child: _SessionDivider(
                      axis: divider.split.axis,
                      onDrag: (delta) {
                        if (divider.usable > 0)
                          widget.controller.resize(
                            divider.split,
                            divider.split.ratio +
                                (divider.split.axis == Axis.horizontal
                                        ? delta.dx
                                        : delta.dy) /
                                    divider.usable,
                          );
                      },
                    ),
                  ),
            ],
          ),
        );
      },
    ),
  );
}

/// A restrained dark separator; the full six-pixel lane still accepts drags.
class _SessionDivider extends StatefulWidget {
  const _SessionDivider({required this.axis, required this.onDrag});
  final Axis axis;
  final ValueChanged<Offset> onDrag;
  @override
  State<_SessionDivider> createState() => _SessionDividerState();
}

class _SessionDividerState extends State<_SessionDivider> {
  bool _hovered = false, _dragging = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _hovered || _dragging;
    final darkSurface = colors.brightness == Brightness.dark
        ? colors.surfaceContainerLowest
        : colors.inverseSurface;
    final track = Color.alphaBlend(
      colors.primary.withValues(alpha: active ? .12 : .025),
      darkSurface,
    );
    final horizontal = widget.axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: const ValueKey('session-divider'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _dragging = true),
        onPanEnd: (_) => setState(() => _dragging = false),
        onPanCancel: () => setState(() => _dragging = false),
        onPanUpdate: (event) => widget.onDrag(event.delta),
        child: AnimatedContainer(
          duration: AppMotion.duration(context, MotionDurations.quick),
          color: track,
          child: Center(
            child: AnimatedContainer(
              key: const ValueKey('session-divider-grip'),
              duration: AppMotion.duration(context, MotionDurations.quick),
              width: horizontal ? 2 : 28,
              height: horizontal ? 28 : 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: colors.primary.withValues(alpha: active ? .8 : .3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionPaneDropTarget extends StatefulWidget {
  const _SessionPaneDropTarget({
    super.key,
    required this.sessionId,
    required this.scope,
    required this.selected,
    required this.onSelect,
    required this.onDrop,
    required this.child,
    this.acceptsSession,
    required this.label,
    this.compactActions = false,
    this.status,
    this.onUnsplit,
    this.onClose,
    this.onDuplicate,
    this.onFullscreen,
    this.fullscreen = false,
    this.immersive = false,
    this.peekVisible = false,
    this.peekInset = 0,
    this.closeLabel,
    this.onSplit,
    this.splitTargets,
    this.onSplitWith,
  });
  final String label;
  final bool compactActions;
  final String? status;
  final VoidCallback? onUnsplit, onClose, onDuplicate;
  final VoidCallback? onFullscreen;
  final bool fullscreen;

  /// This pane alone fills the Android fullscreen view.
  final bool immersive;

  /// The workspace tab strip is dropped down over this pane.
  final bool peekVisible;
  final double peekInset;
  final String? closeLabel;
  final ValueChanged<Axis>? onSplit;
  final List<({String id, String label, String? status})> Function()?
  splitTargets;
  final void Function(String source, SessionSplitEdge edge)? onSplitWith;
  final String sessionId, scope;
  final bool Function(String)? acceptsSession;
  final bool selected;
  final VoidCallback onSelect;
  final void Function(String source, SessionSplitEdge edge) onDrop;
  final Widget child;
  @override
  State<_SessionPaneDropTarget> createState() => _SessionPaneDropTargetState();
}

class _SessionPaneDropTargetState extends State<_SessionPaneDropTarget> {
  SessionSplitEdge? _edge;
  bool _controlsVisible = false;
  bool _controlsPinned = false;
  final _controlsFocus = FocusNode(debugLabel: 'Split pane actions');
  int get _actionCount =>
      (widget.onFullscreen != null ? 1 : 0) +
      (widget.onUnsplit != null ? 1 : 0) +
      (widget.onClose != null ? 1 : 0) +
      (widget.onSplit != null ? 1 : 0) +
      (widget.onDuplicate != null ? 1 : 0);
  bool get _hasActions => _actionCount > 0;
  double get _actionExtent => AppDensity.of(context).isCompact ? 36 : 48;

  /// Handle offset below a dropped-down tab strip.
  double get _inset => widget.peekVisible ? widget.peekInset : 0;

  @override
  void initState() {
    super.initState();
    if (widget.peekVisible) _controlsVisible = _controlsPinned = true;
  }

  @override
  void didUpdateWidget(_SessionPaneDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fullscreen && !oldWidget.fullscreen && widget.selected) {
      _controlsVisible = _controlsPinned = true;
    }
    // In fullscreen the handle's actions drop down and retract together with
    // the tab strip (tap, outside tap, Back or the auto-hide timeout).
    if (widget.peekVisible && !oldWidget.peekVisible) {
      _controlsVisible = _controlsPinned = true;
    } else if (!widget.peekVisible && oldWidget.peekVisible) {
      _controlsVisible = _controlsPinned = false;
    }
  }

  @override
  void dispose() {
    _controlsFocus.dispose();
    super.dispose();
  }

  void _showControls(bool value) {
    if (value != _controlsVisible && mounted)
      setState(() => _controlsVisible = value);
  }

  bool _nearHandle(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (local.dx - box.size.width / 2).abs() <= 26 &&
        local.dy >= _inset &&
        local.dy <= _inset + 24;
  }

  bool _nearActions(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    final count = widget.compactActions
        ? (widget.onFullscreen != null ? 1 : 0) +
              (_actionCount > (widget.onFullscreen != null ? 1 : 0) ? 1 : 0)
        : _actionCount;
    final top = _inset + 24;
    final rows = box != null && box.hasSize
        ? (count * _actionExtent / math.max(_actionExtent, box.size.width))
              .ceil()
        : 1;
    return box != null &&
        box.hasSize &&
        _controlsVisible &&
        (local.dx - box.size.width / 2).abs() <=
            count * _actionExtent / 2 + 8 &&
        local.dy >= top &&
        local.dy <= top + rows * _actionExtent + 8;
  }

  void _hoverControls(PointerEvent event) {
    if (!_hasActions || _controlsFocus.hasPrimaryFocus || widget.peekVisible) {
      return;
    }
    _controlsPinned = false;
    _showControls(
      _nearHandle(event.localPosition) || _nearActions(event.localPosition),
    );
  }

  void _toggleControls() {
    if (widget.immersive) {
      // Fullscreen: the handle drops the workspace tabs down as an overlay
      // (and retracts them); the pane's actions follow the strip.
      final peek = FullscreenTabsPeek.instance;
      if (widget.peekVisible) {
        peek.hide();
      } else {
        _controlsPinned = true;
        _showControls(true);
        peek.show();
      }
      return;
    }
    _controlsPinned = !_controlsVisible;
    _showControls(!_controlsVisible);
  }

  void _afterAction() {
    if (widget.peekVisible) {
      FullscreenTabsPeek.instance.keepAlive();
      return;
    }
    _controlsPinned = false;
    _showControls(false);
  }

  SessionSplitEdge get _partnerEdge {
    final box = context.findRenderObject() as RenderBox?;
    final portrait =
        box != null && box.hasSize && box.size.height > box.size.width;
    return portrait ? SessionSplitEdge.bottom : SessionSplitEdge.right;
  }

  /// Direction choices use the tab menu's split flow; each listed session is
  /// an explicit partner placed beside (landscape) or below (portrait).
  List<PopupMenuEntry<String>> _splitItems(BuildContext context) {
    final targets = widget.splitTargets?.call() ?? const [];
    final portrait = _partnerEdge == SessionSplitEdge.bottom;
    return [
      appMenuItem(
        context,
        key: ValueKey('pane-split-horizontal-${widget.sessionId}'),
        value: 'split:horizontal',
        child: AppMenuLabel(
          Icons.view_week_outlined,
          context.l10n.splitLeftRight,
        ),
      ),
      appMenuItem(
        context,
        key: ValueKey('pane-split-vertical-${widget.sessionId}'),
        value: 'split:vertical',
        child: AppMenuLabel(
          Icons.splitscreen_outlined,
          context.l10n.splitTopBottom,
        ),
      ),
      if (targets.isNotEmpty) const PopupMenuDivider(height: 8),
      for (final target in targets)
        appMenuItem(
          context,
          key: ValueKey('pane-split-with-${target.id}'),
          value: 'with:${target.id}',
          child: AppMenuLabel(
            portrait ? Icons.splitscreen_outlined : Icons.view_week_outlined,
            target.label,
            subtitle: target.status,
          ),
        ),
    ];
  }

  /// Returns false when [action] is not a split command.
  bool _runSplit(String action) {
    if (action == 'split:horizontal') {
      widget.onSplit?.call(Axis.horizontal);
    } else if (action == 'split:vertical') {
      widget.onSplit?.call(Axis.vertical);
    } else if (action.startsWith('with:')) {
      widget.onSplitWith?.call(action.substring(5), _partnerEdge);
    } else {
      return false;
    }
    return true;
  }

  Widget _handle() => Tooltip(
    message: context.l10n.paneActionsLabel(widget.label),
    child: Semantics(
      button: true,
      toggled: _controlsVisible,
      label: context.l10n.paneActionsLabel(widget.label),
      onTap: _toggleControls,
      child: GestureDetector(
        key: ValueKey('pane-handle-${widget.sessionId}'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _toggleControls,
        child: SizedBox(
          width: 44,
          height: 24,
          child: Center(
            child: Container(
              width: 24,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: const Color(0x33000000), width: .5),
                boxShadow: const [
                  BoxShadow(color: Color(0x55000000), blurRadius: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  SessionSplitEdge? _edgeAt(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(global);
    final x = local.dx / box.size.width, y = local.dy / box.size.height;
    final distances = <SessionSplitEdge, double>{
      SessionSplitEdge.left: x,
      SessionSplitEdge.right: 1 - x,
      SessionSplitEdge.top: y,
      SessionSplitEdge.bottom: 1 - y,
    };
    final nearest = distances.entries.reduce(
      (a, b) => a.value < b.value ? a : b,
    );
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    if (mobile) {
      // The centre is a safe no-split region. Keep an already highlighted
      // edge near a corner to prevent left/top flicker from finger jitter.
      if (nearest.value > .30) return null;
      if (_edge != null &&
          distances[_edge]! <= .30 &&
          distances[_edge]! - nearest.value < .08)
        return _edge;
    }
    return nearest.key;
  }

  @override
  Widget build(BuildContext context) => DragTarget<WorkspaceTabDragData>(
    onWillAcceptWithDetails: (details) {
      final accepts =
          details.data.scope == widget.scope &&
          details.data.tabId != widget.sessionId &&
          (widget.acceptsSession?.call(details.data.tabId) ?? true) &&
          (widget.acceptsSession?.call(widget.sessionId) ?? true);
      _edge = accepts ? _edgeAt(details.offset) : null;
      return accepts;
    },
    onMove: (details) => setState(() => _edge = _edgeAt(details.offset)),
    onLeave: (_) => setState(() => _edge = null),
    onAcceptWithDetails: (details) {
      if (details.data.scope != widget.scope ||
          details.data.tabId == widget.sessionId ||
          widget.acceptsSession?.call(details.data.tabId) == false ||
          widget.acceptsSession?.call(widget.sessionId) == false) {
        setState(() => _edge = null);
        return;
      }
      final edge = _edgeAt(details.offset);
      setState(() => _edge = null);
      if (edge != null) widget.onDrop(details.data.tabId, edge);
    },
    builder: (context, candidates, _) => Focus(
      focusNode: _controlsFocus,
      skipTraversal: !_hasActions,
      onFocusChange: (focused) {
        if (_controlsFocus.hasPrimaryFocus) _showControls(focused);
      },
      onKeyEvent: (node, event) {
        if (_hasActions &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyP &&
            HardwareKeyboard.instance.isAltPressed &&
            HardwareKeyboard.instance.isShiftPressed) {
          _controlsPinned = false;
          _showControls(!_controlsVisible);
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _controlsVisible) {
          _controlsPinned = false;
          _showControls(false);
          if (widget.peekVisible) FullscreenTabsPeek.instance.hide();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        key: ValueKey('session-pane-${widget.sessionId}'),
        label: widget.label,
        hint: _hasActions ? context.l10n.paneActionsTapTheWhiteHandle : null,
        child: MouseRegion(
          onEnter: _hoverControls,
          onHover: _hoverControls,
          onExit: (_) {
            if (!_controlsFocus.hasPrimaryFocus && !_controlsPinned)
              _showControls(false);
          },
          child: Listener(
            onPointerDown: (event) {
              widget.onSelect();
              if (event.kind == PointerDeviceKind.touch &&
                  !_nearHandle(event.localPosition) &&
                  !_nearActions(event.localPosition)) {
                _controlsPinned = false;
                _showControls(false);
              }
            },
            // Paint-only: the pane border colour eases between panes; the
            // live child is never faded, moved or re-keyed.
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(
                end: widget.selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
              ),
              duration: AppMotion.duration(context, MotionDurations.quick),
              curve: MotionCurves.move,
              builder: (context, color, child) => DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: color ?? Colors.transparent),
                ),
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Stable slot: per-pane wallpaper (follow-splits mode).
                  WallpaperPaneBackdrop(
                    key: const ValueKey('pane-content'),
                    child: widget.child,
                  ),
                  // While the tab strip is dropped down, a tap on the pane
                  // only retracts it: nothing reaches the terminal/desktop.
                  if (widget.peekVisible)
                    Positioned.fill(
                      key: const ValueKey('fullscreen-tabs-barrier'),
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) =>
                            FullscreenTabsPeek.instance.hide(),
                      ),
                    ),
                  if (_hasActions)
                    Positioned(
                      key: const ValueKey('pane-handle-slot'),
                      top: _inset,
                      left: 0,
                      right: 0,
                      child: _handleGroup(
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _handle(),
                            // Fades in when revealed (hit-testable at once);
                            // hides instantly so no ghost keeps focus or taps.
                            if (_controlsVisible)
                              MotionEntrance(
                                trigger: null,
                                animateOnFirstBuild: true,
                                duration: MotionDurations.quick,
                                offset: const Offset(0, -4),
                                child: _actions(context),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (candidates.isNotEmpty && _edge != null)
                    IgnorePointer(
                      key: const ValueKey('pane-split-preview'),
                      child: _SplitPreview(edge: _edge!),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// Fullscreen: the handle and its actions belong to the dropped-down tab
  /// strip's tap group, and touching them keeps the strip on screen.
  Widget _handleGroup(Widget child) {
    if (!widget.immersive) return child;
    final peek = FullscreenTabsPeek.instance;
    return TapRegion(
      groupId: FullscreenTabsPeek.tapGroup,
      child: Listener(
        onPointerDown: (event) => peek.pointerDown(event.pointer),
        onPointerUp: (event) => peek.pointerUp(event.pointer),
        onPointerCancel: (event) => peek.pointerUp(event.pointer),
        child: child,
      ),
    );
  }

  Widget _actions(BuildContext context) => Material(
    elevation: 3,
    borderRadius: BorderRadius.circular(7),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Wrap(
      alignment: WrapAlignment.center,
      children: [
        if (widget.onFullscreen != null)
          IconButton(
            key: widget.fullscreen && widget.selected
                ? const ValueKey('workspace_exit_fullscreen')
                : ValueKey('pane-fullscreen-${widget.sessionId}'),
            tooltip: widget.fullscreen
                ? context.l10n.exitFullscreen
                : context.l10n.enterFullscreen,
            constraints: BoxConstraints.tightFor(
              width: _actionExtent,
              height: _actionExtent,
            ),
            padding: EdgeInsets.zero,
            icon: Icon(
              widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              size: appMenuIconSize(context),
            ),
            onPressed: widget.onFullscreen,
          ),
        if (!widget.compactActions) ...[
          if (widget.onDuplicate != null)
            IconButton(
              key: ValueKey('pane-duplicate-${widget.sessionId}'),
              constraints: BoxConstraints.tightFor(
                width: _actionExtent,
                height: _actionExtent,
              ),
              padding: EdgeInsets.zero,
              tooltip: context.l10n.duplicateTab,
              icon: Icon(Icons.content_copy, size: appMenuIconSize(context)),
              onPressed: widget.onDuplicate,
            ),
          if (widget.onSplit != null)
            SizedBox(
              width: _actionExtent,
              height: _actionExtent,
              child: PopupMenuButton<String>(
                key: ValueKey('pane-split-${widget.sessionId}'),
                popUpAnimationStyle: AppMotion.menuStyle(context),
                tooltip: context.l10n.splitSelectedPane,
                icon: Icon(
                  Icons.vertical_split_outlined,
                  size: appMenuIconSize(context),
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 180),
                onSelected: (action) {
                  _runSplit(action);
                  _afterAction();
                },
                itemBuilder: _splitItems,
              ),
            ),
          if (widget.onUnsplit != null)
            IconButton(
              key: ValueKey('pane-unsplit-${widget.sessionId}'),
              constraints: BoxConstraints.tightFor(
                width: _actionExtent,
                height: _actionExtent,
              ),
              padding: EdgeInsets.zero,
              tooltip: context.l10n.unsplit,
              icon: Icon(Icons.call_split, size: appMenuIconSize(context)),
              onPressed: widget.onUnsplit,
            ),
          if (widget.onClose != null)
            IconButton(
              key: ValueKey('pane-close-${widget.sessionId}'),
              constraints: BoxConstraints.tightFor(
                width: _actionExtent,
                height: _actionExtent,
              ),
              padding: EdgeInsets.zero,
              tooltip: widget.closeLabel ?? context.l10n.closePane,
              icon: Icon(Icons.close, size: appMenuIconSize(context)),
              onPressed: widget.onClose,
            ),
        ] else if (_actionCount > (widget.onFullscreen != null ? 1 : 0))
          SizedBox(
            width: _actionExtent,
            height: _actionExtent,
            child: PopupMenuButton<String>(
              key: ValueKey('pane-actions-${widget.sessionId}'),
              popUpAnimationStyle: AppMotion.menuStyle(context),
              tooltip: context.l10n.paneActionsLabel(widget.label),
              icon: Icon(Icons.more_horiz, size: appMenuIconSize(context)),
              constraints: const BoxConstraints(minWidth: 160),
              padding: EdgeInsets.zero,
              onSelected: (action) {
                _afterAction();
                if (_runSplit(action)) return;
                if (action == 'duplicate')
                  widget.onDuplicate?.call();
                else if (action == 'unsplit')
                  widget.onUnsplit?.call();
                else if (action == 'close')
                  widget.onClose?.call();
              },
              itemBuilder: (_) => [
                if (widget.status != null)
                  appMenuItem<String>(
                    context,
                    enabled: false,
                    child: Text(
                      widget.status!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (widget.onDuplicate != null)
                  appMenuItem(
                    context,
                    value: 'duplicate',
                    child: AppMenuLabel(
                      Icons.content_copy,
                      context.l10n.duplicateTab,
                    ),
                  ),
                if (widget.onSplit != null) ..._splitItems(context),
                if (widget.onUnsplit != null)
                  appMenuItem(
                    context,
                    value: 'unsplit',
                    child: AppMenuLabel(Icons.call_split, context.l10n.unsplit),
                  ),
                if (widget.onClose != null)
                  appMenuItem(
                    context,
                    value: 'close',
                    child: AppMenuLabel(
                      Icons.close,
                      widget.closeLabel ?? context.l10n.closePane,
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Drop-to-split preview: fades in, then glides between edges as the pointer
/// moves. The caller wraps it in `IgnorePointer`, so it never takes the drop
/// or pointer events away from the pane underneath.
class _SplitPreview extends StatelessWidget {
  const _SplitPreview({required this.edge});
  final SessionSplitEdge edge;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.levelOf(context) == MotionLevel.full
        ? MotionDurations.quick
        : Duration.zero;
    final sideEdge =
        edge == SessionSplitEdge.left || edge == SessionSplitEdge.right;
    return MotionEntrance(
      trigger: null,
      animateOnFirstBuild: true,
      duration: MotionDurations.quick,
      offset: Offset.zero,
      child: AnimatedAlign(
        duration: duration,
        curve: MotionCurves.move,
        alignment: switch (edge) {
          SessionSplitEdge.left => Alignment.centerLeft,
          SessionSplitEdge.right => Alignment.centerRight,
          SessionSplitEdge.top => Alignment.topCenter,
          SessionSplitEdge.bottom => Alignment.bottomCenter,
        },
        child: AnimatedFractionallySizedBox(
          duration: duration,
          curve: MotionCurves.move,
          widthFactor: sideEdge ? .5 : 1,
          heightFactor: sideEdge ? 1 : .5,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .22),
            child: Center(child: Text(context.l10n.dropToSplit)),
          ),
        ),
      ),
    );
  }
}
