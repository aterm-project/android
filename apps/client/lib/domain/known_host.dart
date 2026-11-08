import 'dart:convert';

import 'package:uuid/uuid.dart';

/// The origin of an explicit decision to trust a host key.
enum KnownHostApprovalSource {
  interactiveConfirmation('interactive_confirmation'),
  outOfBandFingerprint('out_of_band_fingerprint'),
  knownHostsImport('known_hosts_import');

  const KnownHostApprovalSource(this.wireValue);

  final String wireValue;

  static KnownHostApprovalSource parse(Object? value) {
    for (final source in values) {
      if (source.wireValue == value) return source;
    }
    throw const FormatException('Unknown KnownHost approval source');
  }
}

enum KnownHostState {
  trusted('trusted'),
  revoked('revoked');

  const KnownHostState(this.wireValue);

  final String wireValue;

  static KnownHostState parse(Object? value) {
    for (final state in values) {
      if (state.wireValue == value) return state;
    }
    throw const FormatException('Unknown KnownHost state');
  }
}

/// An exact revoked KnownHost head that was visible when a later approval was
/// made. The reference is encrypted with that approval and binds its intent to
/// the revision that the user reviewed, without relying on device clocks.
final class KnownHostRevocationReference {
  const KnownHostRevocationReference({
    required this.recordId,
    required this.revisionId,
  });

  factory KnownHostRevocationReference.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.toSet().length != 2 ||
        !value.keys.toSet().containsAll(const {'record_id', 'revision_id'})) {
      throw const FormatException(
        'KnownHost observed revocation reference is malformed',
      );
    }
    final recordId = _string(value['record_id'], 'record_id');
    final revisionId = _string(value['revision_id'], 'revision_id');
    _validateUuidV4(recordId, 'observed_revocations.record_id');
    _validateUuidV4(revisionId, 'observed_revocations.revision_id');
    return KnownHostRevocationReference(
      recordId: recordId,
      revisionId: revisionId,
    );
  }

  final String recordId;
  final String revisionId;

  Map<String, Object?> toJson() => {
    'record_id': recordId,
    'revision_id': revisionId,
  };

  String get sortKey => '$recordId:$revisionId';

  @override
  bool operator ==(Object other) =>
      other is KnownHostRevocationReference &&
      other.recordId == recordId &&
      other.revisionId == revisionId;

  @override
  int get hashCode => Object.hash(recordId, revisionId);
}

const int maxKnownHostObservedRevocations = 256;

/// An approved SSH host key stored as an encrypted Vault record.
///
/// `host` is always persisted in canonical form. DNS names are ASCII DNS
/// labels (internationalized names must already be IDNA ASCII/punycode), IPv4
/// is strict dotted decimal, and IPv6 is normalized to RFC 5952 style. A zone
/// identifier is rejected because it is local-interface state and cannot be
/// shared consistently between devices.
class KnownHostRecord {
  KnownHostRecord._({
    required this.id,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.state,
    required this.approvalSource,
    required this.approvedByDeviceId,
    required this.approvedAt,
    required this.revokedByDeviceId,
    required this.revokedAt,
    required this.schemaVersion,
    required this.observedRevocations,
    required this.revisionId,
    required this.manifest,
  });

  /// Creates a new trust record after the caller has obtained explicit
  /// approval. Each record gets its own random UUIDv4; endpoint slots are not
  /// derived from hostnames and records are never replaced implicitly.
  factory KnownHostRecord.approve({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
    required KnownHostApprovalSource approvalSource,
    required String approvedByDeviceId,
    required DateTime approvedAt,
    List<KnownHostRevocationReference> observedRevocations = const [],
  }) {
    _validatePort(port);
    _validateAlgorithm(algorithm);
    _validateFingerprint(fingerprint);
    _validateUuidV4(approvedByDeviceId, 'approved_by_device_id');
    _validateUtcDateTime(approvedAt, 'approved_at');
    final sortedObservedRevocations = [...observedRevocations]
      ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    _validateObservedRevocations(sortedObservedRevocations);
    return KnownHostRecord._(
      id: const Uuid().v4(),
      host: canonicalizeKnownHost(host),
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
      state: KnownHostState.trusted,
      approvalSource: approvalSource,
      approvedByDeviceId: approvedByDeviceId,
      approvedAt: approvedAt,
      revokedByDeviceId: null,
      revokedAt: null,
      schemaVersion: sortedObservedRevocations.isEmpty ? 1 : 2,
      observedRevocations: List.unmodifiable(sortedObservedRevocations),
      revisionId: null,
      manifest: null,
    );
  }

