import 'app_menu.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../terminal/terminal_search.dart';
import '../terminal/terminal_tools.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';

/// Keep the terminal child mounted across opening/closing and width changes.
class TerminalToolsLayout extends StatelessWidget {
  const TerminalToolsLayout({required this.child, this.sidebar, super.key});
  final Widget child;
  final Widget? sidebar;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(340.0, constraints.maxWidth);
      final docked = constraints.maxWidth >= 760;
      return Stack(
        children: [
          Positioned.fill(
            right: sidebar != null && docked ? width : 0,
            child: child,
          ),
          if (sidebar != null)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: width,
              child: sidebar!,
            ),
        ],
      );
    },
  );
}

class TerminalToolsLauncher extends StatelessWidget {
  const TerminalToolsLauncher({required this.onOpen, super.key});
  final ValueChanged<TerminalToolsSection> onOpen;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        key: const ValueKey('terminal-tools-search'),
        onPressed: () => onOpen(TerminalToolsSection.search),
        icon: const Icon(Icons.search, size: 16),
        label: Text(context.l10n.search2),
      ),
      IconButton(
        key: const ValueKey('terminal-tools-commands'),
        tooltip: context.l10n.quickCommands,
        onPressed: () => onOpen(TerminalToolsSection.commands),
        icon: const Icon(Icons.bolt, size: 18),
      ),
      IconButton(
        key: const ValueKey('terminal-tools-history'),
        tooltip: context.l10n.inputHistory,
        onPressed: () => onOpen(TerminalToolsSection.history),
        icon: const Icon(Icons.history, size: 18),
      ),
    ],
  );
}

class TerminalToolsSidebar extends StatefulWidget {
  const TerminalToolsSidebar({
    required this.section,
    required this.onSection,
    required this.onClose,
    required this.query,
    required this.queryFocus,
    required this.onQuery,
    required this.searchStatus,
    required this.previous,
    required this.next,
    required this.searchHistory,
    required this.loadCommands,
    required this.editCommand,
    required this.deleteCommand,
    required this.history,
    required this.onInsert,
    required this.onConfigureHistory,
    required this.onClearHistory,
    this.historyNotice,
    this.historyChanges,
    this.onSearchKey,
    super.key,
  });
  final TerminalToolsSection section;
  final ValueChanged<TerminalToolsSection> onSection;
  final VoidCallback onClose;
  final TextEditingController query;
  final FocusNode queryFocus;
  final ValueChanged<String> onQuery;
  final String searchStatus;
  final VoidCallback? previous, next;
  final TerminalSearchHistory searchHistory;
  final Future<List<TerminalCommandItem>> Function() loadCommands;
  final Future<void> Function(TerminalCommandItem?) editCommand;
  final Future<void> Function(TerminalCommandItem) deleteCommand;
  final List<TerminalCommandItem> Function() history;
  final bool Function(String) onInsert;
  final Future<void> Function() onConfigureHistory, onClearHistory;
  final String? Function()? historyNotice;
  final Listenable? historyChanges;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchKey;
  @override
  State<TerminalToolsSidebar> createState() => _TerminalToolsSidebarState();
}

const _prefixConstraints = BoxConstraints(minWidth: 40, minHeight: 40);
const _fieldPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 10);
const _tilePadding = EdgeInsets.symmetric(horizontal: 12);
const _listDensity = VisualDensity(horizontal: 0, vertical: -2);

/// Icon section selector for the SSH tools sidebar. Each icon carries a
/// localized tooltip and an exclusive selected state for assistive tech; the
/// selected section's name is shown beside the icons.
class TerminalToolsSectionTabs extends StatelessWidget {
  const TerminalToolsSectionTabs({
    required this.section,
    required this.onSection,
    super.key,
  });
  final TerminalToolsSection section;
  final ValueChanged<TerminalToolsSection> onSection;

  static IconData iconFor(TerminalToolsSection section) => switch (section) {
    TerminalToolsSection.search => Icons.search,
    TerminalToolsSection.commands => Icons.bolt,
    TerminalToolsSection.history => Icons.history,
  };

