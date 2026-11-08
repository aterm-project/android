import 'dart:convert';

import 'ansible_inventory_metadata.dart';
import 'host_operating_system.dart';
import '../l10n/l10n.dart';

Map<String, Object?>? _recordManifestFromJson(Map<String, dynamic> json) {
  final raw = json['_manifest'];
  if (raw == null) return null;
  if (raw is! Map) {
    throw const FormatException('Record _manifest must be a JSON object');
  }
  return Map<String, Object?>.from(raw);
}

enum RecordKind {
  host,
  credential,
  group,
  snippet,
  knownHost,
  preference,
  workspace,
  shellHistory,
}

enum AuthKind { password, privateKey }

enum HostProtocol {
  ssh(22, 'SSH'),
  rdp(3389, 'RDP'),
  vnc(5900, 'VNC');

  const HostProtocol(this.defaultPort, this.label);
  final int defaultPort;
  final String label;
  static HostProtocol parse(Object? value) => value == null
      ? HostProtocol.ssh
      : HostProtocol.values.firstWhere(
          (p) => p.name == value,
          orElse: () => throw const FormatException('Unknown Host protocol'),
        );
}

enum SshPortForwardType { local, remote, dynamic }

const int maxHostPortForwardProfiles = 64;

/// A saved SSH forwarding rule (`ssh -L`, `-R` and `-D` semantics).
///
/// Listeners default to loopback. Binding a listener to a non-loopback
/// address, or letting a remote forward reach a non-loopback address from this
/// device, exposes a network path beyond this device and therefore requires
/// the explicit [exposeToNetwork] acknowledgement. The UI asks for a separate
/// confirmation before such a profile is saved and every time it is started.
class SshPortForwardProfile {
  const SshPortForwardProfile({
    required this.id,
    required this.name,
    required this.type,
    required this.bindAddress,
    required this.bindPort,
    this.destinationAddress,
    this.destinationPort,
    this.exposeToNetwork = false,
  });

  final String id;
  final String name;
  final SshPortForwardType type;

  /// Local listener for local/dynamic forwards, remote SSH listener for remote
  /// forwards. Loopback unless [exposeToNetwork] is set.
  final String bindAddress;
  final int bindPort;

  /// Remote endpoint for local forwards, device-side endpoint for remote
  /// forwards. Dynamic SOCKS profiles do not have a fixed destination.
  final String? destinationAddress;
  final int? destinationPort;

  /// Explicit acknowledgement that this profile may expose a listener or a
  /// device-side network path beyond loopback.
  final bool exposeToNetwork;

  /// True when the profile listens on, or connects from this device to, an
  /// address other than loopback.
  bool get exposesBeyondLoopback =>
      !isLoopbackForwardAddress(bindAddress) ||
      (type == SshPortForwardType.remote &&
          destinationAddress != null &&
          !isLoopbackForwardAddress(destinationAddress!));

  String? validate() {
    if (id.trim().isEmpty || id.length > 128) {
      return currentL10n.forwardProfileIdIsInvalid;
    }
    if (name.trim().isEmpty || name.length > 64) {
      return currentL10n.forwardProfileNameMustBe1;
    }
    if (!isValidForwardBindAddress(bindAddress)) {
      return currentL10n.forwardListenerAddressMustBeLocalhost;
    }
    if (!exposeToNetwork && !isLoopbackForwardAddress(bindAddress)) {
      return currentL10n.forwardListenersMustBindToLoopback;
    }
    if (bindPort < 0 || bindPort > 65535) {
      return currentL10n.forwardListenerPortMustBeBetween;
    }
    if (type == SshPortForwardType.dynamic) {
      if (destinationAddress != null || destinationPort != null) {
        return currentL10n.dynamicForwardingDoesNotHaveA;
      }
      return null;
    }
    final destination = destinationAddress;
    if (destination == null ||
        destination.trim().isEmpty ||
        destination != destination.trim() ||
        destination.length > 253 ||
        destination.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
      return currentL10n.forwardDestinationHostIsInvalid;
    }
    final port = destinationPort;
    if (port == null || port < 1 || port > 65535) {
      return currentL10n.forwardDestinationPortMustBeBetween;
    }
    if (type == SshPortForwardType.remote &&
        !exposeToNetwork &&
        !isLoopbackForwardAddress(destination)) {
      return currentL10n.remoteForwardingTargetsMustUseThis;
    }
    return null;
  }

