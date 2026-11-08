// Real Windows runner entry, built with -t integration/native/local_resume_probe.dart.
// Each phase is a separate process. Environment:
// ATERMIUS_LOCAL_RESUME_PROBE_PHASE=seed|resume|forgot|cleanup
// ATERMIUS_LOCAL_RESUME_PROBE_ROOT=<unique empty absolute fixture directory>
// ATERMIUS_LOCAL_RESUME_PROBE_KEY_PREFIX=atermius-resume-probe-<UUID v4>
// Evidence: <root>/<phase>-result.json. manifest.json contains synthetic IDs only.
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_resume_store.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_resume_revocation_native.dart'
    as revocation;
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

const _secret = 'synthetic-fixture-only-not-a-user-credential';
void _require(bool value) {
  if (!value) throw StateError('Native resume acceptance condition failed.');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['ATERMIUS_LOCAL_RESUME_PROBE_PHASE'];
  final path = Platform.environment['ATERMIUS_LOCAL_RESUME_PROBE_ROOT'];
  final prefix = Platform.environment['ATERMIUS_LOCAL_RESUME_PROBE_KEY_PREFIX'];
  Directory? root;
  LocalProfileCatalog? catalog;
  LocalVaultDatabase? vault;
  UnlockedLocalProfile? profile;
  final evidence = <String, Object>{'passed': false};
  var code = 1;
  var stage = 'environment';
  try {
    _require(Platform.isWindows);
    _require(const ['seed', 'resume', 'forgot', 'cleanup'].contains(phase));
    evidence['phase'] = phase!;
    _require(path != null && path.isNotEmpty && File(path).isAbsolute);
    _require(
      prefix != null &&
          RegExp(
            r'^atermius-resume-probe-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(prefix),
    );
    root = Directory(path!);
    if (phase == 'seed') {
      if (await root.exists()) _require(await root.list().isEmpty);
      await root.create(recursive: true);
    } else {
      _require(await root.exists());
    }
    final manifestFile = File('${root.path}/manifest.json');
    final catalogFile = File('${root.path}/catalog.sqlite');
    if (phase != 'seed') _require(await catalogFile.exists());
    stage = 'crypto_init';
    final crypto = VaultCrypto(await SodiumSumoInit.init());
    const raw = FlutterSecureStorage();
    final store = NativeLocalProfileResumeStore(
      storage: raw,
      keyPrefix: prefix!,
    );
    final secureKey = '$prefix.local-profile-resume.v1';
    catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
    final service = LocalProfileService(
      catalog: catalog,
      crypto: crypto,
      resumeStore: store,
    );
    Future<LocalVaultDatabase> openVault(LocalVaultOpenMode mode) {
      final r = profile!.record;
      return LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(File('${root!.path}/vault.sqlite')),
        profileId: r.profileId,
        localDataDomainId: r.localDataDomainId,
        localVaultId: r.localVaultId,
        mode: mode,
      );
    }

    if (phase == 'seed') {
      _require(await raw.read(key: secureKey) == null);
      final passwordBytes = crypto.randomBytes(32);
      try {
        // This random password is never saved or passed to another process.
        profile = await service.create(password: base64Encode(passwordBytes));
      } finally {
        passwordBytes.fillRange(0, passwordBytes.length, 0);
      }
      vault = await openVault(LocalVaultOpenMode.createNew);
      final repository = LocalHostRepository(
        database: vault,
        profile: profile,
        crypto: crypto,
      );
      final hostId = const Uuid().v4();
      final credentialId = const Uuid().v4();
      await repository.createCredential(
        CredentialRecord(
          id: credentialId,
          name: 'Synthetic probe credential',
          username: 'probe',
          secret: _secret,
        ),
      );
      final savedHost = await repository.createHost(
        HostRecord(
          id: hostId,
          name: 'Synthetic resume host',
          address: 'resume-probe.invalid',
          username: 'probe',
          credentialId: credentialId,
        ),
      );
      await service.remember(profile);
      _require(await raw.read(key: secureKey) != null);
      await manifestFile.writeAsString(
        jsonEncode({
          'profile_id': profile.record.profileId,
          'host_id': savedHost.id,
          'credential_id': credentialId,
        }),
        flush: true,
      );
      evidence['secure_key_retained'] = true;
    } else if (phase == 'cleanup') {
      stage = 'cleanup_owned_fixture';
      await service.forgetResume();
      _require(await raw.read(key: secureKey) == null);
      await revocation.setRevoked(secureKey, false);
      evidence['raw_secure_key_deleted'] = true;
      evidence['marker_cleanup'] = true;
    } else {
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      stage = 'raw_secure_read';
      evidence['raw_secure_record_present'] =
          await raw.read(key: secureKey) != null;
      stage = 'revocation_marker_read';
      evidence['revocation_marker_present'] = await revocation.isRevoked(
        secureKey,
      );
      stage = 'catalog_list';
      evidence['catalog_profile_count'] = (await catalog.list()).length;
      evidence['vault_exists'] = await File('${root.path}/vault.sqlite')
          .exists();
      stage = 'production_try_resume';
      profile = await service.tryResume();
      evidence['resume_nonnull'] = profile != null;
      evidence['profile_id_matches'] =
          profile?.record.profileId == manifest['profile_id'];
      if (phase == 'forgot') {
        _require(profile == null);
        _require(await raw.read(key: secureKey) == null);
        evidence['resume_revoked'] = true;
        await revocation.setRevoked(secureKey, false);
        evidence['marker_cleanup'] = true;
      } else {
        stage = 'require_resumed_profile';
        _require(
          profile != null && profile.record.profileId == manifest['profile_id'],
        );
        _require(await File('${root.path}/vault.sqlite').exists());
        stage = 'vault_open_existing';
        vault = await openVault(LocalVaultOpenMode.openExisting);
        final repository = LocalHostRepository(
          database: vault,
          profile: profile!,
          crypto: crypto,
        );
        stage = 'host_read';
        final host = await repository.getHost(manifest['host_id'] as String);
        stage = 'credential_read';
        final credential = await repository.getCredential(
          manifest['credential_id'] as String,
        );
        evidence['host_exists'] = host != null;
        evidence['credential_exists'] = credential != null;
        evidence['host_address_matches'] =
            host?.address == 'resume-probe.invalid';
        evidence['host_credential_matches'] =
            host?.credentialId == manifest['credential_id'];
        evidence['credential_secret_matches'] = credential?.secret == _secret;
        _require(
          host?.address == 'resume-probe.invalid' &&
              host?.credentialId == manifest['credential_id'] &&
              credential?.secret == _secret,
        );
        evidence['host_decrypted'] = true;
        evidence['credential_decrypted'] = true;
        stage = 'forget_resume';
        await service.forgetResume();
        _require(await raw.read(key: secureKey) == null);
        evidence['raw_secure_key_deleted'] = true;
      }
    }
    stage = 'complete';
    code = 0;
  } on Object catch (error) {
    evidence['error_type'] = error.runtimeType.toString();
  } finally {
    try {
      // Ordinary RAM cleanup must preserve seed's OS protected resume key.
      await profile?.lock();
      await vault?.close();
      await catalog?.close();
    } on Object catch (error) {
      code = 1;
      evidence['cleanup_error_type'] = error.runtimeType.toString();
    }
    evidence['stage'] = stage;
    evidence['passed'] = code == 0;
    if (root != null &&
        const ['seed', 'resume', 'forgot', 'cleanup'].contains(phase)) {
      try {
        await File('${root.path}/$phase-result.json')
            .writeAsString(jsonEncode(evidence), flush: true);
      } on Object {
        code = 1;
      }
    }
  }
  exit(code);
}
