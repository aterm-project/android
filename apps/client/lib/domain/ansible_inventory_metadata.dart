import 'dart:convert';

const ansibleInventoryManifestKey = 'ansible_inventory_v1';

enum AnsibleInventoryEntryState { active, stale }

/// The exact allowlisted Host projection previously accepted from an
/// inventory. It never contains the original inventory text or credentials.
class AnsibleInventoryImportedValues {
  AnsibleInventoryImportedValues({
    required this.name,
    required this.address,
    required this.port,
    required this.username,
    required List<String> tags,
  }) : tags = List.unmodifiable(_normalizedTags(tags)) {
    if (_safeText(name, 'baseline name', 256).trim().isEmpty ||
        _safeText(address, 'baseline address', 1024).trim().isEmpty ||
        _safeText(username, 'baseline username', 256).trim().isEmpty ||
        port < 1 ||
        port > 65535 ||
        this.tags.length > 128 ||
        this.tags.any(
          (tag) =>
              tag.isEmpty ||
              tag != tag.trim() ||
              utf8.encode(tag).length > 64 ||
              RegExp(r'[\u0000-\u001f\u007f]').hasMatch(tag),
        )) {
      throw const FormatException('Ansible inventory baseline is invalid.');
    }
  }

  final String name;
  final String address;
  final int port;
  final String username;
  final List<String> tags;

  Map<String, Object?> toJson() => {
    'name': name,
    'address': address,
    'port': port,
    'username': username,
    'tags': tags,
  };

  factory AnsibleInventoryImportedValues.fromJson(Object? value) {
    final json = _strictObject(value, 'inventory baseline');
    _requireKeys(json, const {'name', 'address', 'port', 'username', 'tags'});
    final name = _safeText(json['name'], 'baseline name', 256);
    final address = _safeText(json['address'], 'baseline address', 1024);
    final username = _safeText(json['username'], 'baseline username', 256);
    final port = json['port'];
    final rawTags = json['tags'];
    if (name.trim().isEmpty ||
        address.trim().isEmpty ||
        username.trim().isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        rawTags is! List ||
        rawTags.length > 128) {
      throw const FormatException('Ansible inventory baseline is invalid.');
    }
    final tags = <String>[];
    final seen = <String>{};
    for (final rawTag in rawTags) {
      final tag = _safeText(rawTag, 'baseline tag', 64);
      if (tag.isEmpty || tag != tag.trim() || !seen.add(tag.toLowerCase())) {
        throw const FormatException('Ansible inventory baseline is invalid.');
      }
      tags.add(tag);
    }
    return AnsibleInventoryImportedValues(
      name: name,
      address: address,
      port: port,
      username: username,
      tags: tags,
    );
  }

  bool sameAs(AnsibleInventoryImportedValues other) =>
      name == other.name &&
      address == other.address &&
      port == other.port &&
      username == other.username &&
      _sameTags(tags, other.tags);

  static List<String> _normalizedTags(List<String> values) {
    final unique = <String, String>{};
    for (final tag in values) {
      unique.putIfAbsent(tag.toLowerCase(), () => tag);
    }
    return unique.values.toList()..sort((left, right) {
      final folded = left.toLowerCase().compareTo(right.toLowerCase());
      return folded == 0 ? left.compareTo(right) : folded;
    });
  }
}

/// Encrypted per-Host inventory provenance and the last accepted source
/// projection. The source label and entry key are bounded user-facing identity
/// values; paths, source contents, arbitrary variables, and credentials are
/// intentionally absent.
class AnsibleInventoryImportMetadata {
  AnsibleInventoryImportMetadata({
    required this.sourceId,
    required this.sourceLabel,
    required this.entryKey,
    required this.baseline,
    this.state = AnsibleInventoryEntryState.active,
    List<String> suppressedTags = const [],
    List<String> retainedTags = const [],
  }) : suppressedTags = List.unmodifiable(
         AnsibleInventoryImportedValues._normalizedTags(suppressedTags),
       ),
       retainedTags = List.unmodifiable(
         AnsibleInventoryImportedValues._normalizedTags(retainedTags),
       ) {
    _validate();
  }