  /// Decodes the strict encrypted-record payload.
  ///
  /// The three underscore-prefixed keys are client repository metadata, not
  /// part of the trust decision. They are accepted so callers can pass a row
  /// returned by `loadRecords()` directly; `_record_id` must still agree with
  /// the payload ID.
  factory KnownHostRecord.fromJson(Map<String, dynamic> json) {
    const required = {
      'id',
      'type',
      'host',
      'port',
      'algorithm',
      'fingerprint',
      'state',
      'approval_source',
      'approved_by_device_id',
      'approved_at',
      'revoked_by_device_id',
      'revoked_at',
    };
    const optional = {
      '_record_id',
      '_revision_id',
      '_manifest',
      'schema_version',
      'observed_revocations',
    };
    final keys = json.keys.toSet();
    if (!keys.containsAll(required) ||
        keys.any((key) => !required.contains(key) && !optional.contains(key))) {
      throw const FormatException(
        'KnownHost record fields are incomplete or unknown',
      );
    }
    if (json['type'] != 'knownHost') {
      throw const FormatException('Record type must be knownHost');
    }

    final id = _string(json['id'], 'id');
    _validateUuidV4(id, 'id');
    final repositoryId = json['_record_id'];
    if (repositoryId != null && (_string(repositoryId, '_record_id') != id)) {
      throw const FormatException(
        'KnownHost payload ID does not match record ID',
      );
    }

    final rawHost = _string(json['host'], 'host');
    final host = canonicalizeKnownHost(rawHost);
    if (host != rawHost) {
      throw const FormatException('KnownHost host is not canonical');
    }

    final port = json['port'];
    if (port is! int) {
      throw const FormatException('KnownHost port must be an integer');
    }
    _validatePort(port);

    final algorithm = _string(json['algorithm'], 'algorithm');
    _validateAlgorithm(algorithm);
    final fingerprint = _string(json['fingerprint'], 'fingerprint');
    _validateFingerprint(fingerprint);
    final state = KnownHostState.parse(json['state']);

    final approvalSource = KnownHostApprovalSource.parse(
      json['approval_source'],
    );
    final approvedByDeviceId = _string(
      json['approved_by_device_id'],
      'approved_by_device_id',
    );
    _validateUuidV4(approvedByDeviceId, 'approved_by_device_id');
    final approvedAt = _parseUtcTimestamp(json['approved_at'], 'approved_at');

    final schemaVersionRaw = json['schema_version'];
    final int schemaVersion;
    final List<KnownHostRevocationReference> observedRevocations;
    if (!json.containsKey('schema_version') &&
        !json.containsKey('observed_revocations')) {
      schemaVersion = 1;
      observedRevocations = const [];
    } else if (schemaVersionRaw is int && schemaVersionRaw == 2) {
      schemaVersion = 2;
      final rawObserved = json['observed_revocations'];
      if (rawObserved is! List || rawObserved.isEmpty) {
        throw const FormatException(
          'Version 2 KnownHost approvals require observed revocations',
        );
      }
      observedRevocations = List<KnownHostRevocationReference>.unmodifiable(
        rawObserved.map(KnownHostRevocationReference.fromJson),
      );
      _validateObservedRevocations(observedRevocations);
    } else {
      throw const FormatException('KnownHost schema version is unsupported');
    }

    final revokedByRaw = json['revoked_by_device_id'];
    final revokedAtRaw = json['revoked_at'];
    final String? revokedByDeviceId;
    final DateTime? revokedAt;
    if (state == KnownHostState.trusted) {
      if (revokedByRaw != null || revokedAtRaw != null) {
        throw const FormatException(
          'Trusted KnownHost records cannot contain revocation metadata',
        );
      }
      revokedByDeviceId = null;
      revokedAt = null;
    } else {
      revokedByDeviceId = _string(revokedByRaw, 'revoked_by_device_id');
      _validateUuidV4(revokedByDeviceId, 'revoked_by_device_id');
      revokedAt = _parseUtcTimestamp(revokedAtRaw, 'revoked_at');
    }

    final revisionIdRaw = json['_revision_id'];
    final String? revisionId;
    if (revisionIdRaw == null) {
      revisionId = null;
    } else {
      revisionId = _string(revisionIdRaw, '_revision_id');
      _validateUuidV4(revisionId, '_revision_id');
    }

    final manifest = _manifestFromJson(json['_manifest']);
    return KnownHostRecord._(
      id: id,
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
      state: state,
      approvalSource: approvalSource,
      approvedByDeviceId: approvedByDeviceId,
      approvedAt: approvedAt,
      revokedByDeviceId: revokedByDeviceId,
      revokedAt: revokedAt,
      schemaVersion: schemaVersion,
      observedRevocations: observedRevocations,
      revisionId: revisionId,
      manifest: manifest,
    );
  }