  SshPortForwardProfile copyWith({
    String? name,
    SshPortForwardType? type,
    String? bindAddress,
    int? bindPort,
    String? destinationAddress,
    int? destinationPort,
    bool clearDestination = false,
    bool? exposeToNetwork,
  }) => SshPortForwardProfile(
    id: id,
    name: name ?? this.name,
    type: type ?? this.type,
    bindAddress: bindAddress ?? this.bindAddress,
    bindPort: bindPort ?? this.bindPort,
    destinationAddress: clearDestination
        ? null
        : destinationAddress ?? this.destinationAddress,
    destinationPort: clearDestination
        ? null
        : destinationPort ?? this.destinationPort,
    exposeToNetwork: exposeToNetwork ?? this.exposeToNetwork,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'bind_address': bindAddress,
    'bind_port': bindPort,
    if (destinationAddress != null) 'destination_address': destinationAddress,
    if (destinationPort != null) 'destination_port': destinationPort,
    // Omitted when false so loopback-only profiles keep their exact pre-
    // existing encrypted JSON shape.
    if (exposeToNetwork) 'expose_to_network': true,
  };

  factory SshPortForwardProfile.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    final type = SshPortForwardType.values.firstWhere(
      (value) => value.name == rawType,
      orElse: () =>
          throw const FormatException('Unknown SSH port forwarding type'),
    );
    final rawExpose = json['expose_to_network'];
    if (rawExpose != null && rawExpose is! bool) {
      throw const FormatException('Forward network exposure flag is invalid');
    }
    final profile = SshPortForwardProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: type,
      bindAddress: json['bind_address'] as String? ?? '127.0.0.1',
      bindPort: (json['bind_port'] as num?)?.toInt() ?? 0,
      destinationAddress: json['destination_address'] as String?,
      destinationPort: (json['destination_port'] as num?)?.toInt(),
      exposeToNetwork: rawExpose == true,
    );
    final issue = profile.validate();
    if (issue != null) throw FormatException(issue);
    return profile;
  }

  @override
  bool operator ==(Object other) =>
      other is SshPortForwardProfile &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.bindAddress == bindAddress &&
      other.bindPort == bindPort &&
      other.destinationAddress == destinationAddress &&
      other.destinationPort == destinationPort &&
      other.exposeToNetwork == exposeToNetwork;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    bindAddress,
    bindPort,
    destinationAddress,
    destinationPort,
    exposeToNetwork,
  );
}

List<int>? _parseForwardIp(String value) {
  try {
    return Uri.parseIPv4Address(value);
  } on FormatException {
    // Not IPv4; try IPv6 below.
  }
  if (!value.contains(':') || value.contains('%')) return null;
  try {
    return Uri.parseIPv6Address(value);
  } on FormatException {
    return null;
  }
}

/// Accepts `localhost` and IPv4/IPv6 literals. Host names are rejected so a
/// listener never depends on DNS resolution at start time.
bool isValidForwardBindAddress(String value) =>
    value.toLowerCase() == 'localhost' || _parseForwardIp(value) != null;

/// `localhost`, 127.0.0.0/8, `::1` and IPv4-mapped loopback.
bool isLoopbackForwardAddress(String value) {
  if (value.toLowerCase() == 'localhost') return true;
  final bytes = _parseForwardIp(value);
  if (bytes == null) return false;
  if (bytes.length == 4) return bytes[0] == 127;
  final isV6Loopback =
      bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  final isMappedV4Loopback =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff &&
      bytes[12] == 127;
  return isV6Loopback || isMappedV4Loopback;
}

/// `0.0.0.0` / `::` listen on every interface of their family.
bool isWildcardForwardAddress(String value) {
  final bytes = _parseForwardIp(value);
  return bytes != null && bytes.every((byte) => byte == 0);
}

Set<String> _forwardListenerAddresses(String value) {
  if (value.toLowerCase() == 'localhost') return const {'127.0.0.1', '::1'};
  final bytes = _parseForwardIp(value);
  if (bytes == null) return {value.toLowerCase()};
  return {
    bytes.length == 4
        ? bytes.join('.')
        : bytes.map((byte) => byte.toRadixString(16)).join(':'),
  };
}

