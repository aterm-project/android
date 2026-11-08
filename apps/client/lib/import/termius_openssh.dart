/// OpenSSH config import for Termius users, reusing [OpenSshConfigImporter].
///
/// `termius export-ssh-config` (termius-cli) writes `Host`, `HostName`,
/// `User`, `Port` and `IdentityFile ~/.termius/ssh_keys/<label>`; Termius'
/// own `~/.ssh` import also reads keep-alive and host-key options. This
/// wrapper keeps the existing importer's safety rules (no Include, Match,
/// ProxyCommand/LocalCommand execution, IdentityFile is never opened) and
/// only adds:
/// * known connection options that Atermius cannot represent are removed
///   before parsing and reported as explicit warnings instead of blocking;
/// * LocalForward/RemoteForward/DynamicForward become saved forward profiles
///   when they are loopback-safe, otherwise they are reported and skipped.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'openssh_config_import.dart';
import 'termius_transfer.dart';

const _uuid = Uuid();

/// Options that change connection behaviour Atermius manages itself. They
/// are reported and dropped; their values are never interpreted.
const _ignoredOptions = {
  'serveraliveinterval',
  'serveralivecountmax',
  'tcpkeepalive',
  'connecttimeout',
  'connectionattempts',
  'compression',
  'identitiesonly',
  'addkeystoagent',
  'usekeychain',
  'preferredauthentications',
  'pubkeyauthentication',
  'passwordauthentication',
  'kbdinteractiveauthentication',
  'challengeresponseauthentication',
  'gssapiauthentication',
  'gssapidelegatecredentials',
  'numberofpasswordprompts',
  'batchmode',
  'forwardagent',
  'forwardx11',
  'forwardx11trusted',
  'requesttty',
  'sendenv',
  'setenv',
  'loglevel',
  'ciphers',
  'macs',
  'kexalgorithms',
  'hostkeyalgorithms',
  'pubkeyacceptedkeytypes',
  'pubkeyacceptedalgorithms',
  'casignaturealgorithms',
  'addressfamily',
  'ipqos',
  'escapechar',
  'visualhostkey',
  'controlmaster',
  'controlpath',
  'controlpersist',
  'exitonforwardfailure',
  'gatewayports',
  'clearallforwardings',
  'certificatefile',
  'identityagent',
  'canonicalizehostname',
  'canonicaldomains',
  'rekeylimit',
  'streamlocalbindunlink',
};

/// Host-key policy options. Atermius always keeps its own known-host gate;
/// these are reported separately so a `StrictHostKeyChecking no` is visible.
const _hostKeyPolicyOptions = {
  'stricthostkeychecking',
  'userknownhostsfile',
  'globalknownhostsfile',
  'updatehostkeys',
  'hashknownhosts',
  'checkhostip',
  'hostkeyalias',
  'verifyhostkeydns',
};

const _forwardOptions = {'localforward', 'remoteforward', 'dynamicforward'};

/// Read-only view of files inside an explicitly selected, already validated
/// OpenSSH bundle. Implementations never touch the real filesystem.
abstract interface class TermiusBundleFiles {
  /// Returns the text of the bundle entry an IdentityFile/CertificateFile
  /// value refers to, or null when it is not inside the bundle.
  String? read(String configValue);
}

final _certificateLine = RegExp(
  r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)-cert-v01@openssh\.com [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$',
);

class TermiusOpenSshImporter {
  const TermiusOpenSshImporter._();

