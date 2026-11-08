import 'app_menu.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/quick_connect.dart';
import 'app_motion.dart';
import 'host_search_field.dart';
import '../l10n/l10n.dart';

/// Keep duplicate leaf names distinguishable in nested group filters.
Map<String, String> hostSearchGroupLabels(Iterable<GroupRecord> groups) {
  final byId = {for (final group in groups) group.id: group};
  return {
    for (final group in byId.values)
      group.id: (() {
        final path = <String>[group.name];
        final seen = <String>{group.id};
        var parent = group.parentId;
        while (parent != null && seen.add(parent)) {
          final node = byId[parent];
          if (node == null) break;
          path.insert(0, node.name);
          parent = node.parentId;
        }
        return path.join(' / ');
      })(),
  };
}

class HostSearchSelection {
  const HostSearchSelection.host(this.hostId) : command = null;
  const HostSearchSelection.command(this.command) : hostId = null;
  final String? hostId;
  final QuickConnectRequest? command;
}

Future<HostSearchSelection?> showHostSearchPalette(
  BuildContext context, {
  required List<HostRecord> Function() hosts,
  required Map<String, String> groups,
  required Key fieldKey,
  required bool Function() isCurrent,
  Listenable? changes,
  void Function(VoidCallback?)? onDismissChanged,
}) async {
  final navigator = Navigator.of(context);
  late final DialogRoute<HostSearchSelection> route;
  void dismiss() {
    if (route.isActive) navigator.removeRoute(route);
  }

  route = AppDialogRoute<HostSearchSelection>(
    context: context,
    motion: AppDialogMotion.palette,
    builder: (_) => _HostSearchPalette(
      hosts: hosts,
      groups: groups,
      fieldKey: fieldKey,
      isCurrent: isCurrent,
      changes: changes,
      onInvalidated: dismiss,
    ),
  );
  final result = navigator.push(route);
  onDismissChanged?.call(dismiss);
  try {
    return await result;
  } finally {
    onDismissChanged?.call(null);
  }
}

class _HostSearchPalette extends StatefulWidget {
  const _HostSearchPalette({
    required this.hosts,
    required this.groups,
    required this.fieldKey,
    required this.isCurrent,
    required this.onInvalidated,
    this.changes,
  });
  final List<HostRecord> Function() hosts;
  final Map<String, String> groups;
  final Key fieldKey;
  final bool Function() isCurrent;
  final VoidCallback onInvalidated;
  final Listenable? changes;
  @override
  State<_HostSearchPalette> createState() => _HostSearchPaletteState();
}

class _HostSearchPaletteState extends State<_HostSearchPalette> {
  final _search = TextEditingController();
  HostProtocol? _protocol;
  String? _group;
  bool _favorites = false;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.isCurrent()) {
      widget.onInvalidated();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _select(HostSearchSelection selection) {
    if (widget.isCurrent()) Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    QuickConnectRequest? command;
    try {
      command = QuickConnectRequest.parse(_search.text);
    } on FormatException {
      // The search field shows bounded syntax guidance while typing.
    }
    final matches = widget.hosts().where((host) {
      if (_protocol != null && host.protocol != _protocol) return false;
      if (_group != null && host.groupId != _group) return false;
      if (_favorites && !host.isFavorite) return false;
      if (command != null) return command.matches(host);
      return query.isEmpty ||
          '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')} ${widget.groups[host.groupId] ?? ''}'
              .toLowerCase()
              .contains(query);
    }).toList();
    return Dialog(
      key: const ValueKey('host_search_palette'),
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 56),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.searchAndQuickConnect,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.closeSearch,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              HostSearchField(
                fieldKey: widget.fieldKey,
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onConnect: (request) =>
                    _select(HostSearchSelection.command(request)),
                onSearchSubmitted: matches.isEmpty
                    ? null
                    : () => _select(HostSearchSelection.host(matches.first.id)),
              ),
              const SizedBox(height: 12),
              Wrap(
                key: const ValueKey('host_search_filters'),
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(context.l10n.all),
                    selected: _protocol == null,
                    onSelected: (_) => setState(() => _protocol = null),
                  ),
                  for (final protocol in HostProtocol.values)
                    ChoiceChip(
                      label: Text(protocol.name.toUpperCase()),
                      selected: _protocol == protocol,
                      onSelected: (_) => setState(() => _protocol = protocol),
                    ),
                  FilterChip(
                    label: Text(context.l10n.favorites),
                    selected: _favorites,
                    onSelected: (value) => setState(() => _favorites = value),
                  ),
                  if (widget.groups.isNotEmpty)
                    PopupMenuButton<String>(
                      popUpAnimationStyle: AppMotion.menuStyle(context),
                      tooltip: context.l10n.filterByGroup,
                      initialValue: _group ?? '',
                      onSelected: (value) =>
                          setState(() => _group = value.isEmpty ? null : value),
                      itemBuilder: (_) => [
                        appMenuItem(context,
                          value: '',
                          child: Text(context.l10n.allGroups),
                        ),
                        for (final entry in widget.groups.entries)
                          appMenuItem(context,
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      child: Chip(
                        label: Text(
                          widget.groups[_group] ?? context.l10n.groups,
                        ),
                        avatar: const Icon(Icons.folder_outlined, size: 16),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.countHosts2(matches.length),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Flexible(
                child: matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(context.l10n.noMatchingHostsTypeAnSsh),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (_, index) {
                          final host = matches[index];
                          return ListTile(
                            key: ValueKey('host-search-result-${host.id}'),
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: Icon(
                              host.protocol == HostProtocol.ssh
                                  ? Icons.terminal
                                  : Icons.desktop_windows_outlined,
                              size: 20,
                            ),
                            title: Text(
                              host.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${host.protocol.name.toUpperCase()} · ${host.username.isEmpty ? '' : '${host.username}@'}${host.endpoint}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.north_east, size: 16),
                            onTap: () =>
                                _select(HostSearchSelection.host(host.id)),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
