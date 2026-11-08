import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';

void main() {
  late Directory directory;
  late File databaseFile;
  late LocalProfileCatalog catalog;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-profile-catalog-',
    );
    databaseFile = File('${directory.path}/catalog.sqlite');
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(databaseFile));
  });

  tearDown(() async {
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('creates two profiles and reads them after close and reopen', () async {
    final first = _profile('1');
    final second = _profile('2');
    final createdAt = DateTime.utc(2025, 3, 4, 5, 6, 7);

    final firstCreated = await _create(catalog, first, createdAt: createdAt);
    final secondCreated = await _create(catalog, second);
    expect(firstCreated.createdAt, createdAt);
    expect(secondCreated.profileId, second.profileId);
    expect(firstCreated.profileVersion, 1);
    expect(firstCreated.vaultKeyEpoch, 1);
    expect(firstCreated.deviceKeyVersion, 1);
    expect((await catalog.list()).map((row) => row.profileId), [
      first.profileId,
      second.profileId,
    ]);

    await catalog.close();
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(databaseFile));
    await catalog.ensureReady();

    final reopened = await catalog.get(first.profileId);
    expect(reopened?.toJson(), firstCreated.toJson());
    expect(reopened?.createdAt.isUtc, isTrue);
    expect((await catalog.list()).map((row) => row.profileId), [
      first.profileId,
      second.profileId,
    ]);
    expect(await catalog.get(_uuid('9')), isNull);
  });

  test('unique profile and identity identifiers cannot be reused', () async {
    final first = _profile('1');
    await _create(catalog, first);

    await expectLater(_create(catalog, first), throwsA(anything));

    final collidingDomain = _profile(
      '2',
    ).copyWith(localDataDomainId: first.localDataDomainId);
    await expectLater(_create(catalog, collidingDomain), throwsA(anything));

    final racing = _profile('3');
    final raceResults = await Future.wait([
      _capture(_create(catalog, racing)),
      _capture(_create(catalog, racing.copyWith(vaultCiphertextByte: 99))),
    ]);
    final winners = raceResults.whereType<LocalProfileRecord>().toList();
    expect(winners, hasLength(1));
    expect(
      (await catalog.get(racing.profileId))?.toJson(),
      winners.single.toJson(),
    );
    expect((await catalog.list()).length, 2);
  });

  test(
    'rejects invalid IDs, context mismatches, and plaintext fields',
    () async {
      final profile = _profile('1');

      await expectLater(
        catalog.create(
          profileId: profile.profileId.replaceFirst('10000000', 'A0000000'),
          localDataDomainId: profile.localDataDomainId,
          localVaultId: profile.localVaultId,
          localDeviceId: profile.localDeviceId,
          kdfMetadata: profile.kdf,
          umkEnvelope: profile.umk,
          vaultKeyEnvelope: profile.vault,
          deviceIdentityEnvelope: profile.identity,
        ),
        throwsA(isA<FormatException>()),
      );

      final unsupportedKdf = Map<String, Object?>.from(profile.kdf)
        ..['mem_kib'] = 131072;
      final unsupportedUmk = Map<String, Object?>.from(profile.umk)
        ..['kdf'] = unsupportedKdf;
      await expectLater(
        catalog.create(
          profileId: profile.profileId,
          localDataDomainId: profile.localDataDomainId,
          localVaultId: profile.localVaultId,
          localDeviceId: profile.localDeviceId,
          kdfMetadata: unsupportedKdf,
          umkEnvelope: unsupportedUmk,
          vaultKeyEnvelope: profile.vault,
          deviceIdentityEnvelope: profile.identity,
        ),
        throwsA(isA<FormatException>()),
      );

      final oversizedUmk = Map<String, Object?>.from(profile.umk)
        ..['ciphertext'] = List<String>.filled(1024 * 1024, 'A').join();
      await expectLater(
        catalog.create(
          profileId: profile.profileId,
          localDataDomainId: profile.localDataDomainId,
          localVaultId: profile.localVaultId,
          localDeviceId: profile.localDeviceId,
          kdfMetadata: profile.kdf,
          umkEnvelope: oversizedUmk,
          vaultKeyEnvelope: profile.vault,
          deviceIdentityEnvelope: profile.identity,
        ),
        throwsA(isA<FormatException>()),
      );

      final wrongContextUmk = Map<String, Object?>.from(profile.umk)
        ..['profile_id'] = _uuid('8');
      await expectLater(
        catalog.create(
          profileId: profile.profileId,
          localDataDomainId: profile.localDataDomainId,
          localVaultId: profile.localVaultId,
          localDeviceId: profile.localDeviceId,
          kdfMetadata: profile.kdf,
          umkEnvelope: wrongContextUmk,
          vaultKeyEnvelope: profile.vault,
          deviceIdentityEnvelope: profile.identity,
        ),
        throwsA(isA<FormatException>()),
      );

      const secretSentinel = 'LOCAL_PRIVATE_MATERIAL_SENTINEL_74dce1';
      final smuggledPrivateKey = Map<String, Object?>.from(profile.identity)
        ..['private_key'] = secretSentinel;
      await expectLater(
        catalog.create(
          profileId: profile.profileId,
          localDataDomainId: profile.localDataDomainId,
          localVaultId: profile.localVaultId,
          localDeviceId: profile.localDeviceId,
          kdfMetadata: profile.kdf,
          umkEnvelope: profile.umk,
          vaultKeyEnvelope: profile.vault,
          deviceIdentityEnvelope: smuggledPrivateKey,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await catalog.list(), isEmpty);

      final rawBytes = await databaseFile.readAsBytes();
      expect(String.fromCharCodes(rawBytes), isNot(contains(secretSentinel)));
    },
  );

  test(
    'validated profile records deep-copy and freeze envelope metadata',
    () async {
      final fixture = _profile('1');
      final created = await _create(catalog, fixture);
      final nestedKdf = created.umkEnvelope['kdf']! as Map<String, Object?>;

      expect(() => nestedKdf['iterations'] = 9, throwsUnsupportedError);
      fixture.kdf['iterations'] = 9;
      expect(nestedKdf['iterations'], 3);
      expect(
        (await catalog.get(fixture.profileId))?.umkEnvelope['kdf'],
        _profileKdfFixture(fixture),
      );
    },
  );

  test(
    'catalog schema stores envelopes as canonical ciphertext JSON',
    () async {
      final profile = _profile('1');
      await _create(catalog, profile);

      final rows = await catalog.customSelect('''
          SELECT kdf_json, umk_envelope_json, vault_key_envelope_json,
                 device_identity_envelope_json
          FROM local_profile_catalog
        ''').getSingle();
      expect(
        jsonDecode(rows.read<String>('umk_envelope_json'))['ciphertext'],
        profile.umk['ciphertext'],
      );
      expect(
        jsonDecode(rows.read<String>('vault_key_envelope_json'))['ciphertext'],
        profile.vault['ciphertext'],
      );
      expect(
        jsonDecode(
          rows.read<String>('device_identity_envelope_json'),
        )['ciphertext'],
        profile.identity['ciphertext'],
      );
    },
  );
}

Future<LocalProfileRecord> _create(
  LocalProfileCatalog catalog,
  _ProfileFixture fixture, {
  DateTime? createdAt,
}) => catalog.create(
  profileId: fixture.profileId,
  localDataDomainId: fixture.localDataDomainId,
  localVaultId: fixture.localVaultId,
  localDeviceId: fixture.localDeviceId,
  createdAt: createdAt,
  kdfMetadata: fixture.kdf,
  umkEnvelope: fixture.umk,
  vaultKeyEnvelope: fixture.vault,
  deviceIdentityEnvelope: fixture.identity,
);

Future<LocalProfileRecord?> _capture(
  Future<LocalProfileRecord> operation,
) async {
  try {
    return await operation;
  } on Object {
    return null;
  }
}

_ProfileFixture _profile(String suffix) {
  final profileId = _uuid('1$suffix');
  final domainId = _uuid('2$suffix');
  final vaultId = _uuid('3$suffix');
  final deviceId = _uuid('4$suffix');
  final kdf = <String, Object?>{
    'id': 'argon2id13',
    'salt': _b64(List<int>.generate(16, (index) => index + suffix.length)),
    'mem_kib': 65536,
    'iterations': 3,
    'parallelism': 1,
    'version': 1,
  };
  return _ProfileFixture(
    profileId: profileId,
    localDataDomainId: domainId,
    localVaultId: vaultId,
    localDeviceId: deviceId,
    kdf: kdf,
    umk: {
      'format': 'atermius-local-umk-envelope',
      'envelope_version': 1,
      'key_version': 1,
      'purpose': 'local-umk-wrap',
      'profile_id': profileId,
      'local_data_domain_id': domainId,
      'kdf': kdf,
      'nonce': _b64(List<int>.filled(24, 1)),
      'ciphertext': _b64(List<int>.filled(48, 2)),
    },
    vault: {
      'format': 'atermius-local-vault-key-envelope',
      'envelope_version': 1,
      'key_version': 1,
      'purpose': 'local-vault-key-wrap',
      'profile_id': profileId,
      'local_data_domain_id': domainId,
      'local_vault_id': vaultId,
      'key_epoch': 1,
      'suite': 'xchacha20-poly1305-ietf',
      'nonce': _b64(List<int>.filled(24, 3)),
      'ciphertext': _b64(List<int>.filled(48, 4)),
    },
    identity: {
      'format': 'atermius-local-device-identity-envelope',
      'envelope_version': 1,
      'key_version': 1,
      'purpose': 'local-device-identity-wrap',
      'profile_id': profileId,
      'local_data_domain_id': domainId,
      'local_device_id': deviceId,
      'signing_algorithm': 'ed25519',
      'signing_public': _b64(List<int>.filled(32, 5)),
      'encryption_algorithm': 'curve25519-xsalsa20-poly1305',
      'encryption_public': _b64(List<int>.filled(32, 6)),
      'suite': 'xchacha20-poly1305-ietf',
      'nonce': _b64(List<int>.filled(24, 7)),
      'ciphertext': _b64(List<int>.filled(112, 8)),
    },
  );
}

String _uuid(String tail) => '10000000-0000-4000-8000-${tail.padLeft(12, '0')}';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Map<String, Object?> _profileKdfFixture(_ProfileFixture fixture) => {
  'id': 'argon2id13',
  'salt': fixture.kdf['salt'],
  'mem_kib': 65536,
  'iterations': 3,
  'parallelism': 1,
  'version': 1,
};

class _ProfileFixture {
  const _ProfileFixture({
    required this.profileId,
    required this.localDataDomainId,
    required this.localVaultId,
    required this.localDeviceId,
    required this.kdf,
    required this.umk,
    required this.vault,
    required this.identity,
  });

  final String profileId;
  final String localDataDomainId;
  final String localVaultId;
  final String localDeviceId;
  final Map<String, Object?> kdf;
  final Map<String, Object?> umk;
  final Map<String, Object?> vault;
  final Map<String, Object?> identity;

  _ProfileFixture copyWith({
    String? localDataDomainId,
    int? vaultCiphertextByte,
  }) {
    final domainId = localDataDomainId ?? this.localDataDomainId;
    return _ProfileFixture(
      profileId: profileId,
      localDataDomainId: domainId,
      localVaultId: localVaultId,
      localDeviceId: localDeviceId,
      kdf: kdf,
      umk: Map<String, Object?>.from(umk)..['local_data_domain_id'] = domainId,
      vault: Map<String, Object?>.from(vault)
        ..['local_data_domain_id'] = domainId
        ..['ciphertext'] = vaultCiphertextByte == null
            ? vault['ciphertext']
            : _b64(List<int>.filled(48, vaultCiphertextByte)),
      identity: Map<String, Object?>.from(identity)
        ..['local_data_domain_id'] = domainId,
    );
  }
}
