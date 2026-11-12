/// Termius-compatible host transfer: CSV import template, planner, and
/// CSV/OpenSSH exporters.
///
/// Evidence for the CSV schema (see the R7 import_export report):
/// * Termius docs: the CSV template carries labels, IP addresses, protocols,
///   ports, groups, subgroups, tags and credentials.
/// * The template bundled with Termius 10.4.0 (`termius_import.csv`) has
///   exactly `Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password`.
///   Its parser accepts only those headers in that order, splits Groups on
///   `/` and Tags on `,` (trimming both), keeps Username/Password verbatim,
///   maps protocol `ssh`/`mosh`/empty to SSH and `telnet` to Telnet.
/// * `SSH_KEY` was observed as an extra column in third-party files; it is
///   accepted on import only and never written (Termius rejects the file).
///
/// Encrypted native Termius exports and cloud data are NOT read here.
///
/// This library is pure Dart. Findings are codes plus non-secret details so
/// the UI can localize them and no secret ever reaches a message.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'openssh_config_import.dart' show maxOpenSshConfigBytes;
import 'termius_csv.dart';

const _uuid = Uuid();

/// Host limit of the reused OpenSSH config importer.
const maxOpenSshExportHosts = 256;

/// Maximum data rows accepted from one import file.
const maxTermiusImportRows = 2000;
const _maxGroupDepth = 16;
const _maxLabelBytes = 512;
const _maxGroupNameBytes = 256;
const _maxTagLength = 64;
const _maxTagsPerHost = 64;
const _maxUsernameBytes = 256;
const _maxPasswordBytes = 65536;
const maxTermiusPrivateKeyBytes = 262144;

/// Header labels of the confirmed Termius CSV template, in template order.
abstract final class TermiusCsvColumn {
  static const groups = 'Groups';
  static const label = 'Label';
  static const tags = 'Tags';
  static const hostname = 'Hostname/IP';
  static const protocol = 'Protocol';
  static const port = 'Port';
  static const username = 'Username';
  static const password = 'Password';

  /// Observed as an optional non-template column (termius-cli issue #218).
  static const sshKey = 'SSH_KEY';

  static const template = [
    groups,
    label,
    tags,
    hostname,
    protocol,
    port,
    username,
    password,
  ];

  static const known = [...template, sshKey];
}

enum TermiusSourceFormat { csv, openSsh }

enum TermiusIssueSeverity { warning, blocking }

/// Every finding the transfer can report. Details are non-secret: column or
/// directive names, protocol words, row numbers.
enum TermiusIssueCode {
  // File level.
  fileTooLarge,
  fileNotUtf8,
  csvStructure,
  emptyFile,
  missingHostnameColumn,
  duplicateHeader,
  unknownHeader,
  tooManyRows,
  noTemplateHeader,
  nonTemplateColumn,
  headerOrderNotTermius,
  // Row level.
  extraFields,
  missingFields,
  controlCharacter,
  missingAddress,
  invalidAddress,
  invalidLabel,
  invalidPort,
  unsupportedProtocol,
  extensionProtocol,
  moshImportedAsSsh,
  missingUsername,
  invalidUsername,
  invalidPassword,
  invalidPrivateKey,
  sshKeyNotInline,
  passwordDroppedForKey,
  credentialsIgnoredForProtocol,
  invalidGroup,
  emptyGroupSegment,
  groupTooDeep,
  invalidTag,
  duplicateTagDropped,
  unknownColumnValue,
  duplicateInFile,
  alreadyExists,
  nameAlreadyUsed,
  excludedByUser,
  invalidRecord,
  // OpenSSH specific.
  sshParserFinding,
  sshOptionIgnored,
  sshHostKeyPolicyIgnored,
  sshForwardBlocked,
  sshJumpMissing,
  sshJumpCycle,
  certificateNotStored,
  certificateWithoutKey,
  bundleKeyMissing,
  bundleKeyInvalid,
  bundleIdentityExtra,
  bundleCertificateMissing,
  bundleEntryRejected,
  bundleTooLarge,
  bundleInvalid,
  bundleConfigMissing,
  bundleConfigAmbiguous,
  // Export specific.
  exportSkippedProtocol,
  exportGroupSlash,
  exportGroupWhitespace,
  exportFormulaRisk,
  exportKeysNotRepresented,
  exportCertificatesNotRepresented,
  exportPassphraseNotExported,
  exportPasswordsNotRepresented,
  exportKeysOmitted,
  exportTooLarge,
  exportCertificatesOmitted,
  exportTagComma,
  exportJumpNotRepresented,
  exportForwardsNotRepresented,
  exportSharedCredentialSkipped,
  exportSecretsOmitted,
  exportAliasRewritten,
  exportHostSkipped,
}

class TermiusIssue {
  const TermiusIssue(
    this.code, {
    this.severity = TermiusIssueSeverity.warning,
    this.line,
    this.row,
    this.detail,
    this.count,
    this.messageBuilder,
  });

  final TermiusIssueCode code;

  /// Lazily localized message from the reused OpenSSH parser (no values).
  final String Function()? messageBuilder;
  final TermiusIssueSeverity severity;

  /// 1-based physical line in the source file.
  final int? line;

  /// 1-based data row (CSV) or Host block ordinal (OpenSSH).
  final int? row;

  /// Non-secret context such as a header name or directive name.
  final String? detail;
  final int? count;

  bool get blocking => severity == TermiusIssueSeverity.blocking;

  @override
  String toString() =>
      'TermiusIssue(${code.name}, ${severity.name}, line: $line, row: $row, '
      'detail: $detail, count: $count)';
}

/// One importable entry parsed from a source file, before planning.
class TermiusImportRow {
  TermiusImportRow({
    required this.row,
    required this.line,
    required this.label,
    required this.address,
    required this.protocol,
    required this.port,
    required this.username,
    required this.groupPath,
    required this.tags,
    this.password,
    this.privateKey,
    this.jumpAlias,
    this.forwards = const [],
    this.certificate,
    List<TermiusIssue>? issues,
  }) : issues = issues ?? [];

  final int row;
  final int line;
  final String label;
  final String address;
  final HostProtocol? protocol;
  final int? port;
  final String username;
  final List<String> groupPath;
  final List<String> tags;

  /// Exact password (whitespace preserved). Never logged.
  final String? password;

  /// Inline private key text. Never logged.
  final String? privateKey;
  final String? jumpAlias;
  final List<SshPortForwardProfile> forwards;

  /// OpenSSH user certificate line (public data) from a selected bundle.
  final String? certificate;
  final List<TermiusIssue> issues;

  bool get blocked => issues.any((issue) => issue.blocking);
  bool get hasSecret => password != null || privateKey != null;

  @override
  String toString() =>
      'TermiusImportRow(row: $row, line: $line, label: $label, '
      'address: $address, secret: ${hasSecret ? '<redacted>' : 'none'})';
}

class TermiusImportDocument {
  const TermiusImportDocument({
    required this.format,
    required this.headers,
    required this.rows,
    required this.fileIssues,
  });

