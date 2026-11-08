import '../l10n/l10n.dart';

import 'dart:collection';
import 'dart:convert';

import 'package:yaml/yaml.dart' as yaml;

/// Maximum source size accepted by the static Ansible inventory parser.
const maxAnsibleInventoryBytes = 1024 * 1024;

/// Upper bound on parsed inventory hosts.
const maxAnsibleInventoryHosts = 512;

enum AnsibleInventoryFormat { ini, yaml }

/// A bounded, non-executing parser for static Ansible inventory files.
///
/// The parser projects only an inventory alias, address, user, port, and group
/// names. It never retains credential variables, arbitrary variables, private
/// key paths, commands, or plugin configuration. It never executes inventory
/// plugins or launches external commands.
class AnsibleInventoryImporter {
  const AnsibleInventoryImporter._();

  static AnsibleInventoryParseResult parse(
    String source, {
    AnsibleInventoryFormat? format,
  }) {
    final detectedFormat = format ?? _detectFormat(source);
    final preflightIssue = _preflight(source);
    if (preflightIssue != null) {
      return AnsibleInventoryParseResult(
        format: detectedFormat,
        hosts: const [],
        issues: [preflightIssue],
        blocksWholeFile: true,
      );
    }
    final templateLine = _findTemplateLine(source);
    if (templateLine != null) {
      return AnsibleInventoryParseResult(
        format: detectedFormat,
        hosts: const [],
        issues: [_issue('unsupported_construct', templateLine, blocking: true)],
        blocksWholeFile: true,
      );
    }
    if (detectedFormat == AnsibleInventoryFormat.yaml) {
      final unsupportedYamlLine = _findUnsupportedYamlSyntaxLine(source);
      if (unsupportedYamlLine != null) {
        return AnsibleInventoryParseResult(
          format: detectedFormat,
          hosts: const [],
          issues: [
            _issue(
              'unsupported_construct',
              unsupportedYamlLine,
              blocking: true,
            ),
          ],
          blocksWholeFile: true,
        );
      }
    }

    return switch (detectedFormat) {
      AnsibleInventoryFormat.ini => _parseIni(source),
      AnsibleInventoryFormat.yaml => _parseYaml(source),
    };
  }
}

class AnsibleInventoryHost {
  const AnsibleInventoryHost({
    required this.name,
    required this.address,
    required this.username,
    required this.port,
    required this.groups,
    required this.sourceLine,
    required this.issues,
  });

  /// Literal inventory alias. No host range expansion is performed.
  final String name;
  final String address;
  final String? username;
  final int port;
  final List<String> groups;
  final int sourceLine;
  final List<AnsibleInventoryIssue> issues;

  bool get canImport =>
      address.isNotEmpty && !issues.any((issue) => issue.blocking);
}

