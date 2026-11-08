import '../crypto/jcs.dart';
import 'merge.dart';
import 'models.dart';

enum HostSecurityMergeBranch { conflict, current }

class HostSecurityFieldPreview {
  const HostSecurityFieldPreview({
    required this.label,
    required this.base,
    required this.conflict,
    required this.current,
  });

  final String label;
  final String base;
  final String conflict;
  final String current;
}

/// Contains display-safe values only. Proxy credentials, host keys, trust
/// material, and attachment manifests are never returned to the widget.
class HostSecurityConflictMergePreview {
  const HostSecurityConflictMergePreview({
    required this.conflictId,
    required this.recordId,
    required this.branchRevisionId,
    required this.baseRevisionId,
    required this.currentHeadRevisionId,
    required this.fields,
  });

  final String conflictId;
  final String recordId;
  final String branchRevisionId;
  final String baseRevisionId;
  final String currentHeadRevisionId;
  final List<HostSecurityFieldPreview> fields;
}

enum HostSecurityMergeStatus { staged, reviewRequired }

class HostSecurityConflictMergeOutcome {
  const HostSecurityConflictMergeOutcome._({
    required this.status,
    this.resolutionRevisionId,
  });

  const HostSecurityConflictMergeOutcome.staged({required String revisionId})
    : this._(
        status: HostSecurityMergeStatus.staged,
        resolutionRevisionId: revisionId,
      );

  const HostSecurityConflictMergeOutcome.reviewRequired()
    : this._(status: HostSecurityMergeStatus.reviewRequired);

  final HostSecurityMergeStatus status;
  final String? resolutionRevisionId;
}

const hostSecurityMergeKeys = <String>{
  'protocol',
  'rdp_cert_sha256',
  'login',
  'address',
  'port',
  'username',
  'auth_kind',
  'credential_id',
  'proxy',
  'jump_chain',
  'jump_host_id',
  'port_forward_profiles',
  'host_key',
  'known_host',
  'known_hosts',
  'host_trust',
};

const _supportedHostKeys = <String>{
  'protocol',
  'rdp_cert_sha256',
  'login',
  'id',
  'type',
  'name',
  'address',
  'port',
  'username',
  'group_id',
  'credential_id',
  'jump_host_id',
  'auth_kind',
  'color',
  'tags',
  'port_forward_profiles',
  'is_favorite',
  'proxy',
  'jump_chain',
  'host_key',
  'known_host',
  'known_hosts',
  'host_trust',
  'deleted',
  '_manifest',
};

const _displayFields = <({String label, String key})>[
  (label: 'Protocol', key: 'protocol'),
  (label: 'RDP certificate SHA-256', key: 'rdp_cert_sha256'),
  (label: 'Address', key: 'address'),
  (label: 'Port', key: 'port'),
  (label: 'SSH username', key: 'username'),
  (label: 'Authentication', key: 'auth_kind'),
  (label: 'Host login', key: 'login'),
  (label: 'SSH credential override', key: 'credential_id'),
  (label: 'Proxy settings', key: 'proxy'),
  (label: 'Jump Host route', key: 'jump_host_id'),
  (label: 'Port forwarding', key: 'port_forward_profiles'),
  (label: 'Host trust', key: 'host_trust'),
];

/// Produces a safe review view only for a genuinely ambiguous Host connection
/// tuple: both verified branches changed connection-security fields from the
/// same base and the resulting tuples differ. Unknown schemas, divergent
/// non-security fields, and changed manifests fail closed.
HostSecurityConflictMergePreview? previewHostSecurityConflict({
  required String conflictId,
  required String recordId,
  required String baseRevisionId,
  required String branchRevisionId,
  required String currentHeadRevisionId,
  required Map<String, Object?> base,
  required Map<String, Object?> conflict,
  required Map<String, Object?> current,
}) {
  if (!_supportedHost(base, recordId) ||
      !_supportedHost(conflict, recordId) ||
      !_supportedHost(current, recordId) ||
      !_sameValue(base['_manifest'], conflict['_manifest']) ||
      !_sameValue(base['_manifest'], current['_manifest'])) {
    return null;
  }

  final conflictChanged = _tupleChanged(base, conflict);
  final currentChanged = _tupleChanged(base, current);
  final tupleDiffers = hostSecurityMergeKeys.any(
    (key) => !_sameField(conflict, current, key),
  );
  if (!conflictChanged || !currentChanged || !tupleDiffers) return null;

  final generic = mergeRecord(base: base, local: conflict, remote: current);
  if (generic.conflicts.keys.any(
    (key) => !hostSecurityMergeKeys.contains(key),
  )) {
    return null;
  }

  return HostSecurityConflictMergePreview(
    conflictId: conflictId,
    recordId: recordId,
    branchRevisionId: branchRevisionId,
    baseRevisionId: baseRevisionId,
    currentHeadRevisionId: currentHeadRevisionId,
    fields: List.unmodifiable([
      for (final field in _displayFields)
        HostSecurityFieldPreview(
          label: field.label,
          base: _displayValue(field.key, base),
          conflict: _displayValue(field.key, conflict),
          current: _displayValue(field.key, current),
        ),
    ]),
  );
}