  final TermiusSourceFormat format;
  final List<String> headers;
  final List<TermiusImportRow> rows;
  final List<TermiusIssue> fileIssues;

  bool get blocksWholeFile => fileIssues.any((issue) => issue.blocking);
}

/// Snapshot of the target's records used for planning and stale detection.
class TermiusCatalog {
  TermiusCatalog({
    required List<HostRecord> hosts,
    required List<GroupRecord> groups,
    List<CredentialRecord> credentials = const [],
  }) : hosts = List.unmodifiable(hosts),
       groups = List.unmodifiable(groups),
       credentials = List.unmodifiable(credentials);

  final List<HostRecord> hosts;
  final List<GroupRecord> groups;
  final List<CredentialRecord> credentials;

  late final Map<String, GroupRecord> _groupsById = {
    for (final group in groups) group.id: group,
  };
  late final Map<String, CredentialRecord> _credentialsById = {
    for (final credential in credentials) credential.id: credential,
  };

  GroupRecord? groupById(String id) => _groupsById[id];
  CredentialRecord? credentialById(String id) => _credentialsById[id];

  /// Digest of identities and the fields the planner depends on. Secrets are
  /// not included. Two equal fingerprints mean a plan is still valid.
  late final String fingerprint = () {
    final parts = <Object?>[
      for (final host
          in [...hosts]..sort((a, b) => a.id.compareTo(b.id)))
        [
          host.id,
          host.revisionId,
          host.name,
          host.address,
          host.port,
          host.username,
          host.protocol.name,
          host.groupId,
          host.jumpHostId,
          host.credentialId,
          host.login?.kind.name,
        ],
      for (final group
          in [...groups]..sort((a, b) => a.id.compareTo(b.id)))
        [group.id, group.name, group.parentId, group.defaultCredentialId],
      // Credential identity/metadata only; secrets are never hashed.
      for (final credential
          in [...credentials]..sort((a, b) => a.id.compareTo(b.id)))
        [
          credential.id,
          credential.revisionId,
          credential.name,
          credential.username,
          credential.kind.name,
          credential.fingerprint,
        ],
    ];
    return crypto.sha256.convert(utf8.encode(jsonEncode(parts))).toString();
  }();
}

/// Narrow hook for the Keychain certificate field owned by the navigation
/// branch (`CredentialRecord.certificate`, private-key credentials only).
/// Root wires it as `certificateOf: (c) => c.certificate` and
/// `withCertificate: (c, cert) => c.copyWith(certificate: cert)`.
abstract interface class TermiusCertificateBridge {
  String? certificateOf(CredentialRecord credential);
  CredentialRecord withCertificate(
    CredentialRecord credential,
    String certificate,
  );
}

enum TermiusLoginSource { hostLogin, hostCredential, groupDefault }

/// The sign-in a Host actually uses, resolved like the connection code:
/// inline Host login, else the Host's Credential, else the nearest ancestor
/// Group default Credential. A Credential username wins when non-empty.
class TermiusEffectiveLogin {
  const TermiusEffectiveLogin({
    required this.kind,
    required this.username,
    required this.source,
    this.password,
    this.privateKey,
    this.passphrase,
    this.certificate,
    this.credentialId,
  });

  final AuthKind kind;
  final String username;
  final TermiusLoginSource source;
  final String? password;
  final String? privateKey;
  final String? passphrase;
  final String? certificate;
  final String? credentialId;

  @override
  String toString() => 'TermiusEffectiveLogin(${kind.name}, ${source.name})';
}

/// Returns null when the Host has no saved sign-in (or a reference is broken).
TermiusEffectiveLogin? resolveTermiusEffectiveLogin(
  HostRecord host,
  TermiusCatalog catalog, {
  TermiusCertificateBridge? certificates,
}) {
  final login = host.login;
  if (login != null) {
    return TermiusEffectiveLogin(
      kind: login.kind,
      username: host.username,
      source: TermiusLoginSource.hostLogin,
      password: login.kind == AuthKind.password ? login.password : null,
      privateKey: login.kind == AuthKind.privateKey ? login.privateKey : null,
      passphrase: login.kind == AuthKind.privateKey ? login.passphrase : null,
    );
  }
  CredentialRecord? credential;
  var source = TermiusLoginSource.hostCredential;
  if (host.credentialId != null) {
    credential = catalog.credentialById(host.credentialId!);
    if (credential == null) return null;
  } else {
    source = TermiusLoginSource.groupDefault;
    final visited = <String>{};
    var groupId = host.groupId;
    while (groupId != null && credential == null) {
      if (!visited.add(groupId)) return null;
      final group = catalog.groupById(groupId);
      if (group == null) return null;
      final defaultId = group.defaultCredentialId;
      if (defaultId != null) {
        credential = catalog.credentialById(defaultId);
        if (credential == null) return null;
      }
      groupId = group.parentId;
    }
    if (credential == null) return null;
  }
  final isKey = credential.kind == AuthKind.privateKey;
  return TermiusEffectiveLogin(
    kind: credential.kind,
    username: credential.username.isEmpty ? host.username : credential.username,
    source: source,
    password: isKey ? null : credential.secret,
    privateKey: isKey ? credential.privateKey : null,
    passphrase: isKey ? credential.passphrase : null,
    certificate: isKey ? certificates?.certificateOf(credential) : null,
    credentialId: credential.id,
  );
}

// ---------------------------------------------------------------------------
// CSV import

class TermiusCsvImporter {
  const TermiusCsvImporter._();