class AnsibleInventoryIssue {
  const AnsibleInventoryIssue({
    required this.line,
    required this.code,
    String? message,
    this.messageBuilder,
    required this.blocking,
    this.host,
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : assert(message != null || messageBuilder != null),
       _message = message;

  final int line;

  /// Stable machine-readable finding code. Never contains source text.
  final String code;

  /// Safe text containing no inventory values or arbitrary variable names.
  final String? _message;
  final String Function()? messageBuilder;

  String get message => messageBuilder?.call() ?? _message ?? '';
  final bool blocking;
  final String? host;
}

class AnsibleInventoryParseResult {
  AnsibleInventoryParseResult({
    required this.format,
    required List<AnsibleInventoryHost> hosts,
    required List<AnsibleInventoryIssue> issues,
    required this.blocksWholeFile,
  }) : hosts = List.unmodifiable(hosts),
       issues = List.unmodifiable(issues);

  final AnsibleInventoryFormat format;
  final List<AnsibleInventoryHost> hosts;
  final List<AnsibleInventoryIssue> issues;
  final bool blocksWholeFile;

  bool get canImportAny =>
      !blocksWholeFile && hosts.any((candidate) => candidate.canImport);
}

const _maxLines = 4096;
const _maxLineLength = 8192;
const _maxGroups = 128;
const _maxVariablesPerHost = 64;
const _maxYamlDepth = 32;
const _maxYamlNodes = 20000;
const _maxAliasLength = 128;
const _maxAddressLength = 255;
const _maxUsernameLength = 64;

String _messageForCode(String code) => switch (code) {
  'file_too_large' => currentL10n.inventoryTooLarge,
  'too_many_lines' => currentL10n.inventoryTooManyLines,
  'line_too_long' => currentL10n.inventoryLineTooLong,
  'control_character' => currentL10n.inventoryControlCharacter,
  'unsupported_format' => currentL10n.inventoryUnsupportedFormat,
  'parse_error' => currentL10n.inventoryParseError,
  'unsupported_construct' => currentL10n.inventoryUnsupportedConstruct,
  'dynamic_inventory' => currentL10n.inventoryDynamicUnsupported,
  'invalid_group' => currentL10n.inventoryInvalidGroup,
  'invalid_host' => currentL10n.inventoryInvalidHost,
  'invalid_variable' => currentL10n.inventoryInvalidVariable,
  'unsupported_connection' => currentL10n.inventoryUnsupportedConnection,
  'ignored_variable' => currentL10n.inventoryIgnoredVariable,
  'conflicting_variable' => currentL10n.inventoryConflictingVariable,
  'duplicate_variable' => currentL10n.inventoryDuplicateVariable,
  'group_cycle' => currentL10n.inventoryGroupCycle,
  'limit_exceeded' => currentL10n.inventoryLimitExceeded,
  'empty_inventory' => currentL10n.inventoryEmpty,
  _ => currentL10n.inventoryUnsupportedConstruct,
};

AnsibleInventoryIssue _issue(
  String code,
  int line, {
  bool blocking = false,
  String? host,
}) => AnsibleInventoryIssue(
  line: line < 1 ? 1 : line,
  code: code,
  messageBuilder: () => _messageForCode(code),
  blocking: blocking,
  host: host,
);

AnsibleInventoryFormat _detectFormat(String source) {
  for (final line in source.split(RegExp(r'\r\n|\n|\r'))) {
    final value = line.trim();
    if (value.isEmpty || value.startsWith('#') || value.startsWith(';')) {
      continue;
    }
    if (value == '---' || value.startsWith('- ') || value.startsWith('{')) {
      return AnsibleInventoryFormat.yaml;
    }
    if (RegExp(r'^[A-Za-z0-9_.-]+\s*:\s*(?:#.*)?$').hasMatch(value) ||
        RegExp(r'^[A-Za-z0-9_.-]+:\s').hasMatch(value)) {
      return AnsibleInventoryFormat.yaml;
    }
    return AnsibleInventoryFormat.ini;
  }
  return AnsibleInventoryFormat.ini;
}

AnsibleInventoryIssue? _preflight(String source) {
  if (source.length > maxAnsibleInventoryBytes ||
      utf8.encode(source).length > maxAnsibleInventoryBytes) {
    return _issue('file_too_large', 1, blocking: true);
  }
  final lines = source.split(RegExp(r'\r\n|\n|\r'));
  if (lines.length > _maxLines) {
    return _issue('too_many_lines', 1, blocking: true);
  }
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.length > _maxLineLength) {
      return _issue('line_too_long', index + 1, blocking: true);
    }
    if (RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]')
        .hasMatch(line)) {
      return _issue('control_character', index + 1, blocking: true);
    }
  }
  return null;
}

class _InventoryValue {
  const _InventoryValue(this.value, this.line);

  final String value;
  final int line;
}

class _InventoryGroup {
  _InventoryGroup(this.name, this.line);

  final String name;
  final int line;
  final Map<String, _InventoryValue> variables = {};
  final Set<String> children = {};
  final Set<String> directHosts = {};
  final List<AnsibleInventoryIssue> issues = [];
}

class _HostDraft {
  _HostDraft(this.name, this.sourceLine);

  final String name;
  final int sourceLine;
  final Set<String> groups = {};
  final Map<String, _InventoryValue> variables = {};
  final List<AnsibleInventoryIssue> issues = [];
  var rawVariableCount = 0;
}

class _InventoryBuilder {
  final Map<String, _InventoryGroup> groups = {};
  final Map<String, _HostDraft> hosts = {};
  final List<AnsibleInventoryIssue> fileIssues = [];
  bool blocksWholeFile = false;

  _InventoryGroup group(String name, int line) {
    var result = groups[name];
    if (result != null) return result;
    if (groups.length >= _maxGroups) {
      addFileIssue('limit_exceeded', line);
      return _InventoryGroup(name, line);
    }
    result = _InventoryGroup(name, line);
    groups[name] = result;
    return result;
  }

  void addFileIssue(String code, int line) {
    fileIssues.add(_issue(code, line, blocking: true));
    blocksWholeFile = true;
  }

