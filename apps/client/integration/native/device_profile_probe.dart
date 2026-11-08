// Independent Windows processes, built with:
// flutter build windows --profile -t integration/native/device_profile_probe.dart
// Environment (reuse ROOT and KEY_PREFIX across the five process invocations):
// ATERMIUS_DEVICE_PROFILE_PROBE_PHASE=seed|resume|locked|open|cleanup
// ATERMIUS_DEVICE_PROFILE_PROBE_ROOT=<unique empty absolute directory>
// ATERMIUS_DEVICE_PROFILE_PROBE_KEY_PREFIX=atermius-device-probe-<UUID v4>
// Run seed -> resume -> locked -> open -> cleanup. Each writes <phase>-result.json.
// ROOT retains only evidence and a synthetic ownership manifest after cleanup;
// ROOT/fixture and both uniquely namespaced OS records/markers are removed.
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/native_coordination.dart';
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
import 'package:path/path.dart' as p;
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

const _phases = ['seed', 'resume', 'locked', 'open', 'cleanup'];
const _format = 'atermius-device-profile-probe-v1';
const _hostAddress = 'device-profile-probe.invalid';

void _require(bool condition) {
  if (!condition) {
    throw StateError('Device profile acceptance condition failed.');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['ATERMIUS_DEVICE_PROFILE_PROBE_PHASE'];
  final path = Platform.environment['ATERMIUS_DEVICE_PROFILE_PROBE_ROOT'];
  final prefix =
      Platform.environment['ATERMIUS_DEVICE_PROFILE_PROBE_KEY_PREFIX'];
  Directory? root;
  Directory? fixture;
  LocalProfileCatalog? catalog;
  LocalVaultDatabase? vault;
  UnlockedLocalProfile? profile;
  var code = 1;
  var stage = 'environment';
  var validatedRoot = false;
  var removeFixture = false;
  final evidence = <String, Object>{'passed': false};
  try {
    _require(Platform.isWindows);
    _require(_phases.contains(phase));
    _require(path != null && path.isNotEmpty && p.isAbsolute(path));
    _require(
      prefix != null &&
          RegExp(
            r'^atermius-device-probe-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(prefix),
    );
    evidence['phase'] = phase!;
    root = Directory(p.normalize(path!));
    if (phase == 'seed') {
      if (await root.exists()) _require(await root.list().isEmpty);
      await root.create(recursive: true);
    }
    _require(
      await FileSystemEntity.type(root.path, followLinks: false) ==
          FileSystemEntityType.directory,
    );
    _require(p.equals(await root.resolveSymbolicLinks(), root.absolute.path));
    fixture = Directory(p.join(root.path, 'fixture'));
    final manifestFile = File(p.join(root.path, 'manifest.json'));
    Map<String, dynamic> manifest;
    if (phase == 'seed') {
      manifest = {'format': _format, 'key_prefix': prefix};
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
      await fixture.create();
    } else {
      _require(await manifestFile.exists());
      manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      _require(
        manifest['format'] == _format && manifest['key_prefix'] == prefix,
      );
    }
    validatedRoot = true;
    if (await fixture.exists()) {
      _require(
        await FileSystemEntity.type(fixture.path, followLinks: false) ==
            FileSystemEntityType.directory,
      );
      _require(
        p.equals(await fixture.resolveSymbolicLinks(), fixture.absolute.path),
      );
    } else {
      _require(phase == 'cleanup');
    }
    // Use the production OS-lock implementation in an isolated fixture folder.
    coordinationDirectory = () async =>
        Directory(p.join(fixture!.path, 'coordination'));
    final resumePrefix = '$prefix.resume';
    final devicePrefix = '$prefix.device';
    final resumeKey = '$resumePrefix.local-profile-resume.v1';
    final deviceKey = '$devicePrefix.local-profile-resume.v1';
    const raw = FlutterSecureStorage();
    final resumeStore = NativeLocalProfileResumeStore(
      storage: raw,
      keyPrefix: resumePrefix,
    );
    final deviceStore = NativeLocalProfileResumeStore(
      storage: raw,
      keyPrefix: devicePrefix,
    );

    if (phase == 'cleanup') {
      stage = 'cleanup_owned_os_records';
      // Delete exactly the two manifest-bound test keys, never readAll/deleteAll.
      await raw.delete(key: resumeKey);
      await raw.delete(key: deviceKey);
      _require(
        await raw.read(key: resumeKey) == null &&
            await raw.read(key: deviceKey) == null,
      );
      await revocation.setRevoked(resumeKey, false);
      await revocation.setRevoked(deviceKey, false);
      _require(
        !await revocation.isRevoked(resumeKey) &&
            !await revocation.isRevoked(deviceKey),
      );
      evidence['owned_secure_records_removed'] = true;
      evidence['owned_markers_removed'] = true;
      removeFixture = true;
    } else {
      stage = 'crypto_and_fixture';
      final crypto = VaultCrypto(await SodiumSumoInit.init());
      final catalogFile = File(p.join(fixture.path, 'catalog.sqlite'));
      if (phase != 'seed') _require(await catalogFile.exists());
      catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
      final service = LocalProfileService(
        catalog: catalog,
        crypto: crypto,
        resumeStore: resumeStore,
        deviceKeyStore: deviceStore,
      );
      Future<LocalVaultDatabase> openVault(
        UnlockedLocalProfile unlocked,
        LocalVaultOpenMode mode,
      ) {
        final r = unlocked.record;
        return LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File(p.join(fixture!.path, 'vault.sqlite'))),
          profileId: r.profileId,
          localDataDomainId: r.localDataDomainId,
          localVaultId: r.localVaultId,
          mode: mode,
        );
      }

      if (phase == 'seed') {
        stage = 'protected_bootstrap';
        _require(
          await raw.read(key: resumeKey) == null &&
              await raw.read(key: deviceKey) == null,
        );
        _require(
          !await revocation.isRevoked(resumeKey) &&
              !await revocation.isRevoked(deviceKey),
        );
        var initializedBeforePublish = false;
        profile = await service.createDeviceProtected(
          initializeVault: (staged) async {
            _require((await catalog!.list()).isEmpty);
            final initialized = await openVault(
              staged,
              LocalVaultOpenMode.createNew,
            );
            await initialized.close();
            initializedBeforePublish = true;
          },
        );
        _require(initializedBeforePublish && profile.isNewlyCreated);
        _require((await catalog.list()).length == 1);
        _require(
          await raw.read(key: resumeKey) != null &&
              await raw.read(key: deviceKey) != null,
        );
        vault = await openVault(profile, LocalVaultOpenMode.openExisting);
        final repository = LocalHostRepository(
          database: vault,
          profile: profile,
          crypto: crypto,
        );
        final host = await repository.createHost(
          HostRecord(
            id: const Uuid().v4(),
            name: 'Synthetic device protected host',
            address: _hostAddress,
            username: 'probe',
          ),
        );
        manifest.addAll({
          'profile_id': profile.record.profileId,
          'host_id': host.id,
        });
        await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
        evidence['vault_initialized_before_catalog'] = true;
        evidence['two_os_records_verified'] = true;
        evidence['synthetic_host_saved'] = true;
      } else if (phase == 'locked') {
        stage = 'manual_lock_revoke_auto_resume';
        profile = await service.tryResume();
        _require(profile?.record.profileId == manifest['profile_id']);
        await service.forgetResume();
        await profile!.lock();
        profile = null;
        _require(await service.tryResume() == null);
        _require(await raw.read(key: resumeKey) == null);
        _require(await deviceStore.read() != null);
        evidence['auto_resume_revoked'] = true;
        evidence['device_key_preserved'] = true;
      } else {
        if (phase == 'open') {
          stage = 'new_process_stays_locked';
          _require(await service.tryResume() == null);
          _require(
            await service.isDeviceManaged(manifest['profile_id'] as String),
          );
          evidence['new_process_auto_resume_blocked'] = true;
          stage = 'explicit_device_unlock';
          profile = await service.unlockDeviceProfile(
            manifest['profile_id'] as String,
          );
        } else {
          stage = 'new_process_resume_without_password';
          profile = await service.tryResume();
        }
        _require(profile?.record.profileId == manifest['profile_id']);
        stage = 'decrypt_same_synthetic_host';
        vault = await openVault(profile!, LocalVaultOpenMode.openExisting);
        final repository = LocalHostRepository(
          database: vault,
          profile: profile,
          crypto: crypto,
        );
        final host = await repository.getHost(manifest['host_id'] as String);
        _require(
          host?.address == _hostAddress &&
              host?.name == 'Synthetic device protected host',
        );
        evidence['same_profile_restored'] = true;
        evidence['same_host_decrypted'] = true;
        evidence['password_not_required'] = true;
        if (phase == 'open') {
          _require(await service.tryResume() == null);
          evidence['explicit_open_does_not_enable_auto_resume'] = true;
        }
      }
    }
    stage = 'complete';
    code = 0;
  } on Object catch (error) {
    evidence['error_type'] = error.runtimeType.toString();
  } finally {
    try {
      await vault?.close();
      await profile?.lock();
      await catalog?.close();
      if (removeFixture && fixture != null && await fixture.exists()) {
        // Only the fixed child of the verified probe root is ever deleted.
        await fixture.delete(recursive: true);
        evidence['fixture_removed'] = true;
      }
    } on Object catch (error) {
      code = 1;
      evidence['cleanup_error_type'] = error.runtimeType.toString();
    }
    evidence['passed'] = code == 0;
    evidence['stage'] = stage;
    if (validatedRoot && root != null && _phases.contains(phase)) {
      try {
        await File(p.join(root.path, '$phase-result.json'))
            .writeAsString(jsonEncode(evidence), flush: true);
      } on Object {
        code = 1;
      }
    }
  }
  exit(code);
}