  final String id;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final KnownHostState state;
  final KnownHostApprovalSource approvalSource;
  final String approvedByDeviceId;
  final DateTime approvedAt;
  final String? revokedByDeviceId;
  final DateTime? revokedAt;
  final int schemaVersion;

  /// Exact endpoint/key revocation heads visible before this explicit
  /// reapproval. Empty for first approvals and legacy v1 records.
  final List<KnownHostRevocationReference> observedRevocations;

  /// Repository metadata, kept when a decrypted record is edited.
  final String? revisionId;
  final Map<String, Object?>? manifest;

  String get endpoint => endpointKey(host: host, port: port);

  bool matchesKey({required String algorithm, required String fingerprint}) =>
      this.algorithm == algorithm && this.fingerprint == fingerprint;

  /// Produces a revocation state while retaining the original approval
  /// decision. It does not create, locate, or overwrite an endpoint slot.
  KnownHostRecord revoke({
    required String revokedByDeviceId,
    required DateTime revokedAt,
  }) {
    if (state == KnownHostState.revoked) {
      throw StateError('KnownHost record is already revoked');
    }
    _validateUuidV4(revokedByDeviceId, 'revoked_by_device_id');
    _validateUtcDateTime(revokedAt, 'revoked_at');
    return KnownHostRecord._(
      id: id,
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
      state: KnownHostState.revoked,
      approvalSource: approvalSource,
      approvedByDeviceId: approvedByDeviceId,
      approvedAt: approvedAt,
      revokedByDeviceId: revokedByDeviceId,
      revokedAt: revokedAt,
      schemaVersion: schemaVersion,
      observedRevocations: observedRevocations,
      revisionId: revisionId,
      manifest: manifest,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'knownHost',
    'host': host,
    'port': port,
    'algorithm': algorithm,
    'fingerprint': fingerprint,
    'state': state.wireValue,
    'approval_source': approvalSource.wireValue,
    'approved_by_device_id': approvedByDeviceId,
    'approved_at': approvedAt.toIso8601String(),
    'revoked_by_device_id': revokedByDeviceId,
    'revoked_at': revokedAt?.toIso8601String(),
    if (schemaVersion == 2) ...{
      'schema_version': 2,
      'observed_revocations': observedRevocations
          .map((reference) => reference.toJson())
          .toList(growable: false),
    },
    if (manifest != null) '_manifest': manifest,
  };
}

void _validateObservedRevocations(
  List<KnownHostRevocationReference> references,
) {
  if (references.length > maxKnownHostObservedRevocations) {
    throw const FormatException(
      'KnownHost observed revocations exceed supported bounds',
    );
  }
  String? previousRecordId;
  for (final reference in references) {
    _validateUuidV4(reference.recordId, 'observed_revocations.record_id');
    _validateUuidV4(reference.revisionId, 'observed_revocations.revision_id');
    if (previousRecordId != null &&
        previousRecordId.compareTo(reference.recordId) >= 0) {
      throw const FormatException(
        'KnownHost observed revocations must be sorted and unique',
      );
    }
    previousRecordId = reference.recordId;
  }
}

/// Canonicalizes DNS, IPv4, or IPv6 host text without `dart:io`, so this code
/// can run in Web as well as native Flutter targets.
String canonicalizeKnownHost(String input) {
  if (input.isEmpty || input.trim() != input || input.contains(RegExp(r'\s'))) {
    throw const FormatException('KnownHost hostname cannot contain whitespace');
  }

  var host = input;
  final hasOpeningBracket = host.startsWith('[');
  final hasClosingBracket = host.endsWith(']');
  if (hasOpeningBracket || hasClosingBracket) {
    if (!hasOpeningBracket || !hasClosingBracket || host.length < 4) {
      throw const FormatException('Malformed bracketed IPv6 hostname');
    }
    host = host.substring(1, host.length - 1);
    if (!host.contains(':')) {
      throw const FormatException('Brackets are only valid around IPv6 hosts');
    }
  } else if (host.contains('[') || host.contains(']')) {
    throw const FormatException('Malformed bracketed IPv6 hostname');
  }

  if (host.contains(':')) return _canonicalizeIpv6(host);
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return _canonicalizeIpv4(host);

  var dnsName = host;
  if (dnsName.endsWith('.')) dnsName = dnsName.substring(0, dnsName.length - 1);
  if (dnsName.isEmpty || dnsName.endsWith('.') || dnsName.length > 253) {
    throw const FormatException('Invalid DNS hostname');
  }
  final labels = dnsName.split('.');
  final labelPattern = RegExp(
    r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
  );
  if (labels.any((label) => !labelPattern.hasMatch(label))) {
    throw const FormatException('Invalid DNS hostname');
  }
  return dnsName.toLowerCase();
}

/// Returns the canonical endpoint key used to compare host-key trust entries.
String endpointKey({required String host, required int port}) {
  _validatePort(port);
  final canonicalHost = canonicalizeKnownHost(host);
  final displayHost = canonicalHost.contains(':')
      ? '[$canonicalHost]'
      : canonicalHost;
  return '$displayHost:$port';
}

String _canonicalizeIpv4(String input) {
  final pieces = input.split('.');
  if (pieces.length != 4) {
    throw const FormatException('IPv4 hostname must contain four octets');
  }
  final octets = <int>[];
  for (final piece in pieces) {
    if (piece.isEmpty ||
        !RegExp(r'^[0-9]{1,3}$').hasMatch(piece) ||
        (piece.length > 1 && piece.startsWith('0'))) {
      throw const FormatException(
        'IPv4 octets must use canonical decimal form',
      );
    }
    final octet = int.parse(piece);
    if (octet > 255) throw const FormatException('IPv4 octet is out of range');
    octets.add(octet);
  }
  return octets.join('.');
}

String _canonicalizeIpv6(String input) {
  if (input.contains('%') || input.contains(':::')) {
    throw const FormatException('Invalid or scoped IPv6 hostname');
  }
  final compressionIndex = input.indexOf('::');
  final hasCompression = compressionIndex >= 0;
  if (hasCompression && compressionIndex != input.lastIndexOf('::')) {
    throw const FormatException('IPv6 may contain only one :: compression');
  }

  final List<int> words;
  if (!hasCompression) {
    words = _parseIpv6Side(input, allowIpv4Tail: true);
    if (words.length != 8) {
      throw const FormatException('Uncompressed IPv6 must contain eight words');
    }
  } else {
    final leftText = input.substring(0, compressionIndex);
    final rightText = input.substring(compressionIndex + 2);
    final left = leftText.isEmpty
        ? <int>[]
        : _parseIpv6Side(leftText, allowIpv4Tail: false);
    final right = rightText.isEmpty
        ? <int>[]
        : _parseIpv6Side(rightText, allowIpv4Tail: true);
    final usedWords = left.length + right.length;
    if (usedWords >= 8) {
      throw const FormatException('IPv6 :: must compress at least one word');
    }
    words = [...left, ...List<int>.filled(8 - usedWords, 0), ...right];
  }

  return _formatIpv6(words);
}

List<int> _parseIpv6Side(String input, {required bool allowIpv4Tail}) {
  final parts = input.split(':');
  final words = <int>[];
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.isEmpty) throw const FormatException('Empty IPv6 word');
    if (part.contains('.')) {
      if (!allowIpv4Tail || index != parts.length - 1) {
        throw const FormatException(
          'Embedded IPv4 must be the final IPv6 component',
        );
      }
      final octets = _canonicalizeIpv4(part).split('.').map(int.parse).toList();
      words
        ..add((octets[0] << 8) | octets[1])
        ..add((octets[2] << 8) | octets[3]);
      continue;
    }
    if (!RegExp(r'^[0-9A-Fa-f]{1,4}$').hasMatch(part)) {
      throw const FormatException('Invalid IPv6 word');
    }
    words.add(int.parse(part, radix: 16));
  }
  return words;
}

