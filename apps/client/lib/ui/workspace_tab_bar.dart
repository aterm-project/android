import 'app_menu.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'session_workspace.dart';
import 'window_caption.dart';
import 'workspace_controls.dart';
import '../l10n/l10n.dart';

@immutable
class WorkspaceTab {
  const WorkspaceTab({
    required this.id,
    required this.title,
    this.isHome = false,
    this.isConnected = false,
    this.status,
    this.isFile = false,
    this.canDetach = true,
    this.canOpenFiles = true,
    this.icon,
    this.members = const [],
  });
  final String id, title;
  final bool isHome, isConnected;
  final String? status;
  final bool isFile, canDetach, canOpenFiles;
  final IconData? icon;
  final List<WorkspaceTab> members;
}

enum _TabCommand {
  close,
  closeOthers,
  duplicate,
  splitHorizontal,
  splitVertical,
  detach,
  properties,
  sftp,
  scp,
  scpUpload,
  scpDownload,
}

class WorkspaceTabBar extends StatelessWidget {
  const WorkspaceTabBar({
    super.key,
    required this.tabs,
    required this.selectedId,
    required this.onSelect,
    required this.onClose,
    this.onNewWindow,
    this.supportsNewWindow = false,
    this.onReorder,
    this.onSplit,
    this.onDetach,
    this.onProperties,
    this.onCloseOthers,
    this.onDuplicate,
    this.dragScope = 'workspace',
    this.leading,
    this.actions = const [],
    this.homeMenuActions = const [],
    this.onSearch,
    this.onToggleTools,
    this.onSftp,
    this.onScp,
    this.onScpUpload,
    this.onScpDownload,
    this.groups = const [],
    this.groupSelections = const {},
    this.onUnsplit,
  });
  final List<WorkspaceTab> tabs;
  final List<List<String>> groups;
  final Map<String, String> groupSelections;
  final ValueChanged<String>? onUnsplit;
  final String selectedId;
  final ValueChanged<String> onSelect, onClose;
  final VoidCallback? onNewWindow;
  final bool supportsNewWindow;

  /// A null destination appends after the last SSH tab. Home is never moved.
  final void Function(String tabId, String? beforeId)? onReorder;
  final void Function(String tabId, Axis axis)? onSplit;
  final ValueChanged<String>? onDetach, onProperties, onCloseOthers;
  final ValueChanged<String>? onDuplicate;
  final String dragScope;
  final Widget? leading;
  final List<Widget> actions;
  final List<WorkspaceAction> homeMenuActions;
  final VoidCallback? onSearch, onToggleTools;
  final ValueChanged<String>? onSftp, onScp, onScpUpload, onScpDownload;

  List<WorkspaceTab> get _displayTabs {
    final byId = {for (final tab in tabs) tab.id: tab};
    final membership = <String, List<WorkspaceTab>>{};
    for (final ids in groups) {
      final members = [
        for (final id in ids)
          if (byId[id] != null && !byId[id]!.isHome) byId[id]!,
      ];
      if (members.length > 1) {
        for (final member in members) {
          membership[member.id] = members;
        }
      }
    }
    final emitted = <String>{};
    return [
      for (final tab in tabs)
        if (membership[tab.id] case final members?) ...[
          if (emitted.add(members.first.id))
            WorkspaceTab(
              id: members.first.id,
              title: '${members.first.title} +${members.length - 1}',
              icon: Icons.space_dashboard_outlined,
              isConnected: members.every((member) => member.isConnected),
              status: currentL10n.countCount2Connected(
                members.where((member) => member.isConnected).length,
                members.length,
              ),
              canDetach: false,
              canOpenFiles: false,
              members: members,
            ),
        ] else
          tab,
    ];
  }

  String _selectionFor(WorkspaceTab tab) =>
      tab.members.any((member) => member.id == selectedId)
      ? selectedId
      : tab.members.any((member) => member.id == groupSelections[tab.id])
      ? groupSelections[tab.id]!
      : tab.id;