  /// Decodes UTF-8 bytes strictly and parses them. Use this from pickers.
  static TermiusImportDocument parseBytes(List<int> bytes) {
    if (bytes.length > maxTermiusCsvBytes) {
      return _fileFailure(TermiusIssueCode.fileTooLarge);
    }
    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return _fileFailure(TermiusIssueCode.fileNotUtf8);
    }
    return parse(source);
  }

  static TermiusImportDocument _fileFailure(
    TermiusIssueCode code, {
    int? line,
    String? detail,
    List<String> headers = const [],
  }) => TermiusImportDocument(
    format: TermiusSourceFormat.csv,
    headers: headers,
    rows: const [],
    fileIssues: [
      TermiusIssue(
        code,
        severity: TermiusIssueSeverity.blocking,
        line: line ?? 1,
        detail: detail,
      ),
    ],
  );

  static TermiusImportDocument parse(String source) {
    final List<TermiusCsvRecord> records;
    try {
      records = TermiusCsv.parse(source);
    } on TermiusCsvException catch (error) {
      return _fileFailure(
        error.code == TermiusCsvErrorCode.tooLarge
            ? TermiusIssueCode.fileTooLarge
            : error.code == TermiusCsvErrorCode.tooManyRecords
            ? TermiusIssueCode.tooManyRows
            : TermiusIssueCode.csvStructure,
        line: error.line,
        detail: error.code.name,
      );
    }
    final nonBlank = records.where((record) => !record.isBlank).toList();
    if (nonBlank.isEmpty) return _fileFailure(TermiusIssueCode.emptyFile);

    final headerRecord = nonBlank.first;
    final headers = [
      for (final header in headerRecord.fields) _normalizeHeader(header),
    ];
    final fileIssues = <TermiusIssue>[];
    final columnIndex = <String, int>{};
    final unknownColumns = <int, String>{};
    for (var index = 0; index < headers.length; index++) {
      final header = headers[index];
      final known = _resolveKnownCsvHeader(header);
      if (known.isEmpty) {
        if (header.isEmpty) {
          unknownColumns[index] = '#${index + 1}';
        } else {
          unknownColumns[index] = _safeDetail(header);
        }
        continue;
      }
      if (columnIndex.containsKey(known)) {
        return _fileFailure(
          TermiusIssueCode.duplicateHeader,
          line: headerRecord.line,
          detail: known,
          headers: headers,
        );
      }
      columnIndex[known] = index;
    }
    if (!columnIndex.containsKey(TermiusCsvColumn.hostname)) {
      // Most likely the file has no header row or is not a Termius template.
      return _fileFailure(
        columnIndex.isEmpty
            ? TermiusIssueCode.noTemplateHeader
            : TermiusIssueCode.missingHostnameColumn,
        line: headerRecord.line,
        detail: TermiusCsvColumn.hostname,
        headers: headers,
      );
    }
    final templatePrefix = headers.length <= TermiusCsvColumn.template.length &&
        [
          for (var index = 0; index < headers.length; index++)
            headers[index] == TermiusCsvColumn.template[index],
        ].every((same) => same);
    if (columnIndex.containsKey(TermiusCsvColumn.sshKey)) {
      fileIssues.add(
        TermiusIssue(
          TermiusIssueCode.nonTemplateColumn,
          line: headerRecord.line,
          detail: TermiusCsvColumn.sshKey,
        ),
      );
    }
    if (!templatePrefix) {
      fileIssues.add(
        TermiusIssue(
          TermiusIssueCode.headerOrderNotTermius,
          line: headerRecord.line,
        ),
      );
    }
    for (final entry in unknownColumns.entries) {
      fileIssues.add(
        TermiusIssue(
          TermiusIssueCode.unknownHeader,
          line: headerRecord.line,
          detail: entry.value,
        ),
      );
    }

    final dataRecords = nonBlank.skip(1).toList();
    if (dataRecords.length > maxTermiusImportRows) {
      return _fileFailureCount(
        TermiusIssueCode.tooManyRows,
        maxTermiusImportRows,
        headers,
      );
    }

    final rows = <TermiusImportRow>[];
    for (var ordinal = 0; ordinal < dataRecords.length; ordinal++) {
      rows.add(
        _parseRow(
          dataRecords[ordinal],
          row: ordinal + 1,
          columns: columnIndex,
          unknownColumns: unknownColumns,
          width: headers.length,
        ),
      );
    }
    return TermiusImportDocument(
      format: TermiusSourceFormat.csv,
      headers: List.unmodifiable(headers),
      rows: List.unmodifiable(rows),
      fileIssues: List.unmodifiable(fileIssues),
    );
  }

  static TermiusImportDocument _fileFailureCount(
    TermiusIssueCode code,
    int count,
    List<String> headers,
  ) => TermiusImportDocument(
    format: TermiusSourceFormat.csv,
    headers: headers,
    rows: const [],
    fileIssues: [
      TermiusIssue(code, severity: TermiusIssueSeverity.blocking, count: count),
    ],
  );

  static String _normalizeHeader(String header) =>
      header.replaceAll('﻿', '').trim();

  static String _resolveKnownCsvHeader(String header) {
    final lower = header.toLowerCase();
    for (final column in TermiusCsvColumn.known) {
      if (column.toLowerCase() == lower) return column;
    }
    return switch (lower) {
      'address' || 'hostname' || 'host' || 'ip' => TermiusCsvColumn.hostname,
      'name' || 'title' => TermiusCsvColumn.label,
      'group' || 'folder' => TermiusCsvColumn.groups,
      'user' => TermiusCsvColumn.username,
      'tag' => TermiusCsvColumn.tags,
      'ssh key' || 'private_key' || 'privatekey' => TermiusCsvColumn.sshKey,
      _ => '',
    };
  }

  static TermiusImportRow _parseRow(
    TermiusCsvRecord record, {
    required int row,
    required Map<String, int> columns,
    required Map<int, String> unknownColumns,
    required int width,
  }) {
    final issues = <TermiusIssue>[];
    void issue(
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
        line: record.line,
        row: row,
        detail: detail,
        count: count,
      ),
    );

    final fields = record.fields;
    if (fields.length > width) {
      final extra = fields.skip(width).any((value) => value.isNotEmpty);
      if (extra) {
        issue(TermiusIssueCode.extraFields, blocking: true, count: fields.length);
      }
    } else if (fields.length < width) {
      issue(TermiusIssueCode.missingFields, count: fields.length);
    }
    String? cell(String column) {
      final index = columns[column];
      if (index == null || index >= fields.length) return null;
      return fields[index];
    }

    for (final entry in unknownColumns.entries) {
      if (entry.key < fields.length && fields[entry.key].isNotEmpty) {
        issue(TermiusIssueCode.unknownColumnValue, detail: entry.value);
      }
    }

    // Address (supports optional `user@host:port` / `host:port` shorthand when
    // the separate Username or Port cell was left empty).
    var address = (cell(TermiusCsvColumn.hostname) ?? '').trim();
    String? inlineUser;
    String? inlinePort;
    if (address.contains('@') && !address.contains(' ')) {
      final at = address.lastIndexOf('@');
      if (at > 0 && at + 1 < address.length) {
        inlineUser = address.substring(0, at);
        address = address.substring(at + 1);
      }
    }
    if (address.startsWith('[')) {
      final close = address.indexOf(']');
      if (close > 1) {
        final rest = address.substring(close + 1);
        if (rest.startsWith(':') && rest.length > 1) {
          inlinePort = rest.substring(1);
          address = address.substring(1, close);
        } else if (rest.isEmpty) {
          address = address.substring(1, close);
        }
      }
    } else {
      final firstColon = address.indexOf(':');
      final lastColon = address.lastIndexOf(':');
      if (firstColon > 0 &&
          firstColon == lastColon &&
          RegExp(r'^[0-9]{1,5}$').hasMatch(address.substring(firstColon + 1))) {
        inlinePort = address.substring(firstColon + 1);
        address = address.substring(0, firstColon);
      }
    }
    if (address.isEmpty) {
      issue(TermiusIssueCode.missingAddress, blocking: true);
    } else if (!_isValidAddress(address)) {
      issue(TermiusIssueCode.invalidAddress, blocking: true);
    }

    // Label.
    var label = (cell(TermiusCsvColumn.label) ?? '').trim();
    if (label.isEmpty) label = address;
    // Termius labels may legitimately contain quoted line breaks and tabs.
    if (RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]').hasMatch(label) ||
        utf8.encode(label).length > _maxLabelBytes) {
      issue(TermiusIssueCode.invalidLabel, blocking: true);
    }

    // Protocol.
    final protocolText = (cell(TermiusCsvColumn.protocol) ?? '')
        .trim()
        .toLowerCase();
    HostProtocol? protocol;
    switch (protocolText) {
      case '':
      case 'ssh':
        protocol = HostProtocol.ssh;
      case 'mosh':
        // Termius stores mosh as SSH with use_mosh; Atermius has no mosh.
        protocol = HostProtocol.ssh;
        issue(TermiusIssueCode.moshImportedAsSsh);
      case 'rdp':
        protocol = HostProtocol.rdp;
        issue(TermiusIssueCode.extensionProtocol, detail: 'rdp');
      case 'vnc':
        protocol = HostProtocol.vnc;
        issue(TermiusIssueCode.extensionProtocol, detail: 'vnc');
      default:
        issue(
          TermiusIssueCode.unsupportedProtocol,
          blocking: true,
          detail: _safeDetail(protocolText),
        );
    }

    // Port.
    final rawPortCell = (cell(TermiusCsvColumn.port) ?? '').trim();
    final portText = rawPortCell.isEmpty ? (inlinePort ?? '') : rawPortCell;
    int? port;
    if (portText.isEmpty) {
      port = protocol?.defaultPort;
    } else {
      final parsed = RegExp(r'^[0-9]{1,5}$').hasMatch(portText)
          ? int.parse(portText)
          : null;
      if (parsed == null || parsed < 1 || parsed > 65535) {
        issue(TermiusIssueCode.invalidPort, blocking: true);
      } else {
        port = parsed;
      }
    }

    // Username. Trimmed: OpenSSH and Termius never use surrounding spaces.
    final rawUserCell = (cell(TermiusCsvColumn.username) ?? '').trim();
    final username = rawUserCell.isEmpty ? (inlineUser ?? '') : rawUserCell;
    if (username.isNotEmpty &&
        (_hasControl(username) ||
            username.contains(RegExp(r'\s')) ||
            utf8.encode(username).length > _maxUsernameBytes)) {
      issue(TermiusIssueCode.invalidUsername, blocking: true);
    } else if (username.isEmpty && protocol == HostProtocol.ssh) {
      issue(TermiusIssueCode.missingUsername, blocking: true);
    }

    // Credentials. The password is kept byte-for-byte, including spaces.
    var password = cell(TermiusCsvColumn.password);
    if (password != null && password.isEmpty) password = null;
    if (password != null &&
        (password.contains('\u0000') ||
            utf8.encode(password).length > _maxPasswordBytes)) {
      issue(TermiusIssueCode.invalidPassword, blocking: true);
      password = null;
    }
    String? privateKey;
    final keyCell = cell(TermiusCsvColumn.sshKey);
    if (keyCell != null && keyCell.trim().isNotEmpty) {
      if (isInlinePrivateKeyText(keyCell)) {
        final normalized = normalizePrivateKeyText(keyCell);
        if (utf8.encode(normalized).length > maxTermiusPrivateKeyBytes ||
            normalized.contains('\u0000')) {
          issue(TermiusIssueCode.invalidPrivateKey, blocking: true);
        } else {
          privateKey = normalized;
        }
      } else {
        // A key label/reference or file path. Never resolved or opened.
        issue(TermiusIssueCode.sshKeyNotInline);
      }
    }
    if (privateKey != null && password != null) {
      issue(TermiusIssueCode.passwordDroppedForKey);
      password = null;
    }
    if (privateKey != null && protocol != null && protocol != HostProtocol.ssh) {
      issue(TermiusIssueCode.credentialsIgnoredForProtocol);
      privateKey = null;
    }

    // Groups: `/` separated path of nested groups.
    final groupPath = <String>[];
    final groupsText = (cell(TermiusCsvColumn.groups) ?? '').trim();
    if (groupsText.isNotEmpty) {
      final segments = groupsText.split('/');
      var droppedEmpty = false;
      for (final raw in segments) {
        final segment = raw.trim();
        if (segment.isEmpty) {
          droppedEmpty = true;
          continue;
        }
        if (_hasControl(segment) ||
            utf8.encode(segment).length > _maxGroupNameBytes) {
          issue(TermiusIssueCode.invalidGroup, blocking: true);
          break;
        }
        groupPath.add(segment);
      }
      if (droppedEmpty) issue(TermiusIssueCode.emptyGroupSegment);
      if (groupPath.length > _maxGroupDepth) {
        issue(
          TermiusIssueCode.groupTooDeep,
          blocking: true,
          count: _maxGroupDepth,
        );
      }
    }

    // Tags: `,` separated (the cell is quoted when it holds several).
    final tagsText = cell(TermiusCsvColumn.tags) ?? '';
    final rawTags = tagsText
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    final tags = parseHostTags(rawTags.join(','));
    if (tags.length != rawTags.length) {
      issue(
        TermiusIssueCode.duplicateTagDropped,
        count: rawTags.length - tags.length,
      );
    }
    if (tags.length > _maxTagsPerHost ||
        tags.any((tag) => tag.length > _maxTagLength || _hasControl(tag))) {
      issue(TermiusIssueCode.invalidTag, blocking: true);
    }

    return TermiusImportRow(
      row: row,
      line: record.line,
      label: label,
      address: address,
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
}

