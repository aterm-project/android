import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';
import '../attachments/attachment_file_saver_model.dart';
import '../domain/sftp_transfer.dart';
import 'scp_protocol.dart';
import 'scp_transfer_types.dart';
export 'scp_transfer_types.dart';

/// Shared by cloud and LocalVault sessions. The existing authenticated SSH client
/// remains owned by its terminal; every transfer opens and closes its own channels.
class SshFileTransferService {
  SshFileTransferService(
    this.client, {
    this.maximumBytes = sshTransferMaximumBytes,
  });
  final SSHClient client;
  final int maximumBytes;

  Future<void> upload({
    required SshTransferProtocol protocol,
    required String remotePath,
    required Stream<Uint8List> source,
    required int size,
    required SshTransferCancellation cancellation,
    void Function(SshTransferProgress)? onProgress,
  }) async {
    final path = validateSshTransferPath(remotePath);
    if (size < 0 || size > maximumBytes) {
      throw const FormatException('File exceeds transfer size limit.');
    }
    final slash = path.lastIndexOf('/');
    final parent = slash == 0 ? '/' : path.substring(0, slash);
    final stage = '$parent/.atermius-transfer-${const Uuid().v4()}';
    if (protocol == SshTransferProtocol.scp) {
      final channel = await _open(
        scpUploadCommand(remotePath: path, stageDirectory: stage),
        cancellation,
      );
      var ownedStage = false;
      try {
        await ScpProtocol(
          channel,
          cancellation,
          maximumBytes: maximumBytes,
        ).upload(
          source: source,
          size: size,
          onProgress: (p) {
            ownedStage = true;
            onProgress?.call(p);
          },
        );
      } catch (_) {
        if (ownedStage) await _cleanupScp(stage);
        rethrow;
      }
      return;
    }
    SftpClient? sftp;
    SftpFile? file;
    var created = false;
    var complete = false;
    try {
      sftp = await _sftp(cancellation);
      final handshake = await cancellation.wait(sftp.handshake);
      if (!supportsSftpExclusiveCreate(handshake.version)) {
        throw UnsupportedError('Safe upload requires SFTP v3 or later.');
      }
      // Do not abandon exclusive-create before its ownership response: otherwise
      // cancelling an in-flight open could mistake an existing file for ours.
      file = await sftp
          .open(path, mode: sftpExclusiveCreateMode)
          .timeout(const Duration(seconds: 30));
      created = true;
      cancellation.check();
      var sent = 0;
      onProgress?.call(
        SshTransferProgress(0, size, SshTransferPhase.transferring),
      );
      final iterator = StreamIterator(source);
      try {
        while (await cancellation.wait(iterator.moveNext())) {
          final chunk = iterator.current;
          if (sent + chunk.length > size) {
            throw const FormatException('Local file changed length.');
          }
          for (
            var offset = 0;
            offset < chunk.length;
            offset += sshTransferChunkBytes
          ) {
            final part = Uint8List.sublistView(
              chunk,
              offset,
              min(chunk.length, offset + sshTransferChunkBytes),
            );
            await cancellation.wait(
              file.writeBytes(part, offset: sent, maxPendingRequests: 1),
            );
            sent += part.length;
            onProgress?.call(
              SshTransferProgress(sent, size, SshTransferPhase.transferring),
            );
          }
        }
      } finally {
        await iterator.cancel();
      }
      if (sent != size) {
        throw const FormatException('Local file changed length.');
      }
      await cancellation.wait(file.close());
      file = null;
      cancellation.beginCommit();
      onProgress?.call(
        SshTransferProgress(sent, size, SshTransferPhase.committing),
      );
      complete = true;
      onProgress?.call(
        SshTransferProgress(sent, size, SshTransferPhase.complete),
      );
    } finally {
      // Closing only this transfer's SFTP channel also releases pending requests.
      try {
        await sftp?.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
      if (created && !complete) {
        // SFTP v3 has no unlink-by-handle. As with the existing upload flow,
        // callers reserve this newly-created pathname until transfer finishes.
        final cleanup = await client.sftp().timeout(
          const Duration(seconds: 10),
        );
        try {
          await cleanup.remove(path).timeout(const Duration(seconds: 10));
        } finally {
          await cleanup.close().timeout(const Duration(seconds: 5));
        }
      }
    }
  }

  Future<int> download({
    required SshTransferProtocol protocol,
    required String remotePath,
    required AttachmentStreamingSaveWriter destination,
    required SshTransferCancellation cancellation,
    void Function(SshTransferProgress)? onProgress,
  }) async {
    SftpClient? sftp;
    var received = 0;
    var total = 0;
    try {
      final path = validateSshTransferPath(remotePath);
      if (protocol == SshTransferProtocol.scp) {
        final channel = await _open(scpDownloadCommand(path), cancellation);
        received =
            await ScpProtocol(
              channel,
              cancellation,
              maximumBytes: maximumBytes,
            ).download(
              onChunk: destination.write,
              onProgress: (p) {
                total = p.total;
                onProgress?.call(p);
              },
            );
      } else {
        sftp = await _sftp(cancellation);
        final attributes = await cancellation.wait(
          sftp.stat(path, followLink: false),
        );
        if (attributes.mode?.type != SftpFileType.regularFile ||
            attributes.size == null ||
            attributes.size! < 0 ||
            attributes.size! > maximumBytes) {
          throw const FormatException('Select a bounded regular file.');
        }
        final file = await cancellation.wait(sftp.open(path));
        final opened = await cancellation.wait(file.stat());
        if (opened.mode?.type != SftpFileType.regularFile ||
            opened.size != attributes.size) {
          throw const FormatException('Remote file changed before opening.');
        }
        total = opened.size!;
        onProgress?.call(
          SshTransferProgress(0, total, SshTransferPhase.transferring),
        );
        final iterator = StreamIterator(
          file.read(
            length: total + 1,
            chunkSize: sshTransferChunkBytes,
            maxPendingRequests: 1,
          ),
        );
        try {
          while (await cancellation.wait(iterator.moveNext())) {
            final part = iterator.current;
            if (received + part.length > total) {
              throw const FormatException('Remote file changed length.');
            }
            await cancellation.wait(destination.write(part));
            received += part.length;
            onProgress?.call(
              SshTransferProgress(
                received,
                total,
                SshTransferPhase.transferring,
              ),
            );
          }
        } finally {
          await iterator.cancel();
        }
        if (received != total) {
          throw const FormatException('Remote file was truncated.');
        }
        final after = await cancellation.wait(file.stat());
        if (after.size != total ||
            (opened.modifyTime != null &&
                after.modifyTime != opened.modifyTime)) {
          throw const FormatException('Remote file changed during download.');
        }
        await cancellation.wait(file.close());
      }
      cancellation.beginCommit();
      onProgress?.call(
        SshTransferProgress(received, total, SshTransferPhase.committing),
      );
      await destination.commit();
      onProgress?.call(
        SshTransferProgress(received, total, SshTransferPhase.complete),
      );
      return received;
    } catch (_) {
      await destination.abort();
      rethrow;
    } finally {
      try {
        await sftp?.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  Future<void> _cleanupScp(String stage) async {
    final path = quoteSshTransferPath(stage);
    final channel = await _open(
      'd=$path; rm -f -- "\$d/payload"; rmdir -- "\$d" 2>/dev/null; test ! -e "\$d"',
      null,
    );
    try {
      final iterator = StreamIterator(channel.stdout);
      var count = 0;
      try {
        while (await iterator.moveNext().timeout(const Duration(seconds: 10))) {
          count += iterator.current.length;
          if (count > 4096) {
            throw const FormatException('Unexpected cleanup output.');
          }
        }
      } finally {
        await iterator.cancel();
      }
      await channel.done.timeout(const Duration(seconds: 10));
      if (channel.exitCode != 0) {
        throw const ScpProtocolException(
          'Remote temporary file cleanup failed.',
        );
      }
    } finally {
      channel.close();
    }
  }

  Future<SftpClient> _sftp(SshTransferCancellation cancel) async {
    final opening = client.sftp();
    try {
      return await cancel.wait(opening);
    } catch (_) {
      unawaited(opening.then((value) => value.close()).catchError((_) {}));
      rethrow;
    }
  }

  Future<_SshScpChannel> _open(
    String command,
    SshTransferCancellation? cancel,
  ) async {
    final opening = client.execute(command);
    try {
      final session = cancel == null
          ? await opening.timeout(const Duration(seconds: 30))
          : await cancel.wait(opening);
      return _SshScpChannel(session);
    } catch (_) {
      unawaited(
        opening.then((value) => value.channel.destroy()).catchError((_) {}),
      );
      rethrow;
    }
  }
}

class _SshScpChannel implements ScpChannel {
  _SshScpChannel(this.session) {
    // Never buffer or disclose remote diagnostics. Bound their aggregate size.
    _errors = session.stderr.listen((bytes) {
      _errorBytes += bytes.length;
      if (_errorBytes > 16384) close();
    }, onError: (_) => close());
  }
  final SSHSession session;
  late final StreamSubscription<Uint8List> _errors;
  var _errorBytes = 0;
  @override
  Stream<Uint8List> get stdout => session.stdout;
  @override
  int? get exitCode => session.exitCode;
  @override
  Future<void> get done => session.done;
  @override
  Future<void> send(Uint8List bytes) async {
    // addStream propagates channel-window backpressure. Socket.flush() races
    // concurrent SSH packet writes in dartssh2 and does not drain its stdin queue.
    await session.stdin.addStream(Stream<Uint8List>.value(bytes));
  }

  @override
  Future<void> finishInput() async {
    unawaited(session.stdin.close().catchError((_) {}));
  }

  @override
  void close() {
    session.channel.destroy();
    unawaited(_errors.cancel());
  }
}
