import 'dart:convert';
import 'dart:typed_data';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';

const deviceRedactionCapabilityFormat = 'atermius-sync-redaction-capability-v1';

enum DeviceRedactionReadinessStatus {
  ready,
  missing,
  invalidated,
  unverifiable,
  unsupported,
}

/// Client-verified view of the signed redaction capability reported by a
/// device. This is for readiness and troubleshooting UI only; the server's
/// purge transaction remains authoritative.
class DeviceRedactionReadiness {
  const DeviceRedactionReadiness({
    required this.status,
    this.revision,
    this.syncRedactionVersion,
  });

  final DeviceRedactionReadinessStatus status;
  final int? revision;
  final int? syncRedactionVersion;

  String get statusLabel => switch (status) {
    DeviceRedactionReadinessStatus.ready => 'Ready',
    DeviceRedactionReadinessStatus.missing => 'Report not received',
    DeviceRedactionReadinessStatus.invalidated =>
      'Report expired or invalidated',
    DeviceRedactionReadinessStatus.unverifiable =>
      'Report could not be verified',
    DeviceRedactionReadinessStatus.unsupported => 'Client version unsupported',
  };

  bool get blocksPurge => status != DeviceRedactionReadinessStatus.ready;

  /// Verifies the detached Ed25519 signature against the public key on this
  /// same device row before trusting its version or invalidation state.
  /// Missing `redaction_capability_report` means the server predates this
  /// projection, so it is shown as unverifiable instead of assumed compatible.
  factory DeviceRedactionReadiness.fromVaultDeviceRow(
    Map<String, dynamic> row, {
    required VaultCrypto crypto,
  }) {
    if (!row.containsKey('redaction_capability_report')) {
      return const DeviceRedactionReadiness(
        status: DeviceRedactionReadinessStatus.unverifiable,
      );
    }
    final rawReport = row['redaction_capability_report'];
    if (rawReport == null) {
      return const DeviceRedactionReadiness(
        status: DeviceRedactionReadinessStatus.missing,
      );
    }
    if (rawReport is! Map) return _unverifiable();

    try {
      final report = Map<String, dynamic>.from(rawReport);
      const fields = {
        'format',
        'account_id',
        'device_id',
        'revision',
        'sync_redaction_version',
        'signature',
        'invalidated_at',
      };
      if (report.length != fields.length ||
          !report.keys.toSet().containsAll(fields)) {
        return _unverifiable();
      }

      final accountId = row['user_id'];
      final deviceId = row['device_id'];
      final signingPublicKeyText = row['signing_public_key'];
      final format = report['format'];
      final revision = report['revision'];
      final version = report['sync_redaction_version'];
      final signatureText = report['signature'];
      final invalidatedAt = report['invalidated_at'];
      if (!_isCanonicalUuid(accountId) ||
          !_isCanonicalUuid(deviceId) ||
          signingPublicKeyText is! String ||
          format is! String ||
          report['account_id'] != accountId ||
          report['device_id'] != deviceId ||
          revision is! int ||
          revision < 1 ||
          revision > 9007199254740991 ||
          version is! int ||
          version < 1 ||
          version > 9007199254740991 ||
          signatureText is! String ||
          (invalidatedAt != null &&
              (invalidatedAt is! String ||
                  DateTime.tryParse(invalidatedAt) == null))) {
        return _unverifiable();
      }

      final signingPublicKey = decodeBase64Url(signingPublicKeyText);
      final signature = decodeBase64Url(signatureText);
      if (signingPublicKey.length != 32 ||
          encodeBase64Url(signingPublicKey) != signingPublicKeyText ||
          signature.length != 64 ||
          encodeBase64Url(signature) != signatureText) {
        return _unverifiable();
      }

      final signedPayload = <String, Object?>{
        'format': format,
        'account_id': accountId,
        'device_id': deviceId,
        'revision': revision,
        'sync_redaction_version': version,
      };
      if (!crypto.sodium.crypto.sign.verifyDetached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(signedPayload))),
        signature: signature,
        publicKey: signingPublicKey,
      )) {
        return _unverifiable();
      }

      if (format != deviceRedactionCapabilityFormat || version != 1) {
        return DeviceRedactionReadiness(
          status: DeviceRedactionReadinessStatus.unsupported,
          revision: revision,
          syncRedactionVersion: version,
        );
      }
      if (invalidatedAt != null) {
        return DeviceRedactionReadiness(
          status: DeviceRedactionReadinessStatus.invalidated,
          revision: revision,
          syncRedactionVersion: version,
        );
      }
      return DeviceRedactionReadiness(
        status: DeviceRedactionReadinessStatus.ready,
        revision: revision,
        syncRedactionVersion: version,
      );
    } on Object {
      return _unverifiable();
    }
  }

  static DeviceRedactionReadiness _unverifiable() =>
      const DeviceRedactionReadiness(
        status: DeviceRedactionReadinessStatus.unverifiable,
      );
}

bool _isCanonicalUuid(Object? value) =>
    value is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value);