bool _hasControl(String value) =>
    RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value);

bool _isValidAddress(String value) =>
    value.length <= 253 &&
    !value.contains(RegExp(r'[\s\u0000-\u001F\u007F,/\\"\x27`$;|&<>()]')) &&
    !value.startsWith('-');

/// True for one PEM/OpenSSH private key block (never a path or key name).
bool isInlinePrivateKeyText(String value) {
  final text = value.trim();
  return RegExp(
    r'^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]+-----END [A-Z0-9 ]*PRIVATE KEY-----$',
  ).hasMatch(text);
}

/// Normalizes line endings of an inline key to LF and ensures one trailing
/// newline, which every OpenSSH/PEM reader accepts. Key material is unchanged.
String normalizePrivateKeyText(String value) {
  final text = value.trim().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return '$text\n';
}

/// Shortens and strips a user-provided non-secret word for display.
String _safeDetail(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '?');
  return cleaned.length > 40 ? '${cleaned.substring(0, 40)}…' : cleaned;
}

// ---------------------------------------------------------------------------
// Planning

enum TermiusDuplicatePolicy {
  /// Rows equal to an existing Host (name and endpoint) are skipped.
  skip,

  /// Every valid row is imported as a new Host.
  importAsNew,
}

enum TermiusRowDisposition {
  create,
  skippedDuplicate,
  skippedExisting,
  blocked,
  excluded,
}

class TermiusPlannedRow {
  const TermiusPlannedRow({
    required this.source,
    required this.disposition,
    required this.issues,
    this.host,
    this.credential,
  });

  final TermiusImportRow source;

  /// A new private-key Credential (with certificate) used by [host].
  final CredentialRecord? credential;
  final TermiusRowDisposition disposition;

  /// The Host that will be created; null unless [disposition] is create.
  final HostRecord? host;

  /// Source issues plus planning findings.
  final List<TermiusIssue> issues;

  bool get willCreate => disposition == TermiusRowDisposition.create;
}