  void addVariable(
    Map<String, _InventoryValue> target,
    String key,
    String value,
    int line,
    List<AnsibleInventoryIssue> issues, {
    String? host,
  }) {
    if (!_isAllowedVariable(key)) {
      issues.add(_issue('ignored_variable', line, host: host));
      return;
    }
    final previous = target[key];
    if (previous != null && previous.value != value) {
      issues.add(
        _issue('conflicting_variable', line, blocking: true, host: host),
      );
      return;
    }
    target[key] = _InventoryValue(value, line);
  }

  void addHost(
    String name,
    int line,
    String groupName,
    Map<String, String> variables,
  ) {
    if (!_isValidAlias(name)) {
      addFileIssue('invalid_host', line);
      return;
    }
    var host = hosts[name];
    if (host == null) {
      if (hosts.length >= maxAnsibleInventoryHosts) {
        addFileIssue('limit_exceeded', line);
        return;
      }
      host = _HostDraft(name, line);
      hosts[name] = host;
    }
    host.groups.add(groupName);
    groups[groupName]?.directHosts.add(name);
    host.rawVariableCount += variables.length;
    if (host.rawVariableCount > _maxVariablesPerHost) {
      host.issues.add(
        _issue('limit_exceeded', line, blocking: true, host: name),
      );
      return;
    }
    for (final entry in variables.entries) {
      addVariable(
        host.variables,
        entry.key,
        entry.value,
        line,
        host.issues,
        host: name,
      );
    }
  }

  AnsibleInventoryParseResult finish(AnsibleInventoryFormat format) {
    if (blocksWholeFile) {
      return AnsibleInventoryParseResult(
        format: format,
        hosts: const [],
        issues: fileIssues,
        blocksWholeFile: true,
      );
    }

    final parentGroups = <String, Set<String>>{};
    for (final group in groups.values) {
      for (final child in group.children) {
        parentGroups.putIfAbsent(child, () => <String>{}).add(group.name);
      }
    }
    if (_hasGroupCycle(parentGroups)) {
      return AnsibleInventoryParseResult(
        format: format,
        hosts: const [],
        issues: [_issue('group_cycle', 1, blocking: true)],
        blocksWholeFile: true,
      );
    }

    final candidates = <AnsibleInventoryHost>[];
    for (final draft in hosts.values) {
      final ancestors = <String>{...draft.groups, 'all'};
      final stack = <String>[...ancestors];
      while (stack.isNotEmpty) {
        final item = stack.removeLast();
        for (final parent in parentGroups[item] ?? const <String>{}) {
          if (ancestors.add(parent)) stack.add(parent);
        }
      }

      final issues = <AnsibleInventoryIssue>[...draft.issues];
      final inherited = <String, _InventoryValue>{};
      final selectedDepth = <String, int>{};
      final depths = _groupDepths(draft.groups, parentGroups);
      for (final groupName in ancestors) {
        final group = groups[groupName];
        if (group == null) continue;
        final depth = depths[groupName] ?? 0;
        issues.addAll(group.issues);
        for (final entry in group.variables.entries) {
          final previous = inherited[entry.key];
          final previousDepth = selectedDepth[entry.key] ?? -1;
          if (previous == null || depth > previousDepth) {
            inherited[entry.key] = entry.value;
            selectedDepth[entry.key] = depth;
          } else if (depth == previousDepth &&
              previous.value != entry.value.value) {
            issues.add(
              _issue(
                'conflicting_variable',
                entry.value.line,
                blocking: true,
                host: draft.name,
              ),
            );
          }
        }
      }

      final effective = <String, _InventoryValue>{...inherited};
      // Host variables have higher precedence than group variables.
      effective.addAll(draft.variables);
      final addressValue = effective['ansible_host']?.value ?? draft.name;
      final usernameValue = effective['ansible_user']?.value;
      final portValue = effective['ansible_port']?.value;
      final connectionValue = effective['ansible_connection']?.value;
      if (connectionValue != null && connectionValue != 'ssh') {
        issues.add(
          _issue(
            'unsupported_connection',
            effective['ansible_connection']!.line,
            blocking: true,
            host: draft.name,
          ),
        );
      }
      if (!_isValidAddress(addressValue)) {
        issues.add(
          _issue(
            'invalid_variable',
            effective['ansible_host']?.line ?? draft.sourceLine,
            blocking: true,
            host: draft.name,
          ),
        );
      }
      if (usernameValue != null && !_isValidUsername(usernameValue)) {
        issues.add(
          _issue(
            'invalid_variable',
            effective['ansible_user']!.line,
            blocking: true,
            host: draft.name,
          ),
        );
      }
      final port = portValue == null ? 22 : int.tryParse(portValue);
      if (port == null || port < 1 || port > 65535) {
        issues.add(
          _issue(
            'invalid_variable',
            effective['ansible_port']?.line ?? draft.sourceLine,
            blocking: true,
            host: draft.name,
          ),
        );
      }

      final candidateGroups =
          ancestors.where((name) => name != 'all').toList(growable: false)
            ..sort();
      candidates.add(
        AnsibleInventoryHost(
          name: draft.name,
          address: _isValidAddress(addressValue) ? addressValue : '',
          username: usernameValue != null && _isValidUsername(usernameValue)
              ? usernameValue
              : null,
          port: port ?? 22,
          groups: candidateGroups,
          sourceLine: draft.sourceLine,
          issues: _dedupeIssues(issues),
        ),
      );
    }

    final resultIssues = <AnsibleInventoryIssue>[...fileIssues];
    if (candidates.isEmpty) resultIssues.add(_issue('empty_inventory', 1));
    return AnsibleInventoryParseResult(
      format: format,
      hosts: candidates,
      issues: resultIssues,
      blocksWholeFile: false,
    );
  }
}