/// Whether two profiles would try to own the same listener on the same side
/// (device or SSH server). This is stricter than the persisted uniqueness
/// check: wildcard listeners and `localhost` (both loopback families) also
/// conflict. Used before saving new edits and before starting a listener.
bool sshPortForwardListenersConflict(
  SshPortForwardProfile a,
  SshPortForwardProfile b,
) {
  if (a.bindPort == 0 || b.bindPort == 0 || a.bindPort != b.bindPort) {
    return false;
  }
  if ((a.type == SshPortForwardType.remote) !=
      (b.type == SshPortForwardType.remote)) {
    return false;
  }
  if (isWildcardForwardAddress(a.bindAddress) ||
      isWildcardForwardAddress(b.bindAddress)) {
    return true;
  }
  return _forwardListenerAddresses(
    a.bindAddress,
  ).intersection(_forwardListenerAddresses(b.bindAddress)).isNotEmpty;
}

/// Maximum number of SSH Jump Hosts allowed before the final target.
const int maxJumpHostHops = 8;

/// Parses the comma-separated tags field while trimming whitespace and
/// dropping empty or case-insensitive duplicate labels.
List<String> parseHostTags(String input) {
  final seen = <String>{};
  return input
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty && seen.add(tag.toLowerCase()))
      .toList(growable: false);
}

/// Authentication saved inside the Host's encrypted record. Legacy shared
/// Credential references remain readable, but creating a Host needs no keychain.
class HostLogin {
  const HostLogin({
    required this.kind,
    this.password,
    this.privateKey,
    this.passphrase,
  });

  final AuthKind kind;
  final String? password;
  final String? privateKey;
  final String? passphrase;

  String? validate() {
    bool valid(String? value, int limit, {bool empty = false}) =>
        value != null &&
        (empty || value.isNotEmpty) &&
        !value.contains('\u0000') &&
        utf8.encode(value).length <= limit;
    if (kind == AuthKind.password) {
      if (!valid(password, 65536) || privateKey != null || passphrase != null) {
        return currentL10n.enterAValidSshPassword;
      }
    } else if (!valid(privateKey, 262144) ||
        password != null ||
        (passphrase != null && !valid(passphrase, 16384, empty: true))) {
      return currentL10n.enterAValidSshPrivateKey;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (kind == AuthKind.password) 'password': password,
    if (kind == AuthKind.privateKey) 'private_key': privateKey,
    if (kind == AuthKind.privateKey && passphrase != null)
      'passphrase': passphrase,
  };

  factory HostLogin.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !const {
            'kind',
            'password',
            'private_key',
            'passphrase',
          }.contains(key),
        ) ||
        !AuthKind.values.any((kind) => kind.name == value['kind']) ||
        const [
          'password',
          'private_key',
          'passphrase',
        ].any((key) => value[key] != null && value[key] is! String)) {
      throw const FormatException('Host login fields are invalid.');
    }
    final login = HostLogin(
      kind: AuthKind.values.byName(value['kind'] as String),
      password: value['password'] as String?,
      privateKey: value['private_key'] as String?,
      passphrase: value['passphrase'] as String?,
    );
    if (login.validate() != null) {
      throw const FormatException('Host login fields are invalid.');
    }
    return login;
  }

  CredentialRecord forHost(HostRecord host) => CredentialRecord(
    id: host.id,
    name: host.name,
    username: host.username,
    kind: kind,
    secret: password,
    privateKey: privateKey,
    passphrase: passphrase,
  );

  @override
  bool operator ==(Object other) =>
      other is HostLogin &&
      kind == other.kind &&
      password == other.password &&
      privateKey == other.privateKey &&
      passphrase == other.passphrase;

  @override
  int get hashCode => Object.hash(kind, password, privateKey, passphrase);
}

class HostRecord {
  const HostRecord({
    required this.id,
    required this.name,
    required this.address,
    int? port,
    this.protocol = HostProtocol.ssh,
    this.rdpCertificateSha256,
    this.username = '',
    this.groupId,
    this.credentialId,
    this.login,
    this.jumpHostId,
    this.authKind = AuthKind.password,
    this.color = 0,
    this.tags = const [],
    this.portForwardProfiles = const [],
    this.isFavorite = false,
    this.lastConnected,
    this.revisionId,
    this.baseRevisionId,
    this.online = false,
    this.manifest,
  }) : port =
           port ??
           (protocol == HostProtocol.rdp
               ? 3389
               : protocol == HostProtocol.vnc
               ? 5900
               : 22);

