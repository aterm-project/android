import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../sftp/external_edit_manager.dart';
import '../sftp/external_edit_platform.dart';
import '../sftp/external_edit_policy.dart';
import '../ssh/file_workspace_controller.dart' show fileWorkspaceErrorText;

/// Localized text for an external-edit failure; never includes contents.
String externalEditErrorText(BuildContext context, Object error) {
  final l10n = context.l10n;
  if (error is! ExternalEditException) return fileWorkspaceErrorText(error);
  return switch (error.error) {
    ExternalEditError.unsupported => l10n.fileEditUnavailable,
    ExternalEditError.tooMany => l10n.fileEditTooMany(
      externalEditMaxConcurrent,
    ),
    ExternalEditError.tooLarge => l10n.fileEditTooLarge,
    ExternalEditError.notRegularRemote => l10n.fileEditNotRegular,
    ExternalEditError.blockedType => l10n.fileEditBlockedType,
    ExternalEditError.localRejected => l10n.fileEditLocalRejected,
    ExternalEditError.localTooLarge => l10n.fileEditLocalTooLarge,
    ExternalEditError.localMissing => l10n.fileEditLocalMissing,
    ExternalEditError.sessionChanged => l10n.fileEditSessionChanged,
    ExternalEditError.atomicReplaceUnsupported =>
      l10n.fileEditAtomicUnsupported,
    ExternalEditError.launchFailed => l10n.fileEditLaunchFailed,
  };
}

/// Persistent footer inside a file tab listing every externally edited file.
/// Changed files offer explicit Upload / Ignore / Keep local; nothing is
/// uploaded without pressing Upload.
class ExternalEditFooter extends StatelessWidget {
  const ExternalEditFooter({
    required this.manager,
    required this.onUpload,
    super.key,
  });

  final ExternalEditManager manager;
  final void Function(ExternalEditItem item) onUpload;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: manager,
    builder: (context, _) {
      final items = manager.items;
      if (items.isEmpty || manager.isClosed) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return Material(
        key: const ValueKey('file_edit_footer'),
        color: colors.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.fileEditFooterTitle(items.length),
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in items)
                          _ExternalEditRow(
                            key: ValueKey('file_edit_row_${item.id}'),
                            item: item,
                            manager: manager,
                            onUpload: onUpload,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ExternalEditRow extends StatelessWidget {
  const _ExternalEditRow({
    required this.item,
    required this.manager,
    required this.onUpload,
    super.key,
  });

  final ExternalEditItem item;
  final ExternalEditManager manager;
  final void Function(ExternalEditItem item) onUpload;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final status = item.status;
    final attention = item.needsAttention;
    final problem =
        status == ExternalEditStatus.conflict ||
        status == ExternalEditStatus.failed ||
        status == ExternalEditStatus.rejected;
    final statusText = switch (status) {
      ExternalEditStatus.watching => l10n.fileEditStatusWatching,
      ExternalEditStatus.changed => l10n.fileEditStatusChanged,
      ExternalEditStatus.uploading => l10n.fileEditStatusUploading,
      ExternalEditStatus.conflict => l10n.fileEditStatusConflict,
      ExternalEditStatus.failed => l10n.fileEditStatusFailed,
      ExternalEditStatus.rejected => l10n.fileEditStatusRejected,
    };
    final error = item.error;
    final detail = error == null
        ? statusText
        : '$statusText · ${externalEditErrorText(context, error)}';
    final uploading = status == ExternalEditStatus.uploading;
    final actions = <Widget>[
      if (attention && status != ExternalEditStatus.rejected)
        FilledButton.tonal(
          key: ValueKey('file_edit_upload_${item.id}'),
          onPressed: item.canUpload ? () => onUpload(item) : null,
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          child: Text(l10n.fileEditUpload),
        ),
      if (attention)
        TextButton(
          key: ValueKey('file_edit_ignore_${item.id}'),
          onPressed: uploading ? null : () => manager.ignore(item),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: Text(l10n.fileEditIgnore),
        ),
      TextButton(
        key: ValueKey('file_edit_keep_${item.id}'),
        onPressed: uploading ? null : () => manager.keepLocal(item),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        child: Text(attention ? l10n.fileEditKeepLocal : l10n.fileEditStop),
      ),
    ];
    final label = Row(
      children: [
        Icon(
          problem
              ? Icons.warning_amber_rounded
              : attention
              ? Icons.edit_note
              : Icons.visibility_outlined,
          size: 18,
          color: problem
              ? colors.error
              : attention
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: item.remotePath,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurface,
                    fontWeight: attention ? FontWeight.w600 : null,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: problem ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (uploading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: label),
                ...actions,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(spacing: 4, children: actions),
              ),
            ],
          ),
        );
      },
    );
  }
}