class TermiusImportPlan {
  const TermiusImportPlan({
    required this.format,
    required this.catalogFingerprint,
    required this.rows,
    required this.newGroups,
    required this.fileIssues,
    this.newCredentials = const [],
  });

  final TermiusSourceFormat format;
  final String catalogFingerprint;
  final List<TermiusPlannedRow> rows;

  /// Groups to create, parents before children.
  final List<GroupRecord> newGroups;

  /// Credentials to create before the hosts that reference them.
  final List<CredentialRecord> newCredentials;
  final List<TermiusIssue> fileIssues;

  bool get blocksWholeFile => fileIssues.any((issue) => issue.blocking);

  List<HostRecord> get hostsToCreate => [
    for (final row in rows)
      if (row.host != null) row.host!,
  ];

  int get createCount => hostsToCreate.length;
  int get secretCount => rows
      .where(
        (row) =>
            row.willCreate &&
            (row.host?.login != null || row.credential != null),
      )
      .length;
  bool get canApply => !blocksWholeFile && createCount > 0;
}

class TermiusImportPlanner {
  const TermiusImportPlanner._();

  static bool _isMissingUsernameIssue(TermiusIssue issue) =>
      issue.blocking &&
      (issue.code == TermiusIssueCode.missingUsername ||
          (issue.code == TermiusIssueCode.sshParserFinding &&
              issue.detail?.toLowerCase() == 'user'));

  /// True when at least one SSH row in [document] has an empty username and
  /// would be unblocked by supplying a valid `fallbackUsername`.
  static bool hasRowsMissingUsername(TermiusImportDocument document) =>
      !document.blocksWholeFile &&
      document.rows.any(
        (row) =>
            row.protocol == HostProtocol.ssh &&
            row.username.isEmpty &&
            row.issues.any(_isMissingUsernameIssue) &&
            row.issues
                .where((issue) => issue.blocking)
                .every(_isMissingUsernameIssue),
      );