  final String id;
  final String name;
  final String address;
  final int port;
  final HostProtocol protocol;
  final String? rdpCertificateSha256;
  final String username;
  final String? groupId;
  final String? credentialId;
  final HostLogin? login;

  /// Optional ID of the next Host used to reach this Host over SSH.
  /// References form a bounded, acyclic chain of at most [maxJumpHostHops].
  final String? jumpHostId;
  final AuthKind authKind;
  final int color;
  final List<String> tags;
  final List<SshPortForwardProfile> portForwardProfiles;
  final bool isFavorite;
  final DateTime? lastConnected;
  final String? revisionId;
  final String? baseRevisionId;
  final bool online;
  final Map<String, Object?>? manifest;

  AnsibleInventoryImportMetadata? get ansibleInventoryImport =>
      readAnsibleInventoryMetadata(manifest);

  String get _operatingSystemEndpoint =>
      jsonEncode([protocol.name, address, port, username, jumpHostId]);

  HostOperatingSystem? get detectedOperatingSystem {
    final metadata = manifest?[hostOperatingSystemManifestKey];
    if (metadata is! Map || metadata['endpoint'] != _operatingSystemEndpoint) {
      return null;
    }
    return HostOperatingSystem.read(manifest);
  }

  HostRecord copyWithDetectedOperatingSystem(HostOperatingSystem system) =>
      copyWith(
        manifest: {
          ...?manifest,
          hostOperatingSystemManifestKey: {
            ...system.toJson(),
            'endpoint': _operatingSystemEndpoint,
          },
        },
      );

  String get endpoint => '$address:$port';

  String? validate() {
    if (rdpCertificateSha256 != null &&
        (protocol != HostProtocol.rdp ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(rdpCertificateSha256!)))
      {
return currentL10n.rdpCertificateFingerprintMustContain64;
}
    if (name.trim().isEmpty) return currentL10n.hostNameIsRequired;
    if (address.trim().isEmpty) return currentL10n.hostAddressIsRequired;
    if (port < 1 || port > 65535) return currentL10n.portMustBeBetween1And;
    if (protocol == HostProtocol.ssh && username.trim().isEmpty)
      {
return currentL10n.usernameIsRequired;
}
    if (protocol != HostProtocol.ssh &&
        (jumpHostId != null ||
            portForwardProfiles.isNotEmpty ||
            authKind != AuthKind.password ||
            credentialId != null)) {
      return currentL10n.remoteDesktopsUsePasswordLoginWithout;
    }
    if (login != null) {
      final issue = login!.validate();
      if (issue != null) return issue;
      if (credentialId != null || authKind != login!.kind) {
        return currentL10n.hostLoginAndAuthenticationSettingsDo;
      }
    }
    if (portForwardProfiles.length > maxHostPortForwardProfiles) {
      return currentL10n.aHostCanHaveAtMost2(maxHostPortForwardProfiles);
    }
    final profileIds = <String>{};
    final listeners = <String>{};
    for (final profile in portForwardProfiles) {
      final issue = profile.validate();
      if (issue != null) return issue;
      if (!profileIds.add(profile.id)) {
        return currentL10n.forwardProfileIdsMustBeUnique;
      }
      if (profile.bindPort != 0) {
        final address = _normalizedForwardBindAddress(profile.bindAddress);
        final side = profile.type == SshPortForwardType.remote
            ? 'remote'
            : 'device';
        if (!listeners.add('$side|$address|${profile.bindPort}')) {
          return currentL10n.forwardListenerAddressAndPortMust;
        }
      }
    }
    return null;
  }

