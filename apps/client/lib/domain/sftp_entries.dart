import 'package:dartssh2/dartssh2.dart';

/// Whether [filename] can be used as one path component supplied by a remote
/// SFTP directory entry or a local file picker.
///
/// Filenames come from the remote server and must never be trusted as paths.
/// Backslashes are rejected as well as POSIX separators so a name cannot be
/// reinterpreted as a path on another client platform.
bool isSafeSftpBasename(String filename) =>
    filename.isNotEmpty &&
    filename != '.' &&
    filename != '..' &&
    !filename.contains('/') &&
    !filename.contains('\\') &&
    !containsSftpControlCharacters(filename);

/// Rejects control code points that can make an untrusted remote name or path
/// render ambiguously or alter terminal/log text.
bool containsSftpControlCharacters(String value) =>
    value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f));

/// Joins a selected remote directory with one validated child basename.
///
/// This deliberately accepts an explicitly selected parent path as-is; the
/// child component is the untrusted part and may not contain path syntax.
String sftpChildPath(String parent, String child) {
  if (!isSafeSftpBasename(child)) {
    throw const FormatException('SFTP filename is not a safe basename.');
  }
  if (containsSftpControlCharacters(parent)) {
    throw const FormatException(
      'SFTP parent path contains control characters.',
    );
  }
  final normalizedParent = parent.replaceFirst(RegExp(r'/+$'), '');
  return normalizedParent.isEmpty ? '/$child' : '$normalizedParent/$child';
}

/// Hides navigation pseudo entries and path-like or malformed names from an
/// untrusted remote directory listing.
List<SftpName> visibleSftpEntries(Iterable<SftpName> entries) =>
    List.unmodifiable(
      entries.where((entry) => isSafeSftpBasename(entry.filename)),
    );