/// Merges ordinary non-conflicting Host fields, then copies the entire
/// connection-security tuple from one reviewed branch. It never combines
/// address/port/proxy/jump/trust values from different branches.
Map<String, Object?>? mergeHostSecurityConflictRecord({
  required String recordId,
  required Map<String, Object?> base,
  required Map<String, Object?> conflict,
  required Map<String, Object?> current,
  required HostSecurityMergeBranch choice,
}) {
  if (!_supportedHost(base, recordId) ||
      !_supportedHost(conflict, recordId) ||
      !_supportedHost(current, recordId) ||
      !_sameValue(base['_manifest'], conflict['_manifest']) ||
      !_sameValue(base['_manifest'], current['_manifest']) ||
      !_tupleChanged(base, conflict) ||
      !_tupleChanged(base, current) ||
      !hostSecurityMergeKeys.any(
        (key) => !_sameField(conflict, current, key),
      )) {
    return null;
  }

  final generic = mergeRecord(base: base, local: conflict, remote: current);
  if (generic.conflicts.keys.any(
    (key) => !hostSecurityMergeKeys.contains(key),
  )) {
    return null;
  }

  final selected = choice == HostSecurityMergeBranch.conflict
      ? conflict
      : current;
  final merged = Map<String, Object?>.from(generic.value);
  for (final key in hostSecurityMergeKeys) {
    if (selected.containsKey(key)) {
      merged[key] = selected[key];
    } else {
      merged.remove(key);
    }
  }
  try {
    final host = HostRecord.fromJson(Map<String, dynamic>.from(merged));
    if (host.validate() != null || host.id != recordId) return null;
  } on Object {
    return null;
  }
  return merged;
}

bool _supportedHost(Map<String, Object?> value, String recordId) {
  if (value.keys.any((key) => !_supportedHostKeys.contains(key)) ||
      value['id'] != recordId ||
      value['type'] != RecordKind.host.name ||
      value['deleted'] == true ||
      (value['auth_kind'] != null &&
          !AuthKind.values.any((kind) => kind.name == value['auth_kind']))) {
    return false;
  }
  try {
    final host = HostRecord.fromJson(Map<String, dynamic>.from(value));
    return host.id == recordId && host.validate() == null;
  } on Object {
    return false;
  }
}

bool _tupleChanged(Map<String, Object?> base, Map<String, Object?> other) =>
    hostSecurityMergeKeys.any((key) => !_sameField(base, other, key));

bool _sameField(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String key,
) =>
    left.containsKey(key) == right.containsKey(key) &&
    _sameValue(left[key], right[key]);

bool _sameValue(Object? left, Object? right) {
  try {
    return canonicalJson(left) == canonicalJson(right);
  } on Object {
    return false;
  }
}

String _displayValue(String key, Map<String, Object?> record) {
  switch (key) {
    case 'address':
      final value = record[key];
      if (value is! String || value.isEmpty) return 'Invalid or unavailable';
      return value.length > 120 ? '${value.substring(0, 117)}…' : value;
    case 'port':
      final value = record[key];
      if (value == null && !record.containsKey(key)) return '22 (default)';
      return value is int ? '$value' : 'Invalid or unavailable';
    case 'username':
      final value = record[key];
      if (value is! String || value.isEmpty) return 'Invalid or unavailable';
      return value.length > 120 ? '${value.substring(0, 117)}…' : value;
    case 'auth_kind':
      final value = record[key];
      if (value == null && !record.containsKey(key))
        return 'password (default)';
      return value is String ? value : 'Invalid or unavailable';
    case 'credential_id':
      return _isConfigured(record[key]) ? '•••••••• (selected)' : 'No override';
    case 'proxy':
      return _isConfigured(record[key]) ? '••••••••' : 'Not configured';
    case 'jump_host_id':
      final chain = record['jump_chain'];
      final jump = record[key];
      if (!_isConfigured(jump) && !_isConfigured(chain))
        return 'Not configured';
      if (jump is String && jump.length >= 8) {
        return 'Host ${jump.substring(0, 8)}…';
      }
      if (chain is List) return '${chain.length} route step(s)';
      return 'Configured';
    case 'port_forward_profiles':
      final value = record[key];
      return value is List && value.isNotEmpty
          ? '${value.length} forwarding rule(s)'
          : 'None';
    case 'host_trust':
      final configured = [
        'host_key',
        'known_host',
        'known_hosts',
        'host_trust',
      ].any((field) => _isConfigured(record[field]));
      return configured ? '•••••••• (configured)' : 'No recorded trust';
    default:
      return '••••••••';
  }
}

bool _isConfigured(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is List) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}
