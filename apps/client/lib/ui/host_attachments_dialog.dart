import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../attachments/attachment_file_saver.dart';
import '../attachments/attachment_upload_source.dart';
import '../attachments/host_attachment_service.dart';
import '../crypto/host_attachment_crypto.dart';
import '../domain/models.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

Future<void> showHostAttachmentsDialog(
  BuildContext context, {
  required AppController app,
  required HostRecord host,
  @visibleForTesting AttachmentStreamingSaveOpener? streamingSaveOpener,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => _HostAttachmentsDialog(
    app: app,
    host: host,
    streamingSaveOpener: streamingSaveOpener,
  ),
);

typedef AttachmentStreamingSaveOpener =
    Future<AttachmentStreamingSaveWriter?> Function({
      required String fileName,
      required String mediaType,
    });

class _HostAttachmentsDialog extends StatefulWidget {
  const _HostAttachmentsDialog({
    required this.app,
    required this.host,
    this.streamingSaveOpener,
  });

  final AppController app;
  final HostRecord host;
  final AttachmentStreamingSaveOpener? streamingSaveOpener;

  @override
  State<_HostAttachmentsDialog> createState() => _HostAttachmentsDialogState();
}

class _HostAttachmentsDialogState extends State<_HostAttachmentsDialog> {
  bool _working = false;
  bool _loadingTransfers = false;
  List<HostAttachmentTransferSummary> _transfers = const [];
  String? _error;
  String _statusText = currentL10n.preparingAttachment;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _loadTransfers();
  }

  Future<void> _loadTransfers() async {
    if (mounted) setState(() => _loadingTransfers = true);
    try {
      final transfers = await app.hostAttachmentTransfers(widget.host.id);
      if (mounted) setState(() => _transfers = transfers);
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingTransfers = false);
    }
  }

  List<HostAttachmentSummary> get _attachments {
    try {
      return app.hostAttachments(widget.host.id);
    } catch (error) {
      _error ??= app.friendlyError(error);
      return const [];
    }
  }

  bool get _canWrite => app.activeVault?.canWrite == true;

  @override
  Widget build(BuildContext context) {
    final attachments = _attachments;
    return AlertDialog(
      title: Text(context.l10n.attachmentsName(widget.host.name)),
      content: SizedBox(
        width: appDialogWidth(context, 620),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.filesAreEncryptedOnThisDevice,
                style: const TextStyle(color: AppColors.muted, height: 1.45),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                _AttachmentMessage(text: _error!, isError: true),
              ],
              const SizedBox(height: 12),
              if (attachments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(context.l10n.noAttachmentsSavedForThisHost),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: attachments.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final attachment = attachments[index];
                      final canDownload = attachment.canDownload;
                      final saveLimit = maxAttachmentBytesForPlatform;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.attach_file_rounded,
                          color: AppColors.teal,
                        ),
                        title: Text(
                          attachment.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${attachment.mediaType} · ${_formatSize(attachment.totalSize)}${canDownload ? '' : ' · download unavailable above ${_formatSize(saveLimit)}'}',
                          style: const TextStyle(color: AppColors.muted),
                        ),
                        trailing: Wrap(
                          spacing: 2,
                          children: [
                            IconButton(
                              tooltip: canDownload
                                  ? context.l10n.downloadAttachment
                                  : context.l10n.downloadUnavailableAboveFormatsize(_formatSize(saveLimit)),
                              onPressed: _working || !canDownload
                                  ? null
                                  : () => _download(attachment),
                              icon: const Icon(Icons.download_outlined),
                            ),
                            if (_canWrite)
                              IconButton(
                                tooltip: context.l10n.removeAttachment,
                                onPressed: _working
                                    ? null
                                    : () => _remove(attachment),
                                color: AppColors.orange,
                                icon: const Icon(Icons.delete_outline),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              if (_loadingTransfers && _transfers.isEmpty)
                const LinearProgressIndicator(),
              if (_transfers.isNotEmpty) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.transferTasks,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final transfer in _transfers.take(8))
                        _buildTransferTile(transfer, attachments),
                      if (_transfers.length > 8)
                        ListTile(
                          dense: true,
                          title: Text(context.l10n.valuevalueMoreTasks(_transfers.length - 8)),
                        ),
                    ],
                  ),
                ),
              ],
              if (_working) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(
                  _statusText,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_canWrite)
          FilledButton.icon(
            onPressed: _working ? null : _pickAndUpload,
            icon: const Icon(Icons.upload_file_outlined),
            label: Text(context.l10n.attachFile),
          ),
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }

  Future<void> _pickAndUpload() async {
    setState(() {
      _working = true;
      _error = null;
      _statusText = context.l10n.chooseAFileToAttach;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: true,
        allowMultiple: false,
        onFileLoading: (status) {
          if (mounted && status == FilePickerStatus.done) {
            setState(() => _statusText = context.l10n.encryptingAndTransferring);
          }
        },
      );
      final files = picked?.files;
      final file = files == null || files.isEmpty ? null : files.first;
      if (file == null) return;

      final legacyBytes = file.bytes;
      final AttachmentUploadSource? source = file.readStream != null
          ? StreamAttachmentUploadSource(
              size: file.size,
              stream: file.readStream!,
            )
          : legacyBytes == null
          ? null
          : MemoryAttachmentUploadSource(legacyBytes);
      if (source == null) {
        if (mounted) {
          setState(
            () => _error =
                context.l10n.thisFileCannotBeLoadedInto,
          );
        }
        return;
      }
      if (source.size > hostAttachmentV2MaxBytes) {
        legacyBytes?.fillRange(0, legacyBytes.length, 0);
        if (mounted) {
          setState(() => _error = context.l10n.attachmentsAreLimitedTo1Gib);
        }
        return;
      }
      if (mounted) {
        setState(() => _statusText = context.l10n.encryptingAndTransferring);
      }
      try {
        await app.addHostAttachmentFromSource(
          hostId: widget.host.id,
          fileName: file.name,
          mediaType: _mediaTypeFor(file.name),
          source: source,
        );
        await _loadTransfers();
        if (mounted) setState(() {});
      } finally {
        // Only clear the in-memory compatibility fallback. Platform stream
        // chunks are consumed and released incrementally by the encryptor.
        legacyBytes?.fillRange(0, legacyBytes.length, 0);
      }
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
      await _loadTransfers();
    } finally {
      await _loadTransfers();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _download(HostAttachmentSummary attachment) async {
    setState(() {
      _working = true;
      _error = null;
      _statusText = context.l10n.downloadingAndVerifyingAttachment;
    });
    Uint8List? bytes;
    AttachmentStreamingSaveWriter? streamingWriter;
    try {
      if (attachment.totalSize > attachmentSmallSaveLimitBytes) {
        // The web picker must be opened synchronously from this button action,
        // before the first network request or asynchronous wait.
        final picker =
            (widget.streamingSaveOpener ?? openAttachmentStreamingSave)(
              fileName: attachment.fileName,
              mediaType: attachment.mediaType,
            );
        streamingWriter = await picker;
        if (streamingWriter == null) {
          if (mounted) setState(() => _error = context.l10n.saveCancelled);
          return;
        }
        await app.downloadHostAttachmentToSink(
          hostId: widget.host.id,
          blobId: attachment.blobId,
          onPlaintextChunk: streamingWriter.write,
        );
        await streamingWriter.commit();
        streamingWriter = null;
        await app.completeHostAttachmentDownload(
          hostId: widget.host.id,
          blobId: attachment.blobId,
        );
        await _loadTransfers();
        return;
      }
      bytes = await app.downloadHostAttachment(
        hostId: widget.host.id,
        blobId: attachment.blobId,
      );
      if (mounted) {
        setState(() => _statusText = context.l10n.savingDecryptedAttachment);
      }
      final saved = await saveAttachmentFile(
        fileName: attachment.fileName,
        mediaType: attachment.mediaType,
        bytes: bytes,
      );
      if (!saved) {
        if (mounted) {
          setState(
            () => _error =
                context.l10n.saveCancelledTheVerifiedEncryptedDownload,
          );
        }
        return;
      }
      await app.completeHostAttachmentDownload(
        hostId: widget.host.id,
        blobId: attachment.blobId,
      );
      await _loadTransfers();
    } catch (error) {
      await _abortSaveWriterBestEffort(streamingWriter);
      if (mounted) setState(() => _error = app.friendlyError(error));
      await _loadTransfers();
    } finally {
      try {
        await _abortSaveWriterBestEffort(streamingWriter);
        bytes?.fillRange(0, bytes.length, 0);
        await _loadTransfers();
      } finally {
        if (mounted) setState(() => _working = false);
      }
    }
  }

  Future<void> _abortSaveWriterBestEffort(
    AttachmentStreamingSaveWriter? writer,
  ) async {
    if (writer == null) return;
    try {
      await writer.abort();
    } on Object {
      // Keep the original transfer error visible and let the dialog recover.
    }
  }

  Future<void> _remove(HostAttachmentSummary attachment) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.removeAttachmentFromThisHost),
        content: Text(
          context.l10n.removeFilenameFromTheCurrentEncrypted(attachment.fileName),
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.removeFromHost),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
      _statusText = context.l10n.removingAttachment;
    });
    try {
      await app.removeHostAttachment(
        hostId: widget.host.id,
        blobId: attachment.blobId,
      );
      await _loadTransfers();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
      await _loadTransfers();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _buildTransferTile(
    HostAttachmentTransferSummary transfer,
    List<HostAttachmentSummary> attachments,
  ) {
    final title = transfer.direction == 'upload'
        ? context.l10n.attachmentUpload
        : context.l10n.attachmentDownload;
    final progress = transfer.totalBytes == 0
        ? null
        : (transfer.transferredBytes / transfer.totalBytes)
              .clamp(0.0, 1.0)
              .toDouble();
    final details = transfer.totalBytes == 0
        ? '${transfer.state} · ${transfer.completedObjects}/${transfer.totalObjects} objects'
        : '${transfer.state} · ${(progress! * 100).round()}% · ${_formatSize(transfer.transferredBytes)} / ${_formatSize(transfer.totalBytes)}';
    final attachment = attachments
        .where((item) => item.blobId == transfer.blobId)
        .firstOrNull;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        transfer.direction == 'upload'
            ? Icons.upload_file_outlined
            : Icons.download_outlined,
        color: AppColors.muted,
      ),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details, style: const TextStyle(color: AppColors.muted)),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: LinearProgressIndicator(value: progress),
            ),
        ],
      ),
      trailing: transfer.direction == 'upload'
          ? transfer.canResume
                ? IconButton(
                    tooltip: context.l10n.resumeUpload,
                    onPressed: _working ? null : () => _resumeUpload(transfer),
                    icon: const Icon(Icons.restart_alt_rounded),
                  )
                : IconButton(
                    tooltip: context.l10n.discardOrphanTransfer,
                    onPressed: _working
                        ? null
                        : () => _discardOrphanTransfer(transfer),
                    icon: const Icon(Icons.delete_outline),
                  )
          : Wrap(
              spacing: 0,
              children: [
                if (attachment != null)
                  IconButton(
                    tooltip: context.l10n.resumeDownload,
                    onPressed: _working ? null : () => _download(attachment),
                    icon: const Icon(Icons.restart_alt_rounded),
                  ),
                IconButton(
                  tooltip: context.l10n.discardDownloadedCopy,
                  onPressed: _working ? null : () => _discardDownload(transfer),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
    );
  }

  Future<void> _resumeUpload(HostAttachmentTransferSummary transfer) async {
    setState(() {
      _working = true;
      _error = null;
      _statusText = context.l10n.resumingEncryptedUpload;
    });
    try {
      await app.resumeHostAttachmentUpload(
        hostId: widget.host.id,
        blobId: transfer.blobId,
      );
      await _loadTransfers();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
      await _loadTransfers();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _discardOrphanTransfer(
    HostAttachmentTransferSummary transfer,
  ) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await app.discardHostAttachmentUpload(
        hostId: widget.host.id,
        blobId: transfer.blobId,
      );
      await _loadTransfers();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _discardDownload(HostAttachmentTransferSummary transfer) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await app.discardHostAttachmentDownload(
        hostId: widget.host.id,
        blobId: transfer.blobId,
      );
      await _loadTransfers();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _mediaTypeFor(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return switch (extension) {
      'txt' || 'log' || 'md' || 'csv' => 'text/plain',
      'json' => 'application/json',
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'zip' => 'application/zip',
      'gz' => 'application/gzip',
      'yaml' || 'yml' => 'application/yaml',
      _ => 'application/octet-stream',
    };
  }
}

class _AttachmentMessage extends StatelessWidget {
  const _AttachmentMessage({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: (isError ? AppColors.red : AppColors.teal).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(
        color: (isError ? AppColors.red : AppColors.teal).withValues(
          alpha: .24,
        ),
      ),
    ),
    child: Text(
      text,
      style: TextStyle(color: isError ? AppColors.red : AppColors.teal),
    ),
  );
}
