import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

const int maxSnippetParameters = 32;
const int maxSnippetArguments = 128;
const int maxSnippetTextLength = 4096;
const Set<String> _supportedLegacyShellLabels = {
  'bash',
  'sh',
  'zsh',
  'fish',
  'powershell',
};

class SnippetInvocationPreview {
  const SnippetInvocationPreview({
    required this.shell,
    required this.command,
    required this.hasCredentialReference,
    required this.canExecute,
    this.blockedReason,
  });

  final String shell;
  final String command;
  final bool hasCredentialReference;
  final bool canExecute;
  final String? blockedReason;

  bool matchesExactly(SnippetInvocationPreview other) =>
      shell == other.shell &&
      command == other.command &&
      hasCredentialReference == other.hasCredentialReference &&
      canExecute == other.canExecute &&
      blockedReason == other.blockedReason;
}

class PreparedSnippetExecution {
  PreparedSnippetExecution({
    required this.snippetId,
    required this.terminalTabId,
    required this.connectionIdentity,
    required this.hostId,
    required this.hostName,
    required this.endpoint,
    required this.shell,
    required this.hostSnapshot,
    required this.definitionSnapshot,
    Map<String, CredentialRecord> credentialSnapshots = const {},
  }) : _credentialSnapshots = Map.of(credentialSnapshots);

  final String snippetId;
  final String terminalTabId;
  final Object connectionIdentity;
  final String hostId;
  final String hostName;
  final String endpoint;
  final String shell;
  final String hostSnapshot;
  final String definitionSnapshot;
  final Map<String, CredentialRecord> _credentialSnapshots;
  bool _consumed = false;

  CredentialRecord? credentialSnapshot(String id) => _credentialSnapshots[id];

  void discard() {
    _consumed = true;
    _credentialSnapshots.clear();
  }

  bool consume() {
    if (_consumed) return false;
    _consumed = true;
    _credentialSnapshots.clear();
    return true;
  }
}

/// Validates all stored structured-command fields before preview or execution.
/// Every command string is literal data; templates and shell expressions are
/// never parsed. Parameter references use the explicit DTO `kind` field.
void validateSnippetDefinition(SnippetRecord snippet) {
  if (snippet.executionMode == SnippetExecutionMode.script) {
    if (snippet.program.isNotEmpty ||
        snippet.arguments.isNotEmpty ||
        snippet.parameters.isNotEmpty) {
      throw const FormatException(
        'Legacy scripts cannot contain structured command fields',
      );
    }
    return;
  }
  if (snippet.executionMode != SnippetExecutionMode.bashCommand) {
    throw const FormatException('Unsupported snippet execution mode');
  }
  if (snippet.shell != 'bash') {
    throw const FormatException('Structured commands currently require Bash');
  }
  if (snippet.body.isNotEmpty) {
    throw const FormatException(
      'Structured commands cannot also contain a free-form script body',
    );
  }
  if (snippet.program.trim().isEmpty) {
    throw const FormatException('Program is required');
  }
  _validateLiteral(snippet.program, 'Program', allowEmpty: false);
  if (snippet.program.length > maxSnippetTextLength) {
    throw const FormatException('Program is too long');
  }
  if (snippet.parameters.length > maxSnippetParameters) {
    throw const FormatException('Too many snippet parameters');
  }
  if (snippet.arguments.length > maxSnippetArguments) {
    throw const FormatException('Too many snippet arguments');
  }

  final byName = <String, SnippetParameter>{};
  for (final parameter in snippet.parameters) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(parameter.name)) {
      throw FormatException('Invalid parameter name: ${parameter.name}');
    }
    if (byName.containsKey(parameter.name)) {
      throw FormatException('Duplicate parameter name: ${parameter.name}');
    }
    byName[parameter.name] = parameter;
    switch (parameter.type) {
      case SnippetParameterType.text:
        if (parameter.credentialId != null) {
          throw FormatException(
            'Text parameter ${parameter.name} cannot reference a Credential',
          );
        }
        final value = parameter.defaultValue;
        if (value != null) _validateTextValue(value, parameter.name);
        break;
      case SnippetParameterType.credentialSecret:
        if (parameter.defaultValue != null) {
          throw FormatException(
            'Credential parameter ${parameter.name} cannot have a default value',
          );
        }
        final credentialId = parameter.credentialId;
        if (credentialId == null ||
            credentialId.isEmpty ||
            credentialId.length > 128) {
          throw FormatException(
            'Credential parameter ${parameter.name} requires a Credential ID',
          );
        }
        break;
    }
  }

  for (final argument in snippet.arguments) {
    final literal = argument.value;
    final reference = argument.parameter;
    if ((literal == null) == (reference == null)) {
      throw const FormatException(
        'Snippet argument must be one literal or reference',
      );
    }
    if (literal != null) {
      _validateLiteral(literal, 'Argument');
      continue;
    }
    if (!byName.containsKey(reference)) {
      throw FormatException('Undefined snippet parameter: $reference');
    }
  }
}

