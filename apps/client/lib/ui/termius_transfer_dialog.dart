import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../import/openssh_config_import.dart';
import '../import/termius_csv.dart';
import '../import/termius_export_file.dart';
import '../import/termius_openssh.dart';
import '../import/termius_openssh_bundle.dart';
import '../import/termius_transfer.dart';
import '../import/termius_transfer_target.dart';
import '../l10n/l10n.dart';
import 'app_motion.dart';

enum TermiusTransferMode { importData, exportData }

class TermiusTransferOutcome {
  const TermiusTransferOutcome({
    this.importedHosts = 0,
    this.createdGroups = 0,
    this.exported = false,
  });

  final int importedHosts;
  final int createdGroups;
  final bool exported;
}

enum TermiusImportSource { csv, openSshConfig, openSshBundle }

/// Returns picked file bytes and display name, or null when cancelled.
typedef TermiusBytesPicker =
    Future<({Uint8List bytes, String name})?> Function(
      TermiusImportSource source,
    );

/// Saves an export; returns false when the user cancelled the picker.
typedef TermiusExportSaver =
    Future<bool> Function({
      required String fileName,
      required Uint8List bytes,
      required bool containsSecrets,
    });

Future<TermiusTransferOutcome?> showTermiusTransferDialog(
  BuildContext context, {
  required TermiusTransferTarget target,
  TermiusTransferMode initialMode = TermiusTransferMode.importData,
  TermiusCertificateBridge? certificates,
}) => showAppDialog<TermiusTransferOutcome>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TermiusTransferDialog(
    target: target,
    initialMode: initialMode,
    certificates: certificates,
  ),
);

const _maxPreviewRows = 200;

/// Termius CSV / OpenSSH import with preview and explicit apply, and
/// CSV / OpenSSH export with opt-in secrets.
class TermiusTransferDialog extends StatefulWidget {
  const TermiusTransferDialog({
    required this.target,
    this.initialMode = TermiusTransferMode.importData,
    this.certificates,
    this.pickBytesForTesting,
    this.saveForTesting,
    super.key,
  });

  final TermiusTransferTarget target;
  final TermiusTransferMode initialMode;

  /// Keychain certificate hook (navigation branch); null = not supported.
  final TermiusCertificateBridge? certificates;

  @visibleForTesting
  final TermiusBytesPicker? pickBytesForTesting;

  @visibleForTesting
  final TermiusExportSaver? saveForTesting;

  @override
  State<TermiusTransferDialog> createState() => _TermiusTransferDialogState();
}

class _TermiusTransferDialogState extends State<TermiusTransferDialog> {
  late TermiusTransferMode _mode = widget.target.canWrite
      ? widget.initialMode
      : TermiusTransferMode.exportData;
  bool _busy = false;
  String? _error;
  String? _notice;

  // Import state.
  TermiusImportDocument? _document;
  TermiusImportPlan? _plan;
  TermiusCatalog? _catalog;
  String? _fileName;
  var _duplicates = TermiusDuplicatePolicy.skip;
  final _excluded = <int>{};

  // Export state.
  var _exportFormat = TermiusExportFormat.csv;
  var _includePasswords = false;
  var _includeKeys = false;
  var _includeDesktops = false;
  TermiusCatalog? _exportCatalog;

  TermiusTransferTarget get target => widget.target;

  @override
  void initState() {
    super.initState();
    if (_mode == TermiusTransferMode.exportData) _loadExportCatalog();
  }

  Future<void> _loadExportCatalog() async {
    try {
      final catalog = await target.loadCatalog();
      if (mounted) setState(() => _exportCatalog = catalog);
    } on Object {
      if (mounted) setState(() => _error = context.l10n.r7ImportFileUnreadable);
    }
  }