  static String? _normalizeFallbackUsername(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        _hasControl(trimmed) ||
        trimmed.contains(RegExp(r'\s')) ||
        utf8.encode(trimmed).length > _maxUsernameBytes) {
      return null;
    }
    return trimmed;
  }

  static TermiusImportPlan plan(
    TermiusImportDocument document,
    TermiusCatalog catalog, {
    TermiusDuplicatePolicy duplicates = TermiusDuplicatePolicy.skip,
    Set<int> excludedRows = const {},
    String Function()? newId,
    TermiusCertificateBridge? certificates,
    String? fallbackUsername,
  }) {
    String id() => newId?.call() ?? _uuid.v4();
    final defaultSshUser = _normalizeFallbackUsername(fallbackUsername);

    final groupsByParent = <String?, Map<String, GroupRecord>>{};
    for (final group in catalog.groups) {
      groupsByParent.putIfAbsent(group.parentId, () => {})[normalizeGroupName(
            group.name,
          )] =
          group;
    }
    final newGroups = <GroupRecord>[];
    String? resolveGroup(List<String> path) {
      String? parent;
      for (final segment in path) {
        final siblings = groupsByParent.putIfAbsent(parent, () => {});
        final key = normalizeGroupName(segment);
        var group = siblings[key];
        if (group == null) {
          group = GroupRecord(id: id(), name: segment.trim(), parentId: parent);
          siblings[key] = group;
          newGroups.add(group);
        }
        parent = group.id;
      }
      return parent;
    }

    String endpointKey(HostProtocol protocol, String address, int port, String user) =>
        jsonEncode([protocol.name, address.toLowerCase(), port, user]);
    final existingByIdentity = <String, HostRecord>{};
    final existingNames = <String, List<HostRecord>>{};
    for (final host in catalog.hosts) {
      existingByIdentity.putIfAbsent(
        jsonEncode([
          host.name.trim().toLowerCase(),
          endpointKey(host.protocol, host.address, host.port, host.username),
        ]),
        () => host,
      );
      existingNames.putIfAbsent(host.name.trim().toLowerCase(), () => []).add(host);
    }

    final seenInFile = <String, int>{};
    final planned = <TermiusPlannedRow>[];
    // Alias -> planned/new Host id, for ProxyJump resolution.
    final idByAlias = <String, String>{};
    final pending = <int, HostRecord>{};
    final pendingCredentials = <int, CredentialRecord>{};

    for (var index = 0; index < document.rows.length; index++) {
      final source = document.rows[index];
      final useFallbackUser =
          defaultSshUser != null &&
          source.protocol == HostProtocol.ssh &&
          source.username.isEmpty &&
          source.issues.any(_isMissingUsernameIssue);
      final effectiveUsername = useFallbackUser
          ? defaultSshUser
          : source.username;
      final issues = <TermiusIssue>[
        for (final issue in source.issues)
          if (useFallbackUser && _isMissingUsernameIssue(issue))
            TermiusIssue(
              issue.code,
              severity: TermiusIssueSeverity.warning,
              line: issue.line,
              row: issue.row,
              detail: issue.detail,
              count: issue.count,
              messageBuilder: issue.messageBuilder,
            )
          else
            issue,
      ];
      void add(TermiusIssueCode code, {bool blocking = false, int? row, String? detail}) =>
          issues.add(
            TermiusIssue(
              code,
              severity: blocking
                  ? TermiusIssueSeverity.blocking
                  : TermiusIssueSeverity.warning,
              line: source.line,
              row: row ?? source.row,
              detail: detail,
            ),
          );

      if (document.blocksWholeFile || issues.any((issue) => issue.blocking)) {
        planned.add(
          TermiusPlannedRow(
            source: source,
            disposition: TermiusRowDisposition.blocked,
            issues: issues,
          ),
        );
        continue;
      }
      if (excludedRows.contains(source.row)) {
        add(TermiusIssueCode.excludedByUser);
        planned.add(
          TermiusPlannedRow(
            source: source,
            disposition: TermiusRowDisposition.excluded,
            issues: issues,
          ),
        );
        continue;
      }
      final protocol = source.protocol!;
      final port = source.port!;
      final nameKey = source.label.trim().toLowerCase();
      final identity = jsonEncode([
        nameKey,
        endpointKey(protocol, source.address, port, effectiveUsername),
      ]);
      final firstRow = seenInFile[identity];
      if (firstRow != null) {
        add(TermiusIssueCode.duplicateInFile, row: firstRow);
        planned.add(
          TermiusPlannedRow(
            source: source,
            disposition: TermiusRowDisposition.skippedDuplicate,
            issues: issues,
          ),
        );
        continue;
      }
      seenInFile[identity] = source.row;
      final existing = existingByIdentity[identity];
      if (existing != null && duplicates == TermiusDuplicatePolicy.skip) {
        add(TermiusIssueCode.alreadyExists, detail: existing.name);
        idByAlias.putIfAbsent(nameKey, () => existing.id);
        planned.add(
          TermiusPlannedRow(
            source: source,
            disposition: TermiusRowDisposition.skippedExisting,
            issues: issues,
          ),
        );
        continue;
      }
      if (existingNames.containsKey(nameKey)) {
        add(TermiusIssueCode.nameAlreadyUsed);
      }

      HostLogin? login;
      CredentialRecord? credential;
      if (source.privateKey != null &&
          source.certificate != null &&
          certificates != null) {
        credential = certificates.withCertificate(
          CredentialRecord(
            id: id(),
            name: source.label,
            username: effectiveUsername,
            kind: AuthKind.privateKey,
            privateKey: source.privateKey,
          ),
          source.certificate!,
        );
      } else if (source.privateKey != null) {
        login = HostLogin(kind: AuthKind.privateKey, privateKey: source.privateKey);
        if (source.certificate != null) {
          add(TermiusIssueCode.certificateNotStored);
        }
      } else if (source.password != null) {
        login = HostLogin(kind: AuthKind.password, password: source.password);
      }
      if (source.certificate != null && source.privateKey == null) {
        add(TermiusIssueCode.certificateWithoutKey);
      }
      final host = HostRecord(
        id: id(),
        name: source.label,
        address: source.address,
        port: port,
        protocol: protocol,
        username: effectiveUsername,
        groupId: source.groupPath.isEmpty ? null : resolveGroup(source.groupPath),
        login: login,
        credentialId: credential?.id,
        authKind: credential != null
            ? AuthKind.privateKey
            : login?.kind ?? AuthKind.password,
        tags: source.tags,
        portForwardProfiles: protocol == HostProtocol.ssh
            ? source.forwards
            : const [],
      );
      final problem = host.validate();
      if (problem != null) {
        add(TermiusIssueCode.invalidRecord, blocking: true);
        planned.add(
          TermiusPlannedRow(
            source: source,
            disposition: TermiusRowDisposition.blocked,
            issues: issues,
          ),
        );
        continue;
      }
      idByAlias.putIfAbsent(nameKey, () => host.id);
      if (credential != null) pendingCredentials[planned.length] = credential;
      pending[planned.length] = host;
      planned.add(
        TermiusPlannedRow(
          source: source,
          disposition: TermiusRowDisposition.create,
          issues: issues,
          host: host,
        ),
      );
    }

    // ProxyJump (OpenSSH only): resolve aliases to planned or saved Hosts.
    for (final name in existingNames.keys) {
      final hosts = existingNames[name]!;
      if (hosts.length == 1) idByAlias.putIfAbsent(name, () => hosts.single.id);
    }
    final graph = <String, String?>{
      for (final host in catalog.hosts) host.id: host.jumpHostId,
    };
    final resolved = <int, HostRecord>{};
    for (final entry in pending.entries) {
      final row = planned[entry.key];
      final alias = row.source.jumpAlias;
      var host = entry.value;
      if (alias != null) {
        final jumpId = idByAlias[alias.trim().toLowerCase()];
        if (jumpId == null || jumpId == host.id) {
          row.issues.add(
            TermiusIssue(
              jumpId == null
                  ? TermiusIssueCode.sshJumpMissing
                  : TermiusIssueCode.sshJumpCycle,
              severity: TermiusIssueSeverity.blocking,
              line: row.source.line,
              row: row.source.row,
              detail: _safeDetail(alias),
            ),
          );
          continue;
        }
        host = host.copyWith(jumpHostId: jumpId);
      }
      resolved[entry.key] = host;
      graph[host.id] = host.jumpHostId;
    }
    // Reject cycles / overlong chains, then drop hosts whose jump target was
    // itself rejected (iterate to a fixed point).
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in resolved.entries.toList()) {
        final host = entry.value;
        if (!_jumpChainValid(host.id, graph)) {
          final row = planned[entry.key];
          row.issues.add(
            TermiusIssue(
              TermiusIssueCode.sshJumpCycle,
              severity: TermiusIssueSeverity.blocking,
              line: row.source.line,
              row: row.source.row,
            ),
          );
          resolved.remove(entry.key);
          graph.remove(host.id);
          changed = true;
        }
      }
    }
    final rows = <TermiusPlannedRow>[];
    for (var index = 0; index < planned.length; index++) {
      final row = planned[index];
      if (!pending.containsKey(index)) {
        rows.add(row);
        continue;
      }
      final host = resolved[index];
      rows.add(
        TermiusPlannedRow(
          source: row.source,
          disposition: host == null
              ? TermiusRowDisposition.blocked
              : TermiusRowDisposition.create,
          issues: List.unmodifiable(row.issues),
          host: host,
          credential: host == null ? null : pendingCredentials[index],
        ),
      );
    }

    // Only create groups that a created Host actually needs.
    final neededGroups = <String>{};
    final newGroupById = {for (final group in newGroups) group.id: group};
    for (final row in rows) {
      var groupId = row.host?.groupId;
      while (groupId != null && newGroupById.containsKey(groupId)) {
        if (!neededGroups.add(groupId)) break;
        groupId = newGroupById[groupId]!.parentId;
      }
    }

    return TermiusImportPlan(
      format: document.format,
      catalogFingerprint: catalog.fingerprint,
      rows: List.unmodifiable(rows),
      newGroups: List.unmodifiable(
        newGroups.where((group) => neededGroups.contains(group.id)),
      ),
      fileIssues: document.fileIssues,
      newCredentials: List.unmodifiable([
        for (final row in rows)
          if (row.credential != null) row.credential!,
      ]),
    );
  }

  static bool _jumpChainValid(String start, Map<String, String?> graph) {
    final seen = <String>{};
    var current = start;
    var hops = 0;
    while (true) {
      if (!seen.add(current)) return false;
      final next = graph[current];
      if (next == null) return true;
      if (++hops > maxJumpHostHops) return false;
      if (!graph.containsKey(next)) return false;
      current = next;
    }
  }
}

/// Orders hosts so every jump target is created before the hosts using it.
List<HostRecord> orderHostsForCreation(
  List<HostRecord> hosts,
  Set<String> existingIds,
) {
  final pending = [...hosts];
  final created = <String>{...existingIds};
  final ordered = <HostRecord>[];
  while (pending.isNotEmpty) {
    final index = pending.indexWhere(
      (host) => host.jumpHostId == null || created.contains(host.jumpHostId),
    );
    if (index < 0) {
      throw StateError('Import jump-host order is not satisfiable.');
    }
    final host = pending.removeAt(index);
    created.add(host.id);
    ordered.add(host);
  }
  return ordered;
}

// ---------------------------------------------------------------------------
// Export

enum TermiusExportFormat { csv, openSsh, openSshBundle }

class TermiusExportOptions {
  const TermiusExportOptions({
    this.includePasswords = false,
    this.includePrivateKeys = false,
    this.includeRemoteDesktops = false,
    this.hostIds,
  });

  /// CSV only: writes passwords in plaintext. Requires in-app confirmation.
  final bool includePasswords;

  /// OpenSSH bundle only: writes private key files (and certificates).
  /// Requires in-app confirmation. The Termius CSV template has no key column.
  final bool includePrivateKeys;

  /// CSV only, Atermius extension: also write RDP/VNC rows.
  final bool includeRemoteDesktops;

  /// Optional subset of Host ids to export; null exports every Host.
  final Set<String>? hostIds;
}

