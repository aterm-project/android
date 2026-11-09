import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'external_edit_policy.dart';

enum ExternalEditError {
  /// Browser/mobile: no external application can be watched.
  unsupported,
  tooMany,
  tooLarge,
  notRegularRemote,
  blockedType,

  /// The local copy became a link, directory or left its private folder.
  localRejected,
  localTooLarge,
  localMissing,

  /// The file tab closed or now belongs to another session/connection.
  sessionChanged,
  atomicReplaceUnsupported,
  launchFailed,
}

/// App-owned failure; the UI maps [error] to localized text. Never carries
/// file contents.
class ExternalEditException implements Exception {
  const ExternalEditException(this.error);
  final ExternalEditError error;

  @override
  String toString() => 'ExternalEditException(${error.name})';
}

/// One private local copy inside its own owned directory. The directory holds
/// only this file (plus whatever an editor writes next to it), so watching it
/// sees atomic "write temp + rename over" saves.
abstract interface class ExternalEditLocalCopy {
  String get path;

  /// Directory events (create/modify/move/delete). Closes on cancel.
  Stream<void> watch();

  /// Streaming SHA-256 of the current regular file at [path], bounded by
  /// [maxBytes]; `null` while the file is absent (mid atomic save). Throws
  /// [ExternalEditException] for links, non-regular files, escapes or
  /// oversized content.
  Future<Digest?> hash(int maxBytes);

  /// Exact bytes of the current regular file with the same checks as
  /// [hash]. The caller owns and clears the returned buffer.
  Future<Uint8List?> read(int maxBytes);

  /// Removes the copy and its owned directory.
  Future<void> delete();
}

/// A per-file-tab private temp root. [close] removes everything it created.
abstract interface class ExternalEditLocalWorkspace {
  Future<ExternalEditLocalCopy> createCopy(String localName, Uint8List bytes);

  Future<void> close();
}

abstract interface class ExternalEditPlatform {
  ExternalEditPlatformKind get kind;

  Future<ExternalEditLocalWorkspace> openWorkspace();

  /// Hands the absolute owned [path] to the OS without a shell. [mode] is
  /// never [ExternalEditLaunchMode.blocked].
  Future<void> launch(String path, ExternalEditLaunchMode mode);
}
