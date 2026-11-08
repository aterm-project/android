import 'dart:async';

enum SshTransferProtocol { sftp, scp }

enum SshTransferPhase { transferring, committing, complete }

class SshTransferProgress {
  const SshTransferProgress(this.transferred, this.total, this.phase);
  final int transferred;
  final int total;
  final SshTransferPhase phase;
  double get fraction => total == 0
      ? (phase == SshTransferPhase.complete ? 1 : 0)
      : transferred / total;
}

class SshTransferCancelled implements Exception {
  const SshTransferCancelled();
  @override
  String toString() => 'File transfer cancelled.';
}

/// One transfer's cancellation scope. Publication is a short, non-cancellable
/// commit boundary: once entered, success/failure is reported rather than a
/// misleading cancellation after the complete destination became visible.
class SshTransferCancellation {
  final _cancelled = Completer<void>.sync();
  bool _committing = false;
  bool get isCancelled => _cancelled.isCompleted;
  bool get canCancel => !isCancelled && !_committing;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (canCancel) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const SshTransferCancelled();
  }

  void beginCommit() {
    check();
    _committing = true;
  }

  Future<T> wait<T>(
    Future<T> future, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    check();
    return Future.any<T>([
      future,
      whenCancelled.then<T>((_) => throw const SshTransferCancelled()),
    ]).timeout(timeout);
  }
}

const sshTransferMaximumBytes = 1024 * 1024 * 1024;
const sshTransferChunkBytes = 64 * 1024;

String validateSshTransferPath(String path) {
  if (path.isEmpty ||
      path.length > 4096 ||
      path.runes.any((c) => c < 32 || (c >= 127 && c <= 159))) {
    throw const FormatException(
      'Remote path contains unsupported control characters.',
    );
  }
  final name = path.split('/').last;
  if (name.isEmpty || name == '.' || name == '..') {
    throw const FormatException('Select one remote file.');
  }
  return path.startsWith('/') || path.startsWith('./') ? path : './$path';
}

/// POSIX single-quote encoding, including apostrophes. Call validation first.
String quoteSshTransferPath(String path) =>
    "'${path.replaceAll("'", "'\"'\"'")}'";

String scpDownloadCommand(String remotePath) =>
    'scp -f -- ${quoteSshTransferPath(validateSshTransferPath(remotePath))}';

String scpUploadCommand({
  required String remotePath,
  required String stageDirectory,
}) {
  final target = quoteSshTransferPath(validateSshTransferPath(remotePath));
  final stage = quoteSshTransferPath(validateSshTransferPath(stageDirectory));
  // mkdir owns an unpredictable directory atomically; traps are installed only
  // after that succeeds. ln refuses an existing destination, including symlinks.
  return 'd=$stage; t=$target; umask 077; mkdir -- "\$d" || exit 1; '
      'trap \'rm -f -- "\$d/payload"; rmdir -- "\$d"\' EXIT; '
      'trap \'exit 1\' HUP INT TERM; scp -t -- "\$d/payload" && ln -- "\$d/payload" "\$t"';
}
