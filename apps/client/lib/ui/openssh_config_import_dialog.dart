import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../import/openssh_config_import.dart';
import 'app_motion.dart';
import '../l10n/l10n.dart';

const _uuid = Uuid();

typedef OpenSshConfigBytesPicker = Future<Uint8List?> Function();

Future<int?> showOpenSshConfigImportDialog(
  BuildContext context, {
  required AppController app,
}) => showAppDialog<int>(
  context: context,
  builder: (_) => OpenSshConfigImportDialog(app: app),
);

/// Preview and explicitly import a bounded, non-executing SSH config subset.
class OpenSshConfigImportDialog extends StatefulWidget {
  const OpenSshConfigImportDialog({
    required this.app,
    this.pickBytesForTesting,
    super.key,
  });

  final AppController app;

  @visibleForTesting
  final OpenSshConfigBytesPicker? pickBytesForTesting;

  @override
  State<OpenSshConfigImportDialog> createState() =>
      _OpenSshConfigImportDialogState();
}

class _OpenSshConfigImportDialogState extends State<OpenSshConfigImportDialog> {
  OpenSshConfigParseResult? _parsed;
  _OpenSshImportPlan? _plan;
  String? _fileName;
  String? _error;
  bool _busy = false;

  AppController get app => widget.app;

