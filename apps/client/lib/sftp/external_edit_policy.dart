import 'dart:typed_data';

import 'sftp_text_editor_service.dart' show sftpTextFileMaxBytes;

/// Largest remote file that can be edited in an external application. It is
/// the same bound the SFTP text filesystem enforces on every read, so the
/// local copy, the upload snapshot and the remote re-checks share one limit.
const externalEditMaxBytes = sftpTextFileMaxBytes;

/// Concurrent external edits (and therefore directory watchers and private
/// temp copies) per file tab.
const externalEditMaxConcurrent = 8;

/// How a downloaded copy may be handed to the operating system.
enum ExternalEditLaunchMode {
  /// The platform's associated application ("open").
  open,

  /// A text-editing verb that never executes the file: ShellExecute "edit"
  /// on Windows, `open -t` on macOS.
  edit,

  /// Opening could execute remote bytes and no safe editing verb exists.
  blocked,
}

enum ExternalEditPlatformKind { windows, macos, linux, unsupported }

/// Formats that launch, install, redirect or execute when "opened".
/// Compared case-insensitively against the sanitized local name.
const _activeExtensions = {
  // Windows executables, installers, shortcuts and shell objects.
  'exe', 'com', 'scr', 'pif', 'cpl', 'msc', 'msi', 'msp', 'mst', 'lnk', 'url',
  'application', 'appref-ms', 'settingcontent-ms', 'library-ms', 'search-ms',
  'searchconnector-ms', 'gadget', 'hta', 'scf', 'chm', 'diagcab', 'xbap',
  'appx', 'appxbundle', 'msix', 'msixbundle', 'cab', 'website', 'shs',
  // Windows scripts (have an "edit" verb).
  'bat', 'cmd', 'ps1', 'psm1', 'psd1', 'ps1xml', 'vbs', 'vbe', 'js', 'jse',
  'wsf', 'wsh', 'wsc', 'reg', 'inf', 'sct',
  // Cross-platform runtimes.
  'jar', 'jnlp',
  // Linux launchers and executables.
  'desktop', 'appimage', 'run', 'bin', 'sh', 'bash', 'zsh', 'csh', 'ksh',
  'fish', 'flatpakref', 'flatpakrepo', 'snap', 'deb', 'rpm',
  // macOS launchers, bundles and location files.
  'app', 'command', 'tool', 'terminal', 'webloc', 'inetloc', 'fileloc',
  'workflow', 'action', 'pkg', 'mpkg', 'prefpane', 'saver', 'kext', 'plugin',
  'scpt', 'scptd', 'osascript',
};

/// Script formats Windows can open with its "edit" verb (Notepad/ISE).
const _windowsEditableScripts = {
  'bat',
  'cmd',
  'ps1',
  'psm1',
  'psd1',
  'ps1xml',
  'vbs',
  'vbe',
  'js',
  'jse',
  'wsf',
  'wsh',
  'wsc',
  'reg',
  'inf',
  'sct',
};

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

bool _startsWith(Uint8List head, List<int> magic) {
  if (head.length < magic.length) return false;
  for (var index = 0; index < magic.length; index++) {
    if (head[index] != magic[index]) return false;
  }
  return true;
}

/// Content that some desktops sniff as runnable regardless of extension.
bool externalEditLooksExecutable(Uint8List head) =>
    _startsWith(head, const [0x23, 0x21]) || // #!
    _startsWith(head, const [0x7f, 0x45, 0x4c, 0x46]) || // ELF
    _startsWith(head, const [0x4d, 0x5a]) || // MZ (PE)
    _startsWith(head, const [0xcf, 0xfa, 0xed, 0xfe]) || // Mach-O 64
    _startsWith(head, const [0xce, 0xfa, 0xed, 0xfe]) || // Mach-O
    _startsWith(head, const [0xca, 0xfe, 0xba, 0xbe]) || // fat / class
    _startsWith(head, '[Desktop Entry]'.codeUnits);

/// Chooses how [localName] (already sanitized) may be launched.
///
/// Windows decides by extension only, so active scripts use "edit" and other
/// active formats are blocked. macOS uses `open -t` (default text editor) for
/// active, extensionless or executable-looking content. Linux has no portable
/// edit verb and `xdg-open` sniffs content, so those are blocked honestly.
ExternalEditLaunchMode externalEditLaunchMode(
  String localName,
  Uint8List head,
  ExternalEditPlatformKind platform,
) {
  final extension = _extension(localName);
  final active = _activeExtensions.contains(extension);
  final executableContent = externalEditLooksExecutable(head);
  switch (platform) {
    case ExternalEditPlatformKind.windows:
      if (!active) return ExternalEditLaunchMode.open;
      return _windowsEditableScripts.contains(extension)
          ? ExternalEditLaunchMode.edit
          : ExternalEditLaunchMode.blocked;
    case ExternalEditPlatformKind.macos:
      return active || executableContent || extension.isEmpty
          ? ExternalEditLaunchMode.edit
          : ExternalEditLaunchMode.open;
    case ExternalEditPlatformKind.linux:
      return active || executableContent
          ? ExternalEditLaunchMode.blocked
          : ExternalEditLaunchMode.open;
    case ExternalEditPlatformKind.unsupported:
      return ExternalEditLaunchMode.blocked;
  }
}

const _windowsReservedNames = {
  'con', 'prn', 'aux', 'nul', 'conin\$', 'conout\$', //
  'com0', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8',
  'com9', 'lpt0', 'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7',
  'lpt8', 'lpt9', 'com¹', 'com²', 'com³', 'lpt¹', 'lpt²', 'lpt³',
};

const _maxLocalNameLength = 120;

/// A local file name for the remote basename [remoteName] that is valid and
/// inert on every desktop: no separators, NTFS stream colons, wildcard or
/// control characters, no trailing dots/spaces (which Windows strips, turning
/// `a.exe.` into `a.exe`), no reserved device names, bounded length with the
/// extension preserved so the associated application still matches.
String externalEditLocalName(String remoteName) {
  final buffer = StringBuffer();
  for (final rune in remoteName.runes) {
    final invalid =
        rune < 0x20 ||
        rune == 0x7f ||
        (rune >= 0x80 && rune < 0xa0) ||
        rune == 0x202e || // right-to-left override disguises extensions
        rune == 0x202d ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        '<>:"/\\|?*'.runes.contains(rune);
    buffer.writeCharCode(invalid ? 0x5f : rune);
  }
  var name = buffer.toString().replaceAll(RegExp(r'[. ]+$'), '');
  name = name.replaceAll(RegExp(r'^[ ]+'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'file';
  final stem = name.split('.').first.toLowerCase().trimRight();
  if (_windowsReservedNames.contains(stem)) name = '_$name';
  if (name.length > _maxLocalNameLength) {
    final extension = _extension(name);
    final keep = extension.isEmpty || extension.length > 16
        ? ''
        : '.$extension';
    final runes = name.runes.toList();
    final stemRunes = runes.take(_maxLocalNameLength - keep.length).toList();
    name = String.fromCharCodes(stemRunes).replaceAll(RegExp(r'[. ]+$'), '');
    name = '${name.isEmpty ? 'file' : name}$keep';
  }
  return name;
}