bool _hasGroupCycle(Map<String, Set<String>> parents) {
  final visiting = <String>{};
  final visited = <String>{};
  bool visit(String group) {
    if (visiting.contains(group)) return true;
    if (visited.contains(group)) return false;
    visiting.add(group);
    for (final parent in parents[group] ?? const <String>{}) {
      if (visit(parent)) return true;
    }
    visiting.remove(group);
    visited.add(group);
    return false;
  }

  for (final group in parents.keys) {
    if (visit(group)) return true;
  }
  return false;
}

Map<String, int> _groupDepths(
  Set<String> groups,
  Map<String, Set<String>> parents,
) {
  final result = <String, int>{};
  int depthOf(String group, int traversed) {
    if (group == 'all') return 0;
    if (traversed > _maxYamlDepth) return _maxYamlDepth;
    final cached = result[group];
    if (cached != null) return cached;
    final groupParents = parents[group] ?? const <String>{};
    if (groupParents.isEmpty) return result[group] = 1;
    var depth = 1;
    for (final parent in groupParents) {
      final candidate = depthOf(parent, traversed + 1) + 1;
      if (candidate > depth) depth = candidate;
    }
    return result[group] = depth;
  }

  for (final group in groups) {
    result[group] = depthOf(group, 0);
  }
  result['all'] = 0;
  return result;
}

List<AnsibleInventoryIssue> _dedupeIssues(List<AnsibleInventoryIssue> input) {
  final seen = <String>{};
  return input
      .where((issue) {
        final key =
            '${issue.code}:${issue.line}:${issue.blocking}:${issue.host}';
        return seen.add(key);
      })
      .toList(growable: false);
}

bool _isAllowedVariable(String key) => const {
  'ansible_host',
  'ansible_user',
  'ansible_port',
  'ansible_connection',
}.contains(key);

bool _isValidAlias(String value) =>
    value.length <= _maxAliasLength &&
    RegExp(r'^[A-Za-z0-9_.:%+-]+$').hasMatch(value) &&
    !value.contains('..');

bool _isValidAddress(String value) =>
    value.isNotEmpty &&
    value.length <= _maxAddressLength &&
    RegExp(r'^[A-Za-z0-9_.:%-]+$').hasMatch(value) &&
    !value.contains('..');

bool _isValidUsername(String value) =>
    value.length <= _maxUsernameLength &&
    RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);

// ---------------------------------------------------------------------------
// INI parser