class TermiusExportResult {
  const TermiusExportResult({
    required this.text,
    required this.exportedHosts,
    required this.issues,
    required this.containsSecrets,
    required this.suggestedFileName,
    this.binary,
    this.keyFiles = 0,
    this.blocked = false,
  });

  /// The output would exceed limits the matching importer enforces; nothing
  /// may be saved (no silent truncation).
  final bool blocked;

  /// Text output (CSV/config) or a human summary for binary bundles.
  final String text;

  /// ZIP bytes for [TermiusExportFormat.openSshBundle].
  final Uint8List? binary;
  final int exportedHosts;
  final int keyFiles;
  final List<TermiusIssue> issues;
  final bool containsSecrets;
  final String suggestedFileName;

  Uint8List get bytes => binary ?? Uint8List.fromList(utf8.encode(text));
}

/// One Host block in an OpenSSH config (shared by config and bundle export).
class TermiusSshHostBlock {
  const TermiusSshHostBlock({
    required this.host,
    required this.alias,
    required this.login,
  });

  final HostRecord host;
  final String alias;
  final TermiusEffectiveLogin? login;
}

class TermiusExporter {
  const TermiusExporter._();

  static List<HostRecord> selectHosts(
    TermiusCatalog catalog,
    TermiusExportOptions options,
  ) {
    final ids = options.hostIds;
    final hosts = ids == null
        ? catalog.hosts
        : catalog.hosts.where((host) => ids.contains(host.id));
    return [...hosts]..sort((a, b) {
      final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return name != 0 ? name : a.id.compareTo(b.id);
    });
  }

  static List<String>? _groupPath(String? groupId, TermiusCatalog catalog) {
    final path = <String>[];
    final seen = <String>{};
    var current = groupId;
    while (current != null) {
      final group = catalog.groupById(current);
      if (group == null || !seen.add(current) || path.length > 64) return null;
      path.insert(0, group.name);
      current = group.parentId;
    }
    return path;
  }

  /// Termius CSV with exactly the eight template columns, in order. Values are
  /// written verbatim (never formula-escaped); anything the Termius parser
  /// would split, trim or cannot carry is reported instead.
  static TermiusExportResult csv(
    TermiusCatalog catalog, {
    TermiusExportOptions options = const TermiusExportOptions(),
    TermiusCertificateBridge? certificates,
    DateTime? now,
  }) {
    final issues = <TermiusIssue>[];
    final rows = <List<String>>[TermiusCsvColumn.template];
    var secretsWritten = false;
    var secretsOmitted = 0;
    var keysOmitted = 0;
    var certificatesOmitted = 0;
    var jumpCount = 0;
    var forwardCount = 0;
    var skippedProtocol = 0;
    var sharedCredentials = 0;
    var formulaRisk = 0;
    for (final host in selectHosts(catalog, options)) {
      if (host.protocol != HostProtocol.ssh && !options.includeRemoteDesktops) {
        skippedProtocol++;
        continue;
      }
      final path = _groupPath(host.groupId, catalog);
      if (path == null) {
        issues.add(
          TermiusIssue(TermiusIssueCode.exportHostSkipped, detail: host.name),
        );
        continue;
      }
      if (path.any((segment) => segment.contains('/'))) {
        issues.add(
          TermiusIssue(TermiusIssueCode.exportGroupSlash, detail: host.name),
        );
      }
      if (path.any((segment) => segment.trim() != segment)) {
        issues.add(
          TermiusIssue(
            TermiusIssueCode.exportGroupWhitespace,
            detail: host.name,
          ),
        );
      }
      if (host.tags.any((tag) => tag.contains(',') || tag.trim() != tag)) {
        issues.add(
          TermiusIssue(TermiusIssueCode.exportTagComma, detail: host.name),
        );
      }
      if (host.jumpHostId != null) jumpCount++;
      if (host.portForwardProfiles.isNotEmpty) forwardCount++;
      final login = resolveTermiusEffectiveLogin(
        host,
        catalog,
        certificates: certificates,
      );
      var password = '';
      if (login != null) {
        if (login.privateKey != null) keysOmitted++;
        if (login.certificate != null) certificatesOmitted++;
        if (login.password != null) {
          if (login.source != TermiusLoginSource.hostLogin) {
            sharedCredentials++;
          }
          if (options.includePasswords) {
            password = login.password!;
            secretsWritten = true;
          } else {
            secretsOmitted++;
          }
        }
      }
      final row = [
        path.join('/'),
        host.name,
        host.tags.join(','),
        host.address,
        host.protocol.name,
        '${host.port}',
        login?.username ?? host.username,
        // Exact bytes, including surrounding whitespace.
        password,
      ];
      if (row.any(isSpreadsheetFormulaRisk)) formulaRisk++;
      rows.add(row);
    }
    void addCount(TermiusIssueCode code, int count) {
      if (count > 0) issues.add(TermiusIssue(code, count: count));
    }

    addCount(TermiusIssueCode.exportSkippedProtocol, skippedProtocol);
    addCount(TermiusIssueCode.exportJumpNotRepresented, jumpCount);
    addCount(TermiusIssueCode.exportForwardsNotRepresented, forwardCount);
    addCount(TermiusIssueCode.exportKeysNotRepresented, keysOmitted);
    addCount(
      TermiusIssueCode.exportCertificatesNotRepresented,
      certificatesOmitted,
    );
    addCount(TermiusIssueCode.exportSharedCredentialSkipped, sharedCredentials);
    addCount(TermiusIssueCode.exportSecretsOmitted, secretsOmitted);
    addCount(TermiusIssueCode.exportFormulaRisk, formulaRisk);
    final text = TermiusCsv.encode(rows);
    final blocked =
        rows.length - 1 > maxTermiusImportRows ||
        utf8EncodedLength(text) > maxTermiusCsvBytes;
    if (blocked) {
      issues.add(
        const TermiusIssue(
          TermiusIssueCode.exportTooLarge,
          severity: TermiusIssueSeverity.blocking,
          detail: 'csv',
        ),
      );
    }
    return TermiusExportResult(
      text: blocked ? '' : text,
      exportedHosts: rows.length - 1,
      issues: List.unmodifiable(issues),
      containsSecrets: secretsWritten && !blocked,
      suggestedFileName: 'atermius-termius-${stamp(now)}.csv',
      blocked: blocked,
    );
  }

