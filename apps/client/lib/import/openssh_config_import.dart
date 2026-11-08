import 'dart:convert';

import '../l10n/l10n.dart';

/// Maximum size accepted by the OpenSSH config picker and parser.
const maxOpenSshConfigBytes = 1024 * 1024;
const _maxOpenSshConfigLines = 4096;
const _maxOpenSshConfigLineLength = 8192;
const _maxOpenSshConfigHosts = 256;

/// A safe, deliberately limited projection of one OpenSSH `Host` alias.
///
/// This model never retains an IdentityFile path or an unrecognized directive
/// value. The importer uses these fields only to create saved Host records.
class OpenSshConfigHost {
  const OpenSshConfigHost({
    required this.alias,
    required this.hostLine,
    required this.address,
    required this.username,
    required this.port,
    required this.fieldLines,
    required this.proxyJumpAlias,
    required this.issues,
  });

  final String alias;
  final int hostLine;
  final String address;
  final String? username;
  final int port;
  final Map<String, int> fieldLines;
  final String? proxyJumpAlias;
  final List<OpenSshConfigIssue> issues;

  bool get hasBlockingIssue => issues.any((issue) => issue.blocking);

  bool get canImport => !hasBlockingIssue && username != null;
}

/// A user-visible parser finding. Messages contain directive names and line
/// numbers, never argument values such as usernames, paths, or command text.
class OpenSshConfigIssue {
  const OpenSshConfigIssue({
    required this.line,
    required this.directive,
    String? message,
    this.messageBuilder,
    required this.blocking,
    this.alias,
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : assert(message != null || messageBuilder != null),
       _message = message;

  final int line;
  final String directive;
  final String? _message;
  final String Function()? messageBuilder;

  String get message => messageBuilder?.call() ?? _message ?? '';
  final bool blocking;

  /// Null means this issue affects interpretation of the whole file.
  final String? alias;
}

class OpenSshConfigParseResult {
  const OpenSshConfigParseResult({
    required this.hosts,
    required this.issues,
    required this.blocksWholeFile,
  });

  final List<OpenSshConfigHost> hosts;
  final List<OpenSshConfigIssue> issues;
  final bool blocksWholeFile;

  bool get canImportAny =>
      !blocksWholeFile && hosts.any((host) => host.canImport);
}

/// Parses only literal Host aliases and a small, non-executing option set.
///
/// Includes, Match blocks, wildcard Host patterns, and command directives are
/// not expanded or executed. They produce blocking findings. IdentityFile is
/// reported but its path is discarded and never opened.
class OpenSshConfigImporter {
  const OpenSshConfigImporter._();

  static OpenSshConfigParseResult parse(String source) {
    if (source.length > maxOpenSshConfigBytes ||
        utf8.encode(source).length > maxOpenSshConfigBytes) {
      return OpenSshConfigParseResult(
        hosts: [],
        issues: [
          OpenSshConfigIssue(
            line: 1,
            directive: 'file',
            messageBuilder: () => currentL10n.theConfigFileExceedsThe1,
            blocking: true,
          ),
        ],
        blocksWholeFile: true,
      );
    }

    final lines = source.split(RegExp(r'\r\n|\n|\r'));
    if (lines.length > _maxOpenSshConfigLines) {
      return OpenSshConfigParseResult(
        hosts: [],
        issues: [
          OpenSshConfigIssue(
            line: 1,
            directive: 'file',
            messageBuilder: () => currentL10n.theConfigFileHasTooMany,
            blocking: true,
          ),
        ],
        blocksWholeFile: true,
      );
    }

    final builders = <String, _HostBuilder>{};
    final globalValues = <String, _DirectiveValue>{};
    final issues = <OpenSshConfigIssue>[];
    List<_HostBuilder>? current;
    var blocksWholeFile = false;

    void addFileIssue(
      int line,
      String directive,
      String Function() messageBuilder,
    ) {
      issues.add(
        OpenSshConfigIssue(
          line: line,
          directive: directive,
          messageBuilder: messageBuilder,
          blocking: true,
        ),
      );
      blocksWholeFile = true;
    }

    for (var index = 0; index < lines.length; index++) {
      final lineNumber = index + 1;
      final line = lines[index];
      if (line.length > _maxOpenSshConfigLineLength) {
        addFileIssue(
          lineNumber,
          'line',
          () => currentL10n.sshImportLineTooLong,
        );
        continue;
      }
      if (RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]')
          .hasMatch(line)) {
        addFileIssue(
          lineNumber,
          'line',
          () => currentL10n.sshImportControlCharacter,
        );
        continue;
      }

      final withoutComment = _stripComment(line);
      if (withoutComment == null) {
        addFileIssue(
          lineNumber,
          'quote',
          () => currentL10n.sshImportUnterminatedQuote,
        );
        continue;
      }
      final rawTokens = _tokenize(withoutComment);
      if (rawTokens == null) {
        addFileIssue(
          lineNumber,
          'quote',
          () => currentL10n.sshImportUnterminatedQuote,
        );
        continue;
      }
      if (rawTokens.isEmpty) continue;

      final equalsAt = rawTokens.first.indexOf('=');
      final tokens = equalsAt <= 0
          ? rawTokens
          : [
              rawTokens.first.substring(0, equalsAt),
              rawTokens.first.substring(equalsAt + 1),
              ...rawTokens.skip(1),
            ];

      final directive = tokens.first.toLowerCase();
      if (directive == 'host') {
        if (tokens.length < 2) {
          addFileIssue(
            lineNumber,
            'Host',
            () => currentL10n.sshImportAliasRequired,
          );
          current = null;
          continue;
        }
        final aliases = tokens.skip(1).toList(growable: false);
        if (aliases.any((alias) => !_isLiteralAlias(alias))) {
          addFileIssue(
            lineNumber,
            'Host',
            () => currentL10n.sshImportUnsupportedPattern,
          );
          current = null;
          continue;
        }
        final next = <_HostBuilder>[];
        for (final alias in aliases) {
          final key = _normalizedAlias(alias);
          var builder = builders[key];
          if (builder == null) {
            if (builders.length >= _maxOpenSshConfigHosts) {
              addFileIssue(
                lineNumber,
                'Host',
                () => currentL10n.sshImportHostLimit,
              );
              break;
            }
            builder = _HostBuilder(alias: alias, hostLine: lineNumber)
              ..values.addAll(globalValues);
            builders[key] = builder;
          }
          next.add(builder);
        }
        current = next;
        continue;
      }

      if (directive == 'include') {
        addFileIssue(lineNumber, 'Include', () => currentL10n.sshImportInclude);
        current = null;
        continue;
      }
      if (directive == 'match') {
        addFileIssue(lineNumber, 'Match', () => currentL10n.sshImportMatch);
        current = null;
        continue;
      }

      if (directive == 'proxycommand' || directive == 'localcommand') {
        final targets = current;
        if (targets == null || targets.isEmpty) {
          addFileIssue(
            lineNumber,
            tokens.first,
            () => currentL10n.sshImportGlobalCommand,
          );
        } else {
          for (final host in targets) {
            host.issues.add(
              OpenSshConfigIssue(
                line: lineNumber,
                directive: tokens.first,
                messageBuilder: () =>
                    currentL10n.commandDirectivesAreNeverExecutedThis,
                blocking: true,
                alias: host.alias,
              ),
            );
          }
        }
        continue;
      }

      final valueTokens = tokens.skip(1).toList(growable: false);
      if (directive == 'identityfile') {
        if (valueTokens.length != 1) {
          final targets = current;
          if (targets == null || targets.isEmpty) {
            addFileIssue(
              lineNumber,
              tokens.first,
              () => currentL10n.sshImportGlobalIdentity,
            );
          } else {
            for (final host in targets) {
              host.issues.add(
                OpenSshConfigIssue(
                  line: lineNumber,
                  directive: tokens.first,
                  messageBuilder: () =>
                      currentL10n.identityfileNeedsOneValueThisHost,
                  blocking: true,
                  alias: host.alias,
                ),
              );
            }
          }
          continue;
        }
        final issue = OpenSshConfigIssue(
          line: lineNumber,
          directive: tokens.first,
          messageBuilder: () => currentL10n.identityfileIsNotReadOrImported,
          blocking: false,
        );
        issues.add(issue);
        for (final host in current ?? const <_HostBuilder>[]) {
          host.issues.add(
            OpenSshConfigIssue(
              line: lineNumber,
              directive: tokens.first,
              messageBuilder: () => issue.message,
              blocking: false,
              alias: host.alias,
            ),
          );
        }
        continue;
      }

      final supported = const {
        'hostname',
        'user',
        'port',
        'proxyjump',
      }.contains(directive);
      if (!supported) {
        final targets = current;
        String message() => currentL10n.sshImportUnknownDirective;
        if (targets == null || targets.isEmpty) {
          addFileIssue(lineNumber, tokens.first, message);
        } else {
          for (final host in targets) {
            host.issues.add(
              OpenSshConfigIssue(
                line: lineNumber,
                directive: tokens.first,
                messageBuilder: message,
                blocking: true,
                alias: host.alias,
              ),
            );
          }
        }
        continue;
      }

      final targets = current;
      if (targets == null || targets.isEmpty) {
        if (valueTokens.length != 1) {
          addFileIssue(
            lineNumber,
            tokens.first,
            () => currentL10n.sshImportGlobalValueCount,
          );
          continue;
        }
        final parsed = _parseDirectiveValue(
          directive,
          valueTokens.single,
          lineNumber,
        );
        if (parsed == null) {
          addFileIssue(
            lineNumber,
            tokens.first,
            () => currentL10n.sshImportGlobalInvalidValue,
          );
        } else {
          globalValues.putIfAbsent(directive, () => parsed);
        }
        continue;
      }

      if (valueTokens.length != 1) {
        for (final host in targets) {
          host.issues.add(
            OpenSshConfigIssue(
              line: lineNumber,
              directive: tokens.first,
              messageBuilder: () =>
                  currentL10n.thisDirectiveNeedsExactlyOneValue,
              blocking: true,
              alias: host.alias,
            ),
          );
        }
        continue;
      }

      for (final host in targets) {
        final parsed = _parseDirectiveValue(
          directive,
          valueTokens.single,
          lineNumber,
        );
        if (parsed == null) {
          host.issues.add(
            OpenSshConfigIssue(
              line: lineNumber,
              directive: tokens.first,
              messageBuilder: () => currentL10n.thisValueIsInvalidOrUnsupported,
              blocking: true,
              alias: host.alias,
            ),
          );
        } else {
          // OpenSSH uses the first obtained value for a client option.
          host.values.putIfAbsent(directive, () => parsed);
        }
      }
    }

    final hosts = <OpenSshConfigHost>[];
    for (final host in builders.values) {
      final username = host.values['user']?.value;
      final userLine = host.values['user']?.line;
      if (username == null || username.isEmpty) {
        host.issues.add(
          OpenSshConfigIssue(
            line: host.hostLine,
            directive: 'User',
            messageBuilder: () => currentL10n.addAUserDirectiveBeforeImporting,
            blocking: true,
            alias: host.alias,
          ),
        );
      }
      final hostname = host.values['hostname'];
      hosts.add(
        OpenSshConfigHost(
          alias: host.alias,
          hostLine: host.hostLine,
          address: hostname?.value ?? host.alias,
          username: username,
          port: int.tryParse(host.values['port']?.value ?? '') ?? 22,
          proxyJumpAlias: switch (host.values['proxyjump']?.value) {
            null || '' => null,
            final alias => alias,
          },
          fieldLines: Map.unmodifiable({
            'Host': host.hostLine,
            if (hostname != null) 'HostName': hostname.line,
            'User': ?userLine,
            if (host.values['port'] != null) 'Port': host.values['port']!.line,
            if (host.values['proxyjump'] != null)
              'ProxyJump': host.values['proxyjump']!.line,
          }),
          issues: List.unmodifiable(host.issues),
        ),
      );
    }

    return OpenSshConfigParseResult(
      hosts: List.unmodifiable(hosts),
      issues: List.unmodifiable(issues),
      blocksWholeFile: blocksWholeFile,
    );
  }

  static _DirectiveValue? _parseDirectiveValue(
    String directive,
    String value,
    int line,
  ) {
    if (value.isEmpty || _hasControl(value)) return null;
    switch (directive) {
      case 'hostname':
        if (value.length > 253 ||
            value.contains(RegExp(r'\s')) ||
            value.contains('%') ||
            !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
          return null;
        }
        return _DirectiveValue(value, line);
      case 'user':
        if (value.length > 256 ||
            value.contains(RegExp(r'\s')) ||
            !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
          return null;
        }
        return _DirectiveValue(value, line);
      case 'port':
        final port = int.tryParse(value);
        if (port == null || port < 1 || port > 65535) return null;
        return _DirectiveValue('$port', line);
      case 'proxyjump':
        if (value.toLowerCase() == 'none') {
          return _DirectiveValue('', line);
        }
        if (!_isLiteralAlias(value)) return null;
        return _DirectiveValue(value, line);
      default:
        return null;
    }
  }

  static bool _isLiteralAlias(String value) =>
      value.isNotEmpty &&
      value.length <= 255 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value);