  final String sourceId;
  final String sourceLabel;
  final String entryKey;
  final AnsibleInventoryImportedValues baseline;
  final AnsibleInventoryEntryState state;
  final List<String> suppressedTags;
  final List<String> retainedTags;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'source_id': sourceId,
    'source_label': sourceLabel,
    'entry_key': entryKey,
    'baseline': baseline.toJson(),
    'state': state.name,
    'suppressed_tags': suppressedTags,
    'retained_tags': retainedTags,
  };

  factory AnsibleInventoryImportMetadata.fromJson(Object? value) {
    final json = _strictObject(value, 'inventory import metadata');
    _requireKeys(json, const {
      'schema_version',
      'source_id',
      'source_label',
      'entry_key',
      'baseline',
      'state',
      'suppressed_tags',
      'retained_tags',
    });
    if (json['schema_version'] != 1) {
      throw const FormatException(
        'Ansible inventory metadata version is unsupported.',
      );
    }
    final stateMatches = AnsibleInventoryEntryState.values.where(
      (candidate) => candidate.name == json['state'],
    );
    final state = stateMatches.isEmpty ? null : stateMatches.first;
    final rawSuppressedTags = json['suppressed_tags'];
    final rawRetainedTags = json['retained_tags'];
    if (state == null ||
        rawSuppressedTags is! List ||
        rawSuppressedTags.length > 128 ||
        rawRetainedTags is! List ||
        rawRetainedTags.length > 128) {
      throw const FormatException('Ansible inventory metadata is invalid.');
    }
    final suppressedTags = <String>[];
    final seenSuppressed = <String>{};
    for (final rawTag in rawSuppressedTags) {
      final tag = _safeText(rawTag, 'suppressed tag', 64);
      if (tag.isEmpty ||
          tag != tag.trim() ||
          !seenSuppressed.add(tag.toLowerCase())) {
        throw const FormatException('Ansible inventory metadata is invalid.');
      }
      suppressedTags.add(tag);
    }
    final retainedTags = <String>[];
    final seenRetained = <String>{};
    for (final rawTag in rawRetainedTags) {
      final tag = _safeText(rawTag, 'retained tag', 64);
      if (tag.isEmpty ||
          tag != tag.trim() ||
          !seenRetained.add(tag.toLowerCase())) {
        throw const FormatException('Ansible inventory metadata is invalid.');
      }
      retainedTags.add(tag);
    }
    return AnsibleInventoryImportMetadata(
      sourceId: _safeUuid(json['source_id']),
      sourceLabel: _safeText(json['source_label'], 'source label', 128),
      entryKey: _safeText(json['entry_key'], 'entry key', 128),
      baseline: AnsibleInventoryImportedValues.fromJson(json['baseline']),
      state: state,
      suppressedTags: suppressedTags,
      retainedTags: retainedTags,
    );
  }

  factory AnsibleInventoryImportMetadata.fromManifest(
    Map<String, Object?>? manifest,
  ) {
    if (manifest == null ||
        !manifest.containsKey(ansibleInventoryManifestKey)) {
      throw const FormatException('Ansible inventory metadata is absent.');
    }
    return AnsibleInventoryImportMetadata.fromJson(
      manifest[ansibleInventoryManifestKey],
    );
  }

  AnsibleInventoryImportMetadata copyWith({
    String? sourceLabel,
    AnsibleInventoryImportedValues? baseline,
    AnsibleInventoryEntryState? state,
    List<String>? suppressedTags,
    List<String>? retainedTags,
  }) => AnsibleInventoryImportMetadata(
    sourceId: sourceId,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    entryKey: entryKey,
    baseline: baseline ?? this.baseline,
    state: state ?? this.state,
    suppressedTags: suppressedTags ?? this.suppressedTags,
    retainedTags: retainedTags ?? this.retainedTags,
  );

  void _validate() {
    _safeUuid(sourceId);
    _safeText(sourceLabel, 'source label', 128);
    _safeText(entryKey, 'entry key', 128);
    if (sourceLabel.trim().isEmpty ||
        entryKey.isEmpty ||
        entryKey != entryKey.trim() ||
        suppressedTags.length > 128 ||
        retainedTags.length > 128 ||
        !_validMetadataTags(suppressedTags) ||
        !_validMetadataTags(retainedTags) ||
        suppressedTags
            .map((tag) => tag.toLowerCase())
            .toSet()
            .intersection(retainedTags.map((tag) => tag.toLowerCase()).toSet())
            .isNotEmpty) {
      throw const FormatException('Ansible inventory metadata is invalid.');
    }
  }
}

bool _validMetadataTags(List<String> tags) => tags.every(
  (tag) =>
      tag.isNotEmpty &&
      tag == tag.trim() &&
      utf8.encode(tag).length <= 64 &&
      !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(tag),
);

AnsibleInventoryImportMetadata? readAnsibleInventoryMetadata(
  Map<String, Object?>? manifest,
) {
  if (manifest == null || !manifest.containsKey(ansibleInventoryManifestKey)) {
    return null;
  }
  return AnsibleInventoryImportMetadata.fromManifest(manifest);
}

Map<String, Object?>? writeAnsibleInventoryMetadata(
  Map<String, Object?>? manifest,
  AnsibleInventoryImportMetadata? metadata,
) {
  final next = Map<String, Object?>.from(manifest ?? const {});
  if (metadata == null) {
    next.remove(ansibleInventoryManifestKey);
  } else {
    next[ansibleInventoryManifestKey] = metadata.toJson();
  }
  return next.isEmpty ? null : next;
}

bool _sameTags(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _strictObject(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Ansible $label must be an object.');
  }
  return Map<String, Object?>.from(value);
}

void _requireKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.keys.toSet().difference(expected).isNotEmpty ||
      !value.keys.toSet().containsAll(expected)) {
    throw const FormatException(
      'Ansible inventory metadata fields are invalid.',
    );
  }
}

String _safeText(Object? value, String label, int maxBytes) {
  if (value is! String ||
      utf8.encode(value).length > maxBytes ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
    throw FormatException('Ansible $label is invalid.');
  }
  return value;
}

String _safeUuid(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value)) {
    throw const FormatException('Ansible inventory source ID is invalid.');
  }
  return value;
}
