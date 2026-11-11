import 'dart:convert';

/// Per-machine access an external AI client has through MCP.
///
/// Ordered from least to most capable; [index] comparisons are meaningful.
enum McpAccessMode {
  /// The machine and its sessions are invisible and every direct-ID call is
  /// rejected exactly like an unknown ID.
  denied,

  /// Existing sessions may be listed and their terminal text/files read.
  /// No connection creation, focus, close, terminal input, exec or writes.
  readOnly,

  /// Every supported action. Trust/authentication prompts remain in the app.
  readWrite;

  bool get canRead => this != denied;
  bool get canWrite => this == readWrite;
  bool atLeast(McpAccessMode other) => index >= other.index;

  /// Stable wire/storage name. Never derive storage from [name] directly so
  /// renaming an enum member cannot silently reinterpret stored policy.
  String get storageName => switch (this) {
    denied => 'denied',
    readOnly => 'read_only',
    readWrite => 'read_write',
  };

  static McpAccessMode? fromStorageName(Object? value) => switch (value) {
    'denied' => denied,
    'read_only' => readOnly,
    'read_write' => readWrite,
    _ => null,
  };

  static McpAccessMode min(McpAccessMode a, McpAccessMode b) =>
      a.index <= b.index ? a : b;
}

/// Explicit policy identity for hostless local sessions (local shell and
/// serial consoles). Generated host IDs are UUIDs; a saved host or remote
/// session that nevertheless claims this ID is treated as unattributable and
/// denied, and a session without either a saved host or this identity is
/// always treated as [McpAccessMode.denied].
const mcpLocalDeviceHostId = '@local-device';

/// Access used when this scope has never stored a policy. It preserves the
/// previous MCP behaviour (read-only until operations are allowed). Unreadable
/// or unavailable stores never fall back to this; they deny everything.
const mcpDefaultAccessWhenUnconfigured = McpAccessMode.readOnly;

const mcpAccessPolicyMaxOverrides = 4096;
const mcpAccessPolicyMaxHostIdLength = 200;
const mcpAccessPolicyMaxStoredBytes = 512 * 1024;
const mcpAccessPolicyMaxScopeLength = 1024;

class McpAccessPolicyFormatException implements Exception {
  const McpAccessPolicyFormatException();
  @override
  String toString() => 'McpAccessPolicyFormatException';
}

bool mcpAccessPolicyValidHostId(String id) =>
    id.isNotEmpty &&
    id.length <= mcpAccessPolicyMaxHostIdLength &&
    !id.contains(RegExp(r'[\x00-\x1f\x7f]'));

/// Immutable per-scope policy: a default plus explicit per-host overrides.
class McpAccessPolicy {
  McpAccessPolicy({
    this.defaultAccess = mcpDefaultAccessWhenUnconfigured,
    Map<String, McpAccessMode> overrides = const {},
  }) : overrides = Map.unmodifiable(overrides) {
    if (overrides.length > mcpAccessPolicyMaxOverrides ||
        overrides.keys.any((id) => !mcpAccessPolicyValidHostId(id))) {
      throw const McpAccessPolicyFormatException();
    }
  }

  /// Everything denied. Used while loading, after errors, and when locked.
  static final closed = McpAccessPolicy(defaultAccess: McpAccessMode.denied);

  final McpAccessMode defaultAccess;
  final Map<String, McpAccessMode> overrides;

  /// [hostId] null means the session cannot be attributed to a policy
  /// identity; such sessions are always denied.
  McpAccessMode effective(String? hostId) => hostId == null
      ? McpAccessMode.denied
      : overrides[hostId] ?? defaultAccess;

  McpAccessPolicy withDefault(McpAccessMode mode) =>
      McpAccessPolicy(defaultAccess: mode, overrides: overrides);

  /// A null [mode] removes the override so the host inherits the default.
  McpAccessPolicy withHost(String hostId, McpAccessMode? mode) {
    if (!mcpAccessPolicyValidHostId(hostId)) {
      throw ArgumentError.value(hostId, 'hostId', 'Invalid host ID.');
    }
    final next = Map.of(overrides);
    if (mode == null) {
      next.remove(hostId);
    } else {
      next[hostId] = mode;
    }
    return McpAccessPolicy(defaultAccess: defaultAccess, overrides: next);
  }

  /// The most restrictive combination: every host gets the lower of its two
  /// effective modes. Applied while a change is being persisted, so a
  /// revocation takes effect before (and regardless of) the disk write.
  static McpAccessPolicy meet(McpAccessPolicy a, McpAccessPolicy b) {
    final next = <String, McpAccessMode>{};
    final ids = {...a.overrides.keys, ...b.overrides.keys};
    final defaultAccess = McpAccessMode.min(a.defaultAccess, b.defaultAccess);
    for (final id in ids) {
      final mode = McpAccessMode.min(a.effective(id), b.effective(id));
      if (mode != defaultAccess) next[id] = mode;
    }
    return McpAccessPolicy(defaultAccess: defaultAccess, overrides: next);
  }

  /// True when some host has less access in [next] than in this policy.
  bool reducedBy(McpAccessPolicy next) {
    if (next.defaultAccess.index < defaultAccess.index) return true;
    for (final id in {...overrides.keys, ...next.overrides.keys}) {
      if (next.effective(id).index < effective(id).index) return true;
    }
    return false;
  }

  /// Bound to [scope] so a file copied between scopes is rejected.
  String encode(String scope) => jsonEncode({
    'version': 1,
    'scope': scope,
    'default': defaultAccess.storageName,
    'hosts': {
      for (final entry
          in (overrides.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key))))
        entry.key: entry.value.storageName,
    },
  });

  /// Throws [McpAccessPolicyFormatException] for anything unexpected,
  /// including a policy written for a different scope.
  static McpAccessPolicy decode(String raw, String scope) {
    if (raw.length > mcpAccessPolicyMaxStoredBytes) {
      throw const McpAccessPolicyFormatException();
    }
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      throw const McpAccessPolicyFormatException();
    }
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['version'] != 1 ||
        value['scope'] != scope) {
      throw const McpAccessPolicyFormatException();
    }
    final defaultAccess = McpAccessMode.fromStorageName(value['default']);
    final hosts = value['hosts'];
    if (defaultAccess == null || hosts is! Map<String, dynamic>) {
      throw const McpAccessPolicyFormatException();
    }
    final overrides = <String, McpAccessMode>{};
    for (final entry in hosts.entries) {
      final mode = McpAccessMode.fromStorageName(entry.value);
      if (mode == null) throw const McpAccessPolicyFormatException();
      overrides[entry.key] = mode;
    }
    return McpAccessPolicy(defaultAccess: defaultAccess, overrides: overrides);
  }

  @override
  bool operator ==(Object other) =>
      other is McpAccessPolicy &&
      other.defaultAccess == defaultAccess &&
      other.overrides.length == overrides.length &&
      overrides.entries.every((e) => other.overrides[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    defaultAccess,
    Object.hashAllUnordered(
      overrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