String _formatIpv6(List<int> words) {
  var bestStart = -1;
  var bestLength = 1;
  for (var index = 0; index < words.length;) {
    if (words[index] != 0) {
      index++;
      continue;
    }
    var end = index + 1;
    while (end < words.length && words[end] == 0) {
      end++;
    }
    final length = end - index;
    if (length > bestLength) {
      bestStart = index;
      bestLength = length;
    }
    index = end;
  }

  final hex = words.map((word) => word.toRadixString(16)).toList();
  if (bestStart < 0) return hex.join(':');
  final bestEnd = bestStart + bestLength;
  final left = hex.take(bestStart).join(':');
  final right = hex.skip(bestEnd).join(':');
  if (left.isEmpty && right.isEmpty) return '::';
  if (left.isEmpty) return '::$right';
  if (right.isEmpty) return '$left::';
  return '$left::$right';
}

void _validatePort(int port) {
  if (port < 1 || port > 65535) {
    throw const FormatException('KnownHost port must be between 1 and 65535');
  }
}

void _validateAlgorithm(String algorithm) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+@-]{0,127}$').hasMatch(algorithm)) {
    throw const FormatException('Invalid SSH host-key algorithm');
  }
}

void _validateFingerprint(String fingerprint) {
  const prefix = 'SHA256:';
  if (!fingerprint.startsWith(prefix)) {
    throw const FormatException(
      'Host-key fingerprint must use OpenSSH SHA256 form',
    );
  }
  final encoded = fingerprint.substring(prefix.length);
  if (!RegExp(r'^[A-Za-z0-9+/]{43}$').hasMatch(encoded)) {
    throw const FormatException('Host-key fingerprint is not canonical base64');
  }
  try {
    if (base64.decode('$encoded=').length != 32 ||
        base64Encode(base64.decode('$encoded=')) != '$encoded=') {
      throw const FormatException('Host-key fingerprint must encode 32 bytes');
    }
  } on FormatException {
    throw const FormatException('Host-key fingerprint is not canonical base64');
  }
}

void _validateUuidV4(String value, String field) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw FormatException('$field must be a lowercase UUIDv4');
  }
}

void _validateUtcDateTime(DateTime value, String field) {
  if (!value.isUtc) throw FormatException('$field must be UTC');
}

DateTime _parseUtcTimestamp(Object? value, String field) {
  final text = _string(value, field);
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z$',
  ).hasMatch(text)) {
    throw FormatException('$field must be canonical UTC RFC 3339');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != text) {
    throw FormatException('$field must be a valid canonical UTC timestamp');
  }
  return parsed;
}

String _string(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

Map<String, Object?>? _manifestFromJson(Object? value) {
  if (value == null) return null;
  if (value is! Map) {
    throw const FormatException('Record _manifest must be a JSON object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('Record _manifest keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}