  static String labelFor(BuildContext context, TerminalToolsSection section) =>
      switch (section) {
        TerminalToolsSection.search => context.l10n.search,
        TerminalToolsSection.commands => context.l10n.quickCommands,
        TerminalToolsSection.history => context.l10n.inputHistory,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      key: const ValueKey('terminal-tools-sections'),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in TerminalToolsSection.values)
                  _SectionIcon(
                    key: ValueKey('terminal-tools-section-${value.name}'),
                    icon: iconFor(value),
                    label: labelFor(context, value),
                    selected: value == section,
                    selectedColor: colors.primary,
                    onPressed: () => onSection(value),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ExcludeSemantics(
            child: Text(
              labelFor(context, section),
              key: const ValueKey('terminal-tools-section-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

bool _touch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({
    required this.icon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onPressed,
    super.key,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    label: label,
    onTap: onPressed,
    child: ExcludeSemantics(
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? selectedColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed,
            child: SizedBox(
              // Touch platforms keep a real 48x48 hit box.
              width: _touch(context) ? 48 : 40,
              height: _touch(context) ? 48 : 32,
              child: Icon(
                icon,
                size: 18,
                color: selected ? AppColors.onAccent : AppColors.muted,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TerminalToolsSidebarState extends State<TerminalToolsSidebar> {
  Future<List<TerminalCommandItem>>? _commands;
  String _filter = '';
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.historyChanges?.addListener(_refreshHistory);
  }

  @override
  void didUpdateWidget(covariant TerminalToolsSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.historyChanges != widget.historyChanges) {
      oldWidget.historyChanges?.removeListener(_refreshHistory);
      widget.historyChanges?.addListener(_refreshHistory);
    }
  }

  @override
  void dispose() {
    widget.historyChanges?.removeListener(_refreshHistory);
    super.dispose();
  }

  void _refreshHistory() {
    if (mounted) setState(() {});
  }

  void _remember() =>
      setState(() => widget.searchHistory.remember(widget.query.text));
  void _move(VoidCallback? action) {
    _remember();
    action?.call();
  }

  Future<void> _action(
    Future<void> Function() work, {
    bool reload = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.theActionDidntCompleteRefreshAnd);
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          if (reload) _commands = null;
        });
    }
  }

  void _insert(String command) {
    if (!isSafeTerminalCommand(command) || !widget.onInsert(command)) {
      setState(() => _error = context.l10n.cantInsertSelectASessionThat);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('terminal-tools-sidebar'),
    color: AppColors.surface,
    shape: const Border(left: BorderSide(color: AppColors.line)),
    child: CustomScrollView(
      key: const ValueKey('terminal-tools-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.terminalTools,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: context.l10n.closeSidebar,
                key: const ValueKey('terminal-tools-close'),
                onPressed: () {
                  _remember();
                  widget.onClose();
                },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
            child: TerminalToolsSectionTabs(
              section: widget.section,
              onSection: (value) {
                if (value == widget.section) return;
                if (widget.section == TerminalToolsSection.search) {
                  _remember();
                }
                setState(() {
                  _filter = '';
                  _error = null;
                });
                widget.onSection(value);
              },
            ),
          ),
        ),
        if (_busy) const SliverToBoxAdapter(child: LinearProgressIndicator()),
        if (_error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.red),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ...switch (widget.section) {
          TerminalToolsSection.search => _search(),
          TerminalToolsSection.commands => _quickCommands(),
          TerminalToolsSection.history => _history(),
        },
      ],
    ),
  );

  List<Widget> _search() => [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              _remember();
              widget.onClose();
              return KeyEventResult.handled;
            }
            return widget.onSearchKey?.call(node, event) ??
                KeyEventResult.ignored;
          },
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.query,
            builder: (context, value, _) => TextField(
              key: const ValueKey('terminal-sidebar-query'),
              controller: widget.query,
              focusNode: widget.queryFocus,
              autofocus: true,
              maxLength: terminalSearchMaxQueryGraphemes,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              onChanged: widget.onQuery,
              onSubmitted: (_) => _move(widget.next),
              textInputAction: TextInputAction.search,
              textAlign: value.text.isEmpty
                  ? TextAlign.center
                  : TextAlign.start,
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: context.l10n.searchCurrentTerminalOutput,
                hintStyle: const TextStyle(
                  fontSize: 12,
                  color: AppColors.muted,
                ),
                hintMaxLines: 1,
                prefixIcon: const Icon(Icons.search, size: 16),
                prefixIconConstraints: _prefixConstraints,
                // Equal icon gutters center the empty prompt within the border,
                // not just within the space left over after the search icon.
                suffixIcon: value.text.isEmpty
                    ? const SizedBox(width: 40)
                    : null,
                suffixIconConstraints: _prefixConstraints,
                contentPadding: _fieldPadding,
                constraints: BoxConstraints(
                  minHeight: _touch(context) ? 48 : 40,
                ),
                counterText: '',
                isDense: true,
              ),
            ),
          ),
        ),
      ),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.searchStatus,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            IconButton(
              tooltip: context.l10n.previousMatch,
              visualDensity: VisualDensity.compact,
              onPressed: widget.previous == null
                  ? null
                  : () => _move(widget.previous),
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: context.l10n.nextMatch,
              visualDensity: VisualDensity.compact,
              onPressed: widget.next == null ? null : () => _move(widget.next),
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
          ],
        ),
      ),
    ),
    SliverToBoxAdapter(
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.searchHistory,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: widget.searchHistory.items.isEmpty
                ? null
                : () => setState(widget.searchHistory.clear),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    ),
    widget.searchHistory.items.isEmpty
        ? SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                context.l10n.searchTermsAreRecordedWhenYou,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          )
        : SliverList.builder(
            itemCount: widget.searchHistory.items.length,
            itemBuilder: (_, index) {
              final value = widget.searchHistory.items[index];
              return ListTile(
                dense: true,
                visualDensity: _listDensity,
                contentPadding: _tilePadding,
                minLeadingWidth: 20,
                horizontalTitleGap: 8,
                leading: const Icon(Icons.history, size: 16),
                title: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  widget.query.text = value;
                  widget.onQuery(value);
                  _remember();
                  widget.queryFocus.requestFocus();
                },
                trailing: IconButton(
                  tooltip: context.l10n.removeSearchTerm,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () =>
                      setState(() => widget.searchHistory.remove(value)),
                ),
              );
            },
          ),
  ];

  Widget _filterField(String hint) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: TextField(
      key: ValueKey('terminal-${widget.section.name}-filter'),
      autofocus: true,
      onChanged: (value) => setState(() => _filter = value),
      textAlign: _filter.isEmpty ? TextAlign.center : TextAlign.start,
      textAlignVertical: TextAlignVertical.center,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AppColors.muted),
        hintMaxLines: 1,
        prefixIcon: const Icon(Icons.filter_list, size: 16),
        prefixIconConstraints: _prefixConstraints,
        suffixIcon: _filter.isEmpty ? const SizedBox(width: 40) : null,
        suffixIconConstraints: _prefixConstraints,
        contentPadding: _fieldPadding,
        constraints: BoxConstraints(minHeight: _touch(context) ? 48 : 40),
        isDense: true,
      ),
    ),
  );
  List<TerminalCommandItem> _filtered(List<TerminalCommandItem> items) {
    final query = _filter.toLowerCase();
    return items
        .where(
          (item) =>
              '${item.title}\n${item.command}'.toLowerCase().contains(query),
        )
        .toList();
  }

  List<Widget> _quickCommands() => [
    SliverToBoxAdapter(child: _filterField(context.l10n.filterByNameOrCommand)),
    SliverToBoxAdapter(
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.saveEncryptedAsSnippets,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ),
          IconButton(
            tooltip: context.l10n.refreshQuickCommands,
            onPressed: () => setState(() => _commands = null),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            key: const ValueKey('terminal-quick-add'),
            tooltip: context.l10n.addQuickCommand,
            onPressed: _busy
                ? null
                : () => _action(() => widget.editCommand(null), reload: true),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          context.l10n.clickToInsertPressEnterTo,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ),
    ),
    FutureBuilder<List<TerminalCommandItem>>(
      future: _commands ??= widget.loadCommands(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(context.l10n.couldntReadQuickCommandsRefreshAnd),
            ),
          );
        }
        if (!snapshot.hasData)
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          );
        return _commandList(_filtered(snapshot.data!), editable: true);
      },
    ),
  ];
  List<Widget> _history() => [
    SliverToBoxAdapter(child: _filterField(context.l10n.filterInputHistory)),
    SliverToBoxAdapter(
      child: Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : () => _action(widget.onConfigureHistory),
            icon: const Icon(Icons.tune, size: 16),
            label: Text(context.l10n.recordingSettings),
          ),
          TextButton(
            onPressed: _busy ? null : () => _action(widget.onClearHistory),
            child: Text(context.l10n.clearLocalHistory),
          ),
        ],
      ),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          widget.historyNotice?.call() ??
              context.l10n.showsCommandsCompletedOnTheCurrent,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ),
    ),
    _commandList(_filtered(widget.history())),
  ];
  Widget _commandList(
    List<TerminalCommandItem> items, {
    bool editable = false,
  }) => items.isEmpty
      ? SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              context.l10n.noMatchingEntries,
              style: const TextStyle(color: AppColors.muted),
            ),
          ),
        )
      : SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              dense: true,
              visualDensity: _listDensity,
              contentPadding: _tilePadding,
              key: ValueKey('terminal-command-${item.id}'),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
              subtitle: Text(
                item.command,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              onTap: () => _insert(item.command),
              trailing: editable
                  ? PopupMenuButton<String>(
                      popUpAnimationStyle: AppMotion.menuStyle(context),
                      tooltip: context.l10n.quickCommandActions,
                      onSelected: (value) {
                        if (value == 'edit')
                          _action(() => widget.editCommand(item), reload: true);
                        if (value == 'delete')
                          _action(
                            () => widget.deleteCommand(item),
                            reload: true,
                          );
                      },
                      itemBuilder: (_) => [
                        appMenuItem(
                          context,
                          value: 'edit',
                          child: Text(context.l10n.edit),
                        ),
                        appMenuItem(
                          context,
                          value: 'delete',
                          child: Text(context.l10n.delete),
                        ),
                      ],
                    )
                  : IconButton(
                      tooltip: context.l10n.insertIntoTerminal,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.north_west, size: 16),
                      onPressed: () => _insert(item.command),
                    ),
            );
          },
        );
}

