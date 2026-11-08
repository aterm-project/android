import 'app_menu.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/sftp_entries.dart';
import '../ssh/file_workspace_controller.dart';
import 'app_motion.dart';
import 'sftp_text_editor_dialog.dart';
import 'remote_file_icon.dart';
import 'transfer_dialog.dart';
import '../l10n/l10n.dart';

/// Embedded directly below the workspace tabs; the caller owns the controller.
class RemoteFileWorkspace extends StatefulWidget {
  const RemoteFileWorkspace({required this.controller, super.key});
  final FileWorkspaceController controller;

  @override
  State<RemoteFileWorkspace> createState() => _RemoteFileWorkspaceState();
}

class _RemoteFileWorkspaceState extends State<RemoteFileWorkspace> {
  late final TextEditingController _path;
  final _pathFocus = FocusNode();
  bool _editingPath = false;
  FileWorkspaceController get model => widget.controller;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: model.path);
    _pathFocus.addListener(_pathFocusChanged);
    model.addListener(_changed);
    if (model.entries.isEmpty && !model.loading) model.refresh();
  }

  @override
  void didUpdateWidget(RemoteFileWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == model) return;
    oldWidget.controller.removeListener(_changed);
    model.addListener(_changed);
    _path.text = model.path;
    if (model.entries.isEmpty && !model.loading) model.refresh();
  }

  void _changed() {
    if (!mounted) return;
    if (!model.loading && !_pathFocus.hasFocus) _path.text = model.path;
    setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _pathFocus.dispose();
    _path.dispose();
    super.dispose();
  }

  void _pathFocusChanged() {
    if (!_pathFocus.hasFocus && mounted) {
      setState(() {
        _editingPath = false;
        _path.text = model.path;
      });
    }
  }

  void _editPath() {
    setState(() {
      _editingPath = true;
      _path.value = TextEditingValue(
        text: model.path,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: model.path.length,
        ),
      );
    });
    _pathFocus.requestFocus();
  }

  Widget _pathControl(bool disabled) => SizedBox(
    key: const ValueKey('remote_file_path_control'),
    height: 36,
    child: _editingPath
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  _pathFocus.unfocus(),
            },
            child: TextField(
              key: const ValueKey('remote_file_path_input'),
              controller: _path,
              focusNode: _pathFocus,
              enabled: !disabled,
              maxLines: 1,
              textInputAction: TextInputAction.go,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: context.l10n.remotePath,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onSubmitted: (value) {
                _pathFocus.unfocus();
                model.navigate(value);
              },
            ),
          )
        : Tooltip(
            message: model.path,
            child: TextButton(
              key: const ValueKey('remote_file_path_display'),
              onPressed: disabled ? null : _editPath,
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                backgroundColor: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: .04),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_open_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      model.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
  );

  Future<void> _run(Future<void> Function() operation) async {
    if (_working || model.isClosed) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(fileWorkspaceErrorText(error))));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _transfer({SftpName? item}) async {
    final completed = await showSshTransferDialog(
      context: context,
      client: model.connection.client,
      direction: item == null
          ? SshTransferDirection.upload
          : SshTransferDirection.download,
      remotePath: item == null
          ? model.path
          : sftpChildPath(model.path, item.filename),
      uploadIntoDirectory: item == null,
      suggestedName: item?.filename,
      initialProtocol: model.protocol,
    );
    if (completed == true && !model.isClosed) await model.refresh();
  }

  Future<void> _createDirectory() async {
    final owner = model;
    final parent = owner.path;
    var name = '';
    final result = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.newFolder),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name),
            child: Text(context.l10n.create),
          ),
        ],
      ),
    );
    if (result == null || owner.isClosed) return;
    await owner.sftp.createDirectory(parent, result);
    await owner.refresh();
  }

  Future<void> _delete(SftpName item) async {
    final owner = model;
    final parent = owner.path;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.confirmDeletion),
        content: Text(
          context.l10n.deleteFilenameFoldersMustBeEmpty(item.filename),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || owner.isClosed) return;
    await owner.sftp.deleteEntry(parent: parent, item: item);
    await owner.refresh();
  }

  Future<void> _edit(SftpName item) async {
    final owner = model;
    final document = await owner.sftp.openTextFile(
      parent: model.path,
      name: item.filename,
    );
    if (!mounted || owner.isClosed) {
      document.dispose();
      return;
    }
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SftpTextEditorDialog(
        document: document,
        saveDocument: owner.sftp.saveTextFile,
        errorText: fileWorkspaceErrorText,
      ),
    );
    if (!model.isClosed) await model.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _working || model.loading || model.isClosed;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: context.l10n.parentFolder,
                onPressed: disabled ? null : model.up,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 20),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: _pathControl(disabled),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: context.l10n.refresh,
                visualDensity: VisualDensity.compact,
                onPressed: disabled ? null : model.refresh,
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                popUpAnimationStyle: AppMotion.menuStyle(context),
                enabled: !disabled,
                tooltip: context.l10n.fileActions,
                style: IconButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  maximumSize: const Size(36, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                padding: EdgeInsets.zero,
                onSelected: (action) => _run(
                  action == 'upload' ? () => _transfer() : _createDirectory,
                ),
                itemBuilder: (_) => [
                  appMenuItem(context,
                    value: 'upload',
                    child: Text(context.l10n.uploadFile),
                  ),
                  appMenuItem(context,
                    value: 'mkdir',
                    child: Text(context.l10n.newFolder),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (model.loading) const LinearProgressIndicator(minHeight: 2),
        if (model.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              model.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: model.entries.isEmpty && !model.loading && model.error == null
              ? Center(child: Text(context.l10n.thisFolderIsEmpty))
              : LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: constraints.maxWidth < 360
                          ? 360
                          : constraints.maxWidth,
                      child: Column(
                        children: [
                          _FileDetailsRow(
                            name: Text(context.l10n.name),
                            modified: context.l10n.modified,
                            size: context.l10n.size,
                            header: true,
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: model.entries.length,
                              itemBuilder: (context, index) {
                                final item = model.entries[index];
                                final directory = item.attr.isDirectory == true;
                                final regular =
                                    item.attr.mode?.type ==
                                    SftpFileType.regularFile;
                                final colors = Theme.of(context).colorScheme;
                                final nameColor = directory
                                    ? const Color(0xFF8CC8FF)
                                    : colors.onSurface;
                                return Material(
                                  color: model.selected == item
                                      ? colors.primary.withValues(alpha: .10)
                                      : Colors.transparent,
                                  child: InkWell(
                                    onTap: disabled
                                        ? null
                                        : () {
                                            model.select(item);
                                            if (directory) model.enter(item);
                                          },
                                    child: _FileDetailsRow(
                                      name: Row(
                                        children: [
                                          Icon(
                                            remoteFileIcon(
                                              item.filename,
                                              directory: directory,
                                              link:
                                                  item.attr.mode?.type ==
                                                  SftpFileType.symbolicLink,
                                            ),
                                            size: 18,
                                            color: directory
                                                ? nameColor
                                                : colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Tooltip(
                                              message: item.filename,
                                              child: Text(
                                                item.filename,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: nameColor,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      modified: _modifiedTime(
                                        item.attr.modifyTime,
                                      ),
                                      size: directory
                                          ? '—'
                                          : _fileSize(item.attr.size),
                                      trailing: PopupMenuButton<String>(
                                        popUpAnimationStyle:
                                            AppMotion.menuStyle(context),
                                        enabled: !disabled,
                                        tooltip: context.l10n.filenameActions(
                                          item.filename,
                                        ),
                                        onSelected: (action) => _run(() async {
                                          switch (action) {
                                            case 'download':
                                              await _transfer(item: item);
                                            case 'edit':
                                              await _edit(item);
                                            case 'delete':
                                              await _delete(item);
                                          }
                                        }),
                                        itemBuilder: (_) => [
                                          if (regular)
                                            appMenuItem(context,
                                              value: 'download',
                                              child: Text(
                                                context.l10n.download,
                                              ),
                                            ),
                                          if (regular)
                                            appMenuItem(context,
                                              value: 'edit',
                                              child: Text(
                                                context.l10n.editText,
                                              ),
                                            ),
                                          appMenuItem(context,
                                            value: 'delete',
                                            child: Text(context.l10n.delete),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

String _modifiedTime(int? seconds) {
  if (seconds == null || seconds.abs() > 8640000000000) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

String _fileSize(int? bytes) {
  if (bytes == null || bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

class _FileDetailsRow extends StatelessWidget {
  const _FileDetailsRow({
    required this.name,
    required this.modified,
    required this.size,
    this.trailing,
    this.header = false,
  });
  final Widget name;
  final String modified, size;
  final Widget? trailing;
  final bool header;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: header ? 30 : 36,
    child: DefaultTextStyle(
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            Expanded(child: name),
            const SizedBox(width: 12),
            SizedBox(
              width: 124,
              child: Text(
                modified,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 66,
              child: Text(size, textAlign: TextAlign.right, maxLines: 1),
            ),
            SizedBox(width: 32, child: trailing),
          ],
        ),
      ),
    ),
  );
}