AnsibleInventoryParseResult _parseIni(String source) {
  final builder = _InventoryBuilder();
  var currentGroup = 'ungrouped';
  var currentMode = _IniMode.hosts;
  builder.group('ungrouped', 1);
  final lines = source.split(RegExp(r'\r\n|\n|\r'));
  final groupVariableCounts = <String, int>{};

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index];
    final trimmed = line.trim();
    if (trimmed.startsWith('#!')) {
      builder.addFileIssue('dynamic_inventory', lineNumber);
      break;
    }
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith(';')) {
      continue;
    }
    if (trimmed.startsWith('[')) {
      final match = RegExp(r'^\[([^\]]+)\]\s*(?:[#;].*)?$').firstMatch(trimmed);
      if (match == null) {
        builder.addFileIssue('invalid_group', lineNumber);
        continue;
      }
      final section = match.group(1)!;
      final suffixAt = section.indexOf(':');
      final groupName = suffixAt < 0 ? section : section.substring(0, suffixAt);
      final suffix = suffixAt < 0 ? '' : section.substring(suffixAt + 1);
      if (!_isValidGroupName(groupName) ||
          (suffix.isNotEmpty && suffix != 'vars' && suffix != 'children')) {
        builder.addFileIssue('invalid_group', lineNumber);
        continue;
      }
      currentGroup = groupName;
      builder.group(groupName, lineNumber);
      currentMode = switch (suffix) {
        'vars' => _IniMode.variables,
        'children' => _IniMode.children,
        _ => _IniMode.hosts,
      };
      continue;
    }

    final tokens = _tokenizeIniLine(line);
    if (tokens == null || tokens.isEmpty) {
      builder.addFileIssue('invalid_host', lineNumber);
      continue;
    }
    final group = builder.group(currentGroup, lineNumber);
    if (currentMode == _IniMode.children) {
      if (tokens.length != 1 || !_isValidGroupName(tokens.single)) {
        builder.addFileIssue('invalid_group', lineNumber);
      } else {
        group.children.add(tokens.single);
        builder.group(tokens.single, lineNumber);
      }
      continue;
    }
    if (currentMode == _IniMode.variables) {
      final assignment = tokens.length == 1
          ? _parseAssignment(tokens.single)
          : null;
      if (assignment == null) {
        builder.addFileIssue('invalid_variable', lineNumber);
      } else {
        final count = (groupVariableCounts[currentGroup] ?? 0) + 1;
        groupVariableCounts[currentGroup] = count;
        if (count > _maxVariablesPerHost) {
          builder.addFileIssue('limit_exceeded', lineNumber);
          continue;
        }
        if (const {
          'plugin',
          'inventory_plugin',
          'script',
        }.contains(assignment.key.toLowerCase())) {
          builder.addFileIssue('dynamic_inventory', lineNumber);
          continue;
        }
        builder.addVariable(
          group.variables,
          assignment.key,
          assignment.value,
          lineNumber,
          group.issues,
        );
      }
      continue;
    }

    final alias = tokens.first;
    final variables = <String, String>{};
    var badVariable = false;
    var hostVariableLimitExceeded = false;
    var duplicateConnectionField = false;
    var variableCount = 0;
    for (final token in tokens.skip(1)) {
      final assignment = _parseAssignment(token);
      if (assignment == null) {
        badVariable = true;
        break;
      }
      if (variables.length >= _maxVariablesPerHost) {
        badVariable = true;
        hostVariableLimitExceeded = true;
        break;
      }
      variableCount++;
      if (variableCount > _maxVariablesPerHost) {
        badVariable = true;
        hostVariableLimitExceeded = true;
        break;
      }
      if (const {
        'plugin',
        'inventory_plugin',
        'script',
      }.contains(assignment.key.toLowerCase())) {
        builder.addFileIssue('dynamic_inventory', lineNumber);
        badVariable = true;
        break;
      }
      if (_isAllowedVariable(assignment.key) &&
          variables.containsKey(assignment.key)) {
        duplicateConnectionField = true;
        continue;
      }
      variables[assignment.key] = assignment.value;
    }
    if (badVariable) {
      builder.addHost(alias, lineNumber, currentGroup, variables);
      builder.hosts[alias]?.issues.add(
        _issue(
          hostVariableLimitExceeded ? 'limit_exceeded' : 'invalid_variable',
          lineNumber,
          blocking: true,
          host: alias,
        ),
      );
      continue;
    }
    builder.addHost(alias, lineNumber, currentGroup, variables);
    if (duplicateConnectionField) {
      builder.hosts[alias]?.issues.add(
        _issue('duplicate_variable', lineNumber, blocking: true, host: alias),
      );
    }
  }

  if (builder.blocksWholeFile) {
    return builder.finish(AnsibleInventoryFormat.ini);
  }
  return builder.finish(AnsibleInventoryFormat.ini);
}

enum _IniMode { hosts, variables, children }

class _Assignment {
  const _Assignment(this.key, this.value);

  final String key;
  final String value;
}