  void _closeTab(WorkspaceTab tab) {
    if (tab.members.isEmpty) {
      onClose(tab.id);
      return;
    }
    for (final member in tab.members) {
      onClose(member.id);
    }
  }

  Future<void> _groupMenu(
    BuildContext context,
    WorkspaceTab tab,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final action = await showMenu<String>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      context: context,
      shape: Theme.of(context).popupMenuTheme.shape ?? workspaceMenuShape,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromRect(
        Rect.fromPoints(point, point),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final member in tab.members)
          appMenuItem(
            context,
            value: 'select:${member.id}',
            child: AppMenuLabel(
              member.icon ??
                  (member.isFile ? Icons.folder_outlined : Icons.terminal),
              member.title,
              subtitle:
                  member.status ??
                  (member.isConnected
                      ? context.l10n.connected
                      : context.l10n.notConnected),
            ),
          ),
        const PopupMenuDivider(height: 8),
        if (onUnsplit != null)
          appMenuItem(
            context,
            value: 'unsplit',
            child: AppMenuLabel(
              Icons.call_split,
              context.l10n.unsplitCurrentPane,
            ),
          ),
        appMenuItem(
          context,
          value: 'close',
          child: AppMenuLabel(
            Icons.close_fullscreen,
            context.l10n.closeThisSplitGroup,
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action.startsWith('select:')) onSelect(action.substring(7));
    if (action == 'unsplit') onUnsplit?.call(_selectionFor(tab));
    if (action == 'close') _closeTab(tab);
  }

  Future<void> _menu(
    BuildContext context,
    WorkspaceTab tab,
    Offset position,
  ) async {
    onSelect(tab.id);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final localPosition = overlay.globalToLocal(position);
    final selected = await showMenu<_TabCommand>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      context: context,
      shape: Theme.of(context).popupMenuTheme.shape ?? workspaceMenuShape,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromRect(
        Rect.fromPoints(localPosition, localPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        if (!tab.isFile && tab.canOpenFiles && onSftp != null)
          appMenuItem(
            context,
            value: _TabCommand.sftp,
            enabled: tab.isConnected,
            child: AppMenuLabel(
              Icons.folder_open_outlined,
              context.l10n.sftpFileManager,
            ),
          ),
        if (!tab.isFile && tab.canOpenFiles && onScp != null)
          appMenuItem(
            context,
            value: _TabCommand.scp,
            enabled: tab.isConnected,
            child: AppMenuLabel(Icons.sync_alt, context.l10n.scpFileManager),
          ),
        if (!tab.isFile &&
            tab.canOpenFiles &&
            onScp == null &&
            onScpUpload != null)
          appMenuItem(
            context,
            value: _TabCommand.scpUpload,
            enabled: tab.isConnected,
            child: AppMenuLabel(
              Icons.upload_file_outlined,
              context.l10n.scpUpload,
            ),
          ),
        if (!tab.isFile &&
            tab.canOpenFiles &&
            onScp == null &&
            onScpDownload != null)
          appMenuItem(
            context,
            value: _TabCommand.scpDownload,
            enabled: tab.isConnected,
            child: AppMenuLabel(
              Icons.file_download_outlined,
              context.l10n.scpDownload,
            ),
          ),
        if (!tab.isFile &&
            tab.canOpenFiles &&
            (onSftp != null ||
                onScp != null ||
                onScpUpload != null ||
                onScpDownload != null))
          const PopupMenuDivider(height: 8),
        if (onDuplicate != null)
          appMenuItem(
            context,
            value: _TabCommand.duplicate,
            child: AppMenuLabel(Icons.content_copy, context.l10n.duplicateTab),
          ),
        appMenuItem(
          context,
          value: _TabCommand.close,
          child: AppMenuLabel(Icons.close, context.l10n.closeTab),
        ),
        appMenuItem(
          context,
          value: _TabCommand.closeOthers,
          enabled: tabs
              .where((value) => !value.isHome && value.id != tab.id)
              .isNotEmpty,
          child: AppMenuLabel(
            Icons.playlist_remove,
            context.l10n.closeOtherTabs,
          ),
        ),
        if (onSplit != null) ...[
          const PopupMenuDivider(height: 8),
          appMenuItem(
            context,
            value: _TabCommand.splitHorizontal,
            child: AppMenuLabel(
              Icons.view_week_outlined,
              context.l10n.splitLeftRight,
            ),
          ),
          appMenuItem(
            context,
            value: _TabCommand.splitVertical,
            child: AppMenuLabel(
              Icons.splitscreen_outlined,
              context.l10n.splitTopBottom,
            ),
          ),
        ],
        if (supportsNewWindow && tab.canDetach && onDetach != null)
          appMenuItem(
            context,
            value: _TabCommand.detach,
            child: AppMenuLabel(
              Icons.open_in_new,
              context.l10n.moveToNewWindow,
            ),
          ),
        if (onProperties != null) ...[
          const PopupMenuDivider(height: 8),
          appMenuItem(
            context,
            value: _TabCommand.properties,
            child: AppMenuLabel(Icons.info_outline, context.l10n.properties),
          ),
        ],
      ],
    );
    if (!context.mounted || selected == null) return;
    switch (selected) {
      case _TabCommand.sftp:
        onSftp?.call(tab.id);
      case _TabCommand.scp:
        onScp?.call(tab.id);
      case _TabCommand.scpUpload:
        onScpUpload?.call(tab.id);
      case _TabCommand.scpDownload:
        onScpDownload?.call(tab.id);
      case _TabCommand.duplicate:
        onDuplicate?.call(tab.id);
      case _TabCommand.close:
        onClose(tab.id);
      case _TabCommand.closeOthers:
        if (onCloseOthers != null) {
          onCloseOthers!(tab.id);
        } else {
          for (final other in tabs.where(
            (value) => !value.isHome && value.id != tab.id,
          )) {
            onClose(other.id);
          }
        }
      case _TabCommand.splitHorizontal:
        onSplit?.call(tab.id, Axis.horizontal);
      case _TabCommand.splitVertical:
        onSplit?.call(tab.id, Axis.vertical);
      case _TabCommand.detach:
        onDetach?.call(tab.id);
      case _TabCommand.properties:
        onProperties?.call(tab.id);
    }
  }

  Widget _tab(BuildContext context, WorkspaceTab tab, WindowBarMetrics bar) {
    final colors = Theme.of(context).colorScheme;
    final selected =
        tab.id == selectedId ||
        tab.members.any((member) => member.id == selectedId);
    final content = Semantics(
      container: true,
      explicitChildNodes: true,
      button: true,
      label: tab.isHome
          ? tab.title
          : context.l10n.tabSemanticsLabel(
              tab.title,
              tab.status ??
                  (tab.isConnected
                      ? context.l10n.tabSemanticsConnected
                      : context.l10n.tabSemanticsDisconnected),
              selected
                  ? context.l10n.tabSemanticsActive
                  : context.l10n.tabSemanticsInactive,
            ),
      onTap: () => onSelect(_selectionFor(tab)),
      selected: selected,
      child: GestureDetector(
        onSecondaryTapDown: tab.isHome
            ? null
            : (event) => tab.members.isEmpty
                  ? _menu(context, tab, event.globalPosition)
                  : _groupMenu(context, tab, event.globalPosition),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            tab.isHome ? 8 : 3,
            bar.tabInset,
            3,
            bar.tabInset,
          ),
          // Selection fill and border cross-fade (120 ms) instead of jumping.
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(
              end: Color.alphaBlend(
                colors.onSurface.withValues(alpha: selected ? .16 : .07),
                colors.surfaceContainerLow,
              ),
            ),
            duration: AppMotion.duration(context, MotionDurations.quick),
            curve: MotionCurves.move,
            builder: (context, color, child) => Material(
              key: ValueKey('workspace-tab-surface-${tab.id}'),
              color: color,
              animationDuration: AppMotion.duration(
                context,
                MotionDurations.quick,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: selected
                      ? colors.primary.withValues(alpha: .7)
                      : colors.onSurface.withValues(alpha: .12),
                ),
              ),
              child: child,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(_selectionFor(tab)),
              child: SizedBox(
                key: ValueKey('workspace-tab-${tab.id}'),
                height: bar.tabHeight,
                width: tab.isHome ? 136 : 196,
                child: Row(
                  children: [
                    if (tab.isHome && homeMenuActions.isNotEmpty)
                      WorkspaceOverflowMenu(
                        key: const ValueKey('workspace_host_menu'),
                        tooltip: context.l10n.hostMenuClickToOpen,
                        actions: homeMenuActions,
                        child: SizedBox(
                          width: 48,
                          height: bar.tabHeight,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.home_outlined, size: bar.iconSize),
                              const Icon(Icons.expand_more, size: 14),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      const SizedBox(width: 12),
                      Icon(
                        tab.icon ??
                            (tab.isHome
                                ? Icons.home_outlined
                                : tab.isFile
                                ? Icons.folder_outlined
                                : Icons.terminal),
                        size: bar.iconSize,
                        color: tab.isConnected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: bar.dense
                            ? const TextStyle(
                                fontSize: WindowBarMetrics.denseLabelSize,
                              )
                            : null,
                        strutStyle: bar.dense
                            ? WindowBarMetrics.denseLabelStrut
                            : null,
                      ),
                    ),
                    if (!tab.isHome)
                      IconButton(
                        tooltip: tab.members.isEmpty
                            ? context.l10n.closeTitle(tab.title)
                            : context.l10n.closeThisSplitGroup,
                        visualDensity: VisualDensity.compact,
                        iconSize: bar.dense ? 14 : 16,
                        padding: bar.dense ? EdgeInsets.zero : null,
                        constraints: bar.dense
                            ? BoxConstraints.tightFor(
                                width: 28,
                                height: bar.tabHeight,
                              )
                            : null,
                        onPressed: () => _closeTab(tab),
                        icon: const Icon(Icons.close),
                      )
                    else
                      const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tab.members.isNotEmpty) {
      return Tooltip(
        message: tab.members
            .map(
              (member) =>
                  '${member.title} · ${member.status ?? (member.isConnected ? context.l10n.connected : context.l10n.notConnected)}',
            )
            .join('\n'),
        child: KeyedSubtree(
          key: ValueKey('workspace-group-${tab.members.first.id}'),
          child: content,
        ),
      );
    }
    if (tab.isHome) return content;
    final data = WorkspaceTabDragData(tabId: tab.id, scope: dragScope);
    final feedback = Material(
      elevation: 8,
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 196,
        height: 40,
        child: Center(
          child: Text(tab.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    void dragEnd(DraggableDetails details) {
      if (details.wasAccepted ||
          !supportsNewWindow ||
          !tab.canDetach ||
          onDetach == null ||
          !context.mounted) {
        return;
      }
      final view = View.of(context);
      final viewport =
          Offset.zero & (view.physicalSize / view.devicePixelRatio);
      if (!viewport.contains(details.offset)) onDetach!(tab.id);
    }

    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final draggable = mobile
        ? LongPressDraggable<WorkspaceTabDragData>(
            data: data,
            feedback: feedback,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragEnd: dragEnd,
            childWhenDragging: Opacity(opacity: .35, child: content),
            child: content,
          )
        : Draggable<WorkspaceTabDragData>(
            data: data,
            feedback: feedback,
            allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragEnd: dragEnd,
            childWhenDragging: Opacity(opacity: .35, child: content),
            child: content,
          );
    return DragTarget<WorkspaceTabDragData>(
      onWillAcceptWithDetails: (details) =>
          onReorder != null &&
          details.data.scope == dragScope &&
          details.data.tabId != tab.id,
      onAcceptWithDetails: (details) =>
          onReorder?.call(details.data.tabId, tab.id),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: candidates.isEmpty ? Colors.transparent : colors.primary,
              width: 2,
            ),
          ),
        ),
        child: draggable,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chrome = WindowChromeScope.of(context);
    final visibleTabs = _displayTabs;
    return ListenableBuilder(
      listenable: chrome,
      builder: (context, _) {
        final embedded = chrome.supported && chrome.state.enabled;
        final bar = WindowBarMetrics.of(context, chrome);
        // Dense native-height bar: every trailing icon (including callers'
        // actions) is exactly one bar tall so icons and caption buttons share
        // one baseline; touch platforms keep the default button sizes.
        Widget sized(Widget row) => !bar.dense
            ? row
            : IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    minimumSize: Size(bar.actionWidth, bar.height),
                    maximumSize: Size(bar.actionWidth, bar.height),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.standard,
                    shape: const RoundedRectangleBorder(),
                  ),
                ),
                child: row,
              );
        return Material(
          color: colors.surfaceContainerLow,
          child: SizedBox(
            key: const ValueKey('workspace_navigation_bar'),
            height: bar.height,
            child: sized(
              Row(
                children: [
                  ?leading,
                  for (final tab in visibleTabs.where((tab) => tab.isHome))
                    _tab(context, tab, bar),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final usedWidth = visibleTabs
                            .where((tab) => !tab.isHome)
                            .fold<double>(
                              0,
                              (width, tab) => width + (tab.isHome ? 142 : 204),
                            );
                        final gapWidth = (constraints.maxWidth - usedWidth)
                            .clamp(32.0, double.infinity);
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final tab in visibleTabs.where(
                                (tab) => !tab.isHome,
                              ))
                                _TabEntrance(
                                  key: ValueKey(
                                    'workspace-tab-motion-${tab.id}',
                                  ),
                                  child: _tab(context, tab, bar),
                                ),
                              DragTarget<WorkspaceTabDragData>(
                                onWillAcceptWithDetails: (details) =>
                                    onReorder != null &&
                                    details.data.scope == dragScope,
                                onAcceptWithDetails: (details) =>
                                    onReorder?.call(details.data.tabId, null),
                                builder: (context, candidates, _) {
                                  final gap = SizedBox(
                                    width: gapWidth,
                                    height: bar.height,
                                    child: candidates.isEmpty
                                        ? null
                                        : ColoredBox(
                                            color: colors.primary.withValues(
                                              alpha: .2,
                                            ),
                                          ),
                                  );
                                  return embedded
                                      ? WindowDragArea(
                                          controller: chrome,
                                          child: gap,
                                        )
                                      : gap;
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  if (homeMenuActions.isEmpty &&
                      supportsNewWindow &&
                      onNewWindow != null)
                    IconButton(
                      tooltip: context.l10n.newWindowCtrlShiftN,
                      onPressed: onNewWindow,
                      icon: const Icon(Icons.add_to_queue_outlined),
                    ),
                  ...actions,
                  if (onSearch != null)
                    IconButton(
                      key: const ValueKey('workspace_host_search_button'),
                      tooltip: context.l10n.searchHostsOrQuickConnect,
                      onPressed: onSearch,
                      icon: Icon(
                        Icons.search_rounded,
                        size: bar.dense ? 18 : 21,
                      ),
                    ),
                  if (onToggleTools != null)
                    IconButton(
                      key: const ValueKey('workspace_terminal_sidebar_button'),
                      tooltip: context.l10n.terminalSidebar,
                      onPressed: onToggleTools,
                      icon: Icon(
                        Icons.vertical_split_outlined,
                        size: bar.dense ? 18 : 21,
                      ),
                    ),
                  WindowCaptionControls(controller: chrome, height: bar.height),
                  if (!embedded) const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// New tab: 160 ms fade + 6 px lift. Paint-only, so the tab's hit area,
/// close button and drag handle are live from the first frame. Closing is
/// immediate: a closed session leaves no ghost that could keep focus or
/// receive taps.
class _TabEntrance extends StatelessWidget {
  const _TabEntrance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => MotionEntrance(
    trigger: null,
    // Tabs built before the strip's first layout (startup, window restore)
    // appear immediately; only tabs opened afterwards play the entrance.
    animateOnFirstBuild:
        context
            .findAncestorStateOfType<ScrollableState>()
            ?.position
            .hasViewportDimension ??
        false,
    duration: MotionDurations.standard,
    offset: const Offset(0, 6),
    child: child,
  );
}