SnippetInvocationPreview previewSnippetInvocation(
  SnippetRecord snippet, {
  Map<String, String> values = const {},
  Set<String> credentialParametersAvailable = const {},
}) {
  validateSnippetDefinition(snippet);
  if (snippet.executionMode == SnippetExecutionMode.script) {
    if (snippet.body.trim().isEmpty) {
      throw const FormatException('Snippet script is empty');
    }
    final supportedShell = _supportedLegacyShellLabels.contains(snippet.shell);
    return SnippetInvocationPreview(
      shell: snippet.shell,
      command: snippet.body,
      hasCredentialReference: false,
      canExecute: supportedShell,
      blockedReason: supportedShell
          ? null
          : 'This snippet has an unknown shell label. No command will be sent.',
    );
  }

  final resolved = _resolveTextValues(snippet.parameters, values);
  final usedCredentialParameters = _usedCredentialParameters(snippet);
  final hasCredential = usedCredentialParameters.isNotEmpty;
  final missingCredentialParameters = usedCredentialParameters
      .where(
        (parameter) => !credentialParametersAvailable.contains(parameter.name),
      )
      .map((parameter) => parameter.name)
      .toList(growable: false);
  final words = <String>[_quoteBashWord(snippet.program)];
  for (final argument in snippet.arguments) {
    if (argument.value != null) {
      words.add(_quoteBashWord(argument.value!));
      continue;
    }
    final parameter = snippet.parameters.firstWhere(
      (item) => item.name == argument.parameter,
    );
    if (parameter.type == SnippetParameterType.credentialSecret) {
      words.add(
        _quoteBashWord('[Credential secret hidden: ${parameter.name}]'),
      );
    } else {
      words.add(_quoteBashWord(resolved[parameter.name]!));
    }
  }
  return SnippetInvocationPreview(
    shell: 'bash',
    command: words.join(' '),
    hasCredentialReference: hasCredential,
    canExecute: missingCredentialParameters.isEmpty,
    blockedReason: missingCredentialParameters.isNotEmpty
        ? 'A referenced password Credential is unavailable. No command will be sent.'
        : null,
  );
}

/// Wraps the reviewed Bash argv command for SSH exec. The target account's
/// login shell parses this fixed POSIX statement. It checks the conventional
/// absolute Bash paths before consulting PATH, then passes the complete
/// user-built Bash payload as one single-quoted argument to `bash -c`.
String buildBashExecRequest(
  SnippetRecord snippet, {
  Map<String, String> values = const {},
  Map<String, String> credentialSecrets = const {},
  String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
}) {
  if (!RegExp(
        r'^__ATERMIUS_BASH_UNAVAILABLE_[A-Za-z0-9_-]{1,80}__$',
      ).hasMatch(bashUnavailableMarker) &&
      bashUnavailableMarker != '__ATERMIUS_BASH_UNAVAILABLE__') {
    throw const FormatException('Invalid Bash availability marker');
  }
  final resolvedCredentials = _resolveCredentialValues(
    _usedCredentialParameters(snippet),
    credentialSecrets,
  );
  final preview = previewSnippetInvocation(
    snippet,
    values: values,
    credentialParametersAvailable: resolvedCredentials.keys.toSet(),
  );
  if (!preview.canExecute) {
    throw const FormatException(
      'This Bash snippet cannot be executed with the current parameters.',
    );
  }
  final payload = _buildBashPayload(
    snippet,
    values: values,
    credentialParameterNames: resolvedCredentials.keys.toSet(),
  );
  final quotedPayload = _quotePosixShellWord(payload);
  final credentialReads = <String>[];
  var credentialIndex = 0;
  for (final parameter in _usedCredentialParameters(snippet)) {
    final environmentName = _credentialEnvironmentName(credentialIndex++);
    credentialReads.add(
      'IFS= read -r $environmentName || exit 125; export $environmentName; ',
    );
  }
  return "bash_path=; if [ -x /bin/bash ]; then bash_path=/bin/bash; elif [ -x /usr/bin/bash ]; then bash_path=/usr/bin/bash; elif [ -x /usr/local/bin/bash ]; then bash_path=/usr/local/bin/bash; else bash_path=\$(command -v bash 2>/dev/null); fi; if [ -n \"\$bash_path\" ] && [ -x \"\$bash_path\" ]; then ${credentialReads.join()}exec \"\$bash_path\" -c $quotedPayload; else printf '%s\\n' '$bashUnavailableMarker' >&2; exit 127; fi";
}

