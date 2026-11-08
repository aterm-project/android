import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/desktop/rdp_certificate_persistence.dart';
import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late VaultCrypto crypto;
  late LocalProfileCatalog catalog;
  late UnlockedLocalProfile profile;
  late LocalVaultDatabase database;
  late LocalHostRepository repository;
  late HostRecord original;
  final pinA = 'a' * 64, pinB = 'b' * 64;
  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });
  setUp(() async {
    catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    profile = await LocalProfileService(
      catalog: catalog,
      crypto: crypto,
    ).create(password: 'operating system observation test');
    final r = profile.record;
    database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase.memory(),
      profileId: r.profileId,
      localDataDomainId: r.localDataDomainId,
      localVaultId: r.localVaultId,
    );
    repository = LocalHostRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
    original = await repository.createHost(
      const HostRecord(
        id: '11111111-1111-4111-8111-111111111111',
        name: 'Original Host',
        address: 'example.test',
        username: 'demo',
        protocol: HostProtocol.rdp,
        manifest: {
          'future_plugin': {'keep': true},
        },
      ),
    );
  });
  tearDown(() async {
    await database.close();
    await profile.lock();
    await catalog.close();
  });

  test('certificate persists in encrypted Host and preserves concurrent name edits', () async {
    await repository.updateHost(
      host: original.copyWith(name: 'New name'),
      baseRevisionId: original.revisionId!,
    );
    final saved = await RdpCertificatePersistence.saveLocal(
      repository: repository,
      reviewed: original,
      pin: pinA,
      isCurrent: () => true,
    );
    expect(saved.name, 'New name');
    expect(saved.manifest?['future_plugin'], {'keep': true});
    expect((await repository.getHost(original.id))?.rdpCertificateSha256, pinA);
    final changed = await RdpCertificatePersistence.saveLocal(
      repository: repository,
      reviewed: saved,
      pin: pinB,
      isCurrent: () => true,
    );
    expect((await repository.getHost(original.id))?.rdpCertificateSha256, pinB);
    expect(changed.revisionId, isNot(saved.revisionId));
  });
  test(
    'endpoint change and competing trust change cannot be overwritten',
    () async {
      final changed = await repository.updateHost(
        host: original.copyWith(address: 'elsewhere.test'),
        baseRevisionId: original.revisionId!,
      );
      await expectLater(
        RdpCertificatePersistence.saveLocal(
          repository: repository,
          reviewed: original,
          pin: pinA,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      final trusted = await repository.updateHost(
        host: changed.copyWith(
          address: original.address,
          rdpCertificateSha256: pinB,
        ),
        baseRevisionId: changed.revisionId!,
      );
      await expectLater(
        RdpCertificatePersistence.saveLocal(
          repository: repository,
          reviewed: original,
          pin: pinA,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(
        (await repository.getHost(original.id))?.revisionId,
        trusted.revisionId,
      );
    },
  );
  test('locked context and deleted Host cannot create trust', () async {
    await expectLater(
      RdpCertificatePersistence.saveLocal(
        repository: repository,
        reviewed: original,
        pin: pinA,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    await repository.deleteHost(
      recordId: original.id,
      baseRevisionId: original.revisionId!,
    );
    await expectLater(
      RdpCertificatePersistence.saveLocal(
        repository: repository,
        reviewed: original,
        pin: pinA,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(await repository.getHost(original.id), isNull);
  });

  test('display settings persist on top of concurrent edits in the encrypted vault', () async {
    // Someone renames the Host after the session started.
    final renamed = await repository.updateHost(
      host: original.copyWith(name: 'Renamed'),
      baseRevisionId: original.revisionId!,
    );
    final sessionCopy = original.copyWith(
      manifest: const RdpSettings(
        resolution: RdpResolutionMode.fixed,
        width: 2560,
        height: 1440,
      ).applyTo(original.manifest),
    );
    final saved = await DesktopDisplayPersistence.saveLocal(
      repository: repository,
      updated: sessionCopy,
      isCurrent: () => true,
    );
    expect(saved.name, 'Renamed');
    expect(saved.revisionId, isNot(renamed.revisionId));
    final reread = await repository.getHost(original.id);
    expect(RdpSettings.of(reread!).width, 2560);
    expect(reread.manifest!['future_plugin'], {'keep': true});
    // A changed endpoint is refused rather than overwritten.
    await repository.updateHost(
      host: reread.copyWith(address: 'other.test'),
      baseRevisionId: reread.revisionId!,
    );
    await expectLater(
      DesktopDisplayPersistence.saveLocal(
        repository: repository,
        updated: sessionCopy,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    await expectLater(
      DesktopDisplayPersistence.saveLocal(
        repository: repository,
        updated: sessionCopy,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
  });

  test('a stale session resolution change never re-enables redirections disabled since', () async {
    // The Host as it was when the session connected: everything redirected.
    const permissive = RdpSettings(
      cameras: true,
      microphone: true,
      clipboardFiles: true,
      smartCards: true,
      drives: [RdpDriveRedirect(name: 'Work', path: '/srv/work')],
      usbDevices: ['1234:abcd'],
      printers: RdpPrinterMode.all,
    );
    final connected = await repository.updateHost(
      host: original.copyWith(manifest: permissive.applyTo(original.manifest)),
      baseRevisionId: original.revisionId!,
    );
    // Meanwhile the Host editor turns every redirection off.
    const locked = RdpSettings(clipboardText: false, scalePercent: 150);
    await repository.updateHost(
      host: connected.copyWith(manifest: locked.applyTo(connected.manifest)),
      baseRevisionId: connected.revisionId!,
    );
    // The stale session (still holding the permissive settings) saves a resolution.
    final sessionCopy = connected.copyWith(
      manifest: permissive
          .copyWith(
            resolution: RdpResolutionMode.fixed,
            width: 2560,
            height: 1440,
            scaling: DesktopLocalScaling.actualSize,
          )
          .applyTo(connected.manifest),
    );
    final saved = await DesktopDisplayPersistence.saveLocal(
      repository: repository,
      updated: sessionCopy,
      isCurrent: () => true,
    );
    final result = RdpSettings.of((await repository.getHost(saved.id))!);
    expect((result.resolution, result.width, result.height, result.scaling),
        (RdpResolutionMode.fixed, 2560, 1440, DesktopLocalScaling.actualSize));
    expect(result.cameras, isFalse);
    expect(result.microphone, isFalse);
    expect(result.clipboardFiles, isFalse);
    expect(result.clipboardText, isFalse);
    expect(result.smartCards, isFalse);
    expect(result.drives, isEmpty);
    expect(result.usbDevices, isEmpty);
    expect(result.printers, RdpPrinterMode.off);
    expect(result.scalePercent, 150);
    expect(saved.manifest!['future_plugin'], {'keep': true});
  });

  test('settings written by a newer version are not overwritten by a display save', () async {
    final future = await repository.updateHost(
      host: original.copyWith(
        manifest: {
          ...?original.manifest,
          rdpSettingsManifestKey: {'version': 2, 'new_field': true},
        },
      ),
      baseRevisionId: original.revisionId!,
    );
    await expectLater(
      DesktopDisplayPersistence.saveLocal(
        repository: repository,
        updated: future.copyWith(
          manifest: const RdpSettings(resolution: RdpResolutionMode.fixed).applyTo(null),
        ),
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    final reread = await repository.getHost(original.id);
    expect(reread!.manifest![rdpSettingsManifestKey], {'version': 2, 'new_field': true});
  });
}
