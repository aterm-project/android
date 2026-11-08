/// Platform-neutral description of an embedded local shell.
///
/// Only non-secret launch metadata is modelled here: a shell *kind* chosen
/// from a fixed list and an optional working directory. Executable paths are
/// never read from configuration or saved layouts; they are resolved at launch
/// time from well-known install locations / `PATH`, and the process is started
/// directly with an argument list (no command-line string is evaluated).
library;

enum LocalShellKind { system, cmd, powershell, pwsh, bash, zsh, fish, sh }

/// Reason a shell cannot be started. UI maps these to localized text.
enum LocalShellIssue {
  unsupportedPlatform,
  shellNotInstalled,
  invalidWorkingDirectory,
  workingDirectoryNotFound,
}

class LocalShellException implements Exception {
  const LocalShellException(this.issue);
  final LocalShellIssue issue;
  @override
  String toString() => 'LocalShellException(${issue.name})';
}

const int maxLocalShellWorkingDirectoryBytes = 4096;

class LocalShellLaunch {
  const LocalShellLaunch({
    this.kind = LocalShellKind.system,
    this.workingDirectory,
  });

  static const systemDefault = LocalShellLaunch();

  final LocalShellKind kind;

  /// Absolute path (or `~`/`~/...`) chosen by the user; null = home.
  final String? workingDirectory;

  bool get isDefault => kind == LocalShellKind.system && workingDirectory == null;

  LocalShellLaunch copyWith({
    LocalShellKind? kind,
    String? workingDirectory,
    bool clearWorkingDirectory = false,
  }) => LocalShellLaunch(
    kind: kind ?? this.kind,
    workingDirectory: clearWorkingDirectory
        ? null
        : workingDirectory ?? this.workingDirectory,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (workingDirectory != null) 'cwd': workingDirectory,
  };