  HostRecord copyWith({
    String? name,
    String? address,
    int? port,
    HostProtocol? protocol,
    String? rdpCertificateSha256,
    bool clearRdpCertificate = false,
    String? username,
    String? groupId,
    bool clearGroup = false,
    String? credentialId,
    bool clearCredential = false,
    HostLogin? login,
    bool clearLogin = false,
    String? jumpHostId,
    bool clearJumpHost = false,
    AuthKind? authKind,
    int? color,
    List<String>? tags,
    List<SshPortForwardProfile>? portForwardProfiles,
    bool? isFavorite,
    DateTime? lastConnected,
    String? revisionId,
    String? baseRevisionId,
    bool? online,
    Map<String, Object?>? manifest,
    bool clearManifest = false,
  }) => HostRecord(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    port: port ?? this.port,
    protocol: protocol ?? this.protocol,
    rdpCertificateSha256: clearRdpCertificate
        ? null
        : rdpCertificateSha256 ?? this.rdpCertificateSha256,
    username: username ?? this.username,
    groupId: clearGroup ? null : groupId ?? this.groupId,
    credentialId: clearCredential ? null : credentialId ?? this.credentialId,
    login: clearLogin ? null : login ?? this.login,
    jumpHostId: clearJumpHost ? null : jumpHostId ?? this.jumpHostId,
    authKind: authKind ?? login?.kind ?? this.authKind,
    color: color ?? this.color,
    tags: tags ?? this.tags,
    portForwardProfiles: portForwardProfiles ?? this.portForwardProfiles,
    isFavorite: isFavorite ?? this.isFavorite,
    lastConnected: lastConnected ?? this.lastConnected,
    revisionId: revisionId ?? this.revisionId,
    baseRevisionId: baseRevisionId ?? this.baseRevisionId,
    online: online ?? this.online,
    manifest: clearManifest ? null : manifest ?? this.manifest,
  );

  HostRecord copyWithAnsibleInventoryImport(
    AnsibleInventoryImportMetadata? metadata,
  ) {
    final nextManifest = writeAnsibleInventoryMetadata(manifest, metadata);
    return copyWith(
      manifest: nextManifest,
      clearManifest: nextManifest == null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.host.name,
    'name': name,
    'address': address,
    'port': port,
    if (protocol != HostProtocol.ssh) 'protocol': protocol.name,
    if (rdpCertificateSha256 != null) 'rdp_cert_sha256': rdpCertificateSha256,
    'username': username,
    'group_id': groupId,
    'credential_id': credentialId,
    if (login != null) 'login': login!.toJson(),
    'jump_host_id': jumpHostId,
    'auth_kind': authKind.name,
    'color': color,
    'tags': tags,
    if (portForwardProfiles.isNotEmpty)
      'port_forward_profiles': portForwardProfiles
          .map((profile) => profile.toJson())
          .toList(growable: false),
    'is_favorite': isFavorite,
    if (manifest != null) '_manifest': manifest,
  };

  factory HostRecord.fromJson(Map<String, dynamic> json) {
    final manifest = _recordManifestFromJson(json);
    readAnsibleInventoryMetadata(manifest);
    return HostRecord(
      id: json['id'] as String,
      name: json['name'] as String? ?? currentL10n.unnamedHost,
      address: json['address'] as String? ?? '',
      port:
          (json['port'] as num?)?.toInt() ??
          HostProtocol.parse(json['protocol']).defaultPort,
      protocol: HostProtocol.parse(json['protocol']),
      rdpCertificateSha256: json['rdp_cert_sha256'] as String?,
      username: json['username'] as String? ?? '',
      groupId: json['group_id'] as String?,
      credentialId: json['credential_id'] as String?,
      login: json.containsKey('login')
          ? HostLogin.fromJson(json['login'])
          : null,
      jumpHostId: json['jump_host_id'] as String?,
      authKind: AuthKind.values.firstWhere(
        (v) => v.name == json['auth_kind'],
        orElse: () => AuthKind.password,
      ),
      color: (json['color'] as num?)?.toInt() ?? 0,
      tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
      portForwardProfiles: _portForwardProfilesFromJson(
        json['port_forward_profiles'],
      ),
      isFavorite: json['is_favorite'] as bool? ?? false,
      revisionId: json['revision_id'] as String?,
      manifest: manifest,
    );
  }

  static const demo = [
    HostRecord(
      id: 'demo-edge-01',
      name: 'Production · Edge 01',
      address: 'edge-01.example.net',
      username: 'deploy',
      groupId: 'production',
      color: 0,
      tags: ['production', 'api'],
      isFavorite: true,
      online: true,
    ),
    HostRecord(
      id: 'demo-db-01',
      name: 'Primary database',
      address: '10.14.0.8',
      username: 'admin',
      groupId: 'production',
      color: 1,
      tags: ['production', 'database'],
    ),
    HostRecord(
      id: 'demo-staging',
      name: 'Staging cluster',
      address: 'staging-01.example.net',
      username: 'ubuntu',
      groupId: 'staging',
      color: 2,
      tags: ['staging'],
      lastConnected: null,
    ),
    HostRecord(
      id: 'demo-nas',
      name: 'Home lab NAS',
      address: '192.168.1.20',
      username: 'alex',
      groupId: 'homelab',
      color: 3,
      tags: ['homelab', 'storage'],
    ),
  ];
}

List<SshPortForwardProfile> _portForwardProfilesFromJson(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > maxHostPortForwardProfiles) {
    throw const FormatException('Host port forward profiles are invalid');
  }
  final profiles = raw
      .map((entry) {
        if (entry is! Map) {
          throw const FormatException('Host port forward profile is invalid');
        }
        return SshPortForwardProfile.fromJson(Map<String, dynamic>.from(entry));
      })
      .toList(growable: false);
  if (profiles.map((profile) => profile.id).toSet().length != profiles.length) {
    throw const FormatException('Host port forward profile IDs are duplicated');
  }
  final listeners = <String>{};
  for (final profile in profiles) {
    if (profile.bindPort == 0) continue;
    final address = _normalizedForwardBindAddress(profile.bindAddress);
    final side = profile.type == SshPortForwardType.remote
        ? 'remote'
        : 'device';
    if (!listeners.add('$side|$address|${profile.bindPort}')) {
      throw const FormatException('Host port forward listeners are duplicated');
    }
  }
  return profiles;
}