  Future<({Uint8List bytes, String name})?> _pick(
    TermiusImportSource source,
  ) async {
    final injected = widget.pickBytesForTesting;
    if (injected != null) return injected(source);
    final limit = switch (source) {
      TermiusImportSource.csv => maxTermiusCsvBytes,
      TermiusImportSource.openSshConfig => maxOpenSshConfigBytes,
      TermiusImportSource.openSshBundle => maxTermiusBundleBytes,
    };
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes;
    if (file.size > limit || bytes == null || bytes.length != file.size) {
      throw const FormatException('unreadable');
    }
    return (bytes: bytes, name: file.name);
  }

  Future<void> _chooseFile(TermiusImportSource source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _document = null;
      _plan = null;
      _fileName = null;
      _excluded.clear();
    });
    Uint8List? bytes;
    try {
      final picked = await _pick(source);
      if (!mounted || picked == null) return;
      // Platform channels may return a read-only view. Own a mutable copy so
      // cleanup never modifies plugin storage or prevents resetting _busy.
      bytes = Uint8List.fromList(picked.bytes);
      final document = switch (source) {
        TermiusImportSource.csv => TermiusCsvImporter.parseBytes(bytes),
        TermiusImportSource.openSshConfig =>
          TermiusOpenSshImporter.parseBytes(bytes),
        TermiusImportSource.openSshBundle =>
          TermiusOpenSshBundleImporter.parseZip(bytes),
      };
      final catalog = await target.loadCatalog();
      if (!mounted) return;
      setState(() {
        _fileName = picked.name;
        _document = document;
        _catalog = catalog;
        _replan();
      });
    } on Object {
      if (mounted) setState(() => _error = context.l10n.r7ImportFileUnreadable);
    } finally {
      // Wipe our plaintext copy; the picker owns the original buffer.
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => _busy = false);
    }
  }

  void _replan() {
    final document = _document;
    final catalog = _catalog;
    if (document == null || catalog == null) {
      _plan = null;
      return;
    }
    _plan = TermiusImportPlanner.plan(
      document,
      catalog,
      duplicates: _duplicates,
      excludedRows: _excluded,
      certificates: widget.certificates,
    );
  }

  Future<void> _confirmAndApply() async {
    final plan = _plan;
    if (_busy || plan == null || !plan.canApply) return;
    final l10n = context.l10n;
    final approved = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('termius_import_confirm_dialog'),
        title: Text(l10n.r7ImportConfirmTitle),
        content: Text(
          l10n.r7ImportConfirmBody(
            plan.createCount,
            plan.newGroups.length,
            plan.secretCount,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('termius_import_confirm_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('termius_import_confirm_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.r7ImportConfirmAccept),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await target.apply(plan);
      if (!mounted) return;
      Navigator.pop(
        context,
        TermiusTransferOutcome(
          importedHosts: report.createdHosts,
          createdGroups: report.createdGroups,
        ),
      );
    } on TermiusApplyException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.failure) {
          TermiusApplyFailure.readOnly => l10n.r7ImportFailReadOnly,
          TermiusApplyFailure.stalePlan => l10n.r7ImportFailStale,
          TermiusApplyFailure.contextChanged => l10n.r7ImportFailScopeChanged,
          _ when error.mutatedTarget => l10n.r7ImportFailPartial(
            error.writtenHosts,
            error.writtenGroups,
            error.writtenCredentials,
          ),
          _ => l10n.r7ImportFailRolledBack,
        };
        if (error.failure == TermiusApplyFailure.stalePlan) {
          _document = null;
          _plan = null;
          _fileName = null;
        }
      });
    } on Object {
      if (mounted) setState(() => _error = l10n.r7ImportFailRolledBack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  TermiusExportOptions get _exportOptions => TermiusExportOptions(
    includePasswords:
        _exportFormat == TermiusExportFormat.csv && _includePasswords,
    includePrivateKeys:
        _exportFormat == TermiusExportFormat.openSshBundle && _includeKeys,
    includeRemoteDesktops:
        _exportFormat == TermiusExportFormat.csv && _includeDesktops,
  );

  TermiusExportResult? _exportPreview() {
    final catalog = _exportCatalog;
    if (catalog == null) return null;
    final certificates = widget.certificates;
    return switch (_exportFormat) {
      TermiusExportFormat.csv => TermiusExporter.csv(
        catalog,
        options: _exportOptions,
        certificates: certificates,
      ),
      TermiusExportFormat.openSsh => TermiusExporter.openSsh(
        catalog,
        options: _exportOptions,
        certificates: certificates,
      ),
      TermiusExportFormat.openSshBundle => TermiusOpenSshBundleExporter.export(
        catalog,
        options: _exportOptions,
        certificates: certificates,
      ),
    };
  }

  Future<void> _export() async {
    if (_busy) return;
    final l10n = context.l10n;
    final result = _exportPreview();
    if (result == null || result.exportedHosts == 0 || result.blocked) return;
    if (result.containsSecrets) {
      final approved = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('termius_export_secret_confirm_dialog'),
          icon: const Icon(Icons.warning_amber_rounded),
          title: Text(l10n.r7ImportExportSecretConfirmTitle),
          content: Text(l10n.r7ImportExportSecretConfirmBody),
          actions: [
            TextButton(
              key: const ValueKey('termius_export_secret_confirm_cancel'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel2),
            ),
            FilledButton(
              key: const ValueKey('termius_export_secret_confirm_accept'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.r7ImportExportSecretConfirmAccept),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final save = widget.saveForTesting ?? saveTermiusExportFile;
      final saved = await save(
        fileName: result.suggestedFileName,
        bytes: result.bytes,
        containsSecrets: result.containsSecrets,
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context, const TermiusTransferOutcome(exported: true));
      } else {
        setState(() => _notice = l10n.r7ImportExportCancelled);
      }
    } on Object {
      if (mounted) setState(() => _error = l10n.r7ImportExportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMode(TermiusTransferMode mode) {
    if (_busy || mode == _mode) return;
    setState(() {
      _mode = mode;
      _error = null;
      _notice = null;
    });
    if (mode == TermiusTransferMode.exportData) _loadExportCatalog();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = MediaQuery.sizeOf(context).width - 48;
    final plan = _plan;
    final importing = _mode == TermiusTransferMode.importData;
    final export = importing ? null : _exportPreview();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const ValueKey('termius_transfer_dialog'),
        scrollable: true,
        title: Text(l10n.r7ImportTransferTitle),
        content: SizedBox(
          width: width < 680 ? width : 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<TermiusTransferMode>(
                segments: [
                  ButtonSegment(
                    value: TermiusTransferMode.importData,
                    enabled: target.canWrite,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      l10n.r7ImportModeImport,
                      key: const ValueKey('termius_mode_import'),
                    ),
                  ),
                  ButtonSegment(
                    value: TermiusTransferMode.exportData,
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(
                      l10n.r7ImportModeExport,
                      key: const ValueKey('termius_mode_export'),
                    ),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => _setMode(selection.single),
              ),
              const SizedBox(height: 12),
              if (!target.canWrite) ...[
                Text(l10n.r7ImportReadOnly),
                const SizedBox(height: 8),
              ],
              if (importing) ..._buildImport(context, plan),
              if (!importing) ..._buildExport(context, export),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 10),
                Text(_notice!, key: const ValueKey('termius_transfer_notice')),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const ValueKey('termius_transfer_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('termius_transfer_close'),
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
          if (importing)
            FilledButton.icon(
              key: const ValueKey('termius_import_apply'),
              onPressed: _busy || plan == null || !plan.canApply
                  ? null
                  : _confirmAndApply,
              icon: const Icon(Icons.download_done_outlined),
              label: Text(
                plan == null || plan.createCount == 0
                    ? l10n.r7ImportApplyNone
                    : l10n.r7ImportApply(plan.createCount),
              ),
            )
          else
            FilledButton.icon(
              key: const ValueKey('termius_export_save'),
              onPressed:
                  _busy ||
                      export == null ||
                      export.exportedHosts == 0 ||
                      export.blocked
                  ? null
                  : _export,
              icon: const Icon(Icons.save_alt_outlined),
              label: Text(l10n.r7ImportExportSave),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildImport(BuildContext context, TermiusImportPlan? plan) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final rows = plan?.rows ?? const <TermiusPlannedRow>[];
    int count(TermiusRowDisposition disposition) =>
        rows.where((row) => row.disposition == disposition).length;
    return [
      Text(l10n.r7ImportIntro),
      const SizedBox(height: 6),
      Text(l10n.r7ImportTemplateColumns, style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      Text(l10n.r7ImportNativeUnsupported, style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('termius_import_pick_csv'),
            onPressed: _busy ? null : () => _chooseFile(TermiusImportSource.csv),
            icon: const Icon(Icons.table_view_outlined),
            label: Text(l10n.r7ImportChooseCsv),
          ),
          OutlinedButton.icon(
            key: const ValueKey('termius_import_pick_openssh'),
            onPressed: _busy
                ? null
                : () => _chooseFile(TermiusImportSource.openSshConfig),
            icon: const Icon(Icons.description_outlined),
            label: Text(l10n.r7ImportChooseOpenSsh),
          ),
          OutlinedButton.icon(
            key: const ValueKey('termius_import_pick_bundle'),
            onPressed: _busy
                ? null
                : () => _chooseFile(TermiusImportSource.openSshBundle),
            icon: const Icon(Icons.folder_zip_outlined),
            label: Text(l10n.r7ImportChooseBundle),
          ),
        ],
      ),
      if (_fileName != null) ...[
        const SizedBox(height: 8),
        Text(_fileName!, style: theme.textTheme.labelMedium),
      ],
      if (plan != null) ...[
        const SizedBox(height: 12),
        Text(
          plan.blocksWholeFile
              ? l10n.r7ImportBlockedFile
              : l10n.r7ImportSummary(
                  plan.createCount,
                  plan.newGroups.length,
                  count(TermiusRowDisposition.skippedDuplicate) +
                      count(TermiusRowDisposition.skippedExisting) +
                      count(TermiusRowDisposition.excluded),
                  count(TermiusRowDisposition.blocked),
                ),
          key: const ValueKey('termius_import_summary'),
          style: theme.textTheme.titleSmall,
        ),
        if (plan.fileIssues.isNotEmpty) ...[
          const SizedBox(height: 8),
          _IssuePanel(
            key: const ValueKey('termius_import_file_issues'),
            issues: plan.fileIssues,
          ),
        ],
        if (!plan.blocksWholeFile && rows.isNotEmpty) ...[
          SwitchListTile(
            key: const ValueKey('termius_import_duplicates'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.r7ImportImportDuplicates),
            value: _duplicates == TermiusDuplicatePolicy.importAsNew,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _duplicates = value
                        ? TermiusDuplicatePolicy.importAsNew
                        : TermiusDuplicatePolicy.skip;
                    _replan();
                  }),
          ),
          Column(
            key: const ValueKey('termius_import_preview'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows.take(_maxPreviewRows))
                _RowTile(
                  row: row,
                  groupPath: _groupPathFor(row, plan),
                  excludable:
                      row.disposition == TermiusRowDisposition.create ||
                      row.disposition == TermiusRowDisposition.excluded,
                  onExcludedChanged: _busy
                      ? null
                      : (excluded) => setState(() {
                          if (excluded) {
                            _excluded.add(row.source.row);
                          } else {
                            _excluded.remove(row.source.row);
                          }
                          _replan();
                        }),
                ),
            ],
          ),
          if (rows.length > _maxPreviewRows)
            Text(l10n.r7ImportMoreRowsHidden(rows.length - _maxPreviewRows)),
        ],
      ],
    ];
  }

  String? _groupPathFor(TermiusPlannedRow row, TermiusImportPlan plan) =>
      row.source.groupPath.isEmpty ? null : row.source.groupPath.join(' / ');

  List<Widget> _buildExport(BuildContext context, TermiusExportResult? export) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final csv = _exportFormat == TermiusExportFormat.csv;
    final bundle = _exportFormat == TermiusExportFormat.openSshBundle;
    final secrets =
        _exportOptions.includePasswords || _exportOptions.includePrivateKeys;
    return [
      Text(l10n.r7ImportExportIntro),
      const SizedBox(height: 10),
      RadioGroup<TermiusExportFormat>(
        groupValue: _exportFormat,
        onChanged: (value) {
          if (_busy || value == null) return;
          setState(() => _exportFormat = value);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<TermiusExportFormat>(
              key: const ValueKey('termius_export_format_csv'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: TermiusExportFormat.csv,
              title: Text(l10n.r7ImportExportFormatCsv),
            ),
            RadioListTile<TermiusExportFormat>(
              key: const ValueKey('termius_export_format_openssh'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: TermiusExportFormat.openSsh,
              title: Text(l10n.r7ImportExportFormatOpenSsh),
            ),
            RadioListTile<TermiusExportFormat>(
              key: const ValueKey('termius_export_format_bundle'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: TermiusExportFormat.openSshBundle,
              title: Text(l10n.r7ImportExportFormatBundle),
              subtitle: Text(l10n.r7ImportExportBundleHelp),
            ),
          ],
        ),
      ),
      if (csv) ...[
        CheckboxListTile(
          key: const ValueKey('termius_export_include_desktops'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _includeDesktops,
          onChanged: _busy
              ? null
              : (value) => setState(() => _includeDesktops = value == true),
          title: Text(l10n.r7ImportExportIncludeDesktops),
        ),
        CheckboxListTile(
          key: const ValueKey('termius_export_include_secrets'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _includePasswords,
          onChanged: _busy
              ? null
              : (value) => setState(() => _includePasswords = value == true),
          title: Text(l10n.r7ImportExportIncludePasswords),
        ),
      ],
      if (bundle)
        CheckboxListTile(
          key: const ValueKey('termius_export_include_keys'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _includeKeys,
          onChanged: _busy
              ? null
              : (value) => setState(() => _includeKeys = value == true),
          title: Text(l10n.r7ImportExportIncludeKeys),
        ),
      if (!csv && !bundle)
        Text(
          l10n.r7ImportExportOpenSshNoSecrets,
          style: theme.textTheme.bodySmall,
        ),
      if (secrets)
          Container(
            key: const ValueKey('termius_export_secret_warning'),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              l10n.r7ImportExportSecretWarning,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
      if (export != null) ...[
        const SizedBox(height: 10),
        Text(
          l10n.r7ImportExportSummary(export.exportedHosts),
          key: const ValueKey('termius_export_summary'),
          style: theme.textTheme.titleSmall,
        ),
        if (export.issues.isNotEmpty) ...[
          const SizedBox(height: 6),
          _IssuePanel(
            key: const ValueKey('termius_export_issues'),
            issues: export.issues,
            warningOnly: !export.blocked,
          ),
        ],
      ],
    ];
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.row,
    required this.groupPath,
    required this.excludable,
    required this.onExcludedChanged,
  });

  final TermiusPlannedRow row;
  final String? groupPath;
  final bool excludable;
  final ValueChanged<bool>? onExcludedChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = row.source;
    final protocol = source.protocol?.label ?? '—';
    final port = source.port?.toString() ?? '—';
    final lines = <String>[
      source.username.isEmpty
          ? l10n.r7ImportRowEndpointNoUser(source.address, port, protocol)
          : l10n.r7ImportRowEndpoint(
              source.username,
              source.address,
              port,
              protocol,
            ),
      if (groupPath != null) l10n.r7ImportRowGroup(groupPath!),
      if (source.tags.isNotEmpty) l10n.r7ImportRowTags(source.tags.join(', ')),
      if (source.jumpAlias != null) l10n.r7ImportRowJump(source.jumpAlias!),
      if (source.forwards.isNotEmpty)
        l10n.r7ImportRowForwards(source.forwards.length),
      if (source.privateKey != null) l10n.r7ImportRowPrivateKey,
      if (source.password != null) l10n.r7ImportRowPassword,
      _dispositionText(l10n, row.disposition),
      for (final issue in row.issues) describeTermiusIssue(l10n, issue),
    ];
    final blocked = row.disposition == TermiusRowDisposition.blocked;
    return ListTile(
      key: ValueKey('termius_import_row_${source.row}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      isThreeLine: true,
      leading: excludable
          ? Checkbox(
              key: ValueKey('termius_import_row_include_${source.row}'),
              value: row.disposition == TermiusRowDisposition.create,
              onChanged: onExcludedChanged == null
                  ? null
                  : (value) => onExcludedChanged!(value != true),
            )
          : Icon(
              blocked ? Icons.error_outline : Icons.remove_circle_outline,
              color: blocked ? Theme.of(context).colorScheme.error : null,
            ),
      title: Text(source.label.isEmpty ? source.address : source.label),
      subtitle: Text(lines.join('\n')),
    );
  }

  static String _dispositionText(
    AppLocalizations l10n,
    TermiusRowDisposition disposition,
  ) => switch (disposition) {
    TermiusRowDisposition.create => l10n.r7ImportDispositionCreate,
    TermiusRowDisposition.skippedDuplicate => l10n.r7ImportDispositionDuplicate,
    TermiusRowDisposition.skippedExisting => l10n.r7ImportDispositionExisting,
    TermiusRowDisposition.blocked => l10n.r7ImportDispositionBlocked,
    TermiusRowDisposition.excluded => l10n.r7ImportDispositionExcluded,
  };
}

class _IssuePanel extends StatelessWidget {
  const _IssuePanel({
    required this.issues,
    this.warningOnly = false,
    super.key,
  });

  final List<TermiusIssue> issues;
  final bool warningOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocking = !warningOnly && issues.any((issue) => issue.blocking);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: blocking ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final issue in issues.take(20))
            Text(describeTermiusIssue(context.l10n, issue)),
          if (issues.length > 20)
            Text(context.l10n.r7ImportMoreIssuesHidden(issues.length - 20)),
        ],
      ),
    );
  }
}

/// Localized, secret-free text for one transfer finding.
String describeTermiusIssue(AppLocalizations l10n, TermiusIssue issue) {
  final name = issue.detail ?? '';
  final count = issue.count ?? 0;
  final message = switch (issue.code) {
    TermiusIssueCode.fileTooLarge => l10n.r7ImportIssueFileTooLarge,
    TermiusIssueCode.fileNotUtf8 => l10n.r7ImportIssueNotUtf8,
    TermiusIssueCode.csvStructure => switch (name) {
      'unterminatedQuote' => l10n.r7ImportIssueCsvUnterminatedQuote,
      'strayQuote' => l10n.r7ImportIssueCsvStrayQuote,
      'tooManyFields' => l10n.r7ImportIssueCsvTooManyFields,
      'fieldTooLong' => l10n.r7ImportIssueCsvFieldTooLong,
      'nulCharacter' => l10n.r7ImportIssueCsvNul,
      _ => l10n.r7ImportIssueCsvInvalid,
    },
    TermiusIssueCode.emptyFile => l10n.r7ImportIssueEmptyFile,
    TermiusIssueCode.missingHostnameColumn => l10n.r7ImportIssueMissingHostname,
    TermiusIssueCode.noTemplateHeader => l10n.r7ImportIssueNoTemplateHeader,
    TermiusIssueCode.nonTemplateColumn => l10n.r7ImportIssueNonTemplateColumn(
      name,
    ),
    TermiusIssueCode.headerOrderNotTermius =>
      l10n.r7ImportIssueHeaderOrderNotTermius,
    TermiusIssueCode.moshImportedAsSsh => l10n.r7ImportIssueMoshAsSsh,
    TermiusIssueCode.duplicateHeader => l10n.r7ImportIssueDuplicateHeader(name),
    TermiusIssueCode.unknownHeader => l10n.r7ImportIssueUnknownHeader(name),
    TermiusIssueCode.tooManyRows => l10n.r7ImportIssueTooManyRows(
      issue.count ?? maxTermiusImportRows,
    ),
    TermiusIssueCode.extraFields => l10n.r7ImportIssueExtraFields,
    TermiusIssueCode.missingFields => l10n.r7ImportIssueMissingFields,
    TermiusIssueCode.controlCharacter => l10n.r7ImportIssueControlCharacter,
    TermiusIssueCode.missingAddress => l10n.r7ImportIssueMissingAddress,
    TermiusIssueCode.invalidAddress => l10n.r7ImportIssueInvalidAddress,
    TermiusIssueCode.invalidLabel => l10n.r7ImportIssueInvalidLabel,
    TermiusIssueCode.invalidPort => l10n.r7ImportIssueInvalidPort,
    TermiusIssueCode.unsupportedProtocol =>
      l10n.r7ImportIssueUnsupportedProtocol(name),
    TermiusIssueCode.extensionProtocol => l10n.r7ImportIssueExtensionProtocol(
      name,
    ),
    TermiusIssueCode.missingUsername => l10n.r7ImportIssueMissingUsername,
    TermiusIssueCode.invalidUsername => l10n.r7ImportIssueInvalidUsername,
    TermiusIssueCode.invalidPassword => l10n.r7ImportIssueInvalidPassword,
    TermiusIssueCode.invalidPrivateKey => l10n.r7ImportIssueInvalidPrivateKey,
    TermiusIssueCode.sshKeyNotInline => l10n.r7ImportIssueSshKeyNotInline,
    TermiusIssueCode.passwordDroppedForKey =>
      l10n.r7ImportIssuePasswordDroppedForKey,
    TermiusIssueCode.credentialsIgnoredForProtocol =>
      l10n.r7ImportIssueKeyIgnoredForProtocol,
    TermiusIssueCode.invalidGroup => l10n.r7ImportIssueInvalidGroup,
    TermiusIssueCode.emptyGroupSegment => l10n.r7ImportIssueEmptyGroupSegment,
    TermiusIssueCode.groupTooDeep => l10n.r7ImportIssueGroupTooDeep(count),
    TermiusIssueCode.invalidTag => l10n.r7ImportIssueInvalidTag,
    TermiusIssueCode.duplicateTagDropped => l10n.r7ImportIssueDuplicateTags(
      count,
    ),
    TermiusIssueCode.unknownColumnValue => l10n.r7ImportIssueUnknownColumnValue(
      name,
    ),
    TermiusIssueCode.duplicateInFile => l10n.r7ImportIssueDuplicateInFile(
      issue.row ?? 0,
    ),
    TermiusIssueCode.alreadyExists => l10n.r7ImportIssueAlreadyExists(name),
    TermiusIssueCode.nameAlreadyUsed => l10n.r7ImportIssueNameAlreadyUsed,
    TermiusIssueCode.excludedByUser => l10n.r7ImportDispositionExcluded,
    TermiusIssueCode.invalidRecord => l10n.r7ImportIssueInvalidRecord,
    TermiusIssueCode.sshParserFinding => l10n.r7ImportIssueSshFinding(
      name.isEmpty ? 'config' : name,
      issue.messageBuilder?.call() ?? l10n.r7ImportIssueSshBlocked,
    ),
    TermiusIssueCode.sshOptionIgnored => l10n.r7ImportIssueSshOptionIgnored(
      name,
    ),
    TermiusIssueCode.sshHostKeyPolicyIgnored =>
      l10n.r7ImportIssueSshHostKeyPolicyIgnored(name),
    TermiusIssueCode.sshForwardBlocked => l10n.r7ImportIssueSshForwardBlocked(
      name,
    ),
    TermiusIssueCode.sshJumpMissing => l10n.r7ImportIssueSshJumpMissing(name),
    TermiusIssueCode.sshJumpCycle => l10n.r7ImportIssueSshJumpCycle,
    TermiusIssueCode.certificateNotStored =>
      l10n.r7ImportIssueCertificateNotStored,
    TermiusIssueCode.certificateWithoutKey =>
      l10n.r7ImportIssueCertificateWithoutKey,
    TermiusIssueCode.bundleKeyMissing => l10n.r7ImportIssueBundleKeyMissing,
    TermiusIssueCode.bundleKeyInvalid => l10n.r7ImportIssueBundleKeyInvalid,
    TermiusIssueCode.bundleIdentityExtra => l10n.r7ImportIssueBundleIdentityExtra(
      name,
    ),
    TermiusIssueCode.bundleCertificateMissing =>
      l10n.r7ImportIssueBundleCertificateMissing,
    TermiusIssueCode.bundleEntryRejected => l10n.r7ImportIssueBundleEntryRejected(
      name,
    ),
    TermiusIssueCode.bundleTooLarge => l10n.r7ImportIssueBundleTooLarge,
    TermiusIssueCode.bundleInvalid => l10n.r7ImportIssueBundleInvalid,
    TermiusIssueCode.bundleConfigMissing => l10n.r7ImportIssueBundleConfigMissing,
    TermiusIssueCode.bundleConfigAmbiguous =>
      l10n.r7ImportIssueBundleConfigAmbiguous,
    TermiusIssueCode.exportCertificatesNotRepresented =>
      l10n.r7ImportIssueExportCertificatesNotRepresented(count),
    TermiusIssueCode.exportPassphraseNotExported =>
      l10n.r7ImportIssueExportPassphraseNotExported(count),
    TermiusIssueCode.exportPasswordsNotRepresented =>
      l10n.r7ImportIssueExportPasswordsNotRepresented(count),
    TermiusIssueCode.exportTooLarge => l10n.r7ImportIssueExportTooLarge,
    TermiusIssueCode.exportKeysOmitted => l10n.r7ImportIssueExportKeysOmitted(
      count,
    ),
    TermiusIssueCode.exportCertificatesOmitted =>
      l10n.r7ImportIssueExportCertificatesOmitted(count),
    TermiusIssueCode.exportSkippedProtocol =>
      l10n.r7ImportIssueExportSkippedProtocol(count),
    TermiusIssueCode.exportGroupSlash => l10n.r7ImportIssueExportGroupSlash(
      name,
    ),
    TermiusIssueCode.exportTagComma => l10n.r7ImportIssueExportTagComma(name),
    TermiusIssueCode.exportGroupWhitespace =>
      l10n.r7ImportIssueExportGroupWhitespace(name),
    TermiusIssueCode.exportFormulaRisk => l10n.r7ImportIssueExportFormulaRisk(
      count,
    ),
    TermiusIssueCode.exportKeysNotRepresented =>
      l10n.r7ImportIssueExportKeysNotRepresented(count),
    TermiusIssueCode.exportJumpNotRepresented =>
      issue.detail == null
          ? l10n.r7ImportIssueExportJumpCount(count)
          : l10n.r7ImportIssueExportJumpHost(name),
    TermiusIssueCode.exportForwardsNotRepresented =>
      l10n.r7ImportIssueExportForwards(count),
    TermiusIssueCode.exportSharedCredentialSkipped =>
      l10n.r7ImportIssueExportSharedCredential(count),
    TermiusIssueCode.exportSecretsOmitted =>
      l10n.r7ImportIssueExportSecretsOmitted(count),
    TermiusIssueCode.exportAliasRewritten =>
      l10n.r7ImportIssueExportAliasRewritten(name),
    TermiusIssueCode.exportHostSkipped => l10n.r7ImportIssueExportHostSkipped(
      name,
    ),
  };
  final line = issue.line;
  return line == null ? message : l10n.r7ImportIssueAtLine(line, message);
}