/// Encodes Credential values for the SSH exec channel's stdin. The wrapper
/// reads one literal line per secret; control characters are rejected so a
/// value cannot create another parameter record. The returned bytes are
/// mutable so the caller can clear them after the SSH channel closes.
Uint8List buildSnippetCredentialInput(
  SnippetRecord snippet, {
  required Map<String, String> credentialSecrets,
}) {
  final resolved = _resolveCredentialValues(
    _usedCredentialParameters(snippet),
    credentialSecrets,
  );
  final builder = BytesBuilder(copy: false);
  for (final parameter in _usedCredentialParameters(snippet)) {
    builder.add(utf8.encode('${resolved[parameter.name]}\n'));
  }
  return builder.takeBytes();
}

/// Returns one already-quoted Bash word per argv item, joined as a command.
/// Credential values are intentionally never accepted by this path.
String buildSnippetCommand(
  SnippetRecord snippet, {
  Map<String, String> values = const {},
}) {
  validateSnippetDefinition(snippet);
  if (snippet.executionMode == SnippetExecutionMode.script) {
    if (snippet.body.trim().isEmpty) {
      throw const FormatException('Snippet script is empty');
    }
    return snippet.body;
  }
  if (_usedCredentialParameters(snippet).isNotEmpty) {
    throw const FormatException(
      'Credential secrets require the confirmed SSH exec channel.',
    );
  }
  final resolved = _resolveTextValues(snippet.parameters, values);
  return _buildBashPayload(snippet, values: resolved);
}

String _buildBashPayload(
  SnippetRecord snippet, {
  Map<String, String> values = const {},
  Set<String> credentialParameterNames = const {},
}) {
  validateSnippetDefinition(snippet);
  final resolved = _resolveTextValues(snippet.parameters, values);
  final credentialIndexes = <String, int>{};
  var nextCredentialIndex = 0;
  for (final parameter in _usedCredentialParameters(snippet)) {
    credentialIndexes[parameter.name] = nextCredentialIndex++;
  }
  if (credentialIndexes.keys
      .toSet()
      .difference(credentialParameterNames)
      .isNotEmpty) {
    throw const FormatException('Credential secret values are required.');
  }
  final words = <String>[_quoteBashWord(snippet.program)];
  final secretLocals = <String>[];
  for (final entry in credentialIndexes.entries) {
    final environmentName = _credentialEnvironmentName(entry.value);
    final localName = '_atermius_snippet_secret_${entry.value}';
    secretLocals.add(
      '$localName="\$$environmentName"; unset $environmentName; ',
    );
  }
  for (final argument in snippet.arguments) {
    if (argument.value != null) {
      words.add(_quoteBashWord(argument.value!));
      continue;
    }
    final parameter = snippet.parameters.firstWhere(
      (item) => item.name == argument.parameter,
    );
    if (parameter.type == SnippetParameterType.credentialSecret) {
      final index = credentialIndexes[parameter.name]!;
      final localName = '_atermius_snippet_secret_$index';
      words.add('"\$$localName"');
    } else {
      words.add(_quoteBashWord(resolved[parameter.name]!));
    }
  }
  return '${secretLocals.join()}${words.join(' ')}';
}

