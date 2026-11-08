import 'dart:convert';

import 'window_combination.dart';

import 'package:uuid/uuid.dart';

/// Stable semantic actions whose keyboard bindings may be synchronized.
///
/// Physical modifier keys are resolved by each client platform. In particular,
/// `mod` means Command on Apple platforms and Control elsewhere.
enum TerminalShortcutAction {
  search('terminal.search', 'Search terminal scrollback'),
  searchNext('terminal.searchNext', 'Next search match'),
  searchPrevious('terminal.searchPrevious', 'Previous search match'),
  disconnect('terminal.disconnect', 'Disconnect active terminal tab');

  const TerminalShortcutAction(this.id, this.label);

  final String id;
  final String label;

  static TerminalShortcutAction fromId(String value) {
    for (final action in values) {
      if (action.id == value) return action;
    }
    throw const FormatException('Terminal shortcut action is not supported');
  }
}

/// Strict, normalized semantic key bindings stored in one encrypted
/// `workspace/terminalShortcuts/all` preference.
class TerminalShortcutBindings {
  TerminalShortcutBindings._(Map<TerminalShortcutAction, String> bindings)
    : _bindings = Map.unmodifiable(bindings);

  factory TerminalShortcutBindings.fromBindings(
    Map<TerminalShortcutAction, String> bindings,
  ) {
    if (bindings.length != TerminalShortcutAction.values.length ||
        bindings.keys.toSet().length != TerminalShortcutAction.values.length ||
        !bindings.keys.toSet().containsAll(TerminalShortcutAction.values)) {
      throw const FormatException(
        'All supported terminal shortcut actions must be bound exactly once',
      );
    }
    final normalized = <TerminalShortcutAction, String>{};
    final seenChords = <String>{};
    for (final action in TerminalShortcutAction.values) {
      final chord = normalizeChord(bindings[action]!);
      if (!seenChords.add(chord)) {
        throw const FormatException('Terminal shortcut chords must be unique');
      }
      normalized[action] = chord;
    }
    return TerminalShortcutBindings._(normalized);
  }