  /// Plans the Host blocks for an OpenSSH config: SSH hosts only, unique
  /// OpenSSH-safe aliases, effective username.
  static List<TermiusSshHostBlock> sshBlocks(
    TermiusCatalog catalog,
    TermiusExportOptions options,
    List<TermiusIssue> issues, {
    TermiusCertificateBridge? certificates,
  }) {
    final selected = selectHosts(catalog, options);
    final hosts = selected
        .where((host) => host.protocol == HostProtocol.ssh)
        .toList();
    final skippedProtocol = selected.length - hosts.length;
    if (skippedProtocol > 0) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.exportSkippedProtocol,
          count: skippedProtocol,
        ),
      );
    }
    final used = <String>{};
    final blocks = <TermiusSshHostBlock>[];
    for (final host in hosts) {
      final login = resolveTermiusEffectiveLogin(
        host,
        catalog,
        certificates: certificates,
      );
      final username = login?.username ?? host.username;
      if (!isSafeSshValue(host.address) ||
          (username.isNotEmpty && !isSafeSshValue(username))) {
        issues.add(
          TermiusIssue(TermiusIssueCode.exportHostSkipped, detail: host.name),
        );
        continue;
      }
      final alias = sshAlias(host.name);
      if (alias != host.name) {
        issues.add(
          TermiusIssue(TermiusIssueCode.exportAliasRewritten, detail: host.name),
        );
      }
      var candidate = alias;
      var suffix = 2;
      while (!used.add(candidate.toLowerCase())) {
        candidate = '$alias-${suffix++}';
      }
      blocks.add(TermiusSshHostBlock(host: host, alias: candidate, login: login));
    }
    return blocks;
  }

  /// Writes OpenSSH Host blocks. [identityFiles] maps Host id to the
  /// IdentityFile (and optional CertificateFile) paths to reference.
  static String writeSshConfig(
    List<TermiusSshHostBlock> blocks,
    List<TermiusIssue> issues, {
    required TermiusCatalog catalog,
    required String header,
    Map<String, ({String identity, String? certificate})> identityFiles =
        const {},
  }) {
    final aliases = {for (final block in blocks) block.host.id: block.alias};
    final buffer = StringBuffer(header);
    for (final block in blocks) {
      final host = block.host;
      final username = block.login?.username ?? host.username;
      buffer
        ..write('\nHost ${block.alias}\n')
        ..write('    HostName ${host.address}\n');
      if (username.isNotEmpty) buffer.write('    User $username\n');
      if (host.port != 22) buffer.write('    Port ${host.port}\n');
      // Atermius-only metadata comments; OpenSSH and Termius ignore them.
      final groupPath = _groupPath(host.groupId, catalog);
      if (groupPath != null &&
          groupPath.isNotEmpty &&
          groupPath.every(_isSafeCommentValue)) {
        buffer.write('    # atermius:group ${groupPath.join('/')}\n');
      }
      if (host.tags.isNotEmpty && host.tags.every(_isSafeCommentValue)) {
        buffer.write('    # atermius:tags ${host.tags.join(',')}\n');
      }
      final files = identityFiles[host.id];
      if (files != null) {
        buffer.write('    IdentityFile ${files.identity}\n');
        if (files.certificate != null) {
          buffer.write('    CertificateFile ${files.certificate}\n');
        }
      }
      final jump = host.jumpHostId;
      if (jump != null) {
        final alias = aliases[jump];
        if (alias != null) {
          buffer.write('    ProxyJump $alias\n');
        } else {
          issues.add(
            TermiusIssue(
              TermiusIssueCode.exportJumpNotRepresented,
              detail: host.name,
            ),
          );
        }
      }
      for (final forward in host.portForwardProfiles) {
        final line = _forwardDirective(forward);
        if (line != null) buffer.write('    $line\n');
      }
    }
    return buffer.toString();
  }

  /// OpenSSH client config only. Never contains passwords, keys or
  /// IdentityFile paths (use the bundle format for key logins).
  static TermiusExportResult openSsh(
    TermiusCatalog catalog, {
    TermiusExportOptions options = const TermiusExportOptions(),
    TermiusCertificateBridge? certificates,
    DateTime? now,
  }) {
    final issues = <TermiusIssue>[];
    final blocks = sshBlocks(
      catalog,
      options,
      issues,
      certificates: certificates,
    );
    final text = writeSshConfig(
      blocks,
      issues,
      catalog: catalog,
      header:
          '# OpenSSH client configuration exported by Atermius\n'
          '# Generated ${stamp(now)}. Contains no passwords and no key files.\n',
    );
    final passwords = blocks.where((b) => b.login?.password != null).length;
    final keys = blocks.where((b) => b.login?.privateKey != null).length;
    if (passwords > 0) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.exportPasswordsNotRepresented,
          count: passwords,
        ),
      );
    }
    if (keys > 0) {
      issues.add(
        TermiusIssue(TermiusIssueCode.exportKeysOmitted, count: keys),
      );
    }
    final blocked = !sshConfigWithinImportLimits(text, blocks.length);
    if (blocked) {
      issues.add(
        const TermiusIssue(
          TermiusIssueCode.exportTooLarge,
          severity: TermiusIssueSeverity.blocking,
          detail: 'config',
        ),
      );
    }
    return TermiusExportResult(
      text: blocked ? '' : text,
      exportedHosts: blocks.length,
      issues: List.unmodifiable(issues),
      containsSecrets: false,
      suggestedFileName: 'atermius-ssh-config-${stamp(now)}.conf',
      blocked: blocked,
    );
  }

  /// Mirrors [OpenSshConfigImporter] limits (1 MiB, 4096 lines, 256 hosts)
  /// so an export is never produced that the importer would refuse.
  static bool sshConfigWithinImportLimits(String text, int hosts) =>
      hosts <= maxOpenSshExportHosts &&
      utf8EncodedLength(text) <= maxOpenSshConfigBytes &&
      '\n'.allMatches(text).length < 4096;

  static String? _forwardDirective(SshPortForwardProfile forward) {
    String endpoint(String address, int? port) {
      final host = address.contains(':') ? '[$address]' : address;
      return '$host:$port';
    }

    if (!isSafeSshValue(forward.bindAddress) ||
        (forward.destinationAddress != null &&
            !isSafeSshValue(forward.destinationAddress!))) {
      return null;
    }
    final bind = endpoint(forward.bindAddress, forward.bindPort);
    return switch (forward.type) {
      SshPortForwardType.local =>
        'LocalForward $bind ${endpoint(forward.destinationAddress!, forward.destinationPort)}',
      SshPortForwardType.remote =>
        'RemoteForward $bind ${endpoint(forward.destinationAddress!, forward.destinationPort)}',
      SshPortForwardType.dynamic => 'DynamicForward $bind',
    };
  }

  static String sshAlias(String name) {
    final trimmed = name.trim();
    if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$').hasMatch(trimmed)) {
      return trimmed;
    }
    var alias = trimmed
        .replaceAll(RegExp(r'[^A-Za-z0-9._:-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[^A-Za-z0-9]+'), '')
        .replaceAll(RegExp(r'-+$'), '');
    if (alias.isEmpty) alias = 'host';
    return alias.length > 200 ? alias.substring(0, 200) : alias;
  }

  static bool _isSafeCommentValue(String value) =>
      value.trim() == value &&
      value.isNotEmpty &&
      !value.contains(RegExp(r'[\u0000-\u001F\u007F/,]'));

  static bool isSafeSshValue(String value) =>
      value.isNotEmpty &&
      value.length <= 253 &&
      RegExp(r'^[A-Za-z0-9._:\-@\[\]]+$').hasMatch(value) &&
      !value.contains('%');

  static String stamp(DateTime? now) {
    final time = (now ?? DateTime.now()).toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}
