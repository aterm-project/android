/// Normalizes decrypted Termius IndexedDB tables (`hosts`, `ssh_configs`,
/// `ssh_identities`, `keys`, `groups`, `tags`, `tag_hosts`, `pf_rules`) into a
/// [TermiusImportDocument] ready for [TermiusImportPlanner].
library;

import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'termius_indexeddb_reader.dart';
import 'termius_local_vault_cipher.dart';
import 'termius_transfer.dart';

const _uuid = Uuid();

/// Expands a packed 32-bit unsigned integer IPv4 string (e.g. `"3221226008"` ->
/// `"192.0.2.24"`), returning all other strings untouched.
String expandPackedTermiusIpv4(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(trimmed)) {
    return trimmed;
  }
  final packed = int.tryParse(trimmed);
  if (packed == null || packed < 0 || packed > 0xffffffff) {
    return trimmed;
  }
  final a = (packed >> 24) & 0xff;
  final b = (packed >> 16) & 0xff;
  final c = (packed >> 8) & 0xff;
  final d = packed & 0xff;
  return '$a.$b.$c.$d';
}

Map<String, Map<String, Object?>> _indexRows(List<Map<String, Object?>> rows) {
  final idx = <String, Map<String, Object?>>{};
  for (final row in rows) {
    final id = row['id'];
    if (id != null && id.toString().isNotEmpty) {
      idx['id:$id'] = row;
    }
    final localId = row['local_id'];
    if (localId != null && localId.toString().isNotEmpty) {
      idx['lid:$localId'] = row;
    }
  }
  return idx;
}

Map<String, Object?>? _deref(
  Object? ref,
  Map<String, Map<String, Object?>> index,
) {
  if (ref == null) return null;
  if (ref is Map) {
    final id = ref['id'];
    if (id != null && id.toString().isNotEmpty) {
      final found = index['id:$id'];
      if (found != null) return found;
    }
    final localId = ref['local_id'];
    if (localId != null && localId.toString().isNotEmpty) {
      final found = index['lid:$localId'];
      if (found != null) return found;
    }
    return null;
  }
  final key = ref.toString().trim();
  if (key.isEmpty) return null;
  return index['id:$key'] ?? index['lid:$key'];
}

String _entityKey(Map<String, Object?>? row) {
  if (row == null) return '';
  return '${row['id'] ?? ''}/${row['local_id'] ?? ''}';
}

String _text(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  return value.toString().trim();
}

String? _rawSecretString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}

List<String> _resolveGroupPath(
  Object? groupRef,
  Map<String, Map<String, Object?>> groupIndex,
) {
  final segments = <String>[];
  final visited = <String>{};
  var current = _deref(groupRef, groupIndex);
  while (current != null && segments.length < 16) {
    final entity = _entityKey(current);
    if (entity.isNotEmpty && !visited.add(entity)) break;
    final label = _text(current['label'] ?? current['name'] ?? current['title']);
    if (label.isNotEmpty) {
      segments.insert(0, label);
    }
    final parentRef =
        current['parent_group'] ??
        current['parent'] ??
        current['parent_id'] ??
        current['group'];
    current = _deref(parentRef, groupIndex);
  }
  return segments;
}

(HostProtocol?, List<TermiusIssue>) _parseProtocol(
  String rawProtocol,
  int rowIndex,
) {
  final normalized = rawProtocol.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'ssh') {
    return (HostProtocol.ssh, const []);
  }
  if (normalized == 'mosh') {
    return (
      HostProtocol.ssh,
      [
        TermiusIssue(
          TermiusIssueCode.moshImportedAsSsh,
          row: rowIndex,
          line: rowIndex,
        ),
      ],
    );
  }
  if (normalized == 'telnet') {
    // Atermius supports Telnet hosts natively.
    return (HostProtocol.telnet, const []);
  }
  if (normalized == 'rdp') {
    return (
      HostProtocol.rdp,
      [
        TermiusIssue(
          TermiusIssueCode.extensionProtocol,
          row: rowIndex,
          line: rowIndex,
          detail: 'rdp',
        ),
      ],
    );
  }
  if (normalized == 'vnc') {
    return (
      HostProtocol.vnc,
      [
        TermiusIssue(
          TermiusIssueCode.extensionProtocol,
          row: rowIndex,
          line: rowIndex,
          detail: 'vnc',
        ),
      ],
    );
  }
  return (
    null,
    [
      TermiusIssue(
        TermiusIssueCode.unsupportedProtocol,
        severity: TermiusIssueSeverity.blocking,
        row: rowIndex,
        line: rowIndex,
        detail: normalized,
      ),
    ],
  );
}

SshPortForwardType _parseForwardType(String raw) {
  final low = raw.trim().toLowerCase();
  if (low.startsWith('remote')) return SshPortForwardType.remote;
  if (low.startsWith('dynamic')) return SshPortForwardType.dynamic;
  return SshPortForwardType.local;
}

bool _isLoopbackAddress(String address) {
  final low = address.trim().toLowerCase();
  return low.isEmpty ||
      low == '127.0.0.1' ||
      low == 'localhost' ||
      low == '::1' ||
      low == '[::1]';
}