  factory TerminalShortcutBindings.fromValue(String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const FormatException('Terminal shortcut value is not valid JSON');
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('Terminal shortcut value must be an object');
    }
    final json = Map<String, Object?>.from(decoded);
    if (json.length != 2 ||
        !json.containsKey('version') ||
        !json.containsKey('bindings') ||
        json['version'] != version) {
      throw const FormatException('Terminal shortcut value version is invalid');
    }
    final rawBindings = json['bindings'];
    if (rawBindings is! Map ||
        rawBindings.keys.any((key) => key is! String) ||
        rawBindings.length != TerminalShortcutAction.values.length) {
      throw const FormatException('Terminal shortcut bindings are invalid');
    }
    final bindings = <TerminalShortcutAction, String>{};
    for (final entry in rawBindings.entries) {
      final action = TerminalShortcutAction.fromId(entry.key as String);
      if (entry.value is! String) {
        throw const FormatException('Terminal shortcut chord must be a string');
      }
      bindings[action] = entry.value as String;
    }
    final result = TerminalShortcutBindings.fromBindings(bindings);
    if (result.toValue() != value) {
      throw const FormatException(
        'Terminal shortcut value must use canonical encoding',
      );
    }
    return result;
  }

  static const int version = 1;
  static const Map<TerminalShortcutAction, String> defaultValues = {
    TerminalShortcutAction.search: 'mod+alt+shift+f',
    TerminalShortcutAction.searchNext: 'mod+alt+g',
    TerminalShortcutAction.searchPrevious: 'mod+alt+shift+g',
    TerminalShortcutAction.disconnect: 'mod+alt+shift+d',
  };
  static final TerminalShortcutBindings defaults =
      TerminalShortcutBindings.fromBindings(defaultValues);

  static const _modifierOrder = ['mod', 'alt', 'shift'];
  static final RegExp _letterOrDigit = RegExp(r'^[a-z0-9]$');
  static final RegExp _functionKey = RegExp(r'^f(?:[1-9]|1[0-2])$');
  static const _reservedChords = <String>{
    // Browser navigation, tab/window management, and page actions.
    'mod+w',
    'mod+q',
    'mod+r',
    'mod+shift+r',
    'mod+t',
    'mod+shift+t',
    'mod+l',
    'mod+f',
    'mod+g',
    'mod+p',
    'mod+s',
    'mod+o',
    'mod+n',
    'mod+shift+w',
    'mod+shift+n',
    'mod+shift+p',
    'mod+shift+g',
    'mod+shift+f',
    'mod+shift+d',
    // Common Chromium, Firefox, and WebKit developer-tool bindings.
    'mod+shift+i',
    'mod+shift+j',
    'mod+shift+c',
    'mod+shift+k',
    'mod+shift+m',
    'mod+alt+i',
    'mod+alt+j',
    'mod+alt+c',
    'mod+alt+u',
    // Common OS window manager / developer-tool bindings.
    'alt+f1',
    'alt+f2',
    'alt+f4',
    'alt+f7',
    'alt+f8',
    'alt+f9',
    'alt+f10',
    'alt+f12',
    'mod+f12',
  };

  final Map<TerminalShortcutAction, String> _bindings;

  String chordFor(TerminalShortcutAction action) => _bindings[action]!;

  Map<TerminalShortcutAction, String> get bindings => _bindings;

  /// Normalizes modifier case/order and the key name, rejecting unsupported or
  /// commonly browser/system-reserved chords. Bare keys are not allowed.
  static String normalizeChord(String value) {
    final pieces = value.trim().toLowerCase().split('+');
    if (pieces.length < 2 || pieces.any((piece) => piece.isEmpty)) {
      throw const FormatException('Terminal shortcut chord is invalid');
    }
    final tokens = pieces.map((piece) => piece.trim()).toList(growable: false);
    final modifiers = <String>[];
    String? key;
    for (final token in tokens) {
      if (_modifierOrder.contains(token)) {
        if (modifiers.contains(token)) {
          throw const FormatException('Terminal shortcut modifier is repeated');
        }
        modifiers.add(token);
      } else {
        if (key != null ||
            (!_letterOrDigit.hasMatch(token) &&
                !_functionKey.hasMatch(token))) {
          throw const FormatException('Terminal shortcut key is not supported');
        }
        key = token;
      }
    }
    if (key == null ||
        (!modifiers.contains('mod') && !modifiers.contains('alt'))) {
      throw const FormatException(
        'Terminal shortcut requires the mod or alt modifier',
      );
    }
    modifiers.sort((left, right) {
      return _modifierOrder
          .indexOf(left)
          .compareTo(_modifierOrder.indexOf(right));
    });
    final normalized = [...modifiers, key].join('+');
    if (_reservedChords.contains(normalized)) {
      throw const FormatException(
        'Terminal shortcut chord is reserved by the browser or operating system',
      );
    }
    return normalized;
  }

  String toValue() => jsonEncode({
    'version': version,
    'bindings': {
      for (final action in TerminalShortcutAction.values)
        action.id: _bindings[action],
    },
  });

  @override
  bool operator ==(Object other) =>
      other is TerminalShortcutBindings &&
      TerminalShortcutAction.values.every(
        (action) => other._bindings[action] == _bindings[action],
      );

  @override
  int get hashCode => Object.hashAll(
    TerminalShortcutAction.values.map((action) => _bindings[action]),
  );
}

/// A named terminal palette supported by the synchronized preference DTO.
///
/// Keep these values deliberately small and stable: they are stored inside
/// signed, encrypted Vault records and decoded by every client version.
enum VaultTerminalThemeChoice {
  atermDark('atermius-dark', 'Atermius Dark'),
  light('light', 'Light');

  const VaultTerminalThemeChoice(this.value, this.label);

  final String value;
  final String label;

  static VaultTerminalThemeChoice fromValue(String value) => switch (value) {
    'atermius-dark' => VaultTerminalThemeChoice.atermDark,
    'light' => VaultTerminalThemeChoice.light,
    _ => throw const FormatException('Terminal theme is not supported'),
  };
}

/// A strictly allowlisted Vault-synced workspace preference.
///
/// The original `workspace/defaultSection/all` payload remains unchanged.
/// Additional logical preferences are added only as explicit tuple/value
/// allowlists so arbitrary settings and platform-local state cannot silently
/// enter Vault sync.
class VaultPreferenceRecord {
  VaultPreferenceRecord._({
    required this.id,
    required this.scope,
    required this.key,
    required this.value,
    required this.platformFamily,
    required this.revisionId,
  });

