import 'dart:async';

import 'app_menu.dart';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/sftp_entries.dart';
import '../platform/file_drop_region.dart';
import '../sftp/external_edit_manager.dart';
import '../ssh/file_workspace_controller.dart';
import 'app_motion.dart';
import 'external_edit_footer.dart';
import 'sftp_text_editor_dialog.dart';
import 'remote_file_icon.dart';
import 'transfer_dialog.dart';
import '../l10n/l10n.dart';

enum _FileAction {
  open,
  download,
  edit,
  openExternal,
  rename,
  copy,
  cut,
  pasteInto,
  copyPath,
  delete,
  paste,
  upload,
  mkdir,
  refresh,
  copyFolderPath,
}

/// An internal remote-entry drag; accepted only by the tab that started it.
class _RemoteEntryDrag {
  const _RemoteEntryDrag(this.owner, this.parent, this.entry);
  final FileWorkspaceController owner;
  final String parent;
  final SftpName entry;
  String get path => sftpChildPath(parent, entry.filename);
}

/// Mouse-driven platforms get internal drag-to-folder; touch keeps scrolling
/// and uses the long-press menu (Cut / Paste into folder) instead.
bool get _pointerDragPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

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
  String? _dragTargetName;

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

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working || model.isClosed) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error) {
      _snack(fileWorkspaceErrorText(error));
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

  Future<String?> _askName({
    required String title,
    required String action,
    String initial = '',
  }) => showAppDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, action: action, initial: initial),
  );

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _createDirectory() async {
    final owner = model;
    final parent = owner.path;
    final result = await _askName(
      title: context.l10n.newFolder,
      action: context.l10n.create,
    );
    if (result == null || owner.isClosed) return;
    await owner.sftp.createDirectory(parent, result);
    await owner.refresh(selectName: result);
  }

  Future<void> _rename(SftpName item) async {
    final owner = model;
    final parent = owner.path;
    final name = await _askName(
      title: context.l10n.fileManagerRenameTitle(item.filename),
      action: context.l10n.fileManagerRename,
      initial: item.filename,
    );
    if (name == null || name == item.filename || owner.isClosed) return;
    await owner.renameEntry(parent, item, name);
  }

  Future<void> _delete(SftpName item) async {
    final owner = model;
    final parent = owner.path;
    final plan = await owner.planDelete(parent, item);
    if (!mounted || owner.isClosed) return;
    final contents = plan.entries.length - 1;
    final confirmed = await _confirm(
      title: context.l10n.confirmDeletion,
      message: contents <= 0
          ? context.l10n.fileManagerDeleteConfirm(item.filename)
          : context.l10n.fileManagerDeleteFolderConfirm(
              item.filename,
              contents,
            ),
      action: context.l10n.delete,
      destructive: true,
    );
    if (!confirmed || owner.isClosed) return;
    await owner.deletePlanned(parent, item, plan);
  }

  Future<void> _paste(String directory) async {
    final owner = model;
    final clip = owner.clipboard;
    if (clip == null) return;
    await owner.paste(
      directory,
      keepBoth: (name) async {
        if (!mounted) return false;
        return _confirm(
          title: context.l10n.fileManagerNameConflictTitle,
          message: context.l10n.fileManagerNameConflictKeepBoth(name),
          action: context.l10n.fileManagerKeepBoth,
        );
      },
    );
  }

  Future<void> _move(_RemoteEntryDrag drag, SftpName folder) async {
    final owner = model;
    if (!identical(drag.owner, owner) || drag.parent != owner.path) return;
    final destination = sftpChildPath(owner.path, folder.filename);
    final confirmed = await _confirm(
      title: context.l10n.fileManagerMoveTitle,
      message: context.l10n.fileManagerMoveConfirm(
        drag.entry.filename,
        folder.filename,
      ),
      action: context.l10n.fileManagerMove,
    );
    if (!confirmed || owner.isClosed || owner.path != drag.parent) return;
    await owner.moveEntry(drag.entry, destination);
  }

  Future<void> _copyPath(String path) async {
    final message = context.l10n.fileManagerPathCopied;
    await Clipboard.setData(ClipboardData(text: path));
    _snack(message);
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

  /// Downloads a private copy and opens it in the associated application.
  /// Saves there only mark the file changed; the footer's Upload sends it.
  Future<void> _openExternal(SftpName item) async {
    final owner = model;
    final edits = owner.externalEdits;
    if (!edits.isSupported) {
      _snack(context.l10n.fileEditUnavailable);
      return;
    }
    try {
      await edits.open(owner.entryPath(item), listedSize: item.attr.size);
      if (mounted &&
          defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)
        _snack(context.l10n.fileEditOpened(item.filename));
    } catch (error) {
      if (mounted) _snack(externalEditErrorText(context, error));
    }
  }

  /// Explicit footer Upload: a server change since opening needs a separate
  /// confirmation before it is replaced.
  Future<void> _uploadExternal(ExternalEditItem item) async {
    final owner = model;
    final edits = owner.externalEdits;
    var result = await edits.upload(item);
    if (result == ExternalEditUploadResult.remoteChanged) {
      if (!mounted || owner.isClosed) return;
      final replace = await _confirm(
        title: context.l10n.fileEditConflictTitle,
        message: context.l10n.fileEditConflictMessage(item.name),
        action: context.l10n.fileEditReplace,
        destructive: true,
      );
      if (!replace || owner.isClosed) return;
      result = await edits.upload(item, replaceRemoteChange: true);
    }
    if (!mounted) return;
    switch (result) {
      case ExternalEditUploadResult.uploaded:
        _snack(context.l10n.fileEditUploaded(item.name));
      case ExternalEditUploadResult.uploadedChangedAgain:
        _snack(context.l10n.fileEditUploadedChangedAgain(item.name));
      case ExternalEditUploadResult.failed:
        final error = item.error;
        if (error != null) _snack(externalEditErrorText(context, error));
      case ExternalEditUploadResult.remoteChanged:
      case ExternalEditUploadResult.notPending:
        break;
    }
    final parent = item.remotePath.substring(
      0,
      item.remotePath.lastIndexOf('/'),
    );
    if ((result == ExternalEditUploadResult.uploaded ||
            result == ExternalEditUploadResult.uploadedChangedAgain) &&
        !owner.isClosed &&
        identical(owner, model) &&
        (parent.isEmpty ? '/' : parent) == owner.path) {
      await owner.refresh(selectName: item.name);
    }
  }

  /// [owner] and [directory] are the tab and folder that were showing when
  /// the drop arrived (captured by the region before inspecting files).
  Future<void> _onDrop(
    FileDropResult result,
    FileWorkspaceController owner,
    String directory,
  ) async {
    if (!mounted) return;
    if (result.failed) {
      _snack(context.l10n.fileManagerDropFailed);
      return;
    }
    if (result.tooMany) {
      _snack(
        context.l10n.fileManagerDropTooManyFiles(fileManagerMaxDroppedFiles),
      );
      return;
    }
    // Reject a stale target: the tab now shows another controller or folder,
    // or was closed, while the dropped files were being inspected.
    if (!identical(owner, model) || owner.isClosed || owner.path != directory) {
      _snack(context.l10n.fileManagerDropTargetChanged);
      return;
    }
    if (_working || owner.busy || owner.loading) {
      _snack(context.l10n.fileManagerBusy);
      return;
    }
    if (result.files.isEmpty) {
      _snack(context.l10n.fileManagerDropNothingAccepted);
      return;
    }
    await _run(() async {
      final summary = await owner.uploadLocalFiles(
        result.files,
        directory,
        onConflict: _uploadConflict,
      );
      if (!mounted) return;
      _snack(
        context.l10n.fileManagerUploadSummary(
          summary.uploaded,
          summary.skipped + result.rejected,
          summary.failed,
        ),
      );
    });
  }

  Future<UploadConflictChoice> _uploadConflict(String name) async {
    if (!mounted) return UploadConflictChoice.cancel;
    final choice = await showAppDialog<UploadConflictChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.fileManagerNameConflictTitle),
        content: Text(context.l10n.fileManagerUploadConflict(name)),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, UploadConflictChoice.cancel),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, UploadConflictChoice.skip),
            child: Text(context.l10n.fileManagerSkip),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, UploadConflictChoice.keepBoth),
            child: Text(context.l10n.fileManagerKeepBoth),
          ),
        ],
      ),
    );
    return choice ?? UploadConflictChoice.cancel;
  }

  // -------------------------------------------------------------------- menus

  List<PopupMenuEntry<_FileAction>> _entryMenuItems(SftpName item) {
    final l10n = context.l10n;
    final type = item.attr.mode?.type;
    final directory = item.attr.isDirectory == true;
    final regular = type == SftpFileType.regularFile;
    final folderPath = directory ? model.entryPath(item) : null;
    PopupMenuItem<_FileAction> entry(
      _FileAction value,
      IconData icon,
      String label, {
      bool enabled = true,
      Color? color,
    }) => appMenuItem(
      context,
      key: ValueKey('file_menu_${value.name}'),
      value: value,
      enabled: enabled,
      child: AppMenuLabel(icon, label, color: color),
    );

    return [
      if (directory)
        entry(_FileAction.open, Icons.folder_open, l10n.fileManagerOpen),
      if (regular) entry(_FileAction.download, Icons.download, l10n.download),
      if (regular) entry(_FileAction.edit, Icons.edit_note, l10n.editText),
      if (regular)
        entry(
          _FileAction.openExternal,
          Icons.open_in_new,
          l10n.fileEditOpenExternal,
        ),
      const PopupMenuDivider(),
      entry(
        _FileAction.rename,
        Icons.drive_file_rename_outline,
        l10n.fileManagerRename,
      ),
      entry(_FileAction.copy, Icons.content_copy, l10n.fileManagerCopy),
      entry(_FileAction.cut, Icons.content_cut, l10n.fileManagerCut),
      if (folderPath != null && model.clipboard != null)
        entry(
          _FileAction.pasteInto,
          Icons.content_paste,
          l10n.fileManagerPasteInto,
          enabled: model.canPasteInto(folderPath),
        ),
      entry(_FileAction.copyPath, Icons.link, l10n.fileManagerCopyPath),
      const PopupMenuDivider(),
      entry(
        _FileAction.delete,
        Icons.delete_outline,
        l10n.delete,
        color: Theme.of(context).colorScheme.error,
      ),
    ];
  }

  List<PopupMenuEntry<_FileAction>> _backgroundMenuItems() {
    final l10n = context.l10n;
    PopupMenuItem<_FileAction> entry(
      _FileAction value,
      IconData icon,
      String label, {
      bool enabled = true,
    }) => appMenuItem(
      context,
      key: ValueKey('file_menu_${value.name}'),
      value: value,
      enabled: enabled,
      child: AppMenuLabel(icon, label),
    );
    return [
      entry(
        _FileAction.paste,
        Icons.content_paste,
        l10n.fileManagerPaste,
        enabled: model.canPasteInto(model.path),
      ),
      const PopupMenuDivider(),
      entry(_FileAction.upload, Icons.upload_file, l10n.uploadFile),
      entry(
        _FileAction.mkdir,
        Icons.create_new_folder_outlined,
        l10n.newFolder,
      ),
      entry(_FileAction.refresh, Icons.refresh, l10n.refresh),
      entry(_FileAction.copyFolderPath, Icons.link, l10n.fileManagerCopyPath),
    ];
  }

  void _perform(_FileAction action, [SftpName? item]) {
    final owner = model;
    final parent = owner.path;
    switch (action) {
      case _FileAction.copy:
        if (item != null) owner.copyToClipboard(item);
      case _FileAction.cut:
        if (item != null) owner.cutToClipboard(item);
      case _FileAction.copyPath:
        if (item != null) {
          _copyPath(sftpChildPath(parent, item.filename));
        }
      case _FileAction.copyFolderPath:
        _copyPath(parent);
      case _FileAction.refresh:
        owner.refresh();
      case _FileAction.open:
        if (item != null) owner.enter(item);
      default:
        _run(() async {
          switch (action) {
            case _FileAction.download:
              await _transfer(item: item);
            case _FileAction.edit:
              await _edit(item!);
            case _FileAction.openExternal:
              await _openExternal(item!);
            case _FileAction.rename:
              await _rename(item!);
            case _FileAction.delete:
              await _delete(item!);
            case _FileAction.pasteInto:
              await _paste(sftpChildPath(parent, item!.filename));
            case _FileAction.paste:
              await _paste(parent);
            case _FileAction.upload:
              await _transfer();
            case _FileAction.mkdir:
              await _createDirectory();
            default:
              break;
          }
        });
    }
  }

  Future<void> _showMenuAt(Offset global, {SftpName? item}) async {
    final disabled = _working || model.loading || model.isClosed || model.busy;
    if (disabled) return;
    if (item != null) model.select(item);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(global);
    final action = await showMenu<_FileAction>(
      context: context,
      popUpAnimationStyle: AppMotion.menuStyle(context),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: item == null ? _backgroundMenuItems() : _entryMenuItems(item),
    );
    if (action == null || !mounted || model.isClosed) return;
    _perform(action, item);
  }

  // -------------------------------------------------------------------- build

  Widget _row(SftpName item, bool disabled) {
    final directory = item.attr.isDirectory == true;
    final colors = Theme.of(context).colorScheme;
    final nameColor = directory ? colors.primary : colors.onSurface;
    final highlighted = _dragTargetName == item.filename;
    Widget row = Material(
      color: highlighted
          ? colors.primary.withValues(alpha: .18)
          : model.selected == item
          ? colors.primary.withValues(alpha: .10)
          : Colors.transparent,
      child: GestureDetector(
        onLongPressStart: disabled
            ? null
            : (details) => _showMenuAt(details.globalPosition, item: item),
        child: InkWell(
          onTap: disabled
              ? null
              : () {
                  model.select(item);
                  if (directory) {
                    model.enter(item);
                  } else if (!kIsWeb &&
                      (defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.iOS)) {
                    unawaited(_openExternal(item));
                  }
                },
          onSecondaryTapUp: disabled
              ? null
              : (details) => _showMenuAt(details.globalPosition, item: item),
          child: _FileDetailsRow(
            name: Row(
              children: [
                Icon(
                  remoteFileIcon(
                    item.filename,
                    directory: directory,
                    link: item.attr.mode?.type == SftpFileType.symbolicLink,
                  ),
                  size: 18,
                  color: directory ? nameColor : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: item.filename,
                    // Touch long-press belongs to the entry menu.
                    triggerMode: _pointerDragPlatform
                        ? null
                        : TooltipTriggerMode.manual,
                    child: Text(
                      item.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: nameColor),
                    ),
                  ),
                ),
              ],
            ),
            modified: _modifiedTime(item.attr.modifyTime),
            size: directory ? '—' : _fileSize(item.attr.size),
            trailing: PopupMenuButton<_FileAction>(
              popUpAnimationStyle: AppMotion.menuStyle(context),
              enabled: !disabled,
              tooltip: context.l10n.filenameActions(item.filename),
              onOpened: () => model.select(item),
              onSelected: (action) => _perform(action, item),
              itemBuilder: (_) => _entryMenuItems(item),
            ),
          ),
        ),
      ),
    );
    if (directory) {
      final content = row;
      row = DragTarget<_RemoteEntryDrag>(
        onWillAcceptWithDetails: (details) {
          final drag = details.data;
          final ok =
              !disabled &&
              identical(drag.owner, model) &&
              drag.parent == model.path &&
              drag.entry.filename != item.filename;
          if (ok && _dragTargetName != item.filename) {
            setState(() => _dragTargetName = item.filename);
          }
          return ok;
        },
        onLeave: (_) {
          if (_dragTargetName == item.filename) {
            setState(() => _dragTargetName = null);
          }
        },
        onAcceptWithDetails: (details) {
          setState(() => _dragTargetName = null);
          _run(() => _move(details.data, item));
        },
        builder: (context, _, _) => content,
      );
    }
    if (_pointerDragPlatform && !disabled) {
      final feedback = Material(
        elevation: 4,
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                remoteFileIcon(item.filename, directory: directory),
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  item.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.onSurface),
                ),
              ),
            ],
          ),
        ),
      );
      row = Draggable<_RemoteEntryDrag>(
        data: _RemoteEntryDrag(model, model.path, item),
        feedback: feedback,
        childWhenDragging: Opacity(opacity: .5, child: row),
        child: row,
      );
    }
    return KeyedSubtree(
      key: ValueKey('remote_file_row_${item.filename}'),
      child: row,
    );
  }

  Widget _background({required Widget child, required bool disabled}) =>
      GestureDetector(
        key: const ValueKey('remote_file_background'),
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: disabled
            ? null
            : (details) => _showMenuAt(details.globalPosition),
        onLongPressStart: disabled
            ? null
            : (details) => _showMenuAt(details.globalPosition),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final disabled = _working || model.loading || model.isClosed || model.busy;
    // The drop callback closes over the exact controller and folder shown in
    // this frame; FileDropRegion keeps the callback current at drop time.
    final dropOwner = model;
    final dropDirectory = model.path;
    final listing =
        model.entries.isEmpty && !model.loading && model.error == null
        ? _background(
            disabled: disabled,
            child: Center(child: Text(context.l10n.thisFolderIsEmpty)),
          )
        : LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: constraints.maxWidth < 360 ? 360 : constraints.maxWidth,
                child: Column(
                  children: [
                    _FileDetailsRow(
                      name: Text(context.l10n.name),
                      modified: context.l10n.modified,
                      size: context.l10n.size,
                      header: true,
                    ),
                    Expanded(
                      child: _background(
                        disabled: disabled,
                        child: ListView.builder(
                          // Bottom room so the last row stays reachable for a
                          // background long-press/right-click.
                          padding: const EdgeInsets.only(bottom: 48),
                          itemCount: model.entries.length,
                          itemBuilder: (context, index) =>
                              _row(model.entries[index], disabled),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
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
                onSelected: (action) => switch (action) {
                  'upload' => _perform(_FileAction.upload),
                  'paste' => _perform(_FileAction.paste),
                  _ => _perform(_FileAction.mkdir),
                },
                itemBuilder: (_) => [
                  appMenuItem(
                    context,
                    value: 'upload',
                    child: Text(context.l10n.uploadFile),
                  ),
                  appMenuItem(
                    context,
                    value: 'mkdir',
                    child: Text(context.l10n.newFolder),
                  ),
                  if (model.clipboard != null)
                    appMenuItem(
                      context,
                      value: 'paste',
                      enabled: model.canPasteInto(model.path),
                      child: Text(context.l10n.fileManagerPaste),
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
          child: FileDropRegion(
            enabled: !model.isClosed,
            maxFiles: fileManagerMaxDroppedFiles,
            onDrop: (result) => _onDrop(result, dropOwner, dropDirectory),
            child: listing,
          ),
        ),
        if (!model.isClosed)
          ExternalEditFooter(
            manager: model.externalEdits,
            onUpload: (item) => _uploadExternal(item),
          ),
        _FileManagerBar(
          model: model,
          onPaste: disabled ? null : () => _perform(_FileAction.paste),
        ),
      ],
    );
  }
}

/// Name prompt for rename/new folder; owns its text controller so the exit
/// animation never touches a disposed controller.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.action,
    required this.initial,
  });

  final String title, action, initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.lastIndexOf('.') > 0
          ? widget.initial.lastIndexOf('.')
          : widget.initial.length,
    );

  String get _value => _controller.text.trim();
  bool get _valid => isSafeSftpBasename(_value) && _value.length <= 255;

  void _submit() {
    if (_valid) Navigator.pop(context, _value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('file_manager_name_input'),
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: context.l10n.name,
        errorText: _value.isEmpty || _valid
            ? null
            : context.l10n.fileManagerInvalidName,
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        onPressed: _valid ? _submit : null,
        child: Text(widget.action),
      ),
    ],
  );
}