_Assignment? _parseAssignment(String token) {
  final equalsAt = token.indexOf('=');
  if (equalsAt <= 0) return null;
  final key = token.substring(0, equalsAt);
  final value = token.substring(equalsAt + 1);
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) ||
      value.isEmpty ||
      value.length > 4096 ||
      RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value)) {
    return null;
  }
  return _Assignment(key, value);
}

List<String>? _tokenizeIniLine(String input) {
  final result = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  var escaped = false;
  var tokenStarted = false;
  void finishToken() {
    if (!tokenStarted) return;
    result.add(buffer.toString());
    buffer.clear();
    tokenStarted = false;
  }

  for (var index = 0; index < input.length; index++) {
    final char = input[index];
    if (escaped) {
      if (char != '\\' && char != '"' && char != "'") return null;
      buffer.write(char);
      escaped = false;
      tokenStarted = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == '\\') {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      } else {
        buffer.write(char);
      }
      tokenStarted = true;
      continue;
    }
    if ((char == '"' || char == "'") && tokenStarted) {
      quote = char;
      continue;
    }
    if ((char == '"' || char == "'") && !tokenStarted) {
      quote = char;
      tokenStarted = true;
      continue;
    }
    if (char == '#' || char == ';') {
      if (!tokenStarted || index == 0 || input[index - 1].trim().isEmpty) {
        break;
      }
    }
    if (char.trim().isEmpty) {
      finishToken();
      continue;
    }
    buffer.write(char);
    tokenStarted = true;
  }
  if (escaped || quote.isNotEmpty) return null;
  finishToken();
  return result;
}

bool _isValidGroupName(String value) =>
    value.length <= 64 && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);

int? _findTemplateLine(String source) {
  final lines = source.split(RegExp(r'\r\n|\n|\r'));
  for (var index = 0; index < lines.length; index++) {
    if (RegExp(r'\{\{|\{%|\{#').hasMatch(lines[index])) return index + 1;
  }
  return null;
}

int? _findUnsupportedYamlSyntaxLine(String source) {
  final lines = source.split(RegExp(r'\r\n|\n|\r'));
  final unsupported = RegExp(
    r'(?:^|[\s\[{,:])(?:&|\*)[A-Za-z0-9_-]+(?=$|[\s,\]}])|(?:^|[\s,{])<<\s*:|(?:^|[\s:\[{,])![A-Za-z0-9_-]+',
  );
  for (var index = 0; index < lines.length; index++) {
    if (unsupported.hasMatch(lines[index])) return index + 1;
  }
  return null;
}

// ---------------------------------------------------------------------------
// YAML parser

AnsibleInventoryParseResult _parseYaml(String source) {
  if (source.trimLeft().startsWith('#!')) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [_issue('dynamic_inventory', 1, blocking: true)],
      blocksWholeFile: true,
    );
  }
  if (RegExp(
        r'^\s*---\s*(?:#.*)?$',
        multiLine: true,
      ).allMatches(source).length >
      1) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [_issue('unsupported_construct', 1, blocking: true)],
      blocksWholeFile: true,
    );
  }

  yaml.YamlNode root;
  try {
    root = yaml.loadYamlNode(source);
  } on yaml.YamlException catch (error) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [
        _issue('parse_error', error.span?.start.line ?? 1, blocking: true),
      ],
      blocksWholeFile: true,
    );
  } on Object {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [_issue('parse_error', 1, blocking: true)],
      blocksWholeFile: true,
    );
  }

  final traversal = _YamlSafetyTraversal();
  final safety = traversal.inspect(root, 0);
  if (safety != null) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [safety],
      blocksWholeFile: true,
    );
  }
  final dynamicLine = _findDynamicConstruct(root, 0);
  if (dynamicLine != null) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [_issue('dynamic_inventory', dynamicLine, blocking: true)],
      blocksWholeFile: true,
    );
  }
  if (root is! yaml.YamlMap) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [
        _issue('unsupported_construct', root.span.start.line, blocking: true),
      ],
      blocksWholeFile: true,
    );
  }

  final mergeOrAliasLine = _findUnsupportedYamlSyntaxLine(source);
  if (mergeOrAliasLine != null) {
    return AnsibleInventoryParseResult(
      format: AnsibleInventoryFormat.yaml,
      hosts: const [],
      issues: [
        _issue('unsupported_construct', mergeOrAliasLine, blocking: true),
      ],
      blocksWholeFile: true,
    );
  }

  final builder = _InventoryBuilder();
  builder.group('all', 1);
  final rootEntries = _stringEntries(root);
  if (rootEntries == null || rootEntries.isEmpty) {
    builder.addFileIssue('unsupported_construct', root.span.start.line);
    return builder.finish(AnsibleInventoryFormat.yaml);
  }

  for (final entry in rootEntries.entries) {
    final name = entry.key;
    if (!_isValidGroupName(name)) {
      builder.addFileIssue('invalid_group', entry.value.span.start.line);
      continue;
    }
    if (entry.value is! yaml.YamlMap) {
      builder.addFileIssue(
        'unsupported_construct',
        entry.value.span.start.line,
      );
      continue;
    }
    _parseYamlGroup(
      builder,
      name,
      entry.value as yaml.YamlMap,
      entry.value.span.start.line,
      depth: 0,
    );
  }
  return builder.finish(AnsibleInventoryFormat.yaml);
}