/// Tables [buildTermiusDocumentFromDecryptedTables] reads. Others (for
/// example `known_hosts`, `proxies`) are never decrypted, so no secret that
/// is not imported is ever materialized in memory.
const Set<String> termiusLocalImportedTables = {
  'hosts',
  'keys',
  'ssh_identities',
  'ssh_configs',
  'groups',
  'tags',
  'tag_hosts',
  'pf_rules',
};

/// Decrypts [rawTables] with [decryptor] and builds a [TermiusImportDocument].
TermiusImportDocument buildTermiusDocumentFromLocalTables(
  TermiusRawTables rawTables,
  TermiusVaultDecryptor decryptor,
) {
  final decrypted = <String, List<Map<String, Object?>>>{};
  for (final entry in rawTables.tables.entries) {
    if (!termiusLocalImportedTables.contains(entry.key)) continue;
    decrypted[entry.key] = [
      for (final row in entry.value)
        (decryptor.walk(row) as Map).cast<String, Object?>(),
    ];
  }
  return buildTermiusDocumentFromDecryptedTables(decrypted);
}

/// Builds a [TermiusImportDocument] from already-decrypted Termius tables.
TermiusImportDocument buildTermiusDocumentFromDecryptedTables(
  Map<String, List<Map<String, Object?>>> decrypted,
) {
  final hostRows = decrypted['hosts'] ?? const [];
  if (hostRows.isEmpty) {
    return const TermiusImportDocument(
      format: TermiusSourceFormat.csv,
      headers: TermiusCsvColumn.template,
      rows: [],
      fileIssues: [
        TermiusIssue(
          TermiusIssueCode.emptyFile,
          severity: TermiusIssueSeverity.blocking,
        ),
      ],
    );
  }

  final keyIndex = _indexRows(decrypted['keys'] ?? const []);
  final identityIndex = _indexRows(decrypted['ssh_identities'] ?? const []);
  final sshConfigIndex = _indexRows(decrypted['ssh_configs'] ?? const []);
  final groupIndex = _indexRows(decrypted['groups'] ?? const []);
  final tagIndex = _indexRows(decrypted['tags'] ?? const []);
  final hostIndex = _indexRows(hostRows);

  // Join `tags` <- `tag_hosts` -> `hosts`.
  final tagsByHostEntity = <String, Set<String>>{};
  for (final link in decrypted['tag_hosts'] ?? const <Map<String, Object?>>[]) {
    final tagRow = _deref(link['tag'], tagIndex);
    final hostRow = _deref(link['host'], hostIndex);
    final label = _text(tagRow?['label'] ?? tagRow?['name']);
    final hostKey = _entityKey(hostRow);
    if (label.isEmpty || hostKey.isEmpty) continue;
    tagsByHostEntity.putIfAbsent(hostKey, () => <String>{}).add(label);
  }

  // Group port-forwarding rules (`pf_rules`) by owning host entity.
  final forwardsByHostEntity = <String, List<SshPortForwardProfile>>{};
  for (final pf in decrypted['pf_rules'] ?? const <Map<String, Object?>>[]) {
    final owner = _deref(pf['host'], hostIndex);
    final ownerKey = _entityKey(owner);
    if (ownerKey.isEmpty) continue;
    final type = _parseForwardType(_text(pf['pf_type']));
    final bindPort = int.tryParse(_text(pf['local_port'])) ?? 0;
    final destPort = int.tryParse(_text(pf['remote_port'])) ?? 0;
    if (bindPort <= 0 || bindPort > 65535) continue;
    if (type != SshPortForwardType.dynamic &&
        (destPort <= 0 || destPort > 65535)) {
      continue;
    }
    final boundRaw = _text(pf['bound_address']);
    final bindAddress = boundRaw.isEmpty ? '127.0.0.1' : boundRaw;
    final targetHost = expandPackedTermiusIpv4(_text(pf['hostname']));
    if (type != SshPortForwardType.dynamic && targetHost.isEmpty) continue;
    final label = _text(pf['label']);
    final expose = !_isLoopbackAddress(bindAddress);
    final list = forwardsByHostEntity.putIfAbsent(ownerKey, () => []);
    if (list.length >= maxHostPortForwardProfiles) continue;
    list.add(
      SshPortForwardProfile(
        id: _uuid.v4(),
        name: label.isEmpty ? '${type.name}-$bindPort' : label,
        type: type,
        bindAddress: bindAddress,
        bindPort: bindPort,
        destinationAddress:
            type == SshPortForwardType.dynamic ? null : targetHost,
        destinationPort: type == SshPortForwardType.dynamic ? null : destPort,
        exposeToNetwork: expose,
      ),
    );
  }

  // Pre-compute primary display labels for jump-host resolution.
  final labelByHostEntity = <String, String>{};
  for (final row in hostRows) {
    final address = expandPackedTermiusIpv4(
      _text(row['address'] ?? row['hostname']),
    );
    final label = _text(row['label'] ?? row['title'] ?? row['name']);
    final effectiveLabel = label.isEmpty ? address : label;
    final key = _entityKey(row);
    if (key.isNotEmpty && effectiveLabel.isNotEmpty) {
      labelByHostEntity[key] = effectiveLabel;
    }
  }

  final importRows = <TermiusImportRow>[];
  var rowNum = 0;

  for (final row in hostRows) {
    if (importRows.length >= maxTermiusImportRows) {
      return TermiusImportDocument(
        format: TermiusSourceFormat.csv,
        headers: TermiusCsvColumn.template,
        rows: importRows,
        fileIssues: const [
          TermiusIssue(
            TermiusIssueCode.tooManyRows,
            severity: TermiusIssueSeverity.blocking,
            count: maxTermiusImportRows,
          ),
        ],
      );
    }
    rowNum++;
    final issues = <TermiusIssue>[];

    final cfg = _deref(row['ssh_config'], sshConfigIndex) ?? const {};
    final identity =
        _deref(cfg['identity'] ?? row['identity'], identityIndex) ?? const {};
    final keyRow = _deref(identity['ssh_key'] ?? cfg['ssh_key'], keyIndex);

    final rawAddress = _text(row['address'] ?? row['hostname']);
    final address = expandPackedTermiusIpv4(rawAddress);
    final rawLabel = _text(row['label'] ?? row['title'] ?? row['name']);
    final label = rawLabel.isEmpty ? address : rawLabel;

    final rawProto = _text(
      row['protocol'] ?? row['connection_type'] ?? cfg['protocol'],
    );
    final (protocol, protoIssues) = _parseProtocol(rawProto, rowNum);
    issues.addAll(protoIssues);

    final rawPortText = _text(cfg['port'] ?? row['port']);
    int? port;
    // Termius leaves an unset port empty or 0; both mean the protocol default.
    if (rawPortText.isEmpty || rawPortText == '0') {
      port = protocol?.defaultPort ?? 22;
    } else {
      final parsed = int.tryParse(rawPortText);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        issues.add(
          TermiusIssue(
            TermiusIssueCode.invalidPort,
            severity: TermiusIssueSeverity.blocking,
            row: rowNum,
            line: rowNum,
          ),
        );
      } else {
        port = parsed;
      }
    }

    if (address.isEmpty) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.missingAddress,
          severity: TermiusIssueSeverity.blocking,
          row: rowNum,
          line: rowNum,
        ),
      );
    }

    final username = _text(identity['username'] ?? row['username']);
    if (username.isEmpty && protocol == HostProtocol.ssh) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.missingUsername,
          severity: TermiusIssueSeverity.blocking,
          row: rowNum,
          line: rowNum,
        ),
      );
    }

    var password = _rawSecretString(identity['password'] ?? row['password']);
    String? privateKey;
    String? passphrase;
    final rawPrivateKey = _text(keyRow?['private_key']);
    if (rawPrivateKey.isNotEmpty) {
      if (isInlinePrivateKeyText(rawPrivateKey)) {
        privateKey = normalizePrivateKeyText(rawPrivateKey);
        // Exact passphrase (whitespace preserved); empty means none.
        passphrase = _rawSecretString(keyRow?['passphrase']);
      } else {
        issues.add(
          TermiusIssue(
            TermiusIssueCode.invalidPrivateKey,
            severity: TermiusIssueSeverity.blocking,
            row: rowNum,
            line: rowNum,
          ),
        );
      }
    }
    if (privateKey != null && password != null) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.passwordDroppedForKey,
          row: rowNum,
          line: rowNum,
        ),
      );
      password = null;
    }

    // Resolve optional jump host reference (`jumphost` / `jump_hosts`).
    String? jumpAlias;
    final jumpRef =
        cfg['jumphost'] ??
        cfg['jump_host'] ??
        (cfg['jump_hosts'] is List && (cfg['jump_hosts'] as List).isNotEmpty
            ? (cfg['jump_hosts'] as List).last
            : null);
    if (jumpRef != null) {
      final jumpRow = _deref(jumpRef, hostIndex);
      jumpAlias = labelByHostEntity[_entityKey(jumpRow)];
    }

    final entity = _entityKey(row);
    final groupPath = _resolveGroupPath(
      row['group'] ?? row['parent_group'],
      groupIndex,
    );
    final tags = (tagsByHostEntity[entity]?.toList() ?? <String>[])..sort();
    final forwards = forwardsByHostEntity[entity] ?? const [];

    importRows.add(
      TermiusImportRow(
        row: rowNum,
        line: rowNum,
        label: label,
        address: address,
        protocol: protocol,
        port: port,
        username: username,
        groupPath: List.unmodifiable(groupPath),
        tags: List.unmodifiable(tags),
        password: password,
        privateKey: privateKey,
        passphrase: passphrase,
        jumpAlias: jumpAlias,
        forwards: List.unmodifiable(forwards),
        issues: issues,
      ),
    );
  }

  return TermiusImportDocument(
    format: TermiusSourceFormat.csv,
    headers: TermiusCsvColumn.template,
    rows: List.unmodifiable(importRows),
    fileIssues: const [],
  );
}
