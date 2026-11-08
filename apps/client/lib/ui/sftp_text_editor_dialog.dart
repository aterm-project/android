import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../sftp/sftp_text_editor_service.dart';
import 'app_motion.dart';
import '../l10n/l10n.dart';

class SftpTextEditorDialog extends StatefulWidget {
  const SftpTextEditorDialog({
    required this.document,
    this.app,
    this.saveDocument,
    this.errorText,
    super.key,
  }) : assert(app != null || saveDocument != null);

  final AppController? app;
  final SftpTextDocument document;
  final Future<SftpTextSaveResult> Function(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
    String? saveAsName,
  })?
  saveDocument;
  final String Function(Object error)? errorText;

  @override
  State<SftpTextEditorDialog> createState() => _SftpTextEditorDialogState();
}

class _SftpTextEditorDialogState extends State<SftpTextEditorDialog> {
  late final TextEditingController _content;
  SftpTextDocument? _conflictDocument;
  bool _saving = false;
  bool _nestedDialogOpen = false;
  bool _closingForDisconnect = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.document.text);
    widget.app?.addListener(_handleAppChanged);
  }

  @override
  void dispose() {
    widget.app?.removeListener(_handleAppChanged);
    _content.clear();
    _content.dispose();
    widget.document.dispose();
    _conflictDocument?.dispose();
    super.dispose();
  }

  void _handleAppChanged() {
    final app = widget.app;
    if (app == null) return;
    final sourceConnection = app
        .terminalTabFor(widget.document.sessionId)
        ?.connection;
    if (!mounted ||
        sourceConnection != null ||
        (widget.document.sessionId == null && app.terminalConnection != null) ||
        _closingForDisconnect) {
      return;
    }
    _closingForDisconnect = true;
    _content.clear();
    _clearConflictDocument();
    final navigator = Navigator.of(context, rootNavigator: true);
    final editorRoute = ModalRoute.of(context);
    final closeEditorAfterChild =
        _nestedDialogOpen && editorRoute?.isCurrent != true;
    navigator.pop();
    if (closeEditorAfterChild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && navigator.canPop()) navigator.pop();
      });
    }
  }

  Future<T?> _showNestedDialog<T>({required WidgetBuilder builder}) async {
    _nestedDialogOpen = true;
    try {
      return await showAppDialog<T>(context: context, builder: builder);
    } finally {
      _nestedDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(context.l10n.editRemoteTextFile),
      content: SizedBox(
        width: (size.width - 64).clamp(280.0, 1000.0).toDouble(),
        height: (size.height - 220).clamp(240.0, 660.0).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.document.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _content,
                autofocus: true,
                expands: true,
                minLines: null,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: context.l10n.remoteFileContents,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.utf8TextUpTo10,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel2),
        ),
        OutlinedButton(
          onPressed: _saving ? null : _saveAs,
          child: Text(context.l10n.saveAs),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.save),
        ),
      ],
    );
  }

  Future<void> _save() async {
    await _saveWithConflictResolution();
  }

  Future<void> _saveAs() async {
    final name = await _askSaveAsName();
    if (name == null) return;
    await _saveAsName(name);
  }

  Future<void> _saveWithConflictResolution() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    Uint8List? approvedRemoteVersion;
    try {
      while (mounted) {
        final result = await _saveDocument(
          widget.document,
          _content.text,
          expectedRemoteBytes: approvedRemoteVersion,
        );
        approvedRemoteVersion?.fillRange(0, approvedRemoteVersion.length, 0);
        approvedRemoteVersion = null;

        if (result is SftpTextSaveSuccess) {
          result.document.dispose();
          if (mounted) Navigator.of(context).pop();
          return;
        }

        final latest = (result as SftpTextRemoteChanged).latestDocument;
        _replaceConflictDocument(latest);
        while (mounted) {
          final choice = await _chooseConflictAction();
          switch (choice) {
            case _ConflictAction.compare:
              await _showComparison(latest);
              continue;
            case _ConflictAction.overwrite:
              approvedRemoteVersion = latest.originalBytes;
              _clearConflictDocument();
              break;
            case _ConflictAction.saveAs:
              final name = await _askSaveAsName();
              if (name == null) continue;
              final saved = await _saveAsName(name, keepBusy: true);
              if (saved) return;
              return;
            case _ConflictAction.cancel:
            case null:
              _clearConflictDocument();
              return;
          }
          break;
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _friendlyError(error));
      }
    } finally {
      approvedRemoteVersion?.fillRange(0, approvedRemoteVersion.length, 0);
      _clearConflictDocument();
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveAsName(String name, {bool keepBusy = false}) async {
    if (!keepBusy) {
      setState(() {
        _saving = true;
        _error = null;
      });
    }
    try {
      final result = await _saveDocument(
        widget.document,
        _content.text,
        saveAsName: name,
      );
      if (result is SftpTextSaveSuccess) {
        result.document.dispose();
        if (mounted) Navigator.of(context).pop();
        return true;
      }
      final latest = (result as SftpTextRemoteChanged).latestDocument;
      _replaceConflictDocument(latest);
      return false;
    } catch (error) {
      if (mounted) {
        setState(() => _error = _friendlyError(error));
      }
      return false;
    } finally {
      if (!keepBusy && mounted) setState(() => _saving = false);
    }
  }

  Future<SftpTextSaveResult> _saveDocument(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
    String? saveAsName,
  }) {
    final saveDocument = widget.saveDocument;
    if (saveDocument != null) {
      return saveDocument(
        document,
        text,
        expectedRemoteBytes: expectedRemoteBytes,
        saveAsName: saveAsName,
      );
    }
    return widget.app!.saveSftpTextFile(
      document,
      text,
      expectedRemoteBytes: expectedRemoteBytes,
      saveAsName: saveAsName,
    );
  }

  String _friendlyError(Object error) =>
      widget.errorText?.call(error) ??
      widget.app?.friendlyError(error) ??
      error.toString();

  Future<String?> _askSaveAsName() async {
    final controller = TextEditingController(text: widget.document.name);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    try {
      return await _showNestedDialog<String>(
        builder: (context) => AlertDialog(
          title: Text(context.l10n.saveRemoteFileAs),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: context.l10n.fileName),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(context.l10n.saveAs),
            ),
          ],
        ),
      ).then((value) {
        final name = value?.trim();
        return name == null || name.isEmpty ? null : name;
      });
    } finally {
      controller.clear();
      controller.dispose();
    }
  }

  Future<_ConflictAction?>
  _chooseConflictAction() => _showNestedDialog<_ConflictAction>(
    builder: (context) => AlertDialog(
      title: Text(context.l10n.remoteFileChanged),
      content: Text(
        context.l10n.theRemoteFileChangedAfterYou,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ConflictAction.compare),
          child: Text(context.l10n.compare),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ConflictAction.saveAs),
          child: Text(context.l10n.saveAs),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ConflictAction.cancel),
          child: Text(context.l10n.cancel2),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(_ConflictAction.overwrite),
          child: Text(context.l10n.overwriteRemoteFile),
        ),
      ],
    ),
  );

  Future<void> _showComparison(SftpTextDocument latest) async {
    final size = MediaQuery.sizeOf(context);
    await _showNestedDialog<void>(
      builder: (context) => AlertDialog(
        title: Text(context.l10n.compareRemoteFileVersions),
        content: SizedBox(
          width: (size.width - 64).clamp(280.0, 1100.0).toDouble(),
          height: (size.height - 200).clamp(220.0, 650.0).toDouble(),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: constraints.maxWidth < 900 ? 900 : constraints.maxWidth,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _comparisonPane('Original', widget.document.text),
                    const VerticalDivider(width: 20),
                    _comparisonPane(context.l10n.latestRemote, latest.text),
                    const VerticalDivider(width: 20),
                    _comparisonPane(context.l10n.yourDraft, _content.text),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.backToConflict),
          ),
        ],
      ),
    );
  }

  Widget _comparisonPane(String title, String text) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectionArea(
                child: Text(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  void _replaceConflictDocument(SftpTextDocument document) {
    if (identical(_conflictDocument, document)) return;
    _conflictDocument?.dispose();
    _conflictDocument = document;
  }

  void _clearConflictDocument() {
    _conflictDocument?.dispose();
    _conflictDocument = null;
  }
}

enum _ConflictAction { compare, saveAs, overwrite, cancel }