class _YamlSafetyTraversal {
  final Set<yaml.YamlNode> _visiting = HashSet<yaml.YamlNode>.identity();
  final Set<yaml.YamlNode> _visited = HashSet<yaml.YamlNode>.identity();
  var _nodeCount = 0;

  AnsibleInventoryIssue? inspect(yaml.YamlNode node, int depth) {
    _nodeCount++;
    if (_nodeCount > _maxYamlNodes || depth > _maxYamlDepth) {
      return _issue('limit_exceeded', node.span.start.line, blocking: true);
    }
    if (_visiting.contains(node)) {
      return _issue(
        'unsupported_construct',
        node.span.start.line,
        blocking: true,
      );
    }
    if (_visited.contains(node)) {
      // YAML aliases are not needed for static host inventories. Reject rather
      // than permit hidden shared or recursive structure.
      return _issue(
        'unsupported_construct',
        node.span.start.line,
        blocking: true,
      );
    }
    _visiting.add(node);
    if (node is yaml.YamlMap) {
      for (final entry in node.nodes.entries) {
        final keyIssue = inspect(entry.key as yaml.YamlNode, depth + 1);
        if (keyIssue != null) return keyIssue;
        final valueIssue = inspect(entry.value, depth + 1);
        if (valueIssue != null) return valueIssue;
      }
    } else if (node is yaml.YamlList) {
      for (final child in node.nodes) {
        final childIssue = inspect(child, depth + 1);
        if (childIssue != null) return childIssue;
      }
    }
    _visiting.remove(node);
    _visited.add(node);
    return null;
  }
}

int? _findDynamicConstruct(yaml.YamlNode node, int depth) {
  if (depth > _maxYamlDepth) return node.span.start.line;
  if (node is yaml.YamlMap) {
    for (final entry in node.nodes.entries) {
      final keyNode = entry.key as yaml.YamlNode;
      final key = keyNode.value;
      if (key is String &&
          const {
            'plugin',
            'compose',
            'keyed_groups',
            'constructed',
            'script',
            'cache',
            'strict',
          }.contains(key.toLowerCase())) {
        return keyNode.span.start.line;
      }
      final nested = _findDynamicConstruct(entry.value, depth + 1);
      if (nested != null) return nested;
    }
  } else if (node is yaml.YamlList) {
    for (final child in node.nodes) {
      final nested = _findDynamicConstruct(child, depth + 1);
      if (nested != null) return nested;
    }
  }
  return null;
}

Map<String, yaml.YamlNode>? _stringEntries(yaml.YamlMap map) {
  final result = <String, yaml.YamlNode>{};
  for (final entry in map.nodes.entries) {
    final key = (entry.key as yaml.YamlNode).value;
    if (key is! String || result.containsKey(key)) return null;
    result[key] = entry.value;
  }
  return result;
}

