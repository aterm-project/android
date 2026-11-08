import 'package:flutter/material.dart';

import '../domain/quick_connect.dart';
import '../domain/models.dart';
import 'app_motion.dart';
import '../l10n/l10n.dart';

Future<HostRecord?> chooseQuickConnectHost(
  BuildContext context,
  List<HostRecord> matches,
) async {
  if (matches.length == 1) return matches.single;
  return showAppDialog<HostRecord>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(context.l10n.chooseAHostToConnectTo),
      children: [
        for (final host in matches)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, host),
            child: Text(
              '${host.name}\n${host.username}@${host.address}:${host.port}',
            ),
          ),
      ],
    ),
  );
}

class HostSearchField extends StatelessWidget {
  const HostSearchField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    required this.onConnect,
    this.enabled = true,
    this.autofocus = false,
    this.onSearchSubmitted,
  });
  final Key fieldKey;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<QuickConnectRequest> onConnect;
  final bool enabled;
  final bool autofocus;
  final VoidCallback? onSearchSubmitted;
  @override
  Widget build(BuildContext context) {
    QuickConnectRequest? request;
    String? syntax;
    try {
      request = QuickConnectRequest.parse(controller.text);
    } on FormatException catch (e) {
      syntax = e.message;
    }
    final command = request;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: fieldKey,
          controller: controller,
          autofocus: autofocus,
          onChanged: onChanged,
          textInputAction: TextInputAction.go,
          onSubmitted: !enabled || syntax != null
              ? null
              : (_) => command != null
                    ? onConnect(command)
                    : onSearchSubmitted?.call(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: context.l10n.searchHostsOrTypeAnSsh,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.clearSearch,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
        if (command != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              key: const ValueKey('quick_connect_action'),
              onPressed: enabled ? () => onConnect(command) : null,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(context.l10n.labelPressEnterToConnect(command.label)),
            ),
          ),
        if (syntax != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(syntax, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