String _normalizedForwardBindAddress(String address) {
  final normalized = address.toLowerCase();
  return normalized == 'localhost' ? '127.0.0.1' : normalized;
}

class CredentialRecord {
  const CredentialRecord({
    required this.id,
    required this.name,
    required this.username,
    this.kind = AuthKind.password,
    this.secret,
    this.privateKey,
    this.passphrase,
    this.fingerprint,
    this.certificate,
    this.revisionId,
    this.manifest,
  });

  final String id;
  final String name;
  final String username;
  final AuthKind kind;
  final String? secret;
  final String? privateKey;
  final String? passphrase;
  final String? fingerprint;

  /// Optional OpenSSH user certificate (`*-cert.pub` line) bound to
  /// [privateKey]. Public data, but treated as a credential field for merge
  /// review because it changes which identity authenticates.
  final String? certificate;
  final String? revisionId;
  final Map<String, Object?>? manifest;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.credential.name,
    'name': name,
    'username': username,
    'kind': kind.name,
    if (secret != null) 'secret': secret,
    if (privateKey != null) 'private_key': privateKey,
    if (passphrase != null) 'passphrase': passphrase,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (certificate != null) 'certificate': certificate,
    if (manifest != null) '_manifest': manifest,
  };

  factory CredentialRecord.fromJson(Map<String, dynamic> json) =>
      CredentialRecord(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Credential',
        username: json['username'] as String? ?? '',
        kind: AuthKind.values.firstWhere(
          (value) => value.name == json['kind'],
          orElse: () => AuthKind.password,
        ),
        secret: json['secret'] as String?,
        privateKey: json['private_key'] as String?,
        passphrase: json['passphrase'] as String?,
        fingerprint: json['fingerprint'] as String?,
        certificate: json['certificate'] as String?,
        manifest: _recordManifestFromJson(json),
      );
}

class SnippetRecord {
  const SnippetRecord({
    required this.id,
    required this.title,
    required this.body,
    this.shell = 'bash',
    this.executionMode = SnippetExecutionMode.script,
    this.program = '',
    this.arguments = const [],
    this.parameters = const [],
    this.tags = const [],
    this.revisionId,
    this.manifest,
  });