  /// Strict parser for saved layouts; unknown keys/kinds are rejected.
  factory LocalShellLaunch.fromJson(Object? json) {
    if (json is! Map ||
        json.keys.any((key) => key != 'kind' && key != 'cwd') ||
        json['kind'] is! String ||
        (json['cwd'] != null && json['cwd'] is! String)) {
      throw const FormatException('Invalid local shell.');
    }
    final kind = LocalShellKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    final cwd = json['cwd'] as String?;
    if (kind == null ||
        (cwd != null && !isPlausibleLocalShellWorkingDirectory(cwd))) {
      throw const FormatException('Invalid local shell.');
    }
    return LocalShellLaunch(kind: kind, workingDirectory: cwd);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalShellLaunch &&
      other.kind == kind &&
      other.workingDirectory == workingDirectory;

  @override
  int get hashCode => Object.hash(kind, workingDirectory);

  @override
  String toString() => 'LocalShellLaunch(${kind.name})';
}

/// Syntax-only check shared by the editor dialog and saved-layout parser.
/// Accepts POSIX absolute paths, Windows drive paths, `~` and `~/...`.
/// Existence is checked separately at launch time.
bool isPlausibleLocalShellWorkingDirectory(String value) {
  if (value.isEmpty ||
      value.length > maxLocalShellWorkingDirectoryBytes ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return false;
  }
  if (value == '~' || value.startsWith('~/') || value.startsWith(r'~\')) {
    return true;
  }
  return value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}

/// Resolved, ready-to-spawn shell. [arguments] is passed verbatim as argv.
class LocalShellCommand {
  const LocalShellCommand({
    required this.kind,
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
  });
  final LocalShellKind kind;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}

/// Host facts used for resolution, injectable for tests.
class LocalShellHost {
  const LocalShellHost({
    required this.isWindows,
    required this.environment,
    required this.isFile,
    required this.isDirectory,
  });
  final bool isWindows;
  final Map<String, String> environment;
  final bool Function(String path) isFile;
  final bool Function(String path) isDirectory;

  String? get home =>
      _nonEmpty(environment[isWindows ? 'USERPROFILE' : 'HOME']);
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty || value.contains('\x00') ? null : value;

const _posixInteractiveShells = {
  'sh',
  'bash',
  'zsh',
  'fish',
  'ksh',
  'mksh',
  'dash',
  'tcsh',
  'csh',
};

String _basename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

bool _absoluteFor(LocalShellHost host, String path) => host.isWindows
    ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)
    : path.startsWith('/');

List<String> _pathDirectories(LocalShellHost host) {
  final raw = host.environment[host.isWindows ? 'Path' : 'PATH'] ??
      host.environment['PATH'] ??
      '';
  return [
    for (final entry in raw.split(host.isWindows ? ';' : ':'))
      if (entry.isNotEmpty &&
          !entry.contains('\x00') &&
          _absoluteFor(host, entry))
        entry,
  ];
}

String _join(LocalShellHost host, String directory, String name) {
  final sep = host.isWindows ? r'\' : '/';
  return directory.endsWith('/') || directory.endsWith(r'\')
      ? '$directory$name'
      : '$directory$sep$name';
}

String? _firstFile(LocalShellHost host, Iterable<String> candidates) {
  for (final candidate in candidates) {
    if (_absoluteFor(host, candidate) && host.isFile(candidate)) {
      return candidate;
    }
  }
  return null;
}

String? _searchPath(LocalShellHost host, String name, {List<String>? extra}) =>
    _firstFile(host, [
      for (final dir in _pathDirectories(host)) _join(host, dir, name),
      ...?extra,
    ]);

String _systemRoot(LocalShellHost host) {
  final root = _nonEmpty(host.environment['SystemRoot']) ??
      _nonEmpty(host.environment['SYSTEMROOT']) ??
      _nonEmpty(host.environment['windir']);
  return root != null && _absoluteFor(host, root) ? root : r'C:\Windows';
}

String? _programFiles(LocalShellHost host) {
  final value = _nonEmpty(host.environment['ProgramFiles']) ??
      _nonEmpty(host.environment['PROGRAMFILES']);
  return value != null && _absoluteFor(host, value) ? value : null;
}

/// Locate a shell executable and its fixed interactive arguments.
({String executable, List<String> arguments})? _locate(
  LocalShellHost host,
  LocalShellKind kind,
) {
  if (host.isWindows) {
    final system32 = '${_systemRoot(host)}\\System32';
    switch (kind) {
      case LocalShellKind.system:
        final comspec = _nonEmpty(host.environment['COMSPEC']) ??
            _nonEmpty(host.environment['ComSpec']);
        final executable = comspec != null &&
                comspec.toLowerCase().endsWith('.exe') &&
                _absoluteFor(host, comspec) &&
                host.isFile(comspec)
            ? comspec
            : _firstFile(host, ['$system32\\cmd.exe']);
        return executable == null
            ? null
            : (executable: executable, arguments: const <String>[]);
      case LocalShellKind.cmd:
        final executable = _firstFile(host, ['$system32\\cmd.exe']);
        return executable == null
            ? null
            : (executable: executable, arguments: const <String>[]);
      case LocalShellKind.powershell:
        final executable = _firstFile(host, [
          '$system32\\WindowsPowerShell\\v1.0\\powershell.exe',
        ]);
        return executable == null
            ? null
            : (executable: executable, arguments: const ['-NoLogo']);
      case LocalShellKind.pwsh:
        final programFiles = _programFiles(host);
        final executable = _firstFile(host, [
          if (programFiles != null) '$programFiles\\PowerShell\\7\\pwsh.exe',
          if (programFiles != null)
            '$programFiles\\PowerShell\\7-preview\\pwsh.exe',
          ..._pathDirectories(host).map((d) => _join(host, d, 'pwsh.exe')),
        ]);
        return executable == null
            ? null
            : (executable: executable, arguments: const ['-NoLogo']);
      case LocalShellKind.bash:
        final programFiles = _programFiles(host);
        final executable = _firstFile(host, [
          if (programFiles != null) '$programFiles\\Git\\bin\\bash.exe',
        ]);
        return executable == null
            ? null
            : (executable: executable, arguments: const ['--login', '-i']);
      case LocalShellKind.zsh:
      case LocalShellKind.fish:
      case LocalShellKind.sh:
        return null;
    }
  }
  const fallbackDirs = ['/bin', '/usr/bin', '/usr/local/bin', '/opt/homebrew/bin'];
  switch (kind) {
    case LocalShellKind.system:
      final shell = _nonEmpty(host.environment['SHELL']);
      final executable = shell != null &&
              shell.startsWith('/') &&
              !RegExp(r'[\x00-\x1f\x7f]').hasMatch(shell) &&
              host.isFile(shell)
          ? shell
          : _firstFile(host, ['/bin/sh']);
      if (executable == null) return null;
      return (
        executable: executable,
        arguments: _posixInteractiveShells.contains(_basename(executable))
            ? const ['-i']
            : const <String>[],
      );
    case LocalShellKind.cmd:
    case LocalShellKind.powershell:
      return null;
    case LocalShellKind.pwsh:
      final executable = _searchPath(
        host,
        'pwsh',
        extra: [for (final dir in fallbackDirs) '$dir/pwsh'],
      );
      return executable == null
          ? null
          : (executable: executable, arguments: const ['-NoLogo']);
    case LocalShellKind.bash:
    case LocalShellKind.zsh:
    case LocalShellKind.fish:
    case LocalShellKind.sh:
      final name = kind.name;
      final executable = name == 'sh'
          ? _firstFile(host, ['/bin/sh'])
          : _searchPath(
              host,
              name,
              extra: [for (final dir in fallbackDirs) '$dir/$name'],
            );
      return executable == null
          ? null
          : (executable: executable, arguments: const ['-i']);
  }
}

/// Expands `~` and checks syntax + existence. Returns null for "home".
String? _resolveWorkingDirectory(LocalShellHost host, String? requested) {
  if (requested == null) {
    final home = host.home;
    return home != null && host.isDirectory(home) ? home : null;
  }
  if (!isPlausibleLocalShellWorkingDirectory(requested)) {
    throw const LocalShellException(LocalShellIssue.invalidWorkingDirectory);
  }
  var path = requested;
  if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
    final home = host.home;
    if (home == null) {
      throw const LocalShellException(LocalShellIssue.workingDirectoryNotFound);
    }
    path = path == '~' ? home : _join(host, home, path.substring(2));
  }
  if (!_absoluteFor(host, path)) {
    throw const LocalShellException(LocalShellIssue.invalidWorkingDirectory);
  }
  if (!host.isDirectory(path)) {
    throw const LocalShellException(LocalShellIssue.workingDirectoryNotFound);
  }
  return path;
}

/// Resolve [launch] into an executable + argv. Throws [LocalShellException].
LocalShellCommand resolveLocalShell(LocalShellLaunch launch, LocalShellHost host) {
  final located = _locate(host, launch.kind);
  if (located == null) {
    throw const LocalShellException(LocalShellIssue.shellNotInstalled);
  }
  return LocalShellCommand(
    kind: launch.kind,
    executable: located.executable,
    arguments: List.unmodifiable(located.arguments),
    workingDirectory: _resolveWorkingDirectory(host, launch.workingDirectory),
  );
}

/// Shell kinds that resolve on [host], system default first. Duplicate
/// executables (e.g. `$SHELL` == bash) are still listed by kind so the user
/// can pick explicitly.
List<LocalShellKind> availableLocalShells(LocalShellHost host) => [
  for (final kind in LocalShellKind.values)
    if (_locate(host, kind) != null) kind,
];