  Future<Uint8List?> _pickBytes() async {
    final injected = widget.pickBytesForTesting;
    if (injected != null) return injected();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    if (file.size > maxOpenSshConfigBytes) {
      final bytes = file.bytes;
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.theSelectedConfigExceedsThe1);
    }
    final bytes = file.bytes;
    if (bytes == null || bytes.length != file.size) {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.theSelectedConfigCouldNotBe);
    }
    _fileName = file.name;
    return bytes;
  }

  Future<void> _chooseFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _parsed = null;
      _plan = null;
      _fileName = null;
    });
    Uint8List? bytes;
    try {
      bytes = await _pickBytes();
      if (!mounted || bytes == null) return;
      if (bytes.length > maxOpenSshConfigBytes) {
        throw FormatException(context.l10n.theSelectedConfigExceedsThe1);
      }
      final source = utf8.decode(bytes, allowMalformed: false);
      final result = OpenSshConfigImporter.parse(source);
      if (!mounted) return;
      setState(() {
        _parsed = result;
        _plan = _buildPlan(result);
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = context.l10n.theConfigFileCouldNotBe);
      }
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => _busy = false);
    }
  }

  _OpenSshImportPlan _buildPlan(OpenSshConfigParseResult parsed) {
    final existingByName = <String, List<HostRecord>>{};
    for (final host in app.hosts) {
      existingByName
          .putIfAbsent(_normalizeName(host.name), () => <HostRecord>[])
          .add(host);
    }
    final candidates = <String, HostRecord>{};
    final conflicts = <String, HostRecord>{};
    final ambiguous = <String>{};
    final idByAlias = <String, String>{};

    for (final configHost in parsed.hosts) {
      final key = _normalizeName(configHost.alias);
      final existing = existingByName[key] ?? const <HostRecord>[];
      if (existing.length == 1) {
        conflicts[key] = existing.single;
        idByAlias[key] = existing.single.id;
      } else if (existing.length > 1) {
        ambiguous.add(key);
      } else if (configHost.canImport && !parsed.blocksWholeFile) {
        idByAlias[key] = _uuid.v4();
      }
    }

    final rowIssues = <String, List<String Function()>>{};
    for (final configHost in parsed.hosts) {
      final key = _normalizeName(configHost.alias);
      if (!configHost.canImport || parsed.blocksWholeFile) continue;
      if (conflicts.containsKey(key) || ambiguous.contains(key)) continue;

      String? jumpId;
      final jumpAlias = configHost.proxyJumpAlias;
      if (jumpAlias != null) {
        final jumpKey = _normalizeName(jumpAlias);
        if (ambiguous.contains(jumpKey)) {
          _appendIssue(
            rowIssues,
            key,
            () => currentL10n.sshImportJumpAmbiguous(
              configHost.fieldLines['ProxyJump']!,
            ),
          );
          continue;
        }
        jumpId = idByAlias[jumpKey];
        if (jumpId == null) {
          _appendIssue(
            rowIssues,
            key,
            () => currentL10n.sshImportJumpMissing(
              configHost.fieldLines['ProxyJump']!,
            ),
          );
          continue;
        }
        if (jumpId == idByAlias[key]) {
          _appendIssue(
            rowIssues,
            key,
            () => currentL10n.sshImportJumpSelf(
              configHost.fieldLines['ProxyJump']!,
            ),
          );
          continue;
        }
      }

      candidates[key] = HostRecord(
        id: idByAlias[key]!,
        name: configHost.alias,
        address: configHost.address,
        port: configHost.port,
        username: configHost.username!,
        jumpHostId: jumpId,
      );
    }

    final plannedGraph = <String, String?>{
      for (final host in app.hosts) host.id: host.jumpHostId,
      for (final host in candidates.values) host.id: host.jumpHostId,
    };
    for (final entry in candidates.entries.toList()) {
      final issue = _validateJumpChain(entry.value.id, plannedGraph);
      if (issue != null) {
        _appendIssue(
          rowIssues,
          entry.key,
          () => _validateJumpChain(entry.value.id, plannedGraph)!,
        );
        candidates.remove(entry.key);
      }
    }

    final rows = <_OpenSshPreviewRow>[];
    for (final configHost in parsed.hosts) {
      final key = _normalizeName(configHost.alias);
      final host = candidates[key];
      final existing = conflicts[key];
      String Function()? disposition;
      if (parsed.blocksWholeFile) {
        disposition = () => currentL10n.sshImportBlockedFile;
      } else if (ambiguous.contains(key)) {
        disposition = () => currentL10n.sshImportAmbiguousName;
      } else if (existing != null) {
        disposition = () => currentL10n.sshImportSavedName(existing.name);
      } else if (rowIssues.containsKey(key)) {
        disposition = () => rowIssues[key]!.map((issue) => issue()).join(' ');
      } else if (!configHost.canImport) {
        disposition = () => currentL10n.sshImportBlockedHost;
      } else if (host == null) {
        disposition = () => currentL10n.sshImportNotImportable;
      }
      rows.add(
        _OpenSshPreviewRow(
          config: configHost,
          host: host,
          disposition: disposition,
        ),
      );
    }
    return _OpenSshImportPlan(rows: rows);
  }

  String? _validateJumpChain(String startId, Map<String, String?> graph) {
    final seen = <String>{};
    var current = startId;
    var hops = 0;
    while (true) {
      if (!seen.add(current)) {
        return context.l10n.thisProxyjumpChainContainsACycle;
      }
      final next = graph[current];
      if (next == null) return null;
      hops++;
      if (hops > maxJumpHostHops) {
        return context.l10n.thisProxyjumpChainExceedsTheMaxjumphosthops(
          maxJumpHostHops,
        );
      }
      if (!graph.containsKey(next)) {
        return context.l10n.thisProxyjumpChainPointsToA;
      }
      current = next;
    }
  }

  void _appendIssue(
    Map<String, List<String Function()>> issues,
    String key,
    String Function() issue,
  ) {
    issues.putIfAbsent(key, () => <String Function()>[]).add(issue);
  }

  Future<void> _confirmAndImport() async {
    final plan = _plan;
    final parsed = _parsed;
    if (_busy || plan == null || parsed == null || !parsed.canImportAny) return;
    if (app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active') {
      setState(() => _error = context.l10n.theActiveVaultIsReadOnly);
      return;
    }
    final importable = plan.rows.where((row) => row.host != null).toList();
    if (importable.isEmpty) return;
    final approved = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('openssh_config_confirm_dialog'),
        title: Text(context.l10n.importTheseHosts),
        content: Text(
          context.l10n.createCountEncryptedHostRecordS(importable.length),
        ),
        actions: [
          TextButton(
            key: const ValueKey('openssh_config_confirm_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('openssh_config_confirm_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirmImport),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final pending = importable.map((row) => row.host!).toList();
    final startingVaultId = app.activeVault?.id;
    var savedCount = 0;
    final savedIds = <String>{};
    try {
      while (pending.isNotEmpty) {
        if (startingVaultId == null || app.activeVault?.id != startingVaultId) {
          throw FormatException(currentL10n.theActiveVaultChangedDuringImport);
        }
        final readyIndex = pending.indexWhere((host) {
          final jumpId = host.jumpHostId;
          return jumpId == null ||
              app.hosts.any((saved) => saved.id == jumpId) ||
              savedIds.contains(jumpId);
        });
        if (readyIndex < 0) {
          throw FormatException(currentL10n.proxyjumpReferencesCouldNotBeSaved);
        }
        final host = pending.removeAt(readyIndex);
        await app.saveHost(host);
        savedCount++;
        savedIds.add(host.id);
        if (app.activeVault?.id != startingVaultId) {
          throw FormatException(currentL10n.theActiveVaultChangedDuringImport);
        }
      }
      if (mounted) Navigator.pop(context, savedCount);
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              '$savedCount Host(s) were saved before an error. Review the Hosts page before retrying; saved records are never overwritten by this importer.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final plan = _plan;
    final count = plan?.rows.where((row) => row.host != null).length ?? 0;
    final dialogWidth = MediaQuery.sizeOf(context).width - 48;
    return AlertDialog(
      scrollable: true,
      title: Text(context.l10n.importOpensshConfig),
      content: SizedBox(
        width: dialogWidth < 620 ? dialogWidth : 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.reviewLiteralHostAliasesHostnameUser),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('openssh_config_pick_file'),
                onPressed: _busy ? null : _chooseFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(_fileName ?? context.l10n.chooseSshConfigFile),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('openssh_config_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (parsed != null) ...[
              const SizedBox(height: 12),
              Text(
                parsed.blocksWholeFile
                    ? context.l10n.reviewBlockedNoRecordsCanBe
                    : context.l10n.sshImportPreviewCounts(count),
                key: const ValueKey('openssh_config_preview_summary'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (parsed.issues.isNotEmpty)
                _IssuesPanel(
                  issues: parsed.issues,
                  key: const ValueKey('openssh_config_file_issues'),
                ),
              if (plan != null && plan.rows.isNotEmpty)
                Column(
                  key: const ValueKey('openssh_config_preview'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < plan.rows.length; index++) ...[
                      if (index > 0) const Divider(height: 1),
                      _HostPreviewTile(row: plan.rows[index]),
                    ],
                  ],
                ),
              if (plan != null && plan.rows.isEmpty)
                Text(context.l10n.noConcreteHostAliasesWereFound),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('openssh_config_close'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
        FilledButton.icon(
          key: const ValueKey('openssh_config_import'),
          onPressed: _busy || count == 0 || parsed?.blocksWholeFile != false
              ? null
              : _confirmAndImport,
          icon: const Icon(Icons.download_done_outlined),
          label: Text(
            count == 0
                ? context.l10n.importHosts
                : context.l10n.importCountHosts(count),
          ),
        ),
      ],
    );
  }

  String _normalizeName(String value) => value.trim().toLowerCase();
}

class _OpenSshImportPlan {
  const _OpenSshImportPlan({required this.rows});

  final List<_OpenSshPreviewRow> rows;
}

class _OpenSshPreviewRow {
  const _OpenSshPreviewRow({
    required this.config,
    required this.host,
    required String Function()? disposition,
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : _disposition = disposition;

  final OpenSshConfigHost config;
  final HostRecord? host;
  final String Function()? _disposition;
  String? get disposition => _disposition?.call();
}

class _HostPreviewTile extends StatelessWidget {
  const _HostPreviewTile({required this.row});

  final _OpenSshPreviewRow row;

  @override
  Widget build(BuildContext context) {
    final config = row.config;
    final lines = <String>[
      context.l10n.importSshEndpointLine(
        config.hostLine,
        config.username ?? context.l10n.importUsernameMissing,
        config.address,
        config.port,
      ),
      if (config.proxyJumpAlias != null)
        context.l10n.importProxyJumpLine(
          config.proxyJumpAlias!,
          config.fieldLines['ProxyJump']!,
        ),
      for (final issue in config.issues)
        context.l10n.lineLineMessage(issue.line, issue.message),
      if (row.disposition != null) row.disposition!,
    ];
    return ListTile(
      key: ValueKey('openssh_config_host_${config.alias}'),
      leading: Icon(
        row.host == null ? Icons.info_outline : Icons.dns_outlined,
        color: row.host == null ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(config.alias),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 1,
      dense: true,
    );
  }
}

class _IssuesPanel extends StatelessWidget {
  const _IssuesPanel({required this.issues, super.key});

  final List<OpenSshConfigIssue> issues;

  @override
  Widget build(BuildContext context) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final issue in issues.take(12))
          Text(context.l10n.lineLineMessage(issue.line, issue.message)),
        if (issues.length > 12)
          Text(
            context.l10n.valuevalueAdditionalFindingsAreHidden(
              issues.length - 12,
            ),
          ),
      ],
    ),
  );
}
