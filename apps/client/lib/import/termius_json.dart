/// Termius Desktop JSON export importer.
///
/// Supports unencrypted JSON exports produced by Termius Desktop / CLI tools
/// (containing `groups`, `hosts`, `ssh_configs`, `identities`, or a direct list
/// of host objects) while enforcing the exact same size, row, and inline-key
/// safety bounds as [TermiusCsvImporter] and [TermiusOpenSshBundleImporter].
/// File paths referenced by keys are never opened from disk.
library;

import 'dart:convert';

import '../domain/models.dart';
import 'termius_csv.dart' show maxTermiusCsvBytes;
import 'termius_transfer.dart';

/// Maximum size accepted for a Termius JSON export file (4 MiB).
const maxTermiusJsonBytes = maxTermiusCsvBytes;

/// Heuristic check for UTF-8 JSON bytes starting with `{` or `[` after optional
/// UTF-8 BOM and ASCII whitespace.
bool looksLikeTermiusJsonBytes(List<int> bytes) {
  var index = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    index = 3;
  }
  while (index < bytes.length) {
    final byte = bytes[index];
    if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
      index++;
      continue;
    }
    return byte == 0x7B || byte == 0x5B; // '{' or '['
  }
  return false;
}

class TermiusJsonImporter {
  const TermiusJsonImporter._();