  /// Creates a new default-workspace-section record with a fresh UUIDv4.
  ///
  /// Pass [id] when constructing a replacement payload for an existing
  /// record; [copyWith] is usually preferable when retaining its revision.
  factory VaultPreferenceRecord.defaultWorkspaceSection({
    required String value,
    String? id,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    _validateDefaultSectionValue(value);
    return VaultPreferenceRecord._(
      id: resolvedId,
      scope: workspaceScope,
      key: defaultSectionKey,
      value: value,
      platformFamily: allPlatforms,
      revisionId: null,
    );
  }

  /// Creates a terminal font-size record with a fresh UUIDv4.
  ///
  /// The wire value remains a decimal string, matching the strict preference
  /// record shape used by the existing default-section setting.
  factory VaultPreferenceRecord.terminalFontSize({
    required int fontSize,
    String? id,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    _validateTerminalFontSize(fontSize.toString());
    return VaultPreferenceRecord._(
      id: resolvedId,
      scope: workspaceScope,
      key: terminalFontSizeKey,
      value: fontSize.toString(),
      platformFamily: allPlatforms,
      revisionId: null,
    );
  }

  /// Creates a terminal color-theme preference with a fresh UUIDv4.
  factory VaultPreferenceRecord.terminalTheme({
    required VaultTerminalThemeChoice theme,
    String? id,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    _validateTerminalTheme(theme.value);
    return VaultPreferenceRecord._(
      id: resolvedId,
      scope: workspaceScope,
      key: terminalThemeKey,
      value: theme.value,
      platformFamily: allPlatforms,
      revisionId: null,
    );
  }

  /// Creates a semantic terminal-shortcut binding record with a fresh UUIDv4.
  factory VaultPreferenceRecord.terminalShortcuts({
    required TerminalShortcutBindings bindings,
    String? id,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    return VaultPreferenceRecord._(
      id: resolvedId,
      scope: workspaceScope,
      key: terminalShortcutsKey,
      value: bindings.toValue(),
      platformFamily: allPlatforms,
      revisionId: null,
    );
  }

  factory VaultPreferenceRecord.windowCombinations({
    required String value,
    String? id,
  }) {
    WindowCombination.decode(value);
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    return VaultPreferenceRecord._(
      id: resolvedId,
      scope: workspaceScope,
      key: windowCombinationsKey,
      value: value,
      platformFamily: allPlatforms,
      revisionId: null,
    );
  }

  /// Decodes a strict v1 payload, optionally accepting repository metadata.
  ///
  /// Repository fields are accepted so a decrypted `loadRecords()` row can be
  /// passed directly. They are validated, but are never returned by [toJson].
  factory VaultPreferenceRecord.fromJson(Map<String, dynamic> json) {
    const requiredFields = {
      'id',
      'type',
      'scope',
      'key',
      'value',
      'platform_family',
    };
    const repositoryFields = {'_record_id', '_revision_id', '_manifest'};
    final keys = json.keys.toSet();
    if (!keys.containsAll(requiredFields) ||
        keys.any(
          (field) =>
              !requiredFields.contains(field) &&
              !repositoryFields.contains(field),
        )) {
      throw const FormatException(
        'Preference record fields are incomplete or unknown',
      );
    }
    if (json['type'] != 'preference') {
      throw const FormatException('Record type must be preference');
    }

    final id = _requiredString(json['id'], 'id');
    _validateUuidV4(id, 'id');
    if (json.containsKey('_record_id')) {
      final repositoryId = _requiredString(json['_record_id'], '_record_id');
      _validateUuidV4(repositoryId, '_record_id');
      if (repositoryId != id) {
        throw const FormatException(
          'Preference payload ID does not match record ID',
        );
      }
    }

    final scope = _requiredString(json['scope'], 'scope');
    final key = _requiredString(json['key'], 'key');
    final platformFamily = _requiredString(
      json['platform_family'],
      'platform_family',
    );
    if (scope != workspaceScope || platformFamily != allPlatforms) {
      throw const FormatException('Preference tuple is not supported');
    }
    final value = _requiredString(json['value'], 'value');
    switch (key) {
      case defaultSectionKey:
        _validateDefaultSectionValue(value);
      case terminalFontSizeKey:
        _validateTerminalFontSize(value);
      case terminalThemeKey:
        _validateTerminalTheme(value);
      case terminalShortcutsKey:
        TerminalShortcutBindings.fromValue(value);
      case windowCombinationsKey:
        WindowCombination.decode(value);
      default:
        throw const FormatException('Preference tuple is not supported');
    }

    final rawRevisionId = json['_revision_id'];
    final String? revisionId;
    if (!json.containsKey('_revision_id') || rawRevisionId == null) {
      revisionId = null;
    } else {
      revisionId = _requiredString(rawRevisionId, '_revision_id');
      _validateUuidV4(revisionId, '_revision_id');
    }
    if (json.containsKey('_manifest')) {
      _validateManifest(json['_manifest']);
    }

    return VaultPreferenceRecord._(
      id: id,
      scope: scope,
      key: key,
      value: value,
      platformFamily: platformFamily,
      revisionId: revisionId,
    );
  }

  static const workspaceScope = 'workspace';
  static const defaultSectionKey = 'defaultSection';
  static const terminalFontSizeKey = 'terminalFontSize';
  static const terminalThemeKey = 'terminalTheme';
  static const terminalShortcutsKey = 'terminalShortcuts';
  static const windowCombinationsKey = 'windowCombinations';
  static const allPlatforms = 'all';
  static const supportedDefaultSectionValues = <String>{
    'hosts',
    'credentials',
    'groups',
    'snippets',
  };
  static const defaultTerminalFontSize = 13;
  static const supportedTerminalFontSizes = <int>{10, 11, 12, 13, 14, 16, 18};
  static const defaultTerminalTheme = VaultTerminalThemeChoice.atermDark;
  static const supportedTerminalThemeValues = <String>{
    'atermius-dark',
    'light',
  };
  static final TerminalShortcutBindings defaultTerminalShortcuts =
      TerminalShortcutBindings.defaults;

  final String id;
  final String scope;
  final String key;
  final String value;
  final String platformFamily;

  /// Current server revision, sourced only from `_revision_id` metadata.
  final String? revisionId;

  bool get isDefaultWorkspaceSection =>
      scope == workspaceScope &&
      key == defaultSectionKey &&
      platformFamily == allPlatforms;

  bool get isTerminalFontSize =>
      scope == workspaceScope &&
      key == terminalFontSizeKey &&
      platformFamily == allPlatforms;

  bool get isTerminalTheme =>
      scope == workspaceScope &&
      key == terminalThemeKey &&
      platformFamily == allPlatforms;

  bool get isTerminalShortcuts =>
      scope == workspaceScope &&
      key == terminalShortcutsKey &&
      platformFamily == allPlatforms;

  int get terminalFontSizeValue {
    if (!isTerminalFontSize) {
      throw StateError('Preference is not a terminal font-size record.');
    }
    return int.parse(value);
  }

  VaultTerminalThemeChoice get terminalThemeValue {
    if (!isTerminalTheme) {
      throw StateError('Preference is not a terminal theme record.');
    }
    return VaultTerminalThemeChoice.fromValue(value);
  }

  TerminalShortcutBindings get terminalShortcutBindings {
    if (!isTerminalShortcuts) {
      throw StateError('Preference is not a terminal shortcut record.');
    }
    return TerminalShortcutBindings.fromValue(value);
  }

  static bool isSupportedDefaultSectionValue(Object? value) =>
      value is String && supportedDefaultSectionValues.contains(value);

  /// Copies this record while keeping its ID and logical preference tuple.
  VaultPreferenceRecord copyWith({Object? value, String? revisionId}) {
    final nextValue = value ?? this.value;
    if (nextValue is! String) {
      throw const FormatException('Preference value must be a string');
    }
    _validatePreferenceValue(key, nextValue);
    if (revisionId != null) _validateUuidV4(revisionId, '_revision_id');
    return VaultPreferenceRecord._(
      id: id,
      scope: scope,
      key: key,
      value: nextValue,
      platformFamily: platformFamily,
      revisionId: revisionId ?? this.revisionId,
    );
  }

  /// Serializes only the v1 encrypted payload; repository metadata is omitted.
  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'preference',
    'scope': scope,
    'key': key,
    'value': value,
    'platform_family': platformFamily,
  };
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

void _validatePreferenceValue(String key, String value) {
  switch (key) {
    case VaultPreferenceRecord.defaultSectionKey:
      _validateDefaultSectionValue(value);
    case VaultPreferenceRecord.terminalFontSizeKey:
      _validateTerminalFontSize(value);
    case VaultPreferenceRecord.terminalThemeKey:
      _validateTerminalTheme(value);
    case VaultPreferenceRecord.terminalShortcutsKey:
      TerminalShortcutBindings.fromValue(value);
    case VaultPreferenceRecord.windowCombinationsKey:
      WindowCombination.decode(value);
    default:
      throw const FormatException('Preference key is not supported');
  }
}

void _validateDefaultSectionValue(String value) {
  if (!VaultPreferenceRecord.isSupportedDefaultSectionValue(value)) {
    throw const FormatException('Default section value is not supported');
  }
}

void _validateTerminalFontSize(String value) {
  final parsed = int.tryParse(value);
  if (parsed == null ||
      parsed.toString() != value ||
      !VaultPreferenceRecord.supportedTerminalFontSizes.contains(parsed)) {
    throw const FormatException('Terminal font size is not supported');
  }
}

void _validateTerminalTheme(String value) {
  if (!VaultPreferenceRecord.supportedTerminalThemeValues.contains(value)) {
    throw const FormatException('Terminal theme is not supported');
  }
}

void _validateUuidV4(String value, String field) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw FormatException('$field must be a lowercase UUIDv4');
  }
}

void _validateManifest(Object? raw) {
  if (raw == null) return;
  if (raw is! Map) {
    throw const FormatException('Record _manifest must be a JSON object');
  }
  if (raw.keys.any((key) => key is! String)) {
    throw const FormatException('Record _manifest keys must be strings');
  }
}