void _parseYamlGroup(
  _InventoryBuilder builder,
  String groupName,
  yaml.YamlMap node,
  int line, {
  required int depth,
}) {
  if (depth > _maxYamlDepth) {
    builder.addFileIssue('limit_exceeded', line);
    return;
  }
  final group = builder.group(groupName, line);
  if (builder.blocksWholeFile) return;
  final fields = _stringEntries(node);
  if (fields == null) {
    builder.addFileIssue('unsupported_construct', line);
    return;
  }
  for (final field in fields.keys) {
    if (!const {'hosts', 'children', 'vars'}.contains(field)) {
      builder.addFileIssue(
        'unsupported_construct',
        fields[field]!.span.start.line,
      );
    }
  }
  final varsNode = fields['vars'];
  if (varsNode != null) {
    if (varsNode is! yaml.YamlMap) {
      builder.addFileIssue('unsupported_construct', varsNode.span.start.line);
    } else {
      final vars = _stringEntries(varsNode);
      if (vars == null) {
        builder.addFileIssue('unsupported_construct', varsNode.span.start.line);
      } else if (vars.length > _maxVariablesPerHost) {
        builder.addFileIssue('limit_exceeded', varsNode.span.start.line);
      } else {
        for (final entry in vars.entries) {
          final value = _yamlScalarString(entry.value);
          if (value == null) {
            if (_isAllowedVariable(entry.key)) {
              group.issues.add(
                _issue(
                  'invalid_variable',
                  entry.value.span.start.line,
                  blocking: true,
                ),
              );
            } else {
              group.issues.add(
                _issue('ignored_variable', entry.value.span.start.line),
              );
            }
          } else {
            builder.addVariable(
              group.variables,
              entry.key,
              value,
              entry.value.span.start.line,
              group.issues,
            );
          }
        }
      }
    }
  }

  final hostsNode = fields['hosts'];
  if (hostsNode != null) {
    if (hostsNode is! yaml.YamlMap) {
      builder.addFileIssue('unsupported_construct', hostsNode.span.start.line);
    } else {
      for (final entry in hostsNode.nodes.entries) {
        final aliasNode = entry.key as yaml.YamlNode;
        final alias = aliasNode.value;
        if (alias is! String || !_isValidAlias(alias)) {
          builder.addFileIssue('invalid_host', aliasNode.span.start.line);
          continue;
        }
        final hostVars = <String, String>{};
        final hostLine = aliasNode.span.start.line;
        if (entry.value is yaml.YamlMap) {
          final values = _stringEntries(entry.value as yaml.YamlMap);
          if (values == null) {
            builder.addFileIssue(
              'unsupported_construct',
              entry.value.span.start.line,
            );
            continue;
          }
          if (values.length > _maxVariablesPerHost) {
            builder.addFileIssue('limit_exceeded', entry.value.span.start.line);
            continue;
          }
          for (final variable in values.entries) {
            final value = _yamlScalarString(variable.value);
            if (value == null) {
              if (_isAllowedVariable(variable.key)) {
                // Preserve an invalid marker without preserving the source
                // value. The validator below will make this host non-importable.
                hostVars[variable.key] = '';
              } else {
                builder.hosts
                    .putIfAbsent(alias, () => _HostDraft(alias, hostLine))
                    .issues
                    .add(
                      _issue(
                        'ignored_variable',
                        variable.value.span.start.line,
                      ),
                    );
              }
              continue;
            }
            if (_isAllowedVariable(variable.key)) {
              hostVars[variable.key] = value;
            } else {
              builder.hosts
                  .putIfAbsent(alias, () => _HostDraft(alias, hostLine))
                  .issues
                  .add(
                    _issue('ignored_variable', variable.value.span.start.line),
                  );
            }
          }
        } else if (entry.value is! yaml.YamlScalar ||
            (entry.value as yaml.YamlScalar).value != null) {
          builder.addFileIssue(
            'unsupported_construct',
            entry.value.span.start.line,
          );
          continue;
        }
        builder.addHost(alias, hostLine, groupName, hostVars);
      }
    }
  }

  final childrenNode = fields['children'];
  if (childrenNode != null) {
    if (childrenNode is! yaml.YamlMap) {
      builder.addFileIssue(
        'unsupported_construct',
        childrenNode.span.start.line,
      );
    } else {
      final children = _stringEntries(childrenNode);
      if (children == null) {
        builder.addFileIssue(
          'unsupported_construct',
          childrenNode.span.start.line,
        );
      } else {
        for (final childEntry in children.entries) {
          if (!_isValidGroupName(childEntry.key) ||
              childEntry.value is! yaml.YamlMap) {
            builder.addFileIssue(
              'invalid_group',
              childEntry.value.span.start.line,
            );
            continue;
          }
          group.children.add(childEntry.key);
          _parseYamlGroup(
            builder,
            childEntry.key,
            childEntry.value as yaml.YamlMap,
            childEntry.value.span.start.line,
            depth: depth + 1,
          );
        }
      }
    }
  }
}

String? _yamlScalarString(yaml.YamlNode node) {
  if (node is! yaml.YamlScalar) return null;
  final value = node.value;
  if (value is String) return value;
  if (value is int) return value.toString();
  return null;
}