  static TermiusImportDocument parseBytes(List<int> bytes) {
    if (bytes.length > maxTermiusJsonBytes) {
      return _failure(TermiusIssueCode.fileTooLarge);
    }
    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return _failure(TermiusIssueCode.fileNotUtf8);
    }
    return parse(source);
  }

  static TermiusImportDocument _failure(
    TermiusIssueCode code, {
    String? detail,
    int? count,
  }) => TermiusImportDocument(
    format: TermiusSourceFormat.csv,
    headers: const [],
    rows: const [],
    fileIssues: [
      TermiusIssue(
        code,
        severity: TermiusIssueSeverity.blocking,
        line: 1,
        detail: detail,
        count: count,
      ),
    ],
  );

  static TermiusImportDocument parse(String source) {
    final clean = source.startsWith('\uFEFF') ? source.substring(1) : source;
    if (utf8.encode(clean).length > maxTermiusJsonBytes) {
      return _failure(TermiusIssueCode.fileTooLarge);
    }
    if (clean.trim().isEmpty) {
      return _failure(TermiusIssueCode.emptyFile);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(clean);
    } on FormatException {
      return _failure(TermiusIssueCode.csvStructure, detail: 'json');
    }

    List<Object?> rawHosts = const [];
    List<Object?> rawGroups = const [];
    List<Object?> rawSshConfigs = const [];
    List<Object?> rawIdentities = const [];
    List<Object?> rawKeys = const [];

    if (decoded is List) {
      rawHosts = decoded;
    } else if (decoded is Map) {
      final root = _unwrapDataContainer(decoded);
      final hostsCandidate =
          root['hosts'] ?? root['servers'] ?? root['connections'] ?? root['items'];
      if (hostsCandidate is List) {
        rawHosts = hostsCandidate;
      } else {
        return _failure(TermiusIssueCode.noTemplateHeader, detail: 'json');
      }
      if (root['groups'] is List) rawGroups = root['groups'] as List;
      if (root['ssh_configs'] is List) {
        rawSshConfigs = root['ssh_configs'] as List;
      } else if (root['sshConfigs'] is List) {
        rawSshConfigs = root['sshConfigs'] as List;
      }
      if (root['identities'] is List) rawIdentities = root['identities'] as List;
      if (root['keys'] is List) {
        rawKeys = root['keys'] as List;
      } else if (root['ssh_keys'] is List) {
        rawKeys = root['ssh_keys'] as List;
      }
    } else {
      return _failure(TermiusIssueCode.csvStructure, detail: 'json');
    }

    if (rawHosts.isEmpty) {
      return _failure(TermiusIssueCode.emptyFile);
    }
    if (rawHosts.length > maxTermiusImportRows) {
      return _failure(
        TermiusIssueCode.tooManyRows,
        count: maxTermiusImportRows,
      );
    }

    final groupsById = <String, ({String name, String? parentId})>{};
    for (final item in rawGroups) {
      if (item is! Map) continue;
      final id = _idOf(item['id'] ?? item['pk'] ?? item['uuid']);
      final name = _str(item['label'] ?? item['name'] ?? item['title'])?.trim();
      if (id == null || name == null || name.isEmpty) continue;
      final parent = _refId(
        item['parent_group'] ?? item['parent_id'] ?? item['parentId'] ?? item['parent'],
      );
      groupsById[id] = (name: name, parentId: parent);
    }

    final keysById = <String, String>{};
    for (final item in rawKeys) {
      if (item is! Map) continue;
      final id = _idOf(item['id'] ?? item['pk'] ?? item['uuid']);
      final privateKey = _str(
        item['private_key'] ?? item['privateKey'] ?? item['key'] ?? item['secret'],
      );
      if (id != null && privateKey != null && privateKey.trim().isNotEmpty) {
        keysById[id] = privateKey;
      }
    }

    final identitiesById = <String, _JsonAuth>{};
    for (final item in rawIdentities) {
      if (item is! Map) continue;
      final id = _idOf(item['id'] ?? item['pk'] ?? item['uuid']);
      if (id == null) continue;
      final keyRef = _refId(item['ssh_key'] ?? item['key'] ?? item['key_id']);
      final inlineKey = _str(item['private_key'] ?? item['privateKey']) ??
          (keyRef != null ? keysById[keyRef] : null);
      identitiesById[id] = _JsonAuth(
        username: _str(item['username'] ?? item['user']),
        password: _str(item['password'] ?? item['secret']),
        privateKey: inlineKey,
      );
    }

    final sshConfigsById = <String, _JsonSshConfig>{};
    for (final item in rawSshConfigs) {
      if (item is! Map) continue;
      final id = _idOf(item['id'] ?? item['pk'] ?? item['uuid']);
      if (id == null) continue;
      final identityRef = _refId(item['identity'] ?? item['identity_id']);
      final identity = identityRef != null ? identitiesById[identityRef] : null;
      final keyRef = _refId(item['ssh_key'] ?? item['key'] ?? item['key_id']);
      sshConfigsById[id] = _JsonSshConfig(
        port: _portOf(item['port']),
        username: _str(item['username'] ?? item['user']) ?? identity?.username,
        password: _str(item['password']) ?? identity?.password,
        privateKey: _str(item['private_key'] ?? item['privateKey']) ??
            (keyRef != null ? keysById[keyRef] : null) ??
            identity?.privateKey,
        useMosh: item['use_mosh'] == true || item['mosh'] == true,
      );
    }

    final rows = <TermiusImportRow>[];
    for (var i = 0; i < rawHosts.length; i++) {
      final item = rawHosts[i];
      rows.add(
        _parseHostObject(
          item,
          row: i + 1,
          groupsById: groupsById,
          sshConfigsById: sshConfigsById,
          identitiesById: identitiesById,
          keysById: keysById,
        ),
      );
    }

    return TermiusImportDocument(
      format: TermiusSourceFormat.csv,
      headers: const [],
      rows: List.unmodifiable(rows),
      fileIssues: const [],
    );
  }

  static Map<Object?, Object?> _unwrapDataContainer(Map<Object?, Object?> map) {
    if (map['hosts'] is List || map['servers'] is List) return map;
    final data = map['data'] ?? map['vault'] ?? map['export'];
    if (data is Map) return data;
    return map;
  }

  static TermiusImportRow _parseHostObject(
    Object? raw, {
    required int row,
    required Map<String, ({String name, String? parentId})> groupsById,
    required Map<String, _JsonSshConfig> sshConfigsById,
    required Map<String, _JsonAuth> identitiesById,
    required Map<String, String> keysById,
  }) {
    final issues = <TermiusIssue>[];
    void addIssue(
      TermiusIssueCode code, {
      bool blocking = false,
      String? detail,
      int? count,
    }) => issues.add(
      TermiusIssue(
        code,
        severity: blocking
            ? TermiusIssueSeverity.blocking
            : TermiusIssueSeverity.warning,
        line: row,
        row: row,
        detail: detail,
        count: count,
      ),
    );

    if (raw is! Map) {
      addIssue(TermiusIssueCode.missingAddress, blocking: true);
      return TermiusImportRow(
        row: row,
        line: row,
        label: '',
        address: '',
        protocol: HostProtocol.ssh,
        port: 22,
        username: '',
        groupPath: const [],
        tags: const [],
        issues: issues,
      );
    }

    final sshConfig = switch (raw['ssh_config'] ?? raw['sshConfig']) {
      final Map inline => _inlineSshConfig(
        inline,
        identitiesById: identitiesById,
        keysById: keysById,
      ),
      final Object? ref => sshConfigsById[_refId(ref) ?? ''],
    };
    final identity = switch (raw['identity'] ?? raw['identity_id']) {
      final Map inline => _JsonAuth(
        username: _str(inline['username'] ?? inline['user']),
        password: _str(inline['password'] ?? inline['secret']),
        privateKey: _str(inline['private_key'] ?? inline['privateKey']),
      ),
      final Object? ref => identitiesById[_refId(ref) ?? ''],
    };

    // Address & endpoint normalization (`user@host:port` or `host:port`).
    var rawAddress = (_str(
              raw['address'] ??
                  raw['hostname'] ??
                  raw['host'] ??
                  raw['ip'] ??
                  raw['target'],
            ) ??
            '')
        .trim();
    String? extractedUser;
    int? extractedPort;
    String? extractedScheme;
    final schemeMatch = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$')
        .firstMatch(rawAddress);
    if (schemeMatch != null) {
      extractedScheme = schemeMatch.group(1)!.toLowerCase();
      rawAddress = schemeMatch.group(2)!.trim();
    }
    final atIndex = rawAddress.lastIndexOf('@');
    if (atIndex > 0 && !rawAddress.contains(' ')) {
      extractedUser = rawAddress.substring(0, atIndex);
      rawAddress = rawAddress.substring(atIndex + 1);
    }
    if (rawAddress.startsWith('[')) {
      final endBracket = rawAddress.indexOf(']');
      if (endBracket > 1) {
        final ipv6 = rawAddress.substring(1, endBracket);
        final rest = rawAddress.substring(endBracket + 1);
        if (rest.startsWith(':')) {
          extractedPort = int.tryParse(rest.substring(1));
        }
        rawAddress = ipv6;
      }
    } else {
      final firstColon = rawAddress.indexOf(':');
      final lastColon = rawAddress.lastIndexOf(':');
      if (firstColon > 0 && firstColon == lastColon) {
        final portCandidate = int.tryParse(rawAddress.substring(firstColon + 1));
        if (portCandidate != null) {
          extractedPort = portCandidate;
          rawAddress = rawAddress.substring(0, firstColon);
        }
      }
    }

    if (rawAddress.isEmpty) {
      addIssue(TermiusIssueCode.missingAddress, blocking: true);
    } else if (!_isValidAddress(rawAddress)) {
      addIssue(TermiusIssueCode.invalidAddress, blocking: true);
    }

    // Label.
    var label = (_str(
              raw['label'] ?? raw['name'] ?? raw['title'] ?? raw['alias'],
            ) ??
            '')
        .trim();
    if (label.isEmpty) label = rawAddress;
    if (RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]')
            .hasMatch(label) ||
        utf8.encode(label).length > 512) {
      addIssue(TermiusIssueCode.invalidLabel, blocking: true);
    }

    // Protocol.
    var protocolText = (_str(raw['protocol'] ?? raw['type']) ??
            extractedScheme ??
            (sshConfig?.useMosh == true ? 'mosh' : ''))
        .trim()
        .toLowerCase();
    HostProtocol? protocol;
    switch (protocolText) {
      case '':
      case 'ssh':
        protocol = HostProtocol.ssh;
      case 'mosh':
        protocol = HostProtocol.ssh;
        addIssue(TermiusIssueCode.moshImportedAsSsh);
      case 'rdp':
        protocol = HostProtocol.rdp;
        addIssue(TermiusIssueCode.extensionProtocol, detail: 'rdp');
      case 'vnc':
        protocol = HostProtocol.vnc;
        addIssue(TermiusIssueCode.extensionProtocol, detail: 'vnc');
      default:
        addIssue(
          TermiusIssueCode.unsupportedProtocol,
          blocking: true,
          detail: protocolText.length > 40
              ? '${protocolText.substring(0, 40)}…'
              : protocolText,
        );
    }

    // Port.
    final rawPort = raw['port'] ?? sshConfig?.port ?? extractedPort;
    int? port;
    if (rawPort == null || (rawPort is String && rawPort.trim().isEmpty)) {
      port = protocol?.defaultPort;
    } else {
      final parsedPort = _portOf(rawPort);
      if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
        addIssue(TermiusIssueCode.invalidPort, blocking: true);
      } else {
        port = parsedPort;
      }
    }

    // Username.
    final username = (_str(raw['username'] ?? raw['user']) ??
            sshConfig?.username ??
            identity?.username ??
            extractedUser ??
            '')
        .trim();
    if (username.isNotEmpty &&
        (_hasControl(username) ||
            username.contains(RegExp(r'\s')) ||
            utf8.encode(username).length > 256)) {
      addIssue(TermiusIssueCode.invalidUsername, blocking: true);
    } else if (username.isEmpty && protocol == HostProtocol.ssh) {
      addIssue(TermiusIssueCode.missingUsername, blocking: true);
    }

    // Password & inline private key.
    var password =
        _str(raw['password']) ?? sshConfig?.password ?? identity?.password;
    if (password != null && password.isEmpty) password = null;
    if (password != null &&
        (password.contains('\u0000') || utf8.encode(password).length > 65536)) {
      addIssue(TermiusIssueCode.invalidPassword, blocking: true);
      password = null;
    }

    final keyRef = _refId(raw['ssh_key'] ?? raw['key'] ?? raw['key_id']);
    final keyText = _str(raw['private_key'] ?? raw['privateKey']) ??
        sshConfig?.privateKey ??
        identity?.privateKey ??
        (keyRef != null ? keysById[keyRef] : null);
    String? privateKey;
    if (keyText != null && keyText.trim().isNotEmpty) {
      if (isInlinePrivateKeyText(keyText)) {
        final normalized = normalizePrivateKeyText(keyText);
        if (utf8.encode(normalized).length > maxTermiusPrivateKeyBytes ||
            normalized.contains('\u0000')) {
          addIssue(TermiusIssueCode.invalidPrivateKey, blocking: true);
        } else {
          privateKey = normalized;
        }
      } else {
        addIssue(TermiusIssueCode.sshKeyNotInline);
      }
    }
    if (privateKey != null && password != null) {
      addIssue(TermiusIssueCode.passwordDroppedForKey);
      password = null;
    }
    if (privateKey != null && protocol != null && protocol != HostProtocol.ssh) {
      addIssue(TermiusIssueCode.credentialsIgnoredForProtocol);
      privateKey = null;
    }

    // Groups.
    final groupPath = _resolveGroupPath(
      raw['group_path'] ??
          raw['groups'] ??
          raw['group'] ??
          raw['group_id'] ??
          raw['groupId'] ??
          raw['folder'],
      groupsById: groupsById,
      addIssue: addIssue,
    );

    // Tags.
    final rawTags = _extractTags(raw['tags']);
    final tags = parseHostTags(rawTags.join(','));
    if (tags.length != rawTags.length) {
      addIssue(
        TermiusIssueCode.duplicateTagDropped,
        count: rawTags.length - tags.length,
      );
    }
    if (tags.length > 64 ||
        tags.any((tag) => tag.length > 64 || _hasControl(tag))) {
      addIssue(TermiusIssueCode.invalidTag, blocking: true);
    }

    return TermiusImportRow(
      row: row,
      line: row,
      label: label,
      address: rawAddress,
      protocol: protocol,
      port: port,
      username: username,
      groupPath: List.unmodifiable(groupPath),
      tags: tags,
      password: password,
      privateKey: privateKey,
      issues: issues,
    );
  }

  static _JsonSshConfig _inlineSshConfig(
    Map<Object?, Object?> item, {
    required Map<String, _JsonAuth> identitiesById,
    required Map<String, String> keysById,
  }) {
    final identityRef = _refId(item['identity'] ?? item['identity_id']);
    final identity = identityRef != null ? identitiesById[identityRef] : null;
    final keyRef = _refId(item['ssh_key'] ?? item['key'] ?? item['key_id']);
    return _JsonSshConfig(
      port: _portOf(item['port']),
      username: _str(item['username'] ?? item['user']) ?? identity?.username,
      password: _str(item['password']) ?? identity?.password,
      privateKey: _str(item['private_key'] ?? item['privateKey']) ??
          (keyRef != null ? keysById[keyRef] : null) ??
          identity?.privateKey,
      useMosh: item['use_mosh'] == true || item['mosh'] == true,
    );
  }

  static List<String> _resolveGroupPath(
    Object? rawGroup, {
    required Map<String, ({String name, String? parentId})> groupsById,
    required void Function(
      TermiusIssueCode code, {
      bool blocking,
      String? detail,
      int? count,
    }) addIssue,
  }) {
    if (rawGroup == null) return const [];
    final rawSegments = <String>[];
    if (rawGroup is List) {
      for (final item in rawGroup) {
        if (item is String) {
          rawSegments.add(item);
        } else if (item is Map) {
          final name = _str(item['label'] ?? item['name']);
          if (name != null) rawSegments.add(name);
        }
      }
    } else if (rawGroup is Map) {
      final id = _idOf(rawGroup['id'] ?? rawGroup['pk'] ?? rawGroup['uuid']);
      if (id != null && groupsById.containsKey(id)) {
        rawSegments.addAll(_walkGroupTree(id, groupsById));
      } else {
        final name = _str(rawGroup['label'] ?? rawGroup['name']);
        if (name != null) rawSegments.addAll(name.split('/'));
      }
    } else {
      final id = _idOf(rawGroup);
      if (id != null && groupsById.containsKey(id)) {
        rawSegments.addAll(_walkGroupTree(id, groupsById));
      } else if (rawGroup is String && rawGroup.trim().isNotEmpty) {
        rawSegments.addAll(rawGroup.split('/'));
      }
    }

    final path = <String>[];
    for (final item in rawSegments) {
      final segment = item.trim();
      if (segment.isEmpty) continue;
      if (_hasControl(segment) || utf8.encode(segment).length > 256) {
        addIssue(TermiusIssueCode.invalidGroup, blocking: true);
        return const [];
      }
      path.add(segment);
    }
    if (path.length > 16) {
      addIssue(TermiusIssueCode.groupTooDeep, blocking: true, count: 16);
    }
    return path;
  }

  static List<String> _walkGroupTree(
    String leafId,
    Map<String, ({String name, String? parentId})> groupsById,
  ) {
    final segments = <String>[];
    final visited = <String>{};
    String? current = leafId;
    while (current != null && visited.add(current) && segments.length <= 17) {
      final node = groupsById[current];
      if (node == null) break;
      segments.insert(0, node.name);
      current = node.parentId;
    }
    return segments;
  }

  static List<String> _extractTags(Object? rawTags) {
    if (rawTags is String) {
      return rawTags
          .split(',')
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList();
    }
    if (rawTags is List) {
      final out = <String>[];
      for (final item in rawTags) {
        final text = switch (item) {
          final String s => s,
          final Map m => _str(m['label'] ?? m['name'] ?? m['tag']),
          _ => null,
        };
        if (text != null && text.trim().isNotEmpty) out.add(text.trim());
      }
      return out;
    }
    return const [];
  }

  static String? _idOf(Object? value) => switch (value) {
    final String s when s.trim().isNotEmpty => s.trim(),
    final int n => '$n',
    _ => null,
  };

  static String? _refId(Object? value) => switch (value) {
    final Map m => _idOf(m['id'] ?? m['pk'] ?? m['uuid']),
    _ => _idOf(value),
  };

  static String? _str(Object? value) => value is String ? value : null;

  static int? _portOf(Object? value) => switch (value) {
    final int n => n,
    final num n when n == n.toInt() => n.toInt(),
    final String s when RegExp(r'^[0-9]{1,5}$').hasMatch(s.trim()) =>
      int.parse(s.trim()),
    _ => null,
  };

  static bool _hasControl(String value) =>
      RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value);

  static bool _isValidAddress(String value) =>
      value.length <= 253 &&
      !value.contains(RegExp(r'[\s\u0000-\u001F\u007F,/\\"\x27`$;|&<>()]')) &&
      !value.startsWith('-');
}

class _JsonAuth {
  const _JsonAuth({this.username, this.password, this.privateKey});
  final String? username;
  final String? password;
  final String? privateKey;
}

class _JsonSshConfig {
  const _JsonSshConfig({
    this.port,
    this.username,
    this.password,
    this.privateKey,
    this.useMosh = false,
  });
  final int? port;
  final String? username;
  final String? password;
  final String? privateKey;
  final bool useMosh;
}