/// Compact, persistent status surface inside the file tab: clipboard state
/// and the running copy/move/delete/upload job with its Cancel action.
class _FileManagerBar extends StatelessWidget {
  const _FileManagerBar({required this.model, required this.onPaste});

  final FileWorkspaceController model;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final activity = model.activity;
    final clip = model.clipboard;
    if (activity == null && clip == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Material(
      key: const ValueKey('file_manager_bar'),
      color: colors.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (activity != null)
                ListenableBuilder(
                  listenable: activity,
                  builder: (context, _) => Row(
                    children: [
                      Icon(
                        switch (activity.kind) {
                          RemoteFileActivityKind.copy => Icons.content_copy,
                          RemoteFileActivityKind.move =>
                            Icons.drive_file_move_outline,
                          RemoteFileActivityKind.delete => Icons.delete_outline,
                          RemoteFileActivityKind.upload => Icons.upload,
                        },
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              switch (activity.kind) {
                                RemoteFileActivityKind.copy =>
                                  l10n.fileManagerCopying(activity.name),
                                RemoteFileActivityKind.move =>
                                  l10n.fileManagerMoving(activity.name),
                                RemoteFileActivityKind.delete =>
                                  l10n.fileManagerDeleting(activity.name),
                                RemoteFileActivityKind.upload =>
                                  l10n.fileManagerUploading(
                                    activity.name,
                                    activity.index + 1,
                                    activity.count,
                                  ),
                              },
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: activity.fraction,
                              minHeight: 3,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('file_manager_cancel'),
                        onPressed: activity.canCancel ? activity.cancel : null,
                        child: Text(l10n.cancel),
                      ),
                    ],
                  ),
                ),
              if (clip != null)
                Row(
                  children: [
                    Icon(
                      clip.mode == RemoteFileClipboardMode.cut
                          ? Icons.content_cut
                          : Icons.content_copy,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message: clip.path,
                        child: Text(
                          clip.mode == RemoteFileClipboardMode.cut
                              ? l10n.fileManagerClipboardCut(clip.name)
                              : l10n.fileManagerClipboardCopied(clip.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('file_manager_paste_here'),
                      onPressed:
                          onPaste != null && model.canPasteInto(model.path)
                          ? onPaste
                          : null,
                      child: Text(l10n.fileManagerPasteHere),
                    ),
                    IconButton(
                      tooltip: l10n.fileManagerClearClipboard,
                      visualDensity: VisualDensity.compact,
                      onPressed: model.clearClipboard,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
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
