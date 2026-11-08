import 'dart:async';

import 'package:flutter/material.dart';

import '../console/local_console.dart';
import '../console/local_shell_l10n.dart';
import '../l10n/l10n.dart';
import 'workspace_controls.dart';

/// Plus-menu entries for embedded local shells, shared by the account
/// workspace and the local Profile. On desktop: the system default shell
/// (legacy id `<prefix>_new_console`), one entry per other installed shell and
/// an options dialog (shell + working directory). On web/mobile: a single
/// entry that explains host shells are unavailable; nothing is started and
/// nothing runs on the server.
List<WorkspaceAction> localShellWorkspaceActions(
  BuildContext context, {
  required String idPrefix,
  required FutureOr<void> Function(LocalShellLaunch launch) onLaunch,
  bool enabled = true,
  bool? supportedOverride,
  List<LocalShellKind>? kindsOverride,
}) {
  final l10n = context.l10n;
  final supported = supportedOverride ?? localConsoleSupported;
  if (!supported) {
    return [
      WorkspaceAction(
        '${idPrefix}_console_unavailable',
        l10n.shellLocalUnavailable,
        Icons.code_off,
        () => showLocalShellUnavailable(context),
      ),
    ];
  }
  final kinds = kindsOverride ?? availableLocalShellKinds();
  return [
    WorkspaceAction(
      '${idPrefix}_new_console',
      l10n.localConsole,
      Icons.code,
      () => onLaunch(LocalShellLaunch.systemDefault),
      enabled: enabled,
    ),
    for (final kind in kinds)
      if (kind != LocalShellKind.system)
        WorkspaceAction(
          '${idPrefix}_new_shell_${kind.name}',
          l10n.shellLocalNewShell(localShellKindLabel(l10n, kind)),
          Icons.terminal_outlined,
          () => onLaunch(LocalShellLaunch(kind: kind)),
          enabled: enabled,
        ),
    WorkspaceAction(
      '${idPrefix}_shell_options',
      l10n.shellLocalOptions,
      Icons.tune,
      () async {
        final launch = await showLocalShellOptionsDialog(
          context,
          kinds: kinds.isEmpty ? const [LocalShellKind.system] : kinds,
        );
        if (launch != null) await onLaunch(launch);
      },
      enabled: enabled,
    ),
  ];
}

Future<void> showLocalShellUnavailable(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('local_shell_unavailable_dialog'),
        title: Text(context.l10n.shellLocalUnavailable),
        content: Text(context.l10n.shellLocalUnavailableDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );

/// Returns the chosen launch, or null when cancelled. Only syntax is checked
/// here; existence is checked when the shell starts.
Future<LocalShellLaunch?> showLocalShellOptionsDialog(
  BuildContext context, {
  required List<LocalShellKind> kinds,
  LocalShellLaunch initial = LocalShellLaunch.systemDefault,
}) => showDialog<LocalShellLaunch>(
  context: context,
  builder: (_) => _LocalShellOptionsDialog(kinds: kinds, initial: initial),
);

class _LocalShellOptionsDialog extends StatefulWidget {
  const _LocalShellOptionsDialog({required this.kinds, required this.initial});
  final List<LocalShellKind> kinds;
  final LocalShellLaunch initial;

  @override
  State<_LocalShellOptionsDialog> createState() =>
      _LocalShellOptionsDialogState();
}

class _LocalShellOptionsDialogState extends State<_LocalShellOptionsDialog> {
  late LocalShellKind _kind = widget.kinds.contains(widget.initial.kind)
      ? widget.initial.kind
      : widget.kinds.first;
  late final _directory = TextEditingController(
    text: widget.initial.workingDirectory ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _directory.dispose();
    super.dispose();
  }

  void _submit() {
    final directory = _directory.text.trim();
    if (directory.isNotEmpty &&
        !isPlausibleLocalShellWorkingDirectory(directory)) {
      setState(() => _error = context.l10n.shellLocalInvalidWorkingDirectory);
      return;
    }
    Navigator.of(context).pop(
      LocalShellLaunch(
        kind: _kind,
        workingDirectory: directory.isEmpty ? null : directory,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const ValueKey('local_shell_options_dialog'),
      title: Text(l10n.shellLocalOptionsTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<LocalShellKind>(
              key: const ValueKey('local_shell_kind'),
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.shellLocalShellLabel),
              items: [
                for (final kind in widget.kinds)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(localShellKindLabel(l10n, kind)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('local_shell_working_directory'),
              controller: _directory,
              maxLength: maxLocalShellWorkingDirectoryBytes,
              decoration: InputDecoration(
                labelText: l10n.shellLocalWorkingDirectoryLabel,
                helperText: l10n.shellLocalWorkingDirectoryHint,
                errorText: _error,
                counterText: '',
              ),
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('local_shell_start'),
          onPressed: _submit,
          child: Text(l10n.shellLocalStart),
        ),
      ],
    );
  }
}