  final String id;
  final String title;
  final String body;
  final String shell;
  final SnippetExecutionMode executionMode;
  final String program;
  final List<SnippetArgument> arguments;
  final List<SnippetParameter> parameters;
  final List<String> tags;
  final String? revisionId;
  final Map<String, Object?>? manifest;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.snippet.name,
    'title': title,
    'body': body,
    'shell_kind': shell,
    if (executionMode != SnippetExecutionMode.script) ...{
      'execution_mode': executionMode.name,
      'program': program,
      'arguments': arguments.map((argument) => argument.toJson()).toList(),
      'parameters': parameters.map((parameter) => parameter.toJson()).toList(),
    },
    'tags': tags,
    if (manifest != null) '_manifest': manifest,
  };

  factory SnippetRecord.fromJson(Map<String, dynamic> json) {
    final rawMode = json['execution_mode'] as String?;
    final mode = SnippetExecutionMode.values.firstWhere(
      (value) => value.name == (rawMode ?? 'script'),
      orElse: () =>
          throw FormatException('Unknown snippet execution mode: $rawMode'),
    );
    final rawArguments = json['arguments'];
    final rawParameters = json['parameters'];
    if (rawArguments != null && rawArguments is! List) {
      throw const FormatException('Snippet arguments must be a JSON array');
    }
    if (rawParameters != null && rawParameters is! List) {
      throw const FormatException('Snippet parameters must be a JSON array');
    }
    return SnippetRecord(
      id: json['id'] as String,
      title: json['title'] as String? ?? currentL10n.untitledSnippet,
      body: json['body'] as String? ?? '',
      shell: json['shell_kind'] as String? ?? 'bash',
      executionMode: mode,
      program: json['program'] as String? ?? '',
      arguments: (rawArguments as List<dynamic>? ?? const [])
          .map((value) => SnippetArgument.fromJson(value))
          .toList(growable: false),
      parameters: (rawParameters as List<dynamic>? ?? const [])
          .map((value) => SnippetParameter.fromJson(value))
          .toList(growable: false),
      tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
      manifest: _recordManifestFromJson(json),
    );
  }
}

enum SnippetExecutionMode { script, bashCommand }

enum SnippetParameterType { text, credentialSecret }

class SnippetParameter {
  const SnippetParameter.text({required this.name, this.defaultValue})
    : type = SnippetParameterType.text,
      credentialId = null;

  const SnippetParameter.credential({
    required this.name,
    required this.credentialId,
  }) : type = SnippetParameterType.credentialSecret,
       defaultValue = null;

  final String name;
  final SnippetParameterType type;
  final String? defaultValue;
  final String? credentialId;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type.name,
    if (defaultValue != null) 'default': defaultValue,
    if (credentialId != null) 'credential_id': credentialId,
  };

  factory SnippetParameter.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Snippet parameter must be a JSON object');
    }
    final json = Map<String, dynamic>.from(value);
    final name = json['name'];
    final type = json['type'];
    if (name is! String || type is! String) {
      throw const FormatException('Snippet parameter requires name and type');
    }
    return switch (type) {
      'text' => SnippetParameter._parseTextSnippetParameter(json, name),
      'credentialSecret' => SnippetParameter._parseCredentialSnippetParameter(
        json,
        name,
      ),
      _ => throw FormatException('Unknown snippet parameter type: $type'),
    };
  }

  static SnippetParameter _parseTextSnippetParameter(
    Map<String, dynamic> json,
    String name,
  ) {
    _requireSnippetKeys(json, const {'name', 'type', 'default'});
    if (json.containsKey('credential_id')) {
      throw const FormatException(
        'Text parameters cannot reference Credentials',
      );
    }
    return SnippetParameter.text(
      name: name,
      defaultValue: json['default'] as String?,
    );
  }

  static SnippetParameter _parseCredentialSnippetParameter(
    Map<String, dynamic> json,
    String name,
  ) {
    _requireSnippetKeys(json, const {'name', 'type', 'credential_id'});
    if (json.containsKey('default')) {
      throw const FormatException('Credential parameters cannot have defaults');
    }
    final credentialId = json['credential_id'];
    if (credentialId is! String || credentialId.isEmpty) {
      throw const FormatException(
        'Credential parameter requires credential_id',
      );
    }
    return SnippetParameter.credential(name: name, credentialId: credentialId);
  }
}

class SnippetArgument {
  const SnippetArgument.literal(this.value) : parameter = null;
  const SnippetArgument.reference(this.parameter) : value = null;

  final String? value;
  final String? parameter;

  Map<String, Object?> toJson() => parameter == null
      ? {'kind': 'literal', 'value': value}
      : {'kind': 'parameter', 'name': parameter};

  factory SnippetArgument.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Snippet argument must be a JSON object');
    }
    final json = Map<String, dynamic>.from(value);
    return switch (json['kind']) {
      'literal' when json['value'] is String =>
        SnippetArgument._parseLiteralSnippetArgument(json),
      'parameter' when json['name'] is String =>
        SnippetArgument._parseReferenceSnippetArgument(json),
      _ => throw const FormatException('Invalid snippet argument object'),
    };
  }

  static SnippetArgument _parseLiteralSnippetArgument(
    Map<String, dynamic> json,
  ) {
    _requireSnippetKeys(json, const {'kind', 'value'});
    return SnippetArgument.literal(json['value'] as String);
  }

  static SnippetArgument _parseReferenceSnippetArgument(
    Map<String, dynamic> json,
  ) {
    _requireSnippetKeys(json, const {'kind', 'name'});
    return SnippetArgument.reference(json['name'] as String);
  }
}