  static bool _hasControl(String value) =>
      RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value);

  static String _normalizedAlias(String value) => value.toLowerCase();

  static String? _stripComment(String line) {
    var quoted = false;
    var escaped = false;
    for (var index = 0; index < line.length; index++) {
      final character = line[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character == r'\') {
        escaped = true;
        continue;
      }
      if (character == '"') {
        quoted = !quoted;
        continue;
      }
      if (!quoted && character == '#') return line.substring(0, index);
    }
    if (quoted || escaped) return null;
    return line;
  }

  static List<String>? _tokenize(String line) {
    final result = <String>[];
    final token = StringBuffer();
    var quoted = false;
    var escaped = false;
    var hasToken = false;
    for (final rune in line.runes) {
      final character = String.fromCharCode(rune);
      if (escaped) {
        token.write(character);
        escaped = false;
        hasToken = true;
        continue;
      }
      if (character == r'\') {
        escaped = true;
        hasToken = true;
        continue;
      }
      if (character == '"') {
        quoted = !quoted;
        hasToken = true;
        continue;
      }
      if (!quoted && RegExp(r'\s').hasMatch(character)) {
        if (hasToken) {
          result.add(token.toString());
          token.clear();
          hasToken = false;
        }
        continue;
      }
      token.write(character);
      hasToken = true;
    }
    if (quoted || escaped) return null;
    if (hasToken) result.add(token.toString());
    return result;
  }
}

class _DirectiveValue {
  const _DirectiveValue(this.value, this.line);

  final String value;
  final int line;
}

class _HostBuilder {
  _HostBuilder({required this.alias, required this.hostLine});

  final String alias;
  final int hostLine;
  final Map<String, _DirectiveValue> values = {};
  final List<OpenSshConfigIssue> issues = [];
}
