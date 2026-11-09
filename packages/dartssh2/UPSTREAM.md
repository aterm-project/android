# dartssh2 upstream and local patch

- Upstream: [vicajilau/dartssh2](https://github.com/vicajilau/dartssh2)
- Base release: `dartssh2` 4.1.0 from the pub.dev hosted package
  (pubspec.lock sha256 `39359aceafcf5940b868249e3c9c6d86e4e0f989eec7417d033c943157c84c51`)
- Upstream license: MIT; the original `LICENSE` is retained in this directory
- Vendored scope: upstream `lib/` plus package metadata, README and CHANGELOG
  (tests, examples and media are not vendored)
- Local change: `lib/src/sftp/sftp_client.dart` adds the public
  `SftpClient.renameNoReplace(oldPath, newPath)`. It sends the standard
  `SSH_FXP_RENAME` request only. Upstream `rename` silently prefers the
  `posix-rename@openssh.com` extension, which REPLACES an existing
  destination; a client-side existence pre-check cannot close that race.
  The file manager's rename / cut-paste / drag-move use `renameNoReplace`.
  The existing `rename` behaviour is unchanged and is still used deliberately
  by the text editor's staged atomic replace (`DartSftpTextFileSystem`).

- Local change: `SftpClient.readdir` closes its directory handle in a
  `finally` block. Upstream closes it only after a full iteration, so a
  consumer that cancels the stream early (the file manager's bounded
  recursive planner stops at its entry limit) or a failed read leaked the
  remote handle. Full iteration, and therefore `listdir`, is unchanged.

When updating dartssh2, re-apply `renameNoReplace` (or switch to an upstream
no-replace API if one appears) and keep
`apps/client/test/remote_file_operations_test.dart` passing. The application
selects this package through the path override in `apps/client/pubspec.yaml`.
