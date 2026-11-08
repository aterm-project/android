enum ConflictKind {
  none,
  fields,
  credential,
  security,
  deleteEdit,
  unsupported,
}

class MergeResult {
  const MergeResult({required this.value, required this.conflicts});

  final Map<String, Object?> value;
  final Map<String, FieldConflict> conflicts;

  bool get clean => conflicts.isEmpty;
}

class FieldConflict {
  const FieldConflict({
    required this.base,
    required this.local,
    required this.remote,
  });

  final Object? base;
  final Object? local;
  final Object? remote;
}

const _credentialFields = {
  'login',
  'secret',
  'private_key',
  'passphrase',
  'certificate',
  'credential_id',
  'auth_kind',
};
const _securityFields = {
  'protocol',
  'rdp_cert_sha256',
  'address',
  'port',
  'proxy',
  'jump_chain',
  'jump_host_id',
  'port_forward_profiles',
  'host_key',
  'known_host',
};

ConflictKind conflictKindFor(String field) {
  if (_credentialFields.contains(field)) return ConflictKind.credential;
  if (_securityFields.contains(field)) return ConflictKind.security;
  return ConflictKind.fields;
}

/// A field-aware three-way merge. Sensitive fields are never silently selected.
MergeResult mergeRecord({
  required Map<String, Object?> base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
}) {
  // Preferences use the project's deterministic same-key policy: keep the
  // local value as the working candidate while SyncRepository retains both
  // signed encrypted branches for later review or restoration.
  final localPreference =
      base['type'] == 'preference' &&
      local['type'] == 'preference' &&
      remote['type'] == 'preference';
  final keys = <String>{...base.keys, ...local.keys, ...remote.keys};
  final result = <String, Object?>{};
  final conflicts = <String, FieldConflict>{};

  for (final key in keys) {
    final b = base[key];
    final l = local[key];
    final r = remote[key];
    if (_same(l, b)) {
      if (remote.containsKey(key)) result[key] = r;
    } else if (_same(r, b) || _same(l, r)) {
      if (local.containsKey(key)) result[key] = l;
    } else {
      conflicts[key] = FieldConflict(base: b, local: l, remote: r);
      // Keep a usable candidate while preserving both branches for resolution.
      if (localPreference) {
        if (local.containsKey(key)) result[key] = l;
      } else if (remote.containsKey(key)) {
        result[key] = r;
      }
    }
  }

  return MergeResult(value: result, conflicts: conflicts);
}

/// Returns whether a clean three-way result may be committed without asking
/// the user. Automatic merging is deliberately limited to low-risk display
/// fields; edits to credentials, connection security, executable content,
/// references, and unknown fields still require explicit review.
bool isAutomaticMergeSafe({
  required Map<String, Object?> base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
  required MergeResult result,
}) {
  if (!result.clean ||
      base['id'] != local['id'] ||
      base['id'] != remote['id'] ||
      base['type'] != local['type'] ||
      base['type'] != remote['type']) {
    return false;
  }

  final allowedFields = switch (base['type']) {
    'host' => const {'name', 'color', 'tags', 'is_favorite'},
    'group' => const {'name', 'color'},
    'credential' => const {'name'},
    'snippet' => const {'title', 'tags'},
    // Workspaces, KnownHosts, preferences and shell history have additional
    // structural or ordering semantics that field-wise merge cannot preserve.
    _ => const <String>{},
  };
  if (allowedFields.isEmpty) return false;

  final keys = <String>{...base.keys, ...local.keys, ...remote.keys};
  for (final key in keys) {
    if (_same(base[key], local[key]) && _same(base[key], remote[key])) {
      continue;
    }
    if (!allowedFields.contains(key)) return false;
  }
  return true;
}

bool _same(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_same(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_same(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
