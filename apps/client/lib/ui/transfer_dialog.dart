import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';

import '../platform/transfer_foreground.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../attachments/attachment_file_saver.dart';
import '../domain/sftp_entries.dart';
import '../ssh/scp_transfer_service.dart';
import '../ssh/scp_transfer_activity.dart';
import '../ssh/scp_mobile_save_writer.dart';
import '../ssh/scp_mobile_file_picker.dart';
import 'app_motion.dart';
export '../ssh/scp_transfer_service.dart';
export '../ssh/scp_transfer_activity.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

enum SshTransferDirection { upload, download }

/// Legacy byte-save compatibility applies only to SFTP, never to SCP.
bool useLegacySftpDownload({
  required SshTransferProtocol protocol,
  required bool supportsStreamingSave,
  required bool mobileWriterAvailable,
}) =>
    protocol == SshTransferProtocol.sftp &&
    !supportsStreamingSave &&
    !mobileWriterAvailable;

Future<bool?> showSshTransferDialog({
  required BuildContext context,
  required SSHClient client,
  required SshTransferDirection direction,
  required String remotePath,
  bool uploadIntoDirectory = false,
  String? suggestedName,
  SshTransferProtocol initialProtocol = SshTransferProtocol.sftp,
  Future<void> Function(String remotePath)? legacySftpDownload,
}) => showAppDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _TransferDialog(
    client: client,
    direction: direction,
    remotePath: remotePath,
    uploadIntoDirectory: uploadIntoDirectory,
    suggestedName: suggestedName,
    initialProtocol: initialProtocol,
    legacySftpDownload: legacySftpDownload,
  ),
);

class _TransferDialog extends StatefulWidget {
  const _TransferDialog({
    required this.client,
    required this.direction,
    required this.remotePath,
    required this.uploadIntoDirectory,
    required this.suggestedName,
    required this.initialProtocol,
    required this.legacySftpDownload,
  });
  final SSHClient client;
  final SshTransferDirection direction;
  final String remotePath;
  final bool uploadIntoDirectory;
  final String? suggestedName;
  final SshTransferProtocol initialProtocol;
  final Future<void> Function(String remotePath)? legacySftpDownload;
  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  late final _path = TextEditingController(text: widget.remotePath);
  late var _protocol = widget.initialProtocol;
  PlatformFile? _file;
  SshTransferCancellation? _cancellation;
  SshTransferProgress? _progress;
  String? _error;
  bool _busy = false;
  bool _legacySftpBusy = false;
  bool get _legacySftpSelected =>
      !_upload &&
      widget.legacySftpDownload != null &&
      useLegacySftpDownload(
        protocol: _protocol,
        supportsStreamingSave: supportsStreamingAttachmentSave,
        mobileWriterAvailable: _mobile,
      );
  bool get _upload => widget.direction == SshTransferDirection.upload;
  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _pick() async {
    try {
      final result = await transferForeground.run(
        'upload',
        () => FilePicker.platform.pickFiles(
          withData: false,
          withReadStream: true,
        ),
      );
      if (!mounted || result == null) return;
      final file = result.files.single;
      if (!isSafeSftpBasename(file.name)) {
        throw FormatException(context.l10n.theSelectedProviderReturnedAnUnsafe);
      }
      if (file.readStream == null) {
        throw UnsupportedError(context.l10n.thisFilePickerDoesNotProvide);
      }
      if (file.size > sshTransferMaximumBytes) {
        throw FormatException(context.l10n.fileExceeds1GibTransferLimit);
      }
      setState(() {
        _file = file;
        _error = null;
        if (widget.uploadIntoDirectory) {
          _path.text = sftpChildPath(widget.remotePath, file.name);
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _file = null;
          _error = context.l10n.couldNotOpenAStreamingFile;
        });
      }
    }
  }