  static TermiusImportDocument parseBytes(List<int> bytes) {
    if (bytes.length > maxOpenSshConfigBytes) {
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

  static TermiusImportDocument _failure(TermiusIssueCode code) =>
      TermiusImportDocument(
        format: TermiusSourceFormat.openSsh,
        headers: const [],
        rows: const [],
        fileIssues: [
          TermiusIssue(code, severity: TermiusIssueSeverity.blocking, line: 1),
        ],
      );

  /// With [bundle], IdentityFile/CertificateFile values are resolved ONLY
  /// against entries of that selected bundle; nothing else is ever read.
  static TermiusImportDocument parse(
    String source, {
    TermiusBundleFiles? bundle,
  }) {
    final source0 = source.startsWith('﻿') ? source.substring(1) : source;
    final lines = source0.split(RegExp(r'\r\n|\n|\r'));
    final fileIssues = <TermiusIssue>[];
    final forwardsByAlias = <String, List<SshPortForwardProfile>>{};
    final forwardIssuesByAlias = <String, List<TermiusIssue>>{};
    final optionIssuesByAlias = <String, List<TermiusIssue>>{};
    final identityByAlias = <String, ({String value, int line})>{};
    final groupByAlias = <String, List<String>>{};
    final tagsByAlias = <String, List<String>>{};
    final metadata = RegExp(r'^\s*#\s*atermius:(group|tags)\s+(\S.*?)\s*$');
    final certificateByAlias = <String, ({String value, int line})>{};
    List<String>? currentAliases;

    // Only rewrite lines when the base importer would accept the file size;
    // otherwise let it report the limit itself.
    final rewrite = lines.length <= 4096;
    for (var index = 0; rewrite && index < lines.length; index++) {
      final lineNumber = index + 1;
      final meta = metadata.firstMatch(lines[index]);
      if (meta != null) {
        // Atermius-only comment metadata written by the Atermius exporter.
        final aliases = currentAliases ?? const <String>[];
        final values = meta
            .group(2)!
            .split(meta.group(1) == 'group' ? '/' : ',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList();
        if (values.length <= 16 &&
            values.every(
              (value) =>
                  value.length <= 256 &&
                  !value.contains(RegExp(r'[\u0000-\u001F\u007F]')),
            )) {
          for (final alias in aliases) {
            (meta.group(1) == 'group' ? groupByAlias : tagsByAlias)
                .putIfAbsent(alias, () => values);
          }
        }
        continue;
      }
      final tokens = _tokens(lines[index]);
      if (tokens == null || tokens.isEmpty) continue;
      final directive = tokens.first.toLowerCase();
      if (directive == 'host') {
        currentAliases = tokens.skip(1).map((a) => a.toLowerCase()).toList();
        continue;
      }
      if (directive == 'match') {
        currentAliases = null;
        continue;
      }
      void report(TermiusIssueCode code, Map<String, List<TermiusIssue>> into) {
        final issue = TermiusIssue(
          code,
          line: lineNumber,
          detail: tokens.first,
        );
        final aliases = currentAliases;
        if (aliases == null || aliases.isEmpty) {
          fileIssues.add(issue);
        } else {
          for (final alias in aliases) {
            into.putIfAbsent(alias, () => []).add(issue);
          }
        }
      }

      if (bundle != null &&
          (directive == 'identityfile' || directive == 'certificatefile')) {
        lines[index] = '';
        final into = directive == 'identityfile'
            ? identityByAlias
            : certificateByAlias;
        final aliases = currentAliases;
        if (tokens.length != 2 || aliases == null || aliases.isEmpty) {
          report(TermiusIssueCode.bundleIdentityExtra, optionIssuesByAlias);
          continue;
        }
        for (final alias in aliases) {
          if (into.containsKey(alias)) {
            optionIssuesByAlias
                .putIfAbsent(alias, () => [])
                .add(
                  TermiusIssue(
                    TermiusIssueCode.bundleIdentityExtra,
                    line: lineNumber,
                    detail: tokens.first,
                  ),
                );
          } else {
            into[alias] = (value: tokens[1], line: lineNumber);
          }
        }
        continue;
      }
      if (_ignoredOptions.contains(directive)) {
        report(TermiusIssueCode.sshOptionIgnored, optionIssuesByAlias);
        lines[index] = '';
      } else if (_hostKeyPolicyOptions.contains(directive)) {
        report(TermiusIssueCode.sshHostKeyPolicyIgnored, optionIssuesByAlias);
        lines[index] = '';
      } else if (_forwardOptions.contains(directive)) {
        lines[index] = '';
        final aliases = currentAliases;
        if (aliases == null || aliases.isEmpty) {
          report(TermiusIssueCode.sshForwardBlocked, forwardIssuesByAlias);
          continue;
        }
        for (final alias in aliases) {
          final profile = _forward(directive, tokens.skip(1).toList());
          if (profile == null) {
            forwardIssuesByAlias
                .putIfAbsent(alias, () => [])
                .add(
                  TermiusIssue(
                    TermiusIssueCode.sshForwardBlocked,
                    line: lineNumber,
                    detail: tokens.first,
                  ),
                );
          } else {
            final list = forwardsByAlias.putIfAbsent(alias, () => []);
            if (list.length < maxHostPortForwardProfiles &&
                !list.any((existing) => _sameListener(existing, profile))) {
              list.add(profile);
            } else {
              forwardIssuesByAlias
                  .putIfAbsent(alias, () => [])
                  .add(
                    TermiusIssue(
                      TermiusIssueCode.sshForwardBlocked,
                      line: lineNumber,
                      detail: tokens.first,
                    ),
                  );
            }
          }
        }
      }
    }

    final parsed = OpenSshConfigImporter.parse(lines.join('\n'));
    for (final issue in parsed.issues) {
      fileIssues.add(_fromParserIssue(issue));
    }
    final rows = <TermiusImportRow>[];
    for (var index = 0; index < parsed.hosts.length; index++) {
      final host = parsed.hosts[index];
      final key = host.alias.toLowerCase();
      final issues = <TermiusIssue>[
        for (final issue in host.issues) _fromParserIssue(issue, row: index + 1),
        for (final issue in optionIssuesByAlias[key] ?? const <TermiusIssue>[])
          TermiusIssue(
            issue.code,
            line: issue.line,
            row: index + 1,
            detail: issue.detail,
          ),
        for (final issue in forwardIssuesByAlias[key] ?? const <TermiusIssue>[])
          TermiusIssue(
            issue.code,
            line: issue.line,
            row: index + 1,
            detail: issue.detail,
          ),
      ];
      String? privateKey;
      String? certificate;
      final identity = identityByAlias[key];
      if (bundle != null && identity != null) {
        final text = bundle.read(identity.value);
        if (text == null) {
          issues.add(
            TermiusIssue(
              TermiusIssueCode.bundleKeyMissing,
              line: identity.line,
              row: index + 1,
            ),
          );
        } else if (!isInlinePrivateKeyText(text) ||
            utf8.encode(text).length > maxTermiusPrivateKeyBytes ||
            text.contains('\u0000')) {
          issues.add(
            TermiusIssue(
              TermiusIssueCode.bundleKeyInvalid,
              line: identity.line,
              row: index + 1,
            ),
          );
        } else {
          privateKey = normalizePrivateKeyText(text);
        }
      }
      final certificateRef = certificateByAlias[key];
      if (bundle != null && certificateRef != null) {
        final text = bundle.read(certificateRef.value)?.trim();
        if (text == null || text.length > 16384 || !_certificateLine.hasMatch(text)) {
          issues.add(
            TermiusIssue(
              TermiusIssueCode.bundleCertificateMissing,
              line: certificateRef.line,
              row: index + 1,
            ),
          );
        } else {
          certificate = text;
        }
      }
      rows.add(
        TermiusImportRow(
          row: index + 1,
          line: host.hostLine,
          label: host.alias,
          address: host.address,
          protocol: HostProtocol.ssh,
          port: host.port,
          username: host.username ?? '',
          groupPath: List.unmodifiable(groupByAlias[key] ?? const <String>[]),
          tags: parseHostTags((tagsByAlias[key] ?? const <String>[]).join(',')),
          jumpAlias: host.proxyJumpAlias,
          privateKey: privateKey,
          certificate: certificate,
          forwards: List.unmodifiable(
            forwardsByAlias[key] ?? const <SshPortForwardProfile>[],
          ),
          issues: issues,
        ),
      );
    }
    final blocking = parsed.blocksWholeFile &&
        !fileIssues.any((issue) => issue.blocking);
    return TermiusImportDocument(
      format: TermiusSourceFormat.openSsh,
      headers: const [],
      rows: List.unmodifiable(rows),
      fileIssues: List.unmodifiable([
        ...fileIssues,
        if (blocking)
          const TermiusIssue(
            TermiusIssueCode.sshParserFinding,
            severity: TermiusIssueSeverity.blocking,
            line: 1,
          ),
      ]),
    );
  }

  static TermiusIssue _fromParserIssue(OpenSshConfigIssue issue, {int? row}) =>
      TermiusIssue(
        TermiusIssueCode.sshParserFinding,
        severity: issue.blocking
            ? TermiusIssueSeverity.blocking
            : TermiusIssueSeverity.warning,
        line: issue.line,
        row: row,
        detail: issue.directive,
        messageBuilder: () => issue.message,
      );

  static bool _sameListener(SshPortForwardProfile a, SshPortForwardProfile b) =>
      a.type == b.type &&
      a.bindAddress.toLowerCase() == b.bindAddress.toLowerCase() &&
      a.bindPort == b.bindPort;

  /// Parses `[bind:]port host:hostport` (Local/Remote) or `[bind:]port`
  /// (Dynamic). Returns null for anything that is not loopback-safe; the
  /// forwarding editor requires explicit exposure confirmation for those.
  static SshPortForwardProfile? _forward(String directive, List<String> args) {
    final type = switch (directive) {
      'localforward' => SshPortForwardType.local,
      'remoteforward' => SshPortForwardType.remote,
      _ => SshPortForwardType.dynamic,
    };
    final expected = type == SshPortForwardType.dynamic ? 1 : 2;
    if (args.length != expected) return null;
    final listen = _endpoint(args.first, allowBarePort: true);
    if (listen == null) return null;
    ({String host, int port})? destination;
    if (type != SshPortForwardType.dynamic) {
      destination = _endpoint(args[1], allowBarePort: false);
      if (destination == null) return null;
    }
    final prefix = switch (type) {
      SshPortForwardType.local => 'L',
      SshPortForwardType.remote => 'R',
      SshPortForwardType.dynamic => 'D',
    };
    final profile = SshPortForwardProfile(
      id: _uuid.v4(),
      name: '$prefix ${listen.port}',
      type: type,
      bindAddress: listen.host,
      bindPort: listen.port,
      destinationAddress: destination?.host,
      destinationPort: destination?.port,
    );
    return profile.validate() == null ? profile : null;
  }

  static ({String host, int port})? _endpoint(
    String value, {
    required bool allowBarePort,
  }) {
    String host;
    String portText;
    final bracketed = RegExp(r'^\[([^\]]+)\]:([0-9]{1,5})$').firstMatch(value);
    if (bracketed != null) {
      host = bracketed.group(1)!;
      portText = bracketed.group(2)!;
    } else if (RegExp(r'^[0-9]{1,5}$').hasMatch(value)) {
      if (!allowBarePort) return null;
      host = '127.0.0.1';
      portText = value;
    } else {
      final colon = value.lastIndexOf(':');
      if (colon <= 0 || value.indexOf(':') != colon) return null;
      host = value.substring(0, colon);
      portText = value.substring(colon + 1);
      if (host == '*' ) return null;
    }
    if (!RegExp(r'^[0-9]{1,5}$').hasMatch(portText)) return null;
    final port = int.parse(portText);
    if (port < (allowBarePort ? 0 : 1) || port > 65535) return null;
    if (host.isEmpty ||
        host.length > 253 ||
        host.contains(RegExp(r'[\s\u0000-\u001F\u007F%/]'))) {
      return null;
    }
    if (host.toLowerCase() == 'localhost') host = '127.0.0.1';
    return (host: host, port: port);
  }

  /// Minimal tokenizer mirroring the base importer's quoting rules. Returns
  /// null for lines the base importer will reject (it reports those).
  static List<String>? _tokens(String line) {
    final result = <String>[];
    final token = StringBuffer();
    var quoted = false;
    var hasToken = false;
    for (final rune in line.runes) {
      final character = String.fromCharCode(rune);
      if (character == '"') {
        quoted = !quoted;
        hasToken = true;
        continue;
      }
      if (!quoted && character == '#') break;
      if (!quoted && (character == ' ' || character == '\t')) {
        if (hasToken) {
          result.add(token.toString());
          token.clear();
          hasToken = false;
        }
        continue;
      }
      if (result.isEmpty && !quoted && character == '=' && hasToken) {
        result.add(token.toString());
        token.clear();
        hasToken = false;
        continue;
      }
      token.write(character);
      hasToken = true;
    }
    if (quoted) return null;
    if (hasToken) result.add(token.toString());
    return result;
  }
}