void _requireSnippetKeys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException(
      'Snippet definition contains unsupported fields',
    );
  }
}

class GroupRecord {
  const GroupRecord({
    required this.id,
    required this.name,
    this.color = 0,
    this.parentId,
    this.defaultCredentialId,
    this.manifest,
  });

  final String id;
  final String name;
  final int color;
  final String? parentId;
  final String? defaultCredentialId;
  final Map<String, Object?>? manifest;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.group.name,
    'name': name,
    'color': color,
    'parent_id': parentId,
    if (defaultCredentialId != null)
      'default_credential_id': defaultCredentialId,
    if (manifest != null) '_manifest': manifest,
  };

  factory GroupRecord.fromJson(Map<String, dynamic> json) {
    const payloadKeys = {
      'id',
      'type',
      'name',
      'color',
      'parent_id',
      'default_credential_id',
      '_record_id',
      '_revision_id',
      '_manifest',
    };
    if (json.keys.any((key) => !payloadKeys.contains(key)) ||
        !json.keys.toSet().containsAll(const {
          'id',
          'type',
          'name',
          'color',
          'parent_id',
        })) {
      throw const FormatException('Group record has an invalid field set.');
    }

    final id = json['id'];
    final type = json['type'];
    final name = json['name'];
    final color = json['color'];
    final parentId = json['parent_id'];
    final defaultCredentialId = json['default_credential_id'];
    final recordId = json['_record_id'];
    final revisionId = json['_revision_id'];
    if (id is! String || !_isCanonicalGroupUuid(id)) {
      throw const FormatException('Group id must be a canonical UUID.');
    }
    if (type != RecordKind.group.name) {
      throw const FormatException('Group record type is invalid.');
    }
    if (json.containsKey('_record_id') &&
        (recordId is! String ||
            !_isCanonicalGroupUuid(recordId) ||
            recordId != id)) {
      throw const FormatException('Group repository record id is invalid.');
    }
    if (json.containsKey('_revision_id') &&
        (revisionId is! String || !_isCanonicalGroupUuid(revisionId))) {
      throw const FormatException('Group revision id is invalid.');
    }
    if (name is! String ||
        name.trim().isEmpty ||
        utf8.encode(name.trim()).length > 256 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
      throw const FormatException('Group name is invalid.');
    }
    if (color is! int || color < 0 || color > 0x7fffffff) {
      throw const FormatException('Group color is invalid.');
    }
    if (parentId != null &&
        (parentId is! String || !_isCanonicalGroupUuid(parentId))) {
      throw const FormatException('Group parent id is invalid.');
    }
    if (defaultCredentialId != null &&
        (defaultCredentialId is! String ||
            !_isCanonicalGroupUuid(defaultCredentialId))) {
      throw const FormatException('Group default credential id is invalid.');
    }
    Map<String, Object?>? manifest;
    if (json.containsKey('_manifest')) {
      final rawManifest = json['_manifest'];
      if (rawManifest == null) {
        manifest = null;
      } else if (rawManifest is! Map ||
          rawManifest.keys.any((key) => key is! String)) {
        throw const FormatException('Group manifest must be a JSON object.');
      } else {
        manifest = Map<String, Object?>.from(rawManifest);
      }
    }
    return GroupRecord(
      id: id,
      name: name,
      color: color,
      parentId: parentId as String?,
      defaultCredentialId: defaultCredentialId as String?,
      manifest: manifest,
    );
  }
}

final _canonicalGroupUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

bool _isCanonicalGroupUuid(String value) => _canonicalGroupUuid.hasMatch(value);

/// Canonical comparison key for sibling Group names.
///
/// Group names are case-insensitive within one parent and ignore surrounding
/// whitespace. The stored display name itself is trimmed when it is saved.
String normalizeGroupName(String name) => name.trim().toLowerCase();

String encodeRecord(Object record) {
  return jsonEncode(switch (record) {
    HostRecord value => value.toJson(),
    CredentialRecord value => value.toJson(),
    SnippetRecord value => value.toJson(),
    GroupRecord value => value.toJson(),
    _ => throw ArgumentError.value(record, 'record', 'Unsupported record type'),
  });
}