Map<String, String> _resolveCredentialValues(
  List<SnippetParameter> parameters,
  Map<String, String> values,
) {
  final credentialParameters = parameters
      .where(
        (parameter) => parameter.type == SnippetParameterType.credentialSecret,
      )
      .toList(growable: false);
  final names = credentialParameters.map((parameter) => parameter.name).toSet();
  for (final supplied in values.keys) {
    if (!names.contains(supplied)) {
      throw FormatException('Unexpected Credential parameter value: $supplied');
    }
  }
  final resolved = <String, String>{};
  for (final parameter in credentialParameters) {
    final value = values[parameter.name];
    if (value == null || value.isEmpty) {
      throw FormatException(
        'A password Credential is required for parameter ${parameter.name}.',
      );
    }
    if (value.length > maxSnippetTextLength) {
      throw FormatException(
        'Credential value for ${parameter.name} is too long.',
      );
    }
    _validateNoControls(value, 'Credential value for ${parameter.name}');
    resolved[parameter.name] = value;
  }
  return resolved;
}

List<SnippetParameter> _usedCredentialParameters(SnippetRecord snippet) {
  final referencedNames = snippet.arguments
      .map((argument) => argument.parameter)
      .whereType<String>()
      .toSet();
  return snippet.parameters
      .where(
        (parameter) =>
            parameter.type == SnippetParameterType.credentialSecret &&
            referencedNames.contains(parameter.name),
      )
      .toList(growable: false);
}

String _credentialEnvironmentName(int index) =>
    'ATERMIUS_SNIPPET_SECRET_$index';

Map<String, String> _resolveTextValues(
  List<SnippetParameter> parameters,
  Map<String, String> values,
) {
  final textParameters = parameters
      .where((parameter) => parameter.type == SnippetParameterType.text)
      .toList(growable: false);
  final names = textParameters.map((parameter) => parameter.name).toSet();
  for (final supplied in values.keys) {
    if (!names.contains(supplied)) {
      throw FormatException('Unexpected snippet parameter value: $supplied');
    }
  }
  final result = <String, String>{};
  for (final parameter in textParameters) {
    final value = values[parameter.name] ?? parameter.defaultValue;
    if (value == null) {
      throw FormatException('Value required for parameter ${parameter.name}');
    }
    _validateTextValue(value, parameter.name);
    result[parameter.name] = value;
  }
  return result;
}

void _validateTextValue(String value, String name) {
  if (value.length > maxSnippetTextLength) {
    throw FormatException('Value for $name is too long');
  }
  _validateNoControls(value, 'Value for $name');
}

void _validateLiteral(String value, String field, {bool allowEmpty = true}) {
  if (!allowEmpty && value.isEmpty) {
    throw FormatException('$field is required');
  }
  if (value.length > maxSnippetTextLength) {
    throw FormatException('$field is too long');
  }
  _validateNoControls(value, field);
}

void _validateNoControls(String value, String field) {
  if (value.runes.any(
    (rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f),
  )) {
    throw FormatException(
      '$field cannot contain NUL, newlines, or control characters',
    );
  }
}

String _quoteBashWord(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _quotePosixShellWord(String value) =>
    "'${value.replaceAll("'", "'\\''")}'";

/// Makes invisible controls visible in the confirmation dialog without
/// changing the command bytes that would be sent to the active SSH session.
String formatSnippetPreviewText(String command) {
  final output = StringBuffer();
  for (final rune in command.runes) {
    if (rune == 0x0a) {
      output.write('\n');
    } else if (rune == 0x09) {
      output.write(r'\t');
    } else if (rune == 0x0d) {
      output.write(r'\r');
    } else if (_isInvisibleOrControlRune(rune)) {
      output
        ..write(r'\u{')
        ..write(rune.toRadixString(16))
        ..write('}');
    } else {
      output.write(String.fromCharCode(rune));
    }
  }
  return output.toString();
}

bool _isInvisibleOrControlRune(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x00ad ||
    rune == 0x061c ||
    rune == 0x034f ||
    (rune >= 0x200b && rune <= 0x200f) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x206f) ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0xfeff ||
    (rune >= 0xe0100 && rune <= 0xe01ef) ||
    (rune >= 0xe0000 && rune <= 0xe007f);