  Future<void> _start() async {
    final source = _file;
    if (_upload && source == null) return;
    final cancellation = SshTransferCancellation();
    AttachmentStreamingSaveWriter? destination;
    Object? activity;
    try {
      final remotePath = validateSshTransferPath(_path.text);
      if (_legacySftpSelected) {
        setState(() {
          _busy = true;
          _legacySftpBusy = true;
          _error = null;
        });
        // This pre-existing bounded byte-save route has no cancellation API.
        // Keep Cancel disabled rather than promise cancellation after commit.
        await widget.legacySftpDownload!(remotePath);
        if (mounted) Navigator.pop(context, true);
        return;
      }
      // The picker remains directly in the button's user gesture for web saves.
      if (!_upload) {
        if (_mobile) {
          destination = MobileSshTransferSaveWriter(
            save: (bytes) => saveMobileSshTransferFile(
              fileName: widget.suggestedName ?? _path.text.split('/').last,
              bytes: bytes,
            ),
          );
        } else if (!supportsStreamingAttachmentSave) {
          throw UnsupportedError(
            context.l10n.streamingFileSavesAreUnavailableOn,
          );
        } else {
          destination = await openAttachmentStreamingSave(
            fileName: widget.suggestedName ?? _path.text.split('/').last,
            mediaType: 'application/octet-stream',
          );
          if (destination == null) return;
        }
      }
      if (!mounted) {
        await destination?.abort();
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
        _progress = null;
        _cancellation = cancellation;
      });
      activity = sshTransferActivity.begin(cancellation);
      void progress(SshTransferProgress p) {
        sshTransferActivity.update(activity!, p);
        if (mounted) setState(() => _progress = p);
      }

      final service = SshFileTransferService(
        widget.client,
        maximumBytes: _mobile && !_upload
            ? mobileSshTransferMaximumBytes
            : sshTransferMaximumBytes,
      );
      if (_upload) {
        await service.upload(
          protocol: _protocol,
          remotePath: _path.text,
          source: source!.readStream!.map(
            (bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          ),
          size: source.size,
          cancellation: cancellation,
          onProgress: progress,
        );
      } else {
        await service.download(
          protocol: _protocol,
          remotePath: _path.text,
          destination: destination!,
          cancellation: cancellation,
          onProgress: progress,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on SshTransferCancelled {
      if (mounted) {
        setState(() => _error = context.l10n.transferCancelled);
      }
    } on UnsupportedError {
      if (mounted) {
        setState(
          () => _error = context.l10n.streamingTransferIsUnavailableOnThis,
        );
      }
    } catch (_) {
      // Remote shell/SFTP errors can contain arbitrary server text. Do not echo it.
      if (mounted) {
        setState(
          () => _error = context.l10n.transferFailedCheckThePathPermissions,
        );
      }
    } finally {
      if (activity != null) sshTransferActivity.end(activity);
      if (mounted) {
        setState(() {
          _busy = false;
          _legacySftpBusy = false;
          _cancellation = null;
          if (_upload) _file = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        _upload ? context.l10n.uploadFile2 : context.l10n.downloadFile,
      ),
      content: SizedBox(
        width: appDialogWidth(context, 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<SshTransferProtocol>(
                segments: const [
                  ButtonSegment(
                    value: SshTransferProtocol.sftp,
                    label: Text('SFTP'),
                  ),
                  ButtonSegment(
                    value: SshTransferProtocol.scp,
                    label: Text('SCP'),
                  ),
                ],
                selected: {_protocol},
                onSelectionChanged: _busy
                    ? null
                    : (v) => setState(() => _protocol = v.single),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _path,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: context.l10n.remoteFilePath,
                ),
              ),
              if (_upload) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_file?.name ?? context.l10n.chooseLocalFile),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                _legacySftpSelected
                    ? context.l10n.sftpCompatibilityDownloadsUpTo16
                    : _mobile && !_upload
                    ? context.l10n.mobileDownloadsUpTo16Mib
                    : context.l10n.singleFilesUpTo1Gib,
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress?.fraction),
                const SizedBox(height: 8),
                Text(
                  _legacySftpBusy
                      ? context.l10n.downloadingWithSftpCompatibilityModeUp
                      : _progress == null
                      ? context.l10n.preparingTransfer
                      : '${_progress!.transferred} / ${_progress!.total} bytes${_progress!.phase == SshTransferPhase.committing ? ' · Finishing…' : ''}',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? (_cancellation?.canCancel == true
                    ? () {
                        _cancellation!.cancel();
                        setState(() {});
                      }
                    : null)
              : () => Navigator.pop(context, false),
          child: Text(_busy ? context.l10n.cancelTransfer : context.l10n.close),
        ),
        FilledButton(
          onPressed: _busy || (_upload && _file == null) ? null : _start,
          child: Text(_upload ? context.l10n.upload : context.l10n.download2),
        ),
      ],
    ),
  );
}
