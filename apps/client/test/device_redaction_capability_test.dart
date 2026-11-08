import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/device_redaction_capability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

late SodiumSumo _sodium;
late VaultCrypto _crypto;
late DeviceIdentity _identity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _sodium = await SodiumSumoInit.init();
    _crypto = VaultCrypto(_sodium);
    _identity = DeviceIdentity.create(_sodium);
  });

  tearDownAll(() => _identity.dispose());

  test('verifies the v1 report using the signing key on its device row', () {
    final readiness = DeviceRedactionReadiness.fromVaultDeviceRow(
      _row(_signedReport()),
      crypto: _crypto,
    );

    expect(readiness.status, DeviceRedactionReadinessStatus.ready);
    expect(readiness.statusLabel, 'Ready');
    expect(readiness.revision, 4);
    expect(readiness.syncRedactionVersion, 1);
    expect(readiness.blocksPurge, isFalse);
  });

  test('distinguishes explicit missing from a legacy absent field', () {
    final missing = DeviceRedactionReadiness.fromVaultDeviceRow(
      _row(null),
      crypto: _crypto,
    );
    final legacyRow = _row(null, includeReport: false);
    final legacy = DeviceRedactionReadiness.fromVaultDeviceRow(
      legacyRow,
      crypto: _crypto,
    );

    expect(missing.status, DeviceRedactionReadinessStatus.missing);
    expect(missing.statusLabel, 'Report not received');
    expect(legacy.status, DeviceRedactionReadinessStatus.unverifiable);
    expect(legacy.statusLabel, 'Report could not be verified');
    expect(legacy.blocksPurge, isTrue);
  });

  test('requires a valid signed report before trusting invalidation state', () {
    final invalidated = DeviceRedactionReadiness.fromVaultDeviceRow(
      _row(_signedReport(invalidatedAt: '2026-10-12T10:00:00Z')),
      crypto: _crypto,
    );
    final otherSigner = DeviceIdentity.create(_sodium);
    try {
      final forged = DeviceRedactionReadiness.fromVaultDeviceRow(
        _row(
          _signedReport(
            signer: otherSigner,
            invalidatedAt: '2026-10-12T10:00:00Z',
          ),
        ),
        crypto: _crypto,
      );

      expect(invalidated.status, DeviceRedactionReadinessStatus.invalidated);
      expect(invalidated.statusLabel, 'Report expired or invalidated');
      expect(forged.status, DeviceRedactionReadinessStatus.unverifiable);
      expect(forged.statusLabel, 'Report could not be verified');
    } finally {
      otherSigner.dispose();
    }
  });

  test(
    'reports a correctly signed unknown format or version as unsupported',
    () {
      final unknownFormat = DeviceRedactionReadiness.fromVaultDeviceRow(
        _row(_signedReport(format: 'atermius-sync-redaction-capability-v2')),
        crypto: _crypto,
      );
      final unknownVersion = DeviceRedactionReadiness.fromVaultDeviceRow(
        _row(_signedReport(version: 2)),
        crypto: _crypto,
      );

      expect(unknownFormat.status, DeviceRedactionReadinessStatus.unsupported);
      expect(unknownVersion.status, DeviceRedactionReadinessStatus.unsupported);
      expect(unknownVersion.statusLabel, 'Client version unsupported');
    },
  );

  test(
    'rejects tampering with signed fields and malformed report envelopes',
    () {
      final tampered = _signedReport()..['revision'] = 5;
      final malformed = _signedReport()..['unexpected'] = true;

      expect(
        DeviceRedactionReadiness.fromVaultDeviceRow(
          _row(tampered),
          crypto: _crypto,
        ).status,
        DeviceRedactionReadinessStatus.unverifiable,
      );
      expect(
        DeviceRedactionReadiness.fromVaultDeviceRow(
          _row(malformed),
          crypto: _crypto,
        ).status,
        DeviceRedactionReadinessStatus.unverifiable,
      );
    },
  );
}

Map<String, dynamic> _row(
  Map<String, dynamic>? report, {
  bool includeReport = true,
}) => {
  'user_id': _accountId,
  'device_id': _deviceId,
  'signing_public_key': encodeBase64Url(_identity.signing.publicKey),
  if (includeReport) 'redaction_capability_report': report,
};

Map<String, dynamic> _signedReport({
  DeviceIdentity? signer,
  String format = deviceRedactionCapabilityFormat,
  int version = 1,
  String? invalidatedAt,
}) {
  final actualSigner = signer ?? _identity;
  final unsigned = <String, Object?>{
    'format': format,
    'account_id': _accountId,
    'device_id': _deviceId,
    'revision': 4,
    'sync_redaction_version': version,
  };
  final signature = _sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
    secretKey: actualSigner.signing.secretKey,
  );
  return {
    ...unsigned,
    'signature': encodeBase64Url(signature),
    'invalidated_at': invalidatedAt,
  };
}