Future<SnippetRecord?> editTerminalQuickCommand(
  BuildContext context, {
  TerminalCommandItem? existing,
}) async {
  final title = TextEditingController(text: existing?.title);
  final command = TextEditingController(text: existing?.command);
  String? error;
  try {
    return await showAppDialog<SnippetRecord>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            existing == null
                ? context.l10n.addQuickCommand
                : context.l10n.editQuickCommand,
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('quick-command-title'),
                  controller: title,
                  autofocus: true,
                  maxLength: 128,
                  decoration: InputDecoration(labelText: context.l10n.name),
                ),
                TextField(
                  key: const ValueKey('quick-command-body'),
                  controller: command,
                  maxLength: 4096,
                  decoration: InputDecoration(
                    labelText: context.l10n.singleLineCommand,
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: AppColors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty ||
                    !isSafeTerminalCommand(command.text)) {
                  update(() => error = context.l10n.enterANameAndASingle);
                  return;
                }
                Navigator.pop(
                  context,
                  SnippetRecord(
                    id: existing?.id ?? const Uuid().v4(),
                    title: title.text.trim(),
                    body: command.text,
                    shell: 'bash',
                  ),
                );
              },
              child: Text(context.l10n.save2),
            ),
          ],
        ),
      ),
    );
  } finally {
    title.dispose();
    command.dispose();
  }
}
